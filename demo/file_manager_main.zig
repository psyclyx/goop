const std = @import("std");
const goop = @import("goop");
const snail = @import("snail");
const render = @import("render.zig");

const wl = @cImport({
    @cInclude("wayland-client.h");
    @cInclude("wayland-egl.h");
    @cInclude("xdg-shell-client-protocol.h");
});

const xkb = @cImport({
    @cInclude("xkbcommon/xkbcommon.h");
});

const egl = @cImport({
    @cInclude("EGL/egl.h");
});

const posix = @cImport({
    @cInclude("poll.h");
    @cInclude("time.h");
    @cInclude("unistd.h");
    @cInclude("sys/mman.h");
});

const c_io = @cImport({
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
});

const c_fs = @cImport({
    @cInclude("dirent.h");
    @cInclude("sys/stat.h");
});

const allocator = std.heap.page_allocator;
const clipboard_mime_utf8 = "text/plain;charset=utf-8";
const clipboard_mime_utf8_string = "UTF8_STRING";
const clipboard_mime_text = "text/plain";

/// Snail-based text measurement adapter for goop.
const SnailTextCtx = struct {
    allocator: std.mem.Allocator,
    font: *const snail.Font,
    atlas: *const snail.Atlas,
    glyph_cache: snail.ttf.GlyphCache,
    ascent_units: f32,
    descent_units: f32,
};

const OutputState = struct {
    global_name: u32,
    output: *wl.wl_output,
    scale: u32 = 1,
    entered: bool = false,
    next: ?*OutputState = null,
};

fn snailMeasureText(text: []const u8, font_size: f32, user_data: ?*anyopaque) goop.TextDimensions {
    const ctx: *SnailTextCtx = @ptrCast(@alignCast(user_data));
    const MeasuredGlyph = struct {
        advance_width: u16,
        bbox: snail.bezier.BBox,
    };
    const scale = font_size / @as(f32, @floatFromInt(ctx.font.unitsPerEm()));
    var width: f32 = 0;
    var prev_gid: u16 = 0;
    var min_y = std.math.inf(f32);
    var max_y = -std.math.inf(f32);
    var have_vertical_bounds = false;
    const view = std.unicode.Utf8View.initUnchecked(text);
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        const gid = ctx.font.glyphIndex(cp) catch 0;
        if (gid == 0) {
            width += scale * 500;
            prev_gid = 0;
            continue;
        }
        if (prev_gid != 0) {
            const kern = ctx.font.getKerning(prev_gid, gid) catch 0;
            width += @as(f32, @floatFromInt(kern)) * scale;
        }
        const glyph_metrics: MeasuredGlyph = if (ctx.atlas.getGlyph(gid)) |info|
            .{ .advance_width = info.advance_width, .bbox = info.bbox }
        else blk: {
            const glyph = ctx.font.inner.parseGlyph(ctx.allocator, &ctx.glyph_cache, gid) catch {
                width += scale * 500;
                prev_gid = gid;
                continue;
            };
            break :blk .{ .advance_width = glyph.metrics.advance_width, .bbox = glyph.metrics.bbox };
        };

        if (glyph_metrics.bbox.max.y > glyph_metrics.bbox.min.y) {
            min_y = @min(min_y, glyph_metrics.bbox.min.y);
            max_y = @max(max_y, glyph_metrics.bbox.max.y);
            have_vertical_bounds = true;
        }

        width += @as(f32, @floatFromInt(glyph_metrics.advance_width)) * scale;
        prev_gid = gid;
    }

    if (have_vertical_bounds) {
        const ascent = @max(max_y, 0) * font_size;
        const descent = @max(-min_y, 0) * font_size;
        return .{
            .width = width,
            .height = ascent + descent,
            .ascent = ascent,
            .descent = descent,
        };
    }

    return .{
        .width = width,
        .height = (ctx.ascent_units + ctx.descent_units) * scale,
        .ascent = ctx.ascent_units * scale,
        .descent = ctx.descent_units * scale,
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

fn isPrintableTextCodepoint(codepoint: u32) bool {
    if (codepoint > std.math.maxInt(u21)) return false;
    if (!std.unicode.utf8ValidCodepoint(@intCast(codepoint))) return false;
    if (codepoint < 0x20) return false;
    if (codepoint >= 0x7F and codepoint < 0xA0) return false;
    return true;
}

fn ensureAtlasForDrawList(atlas: *snail.Atlas, renderer: *render.Renderer, draw_list: goop.DrawList) !bool {
    var changed = false;
    for (draw_list.commands) |command| {
        if (command != .text) continue;
        const text = command.text.text;
        if (text.len == 0) continue;

        if (try atlas.extendGlyphsForText(text)) |next| {
            _ = snail.replaceAtlas(atlas, next);
            changed = true;
        }
    }

    if (changed) renderer.uploadAtlas(atlas);
    return changed;
}

const BrowserSortColumn = enum(u8) {
    name = 0,
    modified = 1,
    kind = 2,
    size = 3,
};

const BrowserSortDirection = enum {
    ascending,
    descending,
};

const BrowserEntryKind = enum {
    directory,
    file,
    symlink,
    other,
};

const BrowserPlace = struct {
    label: []const u8,
    path: []u8,
};

const BrowserEntry = struct {
    name: []u8,
    path: []u8,
    kind: BrowserEntryKind,
    size_bytes: u64,
    modified_unix: i64,
    modified_buf: [24]u8 = [_]u8{0} ** 24,
    modified_len: u8 = 0,
    size_buf: [24]u8 = [_]u8{0} ** 24,
    size_len: u8 = 0,

    fn modifiedText(self: *const BrowserEntry) []const u8 {
        return self.modified_buf[0..self.modified_len];
    }

    fn sizeText(self: *const BrowserEntry) []const u8 {
        return self.size_buf[0..self.size_len];
    }

    fn typeLabel(self: *const BrowserEntry) []const u8 {
        return switch (self.kind) {
            .directory => "Directory",
            .symlink => "Symbolic link",
            .other => "Special",
            .file => fileTypeLabel(self.name),
        };
    }

    fn isDirectory(self: *const BrowserEntry) bool {
        return self.kind == .directory;
    }
};

const State = struct {
    running: bool = true,
    configured: bool = false,
    logical_width: u32 = 800,
    logical_height: u32 = 600,
    buffer_width: u32 = 800,
    buffer_height: u32 = 600,
    buffer_scale: u32 = 1,
    compositor_version: u32 = 0,
    surface_preferred_scale: ?u32 = null,
    needs_redraw: bool = true,
    frame_pending: bool = false,
    timeout_ns: ?u64 = null,
    start_time: posix.struct_timespec = .{ .tv_sec = 0, .tv_nsec = 0 },

    // Wayland globals
    display: ?*wl.wl_display = null,
    compositor: ?*wl.wl_compositor = null,
    wm_base: ?*wl.xdg_wm_base = null,
    seat: ?*wl.wl_seat = null,
    data_device_manager: ?*wl.wl_data_device_manager = null,
    outputs: ?*OutputState = null,

    // Wayland surface chain
    surface: ?*wl.wl_surface = null,
    xdg_surface: ?*wl.xdg_surface = null,
    xdg_toplevel: ?*wl.xdg_toplevel = null,
    egl_window: ?*wl.wl_egl_window = null,
    pointer: ?*wl.wl_pointer = null,
    keyboard: ?*wl.wl_keyboard = null,
    data_device: ?*wl.wl_data_device = null,
    clipboard_source: ?*wl.wl_data_source = null,
    selection_offer: ?*DataOfferState = null,
    drag_offer: ?*DataOfferState = null,
    data_offers: ?*DataOfferState = null,
    last_input_serial: u32 = 0,

    // EGL
    egl_display: egl.EGLDisplay = egl.EGL_NO_DISPLAY,
    egl_surface: egl.EGLSurface = egl.EGL_NO_SURFACE,
    egl_context: egl.EGLContext = egl.EGL_NO_CONTEXT,

    // goop
    ctx: ?*goop.Context = null,

    // File browser model
    current_dir: []u8 = &.{},
    history: std.ArrayListUnmanaged([]u8) = .empty,
    history_index: usize = 0,
    places: std.ArrayListUnmanaged(BrowserPlace) = .empty,
    entries: std.ArrayListUnmanaged(BrowserEntry) = .empty,
    selected_path: ?[]u8 = null,
    last_click_path: ?[]u8 = null,
    last_click_ns: u64 = 0,
    sort_column: BrowserSortColumn = .name,
    sort_direction: BrowserSortDirection = .ascending,
    nav_ratio: f32 = 0.22,
    detail_ratio: f32 = 0.72,
    table_column_weights: [4]f32 = .{ 0.50, 0.22, 0.16, 0.12 },

    // Dynamic UI state
    ui_root: ?goop.NodeHandle = null,
    btn_back: ?goop.NodeHandle = null,
    btn_up: ?goop.NodeHandle = null,
    btn_home: ?goop.NodeHandle = null,
    btn_refresh: ?goop.NodeHandle = null,
    nav_splitter: ?goop.NodeHandle = null,
    detail_splitter: ?goop.NodeHandle = null,
    asset_table: ?goop.NodeHandle = null,
    place_handles: std.ArrayListUnmanaged(goop.NodeHandle) = .empty,
    breadcrumb_handles: std.ArrayListUnmanaged(goop.NodeHandle) = .empty,
    breadcrumb_paths: std.ArrayListUnmanaged([]u8) = .empty,
    row_handles: std.ArrayListUnmanaged(goop.NodeHandle) = .empty,
    ui_strings: std.ArrayListUnmanaged([]u8) = .empty,

    // Last known mouse position from Wayland pointer events
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,

    // xkbcommon state for keymap → text conversion
    xkb_ctx: ?*xkb.xkb_context = null,
    xkb_keymap: ?*xkb.xkb_keymap = null,
    xkb_state: ?*xkb.xkb_state = null,

    // Clipboard text for self-owned selections and the most recent external paste.
    clipboard_buf: std.ArrayListUnmanaged(u8) = .empty,

    fn clipboard(self: *State) goop.Clipboard {
        return .{
            .ptr = @ptrCast(self),
            .getTextFn = @ptrCast(&clipboardGetText),
            .setTextFn = @ptrCast(&clipboardSetText),
        };
    }

    fn clipboardGetText(ptr: *anyopaque) ?[]const u8 {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (self.clipboard_source != null) {
            if (self.clipboard_buf.items.len == 0) return null;
            return self.clipboard_buf.items;
        }
        self.fetchClipboardSelection() catch return null;
        if (self.clipboard_buf.items.len == 0) return null;
        return self.clipboard_buf.items;
    }

    fn clipboardSetText(ptr: *anyopaque, text: []const u8) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.setClipboardSelection(text) catch {};
    }

    fn setClipboardSelection(self: *State, text: []const u8) !void {
        try self.setClipboardBuffer(text);
        if (self.data_device_manager == null or self.data_device == null or self.last_input_serial == 0) return;

        self.destroyClipboardSource();

        const source = wl.wl_data_device_manager_create_data_source(self.data_device_manager) orelse return;
        self.clipboard_source = source;
        _ = wl.wl_data_source_add_listener(source, &data_source_listener, self);
        wl.wl_data_source_offer(source, clipboard_mime_utf8);
        wl.wl_data_source_offer(source, clipboard_mime_utf8_string);
        wl.wl_data_source_offer(source, clipboard_mime_text);
        wl.wl_data_device_set_selection(self.data_device, source, self.last_input_serial);
        if (self.display) |display| _ = wl.wl_display_flush(display);
    }

    fn fetchClipboardSelection(self: *State) !void {
        const offer = self.selection_offer orelse return;
        const mime = preferredOfferMime(offer) orelse return;

        var fds: [2]i32 = undefined;
        if (posix.pipe(&fds) != 0) return error.PipeFailed;
        errdefer _ = posix.close(fds[0]);
        errdefer _ = posix.close(fds[1]);

        wl.wl_data_offer_receive(offer.offer, mime, fds[1]);
        _ = posix.close(fds[1]);
        if (self.display) |display| _ = wl.wl_display_flush(display);

        self.clipboard_buf.clearRetainingCapacity();
        var chunk: [4096]u8 = undefined;
        while (true) {
            const read_count = posix.read(fds[0], &chunk, chunk.len);
            if (read_count <= 0) break;
            try self.clipboard_buf.appendSlice(allocator, chunk[0..@intCast(read_count)]);
        }
        _ = posix.close(fds[0]);
    }

    fn setClipboardBuffer(self: *State, text: []const u8) !void {
        self.clipboard_buf.clearRetainingCapacity();
        try self.clipboard_buf.appendSlice(allocator, text);
    }

    fn addDataOffer(self: *State, offer: *wl.wl_data_offer) !void {
        const entry = try allocator.create(DataOfferState);
        entry.* = .{
            .owner = self,
            .offer = offer,
            .next = self.data_offers,
        };
        self.data_offers = entry;
        _ = wl.wl_data_offer_add_listener(offer, &data_offer_listener, entry);
    }

    fn findDataOffer(self: *State, offer: *wl.wl_data_offer) ?*DataOfferState {
        var it = self.data_offers;
        while (it) |entry| : (it = entry.next) {
            if (entry.offer == offer) return entry;
        }
        return null;
    }

    fn destroyDataOffer(self: *State, target: *DataOfferState) void {
        if (self.selection_offer == target) self.selection_offer = null;
        if (self.drag_offer == target) self.drag_offer = null;

        if (self.data_offers == target) {
            self.data_offers = target.next;
        } else {
            var it = self.data_offers;
            while (it) |entry| : (it = entry.next) {
                if (entry.next == target) {
                    entry.next = target.next;
                    break;
                }
            }
        }

        wl.wl_data_offer_destroy(target.offer);
        allocator.destroy(target);
    }

    fn destroyAllDataOffers(self: *State) void {
        while (self.data_offers) |entry| {
            self.destroyDataOffer(entry);
        }
    }

    fn destroyClipboardSource(self: *State) void {
        if (self.clipboard_source) |source| {
            wl.wl_data_source_destroy(source);
            self.clipboard_source = null;
        }
    }

    fn addOutput(self: *State, global_name: u32, output: *wl.wl_output) !void {
        const entry = try allocator.create(OutputState);
        entry.* = .{
            .global_name = global_name,
            .output = output,
            .next = self.outputs,
        };
        self.outputs = entry;
        _ = wl.wl_output_add_listener(output, &output_listener, self);
    }

    fn findOutput(self: *State, output: *wl.wl_output) ?*OutputState {
        var it = self.outputs;
        while (it) |entry| : (it = entry.next) {
            if (entry.output == output) return entry;
        }
        return null;
    }

    fn destroyOutputEntry(self: *State, target: *OutputState) void {
        if (self.outputs == target) {
            self.outputs = target.next;
        } else {
            var it = self.outputs;
            while (it) |entry| : (it = entry.next) {
                if (entry.next == target) {
                    entry.next = target.next;
                    break;
                }
            }
        }
        wl.wl_output_destroy(target.output);
        allocator.destroy(target);
    }

    fn removeOutputByGlobalName(self: *State, global_name: u32) void {
        var it = self.outputs;
        while (it) |entry| : (it = entry.next) {
            if (entry.global_name == global_name) {
                const was_entered = entry.entered;
                self.destroyOutputEntry(entry);
                if (was_entered and self.surface_preferred_scale == null) self.updateBufferMetrics();
                return;
            }
        }
    }

    fn destroyAllOutputs(self: *State) void {
        while (self.outputs) |entry| {
            self.destroyOutputEntry(entry);
        }
    }

    fn effectiveBufferScale(self: *const State) u32 {
        if (self.surface_preferred_scale) |preferred| return @max(preferred, 1);

        var scale: u32 = 1;
        var it = self.outputs;
        while (it) |entry| : (it = entry.next) {
            if (entry.entered) scale = @max(scale, entry.scale);
        }
        return scale;
    }

    fn setLogicalSize(self: *State, width: u32, height: u32) void {
        self.logical_width = @max(width, 1);
        self.logical_height = @max(height, 1);
        if (self.ctx) |ctx| ctx.setDimensions(self.logical_width, self.logical_height);
        self.updateBufferMetrics();
    }

    fn updateBufferMetrics(self: *State) void {
        const next_scale = self.effectiveBufferScale();
        const next_width = self.logical_width * next_scale;
        const next_height = self.logical_height * next_scale;
        const changed = self.buffer_scale != next_scale or self.buffer_width != next_width or self.buffer_height != next_height;

        self.buffer_scale = next_scale;
        self.buffer_width = next_width;
        self.buffer_height = next_height;

        if (self.surface) |surface| {
            if (self.compositor_version >= 3) {
                wl.wl_surface_set_buffer_scale(surface, @intCast(self.buffer_scale));
            }
        }
        if (changed) {
            if (self.egl_window) |window| {
                wl.wl_egl_window_resize(window, @intCast(self.buffer_width), @intCast(self.buffer_height), 0, 0);
            }
        }
        if (changed) self.needs_redraw = true;
    }
};

const DataOfferState = struct {
    owner: *State,
    offer: *wl.wl_data_offer,
    next: ?*DataOfferState = null,
    offers_text_utf8: bool = false,
    offers_utf8_string: bool = false,
    offers_text_plain: bool = false,
};

fn offerSupportsMime(mime: []const u8, expected: []const u8) bool {
    return std.mem.eql(u8, mime, expected);
}

fn preferredOfferMime(offer: *const DataOfferState) ?[*:0]const u8 {
    if (offer.offers_text_utf8) return clipboard_mime_utf8;
    if (offer.offers_utf8_string) return clipboard_mime_utf8_string;
    if (offer.offers_text_plain) return clipboard_mime_text;
    return null;
}

fn writeAll(fd: i32, bytes: []const u8) void {
    var written: usize = 0;
    while (written < bytes.len) {
        const chunk = posix.write(fd, bytes.ptr + written, bytes.len - written);
        if (chunk <= 0) return;
        written += @intCast(chunk);
    }
}

// ── Wayland listeners ──

const registry_listener = wl.wl_registry_listener{
    .global = &registryGlobal,
    .global_remove = &registryGlobalRemove,
};

fn registryGlobal(data: ?*anyopaque, registry: ?*wl.wl_registry, name: u32, interface: [*c]const u8, version: u32) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    const iface = std.mem.span(@as([*:0]const u8, @ptrCast(interface)));

    if (std.mem.eql(u8, iface, "wl_compositor")) {
        state.compositor_version = @min(version, 6);
        state.compositor = @ptrCast(wl.wl_registry_bind(registry, name, &wl.wl_compositor_interface, state.compositor_version));
    } else if (std.mem.eql(u8, iface, "xdg_wm_base")) {
        state.wm_base = @ptrCast(wl.wl_registry_bind(registry, name, &wl.xdg_wm_base_interface, @min(version, 2)));
        _ = wl.xdg_wm_base_add_listener(state.wm_base, &wm_base_listener, data);
    } else if (std.mem.eql(u8, iface, "wl_seat")) {
        state.seat = @ptrCast(wl.wl_registry_bind(registry, name, &wl.wl_seat_interface, @min(version, 5)));
        _ = wl.wl_seat_add_listener(state.seat, &seat_listener, data);
        ensureDataDevice(state, data);
    } else if (std.mem.eql(u8, iface, "wl_data_device_manager")) {
        state.data_device_manager = @ptrCast(wl.wl_registry_bind(registry, name, &wl.wl_data_device_manager_interface, @min(version, 3)));
        ensureDataDevice(state, data);
    } else if (std.mem.eql(u8, iface, "wl_output")) {
        const output = @as(?*wl.wl_output, @ptrCast(wl.wl_registry_bind(registry, name, &wl.wl_output_interface, @min(version, 4)))) orelse return;
        state.addOutput(name, output) catch wl.wl_output_destroy(output);
    }
}

fn registryGlobalRemove(data: ?*anyopaque, _: ?*wl.wl_registry, name: u32) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    state.removeOutputByGlobalName(name);
}

const wm_base_listener = wl.xdg_wm_base_listener{
    .ping = &wmBasePing,
};

fn wmBasePing(_: ?*anyopaque, wm_base: ?*wl.xdg_wm_base, serial: u32) callconv(.c) void {
    wl.xdg_wm_base_pong(wm_base, serial);
}

const xdg_surface_listener = wl.xdg_surface_listener{
    .configure = &xdgSurfaceConfigure,
};

fn xdgSurfaceConfigure(data: ?*anyopaque, xdg_surface: ?*wl.xdg_surface, serial: u32) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    wl.xdg_surface_ack_configure(xdg_surface, serial);
    state.configured = true;
    state.needs_redraw = true;
}

const xdg_toplevel_listener = wl.xdg_toplevel_listener{
    .configure = &xdgToplevelConfigure,
    .close = &xdgToplevelClose,
    .configure_bounds = &noopConfigureBounds,
    .wm_capabilities = &noopWmCapabilities,
};

fn noopConfigureBounds(_: ?*anyopaque, _: ?*wl.xdg_toplevel, _: i32, _: i32) callconv(.c) void {}
fn noopWmCapabilities(_: ?*anyopaque, _: ?*wl.xdg_toplevel, _: ?*wl.wl_array) callconv(.c) void {}

fn xdgToplevelConfigure(data: ?*anyopaque, _: ?*wl.xdg_toplevel, width: i32, height: i32, _: ?[*]wl.wl_array) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    if (width > 0 and height > 0) {
        state.setLogicalSize(@intCast(width), @intCast(height));
    }
    state.needs_redraw = true;
}

fn xdgToplevelClose(data: ?*anyopaque, _: ?*wl.xdg_toplevel) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    state.running = false;
}

fn ensureDataDevice(state: *State, data: ?*anyopaque) void {
    if (state.data_device != null) return;
    if (state.data_device_manager == null or state.seat == null) return;
    state.data_device = wl.wl_data_device_manager_get_data_device(state.data_device_manager, state.seat);
    if (state.data_device) |device| {
        _ = wl.wl_data_device_add_listener(device, &data_device_listener, data);
    }
}

const output_listener = wl.wl_output_listener{
    .geometry = &noopOutputGeometry,
    .mode = &noopOutputMode,
    .done = &noopOutputDone,
    .scale = &outputScale,
    .name = &noopOutputName,
    .description = &noopOutputDescription,
};

fn noopOutputGeometry(_: ?*anyopaque, _: ?*wl.wl_output, _: i32, _: i32, _: i32, _: i32, _: i32, _: [*c]const u8, _: [*c]const u8, _: i32) callconv(.c) void {}
fn noopOutputMode(_: ?*anyopaque, _: ?*wl.wl_output, _: u32, _: i32, _: i32, _: i32) callconv(.c) void {}
fn noopOutputDone(_: ?*anyopaque, _: ?*wl.wl_output) callconv(.c) void {}
fn noopOutputName(_: ?*anyopaque, _: ?*wl.wl_output, _: [*c]const u8) callconv(.c) void {}
fn noopOutputDescription(_: ?*anyopaque, _: ?*wl.wl_output, _: [*c]const u8) callconv(.c) void {}

fn outputScale(data: ?*anyopaque, output: ?*wl.wl_output, factor: i32) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    const wl_output = output orelse return;
    const entry = state.findOutput(wl_output) orelse return;
    entry.scale = @intCast(@max(factor, 1));
    if (entry.entered and state.surface_preferred_scale == null) state.updateBufferMetrics();
}

const surface_listener = wl.wl_surface_listener{
    .enter = &surfaceEnter,
    .leave = &surfaceLeave,
    .preferred_buffer_scale = &surfacePreferredBufferScale,
    .preferred_buffer_transform = &noopSurfacePreferredBufferTransform,
};

fn surfaceEnter(data: ?*anyopaque, _: ?*wl.wl_surface, output: ?*wl.wl_output) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    const wl_output = output orelse return;
    if (state.findOutput(wl_output)) |entry| {
        if (!entry.entered) {
            entry.entered = true;
            if (state.surface_preferred_scale == null) state.updateBufferMetrics();
        }
    }
}

fn surfaceLeave(data: ?*anyopaque, _: ?*wl.wl_surface, output: ?*wl.wl_output) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    const wl_output = output orelse return;
    if (state.findOutput(wl_output)) |entry| {
        if (entry.entered) {
            entry.entered = false;
            if (state.surface_preferred_scale == null) state.updateBufferMetrics();
        }
    }
}

fn surfacePreferredBufferScale(data: ?*anyopaque, _: ?*wl.wl_surface, factor: i32) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    state.surface_preferred_scale = @intCast(@max(factor, 1));
    state.updateBufferMetrics();
}

fn noopSurfacePreferredBufferTransform(_: ?*anyopaque, _: ?*wl.wl_surface, _: u32) callconv(.c) void {}

const seat_listener = wl.wl_seat_listener{
    .capabilities = &seatCapabilities,
    .name = &seatName,
};

fn seatName(_: ?*anyopaque, _: ?*wl.wl_seat, _: [*c]const u8) callconv(.c) void {}

fn seatCapabilities(data: ?*anyopaque, seat: ?*wl.wl_seat, caps: u32) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    const has_pointer = (caps & wl.WL_SEAT_CAPABILITY_POINTER) != 0;
    const has_keyboard = (caps & wl.WL_SEAT_CAPABILITY_KEYBOARD) != 0;

    if (has_pointer and state.pointer == null) {
        state.pointer = wl.wl_seat_get_pointer(seat);
        _ = wl.wl_pointer_add_listener(state.pointer, &pointer_listener, data);
    } else if (!has_pointer and state.pointer != null) {
        wl.wl_pointer_destroy(state.pointer);
        state.pointer = null;
    }

    if (has_keyboard and state.keyboard == null) {
        state.keyboard = wl.wl_seat_get_keyboard(seat);
        _ = wl.wl_keyboard_add_listener(state.keyboard, &keyboard_listener, data);
    } else if (!has_keyboard and state.keyboard != null) {
        wl.wl_keyboard_destroy(state.keyboard);
        state.keyboard = null;
    }

    ensureDataDevice(state, data);
}

const data_offer_listener = wl.wl_data_offer_listener{
    .offer = &dataOfferOffer,
    .source_actions = &noopDataOfferSourceActions,
    .action = &noopDataOfferAction,
};

fn dataOfferOffer(data: ?*anyopaque, _: ?*wl.wl_data_offer, mime_type: [*c]const u8) callconv(.c) void {
    const offer: *DataOfferState = @ptrCast(@alignCast(data));
    const mime = std.mem.span(@as([*:0]const u8, @ptrCast(mime_type)));
    if (offerSupportsMime(mime, clipboard_mime_utf8)) {
        offer.offers_text_utf8 = true;
    } else if (offerSupportsMime(mime, clipboard_mime_utf8_string)) {
        offer.offers_utf8_string = true;
    } else if (offerSupportsMime(mime, clipboard_mime_text)) {
        offer.offers_text_plain = true;
    }
}

fn noopDataOfferSourceActions(_: ?*anyopaque, _: ?*wl.wl_data_offer, _: u32) callconv(.c) void {}
fn noopDataOfferAction(_: ?*anyopaque, _: ?*wl.wl_data_offer, _: u32) callconv(.c) void {}

const data_source_listener = wl.wl_data_source_listener{
    .target = &noopDataSourceTarget,
    .send = &dataSourceSend,
    .cancelled = &dataSourceCancelled,
    .dnd_drop_performed = &noopDataSourceDropPerformed,
    .dnd_finished = &noopDataSourceFinished,
    .action = &noopDataSourceAction,
};

fn noopDataSourceTarget(_: ?*anyopaque, _: ?*wl.wl_data_source, _: [*c]const u8) callconv(.c) void {}
fn noopDataSourceDropPerformed(_: ?*anyopaque, _: ?*wl.wl_data_source) callconv(.c) void {}
fn noopDataSourceFinished(_: ?*anyopaque, _: ?*wl.wl_data_source) callconv(.c) void {}
fn noopDataSourceAction(_: ?*anyopaque, _: ?*wl.wl_data_source, _: u32) callconv(.c) void {}

fn dataSourceSend(data: ?*anyopaque, _: ?*wl.wl_data_source, _: [*c]const u8, fd: i32) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    defer _ = posix.close(fd);
    if (state.clipboard_buf.items.len == 0) return;
    writeAll(fd, state.clipboard_buf.items);
}

fn dataSourceCancelled(data: ?*anyopaque, source: ?*wl.wl_data_source) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    if (state.clipboard_source == source) state.clipboard_source = null;
    if (source) |clipboard_source| wl.wl_data_source_destroy(clipboard_source);
}

const data_device_listener = wl.wl_data_device_listener{
    .data_offer = &dataDeviceDataOffer,
    .enter = &dataDeviceEnter,
    .leave = &dataDeviceLeave,
    .motion = &noopDataDeviceMotion,
    .drop = &noopDataDeviceDrop,
    .selection = &dataDeviceSelection,
};

fn dataDeviceDataOffer(data: ?*anyopaque, _: ?*wl.wl_data_device, offer: ?*wl.wl_data_offer) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    const data_offer = offer orelse return;
    state.addDataOffer(data_offer) catch wl.wl_data_offer_destroy(data_offer);
}

fn dataDeviceEnter(data: ?*anyopaque, _: ?*wl.wl_data_device, _: u32, _: ?*wl.wl_surface, _: wl.wl_fixed_t, _: wl.wl_fixed_t, offer: ?*wl.wl_data_offer) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    if (state.drag_offer) |drag_offer| state.destroyDataOffer(drag_offer);
    if (offer) |drag_offer| {
        state.drag_offer = state.findDataOffer(drag_offer);
    }
}

fn dataDeviceLeave(data: ?*anyopaque, _: ?*wl.wl_data_device) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    if (state.drag_offer) |drag_offer| state.destroyDataOffer(drag_offer);
}

fn noopDataDeviceMotion(_: ?*anyopaque, _: ?*wl.wl_data_device, _: u32, _: wl.wl_fixed_t, _: wl.wl_fixed_t) callconv(.c) void {}
fn noopDataDeviceDrop(_: ?*anyopaque, _: ?*wl.wl_data_device) callconv(.c) void {}

fn dataDeviceSelection(data: ?*anyopaque, _: ?*wl.wl_data_device, offer: ?*wl.wl_data_offer) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    if (state.selection_offer) |selection_offer| {
        if (offer == null or selection_offer.offer != offer) {
            state.destroyDataOffer(selection_offer);
        }
    }
    if (offer) |selection_offer| {
        state.selection_offer = state.findDataOffer(selection_offer);
    }
}

const pointer_listener = wl.wl_pointer_listener{
    .enter = &pointerEnter,
    .leave = &pointerLeave,
    .motion = &pointerMotion,
    .button = &pointerButton,
    .axis = &pointerAxis,
    .frame = &noopPointerFrame,
    .axis_source = &noopAxisSource,
    .axis_stop = &noopAxisStop,
    .axis_discrete = &noopAxisDiscrete,
    .axis_value120 = &noopAxisValue120,
    .axis_relative_direction = &noopAxisRelDir,
};

fn noopPointerFrame(_: ?*anyopaque, _: ?*wl.wl_pointer) callconv(.c) void {}
fn noopAxisSource(_: ?*anyopaque, _: ?*wl.wl_pointer, _: u32) callconv(.c) void {}
fn noopAxisStop(_: ?*anyopaque, _: ?*wl.wl_pointer, _: u32, _: u32) callconv(.c) void {}
fn noopAxisDiscrete(_: ?*anyopaque, _: ?*wl.wl_pointer, _: u32, _: i32) callconv(.c) void {}
fn noopAxisValue120(_: ?*anyopaque, _: ?*wl.wl_pointer, _: u32, _: i32) callconv(.c) void {}
fn noopAxisRelDir(_: ?*anyopaque, _: ?*wl.wl_pointer, _: u32, _: u32) callconv(.c) void {}

// ── Keyboard listener ──

const keyboard_listener = wl.wl_keyboard_listener{
    .keymap = &keymapHandler,
    .enter = &noopKeyboardEnter,
    .leave = &noopKeyboardLeave,
    .key = &keyboardKey,
    .modifiers = &modifiersHandler,
    .repeat_info = &noopRepeatInfo,
};

fn keymapHandler(data: ?*anyopaque, _: ?*wl.wl_keyboard, format: u32, fd: i32, size: u32) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    defer _ = posix.close(fd);

    if (format != wl.WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1) return;

    if (state.xkb_ctx == null) {
        state.xkb_ctx = xkb.xkb_context_new(xkb.XKB_CONTEXT_NO_FLAGS);
        if (state.xkb_ctx == null) return;
    }

    const ptr = posix.mmap(null, size, posix.PROT_READ, posix.MAP_SHARED, fd, 0);
    if (ptr == posix.MAP_FAILED) return;
    const map_str: [*]const u8 = @ptrCast(ptr);
    defer _ = posix.munmap(@ptrCast(@constCast(map_str)), size);

    if (state.xkb_state) |s| xkb.xkb_state_unref(s);
    if (state.xkb_keymap) |k| xkb.xkb_keymap_unref(k);

    state.xkb_keymap = xkb.xkb_keymap_new_from_string(
        state.xkb_ctx,
        map_str,
        xkb.XKB_KEYMAP_FORMAT_TEXT_V1,
        xkb.XKB_KEYMAP_COMPILE_NO_FLAGS,
    );
    if (state.xkb_keymap) |km| {
        state.xkb_state = xkb.xkb_state_new(km);
    }
}

fn noopKeyboardEnter(_: ?*anyopaque, _: ?*wl.wl_keyboard, _: u32, _: ?*wl.wl_surface, _: ?*wl.wl_array) callconv(.c) void {}
fn noopKeyboardLeave(_: ?*anyopaque, _: ?*wl.wl_keyboard, _: u32, _: ?*wl.wl_surface) callconv(.c) void {}

fn modifiersHandler(data: ?*anyopaque, _: ?*wl.wl_keyboard, _: u32, mods_depressed: u32, mods_latched: u32, mods_locked: u32, group: u32) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    if (state.xkb_state) |s| {
        _ = xkb.xkb_state_update_mask(s, mods_depressed, mods_latched, mods_locked, 0, 0, group);
    }
}
fn noopRepeatInfo(_: ?*anyopaque, _: ?*wl.wl_keyboard, _: i32, _: i32) callconv(.c) void {}

fn evdevToKeycode(scancode: u32) goop.Event.Keycode {
    return switch (scancode) {
        14 => .backspace,
        111 => .delete,
        15 => .tab,
        28 => .enter,
        57 => .space,
        1 => .escape,
        42 => .left_shift,
        54 => .right_shift,
        29 => .left_ctrl,
        97 => .right_ctrl,
        30 => .a,
        46 => .c,
        47 => .v,
        45 => .x,
        102 => .home,
        105 => .left,
        106 => .right,
        103 => .up,
        108 => .down,
        107 => .end,
        else => .unknown,
    };
}

fn keyboardKey(data: ?*anyopaque, _: ?*wl.wl_keyboard, serial: u32, _: u32, key: u32, key_state: u32) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    const ctx = state.ctx orelse return;
    state.last_input_serial = serial;
    // Wayland delivers Linux evdev codes here. xkbcommon needs an extra +8,
    // but goop's logical-key mapping table is keyed by the raw evdev values.
    const scancode = key;
    const goop_state: goop.Event.Key.KeyState = if (key_state == 1) .pressed else .released;
    ctx.pushEvent(.{ .key = .{
        .scancode = scancode,
        .keycode = evdevToKeycode(scancode),
        .state = goop_state,
    } }) catch {};

    // On key press, use xkbcommon to produce a text event with the composed codepoint
    if (key_state == 1) {
        if (state.xkb_state) |xkb_st| {
            // xkb uses evdev keycodes (key + 8)
            const codepoint = xkb.xkb_state_key_get_utf32(xkb_st, key + 8);
            if (isPrintableTextCodepoint(codepoint)) {
                ctx.pushEvent(.{ .text = .{
                    .codepoint = @intCast(codepoint),
                } }) catch {};
            }
        }
    }
    state.needs_redraw = true;
}

fn pointerEnter(data: ?*anyopaque, _: ?*wl.wl_pointer, _: u32, _: ?*wl.wl_surface, sx: wl.wl_fixed_t, sy: wl.wl_fixed_t) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    state.mouse_x = fixedToF32(sx);
    state.mouse_y = fixedToF32(sy);
}

fn pointerLeave(_: ?*anyopaque, _: ?*wl.wl_pointer, _: u32, _: ?*wl.wl_surface) callconv(.c) void {}

fn pointerMotion(data: ?*anyopaque, _: ?*wl.wl_pointer, _: u32, sx: wl.wl_fixed_t, sy: wl.wl_fixed_t) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    const x = fixedToF32(sx);
    const y = fixedToF32(sy);
    state.mouse_x = x;
    state.mouse_y = y;
    if (state.ctx) |ctx| ctx.pushEvent(.{ .mouse_move = .{ .x = x, .y = y } }) catch {};
    state.needs_redraw = true;
}

fn pointerButton(data: ?*anyopaque, _: ?*wl.wl_pointer, serial: u32, time_ms: u32, button: u32, btn_state: u32) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    const ctx = state.ctx orelse return;
    state.last_input_serial = serial;
    const goop_button: goop.Event.MouseButton.Button = switch (button) {
        0x110 => .left, // BTN_LEFT
        0x111 => .right, // BTN_RIGHT
        0x112 => .middle, // BTN_MIDDLE
        else => return,
    };
    const goop_state: goop.Event.MouseButton.ButtonState = if (btn_state == 1) .pressed else .released;

    // Use last known mouse position from Wayland pointer events
    const mx = state.mouse_x;
    const my = state.mouse_y;
    ctx.pushEvent(.{ .mouse_button = .{
        .button = goop_button,
        .state = goop_state,
        .x = mx,
        .y = my,
        .timestamp_ms = time_ms,
    } }) catch {};
    state.needs_redraw = true;
}

fn pointerAxis(data: ?*anyopaque, _: ?*wl.wl_pointer, _: u32, axis: u32, value: wl.wl_fixed_t) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    const v = fixedToF32(value);
    const dx: f32 = if (axis == 1) v else 0; // WL_POINTER_AXIS_HORIZONTAL_SCROLL
    const dy: f32 = if (axis == 0) v else 0; // WL_POINTER_AXIS_VERTICAL_SCROLL
    if (state.ctx) |ctx| ctx.pushEvent(.{ .mouse_scroll = .{ .dx = dx, .dy = dy } }) catch {};
    state.needs_redraw = true;
}

fn fixedToF32(fixed: wl.wl_fixed_t) f32 {
    return @as(f32, @floatFromInt(fixed)) / 256.0;
}

// ── Frame callback ──

const frame_listener = wl.wl_callback_listener{
    .done = &frameDone,
};

fn frameDone(data: ?*anyopaque, callback: ?*wl.wl_callback, _: u32) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    wl.wl_callback_destroy(callback);
    state.frame_pending = false;
}

fn requestFrame(state: *State) void {
    if (state.frame_pending) return;
    const callback = wl.wl_surface_frame(state.surface) orelse return;
    _ = wl.wl_callback_add_listener(callback, &frame_listener, state);
    state.frame_pending = true;
}

// ── EGL setup ──

fn initEgl(state: *State, display: *wl.wl_display) !void {
    state.egl_display = egl.eglGetDisplay(@ptrCast(display)) orelse return error.EglNoDisplay;

    var major: egl.EGLint = 0;
    var minor: egl.EGLint = 0;
    if (egl.eglInitialize(state.egl_display, &major, &minor) == 0) return error.EglInitFailed;

    const attribs = [_]egl.EGLint{
        egl.EGL_SURFACE_TYPE,    egl.EGL_WINDOW_BIT,
        egl.EGL_RED_SIZE,        8,
        egl.EGL_GREEN_SIZE,      8,
        egl.EGL_BLUE_SIZE,       8,
        egl.EGL_ALPHA_SIZE,      8,
        egl.EGL_RENDERABLE_TYPE, egl.EGL_OPENGL_BIT,
        egl.EGL_SAMPLE_BUFFERS,  1,
        egl.EGL_SAMPLES,         4,
        egl.EGL_NONE,
    };
    var config: egl.EGLConfig = null;
    var num_configs: egl.EGLint = 0;
    if (egl.eglChooseConfig(state.egl_display, &attribs, &config, 1, &num_configs) == 0) return error.EglChooseConfigFailed;

    if (egl.eglBindAPI(egl.EGL_OPENGL_API) == 0) return error.EglBindApiFailed;

    const ctx_attribs = [_]egl.EGLint{
        egl.EGL_CONTEXT_MAJOR_VERSION,       3,
        egl.EGL_CONTEXT_MINOR_VERSION,       3,
        egl.EGL_CONTEXT_OPENGL_PROFILE_MASK, egl.EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
        egl.EGL_NONE,
    };
    state.egl_context = egl.eglCreateContext(state.egl_display, config, egl.EGL_NO_CONTEXT, &ctx_attribs) orelse return error.EglCreateContextFailed;

    state.egl_window = wl.wl_egl_window_create(state.surface, @intCast(state.buffer_width), @intCast(state.buffer_height)) orelse return error.EglWindowCreateFailed;

    state.egl_surface = egl.eglCreateWindowSurface(state.egl_display, config, @intFromPtr(state.egl_window), null) orelse return error.EglCreateSurfaceFailed;

    if (egl.eglMakeCurrent(state.egl_display, state.egl_surface, state.egl_surface, state.egl_context) == 0) return error.EglMakeCurrentFailed;
}

fn deinitEgl(state: *State) void {
    _ = egl.eglMakeCurrent(state.egl_display, egl.EGL_NO_SURFACE, egl.EGL_NO_SURFACE, egl.EGL_NO_CONTEXT);
    if (state.egl_surface != egl.EGL_NO_SURFACE) _ = egl.eglDestroySurface(state.egl_display, state.egl_surface);
    if (state.egl_context != egl.EGL_NO_CONTEXT) _ = egl.eglDestroyContext(state.egl_display, state.egl_context);
    if (state.egl_window != null) wl.wl_egl_window_destroy(state.egl_window);
    if (state.egl_display != egl.EGL_NO_DISPLAY) _ = egl.eglTerminate(state.egl_display);
}

// ── Widget tree ──

fn freeOptionalOwnedSlice(buf: *?[]u8) void {
    if (buf.*) |slice| allocator.free(slice);
    buf.* = null;
}

fn clearUiStrings(state: *State) void {
    for (state.ui_strings.items) |text| allocator.free(text);
    state.ui_strings.clearRetainingCapacity();
}

fn clearBreadcrumbPaths(state: *State) void {
    for (state.breadcrumb_paths.items) |path| allocator.free(path);
    state.breadcrumb_paths.clearRetainingCapacity();
}

fn clearPlaces(state: *State) void {
    for (state.places.items) |place| allocator.free(place.path);
    state.places.clearRetainingCapacity();
}

fn clearEntries(state: *State) void {
    for (state.entries.items) |entry| {
        allocator.free(entry.name);
        allocator.free(entry.path);
    }
    state.entries.clearRetainingCapacity();
}

fn clearUiTracking(state: *State) void {
    state.ui_root = null;
    state.btn_back = null;
    state.btn_up = null;
    state.btn_home = null;
    state.btn_refresh = null;
    state.nav_splitter = null;
    state.detail_splitter = null;
    state.asset_table = null;
    state.place_handles.clearRetainingCapacity();
    state.breadcrumb_handles.clearRetainingCapacity();
    state.row_handles.clearRetainingCapacity();
    clearUiStrings(state);
    clearBreadcrumbPaths(state);
}

fn deinitBrowserState(state: *State) void {
    clearUiTracking(state);
    clearEntries(state);
    clearPlaces(state);
    for (state.history.items) |path| allocator.free(path);
    state.history.deinit(allocator);
    state.places.deinit(allocator);
    state.entries.deinit(allocator);
    state.place_handles.deinit(allocator);
    state.breadcrumb_handles.deinit(allocator);
    state.breadcrumb_paths.deinit(allocator);
    state.row_handles.deinit(allocator);
    state.ui_strings.deinit(allocator);
    if (state.current_dir.len > 0) allocator.free(state.current_dir);
    state.current_dir = &.{};
    freeOptionalOwnedSlice(&state.selected_path);
    freeOptionalOwnedSlice(&state.last_click_path);
}

fn allocUiString(state: *State, comptime fmt: []const u8, args: anytype) ![]const u8 {
    const text = try std.fmt.allocPrint(allocator, fmt, args);
    try state.ui_strings.append(allocator, text);
    return text;
}

fn allocUiUtf8Lossy(state: *State, bytes: []const u8) ![]const u8 {
    return allocUiString(state, "{f}", .{std.unicode.fmtUtf8(bytes)});
}

fn currentWorkingDirectoryAlloc(alloc: std.mem.Allocator) ![]u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd = posix.getcwd(&buf, buf.len) orelse return error.GetCwdFailed;
    return alloc.dupe(u8, std.mem.span(cwd));
}

fn normalizeDirectoryPath(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    if (path.len == 0) return alloc.dupe(u8, "/");
    var end = path.len;
    while (end > 1 and path[end - 1] == '/') end -= 1;
    return alloc.dupe(u8, path[0..end]);
}

fn ensureDirectoryOpenable(path: []const u8) !void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const dir = c_fs.opendir(path_z.ptr) orelse return error.NotDir;
    defer _ = c_fs.closedir(dir);
}

fn joinPath(alloc: std.mem.Allocator, dir_path: []const u8, name: []const u8) ![]u8 {
    if (std.mem.eql(u8, dir_path, "/")) return std.fmt.allocPrint(alloc, "/{s}", .{name});
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir_path, name });
}

fn parentPathAlloc(alloc: std.mem.Allocator, path: []const u8) !?[]u8 {
    if (path.len == 0 or std.mem.eql(u8, path, "/")) return null;

    var end = path.len;
    while (end > 1 and path[end - 1] == '/') end -= 1;
    const trimmed = path[0..end];
    const slash_index = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse {
        return try alloc.dupe(u8, "/");
    };
    if (slash_index == 0) return try alloc.dupe(u8, "/");
    return try alloc.dupe(u8, trimmed[0..slash_index]);
}

fn fileTypeLabel(name: []const u8) []const u8 {
    const ext = std.fs.path.extension(name);
    if (std.ascii.eqlIgnoreCase(ext, ".zig")) return "Zig source";
    if (std.ascii.eqlIgnoreCase(ext, ".md")) return "Markdown";
    if (std.ascii.eqlIgnoreCase(ext, ".txt")) return "Text file";
    if (std.ascii.eqlIgnoreCase(ext, ".json")) return "JSON";
    if (std.ascii.eqlIgnoreCase(ext, ".zon")) return "ZON";
    if (std.ascii.eqlIgnoreCase(ext, ".nix")) return "Nix expression";
    if (std.ascii.eqlIgnoreCase(ext, ".toml")) return "TOML";
    if (std.ascii.eqlIgnoreCase(ext, ".yaml") or std.ascii.eqlIgnoreCase(ext, ".yml")) return "YAML";
    if (std.ascii.eqlIgnoreCase(ext, ".png")) return "PNG image";
    if (std.ascii.eqlIgnoreCase(ext, ".jpg") or std.ascii.eqlIgnoreCase(ext, ".jpeg")) return "JPEG image";
    if (std.ascii.eqlIgnoreCase(ext, ".svg")) return "SVG";
    if (std.ascii.eqlIgnoreCase(ext, ".pdf")) return "PDF";
    if (std.ascii.eqlIgnoreCase(ext, ".so")) return "Shared library";
    if (std.ascii.eqlIgnoreCase(ext, ".a")) return "Static library";
    if (std.ascii.eqlIgnoreCase(ext, ".o")) return "Object file";
    return "File";
}

fn browserEntryKind(mode: c_fs.mode_t) BrowserEntryKind {
    const masked = mode & c_fs.S_IFMT;
    if (masked == c_fs.S_IFDIR) return .directory;
    if (masked == c_fs.S_IFREG) return .file;
    if (masked == c_fs.S_IFLNK) return .symlink;
    return .other;
}

fn formatTimestampText(buffer: []u8, unix_seconds: i64) []const u8 {
    if (unix_seconds <= 0) return "";

    var t: posix.time_t = @intCast(unix_seconds);
    var tm_buf: posix.struct_tm = undefined;
    if (posix.localtime_r(&t, &tm_buf) == null) return "";

    const written = posix.strftime(buffer.ptr, buffer.len, "%Y-%m-%d %H:%M", &tm_buf);
    return buffer[0..written];
}

fn formatSizeText(buffer: []u8, kind: BrowserEntryKind, size_bytes: u64) []const u8 {
    if (kind == .directory) return "";
    if (size_bytes < 1024) return std.fmt.bufPrint(buffer, "{} B", .{size_bytes}) catch "";

    const units = [_][]const u8{ "KB", "MB", "GB", "TB" };
    var scaled = @as(f64, @floatFromInt(size_bytes));
    var unit_index: usize = 0;
    while (scaled >= 1024 and unit_index + 1 < units.len) : (unit_index += 1) {
        scaled /= 1024;
    }
    return std.fmt.bufPrint(buffer, "{d:.1} {s}", .{ scaled, units[unit_index] }) catch "";
}

fn appendPlaceIfDirectory(state: *State, label: []const u8, path: []const u8) !void {
    const normalized = try normalizeDirectoryPath(allocator, path);
    errdefer allocator.free(normalized);
    ensureDirectoryOpenable(normalized) catch return;

    for (state.places.items) |existing| {
        if (std.mem.eql(u8, existing.path, normalized)) return;
    }

    try state.places.append(allocator, .{ .label = label, .path = normalized });
}

fn refreshPlaces(state: *State) !void {
    clearPlaces(state);

    if (c_io.getenv("HOME")) |home_raw| {
        const home = std.mem.span(@as([*:0]const u8, @ptrCast(home_raw)));
        try appendPlaceIfDirectory(state, "Home", home);

        const desktop = try std.fmt.allocPrint(allocator, "{s}/Desktop", .{home});
        defer allocator.free(desktop);
        try appendPlaceIfDirectory(state, "Desktop", desktop);

        const documents = try std.fmt.allocPrint(allocator, "{s}/Documents", .{home});
        defer allocator.free(documents);
        try appendPlaceIfDirectory(state, "Documents", documents);

        const downloads = try std.fmt.allocPrint(allocator, "{s}/Downloads", .{home});
        defer allocator.free(downloads);
        try appendPlaceIfDirectory(state, "Downloads", downloads);

        const projects = try std.fmt.allocPrint(allocator, "{s}/projects", .{home});
        defer allocator.free(projects);
        try appendPlaceIfDirectory(state, "Projects", projects);
    }

    if (state.current_dir.len > 0) try appendPlaceIfDirectory(state, "Workspace", state.current_dir);
    try appendPlaceIfDirectory(state, "Temp", "/tmp");
    try appendPlaceIfDirectory(state, "Root", "/");
}

fn sortFieldLess(state: *const State, a: BrowserEntry, b: BrowserEntry) bool {
    return switch (state.sort_column) {
        .name => switch (state.sort_direction) {
            .ascending => std.ascii.lessThanIgnoreCase(a.name, b.name),
            .descending => std.ascii.lessThanIgnoreCase(b.name, a.name),
        },
        .modified => switch (state.sort_direction) {
            .ascending => a.modified_unix < b.modified_unix,
            .descending => a.modified_unix > b.modified_unix,
        },
        .kind => switch (state.sort_direction) {
            .ascending => std.ascii.lessThanIgnoreCase(a.typeLabel(), b.typeLabel()),
            .descending => std.ascii.lessThanIgnoreCase(b.typeLabel(), a.typeLabel()),
        },
        .size => switch (state.sort_direction) {
            .ascending => a.size_bytes < b.size_bytes,
            .descending => a.size_bytes > b.size_bytes,
        },
    };
}

fn browserEntryLessThan(state: *const State, a: BrowserEntry, b: BrowserEntry) bool {
    if (a.isDirectory() != b.isDirectory()) return a.isDirectory();
    if (sortFieldLess(state, a, b)) return true;
    if (sortFieldLess(state, b, a)) return false;
    return std.ascii.lessThanIgnoreCase(a.name, b.name);
}

fn sortDirectoryEntries(state: *State) void {
    std.mem.sort(BrowserEntry, state.entries.items, state, browserEntryLessThan);
}

fn setSelectedPath(state: *State, path: ?[]const u8) !void {
    freeOptionalOwnedSlice(&state.selected_path);
    if (path) |value| state.selected_path = try allocator.dupe(u8, value);
}

fn setLastClickPath(state: *State, path: ?[]const u8) !void {
    freeOptionalOwnedSlice(&state.last_click_path);
    if (path) |value| state.last_click_path = try allocator.dupe(u8, value);
}

fn loadDirectoryEntries(state: *State) !void {
    clearEntries(state);

    const dir_path_z = try allocator.dupeZ(u8, state.current_dir);
    defer allocator.free(dir_path_z);
    const dir = c_fs.opendir(dir_path_z.ptr) orelse return error.OpenDirFailed;
    defer _ = c_fs.closedir(dir);

    while (true) {
        const entry_ptr = c_fs.readdir(dir);
        if (entry_ptr == null) break;

        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry_ptr.*.d_name)));
        if (name.len == 0) continue;
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;

        const full_path = try joinPath(allocator, state.current_dir, name);
        errdefer allocator.free(full_path);

        const full_path_z = try allocator.dupeZ(u8, full_path);
        defer allocator.free(full_path_z);

        var stat_buf: c_fs.struct_stat = undefined;
        if (c_fs.lstat(full_path_z.ptr, &stat_buf) != 0) {
            allocator.free(full_path);
            continue;
        }

        const entry_name = try allocator.dupe(u8, name);
        errdefer allocator.free(entry_name);

        var entry = BrowserEntry{
            .name = entry_name,
            .path = full_path,
            .kind = browserEntryKind(stat_buf.st_mode),
            .size_bytes = @intCast(@max(stat_buf.st_size, 0)),
            .modified_unix = @intCast(stat_buf.st_mtim.tv_sec),
        };
        const modified = formatTimestampText(entry.modified_buf[0..], entry.modified_unix);
        entry.modified_len = @intCast(modified.len);
        const size = formatSizeText(entry.size_buf[0..], entry.kind, entry.size_bytes);
        entry.size_len = @intCast(size.len);
        try state.entries.append(allocator, entry);
    }

    sortDirectoryEntries(state);

    if (state.selected_path) |selected_path| {
        var found = false;
        for (state.entries.items) |entry| {
            if (std.mem.eql(u8, entry.path, selected_path)) {
                found = true;
                break;
            }
        }
        if (!found) freeOptionalOwnedSlice(&state.selected_path);
    }
}

fn selectedEntryIndex(state: *const State) ?usize {
    const selected_path = state.selected_path orelse return null;
    for (state.entries.items, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.path, selected_path)) return index;
    }
    return null;
}

fn selectedEntry(state: *const State) ?*const BrowserEntry {
    const index = selectedEntryIndex(state) orelse return null;
    return &state.entries.items[index];
}

fn setCurrentDirectory(state: *State, path: []const u8, push_history: bool) !bool {
    const normalized = try normalizeDirectoryPath(allocator, path);
    errdefer allocator.free(normalized);
    try ensureDirectoryOpenable(normalized);

    if (state.current_dir.len > 0 and std.mem.eql(u8, state.current_dir, normalized)) {
        allocator.free(normalized);
        try loadDirectoryEntries(state);
        return true;
    }

    if (push_history) {
        while (state.history.items.len > state.history_index + 1) allocator.free(state.history.pop().?);
        try state.history.append(allocator, try allocator.dupe(u8, normalized));
        state.history_index = state.history.items.len - 1;
    }

    if (state.current_dir.len > 0) allocator.free(state.current_dir);
    state.current_dir = normalized;
    freeOptionalOwnedSlice(&state.selected_path);
    freeOptionalOwnedSlice(&state.last_click_path);
    state.last_click_ns = 0;
    try loadDirectoryEntries(state);
    return true;
}

fn navigateBack(state: *State) !bool {
    if (state.history_index == 0 or state.history.items.len == 0) return false;
    state.history_index -= 1;
    return setCurrentDirectory(state, state.history.items[state.history_index], false);
}

fn navigateUp(state: *State) !bool {
    const parent = try parentPathAlloc(allocator, state.current_dir);
    defer if (parent) |path| allocator.free(path);
    const parent_path = parent orelse return false;
    return setCurrentDirectory(state, parent_path, true);
}

fn refreshCurrentDirectory(state: *State) !void {
    freeOptionalOwnedSlice(&state.last_click_path);
    state.last_click_ns = 0;
    try loadDirectoryEntries(state);
}

fn initializeBrowserState(state: *State) !void {
    const cwd = try currentWorkingDirectoryAlloc(allocator);
    defer allocator.free(cwd);
    _ = try setCurrentDirectory(state, cwd, true);
    try refreshPlaces(state);
}

fn addTextCell(ctx: *goop.Context, row: goop.NodeHandle, text: []const u8) !void {
    const cell = try ctx.tree.addChild(row, .{ .table_cell = .{} });
    _ = try ctx.tree.addChild(cell, .{ .text = .{ .content = text } });
}

fn buildWidgetTree(state: *State) !void {
    const ctx = state.ctx orelse return error.NoContext;

    if (state.ui_root) |root| {
        if (ctx.isAlive(root)) try ctx.removeWidget(root);
    }
    clearUiTracking(state);

    state.ui_root = try ctx.tree.addRoot(.{ .container = .{ .direction = .column } });
    const root = state.ui_root.?;

    const header = try ctx.tree.addChild(root, .{ .toolbar = .{} });
    ctx.tree.get(header).style_override = .{
        .bg = .{ .r = 233, .g = 236, .b = 240, .a = 255 },
        .border = .{ .r = 206, .g = 212, .b = 220, .a = 255 },
        .padding = goop.style.Edges.symmetric(10, 8),
        .border_radius = 0,
    };
    state.btn_back = try ctx.tree.addChild(header, .{ .button = .{ .label = "Back" } });
    state.btn_up = try ctx.tree.addChild(header, .{ .button = .{ .label = "Up" } });
    state.btn_home = try ctx.tree.addChild(header, .{ .button = .{ .label = "Home" } });
    state.btn_refresh = try ctx.tree.addChild(header, .{ .button = .{ .label = "Refresh" } });
    _ = try ctx.tree.addChild(header, .{ .text = .{ .content = try allocUiString(state, "Browsing {f}", .{std.unicode.fmtUtf8(state.current_dir)}) } });

    state.nav_splitter = try ctx.tree.addChild(root, .{ .splitter = .{
        .direction = .row,
        .ratio = state.nav_ratio,
        .min_first = 180,
        .min_second = 420,
        .thickness = 8,
    } });

    const sidebar = try ctx.tree.addChild(state.nav_splitter.?, .{ .container = .{ .direction = .column } });
    ctx.tree.get(sidebar).style_override = .{
        .bg = .{ .r = 240, .g = 243, .b = 247, .a = 255 },
        .border = .{ .r = 212, .g = 218, .b = 226, .a = 255 },
        .padding = goop.style.Edges.symmetric(10, 10),
        .border_radius = 0,
    };
    _ = try ctx.tree.addChild(sidebar, .{ .text = .{ .content = "Places" } });
    const places_list = try ctx.tree.addChild(sidebar, .{ .list_box = .{ .selection_mode = .single } });
    for (state.places.items) |place| {
        const handle = try ctx.tree.addChild(places_list, .{ .selectable = .{
            .label = place.label,
            .selected = std.mem.eql(u8, place.path, state.current_dir),
        } });
        try state.place_handles.append(allocator, handle);
    }

    const content = try ctx.tree.addChild(state.nav_splitter.?, .{ .container = .{ .direction = .column } });
    ctx.tree.get(content).style_override = .{
        .bg = .{ .r = 247, .g = 248, .b = 250, .a = 255 },
        .border = .{ .r = 212, .g = 218, .b = 226, .a = 255 },
        .padding = goop.style.Edges.symmetric(10, 10),
        .border_radius = 0,
    };

    const breadcrumb_bar = try ctx.tree.addChild(content, .{ .toolbar = .{} });
    ctx.tree.get(breadcrumb_bar).style_override = .{
        .bg = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
        .border = .{ .r = 214, .g = 220, .b = 228, .a = 255 },
        .padding = goop.style.Edges.symmetric(8, 6),
        .border_radius = 8,
    };
    const root_button = try ctx.tree.addChild(breadcrumb_bar, .{ .button = .{ .label = "/" } });
    try state.breadcrumb_handles.append(allocator, root_button);
    try state.breadcrumb_paths.append(allocator, try allocator.dupe(u8, "/"));
    if (!std.mem.eql(u8, state.current_dir, "/")) {
        var start: usize = 1;
        while (start < state.current_dir.len) {
            const end = std.mem.indexOfScalarPos(u8, state.current_dir, start, '/') orelse state.current_dir.len;
            _ = try ctx.tree.addChild(breadcrumb_bar, .{ .text = .{ .content = "/" } });
            const segment = state.current_dir[start..end];
            const handle = try ctx.tree.addChild(breadcrumb_bar, .{ .button = .{ .label = try allocUiUtf8Lossy(state, segment) } });
            try state.breadcrumb_handles.append(allocator, handle);
            try state.breadcrumb_paths.append(allocator, try allocator.dupe(u8, state.current_dir[0..end]));
            start = end + 1;
        }
    }

    state.detail_splitter = try ctx.tree.addChild(content, .{ .splitter = .{
        .direction = .row,
        .ratio = state.detail_ratio,
        .min_first = 360,
        .min_second = 220,
        .thickness = 8,
    } });

    const file_panel = try ctx.tree.addChild(state.detail_splitter.?, .{ .container = .{ .direction = .column } });
    ctx.tree.get(file_panel).style_override = .{
        .bg = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
        .border = .{ .r = 214, .g = 220, .b = 228, .a = 255 },
        .padding = goop.style.Edges.symmetric(8, 8),
        .border_radius = 8,
    };

    state.asset_table = try ctx.tree.addChild(file_panel, .{ .table = .{
        .columns = 4,
        .resizable = true,
        .sortable = true,
        .selection_mode = .single,
        .min_column_width = 96,
    } });
    {
        const table = &ctx.tree.get(state.asset_table.?).kind.table;
        table.column_weights[0] = state.table_column_weights[0];
        table.column_weights[1] = state.table_column_weights[1];
        table.column_weights[2] = state.table_column_weights[2];
        table.column_weights[3] = state.table_column_weights[3];
        table.sorted_column = @intFromEnum(state.sort_column);
        table.sort_direction = switch (state.sort_direction) {
            .ascending => .ascending,
            .descending => .descending,
        };
    }

    const header_row = try ctx.tree.addChild(state.asset_table.?, .{ .table_row = .{ .header = true } });
    try addTextCell(ctx, header_row, "Name");
    try addTextCell(ctx, header_row, "Modified");
    try addTextCell(ctx, header_row, "Type");
    try addTextCell(ctx, header_row, "Size");

    for (state.entries.items) |entry| {
        const row = try ctx.tree.addChild(state.asset_table.?, .{ .table_row = .{
            .selected = if (state.selected_path) |selected_path| std.mem.eql(u8, entry.path, selected_path) else false,
        } });
        try state.row_handles.append(allocator, row);
        try addTextCell(ctx, row, try allocUiUtf8Lossy(state, entry.name));
        try addTextCell(ctx, row, entry.modifiedText());
        try addTextCell(ctx, row, entry.typeLabel());
        try addTextCell(ctx, row, entry.sizeText());
    }

    if (state.entries.items.len == 0) {
        _ = try ctx.tree.addChild(file_panel, .{ .text = .{ .content = "This directory is empty." } });
    }

    const detail_panel = try ctx.tree.addChild(state.detail_splitter.?, .{ .container = .{ .direction = .column } });
    ctx.tree.get(detail_panel).style_override = .{
        .bg = .{ .r = 250, .g = 251, .b = 253, .a = 255 },
        .border = .{ .r = 214, .g = 220, .b = 228, .a = 255 },
        .padding = goop.style.Edges.symmetric(10, 10),
        .border_radius = 8,
    };
    _ = try ctx.tree.addChild(detail_panel, .{ .text = .{ .content = "Details" } });

    var directory_count: usize = 0;
    for (state.entries.items) |entry| {
        if (entry.isDirectory()) directory_count += 1;
    }
    const file_count = state.entries.items.len - directory_count;

    if (selectedEntry(state)) |entry| {
        _ = try ctx.tree.addChild(detail_panel, .{ .text = .{ .content = try allocUiUtf8Lossy(state, entry.name) } });
        _ = try ctx.tree.addChild(detail_panel, .{ .text = .{ .content = try allocUiString(state, "Type: {s}", .{entry.typeLabel()}) } });
        _ = try ctx.tree.addChild(detail_panel, .{ .text = .{ .content = try allocUiString(state, "Modified: {s}", .{entry.modifiedText()}) } });
        _ = try ctx.tree.addChild(detail_panel, .{ .text = .{ .content = try allocUiString(state, "Size: {s}", .{if (entry.sizeText().len > 0) entry.sizeText() else "—"}) } });
        _ = try ctx.tree.addChild(detail_panel, .{ .text = .{ .content = try allocUiString(state, "Path: {f}", .{std.unicode.fmtUtf8(entry.path)}) } });
        _ = try ctx.tree.addChild(detail_panel, .{ .text = .{ .content = if (entry.isDirectory()) "Click again to open this directory." else "Files stay selected for inspection." } });
    } else {
        const directory_name = if (std.mem.eql(u8, state.current_dir, "/")) "/" else std.fs.path.basename(state.current_dir);
        _ = try ctx.tree.addChild(detail_panel, .{ .text = .{ .content = try allocUiUtf8Lossy(state, directory_name) } });
        _ = try ctx.tree.addChild(detail_panel, .{ .text = .{ .content = try allocUiString(state, "Path: {f}", .{std.unicode.fmtUtf8(state.current_dir)}) } });
        _ = try ctx.tree.addChild(detail_panel, .{ .text = .{ .content = try allocUiString(state, "{d} directories", .{directory_count}) } });
        _ = try ctx.tree.addChild(detail_panel, .{ .text = .{ .content = try allocUiString(state, "{d} files", .{file_count}) } });
        _ = try ctx.tree.addChild(detail_panel, .{ .text = .{ .content = "Select an item, or use Back, Up, Home, and Places to move around." } });
    }

    const status_bar = try ctx.tree.addChild(root, .{ .status_bar = .{} });
    ctx.tree.get(status_bar).style_override = .{
        .bg = .{ .r = 233, .g = 236, .b = 240, .a = 255 },
        .border = .{ .r = 206, .g = 212, .b = 220, .a = 255 },
        .padding = goop.style.Edges.symmetric(10, 7),
        .border_radius = 0,
    };
    _ = try ctx.tree.addChild(status_bar, .{ .text = .{ .content = try allocUiString(state, "{d} items", .{state.entries.items.len}) } });
    _ = try ctx.tree.addChild(status_bar, .{ .text = .{ .content = try allocUiString(state, "{d} selected", .{if (state.selected_path == null) @as(usize, 0) else @as(usize, 1)}) } });
    _ = try ctx.tree.addChild(status_bar, .{ .text = .{ .content = try allocUiString(state, "Location: {f}", .{std.unicode.fmtUtf8(state.current_dir)}) } });
}

// ── Font loading ──

fn loadFont(alloc: std.mem.Allocator) ![]u8 {
    if (fontPathFromEnv()) |path| {
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
    const raw = c_io.getenv("GOOP_DEMO_FONT_PATH") orelse return null;
    return std.mem.span(@as([*:0]const u8, @ptrCast(raw)));
}

fn readFile(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    var path_z: [1024]u8 = undefined;
    if (path.len >= path_z.len) return error.PathTooLong;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;
    const fp = c_io.fopen(&path_z, "rb") orelse return error.FileNotFound;
    defer _ = c_io.fclose(fp);
    _ = c_io.fseek(fp, 0, c_io.SEEK_END);
    const tell = c_io.ftell(fp);
    if (tell < 0) return error.ReadFailed;
    const size: usize = @intCast(tell);
    _ = c_io.fseek(fp, 0, c_io.SEEK_SET);
    const buf = try alloc.alloc(u8, size);
    errdefer alloc.free(buf);
    const read = c_io.fread(buf.ptr, 1, size, fp);
    if (read != size) {
        alloc.free(buf);
        return error.ReadFailed;
    }
    std.debug.print("loaded font: {s} ({} bytes)\n", .{ path, size });
    return buf;
}

// ── Main ──

fn parseTimeout() ?u64 {
    const raw = c_io.getenv("GOOP_DEMO_TIMEOUT") orelse return null;
    const val = std.mem.span(@as([*:0]const u8, @ptrCast(raw)));
    const secs = std.fmt.parseFloat(f64, val) catch return null;
    if (secs <= 0) return null;
    return @intFromFloat(secs * @as(f64, @floatFromInt(std.time.ns_per_s)));
}

fn getMonotonicNs() u64 {
    var ts: posix.struct_timespec = undefined;
    _ = posix.clock_gettime(posix.CLOCK_MONOTONIC, &ts);
    return @intCast(@as(i128, ts.tv_sec) * std.time.ns_per_s + ts.tv_nsec);
}

pub fn main() !void {
    // Connect to Wayland
    const display = wl.wl_display_connect(null) orelse {
        std.debug.print("failed to connect to wayland display\n", .{});
        return error.NoDisplay;
    };
    defer wl.wl_display_disconnect(display);

    var state = State{};
    state.display = display;
    state.timeout_ns = parseTimeout();
    if (state.timeout_ns) |t| {
        std.debug.print("demo will exit after {d:.1}s\n", .{@as(f64, @floatFromInt(t)) / std.time.ns_per_s});
    }
    if (state.timeout_ns != null) {
        _ = posix.clock_gettime(posix.CLOCK_MONOTONIC, &state.start_time);
    }

    // Bind globals
    const registry = wl.wl_display_get_registry(display) orelse return error.NoRegistry;
    _ = wl.wl_registry_add_listener(registry, &registry_listener, &state);
    _ = wl.wl_display_roundtrip(display);

    if (state.compositor == null) return error.NoCompositor;
    if (state.wm_base == null) return error.NoXdgWmBase;

    // Create surface
    state.surface = wl.wl_compositor_create_surface(state.compositor) orelse return error.NoSurface;
    _ = wl.wl_surface_add_listener(state.surface, &surface_listener, &state);
    state.xdg_surface = wl.xdg_wm_base_get_xdg_surface(state.wm_base, state.surface) orelse return error.NoXdgSurface;
    _ = wl.xdg_surface_add_listener(state.xdg_surface, &xdg_surface_listener, &state);
    state.xdg_toplevel = wl.xdg_surface_get_toplevel(state.xdg_surface) orelse return error.NoToplevel;
    _ = wl.xdg_toplevel_add_listener(state.xdg_toplevel, &xdg_toplevel_listener, &state);
    wl.xdg_toplevel_set_title(state.xdg_toplevel, "goop files");
    wl.xdg_toplevel_set_app_id(state.xdg_toplevel, "goop-files");
    wl.wl_surface_commit(state.surface.?);
    _ = wl.wl_display_roundtrip(display);

    // EGL + OpenGL
    try initEgl(&state, display);
    defer deinitEgl(&state);

    // Load font
    const font_data = loadFont(allocator) catch |err| {
        std.debug.print("failed to load font: {}\n", .{err});
        return err;
    };
    defer allocator.free(font_data);

    var font = try snail.Font.init(font_data);
    defer font.deinit();

    // Build glyph atlas for printable ASCII
    var codepoints: [95]u32 = undefined;
    for (0..95) |i| codepoints[i] = @intCast(32 + i);
    var atlas = try snail.Atlas.init(allocator, &font, &codepoints);
    defer atlas.deinit();

    const line_metrics = fontLineMetrics(&font);
    var text_measure = SnailTextCtx{
        .allocator = allocator,
        .font = &font,
        .atlas = &atlas,
        .glyph_cache = snail.ttf.GlyphCache.init(allocator),
        .ascent_units = line_metrics.ascent,
        .descent_units = line_metrics.descent,
    };
    defer text_measure.glyph_cache.deinit();
    const text_measure_ctx = goop.TextMeasureCtx{
        .measureFn = &snailMeasureText,
        .user_data = @ptrCast(&text_measure),
    };

    // goop context + widget tree
    var ctx = try goop.Context.init(allocator, .{
        .width = state.logical_width,
        .height = state.logical_height,
        .theme = .{
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
        },
    });
    defer ctx.deinit();
    state.ctx = &ctx;
    ctx.clipboard = state.clipboard();
    try initializeBrowserState(&state);
    try buildWidgetTree(&state);

    // GL renderer (with snail text support)
    var renderer = try render.Renderer.init(state.buffer_width, state.buffer_height, &font, &atlas);
    defer renderer.deinit();
    renderer.clear_color = .{ 0.95, 0.96, 0.97, 1.0 };

    std.debug.print("goop file manager running (logical {}x{}, scale {}, buffer {}x{})\n", .{
        state.logical_width,
        state.logical_height,
        state.buffer_scale,
        state.buffer_width,
        state.buffer_height,
    });

    // Wayland dispatch/render loop. Redraws are paced by frame callbacks.
    while (state.running) {
        // Check timeout
        if (state.timeout_ns) |t| {
            const now = getMonotonicNs();
            const start = @as(u64, @intCast(@as(i128, state.start_time.tv_sec) * std.time.ns_per_s + state.start_time.tv_nsec));
            const elapsed = now - start;
            if (elapsed >= t) {
                std.debug.print("demo timeout reached, exiting\n", .{});
                break;
            }
        }

        // Dispatch events — use poll with timeout when --timeout is set
        if (state.timeout_ns != null) {
            // Non-blocking: flush + prepare read, poll with 100ms timeout, then read
            while (wl.wl_display_prepare_read(display) != 0)
                _ = wl.wl_display_dispatch_pending(display);
            _ = wl.wl_display_flush(display);

            var pfd = posix.pollfd{
                .fd = wl.wl_display_get_fd(display),
                .events = posix.POLLIN,
                .revents = 0,
            };
            const poll_ret = posix.poll(&pfd, 1, 100);
            if (poll_ret > 0) {
                _ = wl.wl_display_read_events(display);
                _ = wl.wl_display_dispatch_pending(display);
            } else {
                wl.wl_display_cancel_read(display);
                if (poll_ret < 0) break;
            }
        } else {
            // No timeout — block until events arrive
            if (wl.wl_display_dispatch(display) == -1) break;
        }

        if (!state.configured or !state.needs_redraw or state.frame_pending) continue;
        state.needs_redraw = false;

        // Process frame
        ctx.clearClickedFlags();
        ctx.doLayout(&text_measure_ctx);

        ctx.processEvents();

        var rebuild_ui = false;

        if (state.nav_splitter) |h| if (ctx.splitterChanged(h)) {
            state.nav_ratio = ctx.splitterRatio(h);
        };
        if (state.detail_splitter) |h| if (ctx.splitterChanged(h)) {
            state.detail_ratio = ctx.splitterRatio(h);
        };

        if (state.asset_table) |h| if (ctx.tableChanged(h)) {
            state.table_column_weights[0] = ctx.tableColumnFraction(h, 0) orelse state.table_column_weights[0];
            state.table_column_weights[1] = ctx.tableColumnFraction(h, 1) orelse state.table_column_weights[1];
            state.table_column_weights[2] = ctx.tableColumnFraction(h, 2) orelse state.table_column_weights[2];
            state.table_column_weights[3] = ctx.tableColumnFraction(h, 3) orelse state.table_column_weights[3];
        };

        if (state.asset_table) |h| if (ctx.tableSortChanged(h)) {
            if (ctx.tableSortedColumn(h)) |sorted_column| {
                state.sort_column = @enumFromInt(sorted_column);
                state.sort_direction = switch (ctx.tableSortDirection(h).?) {
                    .ascending => .ascending,
                    .descending => .descending,
                };
                sortDirectoryEntries(&state);
                rebuild_ui = true;
            }
        };

        if (state.btn_back) |h| if (ctx.wasClicked(h)) {
            rebuild_ui = try navigateBack(&state) or rebuild_ui;
        };
        if (state.btn_up) |h| if (ctx.wasClicked(h)) {
            rebuild_ui = try navigateUp(&state) or rebuild_ui;
        };
        if (state.btn_home) |h| if (ctx.wasClicked(h)) {
            if (c_io.getenv("HOME")) |home_raw| {
                const home = std.mem.span(@as([*:0]const u8, @ptrCast(home_raw)));
                rebuild_ui = try setCurrentDirectory(&state, home, true) or rebuild_ui;
            }
        };
        if (state.btn_refresh) |h| if (ctx.wasClicked(h)) {
            try refreshCurrentDirectory(&state);
            rebuild_ui = true;
        };

        for (state.place_handles.items, 0..) |handle, index| {
            if (!ctx.wasClicked(handle)) continue;
            if (index >= state.places.items.len) continue;
            rebuild_ui = try setCurrentDirectory(&state, state.places.items[index].path, true) or rebuild_ui;
            break;
        }

        for (state.breadcrumb_handles.items, 0..) |handle, index| {
            if (!ctx.wasClicked(handle)) continue;
            if (index >= state.breadcrumb_paths.items.len) continue;
            rebuild_ui = try setCurrentDirectory(&state, state.breadcrumb_paths.items[index], true) or rebuild_ui;
            break;
        }

        if (state.asset_table) |h| if (ctx.tableSelectionChanged(h)) {
            if (ctx.tableSelectedRowIndex(h)) |row_index| {
                if (row_index < state.entries.items.len) {
                    try setSelectedPath(&state, state.entries.items[row_index].path);
                } else {
                    try setSelectedPath(&state, null);
                }
            } else {
                try setSelectedPath(&state, null);
            }
            rebuild_ui = true;
        };

        for (state.row_handles.items, 0..) |handle, index| {
            if (!ctx.wasClicked(handle)) continue;
            if (index >= state.entries.items.len) continue;

            const entry = state.entries.items[index];
            const now = getMonotonicNs();
            const repeated_click = if (state.last_click_path) |last_clicked|
                std.mem.eql(u8, last_clicked, entry.path) and now - state.last_click_ns <= 400 * std.time.ns_per_ms
            else
                false;

            try setSelectedPath(&state, entry.path);
            try setLastClickPath(&state, entry.path);
            state.last_click_ns = now;
            rebuild_ui = true;

            if (repeated_click and entry.isDirectory()) {
                rebuild_ui = try setCurrentDirectory(&state, entry.path, true) or rebuild_ui;
            }
            break;
        }

        if (rebuild_ui) {
            try buildWidgetTree(&state);
        }

        // Render
        var dl = try ctx.generateDrawList();
        defer ctx.freeDrawList(&dl);
        if (try ensureAtlasForDrawList(&atlas, &renderer, dl)) {
            ctx.setDimensions(state.logical_width, state.logical_height);
            ctx.doLayout(&text_measure_ctx);
            dl = try ctx.generateDrawList();
        }

        renderer.beginFrame(state.buffer_width, state.buffer_height, @floatFromInt(state.buffer_scale));
        renderer.render(dl);

        // Request frame callback BEFORE swap — the callback must be
        // registered before the surface commit that eglSwapBuffers triggers.
        requestFrame(&state);
        _ = egl.eglSwapBuffers(state.egl_display, state.egl_surface);
    }

    // Clean up xkb state
    state.destroyAllDataOffers();
    state.destroyAllOutputs();
    state.destroyClipboardSource();
    deinitBrowserState(&state);
    state.clipboard_buf.deinit(allocator);
    if (state.data_device) |data_device| wl.wl_data_device_release(data_device);
    if (state.data_device_manager) |manager| wl.wl_data_device_manager_destroy(manager);
    if (state.xkb_state) |s| xkb.xkb_state_unref(s);
    if (state.xkb_keymap) |k| xkb.xkb_keymap_unref(k);
    if (state.xkb_ctx) |c| xkb.xkb_context_unref(c);

    std.debug.print("goop file manager exiting\n", .{});
}
