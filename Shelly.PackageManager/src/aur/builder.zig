const std = @import("std");

pub const ProcessResult = struct {
    exit_code: u8,
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(self: *ProcessResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        self.* = undefined;
    }
};

pub const OwnedCommand = struct {
    argv: [][]u8,

    pub fn deinit(self: *OwnedCommand, allocator: std.mem.Allocator) void {
        for (self.argv) |argument| allocator.free(argument);
        allocator.free(self.argv);
        self.* = undefined;
    }

    pub fn asConst(self: *const OwnedCommand) []const []const u8 {
        return @ptrCast(self.argv);
    }
};

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    working_directory: ?[]const u8,
    timeout_seconds: ?u32,
) !ProcessResult {
    return runWithEnvironmentMap(allocator, io, argv, working_directory, timeout_seconds, null);
}

pub fn runWithEnvironment(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    argv: []const []const u8,
    working_directory: ?[]const u8,
    timeout_seconds: ?u32,
) !ProcessResult {
    var environ_map = try executionEnvironment(allocator, environ);
    defer environ_map.deinit();
    return runWithEnvironmentMap(allocator, io, argv, working_directory, timeout_seconds, &environ_map);
}

fn runWithEnvironmentMap(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    working_directory: ?[]const u8,
    timeout_seconds: ?u32,
    environ_map: ?*const std.process.Environ.Map,
) !ProcessResult {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .cwd = if (working_directory) |path| .{ .path = path } else .inherit,
        .environ_map = environ_map,
        .stdout_limit = .limited(16 * 1024 * 1024),
        .stderr_limit = .limited(16 * 1024 * 1024),
        .timeout = if (timeout_seconds) |seconds|
            .{ .duration = .fromSeconds(seconds) }
        else
            .none,
    });
    return .{
        .exit_code = switch (result.term) {
            .exited => |code| code,
            else => 255,
        },
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

pub fn executionEnvironment(allocator: std.mem.Allocator, environ: std.process.Environ) !std.process.Environ.Map {
    var environ_map = try environ.createMap(allocator);
    errdefer environ_map.deinit();
    const path = try buildExecutionPath(allocator, environ);
    defer allocator.free(path);
    try environ_map.put("PATH", path);
    return environ_map;
}

pub fn buildExecutionPath(allocator: std.mem.Allocator, environ: std.process.Environ) ![]u8 {
    const default_path = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/bin";
    const path = environ.getPosix("PATH") orelse default_path;
    if (std.mem.indexOf(u8, path, "core_perl") != null) return allocator.dupe(u8, path);
    return std.fmt.allocPrint(
        allocator,
        "/usr/bin/core_perl:/usr/bin/vendor_perl:/usr/bin/site_perl:{s}",
        .{path},
    );
}

pub fn resolveUsernameForUidFromPasswd(uid: []const u8, passwd: []const u8) []const u8 {
    if (uid.len == 0) return uid;
    var lines = std.mem.splitScalar(u8, passwd, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        var fields = std.mem.splitScalar(u8, trimmed, ':');
        const username = fields.next() orelse continue;
        _ = fields.next() orelse continue;
        const field_uid = fields.next() orelse continue;
        if (std.mem.eql(u8, uid, field_uid)) return username;
    }
    return uid;
}

pub fn resolveUsernameForUid(
    allocator: std.mem.Allocator,
    io: std.Io,
    uid: []const u8,
) ![]u8 {
    if (uid.len == 0) return allocator.dupe(u8, uid);
    const passwd = std.Io.Dir.cwd().readFileAlloc(io, "/etc/passwd", allocator, .limited(4 * 1024 * 1024)) catch
        return allocator.dupe(u8, uid);
    defer allocator.free(passwd);
    return allocator.dupe(u8, resolveUsernameForUidFromPasswd(uid, passwd));
}

pub fn invokingUserCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    command: []const u8,
    arguments: []const []const u8,
) !OwnedCommand {
    var argv: std.ArrayList([]u8) = .empty;
    errdefer {
        for (argv.items) |argument| allocator.free(argument);
        argv.deinit(allocator);
    }

    if (environ.getPosix("SUDO_USER")) |sudo_user| {
        try appendOwned(allocator, &argv, &.{ "sudo", "--preserve-env=PATH", "-u", sudo_user, command });
    } else if (environ.getPosix("PKEXEC_UID")) |uid| {
        const username = try resolveUsernameForUid(allocator, io, uid);
        defer allocator.free(username);
        try appendOwned(allocator, &argv, &.{ "runuser", "-u", username, "-w", "PATH", "--", command });
    } else try appendOwned(allocator, &argv, &.{command});

    try appendOwned(allocator, &argv, arguments);
    return .{ .argv = try argv.toOwnedSlice(allocator) };
}

fn appendOwned(allocator: std.mem.Allocator, list: *std.ArrayList([]u8), values: []const []const u8) !void {
    for (values) |value| try list.append(allocator, try allocator.dupe(u8, value));
}

pub fn makepkgCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    use_chroot: bool,
    chroot_path: []const u8,
    no_check: bool,
) !OwnedCommand {
    if (use_chroot) {
        var argv: std.ArrayList([]u8) = .empty;
        errdefer {
            for (argv.items) |argument| allocator.free(argument);
            argv.deinit(allocator);
        }
        try appendOwned(allocator, &argv, &.{ "makechrootpkg", "-c", "-r", chroot_path });
        if (environ.getPosix("SUDO_USER")) |user| {
            try appendOwned(allocator, &argv, &.{ "-U", user });
        } else if (environ.getPosix("PKEXEC_UID")) |uid| {
            const user = try resolveUsernameForUid(allocator, io, uid);
            defer allocator.free(user);
            if (user.len != 0) try appendOwned(allocator, &argv, &.{ "-U", user });
        }
        return .{ .argv = try argv.toOwnedSlice(allocator) };
    }

    const base = [_][]const u8{ "-f", "-c", "-s", "--noconfirm", "--needed", "--skippgpcheck" };
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    try args.appendSlice(allocator, &base);
    if (no_check) try args.append(allocator, "--nocheck");
    return invokingUserCommand(allocator, io, environ, "makepkg", args.items);
}

pub const BuildProgress = struct {
    percent: u8,
    message: []const u8,
};

pub fn parseBuildProgress(line: []const u8) ?BuildProgress {
    const open = std.mem.indexOfScalar(u8, line, '[') orelse return null;
    const percent_sign = std.mem.indexOfPos(u8, line, open + 1, "%") orelse return null;
    const close = std.mem.indexOfPos(u8, line, percent_sign + 1, "]") orelse return null;
    const percent_text = std.mem.trim(u8, line[open + 1 .. percent_sign], " \t");
    const percent = std.fmt.parseInt(u8, percent_text, 10) catch return null;
    if (percent > 100) return null;
    return .{
        .percent = percent,
        .message = std.mem.trim(u8, line[close + 1 ..], " \t"),
    };
}

pub fn selectBuiltPackageFiles(
    allocator: std.mem.Allocator,
    io: std.Io,
    directory_path: []const u8,
    package_name: []const u8,
) ![][]u8 {
    var directory = std.Io.Dir.cwd().openDir(io, directory_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return allocator.alloc([]u8, 0),
        else => return err,
    };
    defer directory.close(io);
    var iterator = directory.iterate();
    var paths: std.ArrayList([]u8) = .empty;
    errdefer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
    }
    const prefix = try std.fmt.allocPrint(allocator, "{s}-", .{package_name});
    defer allocator.free(prefix);
    var has_named_match = false;
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!isBuiltPackageFile(entry.name)) continue;
        if (std.mem.startsWith(u8, entry.name, prefix)) has_named_match = true;
        try paths.append(allocator, try std.fs.path.join(allocator, &.{ directory_path, entry.name }));
    }
    if (paths.items.len > 1 and !has_named_match) {
        for (paths.items) |path| allocator.free(path);
        paths.clearRetainingCapacity();
    }
    return paths.toOwnedSlice(allocator);
}

pub fn isBuiltPackageFile(file_name: []const u8) bool {
    return isPackageArchiveArtifact(file_name) and
        !std.mem.endsWith(u8, file_name, ".sig");
}

pub fn isPackageArchiveArtifact(file_name: []const u8) bool {
    return std.mem.indexOf(u8, file_name, ".pkg.tar.") != null;
}

pub fn deinitPaths(allocator: std.mem.Allocator, paths: []const []u8) void {
    for (paths) |path| allocator.free(path);
    allocator.free(paths);
}

pub fn cleanBuildArtifacts(io: std.Io, temp_path: []const u8) void {
    for ([_][]const u8{ "src", "pkg" }) |name| {
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&buffer, "{s}/{s}", .{ temp_path, name }) catch continue;
        std.Io.Dir.cwd().deleteTree(io, path) catch {};
    }
}

test "build progress parser recognizes makepkg percentage lines" {
    const progress = parseBuildProgress("[ 42%] Compiling source files").?;
    try std.testing.expectEqual(@as(u8, 42), progress.percent);
    try std.testing.expectEqualStrings("Compiling source files", progress.message);
    try std.testing.expect(parseBuildProgress("ordinary output") == null);
}

test "execution PATH adds Arch Perl paths exactly once" {
    const path = try buildExecutionPath(std.testing.allocator, std.testing.environ);
    defer std.testing.allocator.free(path);
    try std.testing.expect(std.mem.indexOf(u8, path, "/usr/bin/core_perl") != null);

    var environ_map = try executionEnvironment(std.testing.allocator, std.testing.environ);
    defer environ_map.deinit();
    try std.testing.expectEqualStrings(path, environ_map.get("PATH").?);
}

test "UID lookup and VCS build commands replicate invoking-user behavior" {
    const passwd = "root:x:0:0::/root:/bin/bash\nzoey:x:1000:1000::/home/zoey:/bin/bash\n";
    try std.testing.expectEqualStrings("zoey", resolveUsernameForUidFromPasswd("1000", passwd));
    try std.testing.expectEqualStrings("55", resolveUsernameForUidFromPasswd("55", passwd));

    var command = try makepkgCommand(
        std.testing.allocator,
        std.testing.io,
        std.testing.environ,
        false,
        "/var/lib/shelly/chroot",
        true,
    );
    defer command.deinit(std.testing.allocator);
    var found_nocheck = false;
    for (command.argv) |argument| {
        if (std.mem.eql(u8, argument, "--nocheck")) found_nocheck = true;
    }
    try std.testing.expect(found_nocheck);
}

test "built package selection mirrors split-package and stale-output safeguards" {
    var matching = std.testing.tmpDir(.{});
    defer matching.cleanup();
    try matching.dir.writeFile(std.testing.io, .{ .sub_path = "demo-1-1-x86_64.pkg.tar.zst", .data = "" });
    try matching.dir.writeFile(std.testing.io, .{ .sub_path = "demo-docs-1-1-any.pkg.tar.zst", .data = "" });
    try matching.dir.writeFile(std.testing.io, .{ .sub_path = "demo-1-1-x86_64.pkg.tar.zst.sig", .data = "" });
    const matching_path = try matching.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(matching_path);
    const split_files = try selectBuiltPackageFiles(std.testing.allocator, std.testing.io, matching_path, "demo");
    defer deinitPaths(std.testing.allocator, split_files);
    try std.testing.expectEqual(@as(usize, 2), split_files.len);

    var ambiguous = std.testing.tmpDir(.{});
    defer ambiguous.cleanup();
    try ambiguous.dir.writeFile(std.testing.io, .{ .sub_path = "one-1-1-any.pkg.tar.zst", .data = "" });
    try ambiguous.dir.writeFile(std.testing.io, .{ .sub_path = "two-1-1-any.pkg.tar.zst", .data = "" });
    const ambiguous_path = try ambiguous.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(ambiguous_path);
    const no_match = try selectBuiltPackageFiles(std.testing.allocator, std.testing.io, ambiguous_path, "demo");
    defer deinitPaths(std.testing.allocator, no_match);
    try std.testing.expectEqual(@as(usize, 0), no_match.len);

    try std.testing.expect(isBuiltPackageFile("demo.pkg.tar.zst"));
    try std.testing.expect(!isBuiltPackageFile("demo.pkg.tar.zst.sig"));
    try std.testing.expect(isPackageArchiveArtifact("demo.pkg.tar.zst.sig"));
}
