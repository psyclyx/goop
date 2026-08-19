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
    primary_press_serial: ?u32 = null,
    external_drag_element: ?goop.ElementId = null,

    fn timedOut(self: Loop, io: std.Io) bool {
        const timeout = self.timeout_ns orelse return false;
        return monotonicNs(io) - self.started_ns >= timeout;
    }
};

/// A real, separate top-level window for "About goop files" — its own Wayland
/// surface, Vulkan swapchain, text engine, and widget tree. It is NOT an
/// overlay composited into the main window; the compositor owns it.
const about_close_id = goop.ElementId.init(0xA_B0_07_C105E);
const about_clear = [4]f32{ 250.0 / 255.0, 251.0 / 255.0, 253.0 / 255.0, 1.0 };

const AboutWindow = struct {
    window: platform.Window,
    text: text_module.Text,
    context: goop.Context,
    chrome: chrome_module.Chrome,
    target: gpu_module.Target,
    measure: goop.TextMeasureCtx,
    running: bool = true,
    configured: bool = false,
    frame_pending: bool = false,
    dirty: bool = true,
    width: u32 = 440,
    height: u32 = 240,

    fn open(gpu: *gpu_module.Gpu, parent: *platform.Window, io: std.Io, env: *const std.process.Environ.Map) !*AboutWindow {
        const self = try allocator.create(AboutWindow);
        errdefer allocator.destroy(self);
        const w: u32 = 440;
        const h: u32 = 240;

        self.window = try platform.Window.initChild(allocator, parent, .{
            .width = w,
            .height = h,
            .title = "About goop files",
            .application_id = "goop-files-about",
        });
        errdefer self.window.deinit();

        self.text = try text_module.Text.init(allocator, io, env);
        errdefer self.text.deinit();
        self.measure = self.text.measureContext();

        self.context = try goop.Context.init(allocator, .{ .width = w, .height = h });
        errdefer self.context.deinit();
        self.context.setTheme(fm.style.fileManagerThemeForScale(1));

        self.chrome = chrome_module.Chrome.init(allocator);
        errdefer self.chrome.deinit();

        // Share the main window's Vulkan instance and device — two independent
        // VkInstances crash NVIDIA at swapchain teardown.
        self.target = try gpu.openTarget(&self.window, &self.text.engine, w, h);
        errdefer self.target.deinit();

        self.running = true;
        self.configured = false;
        self.frame_pending = false;
        self.dirty = true;
        self.width = w;
        self.height = h;
        try self.build();
        return self;
    }

    fn build(self: *AboutWindow) !void {
        const ctx = &self.context;
        const transparent = goop.Color.rgba(0, 0, 0, 0);
        const root = try ctx.tree.addRoot(.{ .container = .{ .direction = .column } });
        _ = ctx.setStyle(root, .{
            .bg = .rgb(250, 251, 253),
            .padding = goop.style.Edges.all(24),
            .spacing = 10,
            .border_width = 0,
            .border_radius = 0,
        });
        const title = try ctx.tree.addChild(root, .{ .text = .{ .content = "goop files" } });
        _ = ctx.setStyle(title, .{ .font_size = 26, .fg = .rgb(20, 25, 33) });
        const body = try ctx.tree.addChild(root, .{ .text = .{
            .content = "A retained-mode file manager component — a leaner homage to Explorer, built to show off goop.",
            .overflow = .wrap,
        } });
        _ = ctx.setStyle(body, .{ .fg = .rgb(60, 68, 82), .font_size = 14.5 });
        const version = try ctx.tree.addChild(root, .{ .text = .{ .content = "goop 0.3.0 · retained UI toolkit" } });
        _ = ctx.setStyle(version, .{ .fg = .rgb(120, 128, 140), .font_size = 12.5 });
        // A growing filler pins the action row to the bottom of the window.
        _ = try ctx.tree.addChild(root, .{ .container = .{ .direction = .column } });
        const actions = try ctx.tree.addChild(root, .{ .container = .{ .direction = .row, .fit_main = true } });
        _ = ctx.setStyle(actions, .{ .bg = transparent, .padding = goop.style.Edges.all(0), .spacing = 0, .border_width = 0 });
        _ = try ctx.tree.addChild(actions, .{ .spacer = .{} });
        const close = try ctx.tree.addChildControl(actions, .{
            .identity = .{ .element_id = about_close_id, .action_id = null },
            .widget = .{ .button = .{ .label = "Close" } },
        });
        _ = ctx.setStyle(close, fm.style.fileManagerActionButtonStyle(1, true));
        _ = ctx.focusWidget(close);
    }

    /// Service the About window's own event queue and redraw. Returns once it
    /// should close (titlebar close, Escape, or the Close button).
    fn pump(self: *AboutWindow, io: std.Io) !void {
        // No dispatch here: the child shares the parent's Wayland connection, so
        // the main loop's single dispatch already routed our events to our queue.
        while (self.window.pollEvent()) |event| switch (event) {
            .close => self.running = false,
            .configured, .resized => |sz| {
                if (sz.width == 0 or sz.height == 0) continue;
                self.configured = true;
                self.width = sz.width;
                self.height = sz.height;
                self.context.setDimensions(sz.width, sz.height);
                try self.context.pushEvent(.{ .resize = .{ .width = sz.width, .height = sz.height } });
                self.target.resize(sz.width, sz.height);
                self.dirty = true;
            },
            .frame_ready => self.frame_pending = false,
            .pointer_enter, .pointer_motion => |p| {
                try self.context.pushEvent(.{ .mouse_move = .{ .x = @floatCast(p.x), .y = @floatCast(p.y) } });
                self.dirty = true;
            },
            .pointer_leave => {
                try self.context.pushEvent(.{ .mouse_move = .{ .x = -1, .y = -1 } });
                self.dirty = true;
            },
            .pointer_button => |btn| {
                const mapped: goop.Event.MouseButton.Button = switch (btn.button) {
                    0x110 => .left,
                    0x111 => .right,
                    0x112 => .middle,
                    else => continue,
                };
                try self.context.pushEvent(.{ .mouse_button = .{
                    .button = mapped,
                    .state = if (btn.state == .pressed) .pressed else .released,
                    .x = @floatCast(btn.position.x),
                    .y = @floatCast(btn.position.y),
                    .timestamp_ms = btn.time_ms,
                } });
                self.dirty = true;
            },
            .key => |key| {
                if (key.state == .pressed and keycode(key.scancode) == .escape) self.running = false;
                self.dirty = true;
            },
            else => {},
        };
        if (self.context.update(monotonicNs(io) / std.time.ns_per_ms).changed) self.dirty = true;
        if (self.configured and self.dirty and !self.frame_pending and self.running) try self.draw();
    }

    fn draw(self: *AboutWindow) !void {
        self.dirty = false;
        const ctx = &self.context;
        ctx.doLayout(&self.measure);
        const events = try ctx.processEvents();
        for (events.items) |ev| switch (ev) {
            .activated => |a| if (a.element == about_close_id) {
                self.running = false;
            },
            else => {},
        };
        if (!self.running) return;
        ctx.doLayout(&self.measure);
        const visuals = try self.chrome.prepare(ctx.chromeState(), .{});
        var prepared = try self.target.renderer.prepareVisuals(allocator, &self.text.engine, visuals.commands, 1);
        defer prepared.deinit();
        try self.target.renderer.updateVisualResources(&self.text.engine);
        const target = try self.target.beginFrame(&self.text.engine, about_clear) orelse {
            self.dirty = true;
            return;
        };
        try self.target.renderer.drawPreparedVisuals(target, &self.text.engine, &prepared);
        self.window.requestFrame();
        try self.target.presenter.endFrame();
        self.frame_pending = true;
    }

    fn deinit(self: *AboutWindow) void {
        self.target.deinit();
        self.chrome.deinit();
        self.context.deinit();
        self.text.deinit();
        self.window.deinit();
        allocator.destroy(self);
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
    _ = fm.view.tickPanelAnimations(view_input, view_output, monotonicNs(init.io));
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
    var about: ?*AboutWindow = null;
    defer if (about) |w| w.deinit();
    // Optional self-test hook: open the About window immediately so a timed,
    // headless-friendly run can exercise the real second-window path.
    if (init.environ_map.get("GOOP_ABOUT_ON_START") != null) {
        about = AboutWindow.open(&gpu, &window, init.io, init.environ_map) catch null;
    }
    while (loop.running and browser.session.running and !loop.timedOut(init.io)) {
        try drainEvents(
            &window,
            &gpu,
            &context,
            &browser.viewport,
            &browser.domain.interaction,
            &loop,
        );
        if (context.update(monotonicNs(init.io) / std.time.ns_per_ms).changed) loop.dirty = true;
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
        // The About command (logic layer) can only request; the composition
        // root owns windows, so it opens the real top-level here.
        if (browser.domain.interaction.about_requested) {
            browser.domain.interaction.about_requested = false;
            if (about == null) about = AboutWindow.open(&gpu, &window, init.io, init.environ_map) catch null;
        }
        if (about) |w| {
            w.pump(init.io) catch {
                w.deinit();
                about = null;
            };
            if (about) |still| if (!still.running) {
                still.deinit();
                about = null;
            };
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
