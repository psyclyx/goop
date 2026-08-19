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
extern fn goop_skia_context_create_cpu() ?*anyopaque;
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

/// Which Skia renderer to use.
pub const Backend = enum { vulkan, cpu };

/// How capable the Vulkan physical device is. A software device (e.g. lavapipe,
/// which reports `VK_PHYSICAL_DEVICE_TYPE_CPU`) is treated as no better than
/// Skia's own raster path.
pub const DeviceClass = enum { real_gpu, software, none };

/// Pure backend policy: an explicit `GOOP_SKIA_BACKEND` value wins; otherwise
/// use the GPU only for a real GPU, preferring CPU raster over software Vulkan.
pub fn chooseBackend(override: ?[]const u8, class: DeviceClass) Backend {
    if (override) |value| {
        if (std.ascii.eqlIgnoreCase(value, "vulkan")) return .vulkan;
        if (std.ascii.eqlIgnoreCase(value, "cpu")) return .cpu;
        // Unrecognized value falls through to auto-detection.
    }
    return switch (class) {
        .real_gpu => .vulkan,
        .software, .none => .cpu,
    };
}

/// Classify a physical device by its reported type.
pub fn deviceClass(physical: vk.VkPhysicalDevice) DeviceClass {
    var props: vk.VkPhysicalDeviceProperties = undefined;
    vk.vkGetPhysicalDeviceProperties(physical, &props);
    return switch (props.deviceType) {
        vk.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU,
        vk.VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU,
        vk.VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU,
        => .real_gpu,
        else => .software, // CPU (lavapipe) or OTHER
    };
}

fn envBackend() ?[]const u8 {
    const raw = std.c.getenv("GOOP_SKIA_BACKEND") orelse return null;
    return std.mem.span(raw);
}

/// Resolve the backend for a device (or `null` when no Vulkan device exists),
/// reading `GOOP_SKIA_BACKEND` from the environment.
pub fn selectBackend(physical: ?vk.VkPhysicalDevice) Backend {
    const class: DeviceClass = if (physical) |p| deviceClass(p) else .none;
    return chooseBackend(envBackend(), class);
}

/// A Ganesh GrDirectContext bound to a goop Vulkan device.
pub const Context = struct {
    handle: *anyopaque,
    backend: Backend,

    /// GPU (Ganesh) context bound to a goop Vulkan device.
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
        return .{ .handle = handle, .backend = .vulkan };
    }

    /// CPU raster context. Needs no Vulkan device.
    pub fn initCpu() Error!Context {
        const handle = goop_skia_context_create_cpu() orelse return error.SkiaContextInitFailed;
        return .{ .handle = handle, .backend = .cpu };
    }

    /// Pick the backend per `GOOP_SKIA_BACKEND` / device class, then create it.
    /// The Vulkan device is used only if the GPU backend is selected.
    pub fn initAuto(instance: graphics.Instance, device: graphics.Device) Error!Context {
        return switch (selectBackend(device.physical)) {
            .vulkan => initVulkan(instance, device),
            .cpu => initCpu(),
        };
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

test "backend policy honors env override then device class" {
    try std.testing.expectEqual(Backend.vulkan, chooseBackend("vulkan", .software));
    try std.testing.expectEqual(Backend.cpu, chooseBackend("cpu", .real_gpu));
    try std.testing.expectEqual(Backend.vulkan, chooseBackend(null, .real_gpu));
    try std.testing.expectEqual(Backend.cpu, chooseBackend(null, .software));
    try std.testing.expectEqual(Backend.cpu, chooseBackend(null, .none));
    // Unrecognized override falls through to auto-detection.
    try std.testing.expectEqual(Backend.vulkan, chooseBackend("bogus", .real_gpu));
    try std.testing.expectEqual(Backend.cpu, chooseBackend("bogus", .software));
}

test "skia cpu raster renders visual ops without a device" {
    var ctx = try Context.initCpu();
    defer ctx.deinit();
    try std.testing.expectEqual(Backend.cpu, ctx.backend);

    const w: u32 = 96;
    const h: u32 = 64;
    var surf = try ctx.createSurface(w, h);
    defer surf.deinit();

    var enc = surf.encoder();
    enc.clear(.{ .r = 10, .g = 12, .b = 16 });
    try enc.surface(.{
        .bounds = .{ .x = 8, .y = 8, .w = 80, .h = 48 },
        .color = .{ .r = 60, .g = 140, .b = 230 },
        .corner_radius = 6,
    });
    try enc.text(.{
        .bounds = .{ .x = 12, .y = 16, .w = 70, .h = 20 },
        .text = "cpu",
        .color = .{ .r = 255, .g = 255, .b = 255 },
        .font_size = 18,
    });
    ctx.flush();

    var pixels: [w * h * 4]u8 = undefined;
    try surf.readPixels(&pixels);
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

test "skia auto backend selects and renders on the available device" {
    var instance = graphics.Instance.init("goop-skia-auto", &.{}) catch return error.SkipZigTest;
    defer instance.deinit();
    var device = graphics.Device.init(std.testing.allocator, instance, null) catch return error.SkipZigTest;
    defer device.deinit();

    const class = deviceClass(device.physical);
    var ctx = Context.initAuto(instance, device) catch return error.SkipZigTest;
    defer ctx.deinit();
    std.debug.print("skia auto: device class={s} backend={s}\n", .{ @tagName(class), @tagName(ctx.backend) });

    var surf = try ctx.createSurface(64, 48);
    defer surf.deinit();
    var enc = surf.encoder();
    enc.clear(.{ .r = 10, .g = 12, .b = 16 });
    try enc.surface(.{
        .bounds = .{ .x = 8, .y = 8, .w = 48, .h = 32 },
        .color = .{ .r = 60, .g = 140, .b = 230 },
    });
    ctx.flush();

    var pixels: [64 * 48 * 4]u8 = undefined;
    try surf.readPixels(&pixels);
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
