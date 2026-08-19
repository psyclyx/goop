//! Composition root for the full widget showcase.

const std = @import("std");
const goop = @import("goop");
const chrome_module = @import("goop_chrome");
const platform = @import("goop_platform_wayland");
const text_module = @import("demo_text");
const gpu_module = @import("demo_gpu");
const view = @import("showcase_view");
const controller = @import("showcase_controller");
const ids = @import("showcase_ids");

const allocator = std.heap.smp_allocator;

const Loop = struct {
    running: bool = true,
    configured: bool = false,
    frame_pending: bool = false,
    dirty: bool = true,
    width: u32 = 800,
    height: u32 = 600,
    timeout_ns: ?u64 = null,
    started_ns: u64 = 0,

    fn timedOut(self: Loop, io: std.Io) bool {
        const timeout = self.timeout_ns orelse return false;
        return monotonicNs(io) - self.started_ns >= timeout;
    }
};

const Clipboard = struct {
    bytes: std.ArrayListUnmanaged(u8) = .empty,

    fn deinit(self: *Clipboard) void {
        self.bytes.deinit(allocator);
    }

    fn api(self: *Clipboard) goop.Clipboard {
        return .{
            .ptr = self,
            .getTextFn = @ptrCast(&getText),
            .setTextFn = @ptrCast(&setText),
        };
    }

    fn getText(pointer: *anyopaque) ?[]const u8 {
        const self: *Clipboard = @ptrCast(@alignCast(pointer));
        return if (self.bytes.items.len == 0) null else self.bytes.items;
    }

    fn setText(pointer: *anyopaque, bytes: []const u8) void {
        const self: *Clipboard = @ptrCast(@alignCast(pointer));
        self.bytes.clearRetainingCapacity();
        self.bytes.appendSlice(allocator, bytes) catch {};
    }
};

pub fn main(init: std.process.Init) !void {
    var window = try platform.Window.init(allocator, .{
        .width = 800,
        .height = 600,
        .title = "goop demo",
        .application_id = "goop-demo",
    });
    defer window.deinit();

    var text = try text_module.Text.init(allocator, init.io, init.environ_map);
    defer text.deinit();
    const measure_context = text.measureContext();

    var context = try goop.Context.init(allocator, .{ .width = 800, .height = 600 });
    defer context.deinit();
    var chrome = chrome_module.Chrome.init(allocator);
    defer chrome.deinit();
    var clipboard = Clipboard{};
    defer clipboard.deinit();
    context.setClipboard(clipboard.api());

    try view.build(&context);
    var model = controller.Model{};
    defer model.deinit(allocator);
    var gpu = try gpu_module.Gpu.init(
        allocator,
        &window,
        &text.engine,
        800,
        600,
        "goop-showcase",
    );
    defer gpu.deinit();

    var loop = Loop{ .timeout_ns = parseTimeout(init.environ_map) };
    if (loop.timeout_ns != null) loop.started_ns = monotonicNs(init.io);
    while (loop.running and !loop.timedOut(init.io)) {
        try drainEvents(&window, &gpu, &context, &loop);
        const now_ms = monotonicNs(init.io) / std.time.ns_per_ms;
        if (context.update(now_ms).changed) loop.dirty = true;
        if (loop.configured and loop.dirty and !loop.frame_pending) {
            try draw(
                &window,
                &gpu,
                &text,
                &context,
                &chrome,
                &model,
                &measure_context,
                &loop,
                now_ms,
            );
        }
        try window.dispatchTimeout(50);
    }
}

fn drainEvents(
    window: *platform.Window,
    gpu: *gpu_module.Gpu,
    context: *goop.Context,
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
                try context.pushEvent(.{ .mouse_move = .{
                    .x = @floatCast(position.x),
                    .y = @floatCast(position.y),
                } });
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
                try context.pushEvent(.{ .mouse_button = .{
                    .button = mapped,
                    .state = if (button.state == .pressed) .pressed else .released,
                    .x = @floatCast(button.position.x),
                    .y = @floatCast(button.position.y),
                    .timestamp_ms = button.time_ms,
                } });
                loop.dirty = true;
            },
            .scroll => |scroll| {
                try context.pushEvent(.{ .mouse_scroll = .{
                    .dx = if (scroll.axis == .horizontal) @floatCast(scroll.delta) else 0,
                    .dy = if (scroll.axis == .vertical) @floatCast(scroll.delta) else 0,
                } });
                loop.dirty = true;
            },
            .key => |key| {
                try context.pushEvent(.{ .key = .{
                    .scancode = key.scancode,
                    .keycode = keycode(key.scancode),
                    .state = if (key.state == .pressed) .pressed else .released,
                    .mods = modifiers(key.modifiers),
                } });
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

const clear_color = [4]f32{ 30.0 / 255.0, 30.0 / 255.0, 30.0 / 255.0, 1.0 };

fn draw(
    window: *platform.Window,
    gpu: *gpu_module.Gpu,
    text: *text_module.Text,
    context: *goop.Context,
    chrome: *chrome_module.Chrome,
    model: *controller.Model,
    measure_context: *const goop.TextMeasureCtx,
    loop: *Loop,
    now_ms: u64,
) !void {
    loop.dirty = false;
    context.doLayout(measure_context);
    const events = try context.processEvents();
    _ = context.update(now_ms);
    try controller.update(model, allocator, events);
    const popup = model.context_popup;
    view.applyPopupProjection(
        context,
        ids.element.context_popup,
        popup.visible,
        popup.x,
        popup.y,
    );
    context.doLayout(measure_context);
    window.setPointerCursor(switch (context.pointerCursor()) {
        .default => .default,
        .text => .text,
        .resize_horizontal => .resize_horizontal,
        .resize_vertical => .resize_vertical,
    });

    const paint_list = try chrome.prepare(context.chromeState(), .{});
    const logical_to_physical_scale: f32 = 1;
    var prepared = try gpu.renderer.prepareVisuals(
        allocator,
        &text.engine,
        paint_list.commands,
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

test "the showcase composition root does not flatten subsystem owners" {
    try std.testing.expect(!@hasField(Loop, "renderer"));
    try std.testing.expect(!@hasField(Loop, "window"));
}
