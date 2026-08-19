//! Vulkan subsystem composition shared by both demos.

const std = @import("std");
const platform = @import("goop_platform_wayland");
const graphics = @import("goop_graphics_vulkan");
const bridge = @import("goop_wayland_vulkan");
const present = @import("goop_present_vulkan");
const render = @import("goop_render_vulkan");
const snail = @import("goop_snail");

pub const Gpu = struct {
    allocator: std.mem.Allocator,
    instance: graphics.Instance,
    surface: bridge.Surface,
    device: graphics.Device,
    presenter: present.Presenter,
    renderer: render.Renderer,
    renderer_format: graphics.vk.VkFormat,

    pub fn init(
        allocator: std.mem.Allocator,
        window: *const platform.Window,
        text: *const snail.TextEngine,
        width: u32,
        height: u32,
        application_name: [*:0]const u8,
    ) !Gpu {
        const extensions = bridge.requiredInstanceExtensions();
        var instance = try graphics.Instance.init(application_name, &extensions);
        errdefer instance.deinit();

        const handles = window.wsiHandles();
        var surface = try bridge.Surface.init(instance, .{
            .display = @ptrCast(handles.display),
            .surface = @ptrCast(handles.surface),
        });
        errdefer surface.deinit();

        var device = try graphics.Device.init(allocator, instance, surface.handle);
        errdefer device.deinit();

        var presenter = try present.Presenter.init(
            allocator,
            &device,
            surface.handle,
            width,
            height,
        );
        errdefer presenter.deinit();

        var renderer = try render.Renderer.init(
            allocator,
            device.context(),
            presenter.renderPass(),
            text,
            .{
                .frame_slot_count = present.frame_slot_count,
                .attachment_format = presenter.format,
            },
        );
        errdefer renderer.deinit();

        return .{
            .allocator = allocator,
            .instance = instance,
            .surface = surface,
            .device = device,
            .presenter = presenter,
            .renderer = renderer,
            .renderer_format = presenter.format,
        };
    }

    pub fn deinit(self: *Gpu) void {
        self.device.waitIdle();
        self.renderer.deinit();
        self.presenter.deinit();
        self.device.deinit();
        self.surface.deinit();
        self.instance.deinit();
        self.* = undefined;
    }

    pub fn resize(self: *Gpu, width: u32, height: u32) void {
        self.presenter.setDesiredExtent(width, height);
    }

    /// Open an additional render target for a second window that SHARES this
    /// Gpu's Vulkan instance and device. Two independent `VkInstance`s in one
    /// process crash NVIDIA at swapchain teardown; a shared instance avoids it.
    /// A `VkSurfaceKHR` only needs the instance plus the window's WSI handles,
    /// so the second window may live on its own Wayland connection.
    pub fn openTarget(
        self: *Gpu,
        window: *const platform.Window,
        text: *const snail.TextEngine,
        width: u32,
        height: u32,
    ) !Target {
        return Target.init(self, window, text, width, height);
    }

    pub fn beginFrame(self: *Gpu, text: *const snail.TextEngine, clear: [4]f32) !?graphics.RenderTarget {
        const target = try self.presenter.beginFrame(clear) orelse return null;
        const attachment_format = self.presenter.format;
        if (attachment_format != self.renderer_format) {
            self.renderer.deinit();
            self.renderer = try render.Renderer.init(
                self.allocator,
                self.device.context(),
                self.presenter.renderPass(),
                text,
                .{
                    .frame_slot_count = present.frame_slot_count,
                    .attachment_format = attachment_format,
                },
            );
            self.renderer_format = attachment_format;
        }
        return target;
    }
};

/// A per-window render target (surface + swapchain + renderer) borrowing a
/// shared `Gpu`'s instance and device. It never owns the device or instance;
/// `deinit` tears down only this window's swapchain and renderer.
pub const Target = struct {
    gpu: *Gpu,
    surface: bridge.Surface,
    presenter: present.Presenter,
    renderer: render.Renderer,
    renderer_format: graphics.vk.VkFormat,

    fn init(
        gpu: *Gpu,
        window: *const platform.Window,
        text: *const snail.TextEngine,
        width: u32,
        height: u32,
    ) !Target {
        const handles = window.wsiHandles();
        var surface = try bridge.Surface.init(gpu.instance, .{
            .display = @ptrCast(handles.display),
            .surface = @ptrCast(handles.surface),
        });
        errdefer surface.deinit();

        var presenter = try present.Presenter.init(
            gpu.allocator,
            &gpu.device,
            surface.handle,
            width,
            height,
        );
        errdefer presenter.deinit();

        var renderer = try render.Renderer.init(
            gpu.allocator,
            gpu.device.context(),
            presenter.renderPass(),
            text,
            .{
                .frame_slot_count = present.frame_slot_count,
                .attachment_format = presenter.format,
            },
        );
        errdefer renderer.deinit();

        return .{
            .gpu = gpu,
            .surface = surface,
            .presenter = presenter,
            .renderer = renderer,
            .renderer_format = presenter.format,
        };
    }

    pub fn deinit(self: *Target) void {
        self.gpu.device.waitIdle();
        self.renderer.deinit();
        self.presenter.deinit();
        self.surface.deinit();
        self.* = undefined;
    }

    pub fn resize(self: *Target, width: u32, height: u32) void {
        self.presenter.setDesiredExtent(width, height);
    }

    pub fn beginFrame(self: *Target, text: *const snail.TextEngine, clear: [4]f32) !?graphics.RenderTarget {
        const target = try self.presenter.beginFrame(clear) orelse return null;
        const attachment_format = self.presenter.format;
        if (attachment_format != self.renderer_format) {
            self.renderer.deinit();
            self.renderer = try render.Renderer.init(
                self.gpu.allocator,
                self.gpu.device.context(),
                self.presenter.renderPass(),
                text,
                .{
                    .frame_slot_count = present.frame_slot_count,
                    .attachment_format = attachment_format,
                },
            );
            self.renderer_format = attachment_format;
        }
        return target;
    }
};
