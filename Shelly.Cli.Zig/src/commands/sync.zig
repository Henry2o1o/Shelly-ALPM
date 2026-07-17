const std = @import("std");
const Zigalpm = @import("Zigalpm");
const output = @import("../output/config.zig");
const standard_single_pane = @import("../output/standard_single_pane.zig");
const ui_operation = @import("../output/ui_operation.zig");
const parser = @import("../cli/parser.zig");
const runtime = @import("../runtime/context.zig");
const elevation = @import("../runtime/elevation.zig");
const spec = @import("../cli/spec.zig");

const standard_command_path = "shelly sync standard";
const flatpak_command_path = "shelly sync flatpak";

const Runner = struct {
    data: ?*anyopaque = null,
    call: *const fn (
        data: ?*anyopaque,
        context: *runtime.RuntimeContext,
        operation_context: *Zigalpm.OperationContext,
        force: bool,
    ) anyerror!void,
};

const StandardRunnerAdapter = struct {
    runner: Runner,
    force: bool,

    fn call(
        data: ?*anyopaque,
        context: *runtime.RuntimeContext,
        operation_context: *Zigalpm.OperationContext,
    ) !void {
        const self: *StandardRunnerAdapter = @ptrCast(@alignCast(data.?));
        try self.runner.call(self.runner.data, context, operation_context, self.force);
    }
};

const real_standard_runner: Runner = .{ .call = runRealStandardSync };
const real_flatpak_runner: Runner = .{ .call = runRealFlatpakSync };

pub fn dispatch(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
) !?u8 {
    const is_standard = std.mem.eql(u8, invocation.command.path, standard_command_path);
    const is_flatpak = std.mem.eql(u8, invocation.command.path, flatpak_command_path);
    if (!is_standard and !is_flatpak) return null;

    if (is_standard and !invocation.globals.ui_mode) {
        const elevated_exit = elevation.relaunchIfNeeded(context, invocation.arguments) catch |err| {
            try context.stderr.print("Unable to elevate sync: {t}\n", .{err});
            return 1;
        };
        if (elevated_exit) |exit_code| return exit_code;
    }

    return try executeWithRunner(
        context,
        invocation,
        if (is_standard) real_standard_runner else real_flatpak_runner,
    );
}

fn executeWithRunner(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    runner: Runner,
) !u8 {
    const force = optionEnabled(invocation, "--force");

    return if (invocation.globals.ui_mode)
        executeUi(context, invocation, runner, force)
    else
        executeStandard(context, invocation, runner, force);
}

fn executeStandard(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    runner: Runner,
    force: bool,
) !u8 {
    var adapter: StandardRunnerAdapter = .{ .runner = runner, .force = force };
    const succeeded = try standard_single_pane.output(
        context,
        openingMessage(invocation),
        invocation.globals.no_confirm,
        .{ .data = &adapter, .call = StandardRunnerAdapter.call },
    );
    return if (succeeded) 0 else 1;
}

fn executeUi(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    runner: Runner,
    force: bool,
) !u8 {
    var operation_context = Zigalpm.OperationContext.init(context.allocator, context.io);
    defer operation_context.deinit();
    if (invocation.globals.no_confirm) {
        operation_context.setQuestionHandler(.{ .function = ui_operation.acceptQuestionDefaults });
        defer operation_context.setQuestionHandler(null);
    }
    var reporter: ui_operation.Reporter = .{ .context = context };
    const event_subscription = try operation_context.subscribe(.{
        .function = ui_operation.Reporter.handle,
        .data = &reporter,
    });
    defer _ = operation_context.unsubscribe(event_subscription);

    try output.writeAlpmInfoFrame(context, "TransactionStart", openingMessage(invocation));
    try ui_operation.flush(context);

    runner.call(runner.data, context, &operation_context, force) catch |err| {
        const message = try std.fmt.allocPrint(context.allocator, "Sync failed: {t}", .{err});
        defer context.allocator.free(message);
        try output.writeErrorFrame(context, message);
        try output.writeAlpmInfoFrame(context, "TransactionFailed", "Sync failed.");
        try ui_operation.flush(context);
        return 1;
    };

    try output.writeAlpmInfoFrame(
        context,
        "TransactionDone",
        successMessage(invocation),
    );
    try ui_operation.flush(context);
    return if (reporter.failed()) 1 else 0;
}

fn runRealStandardSync(
    _: ?*anyopaque,
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    force: bool,
) !void {
    const manager = try Zigalpm.AlpmManager.init(
        context.allocator,
        context.environ,
        null,
        true,
        null,
    );
    defer manager.deinit();
    manager.setOperationContext(operation_context);
    defer manager.setOperationContext(null);

    try manager.sync(force);
}

fn runRealFlatpakSync(
    _: ?*anyopaque,
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    _: bool,
) !void {
    var manager = Zigalpm.flatpak.AppstreamManager.init(context.allocator, context.io);
    manager.setOperationContext(operation_context);
    defer manager.setOperationContext(null);

    try manager.updateAllAppstreams();
}

fn openingMessage(invocation: *const parser.Invocation) []const u8 {
    return if (std.mem.eql(u8, invocation.command.path, flatpak_command_path))
        "Synchronizing Flatpak AppStream metadata..."
    else
        "Synchronizing package databases...";
}

fn successMessage(invocation: *const parser.Invocation) []const u8 {
    return if (std.mem.eql(u8, invocation.command.path, flatpak_command_path))
        "Flatpak AppStream metadata synchronized successfully!"
    else
        "Package databases synchronized successfully!";
}

fn optionEnabled(invocation: *const parser.Invocation, name: []const u8) bool {
    for (invocation.options) |option| {
        if (!std.mem.eql(u8, option.name, name)) continue;
        const value = option.value orelse return true;
        return !std.ascii.eqlIgnoreCase(value, "false");
    }
    return false;
}

test "sync forwards force and applies no-confirm through the shared operation context" {
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
            fn run(
                data: ?*anyopaque,
                runtime_context: *runtime.RuntimeContext,
                operation_context: *Zigalpm.OperationContext,
                force: bool,
            ) !void {
                const observed: *Capture = @ptrCast(@alignCast(data.?));
                observed.force = force;
                var operation = operation_context.begin(.{ .backend = .alpm, .kind = .sync });
                defer operation.finish(.success);
                var response = try operation.ask(.{ .kind = .confirmation, .prompt = "Continue?" });
                defer response.deinit(runtime_context.allocator);
                observed.no_confirm = response.response == .accepted;
            }
        }.run,
    };

    try std.testing.expectEqual(@as(u8, 0), try executeWithRunner(&context, &outcome.dispatch, runner));
    try std.testing.expect(capture.force);
    try std.testing.expect(capture.no_confirm);
    try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), ":: Synchronizing package databases...") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), ":: Transaction complete.") != null);
    try std.testing.expectEqual(@as(usize, 0), stderr.writer.buffered().len);
}

test "Flatpak sync uses the AppStream path and standard non-UI lifecycle" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    const outcome = try parser.parse(arena.allocator(), &manifest, &.{ "sync", "flatpak" });
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
    const Capture = struct { called: bool = false, force: bool = true };
    var capture: Capture = .{};
    const runner: Runner = .{
        .data = &capture,
        .call = struct {
            fn run(
                data: ?*anyopaque,
                _: *runtime.RuntimeContext,
                operation_context: *Zigalpm.OperationContext,
                force: bool,
            ) !void {
                const observed: *Capture = @ptrCast(@alignCast(data.?));
                observed.called = true;
                observed.force = force;
                var operation = operation_context.begin(.{ .backend = .flatpak, .kind = .update });
                defer operation.finish(.success);
                operation.status(.success, "Flatpak AppStream catalog updated", "flatpak.appstream.updated", null);
            }
        }.run,
    };

    try std.testing.expectEqual(@as(u8, 0), try executeWithRunner(&context, &outcome.dispatch, runner));
    try std.testing.expect(capture.called);
    try std.testing.expect(!capture.force);
    try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), ":: Synchronizing Flatpak AppStream metadata...") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), "Flatpak AppStream catalog updated") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), ":: Transaction complete.") != null);
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
            fn run(data: ?*anyopaque, _: *runtime.RuntimeContext, _: *Zigalpm.OperationContext, _: bool) !void {
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
        fn run(_: ?*anyopaque, _: *runtime.RuntimeContext, _: *Zigalpm.OperationContext, _: bool) !void {
            return error.TestSyncFailure;
        }
    }.run };

    try std.testing.expectEqual(@as(u8, 1), try executeWithRunner(&context, &outcome.dispatch, runner));
    try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), "error: TestSyncFailure") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), ":: Transaction failed.") != null);
    try std.testing.expectEqual(@as(usize, 0), stderr.writer.buffered().len);
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
        fn run(_: ?*anyopaque, _: *runtime.RuntimeContext, operation_context: *Zigalpm.OperationContext, _: bool) !void {
            var operation = operation_context.begin(.{
                .backend = .download,
                .kind = .download,
                .subject = "extra.db",
            });
            defer operation.finish(.success);
            operation.progress(.{ .bytes_completed = 50, .bytes_total = 100 });
        }
    }.run };

    try std.testing.expectEqual(@as(u8, 0), try executeWithRunner(&context, &outcome.dispatch, runner));
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, stdout.writer.buffered(), "[JSON]"));
    try std.testing.expectEqual(@as(usize, 0), stderr.writer.buffered().len);
}
