//! File-manager composition root.
//!
//! Browser logic owns no window or GPU. This module only translates platform
//! events, invokes the controller, and connects resolved visuals to presentation.

const std = @import("std");
const goop = @import("goop");
const visual = @import("goop_visual");
const chrome_module = @import("goop_chrome");
const platform = @import("goop_platform_wayland");
const fm = @import("file_manager");
const text_module = @import("demo_text");
const gpu_module = @import("demo_gpu");
const image_decoder = @import("demo_image_decoder");

const allocator = std.heap.smp_allocator;

const Loop = struct {
    running: bool = true,
    configured: bool = false,
    frame_pending: bool = false,
    dirty: bool = true,
    width: u32 = 1280,
    height: u32 = 720,
    timeout_ns: ?u64 = null,
    started_ns: u64 = 0,

    fn timedOut(self: Loop, io: std.Io) bool {
        const timeout = self.timeout_ns orelse return false;
        return monotonicNs(io) - self.started_ns >= timeout;
    }
};

pub fn main(init: std.process.Init) !void {
    var window = try platform.Window.init(allocator, .{
        .width = 1280,
        .height = 720,
        .title = "goop files",
        .application_id = "goop-files",
    });
    defer window.deinit();

    var text = try text_module.Text.init(allocator, init.io, init.environ_map);
    defer text.deinit();
    const measure_context = text.measureContext();

    var context = try goop.Context.init(allocator, .{
        .width = 1280,
        .height = 720,
    });
    defer context.deinit();
    var chrome = chrome_module.Chrome.init(allocator);
    defer chrome.deinit();
    var browser: fm.state.Browser = .{};
    var behavior = fm.capabilities.behaviorWithImages(
        &browser.session,
        &browser.viewport,
        &browser.domain,
        &browser.effects,
        image_decoder.decoder,
    );
    try fm.controller.init(&behavior, init.io, init.environ_map);
    defer {
        fm.projection.deinit(&browser.projection);
        browser.domain.identities.deinit();
        fm.controller.deinit(&behavior);
    }
    fm.projection.configure(&browser.projection, &measure_context);
    context.setTheme(fm.style.fileManagerThemeForScale(browser.viewport.ui_scale));
    context.setClipboard(fm.controller.clipboard(&browser.effects.transfer));
    fm.controller.resize(&browser.viewport, 1280, 720);
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
    try fm.view.buildWidgetTree(view_input, view_output, &context);

    var gpu = try gpu_module.Gpu.init(
        allocator,
        &window,
        &text.engine,
        1280,
        720,
        "goop-file-manager",
    );
    defer gpu.deinit();

    var loop = Loop{ .timeout_ns = parseTimeout(init.environ_map) };
    if (loop.timeout_ns != null) loop.started_ns = monotonicNs(init.io);
    while (loop.running and browser.session.running and !loop.timedOut(init.io)) {
        try drainEvents(
            &window,
            &gpu,
            &context,
            &browser.viewport,
            &browser.domain.interaction,
            &loop,
        );
        if (loop.configured and loop.dirty and !loop.frame_pending) {
            try draw(
                &window,
                &gpu,
                &text,
                &context,
                &chrome,
                &behavior,
                view_input,
                view_output,
                &measure_context,
                &loop,
                init.io,
            );
        }
        try window.dispatchTimeout(50);
    }
}

fn drainEvents(
    window: *platform.Window,
    gpu: *gpu_module.Gpu,
    context: *goop.Context,
    viewport: *fm.state.Viewport,
    interaction: *fm.state.Interaction,
    loop: *Loop,
) !void {
    while (window.pollEvent()) |event| {
        switch (event) {
            .close => loop.running = false,
            .configured, .resized => |size| {
                if (size.width == 0 or size.height == 0) continue;
                loop.configured = true;
                loop.width = size.width;
                loop.height = size.height;
                fm.controller.resize(viewport, size.width, size.height);
                context.setDimensions(size.width, size.height);
                try context.pushEvent(.{ .resize = .{
                    .width = size.width,
                    .height = size.height,
                } });
                gpu.resize(size.width, size.height);
                loop.dirty = true;
            },
            .frame_ready => loop.frame_pending = false,
            .pointer_enter, .pointer_motion => |position| {
                const x: f32 = @floatCast(position.x);
                const y: f32 = @floatCast(position.y);
                try context.pushEvent(.{ .mouse_move = .{ .x = x, .y = y } });
                loop.dirty = true;
            },
            .pointer_leave => {
                try context.pushEvent(.{ .mouse_move = .{ .x = -1, .y = -1 } });
                loop.dirty = true;
            },
            .pointer_button => |button| {
                const mapped: goop.Event.MouseButton.Button = switch (button.button) {
                    0x110 => .left,
                    0x111 => .right,
                    0x112 => .middle,
                    else => continue,
                };
                const x: f32 = @floatCast(button.position.x);
                const y: f32 = @floatCast(button.position.y);
                try context.pushEvent(.{ .mouse_button = .{
                    .button = mapped,
                    .state = if (button.state == .pressed) .pressed else .released,
                    .x = x,
                    .y = y,
                    .timestamp_ms = button.time_ms,
                    .mods = currentModifiers(interaction),
                } });
                loop.dirty = true;
            },
            .scroll => |scroll| {
                try context.pushEvent(.{ .mouse_scroll = .{
                    .dx = if (scroll.axis == .horizontal) @floatCast(scroll.delta) else 0,
                    .dy = if (scroll.axis == .vertical) @floatCast(scroll.delta) else 0,
                    .mods = currentModifiers(interaction),
                } });
                loop.dirty = true;
            },
            .key => |key| {
                const normalized_key = goop.Event.Key{
                    .scancode = key.scancode,
                    .keycode = keycode(key.scancode),
                    .state = if (key.state == .pressed) .pressed else .released,
                    .mods = normalizedModifiers(key.modifiers),
                };
                const pressed = key.state == .pressed;
                try context.pushEvent(.{ .key = normalized_key });
                fm.controller.keyInput(
                    interaction,
                    normalized_key,
                    context.focusedElementId(),
                );
                if (pressed) {
                    if (key.codepoint) |codepoint| {
                        try context.pushEvent(.{ .text = .{ .codepoint = codepoint } });
                    }
                }
                loop.dirty = true;
            },
            .keyboard_leave => {
                try context.pushEvent(.{ .focus = .{ .focused = false } });
                loop.dirty = true;
            },
        }
    }
}

const clear_color = [4]f32{ 242.0 / 255.0, 245.0 / 255.0, 247.0 / 255.0, 1.0 };

fn draw(
    window: *platform.Window,
    gpu: *gpu_module.Gpu,
    text: *text_module.Text,
    context: *goop.Context,
    chrome: *chrome_module.Chrome,
    behavior: *fm.capabilities.Behavior,
    view_input: fm.capabilities.ViewInput,
    view_output: fm.capabilities.ViewOutput,
    measure_context: *const goop.TextMeasureCtx,
    loop: *Loop,
    io: std.Io,
) !void {
    loop.dirty = false;
    context.doLayout(measure_context);
    const events = try context.processEvents();
    const rebuild = try fm.controller.update(behavior, events, io);
    if (rebuild) try fm.view.buildWidgetTree(view_input, view_output, context);
    context.doLayout(measure_context);
    if (try fm.view.refreshAssetViewportIfNeeded(view_input, view_output, context)) {
        context.doLayout(measure_context);
    }
    fm.view.debugLogLayout(view_input, view_output, context);
    const visuals = try chrome.prepare(context.chromeState(), .{
        .custom_visual = .{
            .context = behavior.domain,
            .resolve_fn = resolveBrowserCustomVisual,
        },
    });
    const logical_to_physical_scale: f32 = 1;
    var prepared = try gpu.renderer.prepareVisuals(
        allocator,
        &text.engine,
        visuals.commands,
        logical_to_physical_scale,
    );
    defer prepared.deinit();
    try gpu.renderer.updateVisualResources(&text.engine);

    const target = try gpu.beginFrame(&text.engine, clear_color) orelse {
        loop.dirty = true;
        return;
    };
    try gpu.renderer.drawPreparedVisuals(target, &text.engine, &prepared);
    window.requestFrame();
    try gpu.presenter.endFrame();
    loop.frame_pending = true;
}

fn resolveBrowserCustomVisual(
    context_ptr: *anyopaque,
    custom: visual.Custom,
) ?visual.Operation {
    const domain: *fm.state.Domain = @ptrCast(@alignCast(context_ptr));
    const preview_id = visual.CustomId.fromElementId(fm.ids.fixed(.preview_image).value());
    if (custom.id.namespace != preview_id.namespace or custom.id.value != preview_id.value) return null;
    const pixels = if (domain.presentation.preview.image) |*value| value else return null;
    return .{ .image = .{
        .bounds = custom.bounds,
        .source = pixels.view(domain.presentation.preview.image_id),
        .fit = .contain,
    } };
}

fn currentModifiers(interaction: *const fm.state.Interaction) goop.Event.Modifiers {
    return .{
        .ctrl = interaction.ctrl_down,
        .shift = interaction.shift_down,
    };
}

fn normalizedModifiers(value: platform.Modifiers) goop.Event.Modifiers {
    return .{
        .ctrl = value.control,
        .shift = value.shift,
        .alt = value.alt,
        .super = value.logo,
    };
}

fn keycode(scancode: u32) goop.Event.Keycode {
    return switch (scancode) {
        14 => .backspace,
        111 => .delete,
        15 => .tab,
        28 => .enter,
        57 => .space,
        1 => .escape,
        42 => .left_shift,
        54 => .right_shift,
        29 => .left_ctrl,
        97 => .right_ctrl,
        30 => .a,
        46 => .c,
        47 => .v,
        45 => .x,
        102 => .home,
        105 => .left,
        106 => .right,
        103 => .up,
        108 => .down,
        107 => .end,
        else => .unknown,
    };
}

fn parseTimeout(environment: *const std.process.Environ.Map) ?u64 {
    const raw = environment.get("GOOP_DEMO_TIMEOUT") orelse return null;
    const seconds = std.fmt.parseFloat(f64, raw) catch return null;
    if (seconds <= 0) return null;
    return @intFromFloat(seconds * @as(f64, @floatFromInt(std.time.ns_per_s)));
}

fn monotonicNs(io: std.Io) u64 {
    const value = std.Io.Clock.awake.now(io).nanoseconds;
    return if (value <= 0) 0 else @intCast(value);
}

test "browser composition state contains no browser model fields" {
    try std.testing.expect(!@hasField(Loop, "entries"));
    try std.testing.expect(!@hasField(Loop, "renderer"));
}
