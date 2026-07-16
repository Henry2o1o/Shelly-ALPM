const std = @import("std");
const command_contract = @import("command_contract");

pub const Argument = struct {
    name: []const u8,
    type: []const u8,
    minimumArity: usize,
    maximumArity: ?usize,
    description: ?[]const u8,
    choices: []const []const u8,
};

pub const Option = struct {
    name: []const u8,
    aliases: []const []const u8,
    type: []const u8,
    minimumArity: usize,
    maximumArity: ?usize,
    required: bool,
    description: ?[]const u8,
    hidden: bool,
    recursive: bool,
    builtIn: bool,
    hasExplicitDefault: bool,
    defaultValue: ?std.json.Value,
    choices: []const []const u8,

    pub fn matches(self: Option, token: []const u8) bool {
        if (std.mem.eql(u8, self.name, token)) return true;
        for (self.aliases) |alias| {
            if (std.mem.eql(u8, alias, token)) return true;
        }
        return false;
    }
};

pub const Command = struct {
    path: []const u8,
    parentPath: ?[]const u8,
    name: []const u8,
    description: ?[]const u8,
    hidden: bool,
    isBranch: bool,
    hasAction: bool,
    aliases: []const []const u8,
    arguments: []const Argument,
    options: []const Option,
    owner: []const u8,
    backends: []const []const u8,
    risk: []const u8,
    status: []const u8,
    notes: ?[]const u8,

    pub fn matches(self: Command, token: []const u8) bool {
        if (std.mem.eql(u8, self.name, token)) return true;
        for (self.aliases) |alias| {
            if (std.mem.eql(u8, alias, token)) return true;
        }
        return false;
    }
};

pub const Manifest = struct {
    schemaVersion: usize,
    binary: []const u8,
    version: []const u8,
    informationalVersion: []const u8,
    commandCount: usize,
    leafCommandCount: usize,
    commands: []const Command,

    pub fn load(allocator: std.mem.Allocator) !Manifest {
        const manifest = try std.json.parseFromSliceLeaky(
            Manifest,
            allocator,
            command_contract.json,
            .{ .ignore_unknown_fields = true },
        );
        if (manifest.schemaVersion != 1 or manifest.commands.len == 0)
            return error.UnsupportedContract;
        return manifest;
    }

    pub fn root(self: *const Manifest) *const Command {
        return &self.commands[0];
    }

    pub fn findByPath(self: *const Manifest, path: []const u8) ?*const Command {
        for (self.commands) |*command| {
            if (std.mem.eql(u8, command.path, path)) return command;
        }
        return null;
    }

    pub fn findChild(self: *const Manifest, parent: *const Command, token: []const u8) ?*const Command {
        for (self.commands) |*command| {
            const parent_path = command.parentPath orelse continue;
            if (std.mem.eql(u8, parent_path, parent.path) and command.matches(token)) return command;
        }
        return null;
    }

    pub fn findOption(self: *const Manifest, command: *const Command, token: []const u8) ?*const Option {
        for (command.options) |*option| {
            if (option.matches(token)) return option;
        }
        if (command != self.root()) {
            for (self.root().options) |*option| {
                if (option.recursive and option.matches(token)) return option;
            }
        }
        return null;
    }
};

test "loads the frozen command contract" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try Manifest.load(arena.allocator());
    try std.testing.expectEqual(@as(usize, 68), manifest.commandCount);
    try std.testing.expectEqualStrings("2.4.1.4", manifest.version);
    try std.testing.expect(manifest.findByPath("shelly flatpak search") != null);
}
