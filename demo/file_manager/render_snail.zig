//! Snail (goop_render_vulkan) renderer for the file manager demo.
//!
//! Implements the `Renderer` seam the app talks to: it owns the demo text
//! engine (measurement + glyph atlas), the shared Vulkan `Gpu`, and the About
//! child window. The Skia backend (`render_skia.zig`) implements the same seam.

const std = @import("std");
const goop = @import("goop");
const visual = @import("goop_visual");
const chrome_module = @import("goop_chrome");
const platform = @import("goop_platform_wayland");
const fm = @import("file_manager");
const text_module = @import("demo_text");
const gpu_module = @import("demo_gpu");

const allocator = std.heap.smp_allocator;

/// This backend can host the About child window.
pub const supports_about = true;

pub const Renderer = struct {
    text: text_module.Text,
    gpu: gpu_module.Gpu,
    about: ?*AboutWindow = null,

    /// Heap-pinned: the snail renderer holds pointers into the text engine's
    /// pool, so the text engine must not move after the renderer is built.
    pub fn create(
        window: *const platform.Window,
        io: std.Io,
        env: *const std.process.Environ.Map,
        width: u32,
        height: u32,
    ) !*Renderer {
        const self = try allocator.create(Renderer);
        errdefer allocator.destroy(self);
        self.text = try text_module.Text.init(allocator, io, env);
        errdefer self.text.deinit();
        self.about = null;
        self.gpu = try gpu_module.Gpu.init(allocator, window, &self.text.engine, width, height, "goop-file-manager");
        return self;
    }

    pub fn destroy(self: *Renderer) void {
        if (self.about) |w| w.deinit();
        self.gpu.deinit();
        self.text.deinit();
        allocator.destroy(self);
    }

    pub fn measureContext(self: *Renderer) goop.TextMeasureCtx {
        return self.text.measureContext();
    }

    pub fn resize(self: *Renderer, width: u32, height: u32) void {
        self.gpu.resize(width, height);
    }

    /// Render one frame of the main window from `commands`. Returns whether a
    /// frame was actually presented (false if the swapchain was not ready).
    pub fn renderFrame(self: *Renderer, window: *platform.Window, commands: []const visual.Operation, clear: [4]f32) !bool {
        var prepared = try self.gpu.renderer.prepareVisuals(allocator, &self.text.engine, commands, 1);
        defer prepared.deinit();
        try self.gpu.renderer.updateVisualResources(&self.text.engine);
        const target = try self.gpu.beginFrame(&self.text.engine, clear) orelse return false;
        try self.gpu.renderer.drawPreparedVisuals(target, &self.text.engine, &prepared);
        window.requestFrame();
        try self.gpu.presenter.endFrame();
        return true;
    }

    /// Open the About window when requested and service its event queue.
    pub fn serviceAbout(self: *Renderer, parent: *platform.Window, io: std.Io, env: *const std.process.Environ.Map, requested: bool) void {
        if (requested and self.about == null) {
            self.about = AboutWindow.open(&self.gpu, parent, io, env) catch null;
        }
        if (self.about) |w| {
            w.pump(io) catch {
                w.deinit();
                self.about = null;
                return;
            };
            if (!w.running) {
                w.deinit();
                self.about = null;
            }
        }
    }
};

// ── About window ────────────────────────────────────────────────────────────
// A real, separate top-level window sharing the main window's Vulkan instance
// and device (two VkInstances crash NVIDIA at swapchain teardown).

const about_close_id = goop.ElementId.init(0xA_B0_07_C105E);
const about_clear = [4]f32{ 250.0 / 255.0, 251.0 / 255.0, 253.0 / 255.0, 1.0 };

const AboutWindow = struct {
    window: platform.Window,
    text: text_module.Text,
    context: goop.Context,
    chrome: chrome_module.Chrome,
    target: gpu_module.Target,
    measure: goop.TextMeasureCtx,
    running: bool = true,
    configured: bool = false,
    frame_pending: bool = false,
    dirty: bool = true,

    fn open(gpu: *gpu_module.Gpu, parent: *platform.Window, io: std.Io, env: *const std.process.Environ.Map) !*AboutWindow {
        const self = try allocator.create(AboutWindow);
        errdefer allocator.destroy(self);
        const w: u32 = 440;
        const h: u32 = 240;

        self.window = try platform.Window.initChild(allocator, parent, .{
            .width = w,
            .height = h,
            .title = "About goop files",
            .application_id = "goop-files-about",
        });
        errdefer self.window.deinit();

        self.text = try text_module.Text.init(allocator, io, env);
        errdefer self.text.deinit();
        self.measure = self.text.measureContext();

        self.context = try goop.Context.init(allocator, .{ .width = w, .height = h });
        errdefer self.context.deinit();
        self.context.setTheme(fm.style.fileManagerThemeForScale(1));

        self.chrome = chrome_module.Chrome.init(allocator);
        errdefer self.chrome.deinit();

        self.target = try gpu.openTarget(&self.window, &self.text.engine, w, h);
        errdefer self.target.deinit();

        self.running = true;
        self.configured = false;
        self.frame_pending = false;
        self.dirty = true;
        try self.build();
        return self;
    }

    fn build(self: *AboutWindow) !void {
        const ctx = &self.context;
        const transparent = goop.Color.rgba(0, 0, 0, 0);
        const root = try ctx.tree.addRoot(.{ .container = .{ .direction = .column } });
        _ = ctx.setStyle(root, .{
            .bg = .rgb(250, 251, 253),
            .padding = goop.style.Edges.all(24),
            .spacing = 10,
            .border_width = 0,
            .border_radius = 0,
        });
        const title = try ctx.tree.addChild(root, .{ .text = .{ .content = "goop files" } });
        _ = ctx.setStyle(title, .{ .font_size = 26, .fg = .rgb(20, 25, 33) });
        const body = try ctx.tree.addChild(root, .{ .text = .{
            .content = "A retained-mode file manager component — a leaner homage to Explorer, built to show off goop.",
            .overflow = .wrap,
        } });
        _ = ctx.setStyle(body, .{ .fg = .rgb(60, 68, 82), .font_size = 14.5 });
        const version = try ctx.tree.addChild(root, .{ .text = .{ .content = "goop 0.3.0 · retained UI toolkit" } });
        _ = ctx.setStyle(version, .{ .fg = .rgb(120, 128, 140), .font_size = 12.5 });
        _ = try ctx.tree.addChild(root, .{ .container = .{ .direction = .column } });
        const actions = try ctx.tree.addChild(root, .{ .container = .{ .direction = .row, .fit_main = true } });
        _ = ctx.setStyle(actions, .{ .bg = transparent, .padding = goop.style.Edges.all(0), .spacing = 0, .border_width = 0 });
        _ = try ctx.tree.addChild(actions, .{ .spacer = .{} });
        const close = try ctx.tree.addChildControl(actions, .{
            .identity = .{ .element_id = about_close_id, .action_id = null },
            .widget = .{ .button = .{ .label = "Close" } },
        });
        _ = ctx.setStyle(close, fm.style.fileManagerActionButtonStyle(1, true));
        _ = ctx.focusWidget(close);
    }

    fn pump(self: *AboutWindow, io: std.Io) !void {
        while (self.window.pollEvent()) |event| switch (event) {
            .close => self.running = false,
            .configured, .resized => |sz| {
                if (sz.width == 0 or sz.height == 0) continue;
                self.configured = true;
                self.context.setDimensions(sz.width, sz.height);
                try self.context.pushEvent(.{ .resize = .{ .width = sz.width, .height = sz.height } });
                self.target.resize(sz.width, sz.height);
                self.dirty = true;
            },
            .frame_ready => self.frame_pending = false,
            .pointer_enter, .pointer_motion => |p| {
                try self.context.pushEvent(.{ .mouse_move = .{ .x = @floatCast(p.x), .y = @floatCast(p.y) } });
                self.dirty = true;
            },
            .pointer_leave => {
                try self.context.pushEvent(.{ .mouse_move = .{ .x = -1, .y = -1 } });
                self.dirty = true;
            },
            .pointer_button => |btn| {
                const mapped: goop.Event.MouseButton.Button = switch (btn.button) {
                    0x110 => .left,
                    0x111 => .right,
                    0x112 => .middle,
                    else => continue,
                };
                try self.context.pushEvent(.{ .mouse_button = .{
                    .button = mapped,
                    .state = if (btn.state == .pressed) .pressed else .released,
                    .x = @floatCast(btn.position.x),
                    .y = @floatCast(btn.position.y),
                    .timestamp_ms = btn.time_ms,
                } });
                self.dirty = true;
            },
            .key => |key| {
                // scancode 1 is Escape (evdev).
                if (key.state == .pressed and key.scancode == 1) self.running = false;
                self.dirty = true;
            },
            else => {},
        };
        if (self.context.update(monotonicNs(io) / std.time.ns_per_ms).changed) self.dirty = true;
        if (self.configured and self.dirty and !self.frame_pending and self.running) try self.draw();
    }

    fn draw(self: *AboutWindow) !void {
        self.dirty = false;
        const ctx = &self.context;
        ctx.doLayout(&self.measure);
        const events = try ctx.processEvents();
        for (events.items) |ev| switch (ev) {
            .activated => |a| if (a.element == about_close_id) {
                self.running = false;
            },
            else => {},
        };
        if (!self.running) return;
        ctx.doLayout(&self.measure);
        const visuals = try self.chrome.prepare(ctx.chromeState(), .{});
        var prepared = try self.target.renderer.prepareVisuals(allocator, &self.text.engine, visuals.commands, 1);
        defer prepared.deinit();
        try self.target.renderer.updateVisualResources(&self.text.engine);
        const target = try self.target.beginFrame(&self.text.engine, about_clear) orelse {
            self.dirty = true;
            return;
        };
        try self.target.renderer.drawPreparedVisuals(target, &self.text.engine, &prepared);
        self.window.requestFrame();
        try self.target.presenter.endFrame();
        self.frame_pending = true;
    }

    fn deinit(self: *AboutWindow) void {
        self.target.deinit();
        self.chrome.deinit();
        self.context.deinit();
        self.text.deinit();
        self.window.deinit();
        allocator.destroy(self);
    }
};

fn monotonicNs(io: std.Io) u64 {
    const value = std.Io.Clock.awake.now(io).nanoseconds;
    return if (value <= 0) 0 else @intCast(value);
}
