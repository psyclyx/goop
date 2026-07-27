//! Minimal offscreen Vulkan probe: create a headless device (no surface),
//! render a `loadOp=CLEAR` pass into an offscreen image, read it back to host
//! memory, and verify the pixels. This isolates the headless plumbing that the
//! real screenshot harness is built on, so renderer bugs and harness bugs never
//! have to be debugged at the same time.

const std = @import("std");
const graphics = @import("goop_graphics_vulkan");
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
        if ((type_bits & bit) != 0 and (props.memoryTypes[i].propertyFlags & properties) == properties) {
            return i;
        }
    }
    return error.NoMemoryType;
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const width: u32 = 64;
    const height: u32 = 64;
    const format = vk.VK_FORMAT_B8G8R8A8_UNORM;

    var instance = try graphics.Instance.init("goop-headless-probe", &.{});
    defer instance.deinit();

    var device = try graphics.Device.init(allocator, instance, null);
    defer device.deinit();
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
    defer vk.vkDestroyImage(dev, image, null);

    var image_reqs: vk.VkMemoryRequirements = undefined;
    vk.vkGetImageMemoryRequirements(dev, image, &image_reqs);
    var image_memory: vk.VkDeviceMemory = null;
    const image_alloc = std.mem.zeroInit(vk.VkMemoryAllocateInfo, .{
        .sType = @as(vk.VkStructureType, @intCast(vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO)),
        .allocationSize = image_reqs.size,
        .memoryTypeIndex = try memoryTypeIndex(device.physical, image_reqs.memoryTypeBits, vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT),
    });
    try check(vk.vkAllocateMemory(dev, &image_alloc, null, &image_memory));
    defer vk.vkFreeMemory(dev, image_memory, null);
    try check(vk.vkBindImageMemory(dev, image, image_memory, 0));

    const subresource_range = vk.VkImageSubresourceRange{
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
        .subresourceRange = subresource_range,
    });
    try check(vk.vkCreateImageView(dev, &view_info, null, &view));
    defer vk.vkDestroyImageView(dev, view, null);

    // ── Render pass: clear then leave in TRANSFER_SRC for readback ──
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
    const color_ref = vk.VkAttachmentReference{
        .attachment = 0,
        .layout = vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
    };
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
    defer vk.vkDestroyRenderPass(dev, render_pass, null);

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
    defer vk.vkDestroyFramebuffer(dev, framebuffer, null);

    // ── Host-visible readback buffer ──
    var readback: vk.VkBuffer = null;
    const buffer_size: vk.VkDeviceSize = @as(vk.VkDeviceSize, width) * height * 4;
    const buffer_info = std.mem.zeroInit(vk.VkBufferCreateInfo, .{
        .sType = @as(vk.VkStructureType, @intCast(vk.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO)),
        .size = buffer_size,
        .usage = vk.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
        .sharingMode = @as(vk.VkSharingMode, @intCast(vk.VK_SHARING_MODE_EXCLUSIVE)),
    });
    try check(vk.vkCreateBuffer(dev, &buffer_info, null, &readback));
    defer vk.vkDestroyBuffer(dev, readback, null);

    var buffer_reqs: vk.VkMemoryRequirements = undefined;
    vk.vkGetBufferMemoryRequirements(dev, readback, &buffer_reqs);
    var buffer_memory: vk.VkDeviceMemory = null;
    const buffer_alloc = std.mem.zeroInit(vk.VkMemoryAllocateInfo, .{
        .sType = @as(vk.VkStructureType, @intCast(vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO)),
        .allocationSize = buffer_reqs.size,
        .memoryTypeIndex = try memoryTypeIndex(
            device.physical,
            buffer_reqs.memoryTypeBits,
            vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        ),
    });
    try check(vk.vkAllocateMemory(dev, &buffer_alloc, null, &buffer_memory));
    defer vk.vkFreeMemory(dev, buffer_memory, null);
    try check(vk.vkBindBufferMemory(dev, readback, buffer_memory, 0));

    // ── Command pool + buffer + fence ──
    var pool: vk.VkCommandPool = null;
    const pool_info = std.mem.zeroInit(vk.VkCommandPoolCreateInfo, .{
        .sType = @as(vk.VkStructureType, @intCast(vk.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO)),
        .queueFamilyIndex = device.graphics_family,
    });
    try check(vk.vkCreateCommandPool(dev, &pool_info, null, &pool));
    defer vk.vkDestroyCommandPool(dev, pool, null);

    var cmd: vk.VkCommandBuffer = null;
    const cmd_alloc = std.mem.zeroInit(vk.VkCommandBufferAllocateInfo, .{
        .sType = @as(vk.VkStructureType, @intCast(vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO)),
        .commandPool = pool,
        .level = @as(vk.VkCommandBufferLevel, @intCast(vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY)),
        .commandBufferCount = 1,
    });
    try check(vk.vkAllocateCommandBuffers(dev, &cmd_alloc, &cmd));

    const begin_info = std.mem.zeroInit(vk.VkCommandBufferBeginInfo, .{
        .sType = @as(vk.VkStructureType, @intCast(vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO)),
        .flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    });
    try check(vk.vkBeginCommandBuffer(cmd, &begin_info));

    // Clear color: opaque blue (R=0.12, G=0.49, B=0.86) so BGRA byte order is
    // easy to eyeball in the readback.
    const clear = vk.VkClearValue{ .color = .{ .float32 = .{ 0.12, 0.49, 0.86, 1.0 } } };
    const rp_begin = std.mem.zeroInit(vk.VkRenderPassBeginInfo, .{
        .sType = @as(vk.VkStructureType, @intCast(vk.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO)),
        .renderPass = render_pass,
        .framebuffer = framebuffer,
        .renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = width, .height = height } },
        .clearValueCount = 1,
        .pClearValues = &clear,
    });
    vk.vkCmdBeginRenderPass(cmd, &rp_begin, vk.VK_SUBPASS_CONTENTS_INLINE);
    vk.vkCmdEndRenderPass(cmd);

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
        .imageExtent = .{ .width = width, .height = height, .depth = 1 },
    };
    vk.vkCmdCopyImageToBuffer(cmd, image, vk.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, readback, 1, &copy);
    try check(vk.vkEndCommandBuffer(cmd));

    var fence: vk.VkFence = null;
    const fence_info = std.mem.zeroInit(vk.VkFenceCreateInfo, .{
        .sType = @as(vk.VkStructureType, @intCast(vk.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO)),
    });
    try check(vk.vkCreateFence(dev, &fence_info, null, &fence));
    defer vk.vkDestroyFence(dev, fence, null);

    const submit = std.mem.zeroInit(vk.VkSubmitInfo, .{
        .sType = @as(vk.VkStructureType, @intCast(vk.VK_STRUCTURE_TYPE_SUBMIT_INFO)),
        .commandBufferCount = 1,
        .pCommandBuffers = &cmd,
    });
    try check(vk.vkQueueSubmit(device.graphics_queue, 1, &submit, fence));
    try check(vk.vkWaitForFences(dev, 1, &fence, vk.VK_TRUE, std.math.maxInt(u64)));

    // ── Read back and verify ──
    var mapped: ?*anyopaque = null;
    try check(vk.vkMapMemory(dev, buffer_memory, 0, buffer_size, 0, &mapped));
    defer vk.vkUnmapMemory(dev, buffer_memory);
    const pixels: [*]const u8 = @ptrCast(mapped.?);

    // Pixel (0,0), BGRA byte order.
    const b = pixels[0];
    const g = pixels[1];
    const r = pixels[2];
    const a = pixels[3];
    std.debug.print("pixel(0,0) BGRA-bytes = R={} G={} B={} A={}\n", .{ r, g, b, a });

    // Expect ~ (30, 125, 219, 255) from the clear color.
    const ok = a == 255 and r > 20 and r < 45 and g > 110 and g < 140 and b > 205 and b < 235;
    if (!ok) {
        std.debug.print("FAIL: unexpected pixel\n", .{});
        return error.UnexpectedPixel;
    }
    std.debug.print("PASS: offscreen clear + readback works\n", .{});

    device.waitIdle();
}
