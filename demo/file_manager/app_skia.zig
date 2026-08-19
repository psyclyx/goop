//! File-manager composition root rendered by the Skia (GPU/Ganesh) backend.
//!
//! Shares all browser logic (`fm.*`) and the demo text engine with the snail
//! `app.zig`; only the renderer differs. The snail path is untouched — this is a
//! separate executable so nobody who does not want Skia links it.
//!
//! Needs a Wayland compositor and a real GPU:  zig build file-manager-skia -Dskia
//! Known gaps versus the snail demo: icon/image ops are not yet mapped onto
//! Skia (toolbar/list icons and image previews do not draw), text is measured
//! with the demo font but drawn with Skia's, and the About window and external
//! drag are not wired here.

const std = @import("std");
const goop = @import("goop");
const visual = @import("goop_visual");
const chrome_module = @import("goop_chrome");
const platform = @import("goop_platform_wayland");
const bridge = @import("goop_wayland_vulkan");
const graphics = @import("goop_graphics_vulkan");
const skia = @import("goop_render_skia");
const fm = @import("file_manager");
const text_module = @import("demo_text");
const image_decoder = @import("demo_image_decoder");

const allocator = std.heap.smp_allocator;

const clear_color = visual.Color{ .r = 242, .g = 245, .b = 247 };

const Loop = struct {
    running: bool = true,
    configured: bool = false,
    dirty: bool = true,
    width: u32 = 1280,
    height: u32 = 720,
    timeout_ns: ?u64 = null,
    started_ns: u64 = 0,

    fn timedOut(self: Loop, io: std.Io) bool {
        const limit = self.timeout_ns orelse return false;
        return monotonicNs(io) -| self.started_ns >= limit;
    }
};

pub fn main(init: std.process.Init) !void {
    var window = try platform.Window.init(allocator, .{
        .width = 1280,
        .height = 720,
        .title = "goop files · skia",
        .application_id = "goop-files-skia",
    });
    defer window.deinit();

    var text = try text_module.Text.init(allocator, init.io, init.environ_map);
    defer text.deinit();
    const measure_context = text.measureContext();

    var context = try goop.Context.init(allocator, .{ .width = 1280, .height = 720 });
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
    _ = fm.view.tickPanelAnimations(view_input, view_output, monotonicNs(init.io));
    try fm.view.buildWidgetTree(view_input, view_output, &context);

    // ── Skia GPU setup (replaces the snail Gpu) ──
    const extensions = bridge.requiredInstanceExtensions();
    var instance = try graphics.Instance.init("goop-file-manager-skia", extensions[0..]);
    defer instance.deinit();
    const handles = window.wsiHandles();
    var surface = try bridge.Surface.init(instance, .{
        .display = @ptrCast(handles.display),
        .surface = @ptrCast(handles.surface),
    });
    defer surface.deinit();
    var device = try graphics.Device.init(allocator, instance, surface.handle);
    defer device.deinit();
    var ctx = try skia.Context.initVulkan(instance, device);
    defer ctx.deinit();
    var target = try skia.WindowTarget.init(&ctx, device, surface.handle, 1280, 720, allocator);
    defer target.deinit();

    var loop = Loop{ .timeout_ns = parseTimeout(init.environ_map) };
    if (loop.timeout_ns != null) loop.started_ns = monotonicNs(init.io);

    while (loop.running and browser.session.running and !loop.timedOut(init.io)) {
        try drainEvents(&window, &target, &context, &browser.viewport, &browser.domain.interaction, &loop);
        if (context.update(monotonicNs(init.io) / std.time.ns_per_ms).changed) loop.dirty = true;
        if (loop.configured and loop.dirty) {
            try draw(&window, &text, &context, &chrome, &behavior, view_input, view_output, &measure_context, &target, &loop, init.io);
        }
        try window.dispatchTimeout(50);
    }
}

fn drainEvents(
    window: *platform.Window,
    target: *skia.WindowTarget,
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
                try context.pushEvent(.{ .resize = .{ .width = size.width, .height = size.height } });
                try target.resize(size.width, size.height);
                loop.dirty = true;
            },
            .frame_ready => {},
            .pointer_enter, .pointer_motion => |position| {
                try context.pushEvent(.{ .mouse_move = .{ .x = @floatCast(position.x), .y = @floatCast(position.y) } });
                loop.dirty = true;
            },
            .pointer_leave => {
                if (!context.pointerGestureActive()) {
                    try context.pushEvent(.{ .mouse_move = .{ .x = -1, .y = -1 } });
                }
                loop.dirty = true;
            },
            .pointer_button => |button| {
                const mapped: goop.Event.MouseButton.Button = switch (button.button) {
                    0x110 => .left,
                    0x111 => .right,
                    0x112 => .middle,
                    else => continue,
                };
                try context.pushEvent(.{ .mouse_button = .{
                    .button = mapped,
                    .state = if (button.state == .pressed) .pressed else .released,
                    .x = @floatCast(button.position.x),
                    .y = @floatCast(button.position.y),
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
                try context.pushEvent(.{ .key = normalized_key });
                fm.controller.keyInput(interaction, normalized_key, context.focusedElementId());
                if (key.state == .pressed) {
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

fn draw(
    window: *platform.Window,
    text: *text_module.Text,
    context: *goop.Context,
    chrome: *chrome_module.Chrome,
    behavior: *fm.capabilities.Behavior,
    view_input: fm.capabilities.ViewInput,
    view_output: fm.capabilities.ViewOutput,
    measure_context: *const goop.TextMeasureCtx,
    target: *skia.WindowTarget,
    loop: *Loop,
    io: std.Io,
) !void {
    _ = text;
    loop.dirty = false;
    context.doLayout(measure_context);
    const events = try context.processEvents();
    const rebuild = try fm.controller.update(behavior, events, io);
    context.setTheme(fm.style.fileManagerThemeForScale(behavior.viewport.ui_scale));
    const animation = fm.view.tickPanelAnimations(view_input, view_output, monotonicNs(io));
    if (rebuild or animation.changed) try fm.view.buildWidgetTree(view_input, view_output, context);
    context.doLayout(measure_context);
    if (try fm.view.refreshAssetViewportIfNeeded(view_input, view_output, context)) {
        context.doLayout(measure_context);
    }
    window.setPointerCursor(switch (context.pointerCursor()) {
        .default => .default,
        .text => .text,
        .resize_horizontal => .resize_horizontal,
        .resize_vertical => .resize_vertical,
    });

    const frame = (try target.acquire()) orelse {
        loop.dirty = true;
        return;
    };
    var f = frame;
    var enc = f.surface.encoder();
    enc.clear(clear_color);
    // icon/image/custom ops are stubs on the Skia encoder; surfaces and text
    // render. No custom-visual resolver, so image previews stay blank for now.
    try chrome.emit(context.chromeState(), .{}, &enc);
    window.requestFrame();
    try target.present(f);
    loop.dirty = animation.active;
}

fn currentModifiers(interaction: *const fm.state.Interaction) goop.Event.Modifiers {
    return .{ .ctrl = interaction.ctrl_down, .shift = interaction.shift_down };
}

fn normalizedModifiers(value: platform.Modifiers) goop.Event.Modifiers {
    return .{ .ctrl = value.control, .shift = value.shift, .alt = value.alt, .super = value.logo };
}

fn keycode(scancode: u32) goop.Event.Keycode {
    return switch (scancode) {
        16 => .q,  17 => .w,  18 => .e,  19 => .r,  20 => .t,
        21 => .y,  22 => .u,  23 => .i,  24 => .o,  25 => .p,
        30 => .a,  31 => .s,  32 => .d,  33 => .f,  34 => .g,
        35 => .h,  36 => .j,  37 => .k,  38 => .l,
        44 => .z,  45 => .x,  46 => .c,  47 => .v,  48 => .b,
        49 => .n,  50 => .m,
        2 => .digit_1,  3 => .digit_2,  4 => .digit_3,  5 => .digit_4,
        6 => .digit_5,  7 => .digit_6,  8 => .digit_7,  9 => .digit_8,
        10 => .digit_9, 11 => .digit_0,
        59 => .f1,  60 => .f2,  61 => .f3,  62 => .f4,  63 => .f5,
        64 => .f6,  65 => .f7,  66 => .f8,  67 => .f9,  68 => .f10,
        87 => .f11, 88 => .f12,
        14 => .backspace,
        111 => .delete,
        110 => .insert,
        15 => .tab,
        28 => .enter,
        57 => .space,
        1 => .escape,
        42 => .left_shift,
        54 => .right_shift,
        29 => .left_ctrl,
        97 => .right_ctrl,
        56 => .left_alt,
        100 => .right_alt,
        12 => .minus,
        13 => .equal,
        102 => .home,
        105 => .left,
        106 => .right,
        103 => .up,
        108 => .down,
        107 => .end,
        104 => .page_up,
        109 => .page_down,
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
