const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const clap = b.dependency("clap", .{
        .target = target,
        .optimize = optimize,
    });
    const clap_mod = clap.module("clap");

    const vaxis = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });
    const vaxis_mod = vaxis.module("vaxis");

    // const main_step = b.step("main", "Build main");
    // {
    //     const exe_mod = b.createModule(.{
    //         .root_source_file = b.path("src/main.zig"),
    //         .target = target,
    //         .optimize = optimize,
    //         // To use the C allocator
    //         .link_libc = true,
    //     });
    //     exe_mod.addImport("clap", clap_mod);
    //     exe_mod.addImport("vaxis", vaxis_mod);

    //     const exe = b.addExecutable(.{
    //         .name = "zbonsai",
    //         .root_module = exe_mod,
    //     });

    //     const compile_step = b.step("build-main", b.fmt("Build {s}", .{"main"}));
    //     compile_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
    //     main_step.dependOn(compile_step);

    //     const run_cmd = b.addRunArtifact(exe);
    //     if (b.args) |args| {
    //         run_cmd.addArgs(args);
    //     }
    //     const run_step = b.step(b.fmt("run-{s}", .{"main"}), b.fmt("Run {s}", .{"main"}));
    //     run_step.dependOn(&run_cmd.step);
    // }

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        // To use the C allocator
        .link_libc = true,
    });
    exe_mod.addImport("clap", clap_mod);
    exe_mod.addImport("vaxis", vaxis_mod);

    const exe = b.addExecutable(.{
        .name = "zbonsai",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run unit tests");
    const unit_tests = b.addTest(.{
        .root_module = exe_mod,
        // .test_runner = .{ 
        //     .path = b.path("test/test_runner.zig"),
        //     .mode = .simple,
        // },
    });
    // unit_tests.linkLibC();
    // unit_tests.root_module.addImport("clap", clap.module("clap"));
    // unit_tests.root_module.addImport("vaxis", vaxis.module("vaxis"));
    const run_unit_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_tests.step);

    // Create "all" step
    // const all_step = b.step("all", "Build everything and runs all tests");
    // all_step.dependOn(main_step);
    // b.default_step.dependOn(all_step);
}
