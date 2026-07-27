//! File-manager composition root.
//!
//! Browser logic owns no window or GPU. This module only translates platform
//! events, invokes the controller, and connects paint deltas to presentation.

const std = @import("std");
const goop = @import("goop");
const display = @import("goop_display");
const platform = @import("goop_platform_wayland");
const logic = @import("file_manager_logic");
const text_module = @import("demo_text");
const paint_convert = @import("paint_convert");
const gpu_module = @import("demo_gpu");

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
    var browser = logic.State{};
    try logic.initSession(
        &browser,
        init.io,
        init.environ_map,
        &context,
        &measure_context,
    );
    defer logic.deinitSession(&browser);
    logic.resize(&browser, &context, 1280, 720);

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
    while (loop.running and browser.runtime.running and !loop.timedOut(init.io)) {
        try drainEvents(
            &window,
            &gpu,
            &context,
            &browser,
            &loop,
        );
        if (loop.configured and loop.dirty and !loop.frame_pending) {
            try draw(
                &window,
                &gpu,
                &text,
                &context,
                &browser,
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
    browser: *logic.State,
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
                logic.resize(browser, context, size.width, size.height);
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
                logic.pointerPosition(browser, x, y);
                try context.pushEvent(.{ .mouse_move = .{ .x = x, .y = y } });
                loop.dirty = true;
            },
            .pointer_leave => {
                logic.pointerPosition(browser, -1, -1);
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
                logic.pointerPosition(browser, x, y);
                if (mapped == .left and button.state == .released) {
                    logic.primaryReleased(browser, x, y);
                }
                try context.pushEvent(.{ .mouse_button = .{
                    .button = mapped,
                    .state = if (button.state == .pressed) .pressed else .released,
                    .x = x,
                    .y = y,
                    .timestamp_ms = button.time_ms,
                    .mods = currentModifiers(browser),
                } });
                loop.dirty = true;
            },
            .scroll => |scroll| {
                try context.pushEvent(.{ .mouse_scroll = .{
                    .dx = if (scroll.axis == .horizontal) @floatCast(scroll.delta) else 0,
                    .dy = if (scroll.axis == .vertical) @floatCast(scroll.delta) else 0,
                    .mods = currentModifiers(browser),
                } });
                loop.dirty = true;
            },
            .key => |key| {
                const mapped = keycode(key.scancode);
                const mods = modifiers(key.modifiers);
                const pressed = key.state == .pressed;
                try context.pushEvent(.{ .key = .{
                    .scancode = key.scancode,
                    .keycode = mapped,
                    .state = if (pressed) .pressed else .released,
                    .mods = mods,
                } });
                logic.keyInput(browser, context, mapped, pressed, mods);
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
    browser: *logic.State,
    measure_context: *const goop.TextMeasureCtx,
    loop: *Loop,
    io: std.Io,
) !void {
    loop.dirty = false;
    try logic.update(browser, context, measure_context, io);
    const paint_list = try logic.paint(browser, context, measure_context);
    const commands = try paint_convert.convert(allocator, paint_list, 1);
    defer allocator.free(commands);

    const target = try gpu.beginFrame(&text.engine, clear_color) orelse {
        loop.dirty = true;
        return;
    };
    try gpu.renderer.drawPaintList(target, &text.engine, commands);
    window.requestFrame();
    try gpu.presenter.endFrame();
    loop.frame_pending = true;
}

fn currentModifiers(browser: *const logic.State) goop.Event.Modifiers {
    return .{
        .ctrl = browser.interaction.ctrl_down,
        .shift = browser.interaction.shift_down,
    };
}

fn modifiers(value: platform.Modifiers) goop.Event.Modifiers {
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
    _ = display;
}
