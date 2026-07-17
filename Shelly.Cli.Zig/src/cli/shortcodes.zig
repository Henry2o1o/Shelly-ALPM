const std = @import("std");
const catalog = @import("catalog.zig");
const spec = @import("spec.zig");

pub const Translation = union(enum) {
    unchanged: []const []const u8,
    translated: []const []const u8,
    failure: []const u8,

    pub fn arguments(self: Translation) ?[]const []const u8 {
        return switch (self) {
            .unchanged => |value| value,
            .translated => |value| value,
            .failure => null,
        };
    }
};

pub fn translate(
    allocator: std.mem.Allocator,
    manifest: *const spec.Manifest,
    args: []const []const u8,
) !Translation {
    if (args.len == 0) return .{ .unchanged = args };
    const token = args[0];
    if (std.mem.eql(u8, token, "-U") or std.mem.eql(u8, token, "-Ua")) {
        var result: std.ArrayList([]const u8) = .empty;
        try result.appendSlice(allocator, &.{ "upgrade", "all" });
        try result.appendSlice(allocator, args[1..]);
        return .{ .translated = try result.toOwnedSlice(allocator) };
    }
    if (token.len < 3 or token[0] != '-') return .{ .unchanged = args };

    const action_code = token[1];
    if (!std.ascii.isAlphabetic(action_code) or !catalog.hasActionCode(action_code))
        return .{ .unchanged = args };

    const type_code = token[2];
    if (!std.ascii.isAlphabetic(type_code) or catalog.findTypeByCode(type_code) == null) {
        return .{ .failure = try std.fmt.allocPrint(
            allocator,
            "Unknown shortcode type '{c}' for action code '{c}'. Valid types: {s}",
            .{ type_code, action_code, try validTypes(allocator, action_code) },
        ) };
    }

    const variant = catalog.findVariantByCodes(action_code, type_code) orelse {
        return .{ .failure = try std.fmt.allocPrint(
            allocator,
            "Action code '{c}' is not available for type '{c}'. Valid types: {s}",
            .{ action_code, type_code, try validTypes(allocator, action_code) },
        ) };
    };
    const path = try std.fmt.allocPrint(
        allocator,
        "shelly {s} {s}",
        .{ variant.action, variant.type_name },
    );
    const command = manifest.findByPath(path) orelse return error.InvalidCatalog;

    var result: std.ArrayList([]const u8) = .empty;
    try result.appendSlice(allocator, &.{ variant.action, variant.type_name });
    for (token[3..]) |modifier| {
        const alias = try std.fmt.allocPrint(allocator, "-{c}", .{modifier});
        if (findLocalOption(command, alias) != null) {
            try result.append(allocator, alias);
            continue;
        }
        if (findRecursiveHelpOption(manifest, alias)) |option| {
            try result.append(allocator, option.name);
            continue;
        }
        return .{ .failure = try std.fmt.allocPrint(
            allocator,
            "Unknown modifier '{c}' for '{s} {s}'. Valid modifiers: {s}",
            .{ modifier, variant.action, variant.type_name, try validModifiers(allocator, manifest, command) },
        ) };
    }
    try result.appendSlice(allocator, args[1..]);
    return .{ .translated = try result.toOwnedSlice(allocator) };
}

fn findLocalOption(command: *const spec.Command, alias: []const u8) ?*const spec.Option {
    for (command.options) |*option| {
        if (option.matches(alias)) return option;
    }
    return null;
}

fn findRecursiveHelpOption(manifest: *const spec.Manifest, alias: []const u8) ?*const spec.Option {
    for (manifest.root().options) |*option| {
        if (!option.recursive or !std.mem.eql(u8, option.name, "--help")) continue;
        if (option.matches(alias)) return option;
    }
    return null;
}

fn validTypes(allocator: std.mem.Allocator, action_code: u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    for (catalog.variants) |variant| {
        if (variant.action_code != action_code or variant.type_code == null) continue;
        if (result.items.len > 0) try result.appendSlice(allocator, ", ");
        try result.append(allocator, variant.type_code.?);
    }
    return result.toOwnedSlice(allocator);
}

fn validModifiers(
    allocator: std.mem.Allocator,
    manifest: *const spec.Manifest,
    command: *const spec.Command,
) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    try appendModifierAliases(allocator, &result, command.options);
    for (manifest.root().options) |option| {
        if (!option.recursive or !std.mem.eql(u8, option.name, "--help")) continue;
        try appendModifierAliases(allocator, &result, &.{option});
    }
    if (result.items.len == 0) return "(none)";
    return result.toOwnedSlice(allocator);
}

fn appendModifierAliases(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    options: []const spec.Option,
) !void {
    for (options) |option| {
        for (option.aliases) |alias| {
            if (alias.len != 2 or alias[0] != '-' or alias[1] == '-') continue;
            if (result.items.len > 0) try result.appendSlice(allocator, ", ");
            try result.append(allocator, alias[1]);
        }
    }
}

test "translates action-type shortcodes from the command manifest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const manifest = try spec.Manifest.load(allocator);

    try expectTranslation(
        allocator,
        &manifest,
        &.{ "-ISu", "firefox" },
        &.{ "install", "standard", "-u", "firefox" },
    );
    try expectTranslation(
        allocator,
        &manifest,
        &.{ "-IAmb", "package" },
        &.{ "install", "aur", "-m", "-b", "package" },
    );
    try expectTranslation(
        allocator,
        &manifest,
        &.{ "-SA", "query" },
        &.{ "search", "aur", "query" },
    );
    try expectTranslation(
        allocator,
        &manifest,
        &.{ "-VK", "ABCD" },
        &.{ "recv", "keyring", "ABCD" },
    );
    try expectTranslation(
        allocator,
        &manifest,
        &.{"-YSf"},
        &.{ "sync", "standard", "-f" },
    );
    try expectTranslation(
        allocator,
        &manifest,
        &.{"-YF"},
        &.{ "sync", "flatpak" },
    );
    try expectTranslation(allocator, &manifest, &.{"-US"}, &.{ "upgrade", "standard" });
    try expectTranslation(allocator, &manifest, &.{"-USa"}, &.{ "upgrade", "standard", "-a" });
    try expectTranslation(allocator, &manifest, &.{"-U"}, &.{ "upgrade", "all" });
    try expectTranslation(allocator, &manifest, &.{"-Ua"}, &.{ "upgrade", "all" });
    try expectTranslation(
        allocator,
        &manifest,
        &.{ "-Ua", "--no-aur" },
        &.{ "upgrade", "all", "--no-aur" },
    );
    try expectTranslation(allocator, &manifest, &.{"-UX"}, &.{ "upgrade", "all" });
    try expectTranslation(allocator, &manifest, &.{"-UI"}, &.{ "upgrade", "appimage" });
    try expectTranslation(allocator, &manifest, &.{"-UA"}, &.{ "upgrade", "aur" });
    try expectTranslation(allocator, &manifest, &.{"-UF"}, &.{ "upgrade", "flatpak" });
    try expectTranslation(
        allocator,
        &manifest,
        &.{"-UAh"},
        &.{ "upgrade", "aur", "--help" },
    );
    try expectTranslation(
        allocator,
        &manifest,
        &.{"-SAh"},
        &.{ "search", "aur", "--help" },
    );
    try expectTranslation(
        allocator,
        &manifest,
        &.{"-YS?"},
        &.{ "sync", "standard", "--help" },
    );
}

test "uses centralized effective modifiers and rejects type-first shortcodes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const manifest = try spec.Manifest.load(allocator);

    const invalid_modifier = try translate(allocator, &manifest, &.{"-IAo"});
    try std.testing.expectEqualStrings(
        "Unknown modifier 'o' for 'install aur'. Valid modifiers: b, m, c, ?, h",
        invalid_modifier.failure,
    );

    const old_standard = try translate(allocator, &manifest, &.{ "-SIu", "firefox" });
    try std.testing.expect(old_standard == .failure);
    const old_aur = try translate(allocator, &manifest, &.{ "-AS", "query" });
    try std.testing.expect(old_aur == .failure);
    const old_keyring = try translate(allocator, &manifest, &.{ "-KV", "ABCD" });
    try std.testing.expect(old_keyring == .failure);
}

test "passes ordinary long form and unrelated options through unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const manifest = try spec.Manifest.load(allocator);

    try expectTranslation(
        allocator,
        &manifest,
        &.{ "install", "standard", "pkg" },
        &.{ "install", "standard", "pkg" },
    );
    try expectTranslation(allocator, &manifest, &.{"-n"}, &.{"-n"});
    try expectTranslation(allocator, &manifest, &.{ "-WW", "x" }, &.{ "-WW", "x" });
}

test "every catalog leaf supports native long-form help and shortcode help" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const manifest = try spec.Manifest.load(allocator);

    for (catalog.variants) |variant| {
        const long_form = try @import("parser.zig").parse(
            allocator,
            &manifest,
            &.{ variant.action, variant.type_name, "--help" },
        );
        try std.testing.expect(long_form == .help);
        try std.testing.expectEqualStrings(variant.action, long_form.help.parentPath.?["shelly ".len..]);

        if (variant.action_code == null or variant.type_code == null) continue;
        const token = try std.fmt.allocPrint(
            allocator,
            "-{c}{c}h",
            .{ variant.action_code.?, variant.type_code.? },
        );
        const translated = try translate(allocator, &manifest, &.{token});
        const translated_arguments = translated.arguments() orelse return error.ShortcodeTranslationFailed;
        const shortcode = try @import("parser.zig").parse(allocator, &manifest, translated_arguments);
        try std.testing.expect(shortcode == .help);
        try std.testing.expectEqualStrings(long_form.help.path, shortcode.help.path);
    }
}

fn expectTranslation(
    allocator: std.mem.Allocator,
    manifest: *const spec.Manifest,
    input: []const []const u8,
    expected: []const []const u8,
) !void {
    const result = try translate(allocator, manifest, input);
    const actual = result.arguments() orelse return error.UnexpectedTranslationFailure;
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |expected_argument, actual_argument|
        try std.testing.expectEqualStrings(expected_argument, actual_argument);
}
