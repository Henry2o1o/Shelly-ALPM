const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zigalpm_dependency = b.dependency("zigalpm", .{
        .target = target,
        .optimize = optimize,
    });
    const zigalpm = zigalpm_dependency.module("Zigalpm");

    const command_contract = b.createModule(.{
        .root_source_file = b.path("contract/generated/command-contract.zig"),
    });
    const config_defaults = b.createModule(.{
        .root_source_file = b.path("contract/generated/config-defaults.zig"),
    });

    const cli = b.addModule("Shelly_Cli_Zig", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli.addImport("Zigalpm", zigalpm);
    cli.addImport("command_contract", command_contract);
    cli.addImport("config_defaults", config_defaults);

    const executable_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    executable_module.addImport("Shelly_Cli_Zig", cli);
    executable_module.addImport("Zigalpm", zigalpm);

    const executable = b.addExecutable(.{
        .name = "shelly",
        .root_module = executable_module,
    });
    b.installArtifact(executable);

    const run_command = b.addRunArtifact(executable);
    run_command.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_command.addArgs(args);

    const run_step = b.step("run", "Run Shelly");
    run_step.dependOn(&run_command.step);

    const module_tests = b.addTest(.{
        .root_module = cli,
    });
    const run_module_tests = b.addRunArtifact(module_tests);

    const executable_tests = b.addTest(.{
        .root_module = executable_module,
    });
    const run_executable_tests = b.addRunArtifact(executable_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_module_tests.step);
    test_step.dependOn(&run_executable_tests.step);

    const update_contract_command = b.addSystemCommand(&.{ "bash", "scripts/update-contract.sh" });
    const update_contract_step = b.step("contract-update", "Regenerate the C# CLI compatibility contract");
    update_contract_step.dependOn(&update_contract_command.step);

    const check_contract_command = b.addSystemCommand(&.{ "bash", "scripts/check-contract.sh" });
    const check_contract_step = b.step("contract-check", "Verify the C# CLI compatibility contract");
    check_contract_step.dependOn(&check_contract_command.step);

    const check_foundation_command = b.addSystemCommand(&.{ "bash", "scripts/check-foundation.sh" });
    const check_foundation_step = b.step("foundation-check", "Verify the native action-first Zig CLI foundation");
    check_foundation_step.dependOn(&check_foundation_command.step);

    const check_phase3_command = b.addSystemCommand(&.{ "bash", "scripts/check-phase3.sh" });
    const check_phase3_step = b.step("phase3-check", "Verify Zig configuration and output behavior against C# golden files");
    check_phase3_step.dependOn(&check_phase3_command.step);
}
