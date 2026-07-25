const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Snail (backend-neutral text/vector preparation) ──
    const snail_dep = b.dependency("snail", .{
        .target = target,
        .optimize = optimize,
    });
    const snail_mod = snail_dep.module("snail");

    // ── Public architecture modules ──
    //
    // Keep these as separately named modules even while compatibility APIs
    // remain available through `goop`. Build wiring is the enforceable
    // dependency graph; consumers do not reach through a monolithic root.
    const display_mod = b.addModule("goop_display", .{
        .root_source_file = b.path("src/display.zig"),
        .target = target,
        .optimize = optimize,
    });

    const ui_mod = b.addModule("goop_ui", .{
        .root_source_file = b.path("src/ui.zig"),
        .target = target,
        .optimize = optimize,
    });
    ui_mod.addImport("goop_display", display_mod);

    const components_mod = b.addModule("goop_components", .{
        .root_source_file = b.path("src/components.zig"),
        .target = target,
        .optimize = optimize,
    });
    components_mod.addImport("goop_ui", ui_mod);

    const driver_mod = b.addModule("goop_driver", .{
        .root_source_file = b.path("src/driver.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    driver_mod.addImport("goop_display", display_mod);
    driver_mod.addImport("goop_ui", ui_mod);
    driver_mod.addIncludePath(b.path("vendor/clay"));
    driver_mod.addCSourceFile(.{
        .file = b.path("vendor/clay/clay.c"),
    });

    const snail_adapter_mod = b.addModule("goop_snail", .{
        .root_source_file = b.path("src/snail_adapter.zig"),
        .target = target,
        .optimize = optimize,
    });
    snail_adapter_mod.addImport("goop_display", display_mod);
    snail_adapter_mod.addImport("snail", snail_mod);

    const graphics_vulkan_mod = b.addModule("goop_graphics_vulkan", .{
        .root_source_file = b.path("src/graphics/vulkan.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    graphics_vulkan_mod.linkSystemLibrary("vulkan", .{});

    const platform_wayland_mod = b.addModule("goop_platform_wayland", .{
        .root_source_file = b.path("src/platform/wayland.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    platform_wayland_mod.addIncludePath(b.path("demo/protocol"));
    platform_wayland_mod.addCSourceFile(.{
        .file = b.path("demo/protocol/xdg-shell-protocol.c"),
    });
    platform_wayland_mod.linkSystemLibrary("wayland-client", .{});
    platform_wayland_mod.linkSystemLibrary("xkbcommon", .{});

    const wayland_vulkan_mod = b.addModule("goop_wayland_vulkan", .{
        .root_source_file = b.path("src/platform/wayland_vulkan.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    wayland_vulkan_mod.addImport("goop_graphics_vulkan", graphics_vulkan_mod);
    wayland_vulkan_mod.linkSystemLibrary("vulkan", .{});
    wayland_vulkan_mod.linkSystemLibrary("wayland-client", .{});

    const present_vulkan_mod = b.addModule("goop_present_vulkan", .{
        .root_source_file = b.path("src/present/vulkan.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    present_vulkan_mod.addImport("goop_graphics_vulkan", graphics_vulkan_mod);
    present_vulkan_mod.linkSystemLibrary("vulkan", .{});

    const render_state_mod = b.createModule(.{
        .root_source_file = snail_dep.path("src/render_state.zig"),
        .target = target,
        .optimize = optimize,
    });
    render_state_mod.addImport("snail", snail_mod);

    const snail_shaders_mod = snail_dep.module("snail-shaders");
    const snail_vulkan_types_mod = b.createModule(.{
        .root_source_file = b.path("src/render/vulkan/snail_types.zig"),
        .target = target,
        .optimize = optimize,
    });
    snail_vulkan_types_mod.addImport("goop_graphics_vulkan", graphics_vulkan_mod);

    const snail_vulkan_shaders_mod = b.createModule(.{
        .root_source_file = b.path("src/render/vulkan/snail_shaders.zig"),
        .target = target,
        .optimize = optimize,
    });
    snail_vulkan_shaders_mod.addImport("snail_shaders", snail_shaders_mod);

    const snail_reference_vulkan_mod = b.createModule(.{
        .root_source_file = snail_dep.path("src/demo/render/vulkan/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    snail_reference_vulkan_mod.addImport("snail", snail_mod);
    snail_reference_vulkan_mod.addImport("render-state", render_state_mod);
    snail_reference_vulkan_mod.addImport("vulkan_types", snail_vulkan_types_mod);
    snail_reference_vulkan_mod.addImport("vulkan_shaders", snail_vulkan_shaders_mod);
    snail_reference_vulkan_mod.addImport("snail_shaders", snail_shaders_mod);
    snail_reference_vulkan_mod.linkSystemLibrary("vulkan", .{});

    const render_vulkan_mod = b.addModule("goop_render_vulkan", .{
        .root_source_file = b.path("src/render/vulkan.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    render_vulkan_mod.addImport("goop_graphics_vulkan", graphics_vulkan_mod);
    render_vulkan_mod.addImport("goop_display", display_mod);
    render_vulkan_mod.addImport("goop_present_vulkan", present_vulkan_mod);
    render_vulkan_mod.addImport("goop_snail", snail_adapter_mod);
    render_vulkan_mod.addImport("snail", snail_mod);
    render_vulkan_mod.addImport("render-state", render_state_mod);
    render_vulkan_mod.addImport("snail_reference_vulkan", snail_reference_vulkan_mod);
    render_vulkan_mod.addImport("snail_vulkan_types", snail_vulkan_types_mod);
    render_vulkan_mod.linkSystemLibrary("vulkan", .{});

    // ── File browser application layers ──
    const browser_actions_mod = b.createModule(.{
        .root_source_file = b.path("demo/browser/actions.zig"),
        .target = target,
        .optimize = optimize,
    });
    const browser_model_mod = b.addModule("file_browser_model", .{
        .root_source_file = b.path("demo/browser/model.zig"),
        .target = target,
        .optimize = optimize,
    });
    const browser_controller_mod = b.addModule("file_browser_controller", .{
        .root_source_file = b.path("demo/browser/controller.zig"),
        .target = target,
        .optimize = optimize,
    });
    browser_controller_mod.addImport("browser_actions", browser_actions_mod);
    browser_controller_mod.addImport("file_browser_model", browser_model_mod);

    const browser_view_mod = b.addModule("file_browser_view", .{
        .root_source_file = b.path("demo/browser/view.zig"),
        .target = target,
        .optimize = optimize,
    });
    browser_view_mod.addImport("browser_actions", browser_actions_mod);
    browser_view_mod.addImport("file_browser_model", browser_model_mod);
    browser_view_mod.addImport("goop_components", components_mod);
    browser_view_mod.addImport("goop_ui", ui_mod);

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

    const file_manager_demo_mod = b.addModule("file_browser_app", .{
        .root_source_file = b.path("demo/browser/app.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    file_manager_demo_mod.addImport("goop_display", display_mod);
    file_manager_demo_mod.addImport("goop_ui", ui_mod);
    file_manager_demo_mod.addImport("goop_driver", driver_mod);
    file_manager_demo_mod.addImport("goop_platform_wayland", platform_wayland_mod);
    file_manager_demo_mod.addImport("goop_graphics_vulkan", graphics_vulkan_mod);
    file_manager_demo_mod.addImport("goop_wayland_vulkan", wayland_vulkan_mod);
    file_manager_demo_mod.addImport("goop_present_vulkan", present_vulkan_mod);
    file_manager_demo_mod.addImport("goop_render_vulkan", render_vulkan_mod);
    file_manager_demo_mod.addImport("goop_snail", snail_adapter_mod);
    file_manager_demo_mod.addImport("file_browser_model", browser_model_mod);
    file_manager_demo_mod.addImport("file_browser_controller", browser_controller_mod);
    file_manager_demo_mod.addImport("file_browser_view", browser_view_mod);

    const file_manager_demo_exe = b.addExecutable(.{
        .name = "goop-file-manager-demo",
        .root_module = file_manager_demo_mod,
    });
    const install_file_manager_demo = b.addInstallArtifact(file_manager_demo_exe, .{});
    b.getInstallStep().dependOn(&install_file_manager_demo.step);

    const build_file_manager_demo = b.step("build-file-manager-demo", "Build the file manager demo executable");
    build_file_manager_demo.dependOn(&install_file_manager_demo.step);

    const run_file_manager_demo = b.addRunArtifact(file_manager_demo_exe);
    run_file_manager_demo.step.dependOn(&install_file_manager_demo.step);
    if (b.args) |args| run_file_manager_demo.addArgs(args);

    const file_manager_demo_step = b.step("file-manager-demo", "Build and run the file manager demo");
    file_manager_demo_step.dependOn(&run_file_manager_demo.step);

    // Keep the generic demo names as aliases for the canonical browser
    // composition root. There is one supported windowed backend: Vulkan.
    const build_demo = b.step("build-demo", "Build the Vulkan demo executable");
    build_demo.dependOn(&install_file_manager_demo.step);
    const demo_step = b.step("demo", "Build and run the Vulkan demo");
    demo_step.dependOn(&run_file_manager_demo.step);

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

    const display_tests = b.addRunArtifact(b.addTest(.{ .root_module = display_mod }));
    const ui_tests = b.addRunArtifact(b.addTest(.{ .root_module = ui_mod }));
    const component_tests = b.addRunArtifact(b.addTest(.{ .root_module = components_mod }));
    const driver_tests = b.addRunArtifact(b.addTest(.{ .root_module = driver_mod }));
    const snail_adapter_tests = b.addRunArtifact(b.addTest(.{ .root_module = snail_adapter_mod }));
    const graphics_vulkan_tests = b.addRunArtifact(b.addTest(.{ .root_module = graphics_vulkan_mod }));
    const platform_wayland_tests = b.addRunArtifact(b.addTest(.{ .root_module = platform_wayland_mod }));
    const wayland_vulkan_tests = b.addRunArtifact(b.addTest(.{ .root_module = wayland_vulkan_mod }));
    const present_vulkan_tests = b.addRunArtifact(b.addTest(.{ .root_module = present_vulkan_mod }));
    const render_vulkan_tests = b.addRunArtifact(b.addTest(.{ .root_module = render_vulkan_mod }));
    const browser_actions_tests = b.addRunArtifact(b.addTest(.{ .root_module = browser_actions_mod }));
    const browser_model_tests = b.addRunArtifact(b.addTest(.{ .root_module = browser_model_mod }));
    const browser_controller_tests = b.addRunArtifact(b.addTest(.{ .root_module = browser_controller_mod }));
    const browser_view_tests = b.addRunArtifact(b.addTest(.{ .root_module = browser_view_mod }));

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&display_tests.step);
    test_step.dependOn(&ui_tests.step);
    test_step.dependOn(&component_tests.step);
    test_step.dependOn(&driver_tests.step);
    test_step.dependOn(&snail_adapter_tests.step);
    test_step.dependOn(&graphics_vulkan_tests.step);
    test_step.dependOn(&platform_wayland_tests.step);
    test_step.dependOn(&wayland_vulkan_tests.step);
    test_step.dependOn(&present_vulkan_tests.step);
    test_step.dependOn(&render_vulkan_tests.step);
    test_step.dependOn(&browser_actions_tests.step);
    test_step.dependOn(&browser_model_tests.step);
    test_step.dependOn(&browser_controller_tests.step);
    test_step.dependOn(&browser_view_tests.step);
    test_step.dependOn(&run_c_example.step);
}
