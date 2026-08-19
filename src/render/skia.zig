//! Skia rendering backend (GPU / Ganesh-on-Vulkan).
//!
//! This is the snail-free renderer: it consumes the backend-neutral
//! `goop_visual` operations and draws them with Skia's GPU backend. Skia is
//! C++, so the draw calls live in `skia/shim.cpp` behind a POD-only C ABI
//! compiled by the system g++ (matching libskia's libstdc++ ABI); this file is
//! the Zig wrapper.
//!
//! The backend reuses the snail-agnostic Vulkan layers: `goop_graphics_vulkan`
//! owns the instance/device that Ganesh binds to. Only the renderer differs
//! between this and `goop_render_vulkan`.

const std = @import("std");
const graphics = @import("goop_graphics_vulkan");
const visual = @import("goop_visual");
const vk = graphics.vk;

extern fn goop_skia_raster_selftest(width: c_int, height: c_int, out_rgba: [*]u8) c_int;

extern fn goop_skia_context_create(
    instance: ?*anyopaque,
    physical_device: ?*anyopaque,
    device: ?*anyopaque,
    queue: ?*anyopaque,
    graphics_queue_index: u32,
    get_instance_proc_addr: ?*anyopaque,
) ?*anyopaque;
extern fn goop_skia_context_destroy(ctx: ?*anyopaque) void;
extern fn goop_skia_flush(ctx: ?*anyopaque) void;

extern fn goop_skia_surface_create(ctx: ?*anyopaque, width: c_int, height: c_int) ?*anyopaque;
extern fn goop_skia_surface_destroy(surface: ?*anyopaque) void;
extern fn goop_skia_surface_canvas(surface: ?*anyopaque) ?*anyopaque;
extern fn goop_skia_surface_read_pixels(surface: ?*anyopaque, width: c_int, height: c_int, out_rgba: [*]u8) c_int;

extern fn goop_skia_clear(canvas: ?*anyopaque, rgba: u32) void;
extern fn goop_skia_clip_push(canvas: ?*anyopaque, x: f32, y: f32, w: f32, h: f32) void;
extern fn goop_skia_clip_pop(canvas: ?*anyopaque) void;
extern fn goop_skia_draw_surface(
    canvas: ?*anyopaque,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    fill: u32,
    border: u32,
    border_width: f32,
    corner_radius: f32,
) void;
extern fn goop_skia_draw_text(
    ctx: ?*anyopaque,
    canvas: ?*anyopaque,
    utf8: [*]const u8,
    len: usize,
    x: f32,
    baseline: f32,
    size: f32,
    rgba: u32,
) void;

/// goop packs colors as 0xRRGGBBAA for the C shim.
fn packColor(c: visual.Color) u32 {
    return (@as(u32, c.r) << 24) | (@as(u32, c.g) << 16) |
        (@as(u32, c.b) << 8) | @as(u32, c.a);
}

pub const Error = error{
    SkiaContextInitFailed,
    SkiaSurfaceCreateFailed,
    SkiaReadbackFailed,
    BufferTooSmall,
};

/// A Ganesh GrDirectContext bound to a goop Vulkan device.
pub const Context = struct {
    handle: *anyopaque,

    pub fn initVulkan(instance: graphics.Instance, device: graphics.Device) Error!Context {
        const get_instance_proc_addr: ?*anyopaque = @ptrCast(@constCast(&vk.vkGetInstanceProcAddr));
        const handle = goop_skia_context_create(
            @ptrCast(instance.handle),
            @ptrCast(device.physical),
            @ptrCast(device.handle),
            @ptrCast(device.graphics_queue),
            device.graphics_family,
            get_instance_proc_addr,
        ) orelse return error.SkiaContextInitFailed;
        return .{ .handle = handle };
    }

    pub fn deinit(self: *Context) void {
        goop_skia_context_destroy(self.handle);
        self.* = undefined;
    }

    /// Submit recorded GPU work and block until it completes (needed before a
    /// CPU readback; on-screen presentation flushes without the CPU sync).
    pub fn flush(self: *Context) void {
        goop_skia_flush(self.handle);
    }

    pub fn createSurface(self: *Context, width: u32, height: u32) Error!Surface {
        const handle = goop_skia_surface_create(self.handle, @intCast(width), @intCast(height)) orelse
            return error.SkiaSurfaceCreateFailed;
        return .{ .handle = handle, .ctx = self.handle, .width = width, .height = height };
    }
};

/// A GPU render target. Its `encoder` replays `goop_visual` operations.
pub const Surface = struct {
    handle: *anyopaque,
    ctx: *anyopaque,
    width: u32,
    height: u32,

    pub fn deinit(self: *Surface) void {
        goop_skia_surface_destroy(self.handle);
        self.* = undefined;
    }

    pub fn encoder(self: *Surface) Encoder {
        return .{ .ctx = self.ctx, .canvas = goop_skia_surface_canvas(self.handle).? };
    }

    pub fn readPixels(self: *Surface, out: []u8) Error!void {
        if (out.len < self.width * self.height * 4) return error.BufferTooSmall;
        if (goop_skia_surface_read_pixels(self.handle, @intCast(self.width), @intCast(self.height), out.ptr) != 0)
            return error.SkiaReadbackFailed;
    }
};

/// Implements the seven-method structural visual encoder contract by drawing
/// onto a Skia canvas. Usable with `visitResolved` and `chrome.emit`.
pub const Encoder = struct {
    ctx: *anyopaque,
    canvas: *anyopaque,

    pub fn clear(self: *Encoder, color: visual.Color) void {
        goop_skia_clear(self.canvas, packColor(color));
    }

    pub fn pushClip(self: *Encoder, rect: visual.Rect) !void {
        goop_skia_clip_push(self.canvas, rect.x, rect.y, rect.w, rect.h);
    }

    pub fn popClip(self: *Encoder) !void {
        goop_skia_clip_pop(self.canvas);
    }

    pub fn surface(self: *Encoder, value: visual.Surface) !void {
        goop_skia_draw_surface(
            self.canvas,
            value.bounds.x,
            value.bounds.y,
            value.bounds.w,
            value.bounds.h,
            packColor(value.color),
            packColor(value.border_color),
            value.border_width,
            value.corner_radius,
        );
    }

    pub fn text(self: *Encoder, value: visual.Text) !void {
        // Approximate baseline placement; the shim owns exact metrics later.
        const baseline = value.bounds.y + value.font_size;
        goop_skia_draw_text(
            self.ctx,
            self.canvas,
            value.text.ptr,
            value.text.len,
            value.bounds.x,
            baseline,
            value.font_size,
            packColor(value.color),
        );
    }

    // Icon/image/custom are not yet mapped onto Skia; a look that only uses
    // surfaces and text renders fully. These are the remaining vocabulary.
    pub fn icon(self: *Encoder, value: visual.Icon) !void {
        _ = self;
        _ = value;
    }
    pub fn image(self: *Encoder, value: visual.Image) !void {
        _ = self;
        _ = value;
    }
    pub fn custom(self: *Encoder, value: visual.Custom) !void {
        _ = self;
        _ = value;
    }
};

/// Render a fixed scene into `out_rgba` (`width*height*4` premultiplied RGBA8)
/// with Skia's CPU raster backend — proves the toolchain without a GPU.
pub fn rasterSelftest(width: u32, height: u32, out_rgba: []u8) !void {
    if (out_rgba.len < width * height * 4) return error.BufferTooSmall;
    if (goop_skia_raster_selftest(@intCast(width), @intCast(height), out_rgba.ptr) != 0)
        return error.SkiaRasterFailed;
}

test "skia raster self-test draws a non-blank scene" {
    const w: u32 = 64;
    const h: u32 = 48;
    var pixels: [w * h * 4]u8 = undefined;
    try rasterSelftest(w, h, &pixels);

    var saw_fill = false;
    var i: usize = 0;
    while (i < pixels.len) : (i += 4) {
        if (pixels[i + 2] > 150) {
            saw_fill = true;
            break;
        }
    }
    try std.testing.expect(saw_fill);
}

test "skia ganesh renders visual ops on a headless vulkan device" {
    // Skips cleanly where no Vulkan device is available.
    var instance = graphics.Instance.init("goop-skia-test", &.{}) catch return error.SkipZigTest;
    defer instance.deinit();
    var device = graphics.Device.init(std.testing.allocator, instance, null) catch return error.SkipZigTest;
    defer device.deinit();

    var ctx = Context.initVulkan(instance, device) catch return error.SkipZigTest;
    defer ctx.deinit();

    const w: u32 = 128;
    const h: u32 = 96;
    var surf = try ctx.createSurface(w, h);
    defer surf.deinit();

    var enc = surf.encoder();
    enc.clear(.{ .r = 20, .g = 22, .b = 28 });
    try enc.surface(.{
        .bounds = .{ .x = 16, .y = 16, .w = 96, .h = 64 },
        .color = .{ .r = 60, .g = 130, .b = 220 },
        .corner_radius = 10,
    });
    try enc.text(.{
        .bounds = .{ .x = 24, .y = 34, .w = 90, .h = 24 },
        .text = "goop",
        .color = .{ .r = 245, .g = 250, .b = 255 },
        .font_size = 22,
    });
    ctx.flush();

    var pixels: [w * h * 4]u8 = undefined;
    try surf.readPixels(&pixels);

    // The bright fill (blue 220) must appear over the dark clear (blue 28).
    var saw_fill = false;
    var i: usize = 0;
    while (i < pixels.len) : (i += 4) {
        if (pixels[i + 2] > 150) {
            saw_fill = true;
            break;
        }
    }
    try std.testing.expect(saw_fill);
}
