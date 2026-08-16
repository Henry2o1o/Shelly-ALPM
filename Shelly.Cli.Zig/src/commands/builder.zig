const std = @import("std");
const Zigalpm = @import("Zigalpm");
const runtime = @import("../runtime/context.zig");
const parser = @import("../cli/parser.zig");
const PkgbuildValidation = Zigalpm.aur.PkgbuildValidation;

const command_path = "shelly build build";

pub fn dispatch(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
) !?u8 {
    if (!std.mem.eql(u8, invocation.command.path, command_path)) return null;
    try Zigalpm.builder.secureBuilderProcess();
    const pkgbuild_path = if (invocation.positionals.len == 0) "PKGBUILD" else invocation.positionals[0];
    const pkgbuild_content = try std.Io.Dir.cwd().readFile(
        context.io,
        pkgbuild_path,
        context.allocator,
        .limited(32 * 1024 * 1024),
    );
    const pkgbuild_parser = Zigalpm.pkgbuild.Parser{
        .allocator = context.allocator,
        .io = context.io,
    };

    var names = try pkgbuild_parser.package_names_content(pkgbuild_content);
    defer names.deinit(context.allocator);

    const package_builds = try context.allocator.alloc(
        Zigalpm.pkgbuild.parser.Pkgbuild,
        names.items.len,
    );

    var parsed_count: usize = 0;
    defer {
        for (package_builds[0..parsed_count]) |*pkgbuild|
            pkgbuild.deinit(context.allocator);
        context.allocator.free(package_builds);
    }

    const build_directory = std.fs.path.dirname(pkgbuild_path) orelse ".";
    for (names.items, package_builds) |name, *pkgbuild| {
        pkgbuild.* = try (Zigalpm.pkgbuild.Parser{
            .allocator = context.allocator,
            .io = context.io,
            .selected_package_name = name,
        }).parser_content(pkgbuild_content, build_directory);

        parsed_count += 1;
    }

    if (!optionEnabled(invocation, "--reviewed")) {
        for (package_builds) |*pkgbuild| {
            var validation: PkgbuildValidation = Zigalpm.aur.validatePkgbuildInfo(
                context.allocator,
                context.io,
                pkgbuild,
                build_directory,
                pkgbuild_content,
            );
            defer validation.deinit(context.allocator);
        }
        //todo create and store the validation for question results
    }
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
