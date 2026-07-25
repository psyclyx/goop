//! File browser composition root.
//!
//! This is the only browser module that knows the platform, retained driver,
//! Vulkan subsystem, and browser controller at the same time.

const std = @import("std");
const display = @import("goop_display");
const ui = @import("goop_ui");
const driver_module = @import("goop_driver");
const platform = @import("goop_platform_wayland");
const snail = @import("goop_snail");
const model_module = @import("file_browser_model");
const controller_module = @import("file_browser_controller");
const view = @import("file_browser_view");
const font = @import("font.zig");
const gpu_module = @import("gpu.zig");

const allocator = std.heap.smp_allocator;

const LoopState = struct {
    running: bool = true,
    configured: bool = false,
    frame_pending: bool = false,
    width: u32 = 1280,
    height: u32 = 720,
    timeout_ns: ?u64 = null,
    started_ns: u64 = 0,

    fn timedOut(self: LoopState, io: std.Io) bool {
        const timeout = self.timeout_ns orelse return false;
        return monotonicNs(io) - self.started_ns >= timeout;
    }
};

pub fn main(init: std.process.Init) !void {
    var window = try platform.Window.init(allocator, .{
        .width = 1280,
        .height = 720,
        .title = "Goop File Browser",
        .application_id = "dev.goop.file-browser",
    });
    defer window.deinit();

    const font_bytes = try font.load(allocator, init.io, init.environ_map);
    defer allocator.free(font_bytes);
    var text = try snail.TextEngine.init(allocator, font_bytes, .{});
    defer text.deinit();

    const cwd = try model_module.currentDirectory(allocator, init.io);
    defer allocator.free(cwd);
    var model = try model_module.Model.init(allocator, init.io, cwd);
    defer model.deinit();

    var retained_driver = driver_module.DeclarativeDriver.init(allocator);
    defer retained_driver.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var gpu = try gpu_module.Gpu.init(allocator, &window, &text, 1280, 720);
    defer gpu.deinit();

    var loop = LoopState{
        .timeout_ns = parseTimeout(init.environ_map),
    };
    if (loop.timeout_ns != null) loop.started_ns = monotonicNs(init.io);
    try runLoop(
        init.io,
        &window,
        &gpu,
        &text,
        &model,
        &retained_driver,
        &arena,
        &loop,
    );
}

fn runLoop(
    io: std.Io,
    window: *platform.Window,
    gpu: *gpu_module.Gpu,
    text: *snail.TextEngine,
    model: *model_module.Model,
    retained_driver: *driver_module.DeclarativeDriver,
    arena: *std.heap.ArenaAllocator,
    loop: *LoopState,
) !void {
    while (loop.running and !loop.timedOut(io)) {
        try drainPlatformEvents(window, gpu, model, retained_driver, loop);
        try applyBrowserActions(model, retained_driver, loop);

        if (loop.configured and !loop.frame_pending and retained_driver.needsFrame()) {
            const presented = try drawBrowserFrame(
                window,
                gpu,
                text,
                model,
                retained_driver,
                arena,
                loop,
            );
            if (presented) {
                loop.frame_pending = true;
                continue;
            }
        }
        try window.dispatchTimeout(50);
    }
}

fn drainPlatformEvents(
    window: *platform.Window,
    gpu: *gpu_module.Gpu,
    model: *model_module.Model,
    retained_driver: *driver_module.DeclarativeDriver,
    loop: *LoopState,
) !void {
    while (window.pollEvent()) |event| {
        switch (event) {
            .close => loop.running = false,
            .configured => |size| {
                loop.configured = true;
                try resize(gpu, retained_driver, loop, size);
            },
            .resized => |size| try resize(gpu, retained_driver, loop, size),
            .frame_ready => loop.frame_pending = false,
            .pointer_enter, .pointer_motion => |position| {
                try retained_driver.pushEvent(.{ .pointer_motion = .{
                    .x = @floatCast(position.x),
                    .y = @floatCast(position.y),
                } });
            },
            .pointer_leave => try retained_driver.pushEvent(.pointer_leave),
            .pointer_button => |button| {
                try retained_driver.pushEvent(.{ .pointer_button = .{
                    .button = switch (button.button) {
                        0x110 => .primary,
                        0x111 => .secondary,
                        else => .other,
                    },
                    .state = if (button.state == .pressed) .pressed else .released,
                    .position = .{
                        .x = @floatCast(button.position.x),
                        .y = @floatCast(button.position.y),
                    },
                } });
            },
            .scroll => |scroll| {
                if (scroll.axis == .vertical) {
                    const rows: i32 = if (scroll.delta > 0) 3 else -3;
                    const viewport = view.Viewport{
                        .width = @floatFromInt(loop.width),
                        .height = @floatFromInt(loop.height),
                    };
                    const outcome = (controller_module.Controller{ .model = model }).scroll(
                        rows,
                        viewport.visibleRows(),
                    );
                    if (outcome.model_changed) retained_driver.invalidate();
                }
            },
            .key => |key| {
                if (key.state == .pressed and key.scancode == 1) loop.running = false;
                try retained_driver.pushEvent(.{ .key = .{
                    .scancode = key.scancode,
                    .state = if (key.state == .pressed) .pressed else .released,
                    .modifiers = .{
                        .control = key.modifiers.control,
                        .shift = key.modifiers.shift,
                        .alt = key.modifiers.alt,
                        .logo = key.modifiers.logo,
                    },
                } });
            },
            .keyboard_leave => {},
        }
    }
}

fn applyBrowserActions(
    model: *model_module.Model,
    retained_driver: *driver_module.DeclarativeDriver,
    loop: *LoopState,
) !void {
    const controller = controller_module.Controller{ .model = model };
    for (retained_driver.pendingActions()) |action| {
        const outcome = try controller.apply(action.value());
        if (outcome.model_changed) retained_driver.invalidate();
        if (outcome.quit) loop.running = false;
    }
    retained_driver.consumeActions();
}

fn drawBrowserFrame(
    window: *platform.Window,
    gpu: *gpu_module.Gpu,
    text: *snail.TextEngine,
    model: *model_module.Model,
    retained_driver: *driver_module.DeclarativeDriver,
    arena: *std.heap.ArenaAllocator,
    loop: *LoopState,
) !bool {
    _ = arena.reset(.retain_capacity);
    const viewport = view.Viewport{
        .width = @floatFromInt(loop.width),
        .height = @floatFromInt(loop.height),
    };
    const root = try view.build(arena.allocator(), model, viewport);
    const frame = try retained_driver.frame(
        root,
        .{ .x = 0, .y = 0, .w = viewport.width, .h = viewport.height },
        browserTheme(),
    );
    if (frame.delta.damage == .none) return false;

    const target = try gpu.beginFrame(text) orelse {
        retained_driver.invalidateAll();
        return false;
    };
    _ = try gpu.renderer.drawDelta(
        target,
        text,
        frame.delta,
        .rgb(18, 22, 28),
    );
    window.requestFrame();
    try gpu.presenter.endFrame();
    return true;
}

fn resize(
    gpu: *gpu_module.Gpu,
    retained_driver: *driver_module.DeclarativeDriver,
    loop: *LoopState,
    size: platform.Size,
) !void {
    if (size.width == 0 or size.height == 0) return;
    loop.width = size.width;
    loop.height = size.height;
    gpu.resize(size.width, size.height);
    retained_driver.invalidateAll();
}

fn browserTheme() ui.Theme {
    return .{
        .bg = .rgb(18, 22, 28),
        .fg = .rgb(224, 230, 237),
        .border = .rgb(61, 72, 86),
        .bg_hover = .rgb(38, 48, 60),
        .bg_active = .rgb(30, 37, 46),
        .font_size = 14,
        .padding = .symmetric(8, 6),
        .spacing = 4,
        .border_radius = 4,
        .border_width = 1,
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

test "the composition root keeps loop state separate from subsystem owners" {
    try std.testing.expect(!@hasField(LoopState, "renderer"));
    try std.testing.expect(!@hasField(LoopState, "entries"));
    try std.testing.expect(!@hasField(LoopState, "display"));
    _ = display;
}
