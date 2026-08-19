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
    const demo_image_codecs = b.option(
        bool,
        "demo-image-codecs",
        "Enable native image codecs in desktop demos",
    ) orelse true;
    const skia_enabled = b.option(
        bool,
        "skia",
        "Build the optional Skia (GPU/Ganesh) rendering backend",
    ) orelse false;

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
    // Build wiring is the enforceable dependency graph: consumers request
    // only the named library seams they intend to compose.
    const geometry_mod = b.addModule("goop_geometry", .{
        .root_source_file = b.path("src/geometry.zig"),
        .target = target,
        .optimize = optimize,
    });

    const input_mod = b.addModule("goop_input", .{
        .root_source_file = b.path("src/input.zig"),
        .target = target,
        .optimize = optimize,
    });

    const image_mod = b.addModule("goop_image", .{
        .root_source_file = b.path("src/image.zig"),
        .target = target,
        .optimize = optimize,
    });

    const visual_mod = b.addModule("goop_visual", .{
        .root_source_file = b.path("src/visual.zig"),
        .target = target,
        .optimize = optimize,
    });
    visual_mod.addImport("goop_geometry", geometry_mod);
    visual_mod.addImport("goop_image", image_mod);

    const ui_mod = b.addModule("goop_ui", .{
        .root_source_file = b.path("src/ui.zig"),
        .target = target,
        .optimize = optimize,
    });

    const desktop_mod = b.addModule("goop_desktop", .{
        .root_source_file = b.path("src/desktop.zig"),
        .target = target,
        .optimize = optimize,
    });
    desktop_mod.addImport("goop_input", input_mod);

    const components_mod = b.addModule("goop_components", .{
        .root_source_file = b.path("src/components.zig"),
        .target = target,
        .optimize = optimize,
    });
    components_mod.addImport("goop_visual", visual_mod);

    const snail_adapter_mod = b.addModule("goop_snail", .{
        .root_source_file = b.path("src/snail_adapter.zig"),
        .target = target,
        .optimize = optimize,
    });
    snail_adapter_mod.addImport("goop_visual", visual_mod);
    snail_adapter_mod.addImport("goop_image", image_mod);
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
    platform_wayland_mod.linkSystemLibrary("wayland-cursor", .{});
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

    const render_vulkan_mod = b.addModule("goop_render_vulkan", .{
        .root_source_file = b.path("src/render/vulkan.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    render_vulkan_mod.addImport("goop_graphics_vulkan", graphics_vulkan_mod);
    render_vulkan_mod.addImport("goop_visual", visual_mod);
    render_vulkan_mod.addImport("goop_snail", snail_adapter_mod);
    render_vulkan_mod.addImport("snail", snail_mod);
    render_vulkan_mod.addImport("snail_reflection", snail_reflection_mod);
    render_vulkan_mod.addImport("goop_render_shaders", render_shaders_mod);
    render_vulkan_mod.linkSystemLibrary("vulkan", .{});

    // ── Optional Skia (GPU/Ganesh) rendering backend ──
    //
    // A snail-free alternative renderer: it consumes the same backend-neutral
    // `goop_visual` operations and draws them with Skia. Skia is C++, so the
    // draw calls live in a POD-only C-ABI shim compiled by Zig's own C++
    // toolchain (`zig c++`) and linked against system `libskia`. Gated behind
    // `-Dskia` so consumers that do not want Skia link nothing.
    if (skia_enabled) {
        // libskia is built against libstdc++, and Ganesh's init hands Skia a
        // std::function it later invokes — so the shim must share libskia's
        // C++ ABI. Rather than force Zig's clang to act as a libstdc++ compiler
        // (which needs a pile of hand-fed stdlib include/lib paths), compile
        // the shim with the system g++: it resolves its own libstdc++/glibc
        // headers and ABI. Zig links the resulting object. Skia's own include
        // comes from pkg-config; libstdc++'s path from g++ itself. No env vars.
        const skia_cflags = b.run(&.{ "pkg-config", "--cflags-only-I", "skia" });
        const libstdcxx = std.mem.trim(u8, b.run(&.{ "g++", "-print-file-name=libstdc++.so" }), " \r\n\t");

        const shim_cc = b.addSystemCommand(&.{
            "g++", "-std=c++17", "-fno-exceptions", "-fno-rtti", "-fPIC", "-c",
        });
        var cflag_it = std.mem.tokenizeAny(u8, skia_cflags, " \r\n\t");
        while (cflag_it.next()) |tok| shim_cc.addArg(b.dupe(tok));
        shim_cc.addFileArg(b.path("src/render/skia/shim.cpp"));
        shim_cc.addArg("-o");
        const shim_obj = shim_cc.addOutputFileArg("goop_skia_shim.o");

        const render_skia_mod = b.addModule("goop_render_skia", .{
            .root_source_file = b.path("src/render/skia.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        render_skia_mod.addImport("goop_visual", visual_mod);
        render_skia_mod.addImport("goop_graphics_vulkan", graphics_vulkan_mod);
        render_skia_mod.linkSystemLibrary("vulkan", .{});
        render_skia_mod.addObjectFile(shim_obj);
        // Link libstdc++ by full path (g++ reports where it lives): `zig cc`'s
        // -L/-l search does not resolve the nix store path, but a positional
        // shared-object input does.
        render_skia_mod.addObjectFile(.{ .cwd_relative = libstdcxx });
        render_skia_mod.linkSystemLibrary("skia", .{});

        const skia_tests = b.addRunArtifact(b.addTest(.{ .root_module = render_skia_mod }));
        const skia_test_step = b.step("test-skia", "Run the Skia backend tests");
        skia_test_step.dependOn(&skia_tests.step);
    }

    // ── Core goop module ──
    //
    // This named Zig module is the behavior/layout core only. The core C ABI
    // and optional caller-owned Chrome C ABI are separate roots below.
    const goop_mod = b.addModule("goop", .{
        .root_source_file = b.path("src/goop.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    goop_mod.addIncludePath(b.path("include"));
    goop_mod.addIncludePath(b.path("vendor/clay"));
    goop_mod.addCSourceFile(.{
        .file = b.path("vendor/clay/clay.c"),
    });
    goop_mod.addImport("goop_ui", ui_mod);
    goop_mod.addImport("goop_input", input_mod);
    goop_mod.addImport("goop_visual", visual_mod);
    desktop_mod.addImport("goop", goop_mod);

    // ── Optional stock look ──
    const chrome_mod = b.addModule("goop_chrome", .{
        .root_source_file = b.path("src/chrome.zig"),
        .target = target,
        .optimize = optimize,
    });
    chrome_mod.addImport("goop", goop_mod);
    chrome_mod.addImport("goop_components", components_mod);
    chrome_mod.addImport("goop_visual", visual_mod);

    // ── Core-only C ABI composition root ──
    const c_api_mod = b.createModule(.{
        .root_source_file = b.path("src/c_api.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    c_api_mod.addIncludePath(b.path("include"));
    c_api_mod.addImport("goop", goop_mod);
    c_api_mod.addImport("goop_visual", visual_mod);

    // Optional caller-owned stock Chrome C ABI. This is a distinct artifact:
    // core-only applications never link or instantiate it.
    const chrome_c_api_mod = b.createModule(.{
        .root_source_file = b.path("src/chrome_c_api.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    chrome_c_api_mod.addIncludePath(b.path("include"));
    chrome_c_api_mod.addImport("goop", goop_mod);
    chrome_c_api_mod.addImport("goop_chrome", chrome_mod);
    chrome_c_api_mod.addImport("goop_visual", visual_mod);

    // ── Static library ──
    const lib = b.addLibrary(.{
        .name = "goop",
        .root_module = c_api_mod,
        .linkage = .static,
    });
    b.installArtifact(lib);

    const shared_lib = b.addLibrary(.{
        .name = "goop",
        .root_module = c_api_mod,
        .linkage = .dynamic,
    });
    b.installArtifact(shared_lib);

    const chrome_c_lib = b.addLibrary(.{
        .name = "goop_chrome",
        .root_module = chrome_c_api_mod,
        .linkage = .static,
    });
    b.installArtifact(chrome_c_lib);

    const chrome_c_shared_lib = b.addLibrary(.{
        .name = "goop_chrome",
        .root_module = chrome_c_api_mod,
        .linkage = .dynamic,
    });
    b.installArtifact(chrome_c_shared_lib);

    b.getInstallStep().dependOn(&b.addInstallHeaderFile(b.path("include/goop.h"), "goop.h").step);
    b.getInstallStep().dependOn(&b.addInstallHeaderFile(b.path("include/goop_chrome.h"), "goop_chrome.h").step);

    const build_lib = b.step("build-lib", "Build the core C static library");
    build_lib.dependOn(&b.addInstallArtifact(lib, .{}).step);

    const build_shared_lib = b.step("build-shared-lib", "Build the core C shared library");
    build_shared_lib.dependOn(&b.addInstallArtifact(shared_lib, .{}).step);

    const build_chrome_lib = b.step("build-chrome-lib", "Build the optional stock Chrome C library");
    build_chrome_lib.dependOn(&b.addInstallArtifact(chrome_c_lib, .{}).step);

    const build_chrome_shared_lib = b.step("build-chrome-shared-lib", "Build the optional stock Chrome C shared library");
    build_chrome_shared_lib.dependOn(&b.addInstallArtifact(chrome_c_shared_lib, .{}).step);

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

    const c_chrome_example = b.addExecutable(.{
        .name = "goop-c-chrome-example",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    c_chrome_example.root_module.addCSourceFile(.{
        .file = b.path("examples/c/chrome.c"),
        .flags = &.{"-std=c11"},
    });
    c_chrome_example.root_module.addIncludePath(b.path("include"));
    c_chrome_example.root_module.linkLibrary(lib);
    c_chrome_example.root_module.linkLibrary(chrome_c_lib);

    const build_c_chrome_example = b.step("build-c-chrome-example", "Build the caller-owned Chrome C example");
    build_c_chrome_example.dependOn(&c_chrome_example.step);

    const run_c_chrome_example = b.addRunArtifact(c_chrome_example);
    const c_chrome_example_step = b.step("c-chrome-example", "Build and run the caller-owned Chrome C example");
    c_chrome_example_step.dependOn(&run_c_chrome_example.step);

    // ── Game embedding acceptance example ──
    const game_embed_mod = b.createModule(.{
        .root_source_file = b.path("examples/game_embed.zig"),
        .target = target,
        .optimize = optimize,
    });
    game_embed_mod.addImport("goop", goop_mod);
    game_embed_mod.addImport("goop_components", components_mod);
    game_embed_mod.addImport("goop_visual", visual_mod);
    const game_embed_exe = b.addExecutable(.{
        .name = "goop-game-embed-example",
        .root_module = game_embed_mod,
    });
    const run_game_embed = b.addRunArtifact(game_embed_exe);
    const game_embed_step = b.step("game-embed-example", "Run core + components with a game-owned render queue");
    game_embed_step.dependOn(&run_game_embed.step);

    // ── Shared demo boundaries ──
    const demo_font_loader_mod = b.createModule(.{
        .root_source_file = b.path("demo/support/font.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    demo_font_loader_mod.linkSystemLibrary("fontconfig", .{});
    const demo_image_decoder_mod = b.createModule(.{
        .root_source_file = b.path(if (demo_image_codecs)
            "demo/support/image_native.zig"
        else
            "demo/support/image_none.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    demo_image_decoder_mod.addImport("goop_image", image_mod);
    if (demo_image_codecs) {
        demo_image_decoder_mod.linkSystemLibrary("spng", .{ .use_pkg_config = .force });
        demo_image_decoder_mod.linkSystemLibrary("libturbojpeg", .{ .use_pkg_config = .force });
        demo_image_decoder_mod.linkSystemLibrary("libwebp", .{ .use_pkg_config = .force });
    }
    const demo_text_mod = b.createModule(.{
        .root_source_file = b.path("demo/support/text.zig"),
        .target = target,
        .optimize = optimize,
    });
    demo_text_mod.addImport("goop", goop_mod);
    demo_text_mod.addImport("goop_snail", snail_adapter_mod);
    demo_text_mod.addImport("demo_font_loader", demo_font_loader_mod);
    demo_text_mod.addImport("demo_image_decoder", demo_image_decoder_mod);

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
    const showcase_ids_mod = b.addModule("showcase_ids", .{
        .root_source_file = b.path("demo/showcase/ids.zig"),
        .target = target,
        .optimize = optimize,
    });
    showcase_ids_mod.addImport("goop_ui", ui_mod);

    const showcase_view_mod = b.addModule("showcase_view", .{
        .root_source_file = b.path("demo/showcase/view.zig"),
        .target = target,
        .optimize = optimize,
    });
    showcase_view_mod.addImport("goop", goop_mod);
    showcase_view_mod.addImport("showcase_ids", showcase_ids_mod);

    const showcase_controller_mod = b.addModule("showcase_controller", .{
        .root_source_file = b.path("demo/showcase/controller.zig"),
        .target = target,
        .optimize = optimize,
    });
    showcase_controller_mod.addImport("goop", goop_mod);
    showcase_controller_mod.addImport("showcase_ids", showcase_ids_mod);

    const showcase_app_mod = b.addModule("showcase_app", .{
        .root_source_file = b.path("demo/showcase/app.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    showcase_app_mod.addImport("goop", goop_mod);
    showcase_app_mod.addImport("goop_chrome", chrome_mod);
    showcase_app_mod.addImport("goop_platform_wayland", platform_wayland_mod);
    showcase_app_mod.addImport("demo_text", demo_text_mod);
    showcase_app_mod.addImport("demo_gpu", demo_gpu_mod);
    showcase_app_mod.addImport("showcase_view", showcase_view_mod);
    showcase_app_mod.addImport("showcase_controller", showcase_controller_mod);
    showcase_app_mod.addImport("showcase_ids", showcase_ids_mod);

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

    const file_manager_mod = b.addModule("file_manager", .{
        .root_source_file = b.path("demo/file_manager/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    file_manager_mod.addImport("goop", goop_mod);
    file_manager_mod.addImport("goop_desktop", desktop_mod);
    file_manager_mod.addImport("goop_image", image_mod);

    const file_manager_demo_mod = b.addModule("file_browser_app", .{
        .root_source_file = b.path("demo/file_manager/app.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    file_manager_demo_mod.addImport("goop", goop_mod);
    file_manager_demo_mod.addImport("goop_visual", visual_mod);
    file_manager_demo_mod.addImport("goop_chrome", chrome_mod);
    file_manager_demo_mod.addImport("goop_platform_wayland", platform_wayland_mod);
    file_manager_demo_mod.addImport("file_manager", file_manager_mod);
    file_manager_demo_mod.addImport("demo_text", demo_text_mod);
    file_manager_demo_mod.addImport("demo_gpu", demo_gpu_mod);
    file_manager_demo_mod.addImport("demo_image_decoder", demo_image_decoder_mod);

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
    const unit_tests = b.addTest(.{ .root_module = goop_mod });
    const run_tests = b.addRunArtifact(unit_tests);
    const chrome_tests = b.addRunArtifact(b.addTest(.{ .root_module = chrome_mod }));
    const c_api_tests = b.addRunArtifact(b.addTest(.{ .root_module = c_api_mod }));
    const chrome_c_api_tests = b.addRunArtifact(b.addTest(.{ .root_module = chrome_c_api_mod }));

    const geometry_tests = b.addRunArtifact(b.addTest(.{ .root_module = geometry_mod }));
    const input_tests = b.addRunArtifact(b.addTest(.{ .root_module = input_mod }));
    const image_tests = b.addRunArtifact(b.addTest(.{ .root_module = image_mod }));
    const visual_tests = b.addRunArtifact(b.addTest(.{ .root_module = visual_mod }));
    const ui_tests = b.addRunArtifact(b.addTest(.{ .root_module = ui_mod }));
    const desktop_tests = b.addRunArtifact(b.addTest(.{ .root_module = desktop_mod }));
    const component_tests = b.addRunArtifact(b.addTest(.{ .root_module = components_mod }));
    const snail_adapter_test_mod = b.createModule(.{
        .root_source_file = b.path("src/snail_adapter_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    snail_adapter_test_mod.addImport("goop_snail", snail_adapter_mod);
    snail_adapter_test_mod.addImport("goop_image", image_mod);
    snail_adapter_test_mod.addImport("goop_visual", visual_mod);
    snail_adapter_test_mod.addImport("snail", snail_mod);
    snail_adapter_test_mod.addAnonymousImport("test_primary_font", .{
        .root_source_file = snail_dep.path("assets/NotoSans-Regular.ttf"),
    });
    snail_adapter_test_mod.addAnonymousImport("test_arabic_font", .{
        .root_source_file = snail_dep.path("assets/NotoSansArabic-Regular.ttf"),
    });
    snail_adapter_test_mod.addAnonymousImport("test_bitmap_font", .{
        .root_source_file = snail_dep.path("assets/test-fonts/chromacheck-cbdt.ttf"),
    });
    const snail_adapter_tests = b.addRunArtifact(b.addTest(.{ .root_module = snail_adapter_test_mod }));
    const demo_font_loader_tests = b.addRunArtifact(b.addTest(.{ .root_module = demo_font_loader_mod }));
    const demo_image_decoder_tests = b.addRunArtifact(b.addTest(.{ .root_module = demo_image_decoder_mod }));
    const demo_text_tests = b.addRunArtifact(b.addTest(.{ .root_module = demo_text_mod }));
    const graphics_vulkan_tests = b.addRunArtifact(b.addTest(.{ .root_module = graphics_vulkan_mod }));
    const platform_wayland_tests = b.addRunArtifact(b.addTest(.{ .root_module = platform_wayland_mod }));
    const wayland_vulkan_tests = b.addRunArtifact(b.addTest(.{ .root_module = wayland_vulkan_mod }));
    const present_vulkan_tests = b.addRunArtifact(b.addTest(.{ .root_module = present_vulkan_mod }));
    const render_vulkan_tests = b.addRunArtifact(b.addTest(.{ .root_module = render_vulkan_mod }));
    const render_shaders_tests = b.addRunArtifact(b.addTest(.{ .root_module = render_shaders_mod }));
    const showcase_controller_tests = b.addRunArtifact(b.addTest(.{
        .root_module = showcase_controller_mod,
    }));
    const file_manager_logic_tests = b.addRunArtifact(b.addTest(.{
        .root_module = file_manager_mod,
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
    headless_mod.addImport("goop_render_vulkan", render_vulkan_mod);
    headless_mod.addImport("goop_snail", snail_adapter_mod);

    const headless_shot_mod = b.createModule(.{
        .root_source_file = b.path("tools/headless_shot.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    headless_shot_mod.addImport("goop", goop_mod);
    headless_shot_mod.addImport("goop_chrome", chrome_mod);
    headless_shot_mod.addImport("file_manager", file_manager_mod);
    headless_shot_mod.addImport("goop_snail", snail_adapter_mod);
    headless_shot_mod.addImport("demo_text", demo_text_mod);
    headless_shot_mod.addImport("headless", headless_mod);
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
    test_step.dependOn(&chrome_tests.step);
    test_step.dependOn(&c_api_tests.step);
    test_step.dependOn(&chrome_c_api_tests.step);
    test_step.dependOn(&geometry_tests.step);
    test_step.dependOn(&input_tests.step);
    test_step.dependOn(&image_tests.step);
    test_step.dependOn(&visual_tests.step);
    test_step.dependOn(&ui_tests.step);
    test_step.dependOn(&desktop_tests.step);
    test_step.dependOn(&component_tests.step);
    test_step.dependOn(&snail_adapter_tests.step);
    test_step.dependOn(&demo_font_loader_tests.step);
    test_step.dependOn(&demo_image_decoder_tests.step);
    test_step.dependOn(&demo_text_tests.step);
    test_step.dependOn(&graphics_vulkan_tests.step);
    test_step.dependOn(&platform_wayland_tests.step);
    test_step.dependOn(&wayland_vulkan_tests.step);
    test_step.dependOn(&present_vulkan_tests.step);
    test_step.dependOn(&render_vulkan_tests.step);
    test_step.dependOn(&render_shaders_tests.step);
    test_step.dependOn(&showcase_controller_tests.step);
    test_step.dependOn(&file_manager_logic_tests.step);
    test_step.dependOn(&run_c_example.step);
    test_step.dependOn(&run_c_chrome_example.step);
    test_step.dependOn(&run_game_embed.step);

    const test_desktop_step = b.step("test-desktop", "Run renderer-free desktop contract tests");
    test_desktop_step.dependOn(&desktop_tests.step);

    const test_file_manager_step = b.step("test-file-manager", "Run focused file-manager model/projection tests");
    test_file_manager_step.dependOn(&file_manager_logic_tests.step);

    const test_core_step = b.step("test-core", "Run renderer-free Goop core tests");
    test_core_step.dependOn(&run_tests.step);

    const test_input_step = b.step("test-input", "Run normalized input contract tests");
    test_input_step.dependOn(&input_tests.step);

    const test_geometry_step = b.step("test-geometry", "Run shared geometry contract tests");
    test_geometry_step.dependOn(&geometry_tests.step);

    const test_visual_step = b.step("test-visual", "Run renderer-owned visual contract tests");
    test_visual_step.dependOn(&visual_tests.step);

    const test_chrome_step = b.step("test-chrome", "Run optional stock Chrome tests");
    test_chrome_step.dependOn(&chrome_tests.step);

    const test_c_api_step = b.step("test-c-api", "Run C ABI tests");
    test_c_api_step.dependOn(&c_api_tests.step);
    test_c_api_step.dependOn(&chrome_c_api_tests.step);

    const test_render_vulkan_step = b.step("test-render-vulkan", "Run Vulkan renderer contract tests");
    test_render_vulkan_step.dependOn(&render_vulkan_tests.step);

    const test_visual_stack_step = b.step("test-visual-stack", "Run visual, Snail preparation, and Vulkan renderer tests");
    test_visual_stack_step.dependOn(&visual_tests.step);
    test_visual_stack_step.dependOn(&snail_adapter_tests.step);
    test_visual_stack_step.dependOn(&render_vulkan_tests.step);

    const test_fonts_step = b.step("test-fonts", "Run Fontconfig composition, fallback, and hinted-placement tests");
    test_fonts_step.dependOn(&demo_font_loader_tests.step);
    test_fonts_step.dependOn(&demo_text_tests.step);
    test_fonts_step.dependOn(&snail_adapter_tests.step);

    const test_image_codecs_step = b.step("test-image-codecs", "Run native image codec contract tests");
    test_image_codecs_step.dependOn(&demo_image_decoder_tests.step);
}
