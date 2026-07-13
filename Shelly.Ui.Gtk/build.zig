const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // GTK's pkg-config file validates the development package and supplies the
    // complete transitive set of libraries needed at link time.
    const gtk4 = b.addModule("gtk4", .{
        .root_source_file = b.path("src/gtk/gtk.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    gtk4.linkSystemLibrary("gtk4", .{ .use_pkg_config = .force });

    const shelly_ui_gtk = b.addModule("Shelly_Ui_Gtk", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    shelly_ui_gtk.addImport("gtk4", gtk4);

    const exe = b.addExecutable(.{
        .name = "Shelly_Ui_Gtk",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "Shelly_Ui_Gtk", .module = shelly_ui_gtk },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const root_tests = b.addTest(.{ .root_module = shelly_ui_gtk });
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&b.addRunArtifact(root_tests).step);
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
}
