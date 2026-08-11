//! Goop-owned Vulkan pipeline renderer: pipeline layout, one pipeline per
//! shader family, a persistently-mapped instance ring, and per-batch command
//! recording. Consumes snail's public render contract (`render.records`
//! instances/batches, `render.target.DrawState`) and the committed
//! `snail_reflection` push-constant ABI. Modeled on escarghost's vk renderer,
//! ported to Snail's public contract (`textPushConstants` in contract.zig).

const std = @import("std");
const snail = @import("snail");
const snail_reflection = @import("snail_reflection");
const shaders = @import("goop_render_shaders");
const graphics = @import("goop_graphics_vulkan");

const vk = graphics.vk;

pub const Family = shaders.Family;
pub const FAMILY_COUNT = shaders.FAMILY_COUNT;

// ── Push constants (from snail's committed reflection) ──

pub const PushConstants = snail_reflection.reflection.PushConstants;

const PUSH_CONSTANT_SIZE: u32 = @sizeOf(PushConstants);
const PUSH_CONSTANT_STAGES = vk.VK_SHADER_STAGE_VERTEX_BIT | vk.VK_SHADER_STAGE_FRAGMENT_BIT;

// ── Vertex format (Instance = 72 bytes, instance-rate) ──

const records = snail.render.records;
const BYTES_PER_INSTANCE: usize = records.BYTES_PER_INSTANCE;

const QUAD_INDICES = [_]u32{ 0, 1, 2, 0, 2, 3 };
const INDICES_PER_GLYPH: u32 = QUAD_INDICES.len;

// ── ShapeKind → Family mapping (mirrors Snail contract.zig) ──

const ShapeKind = records.ShapeKind;
const target = snail.render.target;

pub fn familyForKind(kind: ShapeKind) Family {
    return switch (kind) {
        .regular => .text,
        .colr => .colr,
        .path_quadratic => .path_quadratic,
        .path_conic => .path_conic,
        .path => .path,
        .tt_hinted_text => .tt_hinted_text,
        .autohint => .autohint,
    };
}

/// Build the per-draw push constants for a batch, mirroring Snail
/// contract.zig `textPushConstants`. `atlas_page_texels` is the curve/band
/// pair returned by the device atlas's `atlasPageTexels()`.
pub fn pushConstants(
    draw_state: target.DrawState,
    page_base: u32,
    atlas_page_texels: [2]i32,
) PushConstants {
    return .{
        .mvp = draw_state.mvp.data,
        .viewport = .{ @floatFromInt(draw_state.surface.pixel_width), @floatFromInt(draw_state.surface.pixel_height) },
        .subpixel_order = @intFromEnum(target.SubpixelOrder.none),
        .output_srgb = if (draw_state.surface.encoding.shaderEncodesSrgb()) 1 else 0,
        .page_base = @intCast(page_base),
        .coverage_exponent = draw_state.raster.coverage_transfer.shaderExponent(),
        .dither_scale = draw_state.surface.format.ditherAmplitude(),
        .mask_output = if (draw_state.surface.format.hasColor()) 0 else 1,
        .atlas_page_texels = atlas_page_texels,
    };
}

// ── Host-visible buffer ──

const HostBuffer = struct {
    buffer: vk.VkBuffer,
    memory: vk.VkDeviceMemory,
    mapped: [*]u8,
    size: usize,

    fn init(ctx: graphics.Context, size: usize, usage: vk.VkBufferUsageFlags) !HostBuffer {
        const buffer_info = vk.VkBufferCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .size = size,
            .usage = usage,
            .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
        };
        var buffer: vk.VkBuffer = null;
        if (vk.vkCreateBuffer(ctx.device, &buffer_info, null, &buffer) != vk.VK_SUCCESS) return error.BufferCreationFailed;
        errdefer vk.vkDestroyBuffer(ctx.device, buffer, null);

        var mem_reqs: vk.VkMemoryRequirements = undefined;
        vk.vkGetBufferMemoryRequirements(ctx.device, buffer, &mem_reqs);

        var mem_props: vk.VkPhysicalDeviceMemoryProperties = undefined;
        vk.vkGetPhysicalDeviceMemoryProperties(ctx.physical_device, &mem_props);
        var memory_type_index: ?u32 = null;
        for (0..mem_props.memoryTypeCount) |i| {
            if (mem_reqs.memoryTypeBits & (@as(u32, 1) << @intCast(i)) != 0 and
                mem_props.memoryTypes[i].propertyFlags & (vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) != 0)
            {
                memory_type_index = @intCast(i);
                break;
            }
        }

        const alloc_info = vk.VkMemoryAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .allocationSize = mem_reqs.size,
            .memoryTypeIndex = memory_type_index orelse return error.NoSuitableMemory,
        };
        var memory: vk.VkDeviceMemory = null;
        if (vk.vkAllocateMemory(ctx.device, &alloc_info, null, &memory) != vk.VK_SUCCESS) return error.MemoryAllocationFailed;
        errdefer vk.vkFreeMemory(ctx.device, memory, null);

        if (vk.vkBindBufferMemory(ctx.device, buffer, memory, 0) != vk.VK_SUCCESS) return error.BindBufferFailed;

        var mapped_ptr: ?[*]u8 = null;
        if (vk.vkMapMemory(ctx.device, memory, 0, size, 0, @ptrCast(&mapped_ptr)) != vk.VK_SUCCESS) return error.MapFailed;
        errdefer vk.vkUnmapMemory(ctx.device, memory);

        return .{
            .buffer = buffer,
            .memory = memory,
            .mapped = mapped_ptr.?,
            .size = size,
        };
    }

    fn bytes(self: *const HostBuffer) []u8 {
        return self.mapped[0..self.size];
    }

    fn deinit(self: *HostBuffer, device: vk.VkDevice) void {
        vk.vkUnmapMemory(device, self.memory);
        vk.vkDestroyBuffer(device, self.buffer, null);
        vk.vkFreeMemory(device, self.memory, null);
    }
};

// ── Renderer ──

pub const PipelineRenderer = struct {
    device: vk.VkDevice,
    pipeline_layout: vk.VkPipelineLayout,
    pipelines: [FAMILY_COUNT]vk.VkPipeline,
    ibo: HostBuffer,
    vbo: HostBuffer,
    slot_bytes: usize,
    num_slots: u32,
    cur_slot_base: usize = 0,
    cursor: usize = 0,

    pub fn init(
        ctx: graphics.Context,
        render_pass: vk.VkRenderPass,
        desc_set_layout: vk.VkDescriptorSetLayout,
        slot_bytes: usize,
        num_slots: u32,
    ) !PipelineRenderer {
        if (slot_bytes == 0 or num_slots == 0) return error.InvalidCapacity;
        const vbo_size = std.math.mul(
            usize,
            slot_bytes,
            num_slots,
        ) catch return error.InvalidCapacity;

        // ── Pipeline layout ──
        const pc_range = vk.VkPushConstantRange{
            .stageFlags = PUSH_CONSTANT_STAGES,
            .offset = 0,
            .size = PUSH_CONSTANT_SIZE,
        };

        const layout_info = vk.VkPipelineLayoutCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .setLayoutCount = 1,
            .pSetLayouts = &desc_set_layout,
            .pushConstantRangeCount = 1,
            .pPushConstantRanges = &pc_range,
        };

        var pipeline_layout: vk.VkPipelineLayout = null;
        if (vk.vkCreatePipelineLayout(ctx.device, &layout_info, null, &pipeline_layout) != vk.VK_SUCCESS) {
            return error.PipelineLayoutCreationFailed;
        }
        errdefer vk.vkDestroyPipelineLayout(ctx.device, pipeline_layout, null);

        // ── Index buffer ──
        const ibo_size = @sizeOf(@TypeOf(QUAD_INDICES));
        var ibo = try HostBuffer.init(ctx, ibo_size, vk.VK_BUFFER_USAGE_INDEX_BUFFER_BIT);
        errdefer ibo.deinit(ctx.device);
        @memcpy(ibo.bytes()[0..ibo_size], std.mem.asBytes(&QUAD_INDICES));

        // ── Vertex ring buffer ──
        var vbo = try HostBuffer.init(ctx, vbo_size, vk.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
        errdefer vbo.deinit(ctx.device);

        // ── Pipelines ──
        var pipelines: [FAMILY_COUNT]vk.VkPipeline = [_]vk.VkPipeline{null} ** FAMILY_COUNT;
        for (std.enums.values(Family)) |family| {
            const r = shaders.recipe(family);
            pipelines[@intFromEnum(family)] = try buildPipeline(ctx, render_pass, pipeline_layout, r);
        }
        errdefer {
            for (pipelines) |p| if (p != null) vk.vkDestroyPipeline(ctx.device, p, null);
        }

        return .{
            .device = ctx.device,
            .pipeline_layout = pipeline_layout,
            .pipelines = pipelines,
            .ibo = ibo,
            .vbo = vbo,
            .slot_bytes = slot_bytes,
            .num_slots = num_slots,
        };
    }

    pub fn deinit(self: *PipelineRenderer) void {
        for (self.pipelines) |p| if (p != null) vk.vkDestroyPipeline(self.device, p, null);
        vk.vkDestroyPipelineLayout(self.device, self.pipeline_layout, null);
        self.ibo.deinit(self.device);
        self.vbo.deinit(self.device);
    }

    pub fn beginFrame(self: *PipelineRenderer, frame_slot: u32) !void {
        self.cur_slot_base = try frameSlotBase(frame_slot, self.num_slots, self.slot_bytes);
        self.cursor = 0;
    }

    pub const RenderError = error{
        VertexBufferFull,
    };

    pub fn render(
        self: *PipelineRenderer,
        cmd: vk.VkCommandBuffer,
        desc_set: vk.VkDescriptorSet,
        draw_state: target.DrawState,
        atlas_page_texels: [2]i32,
        instances: []const records.Instance,
        batches: []const records.DrawBatch,
    ) RenderError!void {
        if (instances.len == 0 or batches.len == 0) return;

        const instance_bytes = std.mem.sliceAsBytes(instances);
        if (self.cursor + instance_bytes.len > self.slot_bytes) return error.VertexBufferFull;

        // Copy instance data into the vertex ring.
        const base = self.cur_slot_base + self.cursor;
        @memcpy(self.vbo.bytes()[base..][0..instance_bytes.len], instance_bytes);
        self.cursor += instance_bytes.len;

        // Set viewport (Y-flipped, matching GL convention).
        const w: f32 = @floatFromInt(draw_state.surface.pixel_width);
        const h: f32 = @floatFromInt(draw_state.surface.pixel_height);
        const viewport = vk.VkViewport{
            .x = 0,
            .y = h,
            .width = w,
            .height = -h,
            .minDepth = 0,
            .maxDepth = 1,
        };
        const scissor = if (draw_state.scissor_rect) |rect|
            vk.VkRect2D{
                .offset = .{ .x = rect.x, .y = rect.y },
                .extent = .{ .width = rect.w, .height = rect.h },
            }
        else
            vk.VkRect2D{
                .offset = .{ .x = 0, .y = 0 },
                .extent = .{ .width = draw_state.surface.pixel_width, .height = draw_state.surface.pixel_height },
            };
        vk.vkCmdSetViewport(cmd, 0, 1, &viewport);
        vk.vkCmdSetScissor(cmd, 0, 1, &scissor);

        // Bind index buffer.
        vk.vkCmdBindIndexBuffer(cmd, self.ibo.buffer, 0, vk.VK_INDEX_TYPE_UINT32);

        // Bind descriptor set (once — the device atlas owns it).
        vk.vkCmdBindDescriptorSets(cmd, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, self.pipeline_layout, 0, 1, &desc_set, 0, null);

        // Per batch: bind pipeline, push constants, bind vertex buffer, draw.
        for (batches) |batch| {
            const family = familyForKind(batch.kind);
            const pipeline = self.pipelines[@intFromEnum(family)];
            if (pipeline == null) continue;

            vk.vkCmdBindPipeline(cmd, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);

            const pc = pushConstants(draw_state, batch.page_base, atlas_page_texels);
            vk.vkCmdPushConstants(cmd, self.pipeline_layout, PUSH_CONSTANT_STAGES, 0, PUSH_CONSTANT_SIZE, &pc);

            const vbo_offset: vk.VkDeviceSize = base + batch.first_instance * BYTES_PER_INSTANCE;
            vk.vkCmdBindVertexBuffers(cmd, 0, 1, &self.vbo.buffer, &vbo_offset);

            vk.vkCmdDrawIndexed(cmd, INDICES_PER_GLYPH, batch.instance_count, 0, 0, 0);
        }
    }
};

fn frameSlotBase(frame_slot: u32, frame_slot_count: u32, slot_bytes: usize) !usize {
    if (frame_slot >= frame_slot_count) return error.InvalidFrameSlot;
    return @as(usize, frame_slot) * slot_bytes;
}

test "frame slots outside the configured ring are rejected" {
    try std.testing.expectEqual(@as(usize, 4096), try frameSlotBase(1, 2, 4096));
    try std.testing.expectError(error.InvalidFrameSlot, frameSlotBase(2, 2, 4096));
}

test "renderer forces grayscale even when a caller requests LCD order" {
    const draw_state = target.DrawState{
        .mvp = snail.Mat4.identity,
        .surface = .{
            .pixel_width = 640,
            .pixel_height = 480,
            .encoding = .srgb,
        },
        .raster = .{ .subpixel_order = .rgb },
    };
    const constants = pushConstants(draw_state, 0, .{ 1, 1 });
    try std.testing.expectEqual(@as(i32, @intFromEnum(target.SubpixelOrder.none)), constants.subpixel_order);
    try std.testing.expectEqual(Family.text, familyForKind(.regular));
    try std.testing.expectEqual(Family.tt_hinted_text, familyForKind(.tt_hinted_text));
    try std.testing.expectEqual(Family.autohint, familyForKind(.autohint));
}

fn buildPipeline(ctx: graphics.Context, render_pass: vk.VkRenderPass, layout: vk.VkPipelineLayout, r: shaders.PipelineRecipe) !vk.VkPipeline {
    if (r.vert_spv.len == 0 or r.frag_spv.len == 0) return error.EmptyShader;

    // Shader modules.
    const vert_module = try createShaderModule(ctx.device, r.vert_spv);
    defer vk.vkDestroyShaderModule(ctx.device, vert_module, null);
    const frag_module = try createShaderModule(ctx.device, r.frag_spv);
    defer vk.vkDestroyShaderModule(ctx.device, frag_module, null);

    const shader_stages = [_]vk.VkPipelineShaderStageCreateInfo{
        .{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .stage = vk.VK_SHADER_STAGE_VERTEX_BIT,
            .module = vert_module,
            .pName = "main",
        },
        .{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .stage = vk.VK_SHADER_STAGE_FRAGMENT_BIT,
            .module = frag_module,
            .pName = "main",
        },
    };

    // Vertex input (instance-rate, binding 0, 72-byte stride): the 7
    // attributes of Snail contract.zig `vertexInputAttributes`.
    const binding_desc = vk.VkVertexInputBindingDescription{
        .binding = 0,
        .stride = @intCast(BYTES_PER_INSTANCE),
        .inputRate = vk.VK_VERTEX_INPUT_RATE_INSTANCE,
    };
    const attr_descs = [_]vk.VkVertexInputAttributeDescription{
        .{ .location = 0, .binding = 0, .format = vk.VK_FORMAT_R16G16B16A16_SFLOAT, .offset = @offsetOf(records.Instance, "rect") },
        .{ .location = 1, .binding = 0, .format = vk.VK_FORMAT_R32G32B32A32_SFLOAT, .offset = @offsetOf(records.Instance, "xform") },
        .{ .location = 2, .binding = 0, .format = vk.VK_FORMAT_R32G32_SFLOAT, .offset = @offsetOf(records.Instance, "origin") },
        .{ .location = 3, .binding = 0, .format = vk.VK_FORMAT_R32G32_UINT, .offset = @offsetOf(records.Instance, "glyph") },
        .{ .location = 4, .binding = 0, .format = vk.VK_FORMAT_R32G32B32A32_UINT, .offset = @offsetOf(records.Instance, "payload") },
        .{ .location = 5, .binding = 0, .format = vk.VK_FORMAT_R16G16B16A16_SFLOAT, .offset = @offsetOf(records.Instance, "color") },
        .{ .location = 6, .binding = 0, .format = vk.VK_FORMAT_R16G16B16A16_SFLOAT, .offset = @offsetOf(records.Instance, "tint") },
    };

    const vertex_input_state = vk.VkPipelineVertexInputStateCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
        .vertexBindingDescriptionCount = 1,
        .pVertexBindingDescriptions = &binding_desc,
        .vertexAttributeDescriptionCount = attr_descs.len,
        .pVertexAttributeDescriptions = &attr_descs,
    };

    const input_assembly = vk.VkPipelineInputAssemblyStateCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        .topology = vk.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
    };

    const viewport_state = vk.VkPipelineViewportStateCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        .viewportCount = 1,
        .scissorCount = 1,
    };

    const rasterizer = vk.VkPipelineRasterizationStateCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        .polygonMode = vk.VK_POLYGON_MODE_FILL,
        .cullMode = vk.VK_CULL_MODE_NONE,
        .frontFace = vk.VK_FRONT_FACE_COUNTER_CLOCKWISE,
        .lineWidth = 1.0,
    };

    const multisampling = vk.VkPipelineMultisampleStateCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        .rasterizationSamples = vk.VK_SAMPLE_COUNT_1_BIT,
    };

    // Grayscale shader outputs are premultiplied by coverage.
    const blend_attachment = vk.VkPipelineColorBlendAttachmentState{
        .blendEnable = vk.VK_TRUE,
        .srcColorBlendFactor = vk.VK_BLEND_FACTOR_ONE,
        .dstColorBlendFactor = vk.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
        .colorBlendOp = vk.VK_BLEND_OP_ADD,
        .srcAlphaBlendFactor = vk.VK_BLEND_FACTOR_ONE,
        .dstAlphaBlendFactor = vk.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
        .alphaBlendOp = vk.VK_BLEND_OP_ADD,
        .colorWriteMask = vk.VK_COLOR_COMPONENT_R_BIT | vk.VK_COLOR_COMPONENT_G_BIT | vk.VK_COLOR_COMPONENT_B_BIT | vk.VK_COLOR_COMPONENT_A_BIT,
    };

    const color_blend_state = vk.VkPipelineColorBlendStateCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        .logicOpEnable = vk.VK_FALSE,
        .attachmentCount = 1,
        .pAttachments = &blend_attachment,
    };

    const dynamic_states = [_]vk.VkDynamicState{ vk.VK_DYNAMIC_STATE_VIEWPORT, vk.VK_DYNAMIC_STATE_SCISSOR };
    const dynamic_state = vk.VkPipelineDynamicStateCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
        .dynamicStateCount = dynamic_states.len,
        .pDynamicStates = &dynamic_states,
    };

    const pipeline_info = vk.VkGraphicsPipelineCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
        .stageCount = shader_stages.len,
        .pStages = &shader_stages,
        .pVertexInputState = &vertex_input_state,
        .pInputAssemblyState = &input_assembly,
        .pViewportState = &viewport_state,
        .pRasterizationState = &rasterizer,
        .pMultisampleState = &multisampling,
        .pColorBlendState = &color_blend_state,
        .pDynamicState = &dynamic_state,
        .layout = layout,
        .renderPass = render_pass,
        .subpass = 0,
    };

    var pipeline: vk.VkPipeline = null;
    if (vk.vkCreateGraphicsPipelines(ctx.device, null, 1, &pipeline_info, null, &pipeline) != vk.VK_SUCCESS) {
        return error.PipelineCreationFailed;
    }
    return pipeline;
}

fn createShaderModule(device: vk.VkDevice, spv: []align(4) const u8) !vk.VkShaderModule {
    const create_info = vk.VkShaderModuleCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = spv.len,
        .pCode = @ptrCast(spv.ptr),
    };
    var module: vk.VkShaderModule = null;
    if (vk.vkCreateShaderModule(device, &create_info, null, &module) != vk.VK_SUCCESS) {
        return error.ShaderModuleCreationFailed;
    }
    return module;
}
