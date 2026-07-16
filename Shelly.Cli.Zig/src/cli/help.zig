const std = @import("std");
const spec = @import("spec.zig");

const Writer = std.Io.Writer;

const shortcode_help =
    \\Shortcodes:
    \\  Grammar: -<Type><Action><modifiers...> [positionals]
    \\  Type selects the command group, Action selects the verb, and
    \\  modifiers are that verb's own short flags (case-sensitive).
    \\
    \\  Types:
    \\    I  appimage
    \\    A  aur
    \\    C  config
    \\    F  flatpak
    \\    K  keyring
    \\    S  standard
    \\    U  utility
    \\
    \\  Examples:
    \\    -SIu firefox   ->  install -u firefox
    \\    -AS query      ->  aur search query
    \\    -KV ABCD       ->  keyring recv ABCD
    \\
    \\  In shortcode mode use --ui-mode instead of -U.
    \\
;

const Row = struct {
    label: []const u8,
    description: []const u8,
};

pub fn render(
    allocator: std.mem.Allocator,
    manifest: *const spec.Manifest,
    command: *const spec.Command,
    writer: *Writer,
) !void {
    if (!command.hidden) {
        if (command.description) |description|
            try writer.print("Description:\n  {s}\n\n", .{description});

        try writer.print("Usage:\n  {s}", .{command.path});
        if (command.isBranch) {
            try writer.writeAll(" [command]");
        } else {
            for (command.arguments) |argument| {
                try writer.writeByte(' ');
                try writeUsageArgument(allocator, writer, argument);
            }
        }
        try writer.writeAll(" [options]\n");

        if (command.arguments.len > 0) {
            try writer.writeAll("\nArguments:\n");
            var rows: std.ArrayList(Row) = .empty;
            for (command.arguments) |argument| {
                try rows.append(allocator, .{
                    .label = try argumentLabel(allocator, argument),
                    .description = argument.description orelse "",
                });
            }
            try writeRows(writer, rows.items);
        }

        var option_rows: std.ArrayList(Row) = .empty;
        if (command == manifest.root()) {
            for (command.options) |option| {
                if (!option.hidden and !option.builtIn)
                    try appendOptionRow(allocator, &option_rows, option);
            }
            for (command.options) |option| {
                if (!option.hidden and option.builtIn)
                    try appendOptionRow(allocator, &option_rows, option);
            }
        } else {
            for (command.options) |option| {
                if (!option.hidden) try appendOptionRow(allocator, &option_rows, option);
            }
            for (manifest.root().options) |option| {
                if (!option.hidden and option.recursive)
                    try appendOptionRow(allocator, &option_rows, option);
            }
        }
        if (option_rows.items.len > 0) {
            try writer.writeAll("\nOptions:\n");
            try writeRows(writer, option_rows.items);
        }

        var command_rows: std.ArrayList(Row) = .empty;
        for (manifest.commands) |child| {
            const parent_path = child.parentPath orelse continue;
            if (!std.mem.eql(u8, parent_path, command.path) or child.hidden) continue;
            var label: std.ArrayList(u8) = .empty;
            try label.appendSlice(allocator, child.name);
            for (child.arguments) |argument| {
                try label.append(allocator, ' ');
                try label.appendSlice(allocator, try argumentLabel(allocator, argument));
            }
            try command_rows.append(allocator, .{
                .label = try label.toOwnedSlice(allocator),
                .description = child.description orelse "",
            });
        }
        if (command_rows.items.len > 0) {
            try writer.writeAll("\nCommands:\n");
            try writeRows(writer, command_rows.items);
        }

        try writer.writeByte('\n');
    }
    try writer.writeAll(shortcode_help);
    try writer.writeByte('\n');
}

fn appendOptionRow(
    allocator: std.mem.Allocator,
    rows: *std.ArrayList(Row),
    option: spec.Option,
) !void {
    var description: []const u8 = option.description orelse "";
    if (option.hasExplicitDefault) {
        const value = try formatDefault(allocator, option.defaultValue);
        description = try std.fmt.allocPrint(allocator, "{s} [default: {s}]", .{ description, value });
    }
    try rows.append(allocator, .{
        .label = try optionLabel(allocator, option),
        .description = description,
    });
}

fn writeRows(writer: *Writer, rows: []const Row) !void {
    var width: usize = 0;
    for (rows) |row| width = @max(width, row.label.len);
    for (rows) |row| {
        try writer.print("  {s}", .{row.label});
        try writer.splatByteAll(' ', width - row.label.len + 2);
        try writer.print("{s}\n", .{row.description});
    }
}

fn writeUsageArgument(allocator: std.mem.Allocator, writer: *Writer, argument: spec.Argument) !void {
    const label = try std.fmt.allocPrint(allocator, "<{s}>", .{argument.name});
    const is_many = std.mem.endsWith(u8, argument.type, "[]");
    if (argument.minimumArity == 0) try writer.writeByte('[');
    try writer.writeAll(label);
    if (is_many) try writer.writeAll("...");
    if (argument.minimumArity == 0) try writer.writeByte(']');
}

fn argumentLabel(allocator: std.mem.Allocator, argument: spec.Argument) ![]const u8 {
    if (argument.choices.len == 0)
        return std.fmt.allocPrint(allocator, "<{s}>", .{argument.name});

    const choices = try allocator.dupe([]const u8, argument.choices);
    std.mem.sort([]const u8, choices, {}, struct {
        fn lessThan(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.lessThan);
    var label: std.ArrayList(u8) = .empty;
    try label.append(allocator, '<');
    for (choices, 0..) |choice, index| {
        if (index > 0) try label.append(allocator, '|');
        try label.appendSlice(allocator, choice);
    }
    try label.append(allocator, '>');
    return label.toOwnedSlice(allocator);
}

fn optionLabel(allocator: std.mem.Allocator, option: spec.Option) ![]const u8 {
    var label: std.ArrayList(u8) = .empty;
    var needs_separator = false;
    for (option.aliases) |alias| {
        if (!std.mem.startsWith(u8, alias, "-") or std.mem.startsWith(u8, alias, "--")) continue;
        if (needs_separator) try label.appendSlice(allocator, ", ");
        try label.appendSlice(allocator, alias);
        needs_separator = true;
    }
    if (needs_separator) try label.appendSlice(allocator, ", ");
    try label.appendSlice(allocator, option.name);
    for (option.aliases) |alias| {
        if (!std.mem.startsWith(u8, alias, "--")) continue;
        try label.appendSlice(allocator, ", ");
        try label.appendSlice(allocator, alias);
    }
    if (!std.mem.eql(u8, option.type, "void") and !std.mem.eql(u8, option.type, "bool")) {
        try label.append(allocator, ' ');
        try label.append(allocator, '<');
        try label.appendSlice(allocator, std.mem.trimStart(u8, option.name, "-"));
        try label.append(allocator, '>');
    }
    if (option.required) try label.appendSlice(allocator, " (REQUIRED)");
    return label.toOwnedSlice(allocator);
}

fn formatDefault(allocator: std.mem.Allocator, value: ?std.json.Value) ![]const u8 {
    const actual = value orelse return "null";
    return switch (actual) {
        .null => "null",
        .bool => |boolean| if (boolean) "true" else "false",
        .integer => |integer| std.fmt.allocPrint(allocator, "{d}", .{integer}),
        .float => |float| std.fmt.allocPrint(allocator, "{d}", .{float}),
        .number_string => |number| number,
        .string => |string| string,
        else => "",
    };
}
