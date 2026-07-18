const std = @import("std");
const Zigalpm = @import("Zigalpm");
const config_manager = @import("../config/manager.zig");
const config_model = @import("../config/model.zig");
const output = @import("../output/config.zig");
const table = @import("../output/table.zig");
const parser = @import("../cli/parser.zig");
const shortcodes = @import("../cli/shortcodes.zig");
const runtime = @import("../runtime/context.zig");
const spec = @import("../cli/spec.zig");
const xdg = @import("../runtime/xdg.zig");

const standard_command_path = "shelly list standard";
const appimage_command_path = "shelly list appimage";
const aur_command_path = "shelly list aur";
const flatpak_command_path = "shelly list flatpak";

pub const Backend = enum { standard, appimage, aur, flatpak };

pub const StandardItem = struct {
    name: []const u8,
    version: []const u8 = "",
    size: i64 = 0,
    description: []const u8 = "",
    url: []const u8 = "",
    repository: []const u8 = "",
    replaces: []const []const u8 = &.{},
    licenses: []const []const u8 = &.{},
    groups: []const []const u8 = &.{},
    provides: []const []const u8 = &.{},
    depends: []const []const u8 = &.{},
    optional_depends: []const []const u8 = &.{},
    conflicts: []const []const u8 = &.{},
    install_reason: []const u8 = "Unknown",
    install_date: ?i64 = null,
    build_date: i64 = 0,
    download_size: i64 = 0,
    installed_size: i64 = 0,
    required_by: []const []const u8 = &.{},
    optional_for: []const []const u8 = &.{},
};

pub const AppImageItem = struct {
    name: []const u8,
    desktop_name: []const u8 = "",
    version: []const u8 = "",
    icon_name: []const u8 = "",
    description: []const u8 = "",
    size_on_disk: u64 = 0,
    update_url: []const u8 = "",
    raw_update_info: []const u8 = "",
    repo_owner: ?[]const u8 = null,
    repo_name: ?[]const u8 = null,
    update_type: i32 = 0,
    allow_prerelease: bool = false,
    command_line_args: ?[]const u8 = null,
    path: ?[]const u8 = null,
};

pub const AurItem = struct {
    id: i64 = 0,
    name: []const u8,
    package_base_id: i64 = 0,
    package_base: []const u8 = "",
    version: []const u8 = "",
    description: ?[]const u8 = null,
    url: ?[]const u8 = null,
    num_votes: i64 = 0,
    popularity: f64 = 0,
    out_of_date: ?i64 = null,
    maintainer: ?[]const u8 = null,
    first_submitted: i64 = 0,
    last_modified: i64 = 0,
    url_path: ?[]const u8 = null,
    depends: ?[]const []const u8 = null,
    make_depends: ?[]const []const u8 = null,
    optional_depends: ?[]const []const u8 = null,
    check_depends: ?[]const []const u8 = null,
    conflicts: ?[]const []const u8 = null,
    provides: ?[]const []const u8 = null,
    replaces: ?[]const []const u8 = null,
    groups: ?[]const []const u8 = null,
    licenses: ?[]const []const u8 = null,
    keywords: ?[]const []const u8 = null,
    explicit: bool = false,
};

pub const FlatpakItem = struct {
    id: []const u8,
    name: []const u8,
    version: []const u8,
    arch: []const u8,
    branch: []const u8,
    latest_commit: []const u8 = "",
    summary: []const u8 = "",
    kind: i32 = 0,
    remote: []const u8 = "",
    install_level: i32 = 0,
    installed_size: u64 = 0,
    ref: []const u8 = "",
    full_ref: []const u8 = "",
};

fn ResultSet(comptime T: type) type {
    return struct {
        items: []const T,
        arena: ?*std.heap.ArenaAllocator = null,

        fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            const arena = self.arena orelse return;
            arena.deinit();
            allocator.destroy(arena);
            self.* = undefined;
        }
    };
}

pub const Result = union(Backend) {
    standard: ResultSet(StandardItem),
    appimage: ResultSet(AppImageItem),
    aur: ResultSet(AurItem),
    flatpak: ResultSet(FlatpakItem),

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .standard => |*result| result.deinit(allocator),
            .appimage => |*result| result.deinit(allocator),
            .aur => |*result| result.deinit(allocator),
            .flatpak => |*result| result.deinit(allocator),
        }
    }
};

const Runner = struct {
    data: ?*anyopaque = null,
    call: *const fn (
        data: ?*anyopaque,
        context: *runtime.RuntimeContext,
        backend: Backend,
        show_hidden: bool,
    ) anyerror!Result,
};

const real_runner: Runner = .{ .call = runReal };

pub fn dispatch(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
) !?u8 {
    return dispatchWithRunner(context, invocation, real_runner);
}

fn dispatchWithRunner(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    runner: Runner,
) !?u8 {
    const backend = backendForPath(invocation.command.path) orelse return null;
    var result = runner.call(
        runner.data,
        context,
        backend,
        optionEnabled(invocation, "--show-hidden"),
    ) catch |err| {
        try writeQueryFailure(context, invocation, backend, err);
        return 1;
    };
    defer result.deinit(context.allocator);

    if (invocation.globals.ui_mode) {
        var payload = std.Io.Writer.Allocating.init(context.allocator);
        defer payload.deinit();
        try writeJson(context.allocator, &payload.writer, invocation, &result);
        try output.writeFrame(context, payload.writer.buffered());
    } else if (invocation.globals.json) {
        try writeJson(context.allocator, context.stdout, invocation, &result);
        try context.stdout.writeByte('\n');
    } else {
        try writePlain(context, invocation, &result);
    }
    return 0;
}

fn backendForPath(path: []const u8) ?Backend {
    if (std.mem.eql(u8, path, standard_command_path)) return .standard;
    if (std.mem.eql(u8, path, appimage_command_path)) return .appimage;
    if (std.mem.eql(u8, path, aur_command_path)) return .aur;
    if (std.mem.eql(u8, path, flatpak_command_path)) return .flatpak;
    return null;
}

fn optionEnabled(invocation: *const parser.Invocation, name: []const u8) bool {
    for (invocation.options) |option| {
        if (!std.mem.eql(u8, option.name, name)) continue;
        return option.value == null or !std.ascii.eqlIgnoreCase(option.value.?, "false");
    }
    return false;
}

fn writeQueryFailure(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    backend: Backend,
    err: anyerror,
) !void {
    const message = try std.fmt.allocPrint(
        context.allocator,
        "Unable to list installed {s} objects: {t}",
        .{ @tagName(backend), err },
    );
    defer context.allocator.free(message);
    if (invocation.globals.ui_mode)
        try output.writeErrorFrame(context, message)
    else if (invocation.globals.json)
        try context.stderr.print("{s}\n", .{message})
    else
        try output.writeFailure(context, message);
}

fn writeJson(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    invocation: *const parser.Invocation,
    result: *const Result,
) !void {
    var json: std.json.Stringify = .{ .writer = writer };
    try json.beginArray();
    switch (result.*) {
        .standard => |set| {
            const selected = try selectedStandard(allocator, invocation, set.items);
            defer allocator.free(selected);
            for (selected) |item| try writeStandardJson(&json, item);
        },
        .appimage => |set| for (set.items) |item| try writeAppImageJson(&json, item),
        .aur => |set| {
            const selected = try selectedAur(allocator, invocation, set.items);
            defer allocator.free(selected);
            for (selected) |item| try writeAurJson(&json, item);
        },
        .flatpak => |set| {
            const sorted = try sortedFlatpaks(allocator, set.items);
            defer allocator.free(sorted);
            for (sorted) |item| try writeFlatpakJson(&json, item);
        },
    }
    try json.endArray();
}

fn writeStandardJson(json: *std.json.Stringify, item: StandardItem) !void {
    try json.beginObject();
    try field(json, "Name", item.name);
    try field(json, "Version", item.version);
    try field(json, "Size", item.size);
    try field(json, "Description", item.description);
    try field(json, "Url", item.url);
    try field(json, "Repository", item.repository);
    try field(json, "Replaces", item.replaces);
    try field(json, "Licenses", item.licenses);
    try field(json, "Groups", item.groups);
    try field(json, "Provides", item.provides);
    try field(json, "Depends", item.depends);
    try field(json, "OptDepends", item.optional_depends);
    try field(json, "Conflicts", item.conflicts);
    try field(json, "PackageFile", null);
    try field(json, "InstallReason", item.install_reason);
    try json.objectField("InstallDate");
    if (item.install_date) |seconds| {
        var buffer: [32]u8 = undefined;
        try json.write(try formatIsoDateTime(&buffer, seconds));
    } else {
        try json.write(null);
    }
    try json.objectField("BuildDate");
    var build_date_buffer: [32]u8 = undefined;
    try json.write(try formatIsoDateTime(&build_date_buffer, item.build_date));
    try field(json, "DownloadSize", item.download_size);
    try field(json, "InstalledSize", item.installed_size);
    try field(json, "RequiredBy", item.required_by);
    try field(json, "OptionalFor", item.optional_for);
    try json.endObject();
}

fn writeAppImageJson(json: *std.json.Stringify, item: AppImageItem) !void {
    try json.beginObject();
    try field(json, "Name", item.name);
    try field(json, "DesktopName", item.desktop_name);
    try field(json, "Version", item.version);
    try field(json, "IconName", item.icon_name);
    try field(json, "Description", item.description);
    try field(json, "SizeOnDisk", item.size_on_disk);
    try field(json, "UpdateURl", item.update_url);
    try field(json, "RawUpdateInfo", item.raw_update_info);
    try field(json, "RepoOwner", item.repo_owner);
    try field(json, "RepoName", item.repo_name);
    try field(json, "UpdateType", item.update_type);
    try field(json, "AllowPrerelease", item.allow_prerelease);
    try field(json, "CommandLineArgs", item.command_line_args);
    try field(json, "Path", item.path);
    try json.endObject();
}

fn writeAurJson(json: *std.json.Stringify, item: AurItem) !void {
    try json.beginObject();
    try field(json, "Id", item.id);
    try field(json, "Name", item.name);
    try field(json, "PackageBaseId", item.package_base_id);
    try field(json, "PackageBase", item.package_base);
    try field(json, "Version", item.version);
    try field(json, "Description", item.description);
    try field(json, "Url", item.url);
    try field(json, "NumVotes", item.num_votes);
    try field(json, "Popularity", item.popularity);
    try field(json, "OutOfDate", item.out_of_date);
    try field(json, "Maintainer", item.maintainer);
    try field(json, "FirstSubmitted", item.first_submitted);
    try field(json, "LastModified", item.last_modified);
    try field(json, "UrlPath", item.url_path);
    try field(json, "Depends", item.depends);
    try field(json, "MakeDepends", item.make_depends);
    try field(json, "OptDepends", item.optional_depends);
    try field(json, "CheckDepends", item.check_depends);
    try field(json, "Conflicts", item.conflicts);
    try field(json, "Provides", item.provides);
    try field(json, "Replaces", item.replaces);
    try field(json, "Groups", item.groups);
    try field(json, "License", item.licenses);
    try field(json, "Keywords", item.keywords);
    try field(json, "Explicit", item.explicit);
    try json.endObject();
}

fn writeFlatpakJson(json: *std.json.Stringify, item: FlatpakItem) !void {
    const empty_list: []const []const u8 = &.{};
    try json.beginObject();
    try field(json, "Id", item.id);
    try field(json, "Name", item.name);
    try field(json, "Version", item.version);
    try field(json, "Arch", item.arch);
    try field(json, "Branch", item.branch);
    try field(json, "LatestCommit", item.latest_commit);
    try field(json, "Summary", item.summary);
    try field(json, "Kind", item.kind);
    try field(json, "IconPath", null);
    try field(json, "Description", "");
    try field(json, "Releases", empty_list);
    try field(json, "Categories", empty_list);
    try field(json, "Remote", item.remote);
    try field(json, "InstallLevel", item.install_level);
    try field(json, "Permissions", empty_list);
    try field(json, "InstalledSize", item.installed_size);
    try field(json, "Ref", item.ref);
    try field(json, "FullRef", item.full_ref);
    try json.endObject();
}

fn field(json: *std.json.Stringify, name: []const u8, value: anytype) !void {
    try json.objectField(name);
    try json.write(value);
}

fn writePlain(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    result: *const Result,
) !void {
    switch (result.*) {
        .standard => |set| try writeStandardPlain(context, invocation, set.items),
        .appimage => |set| try writeAppImagePlain(context, set.items),
        .aur => |set| try writeAurPlain(context, invocation, set.items),
        .flatpak => |set| try writeFlatpakPlain(context, set.items),
    }
}

fn writeStandardPlain(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    items: []const StandardItem,
) !void {
    var storage = std.heap.ArenaAllocator.init(context.allocator);
    defer storage.deinit();
    const allocator = storage.allocator();
    const selected = try selectedStandard(allocator, invocation, items);
    const rows = try allocator.alloc([]const []const u8, selected.len);
    const size_display = try loadSizeDisplay(context);
    for (selected, rows) |item, *cells| cells.* = try row(allocator, &.{
        item.name,
        item.repository,
        item.version,
        try formatSignedSize(allocator, size_display, item.installed_size),
        truncate(item.description, 50),
    });
    try table.write(
        context.allocator,
        context.stdout,
        &.{ "Name", "Repository", "Version", "Size", "Description" },
        rows,
        output.supportsAnsi(context),
    );
    try coloredTotal(context, try std.fmt.allocPrint(allocator, "Total: {d} packages", .{selected.len}));
}

fn writeAppImagePlain(context: *runtime.RuntimeContext, items: []const AppImageItem) !void {
    var storage = std.heap.ArenaAllocator.init(context.allocator);
    defer storage.deinit();
    const allocator = storage.allocator();
    const rows = try allocator.alloc([]const []const u8, items.len);
    const size_display = try loadSizeDisplay(context);
    for (items, rows) |item, *cells| {
        const update_info = if (item.update_url.len != 0)
            item.update_url
        else if (item.repo_owner) |owner|
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ owner, item.repo_name orelse "" })
        else
            "";
        cells.* = try row(allocator, &.{
            item.name,
            item.version,
            try formatSize(allocator, size_display, item.size_on_disk),
            update_info,
        });
    }
    try table.write(
        context.allocator,
        context.stdout,
        &.{ "Name", "Version", "Size", "Update Info" },
        rows,
        output.supportsAnsi(context),
    );
}

fn writeAurPlain(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    items: []const AurItem,
) !void {
    var storage = std.heap.ArenaAllocator.init(context.allocator);
    defer storage.deinit();
    const allocator = storage.allocator();
    const selected = try selectedAur(allocator, invocation, items);
    const rows = try allocator.alloc([]const []const u8, selected.len);
    for (selected, rows) |item, *cells| cells.* = try row(allocator, &.{
        item.name,
        item.version,
        truncate(item.description orelse "", 60),
    });
    try table.write(
        context.allocator,
        context.stdout,
        &.{ "Name", "Version", "Description" },
        rows,
        output.supportsAnsi(context),
    );
    try coloredTotal(context, try std.fmt.allocPrint(
        allocator,
        "Total: {d} AUR packages installed",
        .{selected.len},
    ));
}

fn writeFlatpakPlain(context: *runtime.RuntimeContext, items: []const FlatpakItem) !void {
    var storage = std.heap.ArenaAllocator.init(context.allocator);
    defer storage.deinit();
    const allocator = storage.allocator();
    const sorted = try sortedFlatpaks(allocator, items);
    const rows = try allocator.alloc([]const []const u8, sorted.len);
    for (sorted, rows) |item, *cells| cells.* = try row(allocator, &.{
        item.name,
        item.id,
        item.version,
        item.arch,
        item.branch,
        truncate(item.summary, 50),
        item.remote,
    });
    try table.write(
        context.allocator,
        context.stdout,
        &.{ "Name", "Id", "Version", "Arch", "Branch", "Summary", "Remote" },
        rows,
        output.supportsAnsi(context),
    );
    try coloredTotal(context, try std.fmt.allocPrint(allocator, "Total: {d} packages", .{sorted.len}));
}

fn coloredTotal(context: *runtime.RuntimeContext, message: []const u8) !void {
    if (output.supportsAnsi(context))
        try context.stdout.print("\x1b[38;2;0;0;255m{s}\x1b[0m\n", .{message})
    else
        try context.stdout.print("{s}\n", .{message});
}

fn row(allocator: std.mem.Allocator, values: []const []const u8) ![]const []const u8 {
    const result = try allocator.alloc([]const u8, values.len);
    @memcpy(result, values);
    return result;
}

fn selectedAur(
    allocator: std.mem.Allocator,
    invocation: *const parser.Invocation,
    items: []const AurItem,
) ![]AurItem {
    const explicit_only = optionEnabled(invocation, "--explicitOnly");
    const dependency_only = optionEnabled(invocation, "--dependencyOnly");
    var selected: std.ArrayList(AurItem) = .empty;
    for (items) |item| {
        if (explicit_only and !dependency_only and !item.explicit) continue;
        if (dependency_only and !explicit_only and item.explicit) continue;
        try selected.append(allocator, item);
    }
    std.mem.sort(AurItem, selected.items, {}, struct {
        fn lessThan(_: void, left: AurItem, right: AurItem) bool {
            return std.mem.lessThan(u8, left.name, right.name);
        }
    }.lessThan);
    return selected.toOwnedSlice(allocator);
}

fn selectedStandard(
    allocator: std.mem.Allocator,
    invocation: *const parser.Invocation,
    items: []const StandardItem,
) ![]StandardItem {
    const explicit_only = optionEnabled(invocation, "--explicitOnly");
    const dependency_only = optionEnabled(invocation, "--dependencyOnly");
    var selected: std.ArrayList(StandardItem) = .empty;
    for (items) |item| {
        const explicitly_installed = std.mem.eql(u8, item.install_reason, "Explicit");
        const dependency_installed = std.mem.eql(u8, item.install_reason, "Dependency");
        if (explicit_only and !dependency_only and !explicitly_installed) continue;
        if (dependency_only and !explicit_only and !dependency_installed) continue;
        try selected.append(allocator, item);
    }
    std.mem.sort(StandardItem, selected.items, {}, struct {
        fn lessThan(_: void, left: StandardItem, right: StandardItem) bool {
            return std.mem.lessThan(u8, left.name, right.name);
        }
    }.lessThan);
    return selected.toOwnedSlice(allocator);
}

fn sortedFlatpaks(allocator: std.mem.Allocator, items: []const FlatpakItem) ![]FlatpakItem {
    const sorted = try allocator.dupe(FlatpakItem, items);
    std.mem.sort(FlatpakItem, sorted, {}, struct {
        fn lessThan(_: void, left: FlatpakItem, right: FlatpakItem) bool {
            return std.mem.lessThan(u8, left.id, right.id);
        }
    }.lessThan);
    return sorted;
}

const SizeDisplay = enum { bytes, megabytes, gigabytes };

fn loadSizeDisplay(context: *runtime.RuntimeContext) !SizeDisplay {
    const configuration = config_manager.Manager.init(context).read() catch return .megabytes;
    const value = configuration.values.get("FileSizeDisplay") orelse return .megabytes;
    if (value != .string) return .megabytes;
    if (std.ascii.eqlIgnoreCase(value.string, "Bytes")) return .bytes;
    if (std.ascii.eqlIgnoreCase(value.string, "Gigabytes")) return .gigabytes;
    return .megabytes;
}

fn formatSize(allocator: std.mem.Allocator, display: SizeDisplay, bytes: u64) ![]const u8 {
    return switch (display) {
        .bytes => std.fmt.allocPrint(allocator, "{d} B", .{bytes}),
        .megabytes => std.fmt.allocPrint(allocator, "{d:.2} MiB", .{@as(f64, @floatFromInt(bytes)) / 1048576.0}),
        .gigabytes => std.fmt.allocPrint(allocator, "{d:.2} GiB", .{@as(f64, @floatFromInt(bytes)) / 1073741824.0}),
    };
}

fn formatSignedSize(allocator: std.mem.Allocator, display: SizeDisplay, bytes: i64) ![]const u8 {
    return formatSize(allocator, display, if (bytes <= 0) 0 else @intCast(bytes));
}

fn truncate(value: []const u8, maximum: usize) []const u8 {
    return if (value.len <= maximum) value else value[0..maximum];
}

fn runReal(
    _: ?*anyopaque,
    context: *runtime.RuntimeContext,
    backend: Backend,
    show_hidden: bool,
) !Result {
    return switch (backend) {
        .standard => runStandard(context, show_hidden),
        .appimage => runAppImage(context),
        .aur => runAur(context, show_hidden),
        .flatpak => runFlatpak(context),
    };
}

fn runStandard(context: *runtime.RuntimeContext, show_hidden: bool) !Result {
    const manager = try Zigalpm.AlpmManager.init(
        context.allocator,
        context.environ,
        null,
        false,
        null,
    );
    defer manager.deinit();
    if (show_hidden and !manager.show_hidden_packages) _ = manager.toggle_hidden_packages();
    const native_items = try manager.get_installed_packages();
    defer Zigalpm.alpm.OwnedPackage.deinitSlice(context.allocator, native_items);

    const arena = try createArena(context.allocator);
    errdefer destroyArena(context.allocator, arena);
    const allocator = arena.allocator();
    var items: std.ArrayList(StandardItem) = .empty;
    for (native_items) |native| {
        const name = native.name() orelse continue;
        if (!show_hidden and ignoredStandardPackage(manager, name)) continue;
        try items.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .version = try allocator.dupe(u8, native.version() orelse ""),
            .size = native.download_size(),
            .description = try allocator.dupe(u8, native.description() orelse ""),
            .url = try allocator.dupe(u8, native.url() orelse ""),
            .repository = try allocator.dupe(u8, native.repository() orelse ""),
            .replaces = try copyStrings(allocator, native.replaces()),
            .licenses = try copyStrings(allocator, native.licenses()),
            .groups = try copyStrings(allocator, native.groups()),
            .provides = try copyStrings(allocator, native.provides()),
            .depends = try copyStrings(allocator, native.depends()),
            .optional_depends = try copyStrings(allocator, native.optional_depends()),
            .conflicts = try copyStrings(allocator, native.conflicts()),
            .install_reason = @tagName(native.install_reason()),
            .install_date = native.install_date(),
            .build_date = native.build_date(),
            .download_size = native.download_size(),
            .installed_size = native.install_size(),
            .required_by = try copyStrings(allocator, native.required_by()),
            .optional_for = try copyStrings(allocator, native.optional_for()),
        });
    }
    return .{ .standard = .{ .items = try items.toOwnedSlice(allocator), .arena = arena } };
}

fn runAppImage(context: *runtime.RuntimeContext) !Result {
    const configuration = config_manager.Manager.init(context).read() catch
        try config_model.Config.defaults(context.allocator);
    const install_directory = stringValue(&configuration, "AppImageInstallPath") orelse
        try xdg.binHome(context);
    const local_db_path = try std.fs.path.join(
        context.allocator,
        &.{ try xdg.configHome(context), "shelly", "appimage-metadata-v2.db" },
    );
    defer context.allocator.free(local_db_path);
    var manager = Zigalpm.AppImageManager{
        .allocator = context.allocator,
        .io = context.io,
        .environ = context.environ,
        .install_directory = install_directory,
        .local_db_path = local_db_path,
    };
    defer manager.deinit();
    const native_items = try manager.getAppImagesFromLocalDb();
    defer manager.freeAppImages(native_items);

    const arena = try createArena(context.allocator);
    errdefer destroyArena(context.allocator, arena);
    const allocator = arena.allocator();
    const items = try allocator.alloc(AppImageItem, native_items.len);
    for (native_items, items) |native, *item| item.* = .{
        .name = try allocator.dupe(u8, native.name),
        .desktop_name = try allocator.dupe(u8, native.desktop_name),
        .version = try allocator.dupe(u8, native.version),
        .icon_name = try allocator.dupe(u8, native.icon_name),
        .description = try allocator.dupe(u8, native.description),
        .size_on_disk = native.size_on_disk,
        .update_url = try allocator.dupe(u8, native.update_url),
        .raw_update_info = try allocator.dupe(u8, native.raw_update_info),
        .repo_owner = try copyOptionalString(allocator, native.repo_owner),
        .repo_name = try copyOptionalString(allocator, native.repo_name),
        .update_type = @intCast(@intFromEnum(native.update_type)),
        .allow_prerelease = native.allow_prerelease,
        .command_line_args = try allocator.dupe(u8, native.command_line_args),
        .path = try allocator.dupe(u8, native.path),
    };
    return .{ .appimage = .{ .items = items, .arena = arena } };
}

fn runAur(context: *runtime.RuntimeContext, show_hidden: bool) !Result {
    const database_path = try xdg.shellyCache(context, &.{"db"});
    defer context.allocator.free(database_path);
    try std.Io.Dir.cwd().createDirPath(context.io, database_path);
    const manager = try Zigalpm.AurManager.init(context.allocator, context.environ, .{
        .use_temp_path = true,
        .temp_path = database_path,
        .show_hidden_packages = show_hidden,
    });
    defer manager.deinit();
    const native_items = try manager.getInstalledPackages();
    defer Zigalpm.aur.models.Package.deinitSlice(context.allocator, native_items);

    const arena = try createArena(context.allocator);
    errdefer destroyArena(context.allocator, arena);
    const allocator = arena.allocator();
    const items = try allocator.alloc(AurItem, native_items.len);
    for (native_items, items) |native, *item| item.* = .{
        .id = native.id,
        .name = try allocator.dupe(u8, native.name),
        .package_base_id = native.package_base_id,
        .package_base = try allocator.dupe(u8, native.package_base),
        .version = try allocator.dupe(u8, native.version),
        .description = try copyOptionalString(allocator, native.description),
        .url = try copyOptionalString(allocator, native.url),
        .num_votes = native.num_votes,
        .popularity = native.popularity,
        .out_of_date = native.out_of_date,
        .maintainer = try copyOptionalString(allocator, native.maintainer),
        .first_submitted = native.first_submitted,
        .last_modified = native.last_modified,
        .url_path = try copyOptionalString(allocator, native.url_path),
        .depends = try copyOptionalStrings(allocator, native.depends),
        .make_depends = try copyOptionalStrings(allocator, native.make_depends),
        .optional_depends = try copyOptionalStrings(allocator, native.opt_depends),
        .check_depends = try copyOptionalStrings(allocator, native.check_depends),
        .conflicts = try copyOptionalStrings(allocator, native.conflicts),
        .provides = try copyOptionalStrings(allocator, native.provides),
        .replaces = try copyOptionalStrings(allocator, native.replaces),
        .groups = try copyOptionalStrings(allocator, native.groups),
        .licenses = try copyOptionalStrings(allocator, native.licenses),
        .keywords = try copyOptionalStrings(allocator, native.keywords),
        .explicit = native.explicit,
    };
    return .{ .aur = .{ .items = items, .arena = arena } };
}

fn runFlatpak(context: *runtime.RuntimeContext) !Result {
    var manager = Zigalpm.FlatpakManager{ .allocator = context.allocator, .io = context.io };
    defer manager.deinit();
    const native_items = try manager.list_installed_applications();
    defer Zigalpm.flatpak.manager.InstalledApplication.deinitSlice(context.allocator, native_items);

    const arena = try createArena(context.allocator);
    errdefer destroyArena(context.allocator, arena);
    const allocator = arena.allocator();
    const items = try allocator.alloc(FlatpakItem, native_items.len);
    for (native_items, items) |native, *item| {
        const kind = if (native.kind == 0) "app" else "runtime";
        const ref = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}/{s}/{s}",
            .{ kind, native.id, native.arch, native.branch },
        );
        item.* = .{
            .id = try allocator.dupe(u8, native.id),
            .name = try allocator.dupe(u8, native.name),
            .version = try allocator.dupe(u8, native.version),
            .arch = try allocator.dupe(u8, native.arch),
            .branch = try allocator.dupe(u8, native.branch),
            .latest_commit = try allocator.dupe(u8, native.latest_commit),
            .summary = try allocator.dupe(u8, native.summary),
            .kind = native.kind,
            .remote = try allocator.dupe(u8, native.origin),
            .install_level = @intFromEnum(native.scope),
            .installed_size = native.installed_size,
            .ref = ref,
            .full_ref = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ native.origin, ref }),
        };
    }
    return .{ .flatpak = .{ .items = items, .arena = arena } };
}

fn createArena(allocator: std.mem.Allocator) !*std.heap.ArenaAllocator {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    return arena;
}

fn destroyArena(allocator: std.mem.Allocator, arena: *std.heap.ArenaAllocator) void {
    arena.deinit();
    allocator.destroy(arena);
}

fn stringValue(configuration: *const config_model.Config, key: []const u8) ?[]const u8 {
    const value = configuration.values.get(key) orelse return null;
    if (value != .string or value.string.len == 0) return null;
    return value.string;
}

fn copyOptionalString(allocator: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
    return if (value) |text| try allocator.dupe(u8, text) else null;
}

fn copyOptionalStrings(
    allocator: std.mem.Allocator,
    values: ?[]const []const u8,
) !?[]const []const u8 {
    const source = values orelse return null;
    const copies = try allocator.alloc([]const u8, source.len);
    for (source, copies) |value, *copy| copy.* = try allocator.dupe(u8, value);
    return copies;
}

fn copyStrings(allocator: std.mem.Allocator, values: anytype) ![]const []const u8 {
    const copies = try allocator.alloc([]const u8, values.len);
    for (values, copies) |value, *copy| copy.* = try allocator.dupe(u8, value);
    return copies;
}

fn ignoredStandardPackage(manager: *Zigalpm.AlpmManager, name: []const u8) bool {
    for (manager.config.ignore_package.items) |ignored| {
        if (std.mem.eql(u8, ignored, name)) return true;
    }
    return false;
}

fn formatIsoDateTime(buffer: []u8, seconds: i64) ![]const u8 {
    if (seconds < 0) return std.fmt.bufPrint(buffer, "1970-01-01T00:00:00", .{});
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(seconds) };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();
    return std.fmt.bufPrint(
        buffer,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}",
        .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        },
    );
}

fn parseTestArguments(
    allocator: std.mem.Allocator,
    manifest: *const spec.Manifest,
    arguments: []const []const u8,
) !parser.Outcome {
    const translation = try shortcodes.translate(allocator, manifest, arguments);
    const translated = translation.arguments() orelse return error.ShortcodeTranslationFailed;
    return parser.parse(allocator, manifest, translated);
}

fn decodeFirstTestFrame(allocator: std.mem.Allocator, rendered: []const u8) ![]u8 {
    const prefix = "[JSON]";
    const suffix = "[/JSON]";
    const prefix_start = std.mem.indexOf(u8, rendered, prefix) orelse return error.MissingFrame;
    const payload_start = prefix_start + prefix.len;
    const suffix_start = std.mem.indexOfPos(u8, rendered, payload_start, suffix) orelse
        return error.MissingFrame;
    const encoded = rendered[payload_start..suffix_start];
    const decoded_length = try std.base64.standard.Decoder.calcSizeForSlice(encoded);
    const decoded = try allocator.alloc(u8, decoded_length);
    errdefer allocator.free(decoded);
    try std.base64.standard.Decoder.decode(decoded, encoded);
    return decoded;
}

test "list routes long and requested uppercase short forms to package backends only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    const Case = struct { arguments: []const []const u8, backend: Backend };
    const cases = [_]Case{
        .{ .arguments = &.{ "list", "standard" }, .backend = .standard },
        .{ .arguments = &.{"-Ls"}, .backend = .standard },
        .{ .arguments = &.{ "list", "appimage" }, .backend = .appimage },
        .{ .arguments = &.{"-LI"}, .backend = .appimage },
        .{ .arguments = &.{ "list", "aur" }, .backend = .aur },
        .{ .arguments = &.{"-LA"}, .backend = .aur },
        .{ .arguments = &.{ "list", "flatpak" }, .backend = .flatpak },
        .{ .arguments = &.{"-LF"}, .backend = .flatpak },
    };
    for (cases) |case| {
        const outcome = try parseTestArguments(arena.allocator(), &manifest, case.arguments);
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
                fn run(data: ?*anyopaque, _: *runtime.RuntimeContext, backend: Backend, _: bool) !Result {
                    const capture: *?Backend = @ptrCast(@alignCast(data.?));
                    capture.* = backend;
                    return switch (backend) {
                        .standard => .{ .standard = .{ .items = &.{} } },
                        .appimage => .{ .appimage = .{ .items = &.{} } },
                        .aur => .{ .aur = .{ .items = &.{} } },
                        .flatpak => .{ .flatpak = .{ .items = &.{} } },
                    };
                }
            }.run,
        };
        try std.testing.expectEqual(@as(?u8, 0), try dispatchWithRunner(&context, &outcome.dispatch, runner));
        try std.testing.expectEqual(case.backend, observed.?);
    }

    const uppercase_standard = try shortcodes.translate(arena.allocator(), &manifest, &.{"-LS"});
    try std.testing.expect(uppercase_standard == .failure);
    try std.testing.expect(std.mem.indexOf(u8, uppercase_standard.failure, "Unknown shortcode type 'S'") != null);

    const keyring = try parseTestArguments(arena.allocator(), &manifest, &.{ "list", "keyring" });
    try std.testing.expect(keyring == .failure);
}

test "standard install-reason filters apply to structured output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    const items = [_]StandardItem{
        .{ .name = "dependency-package", .version = "1", .install_reason = "Dependency" },
        .{ .name = "explicit-package", .version = "2", .install_reason = "Explicit" },
    };
    const runner: Runner = .{ .data = @constCast(&items), .call = struct {
        fn run(data: ?*anyopaque, _: *runtime.RuntimeContext, _: Backend, show_hidden: bool) !Result {
            try std.testing.expect(show_hidden);
            const values: *const [2]StandardItem = @ptrCast(@alignCast(data.?));
            return .{ .standard = .{ .items = values } };
        }
    }.run };
    const outcome = try parseTestArguments(
        arena.allocator(),
        &manifest,
        &.{ "-Lswe", "--json" },
    );
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
    try std.testing.expectEqual(@as(?u8, 0), try dispatchWithRunner(&context, &outcome.dispatch, runner));
    const rendered = stdout.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "explicit-package") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "dependency-package") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"PackageFile\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"InstallReason\":\"Explicit\"") != null);
}

test "AUR filters apply to JSON and UI structured output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    const items = [_]AurItem{
        .{ .name = "dependency-package", .version = "1", .explicit = false },
        .{ .name = "explicit-package", .version = "2", .explicit = true },
    };
    const runner: Runner = .{ .data = @constCast(&items), .call = struct {
        fn run(data: ?*anyopaque, _: *runtime.RuntimeContext, _: Backend, _: bool) !Result {
            const values: *const [2]AurItem = @ptrCast(@alignCast(data.?));
            return .{ .aur = .{ .items = values } };
        }
    }.run };

    const json_outcome = try parseTestArguments(
        arena.allocator(),
        &manifest,
        &.{ "list", "aur", "--explicitOnly", "--json" },
    );
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
    try std.testing.expectEqual(@as(?u8, 0), try dispatchWithRunner(&context, &json_outcome.dispatch, runner));
    try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), "explicit-package") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), "dependency-package") == null);

    stdout.writer.end = 0;
    const ui_outcome = try parseTestArguments(
        arena.allocator(),
        &manifest,
        &.{ "list", "aur", "--dependencyOnly", "--ui-mode" },
    );
    try std.testing.expectEqual(@as(?u8, 0), try dispatchWithRunner(&context, &ui_outcome.dispatch, runner));
    const payload = try decodeFirstTestFrame(arena.allocator(), stdout.writer.buffered());
    try std.testing.expect(std.mem.indexOf(u8, payload, "dependency-package") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "explicit-package") == null);
}

test "AppImage and Flatpak lists emit compatibility JSON and stable ordering" {
    var output_buffer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output_buffer.deinit();
    const appimages = [_]AppImageItem{.{
        .name = "Editor",
        .version = "3.0",
        .size_on_disk = 4096,
        .update_type = 2,
        .command_line_args = "--safe",
        .path = "/apps/editor.AppImage",
    }};
    const app_result: Result = .{ .appimage = .{ .items = &appimages } };
    var app_invocation: parser.Invocation = undefined;
    app_invocation.options = &.{};
    try writeJson(std.testing.allocator, &output_buffer.writer, &app_invocation, &app_result);
    try std.testing.expect(std.mem.indexOf(u8, output_buffer.writer.buffered(), "\"UpdateURl\":\"\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output_buffer.writer.buffered(), "\"UpdateType\":2") != null);

    output_buffer.writer.end = 0;
    const flatpaks = [_]FlatpakItem{
        .{ .id = "z.app", .name = "Z", .version = "1", .arch = "x86_64", .branch = "stable" },
        .{ .id = "a.app", .name = "A", .version = "2", .arch = "x86_64", .branch = "stable" },
    };
    const flatpak_result: Result = .{ .flatpak = .{ .items = &flatpaks } };
    try writeJson(std.testing.allocator, &output_buffer.writer, &app_invocation, &flatpak_result);
    const rendered = output_buffer.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "a.app").? < std.mem.indexOf(u8, rendered, "z.app").?);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"Permissions\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"InstallLevel\":0") != null);
}
