const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 创建 logging 模块
    const logging_module = b.addModule("zig-logging", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // 测试
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_tests.step);

    // 示例：basic
    const example = b.addExecutable(.{
        .name = "example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/basic.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    example.root_module.addImport("zig-logging", logging_module);

    const install_example = b.addInstallArtifact(example, .{});
    const run_example = b.addRunArtifact(example);
    run_example.step.dependOn(&install_example.step);
    b.step("run-example", "Run basic example").dependOn(&run_example.step);
}
