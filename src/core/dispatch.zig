const std = @import("std");
const widget = @import("widget.zig");
const event = @import("event.zig");
const focus = @import("focus.zig");
const hittest = @import("hittest.zig");

/// Transient input state tracked across events.
pub const MouseState = struct {
    x: f32 = 0,
    y: f32 = 0,
    left_down: bool = false,
    /// The widget that the left button went down on (for click detection).
    press_target: ?widget.NodeHandle = null,
    /// The slider currently being dragged, if any.
    drag_target: ?widget.NodeHandle = null,
    /// The currently keyboard-focused widget, if any.
    focused: ?widget.NodeHandle = null,
    /// Whether a shift key is currently held.
    shift_down: bool = false,
    /// Whether a ctrl key is currently held.
    ctrl_down: bool = false,
};

/// Process a batch of events against the widget tree.
/// Updates interaction state (hovered, pressed) and widget state (clicked).
/// Call after doLayout so layout_rects are populated.
const style = @import("style.zig");

pub fn process(tree: *widget.Tree, events: []const event.Event, mouse: *MouseState, theme: style.Theme) void {
    for (events) |ev| {
        processOne(tree, ev, mouse, theme);
    }
}

fn processOne(tree: *widget.Tree, ev: event.Event, mouse: *MouseState, theme: style.Theme) void {
    switch (ev) {
        .mouse_move => |mm| {
            mouse.x = mm.x;
            mouse.y = mm.y;
            if (mouse.drag_target) |dt| {
                updateSliderValue(tree, dt, mouse.x, theme);
            }
            updateHover(tree, mouse);
        },
        .mouse_button => |mb| {
            mouse.x = mb.x;
            mouse.y = mb.y;
            if (mb.button == .left) {
                if (mb.state == .pressed) {
                    mouse.left_down = true;
                    updateHover(tree, mouse);
                    // Mark the hovered widget as pressed and record press target
                    const target = hittest.hitTest(tree, mouse.x, mouse.y);
                    mouse.press_target = target;
                    if (target) |t| {
                        tree.get(t).interaction.pressed = true;
                        // Focus the clicked widget
                        if (focus.isFocusable(tree.getConst(t).kind)) {
                            mouse.focused = t;
                            focus.syncFocusFlags(tree, mouse.focused);
                        }
                        // Position cursor on click for text inputs
                        if (tree.getConst(t).kind == .text_input) {
                            const node = tree.get(t);
                            const rect = node.layout_rect;
                            const resolved = node.style_override.resolve(theme);
                            const char_width = resolved.font_size * 0.6;
                            const ti = &node.kind.text_input;
                            const text_x = rect.x + resolved.padding.left;
                            const rel_x = mouse.x - text_x;
                            const char_pos = if (char_width > 0) rel_x / char_width else 0;
                            const rounded: u8 = @intFromFloat(std.math.clamp(@round(char_pos), 0, @as(f32, @floatFromInt(ti.len))));
                            ti.cursor = rounded;
                            ti.clearSelection();
                        }
                        // Start slider drag
                        if (tree.getConst(t).kind == .slider) {
                            mouse.drag_target = t;
                            updateSliderValue(tree, t, mouse.x, theme);
                        }
                    }
                } else {
                    // Released
                    mouse.left_down = false;
                    mouse.drag_target = null;
                    const release_target = hittest.hitTest(tree, mouse.x, mouse.y);

                    // Click detection: released on the same widget we pressed on
                    if (mouse.press_target) |pt| {
                        if (release_target == pt) {
                            fireClick(tree, pt);
                        }
                        tree.get(pt).interaction.pressed = false;
                    }
                    mouse.press_target = null;
                    updateHover(tree, mouse);
                }
            }
        },
        .mouse_scroll => |ms| {
            // Find the scroll area under the cursor and adjust scroll offset
            const target = hittest.hitTestKind(tree, mouse.x, mouse.y, .scroll_area);
            if (target) |t| {
                const node = tree.get(t);
                node.kind.scroll_area.scroll_x += ms.dx;
                node.kind.scroll_area.scroll_y += ms.dy;
                clampScroll(tree, t);
            }
        },
        .key => |k| {
            switch (k.keycode) {
                .left_shift, .right_shift => {
                    mouse.shift_down = k.state == .pressed or k.state == .repeat;
                },
                .left_ctrl, .right_ctrl => {
                    mouse.ctrl_down = k.state == .pressed or k.state == .repeat;
                },
                .a => {
                    if (k.state == .pressed or k.state == .repeat) {
                        if (mouse.ctrl_down) {
                            if (mouse.focused) |f| {
                                const node = tree.get(f);
                                if (node.kind == .text_input) {
                                    const ti = &node.kind.text_input;
                                    if (ti.len > 0) {
                                        ti.selection_anchor = 0;
                                        ti.cursor = ti.len;
                                    }
                                }
                            }
                        }
                    }
                },
                .tab => {
                    if (k.state == .pressed or k.state == .repeat) {
                        if (mouse.shift_down) {
                            mouse.focused = focus.focusPrev(tree, mouse.focused);
                        } else {
                            mouse.focused = focus.focusNext(tree, mouse.focused);
                        }
                        focus.syncFocusFlags(tree, mouse.focused);
                    }
                },
                .backspace => {
                    if (k.state == .pressed or k.state == .repeat) {
                        if (mouse.focused) |f| {
                            const node = tree.get(f);
                            if (node.kind == .text_input) {
                                node.kind.text_input.deleteBack();
                            }
                        }
                    }
                },
                .delete => {
                    if (k.state == .pressed or k.state == .repeat) {
                        if (mouse.focused) |f| {
                            const node = tree.get(f);
                            if (node.kind == .text_input) {
                                node.kind.text_input.deleteForward();
                            }
                        }
                    }
                },
                .left => {
                    if (k.state == .pressed or k.state == .repeat) {
                        if (mouse.focused) |f| {
                            const node = tree.get(f);
                            if (node.kind == .text_input) {
                                const ti = &node.kind.text_input;
                                if (mouse.shift_down) {
                                    if (ti.selection_anchor == null) ti.selection_anchor = ti.cursor;
                                    if (ti.cursor > 0) ti.cursor -= 1;
                                } else if (ti.hasSelection()) {
                                    ti.cursor = ti.selectionRange().start;
                                    ti.clearSelection();
                                } else if (ti.cursor > 0) {
                                    ti.cursor -= 1;
                                }
                            }
                        }
                    }
                },
                .right => {
                    if (k.state == .pressed or k.state == .repeat) {
                        if (mouse.focused) |f| {
                            const node = tree.get(f);
                            if (node.kind == .text_input) {
                                const ti = &node.kind.text_input;
                                if (mouse.shift_down) {
                                    if (ti.selection_anchor == null) ti.selection_anchor = ti.cursor;
                                    if (ti.cursor < ti.len) ti.cursor += 1;
                                } else if (ti.hasSelection()) {
                                    ti.cursor = ti.selectionRange().end;
                                    ti.clearSelection();
                                } else if (ti.cursor < ti.len) {
                                    ti.cursor += 1;
                                }
                            }
                        }
                    }
                },
                .home => {
                    if (k.state == .pressed or k.state == .repeat) {
                        if (mouse.focused) |f| {
                            const node = tree.get(f);
                            if (node.kind == .text_input) {
                                const ti = &node.kind.text_input;
                                if (mouse.shift_down) {
                                    if (ti.selection_anchor == null) ti.selection_anchor = ti.cursor;
                                } else {
                                    ti.clearSelection();
                                }
                                ti.cursor = 0;
                            }
                        }
                    }
                },
                .end => {
                    if (k.state == .pressed or k.state == .repeat) {
                        if (mouse.focused) |f| {
                            const node = tree.get(f);
                            if (node.kind == .text_input) {
                                const ti = &node.kind.text_input;
                                if (mouse.shift_down) {
                                    if (ti.selection_anchor == null) ti.selection_anchor = ti.cursor;
                                } else {
                                    ti.clearSelection();
                                }
                                ti.cursor = ti.len;
                            }
                        }
                    }
                },
                .space, .enter => {
                    if (k.state == .pressed) {
                        if (mouse.focused) |f| {
                            fireClick(tree, f);
                        }
                    }
                },
                else => {},
            }
        },
        .text => |t| {
            if (mouse.focused) |f| {
                const node = tree.get(f);
                if (node.kind == .text_input) {
                    // Only handle printable ASCII for now
                    if (t.codepoint >= 0x20 and t.codepoint < 0x7F) {
                        node.kind.text_input.insert(@intCast(t.codepoint));
                    }
                }
            }
        },
        else => {},
    }
}

/// Update hovered state for all nodes based on current mouse position.
fn updateHover(tree: *widget.Tree, mouse: *const MouseState) void {
    const top = hittest.hitTest(tree, mouse.x, mouse.y);
    for (tree.nodes.items) |*node| {
        node.interaction.hovered = false;
    }
    if (top) |t| {
        tree.get(t).interaction.hovered = true;
    }
}

/// Update a slider's value based on mouse x position within its track.
fn updateSliderValue(tree: *widget.Tree, handle: widget.NodeHandle, mouse_x: f32, theme: style.Theme) void {
    const node = tree.get(handle);
    const rect = node.layout_rect;
    const resolved = node.style_override.resolve(theme);
    const thumb_w = resolved.thumb_width;
    const usable = rect.w - thumb_w;
    if (usable <= 0) return;
    const t = std.math.clamp((mouse_x - rect.x - thumb_w * 0.5) / usable, 0, 1);
    node.kind.slider.value = node.kind.slider.min + t * (node.kind.slider.max - node.kind.slider.min);
}

/// Clamp a scroll area's scroll values to keep content in bounds.
/// Uses children's layout rects from the previous frame.
fn clampScroll(tree: *widget.Tree, handle: widget.NodeHandle) void {
    const node = tree.get(handle);
    const viewport = node.layout_rect;
    const extent = contentExtent(tree, handle);

    const max_x = @max(extent.w - viewport.w, 0);
    const max_y = @max(extent.h - viewport.h, 0);

    node.kind.scroll_area.scroll_x = std.math.clamp(node.kind.scroll_area.scroll_x, 0, max_x);
    node.kind.scroll_area.scroll_y = std.math.clamp(node.kind.scroll_area.scroll_y, 0, max_y);
}

/// Compute the bounding box size of all direct children of a node.
/// Returns the total width and height the content occupies.
fn contentExtent(tree: *const widget.Tree, parent: widget.NodeHandle) struct { w: f32, h: f32 } {
    const parent_rect = tree.getConst(parent).layout_rect;
    var max_x: f32 = parent_rect.x;
    var max_y: f32 = parent_rect.y;

    var iter = tree.children(parent);
    while (iter.next()) |child| {
        const r = tree.getConst(child).layout_rect;
        max_x = @max(max_x, r.x + r.w);
        max_y = @max(max_y, r.y + r.h);
    }

    return .{
        .w = max_x - parent_rect.x,
        .h = max_y - parent_rect.y,
    };
}

/// Fire a click on a widget.
fn fireClick(tree: *widget.Tree, handle: widget.NodeHandle) void {
    const node = tree.get(handle);
    switch (node.kind) {
        .button => {
            node.kind.button.clicked = true;
        },
        .checkbox => {
            node.kind.checkbox.checked = !node.kind.checkbox.checked;
            node.kind.checkbox.clicked = true;
        },
        .radio_button => {
            const group = node.kind.radio_button.group;
            // Deselect all other radio buttons in the same group
            for (tree.nodes.items) |*n| {
                if (n.kind == .radio_button and n.kind.radio_button.group == group) {
                    n.kind.radio_button.selected = false;
                }
            }
            node.kind.radio_button.selected = true;
            node.kind.radio_button.clicked = true;
        },
        else => {},
    }
}

// --- Tests ---

test "hover updates on mouse move" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const btn = try tree.addChild(root, .{ .button = .{ .label = "OK" } });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(btn).layout_rect = .{ .x = 10, .y = 10, .w = 100, .h = 30 };

    var mouse = MouseState{};

    // Move onto button
    process(&tree, &.{.{ .mouse_move = .{ .x = 50, .y = 20 } }}, &mouse, style.Theme.default);
    try std.testing.expect(tree.getConst(btn).interaction.hovered);
    try std.testing.expect(!tree.getConst(root).interaction.hovered);

    // Move off button but still on root
    process(&tree, &.{.{ .mouse_move = .{ .x = 500, .y = 300 } }}, &mouse, style.Theme.default);
    try std.testing.expect(!tree.getConst(btn).interaction.hovered);
    try std.testing.expect(tree.getConst(root).interaction.hovered);
}

test "button click sets clicked flag" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const btn = try tree.addChild(root, .{ .button = .{ .label = "Click me" } });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(btn).layout_rect = .{ .x = 10, .y = 10, .w = 100, .h = 30 };

    var mouse = MouseState{};

    // Press and release on button
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 50, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 50, .y = 20 } },
    }, &mouse, style.Theme.default);

    try std.testing.expect(tree.getConst(btn).kind.button.clicked);
    try std.testing.expect(!tree.getConst(btn).interaction.pressed);
}

test "press and release on different widgets does not click" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const btn = try tree.addChild(root, .{ .button = .{ .label = "A" } });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(btn).layout_rect = .{ .x = 10, .y = 10, .w = 100, .h = 30 };

    var mouse = MouseState{};

    // Press on button, release elsewhere
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 50, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 500, .y = 300 } },
    }, &mouse, style.Theme.default);

    try std.testing.expect(!tree.getConst(btn).kind.button.clicked);
}

test "slider drag updates value" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const sl = try tree.addChild(root, .{ .slider = .{ .value = 0, .min = 0, .max = 100 } });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(sl).layout_rect = .{ .x = 10, .y = 10, .w = 200, .h = 24 };

    var mouse = MouseState{};

    // Click at the midpoint of the slider track
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 110, .y = 20 } },
    }, &mouse, style.Theme.default);

    // Should have started dragging
    try std.testing.expect(mouse.drag_target != null);
    const val_after_press = tree.getConst(sl).kind.slider.value;
    try std.testing.expect(val_after_press > 40 and val_after_press < 60);

    // Drag to the right end
    process(&tree, &.{
        .{ .mouse_move = .{ .x = 210, .y = 20 } },
    }, &mouse, style.Theme.default);
    try std.testing.expectApproxEqAbs(@as(f32, 100), tree.getConst(sl).kind.slider.value, 1.0);

    // Drag to the left end
    process(&tree, &.{
        .{ .mouse_move = .{ .x = 10, .y = 20 } },
    }, &mouse, style.Theme.default);
    try std.testing.expectApproxEqAbs(@as(f32, 0), tree.getConst(sl).kind.slider.value, 1.0);

    // Release — drag should stop
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 10, .y = 20 } },
    }, &mouse, style.Theme.default);
    try std.testing.expect(mouse.drag_target == null);

    // Move after release should not change value
    process(&tree, &.{
        .{ .mouse_move = .{ .x = 150, .y = 20 } },
    }, &mouse, style.Theme.default);
    try std.testing.expectApproxEqAbs(@as(f32, 0), tree.getConst(sl).kind.slider.value, 1.0);
}

test "checkbox toggles on click" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const cb = try tree.addChild(root, .{ .checkbox = .{ .label = "Enable", .checked = false } });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(cb).layout_rect = .{ .x = 10, .y = 10, .w = 200, .h = 26 };

    var mouse = MouseState{};

    // Click to check
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 50, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 50, .y = 20 } },
    }, &mouse, style.Theme.default);
    try std.testing.expect(tree.getConst(cb).kind.checkbox.checked);

    // Click again to uncheck
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 50, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 50, .y = 20 } },
    }, &mouse, style.Theme.default);
    try std.testing.expect(!tree.getConst(cb).kind.checkbox.checked);
}

test "radio button selects and deselects group siblings" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const rb1 = try tree.addChild(root, .{ .radio_button = .{ .label = "A", .group = 1 } });
    const rb2 = try tree.addChild(root, .{ .radio_button = .{ .label = "B", .group = 1 } });
    const rb3 = try tree.addChild(root, .{ .radio_button = .{ .label = "Other", .group = 2 } });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(rb1).layout_rect = .{ .x = 10, .y = 10, .w = 200, .h = 26 };
    tree.get(rb2).layout_rect = .{ .x = 10, .y = 40, .w = 200, .h = 26 };
    tree.get(rb3).layout_rect = .{ .x = 10, .y = 70, .w = 200, .h = 26 };

    var mouse = MouseState{};

    // Click rb1
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 50, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 50, .y = 20 } },
    }, &mouse, style.Theme.default);
    try std.testing.expect(tree.getConst(rb1).kind.radio_button.selected);
    try std.testing.expect(!tree.getConst(rb2).kind.radio_button.selected);

    // Click rb2 — should deselect rb1
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 50, .y = 50 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 50, .y = 50 } },
    }, &mouse, style.Theme.default);
    try std.testing.expect(!tree.getConst(rb1).kind.radio_button.selected);
    try std.testing.expect(tree.getConst(rb2).kind.radio_button.selected);

    // rb3 (different group) should be unaffected
    try std.testing.expect(!tree.getConst(rb3).kind.radio_button.selected);

    // Click rb3 — group 1 should be unaffected
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 50, .y = 80 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 50, .y = 80 } },
    }, &mouse, style.Theme.default);
    try std.testing.expect(tree.getConst(rb2).kind.radio_button.selected);
    try std.testing.expect(tree.getConst(rb3).kind.radio_button.selected);
}

test "scroll area responds to mouse scroll" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const scroll = try tree.addRoot(.{ .scroll_area = .{} });
    // Add a child taller than the viewport so scrolling is possible
    const child = try tree.addChild(scroll, .{ .text = .{ .content = "tall content" } });
    tree.get(scroll).layout_rect = .{ .x = 0, .y = 0, .w = 300, .h = 200 };
    tree.get(child).layout_rect = .{ .x = 0, .y = 0, .w = 300, .h = 500 };

    var mouse = MouseState{ .x = 150, .y = 100 };

    process(&tree, &.{.{ .mouse_scroll = .{ .dx = 0, .dy = 30 } }}, &mouse, style.Theme.default);

    try std.testing.expectApproxEqAbs(@as(f32, 30), tree.getConst(scroll).kind.scroll_area.scroll_y, 0.01);
}

test "scroll clamped to content bounds" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const scroll = try tree.addRoot(.{ .scroll_area = .{} });
    const child = try tree.addChild(scroll, .{ .text = .{ .content = "content" } });
    tree.get(scroll).layout_rect = .{ .x = 0, .y = 0, .w = 300, .h = 200 };
    tree.get(child).layout_rect = .{ .x = 0, .y = 0, .w = 300, .h = 400 };

    var mouse = MouseState{ .x = 150, .y = 100 };

    // Scroll way past content — should clamp to max (400 - 200 = 200)
    process(&tree, &.{.{ .mouse_scroll = .{ .dx = 0, .dy = 9999 } }}, &mouse, style.Theme.default);
    try std.testing.expectApproxEqAbs(@as(f32, 200), tree.getConst(scroll).kind.scroll_area.scroll_y, 0.01);

    // Scroll negative — should clamp to 0
    process(&tree, &.{.{ .mouse_scroll = .{ .dx = 0, .dy = -9999 } }}, &mouse, style.Theme.default);
    try std.testing.expectApproxEqAbs(@as(f32, 0), tree.getConst(scroll).kind.scroll_area.scroll_y, 0.01);
}

test "scroll clamped when content fits viewport" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const scroll = try tree.addRoot(.{ .scroll_area = .{} });
    const child = try tree.addChild(scroll, .{ .text = .{ .content = "small" } });
    tree.get(scroll).layout_rect = .{ .x = 0, .y = 0, .w = 300, .h = 200 };
    tree.get(child).layout_rect = .{ .x = 0, .y = 0, .w = 100, .h = 50 };

    var mouse = MouseState{ .x = 150, .y = 100 };

    // Content fits — any scroll should clamp to 0
    process(&tree, &.{.{ .mouse_scroll = .{ .dx = 50, .dy = 50 } }}, &mouse, style.Theme.default);
    try std.testing.expectApproxEqAbs(@as(f32, 0), tree.getConst(scroll).kind.scroll_area.scroll_x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0), tree.getConst(scroll).kind.scroll_area.scroll_y, 0.01);
}

test "tab cycles focus through focusable widgets" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const btn = try tree.addChild(root, .{ .button = .{ .label = "A" } });
    _ = try tree.addChild(root, .{ .text = .{ .content = "skip me" } });
    const cb = try tree.addChild(root, .{ .checkbox = .{ .label = "B" } });
    const sl = try tree.addChild(root, .{ .slider = .{ .value = 0 } });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(btn).layout_rect = .{ .x = 10, .y = 10, .w = 100, .h = 30 };
    tree.get(cb).layout_rect = .{ .x = 10, .y = 50, .w = 200, .h = 26 };
    tree.get(sl).layout_rect = .{ .x = 10, .y = 80, .w = 200, .h = 24 };

    var mouse = MouseState{};
    const tab_press = event.Event{ .key = .{ .scancode = 15, .keycode = .tab, .state = .pressed } };

    // First tab: focus button (first focusable)
    process(&tree, &.{tab_press}, &mouse, style.Theme.default);
    try std.testing.expectEqual(mouse.focused, btn);
    try std.testing.expect(tree.getConst(btn).interaction.focused);

    // Second tab: focus checkbox (skips text)
    process(&tree, &.{tab_press}, &mouse, style.Theme.default);
    try std.testing.expectEqual(mouse.focused, cb);
    try std.testing.expect(!tree.getConst(btn).interaction.focused);
    try std.testing.expect(tree.getConst(cb).interaction.focused);

    // Third tab: focus slider
    process(&tree, &.{tab_press}, &mouse, style.Theme.default);
    try std.testing.expectEqual(mouse.focused, sl);

    // Fourth tab: wraps to button
    process(&tree, &.{tab_press}, &mouse, style.Theme.default);
    try std.testing.expectEqual(mouse.focused, btn);
}

test "shift+tab cycles focus backwards" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const btn = try tree.addChild(root, .{ .button = .{ .label = "A" } });
    const cb = try tree.addChild(root, .{ .checkbox = .{ .label = "B" } });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(btn).layout_rect = .{ .x = 10, .y = 10, .w = 100, .h = 30 };
    tree.get(cb).layout_rect = .{ .x = 10, .y = 50, .w = 200, .h = 26 };

    var mouse = MouseState{};
    const shift_down = event.Event{ .key = .{ .scancode = 42, .keycode = .left_shift, .state = .pressed } };
    const tab_press = event.Event{ .key = .{ .scancode = 15, .keycode = .tab, .state = .pressed } };
    const shift_up = event.Event{ .key = .{ .scancode = 42, .keycode = .left_shift, .state = .released } };

    // Shift+Tab from no focus: should go to last focusable (checkbox)
    process(&tree, &.{ shift_down, tab_press, shift_up }, &mouse, style.Theme.default);
    try std.testing.expectEqual(mouse.focused, cb);

    // Shift+Tab again: should go to button
    process(&tree, &.{ shift_down, tab_press, shift_up }, &mouse, style.Theme.default);
    try std.testing.expectEqual(mouse.focused, btn);
}

test "enter/space activates focused widget" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const btn = try tree.addChild(root, .{ .button = .{ .label = "OK" } });
    const cb = try tree.addChild(root, .{ .checkbox = .{ .label = "Toggle" } });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(btn).layout_rect = .{ .x = 10, .y = 10, .w = 100, .h = 30 };
    tree.get(cb).layout_rect = .{ .x = 10, .y = 50, .w = 200, .h = 26 };

    var mouse = MouseState{};

    // Tab to button, then press Enter
    process(&tree, &.{
        .{ .key = .{ .scancode = 15, .keycode = .tab, .state = .pressed } },
        .{ .key = .{ .scancode = 28, .keycode = .enter, .state = .pressed } },
    }, &mouse, style.Theme.default);
    try std.testing.expect(tree.getConst(btn).kind.button.clicked);

    // Tab to checkbox, press Space to toggle
    process(&tree, &.{
        .{ .key = .{ .scancode = 15, .keycode = .tab, .state = .pressed } },
        .{ .key = .{ .scancode = 57, .keycode = .space, .state = .pressed } },
    }, &mouse, style.Theme.default);
    try std.testing.expect(tree.getConst(cb).kind.checkbox.checked);
}

test "click sets focus" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const btn = try tree.addChild(root, .{ .button = .{ .label = "A" } });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(btn).layout_rect = .{ .x = 10, .y = 10, .w = 100, .h = 30 };

    var mouse = MouseState{};

    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 50, .y = 20 } },
    }, &mouse, style.Theme.default);

    try std.testing.expectEqual(mouse.focused, btn);
    try std.testing.expect(tree.getConst(btn).interaction.focused);
}

test "text input receives character events" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const ti = try tree.addChild(root, .{ .text_input = .{} });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(ti).layout_rect = .{ .x = 10, .y = 10, .w = 300, .h = 30 };

    var mouse = MouseState{};

    // Click to focus the text input
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 50, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 50, .y = 20 } },
    }, &mouse, style.Theme.default);
    try std.testing.expectEqual(mouse.focused, ti);

    // Type "hi"
    process(&tree, &.{
        .{ .text = .{ .codepoint = 'h' } },
        .{ .text = .{ .codepoint = 'i' } },
    }, &mouse, style.Theme.default);

    try std.testing.expectEqualStrings("hi", tree.getConst(ti).kind.text_input.content());
}

test "text input backspace deletes characters" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const ti = try tree.addChild(root, .{ .text_input = .{} });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(ti).layout_rect = .{ .x = 10, .y = 10, .w = 300, .h = 30 };

    var mouse = MouseState{};

    // Click to focus
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 50, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 50, .y = 20 } },
    }, &mouse, style.Theme.default);

    // Type "abc" then backspace
    process(&tree, &.{
        .{ .text = .{ .codepoint = 'a' } },
        .{ .text = .{ .codepoint = 'b' } },
        .{ .text = .{ .codepoint = 'c' } },
        .{ .key = .{ .scancode = 14, .keycode = .backspace, .state = .pressed } },
    }, &mouse, style.Theme.default);

    try std.testing.expectEqualStrings("ab", tree.getConst(ti).kind.text_input.content());
}

test "text input delete key deletes forward" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const ti = try tree.addChild(root, .{ .text_input = .{} });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(ti).layout_rect = .{ .x = 10, .y = 10, .w = 300, .h = 30 };

    var mouse = MouseState{};

    // Click to focus
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 50, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 50, .y = 20 } },
    }, &mouse, style.Theme.default);

    // Type "abc", move cursor left twice, then delete forward
    process(&tree, &.{
        .{ .text = .{ .codepoint = 'a' } },
        .{ .text = .{ .codepoint = 'b' } },
        .{ .text = .{ .codepoint = 'c' } },
        .{ .key = .{ .scancode = 105, .keycode = .left, .state = .pressed } },
        .{ .key = .{ .scancode = 105, .keycode = .left, .state = .pressed } },
        .{ .key = .{ .scancode = 111, .keycode = .delete, .state = .pressed } },
    }, &mouse, style.Theme.default);

    // Should delete 'b', leaving "ac" with cursor at position 1
    try std.testing.expectEqualStrings("ac", tree.getConst(ti).kind.text_input.content());
    try std.testing.expectEqual(@as(u8, 1), tree.getConst(ti).kind.text_input.cursor);
}

test "text input ignores input when not focused" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const ti = try tree.addChild(root, .{ .text_input = .{} });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(ti).layout_rect = .{ .x = 10, .y = 10, .w = 300, .h = 30 };

    var mouse = MouseState{};

    // Type without focusing — should be ignored
    process(&tree, &.{
        .{ .text = .{ .codepoint = 'x' } },
    }, &mouse, style.Theme.default);

    try std.testing.expectEqualStrings("", tree.getConst(ti).kind.text_input.content());
}

test "text input arrow keys move cursor" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const ti = try tree.addChild(root, .{ .text_input = .{} });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(ti).layout_rect = .{ .x = 10, .y = 10, .w = 300, .h = 30 };

    var mouse = MouseState{};

    // Click to focus
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 50, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 50, .y = 20 } },
    }, &mouse, style.Theme.default);

    // Type "abc" — cursor at 3
    process(&tree, &.{
        .{ .text = .{ .codepoint = 'a' } },
        .{ .text = .{ .codepoint = 'b' } },
        .{ .text = .{ .codepoint = 'c' } },
    }, &mouse, style.Theme.default);
    try std.testing.expectEqual(@as(u8, 3), tree.getConst(ti).kind.text_input.cursor);

    // Left arrow twice — cursor at 1
    process(&tree, &.{
        .{ .key = .{ .scancode = 105, .keycode = .left, .state = .pressed } },
        .{ .key = .{ .scancode = 105, .keycode = .left, .state = .pressed } },
    }, &mouse, style.Theme.default);
    try std.testing.expectEqual(@as(u8, 1), tree.getConst(ti).kind.text_input.cursor);

    // Right arrow once — cursor at 2
    process(&tree, &.{
        .{ .key = .{ .scancode = 106, .keycode = .right, .state = .pressed } },
    }, &mouse, style.Theme.default);
    try std.testing.expectEqual(@as(u8, 2), tree.getConst(ti).kind.text_input.cursor);

    // Insert 'x' at cursor position 2 — "abxc"
    process(&tree, &.{
        .{ .text = .{ .codepoint = 'x' } },
    }, &mouse, style.Theme.default);
    try std.testing.expectEqualStrings("abxc", tree.getConst(ti).kind.text_input.content());

    // Left arrow at position 0 stays at 0
    process(&tree, &.{
        .{ .key = .{ .scancode = 105, .keycode = .left, .state = .pressed } },
        .{ .key = .{ .scancode = 105, .keycode = .left, .state = .pressed } },
        .{ .key = .{ .scancode = 105, .keycode = .left, .state = .pressed } },
        .{ .key = .{ .scancode = 105, .keycode = .left, .state = .pressed } },
        .{ .key = .{ .scancode = 105, .keycode = .left, .state = .pressed } },
    }, &mouse, style.Theme.default);
    try std.testing.expectEqual(@as(u8, 0), tree.getConst(ti).kind.text_input.cursor);

    // Right arrow past end stays at len
    process(&tree, &.{
        .{ .key = .{ .scancode = 106, .keycode = .right, .state = .pressed } },
        .{ .key = .{ .scancode = 106, .keycode = .right, .state = .pressed } },
        .{ .key = .{ .scancode = 106, .keycode = .right, .state = .pressed } },
        .{ .key = .{ .scancode = 106, .keycode = .right, .state = .pressed } },
        .{ .key = .{ .scancode = 106, .keycode = .right, .state = .pressed } },
    }, &mouse, style.Theme.default);
    try std.testing.expectEqual(@as(u8, 4), tree.getConst(ti).kind.text_input.cursor);
}

test "text input is focusable via tab" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const btn = try tree.addChild(root, .{ .button = .{ .label = "OK" } });
    const ti = try tree.addChild(root, .{ .text_input = .{} });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(btn).layout_rect = .{ .x = 10, .y = 10, .w = 100, .h = 30 };
    tree.get(ti).layout_rect = .{ .x = 10, .y = 50, .w = 300, .h = 30 };

    var mouse = MouseState{};
    const tab = event.Event{ .key = .{ .scancode = 15, .keycode = .tab, .state = .pressed } };

    // First tab: focus button
    process(&tree, &.{tab}, &mouse, style.Theme.default);
    try std.testing.expectEqual(mouse.focused, btn);

    // Second tab: focus text input
    process(&tree, &.{tab}, &mouse, style.Theme.default);
    try std.testing.expectEqual(mouse.focused, ti);
    try std.testing.expect(tree.getConst(ti).interaction.focused);
}

test "text input home/end keys move cursor" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const ti = try tree.addChild(root, .{ .text_input = .{} });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(ti).layout_rect = .{ .x = 10, .y = 10, .w = 300, .h = 30 };

    var mouse = MouseState{};

    // Click to focus
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 50, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 50, .y = 20 } },
    }, &mouse, style.Theme.default);

    // Type "hello" — cursor at 5
    process(&tree, &.{
        .{ .text = .{ .codepoint = 'h' } },
        .{ .text = .{ .codepoint = 'e' } },
        .{ .text = .{ .codepoint = 'l' } },
        .{ .text = .{ .codepoint = 'l' } },
        .{ .text = .{ .codepoint = 'o' } },
    }, &mouse, style.Theme.default);
    try std.testing.expectEqual(@as(u8, 5), tree.getConst(ti).kind.text_input.cursor);

    // Home — cursor at 0
    process(&tree, &.{
        .{ .key = .{ .scancode = 102, .keycode = .home, .state = .pressed } },
    }, &mouse, style.Theme.default);
    try std.testing.expectEqual(@as(u8, 0), tree.getConst(ti).kind.text_input.cursor);

    // Home when already at 0 — stays at 0
    process(&tree, &.{
        .{ .key = .{ .scancode = 102, .keycode = .home, .state = .pressed } },
    }, &mouse, style.Theme.default);
    try std.testing.expectEqual(@as(u8, 0), tree.getConst(ti).kind.text_input.cursor);

    // End — cursor at 5
    process(&tree, &.{
        .{ .key = .{ .scancode = 107, .keycode = .end, .state = .pressed } },
    }, &mouse, style.Theme.default);
    try std.testing.expectEqual(@as(u8, 5), tree.getConst(ti).kind.text_input.cursor);

    // End when already at end — stays at end
    process(&tree, &.{
        .{ .key = .{ .scancode = 107, .keycode = .end, .state = .pressed } },
    }, &mouse, style.Theme.default);
    try std.testing.expectEqual(@as(u8, 5), tree.getConst(ti).kind.text_input.cursor);
}

test "shift+arrow creates selection" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const ti = try tree.addChild(root, .{ .text_input = .{} });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(ti).layout_rect = .{ .x = 10, .y = 10, .w = 300, .h = 30 };

    var mouse = MouseState{};

    // Click to focus
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 50, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 50, .y = 20 } },
    }, &mouse, style.Theme.default);

    // Type "hello"
    process(&tree, &.{
        .{ .text = .{ .codepoint = 'h' } },
        .{ .text = .{ .codepoint = 'e' } },
        .{ .text = .{ .codepoint = 'l' } },
        .{ .text = .{ .codepoint = 'l' } },
        .{ .text = .{ .codepoint = 'o' } },
    }, &mouse, style.Theme.default);

    // Shift+Left twice — select "lo" (cursor 5->3, anchor 5)
    process(&tree, &.{
        .{ .key = .{ .scancode = 42, .keycode = .left_shift, .state = .pressed } },
        .{ .key = .{ .scancode = 105, .keycode = .left, .state = .pressed } },
        .{ .key = .{ .scancode = 105, .keycode = .left, .state = .pressed } },
    }, &mouse, style.Theme.default);

    const input = &tree.get(ti).kind.text_input;
    try std.testing.expect(input.hasSelection());
    try std.testing.expectEqual(@as(u8, 3), input.cursor);
    try std.testing.expectEqual(@as(?u8, 5), input.selection_anchor);
    try std.testing.expectEqualStrings("lo", input.selectedContent());
}

test "arrow without shift collapses selection" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const ti = try tree.addChild(root, .{ .text_input = .{} });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(ti).layout_rect = .{ .x = 10, .y = 10, .w = 300, .h = 30 };

    var mouse = MouseState{};

    // Click to focus
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 50, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 50, .y = 20 } },
    }, &mouse, style.Theme.default);

    // Type "abc"
    process(&tree, &.{
        .{ .text = .{ .codepoint = 'a' } },
        .{ .text = .{ .codepoint = 'b' } },
        .{ .text = .{ .codepoint = 'c' } },
    }, &mouse, style.Theme.default);

    // Shift+Left twice — select "bc"
    process(&tree, &.{
        .{ .key = .{ .scancode = 42, .keycode = .left_shift, .state = .pressed } },
        .{ .key = .{ .scancode = 105, .keycode = .left, .state = .pressed } },
        .{ .key = .{ .scancode = 105, .keycode = .left, .state = .pressed } },
    }, &mouse, style.Theme.default);

    // Release shift, press Left — collapse to start of selection
    process(&tree, &.{
        .{ .key = .{ .scancode = 42, .keycode = .left_shift, .state = .released } },
        .{ .key = .{ .scancode = 105, .keycode = .left, .state = .pressed } },
    }, &mouse, style.Theme.default);

    const input = &tree.get(ti).kind.text_input;
    try std.testing.expect(!input.hasSelection());
    try std.testing.expectEqual(@as(u8, 1), input.cursor);

    // Now right-collapse: re-select then press Right
    process(&tree, &.{
        .{ .key = .{ .scancode = 42, .keycode = .left_shift, .state = .pressed } },
        .{ .key = .{ .scancode = 106, .keycode = .right, .state = .pressed } },
        .{ .key = .{ .scancode = 106, .keycode = .right, .state = .pressed } },
        .{ .key = .{ .scancode = 42, .keycode = .left_shift, .state = .released } },
        .{ .key = .{ .scancode = 106, .keycode = .right, .state = .pressed } },
    }, &mouse, style.Theme.default);

    try std.testing.expect(!input.hasSelection());
    try std.testing.expectEqual(@as(u8, 3), input.cursor);
}

test "backspace deletes selection" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const ti = try tree.addChild(root, .{ .text_input = .{} });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(ti).layout_rect = .{ .x = 10, .y = 10, .w = 300, .h = 30 };

    var mouse = MouseState{};

    // Click to focus
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 50, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 50, .y = 20 } },
    }, &mouse, style.Theme.default);

    // Type "abcd"
    process(&tree, &.{
        .{ .text = .{ .codepoint = 'a' } },
        .{ .text = .{ .codepoint = 'b' } },
        .{ .text = .{ .codepoint = 'c' } },
        .{ .text = .{ .codepoint = 'd' } },
    }, &mouse, style.Theme.default);

    // Select "bc" (shift+left twice from end, then shift+right to deselect 'd', actually let's just select middle)
    // Move to position 1, then shift+right twice to select "bc"
    process(&tree, &.{
        .{ .key = .{ .scancode = 102, .keycode = .home, .state = .pressed } },
        .{ .key = .{ .scancode = 106, .keycode = .right, .state = .pressed } },
    }, &mouse, style.Theme.default);
    // cursor at 1
    process(&tree, &.{
        .{ .key = .{ .scancode = 42, .keycode = .left_shift, .state = .pressed } },
        .{ .key = .{ .scancode = 106, .keycode = .right, .state = .pressed } },
        .{ .key = .{ .scancode = 106, .keycode = .right, .state = .pressed } },
    }, &mouse, style.Theme.default);

    try std.testing.expectEqualStrings("bc", tree.get(ti).kind.text_input.selectedContent());

    // Backspace deletes the selection
    process(&tree, &.{
        .{ .key = .{ .scancode = 14, .keycode = .backspace, .state = .pressed } },
    }, &mouse, style.Theme.default);

    try std.testing.expectEqualStrings("ad", tree.get(ti).kind.text_input.content());
    try std.testing.expectEqual(@as(u8, 1), tree.get(ti).kind.text_input.cursor);
    try std.testing.expect(!tree.get(ti).kind.text_input.hasSelection());
}

test "typing replaces selection" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const ti = try tree.addChild(root, .{ .text_input = .{} });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(ti).layout_rect = .{ .x = 10, .y = 10, .w = 300, .h = 30 };

    var mouse = MouseState{};

    // Click to focus
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 50, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 50, .y = 20 } },
    }, &mouse, style.Theme.default);

    // Type "hello"
    process(&tree, &.{
        .{ .text = .{ .codepoint = 'h' } },
        .{ .text = .{ .codepoint = 'e' } },
        .{ .text = .{ .codepoint = 'l' } },
        .{ .text = .{ .codepoint = 'l' } },
        .{ .text = .{ .codepoint = 'o' } },
    }, &mouse, style.Theme.default);

    // Select all with Shift+Home
    process(&tree, &.{
        .{ .key = .{ .scancode = 42, .keycode = .left_shift, .state = .pressed } },
        .{ .key = .{ .scancode = 102, .keycode = .home, .state = .pressed } },
    }, &mouse, style.Theme.default);

    try std.testing.expect(tree.get(ti).kind.text_input.hasSelection());

    // Type "x" — replaces entire selection
    process(&tree, &.{
        .{ .text = .{ .codepoint = 'x' } },
    }, &mouse, style.Theme.default);

    try std.testing.expectEqualStrings("x", tree.get(ti).kind.text_input.content());
    try std.testing.expect(!tree.get(ti).kind.text_input.hasSelection());
}

test "ctrl+a selects all text" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const ti = try tree.addChild(root, .{ .text_input = .{} });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(ti).layout_rect = .{ .x = 10, .y = 10, .w = 300, .h = 30 };

    var mouse = MouseState{};

    // Click to focus
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 50, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 50, .y = 20 } },
    }, &mouse, style.Theme.default);

    // Type "hello"
    process(&tree, &.{
        .{ .text = .{ .codepoint = 'h' } },
        .{ .text = .{ .codepoint = 'e' } },
        .{ .text = .{ .codepoint = 'l' } },
        .{ .text = .{ .codepoint = 'l' } },
        .{ .text = .{ .codepoint = 'o' } },
    }, &mouse, style.Theme.default);

    // Ctrl+A
    process(&tree, &.{
        .{ .key = .{ .scancode = 29, .keycode = .left_ctrl, .state = .pressed } },
        .{ .key = .{ .scancode = 30, .keycode = .a, .state = .pressed } },
    }, &mouse, style.Theme.default);

    const input = &tree.get(ti).kind.text_input;
    try std.testing.expect(input.hasSelection());
    try std.testing.expectEqual(@as(?u8, 0), input.selection_anchor);
    try std.testing.expectEqual(@as(u8, 5), input.cursor);
    try std.testing.expectEqualStrings("hello", input.selectedContent());
}

test "ctrl+a on empty input is no-op" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const ti = try tree.addChild(root, .{ .text_input = .{} });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(ti).layout_rect = .{ .x = 10, .y = 10, .w = 300, .h = 30 };

    var mouse = MouseState{};

    // Click to focus
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 50, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 50, .y = 20 } },
    }, &mouse, style.Theme.default);

    // Ctrl+A on empty
    process(&tree, &.{
        .{ .key = .{ .scancode = 29, .keycode = .left_ctrl, .state = .pressed } },
        .{ .key = .{ .scancode = 30, .keycode = .a, .state = .pressed } },
    }, &mouse, style.Theme.default);

    const input = &tree.get(ti).kind.text_input;
    try std.testing.expect(!input.hasSelection());
    try std.testing.expectEqual(@as(u8, 0), input.cursor);
}

test "click positions cursor in text input" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const ti = try tree.addChild(root, .{ .text_input = .{} });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(ti).layout_rect = .{ .x = 10, .y = 10, .w = 300, .h = 30 };

    var mouse = MouseState{};

    // Click to focus and type "hello"
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 50, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 50, .y = 20 } },
    }, &mouse, style.Theme.default);
    process(&tree, &.{
        .{ .text = .{ .codepoint = 'h' } },
        .{ .text = .{ .codepoint = 'e' } },
        .{ .text = .{ .codepoint = 'l' } },
        .{ .text = .{ .codepoint = 'l' } },
        .{ .text = .{ .codepoint = 'o' } },
    }, &mouse, style.Theme.default);

    // Cursor should be at 5 (end). Now click at position 2.
    // Text starts at rect.x(10) + padding.left(6) = 16.
    // char_width = 14 * 0.6 = 8.4
    // To click at char 2: x = 16 + 2 * 8.4 = 32.8
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 32.8, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 32.8, .y = 20 } },
    }, &mouse, style.Theme.default);

    const input = &tree.get(ti).kind.text_input;
    try std.testing.expectEqual(@as(u8, 2), input.cursor);
    try std.testing.expect(!input.hasSelection());
}

test "click before text positions cursor at 0" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const ti = try tree.addChild(root, .{ .text_input = .{} });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(ti).layout_rect = .{ .x = 10, .y = 10, .w = 300, .h = 30 };

    var mouse = MouseState{};

    // Focus and type
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 50, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 50, .y = 20 } },
    }, &mouse, style.Theme.default);
    process(&tree, &.{
        .{ .text = .{ .codepoint = 'a' } },
        .{ .text = .{ .codepoint = 'b' } },
        .{ .text = .{ .codepoint = 'c' } },
    }, &mouse, style.Theme.default);

    // Click at x=12 which is before text start (16), should clamp to 0
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 12, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 12, .y = 20 } },
    }, &mouse, style.Theme.default);

    try std.testing.expectEqual(@as(u8, 0), tree.get(ti).kind.text_input.cursor);
}

test "click past text end positions cursor at len" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const ti = try tree.addChild(root, .{ .text_input = .{} });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(ti).layout_rect = .{ .x = 10, .y = 10, .w = 300, .h = 30 };

    var mouse = MouseState{};

    // Focus and type "hi"
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 50, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 50, .y = 20 } },
    }, &mouse, style.Theme.default);
    process(&tree, &.{
        .{ .text = .{ .codepoint = 'h' } },
        .{ .text = .{ .codepoint = 'i' } },
    }, &mouse, style.Theme.default);

    // Click way past end of text
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 200, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 200, .y = 20 } },
    }, &mouse, style.Theme.default);

    try std.testing.expectEqual(@as(u8, 2), tree.get(ti).kind.text_input.cursor);
}

test "click clears existing selection" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const ti = try tree.addChild(root, .{ .text_input = .{} });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(ti).layout_rect = .{ .x = 10, .y = 10, .w = 300, .h = 30 };

    var mouse = MouseState{};

    // Focus and type "hello"
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 50, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 50, .y = 20 } },
    }, &mouse, style.Theme.default);
    process(&tree, &.{
        .{ .text = .{ .codepoint = 'h' } },
        .{ .text = .{ .codepoint = 'e' } },
        .{ .text = .{ .codepoint = 'l' } },
        .{ .text = .{ .codepoint = 'l' } },
        .{ .text = .{ .codepoint = 'o' } },
    }, &mouse, style.Theme.default);

    // Select all with Ctrl+A
    process(&tree, &.{
        .{ .key = .{ .scancode = 29, .keycode = .left_ctrl, .state = .pressed } },
        .{ .key = .{ .scancode = 30, .keycode = .a, .state = .pressed } },
        .{ .key = .{ .scancode = 30, .keycode = .a, .state = .released } },
        .{ .key = .{ .scancode = 29, .keycode = .left_ctrl, .state = .released } },
    }, &mouse, style.Theme.default);

    try std.testing.expect(tree.get(ti).kind.text_input.hasSelection());

    // Click to position — should clear selection
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 30, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 30, .y = 20 } },
    }, &mouse, style.Theme.default);

    const input = &tree.get(ti).kind.text_input;
    try std.testing.expect(!input.hasSelection());
}
