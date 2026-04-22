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

const MAX_GLYPHS = 4096;
const VERTEX_BUF_LEN = MAX_GLYPHS * snail.FLOATS_PER_GLYPH;
const MAX_VECTOR_PRIMITIVES = 2048;
const VECTOR_BUF_LEN = MAX_VECTOR_PRIMITIVES * snail.VECTOR_FLOATS_PER_PRIMITIVE;

pub const Renderer = struct {
    viewport_w: f32,
    viewport_h: f32,
    scale: f32,
    clear_color: [4]f32,
    scissor_stack: [16]Scissor = undefined,
    scissor_depth: u32 = 0,

    // Snail text state
    text_renderer: snail.Renderer,
    text_batch: snail.Batch,
    vertex_buf: []f32,
    measure_buf: []f32,
    scratch_buf: []u8,
    vector_batch: snail.VectorBatch,
    vector_buf: []f32,
    font: *const snail.Font,
    atlas_view: snail.AtlasView,
    ascent_units: f32,
    descent_units: f32,

    const Scissor = struct { x: i32, y: i32, w: i32, h: i32 };
    const ResolvedText = struct {
        text: []const u8,
        width: f32,
    };

    pub fn init(w: u32, h: u32, font: *const snail.Font, atlas: *const snail.Atlas) !Renderer {
        var text_renderer = try snail.Renderer.init();
        const atlas_view = text_renderer.uploadAtlas(atlas);

        const vertex_buf = try std.heap.page_allocator.alloc(f32, VERTEX_BUF_LEN);
        const measure_buf = try std.heap.page_allocator.alloc(f32, VERTEX_BUF_LEN);
        const scratch_buf = try std.heap.page_allocator.alloc(u8, 256);
        const vector_buf = try std.heap.page_allocator.alloc(f32, VECTOR_BUF_LEN);
        const metrics = fontLineMetrics(font);

        return .{
            .viewport_w = @floatFromInt(w),
            .viewport_h = @floatFromInt(h),
            .scale = 1,
            .clear_color = .{ 0.12, 0.12, 0.12, 1.0 },
            .text_renderer = text_renderer,
            .text_batch = snail.Batch.init(vertex_buf),
            .vertex_buf = vertex_buf,
            .measure_buf = measure_buf,
            .scratch_buf = scratch_buf,
            .vector_batch = snail.VectorBatch.init(vector_buf),
            .vector_buf = vector_buf,
            .font = font,
            .atlas_view = atlas_view,
            .ascent_units = metrics.ascent,
            .descent_units = metrics.descent,
        };
    }

    pub fn deinit(self: *Renderer) void {
        self.text_renderer.deinit();
        std.heap.page_allocator.free(self.vertex_buf);
        std.heap.page_allocator.free(self.measure_buf);
        std.heap.page_allocator.free(self.scratch_buf);
        std.heap.page_allocator.free(self.vector_buf);
    }

    pub fn uploadAtlas(self: *Renderer, atlas: *const snail.Atlas) void {
        self.atlas_view = self.text_renderer.uploadAtlas(atlas);
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
        for (draw_list.commands) |cmd| {
            switch (cmd) {
                .rect => |r| {
                    self.flushText();
                    self.addRect(r);
                },
                .text => |t| {
                    self.flushVector();
                    self.addText(t);
                },
                .icon => |icon| {
                    self.flushText();
                    self.addIcon(icon);
                },
                .clip => |c| {
                    self.flushVector();
                    self.flushText();
                    self.applyClip(c);
                },
                .custom => {
                    self.flushVector();
                    self.flushText();
                },
            }
        }
        self.flushVector();
        self.flushText();

        gl.glDisable(gl.GL_SCISSOR_TEST);
    }

    pub fn renderPaintList(self: *Renderer, paint_list: PaintList) void {
        for (paint_list.commands) |cmd| {
            switch (cmd) {
                .box => |box| {
                    self.flushText();
                    self.addRect(box);
                },
                .text => |text| {
                    self.flushVector();
                    self.addText(text);
                },
                .icon => |icon| {
                    self.flushText();
                    self.addIcon(icon);
                },
                .clip => |clip| {
                    self.flushVector();
                    self.flushText();
                    self.applyClip(clip);
                },
                .custom => {
                    self.flushVector();
                    self.flushText();
                },
            }
        }
        self.flushVector();
        self.flushText();
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
        const baseline_y = @round(self.viewport_h - scaled_baseline);
        _ = self.text_batch.addString(&self.atlas_view, self.font, resolved.text, scaled_x, baseline_y, scaled_font_size, color);
    }

    fn flushText(self: *Renderer) void {
        if (self.text_batch.glyphCount() == 0) return;

        // Y-up orthographic projection — snail's glyph quads use Y-up coords
        const mvp = snail.Mat4.ortho(0, self.viewport_w, 0, self.viewport_h, -1, 1);

        self.text_renderer.beginFrame();
        self.text_renderer.draw(self.text_batch.slice(), mvp, self.viewport_w, self.viewport_h);
        self.text_batch.reset();
    }

    fn addRect(self: *Renderer, r: anytype) void {
        const rect: snail.VectorRect = .{
            .x = r.bounds.x * self.scale,
            .y = r.bounds.y * self.scale,
            .w = r.bounds.w * self.scale,
            .h = r.bounds.h * self.scale,
        };
        const border_width = r.border_width * self.scale;
        const fill_color = colorToVec4(r.color);
        const border_color = colorToVec4(r.border_color);
        const fill: ?snail.VectorFillStyle = if (r.color.a == 0) null else .{ .color = fill_color };
        const stroke: ?snail.VectorStrokeStyle = if (border_width <= 0 or r.border_color.a == 0) null else .{
            .color = border_color,
            .width = border_width,
        };
        if (!self.vector_batch.addRoundedRectStyled(rect, fill, stroke, r.corner_radius * self.scale, .identity)) {
            self.flushVector();
            _ = self.vector_batch.addRoundedRectStyled(rect, fill, stroke, r.corner_radius * self.scale, .identity);
        }
    }

    fn addIcon(self: *Renderer, icon: anytype) void {
        const fill = snail.VectorFillStyle{ .color = colorToVec4(icon.color) };
        const stroke = snail.VectorStrokeStyle{ .color = colorToVec4(icon.color), .width = @max(1.5 * self.scale, 1) };
        const rect = scaledRect(icon.bounds, self.scale);
        switch (icon.kind) {
            .folder => {
                const tab = snail.VectorRect{ .x = rect.x + rect.w * 0.08, .y = rect.y + rect.h * 0.08, .w = rect.w * 0.34, .h = rect.h * 0.22 };
                const body = snail.VectorRect{ .x = rect.x + rect.w * 0.05, .y = rect.y + rect.h * 0.22, .w = rect.w * 0.9, .h = rect.h * 0.63 };
                self.addRoundedRect(tab, fill, null, rect.h * 0.08);
                self.addRoundedRect(body, fill, null, rect.h * 0.1);
            },
            .file => {
                const page = snail.VectorRect{ .x = rect.x + rect.w * 0.14, .y = rect.y + rect.h * 0.08, .w = rect.w * 0.72, .h = rect.h * 0.84 };
                const fold = snail.VectorRect{ .x = rect.x + rect.w * 0.62, .y = rect.y + rect.h * 0.08, .w = rect.w * 0.24, .h = rect.h * 0.24 };
                self.addRoundedRect(page, null, stroke, rect.h * 0.08);
                self.addRoundedRect(fold, fill, null, rect.h * 0.04);
            },
            .symlink => {
                const page = snail.VectorRect{ .x = rect.x + rect.w * 0.12, .y = rect.y + rect.h * 0.1, .w = rect.w * 0.58, .h = rect.h * 0.78 };
                const dot_a = snail.VectorRect{ .x = rect.x + rect.w * 0.54, .y = rect.y + rect.h * 0.38, .w = rect.w * 0.16, .h = rect.w * 0.16 };
                const dot_b = snail.VectorRect{ .x = rect.x + rect.w * 0.7, .y = rect.y + rect.h * 0.22, .w = rect.w * 0.16, .h = rect.w * 0.16 };
                self.addRoundedRect(page, null, stroke, rect.h * 0.08);
                self.addEllipse(dot_a, fill, null);
                self.addEllipse(dot_b, fill, null);
            },
            .home => {
                const body = snail.VectorRect{ .x = rect.x + rect.w * 0.2, .y = rect.y + rect.h * 0.34, .w = rect.w * 0.6, .h = rect.h * 0.5 };
                const roof_left = snail.VectorRect{ .x = rect.x + rect.w * 0.22, .y = rect.y + rect.h * 0.16, .w = rect.w * 0.22, .h = rect.h * 0.18 };
                const roof_right = snail.VectorRect{ .x = rect.x + rect.w * 0.56, .y = rect.y + rect.h * 0.16, .w = rect.w * 0.22, .h = rect.h * 0.18 };
                self.addRoundedRect(body, null, stroke, rect.h * 0.06);
                self.addRoundedRect(roof_left, fill, null, rect.h * 0.05);
                self.addRoundedRect(roof_right, fill, null, rect.h * 0.05);
            },
            .back => {
                const shaft = snail.VectorRect{ .x = rect.x + rect.w * 0.22, .y = rect.y + rect.h * 0.42, .w = rect.w * 0.56, .h = rect.h * 0.16 };
                const head = snail.VectorRect{ .x = rect.x + rect.w * 0.12, .y = rect.y + rect.h * 0.28, .w = rect.w * 0.24, .h = rect.h * 0.44 };
                self.addRoundedRect(shaft, fill, null, rect.h * 0.06);
                self.addRoundedRect(head, fill, null, rect.h * 0.06);
            },
            .up => {
                const shaft = snail.VectorRect{ .x = rect.x + rect.w * 0.42, .y = rect.y + rect.h * 0.24, .w = rect.w * 0.16, .h = rect.h * 0.56 };
                const head = snail.VectorRect{ .x = rect.x + rect.w * 0.28, .y = rect.y + rect.h * 0.12, .w = rect.w * 0.44, .h = rect.h * 0.24 };
                self.addRoundedRect(shaft, fill, null, rect.h * 0.06);
                self.addRoundedRect(head, fill, null, rect.h * 0.06);
            },
            .refresh => {
                const ring = snail.VectorRect{ .x = rect.x + rect.w * 0.18, .y = rect.y + rect.h * 0.18, .w = rect.w * 0.64, .h = rect.h * 0.64 };
                const head = snail.VectorRect{ .x = rect.x + rect.w * 0.6, .y = rect.y + rect.h * 0.12, .w = rect.w * 0.2, .h = rect.h * 0.2 };
                self.addEllipse(ring, null, stroke);
                self.addRoundedRect(head, fill, null, rect.h * 0.05);
            },
            .list => {
                inline for ([_]f32{ 0.22, 0.46, 0.7 }) |y_ratio| {
                    const line = snail.VectorRect{ .x = rect.x + rect.w * 0.18, .y = rect.y + rect.h * y_ratio, .w = rect.w * 0.64, .h = rect.h * 0.1 };
                    self.addRoundedRect(line, fill, null, rect.h * 0.04);
                }
            },
            .grid => {
                inline for ([_]f32{ 0.2, 0.56 }) |y_ratio| {
                    inline for ([_]f32{ 0.2, 0.56 }) |x_ratio| {
                        const cell = snail.VectorRect{ .x = rect.x + rect.w * x_ratio, .y = rect.y + rect.h * y_ratio, .w = rect.w * 0.22, .h = rect.h * 0.22 };
                        self.addRoundedRect(cell, fill, null, rect.h * 0.04);
                    }
                }
            },
            .info => {
                const ring = snail.VectorRect{ .x = rect.x + rect.w * 0.18, .y = rect.y + rect.h * 0.18, .w = rect.w * 0.64, .h = rect.h * 0.64 };
                const stem = snail.VectorRect{ .x = rect.x + rect.w * 0.45, .y = rect.y + rect.h * 0.38, .w = rect.w * 0.1, .h = rect.h * 0.28 };
                const dot = snail.VectorRect{ .x = rect.x + rect.w * 0.43, .y = rect.y + rect.h * 0.24, .w = rect.w * 0.14, .h = rect.w * 0.14 };
                self.addEllipse(ring, null, stroke);
                self.addRoundedRect(stem, fill, null, rect.h * 0.03);
                self.addEllipse(dot, fill, null);
            },
        }
    }

    fn flushVector(self: *Renderer) void {
        if (self.vector_batch.shapeCount() == 0) return;

        self.text_renderer.drawVector(self.vector_batch.slice(), self.viewport_w, self.viewport_h);
        self.vector_batch.reset();
    }

    fn applyClip(self: *Renderer, c_cmd: anytype) void {
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
                const s = self.scissor_stack[self.scissor_depth];
                self.scissor_depth += 1;
                gl.glEnable(gl.GL_SCISSOR_TEST);
                gl.glScissor(s.x, s.y, s.w, s.h);
            }
        } else {
            if (self.scissor_depth > 0) {
                self.scissor_depth -= 1;
            }
            if (self.scissor_depth > 0) {
                const s = self.scissor_stack[self.scissor_depth - 1];
                gl.glScissor(s.x, s.y, s.w, s.h);
            } else {
                gl.glDisable(gl.GL_SCISSOR_TEST);
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
        var probe = snail.Batch.init(self.measure_buf);
        return probe.addString(&self.atlas_view, self.font, text, 0, 0, font_size, .{ 1, 1, 1, 1 });
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
        const scale = font_size / @as(f32, @floatFromInt(self.font.unitsPerEm()));
        const height = (self.ascent_units + self.descent_units) * scale;
        const ascent = self.ascent_units * scale;
        const extra_vertical = @max(bounds.h - height, 0);
        return bounds.y + extra_vertical * 0.5 + ascent;
    }

    fn addRoundedRect(self: *Renderer, rect: snail.VectorRect, fill: ?snail.VectorFillStyle, stroke: ?snail.VectorStrokeStyle, radius: f32) void {
        if (!self.vector_batch.addRoundedRectStyled(rect, fill, stroke, radius, .identity)) {
            self.flushVector();
            _ = self.vector_batch.addRoundedRectStyled(rect, fill, stroke, radius, .identity);
        }
    }

    fn addEllipse(self: *Renderer, rect: snail.VectorRect, fill: ?snail.VectorFillStyle, stroke: ?snail.VectorStrokeStyle) void {
        if (!self.vector_batch.addEllipseStyled(rect, fill, stroke, .identity)) {
            self.flushVector();
            _ = self.vector_batch.addEllipseStyled(rect, fill, stroke, .identity);
        }
    }
};

fn textXForBounds(bounds: goop.draw.Rect, text_width: f32, text_align: goop.TextAlign) f32 {
    return switch (text_align) {
        .start => bounds.x,
        .center => bounds.x + @max(bounds.w - text_width, 0) * 0.5,
        .end => bounds.x + @max(bounds.w - text_width, 0),
    };
}

fn scaledRect(rect: goop.draw.Rect, scale: f32) snail.VectorRect {
    return .{
        .x = rect.x * scale,
        .y = rect.y * scale,
        .w = rect.w * scale,
        .h = rect.h * scale,
    };
}

fn readBigI16(data: []const u8, offset: usize) ?i16 {
    if (offset + 2 > data.len) return null;
    return std.mem.readInt(i16, data[offset..][0..2], .big);
}

fn fontLineMetrics(font: *const snail.Font) struct { ascent: f32, descent: f32 } {
    const inner = font.inner;
    if (inner.hhea_offset != 0) {
        const ascent = readBigI16(inner.data, inner.hhea_offset + 4) orelse @as(i16, @intCast(inner.units_per_em));
        const descent = readBigI16(inner.data, inner.hhea_offset + 6) orelse 0;
        return .{
            .ascent = @floatFromInt(ascent),
            .descent = @floatFromInt(@abs(descent)),
        };
    }
    return .{
        .ascent = @floatFromInt(inner.units_per_em),
        .descent = 0,
    };
}
