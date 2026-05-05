const std = @import("std");
const goop = @import("goop");
const snail = @import("snail");

const gl = @cImport({
    @cDefine("GL_GLEXT_PROTOTYPES", "1");
    @cInclude("GL/glcorearb.h");
});

const DrawCommand = goop.DrawCommand;
const DrawList = goop.DrawList;
const PaintCommand = goop.PaintCommand;
const PaintList = goop.PaintList;

const Scissor = struct { x: i32, y: i32, w: i32, h: i32 };

const RunKind = enum { path, text };

const FrameRun = struct {
    kind: RunKind,
    clip: ?Scissor,
    scene: snail.Scene,

    fn deinit(self: *FrameRun) void {
        self.scene.deinit();
        self.* = undefined;
    }
};

pub const Renderer = struct {
    viewport_w: f32,
    viewport_h: f32,
    scale: f32,
    clear_color: [4]f32,
    scissor_stack: [16]Scissor = undefined,
    scissor_depth: u32 = 0,

    // Snail text state
    text_renderer: snail.GlRenderer,
    frame_arena: *std.heap.ArenaAllocator,
    scene: snail.Scene,
    run_kind: ?RunKind = null,
    path_builder: snail.PathPictureBuilder,
    text_builder: snail.TextBlobBuilder,
    frame_path_picture: ?*snail.PathPicture = null,
    frame_path_picture_initialized: bool = false,
    frame_text_blob: ?*snail.TextBlob = null,
    frame_text_blob_initialized: bool = false,
    runs: std.ArrayListUnmanaged(FrameRun) = .empty,
    draw_words: std.ArrayListUnmanaged(u32) = .empty,
    draw_segments: std.ArrayListUnmanaged(snail.DrawSegment) = .empty,
    scratch_buf: []u8,
    text_atlas: *const snail.TextAtlas,
    text_resources: ?snail.PreparedResources = null,
    ascent_units: f32,
    descent_units: f32,

    const ResolvedText = struct {
        text: []const u8,
        width: f32,
    };

    pub fn init(w: u32, h: u32, text_atlas: *const snail.TextAtlas) !Renderer {
        var text_renderer = try snail.GlRenderer.init(std.heap.page_allocator);
        var text_renderer_owned = true;
        errdefer if (text_renderer_owned) text_renderer.deinit();

        const frame_arena = try std.heap.page_allocator.create(std.heap.ArenaAllocator);
        frame_arena.* = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        var frame_arena_owned = true;
        errdefer if (frame_arena_owned) {
            frame_arena.deinit();
            std.heap.page_allocator.destroy(frame_arena);
        };

        const scratch_buf = try std.heap.page_allocator.alloc(u8, 256);
        var scratch_owned = true;
        errdefer if (scratch_owned) std.heap.page_allocator.free(scratch_buf);

        const metrics = fontLineMetrics(text_atlas);

        var result = Renderer{
            .viewport_w = @floatFromInt(w),
            .viewport_h = @floatFromInt(h),
            .scale = 1,
            .clear_color = .{ 0.12, 0.12, 0.12, 1.0 },
            .text_renderer = text_renderer,
            .frame_arena = frame_arena,
            .scene = snail.Scene.init(frame_arena.allocator()),
            .path_builder = snail.PathPictureBuilder.init(frame_arena.allocator()),
            .text_builder = snail.TextBlobBuilder.init(frame_arena.allocator(), text_atlas),
            .scratch_buf = scratch_buf,
            .text_atlas = text_atlas,
            .ascent_units = metrics.ascent,
            .descent_units = metrics.descent,
        };
        text_renderer_owned = false;
        frame_arena_owned = false;
        scratch_owned = false;
        errdefer result.deinit();
        try result.prepareTextResources(text_atlas);
        return result;
    }

    pub fn deinit(self: *Renderer) void {
        self.clearSceneObjects();
        if (self.text_resources) |*prepared| {
            prepared.deinit();
            self.text_resources = null;
        }
        self.path_builder.deinit();
        self.text_builder.deinit();
        self.scene.deinit();
        self.runs.deinit(std.heap.page_allocator);
        self.draw_words.deinit(std.heap.page_allocator);
        self.draw_segments.deinit(std.heap.page_allocator);
        self.text_renderer.deinit();
        self.frame_arena.deinit();
        std.heap.page_allocator.destroy(self.frame_arena);
        std.heap.page_allocator.free(self.scratch_buf);
    }

    pub fn uploadAtlas(self: *Renderer, text_atlas: *const snail.TextAtlas) void {
        self.clearSceneObjects();
        self.text_atlas = text_atlas;
        self.text_builder.deinit();
        self.text_builder = snail.TextBlobBuilder.init(self.frameAllocator(), text_atlas);
        self.prepareTextResources(text_atlas) catch return;
        const metrics = fontLineMetrics(text_atlas);
        self.ascent_units = metrics.ascent;
        self.descent_units = metrics.descent;
    }

    fn frameAllocator(self: *Renderer) std.mem.Allocator {
        return self.frame_arena.allocator();
    }

    fn prepareTextResources(self: *Renderer, text_atlas: *const snail.TextAtlas) !void {
        if (self.text_resources) |*prepared| {
            prepared.deinit();
            self.text_resources = null;
        }
        if (text_atlas.pageCount() == 0) return;

        var resource_entries: [1]snail.ResourceSet.Entry = undefined;
        var resources = snail.ResourceSet.init(&resource_entries);
        try resources.putTextAtlas(.goop_text_atlas, text_atlas);

        const next = try self.text_renderer.uploadResourcesBlocking(std.heap.page_allocator, &resources);
        self.text_resources = next;
    }

    pub fn beginFrame(self: *Renderer, w: u32, h: u32, scale: f32) void {
        self.viewport_w = @floatFromInt(w);
        self.viewport_h = @floatFromInt(h);
        self.scale = scale;
        self.scissor_depth = 0;
        gl.glViewport(0, 0, @intCast(w), @intCast(h));
        gl.glClearColor(self.clear_color[0], self.clear_color[1], self.clear_color[2], self.clear_color[3]);
        gl.glClear(gl.GL_COLOR_BUFFER_BIT);
        gl.glEnable(gl.GL_BLEND);
        gl.glBlendFunc(gl.GL_SRC_ALPHA, gl.GL_ONE_MINUS_SRC_ALPHA);
        gl.glEnable(gl.GL_MULTISAMPLE);
        gl.glDisable(gl.GL_SCISSOR_TEST);
    }

    pub fn render(self: *Renderer, draw_list: DrawList) void {
        self.clearSceneObjects();
        for (draw_list.commands) |cmd| {
            switch (cmd) {
                .rect => |r| {
                    self.addRect(r);
                },
                .text => |t| {
                    self.addText(t);
                },
                .icon => |icon| {
                    self.addIcon(icon);
                },
                .clip => |c| {
                    self.finishSegment() catch {
                        self.clearSceneObjects();
                        return;
                    };
                    self.updateClip(c);
                },
                .custom => {
                    self.finishSegment() catch {
                        self.clearSceneObjects();
                        return;
                    };
                },
            }
        }
        self.finishSegment() catch {
            self.clearSceneObjects();
            return;
        };
        self.drawSegments();
        self.clearSceneObjects();
        gl.glDisable(gl.GL_SCISSOR_TEST);
    }

    pub fn renderPaintList(self: *Renderer, paint_list: PaintList) void {
        self.clearSceneObjects();
        for (paint_list.commands) |cmd| {
            switch (cmd) {
                .box => |box| {
                    self.addRect(box);
                },
                .text => |text| {
                    self.addText(text);
                },
                .icon => |icon| {
                    self.addIcon(icon);
                },
                .clip => |clip| {
                    self.finishSegment() catch {
                        self.clearSceneObjects();
                        return;
                    };
                    self.updateClip(clip);
                },
                .custom => {
                    self.finishSegment() catch {
                        self.clearSceneObjects();
                        return;
                    };
                },
            }
        }
        self.finishSegment() catch {
            self.clearSceneObjects();
            return;
        };
        self.drawSegments();
        self.clearSceneObjects();
        gl.glDisable(gl.GL_SCISSOR_TEST);
    }

    fn addText(self: *Renderer, t: anytype) void {
        const scaled_font_size = t.font_size * self.scale;
        const resolved = self.resolveTextForBounds(
            t.text,
            scaled_font_size,
            t.bounds.w * self.scale,
            t.text_align,
            t.overflow,
        );
        if (resolved.text.len == 0) return;
        const color = colorToVec4(t.color);
        const unscaled_width = if (resolved.width > 0) resolved.width / self.scale else 0;
        const scaled_x = snapToDevicePixels(textXForBounds(t.bounds, unscaled_width, t.text_align), self.scale);
        const baseline = if (comptime @hasField(@TypeOf(t), "baseline_y"))
            t.baseline_y
        else
            self.textBaselineY(t.bounds, t.font_size);
        const scaled_baseline = snapToDevicePixels(baseline, self.scale);
        const before = self.text_builder.glyphCount();
        _ = self.text_builder.addText(.{}, resolved.text, scaled_x, scaled_baseline, scaled_font_size, color) catch return;
        self.appendTextRange(before) catch return;
    }

    fn drawScene(self: *Renderer, prepared: *const snail.PreparedResources, scene: *const snail.Scene) void {
        if (scene.commandCount() == 0) return;
        const options = snail.DrawOptions{
            .mvp = snail.Mat4.ortho(0, self.viewport_w, self.viewport_h, 0, -1, 1),
            .target = .{
                .pixel_width = self.viewport_w,
                .pixel_height = self.viewport_h,
                .subpixel_order = .none,
            },
        };
        const word_count = @max(snail.DrawList.estimate(scene, options), 1);
        const segment_count = @max(snail.DrawList.estimateSegments(scene, options), 1);
        self.draw_words.resize(std.heap.page_allocator, word_count) catch return;
        self.draw_segments.resize(std.heap.page_allocator, segment_count) catch return;

        var draw = snail.DrawList.init(self.draw_words.items, self.draw_segments.items);
        draw.addScene(prepared, scene, options) catch return;
        self.text_renderer.draw(prepared, draw.slice(), options) catch {};
    }

    fn addRect(self: *Renderer, r: anytype) void {
        const rect: snail.Rect = .{
            .x = r.bounds.x * self.scale,
            .y = r.bounds.y * self.scale,
            .w = r.bounds.w * self.scale,
            .h = r.bounds.h * self.scale,
        };
        if (rect.w <= 0 or rect.h <= 0) return;
        const border_width = r.border_width * self.scale;
        const fill_color = colorToVec4(r.color);
        const border_color = colorToVec4(r.border_color);
        const fill: ?snail.FillStyle = if (r.color.a == 0) null else .{ .color = fill_color };
        const stroke: ?snail.StrokeStyle = if (border_width <= 0 or r.border_color.a == 0) null else .{
            .color = border_color,
            .width = border_width,
            .join = .round,
            .placement = .inside,
        };
        if (fill == null and stroke == null) return;
        const before = self.path_builder.shapeCount();
        self.path_builder.addRoundedRect(rect, fill, stroke, r.corner_radius * self.scale, .identity) catch return;
        self.appendPathRange(before) catch return;
    }

    fn addIcon(self: *Renderer, icon: anytype) void {
        if (icon.color.a == 0) return;
        const fill = snail.FillStyle{ .color = colorToVec4(icon.color) };
        const stroke = snail.StrokeStyle{
            .color = colorToVec4(icon.color),
            .width = @max(1.5 * self.scale, 1),
            .join = .round,
            .placement = .inside,
        };
        const rect = scaledSnappedRect(icon.bounds, self.scale);
        if (rect.w <= 0 or rect.h <= 0) return;
        const before = self.path_builder.shapeCount();
        appendIconPicture(&self.path_builder, icon.kind, rect, fill, stroke) catch return;
        self.appendPathRange(before) catch return;
    }

    fn appendTextRange(self: *Renderer, start: usize) !void {
        const end = self.text_builder.glyphCount();
        if (end <= start) return;
        const blob = try self.ensureFrameTextBlob();
        try self.beginRun(.text);
        try self.scene.addText(.{ .blob = blob, .glyphs = .{
            .start = start,
            .count = end - start,
        } });
    }

    fn ensureFrameTextBlob(self: *Renderer) !*snail.TextBlob {
        if (self.frame_text_blob) |blob| return blob;
        const blob = try std.heap.page_allocator.create(snail.TextBlob);
        self.frame_text_blob = blob;
        return blob;
    }

    fn appendPathRange(self: *Renderer, start: usize) !void {
        const end = self.path_builder.shapeCount();
        if (end <= start) return;
        const picture = try self.ensureFramePathPicture();
        try self.beginRun(.path);
        try self.scene.addPath(.{ .picture = picture, .shapes = .{
            .start = start,
            .count = end - start,
        } });
    }

    fn ensureFramePathPicture(self: *Renderer) !*snail.PathPicture {
        if (self.frame_path_picture) |picture| return picture;
        const picture = try std.heap.page_allocator.create(snail.PathPicture);
        self.frame_path_picture = picture;
        return picture;
    }

    fn updateClip(self: *Renderer, c_cmd: anytype) void {
        if (c_cmd.bounds) |bounds| {
            if (self.scissor_depth < self.scissor_stack.len) {
                const x0: i32 = @intFromFloat(@floor(bounds.x * self.scale));
                const y0: i32 = @intFromFloat(@floor(bounds.y * self.scale));
                const x1: i32 = @intFromFloat(@ceil((bounds.x + bounds.w) * self.scale));
                const y1: i32 = @intFromFloat(@ceil((bounds.y + bounds.h) * self.scale));
                const vh: i32 = @intFromFloat(self.viewport_h);
                self.scissor_stack[self.scissor_depth] = .{
                    .x = @max(0, x0),
                    .y = @max(0, vh - y1),
                    .w = @max(0, x1 - x0),
                    .h = @max(0, y1 - y0),
                };
                self.scissor_depth += 1;
            }
        } else {
            if (self.scissor_depth > 0) {
                self.scissor_depth -= 1;
            }
        }
    }

    fn currentClip(self: *const Renderer) ?Scissor {
        if (self.scissor_depth == 0) return null;
        return self.scissor_stack[self.scissor_depth - 1];
    }

    fn applySegmentClip(clip: ?Scissor) void {
        if (clip) |s| {
            gl.glEnable(gl.GL_SCISSOR_TEST);
            gl.glScissor(s.x, s.y, s.w, s.h);
        } else {
            gl.glDisable(gl.GL_SCISSOR_TEST);
        }
    }

    fn beginRun(self: *Renderer, kind: RunKind) !void {
        if (self.run_kind == kind) return;
        try self.finishSegment();
        self.run_kind = kind;
    }

    fn finishSegment(self: *Renderer) !void {
        const kind = self.run_kind orelse return;
        if (self.scene.commandCount() == 0) {
            self.run_kind = null;
            return;
        }
        const scene = self.scene;
        self.scene = snail.Scene.init(self.frameAllocator());
        errdefer {
            self.scene.deinit();
            self.scene = scene;
        }
        try self.runs.append(std.heap.page_allocator, .{
            .kind = kind,
            .clip = self.currentClip(),
            .scene = scene,
        });
        self.run_kind = null;
    }

    fn prepareFramePathResources(self: *Renderer) !?snail.PreparedResources {
        if (self.path_builder.shapeCount() == 0) return null;
        const picture = self.frame_path_picture orelse return null;
        picture.* = try self.path_builder.freeze(self.frameAllocator());
        self.frame_path_picture_initialized = true;

        var resource_entries: [1]snail.ResourceSet.Entry = undefined;
        var resources = snail.ResourceSet.init(&resource_entries);
        try resources.putPathPicture(.goop_frame_paths, picture);
        return try self.text_renderer.uploadResourcesBlocking(std.heap.page_allocator, &resources);
    }

    fn prepareFrameTextBlob(self: *Renderer) !void {
        if (self.text_builder.glyphCount() == 0) return;
        const blob = self.frame_text_blob orelse return;
        blob.* = try self.text_builder.finish();
        self.frame_text_blob_initialized = true;
    }

    fn drawSegments(self: *Renderer) void {
        self.prepareFrameTextBlob() catch return;
        var path_resources = self.prepareFramePathResources() catch return;
        defer if (path_resources) |*prepared| prepared.deinit();

        for (self.runs.items) |*run| {
            applySegmentClip(run.clip);
            switch (run.kind) {
                .path => {
                    if (path_resources) |*prepared| {
                        self.drawScene(prepared, &run.scene);
                    }
                },
                .text => {
                    const prepared = if (self.text_resources) |*resources| resources else continue;
                    self.drawScene(prepared, &run.scene);
                },
            }
        }
    }

    fn colorToVec4(c: goop.Color) [4]f32 {
        return .{
            @as(f32, @floatFromInt(c.r)) / 255.0,
            @as(f32, @floatFromInt(c.g)) / 255.0,
            @as(f32, @floatFromInt(c.b)) / 255.0,
            @as(f32, @floatFromInt(c.a)) / 255.0,
        };
    }

    fn snapToDevicePixels(value: f32, scale: f32) f32 {
        return @round(value * scale);
    }

    fn ensureScratchCapacity(self: *Renderer, len: usize) void {
        if (self.scratch_buf.len >= len) return;
        const next_len = std.math.ceilPowerOfTwo(usize, @max(len, 256)) catch @max(len, 256);
        self.scratch_buf = std.heap.page_allocator.realloc(self.scratch_buf, next_len) catch self.scratch_buf;
    }

    fn measureTextWidth(self: *Renderer, text: []const u8, font_size: f32) f32 {
        return self.text_atlas.measureText(.{}, text, font_size) catch 0;
    }

    fn resolveTextForBounds(
        self: *Renderer,
        text: []const u8,
        font_size: f32,
        max_width: f32,
        text_align: goop.TextAlign,
        overflow: goop.TextOverflow,
    ) ResolvedText {
        switch (overflow) {
            .visible => return .{
                .text = text,
                .width = if (text_align == .start) 0 else self.measureTextWidth(text, font_size),
            },
            .wrap => return .{
                .text = text,
                .width = if (text_align == .start) 0 else self.measureTextWidth(text, font_size),
            },
            .clip => return .{
                .text = text,
                .width = if (text_align == .start) 0 else self.measureTextWidth(text, font_size),
            },
            .ellipsis => {},
        }
        if (text.len == 0 or max_width <= 0) return .{ .text = "", .width = 0 };
        const full_width = self.measureTextWidth(text, font_size);
        if (full_width <= max_width) return .{ .text = text, .width = full_width };

        const ellipsis = "...";
        const ellipsis_width = self.measureTextWidth(ellipsis, font_size);
        if (ellipsis_width > max_width) return .{ .text = "", .width = 0 };

        var utf8_view = std.unicode.Utf8View.init(text) catch return .{ .text = text, .width = full_width };
        var it = utf8_view.iterator();
        var boundaries: std.ArrayListUnmanaged(usize) = .empty;
        defer boundaries.deinit(std.heap.page_allocator);
        while (it.nextCodepointSlice()) |slice| {
            boundaries.append(std.heap.page_allocator, @intFromPtr(slice.ptr) - @intFromPtr(text.ptr) + slice.len) catch break;
        }
        if (boundaries.items.len == 0) return .{ .text = ellipsis, .width = ellipsis_width };

        var low: usize = 0;
        var high: usize = boundaries.items.len;
        var best_width = ellipsis_width;
        while (low < high) {
            const mid = (low + high + 1) / 2;
            const prefix_len = boundaries.items[mid - 1];
            self.ensureScratchCapacity(prefix_len + ellipsis.len);
            @memcpy(self.scratch_buf[0..prefix_len], text[0..prefix_len]);
            @memcpy(self.scratch_buf[prefix_len .. prefix_len + ellipsis.len], ellipsis);
            const candidate_width = self.measureTextWidth(self.scratch_buf[0 .. prefix_len + ellipsis.len], font_size);
            if (candidate_width <= max_width) {
                low = mid;
                best_width = candidate_width;
            } else {
                high = mid - 1;
            }
        }

        if (low == 0) return .{ .text = ellipsis, .width = ellipsis_width };
        const prefix_len = boundaries.items[low - 1];
        self.ensureScratchCapacity(prefix_len + ellipsis.len);
        @memcpy(self.scratch_buf[0..prefix_len], text[0..prefix_len]);
        @memcpy(self.scratch_buf[prefix_len .. prefix_len + ellipsis.len], ellipsis);
        return .{
            .text = self.scratch_buf[0 .. prefix_len + ellipsis.len],
            .width = best_width,
        };
    }

    fn textBaselineY(self: *Renderer, bounds: goop.draw.Rect, font_size: f32) f32 {
        const units_per_em = self.text_atlas.unitsPerEm() catch return bounds.y + font_size;
        const scale = font_size / @as(f32, @floatFromInt(units_per_em));
        const height = (self.ascent_units + self.descent_units) * scale;
        const ascent = self.ascent_units * scale;
        const extra_vertical = @max(bounds.h - height, 0);
        return bounds.y + extra_vertical * 0.5 + ascent;
    }

    fn appendIconPicture(
        builder: *snail.PathPictureBuilder,
        kind: goop.IconKind,
        rect: snail.Rect,
        fill: snail.FillStyle,
        stroke: snail.StrokeStyle,
    ) !void {
        const transform = snail.Transform2D.translate(rect.x, rect.y);
        const local = snail.Rect{ .x = 0, .y = 0, .w = rect.w, .h = rect.h };
        switch (kind) {
            .folder => {
                var path = snail.Path.init(builder.allocator);
                defer path.deinit();
                try path.moveTo(snail.Vec2.new(local.w * 0.07, local.h * 0.84));
                try path.lineTo(snail.Vec2.new(local.w * 0.07, local.h * 0.18));
                try path.lineTo(snail.Vec2.new(local.w * 0.35, local.h * 0.18));
                try path.lineTo(snail.Vec2.new(local.w * 0.44, local.h * 0.28));
                try path.lineTo(snail.Vec2.new(local.w * 0.93, local.h * 0.28));
                try path.lineTo(snail.Vec2.new(local.w * 0.93, local.h * 0.84));
                try path.close();
                try builder.addPath(&path, fill, null, transform);
            },
            .file => {
                const page = snail.Rect{ .x = local.w * 0.14, .y = local.h * 0.08, .w = local.w * 0.72, .h = local.h * 0.84 };
                const fold = snail.Rect{ .x = local.w * 0.62, .y = local.h * 0.08, .w = local.w * 0.24, .h = local.h * 0.24 };
                try addBuilderRoundedRect(builder, page, null, stroke, local.h * 0.08, transform);
                try addBuilderRoundedRect(builder, fold, fill, null, local.h * 0.04, transform);
            },
            .symlink => {
                const page = snail.Rect{ .x = local.w * 0.12, .y = local.h * 0.1, .w = local.w * 0.58, .h = local.h * 0.78 };
                const dot_a = snail.Rect{ .x = local.w * 0.54, .y = local.h * 0.38, .w = local.w * 0.16, .h = local.w * 0.16 };
                const dot_b = snail.Rect{ .x = local.w * 0.7, .y = local.h * 0.22, .w = local.w * 0.16, .h = local.w * 0.16 };
                try addBuilderRoundedRect(builder, page, null, stroke, local.h * 0.08, transform);
                try addBuilderEllipse(builder, dot_a, fill, null, transform);
                try addBuilderEllipse(builder, dot_b, fill, null, transform);
            },
            .home => {
                const body = snail.Rect{ .x = local.w * 0.2, .y = local.h * 0.34, .w = local.w * 0.6, .h = local.h * 0.5 };
                const roof_left = snail.Rect{ .x = local.w * 0.22, .y = local.h * 0.16, .w = local.w * 0.22, .h = local.h * 0.18 };
                const roof_right = snail.Rect{ .x = local.w * 0.56, .y = local.h * 0.16, .w = local.w * 0.22, .h = local.h * 0.18 };
                try addBuilderRoundedRect(builder, body, null, stroke, local.h * 0.06, transform);
                try addBuilderRoundedRect(builder, roof_left, fill, null, local.h * 0.05, transform);
                try addBuilderRoundedRect(builder, roof_right, fill, null, local.h * 0.05, transform);
            },
            .back => {
                const shaft = snail.Rect{ .x = local.w * 0.22, .y = local.h * 0.42, .w = local.w * 0.56, .h = local.h * 0.16 };
                const head = snail.Rect{ .x = local.w * 0.12, .y = local.h * 0.28, .w = local.w * 0.24, .h = local.h * 0.44 };
                try addBuilderRoundedRect(builder, shaft, fill, null, local.h * 0.06, transform);
                try addBuilderRoundedRect(builder, head, fill, null, local.h * 0.06, transform);
            },
            .up => {
                const shaft = snail.Rect{ .x = local.w * 0.42, .y = local.h * 0.24, .w = local.w * 0.16, .h = local.h * 0.56 };
                const head = snail.Rect{ .x = local.w * 0.28, .y = local.h * 0.12, .w = local.w * 0.44, .h = local.h * 0.24 };
                try addBuilderRoundedRect(builder, shaft, fill, null, local.h * 0.06, transform);
                try addBuilderRoundedRect(builder, head, fill, null, local.h * 0.06, transform);
            },
            .refresh => {
                const ring = snail.Rect{ .x = local.w * 0.18, .y = local.h * 0.18, .w = local.w * 0.64, .h = local.h * 0.64 };
                const head = snail.Rect{ .x = local.w * 0.6, .y = local.h * 0.12, .w = local.w * 0.2, .h = local.h * 0.2 };
                try addBuilderEllipse(builder, ring, null, stroke, transform);
                try addBuilderRoundedRect(builder, head, fill, null, local.h * 0.05, transform);
            },
            .list => {
                inline for ([_]f32{ 0.22, 0.46, 0.7 }) |y_ratio| {
                    const line = snail.Rect{ .x = local.w * 0.18, .y = local.h * y_ratio, .w = local.w * 0.64, .h = local.h * 0.1 };
                    try addBuilderRoundedRect(builder, line, fill, null, local.h * 0.04, transform);
                }
            },
            .grid => {
                inline for ([_]f32{ 0.2, 0.56 }) |y_ratio| {
                    inline for ([_]f32{ 0.2, 0.56 }) |x_ratio| {
                        const cell = snail.Rect{ .x = local.w * x_ratio, .y = local.h * y_ratio, .w = local.w * 0.22, .h = local.h * 0.22 };
                        try addBuilderRoundedRect(builder, cell, fill, null, local.h * 0.04, transform);
                    }
                }
            },
            .info => {
                const ring = snail.Rect{ .x = local.w * 0.18, .y = local.h * 0.18, .w = local.w * 0.64, .h = local.h * 0.64 };
                const stem = snail.Rect{ .x = local.w * 0.45, .y = local.h * 0.38, .w = local.w * 0.1, .h = local.h * 0.28 };
                const dot = snail.Rect{ .x = local.w * 0.43, .y = local.h * 0.24, .w = local.w * 0.14, .h = local.w * 0.14 };
                try addBuilderEllipse(builder, ring, null, stroke, transform);
                try addBuilderRoundedRect(builder, stem, fill, null, local.h * 0.03, transform);
                try addBuilderEllipse(builder, dot, fill, null, transform);
            },
        }
    }

    fn addBuilderRoundedRect(
        builder: *snail.PathPictureBuilder,
        rect: snail.Rect,
        fill: ?snail.FillStyle,
        stroke: ?snail.StrokeStyle,
        radius: f32,
        transform: snail.Transform2D,
    ) !void {
        try builder.addRoundedRect(rect, fill, stroke, radius, transform);
    }

    fn addBuilderEllipse(
        builder: *snail.PathPictureBuilder,
        rect: snail.Rect,
        fill: ?snail.FillStyle,
        stroke: ?snail.StrokeStyle,
        transform: snail.Transform2D,
    ) !void {
        try builder.addEllipse(rect, fill, stroke, transform);
    }

    fn clearSceneObjects(self: *Renderer) void {
        for (self.runs.items) |*run| run.deinit();
        self.runs.clearRetainingCapacity();
        self.run_kind = null;
        self.scene.deinit();

        if (self.frame_path_picture) |picture| {
            if (self.frame_path_picture_initialized) picture.deinit();
            std.heap.page_allocator.destroy(picture);
            self.frame_path_picture = null;
            self.frame_path_picture_initialized = false;
        }

        if (self.frame_text_blob) |blob| {
            if (self.frame_text_blob_initialized) blob.deinit();
            std.heap.page_allocator.destroy(blob);
            self.frame_text_blob = null;
            self.frame_text_blob_initialized = false;
        }

        self.path_builder.deinit();
        self.text_builder.deinit();
        _ = self.frame_arena.reset(.retain_capacity);
        self.scene = snail.Scene.init(self.frameAllocator());
        self.path_builder = snail.PathPictureBuilder.init(self.frameAllocator());
        self.text_builder = snail.TextBlobBuilder.init(self.frameAllocator(), self.text_atlas);
    }
};

fn textXForBounds(bounds: goop.draw.Rect, text_width: f32, text_align: goop.TextAlign) f32 {
    return switch (text_align) {
        .start => bounds.x,
        .center => bounds.x + @max(bounds.w - text_width, 0) * 0.5,
        .end => bounds.x + @max(bounds.w - text_width, 0),
    };
}

fn scaledSnappedRect(rect: goop.draw.Rect, scale: f32) snail.Rect {
    const x0 = @round(rect.x * scale);
    const y0 = @round(rect.y * scale);
    const x1 = @round((rect.x + rect.w) * scale);
    const y1 = @round((rect.y + rect.h) * scale);
    return .{
        .x = x0,
        .y = y0,
        .w = @max(x1 - x0, 0),
        .h = @max(y1 - y0, 0),
    };
}

fn fontLineMetrics(text_atlas: *const snail.TextAtlas) struct { ascent: f32, descent: f32 } {
    const metrics = text_atlas.lineMetrics() catch {
        const units_per_em = text_atlas.unitsPerEm() catch 1000;
        return .{
            .ascent = @floatFromInt(units_per_em),
            .descent = 0,
        };
    };
    return .{
        .ascent = @floatFromInt(metrics.ascent),
        .descent = @floatFromInt(@abs(metrics.descent)),
    };
}
