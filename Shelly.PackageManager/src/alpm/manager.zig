const std = @import("std");
const bindings = @import("bindings.zig");
const events = @import("events.zig");
const configuration = @import("configuration.zig");
const builtin = @import("builtin");

const libalpm = bindings.libalpm; // typed aliases (Handle, Database, Config, ...)
const rawLibalpm = bindings.libalpm.alpm;

threadlocal var active_manager: ?*Manager = null;

pub const ConfigError = error{
    InitFailed,
    RegisterDbFailed,
};

pub const InitError = error{
    InitFailed,
    RegisterDbFailed,
    ConfigParseFailed,
};
pub const TransactionError = error{
    TransInitFailed,
    PrepareFailed,
    CommitFailed,
    UnsatisfiedDeps,
    ConflictingDeps,
    FileConflicts,
};
pub const QueryError = error{ DbNotFound, PkgNotFound };

pub const Manager = struct {
    handle: libalpm.Handle = null,
    is_initialized: bool = false,
    is_cachyos: bool = false,
    allocator: std.mem.Allocator,
    config: configuration.Configuration.Config,
    dispatcher: events.Dispatcher,
    local_db: ?bindings.libalpm.Database = null,
    sync_dbs: std.ArrayList(bindings.libalpm.Database) = .empty,

    pub fn init(allocator: std.mem.Allocator, root: bool, configPath: ?[]const u8) InitError!Manager {
        const database_path = configPath orelse "/etc/pacman.conf";
        const io = std.Io;
        const config = configuration.Configuration.parse(allocator, io, database_path);
        var err: rawLibalpm.alpm_errno_t = 0;
        const handle = rawLibalpm.alpm_initialize(root, database_path, &err) orelse {
            std.log.err("alpm_initialize failed: {s}", .{std.mem.span(rawLibalpm.alpm_strerror(err))});
            return error.InitFailed;
        };
        var self = Manager{
            .handle = handle,
            .is_initialized = true,
            .allocator = allocator,
            .dispatcher = events.Dispatcher.init(allocator),
            .config = config,
        };
        self.applyConfig(config, root);
        return self;
    }

    pub fn deinit(self: *Manager) void {
        if (self.handle) |h| _ = libalpm.alpm.alpm_release(h);
        self.handle = null;
        self.is_initialized = false;
    }

    fn applyConfig(self: *Manager, config: configuration.Configuration.Config, root: bool) void {
        const h = self.handle;

        for (config.ignore_package.items) |pkg_name| {
            self.check("ignore_package", rawLibalpm.alpm_option_add_ignorepkg(h, pkg_name.ptr));
        }

        for (config.ignore_group.items) |group_name| {
            self.check("ignore_group", rawLibalpm.alpm_option_add_ignoregroup(h, group_name.ptr));
        }

        for (config.hook_directory.items) |hook_dir| {
            self.check("hook_directory", rawLibalpm.alpm_option_add_hookdir(h, hook_dir.ptr));
        }

        if (root and config.gpg_directory.len != 0) {
            self.check("gpgdir", rawLibalpm.alpm_option_set_gpgdir(h, config.gpg_directory.ptr));
        }

        if (config.signature_level != 0) {
            self.check("default_sig_level", rawLibalpm.alpm_option_set_default_siglevel(h, @intCast(config.signature_level)));
            self.check("local_file_sig_level", rawLibalpm.alpm_option_set_local_file_siglevel(h, @intCast(config.local_file_signature_level)));
        }
        self.check("remote_file_sig_level", rawLibalpm.alpm_option_set_remote_file_siglevel(h, @intCast(config.remote_file_signature_level)));

        if (config.cache_directory.len != 0) {
            self.check("cachedir", rawLibalpm.alpm_option_add_cachedir(h, config.cache_directory.ptr));
        }

        if (config.log_file.len != 0) {
            self.check("logfile", rawLibalpm.alpm_option_set_logfile(h, config.log_file.ptr));
        }

        self.check("check_space", rawLibalpm.alpm_option_set_checkspace(h, @as(c_int, if (config.check_space) 1 else 0)));

        const resolved_arch = resolveArchitecture(config.architecture);
        const resolved_arch_z = self.allocator.dupeZ(u8, resolved_arch) catch {
            std.log.err("out of memory resolving architecture; skipping repository registration", .{});
            return;
        };
        defer self.allocator.free(resolved_arch_z);

        self.check("add_arch", rawLibalpm.alpm_option_add_architecture(h, resolved_arch_z.ptr));
        self.check("add_arch_any", rawLibalpm.alpm_option_add_architecture(h, "any"));

        var registered_arches: std.ArrayList([]const u8) = .empty;
        defer {
            for (registered_arches.items) |a| self.allocator.free(a);
            registered_arches.deinit(self.allocator);
        }

        for (config.repositories.items) |repo| {
            self.registerRepository(repo, resolved_arch_z, &registered_arches);
        }
    }

    fn check(self: *Manager, what: [:0]const u8, ret: c_int) void {
        if (ret != 0) {
            std.log.warn("alpm option '{s}' failed: {s}", .{
                what,
                std.mem.span(rawLibalpm.alpm_strerror(rawLibalpm.alpm_errno(self.handle))),
            });
        }
    }

    fn resolveArchitecture(architecture: []const u8) []const u8 {
        var it = std.mem.tokenizeScalar(u8, architecture, ' ');
        const first = it.next() orelse "auto";
        if (std.ascii.eqlIgnoreCase(first, "auto")) {
            return switch (builtin.cpu.arch) {
                .x86_64 => "x86_64",
                .aarch64 => "aarch64",
                else => "x86_64",
            };
        }
        return first;
    }

    fn registerRepository(
        self: *Manager,
        repo: configuration.Configuration.Repository,
        resolved_arch: []const u8,
        registered_arches: *std.ArrayList([]const u8),
    ) void {
        const use_default: u32 = @intFromEnum(libalpm.SigLevel.use_default);
        const effective_sig: c_int = if (repo.sig_level == 0 or repo.sig_level == use_default)
            @intCast(self.config.signature_level)
        else
            @intCast(repo.sig_level);

        // alpm copies the treename, so a temporary null-terminated name is fine.
        const name_z = self.allocator.dupeZ(u8, repo.name) catch return;
        defer self.allocator.free(name_z);

        const db = rawLibalpm.alpm_register_syncdb(self.handle, name_z.ptr, effective_sig) orelse {
            std.log.err("alpm_register_syncdb('{s}') failed: {s}", .{
                repo.name,
                std.mem.span(rawLibalpm.alpm_strerror(rawLibalpm.alpm_errno(self.handle))),
            });
            return;
        };

        if (repo.usage != 0) {
            self.check("db_set_usage", rawLibalpm.alpm_db_set_usage(db, @intCast(repo.usage)));
        }

        for (repo.servers.items) |server| {
            self.registerMicroArchitectures(server, resolved_arch, registered_arches);

            const resolved = self.resolveServer(server, repo.name, resolved_arch) orelse continue;
            defer self.allocator.free(resolved);
            self.check("db_add_server", rawLibalpm.alpm_db_add_server(db, resolved.ptr));
        }

        self.sync_dbs.append(self.allocator, .{ .ptr = db }) catch {};
    }

    fn registerMicroArchitectures(
        self: *Manager,
        server: []const u8,
        resolved_arch: []const u8,
        registered_arches: *std.ArrayList([]const u8),
    ) void {
        const marker = "$arch";
        const marker_idx = std.mem.indexOf(u8, server, marker) orelse return;
        const after = server[marker_idx + marker.len ..];
        const suffix_end = std.mem.indexOfScalar(u8, after, '/') orelse after.len;
        const suffix = after[0..suffix_end];

        const v_idx = std.mem.indexOfScalar(u8, suffix, 'v') orelse return;
        const level = std.fmt.parseInt(u8, suffix[v_idx + 1 ..], 10) catch return;

        var i: u8 = level;
        while (i >= 2) : (i -= 1) {
            const arch_name = std.fmt.allocPrint(self.allocator, "{s}_v{d}", .{ resolved_arch, i }) catch return;

            var already = false;
            for (registered_arches.items) |a| {
                if (std.mem.eql(u8, a, arch_name)) {
                    already = true;
                    break;
                }
            }
            if (already) {
                self.allocator.free(arch_name);
                continue;
            }

            const arch_z = self.allocator.dupeZ(u8, arch_name) catch {
                self.allocator.free(arch_name);
                return;
            };
            defer self.allocator.free(arch_z);

            self.check("add_arch", rawLibalpm.alpm_option_add_architecture(self.handle, arch_z.ptr));
            registered_arches.append(self.allocator, arch_name) catch self.allocator.free(arch_name);
        }
    }

    fn resolveServer(self: *Manager, template: []const u8, repo_name: []const u8, resolved_arch: []const u8) ?[:0]const u8 {
        const step1 = std.mem.replaceOwned(u8, self.allocator, template, "$repo", repo_name) catch return null;
        defer self.allocator.free(step1);
        const step2 = std.mem.replaceOwned(u8, self.allocator, step1, "$arch", resolved_arch) catch return null;
        defer self.allocator.free(step2);
        return self.allocator.dupeZ(u8, step2) catch null;
    }
};

test "hi" {
    try std.testing.expectEqualStrings("test", "test");
}
