const std = @import("std");
const widget = @import("widget.zig");
const event = @import("event.zig");
const draw = @import("draw.zig");

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
                    const target = hitTest(tree, mouse.x, mouse.y);
                    mouse.press_target = target;
                    if (target) |t| {
                        tree.get(t).interaction.pressed = true;
                        // Focus the clicked widget
                        if (isFocusable(tree.getConst(t).kind)) {
                            mouse.focused = t;
                            syncFocusFlags(tree, mouse.focused);
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
                    const release_target = hitTest(tree, mouse.x, mouse.y);

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
            const target = hitTestKind(tree, mouse.x, mouse.y, .scroll_area);
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
                .tab => {
                    if (k.state == .pressed or k.state == .repeat) {
                        if (mouse.shift_down) {
                            mouse.focused = focusPrev(tree, mouse.focused);
                        } else {
                            mouse.focused = focusNext(tree, mouse.focused);
                        }
                        syncFocusFlags(tree, mouse.focused);
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
        else => {},
    }
}

/// Update hovered state for all nodes based on current mouse position.
fn updateHover(tree: *widget.Tree, mouse: *const MouseState) void {
    const top = hitTest(tree, mouse.x, mouse.y);
    for (tree.nodes.items) |*node| {
        node.interaction.hovered = false;
    }
    if (top) |t| {
        tree.get(t).interaction.hovered = true;
    }
}

/// Find the topmost (last in tree order) interactive widget at (x, y).
/// Skips text widgets (they don't receive interaction).
fn hitTest(tree: *const widget.Tree, x: f32, y: f32) ?widget.NodeHandle {
    var result: ?widget.NodeHandle = null;
    for (tree.nodes.items, 0..) |node, i| {
        if (!isInteractive(node.kind)) continue;
        if (pointInRect(x, y, node.layout_rect)) {
            result = @enumFromInt(@as(u32, @intCast(i)));
        }
    }
    return result;
}

/// Find the topmost widget of a specific kind at (x, y).
fn hitTestKind(tree: *const widget.Tree, x: f32, y: f32, kind_tag: std.meta.Tag(widget.WidgetKind)) ?widget.NodeHandle {
    var result: ?widget.NodeHandle = null;
    for (tree.nodes.items, 0..) |node, i| {
        if (node.kind != kind_tag) continue;
        if (pointInRect(x, y, node.layout_rect)) {
            result = @enumFromInt(@as(u32, @intCast(i)));
        }
    }
    return result;
}

fn isInteractive(kind: widget.WidgetKind) bool {
    return switch (kind) {
        .button, .checkbox, .radio_button, .slider, .scroll_area, .container => true,
        .text => false,
    };
}

fn pointInRect(x: f32, y: f32, rect: draw.Rect) bool {
    return x >= rect.x and x < rect.x + rect.w and
        y >= rect.y and y < rect.y + rect.h;
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

/// Whether a widget kind can receive keyboard focus.
fn isFocusable(kind: widget.WidgetKind) bool {
    return switch (kind) {
        .button, .checkbox, .radio_button, .slider => true,
        .text, .container, .scroll_area => false,
    };
}

/// Find the next focusable widget in tree order after `current`.
/// Wraps around to the first focusable widget.
fn focusNext(tree: *const widget.Tree, current: ?widget.NodeHandle) ?widget.NodeHandle {
    const nodes = tree.nodes.items;
    if (nodes.len == 0) return null;

    const start: u32 = if (current) |c| @intFromEnum(c) + 1 else 0;

    // Search from start to end, then wrap from 0 to start
    var i: u32 = start;
    var wrapped = false;
    while (true) {
        if (i >= nodes.len) {
            if (wrapped) return current;
            i = 0;
            wrapped = true;
        }
        if (wrapped and current != null and i >= @intFromEnum(current.?) + 1) return current;
        if (isFocusable(nodes[i].kind)) return @enumFromInt(i);
        i += 1;
    }
}

/// Find the previous focusable widget in tree order before `current`.
/// Wraps around to the last focusable widget.
fn focusPrev(tree: *const widget.Tree, current: ?widget.NodeHandle) ?widget.NodeHandle {
    const nodes = tree.nodes.items;
    if (nodes.len == 0) return null;

    const len: u32 = @intCast(nodes.len);
    const start: u32 = if (current) |c| @intFromEnum(c) else len;

    // Search backwards from start-1, wrapping at 0 to end
    if (start == 0) {
        // Wrap to end
        var i: u32 = len;
        while (i > 0) {
            i -= 1;
            if (isFocusable(nodes[i].kind)) return @enumFromInt(i);
        }
        return current;
    }

    var i: u32 = start - 1;
    while (true) {
        if (isFocusable(nodes[i].kind)) return @enumFromInt(i);
        if (i == 0) break;
        i -= 1;
    }
    // Wrap: search from end backwards to start
    i = len;
    while (i > start) {
        i -= 1;
        if (isFocusable(nodes[i].kind)) return @enumFromInt(i);
    }
    return current;
}

/// Update the `.focused` flag on all nodes to match the current focus target.
fn syncFocusFlags(tree: *widget.Tree, focused: ?widget.NodeHandle) void {
    for (tree.nodes.items) |*node| {
        node.interaction.focused = false;
    }
    if (focused) |f| {
        tree.get(f).interaction.focused = true;
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
