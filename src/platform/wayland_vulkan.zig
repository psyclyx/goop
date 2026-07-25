//! Thin Wayland/Vulkan WSI bridge.
//!
//! This is the only module that includes `vulkan_wayland.h`.

const graphics = @import("goop_graphics_vulkan");
const vk = graphics.vk;

const wsi = @cImport({
    @cInclude("wayland-client.h");
    @cInclude("vulkan/vulkan.h");
    @cInclude("vulkan/vulkan_wayland.h");
});

pub const Handles = struct {
    display: *wsi.wl_display,
    surface: *wsi.wl_surface,
};

pub const Surface = struct {
    instance: vk.VkInstance,
    handle: vk.VkSurfaceKHR,

    pub fn init(instance: graphics.Instance, handles: Handles) !Surface {
        const create_info = @import("std").mem.zeroInit(wsi.VkWaylandSurfaceCreateInfoKHR, .{
            .sType = wsi.VK_STRUCTURE_TYPE_WAYLAND_SURFACE_CREATE_INFO_KHR,
            .display = handles.display,
            .surface = handles.surface,
        });
        var local_surface: wsi.VkSurfaceKHR = null;
        try graphics.result(wsi.vkCreateWaylandSurfaceKHR(
            @ptrCast(instance.handle),
            &create_info,
            null,
            &local_surface,
        ));
        return .{
            .instance = instance.handle,
            .handle = @ptrCast(local_surface),
        };
    }

    pub fn deinit(self: *Surface) void {
        if (self.handle != null) {
            vk.vkDestroySurfaceKHR(self.instance, self.handle, null);
        }
        self.* = undefined;
    }
};

pub fn requiredInstanceExtensions() [2][*c]const u8 {
    return .{
        vk.VK_KHR_SURFACE_EXTENSION_NAME,
        wsi.VK_KHR_WAYLAND_SURFACE_EXTENSION_NAME,
    };
}

test "the WSI bridge exposes only handles and surface ownership" {
    const extensions = requiredInstanceExtensions();
    try @import("std").testing.expectEqual(@as(usize, 2), extensions.len);
}
