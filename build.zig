const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zzz = b.dependency("zzz", .{
        .target = target,
        .optimize = optimize,
    }).module("zzz");

    const czalloc = b.dependency("czalloc", .{
        .target = target,
        .optimize = optimize,
    }).module("czalloc");

    const zvips = b.dependency("zvips", .{
        .target = target,
        .optimize = optimize,
    }).module("zvips");

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("zzz", zzz);
    exe_mod.addImport("czalloc", czalloc);
    exe_mod.addImport("zvips", zvips);

    const exe = b.addExecutable(.{
        .name = "imagination",
        .root_module = exe_mod,
        .use_llvm = true,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
