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

const allocator = std.heap.page_allocator;

/// Snail-based text measurement adapter for goop.
const SnailTextCtx = struct {
    font: *const snail.Font,
    atlas: *const snail.Atlas,
};

fn snailMeasureText(text: []const u8, font_size: f32, user_data: ?*anyopaque) goop.TextDimensions {
    const ctx: *const SnailTextCtx = @ptrCast(@alignCast(user_data));
    const scale = font_size / @as(f32, @floatFromInt(ctx.font.unitsPerEm()));
    var width: f32 = 0;
    var prev_gid: u16 = 0;
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
        const info = ctx.atlas.getGlyph(gid) orelse {
            width += scale * 500;
            prev_gid = gid;
            continue;
        };
        width += @as(f32, @floatFromInt(info.advance_width)) * scale;
        prev_gid = gid;
    }
    return .{ .width = width, .height = font_size };
}

const State = struct {
    running: bool = true,
    configured: bool = false,
    width: u32 = 800,
    height: u32 = 600,
    needs_redraw: bool = true,
    frame_pending: bool = false,
    timeout_ns: ?u64 = null,
    start_time: posix.struct_timespec = .{ .tv_sec = 0, .tv_nsec = 0 },

    // Wayland globals
    compositor: ?*wl.wl_compositor = null,
    wm_base: ?*wl.xdg_wm_base = null,
    seat: ?*wl.wl_seat = null,

    // Wayland surface chain
    surface: ?*wl.wl_surface = null,
    xdg_surface: ?*wl.xdg_surface = null,
    xdg_toplevel: ?*wl.xdg_toplevel = null,
    egl_window: ?*wl.wl_egl_window = null,
    pointer: ?*wl.wl_pointer = null,
    keyboard: ?*wl.wl_keyboard = null,

    // EGL
    egl_display: egl.EGLDisplay = egl.EGL_NO_DISPLAY,
    egl_surface: egl.EGLSurface = egl.EGL_NO_SURFACE,
    egl_context: egl.EGLContext = egl.EGL_NO_CONTEXT,

    // goop
    ctx: *goop.Context = undefined,

    // Widget handles for querying state
    btn_a: ?goop.NodeHandle = null,
    btn_b: ?goop.NodeHandle = null,
    btn_c: ?goop.NodeHandle = null,
    checkbox: ?goop.NodeHandle = null,
    radio_a: ?goop.NodeHandle = null,
    radio_b: ?goop.NodeHandle = null,
    radio_c: ?goop.NodeHandle = null,
    tree_parent: ?goop.NodeHandle = null,
    tree_child_a: ?goop.NodeHandle = null,
    tree_child_b: ?goop.NodeHandle = null,
    list_box: ?goop.NodeHandle = null,
    selectable_scene: ?goop.NodeHandle = null,
    selectable_camera: ?goop.NodeHandle = null,
    selectable_light: ?goop.NodeHandle = null,
    dropdown: ?goop.NodeHandle = null,
    menu_file: ?goop.NodeHandle = null,
    menu_edit: ?goop.NodeHandle = null,
    menu_open_recent: ?goop.NodeHandle = null,
    menu_recent_a: ?goop.NodeHandle = null,
    menu_recent_b: ?goop.NodeHandle = null,
    menu_quit: ?goop.NodeHandle = null,
    menu_copy: ?goop.NodeHandle = null,
    menu_paste: ?goop.NodeHandle = null,
    drag_value: ?goop.NodeHandle = null,
    spinbox: ?goop.NodeHandle = null,
    tab_scene: ?goop.NodeHandle = null,
    tab_render: ?goop.NodeHandle = null,
    splitter: ?goop.NodeHandle = null,
    context_popup: ?goop.NodeHandle = null,
    context_action_a: ?goop.NodeHandle = null,
    context_action_b: ?goop.NodeHandle = null,
    click_count: u32 = 0,

    // Last known mouse position from Wayland pointer events
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,

    // xkbcommon state for keymap → text conversion
    xkb_ctx: ?*xkb.xkb_context = null,
    xkb_keymap: ?*xkb.xkb_keymap = null,
    xkb_state: ?*xkb.xkb_state = null,

    // Demo-local clipboard backing store for copy/cut/paste shortcuts.
    clipboard_buf: [1024]u8 = [_]u8{0} ** 1024,
    clipboard_len: usize = 0,

    fn clipboard(self: *State) goop.Clipboard {
        return .{
            .ptr = @ptrCast(self),
            .getTextFn = @ptrCast(&clipboardGetText),
            .setTextFn = @ptrCast(&clipboardSetText),
        };
    }

    fn clipboardGetText(ptr: *anyopaque) ?[]const u8 {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (self.clipboard_len == 0) return null;
        return self.clipboard_buf[0..self.clipboard_len];
    }

    fn clipboardSetText(ptr: *anyopaque, text: []const u8) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        const count = @min(text.len, self.clipboard_buf.len);
        @memcpy(self.clipboard_buf[0..count], text[0..count]);
        self.clipboard_len = count;
    }
};

// ── Wayland listeners ──

const registry_listener = wl.wl_registry_listener{
    .global = &registryGlobal,
    .global_remove = &registryGlobalRemove,
};

fn registryGlobal(data: ?*anyopaque, registry: ?*wl.wl_registry, name: u32, interface: [*c]const u8, version: u32) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    const iface = std.mem.span(@as([*:0]const u8, @ptrCast(interface)));

    if (std.mem.eql(u8, iface, "wl_compositor")) {
        state.compositor = @ptrCast(wl.wl_registry_bind(registry, name, &wl.wl_compositor_interface, @min(version, 4)));
    } else if (std.mem.eql(u8, iface, "xdg_wm_base")) {
        state.wm_base = @ptrCast(wl.wl_registry_bind(registry, name, &wl.xdg_wm_base_interface, @min(version, 2)));
        _ = wl.xdg_wm_base_add_listener(state.wm_base, &wm_base_listener, data);
    } else if (std.mem.eql(u8, iface, "wl_seat")) {
        state.seat = @ptrCast(wl.wl_registry_bind(registry, name, &wl.wl_seat_interface, @min(version, 5)));
        _ = wl.wl_seat_add_listener(state.seat, &seat_listener, data);
    }
}

fn registryGlobalRemove(_: ?*anyopaque, _: ?*wl.wl_registry, _: u32) callconv(.c) void {}

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
        state.width = @intCast(width);
        state.height = @intCast(height);
        if (state.egl_window != null) {
            wl.wl_egl_window_resize(state.egl_window, width, height, 0, 0);
        }
        state.ctx.setDimensions(state.width, state.height);
    }
    state.needs_redraw = true;
}

fn xdgToplevelClose(data: ?*anyopaque, _: ?*wl.xdg_toplevel) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    state.running = false;
}

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

fn keyboardKey(data: ?*anyopaque, _: ?*wl.wl_keyboard, _: u32, _: u32, key: u32, key_state: u32) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    // Wayland delivers Linux evdev codes here. xkbcommon needs an extra +8,
    // but goop's logical-key mapping table is keyed by the raw evdev values.
    const scancode = key;
    const goop_state: goop.Event.Key.KeyState = if (key_state == 1) .pressed else .released;
    state.ctx.pushEvent(.{ .key = .{
        .scancode = scancode,
        .keycode = evdevToKeycode(scancode),
        .state = goop_state,
    } }) catch {};

    // On key press, use xkbcommon to produce a text event with the composed codepoint
    if (key_state == 1) {
        if (state.xkb_state) |xkb_st| {
            // xkb uses evdev keycodes (key + 8)
            const codepoint = xkb.xkb_state_key_get_utf32(xkb_st, key + 8);
            if (codepoint >= 0x20 and codepoint < 0x7F) {
                state.ctx.pushEvent(.{ .text = .{
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
    state.ctx.pushEvent(.{ .mouse_move = .{ .x = x, .y = y } }) catch {};
    state.needs_redraw = true;
}

fn pointerButton(data: ?*anyopaque, _: ?*wl.wl_pointer, _: u32, time_ms: u32, button: u32, btn_state: u32) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
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
    state.ctx.pushEvent(.{ .mouse_button = .{
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
    state.ctx.pushEvent(.{ .mouse_scroll = .{ .dx = dx, .dy = dy } }) catch {};
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

    state.egl_window = wl.wl_egl_window_create(state.surface, @intCast(state.width), @intCast(state.height)) orelse return error.EglWindowCreateFailed;

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

fn buildWidgetTree(state: *State) !void {
    const ctx = state.ctx;

    const root = try ctx.tree.addRoot(.{ .container = .{ .direction = .column } });

    // Menu bar with a nested submenu.
    const menu_bar = try ctx.tree.addChild(root, .{ .menu_bar = .{} });
    state.menu_file = try ctx.tree.addChild(menu_bar, .{ .menu = .{ .label = "File" } });
    const file_popup = try ctx.tree.addChild(state.menu_file.?, .{ .popup = .{
        .placement = .below_start,
        .visible = false,
    } });
    state.menu_open_recent = try ctx.tree.addChild(file_popup, .{ .menu_item = .{ .label = "Open Recent" } });
    const recent_popup = try ctx.tree.addChild(state.menu_open_recent.?, .{ .popup = .{
        .placement = .right_start,
        .visible = false,
    } });
    state.menu_recent_a = try ctx.tree.addChild(recent_popup, .{ .menu_item = .{ .label = "shot_v014.blend" } });
    state.menu_recent_b = try ctx.tree.addChild(recent_popup, .{ .menu_item = .{ .label = "layout_blockout.blend" } });
    state.menu_quit = try ctx.tree.addChild(file_popup, .{ .menu_item = .{ .label = "Quit" } });

    state.menu_edit = try ctx.tree.addChild(menu_bar, .{ .menu = .{ .label = "Edit" } });
    const edit_popup = try ctx.tree.addChild(state.menu_edit.?, .{ .popup = .{
        .placement = .below_start,
        .visible = false,
    } });
    state.menu_copy = try ctx.tree.addChild(edit_popup, .{ .menu_item = .{ .label = "Copy" } });
    state.menu_paste = try ctx.tree.addChild(edit_popup, .{ .menu_item = .{ .label = "Paste" } });

    // Row of buttons
    const button_row = try ctx.tree.addChild(root, .{ .container = .{ .direction = .row } });
    state.btn_a = try ctx.tree.addChild(button_row, .{ .button = .{ .label = "Button A" } });
    state.btn_b = try ctx.tree.addChild(button_row, .{ .button = .{ .label = "Button B" } });
    state.btn_c = try ctx.tree.addChild(button_row, .{ .button = .{ .label = "Button C" } });

    // Text label
    _ = try ctx.tree.addChild(root, .{ .text = .{ .content = "goop demo - click the buttons" } });

    // Simple outline/tree
    _ = try ctx.tree.addChild(root, .{ .text = .{ .content = "Outline" } });
    state.tree_parent = try ctx.tree.addChild(root, .{ .tree_item = .{
        .label = "Scene",
        .group = 10,
        .selected = true,
        .editable = true,
        .rename_trigger = .selected_click,
    } });
    state.tree_child_a = try ctx.tree.addChild(state.tree_parent.?, .{ .tree_item = .{
        .label = "Camera",
        .group = 10,
        .editable = true,
        .rename_trigger = .selected_click,
    } });
    state.tree_child_b = try ctx.tree.addChild(state.tree_parent.?, .{ .tree_item = .{
        .label = "Directional Light",
        .group = 10,
        .editable = true,
        .rename_trigger = .selected_click,
    } });

    _ = try ctx.tree.addChild(root, .{ .text = .{ .content = "List Box" } });
    state.list_box = try ctx.tree.addChild(root, .{ .list_box = .{} });
    state.selectable_scene = try ctx.tree.addChild(state.list_box.?, .{ .selectable = .{
        .label = "Scene Collection",
        .selected = true,
    } });
    state.selectable_camera = try ctx.tree.addChild(state.list_box.?, .{ .selectable = .{
        .label = "Camera Rig",
    } });
    state.selectable_light = try ctx.tree.addChild(state.list_box.?, .{ .selectable = .{
        .label = "Lighting Set",
    } });

    // Dropdown composed from a header + popup menu
    state.dropdown = try ctx.tree.addChild(root, .{ .dropdown = .{ .placeholder = "Viewport mode" } });
    const dropdown_popup = try ctx.tree.addChild(state.dropdown.?, .{ .popup = .{ .placement = .below_start } });
    _ = try ctx.tree.addChild(dropdown_popup, .{ .menu_item = .{ .label = "Solid" } });
    _ = try ctx.tree.addChild(dropdown_popup, .{ .menu_item = .{ .label = "Wireframe" } });
    _ = try ctx.tree.addChild(dropdown_popup, .{ .menu_item = .{ .label = "Material Preview" } });

    // Numeric editing widgets
    _ = try ctx.tree.addChild(root, .{ .text = .{ .content = "Numbers" } });
    const exposure_row = try ctx.tree.addChild(root, .{ .container = .{ .direction = .row } });
    _ = try ctx.tree.addChild(exposure_row, .{ .text = .{ .content = "Exposure" } });
    state.drag_value = try ctx.tree.addChild(exposure_row, .{ .drag_value = .{
        .value = 1.25,
        .min = -4,
        .max = 8,
        .speed = 0.02,
        .precision = 2,
    } });

    const samples_row = try ctx.tree.addChild(root, .{ .container = .{ .direction = .row } });
    _ = try ctx.tree.addChild(samples_row, .{ .text = .{ .content = "Samples" } });
    state.spinbox = try ctx.tree.addChild(samples_row, .{ .spinbox = .{
        .value = 64,
        .min = 1,
        .max = 512,
        .step = 1,
        .precision = 0,
    } });

    // Tabbed container
    _ = try ctx.tree.addChild(root, .{ .text = .{ .content = "Editor Tabs" } });
    const tab_bar = try ctx.tree.addChild(root, .{ .tab_bar = .{} });
    state.tab_scene = try ctx.tree.addChild(tab_bar, .{ .tab_item = .{
        .label = "Scene",
        .selected = true,
    } });
    _ = try ctx.tree.addChild(state.tab_scene.?, .{ .text = .{ .content = "Scene tools: hierarchy, transforms, visibility." } });
    state.tab_render = try ctx.tree.addChild(tab_bar, .{ .tab_item = .{
        .label = "Render",
    } });
    _ = try ctx.tree.addChild(state.tab_render.?, .{ .text = .{ .content = "Render settings: samples, output, color management." } });

    // Checkbox
    state.checkbox = try ctx.tree.addChild(root, .{ .checkbox = .{ .label = "Enable option" } });

    // Radio buttons
    state.radio_a = try ctx.tree.addChild(root, .{ .radio_button = .{ .label = "Option A", .group = 1, .selected = true } });
    state.radio_b = try ctx.tree.addChild(root, .{ .radio_button = .{ .label = "Option B", .group = 1 } });
    state.radio_c = try ctx.tree.addChild(root, .{ .radio_button = .{ .label = "Option C", .group = 1 } });

    // Text input
    _ = try ctx.tree.addChild(root, .{ .text_input = .{ .placeholder = "Type here..." } });

    // Slider
    _ = try ctx.tree.addChild(root, .{ .slider = .{ .value = 0.5, .min = 0, .max = 1 } });

    // Split view for editor-style panes.
    _ = try ctx.tree.addChild(root, .{ .text = .{ .content = "Split View" } });
    state.splitter = try ctx.tree.addChild(root, .{ .splitter = .{
        .direction = .row,
        .ratio = 0.56,
        .min_first = 150,
        .min_second = 140,
        .thickness = 8,
    } });
    const inspector = try ctx.tree.addChild(state.splitter.?, .{ .container = .{ .direction = .column } });
    _ = try ctx.tree.addChild(inspector, .{ .text = .{ .content = "Inspector" } });
    _ = try ctx.tree.addChild(inspector, .{ .text = .{ .content = "Transform" } });
    _ = try ctx.tree.addChild(inspector, .{ .text = .{ .content = "Location  0.00  1.50  6.20" } });
    _ = try ctx.tree.addChild(inspector, .{ .text = .{ .content = "Rotation  0.00  0.00  0.00" } });
    _ = try ctx.tree.addChild(inspector, .{ .text = .{ .content = "Scale     1.00  1.00  1.00" } });

    const viewport = try ctx.tree.addChild(state.splitter.?, .{ .container = .{ .direction = .column } });
    _ = try ctx.tree.addChild(viewport, .{ .text = .{ .content = "Viewport Notes" } });
    const scroll = try ctx.tree.addChild(viewport, .{ .scroll_area = .{} });
    _ = try ctx.tree.addChild(scroll, .{ .text = .{ .content = "Scroll area line 1" } });
    _ = try ctx.tree.addChild(scroll, .{ .text = .{ .content = "Scroll area line 2" } });
    _ = try ctx.tree.addChild(scroll, .{ .text = .{ .content = "Scroll area line 3" } });
    _ = try ctx.tree.addChild(scroll, .{ .text = .{ .content = "Scroll area line 4" } });
    _ = try ctx.tree.addChild(scroll, .{ .text = .{ .content = "Scroll area line 5" } });
    _ = try ctx.tree.addChild(scroll, .{ .text = .{ .content = "Scroll area line 6" } });
    _ = try ctx.tree.addChild(scroll, .{ .text = .{ .content = "Scroll area line 7" } });
    _ = try ctx.tree.addChild(scroll, .{ .text = .{ .content = "Scroll area line 8" } });

    // Context menu popup. The demo opens it on secondary click, but callers
    // can instead use ctx.lastSecondaryClick() to trigger a native popup.
    state.context_popup = try ctx.tree.addRoot(.{ .popup = .{ .placement = .absolute, .visible = false } });
    state.context_action_a = try ctx.tree.addChild(state.context_popup.?, .{ .menu_item = .{ .label = "Rename" } });
    state.context_action_b = try ctx.tree.addChild(state.context_popup.?, .{ .menu_item = .{ .label = "Delete" } });
}

// ── Font loading ──

const c_io = @cImport({
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
});

fn loadFont(alloc: std.mem.Allocator) ![]u8 {
    return readFile(alloc, "/run/current-system/sw/share/X11/fonts/DejaVuSans.ttf") catch
        readFile(alloc, "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf") catch
        readFile(alloc, "/usr/share/fonts/TTF/DejaVuSans.ttf") catch
        loadFontFontconfig(alloc);
}

fn loadFontFontconfig(alloc: std.mem.Allocator) ![]u8 {
    // Use fontconfig to find a sans-serif font (works on NixOS)
    const pipe = c_io.popen("fc-match -f '%{file}' 'sans-serif'", "r") orelse return error.FontNotFound;
    defer _ = c_io.pclose(pipe);
    var path_buf: [1024]u8 = undefined;
    const n = c_io.fread(&path_buf, 1, path_buf.len, pipe);
    if (n == 0) return error.FontNotFound;
    const path = path_buf[0..n];
    std.debug.print("fontconfig resolved: {s}\n", .{path});
    return readFile(alloc, path);
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
    state.xdg_surface = wl.xdg_wm_base_get_xdg_surface(state.wm_base, state.surface) orelse return error.NoXdgSurface;
    _ = wl.xdg_surface_add_listener(state.xdg_surface, &xdg_surface_listener, &state);
    state.xdg_toplevel = wl.xdg_surface_get_toplevel(state.xdg_surface) orelse return error.NoToplevel;
    _ = wl.xdg_toplevel_add_listener(state.xdg_toplevel, &xdg_toplevel_listener, &state);
    wl.xdg_toplevel_set_title(state.xdg_toplevel, "goop demo");
    wl.xdg_toplevel_set_app_id(state.xdg_toplevel, "goop-demo");
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

    const text_measure_ctx = goop.TextMeasureCtx{
        .measureFn = &snailMeasureText,
        .user_data = @ptrCast(@constCast(&SnailTextCtx{ .font = &font, .atlas = &atlas })),
    };

    // goop context + widget tree
    var ctx = try goop.Context.init(allocator, .{ .width = state.width, .height = state.height });
    defer ctx.deinit();
    state.ctx = &ctx;
    ctx.clipboard = state.clipboard();
    try buildWidgetTree(&state);

    // GL renderer (with snail text support)
    var renderer = try render.Renderer.init(state.width, state.height, &font, &atlas);
    defer renderer.deinit();

    std.debug.print("goop demo running ({}x{})\n", .{ state.width, state.height });

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

        if (ctx.lastSecondaryClick()) |click| {
            if (state.context_popup) |popup| {
                const popup_node = ctx.tree.get(popup);
                popup_node.kind.popup.x = click.x;
                popup_node.kind.popup.y = click.y;
                popup_node.kind.popup.visible = true;
                std.debug.print("Secondary click on widget {} at ({d:.1}, {d:.1})\n", .{
                    click.target.index,
                    click.x,
                    click.y,
                });
            }
        }

        // Check clicks
        if (state.btn_a) |h| if (ctx.wasClicked(h)) {
            state.click_count += 1;
            std.debug.print("Button A clicked! (total: {})\n", .{state.click_count});
        };
        if (state.btn_b) |h| if (ctx.wasClicked(h)) {
            state.click_count += 1;
            std.debug.print("Button B clicked! (total: {})\n", .{state.click_count});
        };
        if (state.btn_c) |h| if (ctx.wasClicked(h)) {
            state.click_count += 1;
            std.debug.print("Button C clicked! (total: {})\n", .{state.click_count});
        };

        // Log checkbox state changes (checkbox toggles itself on click)
        if (state.checkbox) |h| if (ctx.wasClicked(h)) {
            std.debug.print("Checkbox toggled: {}\n", .{ctx.isChecked(h)});
        };

        // Log radio button selection
        if (state.radio_a) |h| if (ctx.wasClicked(h)) std.debug.print("Radio: Option A selected\n", .{});
        if (state.radio_b) |h| if (ctx.wasClicked(h)) std.debug.print("Radio: Option B selected\n", .{});
        if (state.radio_c) |h| if (ctx.wasClicked(h)) std.debug.print("Radio: Option C selected\n", .{});
        if (state.tree_parent) |h| {
            if (ctx.treeItemToggled(h)) std.debug.print("Outline root expanded: {}\n", .{ctx.isExpanded(h)});
            if (ctx.wasClicked(h)) std.debug.print("Outline selected: Scene\n", .{});
            if (ctx.treeItemRenameCommitted(h)) std.debug.print("Outline renamed: {s}\n", .{ctx.treeItemLabel(h)});
        }
        if (state.tree_child_a) |h| {
            if (ctx.wasClicked(h)) std.debug.print("Outline selected: Camera\n", .{});
            if (ctx.treeItemRenameCommitted(h)) std.debug.print("Outline renamed: {s}\n", .{ctx.treeItemLabel(h)});
        }
        if (state.tree_child_b) |h| {
            if (ctx.wasClicked(h)) std.debug.print("Outline selected: Directional Light\n", .{});
            if (ctx.treeItemRenameCommitted(h)) std.debug.print("Outline renamed: {s}\n", .{ctx.treeItemLabel(h)});
        }
        if (state.list_box) |h| if (ctx.listBoxChanged(h)) {
            if (ctx.listBoxSelectedIndex(h)) |index| {
                std.debug.print("List box selected index: {}\n", .{index});
            }
        };
        if (state.selectable_scene) |h| if (ctx.wasClicked(h)) std.debug.print("List row selected: Scene Collection\n", .{});
        if (state.selectable_camera) |h| if (ctx.wasClicked(h)) std.debug.print("List row selected: Camera Rig\n", .{});
        if (state.selectable_light) |h| if (ctx.wasClicked(h)) std.debug.print("List row selected: Lighting Set\n", .{});
        if (state.dropdown) |h| if (ctx.dropdownChanged(h)) {
            std.debug.print("Dropdown selected: {s}\n", .{ctx.dropdownValue(h)});
        };
        if (state.menu_file) |h| if (ctx.wasClicked(h)) std.debug.print("Menu toggled: File\n", .{});
        if (state.menu_edit) |h| if (ctx.wasClicked(h)) std.debug.print("Menu toggled: Edit\n", .{});
        if (state.menu_recent_a) |h| if (ctx.wasClicked(h)) std.debug.print("Recent file: shot_v014.blend\n", .{});
        if (state.menu_recent_b) |h| if (ctx.wasClicked(h)) std.debug.print("Recent file: layout_blockout.blend\n", .{});
        if (state.menu_quit) |h| if (ctx.wasClicked(h)) std.debug.print("Menu action: Quit\n", .{});
        if (state.menu_copy) |h| if (ctx.wasClicked(h)) std.debug.print("Menu action: Copy\n", .{});
        if (state.menu_paste) |h| if (ctx.wasClicked(h)) std.debug.print("Menu action: Paste\n", .{});
        if (state.drag_value) |h| if (ctx.dragValueChanged(h)) {
            std.debug.print("Exposure changed: {d:.2}\n", .{ctx.dragValue(h)});
        };
        if (state.spinbox) |h| if (ctx.spinboxChanged(h)) {
            std.debug.print("Samples changed: {d:.0}\n", .{ctx.spinboxValue(h)});
        };
        if (state.tab_scene) |h| if (ctx.wasClicked(h)) {
            std.debug.print("Tab selected: Scene\n", .{});
        };
        if (state.tab_render) |h| if (ctx.wasClicked(h)) {
            std.debug.print("Tab selected: Render\n", .{});
        };
        if (state.splitter) |h| if (ctx.splitterChanged(h)) {
            std.debug.print("Splitter ratio: {d:.2}\n", .{ctx.splitterRatio(h)});
        };
        if (state.context_action_a) |h| if (ctx.wasClicked(h)) std.debug.print("Context action: Rename\n", .{});
        if (state.context_action_b) |h| if (ctx.wasClicked(h)) std.debug.print("Context action: Delete\n", .{});

        // Render
        var dl = try ctx.generateDrawList();
        defer ctx.freeDrawList(&dl);

        renderer.beginFrame(state.width, state.height);
        renderer.render(dl);

        // Request frame callback BEFORE swap — the callback must be
        // registered before the surface commit that eglSwapBuffers triggers.
        requestFrame(&state);
        _ = egl.eglSwapBuffers(state.egl_display, state.egl_surface);
    }

    // Clean up xkb state
    if (state.xkb_state) |s| xkb.xkb_state_unref(s);
    if (state.xkb_keymap) |k| xkb.xkb_keymap_unref(k);
    if (state.xkb_ctx) |c| xkb.xkb_context_unref(c);

    std.debug.print("goop demo exiting\n", .{});
}
