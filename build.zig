const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Snail (GPU text rendering) ──
    const snail_dep = b.dependency("snail", .{});
    const snail_mod = @import("snail").module(snail_dep.builder, target, optimize);

    // ── Core goop module ──
    const goop_mod = b.createModule(.{
        .root_source_file = b.path("src/goop.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    goop_mod.addImport("snail", snail_mod);
    goop_mod.addIncludePath(b.path("vendor/clay"));
    goop_mod.addCSourceFile(.{
        .file = b.path("vendor/clay/clay.c"),
    });

    // ── Static library ──
    const lib = b.addLibrary(.{
        .name = "goop",
        .root_module = goop_mod,
        .linkage = .static,
    });
    b.installArtifact(lib);

    // ── Demo executable ──
    const demo_mod = b.createModule(.{
        .root_source_file = b.path("demo/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    demo_mod.addImport("goop", goop_mod);
    demo_mod.addImport("snail", snail_mod);
    demo_mod.addIncludePath(b.path("demo/protocol"));
    demo_mod.addCSourceFile(.{ .file = b.path("demo/protocol/xdg-shell-protocol.c") });
    demo_mod.linkSystemLibrary("wayland-client", .{});
    demo_mod.linkSystemLibrary("wayland-egl", .{});
    demo_mod.linkSystemLibrary("egl", .{});
    demo_mod.linkSystemLibrary("xkbcommon", .{});
    demo_mod.linkSystemLibrary("gl", .{});

    const demo_exe = b.addExecutable(.{
        .name = "goop-demo",
        .root_module = demo_mod,
    });
    b.installArtifact(demo_exe);

    const run_demo = b.addRunArtifact(demo_exe);
    run_demo.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_demo.addArgs(args);

    const demo_step = b.step("demo", "Build and run the demo");
    demo_step.dependOn(&run_demo.step);

    // ── Tests ──
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/goop.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addImport("snail", snail_mod);
    test_mod.addIncludePath(b.path("vendor/clay"));
    test_mod.addCSourceFile(.{
        .file = b.path("vendor/clay/clay.c"),
    });

    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
