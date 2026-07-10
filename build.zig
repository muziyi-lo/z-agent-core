const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const version_str = b.option([]const u8, "version", "Override version string") orelse "0.1.0";

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version_str);

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build_options", .module = build_options.createModule() },
        },
    });

    const exe = b.addExecutable(.{
        .name = "z-agent-core",
        .root_module = root_module,
        .version = std.SemanticVersion.parse(version_str) catch @panic("bad version"),
    });

    exe.root_module.addWin32ResourceFile(.{ .file = b.path("src/Logo.rc") });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Architecture check
    const check_arch = b.addSystemCommand(&.{
        "node", "../../.opencode/skills/zig-dev/scripts/check-arch.mjs",
        ".", "--fail-on-any",
    });
    check_arch.step.dependOn(b.getInstallStep());

    const check_step = b.step("check", "Build + architecture scan");
    check_step.dependOn(&check_arch.step);
    check_step.dependOn(b.getInstallStep());

    // Tests (runner pattern)
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build_options", .module = build_options.createModule() },
        },
    });
    const test_runner = b.addTest(.{
        .root_module = test_module,
    });
    const run_tests = b.addRunArtifact(test_runner);
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_tests.step);
}
