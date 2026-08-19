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
const fm_render = @import("fm_render");
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
    primary_press_serial: ?u32 = null,
    external_drag_element: ?goop.ElementId = null,

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

    const renderer = try fm_render.Renderer.create(&window, init.io, init.environ_map, 1280, 720);
    defer renderer.destroy();
    const measure_context = renderer.measureContext();

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
    _ = fm.view.tickPanelAnimations(view_input, view_output, monotonicNs(init.io));
    try fm.view.buildWidgetTree(view_input, view_output, &context);

    var loop = Loop{ .timeout_ns = parseTimeout(init.environ_map) };
    if (loop.timeout_ns != null) loop.started_ns = monotonicNs(init.io);
    // Optional self-test hook: request the About window immediately so a timed,
    // headless-friendly run can exercise the real second-window path.
    if (comptime fm_render.supports_about) {
        if (init.environ_map.get("GOOP_ABOUT_ON_START") != null) {
            browser.domain.interaction.about_requested = true;
        }
    }
    while (loop.running and browser.session.running and !loop.timedOut(init.io)) {
        try drainEvents(
            &window,
            renderer,
            &context,
            &browser.viewport,
            &browser.domain.interaction,
            &loop,
        );
        if (context.update(monotonicNs(init.io) / std.time.ns_per_ms).changed) loop.dirty = true;
        if (loop.configured and loop.dirty and !loop.frame_pending) {
            try draw(
                &window,
                renderer,
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
        // The About command (logic layer) can only request; the composition root
        // owns windows. Only backends that support child windows service it.
        const about_requested = browser.domain.interaction.about_requested;
        browser.domain.interaction.about_requested = false;
        if (comptime fm_render.supports_about) {
            renderer.serviceAbout(&window, init.io, init.environ_map, about_requested);
        }
        try window.dispatchTimeout(50);
    }
}

fn drainEvents(
    window: *platform.Window,
    renderer: *fm_render.Renderer,
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
                renderer.resize(size.width, size.height);
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
                if (mapped == .left) {
                    if (button.state == .pressed) {
                        loop.primary_press_serial = button.serial;
                        loop.external_drag_element = null;
                    } else {
                        loop.primary_press_serial = null;
                        loop.external_drag_element = null;
                    }
                }
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
    renderer: *fm_render.Renderer,
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
    try beginExternalFileDrag(window, context, behavior, loop);
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
    fm.view.debugLogLayout(view_input, view_output, context);
    const visuals = try chrome.prepare(context.chromeState(), .{
        .custom_visual = .{
            .context = behavior.domain,
            .resolve_fn = resolveBrowserCustomVisual,
        },
    });
    const presented = try renderer.renderFrame(window, visuals.commands, clear_color);
    if (!presented) {
        loop.dirty = true;
        return;
    }
    loop.frame_pending = true;
    loop.dirty = animation.active;
}

fn beginExternalFileDrag(
    window: *platform.Window,
    context: *const goop.Context,
    behavior: *fm.capabilities.Behavior,
    loop: *Loop,
) !void {
    const serial = loop.primary_press_serial orelse return;
    const element = context.draggedElementId() orelse return;
    if (loop.external_drag_element == element) return;
    if (fm.ids.family(element) != .asset) return;
    const path = behavior.domain.identities.path(element) orelse return;
    const paths: []const []const u8 = if (fm.model.isPathSelected(&behavior.domain.model, path))
        behavior.domain.model.selected_paths.items
    else
        &.{path};
    try fm.transfer.setDragSelection(&behavior.effects.transfer, paths);
    window.startExternalDrag(serial, .{
        .uri_list = behavior.effects.transfer.drag_uri_list_buf.items,
        .plain_text = behavior.effects.transfer.drag_plain_buf.items,
        .gnome_files = behavior.effects.transfer.drag_gnome_files_buf.items,
    }) catch |err| switch (err) {
        error.DragUnavailable, error.DragAlreadyActive => return,
        else => return err,
    };
    loop.external_drag_element = element;
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
        // Letters (evdev), full A–Z so Alt+<letter> mnemonics and in-menu
        // access keys work for every menu.
        16 => .q,  17 => .w,  18 => .e,  19 => .r,  20 => .t,
        21 => .y,  22 => .u,  23 => .i,  24 => .o,  25 => .p,
        30 => .a,  31 => .s,  32 => .d,  33 => .f,  34 => .g,
        35 => .h,  36 => .j,  37 => .k,  38 => .l,
        44 => .z,  45 => .x,  46 => .c,  47 => .v,  48 => .b,
        49 => .n,  50 => .m,
        // Digits
        2 => .digit_1,  3 => .digit_2,  4 => .digit_3,  5 => .digit_4,
        6 => .digit_5,  7 => .digit_6,  8 => .digit_7,  9 => .digit_8,
        10 => .digit_9, 11 => .digit_0,
        // Function keys (Explorer: F2 rename, F5 refresh)
        59 => .f1,  60 => .f2,  61 => .f3,  62 => .f4,  63 => .f5,
        64 => .f6,  65 => .f7,  66 => .f8,  67 => .f9,  68 => .f10,
        87 => .f11, 88 => .f12,
        // Editing / navigation
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

test "browser composition state contains no browser model fields" {
    try std.testing.expect(!@hasField(Loop, "entries"));
    try std.testing.expect(!@hasField(Loop, "renderer"));
}
