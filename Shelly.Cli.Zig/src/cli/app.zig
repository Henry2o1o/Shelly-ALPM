const std = @import("std");
const help = @import("help.zig");
const parser = @import("parser.zig");
const shortcodes = @import("shortcodes.zig");
const spec = @import("spec.zig");
const runtime = @import("../runtime/context.zig");

pub fn run(context: *runtime.RuntimeContext, arguments: []const []const u8) !u8 {
    const manifest = try spec.Manifest.load(context.allocator);
    const translation = try shortcodes.translate(context.allocator, arguments);
    const translated = switch (translation) {
        .unchanged => |value| value,
        .translated => |value| value,
        .failure => |message| {
            try context.stderr.print("{s}\n", .{message});
            return 1;
        },
    };

    const outcome = try parser.parse(context.allocator, &manifest, translated);
    return switch (outcome) {
        .help => |command| renderHelp(context, &manifest, command),
        .version => printVersion(context, &manifest),
        .dispatch => |invocation| context.dispatch(&invocation),
        .failure => |failure| renderFailure(context, &manifest, failure),
    };
}

fn renderHelp(
    context: *runtime.RuntimeContext,
    manifest: *const spec.Manifest,
    command: *const spec.Command,
) !u8 {
    try help.render(context.allocator, manifest, command, context.stdout);
    return 0;
}

fn printVersion(context: *runtime.RuntimeContext, manifest: *const spec.Manifest) !u8 {
    try context.stdout.print("{s}\n", .{manifest.informationalVersion});
    return 0;
}

fn renderFailure(
    context: *runtime.RuntimeContext,
    manifest: *const spec.Manifest,
    failure: parser.Failure,
) !u8 {
    try context.stderr.print("{s}\n\n", .{failure.message});
    if (failure.leading_help_newline) try context.stdout.writeByte('\n');
    try help.render(context.allocator, manifest, failure.help_command, context.stdout);
    return 1;
}

test "no arguments dispatch upgrade-all through the injected runtime" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    var observed = false;
    var context: runtime.RuntimeContext = .{
        .allocator = arena.allocator(),
        .io = std.testing.io,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
        .dispatcher = .{ .user_data = &observed, .call = struct {
            fn dispatch(
                data: ?*anyopaque,
                _: *runtime.RuntimeContext,
                invocation: *const parser.Invocation,
            ) !u8 {
                const called: *bool = @ptrCast(@alignCast(data.?));
                called.* = true;
                try std.testing.expectEqualStrings("shelly upgrade-all", invocation.command.path);
                return 37;
            }
        }.dispatch },
    };

    try std.testing.expectEqual(@as(u8, 37), try run(&context, &.{}));
    try std.testing.expect(observed);
}

test "help and parser errors bypass dispatch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
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

    try std.testing.expectEqual(@as(u8, 0), try run(&context, &.{ "query", "--help" }));
    try std.testing.expect(std.mem.indexOf(u8, stdout.writer.buffered(), "shelly query [<package>]") != null);

    stdout.writer.end = 0;
    try std.testing.expectEqual(@as(u8, 1), try run(&context, &.{ "config", "get" }));
    try std.testing.expect(std.mem.indexOf(u8, stderr.writer.buffered(), "Required argument 'key' missing") != null);
}
