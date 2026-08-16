const std = @import("std");
const Zigalpm = @import("Zigalpm");
const runtime = @import("../runtime/context.zig");
const parser = @import("../cli/parser.zig");

const command_path = "shelly build build";

pub fn dispatch(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
) !?u8 {
    if (!std.mem.eql(u8, invocation.command.path, command_path)) return null;
    try Zigalpm.builder.secureBuilderProcess();
    const has_location: bool = invocation.positionals.len == 0;
    const pkgbuild_path = if (!has_location) "PKGBUILD" else invocation.positionals[0];
    const pkgbuild_content = try std.Io.Dir.cwd().readFile(
        context.io,
        pkgbuild_path,
        context.allocator,
        .limited(32 * 1024 * 1024),
    );
    if (!optionEnabled(invocation, "--reviewed")) {}
    return "";
}

fn optionEnabled(invocation: *const parser.Invocation, name: []const u8) bool {
    for (invocation.options) |option| {
        if (!std.mem.eql(u8, option.name, name)) continue;
        const value = option.value orelse return true;
        return !std.ascii.eqlIgnoreCase(value, "false");
    }
    return false;
}
