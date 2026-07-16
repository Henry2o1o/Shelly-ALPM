const std = @import("std");
const builtin = @import("builtin");
const context_module = @import("context.zig");

pub const Error = error{
    UnsupportedPlatform,
    ElevationFailed,
};

/// Relaunches the current executable through the configured privilege
/// elevator when the process is not already root. A non-null result is the
/// elevated child's exit code and must be returned by the caller immediately.
pub fn relaunchIfNeeded(
    context: *context_module.RuntimeContext,
    arguments: []const []const u8,
) !?u8 {
    if (builtin.os.tag != .linux) return error.UnsupportedPlatform;
    if (std.os.linux.geteuid() == 0) return null;

    const executable = try std.process.executablePathAlloc(context.io, context.allocator);
    defer context.allocator.free(executable);
    const elevator = findElevator(context);
    const elevated_arguments = try buildArguments(context.allocator, elevator, executable, arguments);
    defer context.allocator.free(elevated_arguments);

    var child = try std.process.spawn(context.io, .{
        .argv = elevated_arguments,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    errdefer child.kill(context.io);

    return @as(?u8, try exitCode(try child.wait(context.io)));
}

fn findElevator(context: *const context_module.RuntimeContext) []const u8 {
    if (context.environment) |environment| {
        if (environment.get("SHELLY_ELEVATOR")) |configured| {
            const trimmed = std.mem.trim(u8, configured, " \t\r\n");
            if (trimmed.len > 0) return trimmed;
        }
        if (environment.get("PATH")) |path| {
            if (isOnPath(context, path, "doas")) return "doas";
            if (isOnPath(context, path, "sudo")) return "sudo";
        }
    }
    return "sudo";
}

fn isOnPath(
    context: *const context_module.RuntimeContext,
    path_environment: []const u8,
    executable: []const u8,
) bool {
    var paths = std.mem.splitScalar(u8, path_environment, ':');
    while (paths.next()) |path| {
        if (path.len == 0) continue;
        const candidate = std.fs.path.join(context.allocator, &.{ path, executable }) catch continue;
        defer context.allocator.free(candidate);
        std.Io.Dir.accessAbsolute(context.io, candidate, .{}) catch continue;
        return true;
    }
    return false;
}

fn buildArguments(
    allocator: std.mem.Allocator,
    elevator: []const u8,
    executable: []const u8,
    arguments: []const []const u8,
) ![]const []const u8 {
    const result = try allocator.alloc([]const u8, arguments.len + 2);
    result[0] = elevator;
    result[1] = executable;
    @memcpy(result[2..], arguments);
    return result;
}

fn exitCode(term: std.process.Child.Term) Error!u8 {
    return switch (term) {
        .exited => |code| code,
        .signal => |signal| @truncate(128 + @intFromEnum(signal)),
        .stopped, .unknown => error.ElevationFailed,
    };
}

test "elevated arguments preserve the canonical invocation" {
    const arguments = [_][]const u8{ "sync", "standard", "--force" };
    const elevated = try buildArguments(std.testing.allocator, "doas", "/usr/bin/shelly", &arguments);
    defer std.testing.allocator.free(elevated);

    const expected = [_][]const u8{ "doas", "/usr/bin/shelly", "sync", "standard", "--force" };
    try std.testing.expectEqual(expected.len, elevated.len);
    for (expected, elevated) |wanted, actual| try std.testing.expectEqualStrings(wanted, actual);
}

test "elevation child status maps to shell exit codes" {
    try std.testing.expectEqual(@as(u8, 7), try exitCode(.{ .exited = 7 }));
    try std.testing.expectError(error.ElevationFailed, exitCode(.{ .unknown = 1 }));
}
