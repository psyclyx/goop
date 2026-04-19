const std = @import("std");
const goop = @import("goop");
const snail = @import("snail");

const gl = @cImport({
    @cDefine("GL_GLEXT_PROTOTYPES", "1");
    @cInclude("GL/glcorearb.h");
});

const DrawCommand = goop.DrawCommand;
const DrawList = goop.DrawList;

const MAX_GLYPHS = 4096;
const VERTEX_BUF_LEN = MAX_GLYPHS * snail.FLOATS_PER_GLYPH;
const MAX_VECTOR_PRIMITIVES = 2048;
const VECTOR_BUF_LEN = MAX_VECTOR_PRIMITIVES * snail.VECTOR_FLOATS_PER_PRIMITIVE;

pub const Renderer = struct {
    viewport_w: f32,
    viewport_h: f32,
    scale: f32,
    scissor_stack: [16]Scissor = undefined,
    scissor_depth: u32 = 0,

    // Snail text state
    text_renderer: snail.Renderer,
    text_batch: snail.Batch,
    vertex_buf: []f32,
    vector_batch: snail.VectorBatch,
    vector_buf: []f32,
    font: *const snail.Font,
    atlas: *const snail.Atlas,

    const Scissor = struct { x: i32, y: i32, w: i32, h: i32 };

    pub fn init(w: u32, h: u32, font: *const snail.Font, atlas: *const snail.Atlas) !Renderer {
        var text_renderer = try snail.Renderer.init();
        text_renderer.uploadAtlas(atlas);

        const vertex_buf = try std.heap.page_allocator.alloc(f32, VERTEX_BUF_LEN);
        const vector_buf = try std.heap.page_allocator.alloc(f32, VECTOR_BUF_LEN);

        return .{
            .viewport_w = @floatFromInt(w),
            .viewport_h = @floatFromInt(h),
            .scale = 1,
            .text_renderer = text_renderer,
            .text_batch = snail.Batch.init(vertex_buf),
            .vertex_buf = vertex_buf,
            .vector_batch = snail.VectorBatch.init(vector_buf),
            .vector_buf = vector_buf,
            .font = font,
            .atlas = atlas,
        };
    }

    pub fn deinit(self: *Renderer) void {
        self.text_renderer.deinit();
        std.heap.page_allocator.free(self.vertex_buf);
        std.heap.page_allocator.free(self.vector_buf);
    }

    pub fn beginFrame(self: *Renderer, w: u32, h: u32, scale: f32) void {
        self.viewport_w = @floatFromInt(w);
        self.viewport_h = @floatFromInt(h);
        self.scale = scale;
        self.scissor_depth = 0;
        gl.glViewport(0, 0, @intCast(w), @intCast(h));
        gl.glClearColor(0.12, 0.12, 0.12, 1.0);
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
                .clip => |c| {
                    self.flushVector();
                    self.flushText();
                    self.applyClip(c);
                },
            }
        }
        self.flushVector();
        self.flushText();

        gl.glDisable(gl.GL_SCISSOR_TEST);
    }

    fn addText(self: *Renderer, t: DrawCommand.DrawText) void {
        const color = colorToVec4(t.color);
        // goop y is top of text box (Y-down); snail positions glyphs in Y-up
        // coordinates relative to the baseline. Convert by flipping to Y-up.
        // Snap to pixel grid — fractional positions cause jagged glyph edges
        // because coverage straddles pixel boundaries.
        const scaled_x = snapToDevicePixels(t.x, self.scale);
        const scaled_top = snapToDevicePixels(t.y, self.scale);
        const scaled_font_size = t.font_size * self.scale;
        const baseline_y = @round(self.viewport_h - (scaled_top + scaled_font_size));
        _ = self.text_batch.addString(self.atlas, self.font, t.text, scaled_x, baseline_y, scaled_font_size, color);
    }

    fn flushText(self: *Renderer) void {
        if (self.text_batch.glyphCount() == 0) return;

        // Y-up orthographic projection — snail's glyph quads use Y-up coords
        const mvp = snail.Mat4.ortho(0, self.viewport_w, 0, self.viewport_h, -1, 1);

        self.text_renderer.beginFrame();
        self.text_renderer.draw(self.text_batch.slice(), mvp, self.viewport_w, self.viewport_h);
        self.text_batch.reset();
    }

    fn addRect(self: *Renderer, r: DrawCommand.DrawRect) void {
        const rect: snail.VectorRect = .{
            .x = r.bounds.x * self.scale,
            .y = r.bounds.y * self.scale,
            .w = r.bounds.w * self.scale,
            .h = r.bounds.h * self.scale,
        };
        const fill = colorToVec4(r.color);
        const border = colorToVec4(r.border_color);
        if (!self.vector_batch.addRoundedRect(rect, fill, border, r.border_width * self.scale, r.corner_radius * self.scale)) {
            self.flushVector();
            _ = self.vector_batch.addRoundedRect(rect, fill, border, r.border_width * self.scale, r.corner_radius * self.scale);
        }
    }

    fn flushVector(self: *Renderer) void {
        if (self.vector_batch.shapeCount() == 0) return;

        self.text_renderer.drawVector(self.vector_batch.slice(), self.viewport_w, self.viewport_h);
        self.vector_batch.reset();
    }

    fn applyClip(self: *Renderer, c_cmd: DrawCommand.ClipRect) void {
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
};
