const std = @import("std");
const Zigalpm = @import("Zigalpm");
const config_manager = @import("../config/manager.zig");
const config_model = @import("../config/model.zig");
const output = @import("../output/config.zig");
const standard_single_pane = @import("../output/standard_single_pane.zig");
const ui_operation = @import("../output/ui_operation.zig");
const parser = @import("../cli/parser.zig");
const runtime = @import("../runtime/context.zig");
const elevation = @import("../runtime/elevation.zig");
const xdg = @import("../runtime/xdg.zig");
const spec = @import("../cli/spec.zig");

const standard_command_path = "shelly upgrade standard";
const all_command_path = "shelly upgrade all";
const appimage_command_path = "shelly upgrade appimage";
const aur_command_path = "shelly upgrade aur";
const flatpak_command_path = "shelly upgrade flatpak";

const UpgradeError = error{
    BackendFailed,
    OneOrMoreBackendsFailed,
};

const Backend = enum {
    standard,
    aur,
    flatpak,
    appimage,

    fn operationBackend(self: Backend) Zigalpm.OperationBackend {
        return switch (self) {
            .standard => .alpm,
            .aur => .aur,
            .flatpak => .flatpak,
            .appimage => .appimage,
        };
    }

    fn displayName(self: Backend) []const u8 {
        return switch (self) {
            .standard => "Standard",
            .aur => "AUR",
            .flatpak => "Flatpak",
            .appimage => "AppImage",
        };
    }
};

const Runner = struct {
    data: ?*anyopaque = null,
    call: *const fn (
        data: ?*anyopaque,
        context: *runtime.RuntimeContext,
        operation_context: *Zigalpm.OperationContext,
        backend: Backend,
        invocation: *const parser.Invocation,
    ) anyerror!void,
};

const RunnerAdapter = struct {
    runner: Runner,
    invocation: *const parser.Invocation,

    fn call(
        data: ?*anyopaque,
        context: *runtime.RuntimeContext,
        operation_context: *Zigalpm.OperationContext,
    ) !void {
        const self: *RunnerAdapter = @ptrCast(@alignCast(data.?));
        try runSelected(self.runner, context, operation_context, self.invocation);
    }
};

const real_runner: Runner = .{ .call = runRealUpgrade };

pub fn dispatch(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
) !?u8 {
    if (!isUpgradePath(invocation.command.path)) return null;

    if (!invocation.globals.ui_mode and requiresElevation(invocation)) {
        const elevated_exit = elevation.relaunchIfNeeded(context, invocation.arguments) catch |err| {
            try context.stderr.print("Unable to elevate upgrade: {t}\n", .{err});
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
    return if (invocation.globals.ui_mode)
        executeUi(context, invocation, runner)
    else
        executeStandard(context, invocation, runner);
}

fn executeStandard(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    runner: Runner,
) !u8 {
    var adapter: RunnerAdapter = .{ .runner = runner, .invocation = invocation };
    const succeeded = try standard_single_pane.output(
        context,
        openingMessage(invocation),
        invocation.globals.no_confirm,
        .{ .data = &adapter, .call = RunnerAdapter.call },
    );
    return if (succeeded) 0 else 1;
}

fn executeUi(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    runner: Runner,
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

    runSelected(runner, context, &operation_context, invocation) catch |err| {
        const message = try std.fmt.allocPrint(context.allocator, "Upgrade failed: {t}", .{err});
        defer context.allocator.free(message);
        try output.writeErrorFrame(context, message);
        try output.writeAlpmInfoFrame(context, "TransactionFailed", failureMessage(invocation));
        try ui_operation.flush(context);
        return 1;
    };

    try output.writeAlpmInfoFrame(context, "TransactionDone", successMessage(invocation));
    try ui_operation.flush(context);
    return if (reporter.failed()) 1 else 0;
}

fn runSelected(
    runner: Runner,
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    invocation: *const parser.Invocation,
) !void {
    if (!std.mem.eql(u8, invocation.command.path, all_command_path)) {
        try runner.call(
            runner.data,
            context,
            operation_context,
            backendForPath(invocation.command.path) orelse unreachable,
            invocation,
        );
        return;
    }

    var failed = false;
    for (all_backends) |backend| {
        if (!backendEnabled(invocation, backend)) continue;
        runner.call(runner.data, context, operation_context, backend, invocation) catch |err| {
            failed = true;
            try reportBackendFailure(context, operation_context, backend, err);
        };
    }
    if (failed) return UpgradeError.OneOrMoreBackendsFailed;
}

const all_backends = [_]Backend{ .standard, .aur, .flatpak, .appimage };

fn runRealUpgrade(
    _: ?*anyopaque,
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    backend: Backend,
    invocation: *const parser.Invocation,
) !void {
    return switch (backend) {
        .standard => runStandard(context, operation_context, invocation),
        .aur => runAur(context, operation_context, invocation),
        .flatpak => runFlatpakStep(context, operation_context, invocation),
        .appimage => runAppImage(context, operation_context),
    };
}

fn runStandard(
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    invocation: *const parser.Invocation,
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

    try manager.sync(false);
    const updates = try manager.get_updates_available();
    defer Zigalpm.alpm.OwnedPackageWithUpdate.deinitSlice(context.allocator, updates);
    if (updates.len == 0) {
        emitStatus(operation_context, .standard, .success, "Standard Packages are up to date!");
        return;
    }

    try emitFormattedStatus(
        context,
        operation_context,
        .standard,
        .information,
        "{d} standard packages need updates:",
        .{updates.len},
    );
    for (updates) |update| {
        try emitFormattedStatus(
            context,
            operation_context,
            .standard,
            .information,
            "  {s}/{s}: {s} -> {s}",
            .{
                update.new_package.repository() orelse "unknown",
                update.new_package.name() orelse "unknown",
                update.old_package.version() orelse "unknown",
                update.new_package.version() orelse "unknown",
            },
        );
    }

    var restart_report = try manager.sync_system_update(.{});
    defer restart_report.deinit();
    if (invocation.globals.ui_mode and restart_report.needs_reboot)
        emitStatus(operation_context, .standard, .warning, "[RESTART_REQUIRED]reboot");
    for (restart_report.failures) |failure| {
        try emitFormattedStatus(
            context,
            operation_context,
            .standard,
            .warning,
            "[RESTART_FAILED]service:{s}|{s}",
            .{ failure.service, failure.message },
        );
    }
}

fn runAur(
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    invocation: *const parser.Invocation,
) !void {
    // The Zig CLI always renders non-UI operations through the shared single
    // pane. Accepting --singlepane therefore preserves the C# modifier while
    // selecting the same native output path as the default.
    _ = optionEnabled(invocation, "--singlepane");

    const manager = try Zigalpm.AurManager.init(context.allocator, context.environ, .{
        .root = true,
        .no_check = !optionEnabled(invocation, "--check"),
    });
    defer manager.deinit();
    manager.setOperationContext(operation_context);
    defer manager.setOperationContext(null);

    const updates = try manager.getPackagesNeedingUpdate(true);
    defer Zigalpm.aur.models.Update.deinitSlice(context.allocator, updates);
    if (updates.len == 0) {
        emitStatus(operation_context, .aur, .success, "All AUR packages are up to date.");
        return;
    }

    try emitFormattedStatus(
        context,
        operation_context,
        .aur,
        .information,
        "{d} AUR packages need updates:",
        .{updates.len},
    );
    const package_names = try context.allocator.alloc([]const u8, updates.len);
    defer context.allocator.free(package_names);
    for (updates, package_names) |update, *name| {
        name.* = update.name;
        try emitFormattedStatus(
            context,
            operation_context,
            .aur,
            .information,
            "  {s}: {s} -> {s}",
            .{ update.name, update.version, update.new_version },
        );
    }
    try manager.updatePackages(package_names);
}

fn runFlatpak(
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
) !void {
    var manager = Zigalpm.FlatpakManager{ .allocator = context.allocator, .io = context.io };
    defer manager.deinit();
    try manager.setOperationContext(operation_context);
    defer manager.setOperationContext(null) catch {};
    if (!try manager.upgrade_flatpaks()) return UpgradeError.BackendFailed;
}

fn runFlatpakStep(
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    invocation: *const parser.Invocation,
) !void {
    if (std.mem.eql(u8, invocation.command.path, all_command_path) and
        !invocation.globals.ui_mode)
    {
        var arguments: std.ArrayList([]const u8) = .empty;
        defer arguments.deinit(context.allocator);
        try arguments.appendSlice(context.allocator, &.{ "upgrade", "flatpak" });
        if (invocation.globals.no_confirm)
            try arguments.append(context.allocator, "--no-confirm");
        if (invocation.globals.json)
            try arguments.append(context.allocator, "--json");
        if (invocation.globals.verbose)
            try arguments.append(context.allocator, "--verbose");
        if (try elevation.runAsInvokingUser(context, arguments.items)) |exit_code| {
            if (exit_code != 0) return UpgradeError.BackendFailed;
            return;
        }
    }
    try runFlatpak(context, operation_context);
}

fn runAppImage(
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
) !void {
    const configuration = config_manager.Manager.init(context).read() catch
        try config_model.Config.defaults(context.allocator);
    const install_directory = stringValue(&configuration, "AppImageInstallPath") orelse
        try xdg.binHome(context);
    const local_db_path = try std.fs.path.join(
        context.allocator,
        &.{ try xdg.configHome(context), "shelly", "appimage-metadata-v2.db" },
    );
    var manager = Zigalpm.appimage.UpdateManager{
        .allocator = context.allocator,
        .io = context.io,
        .environ = context.environ,
        .install_directory = install_directory,
        .local_db_path = local_db_path,
    };
    defer manager.deinit();
    try manager.setOperationContext(operation_context);
    defer manager.setOperationContext(null) catch {};

    var updates = try manager.get_updates();
    defer updates.deinit();
    if (updates.items.len == 0) {
        emitStatus(operation_context, .appimage, .success, "No updates available for any AppImage.");
        return;
    }

    var failed = false;
    for (updates.items) |*update| {
        try emitFormattedStatus(
            context,
            operation_context,
            .appimage,
            .information,
            "Updating {s} to {s}",
            .{ update.name, update.version },
        );
        if (!try manager.update(update)) failed = true;
    }
    if (failed) return UpgradeError.BackendFailed;
}

fn reportBackendFailure(
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    backend: Backend,
    err: anyerror,
) !void {
    const message = try std.fmt.allocPrint(
        context.allocator,
        "{s} upgrade step failed: {t}",
        .{ backend.displayName(), err },
    );
    defer context.allocator.free(message);
    var operation = operation_context.begin(.{
        .backend = backend.operationBackend(),
        .kind = .update,
        .subject = backend.displayName(),
    });
    operation.reportError(err, message, "upgrade", null, true);
    operation.finish(.failed);
}

fn emitStatus(
    operation_context: *Zigalpm.OperationContext,
    backend: Backend,
    level: Zigalpm.OperationStatusLevel,
    message: []const u8,
) void {
    var operation = operation_context.begin(.{
        .backend = backend.operationBackend(),
        .kind = .update,
        .subject = backend.displayName(),
    });
    operation.status(level, message, "upgrade.status", null);
    operation.finish(.success);
}

fn emitFormattedStatus(
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    backend: Backend,
    level: Zigalpm.OperationStatusLevel,
    comptime format: []const u8,
    arguments: anytype,
) !void {
    const message = try std.fmt.allocPrint(context.allocator, format, arguments);
    defer context.allocator.free(message);
    emitStatus(operation_context, backend, level, message);
}

fn requiresElevation(invocation: *const parser.Invocation) bool {
    if (std.mem.eql(u8, invocation.command.path, standard_command_path) or
        std.mem.eql(u8, invocation.command.path, aur_command_path)) return true;
    if (!std.mem.eql(u8, invocation.command.path, all_command_path)) return false;
    return backendEnabled(invocation, .standard) or backendEnabled(invocation, .aur);
}

fn backendEnabled(invocation: *const parser.Invocation, backend: Backend) bool {
    return switch (backend) {
        .standard => !optionEnabled(invocation, "--no-repo"),
        .aur => !optionEnabled(invocation, "--no-aur"),
        .flatpak => !optionEnabled(invocation, "--no-flatpak"),
        .appimage => !optionEnabled(invocation, "--no-appimage"),
    };
}

fn backendForPath(path: []const u8) ?Backend {
    if (std.mem.eql(u8, path, standard_command_path)) return .standard;
    if (std.mem.eql(u8, path, aur_command_path)) return .aur;
    if (std.mem.eql(u8, path, flatpak_command_path)) return .flatpak;
    if (std.mem.eql(u8, path, appimage_command_path)) return .appimage;
    return null;
}

fn openingMessage(invocation: *const parser.Invocation) []const u8 {
    if (std.mem.eql(u8, invocation.command.path, all_command_path))
        return "Upgrading all selected package backends...";
    return switch (backendForPath(invocation.command.path) orelse unreachable) {
        .standard => "Performing full system upgrade...",
        .aur => "Upgrading out-of-date AUR packages...",
        .flatpak => "Updating all Flatpak apps and runtimes...",
        .appimage => "Checking for AppImage upgrades...",
    };
}

fn successMessage(invocation: *const parser.Invocation) []const u8 {
    if (std.mem.eql(u8, invocation.command.path, all_command_path)) return "All upgrades complete.";
    return switch (backendForPath(invocation.command.path) orelse unreachable) {
        .standard => "System upgraded successfully!",
        .aur => "AUR upgrade complete.",
        .flatpak => "Flatpak upgrade complete.",
        .appimage => "AppImage upgrades complete.",
    };
}

fn failureMessage(invocation: *const parser.Invocation) []const u8 {
    if (std.mem.eql(u8, invocation.command.path, all_command_path))
        return "One or more upgrade steps failed.";
    return switch (backendForPath(invocation.command.path) orelse unreachable) {
        .standard => "System upgrade failed.",
        .aur => "AUR upgrade failed.",
        .flatpak => "Flatpak upgrade failed.",
        .appimage => "AppImage upgrade failed.",
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

fn stringValue(configuration: *const config_model.Config, key: []const u8) ?[]const u8 {
    const value = configuration.values.get(key) orelse return null;
    if (value != .string or value.string.len == 0) return null;
    return value.string;
}

fn isUpgradePath(path: []const u8) bool {
    return std.mem.eql(u8, path, standard_command_path) or
        std.mem.eql(u8, path, all_command_path) or
        std.mem.eql(u8, path, appimage_command_path) or
        std.mem.eql(u8, path, aur_command_path) or
        std.mem.eql(u8, path, flatpak_command_path);
}

test "upgrade routes every action-first type through the combined handler" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());

    const paths = [_]struct { arguments: []const []const u8, backend: Backend }{
        .{ .arguments = &.{ "upgrade", "standard", "--no-confirm" }, .backend = .standard },
        .{ .arguments = &.{ "upgrade", "aur", "--check", "--singlepane", "--no-confirm" }, .backend = .aur },
        .{ .arguments = &.{ "upgrade", "flatpak", "--no-confirm" }, .backend = .flatpak },
        .{ .arguments = &.{ "upgrade", "appimage", "--no-confirm" }, .backend = .appimage },
    };
    for (paths) |expected| {
        const outcome = try parser.parse(arena.allocator(), &manifest, expected.arguments);
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
        var observed: ?Backend = null;
        const runner: Runner = .{
            .data = &observed,
            .call = struct {
                fn run(
                    data: ?*anyopaque,
                    _: *runtime.RuntimeContext,
                    operation_context: *Zigalpm.OperationContext,
                    backend: Backend,
                    _: *const parser.Invocation,
                ) !void {
                    const capture: *?Backend = @ptrCast(@alignCast(data.?));
                    capture.* = backend;
                    var operation = operation_context.begin(.{
                        .backend = backend.operationBackend(),
                        .kind = .update,
                        .subject = backend.displayName(),
                    });
                    operation.progress(.{ .completed = 1, .total = 1, .percentage = 100 });
                    operation.finish(.success);
                }
            }.run,
        };

        try std.testing.expectEqual(@as(u8, 0), try executeWithRunner(&context, &outcome.dispatch, runner));
        try std.testing.expectEqual(expected.backend, observed.?);
        try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), ":: Transaction complete.") != null);
    }
}

test "upgrade all honors every exclusion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    const outcome = try parser.parse(arena.allocator(), &manifest, &.{
        "upgrade",
        "all",
        "--no-repo",
        "--no-flatpak",
        "--no-appimage",
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
    var calls: std.ArrayList(Backend) = .empty;
    defer calls.deinit(std.testing.allocator);
    const runner: Runner = .{
        .data = &calls,
        .call = struct {
            fn run(
                data: ?*anyopaque,
                _: *runtime.RuntimeContext,
                _: *Zigalpm.OperationContext,
                backend: Backend,
                _: *const parser.Invocation,
            ) !void {
                const captured: *std.ArrayList(Backend) = @ptrCast(@alignCast(data.?));
                try captured.append(std.testing.allocator, backend);
            }
        }.run,
    };

    try std.testing.expectEqual(@as(u8, 0), try executeWithRunner(&context, &outcome.dispatch, runner));
    try std.testing.expectEqualSlices(Backend, &.{.aur}, calls.items);
}

test "upgrade all continues after a failed backend and returns failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    const outcome = try parser.parse(arena.allocator(), &manifest, &.{ "upgrade", "all", "--no-confirm" });
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
    var calls: std.ArrayList(Backend) = .empty;
    defer calls.deinit(std.testing.allocator);
    const runner: Runner = .{
        .data = &calls,
        .call = struct {
            fn run(
                data: ?*anyopaque,
                _: *runtime.RuntimeContext,
                _: *Zigalpm.OperationContext,
                backend: Backend,
                _: *const parser.Invocation,
            ) !void {
                const captured: *std.ArrayList(Backend) = @ptrCast(@alignCast(data.?));
                try captured.append(std.testing.allocator, backend);
                if (backend == .aur) return error.SyntheticAurFailure;
            }
        }.run,
    };

    try std.testing.expectEqual(@as(u8, 1), try executeWithRunner(&context, &outcome.dispatch, runner));
    try std.testing.expectEqualSlices(Backend, &all_backends, calls.items);
    try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), "AUR upgrade step failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), ":: Transaction failed.") != null);
}

test "upgrade UI mode emits backend percentage frames" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    const outcome = try parser.parse(arena.allocator(), &manifest, &.{
        "upgrade",
        "flatpak",
        "--ui-mode",
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
    const runner: Runner = .{
        .call = struct {
            fn run(
                _: ?*anyopaque,
                _: *runtime.RuntimeContext,
                operation_context: *Zigalpm.OperationContext,
                backend: Backend,
                _: *const parser.Invocation,
            ) !void {
                var operation = operation_context.begin(.{
                    .backend = backend.operationBackend(),
                    .kind = .update,
                    .subject = "org.example.App",
                });
                operation.progress(.{ .stage = "Updating", .percentage = 44 });
                operation.finish(.success);
            }
        }.run,
    };

    try std.testing.expectEqual(@as(u8, 0), try executeWithRunner(&context, &outcome.dispatch, runner));
    const rendered = stdout.writer.buffered();
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, rendered, "[JSON]"));
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[/JSON]") != null);
    try std.testing.expectEqual(@as(usize, 0), stderr.writer.buffered().len);
}
