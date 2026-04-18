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

pub const Renderer = struct {
    // Rect shader state
    program: gl.GLuint,
    vao: gl.GLuint,
    vbo: gl.GLuint,
    u_rect: gl.GLint,
    u_color: gl.GLint,
    u_viewport: gl.GLint,
    u_corner_radius: gl.GLint,
    viewport_w: f32,
    viewport_h: f32,
    scissor_stack: [16]Scissor = undefined,
    scissor_depth: u32 = 0,

    // Snail text state
    text_renderer: snail.Renderer,
    text_batch: snail.Batch,
    vertex_buf: []f32,
    font: *const snail.Font,
    atlas: *const snail.Atlas,

    const Scissor = struct { x: i32, y: i32, w: i32, h: i32 };

    const vert_src =
        \\#version 330 core
        \\layout(location = 0) in vec2 a_pos;
        \\uniform vec4 u_rect;
        \\uniform vec2 u_viewport;
        \\void main() {
        \\    vec2 pixel = u_rect.xy + a_pos * u_rect.zw;
        \\    vec2 ndc = (pixel / u_viewport) * 2.0 - 1.0;
        \\    ndc.y = -ndc.y;
        \\    gl_Position = vec4(ndc, 0.0, 1.0);
        \\}
    ;

    const frag_src =
        \\#version 330 core
        \\uniform vec4 u_color;
        \\uniform vec4 u_rect;
        \\uniform vec2 u_viewport;
        \\uniform float u_corner_radius;
        \\out vec4 frag_color;
        \\void main() {
        \\    vec2 pixel = gl_FragCoord.xy;
        \\    pixel.y = u_viewport.y - pixel.y;
        \\    vec2 half_size = u_rect.zw * 0.5;
        \\    vec2 center = u_rect.xy + half_size;
        \\    float r = min(u_corner_radius, min(half_size.x, half_size.y));
        \\    vec2 d = abs(pixel - center) - half_size + r;
        \\    float dist = length(max(d, 0.0)) - r;
        \\    if (dist > 0.5) discard;
        \\    float alpha = 1.0 - smoothstep(-0.5, 0.5, dist);
        \\    frag_color = vec4(u_color.rgb, u_color.a * alpha);
        \\}
    ;

    pub fn init(w: u32, h: u32, font: *const snail.Font, atlas: *const snail.Atlas) !Renderer {
        const vs = compileShader(gl.GL_VERTEX_SHADER, vert_src);
        const fs = compileShader(gl.GL_FRAGMENT_SHADER, frag_src);
        const program = gl.glCreateProgram();
        gl.glAttachShader(program, vs);
        gl.glAttachShader(program, fs);
        gl.glLinkProgram(program);
        gl.glDeleteShader(vs);
        gl.glDeleteShader(fs);

        var success: gl.GLint = 0;
        gl.glGetProgramiv(program, gl.GL_LINK_STATUS, &success);
        if (success == 0) {
            var buf: [512]u8 = undefined;
            var len: gl.GLsizei = 0;
            gl.glGetProgramInfoLog(program, 512, &len, &buf);
            std.debug.print("shader link error: {s}\n", .{buf[0..@intCast(len)]});
        }

        // Unit quad: two triangles
        const vertices = [_]f32{
            0, 0, 1, 0, 1, 1,
            0, 0, 1, 1, 0, 1,
        };

        var vao: gl.GLuint = 0;
        var vbo: gl.GLuint = 0;
        gl.glGenVertexArrays(1, &vao);
        gl.glGenBuffers(1, &vbo);
        gl.glBindVertexArray(vao);
        gl.glBindBuffer(gl.GL_ARRAY_BUFFER, vbo);
        gl.glBufferData(gl.GL_ARRAY_BUFFER, @sizeOf(@TypeOf(vertices)), &vertices, gl.GL_STATIC_DRAW);
        gl.glVertexAttribPointer(0, 2, gl.GL_FLOAT, gl.GL_FALSE, 2 * @sizeOf(f32), null);
        gl.glEnableVertexAttribArray(0);
        gl.glBindVertexArray(0);

        // Snail text renderer
        var text_renderer = try snail.Renderer.init();
        text_renderer.uploadAtlas(atlas);

        const vertex_buf = try std.heap.page_allocator.alloc(f32, VERTEX_BUF_LEN);

        return .{
            .program = program,
            .vao = vao,
            .vbo = vbo,
            .u_rect = gl.glGetUniformLocation(program, "u_rect"),
            .u_color = gl.glGetUniformLocation(program, "u_color"),
            .u_viewport = gl.glGetUniformLocation(program, "u_viewport"),
            .u_corner_radius = gl.glGetUniformLocation(program, "u_corner_radius"),
            .viewport_w = @floatFromInt(w),
            .viewport_h = @floatFromInt(h),
            .text_renderer = text_renderer,
            .text_batch = snail.Batch.init(vertex_buf),
            .vertex_buf = vertex_buf,
            .font = font,
            .atlas = atlas,
        };
    }

    pub fn deinit(self: *Renderer) void {
        gl.glDeleteVertexArrays(1, &self.vao);
        gl.glDeleteBuffers(1, &self.vbo);
        gl.glDeleteProgram(self.program);
        self.text_renderer.deinit();
        std.heap.page_allocator.free(self.vertex_buf);
    }

    pub fn beginFrame(self: *Renderer, w: u32, h: u32) void {
        self.viewport_w = @floatFromInt(w);
        self.viewport_h = @floatFromInt(h);
        self.scissor_depth = 0;
        gl.glViewport(0, 0, @intCast(w), @intCast(h));
        gl.glClearColor(0.12, 0.12, 0.12, 1.0);
        gl.glClear(gl.GL_COLOR_BUFFER_BIT);
        gl.glEnable(gl.GL_BLEND);
        gl.glBlendFunc(gl.GL_SRC_ALPHA, gl.GL_ONE_MINUS_SRC_ALPHA);
        gl.glDisable(gl.GL_SCISSOR_TEST);
    }

    pub fn render(self: *Renderer, draw_list: DrawList) void {
        for (draw_list.commands) |cmd| {
            switch (cmd) {
                .rect => |r| {
                    self.flushText();
                    self.bindRectProgram();
                    self.drawRect(r);
                },
                .text => |t| self.addText(t),
                .clip => |c| {
                    self.flushText();
                    self.bindRectProgram();
                    self.applyClip(c);
                },
            }
        }
        self.flushText();

        gl.glDisable(gl.GL_SCISSOR_TEST);
    }

    fn bindRectProgram(self: *Renderer) void {
        gl.glUseProgram(self.program);
        gl.glBindVertexArray(self.vao);
        gl.glUniform2f(self.u_viewport, self.viewport_w, self.viewport_h);
    }

    fn addText(self: *Renderer, t: DrawCommand.DrawText) void {
        const color = colorToVec4(t.color);
        // goop y is top of text box; snail y is baseline (Y-up in ortho).
        // With ortho(0, w, h, 0), Y=0 is top, Y=h is bottom.
        // snail draws glyphs relative to baseline going upward in its coord system.
        // We use ortho(0, w, 0, h) so Y=0 is bottom — then baseline = viewport_h - (t.y + font_size * 0.8)
        // Actually simpler: use ortho(0, w, h, 0) for Y-down, and pass y + ascent as baseline.
        const baseline_y = t.y + t.font_size;
        _ = self.text_batch.addString(self.atlas, self.font, t.text, t.x, baseline_y, t.font_size, color);
    }

    fn flushText(self: *Renderer) void {
        if (self.text_batch.glyphCount() == 0) return;

        // Y-down orthographic projection matching goop's coordinate system
        const mvp = snail.Mat4.ortho(0, self.viewport_w, self.viewport_h, 0, -1, 1);

        self.text_renderer.beginFrame();
        self.text_renderer.draw(self.text_batch.slice(), mvp, self.viewport_w, self.viewport_h);
        self.text_batch.reset();
    }

    fn drawRect(self: *Renderer, r: DrawCommand.DrawRect) void {
        const color = colorToVec4(r.color);
        gl.glUniform4f(self.u_rect, r.bounds.x, r.bounds.y, r.bounds.w, r.bounds.h);
        gl.glUniform4f(self.u_color, color[0], color[1], color[2], color[3]);
        gl.glUniform1f(self.u_corner_radius, r.corner_radius);
        gl.glDrawArrays(gl.GL_TRIANGLES, 0, 6);
    }

    fn applyClip(self: *Renderer, c_cmd: DrawCommand.ClipRect) void {
        if (c_cmd.bounds) |bounds| {
            if (self.scissor_depth < self.scissor_stack.len) {
                const vh: i32 = @intFromFloat(self.viewport_h);
                self.scissor_stack[self.scissor_depth] = .{
                    .x = @intFromFloat(bounds.x),
                    .y = vh - @as(i32, @intFromFloat(bounds.y + bounds.h)),
                    .w = @intFromFloat(bounds.w),
                    .h = @intFromFloat(bounds.h),
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

    fn compileShader(shader_type: gl.GLenum, source: [*:0]const u8) gl.GLuint {
        const shader = gl.glCreateShader(shader_type);
        const sources = [_][*c]const u8{source};
        gl.glShaderSource(shader, 1, &sources, null);
        gl.glCompileShader(shader);

        var success: gl.GLint = 0;
        gl.glGetShaderiv(shader, gl.GL_COMPILE_STATUS, &success);
        if (success == 0) {
            var buf: [512]u8 = undefined;
            var len: gl.GLsizei = 0;
            gl.glGetShaderInfoLog(shader, 512, &len, &buf);
            std.debug.print("shader compile error: {s}\n", .{buf[0..@intCast(len)]});
        }
        return shader;
    }

    fn colorToVec4(c: goop.Color) [4]f32 {
        return .{
            @as(f32, @floatFromInt(c.r)) / 255.0,
            @as(f32, @floatFromInt(c.g)) / 255.0,
            @as(f32, @floatFromInt(c.b)) / 255.0,
            @as(f32, @floatFromInt(c.a)) / 255.0,
        };
    }
};
