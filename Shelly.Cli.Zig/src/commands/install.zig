const std = @import("std");
const Zigalpm = @import("Zigalpm");
const config_manager = @import("../config/manager.zig");
const config_model = @import("../config/model.zig");
const output = @import("../output/config.zig");
const standard_single_pane = @import("../output/standard_single_pane.zig");
const parser = @import("../cli/parser.zig");
const runtime = @import("../runtime/context.zig");
const elevation = @import("../runtime/elevation.zig");
const xdg = @import("../runtime/xdg.zig");
const spec = @import("../cli/spec.zig");

const standard_command_path = "shelly install standard";
const appimage_command_path = "shelly install appimage";
const aur_command_path = "shelly install aur";
const flatpak_command_path = "shelly install flatpak";

const InstallError = error{
    BackendFailed,
    DownloadFailed,
    NoFlatpakRemote,
    UnsupportedLocalPackage,
};

const Runner = struct {
    data: ?*anyopaque = null,
    call: *const fn (
        data: ?*anyopaque,
        context: *runtime.RuntimeContext,
        operation_context: *Zigalpm.OperationContext,
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
        try self.runner.call(self.runner.data, context, operation_context, self.invocation);
    }
};

const real_runner: Runner = .{ .call = runRealInstall };

pub fn dispatch(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
) !?u8 {
    if (!isInstallPath(invocation.command.path)) return null;

    if (needsPackages(invocation) and invocation.positionals.len == 0)
        return try reportValidationFailure(
            context,
            invocation,
            if (std.mem.eql(u8, invocation.command.path, standard_command_path))
                "Error: No packages specified"
            else
                "No packages specified.",
        );
    if (optionEnabled(invocation, "--build-deps") and dependencyTargetCount(invocation) > 1)
        return try reportValidationFailure(
            context,
            invocation,
            "Cannot build dependencies for multiple packages at once.",
        );

    if (!invocation.globals.ui_mode and needsElevation(invocation)) {
        const elevated_exit = elevation.relaunchIfNeeded(context, invocation.arguments) catch |err| {
            try context.stderr.print("Unable to elevate install: {t}\n", .{err});
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
    const opening = try openingMessage(context.allocator, invocation);
    defer context.allocator.free(opening);
    return if (invocation.globals.ui_mode)
        executeUi(context, invocation, runner, opening)
    else
        executeStandard(context, invocation, runner, opening);
}

fn executeStandard(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    runner: Runner,
    opening: []const u8,
) !u8 {
    var adapter: RunnerAdapter = .{ .runner = runner, .invocation = invocation };
    const succeeded = try standard_single_pane.output(
        context,
        opening,
        invocation.globals.no_confirm,
        .{ .data = &adapter, .call = RunnerAdapter.call },
    );
    return if (succeeded) 0 else 1;
}

fn executeUi(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    runner: Runner,
    opening: []const u8,
) !u8 {
    var operation_context = Zigalpm.OperationContext.init(context.allocator, context.io);
    defer operation_context.deinit();
    if (invocation.globals.no_confirm) {
        operation_context.setQuestionHandler(.{ .function = acceptQuestionDefaults });
        defer operation_context.setQuestionHandler(null);
    }
    var reporter: UiReporter = .{ .context = context };
    const event_subscription = try operation_context.subscribe(.{
        .function = UiReporter.handle,
        .data = &reporter,
    });
    defer _ = operation_context.unsubscribe(event_subscription);

    try output.writeAlpmInfoFrame(context, "TransactionStart", opening);
    try flushOutput(context);

    runner.call(runner.data, context, &operation_context, invocation) catch |err| {
        const message = try std.fmt.allocPrint(context.allocator, "Installation failed: {t}", .{err});
        defer context.allocator.free(message);
        try output.writeErrorFrame(context, message);
        try output.writeAlpmInfoFrame(context, "TransactionFailed", failureMessage(invocation));
        try flushOutput(context);
        return 1;
    };

    try output.writeAlpmInfoFrame(context, "TransactionDone", successMessage(invocation));
    try flushOutput(context);
    return if (reporter.write_failed.load(.acquire)) 1 else 0;
}

fn runRealInstall(
    _: ?*anyopaque,
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    invocation: *const parser.Invocation,
) !void {
    if (std.mem.eql(u8, invocation.command.path, standard_command_path))
        return runStandard(context, operation_context, invocation);
    if (std.mem.eql(u8, invocation.command.path, aur_command_path))
        return runAur(context, operation_context, invocation);
    if (std.mem.eql(u8, invocation.command.path, appimage_command_path))
        return runAppImage(context, operation_context, invocation);
    if (std.mem.eql(u8, invocation.command.path, flatpak_command_path))
        return runFlatpak(context, operation_context, invocation);
    unreachable;
}

const PackageSource = union(enum) {
    repository: []const u8,
    file: []const u8,
    url: []const u8,
};

fn runStandard(
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    invocation: *const parser.Invocation,
) !void {
    var repository_packages: std.ArrayList([]const u8) = .empty;
    defer repository_packages.deinit(context.allocator);
    var local_packages: std.ArrayList([]const u8) = .empty;
    defer local_packages.deinit(context.allocator);
    var downloaded_paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (downloaded_paths.items) |path| {
            std.Io.Dir.cwd().deleteFile(context.io, path) catch {};
            context.allocator.free(path);
        }
        downloaded_paths.deinit(context.allocator);
    }

    for (invocation.positionals) |value| switch (classifyPackageSource(value)) {
        .repository => |name| try repository_packages.append(context.allocator, name),
        .file => |path| try local_packages.append(context.allocator, path),
        .url => |url| {
            const path = try downloadPackage(context, operation_context, url);
            try downloaded_paths.append(context.allocator, path);
            try local_packages.append(context.allocator, path);
        },
    };

    if (optionEnabled(invocation, "--build-deps") and repository_packages.items.len > 1)
        return error.MultipleDependencyTargets;

    if (repository_packages.items.len > 0)
        try installRepositoryPackages(context, operation_context, invocation, repository_packages.items);
    for (local_packages.items) |path|
        try installLocalPackage(context, operation_context, path);
}

fn installRepositoryPackages(
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    invocation: *const parser.Invocation,
    package_names: []const []const u8,
) !void {
    const manager = try Zigalpm.AlpmManager.init(context.allocator, context.environ, null, true, null);
    defer manager.deinit();
    manager.setOperationContext(operation_context);
    defer manager.setOperationContext(null);

    if (optionEnabled(invocation, "--upgrade")) {
        try manager.sync(false);
        const updates = try manager.get_updates_available();
        defer Zigalpm.alpm.OwnedPackageWithUpdate.deinitSlice(context.allocator, updates);
        if (updates.len > 0) {
            var restart_report = try manager.sync_system_update(.{});
            restart_report.deinit();
        }
    }

    const names = try sentinelStrings(context.allocator, package_names);
    defer freeSentinelStrings(context.allocator, names);
    if (optionEnabled(invocation, "--build-deps")) {
        try manager.install_dependencies_only(
            names[0],
            optionEnabled(invocation, "--make-deps"),
            .{},
        );
        return;
    }
    try manager.install_packages(
        names,
        if (optionEnabled(invocation, "--no-deps")) .{ .nodeps = true } else .{},
    );
}

fn installLocalPackage(
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    location: []const u8,
) !void {
    std.Io.Dir.cwd().access(context.io, location, .{}) catch return error.FileNotFound;
    const current_directory = try std.process.currentPathAlloc(context.io, context.allocator);
    defer context.allocator.free(current_directory);
    const absolute_path = try std.fs.path.resolve(context.allocator, &.{ current_directory, location });
    defer context.allocator.free(absolute_path);
    const inspector: Zigalpm.local.Inspector = .{ .allocator = context.allocator, .io = context.io };

    if (try inspector.isArchPackage(absolute_path)) {
        const manager = try Zigalpm.AlpmManager.init(context.allocator, context.environ, null, true, null);
        defer manager.deinit();
        manager.setOperationContext(operation_context);
        defer manager.setOperationContext(null);
        try manager.install_local_packages(&.{absolute_path}, .{});
        return;
    }
    if (try inspector.isBinariesPackage(absolute_path)) {
        var manager = Zigalpm.LocalManager.init(context.allocator, context.io, .{});
        defer manager.deinit();
        manager.setOperationContext(operation_context);
        defer manager.setOperationContext(null);
        if (!try manager.installBinariesPackage(absolute_path)) return InstallError.BackendFailed;
        return;
    }
    return InstallError.UnsupportedLocalPackage;
}

fn downloadPackage(
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    url: []const u8,
) ![]const u8 {
    var random: [8]u8 = undefined;
    context.io.random(&random);
    const suffix = std.fmt.bytesToHex(random, .lower);
    const file_name = urlFileName(url);
    const destination = try std.fmt.allocPrint(
        context.allocator,
        "/tmp/shelly-install-{s}-{s}",
        .{ suffix[0..8], file_name },
    );
    errdefer {
        std.Io.Dir.cwd().deleteFile(context.io, destination) catch {};
        context.allocator.free(destination);
    }

    var downloader = Zigalpm.shared.Downloader.init(
        context.allocator,
        context.io,
        Zigalpm.shared.downloader.DownloadConfiguration.default(),
    );
    defer downloader.deinit();
    downloader.setOperationContext(operation_context);
    return switch (downloader.downloadToFile(url, destination, true)) {
        .succes, .skipped => destination,
        .failure => InstallError.DownloadFailed,
    };
}

fn runAur(
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    invocation: *const parser.Invocation,
) !void {
    if (optionEnabled(invocation, "--build-deps") and invocation.positionals.len > 1)
        return error.MultipleDependencyTargets;
    const manager = try Zigalpm.AurManager.init(context.allocator, context.environ, .{
        .root = true,
        .use_chroot = optionEnabled(invocation, "--chroot"),
        .no_check = !optionEnabled(invocation, "--check"),
    });
    defer manager.deinit();
    manager.setOperationContext(operation_context);
    defer manager.setOperationContext(null);

    if (optionEnabled(invocation, "--build-deps")) {
        try manager.installDependenciesOnly(
            invocation.positionals[0],
            optionEnabled(invocation, "--make-deps"),
        );
    } else {
        try manager.installPackages(invocation.positionals);
    }
}

fn runAppImage(
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    invocation: *const parser.Invocation,
) !void {
    const location = invocation.positionals[0];
    std.Io.Dir.cwd().access(context.io, location, .{}) catch return error.FileNotFound;
    if (!Zigalpm.AppImageManager.isAppImage(location)) return error.NotAnAppImage;

    const configuration = config_manager.Manager.init(context).read() catch
        try config_model.Config.defaults(context.allocator);
    const install_directory = stringValue(&configuration, "AppImageInstallPath") orelse
        try xdg.binHome(context);
    const local_db_path = try std.fs.path.join(
        context.allocator,
        &.{ try xdg.configHome(context), "shelly", "appimage-metadata-v2.db" },
    );
    var manager = Zigalpm.AppImageManager{
        .allocator = context.allocator,
        .io = context.io,
        .environ = context.environ,
        .install_directory = install_directory,
        .local_db_path = local_db_path,
    };
    defer manager.deinit();
    try manager.setOperationContext(operation_context);
    defer manager.setOperationContext(null) catch {};
    if (!try manager.installAppImage(location)) return InstallError.BackendFailed;
}

const FlatpakCandidate = struct {
    id: []const u8,
    name: []const u8,
    remote: []const u8,
};

fn runFlatpak(
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    invocation: *const parser.Invocation,
) !void {
    const requested_scope: Zigalpm.flatpak.bindings.libflatpak.Scope =
        if (optionEnabled(invocation, "--user")) .USER else .SYSTEM;
    const requested_id = invocation.positionals[0];
    var selected_id: []const u8 = requested_id;
    var selected_remote: []const u8 = optionValue(invocation, "--remote") orelse "";
    var owned_remote: ?[]const u8 = null;
    defer if (owned_remote) |remote| context.allocator.free(remote);

    var catalogs: ?[]Zigalpm.flatpak.AppstreamCatalog = null;
    defer if (catalogs) |values|
        Zigalpm.flatpak.AppstreamCatalog.deinitSlice(context.allocator, values);
    if (selected_remote.len == 0 and std.mem.indexOfScalar(u8, requested_id, '.') == null) {
        var appstreams = Zigalpm.flatpak.AppstreamManager.init(context.allocator, context.io);
        appstreams.setOperationContext(operation_context);
        catalogs = appstreams.getAllRemoteCatalogs(null) catch null;
        var candidates: std.ArrayList(FlatpakCandidate) = .empty;
        defer candidates.deinit(context.allocator);
        for (catalogs orelse &.{}) |catalog| {
            if (catalog.scope != requested_scope) continue;
            for (catalog.apps) |application| {
                const partial = containsIgnoreCase(application.id, requested_id) or
                    containsIgnoreCase(application.name, requested_id);
                if (!partial) continue;
                try candidates.append(context.allocator, .{
                    .id = application.id,
                    .name = application.name,
                    .remote = catalog.remote_name,
                });
            }
        }
        if (candidates.items.len > 0) {
            const selected = try selectFlatpakCandidate(context, operation_context, candidates.items);
            selected_id = selected.id;
            selected_remote = selected.remote;
        }
    }
    if (selected_remote.len == 0) {
        owned_remote = try firstFlatpakRemote(context, operation_context, requested_scope);
        selected_remote = owned_remote orelse "";
    }
    if (selected_remote.len == 0) return InstallError.NoFlatpakRemote;

    const id_z = try context.allocator.dupeZ(u8, selected_id);
    defer context.allocator.free(id_z);
    const remote_z = try context.allocator.dupeZ(u8, selected_remote);
    defer context.allocator.free(remote_z);
    const branch_z = try context.allocator.dupeZ(u8, optionValue(invocation, "--branch") orelse "stable");
    defer context.allocator.free(branch_z);

    var manager = Zigalpm.FlatpakManager{ .allocator = context.allocator, .io = context.io };
    defer manager.deinit();
    try manager.setOperationContext(operation_context);
    defer manager.setOperationContext(null) catch {};
    if (!try manager.install_flatpak(
        id_z,
        remote_z,
        requested_scope,
        branch_z,
        optionEnabled(invocation, "--runtime"),
    )) return InstallError.BackendFailed;
}

fn firstFlatpakRemote(
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    requested_scope: Zigalpm.flatpak.bindings.libflatpak.Scope,
) !?[]const u8 {
    var manager = Zigalpm.flatpak.RemoteManager{ .allocator = context.allocator, .io = context.io };
    manager.setOperationContext(operation_context);
    const remotes = try manager.listRemotesWithDetails();
    defer context.allocator.free(remotes);
    for (remotes) |remote| {
        if (remote.get_scope() != requested_scope or remote.disabled()) continue;
        const name = remote.name() orelse continue;
        if (name.len > 0) return try context.allocator.dupe(u8, name);
    }
    return null;
}

fn selectFlatpakCandidate(
    context: *runtime.RuntimeContext,
    operation_context: *Zigalpm.OperationContext,
    candidates: []const FlatpakCandidate,
) !FlatpakCandidate {
    if (candidates.len == 1) return candidates[0];
    const options = try context.allocator.alloc(Zigalpm.OperationQuestionOption, candidates.len);
    defer context.allocator.free(options);
    const labels = try context.allocator.alloc([]const u8, candidates.len);
    var initialized_labels: usize = 0;
    defer {
        for (labels[0..initialized_labels]) |label| context.allocator.free(label);
        context.allocator.free(labels);
    }
    for (candidates, options, labels) |candidate, *option, *label| {
        label.* = try std.fmt.allocPrint(context.allocator, "{s} ({s}) [{s}]", .{
            candidate.name,
            candidate.id,
            candidate.remote,
        });
        initialized_labels += 1;
        option.* = .{ .id = candidate.id, .label = label.* };
    }
    var operation = operation_context.begin(.{
        .backend = .flatpak,
        .kind = .search,
        .subject = candidates[0].id,
    });
    defer operation.finish(.success);
    var response = try operation.ask(.{
        .kind = .select_one,
        .prompt = "Select a package to install:",
        .options = options,
        .default_response = .{ .choice = 0 },
    });
    defer response.deinit(context.allocator);
    const index = switch (response.response) {
        .choice => |value| value,
        else => 0,
    };
    return candidates[if (index < candidates.len) index else 0];
}

fn reportValidationFailure(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    message: []const u8,
) !u8 {
    if (invocation.globals.ui_mode) {
        try output.writeErrorFrame(context, message);
    } else {
        try output.writeFailure(context, message);
    }
    try flushOutput(context);
    return 1;
}

fn openingMessage(allocator: std.mem.Allocator, invocation: *const parser.Invocation) ![]const u8 {
    if (std.mem.eql(u8, invocation.command.path, standard_command_path) or
        std.mem.eql(u8, invocation.command.path, aur_command_path))
    {
        const names = try joined(allocator, invocation.positionals);
        defer allocator.free(names);
        if (std.mem.eql(u8, invocation.command.path, standard_command_path))
            return std.fmt.allocPrint(allocator, "Installing packages: {s}", .{names});
        return std.fmt.allocPrint(allocator, "Installing AUR packages: {s}", .{names});
    }
    if (std.mem.eql(u8, invocation.command.path, appimage_command_path))
        return std.fmt.allocPrint(allocator, "Installing AppImage: {s}", .{invocation.positionals[0]});
    return std.fmt.allocPrint(allocator, "Installing Flatpak: {s}", .{invocation.positionals[0]});
}

fn successMessage(invocation: *const parser.Invocation) []const u8 {
    if (std.mem.eql(u8, invocation.command.path, standard_command_path))
        return "Packages installed successfully!";
    if (std.mem.eql(u8, invocation.command.path, aur_command_path))
        return if (optionEnabled(invocation, "--build-deps"))
            "Dependencies installed successfully!"
        else
            "Installation complete.";
    if (std.mem.eql(u8, invocation.command.path, appimage_command_path))
        return "Successfully installed appimage.";
    return "Flatpak install complete.";
}

fn failureMessage(invocation: *const parser.Invocation) []const u8 {
    if (std.mem.eql(u8, invocation.command.path, aur_command_path) and
        optionEnabled(invocation, "--build-deps")) return "Dependency installation failed.";
    return "Installation failed.";
}

const UiReporter = struct {
    context: *runtime.RuntimeContext,
    mutex: std.Io.Mutex = .init,
    write_failed: std.atomic.Value(bool) = .init(false),

    fn handle(data: ?*anyopaque, event: Zigalpm.OperationEvent) void {
        const self: *UiReporter = @ptrCast(@alignCast(data.?));
        self.mutex.lockUncancelable(self.context.io);
        defer self.mutex.unlock(self.context.io);
        self.write(event) catch self.write_failed.store(true, .release);
    }

    fn write(self: *UiReporter, event: Zigalpm.OperationEvent) !void {
        switch (event) {
            .status => |status| try output.writeAlpmInfoFrame(self.context, "InformationalOutput", status.message),
            .progress => |progress| {
                const message = progress.update.message orelse progress.update.stage orelse return;
                try output.writeAlpmInfoFrame(self.context, "InformationalOutput", message);
            },
            .failure => |failure| try output.writeErrorFrame(self.context, failure.message),
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

fn classifyPackageSource(value: []const u8) PackageSource {
    if (isUrl(value)) return .{ .url = value };
    if (isRepositoryQualifiedName(value)) return .{ .repository = value };
    if (std.mem.indexOfScalar(u8, value, '/') != null or
        std.mem.indexOfScalar(u8, value, '\\') != null or
        std.mem.startsWith(u8, value, "~") or
        std.fs.path.isAbsolute(value) or
        std.fs.path.extension(value).len > 0) return .{ .file = value };
    return .{ .repository = value };
}

fn isUrl(value: []const u8) bool {
    return startsWithIgnoreCase(value, "http://") or
        startsWithIgnoreCase(value, "https://") or
        startsWithIgnoreCase(value, "ftp://");
}

fn isRepositoryQualifiedName(value: []const u8) bool {
    if (value.len == 0 or value[0] == '~' or std.fs.path.isAbsolute(value)) return false;
    const slash = std.mem.indexOfScalar(u8, value, '/') orelse return false;
    if (slash == 0 or slash + 1 >= value.len or std.mem.indexOfScalarPos(u8, value, slash + 1, '/') != null)
        return false;
    if (std.fs.path.extension(value[slash + 1 ..]).len > 0) return false;
    for (value) |character| {
        if (character == '/') continue;
        if (!std.ascii.isAlphanumeric(character) and
            character != '-' and character != '_' and character != '.' and
            character != '+' and character != '@') return false;
    }
    return true;
}

fn urlFileName(url: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, url, "?#") orelse url.len;
    const path = url[0..end];
    const slash = std.mem.lastIndexOfScalar(u8, path, '/');
    const name = if (slash) |index| path[index + 1 ..] else path;
    return if (name.len == 0) "package-download" else name;
}

fn startsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    return value.len >= prefix.len and std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix);
}

fn containsIgnoreCase(value: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > value.len) return false;
    for (0..value.len - needle.len + 1) |index| {
        if (std.ascii.eqlIgnoreCase(value[index .. index + needle.len], needle)) return true;
    }
    return false;
}

fn sentinelStrings(allocator: std.mem.Allocator, values: []const []const u8) ![][:0]const u8 {
    const result = try allocator.alloc([:0]const u8, values.len);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |value| allocator.free(value);
        allocator.free(result);
    }
    for (values, result) |value, *destination| {
        destination.* = try allocator.dupeZ(u8, value);
        initialized += 1;
    }
    return result;
}

fn freeSentinelStrings(allocator: std.mem.Allocator, values: [][:0]const u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

fn optionEnabled(invocation: *const parser.Invocation, name: []const u8) bool {
    for (invocation.options) |option| {
        if (!std.mem.eql(u8, option.name, name)) continue;
        const value = option.value orelse return true;
        return !std.ascii.eqlIgnoreCase(value, "false");
    }
    return false;
}

fn optionValue(invocation: *const parser.Invocation, name: []const u8) ?[]const u8 {
    for (invocation.options) |option| {
        if (std.mem.eql(u8, option.name, name)) return option.value;
    }
    return null;
}

fn stringValue(configuration: *const config_model.Config, key: []const u8) ?[]const u8 {
    const value = configuration.values.get(key) orelse return null;
    if (value != .string or value.string.len == 0) return null;
    return value.string;
}

fn joined(allocator: std.mem.Allocator, values: []const []const u8) ![]const u8 {
    return std.mem.join(allocator, ", ", values);
}

fn isInstallPath(path: []const u8) bool {
    return std.mem.eql(u8, path, standard_command_path) or
        std.mem.eql(u8, path, appimage_command_path) or
        std.mem.eql(u8, path, aur_command_path) or
        std.mem.eql(u8, path, flatpak_command_path);
}

fn needsPackages(invocation: *const parser.Invocation) bool {
    return std.mem.eql(u8, invocation.command.path, standard_command_path) or
        std.mem.eql(u8, invocation.command.path, aur_command_path);
}

fn dependencyTargetCount(invocation: *const parser.Invocation) usize {
    if (std.mem.eql(u8, invocation.command.path, aur_command_path))
        return invocation.positionals.len;
    if (!std.mem.eql(u8, invocation.command.path, standard_command_path)) return 0;
    var count: usize = 0;
    for (invocation.positionals) |value| switch (classifyPackageSource(value)) {
        .repository => count += 1,
        .file, .url => {},
    };
    return count;
}

fn needsElevation(invocation: *const parser.Invocation) bool {
    return std.mem.eql(u8, invocation.command.path, standard_command_path) or
        std.mem.eql(u8, invocation.command.path, aur_command_path) or
        (std.mem.eql(u8, invocation.command.path, flatpak_command_path) and
            !optionEnabled(invocation, "--user"));
}

fn flushOutput(context: *runtime.RuntimeContext) !void {
    try context.stdout.flush();
    try context.stderr.flush();
}

test "install routes every action-first backend and forwards type-specific options" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
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
    const Capture = struct {
        calls: usize = 0,
        paths: [4][]const u8 = undefined,

        fn run(
            data: ?*anyopaque,
            _: *runtime.RuntimeContext,
            _: *Zigalpm.OperationContext,
            invocation: *const parser.Invocation,
        ) !void {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            self.paths[self.calls] = invocation.command.path;
            self.calls += 1;
            if (std.mem.eql(u8, invocation.command.path, standard_command_path))
                try std.testing.expect(optionEnabled(invocation, "--no-deps"));
            if (std.mem.eql(u8, invocation.command.path, aur_command_path))
                try std.testing.expect(optionEnabled(invocation, "--chroot"));
            if (std.mem.eql(u8, invocation.command.path, flatpak_command_path)) {
                try std.testing.expectEqualStrings("flathub-beta", optionValue(invocation, "--remote").?);
                try std.testing.expectEqualStrings("beta", optionValue(invocation, "--branch").?);
            }
        }
    };
    var capture: Capture = .{};
    const runner: Runner = .{ .data = &capture, .call = Capture.run };
    const arguments = [_][]const []const u8{
        &.{ "install", "standard", "--no-deps", "demo" },
        &.{ "install", "appimage", "demo.AppImage" },
        &.{ "install", "aur", "--chroot", "demo-git" },
        &.{ "install", "flatpak", "--user", "--remote", "flathub-beta", "--branch", "beta", "org.demo.App" },
    };
    for (arguments) |argv| {
        const outcome = try parser.parse(arena.allocator(), &manifest, argv);
        const invocation = outcome.dispatch;
        try std.testing.expectEqual(@as(u8, 0), try executeWithRunner(&context, &invocation, runner));
    }
    try std.testing.expectEqual(@as(usize, 4), capture.calls);
    try std.testing.expectEqualStrings(standard_command_path, capture.paths[0]);
    try std.testing.expectEqualStrings(appimage_command_path, capture.paths[1]);
    try std.testing.expectEqualStrings(aur_command_path, capture.paths[2]);
    try std.testing.expectEqualStrings(flatpak_command_path, capture.paths[3]);
}

test "install uses the shared non-UI and UI transaction lifecycles" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
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
    const Success = struct {
        fn run(_: ?*anyopaque, _: *runtime.RuntimeContext, _: *Zigalpm.OperationContext, _: *const parser.Invocation) !void {}
    };
    const runner: Runner = .{ .call = Success.run };

    var outcome = try parser.parse(arena.allocator(), &manifest, &.{ "install", "standard", "demo" });
    try std.testing.expectEqual(@as(u8, 0), try executeWithRunner(&context, &outcome.dispatch, runner));
    try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), ":: Installing packages: demo") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), ":: Transaction complete.") != null);

    stdout.writer.end = 0;
    outcome = try parser.parse(arena.allocator(), &manifest, &.{ "install", "aur", "--ui-mode", "demo" });
    try std.testing.expectEqual(@as(u8, 0), try executeWithRunner(&context, &outcome.dispatch, runner));
    try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), "[JSON]") != null);
}

test "install backend failures return a failing exit code and transaction result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    const outcome = try parser.parse(arena.allocator(), &manifest, &.{ "install", "standard", "demo" });
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
    const Failure = struct {
        fn run(_: ?*anyopaque, _: *runtime.RuntimeContext, _: *Zigalpm.OperationContext, _: *const parser.Invocation) !void {
            return error.TestInstallFailure;
        }
    };
    try std.testing.expectEqual(
        @as(u8, 1),
        try executeWithRunner(&context, &outcome.dispatch, .{ .call = Failure.run }),
    );
    try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), "error: TestInstallFailure") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), ":: Transaction failed.") != null);
}

test "standard source classification preserves repository names files and URLs" {
    try std.testing.expect(classifyPackageSource("core/linux") == .repository);
    try std.testing.expect(classifyPackageSource("linux") == .repository);
    try std.testing.expect(classifyPackageSource("./demo.pkg.tar.zst") == .file);
    try std.testing.expect(classifyPackageSource("demo.pkg.tar.zst") == .file);
    try std.testing.expect(classifyPackageSource("https://example.test/demo.pkg.tar.zst") == .url);
    try std.testing.expectEqualStrings("demo.pkg.tar.zst", urlFileName("https://example.test/demo.pkg.tar.zst?token=1"));
}

test "Flatpak candidate selection uses the shared question response" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stdout = std.Io.Writer.Discarding.init(&.{});
    var stderr = std.Io.Writer.Discarding.init(&.{});
    var context: runtime.RuntimeContext = .{
        .allocator = arena.allocator(),
        .io = std.testing.io,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
    };
    var operations = Zigalpm.OperationContext.init(arena.allocator(), std.testing.io);
    defer operations.deinit();
    operations.setQuestionHandler(.{ .function = struct {
        fn answer(_: ?*anyopaque, _: Zigalpm.OperationQuestion) Zigalpm.OperationQuestionResponse {
            return .{ .choice = 1 };
        }
    }.answer });
    const selected = try selectFlatpakCandidate(&context, &operations, &.{
        .{ .id = "org.demo.One", .name = "One", .remote = "flathub" },
        .{ .id = "org.demo.Two", .name = "Two", .remote = "flathub-beta" },
    });
    try std.testing.expectEqualStrings("org.demo.Two", selected.id);
    try std.testing.expectEqualStrings("flathub-beta", selected.remote);
}
