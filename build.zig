const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ---- Library Module ----
    const mod = b.addModule("matchconf", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // ---- Library Unit Tests ----
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // ---- Integration Tests ----
    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "matchconf", .module = mod },
            },
        }),
    });
    const run_integration_tests = b.addRunArtifact(integration_tests);

    // ---- Test Step ----
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_integration_tests.step);

    // ---- SSH Config Example ----
    const ssh_example = b.addExecutable(.{
        .name = "ssh-config-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/ssh_config.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "matchconf", .module = mod },
            },
        }),
    });

    // ---- Deploy Config Example ----
    const deploy_example = b.addExecutable(.{
        .name = "deploy-config-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/deploy_config.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "matchconf", .module = mod },
            },
        }),
    });

    // ---- Example Build Step ----
    const examples_step = b.step("examples", "Build all examples");
    examples_step.dependOn(&ssh_example.step);
    examples_step.dependOn(&deploy_example.step);

    // ---- Run Example Steps ----
    const run_ssh_cmd = b.addRunArtifact(ssh_example);
    const run_ssh_step = b.step("run-ssh-example", "Run the SSH config example");
    run_ssh_step.dependOn(&run_ssh_cmd.step);

    const run_deploy_cmd = b.addRunArtifact(deploy_example);
    const run_deploy_step = b.step("run-deploy-example", "Run the deploy config example");
    run_deploy_step.dependOn(&run_deploy_cmd.step);

    // ---- Install ----
    b.installArtifact(ssh_example);
    b.installArtifact(deploy_example);
}
