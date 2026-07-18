const std = @import("std");
const catalog = @import("catalog.zig");
const spec = @import("spec.zig");

const Writer = std.Io.Writer;

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
        const action_branch = isActionBranch(manifest, command);
        const standalone_default = standaloneDefaultChild(manifest, command);
        const detail_command = standalone_default orelse command;
        if (detail_command.description) |description|
            try writer.print("Description:\n  {s}\n\n", .{description});

        if (detail_command.implementation) |implementation|
            try writer.print("Implementation:\n  {s}\n\n", .{implementation});

        try writer.print("Usage:\n  {s}", .{command.path});
        if (standalone_default) |default_child| {
            for (default_child.arguments) |argument| {
                try writer.writeByte(' ');
                try writeUsageArgument(allocator, writer, argument);
            }
        } else if (command.isBranch) {
            try writer.writeAll(if (action_branch and !usesNamedSubcommands(command)) " [type]" else " [command]");
        } else {
            for (command.arguments) |argument| {
                try writer.writeByte(' ');
                try writeUsageArgument(allocator, writer, argument);
            }
        }
        try writer.writeAll(" [options]\n");

        if (detail_command.arguments.len > 0) {
            try writer.writeAll("\nArguments:\n");
            var rows: std.ArrayList(Row) = .empty;
            for (detail_command.arguments) |argument| {
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
            for (detail_command.options) |option| {
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

        if (action_branch and standalone_default == null)
            try writeActionModifiers(allocator, manifest, command, writer);

        var command_rows: std.ArrayList(Row) = .empty;
        if (standalone_default == null) {
            for (manifest.commands) |child| {
                const parent_path = child.parentPath orelse continue;
                if (!std.mem.eql(u8, parent_path, command.path) or child.hidden) continue;
                var label: std.ArrayList(u8) = .empty;
                try label.appendSlice(allocator, if (action_branch) child.path else child.name);
                for (child.arguments) |argument| {
                    try label.append(allocator, ' ');
                    try label.appendSlice(allocator, try argumentLabel(allocator, argument));
                }
                var description: []const u8 = child.description orelse "";
                if (child.actionCode != null and child.typeCode != null) {
                    description = try std.fmt.allocPrint(
                        allocator,
                        "{s} [shortcode: -{c}{c}]",
                        .{ description, child.actionCode.?, child.typeCode.? },
                    );
                }
                if (child.implementation) |implementation| {
                    description = try std.fmt.allocPrint(
                        allocator,
                        "{s} [implementation: {s}]",
                        .{ description, implementation },
                    );
                }
                try command_rows.append(allocator, .{
                    .label = try label.toOwnedSlice(allocator),
                    .description = description,
                });
            }
        }
        if (command_rows.items.len > 0) {
            try writer.writeAll("\nCommands:\n");
            try writeRows(writer, command_rows.items);
        }

        try writer.writeByte('\n');
    }
    try writeShortcodeHelp(writer);
    try writer.writeByte('\n');
}

fn isActionBranch(manifest: *const spec.Manifest, command: *const spec.Command) bool {
    const parent_path = command.parentPath orelse return false;
    return command.isBranch and std.mem.eql(u8, parent_path, manifest.root().path);
}

fn standaloneDefaultChild(
    manifest: *const spec.Manifest,
    command: *const spec.Command,
) ?*const spec.Command {
    if (!isActionBranch(manifest, command)) return null;
    const default_child = manifest.findDefaultChild(command) orelse return null;
    var child_count: usize = 0;
    for (manifest.commands) |candidate| {
        const parent_path = candidate.parentPath orelse continue;
        if (std.mem.eql(u8, parent_path, command.path)) child_count += 1;
    }
    return if (child_count == 1) default_child else null;
}

fn writeActionModifiers(
    allocator: std.mem.Allocator,
    manifest: *const spec.Manifest,
    action: *const spec.Command,
    writer: *Writer,
) !void {
    var has_modifiers = false;
    for (manifest.commands) |child| {
        if (!isChildOf(&child, action) or child.options.len == 0) continue;
        has_modifiers = true;
        break;
    }
    if (!has_modifiers) return;

    try writer.writeAll(if (usesNamedSubcommands(action))
        "\nModifiers by Command:\n"
    else
        "\nModifiers by Type:\n");

    var shared_rows: std.ArrayList(Row) = .empty;
    for (manifest.commands) |child| {
        if (!isChildOf(&child, action)) continue;
        for (child.options) |option| {
            if (option.hidden or option.builtIn or optionTypeCount(manifest, action, option.name) < 2) continue;
            if (hasOptionRow(shared_rows.items, option.name)) continue;

            var type_names: std.ArrayList(u8) = .empty;
            for (manifest.commands) |candidate| {
                if (!isChildOf(&candidate, action) or findLocalOption(&candidate, option.name) == null) continue;
                if (type_names.items.len > 0) try type_names.appendSlice(allocator, ", ");
                try type_names.appendSlice(allocator, candidate.name);
            }
            const description = if (usesNamedSubcommands(action))
                try std.fmt.allocPrint(
                    allocator,
                    "{s} [commands: {s}]",
                    .{ option.description orelse "", type_names.items },
                )
            else
                try std.fmt.allocPrint(
                    allocator,
                    "{s} [types: {s}]",
                    .{ option.description orelse "", type_names.items },
                );
            try shared_rows.append(allocator, .{
                .label = try optionLabel(allocator, option),
                .description = description,
            });
        }
    }
    if (shared_rows.items.len > 0) {
        try writer.writeAll("  Shared:\n");
        try writeIndentedRows(writer, shared_rows.items, 4);
    }

    for (manifest.commands) |child| {
        if (!isChildOf(&child, action)) continue;
        var rows: std.ArrayList(Row) = .empty;
        for (child.options) |option| {
            if (option.hidden or option.builtIn or optionTypeCount(manifest, action, option.name) > 1) continue;
            var description: []const u8 = option.description orelse "";
            if (option.hasExplicitDefault) {
                description = try std.fmt.allocPrint(
                    allocator,
                    "{s} [default: {s}]",
                    .{ description, try formatDefault(allocator, option.defaultValue) },
                );
            }
            try rows.append(allocator, .{
                .label = try optionLabel(allocator, option),
                .description = description,
            });
        }
        if (rows.items.len == 0) continue;
        if (usesNamedSubcommands(action))
            try writer.print("  {s}:\n", .{child.name})
        else
            try writer.print("  {s} only:\n", .{child.name});
        try writeIndentedRows(writer, rows.items, 4);
    }
}

fn isChildOf(command: *const spec.Command, parent: *const spec.Command) bool {
    const parent_path = command.parentPath orelse return false;
    return std.mem.eql(u8, parent_path, parent.path);
}

fn usesNamedSubcommands(command: *const spec.Command) bool {
    return std.mem.eql(u8, command.name, "mark");
}

fn optionTypeCount(manifest: *const spec.Manifest, action: *const spec.Command, name: []const u8) usize {
    if (usesNamedSubcommands(action)) return 1;
    var count: usize = 0;
    for (manifest.commands) |candidate| {
        if (isChildOf(&candidate, action) and findLocalOption(&candidate, name) != null) count += 1;
    }
    return count;
}

fn findLocalOption(command: *const spec.Command, name: []const u8) ?*const spec.Option {
    for (command.options) |*option| {
        if (std.mem.eql(u8, option.name, name)) return option;
    }
    return null;
}

fn hasOptionRow(rows: []const Row, name: []const u8) bool {
    for (rows) |row| {
        if (std.mem.indexOf(u8, row.label, name) != null) return true;
    }
    return false;
}

fn writeIndentedRows(writer: *Writer, rows: []const Row, indent: usize) !void {
    var width: usize = 0;
    for (rows) |row| width = @max(width, row.label.len);
    for (rows) |row| {
        try writer.splatByteAll(' ', indent);
        try writer.print("{s}", .{row.label});
        try writer.splatByteAll(' ', width - row.label.len + 2);
        try writer.print("{s}\n", .{row.description});
    }
}

fn writeShortcodeHelp(writer: *Writer) !void {
    try writer.writeAll(
        \\Shortcodes:
        \\  Grammar: -<UppercaseAction><lowercaseTypeOrCommand><modifiers...> [positionals]
        \\  Uppercase Action selects the operation, the lowercase selector chooses its target or subcommand, and
        \\  modifiers are that action/type pair's short flags (case-sensitive).
        \\  Standalone root actions such as downgrade omit the lowercase Type.
        \\  Search may combine standard, AUR, and Flatpak types (s/a/f); modifiers apply
        \\  only to selected search types that support them.
        \\  List also accepts the compatibility selectors I/A/F used in the examples.
        \\
        \\  Types:
        \\
    );
    for (catalog.types) |command_type| {
        const code = command_type.code orelse continue;
        try writer.print("    {c}  {s}\n", .{ code, command_type.name });
    }
    try writer.writeAll(
        \\
        \\  Examples:
        \\    -U             ->  upgrade all
        \\    -Us            ->  upgrade standard
        \\    -Ua            ->  upgrade aur
        \\    -Uf            ->  upgrade flatpak
        \\    -Ui            ->  upgrade appimage
        \\    -Ux            ->  upgrade all
        \\    -Ls            ->  list standard
        \\    -LI            ->  list appimage
        \\    -LA            ->  list aur
        \\    -LF            ->  list flatpak
        \\    -Ts linux      ->  update standard linux
        \\    -Ta demo-git   ->  update aur demo-git
        \\    -Tf org.app.Id ->  update flatpak org.app.Id
        \\    -D linux       ->  downgrade linux
        \\    -Me linux      ->  mark explicit linux
        \\    -Md linux      ->  mark dependency linux
        \\    -Mga linux     ->  mark ignore --add linux
        \\    -Mh            ->  mark --help
        \\    -Mol           ->  mark hold --list
        \\    -Ih            ->  install --help
        \\    -Iav pkg sha   ->  install aur --version pkg sha
        \\    -Ife file      ->  install flatpak --ref-file file
        \\    -Ifu file      ->  install flatpak --bundle file
        \\    -Zs             ->  purify standard
        \\    -Zsc            ->  purify standard --cache
        \\    -Zf             ->  purify flatpak
        \\    -Isu firefox   ->  install standard -u firefox
        \\    -Sa query      ->  search aur query
        \\    -Sap yay       ->  search aur --pkgbuild yay
        \\    -Ssa query     ->  search standard and aur for query
        \\    -Ssafv query   ->  search standard (available), aur, and flatpak for query
        \\    -Sah           ->  search aur --help
        \\    -Vk ABCD       ->  recv keyring ABCD
        \\
        \\  In shortcode mode use --ui-mode instead of -U.
        \\
    );
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
        if (option.minimumArity == 0) try label.append(allocator, '[');
        try label.append(allocator, '<');
        try label.appendSlice(allocator, std.mem.trimStart(u8, option.name, "-"));
        try label.append(allocator, '>');
        if (option.minimumArity == 0) try label.append(allocator, ']');
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

test "action help shows shared and type-specific modifiers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    const command = manifest.findByPath("shelly install").?;
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    try render(arena.allocator(), &manifest, command, &output.writer);
    const rendered = output.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "shelly install [type]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Modifiers by Type:") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Shared:") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "--build-deps") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[types: standard, aur]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "aur only:") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "--chroot") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "-v, --version") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "-e, --ref-file") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "-u, --bundle") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Commands:") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "shelly install aur <packages>") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\nTypes:\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[shortcode: -Ia]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "AurManager.installPackages") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "installPackageVersion") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "AppImageManager.installAppImage") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "FlatpakManager.install_flatpak") != null);
}

test "sync action help lists standard and Flatpak variants" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    const command = manifest.findByPath("shelly sync").?;
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    try render(arena.allocator(), &manifest, command, &output.writer);
    const rendered = output.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "standard") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "flatpak") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[shortcode: -Ys]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[shortcode: -Yf]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "AlpmManager.sync") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "AppstreamManager.updateAllAppstreams") != null);
}

test "upgrade action help documents every backend and its actual modifiers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    const command = manifest.findByPath("shelly upgrade").?;
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    try render(arena.allocator(), &manifest, command, &output.writer);
    const rendered = output.writer.buffered();
    for ([_][]const u8{ "[shortcode: -Us]", "[shortcode: -Ux]", "[shortcode: -Ui]", "[shortcode: -Ua]", "[shortcode: -Uf]" }) |needle|
        try std.testing.expect(std.mem.indexOf(u8, rendered, needle) != null);
    for ([_][]const u8{ "--all", "--no-repo", "--no-aur", "--no-flatpak", "--no-appimage", "--check", "--singlepane" }) |needle|
        try std.testing.expect(std.mem.indexOf(u8, rendered, needle) != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "AlpmManager.sync") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "AurManager.getPackagesNeedingUpdate") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "FlatpakManager.upgrade_flatpaks") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "appimage.UpdateManager.get_updates") != null);
}

test "update action help documents targeted native backends and shortcodes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    const command = manifest.findByPath("shelly update").?;
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    try render(arena.allocator(), &manifest, command, &output.writer);
    const rendered = output.writer.buffered();
    for ([_][]const u8{ "[shortcode: -Ts]", "[shortcode: -Ta]", "[shortcode: -Tf]" }) |needle|
        try std.testing.expect(std.mem.indexOf(u8, rendered, needle) != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "AlpmManager.update_packages") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "AurManager.updatePackages") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "FlatpakManager.update_installed_flatpak") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "partial-upgrade warning and confirmation") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "--check") != null);
}

test "downgrade help renders its single default backend as a root command" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    var rendered = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer rendered.deinit();

    try render(
        arena.allocator(),
        &manifest,
        manifest.findByPath("shelly downgrade").?,
        &rendered.writer,
    );
    const value = rendered.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, value, "shelly downgrade [<package>] [options]") != null);
    try std.testing.expect(std.mem.indexOf(u8, value, "shelly downgrade [type]") == null);
    try std.testing.expect(std.mem.indexOf(u8, value, "--list-options") != null);
    try std.testing.expect(std.mem.indexOf(u8, value, "ArchiveManager.find_candidates") != null);
    try std.testing.expect(std.mem.indexOf(u8, value, "-D linux") != null);
    try std.testing.expect(std.mem.indexOf(u8, value, "-Ds linux") == null);
}

test "purify action help documents native standard and Flatpak backends" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    const command = manifest.findByPath("shelly purify").?;
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    try render(arena.allocator(), &manifest, command, &output.writer);
    const rendered = output.writer.buffered();
    for ([_][]const u8{ "[shortcode: -Zs]", "[shortcode: -Zf]", "--dry-run", "--orphans", "--cache" }) |needle|
        try std.testing.expect(std.mem.indexOf(u8, rendered, needle) != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "AlpmManager.purify") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "CacheManager") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[default: 3]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "FlatpakManager.remove_unused_dependencies") != null);
}

test "search help names the native method used by the selected type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    try render(
        arena.allocator(),
        &manifest,
        manifest.findByPath("shelly search flatpak").?,
        &output.writer,
    );
    const rendered = output.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "AppstreamManager.getAllRemoteCatalogs") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Flathub") == null);
}

test "help documents action targets and named subcommand shortcodes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    try render(arena.allocator(), &manifest, manifest.root(), &output.writer);
    const rendered = output.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "-<UppercaseAction><lowercaseTypeOrCommand><modifiers...>") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "-Isu firefox") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "-Ua") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "-Ux") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "-Vk ABCD") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "-Me linux") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "-Mga linux") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "-Mh            ->  mark --help") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "-Ife file      ->  install flatpak --ref-file file") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "-Ifu file      ->  install flatpak --bundle file") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Search may combine standard, AUR, and Flatpak types (s/a/f)") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "-Ssa query") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "-Sap yay       ->  search aur --pkgbuild yay") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "-Ssafv query") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\n    s  standard\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\n    S  standard\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "-ISu firefox") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "-<Type><Action>") == null);
}
