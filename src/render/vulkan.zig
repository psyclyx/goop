//! Vulkan UI renderer.
//!
//! This module consumes backend-neutral Snail records and a caller-supplied
//! frame target. It owns pipelines, buffers, and device-atlas resources, but
//! no Vulkan instance, window-system surface, swapchain, or frame lifecycle.

const std = @import("std");
const graphics = @import("goop_graphics_vulkan");
const visual = @import("goop_visual");
const goop_snail = @import("goop_snail");
const snail = @import("snail");
const DeviceAtlas = @import("vulkan/device_atlas.zig").DeviceAtlas;
const PipelineRenderer = @import("vulkan/renderer.zig").PipelineRenderer;
const target_mod = snail.render.target;
const stock_icon = @import("stock_icon.zig");

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    atlas: DeviceAtlas,
    images: goop_snail.ImageEngine,
    pipelines: PipelineRenderer,
    instances: []goop_snail.Instance,
    batches: []goop_snail.DrawBatch,
    binding: goop_snail.Binding,
    image_binding: goop_snail.Binding,
    uploaded_atlas_identity: goop_snail.AtlasIdentity,
    uploaded_image_atlas_identity: goop_snail.AtlasIdentity,
    attachment_format: graphics.vk.VkFormat,
    max_images: usize,
    max_image_width: u32,
    max_image_height: u32,
    clip_stack: [64]visual.Rect = undefined,
    clip_depth: usize = 0,

    pub const Options = struct {
        frame_slot_count: u32,
        attachment_format: graphics.vk.VkFormat,
        max_instances: usize = 65_536,
        max_bindings: u32 = 8,
        layer_info_height: u32 = 256,
        max_layer_info_height: u32 = 4096,
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
        if (options.frame_slot_count == 0 or options.max_instances == 0 or
            options.max_images == 0 or options.max_image_width == 0 or
            options.max_image_height == 0)
        {
            return error.InvalidCapacity;
        }
        const frame_slot_bytes = std.math.mul(
            usize,
            options.max_instances,
            snail.render.records.BYTES_PER_INSTANCE,
        ) catch return error.InvalidCapacity;

        var images = try goop_snail.ImageEngine.init(allocator, text.pool());
        errdefer images.deinit();

        var atlas = try DeviceAtlas.init(allocator, device_context, text.pool(), .{
            .max_bindings = options.max_bindings,
            .layer_info_height = options.layer_info_height,
            .max_layer_info_height = options.max_layer_info_height,
            .max_images = options.max_images,
            .max_image_width = options.max_image_width,
            .max_image_height = options.max_image_height,
        });
        errdefer atlas.deinit();

        var bindings: [2]goop_snail.Binding = undefined;
        atlas.upload(allocator, &.{ text.atlas(), images.atlas() }, &bindings) catch |err| switch (err) {
            error.NoFreeLayerInfoRows => try atlas.rebuild(
                allocator,
                &.{ text.atlas(), images.atlas() },
                &bindings,
            ),
            else => return err,
        };

        var pipelines = try PipelineRenderer.init(
            device_context,
            render_pass,
            atlas.descriptorSetLayout(),
            frame_slot_bytes,
            options.frame_slot_count,
        );
        errdefer pipelines.deinit();

        const instances = try allocator.alloc(goop_snail.Instance, options.max_instances);
        errdefer allocator.free(instances);
        const batches = try allocator.alloc(goop_snail.DrawBatch, options.max_instances);
        errdefer allocator.free(batches);

        return .{
            .allocator = allocator,
            .atlas = atlas,
            .images = images,
            .pipelines = pipelines,
            .instances = instances,
            .batches = batches,
            .binding = bindings[0],
            .image_binding = bindings[1],
            .uploaded_atlas_identity = text.atlasIdentity(),
            .uploaded_image_atlas_identity = images.atlasIdentity(),
            .attachment_format = options.attachment_format,
            .max_images = options.max_images,
            .max_image_width = options.max_image_width,
            .max_image_height = options.max_image_height,
        };
    }

    pub fn deinit(self: *Renderer) void {
        self.pipelines.deinit();
        self.atlas.deinit();
        self.images.deinit();
        self.allocator.free(self.batches);
        self.allocator.free(self.instances);
        self.* = undefined;
    }

    /// Begin replay of a stream prepared by `prepareVisuals`. This is private:
    /// prepared text is tied to the exact retained operation stream and must
    /// not be paired by convention with arbitrary direct-look output.
    fn beginPreparedReplay(
        self: *Renderer,
        target: graphics.RenderTarget,
        text: *goop_snail.TextEngine,
        prepared: *const PreparedVisuals,
    ) !Encoder {
        try self.pipelines.beginFrame(target.frame_slot);
        self.clip_depth = 0;
        return .{
            .renderer = self,
            .target = target,
            .text_engine = text,
            .prepared = prepared,
            .scale = prepared.logical_to_physical_scale,
            .frame_bounds = .{
                .x = 0,
                .y = 0,
                .w = @floatFromInt(target.extent.width),
                .h = @floatFromInt(target.extent.height),
            },
        };
    }

    /// Allocation-free Vulkan replay of the exact retained stream captured by
    /// `prepareVisuals`. Game renderers can implement `goop_visual`'s generic
    /// structural capability directly; this Snail backend requires its named
    /// preparation and upload phases first.
    pub fn drawPreparedVisuals(
        self: *Renderer,
        target: graphics.RenderTarget,
        text: *goop_snail.TextEngine,
        prepared: *const PreparedVisuals,
    ) !void {
        if (!std.meta.eql(text.atlasIdentity(), prepared.atlas_identity) or
            !std.meta.eql(self.images.atlasIdentity(), prepared.image_atlas_identity))
        {
            return error.PreparedVisualsStale;
        }
        if (!std.meta.eql(self.uploaded_atlas_identity, prepared.atlas_identity)) {
            return error.VisualResourcesNotUpdated;
        }
        if (!std.meta.eql(self.uploaded_image_atlas_identity, prepared.image_atlas_identity)) {
            return error.VisualResourcesNotUpdated;
        }
        var encoder = try self.beginPreparedReplay(target, text, prepared);
        try visual.emitAll(&encoder, prepared.commands);
        try encoder.finish();
    }

    pub fn prepareVisuals(
        self: *Renderer,
        allocator: std.mem.Allocator,
        text_engine: *goop_snail.TextEngine,
        commands: []const visual.Operation,
        logical_to_physical_scale: f32,
    ) !PreparedVisuals {
        return prepareVisualOperations(
            self,
            allocator,
            text_engine,
            commands,
            logical_to_physical_scale,
        );
    }

    /// Explicit GPU resource update phase. The current Snail Vulkan upload is
    /// synchronous, so callers should invoke this before acquiring/beginning a
    /// frame rather than discovering a queue wait while encoding text.
    pub fn updateVisualResources(self: *Renderer, text: *const goop_snail.TextEngine) !void {
        const identity = text.atlasIdentity();
        if (!std.meta.eql(identity, self.uploaded_atlas_identity)) {
            self.binding = self.updateAtlasBinding(self.binding, text.atlas()) catch |err| switch (err) {
                error.NoFreeLayerInfoRows => {
                    try self.rebuildAtlasBindings(text);
                    return;
                },
                else => return err,
            };
            self.uploaded_atlas_identity = identity;
        }
        const image_identity = self.images.atlasIdentity();
        if (!std.meta.eql(image_identity, self.uploaded_image_atlas_identity)) {
            self.image_binding = self.updateAtlasBinding(self.image_binding, self.images.atlas()) catch |err| switch (err) {
                error.NoFreeLayerInfoRows => {
                    try self.rebuildAtlasBindings(text);
                    return;
                },
                else => return err,
            };
            self.uploaded_image_atlas_identity = image_identity;
        }
    }

    fn rebuildAtlasBindings(
        self: *Renderer,
        text: *const goop_snail.TextEngine,
    ) !void {
        var bindings: [2]goop_snail.Binding = undefined;
        try self.atlas.rebuild(
            self.allocator,
            &.{ text.atlas(), self.images.atlas() },
            &bindings,
        );
        self.binding = bindings[0];
        self.image_binding = bindings[1];
        self.uploaded_atlas_identity = text.atlasIdentity();
        self.uploaded_image_atlas_identity = self.images.atlasIdentity();
    }

    fn updateAtlasBinding(
        self: *Renderer,
        previous: goop_snail.Binding,
        atlas: *const goop_snail.Atlas,
    ) !goop_snail.Binding {
        return self.atlas.uploadDelta(
            self.allocator,
            previous,
            atlas,
        ) catch |upload_error| switch (upload_error) {
            // Snail's planner only deltas exact/direct-child snapshots:
            // text measurement during layout extends the atlas ahead of the
            // binding by several snapshots, so a frame's first draw after
            // shaping is a skipped descendant and needs a fresh binding —
            // the same fallback as an outgrown side-data reservation.
            error.NoLayerInfoRoomToGrow, error.NoImageRoomToGrow, error.IncompatibleSnapshot => replacement: {
                self.atlas.release(previous);
                var bindings: [1]goop_snail.Binding = undefined;
                try self.atlas.upload(self.allocator, &.{atlas}, &bindings);
                break :replacement bindings[0];
            },
            else => return upload_error,
        };
    }

    fn drawPrepared(
        self: *Renderer,
        target: graphics.RenderTarget,
        text: *const goop_snail.TextEngine,
        prepared: *const goop_snail.PreparedText,
        scissor: ?visual.Rect,
    ) !void {
        try self.drawShapes(target, text, prepared.shapes, scissor);
    }

    fn drawImage(
        self: *Renderer,
        target: graphics.RenderTarget,
        prepared: *const goop_snail.PreparedText,
        scissor: ?visual.Rect,
    ) !void {
        try self.drawShapesWith(target, &self.images, self.image_binding, prepared.shapes, scissor);
    }

    fn drawShapes(
        self: *Renderer,
        target: graphics.RenderTarget,
        text: *const goop_snail.TextEngine,
        shapes: []const snail.Shape,
        scissor: ?visual.Rect,
    ) !void {
        try self.drawShapesWith(target, text, self.binding, shapes, scissor);
    }

    fn drawShapesWith(
        self: *Renderer,
        target: graphics.RenderTarget,
        source: anytype,
        binding: goop_snail.Binding,
        shapes: []const snail.Shape,
        scissor: ?visual.Rect,
    ) !void {
        var instance_len: usize = 0;
        var batch_len: usize = 0;
        _ = try source.emitShapes(
            binding,
            shapes,
            self.instances,
            self.batches,
            &instance_len,
            &batch_len,
        );

        try self.pipelines.render(
            target.command_buffer,
            self.atlas.descriptorSet(),
            drawState(target, self.attachment_format, scissor),
            self.atlas.atlasPageTexels(),
            self.instances[0..instance_len],
            self.batches[0..batch_len],
        );
    }
};

/// Explicitly allocated/shaped CPU resources for one visual stream. Preparing
/// may extend the Snail atlas but performs no Vulkan work; upload is a separate
/// `Renderer.updateVisualResources` call.
pub const PreparedVisuals = struct {
    allocator: std.mem.Allocator,
    /// Borrowed exact stream. It and all borrowed text bytes must outlive this
    /// preparation and its draw call.
    commands: []const visual.Operation,
    text_runs: []goop_snail.PreparedText,
    image_runs: []goop_snail.PreparedText,
    logical_to_physical_scale: f32,
    atlas_identity: goop_snail.AtlasIdentity,
    image_atlas_identity: goop_snail.AtlasIdentity,

    pub fn deinit(self: *PreparedVisuals) void {
        for (self.text_runs) |*run| run.deinit();
        for (self.image_runs) |*run| run.deinit();
        self.allocator.free(self.text_runs);
        self.allocator.free(self.image_runs);
        self.* = undefined;
    }
};

/// Shape and place every text operation. Allocation and shaping are explicit
/// in this API and complete before Vulkan command encoding starts.
fn prepareVisualOperations(
    renderer: *Renderer,
    allocator: std.mem.Allocator,
    text_engine: *goop_snail.TextEngine,
    commands: []const visual.Operation,
    logical_to_physical_scale: f32,
) !PreparedVisuals {
    if (!std.math.isFinite(logical_to_physical_scale) or logical_to_physical_scale <= 0) {
        return error.InvalidVisualScale;
    }

    var text_count: usize = 0;
    var image_count: usize = 0;
    for (commands) |command| switch (command) {
        .text => text_count += 1,
        .image => image_count += 1,
        .custom => return error.UnsupportedCustomVisual,
        else => {},
    };

    const image_sources = try allocator.alloc(visual.ImageSource, image_count);
    defer allocator.free(image_sources);
    var image_source_len: usize = 0;
    var unique_image_count: usize = 0;
    for (commands) |command| switch (command) {
        .image => |value| {
            try value.source.validate();
            if (value.source.width > renderer.max_image_width or
                value.source.height > renderer.max_image_height)
            {
                return error.ImageDimensionsExceedRendererCapacity;
            }
            var seen = false;
            for (image_sources[0..image_source_len]) |existing| {
                if (!std.meta.eql(existing.id, value.source.id)) continue;
                if (existing.width != value.source.width or existing.height != value.source.height) {
                    return error.ResourceIdentityCollision;
                }
                seen = true;
                break;
            }
            if (!seen) unique_image_count += 1;
            image_sources[image_source_len] = value.source;
            image_source_len += 1;
        },
        else => {},
    };
    if (unique_image_count > renderer.max_images) return error.ImageCountExceedsRendererCapacity;

    const runs = try allocator.alloc(goop_snail.PreparedText, text_count);
    var initialized: usize = 0;
    errdefer {
        for (runs[0..initialized]) |*run| run.deinit();
        allocator.free(runs);
    }

    const image_runs = try allocator.alloc(goop_snail.PreparedText, image_count);
    var initialized_images: usize = 0;
    errdefer {
        for (image_runs[0..initialized_images]) |*run| run.deinit();
        allocator.free(image_runs);
    }

    try renderer.images.syncResources(image_sources);

    for (commands) |command| switch (command) {
        .text => |logical| {
            const value = visual.Text{
                .bounds = scaleRect(logical.bounds, logical_to_physical_scale),
                .text = logical.text,
                .color = logical.color,
                .font_size = logical.font_size * logical_to_physical_scale,
                .text_align = logical.text_align,
                .overflow = logical.overflow,
            };
            // Alignment is a paint-time device fact: hinted advances can
            // differ from renderer-independent layout metrics at this ppem.
            const metrics = try text_engine.prepareMetrics(
                value.text,
                value.font_size,
                .identity,
            );
            const x = switch (value.text_align) {
                .start => value.bounds.x,
                .center => value.bounds.x + @max(0, value.bounds.w - metrics.width) * 0.5,
                .end => value.bounds.x + @max(0, value.bounds.w - metrics.width),
            };
            const baseline = value.bounds.y +
                @max(0, value.bounds.h - metrics.height()) * 0.5 + metrics.ascent;
            runs[initialized] = try text_engine.prepareText(
                allocator,
                value.text,
                .{
                    .baseline = .{ .x = x, .y = baseline },
                    // Visual commands were converted to physical pixels
                    // above, so scene coordinates already are device pixels.
                    .world_to_pixel = .identity,
                },
                value.font_size,
                value.color,
            );
            initialized += 1;
        },
        .image => |logical| {
            var physical = logical;
            physical.bounds = scaleRect(logical.bounds, logical_to_physical_scale);
            image_runs[initialized_images] = try renderer.images.prepareImage(allocator, physical);
            initialized_images += 1;
        },
        else => {},
    };

    return .{
        .allocator = allocator,
        .commands = commands,
        .text_runs = runs,
        .image_runs = image_runs,
        .logical_to_physical_scale = logical_to_physical_scale,
        .atlas_identity = text_engine.atlasIdentity(),
        .image_atlas_identity = renderer.images.atlasIdentity(),
    };
}

/// Internal allocation-free replay encoder. Its text cursor is intentionally
/// coupled to `PreparedVisuals`; it is not the generic direct-look seam.
const Encoder = struct {
    renderer: *Renderer,
    target: graphics.RenderTarget,
    text_engine: *goop_snail.TextEngine,
    prepared: *const PreparedVisuals,
    scale: f32,
    frame_bounds: visual.Rect,
    text_index: usize = 0,
    image_index: usize = 0,

    pub fn finish(self: *Encoder) !void {
        if (self.renderer.clip_depth != 0) return error.UnbalancedClipStack;
        if (self.text_index != self.prepared.text_runs.len) {
            return error.PreparedVisualTextMismatch;
        }
        if (self.image_index != self.prepared.image_runs.len) {
            return error.PreparedVisualImageMismatch;
        }
    }

    pub fn pushClip(self: *Encoder, logical_bounds: visual.Rect) !void {
        if (self.renderer.clip_depth == self.renderer.clip_stack.len) {
            return error.ClipStackOverflow;
        }
        const bounds = scaleRect(logical_bounds, self.scale);
        const effective = if (self.renderer.clip_depth > 0)
            intersect(self.renderer.clip_stack[self.renderer.clip_depth - 1], bounds) orelse zero_rect
        else
            bounds;
        self.renderer.clip_stack[self.renderer.clip_depth] = effective;
        self.renderer.clip_depth += 1;
    }

    pub fn popClip(self: *Encoder) !void {
        if (self.renderer.clip_depth == 0) return error.UnbalancedClipStack;
        self.renderer.clip_depth -= 1;
    }

    pub fn surface(self: *Encoder, logical: visual.Surface) !void {
        const value = visual.Surface{
            .bounds = scaleRect(logical.bounds, self.scale),
            .color = logical.color,
            .border_color = logical.border_color,
            .border_width = logical.border_width * self.scale,
            .corner_radius = logical.corner_radius * self.scale,
        };
        const clipped = self.visible(value.bounds) orelse return;
        try drawSurface(self.renderer, self.target, self.text_engine, value, clipped);
    }

    pub fn text(self: *Encoder, logical: visual.Text) !void {
        if (self.text_index >= self.prepared.text_runs.len) {
            return error.PreparedVisualTextMismatch;
        }
        const bounds = scaleRect(logical.bounds, self.scale);
        const prepared = &self.prepared.text_runs[self.text_index];
        self.text_index += 1;
        const clipped = self.visible(bounds) orelse return;
        try self.renderer.drawPrepared(self.target, self.text_engine, prepared, clipped);
    }

    pub fn icon(self: *Encoder, logical: visual.Icon) !void {
        const value = visual.Icon{
            .bounds = scaleRect(logical.bounds, self.scale),
            .kind = logical.kind,
            .color = logical.color,
        };
        const clipped = self.visible(value.bounds) orelse return;
        try drawIcon(self.renderer, self.target, self.text_engine, value, clipped);
    }

    pub fn image(self: *Encoder, logical: visual.Image) !void {
        if (self.image_index >= self.prepared.image_runs.len) {
            return error.PreparedVisualImageMismatch;
        }
        const prepared = &self.prepared.image_runs[self.image_index];
        self.image_index += 1;
        const clipped = self.visible(scaleRect(logical.bounds, self.scale)) orelse return;
        try self.renderer.drawImage(self.target, prepared, clipped);
    }

    pub fn custom(_: *Encoder, _: visual.Custom) !void {
        return error.UnsupportedCustomVisual;
    }

    fn visible(self: *const Encoder, bounds: visual.Rect) ?visual.Rect {
        var result = intersect(bounds, self.frame_bounds) orelse return null;
        if (self.renderer.clip_depth > 0) {
            result = intersect(
                result,
                self.renderer.clip_stack[self.renderer.clip_depth - 1],
            ) orelse return null;
        }
        return result;
    }
};

fn scaleRect(rect: visual.Rect, scale: f32) visual.Rect {
    return .{
        .x = rect.x * scale,
        .y = rect.y * scale,
        .w = rect.w * scale,
        .h = rect.h * scale,
    };
}

fn intersect(a: visual.Rect, b: visual.Rect) ?visual.Rect {
    const left = @max(a.x, b.x);
    const top = @max(a.y, b.y);
    const right = @min(a.x + a.w, b.x + b.w);
    const bottom = @min(a.y + a.h, b.y + b.h);
    if (right <= left or bottom <= top) return null;
    return .{ .x = left, .y = top, .w = right - left, .h = bottom - top };
}

fn clearRect(
    command_buffer: graphics.vk.VkCommandBuffer,
    bounds: visual.Rect,
    color: visual.Color,
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

fn drawState(
    target: graphics.RenderTarget,
    attachment_format: graphics.vk.VkFormat,
    scissor: ?visual.Rect,
) target_mod.DrawState {
    const width: f32 = @floatFromInt(target.extent.width);
    const height: f32 = @floatFromInt(target.extent.height);
    return .{
        .mvp = snail.Mat4.ortho(0, width, height, 0, -1, 1),
        .surface = .{
            .pixel_width = target.extent.width,
            .pixel_height = target.extent.height,
            .encoding = if (isSrgbFormat(attachment_format))
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
    target: graphics.RenderTarget,
    text: *goop_snail.TextEngine,
    surface: visual.Surface,
    visible: visual.Rect,
) !void {
    const border = @min(
        @max(0, surface.border_width),
        @min(surface.bounds.w, surface.bounds.h) * 0.5,
    );
    if (border > 0 and surface.border_color.a > 0) {
        try drawRoundedColorRect(self, target, text, surface.bounds, surface.border_color, surface.corner_radius, visible);
        const inner = visual.Rect{
            .x = surface.bounds.x + border,
            .y = surface.bounds.y + border,
            .w = @max(0, surface.bounds.w - border * 2),
            .h = @max(0, surface.bounds.h - border * 2),
        };
        try drawRoundedColorRect(self, target, text, inner, surface.color, @max(0, surface.corner_radius - border), visible);
    } else {
        try drawRoundedColorRect(self, target, text, surface.bounds, surface.color, surface.corner_radius, visible);
    }
}

fn drawRoundedColorRect(
    self: *Renderer,
    target: graphics.RenderTarget,
    text: *goop_snail.TextEngine,
    bounds: visual.Rect,
    color: visual.Color,
    requested_radius: f32,
    visible: visual.Rect,
) !void {
    if (color.a == 0 or bounds.w <= 0 or bounds.h <= 0) return;
    const radius = @min(@max(requested_radius, 0), @min(bounds.w, bounds.h) * 0.5);
    if (radius < 0.75) {
        if (intersect(bounds, visible)) |clipped| try drawColorRect(self, target, text, bounds, color, clipped);
        return;
    }

    const bands: usize = @intFromFloat(@ceil(radius));
    for (0..bands) |index| {
        const y_offset = @min(@as(f32, @floatFromInt(index)), radius);
        const band_height = @min(@as(f32, 1), radius - y_offset);
        if (band_height <= 0) continue;
        const inset = roundedBandInset(radius, y_offset + band_height * 0.5);
        const width = @max(0, bounds.w - inset * 2);
        const top = visual.Rect{ .x = bounds.x + inset, .y = bounds.y + y_offset, .w = width, .h = band_height };
        const bottom = visual.Rect{ .x = bounds.x + inset, .y = bounds.y + bounds.h - y_offset - band_height, .w = width, .h = band_height };
        if (intersect(top, visible)) |clipped| try drawColorRect(self, target, text, top, color, clipped);
        if (intersect(bottom, visible)) |clipped| try drawColorRect(self, target, text, bottom, color, clipped);
    }
    const middle = visual.Rect{
        .x = bounds.x,
        .y = bounds.y + radius,
        .w = bounds.w,
        .h = @max(0, bounds.h - radius * 2),
    };
    if (intersect(middle, visible)) |clipped| try drawColorRect(self, target, text, middle, color, clipped);
}

fn roundedBandInset(radius: f32, y_from_edge: f32) f32 {
    if (radius <= 0) return 0;
    const dy = std.math.clamp(radius - y_from_edge, 0, radius);
    return radius - @sqrt(@max(0, radius * radius - dy * dy));
}

const ColorRectMode = enum { skip, replace, blend };

fn colorRectMode(color: visual.Color) ColorRectMode {
    return if (color.a == 0)
        .skip
    else if (color.a == 255)
        .replace
    else
        .blend;
}

fn drawColorRect(
    self: *Renderer,
    target: graphics.RenderTarget,
    text: *goop_snail.TextEngine,
    bounds: visual.Rect,
    color: visual.Color,
    visible: visual.Rect,
) !void {
    switch (colorRectMode(color)) {
        .skip => return,
        .replace => {
            clearRect(
                target.command_buffer,
                visible,
                color,
                target.extent,
                self.attachment_format,
            );
            return;
        },
        .blend => {
            const shapes = [1]snail.Shape{text.rectShape(bounds, color)};
            try self.drawShapes(target, text, &shapes, visible);
        },
    }
}

/// Compact fallback icon vocabulary. Icons stay a renderer concern: the
/// visual protocol carries only opaque semantic IDs.
fn drawIcon(
    self: *Renderer,
    target: graphics.RenderTarget,
    text: *goop_snail.TextEngine,
    icon: visual.Icon,
    visible: visual.Rect,
) !void {
    const b = icon.bounds;
    for (stock_icon.geometry(icon.kind)) |definition| {
        const normalized = definition.rect;
        const part = visual.Rect{
            .x = b.x + b.w * normalized.x,
            .y = b.y + b.h * normalized.y,
            .w = b.w * normalized.w,
            .h = b.h * normalized.h,
        };
        if (part.w <= 0 or part.h <= 0) continue;
        if (intersect(part, visible)) |clipped| {
            const part_color = switch (definition.tone) {
                .base => icon.color,
                .detail => iconDetailColor(icon.color),
                .highlight => iconHighlightColor(icon.color),
                .paper => iconPaperColor(icon.color),
            };
            try drawColorRect(
                self,
                target,
                text,
                part,
                part_color,
                clipped,
            );
        }
    }
}

fn iconPaperColor(color: visual.Color) visual.Color {
    return .{
        .r = @intCast((@as(u16, color.r) + 255 * 5) / 6),
        .g = @intCast((@as(u16, color.g) + 255 * 5) / 6),
        .b = @intCast((@as(u16, color.b) + 255 * 5) / 6),
        .a = color.a,
    };
}

fn iconDetailColor(color: visual.Color) visual.Color {
    return .{
        .r = @intCast(@as(u16, color.r) * 3 / 5),
        .g = @intCast(@as(u16, color.g) * 3 / 5),
        .b = @intCast(@as(u16, color.b) * 3 / 5),
        .a = color.a,
    };
}

fn iconHighlightColor(color: visual.Color) visual.Color {
    return .{
        .r = @intCast((@as(u16, color.r) * 3 + 255) / 4),
        .g = @intCast((@as(u16, color.g) * 3 + 255) / 4),
        .b = @intCast((@as(u16, color.b) * 3 + 255) / 4),
        .a = color.a,
    };
}

const zero_rect = visual.Rect{ .x = 0, .y = 0, .w = 0, .h = 0 };

fn pixelRect(rect: visual.Rect, extent: graphics.vk.VkExtent2D) target_mod.PixelRect {
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

fn attachmentColor(color: visual.Color, format: graphics.vk.VkFormat) [4]f32 {
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

test "rounded rectangle bands remain symmetric and bounded" {
    for (1..33) |radius_int| {
        const radius: f32 = @floatFromInt(radius_int);
        var previous = radius;
        for (0..radius_int) |band| {
            const inset = roundedBandInset(radius, @as(f32, @floatFromInt(band)) + 0.5);
            try std.testing.expect(inset >= 0 and inset <= radius);
            try std.testing.expect(inset <= previous + 0.0001);
            previous = inset;
        }
    }
}

test "logical-to-physical scaling is explicit and complete" {
    const scaled = scaleRect(.{ .x = 2, .y = 3, .w = 5, .h = 7 }, 1.5);
    try std.testing.expectEqual(@as(f32, 3), scaled.x);
    try std.testing.expectEqual(@as(f32, 4.5), scaled.y);
    try std.testing.expectEqual(@as(f32, 7.5), scaled.w);
    try std.testing.expectEqual(@as(f32, 10.5), scaled.h);
}
