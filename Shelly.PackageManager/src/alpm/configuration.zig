const std = @import("std");
const Io = std.Io;
const Bindings = @import("bindings.zig");
const Allocator = std.mem.Allocator;

const equalIgnoreCase = std.ascii.eqlIgnoreCase;

pub const Configuration = struct {
    pub const Repository = struct {
        name: []const u8,
        servers: std.ArrayList([]const u8) = .empty,
        sig_level: Bindings.libalpm.SigLevel = .use_default,
    };

    pub const Config = struct {
        arena: std.heap.ArenaAllocator,

        root_directory: []const u8,
        database_path: []const u8,
        cache_directory: []const u8,
        log_file: []const u8,
        gpg_directory: []const u8,
        hook_directory: std.ArrayList([]const u8),
        hold_packages: std.ArrayList([]const u8),
        transfer_command: []const u8,
        transfer_command_two: []const u8,
        use_delta: f64,
        architecture: []const u8,
        ignore_package: std.ArrayList([]const u8),
        ignore_group: std.ArrayList([]const u8),
        no_upgrade: std.ArrayList([]const u8),
        no_extract: std.ArrayList([]const u8),
        use_system_log: bool,
        check_space: bool,
        repositories: std.ArrayList(Repository),
        signature_level: Bindings.libalpm.SigLevel,
        local_file_signature_level: Bindings.libalpm.SigLevel,
        remote_file_signature_level: Bindings.libalpm.SigLevel,

        pub fn initialize_with_defaults(alloc: Allocator) Allocator.Error!Config {
            var conf = Config{
                .arena = std.heap.ArenaAllocator.init(alloc),
                .root_directory = "/",
                .database_path = "/var/lib/pacman",
                .cache_directory = "/var/cache/pacman/pkg",
                .log_file = "/var/log/shelly.log",
                .gpg_directory = "/etc/pacman.d/gnupg",
                .hook_directory = .empty,
                .hold_packages = .empty,
                .transfer_command = "/usr/bin/curl -L -C - -f -o %o %u",
                .transfer_command_two = "/usr/bin/wget --passive-ftp -c -O %o %u",
                .use_delta = 0.7,
                .architecture = "auto",
                .ignore_package = .empty,
                .ignore_group = .empty,
                .no_upgrade = .empty,
                .no_extract = .empty,
                .use_system_log = false,
                .check_space = false,
                .repositories = .empty,
                .signature_level = .package | .database_optional,
                .local_file_signature_level = .package_optional | .database_optional,
                .remote_file_signature_level = .package | .database,
            };
            const aa = conf.arena.allocator();
            try conf.hook_directory.append(aa, "/usr/share/libalpm/hooks");
            try conf.hook_directory.append(aa, "/etc/pacman.d/hooks");
            try conf.hold_packages.append(aa, "pacman");
            try conf.hold_packages.append(aa, "glibc");
            try conf.hold_packages.append(aa, "shelly");
            return conf;
        }

        pub fn deinitialize(self: *Config) void {
            self.arena.deinit();
        }
    };
};
