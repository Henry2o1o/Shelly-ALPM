const bindings = @import("bindings.zig");
const std = @import("std");
const parser = @import("appstream_parser.zig");

const flatpak = bindings.libflatpak;
const rawflatpak = bindings.libflatpak.flatpak;

pub const Error = error{
    NotInitialized,
    RemoteNotFound,
    CatalogNotFound,
    FlatpakError,
};

/// An owned catalog. All strings and application models remain valid until
/// `deinit` is called.
pub const AppstreamCatalog = struct {
    owner_allocator: std.mem.Allocator,
    arena_state: *std.heap.ArenaAllocator,
    remote_name: []const u8,
    scope: flatpak.Scope,
    arch: []const u8,
    path: []const u8,
    apps: []parser.AppstreamApp,

    pub fn deinit(self: *AppstreamCatalog) void {
        self.arena_state.deinit();
        self.owner_allocator.destroy(self.arena_state);
        self.* = undefined;
    }

    pub fn deinitSlice(allocator: std.mem.Allocator, catalogs: []AppstreamCatalog) void {
        for (catalogs) |*catalog| catalog.deinit();
        allocator.free(catalogs);
    }
};

pub const AppstreamManager = struct {
    allocator: ?std.mem.Allocator = null,
    io: ?std.Io = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) AppstreamManager {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn updateAllAppstreams(self: AppstreamManager) !void {
        const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
        var g_error: ?*rawflatpak.GError = null;
        defer rawflatpak.g_object_unref(cancellable);
        defer if (g_error) |e| rawflatpak.g_error_free(e);

        var installation: ?*rawflatpak.FlatpakInstallation = null;
        var remotes_ptrs: ?*rawflatpak.GPtrArray = null;

        installation = rawflatpak.flatpak_installation_new_system(cancellable, &g_error);
        remotes_ptrs = rawflatpak.flatpak_installation_list_remotes(installation, cancellable, &g_error);

        try self.enumerate_appstreams(remotes_ptrs, flatpak.Scope.SYSTEM);

        installation = rawflatpak.flatpak_installation_new_user(cancellable, &g_error);
        remotes_ptrs = rawflatpak.flatpak_installation_list_remotes(installation, cancellable, &g_error);

        try self.enumerate_appstreams(remotes_ptrs, flatpak.Scope.USER);
    }

    fn enumerate_appstreams(self: AppstreamManager, remote_ptrs: ?*rawflatpak.GPtrArray, scope: flatpak.Scope) !void {
        if (remote_ptrs) |ptrs| {
            var j: usize = 0;
            while (j < ptrs.len) : (j += 1) {
                const raw: *rawflatpak.FlatpakRemote = @ptrCast(@alignCast(ptrs.pdata[j]));
                const remote = flatpak.Remote.new(raw, scope);
                if (remote.name()) |name| {
                    try self.updateRemoteAppstream(scope, name);
                }
            }
        }
    }

    pub fn updateRemoteAppstream(_: AppstreamManager, scope: flatpak.Scope, remote_name: [:0]const u8) !void {
        const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
        var g_error: ?*rawflatpak.GError = null;
        defer rawflatpak.g_object_unref(cancellable);
        defer if (g_error) |e| rawflatpak.g_error_free(e);

        const installation = if (scope == .SYSTEM)
            rawflatpak.flatpak_installation_new_system(cancellable, &g_error)
        else
            rawflatpak.flatpak_installation_new_user(cancellable, &g_error);

        const arch = std.mem.span(rawflatpak.flatpak_get_default_arch());
        _ = rawflatpak.flatpak_installation_update_appstream_sync(installation, remote_name, arch, null, cancellable, &g_error);
        if (g_error) |err| {
            std.log.err("appstream update error: {s}", .{std.mem.span(err.message)});
            return error.FlatpakError;
        }
    }

    /// Return the first enabled catalog for a remote, preferring the system
    /// installation to match the C# manager's lookup order.
    pub fn getRemoteCatalog(
        self: AppstreamManager,
        remote_name: []const u8,
        requested_arch: ?[]const u8,
    ) !AppstreamCatalog {
        if (try self.getRemoteCatalogForScope(remote_name, requested_arch, .SYSTEM)) |catalog| return catalog;
        if (try self.getRemoteCatalogForScope(remote_name, requested_arch, .USER)) |catalog| return catalog;
        return Error.RemoteNotFound;
    }

    /// Return every available local AppStream catalog across system and user
    /// installations. Missing catalogs are skipped, matching Flatpak's behavior
    /// for remotes that do not publish AppStream metadata.
    pub fn getAllRemoteCatalogs(
        self: AppstreamManager,
        requested_arch: ?[]const u8,
    ) ![]AppstreamCatalog {
        const allocator = self.allocator orelse return Error.NotInitialized;
        _ = self.io orelse return Error.NotInitialized;

        var catalogs: std.ArrayList(AppstreamCatalog) = .empty;
        errdefer {
            for (catalogs.items) |*catalog| catalog.deinit();
            catalogs.deinit(allocator);
        }

        try self.appendCatalogsForScope(&catalogs, requested_arch, .SYSTEM);
        try self.appendCatalogsForScope(&catalogs, requested_arch, .USER);
        return catalogs.toOwnedSlice(allocator);
    }

    /// Parse a known catalog path. This is also useful to consumers that obtain
    /// a catalog path from an alternate Flatpak installation.
    pub fn loadCatalogFromPath(
        self: AppstreamManager,
        remote_name: []const u8,
        scope: flatpak.Scope,
        arch: []const u8,
        path: []const u8,
    ) !AppstreamCatalog {
        const allocator = self.allocator orelse return Error.NotInitialized;
        const io = self.io orelse return Error.NotInitialized;

        const arena_state = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(arena_state);
        arena_state.* = std.heap.ArenaAllocator.init(allocator);
        errdefer arena_state.deinit();
        const arena = arena_state.allocator();

        const appstream_parser = parser.AppstreamParser{ .arena = arena, .io = io };
        const apps = try appstream_parser.parseFile(path);
        return .{
            .owner_allocator = allocator,
            .arena_state = arena_state,
            .remote_name = try arena.dupe(u8, remote_name),
            .scope = scope,
            .arch = try arena.dupe(u8, arch),
            .path = try arena.dupe(u8, path),
            .apps = apps,
        };
    }

    fn getRemoteCatalogForScope(
        self: AppstreamManager,
        remote_name: []const u8,
        requested_arch: ?[]const u8,
        scope: flatpak.Scope,
    ) !?AppstreamCatalog {
        const allocator = self.allocator orelse return Error.NotInitialized;
        _ = self.io orelse return Error.NotInitialized;
        const remote_name_z = try allocator.dupeSentinel(u8, remote_name, 0);
        defer allocator.free(remote_name_z);

        const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
        defer rawflatpak.g_object_unref(cancellable);
        var g_error: ?*rawflatpak.GError = null;
        defer if (g_error) |value| rawflatpak.g_error_free(value);

        const installation = if (scope == .SYSTEM)
            rawflatpak.flatpak_installation_new_system(cancellable, &g_error)
        else
            rawflatpak.flatpak_installation_new_user(cancellable, &g_error);
        if (installation == null or g_error != null) return null;
        defer rawflatpak.g_object_unref(installation);

        const remote = rawflatpak.flatpak_installation_get_remote_by_name(
            installation,
            remote_name_z,
            cancellable,
            &g_error,
        );
        if (remote == null or g_error != null) return null;
        defer rawflatpak.g_object_unref(remote);
        if (rawflatpak.flatpak_remote_get_disabled(remote) != 0) return null;

        return self.loadCatalogForRemote(remote, remote_name, scope, requested_arch) catch |err| switch (err) {
            Error.CatalogNotFound => null,
            else => return err,
        };
    }

    fn appendCatalogsForScope(
        self: AppstreamManager,
        catalogs: *std.ArrayList(AppstreamCatalog),
        requested_arch: ?[]const u8,
        scope: flatpak.Scope,
    ) !void {
        const allocator = self.allocator orelse return Error.NotInitialized;
        const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
        defer rawflatpak.g_object_unref(cancellable);
        var g_error: ?*rawflatpak.GError = null;
        defer if (g_error) |value| rawflatpak.g_error_free(value);

        const installation = if (scope == .SYSTEM)
            rawflatpak.flatpak_installation_new_system(cancellable, &g_error)
        else
            rawflatpak.flatpak_installation_new_user(cancellable, &g_error);
        if (installation == null or g_error != null) return;
        defer rawflatpak.g_object_unref(installation);

        const remote_ptrs = rawflatpak.flatpak_installation_list_remotes(installation, cancellable, &g_error);
        if (remote_ptrs == null or g_error != null) return;
        defer rawflatpak.g_ptr_array_unref(remote_ptrs);

        var index: usize = 0;
        while (index < remote_ptrs.*.len) : (index += 1) {
            const remote: *rawflatpak.FlatpakRemote = @ptrCast(@alignCast(remote_ptrs.*.pdata[index]));
            if (rawflatpak.flatpak_remote_get_disabled(remote) != 0) continue;
            const name_ptr = rawflatpak.flatpak_remote_get_name(remote);
            if (name_ptr == null) continue;
            const name = std.mem.span(name_ptr);
            var catalog = self.loadCatalogForRemote(remote, name, scope, requested_arch) catch |err| switch (err) {
                Error.CatalogNotFound => continue,
                else => return err,
            };
            errdefer catalog.deinit();
            try catalogs.append(allocator, catalog);
        }
    }

    fn loadCatalogForRemote(
        self: AppstreamManager,
        remote: *rawflatpak.FlatpakRemote,
        remote_name: []const u8,
        scope: flatpak.Scope,
        requested_arch: ?[]const u8,
    ) !AppstreamCatalog {
        const allocator = self.allocator orelse return Error.NotInitialized;
        const io = self.io orelse return Error.NotInitialized;
        const arch = requested_arch orelse std.mem.span(rawflatpak.flatpak_get_default_arch());
        const arch_z = try allocator.dupeSentinel(u8, arch, 0);
        defer allocator.free(arch_z);

        const directory_file = rawflatpak.flatpak_remote_get_appstream_dir(remote, arch_z) orelse
            return Error.CatalogNotFound;
        defer rawflatpak.g_object_unref(directory_file);
        const directory_path_ptr = rawflatpak.g_file_get_path(directory_file);
        if (directory_path_ptr == null) return Error.CatalogNotFound;
        defer rawflatpak.g_free(directory_path_ptr);
        const directory_path = std.mem.span(directory_path_ptr);

        const xml_path = try std.fs.path.join(allocator, &.{ directory_path, "appstream.xml" });
        defer allocator.free(xml_path);
        if (fileExists(io, xml_path))
            return self.loadCatalogFromPath(remote_name, scope, arch, xml_path);

        const gzip_path = try std.fs.path.join(allocator, &.{ directory_path, "appstream.xml.gz" });
        defer allocator.free(gzip_path);
        if (fileExists(io, gzip_path))
            return self.loadCatalogFromPath(remote_name, scope, arch, gzip_path);

        return Error.CatalogNotFound;
    }
};

fn fileExists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

test "test updateRemoteAppstream" {
    const manager = AppstreamManager{};
    try manager.updateRemoteAppstream(flatpak.Scope.SYSTEM, "flathub");
}

test "AppStream manager returns an owned typed catalog" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/appstream.xml",
        .{temporary.sub_path},
    );
    defer std.testing.allocator.free(path);

    var file = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{});
    defer file.close(std.testing.io);
    try file.writeStreamingAll(
        std.testing.io,
        "<components><component type=\"desktop-application\"><id>org.example.App</id><name>Example</name></component></components>",
    );

    const manager = AppstreamManager.init(std.testing.allocator, std.testing.io);
    var catalog = try manager.loadCatalogFromPath("test", .USER, "x86_64", path);
    defer catalog.deinit();

    try std.testing.expectEqualStrings("test", catalog.remote_name);
    try std.testing.expectEqual(flatpak.Scope.USER, catalog.scope);
    try std.testing.expectEqual(@as(usize, 1), catalog.apps.len);
    try std.testing.expectEqualStrings("org.example.App", catalog.apps[0].id);
}

test "AppStream manager exposes one and all remote catalog retrieval" {
    _ = AppstreamManager.getRemoteCatalog;
    _ = AppstreamManager.getAllRemoteCatalogs;
    _ = AppstreamCatalog.deinitSlice;
}

//test "test updateAllAppstream" {
//  const manager = AppstreamManager{};
//try manager.updateAllAppstreams();
//}
