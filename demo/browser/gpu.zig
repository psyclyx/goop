//! Cohesive Vulkan subsystem ownership for the browser composition root.
//!
//! Window-system ownership remains in `goop_platform_wayland`; only its raw
//! WSI handles cross into the bridge during initialization.

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

    pub fn init(
        allocator: std.mem.Allocator,
        window: *const platform.Window,
        text: *const snail.TextEngine,
        width: u32,
        height: u32,
    ) !Gpu {
        const extensions = bridge.requiredInstanceExtensions();
        var instance = try graphics.Instance.init("goop-file-browser", &extensions);
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
            .{},
        );
        errdefer renderer.deinit();

        return .{
            .allocator = allocator,
            .instance = instance,
            .surface = surface,
            .device = device,
            .presenter = presenter,
            .renderer = renderer,
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

    /// Returns null while a swapchain is being recreated. The caller must
    /// preserve/repromote its damage for the next frame.
    pub fn beginFrame(self: *Gpu, text: *const snail.TextEngine) !?present.FrameTarget {
        const target = try self.presenter.beginFrame(.{ 0, 0, 0, 1 });
        if (target != null) return target;
        if (self.renderer.context.render_pass != self.presenter.renderPass() and
            self.presenter.renderPass() != null)
        {
            self.renderer.deinit();
            self.renderer = try render.Renderer.init(
                self.allocator,
                self.device.context(),
                self.presenter.renderPass(),
                text,
                .{},
            );
        }
        return null;
    }
};
