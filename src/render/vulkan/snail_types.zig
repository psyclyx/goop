//! Handle bundle expected by Snail's caller-owned reference renderer.

const graphics = @import("goop_graphics_vulkan");
pub const vk = graphics.vk;

pub const VulkanContext = struct {
    physical_device: vk.VkPhysicalDevice,
    device: vk.VkDevice,
    graphics_queue: vk.VkQueue,
    queue_family_index: u32,
    render_pass: vk.VkRenderPass,
    supports_dual_source_blend: bool = false,

    pub fn init(context: graphics.Context, render_pass: vk.VkRenderPass) VulkanContext {
        return .{
            .physical_device = context.physical_device,
            .device = context.device,
            .graphics_queue = context.graphics_queue,
            .queue_family_index = context.graphics_family,
            .render_pass = render_pass,
            .supports_dual_source_blend = context.supports_dual_source_blend,
        };
    }
};
