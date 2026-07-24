const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const version_str = b.option([]const u8, "version", "Override version string") orelse "0.2.1";

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
}
