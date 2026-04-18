const std = @import("std");
const widget = @import("widget.zig");
const event = @import("event.zig");
const draw = @import("draw.zig");

/// Transient mouse state tracked across events.
pub const MouseState = struct {
    x: f32 = 0,
    y: f32 = 0,
    left_down: bool = false,
    /// The widget that the left button went down on (for click detection).
    press_target: ?widget.NodeHandle = null,
    /// The slider currently being dragged, if any.
    drag_target: ?widget.NodeHandle = null,
};

/// Process a batch of events against the widget tree.
/// Updates interaction state (hovered, pressed) and widget state (clicked).
/// Call after doLayout so layout_rects are populated.
pub fn process(tree: *widget.Tree, events: []const event.Event, mouse: *MouseState) void {
    for (events) |ev| {
        processOne(tree, ev, mouse);
    }
}

fn processOne(tree: *widget.Tree, ev: event.Event, mouse: *MouseState) void {
    switch (ev) {
        .mouse_move => |mm| {
            mouse.x = mm.x;
            mouse.y = mm.y;
            if (mouse.drag_target) |dt| {
                updateSliderValue(tree, dt, mouse.x);
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
                        // Start slider drag
                        if (tree.getConst(t).kind == .slider) {
                            mouse.drag_target = t;
                            updateSliderValue(tree, t, mouse.x);
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
        .button, .checkbox, .slider, .scroll_area, .container => true,
        .text => false,
    };
}

fn pointInRect(x: f32, y: f32, rect: draw.Rect) bool {
    return x >= rect.x and x < rect.x + rect.w and
        y >= rect.y and y < rect.y + rect.h;
}

/// Update a slider's value based on mouse x position within its track.
fn updateSliderValue(tree: *widget.Tree, handle: widget.NodeHandle, mouse_x: f32) void {
    const node = tree.get(handle);
    const rect = node.layout_rect;
    const thumb_w: f32 = 16;
    const usable = rect.w - thumb_w;
    if (usable <= 0) return;
    const t = std.math.clamp((mouse_x - rect.x - thumb_w * 0.5) / usable, 0, 1);
    node.kind.slider.value = node.kind.slider.min + t * (node.kind.slider.max - node.kind.slider.min);
}

/// Fire a click on a widget (currently only buttons respond).
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
    process(&tree, &.{.{ .mouse_move = .{ .x = 50, .y = 20 } }}, &mouse);
    try std.testing.expect(tree.getConst(btn).interaction.hovered);
    try std.testing.expect(!tree.getConst(root).interaction.hovered);

    // Move off button but still on root
    process(&tree, &.{.{ .mouse_move = .{ .x = 500, .y = 300 } }}, &mouse);
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
    }, &mouse);

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
    }, &mouse);

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
    }, &mouse);

    // Should have started dragging
    try std.testing.expect(mouse.drag_target != null);
    const val_after_press = tree.getConst(sl).kind.slider.value;
    try std.testing.expect(val_after_press > 40 and val_after_press < 60);

    // Drag to the right end
    process(&tree, &.{
        .{ .mouse_move = .{ .x = 210, .y = 20 } },
    }, &mouse);
    try std.testing.expectApproxEqAbs(@as(f32, 100), tree.getConst(sl).kind.slider.value, 1.0);

    // Drag to the left end
    process(&tree, &.{
        .{ .mouse_move = .{ .x = 10, .y = 20 } },
    }, &mouse);
    try std.testing.expectApproxEqAbs(@as(f32, 0), tree.getConst(sl).kind.slider.value, 1.0);

    // Release — drag should stop
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 10, .y = 20 } },
    }, &mouse);
    try std.testing.expect(mouse.drag_target == null);

    // Move after release should not change value
    process(&tree, &.{
        .{ .mouse_move = .{ .x = 150, .y = 20 } },
    }, &mouse);
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
    }, &mouse);
    try std.testing.expect(tree.getConst(cb).kind.checkbox.checked);

    // Click again to uncheck
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 50, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 50, .y = 20 } },
    }, &mouse);
    try std.testing.expect(!tree.getConst(cb).kind.checkbox.checked);
}

test "scroll area responds to mouse scroll" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const scroll = try tree.addRoot(.{ .scroll_area = .{} });
    tree.get(scroll).layout_rect = .{ .x = 0, .y = 0, .w = 300, .h = 200 };

    var mouse = MouseState{ .x = 150, .y = 100 };

    process(&tree, &.{.{ .mouse_scroll = .{ .dx = 0, .dy = 30 } }}, &mouse);

    try std.testing.expectApproxEqAbs(@as(f32, 30), tree.getConst(scroll).kind.scroll_area.scroll_y, 0.01);
}
