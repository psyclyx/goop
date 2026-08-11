//! Swapchain and frame lifecycle.
//!
//! The presenter owns no UI or renderer state. A renderer receives a
//! `graphics.RenderTarget` and records commands inside the active render pass.

const std = @import("std");
const graphics = @import("goop_graphics_vulkan");
pub const vk = graphics.vk;

// Each frame renders straight into its acquired swapchain image (distinct
// resources) with per-frame command buffers and sync objects, so frames in
// flight never share a mutable target — no cross-frame hazard. Two lets the CPU
// record the next frame while the GPU finishes the previous one.
pub const frame_slot_count: u32 = 2;

const DeviceView = struct {
    physical: vk.VkPhysicalDevice,
    handle: vk.VkDevice,
    graphics_queue: vk.VkQueue,
    present_queue: vk.VkQueue,
    graphics_family: u32,
    present_family: u32,

    fn init(device: *const graphics.Device) DeviceView {
        return .{
            .physical = device.physical,
            .handle = device.handle,
            .graphics_queue = device.graphics_queue,
            .present_queue = device.present_queue,
            .graphics_family = device.graphics_family,
            .present_family = device.present_family,
        };
    }

    fn waitIdle(self: DeviceView) void {
        if (self.handle != null) _ = vk.vkDeviceWaitIdle(self.handle);
    }
};

pub const Presenter = struct {
    allocator: std.mem.Allocator,
    device: DeviceView,
    surface: vk.VkSurfaceKHR,
    desired_width: u32,
    desired_height: u32,

    swapchain: vk.VkSwapchainKHR = null,
    images: []vk.VkImage = &.{},
    views: []vk.VkImageView = &.{},
    format: vk.VkFormat = vk.VK_FORMAT_UNDEFINED,
    color_space: vk.VkColorSpaceKHR = vk.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR,
    extent: vk.VkExtent2D = .{ .width = 0, .height = 0 },
    render_pass: vk.VkRenderPass = null,
    framebuffers: []vk.VkFramebuffer = &.{},
    clear_value: vk.VkClearValue = .{ .color = .{ .float32 = .{ 0, 0, 0, 1 } } },

    command_pool: vk.VkCommandPool = null,
    command_buffers: [frame_slot_count]vk.VkCommandBuffer = .{null} ** frame_slot_count,
    image_available: [frame_slot_count]vk.VkSemaphore = .{null} ** frame_slot_count,
    render_finished: [frame_slot_count]vk.VkSemaphore = .{null} ** frame_slot_count,
    in_flight: [frame_slot_count]vk.VkFence = .{null} ** frame_slot_count,

    current_frame: u32 = 0,
    current_image: u32 = 0,
    active_frame: bool = false,
    recreate_pending: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        device: *graphics.Device,
        surface: vk.VkSurfaceKHR,
        width: u32,
        height: u32,
    ) !Presenter {
        var self = Presenter{
            .allocator = allocator,
            .device = .init(device),
            .surface = surface,
            .desired_width = width,
            .desired_height = height,
        };
        errdefer self.deinit();

        try self.createCommandPool();
        try self.createSyncObjects();
        try self.createSwapchain();
        return self;
    }

    pub fn deinit(self: *Presenter) void {
        self.device.waitIdle();
        self.destroySwapchain();
        for (0..frame_slot_count) |index| {
            if (self.render_finished[index] != null) {
                vk.vkDestroySemaphore(self.device.handle, self.render_finished[index], null);
            }
            if (self.image_available[index] != null) {
                vk.vkDestroySemaphore(self.device.handle, self.image_available[index], null);
            }
            if (self.in_flight[index] != null) {
                vk.vkDestroyFence(self.device.handle, self.in_flight[index], null);
            }
        }
        if (self.command_pool != null) {
            vk.vkDestroyCommandPool(self.device.handle, self.command_pool, null);
        }
        self.* = undefined;
    }

    pub fn setDesiredExtent(self: *Presenter, width: u32, height: u32) void {
        if (self.desired_width == width and self.desired_height == height) return;
        self.desired_width = width;
        self.desired_height = height;
        self.recreate_pending = true;
    }

    pub fn framebufferExtent(self: *const Presenter) vk.VkExtent2D {
        return self.extent;
    }

    pub fn renderPass(self: *const Presenter) vk.VkRenderPass {
        return self.render_pass;
    }

    /// Acquire an image and begin its render pass. `null` means the surface is
    /// temporarily unrenderable (usually zero-sized or just recreated).
    pub fn beginFrame(self: *Presenter, clear: [4]f32) !?graphics.RenderTarget {
        std.debug.assert(!self.active_frame);
        if (self.desired_width == 0 or self.desired_height == 0) return null;
        if (self.recreate_pending) {
            try self.recreate();
            return null;
        }

        const frame = self.current_frame;
        try graphics.result(vk.vkWaitForFences(
            self.device.handle,
            1,
            &self.in_flight[frame],
            vk.VK_TRUE,
            std.math.maxInt(u64),
        ));

        const acquired = vk.vkAcquireNextImageKHR(
            self.device.handle,
            self.swapchain,
            std.math.maxInt(u64),
            self.image_available[frame],
            null,
            &self.current_image,
        );
        if (acquired == vk.VK_ERROR_OUT_OF_DATE_KHR) {
            self.recreate_pending = true;
            return null;
        }
        if (acquired == vk.VK_SUBOPTIMAL_KHR) {
            self.recreate_pending = true;
        } else {
            try graphics.result(acquired);
        }

        try graphics.result(vk.vkResetFences(
            self.device.handle,
            1,
            &self.in_flight[frame],
        ));
        try graphics.result(vk.vkResetCommandBuffer(
            self.command_buffers[frame],
            0,
        ));

        const begin_info = std.mem.zeroInit(vk.VkCommandBufferBeginInfo, .{
            .sType = @as(vk.VkStructureType, @intCast(vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO)),
            .flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        });
        try graphics.result(vk.vkBeginCommandBuffer(
            self.command_buffers[frame],
            &begin_info,
        ));

        self.clear_value = .{ .color = .{ .float32 = clear } };
        const render_pass_info = std.mem.zeroInit(vk.VkRenderPassBeginInfo, .{
            .sType = @as(vk.VkStructureType, @intCast(vk.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO)),
            .renderPass = self.render_pass,
            .framebuffer = self.framebuffers[self.current_image],
            .renderArea = .{
                .offset = .{ .x = 0, .y = 0 },
                .extent = self.extent,
            },
            .clearValueCount = 1,
            .pClearValues = &self.clear_value,
        });
        vk.vkCmdBeginRenderPass(
            self.command_buffers[frame],
            &render_pass_info,
            vk.VK_SUBPASS_CONTENTS_INLINE,
        );
        self.active_frame = true;

        return .{
            .command_buffer = self.command_buffers[frame],
            .extent = self.extent,
            .frame_slot = frame,
        };
    }

    pub fn endFrame(self: *Presenter) !void {
        std.debug.assert(self.active_frame);
        defer self.active_frame = false;

        const frame = self.current_frame;
        const command_buffer = self.command_buffers[frame];
        // The render pass rendered straight into the acquired swapchain image
        // and its finalLayout transitioned it to PRESENT_SRC — nothing else to
        // do but submit and present.
        vk.vkCmdEndRenderPass(command_buffer);
        try graphics.result(vk.vkEndCommandBuffer(command_buffer));

        const wait_stage = [_]vk.VkPipelineStageFlags{
            vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        };
        const submit_info = std.mem.zeroInit(vk.VkSubmitInfo, .{
            .sType = @as(vk.VkStructureType, @intCast(vk.VK_STRUCTURE_TYPE_SUBMIT_INFO)),
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &self.image_available[frame],
            .pWaitDstStageMask = &wait_stage,
            .commandBufferCount = 1,
            .pCommandBuffers = &command_buffer,
            .signalSemaphoreCount = 1,
            .pSignalSemaphores = &self.render_finished[frame],
        });
        try graphics.result(vk.vkQueueSubmit(
            self.device.graphics_queue,
            1,
            &submit_info,
            self.in_flight[frame],
        ));

        const present_info = std.mem.zeroInit(vk.VkPresentInfoKHR, .{
            .sType = @as(vk.VkStructureType, @intCast(vk.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR)),
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &self.render_finished[frame],
            .swapchainCount = 1,
            .pSwapchains = &self.swapchain,
            .pImageIndices = &self.current_image,
        });
        const presented = vk.vkQueuePresentKHR(self.device.present_queue, &present_info);
        if (presented == vk.VK_ERROR_OUT_OF_DATE_KHR or
            presented == vk.VK_SUBOPTIMAL_KHR)
        {
            self.recreate_pending = true;
        } else {
            try graphics.result(presented);
        }
        self.current_frame = (frame + 1) % frame_slot_count;
    }

    fn recreate(self: *Presenter) !void {
        if (self.desired_width == 0 or self.desired_height == 0) return;
        self.device.waitIdle();
        self.destroySwapchain();
        try self.createSwapchain();
        self.recreate_pending = false;
    }

    fn createCommandPool(self: *Presenter) !void {
        const pool_info = std.mem.zeroInit(vk.VkCommandPoolCreateInfo, .{
            .sType = @as(vk.VkStructureType, @intCast(vk.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO)),
            .flags = vk.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
            .queueFamilyIndex = self.device.graphics_family,
        });
        try graphics.result(vk.vkCreateCommandPool(
            self.device.handle,
            &pool_info,
            null,
            &self.command_pool,
        ));

        const alloc_info = std.mem.zeroInit(vk.VkCommandBufferAllocateInfo, .{
            .sType = @as(vk.VkStructureType, @intCast(vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO)),
            .commandPool = self.command_pool,
            .level = @as(vk.VkCommandBufferLevel, @intCast(vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY)),
            .commandBufferCount = frame_slot_count,
        });
        try graphics.result(vk.vkAllocateCommandBuffers(
            self.device.handle,
            &alloc_info,
            &self.command_buffers,
        ));
    }

    fn createSyncObjects(self: *Presenter) !void {
        const semaphore_info = std.mem.zeroInit(vk.VkSemaphoreCreateInfo, .{
            .sType = @as(vk.VkStructureType, @intCast(vk.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO)),
        });
        const fence_info = std.mem.zeroInit(vk.VkFenceCreateInfo, .{
            .sType = @as(vk.VkStructureType, @intCast(vk.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO)),
            .flags = vk.VK_FENCE_CREATE_SIGNALED_BIT,
        });
        for (0..frame_slot_count) |index| {
            try graphics.result(vk.vkCreateSemaphore(
                self.device.handle,
                &semaphore_info,
                null,
                &self.image_available[index],
            ));
            try graphics.result(vk.vkCreateSemaphore(
                self.device.handle,
                &semaphore_info,
                null,
                &self.render_finished[index],
            ));
            try graphics.result(vk.vkCreateFence(
                self.device.handle,
                &fence_info,
                null,
                &self.in_flight[index],
            ));
        }
    }

    fn createSwapchain(self: *Presenter) !void {
        var capabilities: vk.VkSurfaceCapabilitiesKHR = undefined;
        try graphics.result(vk.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(
            self.device.physical,
            self.surface,
            &capabilities,
        ));

        const selected_format = try self.chooseSurfaceFormat();
        const present_mode = try self.choosePresentMode();
        const extent = chooseExtent(capabilities, self.desired_width, self.desired_height);
        if (extent.width == 0 or extent.height == 0) return;

        var image_count = capabilities.minImageCount + 1;
        if (capabilities.maxImageCount > 0) {
            image_count = @min(image_count, capabilities.maxImageCount);
        }
        const queue_families = [_]u32{
            self.device.graphics_family,
            self.device.present_family,
        };
        const separate_queues = self.device.graphics_family != self.device.present_family;
        const create_info = std.mem.zeroInit(vk.VkSwapchainCreateInfoKHR, .{
            .sType = @as(vk.VkStructureType, @intCast(vk.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR)),
            .surface = self.surface,
            .minImageCount = image_count,
            .imageFormat = selected_format.format,
            .imageColorSpace = selected_format.colorSpace,
            .imageExtent = extent,
            .imageArrayLayers = 1,
            .imageUsage = @as(vk.VkImageUsageFlags, vk.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT),
            .imageSharingMode = @as(vk.VkSharingMode, @intCast(if (separate_queues)
                vk.VK_SHARING_MODE_CONCURRENT
            else
                vk.VK_SHARING_MODE_EXCLUSIVE)),
            .queueFamilyIndexCount = if (separate_queues) @as(u32, 2) else 0,
            .pQueueFamilyIndices = if (separate_queues) queue_families[0..].ptr else null,
            .preTransform = capabilities.currentTransform,
            .compositeAlpha = chooseCompositeAlpha(capabilities.supportedCompositeAlpha),
            .presentMode = present_mode,
            .clipped = @as(vk.VkBool32, @intCast(vk.VK_TRUE)),
            .oldSwapchain = null,
        });
        try graphics.result(vk.vkCreateSwapchainKHR(
            self.device.handle,
            &create_info,
            null,
            &self.swapchain,
        ));
        errdefer self.destroySwapchain();

        var actual_count: u32 = 0;
        try graphics.result(vk.vkGetSwapchainImagesKHR(
            self.device.handle,
            self.swapchain,
            &actual_count,
            null,
        ));
        self.images = try self.allocator.alloc(vk.VkImage, actual_count);
        try graphics.result(vk.vkGetSwapchainImagesKHR(
            self.device.handle,
            self.swapchain,
            &actual_count,
            self.images.ptr,
        ));
        self.views = try self.allocator.alloc(vk.VkImageView, actual_count);
        @memset(self.views, null);

        self.format = selected_format.format;
        self.color_space = selected_format.colorSpace;
        self.extent = extent;
        try self.createRenderPass();
        try self.createViewsAndFramebuffers();
    }

    fn createRenderPass(self: *Presenter) !void {
        const attachment = vk.VkAttachmentDescription{
            .flags = 0,
            .format = self.format,
            .samples = @as(vk.VkSampleCountFlagBits, @intCast(vk.VK_SAMPLE_COUNT_1_BIT)),
            .loadOp = @as(vk.VkAttachmentLoadOp, @intCast(vk.VK_ATTACHMENT_LOAD_OP_CLEAR)),
            .storeOp = @as(vk.VkAttachmentStoreOp, @intCast(vk.VK_ATTACHMENT_STORE_OP_STORE)),
            .stencilLoadOp = @as(vk.VkAttachmentLoadOp, @intCast(vk.VK_ATTACHMENT_LOAD_OP_DONT_CARE)),
            .stencilStoreOp = @as(vk.VkAttachmentStoreOp, @intCast(vk.VK_ATTACHMENT_STORE_OP_DONT_CARE)),
            .initialLayout = @as(vk.VkImageLayout, @intCast(vk.VK_IMAGE_LAYOUT_UNDEFINED)),
            .finalLayout = @as(vk.VkImageLayout, @intCast(vk.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR)),
        };
        const color_reference = vk.VkAttachmentReference{
            .attachment = 0,
            .layout = @as(vk.VkImageLayout, @intCast(vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL)),
        };
        const subpass = std.mem.zeroInit(vk.VkSubpassDescription, .{
            .pipelineBindPoint = @as(vk.VkPipelineBindPoint, @intCast(vk.VK_PIPELINE_BIND_POINT_GRAPHICS)),
            .colorAttachmentCount = 1,
            .pColorAttachments = &color_reference,
        });
        const dependency = vk.VkSubpassDependency{
            .srcSubpass = vk.VK_SUBPASS_EXTERNAL,
            .dstSubpass = 0,
            .srcStageMask = vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            .dstStageMask = vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            .srcAccessMask = 0,
            .dstAccessMask = vk.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            .dependencyFlags = 0,
        };
        const create_info = std.mem.zeroInit(vk.VkRenderPassCreateInfo, .{
            .sType = @as(vk.VkStructureType, @intCast(vk.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO)),
            .attachmentCount = 1,
            .pAttachments = &attachment,
            .subpassCount = 1,
            .pSubpasses = &subpass,
            .dependencyCount = 1,
            .pDependencies = &dependency,
        });
        try graphics.result(vk.vkCreateRenderPass(
            self.device.handle,
            &create_info,
            null,
            &self.render_pass,
        ));
    }

    fn createViewsAndFramebuffers(self: *Presenter) !void {
        for (self.images, 0..) |image, index| {
            const view_info = std.mem.zeroInit(vk.VkImageViewCreateInfo, .{
                .sType = @as(vk.VkStructureType, @intCast(vk.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO)),
                .image = image,
                .viewType = @as(vk.VkImageViewType, @intCast(vk.VK_IMAGE_VIEW_TYPE_2D)),
                .format = self.format,
                .components = .{
                    .r = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
                    .g = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
                    .b = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
                    .a = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
                },
                .subresourceRange = .{
                    .aspectMask = @as(vk.VkImageAspectFlags, @intCast(vk.VK_IMAGE_ASPECT_COLOR_BIT)),
                    .baseMipLevel = 0,
                    .levelCount = 1,
                    .baseArrayLayer = 0,
                    .layerCount = 1,
                },
            });
            try graphics.result(vk.vkCreateImageView(
                self.device.handle,
                &view_info,
                null,
                &self.views[index],
            ));
        }

        self.framebuffers = try self.allocator.alloc(vk.VkFramebuffer, self.images.len);
        @memset(self.framebuffers, null);
        for (self.views, 0..) |view, index| {
            const framebuffer_info = std.mem.zeroInit(vk.VkFramebufferCreateInfo, .{
                .sType = @as(vk.VkStructureType, @intCast(vk.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO)),
                .renderPass = self.render_pass,
                .attachmentCount = 1,
                .pAttachments = &self.views[index],
                .width = self.extent.width,
                .height = self.extent.height,
                .layers = 1,
            });
            _ = view;
            try graphics.result(vk.vkCreateFramebuffer(
                self.device.handle,
                &framebuffer_info,
                null,
                &self.framebuffers[index],
            ));
        }
    }

    fn destroySwapchain(self: *Presenter) void {
        for (self.framebuffers) |framebuffer| {
            if (framebuffer != null) vk.vkDestroyFramebuffer(self.device.handle, framebuffer, null);
        }
        for (self.views) |view| {
            if (view != null) vk.vkDestroyImageView(self.device.handle, view, null);
        }
        if (self.render_pass != null) {
            vk.vkDestroyRenderPass(self.device.handle, self.render_pass, null);
        }
        if (self.swapchain != null) {
            vk.vkDestroySwapchainKHR(self.device.handle, self.swapchain, null);
        }
        if (self.framebuffers.len > 0) self.allocator.free(self.framebuffers);
        if (self.views.len > 0) self.allocator.free(self.views);
        if (self.images.len > 0) self.allocator.free(self.images);
        self.framebuffers = &.{};
        self.views = &.{};
        self.images = &.{};
        self.render_pass = null;
        self.swapchain = null;
        self.extent = .{ .width = 0, .height = 0 };
    }

    fn chooseSurfaceFormat(self: *Presenter) !vk.VkSurfaceFormatKHR {
        var count: u32 = 0;
        try graphics.result(vk.vkGetPhysicalDeviceSurfaceFormatsKHR(
            self.device.physical,
            self.surface,
            &count,
            null,
        ));
        if (count == 0) return error.NoSurfaceFormat;
        const formats = try self.allocator.alloc(vk.VkSurfaceFormatKHR, count);
        defer self.allocator.free(formats);
        try graphics.result(vk.vkGetPhysicalDeviceSurfaceFormatsKHR(
            self.device.physical,
            self.surface,
            &count,
            formats.ptr,
        ));
        for (formats[0..count]) |format| {
            if (format.format == vk.VK_FORMAT_B8G8R8A8_SRGB and
                format.colorSpace == vk.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR)
            {
                return format;
            }
        }
        return formats[0];
    }

    fn choosePresentMode(self: *Presenter) !vk.VkPresentModeKHR {
        var count: u32 = 0;
        try graphics.result(vk.vkGetPhysicalDeviceSurfacePresentModesKHR(
            self.device.physical,
            self.surface,
            &count,
            null,
        ));
        if (count == 0) return vk.VK_PRESENT_MODE_FIFO_KHR;
        const modes = try self.allocator.alloc(vk.VkPresentModeKHR, count);
        defer self.allocator.free(modes);
        try graphics.result(vk.vkGetPhysicalDeviceSurfacePresentModesKHR(
            self.device.physical,
            self.surface,
            &count,
            modes.ptr,
        ));
        for (modes[0..count]) |mode| {
            if (mode == vk.VK_PRESENT_MODE_MAILBOX_KHR) return mode;
        }
        return vk.VK_PRESENT_MODE_FIFO_KHR;
    }
};

fn chooseExtent(
    capabilities: vk.VkSurfaceCapabilitiesKHR,
    width: u32,
    height: u32,
) vk.VkExtent2D {
    if (capabilities.currentExtent.width != std.math.maxInt(u32)) {
        return capabilities.currentExtent;
    }
    return .{
        .width = std.math.clamp(
            width,
            capabilities.minImageExtent.width,
            capabilities.maxImageExtent.width,
        ),
        .height = std.math.clamp(
            height,
            capabilities.minImageExtent.height,
            capabilities.maxImageExtent.height,
        ),
    };
}

fn chooseCompositeAlpha(flags: vk.VkCompositeAlphaFlagsKHR) vk.VkCompositeAlphaFlagBitsKHR {
    const candidates = [_]vk.VkCompositeAlphaFlagBitsKHR{
        vk.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
        vk.VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR,
        vk.VK_COMPOSITE_ALPHA_POST_MULTIPLIED_BIT_KHR,
        vk.VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR,
    };
    for (candidates) |candidate| {
        if (flags & @as(vk.VkCompositeAlphaFlagsKHR, @intCast(candidate)) != 0) {
            return candidate;
        }
    }
    return vk.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
}

fn memoryTypeIndex(
    physical: vk.VkPhysicalDevice,
    supported_bits: u32,
    required_flags: vk.VkMemoryPropertyFlags,
) !u32 {
    var properties: vk.VkPhysicalDeviceMemoryProperties = undefined;
    vk.vkGetPhysicalDeviceMemoryProperties(physical, &properties);
    for (0..properties.memoryTypeCount) |index| {
        const bit = @as(u32, 1) << @as(u5, @intCast(index));
        if (supported_bits & bit == 0) continue;
        if (properties.memoryTypes[index].propertyFlags & required_flags == required_flags) {
            return @intCast(index);
        }
    }
    return error.NoCompatibleMemoryType;
}

fn colorRange() vk.VkImageSubresourceRange {
    return .{
        .aspectMask = @as(vk.VkImageAspectFlags, @intCast(vk.VK_IMAGE_ASPECT_COLOR_BIT)),
        .baseMipLevel = 0,
        .levelCount = 1,
        .baseArrayLayer = 0,
        .layerCount = 1,
    };
}

fn colorLayers() vk.VkImageSubresourceLayers {
    return .{
        .aspectMask = @as(vk.VkImageAspectFlags, @intCast(vk.VK_IMAGE_ASPECT_COLOR_BIT)),
        .mipLevel = 0,
        .baseArrayLayer = 0,
        .layerCount = 1,
    };
}

fn imageBarrier(
    image: vk.VkImage,
    old_layout: vk.VkImageLayout,
    new_layout: vk.VkImageLayout,
    source_access: vk.VkAccessFlags,
    destination_access: vk.VkAccessFlags,
) vk.VkImageMemoryBarrier {
    return std.mem.zeroInit(vk.VkImageMemoryBarrier, .{
        .sType = @as(vk.VkStructureType, @intCast(vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER)),
        .srcAccessMask = source_access,
        .dstAccessMask = destination_access,
        .oldLayout = old_layout,
        .newLayout = new_layout,
        .srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresourceRange = colorRange(),
    });
}

test "presenter renders into per-image swapchain framebuffers, holds no UI state" {
    try std.testing.expect(@hasField(Presenter, "framebuffers"));
    try std.testing.expect(!@hasField(Presenter, "composition_image"));
    try std.testing.expect(!@hasField(Presenter, "paint_commands"));
}
