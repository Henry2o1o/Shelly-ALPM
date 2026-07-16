const std = @import("std");

const Action = struct {
    type_code: u8,
    action_code: u8,
    verb: []const u8,
    modifiers: []const u8,
};

const actions = [_]Action{
    .{ .type_code = 'S', .action_code = 'I', .verb = "install", .modifiers = "bmdu" },
    .{ .type_code = 'S', .action_code = 'R', .verb = "remove", .modifiers = "coirlf" },
    .{ .type_code = 'S', .action_code = 'Q', .verb = "query", .modifiers = "railtpwdg" },
    .{ .type_code = 'S', .action_code = 'M', .verb = "mark", .modifiers = "ed" },
    .{ .type_code = 'S', .action_code = 'Y', .verb = "sync", .modifiers = "f" },
    .{ .type_code = 'S', .action_code = 'P', .verb = "purify", .modifiers = "do" },
    .{ .type_code = 'S', .action_code = 'N', .verb = "news", .modifiers = "a" },
    .{ .type_code = 'S', .action_code = 'D', .verb = "downgrade", .modifiers = "oilt" },
    .{ .type_code = 'S', .action_code = 'G', .verb = "ignore", .modifiers = "larc" },
    .{ .type_code = 'S', .action_code = 'U', .verb = "upgrade", .modifiers = "" },
    .{ .type_code = 'S', .action_code = 'T', .verb = "update", .modifiers = "" },

    .{ .type_code = 'U', .action_code = 'C', .verb = "cache-clean", .modifiers = "kidct" },
    .{ .type_code = 'U', .action_code = 'K', .verb = "check-updates", .modifiers = "alc" },
    .{ .type_code = 'U', .action_code = 'E', .verb = "export", .modifiers = "ao" },
    .{ .type_code = 'U', .action_code = 'F', .verb = "fix-permissions", .modifiers = "" },

    .{ .type_code = 'A', .action_code = 'I', .verb = "install", .modifiers = "omc" },
    .{ .type_code = 'A', .action_code = 'V', .verb = "install-version", .modifiers = "" },
    .{ .type_code = 'A', .action_code = 'R', .verb = "remove", .modifiers = "coi" },
    .{ .type_code = 'A', .action_code = 'T', .verb = "update", .modifiers = "" },
    .{ .type_code = 'A', .action_code = 'U', .verb = "upgrade", .modifiers = "" },
    .{ .type_code = 'A', .action_code = 'L', .verb = "list", .modifiers = "" },
    .{ .type_code = 'A', .action_code = 'P', .verb = "list-updates", .modifiers = "" },
    .{ .type_code = 'A', .action_code = 'S', .verb = "search", .modifiers = "s" },
    .{ .type_code = 'A', .action_code = 'B', .verb = "search-pkgbuild", .modifiers = "" },

    .{ .type_code = 'F', .action_code = 'I', .verb = "install", .modifiers = "rb" },
    .{ .type_code = 'F', .action_code = 'T', .verb = "update", .modifiers = "" },
    .{ .type_code = 'F', .action_code = 'U', .verb = "upgrade", .modifiers = "" },
    .{ .type_code = 'F', .action_code = 'L', .verb = "list", .modifiers = "" },
    .{ .type_code = 'F', .action_code = 'P', .verb = "list-updates", .modifiers = "" },
    .{ .type_code = 'F', .action_code = 'R', .verb = "uninstall", .modifiers = "rc" },
    .{ .type_code = 'F', .action_code = 'N', .verb = "running", .modifiers = "" },
    .{ .type_code = 'F', .action_code = 'X', .verb = "run", .modifiers = "" },
    .{ .type_code = 'F', .action_code = 'K', .verb = "kill", .modifiers = "" },
    .{ .type_code = 'F', .action_code = 'S', .verb = "search", .modifiers = "lp" },
    .{ .type_code = 'F', .action_code = 'H', .verb = "repair", .modifiers = "" },
    .{ .type_code = 'F', .action_code = 'M', .verb = "list-remotes", .modifiers = "" },
    .{ .type_code = 'F', .action_code = 'A', .verb = "add-remotes", .modifiers = "usg" },
    .{ .type_code = 'F', .action_code = 'D', .verb = "remove-remotes", .modifiers = "s" },
    .{ .type_code = 'F', .action_code = 'E', .verb = "install-ref-file", .modifiers = "s" },
    .{ .type_code = 'F', .action_code = 'B', .verb = "install-bundle", .modifiers = "s" },
    .{ .type_code = 'F', .action_code = 'Y', .verb = "sync-remote-appstream", .modifiers = "" },
    .{ .type_code = 'F', .action_code = 'G', .verb = "get-remote-appstream", .modifiers = "" },
    .{ .type_code = 'F', .action_code = 'O', .verb = "app-remote-info", .modifiers = "" },

    .{ .type_code = 'I', .action_code = 'I', .verb = "install", .modifiers = "" },
    .{ .type_code = 'I', .action_code = 'R', .verb = "remove", .modifiers = "c" },
    .{ .type_code = 'I', .action_code = 'L', .verb = "list", .modifiers = "" },
    .{ .type_code = 'I', .action_code = 'U', .verb = "upgrade", .modifiers = "" },
    .{ .type_code = 'I', .action_code = 'P', .verb = "list-updates", .modifiers = "" },
    .{ .type_code = 'I', .action_code = 'S', .verb = "sync-meta", .modifiers = "" },
    .{ .type_code = 'I', .action_code = 'C', .verb = "configure-updates", .modifiers = "p" },
    .{ .type_code = 'I', .action_code = 'M', .verb = "migrate-manager", .modifiers = "" },

    .{ .type_code = 'C', .action_code = 'G', .verb = "get", .modifiers = "" },
    .{ .type_code = 'C', .action_code = 'S', .verb = "set", .modifiers = "" },
    .{ .type_code = 'C', .action_code = 'L', .verb = "list", .modifiers = "" },
    .{ .type_code = 'C', .action_code = 'R', .verb = "reset", .modifiers = "" },
    .{ .type_code = 'C', .action_code = 'P', .verb = "parallel", .modifiers = "" },
};

const Type = struct { code: u8, group: []const u8 };
const types = [_]Type{
    .{ .code = 'I', .group = "appimage" },
    .{ .code = 'A', .group = "aur" },
    .{ .code = 'C', .group = "config" },
    .{ .code = 'F', .group = "flatpak" },
    .{ .code = 'K', .group = "keyring" },
    .{ .code = 'S', .group = "" },
    .{ .code = 'U', .group = "" },
};

const keyring_actions = [_]struct { code: u8, action: []const u8 }{
    .{ .code = 'I', .action = "init" },
    .{ .code = 'L', .action = "list" },
    .{ .code = 'R', .action = "refresh" },
    .{ .code = 'S', .action = "lsign" },
    .{ .code = 'P', .action = "populate" },
    .{ .code = 'V', .action = "recv" },
};

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

pub fn translate(allocator: std.mem.Allocator, args: []const []const u8) !Translation {
    if (args.len == 0) return .{ .unchanged = args };
    const token = args[0];
    if (token.len < 3 or token[0] != '-') return .{ .unchanged = args };

    const type_code = token[1];
    const command_type = findType(type_code) orelse return .{ .unchanged = args };
    const action_code = token[2];
    if (!std.ascii.isAlphabetic(action_code)) return .{ .unchanged = args };

    if (type_code == 'K') return translateKeyring(allocator, action_code, token[3..], args[1..]);

    const action = findAction(type_code, action_code) orelse {
        const valid = try validActions(allocator, type_code);
        return .{ .failure = try std.fmt.allocPrint(
            allocator,
            "Unknown shortcode action '{c}' for type '{c}'. Valid actions: {s}",
            .{ action_code, type_code, valid },
        ) };
    };

    var result: std.ArrayList([]const u8) = .empty;
    if (command_type.group.len > 0) try result.append(allocator, command_type.group);
    try result.append(allocator, action.verb);
    for (token[3..]) |modifier| {
        if (std.mem.indexOfScalar(u8, action.modifiers, modifier) == null) {
            const valid = try validModifiers(allocator, action.modifiers);
            return .{ .failure = try std.fmt.allocPrint(
                allocator,
                "Unknown modifier '{c}' for '{s}'. Valid modifiers: {s}",
                .{ modifier, action.verb, valid },
            ) };
        }
        try result.append(allocator, try std.fmt.allocPrint(allocator, "-{c}", .{modifier}));
    }
    try result.appendSlice(allocator, args[1..]);
    return .{ .translated = try result.toOwnedSlice(allocator) };
}

fn translateKeyring(
    allocator: std.mem.Allocator,
    action_code: u8,
    modifiers: []const u8,
    rest: []const []const u8,
) !Translation {
    if (modifiers.len > 0)
        return .{ .failure = "Keyring shortcodes do not accept modifiers." };
    for (keyring_actions) |action| {
        if (action.code != action_code) continue;
        var result: std.ArrayList([]const u8) = .empty;
        try result.appendSlice(allocator, &.{ "keyring", action.action });
        try result.appendSlice(allocator, rest);
        return .{ .translated = try result.toOwnedSlice(allocator) };
    }
    return .{ .failure = try std.fmt.allocPrint(
        allocator,
        "Unknown keyring action '{c}'. Valid actions: I, L, R, S, P, V",
        .{action_code},
    ) };
}

fn findType(code: u8) ?Type {
    for (types) |command_type| if (command_type.code == code) return command_type;
    return null;
}

fn findAction(type_code: u8, action_code: u8) ?Action {
    for (actions) |action| {
        if (action.type_code == type_code and action.action_code == action_code) return action;
    }
    return null;
}

fn validActions(allocator: std.mem.Allocator, type_code: u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    for (actions) |action| {
        if (action.type_code != type_code) continue;
        if (result.items.len > 0) try result.appendSlice(allocator, ", ");
        try result.append(allocator, action.action_code);
    }
    return result.toOwnedSlice(allocator);
}

fn validModifiers(allocator: std.mem.Allocator, modifiers: []const u8) ![]const u8 {
    if (modifiers.len == 0) return "(none)";
    var result: std.ArrayList(u8) = .empty;
    for (modifiers, 0..) |modifier, index| {
        if (index > 0) try result.appendSlice(allocator, ", ");
        try result.append(allocator, modifier);
    }
    return result.toOwnedSlice(allocator);
}

test "translates standard and keyring shortcodes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const standard = try translate(allocator, &.{ "-SIu", "firefox" });
    const expected_standard = [_][]const u8{ "install", "-u", "firefox" };
    for (expected_standard, standard.arguments().?) |expected, actual|
        try std.testing.expectEqualStrings(expected, actual);

    const keyring = try translate(allocator, &.{ "-KV", "ABCD" });
    const expected_keyring = [_][]const u8{ "keyring", "recv", "ABCD" };
    for (expected_keyring, keyring.arguments().?) |expected, actual|
        try std.testing.expectEqualStrings(expected, actual);
}

test "reports shortcode validation errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const result = try translate(allocator, &.{"-SIx"});
    try std.testing.expectEqualStrings(
        "Unknown modifier 'x' for 'install'. Valid modifiers: b, m, d, u",
        result.failure,
    );
}

test "matches the frozen shortcode translation matrix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try expectTranslation(allocator, &.{ "-SQad", "query" }, &.{ "query", "-a", "-d", "query" });
    try expectTranslation(allocator, &.{ "-SRcr", "pkg" }, &.{ "remove", "-c", "-r", "pkg" });
    try expectTranslation(allocator, &.{ "-AS", "query" }, &.{ "aur", "search", "query" });
    try expectTranslation(allocator, &.{ "-FR", "app" }, &.{ "flatpak", "uninstall", "app" });
    try expectTranslation(allocator, &.{"-UC"}, &.{"cache-clean"});
    try expectTranslation(
        allocator,
        &.{ "-SIu", "pkg", "-n", "--json" },
        &.{ "install", "-u", "pkg", "-n", "--json" },
    );
    try expectTranslation(allocator, &.{ "install", "pkg" }, &.{ "install", "pkg" });
    try expectTranslation(allocator, &.{ "aur", "search", "x" }, &.{ "aur", "search", "x" });
    try expectTranslation(
        allocator,
        &.{ "--json", "query", "-a", "x" },
        &.{ "--json", "query", "-a", "x" },
    );
    try expectTranslation(allocator, &.{"-n"}, &.{"-n"});
    try expectTranslation(allocator, &.{ "-ZZ", "x" }, &.{ "-ZZ", "x" });

    const invalid_action = try translate(allocator, &.{ "-SZ", "x" });
    try std.testing.expectEqualStrings(
        "Unknown shortcode action 'Z' for type 'S'. Valid actions: I, R, Q, M, Y, P, N, D, G, U, T",
        invalid_action.failure,
    );
    const keyring_modifier = try translate(allocator, &.{ "-KVx", "x" });
    try std.testing.expectEqualStrings(
        "Keyring shortcodes do not accept modifiers.",
        keyring_modifier.failure,
    );
}

fn expectTranslation(
    allocator: std.mem.Allocator,
    input: []const []const u8,
    expected: []const []const u8,
) !void {
    const result = try translate(allocator, input);
    const actual = result.arguments() orelse return error.UnexpectedTranslationFailure;
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |expected_argument, actual_argument|
        try std.testing.expectEqualStrings(expected_argument, actual_argument);
}
