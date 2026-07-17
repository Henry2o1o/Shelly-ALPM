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
    implementation: ?[]const u8 = null,
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
        const action_description = catalog.actionDescription(variant.action) orelse
            try sourceActionDescription(frozen, variant.action);
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
            const source_arguments = if (candidate.keyring_action != null)
                source.arguments[1..]
            else
                source.arguments;
            const arguments = try effectiveArguments(allocator, source_arguments, candidate);
            const options = try effectiveOptions(allocator, source.options, candidate);

            try commands.append(allocator, .{
                .path = command_path,
                .parentPath = action_path,
                .name = candidate.type_name,
                .description = candidate.help.description orelse source.description,
                .hidden = source.hidden,
                .isBranch = false,
                .hasAction = true,
                .aliases = &.{},
                .arguments = arguments,
                .options = options,
                .owner = source.owner,
                .backends = source.backends,
                .risk = source.risk,
                .status = if (candidate.help.implementation != null) "native" else source.status,
                .notes = source.notes,
                .implementation = candidate.help.implementation,
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

fn sourceActionDescription(frozen: Manifest, action: []const u8) ![]const u8 {
    for (catalog.variants) |variant| {
        if (!std.mem.eql(u8, variant.action, action)) continue;
        if (variant.help.description) |description| return description;
        const source = frozen.findByPath(variant.source_path) orelse return error.InvalidContract;
        return source.description orelse return error.InvalidContract;
    }
    return error.InvalidContract;
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
        if (findHelpText(variant.help.options, source.name)) |description|
            option.description = description;
        try options.append(allocator, option);
    }
    return options.toOwnedSlice(allocator);
}

fn effectiveArguments(
    allocator: std.mem.Allocator,
    source_arguments: []const Argument,
    variant: catalog.Variant,
) ![]const Argument {
    if (variant.help.arguments.len == 0) return source_arguments;
    const arguments = try allocator.dupe(Argument, source_arguments);
    for (arguments) |*argument| {
        if (findHelpText(variant.help.arguments, argument.name)) |description|
            argument.description = description;
    }
    return arguments;
}

fn findHelpText(values: []const catalog.HelpText, name: []const u8) ?[]const u8 {
    for (values) |value| {
        if (std.mem.eql(u8, value.name, name)) return value.description;
    }
    return null;
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

test "native help overrides describe the implementation that actually executes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try Manifest.load(arena.allocator());

    const standard = manifest.findByPath("shelly search standard").?;
    try std.testing.expect(std.mem.indexOf(u8, standard.description.?, "ALPM repository") != null);
    try std.testing.expect(std.mem.indexOf(u8, standard.implementation.?, "get_installed_packages") != null);
    try std.testing.expectEqualStrings(
        "Search packages from the local ALPM database",
        manifest.findOption(standard, "--installed").?.description.?,
    );

    const aur = manifest.findByPath("shelly search aur").?;
    try std.testing.expectEqualStrings(
        "Append high-confidence standard ALPM repository matches to the AUR results",
        manifest.findOption(aur, "--standard").?.description.?,
    );

    const flatpak = manifest.findByPath("shelly search flatpak").?;
    try std.testing.expect(std.mem.indexOf(u8, flatpak.description.?, "cached AppStream") != null);
    try std.testing.expectEqualStrings(
        "Zigalpm.flatpak.AppstreamManager.getAllRemoteCatalogs",
        flatpak.implementation.?,
    );
    try std.testing.expect(std.mem.indexOf(u8, flatpak.arguments[0].description.?, "local AppStream") != null);

    const install_standard = manifest.findByPath("shelly install standard").?;
    try std.testing.expectEqualStrings("native", install_standard.status);
    try std.testing.expect(std.mem.indexOf(u8, install_standard.implementation.?, "install_packages") != null);
    try std.testing.expect(std.mem.indexOf(u8, install_standard.implementation.?, "downloadToFile") != null);

    const install_appimage = manifest.findByPath("shelly install appimage").?;
    try std.testing.expectEqualStrings("Zigalpm.AppImageManager.installAppImage", install_appimage.implementation.?);

    const install_aur = manifest.findByPath("shelly install aur").?;
    try std.testing.expect(std.mem.indexOf(u8, install_aur.implementation.?, "installDependenciesOnly") != null);

    const install_flatpak = manifest.findByPath("shelly install flatpak").?;
    try std.testing.expect(std.mem.indexOf(u8, install_flatpak.implementation.?, "install_flatpak") != null);
    try std.testing.expect(std.mem.indexOf(u8, install_flatpak.description.?, "AppStream") != null);
}

test "every action help entry explains its command instead of using a generic placeholder" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try Manifest.load(arena.allocator());

    for (manifest.commands) |command| {
        const parent_path = command.parentPath orelse continue;
        if (!command.isBranch or !std.mem.eql(u8, parent_path, manifest.root().path)) continue;
        const description = command.description orelse return error.MissingActionDescription;
        try std.testing.expect(description.len > 0);
        try std.testing.expect(std.mem.indexOf(
            u8,
            description,
            "for a package or administrative type",
        ) == null);
    }
}
