const std = @import("std");
const Zigalpm = @import("Zigalpm");
const output = @import("../output/config.zig");
const parser = @import("../cli/parser.zig");
const runtime = @import("../runtime/context.zig");
const spec = @import("../cli/spec.zig");
const xdg = @import("../runtime/xdg.zig");

const command_path = "shelly backup utility";

pub const Package = struct {
    name: []const u8,
    explicit: bool,
};

pub const Flatpak = struct {
    id: []const u8,
    kind: i32,
};

pub const State = struct {
    standard: []const Package,
    aur: []const Package,
    flatpak: []const Flatpak,
};

const Runner = struct {
    data: ?*anyopaque = null,
    call: *const fn (
        data: ?*anyopaque,
        context: *runtime.RuntimeContext,
    ) anyerror!State,
};

const real_runner: Runner = .{ .call = collectState };

pub fn dispatch(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
) !?u8 {
    if (!std.mem.eql(u8, invocation.command.path, command_path)) return null;
    return try executeWithRunner(context, invocation, real_runner);
}

fn executeWithRunner(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    runner: Runner,
) !u8 {
    if (!optionEnabled(invocation, "--export")) {
        try writeOperationRequired(context, invocation);
        return 1;
    }
    const state = runner.call(runner.data, context) catch |err| {
        try writeFailure(context, invocation, err);
        return 1;
    };

    var toml = std.Io.Writer.Allocating.init(context.allocator);
    defer toml.deinit();
    writeToml(context.allocator, &toml.writer, state) catch |err| {
        try writeFailure(context, invocation, err);
        return 1;
    };

    const file_name = exportFileName(context, optionValue(invocation, "--name")) catch |err| {
        try writeFailure(context, invocation, err);
        return 1;
    };
    const path = exportPath(context, optionValue(invocation, "--output"), file_name) catch |err| {
        try writeFailure(context, invocation, err);
        return 1;
    };
    writeExportFile(context, path, toml.writer.buffered()) catch |err| {
        try writeFailure(context, invocation, err);
        return 1;
    };

    try context.stdout.writeAll(toml.writer.buffered());
    if (toml.writer.buffered().len == 0 or toml.writer.buffered()[toml.writer.buffered().len - 1] != '\n')
        try context.stdout.writeByte('\n');
    try writeSuccess(context, path);
    return 0;
}

fn collectState(_: ?*anyopaque, context: *runtime.RuntimeContext) !State {
    var standard: std.ArrayList(Package) = .empty;
    var aur: std.ArrayList(Package) = .empty;
    var flatpaks: std.ArrayList(Flatpak) = .empty;

    {
        const manager = try Zigalpm.AlpmManager.init(
            context.allocator,
            context.environ,
            null,
            false,
            null,
        );
        defer manager.deinit();
        if (!manager.show_hidden_packages) _ = manager.toggle_hidden_packages();

        const installed = try manager.get_installed_packages();
        defer Zigalpm.alpm.OwnedPackage.deinitSlice(context.allocator, installed);
        const foreign = try manager.get_foreign_packages();
        defer Zigalpm.alpm.OwnedPackage.deinitSlice(context.allocator, foreign);

        for (installed) |package| {
            const name = package.name() orelse continue;
            if (containsOwnedPackage(foreign, name)) continue;
            try standard.append(context.allocator, .{
                .name = try context.allocator.dupe(u8, name),
                .explicit = package.install_reason() == .Explicit,
            });
        }
    }

    {
        const manager = try Zigalpm.AurManager.init(context.allocator, context.environ, .{
            .show_hidden_packages = true,
        });
        defer manager.deinit();
        const installed = try manager.getInstalledPackages();
        defer Zigalpm.aur.models.Package.deinitSlice(context.allocator, installed);
        for (installed) |package| {
            try aur.append(context.allocator, .{
                .name = try context.allocator.dupe(u8, package.name),
                .explicit = package.explicit,
            });
        }
    }

    {
        var manager = Zigalpm.FlatpakManager{
            .allocator = context.allocator,
            .io = context.io,
        };
        defer manager.deinit();
        const installed = try manager.list_installed_applications();
        defer Zigalpm.flatpak.manager.InstalledApplication.deinitSlice(context.allocator, installed);
        for (installed) |application| {
            try flatpaks.append(context.allocator, .{
                .id = try context.allocator.dupe(u8, application.id),
                .kind = application.kind,
            });
        }
    }

    return .{
        .standard = try standard.toOwnedSlice(context.allocator),
        .aur = try aur.toOwnedSlice(context.allocator),
        .flatpak = try flatpaks.toOwnedSlice(context.allocator),
    };
}

fn containsOwnedPackage(packages: []const Zigalpm.alpm.OwnedPackage, name: []const u8) bool {
    for (packages) |package| {
        if (std.mem.eql(u8, package.name() orelse continue, name)) return true;
    }
    return false;
}

fn writeToml(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    state: State,
) !void {
    const standard = try selectedPackages(allocator, state.standard);
    const aur = try selectedPackages(allocator, state.aur);
    const flatpaks = try selectedFlatpaks(allocator, state.flatpak);

    try writePackageArray(writer, "standard", standard);
    try writer.writeByte('\n');
    try writePackageArray(writer, "aur", aur);
    try writer.writeByte('\n');
    try writeFlatpakArray(writer, flatpaks);
}

fn selectedPackages(
    allocator: std.mem.Allocator,
    packages: []const Package,
) ![]Package {
    var selected: std.ArrayList(Package) = .empty;
    for (packages) |package| {
        if (package.explicit) try selected.append(allocator, package);
    }
    std.mem.sort(Package, selected.items, {}, struct {
        fn lessThan(_: void, left: Package, right: Package) bool {
            return std.mem.lessThan(u8, left.name, right.name);
        }
    }.lessThan);
    return selected.toOwnedSlice(allocator);
}

fn selectedFlatpaks(
    allocator: std.mem.Allocator,
    flatpaks: []const Flatpak,
) ![]Flatpak {
    var selected: std.ArrayList(Flatpak) = .empty;
    for (flatpaks) |application| {
        // Flatpak application refs are user-selected objects; runtime refs are
        // dependencies and are intentionally omitted from an explicit export.
        if (application.kind != 0 or containsFlatpak(selected.items, application.id)) continue;
        // The same ID may exist at both system and user scope. A TOML table
        // cannot contain duplicate keys, and reinstalling the ID only needs one
        // entry, so retain the system-first result returned by the manager.
        try selected.append(allocator, application);
    }
    std.mem.sort(Flatpak, selected.items, {}, struct {
        fn lessThan(_: void, left: Flatpak, right: Flatpak) bool {
            return std.mem.lessThan(u8, left.id, right.id);
        }
    }.lessThan);
    return selected.toOwnedSlice(allocator);
}

fn containsFlatpak(flatpaks: []const Flatpak, id: []const u8) bool {
    for (flatpaks) |application| {
        if (std.mem.eql(u8, application.id, id)) return true;
    }
    return false;
}

fn writePackageArray(
    writer: *std.Io.Writer,
    type_name: []const u8,
    packages: []const Package,
) !void {
    try writer.print("{s} = [\n", .{type_name});
    for (packages) |package| {
        try writer.writeAll("  ");
        try writeTomlString(writer, package.name);
        try writer.writeAll(",\n");
    }
    try writer.writeAll("]\n");
}

fn writeFlatpakArray(writer: *std.Io.Writer, flatpaks: []const Flatpak) !void {
    try writer.writeAll("flatpak = [\n");
    for (flatpaks) |application| {
        try writer.writeAll("  ");
        try writeTomlString(writer, application.id);
        try writer.writeAll(",\n");
    }
    try writer.writeAll("]\n");
}

fn writeTomlString(writer: *std.Io.Writer, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |byte| switch (byte) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        0x08 => try writer.writeAll("\\b"),
        0x0c => try writer.writeAll("\\f"),
        0x00...0x07, 0x0b, 0x0e...0x1f, 0x7f => try writer.print("\\u{X:0>4}", .{byte}),
        else => try writer.writeByte(byte),
    };
    try writer.writeByte('"');
}

fn exportFileName(
    context: *runtime.RuntimeContext,
    requested_name: ?[]const u8,
) ![]const u8 {
    if (requested_name) |name| {
        if (name.len > 0) {
            if (std.mem.endsWith(u8, name, ".toml"))
                return context.allocator.dupe(u8, name);
            return std.fmt.allocPrint(context.allocator, "{s}.toml", .{name});
        }
    }

    const seconds = std.Io.Clock.real.now(context.io).toSeconds();
    if (seconds < 0) return error.InvalidTimestamp;
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(seconds) };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();
    return std.fmt.allocPrint(
        context.allocator,
        "{d:0>4}{d:0>2}{d:0>2}{d:0>2}{d:0>2}{d:0>2}_shelly.toml",
        .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        },
    );
}

fn exportPath(
    context: *runtime.RuntimeContext,
    requested_output: ?[]const u8,
    file_name: []const u8,
) ![]const u8 {
    if (requested_output) |directory| {
        if (directory.len > 0)
            return std.fs.path.join(context.allocator, &.{ directory, file_name });
    }
    return xdg.shellyCache(context, &.{file_name});
}

fn writeExportFile(
    context: *runtime.RuntimeContext,
    path: []const u8,
    contents: []const u8,
) !void {
    if (std.fs.path.dirname(path)) |directory|
        try std.Io.Dir.cwd().createDirPath(context.io, directory);
    var file = try std.Io.Dir.cwd().createFile(context.io, path, .{});
    defer file.close(context.io);
    try file.writeStreamingAll(context.io, contents);
}

fn writeSuccess(context: *runtime.RuntimeContext, path: []const u8) !void {
    if (output.supportsAnsi(context))
        try context.stdout.print("\x1b[34mBackup exported to: {s}\x1b[0m\n", .{path})
    else
        try context.stdout.print("Backup exported to: {s}\n", .{path});
}

fn writeFailure(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    err: anyerror,
) !void {
    const message = try std.fmt.allocPrint(
        context.allocator,
        "Unable to export backup: {t}",
        .{err},
    );
    if (invocation.globals.ui_mode)
        try output.writeErrorFrame(context, message)
    else
        try context.stderr.print("{s}\n", .{message});
}

fn writeOperationRequired(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
) !void {
    const message = "No backup operation selected. Use --export.";
    if (invocation.globals.ui_mode)
        try output.writeErrorFrame(context, message)
    else
        try context.stderr.print("{s}\n", .{message});
}

fn optionEnabled(invocation: *const parser.Invocation, name: []const u8) bool {
    for (invocation.options) |option| {
        if (!std.mem.eql(u8, option.name, name)) continue;
        return option.value == null or !std.ascii.eqlIgnoreCase(option.value.?, "false");
    }
    return false;
}

fn optionValue(invocation: *const parser.Invocation, name: []const u8) ?[]const u8 {
    for (invocation.options) |option| {
        if (std.mem.eql(u8, option.name, name)) return option.value;
    }
    return null;
}

const sample_state: State = .{
    .standard = &.{
        .{ .name = "zlib", .explicit = false },
        .{ .name = "linux", .explicit = true },
        .{ .name = "base", .explicit = true },
    },
    .aur = &.{
        .{ .name = "aur-dependency", .explicit = false },
        .{ .name = "yay", .explicit = true },
    },
    .flatpak = &.{
        .{ .id = "org.example.Runtime", .kind = 1 },
        .{ .id = "org.mozilla.firefox", .kind = 0 },
        .{ .id = "org.mozilla.firefox", .kind = 0 },
    },
};

fn sampleRunner(_: ?*anyopaque, _: *runtime.RuntimeContext) !State {
    return sample_state;
}

test "backup is a standalone -B command with export and local modifiers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const manifest = try spec.Manifest.load(allocator);

    const base = try @import("../cli/shortcodes.zig").translate(allocator, &manifest, &.{"-B"});
    try std.testing.expect(base == .translated);
    try expectArguments(&.{"backup"}, base.translated);

    const export_state = try @import("../cli/shortcodes.zig").translate(allocator, &manifest, &.{"-Be"});
    try std.testing.expect(export_state == .translated);
    try expectArguments(&.{ "backup", "-e" }, export_state.translated);

    const named = try @import("../cli/shortcodes.zig").translate(
        allocator,
        &manifest,
        &.{ "-Bea", "snapshot" },
    );
    try std.testing.expect(named == .translated);
    try expectArguments(&.{ "backup", "-e", "-a", "snapshot" }, named.translated);

    const help = try @import("../cli/shortcodes.zig").translate(allocator, &manifest, &.{"-Bh"});
    try std.testing.expect(help == .translated);
    try expectArguments(&.{ "backup", "--help" }, help.translated);

    const long_form = try parser.parse(allocator, &manifest, &.{ "backup", "--export" });
    try std.testing.expect(long_form == .dispatch);
    try std.testing.expectEqualStrings(command_path, long_form.dispatch.command.path);

    const removed_export_command = try parser.parse(allocator, &manifest, &.{"export"});
    try std.testing.expect(removed_export_command == .failure);
    try std.testing.expectEqualStrings(
        "Unrecognized command or argument 'export'.",
        removed_export_command.failure.message,
    );

    const removed_export_shortcode = try @import("../cli/shortcodes.zig").translate(
        allocator,
        &manifest,
        &.{"-E"},
    );
    try std.testing.expect(removed_export_shortcode == .unchanged);
}

test "backup requires an operation before collecting package state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    const outcome = try parser.parse(arena.allocator(), &manifest, &.{"backup"});
    try std.testing.expect(outcome == .dispatch);

    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    var context: runtime.RuntimeContext = .{
        .allocator = arena.allocator(),
        .io = std.testing.io,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
    };
    var called = false;
    const runner: Runner = .{ .data = &called, .call = struct {
        fn run(data: ?*anyopaque, _: *runtime.RuntimeContext) !State {
            const observed: *bool = @ptrCast(@alignCast(data.?));
            observed.* = true;
            return sample_state;
        }
    }.run };
    try std.testing.expectEqual(@as(u8, 1), try executeWithRunner(&context, &outcome.dispatch, runner));
    try std.testing.expect(!called);
    try std.testing.expectEqualStrings(
        "No backup operation selected. Use --export.\n",
        stderr.writer.buffered(),
    );
}

test "backup TOML uses top-level type arrays without versions or dependencies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rendered = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer rendered.deinit();

    try writeToml(arena.allocator(), &rendered.writer, sample_state);
    try std.testing.expectEqualStrings(
        \\standard = [
        \\  "base",
        \\  "linux",
        \\]
        \\
        \\aur = [
        \\  "yay",
        \\]
        \\
        \\flatpak = [
        \\  "org.mozilla.firefox",
        \\]
        \\
    , rendered.writer.buffered());
    try std.testing.expect(std.mem.indexOf(u8, rendered.writer.buffered(), "zlib") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.writer.buffered(), "aur-dependency") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.writer.buffered(), "Runtime") == null);
}

test "backup export writes named TOML files to the requested directory" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var absolute_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const absolute_length = try temporary.dir.realPath(std.testing.io, &absolute_buffer);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());
    const outcome = try parser.parse(arena.allocator(), &manifest, &.{
        "backup",
        "--export",
        "--name",
        "machine",
        "--output",
        absolute_buffer[0..absolute_length],
    });
    try std.testing.expect(outcome == .dispatch);

    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    var context: runtime.RuntimeContext = .{
        .allocator = arena.allocator(),
        .io = std.testing.io,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
    };
    try std.testing.expectEqual(
        @as(u8, 0),
        try executeWithRunner(&context, &outcome.dispatch, .{ .call = sampleRunner }),
    );

    const saved = try temporary.dir.readFileAlloc(
        std.testing.io,
        "machine.toml",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(saved);
    try std.testing.expect(std.mem.startsWith(u8, saved, "standard = [\n"));
    try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), saved) != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), "machine.toml") != null);
    try std.testing.expectEqual(@as(usize, 0), stderr.writer.buffered().len);
}

test "TOML package names are escaped" {
    var rendered = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer rendered.deinit();
    try writePackageArray(&rendered.writer, "standard", &.{.{
        .name = "quoted\"package",
        .explicit = true,
    }});
    try std.testing.expectEqualStrings(
        "standard = [\n  \"quoted\\\"package\",\n]\n",
        rendered.writer.buffered(),
    );
}

fn expectArguments(expected: []const []const u8, actual: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |wanted, observed|
        try std.testing.expectEqualStrings(wanted, observed);
}
