const std = @import("std");
const Io = std.Io;
const Package = @import("../models/packages.zig").Package;
const Remote = @import("../models/flatpak.zig").Remote;
const Flatpak = @import("../models/flatpak.zig").Flatpak;
const AppstreamApp = @import("../models/flatpak.zig").AppstreamApp;
const FlatpakRemoteInfo = @import("../models/flatpak.zig").FlatpakRemoteInfo;
const CheckUpdates = @import("../models/sync.zig").CheckUpdates;
const JsonPackFrame = @import("../helpers/ui_decode.zig").JsonPackFrame;
const RunResult = std.process.RunResult;

pub const ShellyCli = struct {
    allocator: std.mem.Allocator,
    io: Io,

    fn run(self: ShellyCli, args: []const []const u8) !RunResult {
        var argv = try self.allocator.alloc([]const u8, args.len + 1);
        defer self.allocator.free(argv);
        @memcpy(argv[0..args.len], args);
        argv[args.len] = "--ui-mode";

        const result = try std.process.run(self.allocator, self.io, .{ .argv = argv });
        errdefer self.allocator.free(result.stdout);
        errdefer self.allocator.free(result.stderr);

        if (result.term != .exited or result.term.exited != 0) {
            std.debug.print("failed: {s}\n", .{result.stderr});
            return error.CommandFailed;
        }
        return result;
    }

    pub fn get_packages(self: ShellyCli) !std.json.Parsed([]Package) {
        const result = try self.run(&.{
            "shelly",
            "query",
            "--available",
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        return try JsonPackFrame.decode([]Package, self.allocator, result.stdout);
    }

    pub fn get_installed_packages(self: ShellyCli) !std.json.Parsed([]Package) {
        const result = try self.run(&.{
            "shelly",
            "query",
            "--installed",
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        return try JsonPackFrame.decode([]Package, self.allocator, result.stdout);
    }

    pub fn get_remotes(self: ShellyCli) !std.json.Parsed([]Remote) {
        const result = try self.run(&.{
            "shelly",
            "flatpak",
            "list-remotes",
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        return try JsonPackFrame.decode([]Remote, self.allocator, result.stdout);
    }

    pub fn get_installed_flatpaks(self: ShellyCli) !std.json.Parsed([]Flatpak) {
        const result = try self.run(&.{ "shelly", "flatpak", "list" });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);
        return try JsonPackFrame.decode([]Flatpak, self.allocator, result.stdout);
    }

    pub fn get_remote_appstream_apps(self: ShellyCli) !std.json.Parsed([]AppstreamApp) {
        const result = try self.run(&.{ "shelly", "flatpak", "get-remote-appstream", "all" });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        return try JsonPackFrame.decode([]AppstreamApp, self.allocator, result.stdout);
    }

    pub fn get_flatpak_remote_info(self: ShellyCli, remote: []const u8, id: []const u8, branch: []const u8) !std.json.Parsed(FlatpakRemoteInfo) {
        const result = try self.run(&.{ "shelly", "flatpak", "app-remote-info", remote, id, branch, "--json" });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        return try JsonPackFrame.decode(FlatpakRemoteInfo, self.allocator, result.stdout);
    }

    pub fn check_updates(self: ShellyCli) !std.json.Parsed(CheckUpdates) {
        const result = try self.run(&.{ "shelly", "check-updates", "-a", "-l", "-j" });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        return try JsonPackFrame.decode(CheckUpdates, self.allocator, result.stdout);
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
