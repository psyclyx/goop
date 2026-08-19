//! Minimal on-screen Skia (GPU/Ganesh) window.
//!
//! Composes a Wayland window, a Vulkan surface/device, and the Skia backend's
//! `WindowTarget`, then loops acquire → draw → present. It draws a static scene
//! (a rounded panel and a line of text) through the same seven-method encoder
//! the rest of goop uses.
//!
//! Run on a machine with a Wayland compositor and a real GPU:
//!   zig build skia-window -Dskia
//! Close the window to exit. This path needs a display; it is not exercised by
//! the headless test suite.

const std = @import("std");
const wayland = @import("goop_platform_wayland");
const bridge = @import("goop_wayland_vulkan");
const graphics = @import("goop_graphics_vulkan");
const skia = @import("goop_render_skia");
const visual = @import("goop_visual");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var window = try wayland.Window.init(allocator, .{
        .width = 960,
        .height = 600,
        .title = "goop · skia",
    });
    defer window.deinit();

    const extensions = bridge.requiredInstanceExtensions();
    var instance = try graphics.Instance.init("goop-skia-window", extensions[0..]);
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

    var size = window.size();
    var target = try skia.WindowTarget.init(&ctx, device, surface.handle, size.width, size.height, allocator);
    defer target.deinit();

    var running = true;
    while (running) {
        try window.dispatchTimeout(16);
        while (window.pollEvent()) |event| switch (event) {
            .close => running = false,
            .configured, .resized => |new_size| {
                if (new_size.width != size.width or new_size.height != size.height) {
                    size = new_size;
                    try target.resize(size.width, size.height);
                }
            },
            else => {},
        };
        if (!running) break;

        const frame = (try target.acquire()) orelse {
            try target.resize(size.width, size.height);
            continue;
        };
        var f = frame;
        drawScene(&f.surface, size.width, size.height);
        try target.present(f);
    }
}

fn drawScene(surf: *skia.Surface, width: u32, height: u32) void {
    const w: f32 = @floatFromInt(width);
    const h: f32 = @floatFromInt(height);
    var enc = surf.encoder();
    enc.clear(.{ .r = 24, .g = 26, .b = 32 });
    enc.surface(.{
        .bounds = .{ .x = 0.1 * w, .y = 0.15 * h, .w = 0.8 * w, .h = 0.7 * h },
        .color = .{ .r = 46, .g = 52, .b = 66 },
        .border_color = .{ .r = 90, .g = 150, .b = 235 },
        .border_width = 2,
        .corner_radius = 14,
    }) catch {};
    enc.text(.{
        .bounds = .{ .x = 0.14 * w, .y = 0.22 * h, .w = 0.6 * w, .h = 40 },
        .text = "goop · skia gpu",
        .color = .{ .r = 235, .g = 240, .b = 250 },
        .font_size = 28,
    }) catch {};
}
