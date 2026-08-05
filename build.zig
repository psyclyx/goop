const std = @import("std");

/// slangc toolchain gate, mirroring snail's toolchainGates pattern: when
/// slangc is missing from PATH, every shader Run step gets a Fail-step
/// dependency so the build aborts with an actionable message instead of a
/// raw exec error. Cached per build graph.
var slangc_gate_cache: ?struct {
    owner: *std.Build,
    fail: ?*std.Build.Step,
} = null;

fn attachSlangcGate(b: *std.Build, step: *std.Build.Step) void {
    if (slangc_gate_cache) |*g| {
        if (g.owner == b) {
            if (g.fail) |fail| step.dependOn(fail);
            return;
        }
    }
    const missing = if (b.findProgram(&.{"slangc"}, &.{})) |_| false else |_| true;
    const fail: ?*std.Build.Step = if (missing)
        &b.addFail("goop compiles its Vulkan SPIR-V from snail's slang sources; slangc (shader-slang) is missing from PATH — enter nix-shell or install shader-slang").step
    else
        null;
    slangc_gate_cache = .{ .owner = b, .fail = fail };
    if (fail) |f| step.dependOn(f);
}

/// Compile one entry point of one snail slang family to SPIR-V with the flat
/// (uniform-texel-buffer) atlas storage. Flags mirror snail's own
/// `slangcFamily`/`vulkanStageSpv` exactly. The dependency is hash-immutable,
/// so recursive file-input registration (snail's addModuleInputs trick) is
/// unnecessary.
fn compileSnailSlang(
    b: *std.Build,
    snail_dep: *std.Build.Dependency,
    name: []const u8,
    comptime stage: enum { vertex, fragment },
) std.Build.LazyPath {
    const slang_dir = snail_dep.namedLazyPath("snail_slang");
    const cmd = b.addSystemCommand(&.{"slangc"});
    attachSlangcGate(b, &cmd.step);
    cmd.addArgs(&.{
        "-DSNAIL_TARGET_VULKAN",
        "-DSNAIL_FLAT_STORAGE",
        "-entry",
        switch (stage) {
            .vertex => "vertexMain",
            .fragment => "fragmentMain",
        },
        "-stage",
        switch (stage) {
            .vertex => "vertex",
            .fragment => "fragment",
        },
        "-default-image-format-unknown",
        "-warnings-disable",
        "39001",
        "-I",
    });
    cmd.addDirectoryArg(slang_dir);
    cmd.addFileArg(slang_dir.join(b.allocator, b.fmt("families/{s}.slang", .{name})) catch @panic("OOM"));
    cmd.addArgs(&.{ "-target", "spirv", "-profile", "spirv_1_3", "-O2", "-o" });
    return cmd.addOutputFileArg(b.fmt("{s}.{s}.spv", .{ name, @tagName(stage) }));
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Snail (backend-neutral text/vector preparation) ──
    const snail_dep = b.dependency("snail", .{
        .target = target,
        .optimize = optimize,
    });
    const snail_mod = snail_dep.module("snail");
    // The committed, toolchain-free shader binding contract (PushConstants +
    // descriptor binding numbers).
    const snail_reflection_mod = snail_dep.module("snail-shaders-reflection");

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

    // ── Goop-owned Vulkan shader artifacts ──
    //
    // Goop compiles its SPIR-V itself from snail's slang sources (flat
    // atlas storage), so future goop-authored animation families can import
    // snail's slang modules the same way snail's game_material example does.
    const render_shaders_mod = b.addModule("goop_render_shaders", .{
        .root_source_file = b.path("src/render/vulkan/shaders.zig"),
        .target = target,
        .optimize = optimize,
    });
    render_shaders_mod.addAnonymousImport("text_vert_spv", .{ .root_source_file = compileSnailSlang(b, snail_dep, "text", .vertex) });
    render_shaders_mod.addAnonymousImport("text_frag_spv", .{ .root_source_file = compileSnailSlang(b, snail_dep, "text", .fragment) });
    render_shaders_mod.addAnonymousImport("colr_frag_spv", .{ .root_source_file = compileSnailSlang(b, snail_dep, "colr", .fragment) });
    render_shaders_mod.addAnonymousImport("path_quadratic_frag_spv", .{ .root_source_file = compileSnailSlang(b, snail_dep, "path_quadratic", .fragment) });
    render_shaders_mod.addAnonymousImport("path_conic_frag_spv", .{ .root_source_file = compileSnailSlang(b, snail_dep, "path_conic", .fragment) });
    render_shaders_mod.addAnonymousImport("path_frag_spv", .{ .root_source_file = compileSnailSlang(b, snail_dep, "path", .fragment) });
    render_shaders_mod.addAnonymousImport("tt_hinted_text_frag_spv", .{ .root_source_file = compileSnailSlang(b, snail_dep, "tt_hinted_text", .fragment) });
    render_shaders_mod.addAnonymousImport("autohint_vert_spv", .{ .root_source_file = compileSnailSlang(b, snail_dep, "autohint", .vertex) });
    render_shaders_mod.addAnonymousImport("autohint_frag_spv", .{ .root_source_file = compileSnailSlang(b, snail_dep, "autohint", .fragment) });
    render_shaders_mod.addAnonymousImport("text_subpixel_frag_spv", .{ .root_source_file = compileSnailSlang(b, snail_dep, "text_subpixel", .fragment) });
    render_shaders_mod.addAnonymousImport("tt_hinted_text_subpixel_frag_spv", .{ .root_source_file = compileSnailSlang(b, snail_dep, "tt_hinted_text_subpixel", .fragment) });
    render_shaders_mod.addAnonymousImport("autohint_subpixel_frag_spv", .{ .root_source_file = compileSnailSlang(b, snail_dep, "autohint_subpixel", .fragment) });

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
    render_vulkan_mod.addImport("snail_reflection", snail_reflection_mod);
    render_vulkan_mod.addImport("goop_render_shaders", render_shaders_mod);
    render_vulkan_mod.linkSystemLibrary("vulkan", .{});

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

    // ── Shared demo boundaries ──
    const demo_font_loader_mod = b.createModule(.{
        .root_source_file = b.path("demo/support/font.zig"),
        .target = target,
        .optimize = optimize,
    });
    const demo_text_mod = b.createModule(.{
        .root_source_file = b.path("demo/support/text.zig"),
        .target = target,
        .optimize = optimize,
    });
    demo_text_mod.addImport("goop", goop_mod);
    demo_text_mod.addImport("goop_snail", snail_adapter_mod);
    demo_text_mod.addImport("demo_font_loader", demo_font_loader_mod);

    const paint_convert_mod = b.createModule(.{
        .root_source_file = b.path("demo/support/paint_convert.zig"),
        .target = target,
        .optimize = optimize,
    });
    paint_convert_mod.addImport("goop", goop_mod);
    paint_convert_mod.addImport("goop_display", display_mod);


    const demo_gpu_mod = b.createModule(.{
        .root_source_file = b.path("demo/support/gpu.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    demo_gpu_mod.addImport("goop_platform_wayland", platform_wayland_mod);
    demo_gpu_mod.addImport("goop_graphics_vulkan", graphics_vulkan_mod);
    demo_gpu_mod.addImport("goop_wayland_vulkan", wayland_vulkan_mod);
    demo_gpu_mod.addImport("goop_present_vulkan", present_vulkan_mod);
    demo_gpu_mod.addImport("goop_render_vulkan", render_vulkan_mod);
    demo_gpu_mod.addImport("goop_snail", snail_adapter_mod);

    // ── Full widget showcase ──
    const showcase_view_mod = b.addModule("showcase_view", .{
        .root_source_file = b.path("demo/showcase/view.zig"),
        .target = target,
        .optimize = optimize,
    });
    showcase_view_mod.addImport("goop", goop_mod);

    const showcase_controller_mod = b.addModule("showcase_controller", .{
        .root_source_file = b.path("demo/showcase/controller.zig"),
        .target = target,
        .optimize = optimize,
    });
    showcase_controller_mod.addImport("goop", goop_mod);
    showcase_controller_mod.addImport("showcase_view", showcase_view_mod);

    const showcase_app_mod = b.addModule("showcase_app", .{
        .root_source_file = b.path("demo/showcase/app.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    showcase_app_mod.addImport("goop", goop_mod);
    showcase_app_mod.addImport("goop_display", display_mod);
    showcase_app_mod.addImport("goop_platform_wayland", platform_wayland_mod);
    showcase_app_mod.addImport("demo_text", demo_text_mod);
    showcase_app_mod.addImport("paint_convert", paint_convert_mod);
    showcase_app_mod.addImport("demo_gpu", demo_gpu_mod);
    showcase_app_mod.addImport("showcase_view", showcase_view_mod);
    showcase_app_mod.addImport("showcase_controller", showcase_controller_mod);

    const showcase_exe = b.addExecutable(.{
        .name = "goop-demo",
        .root_module = showcase_app_mod,
    });
    const install_showcase = b.addInstallArtifact(showcase_exe, .{});
    b.getInstallStep().dependOn(&install_showcase.step);

    const build_demo = b.step("build-demo", "Build the Vulkan widget showcase");
    build_demo.dependOn(&install_showcase.step);
    const run_demo = b.addRunArtifact(showcase_exe);
    run_demo.step.dependOn(&install_showcase.step);
    if (b.args) |args| run_demo.addArgs(args);
    const demo_step = b.step("demo", "Build and run the Vulkan widget showcase");
    demo_step.dependOn(&run_demo.step);

    const file_manager_logic_mod = b.addModule("file_manager_logic", .{
        .root_source_file = b.path("demo/file_manager/controller.zig"),
        .target = target,
        .optimize = optimize,
    });
    file_manager_logic_mod.addImport("goop", goop_mod);

    const file_manager_demo_mod = b.addModule("file_browser_app", .{
        .root_source_file = b.path("demo/file_manager/app.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    file_manager_demo_mod.addImport("goop", goop_mod);
    file_manager_demo_mod.addImport("goop_display", display_mod);
    file_manager_demo_mod.addImport("goop_platform_wayland", platform_wayland_mod);
    file_manager_demo_mod.addImport("file_manager_logic", file_manager_logic_mod);
    file_manager_demo_mod.addImport("demo_text", demo_text_mod);
    file_manager_demo_mod.addImport("paint_convert", paint_convert_mod);
    file_manager_demo_mod.addImport("demo_gpu", demo_gpu_mod);

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
    const snail_adapter_tests = b.addRunArtifact(b.addTest(.{ .root_module = snail_adapter_mod }));
    const graphics_vulkan_tests = b.addRunArtifact(b.addTest(.{ .root_module = graphics_vulkan_mod }));
    const platform_wayland_tests = b.addRunArtifact(b.addTest(.{ .root_module = platform_wayland_mod }));
    const wayland_vulkan_tests = b.addRunArtifact(b.addTest(.{ .root_module = wayland_vulkan_mod }));
    const present_vulkan_tests = b.addRunArtifact(b.addTest(.{ .root_module = present_vulkan_mod }));
    const render_vulkan_tests = b.addRunArtifact(b.addTest(.{ .root_module = render_vulkan_mod }));
    const render_shaders_tests = b.addRunArtifact(b.addTest(.{ .root_module = render_shaders_mod }));
    const file_manager_logic_tests = b.addRunArtifact(b.addTest(.{
        .root_module = file_manager_logic_mod,
    }));


    const headless_probe_mod = b.createModule(.{
        .root_source_file = b.path("tools/headless_probe.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    headless_probe_mod.addImport("goop_graphics_vulkan", graphics_vulkan_mod);
    const headless_probe_exe = b.addExecutable(.{
        .name = "goop-headless-probe",
        .root_module = headless_probe_mod,
    });
    const run_headless_probe = b.addRunArtifact(headless_probe_exe);
    const headless_probe_step = b.step("headless-probe", "Validate offscreen Vulkan render + readback");
    headless_probe_step.dependOn(&run_headless_probe.step);

    const headless_mod = b.createModule(.{
        .root_source_file = b.path("demo/support/headless.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    headless_mod.addImport("goop_graphics_vulkan", graphics_vulkan_mod);
    headless_mod.addImport("goop_present_vulkan", present_vulkan_mod);
    headless_mod.addImport("goop_render_vulkan", render_vulkan_mod);
    headless_mod.addImport("goop_snail", snail_adapter_mod);
    headless_mod.addImport("goop_display", display_mod);

    const headless_shot_mod = b.createModule(.{
        .root_source_file = b.path("tools/headless_shot.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    headless_shot_mod.addImport("goop", goop_mod);
    headless_shot_mod.addImport("file_manager_logic", file_manager_logic_mod);
    headless_shot_mod.addImport("goop_snail", snail_adapter_mod);
    headless_shot_mod.addImport("demo_text", demo_text_mod);
    headless_shot_mod.addImport("headless", headless_mod);
    headless_shot_mod.addImport("paint_convert", paint_convert_mod);
    const headless_shot_exe = b.addExecutable(.{
        .name = "goop-headless-shot",
        .root_module = headless_shot_mod,
    });
    const run_headless_shot = b.addRunArtifact(headless_shot_exe);
    if (b.args) |args| run_headless_shot.addArgs(args);
    const headless_shot_step = b.step("headless-shot", "Render a real file-manager frame offscreen to a PPM");
    headless_shot_step.dependOn(&run_headless_shot.step);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&display_tests.step);
    test_step.dependOn(&ui_tests.step);
    test_step.dependOn(&component_tests.step);
    test_step.dependOn(&snail_adapter_tests.step);
    test_step.dependOn(&graphics_vulkan_tests.step);
    test_step.dependOn(&platform_wayland_tests.step);
    test_step.dependOn(&wayland_vulkan_tests.step);
    test_step.dependOn(&present_vulkan_tests.step);
    test_step.dependOn(&render_vulkan_tests.step);
    test_step.dependOn(&render_shaders_tests.step);
    test_step.dependOn(&file_manager_logic_tests.step);
    test_step.dependOn(&run_c_example.step);
}
