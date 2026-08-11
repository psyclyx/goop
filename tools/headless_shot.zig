//! Headless screenshot driver: render a real file-manager frame into an
//! offscreen image and dump a PPM (+ assert pixels). Events are data, so a
//! scripted interaction can be driven and its rendered result inspected without
//! a compositor.
//!
//! Usage: run with GOOP_SHOT=<path.ppm> to choose the output (default shot.ppm).

const std = @import("std");
const goop = @import("goop");
const chrome_module = @import("goop_chrome");
const fm = @import("file_manager");
const snail = @import("goop_snail");
const demo_text = @import("demo_text");
const headless = @import("headless");

const width: u32 = 1280;
const height: u32 = 720;
const clear_rgb = [3]u8{ 242, 245, 247 };

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;

    var text = try demo_text.Text.init(allocator, init.io, init.environ_map);
    defer text.deinit();
    const measure = text.measureContext();

    var ctx = try goop.Context.init(allocator, .{ .width = width, .height = height });
    defer ctx.deinit();
    var chrome = chrome_module.Chrome.init(allocator);
    defer chrome.deinit();

    var browser: fm.state.Browser = .{};
    var behavior = fm.capabilities.behavior(&browser.session, &browser.viewport, &browser.domain, &browser.effects);
    try fm.controller.init(&behavior, init.io, init.environ_map);
    defer {
        fm.projection.deinit(&browser.projection);
        browser.domain.identities.deinit();
        fm.controller.deinit(&behavior);
    }
    fm.projection.configure(&browser.projection, &measure);
    fm.controller.resize(&browser.viewport, width, height);
    ctx.setTheme(fm.style.fileManagerThemeForScale(browser.viewport.ui_scale));
    ctx.setClipboard(fm.controller.clipboard(&browser.effects.transfer));
    const view_input = fm.capabilities.viewInput(
        &browser.viewport,
        &browser.domain.model,
        &browser.domain.interaction,
        &browser.domain.presentation,
    );
    const view_output = fm.capabilities.viewOutput(
        &browser.projection,
        &browser.domain.identities,
    );
    try fm.view.buildWidgetTree(view_input, view_output, &ctx);

    var shot = try headless.Offscreen.init(allocator, &text.engine, width, height);
    defer shot.deinit();

    // Frame 1: initial layout, nothing selected.
    try updateBrowser(&behavior, view_input, view_output, &ctx, &measure, init.io);
    {
        const visuals = try chrome.prepare(ctx.chromeState(), .{});
        var prepared = try shot.renderer.prepareVisuals(allocator, &text.engine, visuals.commands, 1);
        defer prepared.deinit();
        try shot.renderer.updateVisualResources(&text.engine);
        try shot.renderPreparedVisuals(&text.engine, &prepared, clear_rgb);
    }
    const shaped_after_frame1 = text.engine.shapeCacheSize();

    // Re-render the identical frame: with the shape cache warm, no run should
    // need reshaping.
    {
        const visuals = try chrome.prepare(ctx.chromeState(), .{});
        var prepared = try shot.renderer.prepareVisuals(allocator, &text.engine, visuals.commands, 1);
        defer prepared.deinit();
        try shot.renderer.updateVisualResources(&text.engine);
        try shot.renderPreparedVisuals(&text.engine, &prepared, clear_rgb);
    }
    const shaped_after_reframe = text.engine.shapeCacheSize();
    std.debug.print("shape cache: {} after frame 1, {} after identical re-render (delta {})\n", .{ shaped_after_frame1, shaped_after_reframe, shaped_after_reframe - shaped_after_frame1 });

    // Click the first asset row so the frame we capture exercises selection.
    var clicked = false;
    if (browser.domain.model.entries.items.len > 0) {
        const first_entry = browser.domain.model.entries.items[0];
        const element = browser.domain.identities.existingIdForPath(.asset, first_entry.path);
        if (if (element) |id| ctx.tree.findByElementId(id) else null) |row| {
            const rect = ctx.tree.getConst(row).layout_rect;
            const x = rect.x + rect.w * 0.5;
            const y = rect.y + rect.h * 0.5;
            try ctx.pushEvent(.{ .mouse_button = .{ .button = .left, .state = .pressed, .x = x, .y = y } });
            try ctx.pushEvent(.{ .mouse_button = .{ .button = .left, .state = .released, .x = x, .y = y } });
            clicked = true;
        }
    }

    try updateBrowser(&behavior, view_input, view_output, &ctx, &measure, init.io);
    const visuals = try chrome.prepare(ctx.chromeState(), .{});
    var prepared = try shot.renderer.prepareVisuals(allocator, &text.engine, visuals.commands, 1);
    defer prepared.deinit();
    try shot.renderer.updateVisualResources(&text.engine);
    try shot.renderPreparedVisuals(&text.engine, &prepared, clear_rgb);

    // Sample a spread of pixels to confirm real content rendered (not a
    // uniform clear) and report the selected row's fill color.
    var min = [3]u16{ 255, 255, 255 };
    var max = [3]u16{ 0, 0, 0 };
    var yy: u32 = 0;
    while (yy < height) : (yy += 17) {
        var xx: u32 = 0;
        while (xx < width) : (xx += 17) {
            const p = try shot.pixel(xx, yy);
            for (0..3) |c| {
                min[c] = @min(min[c], p[c]);
                max[c] = @max(max[c], p[c]);
            }
        }
    }
    std.debug.print("pixel spread: R[{}..{}] G[{}..{}] B[{}..{}]\n", .{ min[0], max[0], min[1], max[1], min[2], max[2] });

    if (clicked and browser.domain.model.selected_paths.items.len > 0 and browser.domain.model.entries.items.len > 0) {
        const first_entry = browser.domain.model.entries.items[0];
        const element = browser.domain.identities.existingIdForPath(.asset, first_entry.path);
        if (if (element) |id| ctx.tree.findByElementId(id) else null) |row| {
            const rect = ctx.tree.getConst(row).layout_rect;
            const px: u32 = @intFromFloat(@max(0, rect.x + rect.w * 0.5));
            const py: u32 = @intFromFloat(@max(0, rect.y + rect.h * 0.5));
            const p = try shot.pixel(@min(px, width - 1), @min(py, height - 1));
            std.debug.print("selected row #0 center pixel: R={} G={} B={}\n", .{ p[0], p[1], p[2] });
        }
    }

    const out = init.environ_map.get("GOOP_SHOT") orelse "shot.ppm";
    try shot.writePpm(init.io, out);
    std.debug.print("wrote {s} ({}x{})\n", .{ out, width, height });

    // Assert the frame is not a uniform clear.
    if (max[0] - min[0] < 10 and max[1] - min[1] < 10 and max[2] - min[2] < 10) {
        std.debug.print("FAIL: frame looks uniform (nothing rendered?)\n", .{});
        return error.UniformFrame;
    }
    std.debug.print("PASS: real UI rendered headlessly\n", .{});
}

fn updateBrowser(
    behavior: *fm.capabilities.Behavior,
    view_input: fm.capabilities.ViewInput,
    view_output: fm.capabilities.ViewOutput,
    ctx: *goop.Context,
    measure: *const goop.TextMeasureCtx,
    io: std.Io,
) !void {
    ctx.doLayout(measure);
    const events = try ctx.processEvents();
    if (try fm.controller.update(behavior, events, io)) {
        try fm.view.buildWidgetTree(view_input, view_output, ctx);
    }
    ctx.doLayout(measure);
    if (try fm.view.refreshAssetViewportIfNeeded(view_input, view_output, ctx)) {
        ctx.doLayout(measure);
    }
}
