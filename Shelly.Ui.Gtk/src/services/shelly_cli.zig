const std = @import("std");
const Io = std.Io;

pub const ShellyCli = struct {
    allocator: std.mem.Allocator,
    io: Io,

    pub const Package = struct {
        Name: []const u8 = "",
        Version: []const u8 = "",
        Size: i64 = 0,
        Description: []const u8 = "",
        Url: ?[]const u8 = null,
        Repository: []const u8 = "",
        Replaces: []const []const u8 = &.{},
        Licenses: []const []const u8 = &.{},
        Groups: []const []const u8 = &.{},
        Provides: []const []const u8 = &.{},
        Depends: []const []const u8 = &.{},
        OptDepends: []const []const u8 = &.{},
        Conflicts: []const []const u8 = &.{},
        PackageFile: ?FileNode = null,
        InstallReason: []const u8 = "",
        BuildDate: []const u8 = "",
        InstallDate: ?[]const u8 = null,
        DownloadSize: i64 = 0,
        InstalledSize: i64 = 0,
        RequiredBy: []const []const u8 = &.{},
        OptionalFor: []const []const u8 = &.{},
    };

    const FileNode = struct { Name: []const u8, Files: []const FileNode };

    pub fn get_packages(self: ShellyCli) !std.json.Parsed([]Package) {
        const result = try std.process.run(self.allocator, self.io, .{
            .argv = &.{ "shelly", "-SQ", "--json", "--take", "30000" },
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term != .exited or result.term.exited != 0) {
            std.debug.print("failed: {s}\n", .{result.stderr});
            return error.CommandFailed;
        }

        return std.json.parseFromSlice([]Package, self.allocator, result.stdout, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
    }
};

test "get_packages" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();

    const cli: ShellyCli = .{ .allocator = std.testing.allocator, .io = threaded.io() };

    const parsed = try cli.get_packages();

    defer parsed.deinit();

    try std.testing.expect(parsed.value.len > 0);
    std.debug.print("{s} {s}\n", .{ parsed.value[0].Name, parsed.value[0].Version });
}
