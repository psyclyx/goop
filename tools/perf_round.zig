const std = @import("std");
const goop = @import("goop");
const snail = @import("snail");
const render = @import("goop_demo_render");
const c = @cImport({
    @cInclude("time.h");
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
});
const egl = @cImport({
    @cInclude("EGL/egl.h");
    @cInclude("EGL/eglext.h");
});
const gl = @cImport({
    @cDefine("GL_GLEXT_PROTOTYPES", "1");
    @cInclude("GL/glcorearb.h");
});

const BenchConfig = struct {
    width: u32 = 1440,
    height: u32 = 900,
    table_rows: usize = 320,
    layout_iters: usize = 120,
    paint_iters: usize = 240,
    lower_iters: usize = 240,
    redraw_iters: usize = 240,
    render_iters: usize = 240,
    cache_iters: usize = 20_000,
};

const SceneSummary = struct {
    node_count: usize,
    paint_count: usize,
    draw_count: usize,
};

const SnailResources = struct {
    allocator: std.mem.Allocator,
    font_data: []u8,
    font: snail.Font,
    atlas: snail.Atlas,

    fn init(allocator: std.mem.Allocator) !SnailResources {
        const font_data = try loadDemoFont(allocator);
        errdefer allocator.free(font_data);

        var font = try snail.Font.init(font_data);
        errdefer font.deinit();

        var codepoints: [95]u32 = undefined;
        for (0..95) |i| codepoints[i] = @intCast(32 + i);
        var atlas = try snail.Atlas.init(allocator, &font, &codepoints);
        errdefer atlas.deinit();

        return .{
            .allocator = allocator,
            .font_data = font_data,
            .font = font,
            .atlas = atlas,
        };
    }

    fn deinit(self: *SnailResources) void {
        self.atlas.deinit();
        self.font.deinit();
        self.allocator.free(self.font_data);
    }
};

const SnailTextCtx = struct {
    allocator: std.mem.Allocator,
    font: *const snail.Font,
    atlas: *const snail.Atlas,
    measure_buf: []f32,
    scratch_buf: []u8,
    ascent_units: f32,
    descent_units: f32,

    fn init(allocator: std.mem.Allocator, resources: *const SnailResources) !SnailTextCtx {
        const metrics = fontLineMetrics(&resources.font);
        return .{
            .allocator = allocator,
            .font = &resources.font,
            .atlas = &resources.atlas,
            .measure_buf = try allocator.alloc(f32, 64 * snail.FLOATS_PER_GLYPH),
            .scratch_buf = try allocator.alloc(u8, 64),
            .ascent_units = metrics.ascent,
            .descent_units = metrics.descent,
        };
    }

    fn deinit(self: *SnailTextCtx) void {
        self.allocator.free(self.measure_buf);
        self.allocator.free(self.scratch_buf);
    }

    fn ensureMeasureCapacity(self: *SnailTextCtx, glyph_capacity: usize) !void {
        const needed = @max(glyph_capacity, 64) * snail.FLOATS_PER_GLYPH;
        if (self.measure_buf.len >= needed) return;
        const next_len = std.math.ceilPowerOfTwo(usize, needed) catch needed;
        self.measure_buf = try self.allocator.realloc(self.measure_buf, next_len);
    }

    fn ensureScratchCapacity(self: *SnailTextCtx, byte_len: usize) !void {
        if (self.scratch_buf.len >= byte_len) return;
        const next_len = std.math.ceilPowerOfTwo(usize, @max(byte_len, 64)) catch @max(byte_len, 64);
        self.scratch_buf = try self.allocator.realloc(self.scratch_buf, next_len);
    }

    fn sanitizeUtf8Lossy(self: *SnailTextCtx, text: []const u8) []const u8 {
        if (std.unicode.Utf8View.init(text)) |_| return text else |_| {}

        var out_len: usize = 0;
        var index: usize = 0;
        while (index < text.len) {
            const cp = blk: {
                const cp_len = std.unicode.utf8ByteSequenceLength(text[index]) catch {
                    index += 1;
                    break :blk std.unicode.replacement_character;
                };
                if (index + cp_len > text.len) {
                    index += 1;
                    break :blk std.unicode.replacement_character;
                }
                const slice = text[index .. index + cp_len];
                const decoded = std.unicode.utf8Decode(slice) catch {
                    index += 1;
                    break :blk std.unicode.replacement_character;
                };
                index += cp_len;
                break :blk decoded;
            };

            var encoded: [4]u8 = undefined;
            const encoded_len = std.unicode.utf8Encode(cp, &encoded) catch 0;
            self.ensureScratchCapacity(out_len + encoded_len) catch return text;
            @memcpy(self.scratch_buf[out_len..][0..encoded_len], encoded[0..encoded_len]);
            out_len += encoded_len;
        }

        return self.scratch_buf[0..out_len];
    }

    fn fallbackWidth(text: []const u8, font_size: f32) f32 {
        const glyphs = std.unicode.utf8CountCodepoints(text) catch text.len;
        return @as(f32, @floatFromInt(glyphs)) * font_size * 0.6;
    }
};

const OffscreenSurface = struct {
    display: egl.EGLDisplay = egl.EGL_NO_DISPLAY,
    surface: egl.EGLSurface = egl.EGL_NO_SURFACE,
    context: egl.EGLContext = egl.EGL_NO_CONTEXT,

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

        const surface_attribs = [_]egl.EGLint{
            egl.EGL_WIDTH,  @as(egl.EGLint, @intCast(width)),
            egl.EGL_HEIGHT, @as(egl.EGLint, @intCast(height)),
            egl.EGL_NONE,
        };
        result.surface = egl.eglCreatePbufferSurface(result.display, config, &surface_attribs) orelse {
            return error.EglCreateSurfaceFailed;
        };
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

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const config = BenchConfig{};

    var fallback_ctx = try initBenchContext(config);
    defer fallback_ctx.deinit();
    try buildExplorerWorkload(&fallback_ctx, alloc, config.table_rows);
    _ = try runHeadlessSuite("core/no text measurer", &fallback_ctx, config, null, null);

    std.debug.print("\n", .{});

    var snail_resources = try SnailResources.init(std.heap.page_allocator);
    defer snail_resources.deinit();

    var text_measure = try SnailTextCtx.init(std.heap.page_allocator, &snail_resources);
    defer text_measure.deinit();
    const text_measure_ctx = goop.TextMeasureCtx{
        .measureFn = &snailMeasureText,
        .user_data = @ptrCast(&text_measure),
    };

    var snail_ctx = try initBenchContext(config);
    defer snail_ctx.deinit();
    try buildExplorerWorkload(&snail_ctx, alloc, config.table_rows);
    const scene = try runHeadlessSuite("core/snail text measurer", &snail_ctx, config, &text_measure_ctx, &snail_resources);

    std.debug.print("\n", .{});
    runRenderSuite("demo/offscreen renderer", &snail_ctx, config, &text_measure_ctx, &snail_resources, scene) catch |err| {
        std.debug.print("[demo/offscreen renderer]\nunavailable: {s}\n", .{@errorName(err)});
    };
}

fn initBenchContext(config: BenchConfig) !goop.Context {
    return goop.Context.init(std.heap.page_allocator, .{
        .width = config.width,
        .height = config.height,
        .theme = benchTheme(),
    });
}

fn benchTheme() goop.Theme {
    return .{
        .bg = .rgb(243, 246, 251),
        .fg = .rgb(24, 29, 38),
        .accent = .rgb(58, 126, 219),
        .border = .rgb(203, 210, 223),
        .bg_hover = .rgb(231, 238, 248),
        .bg_active = .rgb(220, 229, 243),
        .focus_ring = .rgba(58, 126, 219, 210),
        .placeholder_fg = .rgb(123, 133, 148),
        .selection_bg = .rgba(58, 126, 219, 84),
        .tree_guide = .rgba(145, 152, 165, 180),
        .font_size = 14,
        .padding = goop.style.Edges.symmetric(8, 6),
        .border_radius = 6,
        .border_width = 1,
        .spacing = 6,
        .thumb_width = 14,
    };
}

fn runHeadlessSuite(label: []const u8, ctx: *goop.Context, config: BenchConfig, text_ctx: ?*const goop.TextMeasureCtx, snail_resources: ?*SnailResources) !SceneSummary {
    std.debug.print("[{s}]\n", .{label});

    try prepareContext(ctx, config, text_ctx, snail_resources, null);

    const initial_paint_list = try ctx.generatePaintList();
    const initial_draw_list = try ctx.generateDrawList();
    const scene = SceneSummary{
        .node_count = ctx.tree.count(),
        .paint_count = initial_paint_list.commands.len,
        .draw_count = initial_draw_list.commands.len,
    };

    try warmContext(ctx, config, text_ctx);

    const layout_paint_total_ns = try benchLayoutAndPaint(ctx, config, text_ctx);
    const paint_regen_total_ns = try benchPaintRegen(ctx, config, text_ctx);
    const lower_total_ns = try benchLowerCachedPaint(ctx, config, text_ctx);
    const draw_regen_total_ns = try benchDrawRegen(ctx, config, text_ctx);
    const paint_cache_total_ns = try benchCachedPaint(ctx, config, text_ctx);
    const draw_cache_total_ns = try benchCachedDraw(ctx, config, text_ctx);

    printSummary("layout+paint (resize invalidation)", layout_paint_total_ns, config.layout_iters);
    printSummary("paint regen (mouse move)", paint_regen_total_ns, config.paint_iters);
    printSummary("lower cached paint -> draw", lower_total_ns, config.lower_iters);
    printSummary("full draw regen (mouse move)", draw_regen_total_ns, config.redraw_iters);
    printSummary("cached paint list hit", paint_cache_total_ns, config.cache_iters);
    printSummary("cached draw list hit", draw_cache_total_ns, config.cache_iters);
    printSceneSummary(scene, config.table_rows);

    return scene;
}

fn runRenderSuite(label: []const u8, ctx: *goop.Context, config: BenchConfig, text_ctx: *const goop.TextMeasureCtx, snail_resources: *SnailResources, scene: SceneSummary) !void {
    std.debug.print("[{s}]\n", .{label});

    var offscreen = try OffscreenSurface.init(config.width, config.height);
    defer offscreen.deinit();

    var renderer = try render.Renderer.init(config.width, config.height, &snail_resources.font, &snail_resources.atlas);
    defer renderer.deinit();

    try prepareContext(ctx, config, text_ctx, snail_resources, &renderer);
    const paint_list = try ctx.generatePaintList();

    for (0..16) |_| {
        renderer.beginFrame(config.width, config.height, 1);
        renderer.renderPaintList(paint_list);
        gl.glFinish();
    }

    const render_submit_total_ns = benchRenderPaintList(&renderer, paint_list, config, false);
    gl.glFinish();
    const render_finish_total_ns = benchRenderPaintList(&renderer, paint_list, config, true);
    const frame_total_ns = try benchFrameRegenAndRender(ctx, &renderer, config);

    printSummary("render cached paint (submit)", render_submit_total_ns, config.render_iters);
    printSummary("render cached paint (glFinish)", render_finish_total_ns, config.render_iters);
    printSummary("full frame regen + render (glFinish)", frame_total_ns, config.redraw_iters);
    printSceneSummary(scene, config.table_rows);
}

fn prepareContext(ctx: *goop.Context, config: BenchConfig, text_ctx: ?*const goop.TextMeasureCtx, snail_resources: ?*SnailResources, renderer: ?*render.Renderer) !void {
    ctx.setDimensions(config.width, config.height);
    ctx.doLayout(text_ctx);
    if (snail_resources) |resources| {
        const measure = text_ctx orelse return;
        try stabilizeAtlas(ctx, config, measure, resources, renderer);
    }
}

fn stabilizeAtlas(ctx: *goop.Context, config: BenchConfig, text_ctx: *const goop.TextMeasureCtx, snail_resources: *SnailResources, renderer: ?*render.Renderer) !void {
    while (true) {
        const paint_list = try ctx.generatePaintList();
        if (!try ensureAtlasForPaintList(&snail_resources.atlas, renderer, paint_list)) break;
        ctx.setDimensions(config.width, config.height);
        ctx.doLayout(text_ctx);
    }
}

fn warmContext(ctx: *goop.Context, config: BenchConfig, text_ctx: ?*const goop.TextMeasureCtx) !void {
    for (0..16) |i| {
        ctx.setDimensions(config.width + @as(u32, @intCast(i & 1)), config.height);
        ctx.doLayout(text_ctx);
        _ = try ctx.generatePaintList();
        _ = try ctx.generateDrawList();
    }
    for (0..32) |i| {
        try ctx.pushEvent(.{ .mouse_move = .{
            .x = 320 + @as(f32, @floatFromInt(i % 17)),
            .y = 180 + @as(f32, @floatFromInt(i % 11)),
        } });
        ctx.processEvents();
        _ = try ctx.generatePaintList();
        _ = try ctx.generateDrawList();
    }
    _ = try ctx.generatePaintList();
    _ = try ctx.generateDrawList();
}

fn benchLayoutAndPaint(ctx: *goop.Context, config: BenchConfig, text_ctx: ?*const goop.TextMeasureCtx) !u64 {
    const start_ns = monotonicNs();
    var paint_accum: usize = 0;

    for (0..config.layout_iters) |i| {
        const width = config.width + @as(u32, @intCast(i & 1));
        ctx.setDimensions(width, config.height);
        ctx.doLayout(text_ctx);
        const paint_list = try ctx.generatePaintList();
        paint_accum +%= paint_list.commands.len;
    }

    std.mem.doNotOptimizeAway(paint_accum);
    return monotonicNs() - start_ns;
}

fn benchPaintRegen(ctx: *goop.Context, config: BenchConfig, text_ctx: ?*const goop.TextMeasureCtx) !u64 {
    ctx.setDimensions(config.width, config.height);
    ctx.doLayout(text_ctx);
    _ = try ctx.generatePaintList();

    const start_ns = monotonicNs();
    var paint_accum: usize = 0;

    for (0..config.paint_iters) |i| {
        try ctx.pushEvent(.{ .mouse_move = .{
            .x = 280 + @as(f32, @floatFromInt((i * 7) % 91)),
            .y = 160 + @as(f32, @floatFromInt((i * 13) % 57)),
        } });
        ctx.processEvents();
        const paint_list = try ctx.generatePaintList();
        paint_accum +%= paint_list.commands.len;
    }

    std.mem.doNotOptimizeAway(paint_accum);
    return monotonicNs() - start_ns;
}

fn benchLowerCachedPaint(ctx: *goop.Context, config: BenchConfig, text_ctx: ?*const goop.TextMeasureCtx) !u64 {
    ctx.setDimensions(config.width, config.height);
    ctx.doLayout(text_ctx);
    const paint_list = try ctx.generatePaintList();

    const start_ns = monotonicNs();
    var draw_accum: usize = 0;

    for (0..config.lower_iters) |_| {
        var draw_list = try goop.draw.lowerPaintList(paint_list, std.heap.page_allocator, text_ctx);
        draw_accum +%= draw_list.commands.len;
        goop.draw.freeDrawList(&draw_list, std.heap.page_allocator);
    }

    std.mem.doNotOptimizeAway(draw_accum);
    return monotonicNs() - start_ns;
}

fn benchDrawRegen(ctx: *goop.Context, config: BenchConfig, text_ctx: ?*const goop.TextMeasureCtx) !u64 {
    ctx.setDimensions(config.width, config.height);
    ctx.doLayout(text_ctx);
    _ = try ctx.generateDrawList();

    const start_ns = monotonicNs();
    var draw_accum: usize = 0;

    for (0..config.redraw_iters) |i| {
        try ctx.pushEvent(.{ .mouse_move = .{
            .x = 280 + @as(f32, @floatFromInt((i * 7) % 91)),
            .y = 160 + @as(f32, @floatFromInt((i * 13) % 57)),
        } });
        ctx.processEvents();
        const draw_list = try ctx.generateDrawList();
        draw_accum +%= draw_list.commands.len;
    }

    std.mem.doNotOptimizeAway(draw_accum);
    return monotonicNs() - start_ns;
}

fn benchCachedPaint(ctx: *goop.Context, config: BenchConfig, text_ctx: ?*const goop.TextMeasureCtx) !u64 {
    ctx.setDimensions(config.width, config.height);
    ctx.doLayout(text_ctx);
    _ = try ctx.generatePaintList();

    const start_ns = monotonicNs();
    var paint_accum: usize = 0;

    for (0..config.cache_iters) |_| {
        const paint_list = try ctx.generatePaintList();
        paint_accum +%= paint_list.commands.len;
    }

    std.mem.doNotOptimizeAway(paint_accum);
    return monotonicNs() - start_ns;
}

fn benchCachedDraw(ctx: *goop.Context, config: BenchConfig, text_ctx: ?*const goop.TextMeasureCtx) !u64 {
    ctx.setDimensions(config.width, config.height);
    ctx.doLayout(text_ctx);
    _ = try ctx.generateDrawList();

    const start_ns = monotonicNs();
    var draw_accum: usize = 0;

    for (0..config.cache_iters) |_| {
        const draw_list = try ctx.generateDrawList();
        draw_accum +%= draw_list.commands.len;
    }

    std.mem.doNotOptimizeAway(draw_accum);
    return monotonicNs() - start_ns;
}

fn benchRenderPaintList(renderer: *render.Renderer, paint_list: goop.PaintList, config: BenchConfig, sync_gpu: bool) u64 {
    const start_ns = monotonicNs();
    var paint_accum: usize = 0;

    for (0..config.render_iters) |_| {
        renderer.beginFrame(config.width, config.height, 1);
        renderer.renderPaintList(paint_list);
        if (sync_gpu) gl.glFinish();
        paint_accum +%= paint_list.commands.len;
    }

    std.mem.doNotOptimizeAway(paint_accum);
    return monotonicNs() - start_ns;
}

fn benchFrameRegenAndRender(ctx: *goop.Context, renderer: *render.Renderer, config: BenchConfig) !u64 {
    const start_ns = monotonicNs();
    var paint_accum: usize = 0;

    for (0..config.redraw_iters) |i| {
        try ctx.pushEvent(.{ .mouse_move = .{
            .x = 280 + @as(f32, @floatFromInt((i * 7) % 91)),
            .y = 160 + @as(f32, @floatFromInt((i * 13) % 57)),
        } });
        ctx.processEvents();
        const paint_list = try ctx.generatePaintList();
        renderer.beginFrame(config.width, config.height, 1);
        renderer.renderPaintList(paint_list);
        gl.glFinish();
        paint_accum +%= paint_list.commands.len;
    }

    std.mem.doNotOptimizeAway(paint_accum);
    return monotonicNs() - start_ns;
}

fn ensureAtlasForPaintList(atlas: *snail.Atlas, renderer: ?*render.Renderer, paint_list: goop.PaintList) !bool {
    var changed = false;
    for (paint_list.commands) |command| {
        if (command != .text) continue;
        const text = command.text.text;
        if (text.len == 0) continue;

        const next = if (comptime @hasDecl(snail.Atlas, "extendText"))
            try atlas.extendText(text)
        else
            try atlas.extendGlyphsForText(text);
        if (next) |next_atlas| {
            _ = snail.replaceAtlas(atlas, next_atlas);
            changed = true;
        }
    }

    if (changed and renderer != null) renderer.?.uploadAtlas(atlas);
    return changed;
}

fn snailMeasureText(text: []const u8, font_size: f32, user_data: ?*anyopaque) goop.TextDimensions {
    const ctx: *SnailTextCtx = @ptrCast(@alignCast(user_data));
    const sanitized = ctx.sanitizeUtf8Lossy(text);
    const scale = font_size / @as(f32, @floatFromInt(ctx.font.unitsPerEm()));
    const glyphs = @max(std.unicode.utf8CountCodepoints(sanitized) catch sanitized.len, 1);
    const width = blk: {
        ctx.ensureMeasureCapacity(glyphs) catch break :blk SnailTextCtx.fallbackWidth(sanitized, font_size);
        var probe = snail.Batch.init(ctx.measure_buf);
        break :blk probe.addString(ctx.atlas, ctx.font, sanitized, 0, 0, font_size, .{ 1, 1, 1, 1 });
    };

    return .{
        .width = width,
        .height = (ctx.ascent_units + ctx.descent_units) * scale,
        .ascent = ctx.ascent_units * scale,
        .descent = ctx.descent_units * scale,
    };
}

fn createEglDisplay() !egl.EGLDisplay {
    if (surfacelessDisplay()) |display| return display;
    return egl.eglGetDisplay(egl.EGL_DEFAULT_DISPLAY) orelse error.EglNoDisplay;
}

fn surfacelessDisplay() ?egl.EGLDisplay {
    const client_exts_ptr = egl.eglQueryString(egl.EGL_NO_DISPLAY, egl.EGL_EXTENSIONS) orelse return null;
    const client_exts = std.mem.span(client_exts_ptr);
    if (!hasExtension(client_exts, "EGL_EXT_platform_base")) return null;
    if (!hasExtension(client_exts, "EGL_MESA_platform_surfaceless")) return null;

    const proc = egl.eglGetProcAddress("eglGetPlatformDisplayEXT") orelse return null;
    const GetPlatformDisplayExt = *const fn (egl.EGLenum, egl.EGLNativeDisplayType, ?*const egl.EGLint) callconv(.c) egl.EGLDisplay;
    const get_platform_display: GetPlatformDisplayExt = @ptrCast(proc);
    const display = get_platform_display(@as(egl.EGLenum, @intCast(egl.EGL_PLATFORM_SURFACELESS_MESA)), null, null);
    if (display == egl.EGL_NO_DISPLAY) return null;
    return display;
}

fn hasExtension(exts: []const u8, needle: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, exts, ' ');
    while (it.next()) |ext| {
        if (std.mem.eql(u8, ext, needle)) return true;
    }
    return false;
}

fn loadDemoFont(alloc: std.mem.Allocator) ![]u8 {
    if (fontPathFromEnv()) |path| {
        return readFile(alloc, path);
    }

    if (try fontPathFromFontconfig(alloc)) |path| {
        defer alloc.free(path);
        return readFile(alloc, path);
    }

    const fallback_paths = [_][]const u8{
        "/run/current-system/sw/share/X11/fonts/DejaVuSans.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/TTF/DejaVuSans.ttf",
    };
    for (fallback_paths) |path| {
        return readFile(alloc, path) catch continue;
    }

    std.debug.print("font not found; set GOOP_DEMO_FONT_PATH to a TTF file\n", .{});
    return error.FontNotFound;
}

fn fontPathFromEnv() ?[]const u8 {
    const raw = c.getenv("GOOP_DEMO_FONT_PATH") orelse return null;
    return std.mem.span(@as([*:0]const u8, @ptrCast(raw)));
}

fn fontPathFromFontconfig(alloc: std.mem.Allocator) !?[]u8 {
    const patterns = [_][]const u8{
        "Noto Sans:style=Regular",
        "sans-serif:style=Regular",
    };

    for (patterns) |pattern| {
        var command_buf: [256]u8 = undefined;
        const command = try std.fmt.bufPrintZ(&command_buf, "fc-match -f '%{{file}}\\n' '{s}'", .{pattern});

        const pipe = c.popen(command.ptr, "r") orelse continue;
        defer _ = c.pclose(pipe);

        var buf: [4096]u8 = undefined;
        const raw = c.fgets(&buf, @intCast(buf.len), pipe) orelse continue;
        const line = std.mem.trimEnd(u8, std.mem.span(@as([*:0]const u8, @ptrCast(raw))), "\r\n");
        if (line.len == 0) continue;
        return try alloc.dupe(u8, line);
    }

    return null;
}

fn readFile(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    var path_z: [1024]u8 = undefined;
    if (path.len >= path_z.len) return error.PathTooLong;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;

    const fp = c.fopen(&path_z, "rb") orelse return error.FileNotFound;
    defer _ = c.fclose(fp);

    _ = c.fseek(fp, 0, c.SEEK_END);
    const tell = c.ftell(fp);
    if (tell < 0) return error.ReadFailed;
    const size: usize = @intCast(tell);
    _ = c.fseek(fp, 0, c.SEEK_SET);

    const buf = try alloc.alloc(u8, size);
    errdefer alloc.free(buf);

    const read = c.fread(buf.ptr, 1, size, fp);
    if (read != size) return error.ReadFailed;
    std.debug.print("loaded font: {s} ({} bytes)\n", .{ path, size });
    return buf;
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

fn printSummary(label: []const u8, total_ns: u64, iterations: usize) void {
    const total_ms = @as(f64, @floatFromInt(total_ns)) / @as(f64, std.time.ns_per_ms);
    const avg_us = @as(f64, @floatFromInt(total_ns)) / @as(f64, @floatFromInt(iterations)) / @as(f64, std.time.ns_per_us);
    const ops_per_s = @as(f64, @floatFromInt(iterations)) * @as(f64, std.time.ns_per_s) / @as(f64, @floatFromInt(total_ns));
    std.debug.print(
        "{s}: total={d:.2}ms avg={d:.2}us ops/s={d:.1}\n",
        .{ label, total_ms, avg_us, ops_per_s },
    );
}

fn printSceneSummary(scene: SceneSummary, table_rows: usize) void {
    std.debug.print(
        "scene summary: nodes={}, paint_commands={}, draw_commands={}, table_rows={}\n",
        .{ scene.node_count, scene.paint_count, scene.draw_count, table_rows },
    );
}

fn labelf(alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![]const u8 {
    return std.fmt.allocPrint(alloc, fmt, args);
}

fn monotonicNs() u64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(u64, @intCast(ts.tv_sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.tv_nsec));
}

fn buildExplorerWorkload(ctx: *goop.Context, alloc: std.mem.Allocator, table_rows: usize) !void {
    const root = try ctx.tree.addRoot(.{ .container = .{ .direction = .column } });

    const menu_bar = try ctx.tree.addChild(root, .{ .menu_bar = .{} });
    _ = try ctx.tree.addChild(menu_bar, .{ .menu = .{ .label = "File" } });
    _ = try ctx.tree.addChild(menu_bar, .{ .menu = .{ .label = "Edit" } });
    _ = try ctx.tree.addChild(menu_bar, .{ .menu = .{ .label = "View" } });
    _ = try ctx.tree.addChild(menu_bar, .{ .menu = .{ .label = "Go" } });
    _ = try ctx.tree.addChild(menu_bar, .{ .menu = .{ .label = "Help" } });

    const toolbar = try ctx.tree.addChild(root, .{ .toolbar = .{} });
    ctx.tree.get(toolbar).style_override = .{
        .bg = .rgb(232, 236, 243),
        .border = .rgb(203, 210, 223),
        .padding = goop.style.Edges.symmetric(10, 8),
        .border_radius = 0,
    };
    _ = try ctx.tree.addChild(toolbar, .{ .button = .{ .label = "Back" } });
    _ = try ctx.tree.addChild(toolbar, .{ .button = .{ .label = "Forward" } });
    _ = try ctx.tree.addChild(toolbar, .{ .button = .{ .label = "Up" } });
    _ = try ctx.tree.addChild(toolbar, .{ .button = .{ .label = "New" } });
    _ = try ctx.tree.addChild(toolbar, .{ .button = .{ .label = "Sort" } });
    _ = try ctx.tree.addChild(toolbar, .{ .button = .{ .label = "View" } });
    const address_input = try ctx.tree.addChild(toolbar, .{ .text_input = .{} });
    ctx.tree.get(address_input).kind.text_input.insertSlice("C:\\Workspace\\goop\\assets\\mock-project");
    _ = try ctx.tree.addChild(toolbar, .{ .text_input = .{ .placeholder = "Search mock-project" } });

    const content_split = try ctx.tree.addChild(root, .{ .splitter = .{
        .direction = .row,
        .ratio = 0.26,
        .min_first = 220,
        .min_second = 640,
        .thickness = 8,
    } });

    const nav_panel = try ctx.tree.addChild(content_split, .{ .container = .{ .direction = .column } });
    ctx.tree.get(nav_panel).style_override = .{
        .bg = .rgb(247, 249, 252),
        .border = .rgb(214, 220, 230),
        .padding = goop.style.Edges.symmetric(10, 10),
        .border_radius = 0,
    };
    _ = try ctx.tree.addChild(nav_panel, .{ .text = .{ .content = "Folders" } });
    try addNavTree(ctx, alloc, nav_panel);

    const main_panel = try ctx.tree.addChild(content_split, .{ .container = .{ .direction = .column } });
    ctx.tree.get(main_panel).style_override = .{
        .bg = .rgb(250, 252, 255),
        .border = .rgb(214, 220, 230),
        .padding = goop.style.Edges.symmetric(10, 10),
        .border_radius = 0,
    };

    const crumb_bar = try ctx.tree.addChild(main_panel, .{ .toolbar = .{} });
    ctx.tree.get(crumb_bar).style_override = .{
        .bg = .rgb(255, 255, 255),
        .border = .rgb(214, 220, 230),
        .padding = goop.style.Edges.symmetric(10, 7),
        .border_radius = 4,
    };
    _ = try ctx.tree.addChild(crumb_bar, .{ .text = .{ .content = "This PC" } });
    _ = try ctx.tree.addChild(crumb_bar, .{ .text = .{ .content = ">" } });
    _ = try ctx.tree.addChild(crumb_bar, .{ .text = .{ .content = "Workspace" } });
    _ = try ctx.tree.addChild(crumb_bar, .{ .text = .{ .content = ">" } });
    _ = try ctx.tree.addChild(crumb_bar, .{ .text = .{ .content = "goop" } });
    _ = try ctx.tree.addChild(crumb_bar, .{ .text = .{ .content = ">" } });
    _ = try ctx.tree.addChild(crumb_bar, .{ .text = .{ .content = "assets" } });
    _ = try ctx.tree.addChild(crumb_bar, .{ .text = .{ .content = ">" } });
    _ = try ctx.tree.addChild(crumb_bar, .{ .text = .{ .content = "mock-project" } });

    const detail_split = try ctx.tree.addChild(main_panel, .{ .splitter = .{
        .direction = .column,
        .ratio = 0.82,
        .min_first = 380,
        .min_second = 110,
        .thickness = 8,
    } });

    const table_container = try ctx.tree.addChild(detail_split, .{ .container = .{ .direction = .column } });
    const file_table = try ctx.tree.addChild(table_container, .{ .table = .{
        .columns = 4,
        .resizable = true,
        .sortable = true,
        .selection_mode = .multiple,
        .min_column_width = 92,
    } });
    {
        const table = &ctx.tree.get(file_table).kind.table;
        table.column_weights[0] = 0.50;
        table.column_weights[1] = 0.20;
        table.column_weights[2] = 0.18;
        table.column_weights[3] = 0.12;
    }
    try addFileTable(ctx, alloc, file_table, table_rows);

    const preview = try ctx.tree.addChild(detail_split, .{ .container = .{ .direction = .column } });
    ctx.tree.get(preview).style_override = .{
        .bg = .rgb(246, 248, 252),
        .border = .rgb(214, 220, 230),
        .padding = goop.style.Edges.symmetric(10, 10),
    };
    _ = try ctx.tree.addChild(preview, .{ .text = .{ .content = "Details Pane" } });
    _ = try ctx.tree.addChild(preview, .{ .text = .{ .content = "Selected: render-cache-017.bin" } });
    _ = try ctx.tree.addChild(preview, .{ .text = .{ .content = "Type: Binary Cache" } });
    _ = try ctx.tree.addChild(preview, .{ .text = .{ .content = "Size: 18.4 MB" } });
    _ = try ctx.tree.addChild(preview, .{ .text = .{ .content = "Tags: Generated, Preview, Shared" } });

    const status_bar = try ctx.tree.addChild(root, .{ .status_bar = .{} });
    ctx.tree.get(status_bar).style_override = .{
        .bg = .rgb(232, 236, 243),
        .border = .rgb(203, 210, 223),
        .padding = goop.style.Edges.symmetric(10, 7),
        .border_radius = 0,
    };
    _ = try ctx.tree.addChild(status_bar, .{ .text = .{ .content = "1,284 items" } });
    _ = try ctx.tree.addChild(status_bar, .{ .text = .{ .content = "146 selected" } });
    _ = try ctx.tree.addChild(status_bar, .{ .text = .{ .content = "Status: Indexed" } });
}

fn addNavTree(ctx: *goop.Context, alloc: std.mem.Allocator, parent: goop.NodeHandle) !void {
    const quick = try ctx.tree.addChild(parent, .{ .tree_item = .{
        .label = "Quick Access",
        .group = 1,
        .selected = true,
    } });
    _ = try ctx.tree.addChild(quick, .{ .tree_item = .{ .label = "Desktop", .group = 1 } });
    _ = try ctx.tree.addChild(quick, .{ .tree_item = .{ .label = "Downloads", .group = 1 } });
    _ = try ctx.tree.addChild(quick, .{ .tree_item = .{ .label = "Documents", .group = 1 } });
    _ = try ctx.tree.addChild(quick, .{ .tree_item = .{ .label = "Pictures", .group = 1 } });

    const this_pc = try ctx.tree.addChild(parent, .{ .tree_item = .{
        .label = "This PC",
        .group = 1,
    } });
    _ = try ctx.tree.addChild(this_pc, .{ .tree_item = .{ .label = "Desktop", .group = 1 } });
    _ = try ctx.tree.addChild(this_pc, .{ .tree_item = .{ .label = "Documents", .group = 1 } });
    _ = try ctx.tree.addChild(this_pc, .{ .tree_item = .{ .label = "Downloads", .group = 1 } });
    _ = try ctx.tree.addChild(this_pc, .{ .tree_item = .{ .label = "Pictures", .group = 1 } });
    _ = try ctx.tree.addChild(this_pc, .{ .tree_item = .{ .label = "Music", .group = 1 } });
    _ = try ctx.tree.addChild(this_pc, .{ .tree_item = .{ .label = "Videos", .group = 1 } });

    const workspace = try ctx.tree.addChild(parent, .{ .tree_item = .{
        .label = "Workspace",
        .group = 1,
    } });
    for (0..10) |section| {
        const folder = try labelf(alloc, "Client {:0>2}", .{section + 1});
        const branch = try ctx.tree.addChild(workspace, .{ .tree_item = .{
            .label = folder,
            .group = 1,
        } });
        for (0..4) |sub| {
            const child = try labelf(alloc, "Shot {:0>2}.{:0>2}", .{ section + 1, sub + 1 });
            _ = try ctx.tree.addChild(branch, .{ .tree_item = .{
                .label = child,
                .group = 1,
            } });
        }
    }
}

fn addFileTable(ctx: *goop.Context, alloc: std.mem.Allocator, table: goop.NodeHandle, table_rows: usize) !void {
    const header = try ctx.tree.addChild(table, .{ .table_row = .{ .header = true } });
    try addHeaderCell(ctx, header, "Name");
    try addHeaderCell(ctx, header, "Date modified");
    try addHeaderCell(ctx, header, "Type");
    try addHeaderCell(ctx, header, "Size");

    for (0..table_rows) |i| {
        const row = try ctx.tree.addChild(table, .{ .table_row = .{
            .selected = i % 19 == 0,
        } });

        const kind = switch (i % 6) {
            0 => "Folder",
            1 => "PNG File",
            2 => "Zig Source",
            3 => "Markdown",
            4 => "Binary Cache",
            else => "JSON File",
        };
        const ext = switch (i % 6) {
            0 => "",
            1 => ".png",
            2 => ".zig",
            3 => ".md",
            4 => ".bin",
            else => ".json",
        };
        const name = try labelf(alloc, "render-cache-{:0>3}{s}", .{ i + 1, ext });
        const month = @as(u8, @intCast((i % 12) + 1));
        const day = @as(u8, @intCast((i % 28) + 1));
        const date = try labelf(alloc, "2026-{d:0>2}-{d:0>2}  {d:0>2}:{d:0>2}", .{
            month,
            day,
            @as(u8, @intCast((i * 3) % 24)),
            @as(u8, @intCast((i * 7) % 60)),
        });
        const size = if (i % 6 == 0)
            ""
        else
            try labelf(alloc, "{d}.{d} MB", .{
                1 + (i % 97),
                (i * 3) % 10,
            });

        try addBodyCell(ctx, row, name);
        try addBodyCell(ctx, row, date);
        try addBodyCell(ctx, row, kind);
        try addBodyCell(ctx, row, size);
    }
}

fn addHeaderCell(ctx: *goop.Context, row: goop.NodeHandle, label: []const u8) !void {
    const cell = try ctx.tree.addChild(row, .{ .table_cell = .{} });
    _ = try ctx.tree.addChild(cell, .{ .text = .{ .content = label } });
}

fn addBodyCell(ctx: *goop.Context, row: goop.NodeHandle, label: []const u8) !void {
    const cell = try ctx.tree.addChild(row, .{ .table_cell = .{} });
    _ = try ctx.tree.addChild(cell, .{ .text = .{ .content = label } });
}
