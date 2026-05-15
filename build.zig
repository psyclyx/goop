const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Snail (GPU text rendering) ──
    const snail_dep = b.dependency("snail", .{
        .target = target,
        .optimize = optimize,
        .@"c-api" = false,
        .@"cpu-renderer" = false,
        .vulkan = false,
    });
    const snail_mod = snail_dep.module("snail");

    // ── Core goop module ──
    const goop_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    goop_mod.addIncludePath(b.path("include"));
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

    const shared_lib = b.addLibrary(.{
        .name = "goop",
        .root_module = goop_mod,
        .linkage = .dynamic,
    });
    b.installArtifact(shared_lib);

    b.getInstallStep().dependOn(&b.addInstallHeaderFile(b.path("include/goop.h"), "goop.h").step);

    const build_lib = b.step("build-lib", "Build the static library");
    build_lib.dependOn(&b.addInstallArtifact(lib, .{}).step);

    const build_shared_lib = b.step("build-shared-lib", "Build the shared library");
    build_shared_lib.dependOn(&b.addInstallArtifact(shared_lib, .{}).step);

    // ── C API example ──
    const c_example = b.addExecutable(.{
        .name = "goop-c-example",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    c_example.root_module.addCSourceFile(.{
        .file = b.path("examples/c/basic.c"),
        .flags = &.{"-std=c11"},
    });
    c_example.root_module.addIncludePath(b.path("include"));
    c_example.root_module.linkLibrary(lib);

    const build_c_example = b.step("build-c-example", "Build the headless C API example");
    build_c_example.dependOn(&c_example.step);

    const run_c_example = b.addRunArtifact(c_example);
    const c_example_step = b.step("c-example", "Build and run the headless C API example");
    c_example_step.dependOn(&run_c_example.step);

    // ── Demo renderer module (shared by demo, file-manager demo, perf, screenshot) ──
    const render_mod = b.createModule(.{
        .root_source_file = b.path("demo/render.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    render_mod.addImport("goop", goop_mod);
    render_mod.addImport("snail", snail_mod);
    render_mod.linkSystemLibrary("gl", .{});

    // ── Demo executable ──
    const demo_mod = b.createModule(.{
        .root_source_file = b.path("demo/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    demo_mod.addImport("goop", goop_mod);
    demo_mod.addImport("snail", snail_mod);
    demo_mod.addImport("goop_demo_render", render_mod);
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

    const build_demo = b.step("build-demo", "Build the demo executable");
    build_demo.dependOn(&b.addInstallArtifact(demo_exe, .{}).step);

    const run_demo = b.addRunArtifact(demo_exe);
    run_demo.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_demo.addArgs(args);

    const demo_step = b.step("demo", "Build and run the demo");
    demo_step.dependOn(&run_demo.step);

    const file_manager_demo_mod = b.createModule(.{
        .root_source_file = b.path("demo/file_manager_main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    file_manager_demo_mod.addImport("goop", goop_mod);
    file_manager_demo_mod.addImport("snail", snail_mod);
    file_manager_demo_mod.addImport("goop_demo_render", render_mod);
    file_manager_demo_mod.addIncludePath(b.path("demo/protocol"));
    file_manager_demo_mod.addCSourceFile(.{ .file = b.path("demo/protocol/xdg-shell-protocol.c") });
    file_manager_demo_mod.linkSystemLibrary("wayland-client", .{});
    file_manager_demo_mod.linkSystemLibrary("wayland-cursor", .{});
    file_manager_demo_mod.linkSystemLibrary("wayland-egl", .{});
    file_manager_demo_mod.linkSystemLibrary("egl", .{});
    file_manager_demo_mod.linkSystemLibrary("xkbcommon", .{});
    file_manager_demo_mod.linkSystemLibrary("gl", .{});

    const file_manager_demo_exe = b.addExecutable(.{
        .name = "goop-file-manager-demo",
        .root_module = file_manager_demo_mod,
    });
    b.installArtifact(file_manager_demo_exe);

    const build_file_manager_demo = b.step("build-file-manager-demo", "Build the file manager demo executable");
    build_file_manager_demo.dependOn(&b.addInstallArtifact(file_manager_demo_exe, .{}).step);

    const run_file_manager_demo = b.addRunArtifact(file_manager_demo_exe);
    run_file_manager_demo.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_file_manager_demo.addArgs(args);

    const file_manager_demo_step = b.step("file-manager-demo", "Build and run the file manager demo");
    file_manager_demo_step.dependOn(&run_file_manager_demo.step);

    // ── Headless perf round ──
    const perf_mod = b.createModule(.{
        .root_source_file = b.path("tools/perf_round.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    perf_mod.addImport("goop", goop_mod);
    perf_mod.addImport("goop_demo_render", render_mod);
    perf_mod.addImport("snail", snail_mod);
    perf_mod.linkSystemLibrary("egl", .{});
    perf_mod.linkSystemLibrary("gl", .{});

    const perf_exe = b.addExecutable(.{
        .name = "goop-perf-round",
        .root_module = perf_mod,
    });

    const build_perf = b.step("build-perf-round", "Build the headless perf benchmark");
    build_perf.dependOn(&perf_exe.step);

    const run_perf = b.addRunArtifact(perf_exe);
    const perf_step = b.step("perf-round", "Build and run the headless perf benchmark");
    perf_step.dependOn(&run_perf.step);

    // ── Headless screenshot ──
    const fm_lib_mod = b.createModule(.{
        .root_source_file = b.path("demo/file_manager_main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    fm_lib_mod.addImport("goop", goop_mod);
    fm_lib_mod.addImport("snail", snail_mod);
    fm_lib_mod.addImport("goop_demo_render", render_mod);
    fm_lib_mod.addIncludePath(b.path("demo/protocol"));
    fm_lib_mod.addCSourceFile(.{ .file = b.path("demo/protocol/xdg-shell-protocol.c") });
    fm_lib_mod.linkSystemLibrary("wayland-client", .{});
    fm_lib_mod.linkSystemLibrary("wayland-cursor", .{});
    fm_lib_mod.linkSystemLibrary("wayland-egl", .{});
    fm_lib_mod.linkSystemLibrary("egl", .{});
    fm_lib_mod.linkSystemLibrary("xkbcommon", .{});
    fm_lib_mod.linkSystemLibrary("gl", .{});

    const screenshot_mod = b.createModule(.{
        .root_source_file = b.path("tools/screenshot.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    screenshot_mod.addImport("goop", goop_mod);
    screenshot_mod.addImport("goop_demo_render", render_mod);
    screenshot_mod.addImport("snail", snail_mod);
    screenshot_mod.addImport("file_manager", fm_lib_mod);
    screenshot_mod.linkSystemLibrary("egl", .{});
    screenshot_mod.linkSystemLibrary("gl", .{});
    screenshot_mod.linkSystemLibrary("wayland-client", .{});
    screenshot_mod.linkSystemLibrary("wayland-cursor", .{});
    screenshot_mod.linkSystemLibrary("wayland-egl", .{});
    screenshot_mod.linkSystemLibrary("xkbcommon", .{});

    const screenshot_exe = b.addExecutable(.{
        .name = "goop-screenshot",
        .root_module = screenshot_mod,
    });

    const build_screenshot = b.step("build-screenshot", "Build the headless screenshot tool");
    build_screenshot.dependOn(&screenshot_exe.step);

    const ppm_path = b.pathFromRoot("docs/assets/goop-file-manager-demo.ppm");
    const png_path = b.pathFromRoot("docs/assets/goop-file-manager-demo.png");

    const run_screenshot = b.addRunArtifact(screenshot_exe);
    run_screenshot.addArg("--output");
    run_screenshot.addArg(ppm_path);
    run_screenshot.addArg("--dir");
    run_screenshot.addArg(b.pathFromRoot("."));
    run_screenshot.addArg("--width");
    run_screenshot.addArg("1280");
    run_screenshot.addArg("--height");
    run_screenshot.addArg("720");

    const convert_step = b.addSystemCommand(&.{ "magick", ppm_path, png_path });
    convert_step.step.dependOn(&run_screenshot.step);

    const cleanup_step = b.addSystemCommand(&.{ "rm", "-f", ppm_path });
    cleanup_step.step.dependOn(&convert_step.step);

    const screenshot_step = b.step("screenshot", "Render the file manager demo to docs/assets/");
    screenshot_step.dependOn(&cleanup_step.step);

    // ── Tests ──
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addIncludePath(b.path("include"));
    test_mod.addIncludePath(b.path("vendor/clay"));
    test_mod.addCSourceFile(.{
        .file = b.path("vendor/clay/clay.c"),
    });

    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(unit_tests);

    const file_manager_test_mod = b.createModule(.{
        .root_source_file = b.path("demo/file_manager_main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    file_manager_test_mod.addImport("goop", goop_mod);
    file_manager_test_mod.addImport("snail", snail_mod);
    file_manager_test_mod.addImport("goop_demo_render", render_mod);
    file_manager_test_mod.addIncludePath(b.path("demo/protocol"));
    file_manager_test_mod.addCSourceFile(.{ .file = b.path("demo/protocol/xdg-shell-protocol.c") });
    file_manager_test_mod.linkSystemLibrary("wayland-client", .{});
    file_manager_test_mod.linkSystemLibrary("wayland-cursor", .{});
    file_manager_test_mod.linkSystemLibrary("wayland-egl", .{});
    file_manager_test_mod.linkSystemLibrary("egl", .{});
    file_manager_test_mod.linkSystemLibrary("xkbcommon", .{});
    file_manager_test_mod.linkSystemLibrary("gl", .{});

    const file_manager_unit_tests = b.addTest(.{ .root_module = file_manager_test_mod });
    const run_file_manager_tests = b.addRunArtifact(file_manager_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_file_manager_tests.step);
    test_step.dependOn(&run_c_example.step);
}
