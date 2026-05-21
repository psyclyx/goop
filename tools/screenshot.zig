// Headless screenshot tool. Initializes the file_manager demo's State,
// builds the same widget tree the live demo builds, renders one frame to
// an offscreen EGL surface, reads pixels back, and writes a PPM file. A
// build step pipes the PPM through ImageMagick to produce a PNG.
//
// CLI: --output <path.ppm> [--dir <path>] [--width N] [--height N]
//      Defaults: dir=cwd, 1280x720.

const std = @import("std");
const goop = @import("goop");
const snail = @import("snail");
const render = @import("goop_demo_render");
const fm = @import("file_manager");
const egl_util = @import("goop_demo_egl");

const egl = egl_util.egl;
const gl = @cImport({
    @cDefine("GL_GLEXT_PROTOTYPES", "1");
    @cInclude("GL/glcorearb.h");
});

const screenshot_allocator = std.heap.smp_allocator;

const Args = struct {
    output: []const u8,
    dir: ?[]const u8 = null,
    width: u32 = 1280,
    height: u32 = 720,
};

pub fn main(init: std.process.Init) !void {
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    var args = Args{ .output = "" };
    var output_buf: ?[]const u8 = null;
    var dir_buf: ?[]const u8 = null;

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= argv.len) return error.MissingOutputArg;
            output_buf = argv[i];
        } else if (std.mem.eql(u8, arg, "--dir")) {
            i += 1;
            if (i >= argv.len) return error.MissingDirArg;
            dir_buf = argv[i];
        } else if (std.mem.eql(u8, arg, "--width")) {
            i += 1;
            if (i >= argv.len) return error.MissingWidthArg;
            args.width = std.fmt.parseInt(u32, argv[i], 10) catch return error.BadWidth;
        } else if (std.mem.eql(u8, arg, "--height")) {
            i += 1;
            if (i >= argv.len) return error.MissingHeightArg;
            args.height = std.fmt.parseInt(u32, argv[i], 10) catch return error.BadHeight;
        } else {
            std.debug.print("unknown arg: {s}\n", .{arg});
            return error.UnknownArg;
        }
    }

    args.output = output_buf orelse {
        std.debug.print("--output <path.ppm> is required\n", .{});
        return error.MissingOutputArg;
    };
    args.dir = dir_buf;

    var offscreen = try OffscreenSurface.init(args.width, args.height);
    defer offscreen.deinit();

    const font_data = try fm.loadFont(screenshot_allocator, init.environ_map, init.io);
    defer screenshot_allocator.free(font_data);

    var text_atlas = try snail.TextAtlas.init(screenshot_allocator, &.{.{ .data = font_data }});
    defer text_atlas.deinit();

    const line_metrics = fm.fontLineMetrics(&text_atlas);
    const measure_scratch = try screenshot_allocator.alloc(u8, 64);
    defer screenshot_allocator.free(measure_scratch);
    var text_measure = fm.SnailTextCtx{
        .allocator = screenshot_allocator,
        .text_atlas = &text_atlas,
        .scratch_buf = measure_scratch,
        .ascent_units = line_metrics.ascent,
        .descent_units = line_metrics.descent,
    };
    const text_measure_ctx = goop.TextMeasureCtx{
        .measureFn = &fm.snailMeasureText,
        .user_data = @ptrCast(&text_measure),
    };

    var state = fm.State{};
    state.io = init.io;
    state.env = init.environ_map;
    state.text_measure_ctx = &text_measure_ctx;
    state.logical_width = args.width;
    state.logical_height = args.height;
    state.buffer_width = args.width;
    state.buffer_height = args.height;
    state.buffer_scale = 1;
    state.configured = true;

    var ctx = try goop.Context.init(screenshot_allocator, .{
        .width = args.width,
        .height = args.height,
        .theme = fm.fileManagerTheme(&state),
    });
    defer ctx.deinit();
    state.ctx = &ctx;

    if (args.dir) |dir| {
        _ = try fm.setCurrentDirectory(&state, dir, true);
    } else {
        try fm.initializeBrowserState(&state);
    }
    try fm.refreshPlaces(&state);
    try fm.buildWidgetTree(&state);

    var renderer = try render.Renderer.init(args.width, args.height, &text_atlas);
    defer renderer.deinit();
    renderer.target_encoding = if (offscreen.surface_srgb) .srgb else .srgb_pixels_on_linear_attachment;
    renderer.clear_color = .{ 0.95, 0.96, 0.97, 1.0 };

    // Stabilize the text atlas: the demo grows it on demand the first time
    // each glyph is seen, so we layout/paint repeatedly until no new glyphs
    // are added. Without this the first paint can lay out against a smaller
    // atlas than the rendered frame uses.
    var ensured = std.BufSet.init(screenshot_allocator);
    defer ensured.deinit();

    var stabilize_attempts: usize = 0;
    while (stabilize_attempts < 8) : (stabilize_attempts += 1) {
        ctx.doLayout(&text_measure_ctx);
        const base_paint = try ctx.generatePaintList();
        const composed = try fm.composeFileBrowserPaintList(&state, base_paint);
        const grew = try ensureAtlasForPaintList(&text_atlas, &renderer, &ensured, composed);
        if (!grew) break;
    }

    ctx.doLayout(&text_measure_ctx);
    const base_paint = try ctx.generatePaintList();
    const paint_list = try fm.composeFileBrowserPaintList(&state, base_paint);

    renderer.beginFrame(args.width, args.height, 1);
    renderer.renderPaintList(paint_list);
    gl.glFinish();

    const stride = args.width * 4;
    const pixels = try screenshot_allocator.alloc(u8, stride * args.height);
    defer screenshot_allocator.free(pixels);

    gl.glPixelStorei(gl.GL_PACK_ALIGNMENT, 1);
    gl.glReadPixels(
        0,
        0,
        @intCast(args.width),
        @intCast(args.height),
        gl.GL_RGBA,
        gl.GL_UNSIGNED_BYTE,
        @ptrCast(pixels.ptr),
    );

    try writePpm(init.io, args.output, pixels, args.width, args.height);
    std.debug.print("wrote {s} ({}x{})\n", .{ args.output, args.width, args.height });
}

fn ensureAtlasForPaintList(
    atlas: *snail.TextAtlas,
    renderer: *render.Renderer,
    ensured: *std.BufSet,
    paint_list: goop.PaintList,
) !bool {
    var grew = false;
    for (paint_list.commands) |cmd| {
        if (cmd != .text) continue;
        const text = cmd.text.text;
        if (text.len == 0) continue;
        if (ensured.contains(text)) continue;
        if (try atlas.ensureText(.{}, text)) |next| {
            atlas.deinit();
            atlas.* = next;
            grew = true;
        }
        try ensured.insert(text);
    }
    if (grew) renderer.uploadAtlas(atlas);
    return grew;
}

fn writePpm(io: std.Io, path: []const u8, rgba: []const u8, width: u32, height: u32) !void {
    var rgb = try screenshot_allocator.alloc(u8, @as(usize, width) * @as(usize, height) * 3);
    defer screenshot_allocator.free(rgb);

    // glReadPixels gives bottom-up; flip to top-down while converting
    // RGBA -> RGB.
    var y: usize = 0;
    while (y < height) : (y += 1) {
        const src_row = (height - 1 - y) * @as(usize, width) * 4;
        const dst_row = y * @as(usize, width) * 3;
        var x: usize = 0;
        while (x < width) : (x += 1) {
            rgb[dst_row + x * 3 + 0] = rgba[src_row + x * 4 + 0];
            rgb[dst_row + x * 3 + 1] = rgba[src_row + x * 4 + 1];
            rgb[dst_row + x * 3 + 2] = rgba[src_row + x * 4 + 2];
        }
    }

    var header_buf: [64]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buf, "P6\n{d} {d}\n255\n", .{ width, height });

    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);

    try file.writeStreamingAll(io, header);
    try file.writeStreamingAll(io, rgb);
}

const OffscreenSurface = struct {
    display: egl.EGLDisplay = egl.EGL_NO_DISPLAY,
    surface: egl.EGLSurface = egl.EGL_NO_SURFACE,
    context: egl.EGLContext = egl.EGL_NO_CONTEXT,
    surface_srgb: bool = false,

    fn init(width: u32, height: u32) !OffscreenSurface {
        var result = OffscreenSurface{};
        result.display = try createEglDisplay();
        errdefer result.deinit();

        var major: egl.EGLint = 0;
        var minor: egl.EGLint = 0;
        if (egl.eglInitialize(result.display, &major, &minor) == 0) return error.EglInitFailed;

        const attribs = [_]egl.EGLint{
            egl.EGL_SURFACE_TYPE,    egl.EGL_PBUFFER_BIT,
            egl.EGL_RED_SIZE,        8,
            egl.EGL_GREEN_SIZE,      8,
            egl.EGL_BLUE_SIZE,       8,
            egl.EGL_ALPHA_SIZE,      8,
            egl.EGL_RENDERABLE_TYPE, egl.EGL_OPENGL_BIT,
            egl.EGL_NONE,
        };
        var config: egl.EGLConfig = null;
        var num_configs: egl.EGLint = 0;
        if (egl.eglChooseConfig(result.display, &attribs, &config, 1, &num_configs) == 0 or num_configs == 0) {
            return error.EglChooseConfigFailed;
        }
        if (egl.eglBindAPI(egl.EGL_OPENGL_API) == 0) return error.EglBindApiFailed;

        const ctx_attribs = [_]egl.EGLint{
            egl.EGL_CONTEXT_MAJOR_VERSION,       3,
            egl.EGL_CONTEXT_MINOR_VERSION,       3,
            egl.EGL_CONTEXT_OPENGL_PROFILE_MASK, egl.EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
            egl.EGL_NONE,
        };
        result.context = egl.eglCreateContext(result.display, config, egl.EGL_NO_CONTEXT, &ctx_attribs) orelse {
            return error.EglCreateContextFailed;
        };

        const surface_attribs = egl_util.pbufferSurfaceAttribs(result.display, width, height);
        result.surface = egl.eglCreatePbufferSurface(result.display, config, &surface_attribs) orelse fallback: {
            if (surface_attribs[4] == egl.EGL_NONE) return error.EglCreateSurfaceFailed;
            const linear_attribs = egl_util.linearPbufferSurfaceAttribs(width, height);
            break :fallback egl.eglCreatePbufferSurface(result.display, config, &linear_attribs) orelse return error.EglCreateSurfaceFailed;
        };
        result.surface_srgb = egl_util.surfaceIsSrgb(result.display, result.surface);
        if (egl.eglMakeCurrent(result.display, result.surface, result.surface, result.context) == 0) {
            return error.EglMakeCurrentFailed;
        }
        return result;
    }

    fn deinit(self: *OffscreenSurface) void {
        _ = egl.eglMakeCurrent(self.display, egl.EGL_NO_SURFACE, egl.EGL_NO_SURFACE, egl.EGL_NO_CONTEXT);
        if (self.surface != egl.EGL_NO_SURFACE) _ = egl.eglDestroySurface(self.display, self.surface);
        if (self.context != egl.EGL_NO_CONTEXT) _ = egl.eglDestroyContext(self.display, self.context);
        if (self.display != egl.EGL_NO_DISPLAY) _ = egl.eglTerminate(self.display);
    }
};

fn createEglDisplay() !egl.EGLDisplay {
    if (surfacelessDisplay()) |display| return display;
    return egl.eglGetDisplay(egl.EGL_DEFAULT_DISPLAY) orelse error.EglNoDisplay;
}

fn surfacelessDisplay() ?egl.EGLDisplay {
    const client_exts_ptr = egl.eglQueryString(egl.EGL_NO_DISPLAY, egl.EGL_EXTENSIONS) orelse return null;
    const client_exts = std.mem.span(client_exts_ptr);
    if (!egl_util.hasExtension(client_exts, "EGL_EXT_platform_base")) return null;
    if (!egl_util.hasExtension(client_exts, "EGL_MESA_platform_surfaceless")) return null;

    const proc = egl.eglGetProcAddress("eglGetPlatformDisplayEXT") orelse return null;
    const GetPlatformDisplayExt = *const fn (egl.EGLenum, egl.EGLNativeDisplayType, ?*const egl.EGLint) callconv(.c) egl.EGLDisplay;
    const get_platform_display: GetPlatformDisplayExt = @ptrCast(proc);
    const display = get_platform_display(@as(egl.EGLenum, @intCast(egl.EGL_PLATFORM_SURFACELESS_MESA)), null, null);
    if (display == egl.EGL_NO_DISPLAY) return null;
    return display;
}
