const std = @import("std");

const alpm_bindings = @import("../alpm/bindings.zig");
const alpm_configuration = @import("../alpm/configuration.zig");
const AlpmManager = @import("../alpm/manager.zig").Manager;

const SigLevel = alpm_bindings.libalpm.SigLevel;
const DatabaseUsage = alpm_bindings.libalpm.DatabaseUsage;

pub const Error = error{
    ForbiddenMakepkgArgument,
    InvalidConfigurationValue,
    InvalidOperationDirectory,
    MissingBootstrapFile,
    MissingBuildArtifact,
    NoRepositories,
    OperationDirectoryNotEmpty,
    ProcessFailed,
};

pub const Layout = struct {
    allocator: std.mem.Allocator,
    operation: []u8,
    root: []u8,
    config_directory: []u8,
    alpm_config: []u8,
    database: []u8,
    package_cache: []u8,
    log: []u8,
    build: []u8,
    build_home: []u8,
    artifacts: []u8,
    source_cache: []u8,
    source_package_cache: []u8,
    build_logs: []u8,
    makepkg_config_host: []u8,
    phase0_build_host: []u8,

    pub fn init(allocator: std.mem.Allocator, operation_directory: []const u8) !Layout {
        if (!std.fs.path.isAbsolute(operation_directory) or
            std.mem.indexOfAny(u8, operation_directory, "\r\n") != null)
            return Error.InvalidOperationDirectory;
        const operation = try std.fs.path.resolve(allocator, &.{operation_directory});
        errdefer allocator.free(operation);
        if (std.mem.eql(u8, operation, "/"))
            return Error.InvalidOperationDirectory;

        const root = try join(allocator, &.{ operation, "root" });
        errdefer allocator.free(root);
        const config_directory = try join(allocator, &.{ operation, "config" });
        errdefer allocator.free(config_directory);
        const alpm_config = try join(allocator, &.{ config_directory, "alpm.conf" });
        errdefer allocator.free(alpm_config);
        const database = try join(allocator, &.{ root, "var/lib/shelly/alpm" });
        errdefer allocator.free(database);
        const package_cache = try join(allocator, &.{ root, "var/cache/shelly/pkg" });
        errdefer allocator.free(package_cache);
        const log = try join(allocator, &.{ root, "var/log/shelly.log" });
        errdefer allocator.free(log);
        const build = try join(allocator, &.{ root, "build" });
        errdefer allocator.free(build);
        const build_home = try join(allocator, &.{ root, "home/shelly-build" });
        errdefer allocator.free(build_home);
        const artifacts = try join(allocator, &.{ root, "var/lib/shelly/artifacts" });
        errdefer allocator.free(artifacts);
        const source_cache = try join(allocator, &.{ root, "var/cache/shelly/sources" });
        errdefer allocator.free(source_cache);
        const source_package_cache = try join(allocator, &.{ root, "var/cache/shelly/srcpackages" });
        errdefer allocator.free(source_package_cache);
        const build_logs = try join(allocator, &.{ root, "var/log/shelly-build" });
        errdefer allocator.free(build_logs);
        const makepkg_config_host = try join(allocator, &.{ root, "etc/shelly-phase0-makepkg.conf" });
        errdefer allocator.free(makepkg_config_host);
        const phase0_build_host = try join(allocator, &.{ build, "phase0" });
        errdefer allocator.free(phase0_build_host);

        return .{
            .allocator = allocator,
            .operation = operation,
            .root = root,
            .config_directory = config_directory,
            .alpm_config = alpm_config,
            .database = database,
            .package_cache = package_cache,
            .log = log,
            .build = build,
            .build_home = build_home,
            .artifacts = artifacts,
            .source_cache = source_cache,
            .source_package_cache = source_package_cache,
            .build_logs = build_logs,
            .makepkg_config_host = makepkg_config_host,
            .phase0_build_host = phase0_build_host,
        };
    }

    pub fn deinit(self: *Layout) void {
        const allocator = self.allocator;
        allocator.free(self.operation);
        allocator.free(self.root);
        allocator.free(self.config_directory);
        allocator.free(self.alpm_config);
        allocator.free(self.database);
        allocator.free(self.package_cache);
        allocator.free(self.log);
        allocator.free(self.build);
        allocator.free(self.build_home);
        allocator.free(self.artifacts);
        allocator.free(self.source_cache);
        allocator.free(self.source_package_cache);
        allocator.free(self.build_logs);
        allocator.free(self.makepkg_config_host);
        allocator.free(self.phase0_build_host);
        self.* = undefined;
    }

    pub fn create(self: *const Layout, io: std.Io) !void {
        try requireEmptyOrMissingDirectory(io, self.operation);
        for ([_][]const u8{
            self.root,
            self.config_directory,
            self.database,
            self.package_cache,
            self.build,
            self.build_home,
            self.artifacts,
            self.source_cache,
            self.source_package_cache,
            self.build_logs,
            self.phase0_build_host,
        }) |path| try std.Io.Dir.cwd().createDirPath(io, path);

        const log_parent = std.fs.path.dirname(self.log) orelse
            return Error.InvalidOperationDirectory;
        try std.Io.Dir.cwd().createDirPath(io, log_parent);
    }
};

pub const SpikeOptions = struct {
    host_alpm_config: []const u8 = "/etc/pacman.conf",
    host_makepkg_config: []const u8 = "/etc/makepkg.conf",
    bootstrap_only: bool = false,
};

pub const SpikeResult = struct {
    artifact_count: usize,
};

pub const makepkg_arguments = [_][]const u8{
    "makepkg",
    "--config",
    "/etc/shelly-phase0-makepkg.conf",
    "-f",
    "-c",
    "--noconfirm",
    "--nocheck",
};

const phase0_pkgbuild =
    \\pkgname=shelly-phase0-probe
    \\pkgver=1
    \\pkgrel=1
    \\pkgdesc='Shelly isolated build-root feasibility probe'
    \\arch=('any')
    \\license=('GPL-3.0-only')
    \\source=()
    \\sha256sums=()
    \\
    \\package() {
    \\  install -Dm644 /dev/null \
    \\    "$pkgdir/usr/share/shelly-phase0-probe/installed"
    \\}
    \\
;

pub fn runPhase0Spike(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    operation_directory: []const u8,
    options: SpikeOptions,
) !SpikeResult {
    try validateMakepkgArguments(&makepkg_arguments);

    var layout = try Layout.init(allocator, operation_directory);
    defer layout.deinit();
    try layout.create(io);

    var source_config = try alpm_configuration.Configuration.parse(
        allocator,
        io,
        options.host_alpm_config,
    );
    defer source_config.deinitialize();
    var has_repository = false;
    for (source_config.repositories.items) |repository| {
        if (repository.servers.items.len != 0) {
            has_repository = true;
            break;
        }
    }
    if (!has_repository) return Error.NoRepositories;

    const generated_config = try renderIsolatedConfig(allocator, &source_config, &layout);
    defer allocator.free(generated_config);
    try writeFile(io, layout.alpm_config, generated_config, 0o600);

    std.debug.print("phase0: synchronizing isolated repositories\n", .{});
    {
        const manager = try AlpmManager.init(
            allocator,
            environ,
            layout.alpm_config,
            true,
            null,
        );
        defer manager.deinit();
        try manager.sync(false);

        std.debug.print("phase0: installing bootstrap packages with Shelly/libalpm\n", .{});
        var bootstrap_targets = [_][:0]const u8{
            "base-devel",
            "git",
            "gnupg",
            "ca-certificates",
            "shadow",
        };
        try manager.install_packages(&bootstrap_targets, .{ .alldeps = true, .needed = true });
    }

    try validateBootstrap(io, &layout);
    if (options.bootstrap_only) return .{ .artifact_count = 0 };

    try prepareBuildProbe(allocator, io, &layout, options.host_makepkg_config);
    try createBuildUser(io, layout.root);
    try assignBuildOwnership(io, layout.root);
    try runMakepkgProbe(io, layout.root);
    try validateGuestOwnership(io, layout.root);

    const artifact_count = try countArtifacts(io, layout.artifacts);
    if (artifact_count == 0) return Error.MissingBuildArtifact;
    return .{ .artifact_count = artifact_count };
}

pub fn renderIsolatedConfig(
    allocator: std.mem.Allocator,
    source: *const alpm_configuration.Configuration.Config,
    layout: *const Layout,
) ![]u8 {
    for ([_][]const u8{
        layout.root,
        layout.database,
        layout.package_cache,
        layout.log,
        source.gpg_directory,
        source.architecture,
    }) |value| try validateConfigurationValue(value);

    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    const writer = &output.writer;

    try writer.writeAll(
        "# Generated by Shelly's isolated build-root phase-0 spike.\n" ++
            "# Package transactions use Shelly/libalpm; no package-manager frontend is invoked.\n\n" ++
            "[options]\n",
    );
    try writer.print("RootDir = {s}\n", .{layout.root});
    try writer.print("DBPath = {s}\n", .{layout.database});
    try writer.print("CacheDir = {s}\n", .{layout.package_cache});
    try writer.print("LogFile = {s}\n", .{layout.log});
    try writer.print("GPGDir = {s}\n", .{source.gpg_directory});
    try writer.print("Architecture = {s}\n", .{source.architecture});
    if (source.check_space) try writer.writeAll("CheckSpace\n");
    try writeSignatureLevel(writer, "SigLevel", source.signature_level);
    try writeSignatureLevel(writer, "LocalFileSigLevel", source.local_file_signature_level);
    try writeSignatureLevel(writer, "RemoteFileSigLevel", source.remote_file_signature_level);

    for (source.repositories.items) |repository| {
        try validateConfigurationValue(repository.name);
        if (repository.servers.items.len == 0) continue;
        try writer.print("\n[{s}]\n", .{repository.name});
        for (repository.servers.items) |server| {
            try validateConfigurationValue(server);
            try writer.print("Server = {s}\n", .{server});
        }
        try writeSignatureLevel(writer, "SigLevel", repository.sig_level);
        try writeUsage(writer, repository.usage);
    }

    return output.toOwnedSlice();
}

pub fn validateMakepkgArguments(arguments: []const []const u8) Error!void {
    for (arguments) |argument| {
        if (std.mem.eql(u8, argument, "-s") or
            std.mem.eql(u8, argument, "--syncdeps") or
            std.mem.eql(u8, argument, "-i") or
            std.mem.eql(u8, argument, "--install") or
            std.mem.startsWith(u8, argument, "--syncdeps=") or
            std.mem.startsWith(u8, argument, "--install="))
            return Error.ForbiddenMakepkgArgument;
        if (argument.len > 1 and argument[0] == '-' and argument[1] != '-') {
            for (argument[1..]) |short_option| {
                if (short_option == 's' or short_option == 'i')
                    return Error.ForbiddenMakepkgArgument;
            }
        }
    }
}

fn prepareBuildProbe(
    allocator: std.mem.Allocator,
    io: std.Io,
    layout: *const Layout,
    host_makepkg_config: []const u8,
) !void {
    const source = try std.Io.Dir.cwd().readFileAlloc(
        io,
        host_makepkg_config,
        allocator,
        .limited(4 * 1024 * 1024),
    );
    defer allocator.free(source);

    var config: std.Io.Writer.Allocating = .init(allocator);
    defer config.deinit();
    try config.writer.writeAll(source);
    if (source.len != 0 and source[source.len - 1] != '\n') try config.writer.writeByte('\n');
    try config.writer.writeAll(
        "\n# Shelly phase-0 isolation overrides.\n" ++
            "PACMAN=/usr/bin/false\n" ++
            "PKGDEST=/var/lib/shelly/artifacts\n" ++
            "SRCDEST=/var/cache/shelly/sources\n" ++
            "SRCPKGDEST=/var/cache/shelly/srcpackages\n" ++
            "LOGDEST=/var/log/shelly-build\n" ++
            "BUILDDIR=/build/.makepkg\n",
    );
    try writeFile(io, layout.makepkg_config_host, config.written(), 0o644);

    const pkgbuild_path = try join(allocator, &.{ layout.phase0_build_host, "PKGBUILD" });
    defer allocator.free(pkgbuild_path);
    try writeFile(io, pkgbuild_path, phase0_pkgbuild, 0o644);
}

fn createBuildUser(io: std.Io, root: []const u8) !void {
    try runInherited(io, &.{
        "systemd-nspawn",
        "--directory",
        root,
        "--register=no",
        "--quiet",
        "useradd",
        "--create-home",
        "--user-group",
        "--shell",
        "/usr/bin/bash",
        "shelly-build",
    });
}

fn assignBuildOwnership(io: std.Io, root: []const u8) !void {
    try runInherited(io, &.{
        "systemd-nspawn",
        "--directory",
        root,
        "--register=no",
        "--quiet",
        "chown",
        "-R",
        "shelly-build:shelly-build",
        "/build",
        "/home/shelly-build",
        "/var/lib/shelly/artifacts",
        "/var/cache/shelly/sources",
        "/var/cache/shelly/srcpackages",
        "/var/log/shelly-build",
    });
}

fn runMakepkgProbe(io: std.Io, root: []const u8) !void {
    var arguments: [makepkg_arguments.len + 12][]const u8 = undefined;
    const prefix = [_][]const u8{
        "systemd-nspawn",
        "--directory",
        root,
        "--register=no",
        "--quiet",
        "--user",
        "shelly-build",
        "--chdir",
        "/build/phase0",
        "--setenv",
        "HOME=/home/shelly-build",
        "--",
    };
    @memcpy(arguments[0..prefix.len], &prefix);
    @memcpy(arguments[prefix.len..], &makepkg_arguments);
    try runInherited(io, &arguments);
}

fn validateGuestOwnership(io: std.Io, root: []const u8) !void {
    try runInherited(io, &.{
        "systemd-nspawn",
        "--directory",
        root,
        "--register=no",
        "--quiet",
        "--user",
        "shelly-build",
        "--",
        "/usr/bin/bash",
        "-c",
        "set -- /var/lib/shelly/artifacts/*.pkg.tar.*; [ -f \"$1\" ] && [ -O \"$1\" ]",
    });
}

fn runInherited(io: std.Io, arguments: []const []const u8) !void {
    var child = try std.process.spawn(io, .{
        .argv = arguments,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    errdefer child.kill(io);
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) return Error.ProcessFailed,
        else => return Error.ProcessFailed,
    }
}

fn validateBootstrap(io: std.Io, layout: *const Layout) !void {
    for ([_][]const u8{
        "usr/bin/bash",
        "usr/bin/makepkg",
        "usr/bin/fakeroot",
        "usr/bin/git",
        "usr/bin/useradd",
        "var/lib/shelly/alpm/local",
        "usr/share/libalpm/hooks",
    }) |relative| {
        const path = try join(layout.allocator, &.{ layout.root, relative });
        defer layout.allocator.free(path);
        _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch
            return Error.MissingBootstrapFile;
    }
}

fn countArtifacts(io: std.Io, directory_path: []const u8) !usize {
    var directory = try std.Io.Dir.cwd().openDir(io, directory_path, .{ .iterate = true });
    defer directory.close(io);
    var iterator = directory.iterate();
    var count: usize = 0;
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file or
            std.mem.indexOf(u8, entry.name, ".pkg.tar.") == null or
            std.mem.endsWith(u8, entry.name, ".sig"))
            continue;
        count += 1;
    }
    return count;
}

fn requireEmptyOrMissingDirectory(io: std.Io, path: []const u8) !void {
    var directory = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            try std.Io.Dir.cwd().createDirPath(io, path);
            return;
        },
        else => return err,
    };
    defer directory.close(io);
    var iterator = directory.iterate();
    if (try iterator.next(io) != null) return Error.OperationDirectoryNotEmpty;
}

fn writeFile(io: std.Io, path: []const u8, content: []const u8, mode: u16) !void {
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = content,
        .flags = .{ .permissions = std.Io.File.Permissions.fromMode(mode) },
    });
}

fn validateConfigurationValue(value: []const u8) Error!void {
    if (value.len == 0 or std.mem.indexOfAny(u8, value, "\r\n") != null)
        return Error.InvalidConfigurationValue;
}

fn writeSignatureLevel(
    writer: *std.Io.Writer,
    directive: []const u8,
    raw_level: u32,
) !void {
    const level: SigLevel = @bitCast(raw_level);
    if (level.use_default) return;

    try writer.print("{s} =", .{directive});
    if (!level.package and !level.database) {
        try writer.writeAll(" Never\n");
        return;
    }

    try writer.writeAll(if (level.package)
        if (level.package_optional) " PackageOptional" else " PackageRequired"
    else
        " PackageNever");
    try writer.writeAll(if (level.database)
        if (level.database_optional) " DatabaseOptional" else " DatabaseRequired"
    else
        " DatabaseNever");
    if (level.package_marginal_ok) try writer.writeAll(" PackageMarginalOK");
    if (level.package_unknown_ok) try writer.writeAll(" PackageUnknownOK");
    if (level.database_marginal_ok) try writer.writeAll(" DatabaseMarginalOK");
    if (level.database_unknown_ok) try writer.writeAll(" DatabaseUnknownOK");
    try writer.writeByte('\n');
}

fn writeUsage(writer: *std.Io.Writer, raw_usage: u32) !void {
    if (raw_usage == 0) return;
    try writer.writeAll("Usage =");
    if (raw_usage & @intFromEnum(DatabaseUsage.sync) != 0) try writer.writeAll(" Sync");
    if (raw_usage & @intFromEnum(DatabaseUsage.search) != 0) try writer.writeAll(" Search");
    if (raw_usage & @intFromEnum(DatabaseUsage.install) != 0) try writer.writeAll(" Install");
    if (raw_usage & @intFromEnum(DatabaseUsage.upgrade) != 0) try writer.writeAll(" Upgrade");
    try writer.writeByte('\n');
}

fn join(allocator: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    return std.fs.path.join(allocator, parts);
}

test "isolated config redirects every mutable ALPM path" {
    var source = try alpm_configuration.Configuration.parse_string(std.testing.allocator, std.testing.io,
        \\[options]
        \\Architecture = x86_64
        \\SigLevel = Required DatabaseOptional
        \\LocalFileSigLevel = Optional
        \\GPGDir = /etc/pacman.d/gnupg
        \\CheckSpace
        \\
        \\[core]
        \\Server = https://mirror.example/$repo/os/$arch
        \\Usage = Sync Search Install Upgrade
        \\
    );
    defer source.deinitialize();
    var layout = try Layout.init(std.testing.allocator, "/tmp/shelly-phase0-unit");
    defer layout.deinit();

    const rendered = try renderIsolatedConfig(std.testing.allocator, &source, &layout);
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "RootDir = /tmp/shelly-phase0-unit/root") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "DBPath = /tmp/shelly-phase0-unit/root/var/lib/shelly/alpm") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "CacheDir = /tmp/shelly-phase0-unit/root/var/cache/shelly/pkg") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[core]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Server = https://mirror.example/$repo/os/$arch") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Usage = Sync Search Install Upgrade") != null);
}

test "phase0 makepkg arguments cannot request dependency or package installation" {
    try validateMakepkgArguments(&makepkg_arguments);
    try std.testing.expectError(
        Error.ForbiddenMakepkgArgument,
        validateMakepkgArguments(&.{ "makepkg", "--syncdeps" }),
    );
    try std.testing.expectError(
        Error.ForbiddenMakepkgArgument,
        validateMakepkgArguments(&.{ "makepkg", "--install" }),
    );
    try std.testing.expectError(
        Error.ForbiddenMakepkgArgument,
        validateMakepkgArguments(&.{ "makepkg", "-csi" }),
    );
}

test "isolated layout rejects the filesystem root" {
    try std.testing.expectError(
        Error.InvalidOperationDirectory,
        Layout.init(std.testing.allocator, "/"),
    );
    try std.testing.expectError(
        Error.InvalidOperationDirectory,
        Layout.init(std.testing.allocator, "relative"),
    );
    try std.testing.expectError(
        Error.InvalidOperationDirectory,
        Layout.init(std.testing.allocator, "/tmp/.."),
    );
}
