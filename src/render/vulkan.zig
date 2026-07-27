//! Vulkan UI renderer.
//!
//! This module consumes backend-neutral Snail records and a caller-supplied
//! frame target. It owns pipelines, buffers, and device-atlas resources, but
//! no Vulkan instance, window-system surface, swapchain, or frame lifecycle.

const std = @import("std");
const graphics = @import("goop_graphics_vulkan");
const display = @import("goop_display");
const present = @import("goop_present_vulkan");
const goop_snail = @import("goop_snail");
const snail = @import("snail");
const render_state = @import("render-state");
const reference = @import("snail_reference_vulkan");
const reference_types = @import("snail_vulkan_types");

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    context: reference.VulkanContext,
    layout: reference.VulkanResourceLayout,
    transfer_pool: reference.vk.VkCommandPool,
    cache: reference.VulkanDeviceAtlas,
    caller: reference.Renderer,
    instances: []goop_snail.Instance,
    batches: []goop_snail.DrawBatch,
    binding: goop_snail.Binding,
    clip_stack: std.ArrayListUnmanaged(display.Rect) = .empty,

    pub const Options = struct {
        max_instances: usize = 65_536,
        max_bindings: u32 = 8,
        layer_info_height: u32 = 256,
        max_images: u32 = 16,
        max_image_width: u32 = 2048,
        max_image_height: u32 = 2048,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        device_context: graphics.Context,
        render_pass: graphics.vk.VkRenderPass,
        text: *const goop_snail.TextEngine,
        options: Options,
    ) !Renderer {
        if (options.max_instances == 0) return error.InvalidCapacity;
        const context = reference_types.VulkanContext.init(device_context, render_pass);

        var layout: reference.VulkanResourceLayout = undefined;
        try layout.init(context);
        errdefer layout.deinit();

        const transfer_pool = try reference.createTransferPool(context);
        errdefer reference.vk.vkDestroyCommandPool(context.device, transfer_pool, null);

        var cache = try reference.VulkanDeviceAtlas.init(
            allocator,
            text.pool(),
            reference.cachePipelineShape(context, &layout, transfer_pool),
            .{
                .max_bindings = options.max_bindings,
                .layer_info_height = options.layer_info_height,
                .max_images = options.max_images,
                .max_image_width = options.max_image_width,
                .max_image_height = options.max_image_height,
            },
        );
        errdefer cache.deinit();

        var bindings: [1]goop_snail.Binding = undefined;
        try cache.upload(allocator, &.{text.atlas()}, &bindings);

        var caller = try reference.Renderer.init(
            context,
            cache.descriptorSetLayout(),
            options.max_instances * snail.render.records.BYTES_PER_INSTANCE,
            present.max_frames_in_flight,
            .disabled,
        );
        errdefer caller.deinit();

        const instances = try allocator.alloc(goop_snail.Instance, options.max_instances);
        errdefer allocator.free(instances);
        const batches = try allocator.alloc(goop_snail.DrawBatch, options.max_instances);
        errdefer allocator.free(batches);

        return .{
            .allocator = allocator,
            .context = context,
            .layout = layout,
            .transfer_pool = transfer_pool,
            .cache = cache,
            .caller = caller,
            .instances = instances,
            .batches = batches,
            .binding = bindings[0],
        };
    }

    pub fn deinit(self: *Renderer) void {
        self.clip_stack.deinit(self.allocator);
        self.caller.deinit();
        self.cache.deinit();
        reference.vk.vkDestroyCommandPool(
            self.context.device,
            self.transfer_pool,
            null,
        );
        self.layout.deinit();
        self.allocator.free(self.batches);
        self.allocator.free(self.instances);
        self.* = undefined;
    }

    /// Draw one resolved paint command clipped to `visible`.
    fn drawResolvedCommand(
        self: *Renderer,
        target: present.FrameTarget,
        text: *goop_snail.TextEngine,
        paint: display.PaintCommand,
        visible: display.Rect,
    ) !void {
        switch (paint) {
            .surface => |surface| try drawSurface(self, target, text, surface, visible),
            .icon => |icon| try drawIcon(self, target, text, icon, visible),
            .text => |text_command| {
                const metrics = try text.measure(text_command.text, text_command.font_size);
                const x = switch (text_command.text_align) {
                    .start => text_command.bounds.x,
                    .center => text_command.bounds.x +
                        @max(0, text_command.bounds.w - metrics.width) * 0.5,
                    .end => text_command.bounds.x +
                        @max(0, text_command.bounds.w - metrics.width),
                };
                const baseline = text_command.bounds.y +
                    @max(0, text_command.bounds.h - metrics.height()) * 0.5 +
                    metrics.ascent;
                var prepared = try text.prepareText(
                    self.allocator,
                    text_command.text,
                    .{ .x = x, .y = baseline },
                    text_command.font_size,
                    text_command.color,
                );
                defer prepared.deinit();
                try self.updateAtlas(text);
                try self.drawPrepared(target, text, &prepared, visible);
            },
            .clip, .custom => {},
        }
    }

    /// Full-redraw path: draw every command in painter order into the whole
    /// frame, clipped only by the active clip stack. No damage regions, no
    /// retained composition — the render pass is expected to clear the target
    /// (loadOp=CLEAR). This is the renderer for the swapchain-direct pipeline:
    /// correct compositing by construction (no partial clears to leave stale
    /// pixels), and cheap because the instance stream is retained upstream.
    pub fn drawPaintList(
        self: *Renderer,
        target: present.FrameTarget,
        text: *goop_snail.TextEngine,
        commands: []const display.PaintCommand,
    ) !void {
        const full = display.Rect{
            .x = 0,
            .y = 0,
            .w = @floatFromInt(target.extent.width),
            .h = @floatFromInt(target.extent.height),
        };
        self.caller.beginFrame(target.frame_index);
        self.clip_stack.clearRetainingCapacity();
        for (commands) |paint| {
            if (paint == .clip) {
                if (paint.clip.bounds) |clip_bounds| {
                    const effective = if (self.clip_stack.items.len > 0)
                        intersect(self.clip_stack.items[self.clip_stack.items.len - 1], clip_bounds) orelse zero_rect
                    else
                        clip_bounds;
                    try self.clip_stack.append(self.allocator, effective);
                } else if (self.clip_stack.items.len > 0) {
                    _ = self.clip_stack.pop();
                }
                continue;
            }
            const bounds = display.commandBounds(paint) orelse continue;
            var visible = intersect(bounds, full) orelse continue;
            if (self.clip_stack.items.len > 0) {
                visible = intersect(visible, self.clip_stack.items[self.clip_stack.items.len - 1]) orelse continue;
            }
            try self.drawResolvedCommand(target, text, paint, visible);
        }
    }

    fn updateAtlas(self: *Renderer, text: *const goop_snail.TextEngine) !void {
        self.binding = self.cache.uploadDelta(
            self.allocator,
            self.binding,
            text.atlas(),
        ) catch |upload_error| switch (upload_error) {
            error.NoLayerInfoRoomToGrow, error.NoImageRoomToGrow => replacement: {
                self.cache.release(self.binding);
                var bindings: [1]goop_snail.Binding = undefined;
                try self.cache.upload(self.allocator, &.{text.atlas()}, &bindings);
                break :replacement bindings[0];
            },
            else => return upload_error,
        };
    }

    fn drawPrepared(
        self: *Renderer,
        target: present.FrameTarget,
        text: *const goop_snail.TextEngine,
        prepared: *const goop_snail.PreparedText,
        scissor: ?display.Rect,
    ) !void {
        var instance_len: usize = 0;
        var batch_len: usize = 0;
        _ = try text.emit(
            self.binding,
            prepared,
            self.instances,
            self.batches,
            &instance_len,
            &batch_len,
        );

        try self.caller.render(
            target.command_buffer,
            &self.cache,
            drawState(target, scissor),
            self.instances[0..instance_len],
            self.batches[0..batch_len],
        );
    }
};

fn intersect(a: display.Rect, b: display.Rect) ?display.Rect {
    const left = @max(a.x, b.x);
    const top = @max(a.y, b.y);
    const right = @min(a.x + a.w, b.x + b.w);
    const bottom = @min(a.y + a.h, b.y + b.h);
    if (right <= left or bottom <= top) return null;
    return .{ .x = left, .y = top, .w = right - left, .h = bottom - top };
}

fn clearRect(
    command_buffer: graphics.vk.VkCommandBuffer,
    bounds: display.Rect,
    color: display.Color,
    extent: graphics.vk.VkExtent2D,
    format: graphics.vk.VkFormat,
) void {
    const x: i32 = @intFromFloat(@max(0, @floor(bounds.x)));
    const y: i32 = @intFromFloat(@max(0, @floor(bounds.y)));
    const right: u32 = @intFromFloat(@min(
        @as(f32, @floatFromInt(extent.width)),
        @ceil(bounds.x + bounds.w),
    ));
    const bottom: u32 = @intFromFloat(@min(
        @as(f32, @floatFromInt(extent.height)),
        @ceil(bounds.y + bounds.h),
    ));
    const unsigned_x: u32 = @intCast(x);
    const unsigned_y: u32 = @intCast(y);
    if (right <= unsigned_x or bottom <= unsigned_y) return;

    const encoded = attachmentColor(color, format);
    const attachment = graphics.vk.VkClearAttachment{
        .aspectMask = graphics.vk.VK_IMAGE_ASPECT_COLOR_BIT,
        .colorAttachment = 0,
        .clearValue = .{ .color = .{ .float32 = encoded } },
    };
    const clear = graphics.vk.VkClearRect{
        .rect = .{
            .offset = .{ .x = x, .y = y },
            .extent = .{
                .width = right - unsigned_x,
                .height = bottom - unsigned_y,
            },
        },
        .baseArrayLayer = 0,
        .layerCount = 1,
    };
    graphics.vk.vkCmdClearAttachments(command_buffer, 1, &attachment, 1, &clear);
}

fn drawState(target: present.FrameTarget, scissor: ?display.Rect) render_state.DrawState {
    const width: f32 = @floatFromInt(target.extent.width);
    const height: f32 = @floatFromInt(target.extent.height);
    return .{
        .mvp = snail.Mat4.ortho(0, width, height, 0, -1, 1),
        .surface = .{
            .pixel_width = target.extent.width,
            .pixel_height = target.extent.height,
            .encoding = if (isSrgbFormat(target.format))
                .srgb
            else
                .srgb_pixels_on_linear_attachment,
            .format = .bgra8_unorm,
        },
        .raster = .{ .subpixel_order = .none },
        .scissor_rect = if (scissor) |rect| pixelRect(rect, target.extent) else null,
    };
}

fn drawSurface(
    self: *Renderer,
    target: present.FrameTarget,
    text: *goop_snail.TextEngine,
    surface: display.PaintCommand.Surface,
    visible: display.Rect,
) !void {
    try drawColorRect(
        self,
        target,
        text,
        surface.bounds,
        surface.color,
        visible,
    );

    const border = @min(
        @max(0, surface.border_width),
        @min(surface.bounds.w, surface.bounds.h) * 0.5,
    );
    if (border > 0 and surface.border_color.a > 0) {
        const b = surface.bounds;
        const edges = [_]display.Rect{
            .{ .x = b.x, .y = b.y, .w = b.w, .h = border },
            .{ .x = b.x, .y = b.y + b.h - border, .w = b.w, .h = border },
            .{ .x = b.x, .y = b.y + border, .w = border, .h = @max(0, b.h - border * 2) },
            .{ .x = b.x + b.w - border, .y = b.y + border, .w = border, .h = @max(0, b.h - border * 2) },
        };
        for (edges) |edge| {
            if (intersect(edge, visible)) |clipped| {
                try drawColorRect(
                    self,
                    target,
                    text,
                    edge,
                    surface.border_color,
                    clipped,
                );
            }
        }
    }
}

const ColorRectMode = enum { skip, replace, blend };

fn colorRectMode(color: display.Color) ColorRectMode {
    return if (color.a == 0)
        .skip
    else if (color.a == 255)
        .replace
    else
        .blend;
}

fn drawColorRect(
    self: *Renderer,
    target: present.FrameTarget,
    text: *goop_snail.TextEngine,
    bounds: display.Rect,
    color: display.Color,
    visible: display.Rect,
) !void {
    switch (colorRectMode(color)) {
        .skip => return,
        .replace => {
            clearRect(
                target.command_buffer,
                visible,
                color,
                target.extent,
                target.format,
            );
            return;
        },
        .blend => {
            var prepared = try text.prepareRect(self.allocator, bounds, color);
            defer prepared.deinit();
            try self.drawPrepared(target, text, &prepared, visible);
        },
    }
}

/// Compact fallback icon vocabulary. Icons stay a renderer concern: the
/// display protocol carries only opaque semantic IDs.
fn drawIcon(
    self: *Renderer,
    target: present.FrameTarget,
    text: *goop_snail.TextEngine,
    icon: display.PaintCommand.Icon,
    visible: display.Rect,
) !void {
    const b = icon.bounds;
    const parts = switch (icon.kind) {
        0 => [_]display.Rect{
            .{ .x = b.x + b.w * 0.07, .y = b.y + b.h * 0.28, .w = b.w * 0.86, .h = b.h * 0.58 },
            .{ .x = b.x + b.w * 0.12, .y = b.y + b.h * 0.18, .w = b.w * 0.34, .h = b.h * 0.2 },
            zero_rect,
            zero_rect,
        },
        1, 2 => [_]display.Rect{
            .{ .x = b.x + b.w * 0.18, .y = b.y + b.h * 0.08, .w = b.w * 0.64, .h = b.h * 0.84 },
            zero_rect,
            zero_rect,
            zero_rect,
        },
        7 => [_]display.Rect{
            .{ .x = b.x + b.w * 0.18, .y = b.y + b.h * 0.22, .w = b.w * 0.64, .h = b.h * 0.1 },
            .{ .x = b.x + b.w * 0.18, .y = b.y + b.h * 0.46, .w = b.w * 0.64, .h = b.h * 0.1 },
            .{ .x = b.x + b.w * 0.18, .y = b.y + b.h * 0.70, .w = b.w * 0.64, .h = b.h * 0.1 },
            zero_rect,
        },
        8 => [_]display.Rect{
            .{ .x = b.x + b.w * 0.18, .y = b.y + b.h * 0.18, .w = b.w * 0.25, .h = b.h * 0.25 },
            .{ .x = b.x + b.w * 0.57, .y = b.y + b.h * 0.18, .w = b.w * 0.25, .h = b.h * 0.25 },
            .{ .x = b.x + b.w * 0.18, .y = b.y + b.h * 0.57, .w = b.w * 0.25, .h = b.h * 0.25 },
            .{ .x = b.x + b.w * 0.57, .y = b.y + b.h * 0.57, .w = b.w * 0.25, .h = b.h * 0.25 },
        },
        else => [_]display.Rect{
            .{ .x = b.x + b.w * 0.2, .y = b.y + b.h * 0.2, .w = b.w * 0.6, .h = b.h * 0.6 },
            zero_rect,
            zero_rect,
            zero_rect,
        },
    };
    for (parts) |part| {
        if (part.w <= 0 or part.h <= 0) continue;
        if (intersect(part, visible)) |clipped| {
            try drawColorRect(
                self,
                target,
                text,
                part,
                icon.color,
                clipped,
            );
        }
    }
}

const zero_rect = display.Rect{ .x = 0, .y = 0, .w = 0, .h = 0 };

fn pixelRect(rect: display.Rect, extent: graphics.vk.VkExtent2D) render_state.PixelRect {
    const x0: i32 = @intFromFloat(@max(0, @floor(rect.x)));
    const y0: i32 = @intFromFloat(@max(0, @floor(rect.y)));
    const x1: u32 = @intFromFloat(@min(
        @as(f32, @floatFromInt(extent.width)),
        @ceil(rect.x + rect.w),
    ));
    const y1: u32 = @intFromFloat(@min(
        @as(f32, @floatFromInt(extent.height)),
        @ceil(rect.y + rect.h),
    ));
    const ux0: u32 = @intCast(x0);
    const uy0: u32 = @intCast(y0);
    return .{
        .x = x0,
        .y = y0,
        .w = x1 -| ux0,
        .h = y1 -| uy0,
    };
}

fn attachmentColor(color: display.Color, format: graphics.vk.VkFormat) [4]f32 {
    if (isSrgbFormat(format)) return goop_snail.linearColor(color);
    const scale: f32 = 1.0 / 255.0;
    return .{
        @as(f32, @floatFromInt(color.r)) * scale,
        @as(f32, @floatFromInt(color.g)) * scale,
        @as(f32, @floatFromInt(color.b)) * scale,
        @as(f32, @floatFromInt(color.a)) * scale,
    };
}

fn isSrgbFormat(format: graphics.vk.VkFormat) bool {
    return format == graphics.vk.VK_FORMAT_B8G8R8A8_SRGB or
        format == graphics.vk.VK_FORMAT_R8G8B8A8_SRGB;
}

test "renderer ownership excludes presentation and platform state" {
    try std.testing.expect(!@hasField(Renderer, "swapchain"));
    try std.testing.expect(!@hasField(Renderer, "surface"));
    try std.testing.expect(!@hasField(Renderer, "window"));
}

test "damage intersection rejects disjoint rectangles" {
    try std.testing.expect(intersect(
        .{ .x = 0, .y = 0, .w = 10, .h = 10 },
        .{ .x = 20, .y = 20, .w = 2, .h = 2 },
    ) == null);
    const overlap = intersect(
        .{ .x = 0, .y = 0, .w = 10, .h = 10 },
        .{ .x = 5, .y = 2, .w = 10, .h = 4 },
    ).?;
    try std.testing.expectEqual(@as(f32, 5), overlap.w);
}

test "surface alpha selects skip, replacement, or blended drawing" {
    try std.testing.expectEqual(
        ColorRectMode.skip,
        colorRectMode(.rgba(20, 30, 40, 0)),
    );
    try std.testing.expectEqual(
        ColorRectMode.blend,
        colorRectMode(.rgba(20, 30, 40, 84)),
    );
    try std.testing.expectEqual(
        ColorRectMode.replace,
        colorRectMode(.rgba(20, 30, 40, 255)),
    );
}
