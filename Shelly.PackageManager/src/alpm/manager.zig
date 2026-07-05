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
        self.applyConfig(config);
        return self;
    }

    pub fn deinit(self: *Manager) void {
        // NOTE: `self.dispatcher.deinit()` is intentionally not called yet:
        // events.zig still uses the pre-0.16 managed ArrayList API (append/deinit
        // without an allocator) and won't compile until updated.
        if (self.handle) |h| _ = libalpm.alpm.alpm_release(h);
        self.handle = null;
        self.is_initialized = false;
    }

    /// Apply the optional settings from `config` to the live handle. Option
    /// setter failures are logged but non-fatal; the resulting `alpm_errno` is
    /// reported for context.
    fn applyConfig(self: *Manager, config: configuration.Configuration.Config) void {
        const h = self.handle;

        for (config.hook_directory.items) |hooks| {
            self.check("hook_directory", rawLibalpm.alpm_option_add_hookdir(h, hooks.ptr));
        }

        if (config.cache_directory) |v| self.check("cachedir", rawLibalpm.alpm_option_add_cachedir(h, v.ptr));
        if (config.log_file) |v| self.check("logfile", rawLibalpm.alpm_option_set_logfile(h, v.ptr));
        if (config.gpg_dir) |v| self.check("gpgdir", rawLibalpm.alpm_option_set_gpgdir(h, v.ptr));

        for (config.ignore_package.items) |pkgName| {
            self.check("ignore_package", rawLibalpm.alpm_option_add_ignorepkg(h, pkgName.ptr));
        }

        for (config.ignore_group.items) |groupName| {
            self.check("ignore_group", rawLibalpm.alpm_option_add_ignoregroup(h, groupName.ptr));
        }

        if (config.signature_level) |level| {
            self.check("default_sig_level", rawLibalpm.alpm_option_set_default_siglevel(h, level));
        }

        if (config.local_file_signature_level) |level| {
            self.check("local_file_sig_level", rawLibalpm.alpm_option_set_local_file_siglevel(h, level));
        }

        if (config.remote_file_signature_level) |level| {
            self.check("remote_file_sig_level", rawLibalpm.alpm_option_set_remote_file_siglevel(h, level));
        }

        self.check("check_space", rawLibalpm.alpm_option_set_check_space(h, @intFromBool(config.CheckSpace)));
    }

    fn addArchitecture(self: *Manager, arch: [:0]const u8) void {
        var resolved_arch: [:0]const u8 = blk: {
            var it = std.mem.splitScalar([:0]u8, arch, ' ');
            break :blk it.first();
        };

        if (resolved_arch.len == 0) resolved_arch = "auto";

        if (std.ascii.eqlIgnoreCase(resolved_arch, "auto")) {
            resolved_arch = switch (builtin.cpu.arch) {
                .x86_64 => "x86_64",
                .aarch64 => "aarch64",
                else => "x86_64",
            };
        }

        self.check("add_arch", rawLibalpm.alpm_option_add_arch(self.handle, resolved_arch.ptr));
    }

    fn check(self: *Manager, what: [:0]const u8, ret: c_int) void {
        if (ret != 0) {
            std.log.warn("alpm option '{s}' failed: {s}", .{
                what,
                std.mem.span(rawLibalpm.alpm_strerror(rawLibalpm.alpm_errno(self.handle))),
            });
        }
    }

    /// Register a sync database (e.g. "core", "extra") and attach its servers.
    pub fn registerSyncDb(
        self: *Manager,
        name: [:0]const u8,
        servers: []const [:0]const u8,
    ) ConfigError!libalpm.Database {
        const db = rawLibalpm.alpm_register_syncdb(self.handle, name.ptr, rawLibalpm.ALPM_SIG_USE_DEFAULT) orelse {
            std.log.err("alpm_register_syncdb('{s}') failed: {s}", .{
                name,
                std.mem.span(rawLibalpm.alpm_strerror(rawLibalpm.alpm_errno(self.handle))),
            });
            return error.RegisterDbFailed;
        };
        for (servers) |url| {
            self.check("db_add_server", rawLibalpm.alpm_db_add_server(db, url.ptr));
        }
        return db;
    }
};

test "hi" {
    try std.testing.expectEqualStrings("test", "test");
}
