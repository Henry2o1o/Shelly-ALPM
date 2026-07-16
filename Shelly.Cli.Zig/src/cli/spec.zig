const std = @import("std");
const catalog = @import("catalog.zig");
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
    actionCode: ?u8 = null,
    typeCode: ?u8 = null,
    defaultForAction: bool = false,

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
        const frozen = try std.json.parseFromSliceLeaky(
            Manifest,
            allocator,
            command_contract.json,
            .{ .ignore_unknown_fields = true },
        );
        if (frozen.schemaVersion != 1 or frozen.commands.len == 0)
            return error.UnsupportedContract;
        return projectActionFirst(allocator, frozen);
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

    pub fn findDefaultChild(self: *const Manifest, parent: *const Command) ?*const Command {
        for (self.commands) |*command| {
            const parent_path = command.parentPath orelse continue;
            if (command.defaultForAction and std.mem.eql(u8, parent_path, parent.path)) return command;
        }
        return null;
    }

    pub fn findOption(self: *const Manifest, command: *const Command, token: []const u8) ?*const Option {
        for (command.options) |*option| {
            if (option.matches(token)) return option;
        }
        if (self.findDefaultChild(command)) |default_child| {
            for (default_child.options) |*option| {
                if (option.matches(token)) return option;
            }
        }
        if (command != self.root()) {
            for (self.root().options) |*option| {
                if (option.recursive and option.matches(token)) return option;
            }
        }
        return null;
    }
};

fn projectActionFirst(allocator: std.mem.Allocator, frozen: Manifest) !Manifest {
    var commands: std.ArrayList(Command) = .empty;

    var root_command = frozen.commands[0];
    root_command.actionCode = null;
    root_command.typeCode = null;
    try commands.append(allocator, root_command);

    for (catalog.variants, 0..) |variant, variant_index| {
        var action_seen = false;
        for (catalog.variants[0..variant_index]) |earlier| {
            if (std.mem.eql(u8, earlier.action, variant.action)) {
                action_seen = true;
                break;
            }
        }
        if (action_seen) continue;

        const action_path = try std.fmt.allocPrint(allocator, "shelly {s}", .{variant.action});
        const action_description = try std.fmt.allocPrint(
            allocator,
            "Run {s} for a package or administrative type.",
            .{variant.action},
        );
        var action_hidden = true;
        for (catalog.variants) |candidate| {
            if (!std.mem.eql(u8, candidate.action, variant.action)) continue;
            const source = frozen.findByPath(candidate.source_path) orelse return error.InvalidContract;
            if (!source.hidden) action_hidden = false;
        }

        try commands.append(allocator, .{
            .path = action_path,
            .parentPath = "shelly",
            .name = variant.action,
            .description = action_description,
            .hidden = action_hidden,
            .isBranch = true,
            .hasAction = false,
            .aliases = &.{},
            .arguments = &.{},
            .options = &.{},
            .owner = "cli-core",
            .backends = &.{},
            .risk = "branch",
            .status = "native",
            .notes = "Action-first command group generated by the Zig CLI catalog.",
        });

        for (catalog.variants) |candidate| {
            if (!std.mem.eql(u8, candidate.action, variant.action)) continue;
            const source = frozen.findByPath(candidate.source_path) orelse return error.InvalidContract;
            const command_path = try std.fmt.allocPrint(
                allocator,
                "shelly {s} {s}",
                .{ candidate.action, candidate.type_name },
            );
            const arguments = if (candidate.keyring_action != null)
                source.arguments[1..]
            else
                source.arguments;
            const options = try effectiveOptions(allocator, source.options, candidate);

            try commands.append(allocator, .{
                .path = command_path,
                .parentPath = action_path,
                .name = candidate.type_name,
                .description = source.description,
                .hidden = source.hidden,
                .isBranch = false,
                .hasAction = true,
                .aliases = &.{},
                .arguments = arguments,
                .options = options,
                .owner = source.owner,
                .backends = source.backends,
                .risk = source.risk,
                .status = source.status,
                .notes = source.notes,
                .actionCode = candidate.action_code,
                .typeCode = candidate.type_code,
                .defaultForAction = candidate.default_for_action,
            });
        }
    }

    const projected = try commands.toOwnedSlice(allocator);
    return .{
        .schemaVersion = frozen.schemaVersion,
        .binary = frozen.binary,
        .version = frozen.version,
        .informationalVersion = frozen.informationalVersion,
        .commandCount = projected.len,
        .leafCommandCount = catalog.variants.len,
        .commands = projected,
    };
}

fn effectiveOptions(
    allocator: std.mem.Allocator,
    source_options: []const Option,
    variant: catalog.Variant,
) ![]const Option {
    if (source_options.len == 0) return source_options;

    var options: std.ArrayList(Option) = .empty;
    for (source_options) |source| {
        if (variant.keyring_action != null and
            !std.mem.eql(u8, variant.keyring_action.?, "recv") and
            std.mem.eql(u8, source.name, "--keyserver")) continue;
        var option = source;
        if (catalog.findSharedModifier(variant.action, variant.type_name, source.name)) |shared| {
            option.name = shared.name;
            option.aliases = shared.aliases;
            option.description = shared.description;
        }
        try options.append(allocator, option);
    }
    return options.toOwnedSlice(allocator);
}

test "projects the frozen metadata into the action-first command catalog" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try Manifest.load(arena.allocator());
    try std.testing.expectEqual(catalog.variants.len, manifest.leafCommandCount);
    try std.testing.expectEqualStrings("2.4.1.4", manifest.version);
    try std.testing.expect(manifest.findByPath("shelly search flatpak") != null);
    try std.testing.expect(manifest.findByPath("shelly search standard") != null);
    try std.testing.expect(manifest.findByPath("shelly sync flatpak") != null);
    try std.testing.expect(manifest.findByPath("shelly flatpak search") == null);
    try std.testing.expect(manifest.findByPath("shelly sync-remote-appstream flatpak") == null);
    try std.testing.expect(manifest.findByPath("shelly query") == null);
    try std.testing.expectEqualStrings(
        "shelly sync standard",
        manifest.findDefaultChild(manifest.findByPath("shelly sync").?).?.path,
    );
}

test "centralizes shared modifiers while retaining type additions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try Manifest.load(arena.allocator());

    const standard = manifest.findByPath("shelly install standard").?;
    const aur = manifest.findByPath("shelly install aur").?;
    try std.testing.expect(standard.options[0].matches("-b"));
    try std.testing.expect(aur.options[0].matches("-b"));
    try std.testing.expect(!aur.options[0].matches("-o"));
    try std.testing.expect(manifest.findOption(aur, "--chroot") != null);

    const flatpak_remove = manifest.findByPath("shelly remove flatpak").?;
    try std.testing.expect(manifest.findOption(flatpak_remove, "--remove-config") != null);
    try std.testing.expect(manifest.findOption(flatpak_remove, "--config") == null);
}
