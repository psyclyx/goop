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
    click_count: u32 = 0,

    // Last known mouse position from Wayland pointer events
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,

    // xkbcommon state for keymap → text conversion
    xkb_ctx: ?*xkb.xkb_context = null,
    xkb_keymap: ?*xkb.xkb_keymap = null,
    xkb_state: ?*xkb.xkb_state = null,
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
    defer _ = posix.munmap(@constCast(@ptrCast(map_str)), size);

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
        107 => .end,
        else => .unknown,
    };
}

fn keyboardKey(data: ?*anyopaque, _: ?*wl.wl_keyboard, _: u32, _: u32, key: u32, key_state: u32) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    // Wayland key codes are evdev codes minus 8
    const scancode = key + 8;
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

fn pointerEnter(_: ?*anyopaque, _: ?*wl.wl_pointer, _: u32, _: ?*wl.wl_surface, sx: wl.wl_fixed_t, sy: wl.wl_fixed_t) callconv(.c) void {
    _ = sx;
    _ = sy;
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

fn pointerButton(data: ?*anyopaque, _: ?*wl.wl_pointer, _: u32, _: u32, button: u32, btn_state: u32) callconv(.c) void {
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
        egl.EGL_CONTEXT_MAJOR_VERSION, 3,
        egl.EGL_CONTEXT_MINOR_VERSION, 3,
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

    // Row of buttons
    const button_row = try ctx.tree.addChild(root, .{ .container = .{ .direction = .row } });
    state.btn_a = try ctx.tree.addChild(button_row, .{ .button = .{ .label = "Button A" } });
    state.btn_b = try ctx.tree.addChild(button_row, .{ .button = .{ .label = "Button B" } });
    state.btn_c = try ctx.tree.addChild(button_row, .{ .button = .{ .label = "Button C" } });

    // Text label
    _ = try ctx.tree.addChild(root, .{ .text = .{ .content = "goop demo - click the buttons" } });

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

    // Scroll area with overflowing content
    const scroll = try ctx.tree.addChild(root, .{ .scroll_area = .{} });
    _ = try ctx.tree.addChild(scroll, .{ .text = .{ .content = "Scroll area line 1" } });
    _ = try ctx.tree.addChild(scroll, .{ .text = .{ .content = "Scroll area line 2" } });
    _ = try ctx.tree.addChild(scroll, .{ .text = .{ .content = "Scroll area line 3" } });
    _ = try ctx.tree.addChild(scroll, .{ .text = .{ .content = "Scroll area line 4" } });
    _ = try ctx.tree.addChild(scroll, .{ .text = .{ .content = "Scroll area line 5" } });
    _ = try ctx.tree.addChild(scroll, .{ .text = .{ .content = "Scroll area line 6" } });
    _ = try ctx.tree.addChild(scroll, .{ .text = .{ .content = "Scroll area line 7" } });
    _ = try ctx.tree.addChild(scroll, .{ .text = .{ .content = "Scroll area line 8" } });
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
