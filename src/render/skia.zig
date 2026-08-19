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
extern fn goop_skia_surface_wrap_vk_image(ctx: ?*anyopaque, image: ?*anyopaque, format: u32, width: c_int, height: c_int, usage: u32) ?*anyopaque;
extern fn goop_skia_flush_present(ctx: ?*anyopaque, surface: ?*anyopaque, wait_sem: ?*anyopaque, signal_sem: ?*anyopaque, queue_family: u32) c_int;
extern fn goop_skia_measure_text(ctx: ?*anyopaque, utf8: [*]const u8, len: usize, size: f32, out: [*]f32) void;
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
    SkiaPresentFailed,
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

    /// Wrap a caller-owned `VkImage` (e.g. an acquired swapchain image) as a
    /// render target. GPU backend only. This is the primitive on-screen
    /// presentation is built on: render into the compositor's image, then the
    /// caller presents it. `usage` must match the image's `VkImageUsageFlags`.
    pub fn wrapVkImage(self: *Context, image: vk.VkImage, format: u32, width: u32, height: u32, usage: u32) Error!Surface {
        const handle = goop_skia_surface_wrap_vk_image(self.handle, @ptrCast(image), format, @intCast(width), @intCast(height), usage) orelse
            return error.SkiaSurfaceCreateFailed;
        return .{ .handle = handle, .ctx = self.handle, .width = width, .height = height };
    }

    /// Flush a wrapped swapchain surface for presentation: wait on `wait_sem`
    /// (the acquire semaphore, may be null), signal `signal_sem` when Skia's
    /// work completes, and transition the image to `PRESENT_SRC_KHR`. The caller
    /// then presents the image waiting on `signal_sem`.
    pub fn flushPresent(self: *Context, surf: *Surface, wait_sem: vk.VkSemaphore, signal_sem: vk.VkSemaphore, queue_family: u32) Error!void {
        if (goop_skia_flush_present(self.handle, surf.handle, @ptrCast(wait_sem), @ptrCast(signal_sem), queue_family) != 0)
            return error.SkiaPresentFailed;
    }

    /// Measure text with the context's own font (Skia's `SkFont`). Lets a
    /// Skia-rendered UI lay out text without linking a separate text engine.
    pub fn measureText(self: *Context, bytes: []const u8, size: f32) TextMetrics {
        var out = [4]f32{ 0, 0, 0, 0 };
        goop_skia_measure_text(self.handle, bytes.ptr, bytes.len, size, &out);
        return .{ .width = out[0], .height = out[1], .ascent = out[2], .descent = out[3] };
    }
};

/// Result of `Context.measureText`. `ascent`/`descent` are positive distances
/// from the baseline.
pub const TextMetrics = struct {
    width: f32,
    height: f32,
    ascent: f32,
    descent: f32,
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

/// An on-screen Skia target: owns a swapchain over a `VkSurfaceKHR`, wraps each
/// swapchain image as a Skia render target once, and drives acquire → render →
/// present. GPU (Ganesh) backend only. This is the on-screen counterpart to
/// `Context.createSurface`; the snail renderer's `goop_present_vulkan` is left
/// untouched.
///
/// It synchronises with a `vkDeviceWaitIdle` after each present — correct and
/// simple rather than pipelined; a consumer wanting frames in flight can build
/// its own loop on `wrapVkImage`/`flushPresent`.
pub const WindowTarget = struct {
    // The stable C++ GrDirectContext handle (not a *Context): survives moving
    // the owning struct, so a caller can store the Context and WindowTarget
    // together by value.
    ctx_handle: *anyopaque,
    allocator: std.mem.Allocator,
    device_handle: vk.VkDevice,
    physical: vk.VkPhysicalDevice,
    graphics_queue: vk.VkQueue,
    present_queue: vk.VkQueue,
    graphics_family: u32,
    present_family: u32,
    surface: vk.VkSurfaceKHR,

    desired_width: u32 = 0,
    desired_height: u32 = 0,
    swapchain: vk.VkSwapchainKHR = null,
    images: []vk.VkImage = &.{},
    surfaces: []?*anyopaque = &.{},
    format: vk.VkFormat = vk.VK_FORMAT_UNDEFINED,
    extent: vk.VkExtent2D = .{ .width = 0, .height = 0 },
    image_available: vk.VkSemaphore = null,
    render_finished: vk.VkSemaphore = null,

    // Granular so a caller can tell which Vulkan step failed rather than one
    // opaque "init failed".
    pub const InitError = Error || error{
        NotGpuBackend,
        SemaphoreCreateFailed,
        SurfaceCapabilitiesQueryFailed,
        SurfaceFormatQueryFailed,
        SwapchainCreateFailed,
        SwapchainImageQueryFailed,
        SwapchainImageWrapFailed,
        OutOfMemory,
    };

    pub const Frame = struct { surface: Surface, image_index: u32 };

    pub fn init(
        ctx: *Context,
        device: graphics.Device,
        surface: vk.VkSurfaceKHR,
        width: u32,
        height: u32,
        allocator: std.mem.Allocator,
    ) InitError!WindowTarget {
        if (ctx.backend != .vulkan) return error.NotGpuBackend;
        var self = WindowTarget{
            .ctx_handle = ctx.handle,
            .allocator = allocator,
            .device_handle = device.handle,
            .physical = device.physical,
            .graphics_queue = device.graphics_queue,
            .present_queue = device.present_queue,
            .graphics_family = device.graphics_family,
            .present_family = device.present_family,
            .surface = surface,
            .desired_width = width,
            .desired_height = height,
        };
        const sem_info = std.mem.zeroInit(vk.VkSemaphoreCreateInfo, .{
            .sType = @as(vk.VkStructureType, @intCast(vk.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO)),
        });
        if (vk.vkCreateSemaphore(self.device_handle, &sem_info, null, &self.image_available) != vk.VK_SUCCESS)
            return error.SemaphoreCreateFailed;
        if (vk.vkCreateSemaphore(self.device_handle, &sem_info, null, &self.render_finished) != vk.VK_SUCCESS)
            return error.SemaphoreCreateFailed;
        // The Wayland surface may not have a usable extent yet; build the
        // swapchain lazily on the first acquire once a real size is known.
        try self.ensureSwapchain();
        return self;
    }

    pub fn ready(self: *const WindowTarget) bool {
        return self.swapchain != null;
    }

    pub fn deinit(self: *WindowTarget) void {
        _ = vk.vkDeviceWaitIdle(self.device_handle);
        self.destroySwapchain();
        if (self.image_available != null) vk.vkDestroySemaphore(self.device_handle, self.image_available, null);
        if (self.render_finished != null) vk.vkDestroySemaphore(self.device_handle, self.render_finished, null);
        self.* = undefined;
    }

    /// Note a new desired size (e.g. after a resize). The swapchain is rebuilt
    /// lazily on the next acquire.
    pub fn resize(self: *WindowTarget, width: u32, height: u32) InitError!void {
        self.desired_width = width;
        self.desired_height = height;
        _ = vk.vkDeviceWaitIdle(self.device_handle);
        self.destroySwapchain();
        try self.ensureSwapchain();
    }

    /// Acquire the next image and return a render target for it. `null` means no
    /// frame is available yet (surface not sized, or out of date — the caller
    /// keeps looping / resizes).
    pub fn acquire(self: *WindowTarget) InitError!?Frame {
        if (self.swapchain == null) {
            try self.ensureSwapchain();
            if (self.swapchain == null) return null;
        }
        var index: u32 = 0;
        const acquired = vk.vkAcquireNextImageKHR(
            self.device_handle,
            self.swapchain,
            std.math.maxInt(u64),
            self.image_available,
            null,
            &index,
        );
        if (acquired == vk.VK_ERROR_OUT_OF_DATE_KHR or acquired == vk.VK_SUBOPTIMAL_KHR) {
            self.destroySwapchain();
            return null;
        }
        if (acquired != vk.VK_SUCCESS) return error.SwapchainCreateFailed;
        return .{
            .surface = .{
                .handle = self.surfaces[index].?,
                .ctx = self.ctx_handle,
                .width = self.extent.width,
                .height = self.extent.height,
            },
            .image_index = index,
        };
    }

    /// Present a rendered frame. `frame.surface` must have been drawn into.
    pub fn present(self: *WindowTarget, frame: Frame) InitError!void {
        if (goop_skia_flush_present(self.ctx_handle, frame.surface.handle, @ptrCast(self.image_available), @ptrCast(self.render_finished), self.present_family) != 0)
            return error.SkiaPresentFailed;

        var image_index = frame.image_index;
        const present_info = std.mem.zeroInit(vk.VkPresentInfoKHR, .{
            .sType = @as(vk.VkStructureType, @intCast(vk.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR)),
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &self.render_finished,
            .swapchainCount = 1,
            .pSwapchains = &self.swapchain,
            .pImageIndices = &image_index,
        });
        _ = vk.vkQueuePresentKHR(self.present_queue, &present_info);
        _ = vk.vkDeviceWaitIdle(self.device_handle);
    }

    /// Build the swapchain if it is missing and the surface has a usable size.
    /// A zero extent (surface not configured yet) is not an error — it simply
    /// leaves the swapchain unbuilt for a later acquire.
    fn ensureSwapchain(self: *WindowTarget) InitError!void {
        if (self.swapchain != null) return;

        var caps: vk.VkSurfaceCapabilitiesKHR = undefined;
        if (vk.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(self.physical, self.surface, &caps) != vk.VK_SUCCESS)
            return error.SurfaceCapabilitiesQueryFailed;

        const surface_format = self.chooseFormat() catch return error.SurfaceFormatQueryFailed;
        const extent = chooseSwapExtent(caps, self.desired_width, self.desired_height);
        if (extent.width == 0 or extent.height == 0) return; // defer until sized

        var image_count = caps.minImageCount + 1;
        if (caps.maxImageCount > 0) image_count = @min(image_count, caps.maxImageCount);

        const families = [_]u32{ self.graphics_family, self.present_family };
        const separate = self.graphics_family != self.present_family;
        const usage: vk.VkImageUsageFlags = vk.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
        const create_info = std.mem.zeroInit(vk.VkSwapchainCreateInfoKHR, .{
            .sType = @as(vk.VkStructureType, @intCast(vk.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR)),
            .surface = self.surface,
            .minImageCount = image_count,
            .imageFormat = surface_format.format,
            .imageColorSpace = surface_format.colorSpace,
            .imageExtent = extent,
            .imageArrayLayers = 1,
            .imageUsage = usage,
            .imageSharingMode = @as(vk.VkSharingMode, @intCast(if (separate) vk.VK_SHARING_MODE_CONCURRENT else vk.VK_SHARING_MODE_EXCLUSIVE)),
            .queueFamilyIndexCount = if (separate) @as(u32, 2) else 0,
            .pQueueFamilyIndices = if (separate) families[0..].ptr else null,
            .preTransform = caps.currentTransform,
            .compositeAlpha = @as(vk.VkCompositeAlphaFlagBitsKHR, @intCast(vk.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR)),
            .presentMode = @as(vk.VkPresentModeKHR, @intCast(vk.VK_PRESENT_MODE_FIFO_KHR)),
            .clipped = @as(vk.VkBool32, @intCast(vk.VK_TRUE)),
        });
        if (vk.vkCreateSwapchainKHR(self.device_handle, &create_info, null, &self.swapchain) != vk.VK_SUCCESS) {
            self.swapchain = null;
            return error.SwapchainCreateFailed;
        }

        var count: u32 = 0;
        if (vk.vkGetSwapchainImagesKHR(self.device_handle, self.swapchain, &count, null) != vk.VK_SUCCESS)
            return error.SwapchainImageQueryFailed;
        self.images = try self.allocator.alloc(vk.VkImage, count);
        if (vk.vkGetSwapchainImagesKHR(self.device_handle, self.swapchain, &count, self.images.ptr) != vk.VK_SUCCESS)
            return error.SwapchainImageQueryFailed;

        self.format = surface_format.format;
        self.extent = extent;
        self.surfaces = try self.allocator.alloc(?*anyopaque, count);
        @memset(self.surfaces, null);
        for (self.images, 0..) |image, i| {
            const wrapped = goop_skia_surface_wrap_vk_image(
                self.ctx_handle,
                @ptrCast(image),
                @intCast(self.format),
                @intCast(extent.width),
                @intCast(extent.height),
                @intCast(usage),
            ) orelse return error.SwapchainImageWrapFailed;
            self.surfaces[i] = wrapped;
        }
    }

    fn destroySwapchain(self: *WindowTarget) void {
        for (self.surfaces) |s| {
            if (s) |handle| goop_skia_surface_destroy(handle);
        }
        if (self.surfaces.len > 0) self.allocator.free(self.surfaces);
        if (self.images.len > 0) self.allocator.free(self.images);
        if (self.swapchain != null) vk.vkDestroySwapchainKHR(self.device_handle, self.swapchain, null);
        self.surfaces = &.{};
        self.images = &.{};
        self.swapchain = null;
        self.extent = .{ .width = 0, .height = 0 };
    }

    fn chooseFormat(self: *WindowTarget) !vk.VkSurfaceFormatKHR {
        var count: u32 = 0;
        if (vk.vkGetPhysicalDeviceSurfaceFormatsKHR(self.physical, self.surface, &count, null) != vk.VK_SUCCESS or count == 0)
            return error.SwapchainInitFailed;
        const formats = try self.allocator.alloc(vk.VkSurfaceFormatKHR, count);
        defer self.allocator.free(formats);
        _ = vk.vkGetPhysicalDeviceSurfaceFormatsKHR(self.physical, self.surface, &count, formats.ptr);
        for (formats[0..count]) |f| {
            if (f.format == vk.VK_FORMAT_B8G8R8A8_UNORM) return f;
        }
        return formats[0];
    }
};

fn chooseSwapExtent(caps: vk.VkSurfaceCapabilitiesKHR, width: u32, height: u32) vk.VkExtent2D {
    if (caps.currentExtent.width != std.math.maxInt(u32)) return caps.currentExtent;
    return .{
        .width = std.math.clamp(width, caps.minImageExtent.width, caps.maxImageExtent.width),
        .height = std.math.clamp(height, caps.minImageExtent.height, caps.maxImageExtent.height),
    };
}

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

fn testMemoryTypeIndex(physical: vk.VkPhysicalDevice, type_bits: u32, properties: u32) !u32 {
    var mem_props: vk.VkPhysicalDeviceMemoryProperties = undefined;
    vk.vkGetPhysicalDeviceMemoryProperties(physical, &mem_props);
    var i: u32 = 0;
    while (i < mem_props.memoryTypeCount) : (i += 1) {
        const suitable = (type_bits & (@as(u32, 1) << @intCast(i))) != 0;
        const has_props = (mem_props.memoryTypes[i].propertyFlags & properties) == properties;
        if (suitable and has_props) return i;
    }
    return error.NoSuitableMemoryType;
}

// Verifies the on-screen rendering primitive offscreen: wrap a caller-owned
// VkImage (standing in for an acquired swapchain image), render into it on the
// GPU, and read it back. The compositor acquire/present loop around this is
// display-gated and not exercised here.
test "skia wraps an external vulkan image as a render target" {
    var instance = graphics.Instance.init("goop-skia-wrap", &.{}) catch return error.SkipZigTest;
    defer instance.deinit();
    var device = graphics.Device.init(std.testing.allocator, instance, null) catch return error.SkipZigTest;
    defer device.deinit();
    if (deviceClass(device.physical) != .real_gpu) return error.SkipZigTest;

    var ctx = Context.initVulkan(instance, device) catch return error.SkipZigTest;
    defer ctx.deinit();

    const w: u32 = 96;
    const h: u32 = 64;
    // BGRA is what real swapchains use — exercises the format→SkColorType map.
    const format = vk.VK_FORMAT_B8G8R8A8_UNORM;
    const usage: u32 = @intCast(vk.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT |
        vk.VK_IMAGE_USAGE_TRANSFER_SRC_BIT | vk.VK_IMAGE_USAGE_TRANSFER_DST_BIT |
        vk.VK_IMAGE_USAGE_SAMPLED_BIT);

    var image: vk.VkImage = null;
    const image_info = std.mem.zeroInit(vk.VkImageCreateInfo, .{
        .sType = @as(vk.VkStructureType, @intCast(vk.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO)),
        .imageType = @as(vk.VkImageType, @intCast(vk.VK_IMAGE_TYPE_2D)),
        .format = format,
        .extent = .{ .width = w, .height = h, .depth = 1 },
        .mipLevels = 1,
        .arrayLayers = 1,
        .samples = @as(vk.VkSampleCountFlagBits, @intCast(vk.VK_SAMPLE_COUNT_1_BIT)),
        .tiling = @as(vk.VkImageTiling, @intCast(vk.VK_IMAGE_TILING_OPTIMAL)),
        .usage = usage,
        .sharingMode = @as(vk.VkSharingMode, @intCast(vk.VK_SHARING_MODE_EXCLUSIVE)),
        .initialLayout = @as(vk.VkImageLayout, @intCast(vk.VK_IMAGE_LAYOUT_UNDEFINED)),
    });
    if (vk.vkCreateImage(device.handle, &image_info, null, &image) != vk.VK_SUCCESS) return error.SkipZigTest;
    defer vk.vkDestroyImage(device.handle, image, null);

    var reqs: vk.VkMemoryRequirements = undefined;
    vk.vkGetImageMemoryRequirements(device.handle, image, &reqs);
    var memory: vk.VkDeviceMemory = null;
    const mem_alloc = std.mem.zeroInit(vk.VkMemoryAllocateInfo, .{
        .sType = @as(vk.VkStructureType, @intCast(vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO)),
        .allocationSize = reqs.size,
        .memoryTypeIndex = testMemoryTypeIndex(device.physical, reqs.memoryTypeBits, vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) catch return error.SkipZigTest,
    });
    if (vk.vkAllocateMemory(device.handle, &mem_alloc, null, &memory) != vk.VK_SUCCESS) return error.SkipZigTest;
    defer vk.vkFreeMemory(device.handle, memory, null);
    if (vk.vkBindImageMemory(device.handle, image, memory, 0) != vk.VK_SUCCESS) return error.SkipZigTest;

    var surf = try ctx.wrapVkImage(image, @intCast(format), w, h, usage);
    defer surf.deinit();

    var enc = surf.encoder();
    enc.clear(.{ .r = 12, .g = 14, .b = 20 });
    try enc.surface(.{
        .bounds = .{ .x = 12, .y = 12, .w = 72, .h = 40 },
        .color = .{ .r = 70, .g = 150, .b = 235 },
        .corner_radius = 8,
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
