const std = @import("std");
const Zigalpm = @import("Zigalpm");
const output = @import("../output/config.zig");
const parser = @import("../cli/parser.zig");
const runtime = @import("../runtime/context.zig");
const elevation = @import("../runtime/elevation.zig");
const spec = @import("../cli/spec.zig");

const command_path = "shelly sync standard";

const Runner = struct {
    data: ?*anyopaque = null,
    call: *const fn (
        data: ?*anyopaque,
        context: *runtime.RuntimeContext,
        force: bool,
        no_confirm: bool,
        ui_mode: bool,
    ) anyerror!void,
};

const real_runner: Runner = .{ .call = runRealSync };

pub fn dispatch(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
) !?u8 {
    if (!std.mem.eql(u8, invocation.command.path, command_path)) return null;

    if (!invocation.globals.ui_mode) {
        const elevated_exit = elevation.relaunchIfNeeded(context, invocation.arguments) catch |err| {
            try context.stderr.print("Unable to elevate sync: {t}\n", .{err});
            return 1;
        };
        if (elevated_exit) |exit_code| return exit_code;
    }

    return try executeWithRunner(context, invocation, real_runner);
}

fn executeWithRunner(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    runner: Runner,
) !u8 {
    const force = optionEnabled(invocation, "--force");

    if (invocation.globals.ui_mode) {
        try output.writeAlpmInfoFrame(context, "TransactionStart", "Synchronizing package databases...");
    } else {
        try context.stdout.writeAll("Initializing ALPM...\n");
        try context.stdout.writeAll("Synchronizing package databases...\n");
    }
    try flushOutput(context);

    runner.call(
        runner.data,
        context,
        force,
        invocation.globals.no_confirm,
        invocation.globals.ui_mode,
    ) catch |err| {
        if (invocation.globals.ui_mode) {
            const message = try std.fmt.allocPrint(context.allocator, "Sync failed: {t}", .{err});
            defer context.allocator.free(message);
            try output.writeErrorFrame(context, message);
            try output.writeAlpmInfoFrame(context, "TransactionFailed", "Sync failed.");
        } else {
            try context.stderr.print("error: {t}\n", .{err});
            try output.writeFailure(context, "Sync failed. See errors above.");
        }
        try flushOutput(context);
        return 1;
    };

    if (invocation.globals.ui_mode) {
        try output.writeAlpmInfoFrame(
            context,
            "TransactionDone",
            "Package databases synchronized successfully!",
        );
    } else {
        try output.writeSuccess(context, "Package databases synchronized successfully!");
    }
    try flushOutput(context);
    return 0;
}

fn flushOutput(context: *runtime.RuntimeContext) !void {
    try context.stdout.flush();
    try context.stderr.flush();
}

fn runRealSync(
    _: ?*anyopaque,
    context: *runtime.RuntimeContext,
    force: bool,
    no_confirm: bool,
    ui_mode: bool,
) !void {
    var operation_context = Zigalpm.OperationContext.init(context.allocator, context.io);
    defer operation_context.deinit();
    if (no_confirm) {
        operation_context.setQuestionHandler(.{ .function = acceptQuestionDefaults });
    }
    var reporter: Reporter = .{ .context = context, .ui_mode = ui_mode };
    const event_subscription = try operation_context.subscribe(.{
        .function = Reporter.handle,
        .data = &reporter,
    });
    defer _ = operation_context.unsubscribe(event_subscription);

    const manager = try Zigalpm.AlpmManager.init(
        context.allocator,
        context.environ,
        null,
        true,
        null,
    );
    defer manager.deinit();
    manager.setOperationContext(&operation_context);
    defer manager.setOperationContext(null);

    try manager.sync(force);
    if (reporter.write_failed.load(.acquire)) return error.OutputFailed;
}

const Reporter = struct {
    context: *runtime.RuntimeContext,
    ui_mode: bool,
    mutex: std.Io.Mutex = .init,
    write_failed: std.atomic.Value(bool) = .init(false),

    fn handle(data: ?*anyopaque, event: Zigalpm.OperationEvent) void {
        const self: *Reporter = @ptrCast(@alignCast(data.?));
        self.mutex.lockUncancelable(self.context.io);
        defer self.mutex.unlock(self.context.io);
        self.write(event) catch self.write_failed.store(true, .release);
    }

    fn write(self: *Reporter, event: Zigalpm.OperationEvent) !void {
        switch (event) {
            .status => |status| {
                if (self.ui_mode) {
                    try output.writeAlpmInfoFrame(self.context, "InformationalOutput", status.message);
                } else {
                    try self.context.stdout.print(":: {s}\n", .{status.message});
                }
            },
            .progress => |progress| {
                const message = progress.update.message orelse progress.update.stage orelse return;
                if (self.ui_mode) {
                    try output.writeAlpmInfoFrame(self.context, "InformationalOutput", message);
                } else if (progress.update.percentage) |percentage| {
                    try self.context.stdout.print(":: {s}: {d:.0}%\n", .{ message, percentage });
                } else {
                    try self.context.stdout.print(":: {s}\n", .{message});
                }
            },
            .failure => |failure| {
                if (self.ui_mode) {
                    try output.writeErrorFrame(self.context, failure.message);
                } else {
                    try self.context.stderr.print("error: {s}\n", .{failure.message});
                }
            },
            .started, .completed => {},
        }
        try flushOutput(self.context);
    }
};

fn acceptQuestionDefaults(
    _: ?*anyopaque,
    question: Zigalpm.OperationQuestion,
) Zigalpm.OperationQuestionResponse {
    return switch (question.kind) {
        .confirmation, .review_changes => .accepted,
        .select_one, .select_provider => .{ .choice = 0 },
        .select_many, .select_optional_dependencies => .{ .choices = &.{} },
    };
}

fn optionEnabled(invocation: *const parser.Invocation, name: []const u8) bool {
    for (invocation.options) |option| {
        if (!std.mem.eql(u8, option.name, name)) continue;
        const value = option.value orelse return true;
        return !std.ascii.eqlIgnoreCase(value, "false");
    }
    return false;
}

test "sync forwards force and no-confirm to the backend" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    const outcome = try parser.parse(arena.allocator(), &manifest, &.{
        "sync",
        "--force",
        "--no-confirm",
    });
    try std.testing.expect(outcome == .dispatch);

    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    var context: runtime.RuntimeContext = .{
        .allocator = arena.allocator(),
        .io = std.testing.io,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
    };
    const Capture = struct { force: bool = false, no_confirm: bool = false };
    var capture: Capture = .{};
    const runner: Runner = .{
        .data = &capture,
        .call = struct {
            fn run(data: ?*anyopaque, _: *runtime.RuntimeContext, force: bool, no_confirm: bool, _: bool) !void {
                const observed: *Capture = @ptrCast(@alignCast(data.?));
                observed.force = force;
                observed.no_confirm = no_confirm;
            }
        }.run,
    };

    try std.testing.expectEqual(@as(u8, 0), try executeWithRunner(&context, &outcome.dispatch, runner));
    try std.testing.expect(capture.force);
    try std.testing.expect(capture.no_confirm);
    try std.testing.expect(std.mem.indexOf(
        u8,
        stdout.writer.buffered(),
        "Package databases synchronized successfully!",
    ) != null);
    try std.testing.expectEqual(@as(usize, 0), stderr.writer.buffered().len);
}

test "sync flushes its initial status before starting the backend" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    const outcome = try parser.parse(arena.allocator(), &manifest, &.{"sync"});
    try std.testing.expect(outcome == .dispatch);

    const TrackingWriter = struct {
        interface: std.Io.Writer = undefined,
        buffer: [4096]u8 = undefined,
        flush_count: usize = 0,

        fn init(self: *@This()) void {
            self.interface = .{
                .vtable = &.{ .drain = drain, .flush = flush },
                .buffer = &self.buffer,
            };
        }

        fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
            writer.end = 0;
            return std.Io.Writer.countSplat(data, splat);
        }

        fn flush(writer: *std.Io.Writer) std.Io.Writer.Error!void {
            const self: *@This() = @alignCast(@fieldParentPtr("interface", writer));
            self.flush_count += 1;
            writer.end = 0;
        }
    };
    var stdout: TrackingWriter = .{};
    stdout.init();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    var context: runtime.RuntimeContext = .{
        .allocator = arena.allocator(),
        .io = std.testing.io,
        .stdout = &stdout.interface,
        .stderr = &stderr.writer,
    };
    const Capture = struct { writer: *TrackingWriter, initial_status_was_flushed: bool = false };
    var capture: Capture = .{ .writer = &stdout };
    const runner: Runner = .{
        .data = &capture,
        .call = struct {
            fn run(data: ?*anyopaque, _: *runtime.RuntimeContext, _: bool, _: bool, _: bool) !void {
                const observed: *Capture = @ptrCast(@alignCast(data.?));
                observed.initial_status_was_flushed = observed.writer.flush_count > 0;
            }
        }.run,
    };

    try std.testing.expectEqual(@as(u8, 0), try executeWithRunner(&context, &outcome.dispatch, runner));
    try std.testing.expect(capture.initial_status_was_flushed);
}

test "sync reports backend failures and returns a failure exit code" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    const outcome = try parser.parse(arena.allocator(), &manifest, &.{ "sync", "standard" });
    try std.testing.expect(outcome == .dispatch);

    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    var context: runtime.RuntimeContext = .{
        .allocator = arena.allocator(),
        .io = std.testing.io,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
    };
    const runner: Runner = .{ .call = struct {
        fn run(_: ?*anyopaque, _: *runtime.RuntimeContext, _: bool, _: bool, _: bool) !void {
            return error.TestSyncFailure;
        }
    }.run };

    try std.testing.expectEqual(@as(u8, 1), try executeWithRunner(&context, &outcome.dispatch, runner));
    try std.testing.expect(std.mem.indexOf(u8, stderr.writer.buffered(), "TestSyncFailure") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), "Sync failed") != null);
}

test "sync UI mode emits transaction frames" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    const outcome = try parser.parse(arena.allocator(), &manifest, &.{ "sync", "standard", "--ui-mode" });
    try std.testing.expect(outcome == .dispatch);

    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    var context: runtime.RuntimeContext = .{
        .allocator = arena.allocator(),
        .io = std.testing.io,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
    };
    const runner: Runner = .{ .call = struct {
        fn run(_: ?*anyopaque, _: *runtime.RuntimeContext, _: bool, _: bool, _: bool) !void {}
    }.run };

    try std.testing.expectEqual(@as(u8, 0), try executeWithRunner(&context, &outcome.dispatch, runner));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, stdout.writer.buffered(), "[JSON]"));
    try std.testing.expectEqual(@as(usize, 0), stderr.writer.buffered().len);
}
