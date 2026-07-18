const std = @import("std");
const Io = std.Io;
const Package = @import("../models/packages.zig").Package;
const Remote = @import("../models/flatpak.zig").Remote;
const Flatpak = @import("../models/flatpak.zig").Flatpak;
const AppstreamApp = @import("../models/flatpak.zig").AppstreamApp;
const FlatpakRemoteInfo = @import("../models/flatpak.zig").FlatpakRemoteInfo;
const CheckUpdates = @import("../models/sync.zig").CheckUpdates;

const RunResult = std.process.RunResult;

fn parse_appstream_apps(allocator: std.mem.Allocator, json: []const u8) !std.json.Parsed([]AppstreamApp) {
    return std.json.parseFromSlice([]AppstreamApp, allocator, json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

pub const ShellyCli = struct {
    allocator: std.mem.Allocator,
    io: Io,

    fn run(self: ShellyCli, args: []const []const u8) !RunResult {
        const result = try std.process.run(self.allocator, self.io, .{ .argv = args });
        errdefer self.allocator.free(result.stdout);
        errdefer self.allocator.free(result.stderr);

        if (result.term != .exited or result.term.exited != 0) {
            std.debug.print("failed: {s}\n", .{result.stderr});
            return error.CommandFailed;
        }
        return result;
    }

    pub fn get_packages(self: ShellyCli) !std.json.Parsed([]Package) {
        const result = try self.run(&.{ "shelly", "-SQ", "--json", "--take", "30000" });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        return std.json.parseFromSlice([]Package, self.allocator, result.stdout, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
    }

    pub fn get_installed_packages(self: ShellyCli) !std.json.Parsed([]Package) {
        const result = try self.run(&.{ "shelly", "-SQi", "--json", "--take", "30000" });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        return std.json.parseFromSlice([]Package, self.allocator, result.stdout, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
    }

    pub fn get_remotes(self: ShellyCli) !std.json.Parsed([]Remote) {
        const result = try self.run(&.{ "shelly", "flatpak", "list-remotes", "--json" });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        return std.json.parseFromSlice([]Remote, self.allocator, result.stdout, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
    }

    pub fn get_installed_flatpaks(self: ShellyCli) !std.json.Parsed([]Flatpak) {
        const result = try self.run(&.{ "shelly", "flatpak", "list", "--json" });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        return std.json.parseFromSlice([]Flatpak, self.allocator, result.stdout, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
    }

    pub fn get_remote_appstream_apps(self: ShellyCli) !std.json.Parsed([]AppstreamApp) {
        const result = try self.run(&.{ "shelly", "flatpak", "get-remote-appstream", "all" });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        return parse_appstream_apps(self.allocator, result.stdout);
    }

    pub fn get_flatpak_remote_info(self: ShellyCli, remote: []const u8, id: []const u8, branch: []const u8) !std.json.Parsed(FlatpakRemoteInfo) {
        const result = try self.run(&.{ "shelly", "flatpak", "app-remote-info", remote, id, branch, "--json" });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        return std.json.parseFromSlice(FlatpakRemoteInfo, self.allocator, result.stdout, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
    }

    pub fn check_updates(self: ShellyCli) !std.json.Parsed(CheckUpdates) {
        const result = try self.run(&.{ "shelly", "check-updates", "-a", "-l", "-j" });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        return std.json.parseFromSlice(CheckUpdates, self.allocator, result.stdout, .{
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

test "get_remotes" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();

    const cli: ShellyCli = .{ .allocator = std.testing.allocator, .io = threaded.io() };

    const parsed = try cli.get_remotes();

    defer parsed.deinit();

    try std.testing.expect(parsed.value.len > 0);
    std.debug.print("{s} {t}\n", .{ parsed.value[0].Name, parsed.value[0].Scope });
}

test "get_flatpaks" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();

    const cli: ShellyCli = .{ .allocator = std.testing.allocator, .io = threaded.io() };

    const parsed = try cli.get_installed_flatpaks();

    defer parsed.deinit();

    try std.testing.expect(parsed.value.len > 0);
    std.debug.print("{s} {t}\n", .{ parsed.value[0].Name, parsed.value[0].InstallLevel });
}

test "parse remote AppStream apps" {
    const json =
        \\[{"Id":"org.example.App","Name":"Example","Summary":"Useful app","Icons":[{"Type":"remote","Url":"https://example.test/icon.png","Width":128,"Height":128,"Scale":1}],"Remotes":[{"Name":"flathub","Scope":0,"Url":""}]}]
    ;
    const parsed = try parse_appstream_apps(std.testing.allocator, json);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.value.len);
    try std.testing.expectEqualStrings("org.example.App", parsed.value[0].Id);
    try std.testing.expectEqualStrings("Example", parsed.value[0].Name);
    try std.testing.expectEqualStrings("https://example.test/icon.png", parsed.value[0].Icons[0].Url);
    try std.testing.expectEqualStrings("flathub", parsed.value[0].Remotes[0].Name);
}
