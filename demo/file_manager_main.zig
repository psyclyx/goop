const std = @import("std");
const goop = @import("goop");
const snail = @import("snail");
const render = @import("render.zig");

const wl = @cImport({
    @cInclude("wayland-client.h");
    @cInclude("wayland-cursor.h");
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
    measure_buf: []f32,
    scratch_buf: []u8,
    ascent_units: f32,
    descent_units: f32,

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

const OutputState = struct {
    global_name: u32,
    output: *wl.wl_output,
    scale: u32 = 1,
    entered: bool = false,
    next: ?*OutputState = null,
};

const CursorKind = enum {
    default,
    pointer,
    text,
    ew_resize,
    ns_resize,
};

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

fn ensureAtlasForPaintList(atlas: *snail.Atlas, renderer: *render.Renderer, paint_list: goop.PaintList) !bool {
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

const BrowserViewMode = enum {
    list,
    grid,
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
    shm: ?*wl.wl_shm = null,
    data_device_manager: ?*wl.wl_data_device_manager = null,
    outputs: ?*OutputState = null,

    // Wayland surface chain
    surface: ?*wl.wl_surface = null,
    cursor_surface: ?*wl.wl_surface = null,
    xdg_surface: ?*wl.xdg_surface = null,
    xdg_toplevel: ?*wl.xdg_toplevel = null,
    egl_window: ?*wl.wl_egl_window = null,
    pointer: ?*wl.wl_pointer = null,
    cursor_theme: ?*wl.wl_cursor_theme = null,
    cursor_theme_scale: u32 = 0,
    pointer_enter_serial: u32 = 0,
    pointer_inside: bool = false,
    cursor_kind: CursorKind = .default,
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
    selected_paths: std.ArrayListUnmanaged([]u8) = .empty,
    selected_path: ?[]u8 = null,
    last_click_path: ?[]u8 = null,
    last_click_ns: u64 = 0,
    sort_column: BrowserSortColumn = .name,
    sort_direction: BrowserSortDirection = .ascending,
    view_mode: BrowserViewMode = .list,
    nav_ratio: f32 = 0.22,
    detail_ratio: f32 = 0.72,
    table_column_weights: [4]f32 = .{ 0.50, 0.22, 0.16, 0.12 },

    // Dynamic UI state
    ui_root: ?goop.NodeHandle = null,
    btn_back: ?goop.NodeHandle = null,
    btn_up: ?goop.NodeHandle = null,
    btn_home: ?goop.NodeHandle = null,
    btn_refresh: ?goop.NodeHandle = null,
    btn_list_view: ?goop.NodeHandle = null,
    btn_grid_view: ?goop.NodeHandle = null,
    nav_splitter: ?goop.NodeHandle = null,
    detail_splitter: ?goop.NodeHandle = null,
    asset_table: ?goop.NodeHandle = null,
    asset_grid: ?goop.NodeHandle = null,
    place_handles: std.ArrayListUnmanaged(goop.NodeHandle) = .empty,
    breadcrumb_handles: std.ArrayListUnmanaged(goop.NodeHandle) = .empty,
    breadcrumb_paths: std.ArrayListUnmanaged([]u8) = .empty,
    row_handles: std.ArrayListUnmanaged(goop.NodeHandle) = .empty,
    name_cell_handles: std.ArrayListUnmanaged(goop.NodeHandle) = .empty,
    grid_handles: std.ArrayListUnmanaged(goop.NodeHandle) = .empty,
    ui_strings: std.ArrayListUnmanaged([]u8) = .empty,
    composed_paint_commands: std.ArrayListUnmanaged(goop.PaintCommand) = .empty,

    // Last known mouse position from Wayland pointer events
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,
    text_measure_ctx: ?*const goop.TextMeasureCtx = null,

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
            self.resetCursorTheme();
        }
        if (changed) self.needs_redraw = true;
    }

    fn ensureCursorSurface(self: *State) void {
        if (self.cursor_surface != null or self.compositor == null) return;
        self.cursor_surface = wl.wl_compositor_create_surface(self.compositor);
    }

    fn ensureCursorTheme(self: *State) void {
        if (self.shm == null) return;
        if (self.cursor_theme != null and self.cursor_theme_scale == self.buffer_scale) return;
        self.resetCursorTheme();
        const size = @as(c_int, @intCast(24 * @max(self.buffer_scale, 1)));
        self.cursor_theme = wl.wl_cursor_theme_load(null, size, self.shm);
        self.cursor_theme_scale = self.buffer_scale;
    }

    fn resetCursorTheme(self: *State) void {
        if (self.cursor_theme) |theme| wl.wl_cursor_theme_destroy(theme);
        self.cursor_theme = null;
        self.cursor_theme_scale = 0;
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

fn cursorNames(kind: CursorKind) []const [:0]const u8 {
    return switch (kind) {
        .default => &[_][:0]const u8{ "left_ptr" },
        .pointer => &[_][:0]const u8{ "pointer", "hand2", "left_ptr" },
        .text => &[_][:0]const u8{ "text", "xterm", "left_ptr" },
        .ew_resize => &[_][:0]const u8{ "col-resize", "sb_h_double_arrow", "left_ptr" },
        .ns_resize => &[_][:0]const u8{ "row-resize", "sb_v_double_arrow", "left_ptr" },
    };
}

fn lookupCursor(state: *State, kind: CursorKind) ?*wl.wl_cursor {
    state.ensureCursorTheme();
    const theme = state.cursor_theme orelse return null;
    for (cursorNames(kind)) |name| {
        if (wl.wl_cursor_theme_get_cursor(theme, name.ptr)) |cursor| return cursor;
    }
    return null;
}

fn desiredCursorKind(state: *State) CursorKind {
    if (!state.pointer_inside) return .default;
    const ctx = state.ctx orelse return .default;
    const handle = goop.hittest.hitTest(&ctx.tree, state.mouse_x, state.mouse_y) orelse return .default;
    const node = ctx.tree.getConst(handle);

    return switch (node.kind) {
        .splitter => switch (node.kind.splitter.direction) {
            .row => .ew_resize,
            .column => .ns_resize,
        },
        .table => blk: {
            if (goop.widget.tableResizeHandleIndexAtPoint(&ctx.tree, handle, state.mouse_x, state.mouse_y) != null) break :blk .ew_resize;
            if (goop.widget.tableHeaderCellIndexAtPoint(&ctx.tree, handle, state.mouse_x, state.mouse_y) != null) break :blk .pointer;
            break :blk .default;
        },
        .button,
        .selectable,
        .dropdown,
        .menu,
        .menu_item,
        .tab_item,
        => .pointer,
        .text_input => .text,
        else => .default,
    };
}

fn applyCursorKind(state: *State, kind: CursorKind) void {
    if (!state.pointer_inside or state.pointer == null or state.pointer_enter_serial == 0) return;

    state.ensureCursorSurface();
    const cursor_surface = state.cursor_surface orelse return;
    const cursor = lookupCursor(state, kind) orelse lookupCursor(state, .default) orelse return;
    if (cursor.image_count == 0) return;

    const image_ptr = cursor.images[0];
    const image = image_ptr.*;
    const buffer = wl.wl_cursor_image_get_buffer(image_ptr) orelse return;

    wl.wl_pointer_set_cursor(state.pointer, state.pointer_enter_serial, cursor_surface, @intCast(image.hotspot_x), @intCast(image.hotspot_y));
    wl.wl_surface_attach(cursor_surface, buffer, 0, 0);
    wl.wl_surface_damage_buffer(cursor_surface, 0, 0, @intCast(image.width), @intCast(image.height));
    wl.wl_surface_commit(cursor_surface);
    state.cursor_kind = kind;
}

fn updatePointerCursor(state: *State) void {
    const next = desiredCursorKind(state);
    if (next == state.cursor_kind and state.cursor_theme != null and state.cursor_theme_scale == state.buffer_scale) return;
    applyCursorKind(state, next);
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
    } else if (std.mem.eql(u8, iface, "wl_shm")) {
        state.shm = @ptrCast(wl.wl_registry_bind(registry, name, &wl.wl_shm_interface, @min(version, 1)));
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
        state.pointer_inside = false;
        state.pointer_enter_serial = 0;
        state.cursor_kind = .default;
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

fn pointerEnter(data: ?*anyopaque, _: ?*wl.wl_pointer, serial: u32, _: ?*wl.wl_surface, sx: wl.wl_fixed_t, sy: wl.wl_fixed_t) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    state.pointer_enter_serial = serial;
    state.pointer_inside = true;
    state.mouse_x = fixedToF32(sx);
    state.mouse_y = fixedToF32(sy);
    updatePointerCursor(state);
}

fn pointerLeave(data: ?*anyopaque, _: ?*wl.wl_pointer, _: u32, _: ?*wl.wl_surface) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    state.pointer_inside = false;
    state.cursor_kind = .default;
}

fn pointerMotion(data: ?*anyopaque, _: ?*wl.wl_pointer, _: u32, sx: wl.wl_fixed_t, sy: wl.wl_fixed_t) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    const x = fixedToF32(sx);
    const y = fixedToF32(sy);
    state.mouse_x = x;
    state.mouse_y = y;
    if (state.ctx) |ctx| ctx.pushEvent(.{ .mouse_move = .{ .x = x, .y = y } }) catch {};
    updatePointerCursor(state);
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

fn clearSelectedPaths(state: *State) void {
    for (state.selected_paths.items) |path| allocator.free(path);
    state.selected_paths.clearRetainingCapacity();
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
    state.btn_list_view = null;
    state.btn_grid_view = null;
    state.nav_splitter = null;
    state.detail_splitter = null;
    state.asset_table = null;
    state.asset_grid = null;
    state.place_handles.clearRetainingCapacity();
    state.breadcrumb_handles.clearRetainingCapacity();
    state.row_handles.clearRetainingCapacity();
    state.name_cell_handles.clearRetainingCapacity();
    state.grid_handles.clearRetainingCapacity();
    clearUiStrings(state);
    clearBreadcrumbPaths(state);
}

fn deinitBrowserState(state: *State) void {
    clearUiTracking(state);
    clearEntries(state);
    clearPlaces(state);
    clearSelectedPaths(state);
    for (state.history.items) |path| allocator.free(path);
    state.history.deinit(allocator);
    state.places.deinit(allocator);
    state.entries.deinit(allocator);
    state.selected_paths.deinit(allocator);
    state.place_handles.deinit(allocator);
    state.breadcrumb_handles.deinit(allocator);
    state.breadcrumb_paths.deinit(allocator);
    state.row_handles.deinit(allocator);
    state.name_cell_handles.deinit(allocator);
    state.grid_handles.deinit(allocator);
    state.ui_strings.deinit(allocator);
    state.composed_paint_commands.deinit(allocator);
    if (state.current_dir.len > 0) allocator.free(state.current_dir);
    state.current_dir = &.{};
    freeOptionalOwnedSlice(&state.selected_path);
    freeOptionalOwnedSlice(&state.last_click_path);
}

fn trackUiString(state: *State, text: []u8) ![]const u8 {
    try state.ui_strings.append(allocator, text);
    return text;
}

fn allocUiString(state: *State, comptime fmt: []const u8, args: anytype) ![]const u8 {
    return trackUiString(state, try std.fmt.allocPrint(allocator, fmt, args));
}

fn allocUtf8LossyOwned(bytes: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{f}", .{std.unicode.fmtUtf8(bytes)});
}

fn allocUiUtf8Lossy(state: *State, bytes: []const u8) ![]const u8 {
    return trackUiString(state, try allocUtf8LossyOwned(bytes));
}

fn allocUiEllipsizedUtf8Lossy(state: *State, bytes: []const u8, max_width: f32, font_size: f32) ![]const u8 {
    const full = try allocUtf8LossyOwned(bytes);
    errdefer allocator.free(full);

    const text_ctx = state.text_measure_ctx;
    if (text_ctx == null or goop.layout.measureTextDimensions(full, font_size, text_ctx).width <= max_width) {
        return trackUiString(state, full);
    }

    const ellipsis = "...";
    const ellipsis_width = goop.layout.measureTextDimensions(ellipsis, font_size, text_ctx).width;
    if (ellipsis_width >= max_width) {
        allocator.free(full);
        return allocUiString(state, "{s}", .{ellipsis});
    }

    var codepoint_ends: std.ArrayListUnmanaged(usize) = .empty;
    defer codepoint_ends.deinit(allocator);

    var total_bytes: usize = 0;
    var view = std.unicode.Utf8View.init(full) catch unreachable;
    var it = view.iterator();
    while (it.nextCodepointSlice()) |slice| {
        total_bytes += slice.len;
        try codepoint_ends.append(allocator, total_bytes);
    }

    var keep = codepoint_ends.items.len;
    while (keep > 0) : (keep -= 1) {
        const prefix_len = codepoint_ends.items[keep - 1];
        const prefix_width = goop.layout.measureTextDimensions(full[0..prefix_len], font_size, text_ctx).width;
        if (prefix_width + ellipsis_width <= max_width) {
            const truncated = try std.fmt.allocPrint(allocator, "{s}{s}", .{ full[0..prefix_len], ellipsis });
            allocator.free(full);
            return trackUiString(state, truncated);
        }
    }

    allocator.free(full);
    return allocUiString(state, "{s}", .{ellipsis});
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

fn timestampMonthAbbrev(index: i32) []const u8 {
    const months = [_][]const u8{
        "Jan",
        "Feb",
        "Mar",
        "Apr",
        "May",
        "Jun",
        "Jul",
        "Aug",
        "Sep",
        "Oct",
        "Nov",
        "Dec",
    };
    const clamped = std.math.clamp(index, 0, @as(i32, @intCast(months.len - 1)));
    return months[@intCast(clamped)];
}

fn formatTimestampCompactText(buffer: []u8, unix_seconds: i64) []const u8 {
    if (unix_seconds <= 0) return "";

    var t: posix.time_t = @intCast(unix_seconds);
    var tm_buf: posix.struct_tm = undefined;
    if (posix.localtime_r(&t, &tm_buf) == null) return "";

    const now = posix.time(null);
    var now_tm: posix.struct_tm = undefined;
    const now_ok = posix.localtime_r(&now, &now_tm) != null;
    const diff_seconds = if (now_ok) @as(i64, @intCast(now)) - unix_seconds else std.math.maxInt(i64);

    if (now_ok and tm_buf.tm_year == now_tm.tm_year and tm_buf.tm_yday == now_tm.tm_yday) {
        return std.fmt.bufPrint(buffer, "Today {d:0>2}:{d:0>2}", .{
            tm_buf.tm_hour,
            tm_buf.tm_min,
        }) catch "";
    }
    if (now_ok and diff_seconds >= 0 and diff_seconds < 48 * 60 * 60) {
        return std.fmt.bufPrint(buffer, "Yesterday {d:0>2}:{d:0>2}", .{
            tm_buf.tm_hour,
            tm_buf.tm_min,
        }) catch "";
    }
    if (now_ok and tm_buf.tm_year == now_tm.tm_year) {
        return std.fmt.bufPrint(buffer, "{s} {d} {d:0>2}:{d:0>2}", .{
            timestampMonthAbbrev(tm_buf.tm_mon),
            tm_buf.tm_mday,
            tm_buf.tm_hour,
            tm_buf.tm_min,
        }) catch "";
    }

    return std.fmt.bufPrint(buffer, "{s} {d}, {d}", .{
        timestampMonthAbbrev(tm_buf.tm_mon),
        tm_buf.tm_mday,
        tm_buf.tm_year + 1900,
    }) catch "";
}

fn formatTimestampDetailText(buffer: []u8, unix_seconds: i64) []const u8 {
    if (unix_seconds <= 0) return "";

    var t: posix.time_t = @intCast(unix_seconds);
    var tm_buf: posix.struct_tm = undefined;
    if (posix.localtime_r(&t, &tm_buf) == null) return "";

    return std.fmt.bufPrint(buffer, "{s} {d}, {d} at {d:0>2}:{d:0>2}", .{
        timestampMonthAbbrev(tm_buf.tm_mon),
        tm_buf.tm_mday,
        tm_buf.tm_year + 1900,
        tm_buf.tm_hour,
        tm_buf.tm_min,
    }) catch "";
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

fn sortColumnLabel(column: BrowserSortColumn) []const u8 {
    return switch (column) {
        .name => "name",
        .modified => "modified time",
        .kind => "type",
        .size => "size",
    };
}

fn sortDirectionLabel(direction: BrowserSortDirection) []const u8 {
    return switch (direction) {
        .ascending => "ascending",
        .descending => "descending",
    };
}

fn entryIconText(entry: BrowserEntry) []const u8 {
    return switch (entry.kind) {
        .directory => "\u{25A3}",
        .symlink => "\u{2197}",
        .other => "\u{25EB}",
        .file => "\u{25A4}",
    };
}

fn allocEntryNameLabel(state: *State, entry: BrowserEntry) ![]const u8 {
    return allocUiString(state, "{s} {f}", .{
        entryIconText(entry),
        std.unicode.fmtUtf8(entry.name),
    });
}

fn allocFormattedTimestamp(state: *State, unix_seconds: i64) ![]const u8 {
    var buf: [40]u8 = undefined;
    const text = formatTimestampCompactText(buf[0..], unix_seconds);
    return allocUiString(state, "{s}", .{text});
}

fn allocFormattedTimestampDetail(state: *State, unix_seconds: i64) ![]const u8 {
    var buf: [48]u8 = undefined;
    const text = formatTimestampDetailText(buf[0..], unix_seconds);
    return allocUiString(state, "{s}", .{text});
}

fn allocFormattedSize(state: *State, kind: BrowserEntryKind, size_bytes: u64) ![]const u8 {
    var buf: [24]u8 = undefined;
    const text = formatSizeText(buf[0..], kind, size_bytes);
    return allocUiString(state, "{s}", .{text});
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
    }

    try appendPlaceIfDirectory(state, "/tmp", "/tmp");
    try appendPlaceIfDirectory(state, "/", "/");
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

fn isPathSelected(state: *const State, path: []const u8) bool {
    for (state.selected_paths.items) |selected| {
        if (std.mem.eql(u8, selected, path)) return true;
    }
    return false;
}

fn selectedPathCount(state: *const State) usize {
    return state.selected_paths.items.len;
}

fn selectedEntryExists(state: *const State, path: []const u8) bool {
    for (state.entries.items) |entry| {
        if (std.mem.eql(u8, entry.path, path)) return true;
    }
    return false;
}

fn setSelectedPath(state: *State, path: ?[]const u8) !void {
    freeOptionalOwnedSlice(&state.selected_path);
    if (path) |value| state.selected_path = try allocator.dupe(u8, value);
}

fn setLastClickPath(state: *State, path: ?[]const u8) !void {
    freeOptionalOwnedSlice(&state.last_click_path);
    if (path) |value| state.last_click_path = try allocator.dupe(u8, value);
}

fn syncPrimarySelection(state: *State) !void {
    if (state.selected_path) |selected_path| {
        if (isPathSelected(state, selected_path)) return;
        freeOptionalOwnedSlice(&state.selected_path);
    }

    if (state.selected_paths.items.len > 0) {
        try setSelectedPath(state, state.selected_paths.items[0]);
    }
}

fn syncSelectedPathsFromTable(state: *State, ctx: *goop.Context, handle: goop.NodeHandle) !void {
    clearSelectedPaths(state);

    var row_index: usize = 0;
    var iter = ctx.tree.children(handle);
    while (iter.next()) |child| {
        const node = ctx.tree.getConst(child);
        if (node.kind != .table_row or node.kind.table_row.header) continue;
        if (row_index >= state.entries.items.len) break;
        if (node.kind.table_row.selected) {
            try state.selected_paths.append(allocator, try allocator.dupe(u8, state.entries.items[row_index].path));
        }
        row_index += 1;
    }

    try syncPrimarySelection(state);
}

fn syncSelectedPathsFromGrid(state: *State, ctx: *goop.Context, handle: goop.NodeHandle) !void {
    clearSelectedPaths(state);

    var item_index: usize = 0;
    var iter = ctx.tree.children(handle);
    while (iter.next()) |child| {
        const node = ctx.tree.getConst(child);
        if (node.kind != .grid_item) continue;
        if (item_index >= state.entries.items.len) break;
        if (node.kind.grid_item.selected) {
            try state.selected_paths.append(allocator, try allocator.dupe(u8, state.entries.items[item_index].path));
        }
        item_index += 1;
    }

    try syncPrimarySelection(state);
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

        const entry = BrowserEntry{
            .name = entry_name,
            .path = full_path,
            .kind = browserEntryKind(stat_buf.st_mode),
            .size_bytes = @intCast(@max(stat_buf.st_size, 0)),
            .modified_unix = @intCast(stat_buf.st_mtim.tv_sec),
        };
        try state.entries.append(allocator, entry);
    }

    sortDirectoryEntries(state);

    var index: usize = 0;
    while (index < state.selected_paths.items.len) {
        if (selectedEntryExists(state, state.selected_paths.items[index])) {
            index += 1;
            continue;
        }
        allocator.free(state.selected_paths.swapRemove(index));
    }

    if (state.selected_path) |selected_path| {
        if (!selectedEntryExists(state, selected_path)) freeOptionalOwnedSlice(&state.selected_path);
    }

    try syncPrimarySelection(state);
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
    clearSelectedPaths(state);
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

fn addNameCell(ctx: *goop.Context, row: goop.NodeHandle, text: []const u8) !goop.NodeHandle {
    const cell = try ctx.tree.addChild(row, .{ .table_cell = .{} });
    ctx.tree.get(cell).style_override = .{
        .padding = .{ .top = 6, .right = 8, .bottom = 6, .left = 30 },
    };
    _ = try ctx.tree.addChild(cell, .{ .text = .{ .content = text } });
    return cell;
}

fn browserEntryIconKind(entry: BrowserEntry) goop.IconKind {
    return switch (entry.kind) {
        .directory => .folder,
        .symlink => .symlink,
        else => .file,
    };
}

fn browserEntryIconColor(theme: goop.Theme, entry: BrowserEntry, selected: bool) goop.Color {
    if (selected) return theme.accent;
    return switch (entry.kind) {
        .directory => .rgb(74, 120, 201),
        .symlink => .rgb(44, 140, 134),
        else => .rgb(118, 127, 141),
    };
}

fn iconRectInTableCell(cell_rect: goop.draw.Rect) goop.draw.Rect {
    const size = @min(@max(cell_rect.h - 10, 14), 18);
    return .{
        .x = cell_rect.x + 8,
        .y = cell_rect.y + (cell_rect.h - size) * 0.5,
        .w = size,
        .h = size,
    };
}

fn iconRectInGridItem(ctx: *goop.Context, handle: goop.NodeHandle) goop.draw.Rect {
    const node = ctx.tree.getConst(handle);
    const resolved = node.style_override.resolve(ctx.theme);
    const rect = node.layout_rect;
    const inner = goop.draw.Rect{
        .x = rect.x + resolved.padding.left,
        .y = rect.y + resolved.padding.top,
        .w = @max(rect.w - resolved.padding.left - resolved.padding.right, 0),
        .h = @max(rect.h - resolved.padding.top - resolved.padding.bottom, 0),
    };
    const icon_size = @max(@min(inner.w, inner.h - resolved.font_size - ctx.theme.spacing), 0);
    return .{
        .x = inner.x + (inner.w - icon_size) * 0.5,
        .y = inner.y,
        .w = icon_size,
        .h = @min(icon_size, inner.h - resolved.font_size - ctx.theme.spacing),
    };
}

fn composeFileBrowserPaintList(state: *State, base: goop.PaintList) !goop.PaintList {
    const ctx = state.ctx orelse return base;
    state.composed_paint_commands.clearRetainingCapacity();
    try state.composed_paint_commands.appendSlice(allocator, base.commands);

    switch (state.view_mode) {
        .list => {
            for (state.name_cell_handles.items, 0..) |handle, index| {
                if (index >= state.entries.items.len or !ctx.isAlive(handle)) continue;
                const cell = ctx.tree.getConst(handle);
                const row_handle = cell.parent orelse continue;
                const row = ctx.tree.getConst(row_handle);
                const entry = state.entries.items[index];
                try state.composed_paint_commands.append(allocator, .{ .icon = .{
                    .bounds = iconRectInTableCell(cell.layout_rect),
                    .kind = browserEntryIconKind(entry),
                    .color = browserEntryIconColor(ctx.theme, entry, row.kind.table_row.selected),
                } });
            }
        },
        .grid => {
            for (state.grid_handles.items, 0..) |handle, index| {
                if (index >= state.entries.items.len or !ctx.isAlive(handle)) continue;
                const node = ctx.tree.getConst(handle);
                const entry = state.entries.items[index];
                try state.composed_paint_commands.append(allocator, .{ .icon = .{
                    .bounds = iconRectInGridItem(ctx, handle),
                    .kind = browserEntryIconKind(entry),
                    .color = browserEntryIconColor(ctx.theme, entry, node.kind.grid_item.selected),
                } });
            }
        },
    }

    return .{ .commands = state.composed_paint_commands.items };
}

fn addViewModeButton(ctx: *goop.Context, parent: goop.NodeHandle, label: []const u8, active: bool) !goop.NodeHandle {
    const handle = try ctx.tree.addChild(parent, .{ .button = .{ .label = label } });
    ctx.tree.get(handle).style_override = .{
        .bg = if (active)
            .{ .r = 219, .g = 233, .b = 253, .a = 255 }
        else
            .{ .r = 243, .g = 246, .b = 250, .a = 255 },
        .border = if (active)
            .{ .r = 88, .g = 135, .b = 212, .a = 255 }
        else
            .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .border_width = if (active) 1 else 0,
        .padding = goop.style.Edges.symmetric(10, 6),
        .border_radius = 6,
    };
    return handle;
}

fn buildWidgetTree(state: *State) !void {
    const ctx = state.ctx orelse return error.NoContext;
    const transparent = goop.Color.rgba(0, 0, 0, 0);

    if (state.ui_root) |root| {
        if (ctx.isAlive(root)) try ctx.removeWidget(root);
    }
    clearUiTracking(state);

    state.ui_root = try ctx.tree.addRoot(.{ .container = .{ .direction = .column } });
    const root = state.ui_root.?;
    ctx.tree.get(root).style_override = .{
        .bg = transparent,
        .border_width = 0,
        .padding = goop.style.Edges.all(0),
        .border_radius = 0,
    };

    const header = try ctx.tree.addChild(root, .{ .toolbar = .{} });
    ctx.tree.get(header).style_override = .{
        .bg = .{ .r = 233, .g = 236, .b = 240, .a = 255 },
        .border_width = 0,
        .padding = goop.style.Edges.symmetric(12, 10),
        .border_radius = 0,
    };
    state.btn_back = try ctx.tree.addChild(header, .{ .button = .{ .label = "Back" } });
    state.btn_up = try ctx.tree.addChild(header, .{ .button = .{ .label = "Up" } });
    state.btn_home = try ctx.tree.addChild(header, .{ .button = .{ .label = "Home" } });
    state.btn_refresh = try ctx.tree.addChild(header, .{ .button = .{ .label = "Refresh" } });
    _ = try ctx.tree.addChild(header, .{ .text = .{ .content = try allocUiUtf8Lossy(state, state.current_dir) } });

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
        .border_width = 0,
        .padding = goop.style.Edges.symmetric(12, 12),
        .border_radius = 0,
    };
    _ = try ctx.tree.addChild(sidebar, .{ .text = .{ .content = "Places" } });
    const places_scroll = try ctx.tree.addChild(sidebar, .{ .scroll_area = .{} });
    ctx.tree.get(places_scroll).style_override = .{
        .bg = transparent,
        .border_width = 0,
        .padding = goop.style.Edges.all(0),
        .border_radius = 0,
    };
    const places_list = try ctx.tree.addChild(places_scroll, .{ .list_box = .{ .selection_mode = .single } });
    for (state.places.items) |place| {
        const handle = try ctx.tree.addChild(places_list, .{ .selectable = .{
            .label = place.label,
            .selected = std.mem.eql(u8, place.path, state.current_dir),
        } });
        try state.place_handles.append(allocator, handle);
    }

    const content = try ctx.tree.addChild(state.nav_splitter.?, .{ .container = .{ .direction = .column } });
    ctx.tree.get(content).style_override = .{
        .bg = transparent,
        .border_width = 0,
        .padding = goop.style.Edges.symmetric(10, 10),
        .border_radius = 0,
    };

    const breadcrumb_bar = try ctx.tree.addChild(content, .{ .toolbar = .{} });
    ctx.tree.get(breadcrumb_bar).style_override = .{
        .bg = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
        .border = .{ .r = 214, .g = 220, .b = 228, .a = 255 },
        .padding = goop.style.Edges.symmetric(10, 7),
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
        .border_width = 0,
        .padding = goop.style.Edges.all(0),
        .border_radius = 10,
    };

    const file_panel_header = try ctx.tree.addChild(file_panel, .{ .toolbar = .{} });
    ctx.tree.get(file_panel_header).style_override = .{
        .bg = .{ .r = 247, .g = 249, .b = 252, .a = 255 },
        .border_width = 0,
        .padding = goop.style.Edges.symmetric(12, 9),
        .border_radius = 10,
    };
    _ = try ctx.tree.addChild(file_panel_header, .{ .text = .{ .content = try allocUiString(state, "{d} entries", .{state.entries.items.len}) } });
    _ = try ctx.tree.addChild(file_panel_header, .{ .text = .{ .content = try allocUiString(state, "Sort: {s}, {s}", .{ sortColumnLabel(state.sort_column), sortDirectionLabel(state.sort_direction) }) } });
    state.btn_list_view = try addViewModeButton(ctx, file_panel_header, "List", state.view_mode == .list);
    state.btn_grid_view = try addViewModeButton(ctx, file_panel_header, "Grid", state.view_mode == .grid);

    const file_panel_scroll = try ctx.tree.addChild(file_panel, .{ .scroll_area = .{} });
    ctx.tree.get(file_panel_scroll).style_override = .{
        .bg = transparent,
        .border_width = 0,
        .padding = goop.style.Edges.all(0),
        .border_radius = 0,
    };

    switch (state.view_mode) {
        .list => {
            state.asset_table = try ctx.tree.addChild(file_panel_scroll, .{ .table = .{
                .columns = 4,
                .resizable = true,
                .sortable = true,
                .selection_mode = .multiple,
                .min_column_width = 96,
            } });
            ctx.tree.get(state.asset_table.?).style_override = .{
                .bg = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
                .border_width = 0,
                .padding = goop.style.Edges.all(0),
                .border_radius = 0,
            };
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
                    .selected = isPathSelected(state, entry.path),
                } });
                try state.row_handles.append(allocator, row);
                try state.name_cell_handles.append(allocator, try addNameCell(ctx, row, try allocEntryNameLabel(state, entry)));
                try addTextCell(ctx, row, try allocFormattedTimestamp(state, entry.modified_unix));
                try addTextCell(ctx, row, entry.typeLabel());
                try addTextCell(ctx, row, try allocFormattedSize(state, entry.kind, entry.size_bytes));
            }
        },
        .grid => {
            state.asset_grid = try ctx.tree.addChild(file_panel_scroll, .{ .grid_selector = .{
                .selection_mode = .multiple,
                .item_width = 132,
                .item_height = 108,
                .column_gap = 12,
                .row_gap = 12,
            } });
            ctx.tree.get(state.asset_grid.?).style_override = .{
                .bg = transparent,
                .border_width = 0,
                .padding = goop.style.Edges.symmetric(10, 10),
                .border_radius = 0,
            };

            for (state.entries.items) |entry| {
                const item = try ctx.tree.addChild(state.asset_grid.?, .{ .grid_item = .{
                    .label = try allocUiEllipsizedUtf8Lossy(state, entry.name, 104, ctx.theme.font_size),
                    .icon = entryIconText(entry),
                    .selected = isPathSelected(state, entry.path),
                } });
                ctx.tree.get(item).style_override = .{
                    .bg = if (entry.isDirectory())
                        .{ .r = 243, .g = 247, .b = 255, .a = 255 }
                    else
                        .{ .r = 252, .g = 252, .b = 253, .a = 255 },
                    .border = if (entry.isDirectory())
                        .{ .r = 184, .g = 204, .b = 233, .a = 255 }
                    else
                        .{ .r = 214, .g = 220, .b = 228, .a = 255 },
                    .border_width = 0,
                    .padding = goop.style.Edges.symmetric(10, 10),
                    .border_radius = 10,
                };
                try state.grid_handles.append(allocator, item);
            }
        },
    }

    if (state.entries.items.len == 0) {
        _ = try ctx.tree.addChild(file_panel_scroll, .{ .text = .{ .content = "This directory is empty." } });
    }

    const detail_panel = try ctx.tree.addChild(state.detail_splitter.?, .{ .container = .{ .direction = .column } });
    ctx.tree.get(detail_panel).style_override = .{
        .bg = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
        .border_width = 0,
        .padding = goop.style.Edges.all(0),
        .border_radius = 10,
    };
    const detail_header = try ctx.tree.addChild(detail_panel, .{ .toolbar = .{} });
    ctx.tree.get(detail_header).style_override = .{
        .bg = .{ .r = 247, .g = 249, .b = 252, .a = 255 },
        .border_width = 0,
        .padding = goop.style.Edges.symmetric(12, 9),
        .border_radius = 10,
    };
    _ = try ctx.tree.addChild(detail_header, .{ .text = .{ .content = "Info" } });
    const detail_scroll = try ctx.tree.addChild(detail_panel, .{ .scroll_area = .{} });
    ctx.tree.get(detail_scroll).style_override = .{
        .bg = transparent,
        .border_width = 0,
        .padding = goop.style.Edges.symmetric(12, 12),
        .border_radius = 0,
    };

    var directory_count: usize = 0;
    for (state.entries.items) |entry| {
        if (entry.isDirectory()) directory_count += 1;
    }
    const file_count = state.entries.items.len - directory_count;

    var selected_directory_count: usize = 0;
    var selected_file_count: usize = 0;
    var selected_file_bytes: u64 = 0;
    for (state.entries.items) |entry| {
        if (!isPathSelected(state, entry.path)) continue;
        if (entry.isDirectory()) {
            selected_directory_count += 1;
        } else {
            selected_file_count += 1;
            selected_file_bytes += entry.size_bytes;
        }
    }

    if (selectedPathCount(state) == 1 and selectedEntry(state) != null) {
        const entry = selectedEntry(state).?;
        const modified_text = try allocFormattedTimestampDetail(state, entry.modified_unix);
        const size_text = try allocFormattedSize(state, entry.kind, entry.size_bytes);
        _ = try ctx.tree.addChild(detail_scroll, .{ .text = .{ .content = try allocEntryNameLabel(state, entry.*) } });
        _ = try ctx.tree.addChild(detail_scroll, .{ .text = .{ .content = try allocUiString(state, "Type: {s}", .{entry.typeLabel()}) } });
        _ = try ctx.tree.addChild(detail_scroll, .{ .text = .{ .content = try allocUiString(state, "Modified: {s}", .{modified_text}) } });
        _ = try ctx.tree.addChild(detail_scroll, .{ .text = .{ .content = try allocUiString(state, "Size: {s}", .{if (size_text.len > 0) size_text else "-"}) } });
        _ = try ctx.tree.addChild(detail_scroll, .{ .text = .{ .content = try allocUiString(state, "Path: {f}", .{std.unicode.fmtUtf8(entry.path)}) } });
        _ = try ctx.tree.addChild(detail_scroll, .{ .text = .{ .content = if (entry.isDirectory()) "Double-click to open this directory." else "Use Ctrl-click and Shift-click to build a selection." } });
    } else if (selectedPathCount(state) > 1) {
        const selected_size_text = try allocFormattedSize(state, .file, selected_file_bytes);
        _ = try ctx.tree.addChild(detail_scroll, .{ .text = .{ .content = try allocUiString(state, "{d} items selected", .{selectedPathCount(state)}) } });
        _ = try ctx.tree.addChild(detail_scroll, .{ .text = .{ .content = try allocUiString(state, "{d} directories", .{selected_directory_count}) } });
        _ = try ctx.tree.addChild(detail_scroll, .{ .text = .{ .content = try allocUiString(state, "{d} files", .{selected_file_count}) } });
        if (selected_file_count > 0) {
            _ = try ctx.tree.addChild(detail_scroll, .{ .text = .{ .content = try allocUiString(state, "Combined file size: {s}", .{selected_size_text}) } });
        }
        if (state.selected_path) |selected_path| {
            _ = try ctx.tree.addChild(detail_scroll, .{ .text = .{ .content = try allocUiString(state, "Active item: {f}", .{std.unicode.fmtUtf8(std.fs.path.basename(selected_path))}) } });
        }
    } else {
        const directory_name = if (std.mem.eql(u8, state.current_dir, "/")) "/" else std.fs.path.basename(state.current_dir);
        _ = try ctx.tree.addChild(detail_scroll, .{ .text = .{ .content = try allocUiUtf8Lossy(state, directory_name) } });
        _ = try ctx.tree.addChild(detail_scroll, .{ .text = .{ .content = try allocUiString(state, "Path: {f}", .{std.unicode.fmtUtf8(state.current_dir)}) } });
        _ = try ctx.tree.addChild(detail_scroll, .{ .text = .{ .content = try allocUiString(state, "{d} directories", .{directory_count}) } });
        _ = try ctx.tree.addChild(detail_scroll, .{ .text = .{ .content = try allocUiString(state, "{d} files", .{file_count}) } });
        _ = try ctx.tree.addChild(detail_scroll, .{ .text = .{ .content = "Select files, or double-click a directory to open it." } });
    }

    const status_bar = try ctx.tree.addChild(root, .{ .status_bar = .{} });
    ctx.tree.get(status_bar).style_override = .{
        .bg = .{ .r = 233, .g = 236, .b = 240, .a = 255 },
        .border_width = 0,
        .padding = goop.style.Edges.symmetric(12, 8),
        .border_radius = 0,
    };
    _ = try ctx.tree.addChild(status_bar, .{ .text = .{ .content = try allocUiString(state, "{d} entries", .{state.entries.items.len}) } });
    _ = try ctx.tree.addChild(status_bar, .{ .text = .{ .content = try allocUiString(state, "{d} selected", .{selectedPathCount(state)}) } });
    _ = try ctx.tree.addChild(status_bar, .{ .text = .{ .content = try allocUiString(state, "Path: {f}", .{std.unicode.fmtUtf8(state.current_dir)}) } });
}

// ── Font loading ──

fn loadFont(alloc: std.mem.Allocator) ![]u8 {
    if (fontPathFromEnv()) |path| {
        return readFile(alloc, path);
    }

    if (try fontPathFromFontconfig(alloc)) |path| {
        defer alloc.free(path);
        if (readFile(alloc, path)) |font_data| {
            return font_data;
        } else |_| {}
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

fn fontPathFromFontconfig(alloc: std.mem.Allocator) !?[]u8 {
    const patterns = [_][]const u8{
        "Noto Sans:style=Regular",
        "sans-serif:style=Regular",
    };

    for (patterns) |pattern| {
        var command_buf: [256]u8 = undefined;
        const command = try std.fmt.bufPrintZ(&command_buf, "fc-match -f '%{{file}}\\n' '{s}'", .{pattern});

        const pipe = c_io.popen(command.ptr, "r") orelse continue;
        defer _ = c_io.pclose(pipe);

        var buf: [4096]u8 = undefined;
        const raw = c_io.fgets(&buf, @intCast(buf.len), pipe) orelse continue;
        const line = std.mem.trimEnd(u8, std.mem.span(@as([*:0]const u8, @ptrCast(raw))), "\r\n");
        if (line.len == 0) continue;
        return @as(?[]u8, try alloc.dupe(u8, line));
    }

    return null;
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
        .measure_buf = try allocator.alloc(f32, 64 * snail.FLOATS_PER_GLYPH),
        .scratch_buf = try allocator.alloc(u8, 64),
        .ascent_units = line_metrics.ascent,
        .descent_units = line_metrics.descent,
    };
    defer allocator.free(text_measure.measure_buf);
    defer allocator.free(text_measure.scratch_buf);
    const text_measure_ctx = goop.TextMeasureCtx{
        .measureFn = &snailMeasureText,
        .user_data = @ptrCast(&text_measure),
    };
    state.text_measure_ctx = &text_measure_ctx;

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
        if (state.btn_list_view) |h| if (ctx.wasClicked(h) and state.view_mode != .list) {
            state.view_mode = .list;
            rebuild_ui = true;
        };
        if (state.btn_grid_view) |h| if (ctx.wasClicked(h) and state.view_mode != .grid) {
            state.view_mode = .grid;
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
            try syncSelectedPathsFromTable(&state, &ctx, h);
            rebuild_ui = true;
        };
        if (state.asset_grid) |h| if (ctx.gridSelectorChanged(h)) {
            try syncSelectedPathsFromGrid(&state, &ctx, h);
            rebuild_ui = true;
        };

        for (state.row_handles.items, 0..) |handle, index| {
            if (!ctx.wasClicked(handle)) continue;
            if (index >= state.entries.items.len) continue;

            const entry = state.entries.items[index];
            const still_selected = ctx.tree.getConst(handle).kind.table_row.selected;
            const now = getMonotonicNs();
            const repeated_click = if (state.last_click_path) |last_clicked|
                std.mem.eql(u8, last_clicked, entry.path) and now - state.last_click_ns <= 400 * std.time.ns_per_ms
            else
                false;

            if (still_selected) {
                try setSelectedPath(&state, entry.path);
            } else {
                try syncPrimarySelection(&state);
            }
            try setLastClickPath(&state, entry.path);
            state.last_click_ns = now;
            rebuild_ui = true;

            if (repeated_click and entry.isDirectory()) {
                rebuild_ui = try setCurrentDirectory(&state, entry.path, true) or rebuild_ui;
            }
            break;
        }

        for (state.grid_handles.items, 0..) |handle, index| {
            if (!ctx.wasClicked(handle)) continue;
            if (index >= state.entries.items.len) continue;

            const entry = state.entries.items[index];
            const still_selected = ctx.tree.getConst(handle).kind.grid_item.selected;
            const now = getMonotonicNs();
            const repeated_click = if (state.last_click_path) |last_clicked|
                std.mem.eql(u8, last_clicked, entry.path) and now - state.last_click_ns <= 400 * std.time.ns_per_ms
            else
                false;

            if (still_selected) {
                try setSelectedPath(&state, entry.path);
            } else {
                try syncPrimarySelection(&state);
            }
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
        // Event handlers can rebuild the widget tree after the initial hit-test
        // layout pass above, so run layout again if the tree became dirty.
        ctx.doLayout(&text_measure_ctx);
        updatePointerCursor(&state);
        var base_paint_list = try ctx.generatePaintList();
        defer ctx.freePaintList(&base_paint_list);
        if (try ensureAtlasForPaintList(&atlas, &renderer, base_paint_list)) {
            ctx.setDimensions(state.logical_width, state.logical_height);
            ctx.doLayout(&text_measure_ctx);
            base_paint_list = try ctx.generatePaintList();
        }
        const paint_list = try composeFileBrowserPaintList(&state, base_paint_list);

        renderer.beginFrame(state.buffer_width, state.buffer_height, @floatFromInt(state.buffer_scale));
        renderer.renderPaintList(paint_list);

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
    state.resetCursorTheme();
    if (state.cursor_surface) |cursor_surface| wl.wl_surface_destroy(cursor_surface);
    if (state.shm) |shm| wl.wl_shm_destroy(shm);
    if (state.xkb_state) |s| xkb.xkb_state_unref(s);
    if (state.xkb_keymap) |k| xkb.xkb_keymap_unref(k);
    if (state.xkb_ctx) |c| xkb.xkb_context_unref(c);

    std.debug.print("goop file manager exiting\n", .{});
}
