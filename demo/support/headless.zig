//! Offscreen render target for headless screenshots and pixel-level tests.
//!
//! Stands up a surfaceless Vulkan device, renders frames into an offscreen
//! color image via the same `render.Renderer` the windowed app uses, and reads
//! the result back to host memory. Events are data and paint is a value, so a
//! full UI frame can be rendered and asserted without a compositor.

const std = @import("std");
const graphics = @import("goop_graphics_vulkan");
const present = @import("goop_present_vulkan");
const render = @import("goop_render_vulkan");
const snail = @import("goop_snail");
const display = @import("goop_display");

const vk = graphics.vk;

fn check(code: vk.VkResult) !void {
    return graphics.result(code);
}

fn memoryTypeIndex(physical: vk.VkPhysicalDevice, type_bits: u32, properties: vk.VkMemoryPropertyFlags) !u32 {
    var props: vk.VkPhysicalDeviceMemoryProperties = undefined;
    vk.vkGetPhysicalDeviceMemoryProperties(physical, &props);
    var i: u32 = 0;
    while (i < props.memoryTypeCount) : (i += 1) {
        const bit = @as(u32, 1) << @intCast(i);
        if ((type_bits & bit) != 0 and (props.memoryTypes[i].propertyFlags & properties) == properties) return i;
    }
    return error.NoMemoryType;
}

pub const Offscreen = struct {
    allocator: std.mem.Allocator,
    instance: graphics.Instance,
    device: graphics.Device,
    width: u32,
    height: u32,
    format: vk.VkFormat,

    image: vk.VkImage,
    image_memory: vk.VkDeviceMemory,
    view: vk.VkImageView,
    render_pass: vk.VkRenderPass,
    framebuffer: vk.VkFramebuffer,

    readback: vk.VkBuffer,
    readback_memory: vk.VkDeviceMemory,
    readback_size: vk.VkDeviceSize,

    pool: vk.VkCommandPool,
    cmd: vk.VkCommandBuffer,
    fence: vk.VkFence,

    renderer: render.Renderer,

    pub fn init(
        allocator: std.mem.Allocator,
        text: *const snail.TextEngine,
        width: u32,
        height: u32,
    ) !Offscreen {
        const format = vk.VK_FORMAT_B8G8R8A8_UNORM;

        var instance = try graphics.Instance.init("goop-headless", &.{});
        errdefer instance.deinit();

        var device = try graphics.Device.init(allocator, instance, null);
        errdefer device.deinit();
        const dev = device.handle;

        // ── Offscreen color image ──
        var image: vk.VkImage = null;
        const image_info = std.mem.zeroInit(vk.VkImageCreateInfo, .{
            .sType = @as(vk.VkStructureType, @intCast(vk.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO)),
            .imageType = @as(vk.VkImageType, @intCast(vk.VK_IMAGE_TYPE_2D)),
            .format = format,
            .extent = .{ .width = width, .height = height, .depth = 1 },
            .mipLevels = 1,
            .arrayLayers = 1,
            .samples = @as(vk.VkSampleCountFlagBits, @intCast(vk.VK_SAMPLE_COUNT_1_BIT)),
            .tiling = @as(vk.VkImageTiling, @intCast(vk.VK_IMAGE_TILING_OPTIMAL)),
            .usage = vk.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | vk.VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
            .sharingMode = @as(vk.VkSharingMode, @intCast(vk.VK_SHARING_MODE_EXCLUSIVE)),
            .initialLayout = @as(vk.VkImageLayout, @intCast(vk.VK_IMAGE_LAYOUT_UNDEFINED)),
        });
        try check(vk.vkCreateImage(dev, &image_info, null, &image));
        errdefer vk.vkDestroyImage(dev, image, null);

        var image_reqs: vk.VkMemoryRequirements = undefined;
        vk.vkGetImageMemoryRequirements(dev, image, &image_reqs);
        var image_memory: vk.VkDeviceMemory = null;
        const image_alloc = std.mem.zeroInit(vk.VkMemoryAllocateInfo, .{
            .sType = @as(vk.VkStructureType, @intCast(vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO)),
            .allocationSize = image_reqs.size,
            .memoryTypeIndex = try memoryTypeIndex(device.physical, image_reqs.memoryTypeBits, vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT),
        });
        try check(vk.vkAllocateMemory(dev, &image_alloc, null, &image_memory));
        errdefer vk.vkFreeMemory(dev, image_memory, null);
        try check(vk.vkBindImageMemory(dev, image, image_memory, 0));

        const range = vk.VkImageSubresourceRange{
            .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        };
        var view: vk.VkImageView = null;
        const view_info = std.mem.zeroInit(vk.VkImageViewCreateInfo, .{
            .sType = @as(vk.VkStructureType, @intCast(vk.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO)),
            .image = image,
            .viewType = @as(vk.VkImageViewType, @intCast(vk.VK_IMAGE_VIEW_TYPE_2D)),
            .format = format,
            .subresourceRange = range,
        });
        try check(vk.vkCreateImageView(dev, &view_info, null, &view));
        errdefer vk.vkDestroyImageView(dev, view, null);

        // ── Render pass: clear, store, leave in TRANSFER_SRC for readback ──
        var render_pass: vk.VkRenderPass = null;
        const attachment = std.mem.zeroInit(vk.VkAttachmentDescription, .{
            .format = format,
            .samples = @as(vk.VkSampleCountFlagBits, @intCast(vk.VK_SAMPLE_COUNT_1_BIT)),
            .loadOp = @as(vk.VkAttachmentLoadOp, @intCast(vk.VK_ATTACHMENT_LOAD_OP_CLEAR)),
            .storeOp = @as(vk.VkAttachmentStoreOp, @intCast(vk.VK_ATTACHMENT_STORE_OP_STORE)),
            .stencilLoadOp = @as(vk.VkAttachmentLoadOp, @intCast(vk.VK_ATTACHMENT_LOAD_OP_DONT_CARE)),
            .stencilStoreOp = @as(vk.VkAttachmentStoreOp, @intCast(vk.VK_ATTACHMENT_STORE_OP_DONT_CARE)),
            .initialLayout = @as(vk.VkImageLayout, @intCast(vk.VK_IMAGE_LAYOUT_UNDEFINED)),
            .finalLayout = @as(vk.VkImageLayout, @intCast(vk.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL)),
        });
        const color_ref = vk.VkAttachmentReference{ .attachment = 0, .layout = vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
        const subpass = std.mem.zeroInit(vk.VkSubpassDescription, .{
            .pipelineBindPoint = @as(vk.VkPipelineBindPoint, @intCast(vk.VK_PIPELINE_BIND_POINT_GRAPHICS)),
            .colorAttachmentCount = 1,
            .pColorAttachments = &color_ref,
        });
        const rp_info = std.mem.zeroInit(vk.VkRenderPassCreateInfo, .{
            .sType = @as(vk.VkStructureType, @intCast(vk.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO)),
            .attachmentCount = 1,
            .pAttachments = &attachment,
            .subpassCount = 1,
            .pSubpasses = &subpass,
        });
        try check(vk.vkCreateRenderPass(dev, &rp_info, null, &render_pass));
        errdefer vk.vkDestroyRenderPass(dev, render_pass, null);

        var framebuffer: vk.VkFramebuffer = null;
        const fb_info = std.mem.zeroInit(vk.VkFramebufferCreateInfo, .{
            .sType = @as(vk.VkStructureType, @intCast(vk.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO)),
            .renderPass = render_pass,
            .attachmentCount = 1,
            .pAttachments = &view,
            .width = width,
            .height = height,
            .layers = 1,
        });
        try check(vk.vkCreateFramebuffer(dev, &fb_info, null, &framebuffer));
        errdefer vk.vkDestroyFramebuffer(dev, framebuffer, null);

        // ── Host-visible readback buffer ──
        const readback_size: vk.VkDeviceSize = @as(vk.VkDeviceSize, width) * height * 4;
        var readback: vk.VkBuffer = null;
        const buffer_info = std.mem.zeroInit(vk.VkBufferCreateInfo, .{
            .sType = @as(vk.VkStructureType, @intCast(vk.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO)),
            .size = readback_size,
            .usage = vk.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
            .sharingMode = @as(vk.VkSharingMode, @intCast(vk.VK_SHARING_MODE_EXCLUSIVE)),
        });
        try check(vk.vkCreateBuffer(dev, &buffer_info, null, &readback));
        errdefer vk.vkDestroyBuffer(dev, readback, null);

        var buffer_reqs: vk.VkMemoryRequirements = undefined;
        vk.vkGetBufferMemoryRequirements(dev, readback, &buffer_reqs);
        var readback_memory: vk.VkDeviceMemory = null;
        const buffer_alloc = std.mem.zeroInit(vk.VkMemoryAllocateInfo, .{
            .sType = @as(vk.VkStructureType, @intCast(vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO)),
            .allocationSize = buffer_reqs.size,
            .memoryTypeIndex = try memoryTypeIndex(
                device.physical,
                buffer_reqs.memoryTypeBits,
                vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            ),
        });
        try check(vk.vkAllocateMemory(dev, &buffer_alloc, null, &readback_memory));
        errdefer vk.vkFreeMemory(dev, readback_memory, null);
        try check(vk.vkBindBufferMemory(dev, readback, readback_memory, 0));

        // ── Command pool / buffer / fence ──
        var pool: vk.VkCommandPool = null;
        const pool_info = std.mem.zeroInit(vk.VkCommandPoolCreateInfo, .{
            .sType = @as(vk.VkStructureType, @intCast(vk.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO)),
            .flags = vk.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
            .queueFamilyIndex = device.graphics_family,
        });
        try check(vk.vkCreateCommandPool(dev, &pool_info, null, &pool));
        errdefer vk.vkDestroyCommandPool(dev, pool, null);

        var cmd: vk.VkCommandBuffer = null;
        const cmd_alloc = std.mem.zeroInit(vk.VkCommandBufferAllocateInfo, .{
            .sType = @as(vk.VkStructureType, @intCast(vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO)),
            .commandPool = pool,
            .level = @as(vk.VkCommandBufferLevel, @intCast(vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY)),
            .commandBufferCount = 1,
        });
        try check(vk.vkAllocateCommandBuffers(dev, &cmd_alloc, &cmd));

        var fence: vk.VkFence = null;
        const fence_info = std.mem.zeroInit(vk.VkFenceCreateInfo, .{
            .sType = @as(vk.VkStructureType, @intCast(vk.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO)),
        });
        try check(vk.vkCreateFence(dev, &fence_info, null, &fence));
        errdefer vk.vkDestroyFence(dev, fence, null);

        var renderer = try render.Renderer.init(allocator, device.context(), render_pass, text, .{});
        errdefer renderer.deinit();

        return .{
            .allocator = allocator,
            .instance = instance,
            .device = device,
            .width = width,
            .height = height,
            .format = format,
            .image = image,
            .image_memory = image_memory,
            .view = view,
            .render_pass = render_pass,
            .framebuffer = framebuffer,
            .readback = readback,
            .readback_memory = readback_memory,
            .readback_size = readback_size,
            .pool = pool,
            .cmd = cmd,
            .fence = fence,
            .renderer = renderer,
        };
    }

    pub fn deinit(self: *Offscreen) void {
        self.device.waitIdle();
        const dev = self.device.handle;
        self.renderer.deinit();
        vk.vkDestroyFence(dev, self.fence, null);
        vk.vkDestroyCommandPool(dev, self.pool, null);
        vk.vkFreeMemory(dev, self.readback_memory, null);
        vk.vkDestroyBuffer(dev, self.readback, null);
        vk.vkDestroyFramebuffer(dev, self.framebuffer, null);
        vk.vkDestroyRenderPass(dev, self.render_pass, null);
        vk.vkDestroyImageView(dev, self.view, null);
        vk.vkFreeMemory(dev, self.image_memory, null);
        vk.vkDestroyImage(dev, self.image, null);
        self.device.deinit();
        self.instance.deinit();
        self.* = undefined;
    }

    fn frameTarget(self: *Offscreen) present.FrameTarget {
        return .{
            .command_buffer = self.cmd,
            .render_pass = self.render_pass,
            .framebuffer = self.framebuffer,
            .extent = .{ .width = self.width, .height = self.height },
            .format = self.format,
            .frame_index = 0,
            .image_index = 0,
        };
    }

    /// Full-redraw path: draw a flat display command stream into the offscreen
    /// image (render pass clears first) and copy to the readback buffer.
    pub fn renderPaintList(
        self: *Offscreen,
        text: *snail.TextEngine,
        commands: []const display.PaintCommand,
        clear_rgb: [3]u8,
    ) !void {
        try check(vk.vkResetCommandBuffer(self.cmd, 0));

        const begin = std.mem.zeroInit(vk.VkCommandBufferBeginInfo, .{
            .sType = @as(vk.VkStructureType, @intCast(vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO)),
            .flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        });
        try check(vk.vkBeginCommandBuffer(self.cmd, &begin));

        const clear = vk.VkClearValue{ .color = .{ .float32 = .{
            @as(f32, @floatFromInt(clear_rgb[0])) / 255.0,
            @as(f32, @floatFromInt(clear_rgb[1])) / 255.0,
            @as(f32, @floatFromInt(clear_rgb[2])) / 255.0,
            1.0,
        } } };
        const rp_begin = std.mem.zeroInit(vk.VkRenderPassBeginInfo, .{
            .sType = @as(vk.VkStructureType, @intCast(vk.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO)),
            .renderPass = self.render_pass,
            .framebuffer = self.framebuffer,
            .renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = self.width, .height = self.height } },
            .clearValueCount = 1,
            .pClearValues = &clear,
        });
        vk.vkCmdBeginRenderPass(self.cmd, &rp_begin, vk.VK_SUBPASS_CONTENTS_INLINE);
        try self.renderer.drawPaintList(self.frameTarget(), text, commands);
        vk.vkCmdEndRenderPass(self.cmd);

        try self.copyAndSubmit();
    }

    fn copyAndSubmit(self: *Offscreen) !void {
        const dev = self.device.handle;
        const copy = vk.VkBufferImageCopy{
            .bufferOffset = 0,
            .bufferRowLength = 0,
            .bufferImageHeight = 0,
            .imageSubresource = .{
                .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
                .mipLevel = 0,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
            .imageOffset = .{ .x = 0, .y = 0, .z = 0 },
            .imageExtent = .{ .width = self.width, .height = self.height, .depth = 1 },
        };
        vk.vkCmdCopyImageToBuffer(self.cmd, self.image, vk.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, self.readback, 1, &copy);
        try check(vk.vkEndCommandBuffer(self.cmd));

        const submit = std.mem.zeroInit(vk.VkSubmitInfo, .{
            .sType = @as(vk.VkStructureType, @intCast(vk.VK_STRUCTURE_TYPE_SUBMIT_INFO)),
            .commandBufferCount = 1,
            .pCommandBuffers = &self.cmd,
        });
        try check(vk.vkResetFences(dev, 1, &self.fence));
        try check(vk.vkQueueSubmit(self.device.graphics_queue, 1, &submit, self.fence));
        try check(vk.vkWaitForFences(dev, 1, &self.fence, vk.VK_TRUE, std.math.maxInt(u64)));
    }

    /// sRGB-encoded pixel at (x, y) as {r, g, b, a}. Valid until the next render.
    pub fn pixel(self: *Offscreen, x: u32, y: u32) ![4]u8 {
        const dev = self.device.handle;
        var mapped: ?*anyopaque = null;
        try check(vk.vkMapMemory(dev, self.readback_memory, 0, self.readback_size, 0, &mapped));
        defer vk.vkUnmapMemory(dev, self.readback_memory);
        const bytes: [*]const u8 = @ptrCast(mapped.?);
        const offset = (y * self.width + x) * 4;
        // Stored BGRA.
        return .{ bytes[offset + 2], bytes[offset + 1], bytes[offset + 0], bytes[offset + 3] };
    }

    /// Dump the current readback buffer to a binary PPM (P6) for eyeballing.
    pub fn writePpm(self: *Offscreen, io: std.Io, path: []const u8) !void {
        const dev = self.device.handle;
        var mapped: ?*anyopaque = null;
        try check(vk.vkMapMemory(dev, self.readback_memory, 0, self.readback_size, 0, &mapped));
        defer vk.vkUnmapMemory(dev, self.readback_memory);
        const bytes: [*]const u8 = @ptrCast(mapped.?);

        const pixel_count = @as(usize, self.width) * self.height;
        var header_buf: [64]u8 = undefined;
        const header = try std.fmt.bufPrint(&header_buf, "P6\n{d} {d}\n255\n", .{ self.width, self.height });

        const out = try self.allocator.alloc(u8, header.len + pixel_count * 3);
        defer self.allocator.free(out);
        @memcpy(out[0..header.len], header);
        var i: usize = 0;
        while (i < pixel_count) : (i += 1) {
            const o = header.len + i * 3;
            out[o + 0] = bytes[i * 4 + 2]; // R
            out[o + 1] = bytes[i * 4 + 1]; // G
            out[o + 2] = bytes[i * 4 + 0]; // B
        }

        var file = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, out);
    }
};
