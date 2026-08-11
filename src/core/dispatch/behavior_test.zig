const std = @import("std");
const widget = @import("../widget.zig");
const input_types = @import("goop_input");
const focus = @import("../focus.zig");
const style = @import("../style.zig");
const dispatch_core = @import("../dispatch.zig");
const control_event = @import("../control_event.zig");
const scroll_dispatch = @import("scroll.zig");

const MouseState = dispatch_core.MouseState;

/// State-oriented dispatch tests use the canonical semantic path but ignore
/// the returned occurrence batch. Tests about occurrences call
/// `processEvents` directly and assert semantic IDs and payloads.
const dispatch = struct {
    fn process(tree: *widget.Tree, events: []const input_types.Event, mouse: *MouseState, theme: style.Theme) void {
        var journal: @import("../control_event.zig").Journal = .{};
        defer journal.deinit(std.testing.allocator);
        journal.prepareBatch(std.testing.allocator, tree.count(), events.len) catch unreachable;
        dispatch_core.process(
            tree,
            events,
            mouse,
            theme,
            null,
            null,
            &journal,
        );
    }

    fn processEvents(
        tree: *widget.Tree,
        events: []const input_types.Event,
        mouse: *MouseState,
        theme: style.Theme,
        journal: *control_event.Journal,
    ) !control_event.ControlEvents {
        journal.clearRetainingCapacity();
        try journal.prepareBatch(std.testing.allocator, tree.count(), events.len);
        dispatch_core.process(
            tree,
            events,
            mouse,
            theme,
            null,
            null,
            journal,
        );
        return journal.view();
    }

    fn cancelPointerGesture(tree: *widget.Tree, mouse: *MouseState) void {
        dispatch_core.cancelPointerGesture(tree, mouse);
    }

    fn cancelPointerGestureEvents(
        tree: *widget.Tree,
        mouse: *MouseState,
        journal: *control_event.Journal,
    ) !control_event.ControlEvents {
        journal.clearRetainingCapacity();
        try journal.prepareBatch(std.testing.allocator, tree.count(), 1);
        mouse.control_journal = journal;
        defer mouse.control_journal = null;
        dispatch_core.cancelPointerGesture(tree, mouse);
        return journal.view();
    }
};

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
    dispatch.process(&tree, &.{.{ .mouse_move = .{ .x = 50, .y = 20 } }}, &mouse, style.Theme.default);
    try std.testing.expect(tree.getConst(btn).interaction.hovered);
    try std.testing.expect(!tree.getConst(root).interaction.hovered);

    // Move off button but still on root
    dispatch.process(&tree, &.{.{ .mouse_move = .{ .x = 500, .y = 300 } }}, &mouse, style.Theme.default);
    try std.testing.expect(!tree.getConst(btn).interaction.hovered);
    try std.testing.expect(tree.getConst(root).interaction.hovered);
}

test "button click emits semantic activation" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const btn = try tree.addChild(root, .{ .button = .{ .label = "Click me" } });
    try tree.setElementId(btn, .init(1));

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(btn).layout_rect = .{ .x = 10, .y = 10, .w = 100, .h = 30 };

    var mouse = MouseState{};

    // Press and release on button
    var journal: control_event.Journal = .{};
    defer journal.deinit(allocator);
    const output = try dispatch.processEvents(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 50, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 50, .y = 20 } },
    }, &mouse, style.Theme.default, &journal);

    try std.testing.expectEqual(@as(usize, 1), output.items.len);
    try std.testing.expectEqual(control_event.ElementId.init(1), output.items[0].activated.element);
    try std.testing.expect(!tree.getConst(btn).interaction.pressed);
}

test "click across a tree rebuild still fires via stable element id" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    var btn = try tree.addChild(root, .{ .button = .{ .label = "Click me" } });
    try tree.setElementId(btn, .init(7));
    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(btn).layout_rect = .{ .x = 10, .y = 10, .w = 100, .h = 30 };

    var mouse = MouseState{};

    // Press in one dispatch pass.
    dispatch.process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 50, .y = 20 } },
    }, &mouse, style.Theme.default);
    try std.testing.expect(mouse.press_target != null);

    // The whole tree is rebuilt before the release arrives (as immediate-mode
    // UIs do every frame): the same logical button gets a brand-new handle.
    try tree.remove(btn);
    btn = try tree.addChild(root, .{ .button = .{ .label = "Click me" } });
    try tree.setElementId(btn, .init(7));
    tree.get(btn).layout_rect = .{ .x = 10, .y = 10, .w = 100, .h = 30 };

    // Release: the click must still land on the rebuilt button.
    var journal: control_event.Journal = .{};
    defer journal.deinit(allocator);
    const output = try dispatch.processEvents(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 50, .y = 20 } },
    }, &mouse, style.Theme.default, &journal);

    try std.testing.expectEqual(@as(usize, 1), output.items.len);
    try std.testing.expectEqual(control_event.ElementId.init(7), output.items[0].activated.element);
}

test "click across a tree rebuild is dropped without semantic element identity" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    var btn = try tree.addChild(root, .{ .button = .{ .label = "Click me" } });
    // The press target has no semantic identity to re-resolve.
    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(btn).layout_rect = .{ .x = 10, .y = 10, .w = 100, .h = 30 };

    var mouse = MouseState{};

    dispatch.process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 50, .y = 20 } },
    }, &mouse, style.Theme.default);

    try tree.remove(btn);
    btn = try tree.addChild(root, .{ .button = .{ .label = "Click me" } });
    try tree.setElementId(btn, .init(8));
    tree.get(btn).layout_rect = .{ .x = 10, .y = 10, .w = 100, .h = 30 };

    var journal: control_event.Journal = .{};
    defer journal.deinit(allocator);
    const output = try dispatch.processEvents(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 50, .y = 20 } },
    }, &mouse, style.Theme.default, &journal);

    try std.testing.expectEqual(@as(usize, 0), output.items.len);
    try std.testing.expect(mouse.press_target == null);
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
    dispatch.process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 50, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 500, .y = 300 } },
    }, &mouse, style.Theme.default);

    try std.testing.expect(!tree.getConst(btn).interaction.pressed);
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
    dispatch.process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 110, .y = 20 } },
    }, &mouse, style.Theme.default);

    // Should have started dragging
    try std.testing.expect(mouse.drag_target != null);
    const val_after_press = tree.getConst(sl).kind.slider.value;
    try std.testing.expect(val_after_press > 40 and val_after_press < 60);

    // Drag to the right end
    dispatch.process(&tree, &.{
        .{ .mouse_move = .{ .x = 210, .y = 20 } },
    }, &mouse, style.Theme.default);
    try std.testing.expectApproxEqAbs(@as(f32, 100), tree.getConst(sl).kind.slider.value, 1.0);

    // Drag to the left end
    dispatch.process(&tree, &.{
        .{ .mouse_move = .{ .x = 10, .y = 20 } },
    }, &mouse, style.Theme.default);
    try std.testing.expectApproxEqAbs(@as(f32, 0), tree.getConst(sl).kind.slider.value, 1.0);

    // Release — drag should stop
    dispatch.process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 10, .y = 20 } },
    }, &mouse, style.Theme.default);
    try std.testing.expect(mouse.drag_target == null);

    // Move after release should not change value
    dispatch.process(&tree, &.{
        .{ .mouse_move = .{ .x = 150, .y = 20 } },
    }, &mouse, style.Theme.default);
    try std.testing.expectApproxEqAbs(@as(f32, 0), tree.getConst(sl).kind.slider.value, 1.0);
}

test "drag value drag updates value" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const drag_value = try tree.addChild(root, .{ .drag_value = .{
        .value = 10,
        .min = 0,
        .max = 100,
        .speed = 0.5,
    } });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 400, .h = 300 };
    tree.get(drag_value).layout_rect = .{ .x = 10, .y = 10, .w = 120, .h = 28 };

    var mouse = MouseState{};
    dispatch.process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 20, .y = 20 } },
    }, &mouse, style.Theme.default);

    try std.testing.expect(mouse.drag_target == null);
    dispatch.process(&tree, &.{
        .{ .mouse_move = .{ .x = 40, .y = 20 } },
    }, &mouse, style.Theme.default);

    try std.testing.expect(mouse.drag_target != null);
    try std.testing.expectApproxEqAbs(@as(f32, 20), tree.getConst(drag_value).kind.drag_value.value, 0.01);
}

test "drag value accepts typed edits" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const drag_value = try tree.addChild(root, .{ .drag_value = .{
        .value = 10,
        .min = 0,
        .max = 100,
        .precision = 0,
    } });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 400, .h = 300 };
    tree.get(drag_value).layout_rect = .{ .x = 10, .y = 10, .w = 120, .h = 28 };

    var mouse = MouseState{};
    dispatch.process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 20, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 20, .y = 20 } },
    }, &mouse, style.Theme.default);

    try std.testing.expect(tree.getConst(drag_value).kind.drag_value.editing);
    try std.testing.expect(mouse.focused.?.eql(drag_value));

    dispatch.process(&tree, &.{
        .{ .text = .{ .codepoint = '4' } },
        .{ .text = .{ .codepoint = '2' } },
        .{ .key = .{ .scancode = 28, .keycode = .enter, .state = .pressed } },
    }, &mouse, style.Theme.default);

    try std.testing.expect(!tree.getConst(drag_value).kind.drag_value.editing);
    try std.testing.expectApproxEqAbs(@as(f32, 42), tree.getConst(drag_value).kind.drag_value.value, 0.01);
}

test "focused drag value begins editing on numeric text input" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const drag_value = try tree.addChild(root, .{ .drag_value = .{
        .value = 10,
        .min = 0,
        .max = 100,
        .precision = 0,
    } });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 400, .h = 300 };
    tree.get(drag_value).layout_rect = .{ .x = 10, .y = 10, .w = 120, .h = 28 };

    var mouse = MouseState{ .focused = drag_value };
    focus.syncFocusFlags(&tree, mouse.focused);

    dispatch.process(&tree, &.{
        .{ .text = .{ .codepoint = '7' } },
        .{ .key = .{ .scancode = 28, .keycode = .enter, .state = .pressed } },
    }, &mouse, style.Theme.default);

    try std.testing.expect(!tree.getConst(drag_value).kind.drag_value.editing);
    try std.testing.expectApproxEqAbs(@as(f32, 7), tree.getConst(drag_value).kind.drag_value.value, 0.01);
}

test "spinbox click steps value" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const spinbox = try tree.addChild(root, .{ .spinbox = .{
        .value = 5,
        .min = 0,
        .max = 10,
        .step = 2,
    } });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 400, .h = 300 };
    tree.get(spinbox).layout_rect = .{ .x = 10, .y = 10, .w = 120, .h = 28 };

    var mouse = MouseState{};
    dispatch.process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 120, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 120, .y = 20 } },
    }, &mouse, style.Theme.default);
    try std.testing.expectApproxEqAbs(@as(f32, 7), tree.getConst(spinbox).kind.spinbox.value, 0.01);
    dispatch.process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 20, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 20, .y = 20 } },
    }, &mouse, style.Theme.default);
    try std.testing.expectApproxEqAbs(@as(f32, 5), tree.getConst(spinbox).kind.spinbox.value, 0.01);
}

test "spinbox accepts typed edits in the value field" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const spinbox = try tree.addChild(root, .{ .spinbox = .{
        .value = 5,
        .min = 0,
        .max = 10,
        .precision = 0,
    } });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 400, .h = 300 };
    tree.get(spinbox).layout_rect = .{ .x = 10, .y = 10, .w = 120, .h = 28 };

    var mouse = MouseState{};
    dispatch.process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 60, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 60, .y = 20 } },
    }, &mouse, style.Theme.default);

    try std.testing.expect(tree.getConst(spinbox).kind.spinbox.editing);
    try std.testing.expect(mouse.focused.?.eql(spinbox));

    dispatch.process(&tree, &.{
        .{ .text = .{ .codepoint = '9' } },
        .{ .key = .{ .scancode = 28, .keycode = .enter, .state = .pressed } },
    }, &mouse, style.Theme.default);

    try std.testing.expect(!tree.getConst(spinbox).kind.spinbox.editing);
    try std.testing.expectApproxEqAbs(@as(f32, 9), tree.getConst(spinbox).kind.spinbox.value, 0.01);
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
    dispatch.process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 50, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 50, .y = 20 } },
    }, &mouse, style.Theme.default);
    try std.testing.expect(tree.getConst(cb).kind.checkbox.checked);

    // Click again to uncheck
    dispatch.process(&tree, &.{
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
    dispatch.process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 50, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 50, .y = 20 } },
    }, &mouse, style.Theme.default);
    try std.testing.expect(tree.getConst(rb1).kind.radio_button.selected);
    try std.testing.expect(!tree.getConst(rb2).kind.radio_button.selected);

    // Click rb2 — should deselect rb1
    dispatch.process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 50, .y = 50 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 50, .y = 50 } },
    }, &mouse, style.Theme.default);
    try std.testing.expect(!tree.getConst(rb1).kind.radio_button.selected);
    try std.testing.expect(tree.getConst(rb2).kind.radio_button.selected);

    // rb3 (different group) should be unaffected
    try std.testing.expect(!tree.getConst(rb3).kind.radio_button.selected);

    // Click rb3 — group 1 should be unaffected
    dispatch.process(&tree, &.{
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

    dispatch.process(&tree, &.{.{ .mouse_scroll = .{ .dx = 0, .dy = 30 } }}, &mouse, style.Theme.default);

    try std.testing.expectApproxEqAbs(@as(f32, 30), tree.getConst(scroll).kind.scroll_area.scroll_y, 0.01);
}

test "shift mouse wheel scrolls horizontally" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const scroll = try tree.addRoot(.{ .scroll_area = .{} });
    const child = try tree.addChild(scroll, .{ .text = .{ .content = "wide content" } });
    tree.get(scroll).layout_rect = .{ .x = 0, .y = 0, .w = 300, .h = 200 };
    tree.get(child).layout_rect = .{ .x = 0, .y = 0, .w = 600, .h = 200 };

    var mouse = MouseState{ .x = 150, .y = 100, .shift_down = true };

    dispatch.process(&tree, &.{.{ .mouse_scroll = .{ .dx = 0, .dy = 45 } }}, &mouse, style.Theme.default);

    try std.testing.expectApproxEqAbs(@as(f32, 45), tree.getConst(scroll).kind.scroll_area.scroll_x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0), tree.getConst(scroll).kind.scroll_area.scroll_y, 0.01);
}

test "disabled horizontal scroll ignores shift mouse wheel" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const scroll = try tree.addRoot(.{ .scroll_area = .{ .disable_horizontal_scroll = true } });
    const child = try tree.addChild(scroll, .{ .text = .{ .content = "wide content" } });
    tree.get(scroll).layout_rect = .{ .x = 0, .y = 0, .w = 300, .h = 200 };
    tree.get(child).layout_rect = .{ .x = 0, .y = 0, .w = 600, .h = 200 };

    var mouse = MouseState{ .x = 150, .y = 100, .shift_down = true };

    dispatch.process(&tree, &.{.{ .mouse_scroll = .{ .dx = 0, .dy = 45 } }}, &mouse, style.Theme.default);

    try std.testing.expectApproxEqAbs(@as(f32, 0), tree.getConst(scroll).kind.scroll_area.scroll_x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0), tree.getConst(scroll).kind.scroll_area.scroll_y, 0.01);
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
    dispatch.process(&tree, &.{.{ .mouse_scroll = .{ .dx = 0, .dy = 9999 } }}, &mouse, style.Theme.default);
    try std.testing.expectApproxEqAbs(@as(f32, 200), tree.getConst(scroll).kind.scroll_area.scroll_y, 0.01);

    // Scroll negative — should clamp to 0
    dispatch.process(&tree, &.{.{ .mouse_scroll = .{ .dx = 0, .dy = -9999 } }}, &mouse, style.Theme.default);
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
    dispatch.process(&tree, &.{.{ .mouse_scroll = .{ .dx = 50, .dy = 50 } }}, &mouse, style.Theme.default);
    try std.testing.expectApproxEqAbs(@as(f32, 0), tree.getConst(scroll).kind.scroll_area.scroll_x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0), tree.getConst(scroll).kind.scroll_area.scroll_y, 0.01);
}

test "scroll clamping accounts for offset child rects" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const scroll = try tree.addRoot(.{ .scroll_area = .{ .scroll_y = 150 } });
    const child = try tree.addChild(scroll, .{ .text = .{ .content = "content" } });
    tree.get(scroll).layout_rect = .{ .x = 0, .y = 0, .w = 300, .h = 200 };
    tree.get(child).layout_rect = .{ .x = 0, .y = -150, .w = 300, .h = 500 };

    scroll_dispatch.clampScroll(&tree, scroll);

    try std.testing.expectApproxEqAbs(@as(f32, 150), tree.getConst(scroll).kind.scroll_area.scroll_y, 0.01);
}

test "scrollbar track click jumps scroll position" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const scroll = try tree.addRoot(.{ .scroll_area = .{} });
    const child = try tree.addChild(scroll, .{ .spacer = .{ .height = 300 } });
    tree.get(scroll).layout_rect = .{ .x = 0, .y = 0, .w = 120, .h = 80 };
    tree.get(child).layout_rect = .{ .x = 0, .y = 0, .w = 120, .h = 300 };

    const theme = style.Theme.default;
    const metrics = scroll_dispatch.verticalScrollbarMetrics(&tree, scroll, theme).?;
    var mouse = MouseState{};

    dispatch.process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = metrics.track.x + metrics.track.w * 0.5, .y = metrics.track.y + metrics.track.h - 4 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = metrics.track.x + metrics.track.w * 0.5, .y = metrics.track.y + metrics.track.h - 4 } },
    }, &mouse, theme);

    try std.testing.expect(tree.getConst(scroll).kind.scroll_area.scroll_y > 0);
}

test "scrollbar thumb drag updates scroll position" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const scroll = try tree.addRoot(.{ .scroll_area = .{} });
    const child = try tree.addChild(scroll, .{ .spacer = .{ .height = 300 } });
    tree.get(scroll).layout_rect = .{ .x = 0, .y = 0, .w = 120, .h = 80 };
    tree.get(child).layout_rect = .{ .x = 0, .y = 0, .w = 120, .h = 300 };

    const theme = style.Theme.default;
    const metrics = scroll_dispatch.verticalScrollbarMetrics(&tree, scroll, theme).?;
    const thumb_center_x = metrics.thumb.x + metrics.thumb.w * 0.5;
    const thumb_center_y = metrics.thumb.y + metrics.thumb.h * 0.5;
    var mouse = MouseState{};

    dispatch.process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = thumb_center_x, .y = thumb_center_y } },
        .{ .mouse_move = .{ .x = thumb_center_x, .y = thumb_center_y + 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = thumb_center_x, .y = thumb_center_y + 20 } },
    }, &mouse, theme);

    try std.testing.expect(tree.getConst(scroll).kind.scroll_area.scroll_y > 0);
}

test "scrollbar hover and active state follow its own hit geometry" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const scroll = try tree.addRoot(.{ .scroll_area = .{} });
    const child = try tree.addChild(scroll, .{ .spacer = .{ .height = 300 } });
    tree.get(scroll).layout_rect = .{ .x = 0, .y = 0, .w = 120, .h = 80 };
    tree.get(child).layout_rect = .{ .x = 0, .y = 0, .w = 120, .h = 300 };

    const theme = style.Theme.default;
    const metrics = scroll_dispatch.verticalScrollbarMetrics(&tree, scroll, theme).?;
    const x = metrics.thumb.x + metrics.thumb.w * 0.5;
    const y = metrics.thumb.y + metrics.thumb.h * 0.5;
    var mouse = MouseState{};

    dispatch.process(&tree, &.{.{ .mouse_move = .{ .x = x, .y = y } }}, &mouse, theme);
    try std.testing.expectEqual(
        widget.WidgetKind.ScrollArea.ScrollbarAxis.vertical,
        tree.getConst(scroll).kind.scroll_area.internal.hovered_scrollbar.?,
    );

    dispatch.process(&tree, &.{.{ .mouse_button = .{ .button = .left, .state = .pressed, .x = x, .y = y } }}, &mouse, theme);
    try std.testing.expectEqual(
        widget.WidgetKind.ScrollArea.ScrollbarAxis.vertical,
        tree.getConst(scroll).kind.scroll_area.internal.active_scrollbar.?,
    );

    dispatch.process(&tree, &.{.{ .mouse_button = .{ .button = .left, .state = .released, .x = x, .y = y } }}, &mouse, theme);
    try std.testing.expect(tree.getConst(scroll).kind.scroll_area.internal.active_scrollbar == null);
}

test "horizontal scrollbar track click jumps scroll position" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const scroll = try tree.addRoot(.{ .scroll_area = .{} });
    const child = try tree.addChild(scroll, .{ .spacer = .{ .width = 300, .height = 80 } });
    tree.get(scroll).layout_rect = .{ .x = 0, .y = 0, .w = 120, .h = 80 };
    tree.get(child).layout_rect = .{ .x = 0, .y = 0, .w = 300, .h = 80 };

    const theme = style.Theme.default;
    const metrics = scroll_dispatch.horizontalScrollbarMetrics(&tree, scroll, theme).?;
    var mouse = MouseState{};

    dispatch.process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = metrics.track.x + metrics.track.w - 4, .y = metrics.track.y + metrics.track.h * 0.5 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = metrics.track.x + metrics.track.w - 4, .y = metrics.track.y + metrics.track.h * 0.5 } },
    }, &mouse, theme);

    try std.testing.expect(tree.getConst(scroll).kind.scroll_area.scroll_x > 0);
}

test "horizontal scrollbar thumb drag updates scroll position" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const scroll = try tree.addRoot(.{ .scroll_area = .{} });
    const child = try tree.addChild(scroll, .{ .spacer = .{ .width = 300, .height = 80 } });
    tree.get(scroll).layout_rect = .{ .x = 0, .y = 0, .w = 120, .h = 80 };
    tree.get(child).layout_rect = .{ .x = 0, .y = 0, .w = 300, .h = 80 };

    const theme = style.Theme.default;
    const metrics = scroll_dispatch.horizontalScrollbarMetrics(&tree, scroll, theme).?;
    const thumb_center_x = metrics.thumb.x + metrics.thumb.w * 0.5;
    const thumb_center_y = metrics.thumb.y + metrics.thumb.h * 0.5;
    var mouse = MouseState{};

    dispatch.process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = thumb_center_x, .y = thumb_center_y } },
        .{ .mouse_move = .{ .x = thumb_center_x + 20, .y = thumb_center_y } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = thumb_center_x + 20, .y = thumb_center_y } },
    }, &mouse, theme);

    try std.testing.expect(tree.getConst(scroll).kind.scroll_area.scroll_x > 0);
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
    const tab_press = input_types.Event{ .key = .{ .scancode = 15, .keycode = .tab, .state = .pressed } };

    // First tab: focus button (first focusable)
    dispatch.process(&tree, &.{tab_press}, &mouse, style.Theme.default);
    try std.testing.expect(mouse.focused.?.eql(btn));
    try std.testing.expect(tree.getConst(btn).interaction.focused);

    // Second tab: focus checkbox (skips text)
    dispatch.process(&tree, &.{tab_press}, &mouse, style.Theme.default);
    try std.testing.expect(mouse.focused.?.eql(cb));
    try std.testing.expect(!tree.getConst(btn).interaction.focused);
    try std.testing.expect(tree.getConst(cb).interaction.focused);

    // Third tab: focus slider
    dispatch.process(&tree, &.{tab_press}, &mouse, style.Theme.default);
    try std.testing.expect(mouse.focused.?.eql(sl));

    // Fourth tab: wraps to button
    dispatch.process(&tree, &.{tab_press}, &mouse, style.Theme.default);
    try std.testing.expect(mouse.focused.?.eql(btn));
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
    const shift_down = input_types.Event{ .key = .{ .scancode = 42, .keycode = .left_shift, .state = .pressed } };
    const tab_press = input_types.Event{ .key = .{ .scancode = 15, .keycode = .tab, .state = .pressed } };
    const shift_up = input_types.Event{ .key = .{ .scancode = 42, .keycode = .left_shift, .state = .released } };

    // Shift+Tab from no focus: should go to last focusable (checkbox)
    dispatch.process(&tree, &.{ shift_down, tab_press, shift_up }, &mouse, style.Theme.default);
    try std.testing.expect(mouse.focused.?.eql(cb));

    // Shift+Tab again: should go to button
    dispatch.process(&tree, &.{ shift_down, tab_press, shift_up }, &mouse, style.Theme.default);
    try std.testing.expect(mouse.focused.?.eql(btn));
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
    dispatch.process(&tree, &.{
        .{ .key = .{ .scancode = 15, .keycode = .tab, .state = .pressed } },
        .{ .key = .{ .scancode = 28, .keycode = .enter, .state = .pressed } },
    }, &mouse, style.Theme.default);

    // Tab to checkbox, press Space to toggle
    dispatch.process(&tree, &.{
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

    dispatch.process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 50, .y = 20 } },
    }, &mouse, style.Theme.default);

    try std.testing.expect(mouse.focused.?.eql(btn));
    try std.testing.expect(tree.getConst(btn).interaction.focused);
}

test "click on non-focusable surface clears focus" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const btn = try tree.addChild(root, .{ .button = .{ .label = "A" } });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(btn).layout_rect = .{ .x = 10, .y = 10, .w = 100, .h = 30 };

    var mouse = MouseState{};

    dispatch.process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 50, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 50, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 250, .y = 200 } },
    }, &mouse, style.Theme.default);

    try std.testing.expect(mouse.focused == null);
    try std.testing.expect(!tree.getConst(btn).interaction.focused);
}

test "window blur clears widget focus" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const btn = try tree.addChild(root, .{ .button = .{ .label = "A" } });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(btn).layout_rect = .{ .x = 10, .y = 10, .w = 100, .h = 30 };

    var mouse = MouseState{};

    dispatch.process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 50, .y = 20 } },
        .{ .focus = .{ .focused = false } },
    }, &mouse, style.Theme.default);

    try std.testing.expect(mouse.focused == null);
    try std.testing.expect(!tree.getConst(btn).interaction.focused);
}

test "tab item click selects sibling tab" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const tabs = try tree.addChild(root, .{ .tab_bar = .{} });
    const scene = try tree.addChild(tabs, .{ .tab_item = .{
        .label = "Scene",
        .selected = true,
    } });
    const render = try tree.addChild(tabs, .{ .tab_item = .{
        .label = "Render",
    } });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 400, .h = 300 };
    tree.get(tabs).layout_rect = .{ .x = 10, .y = 10, .w = 220, .h = 80 };
    tree.get(scene).layout_rect = .{ .x = 10, .y = 10, .w = 70, .h = 28 };
    tree.get(render).layout_rect = .{ .x = 84, .y = 10, .w = 80, .h = 28 };

    var mouse = MouseState{};
    dispatch.process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 100, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 100, .y = 20 } },
    }, &mouse, style.Theme.default);

    try std.testing.expect(!tree.getConst(scene).kind.tab_item.selected);
    try std.testing.expect(tree.getConst(render).kind.tab_item.selected);
}

test "selectable rows update sibling selection and list box change state" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const list_box = try tree.addChild(root, .{ .list_box = .{} });
    const first = try tree.addChild(list_box, .{ .selectable = .{
        .label = "Scene",
        .selected = true,
    } });
    const second = try tree.addChild(list_box, .{ .selectable = .{
        .label = "Camera",
    } });
    const third = try tree.addChild(list_box, .{ .selectable = .{
        .label = "Light",
    } });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 400, .h = 300 };
    tree.get(list_box).layout_rect = .{ .x = 10, .y = 10, .w = 220, .h = 90 };
    tree.get(first).layout_rect = .{ .x = 10, .y = 10, .w = 220, .h = 26 };
    tree.get(second).layout_rect = .{ .x = 10, .y = 36, .w = 220, .h = 26 };
    tree.get(third).layout_rect = .{ .x = 10, .y = 62, .w = 220, .h = 26 };

    var mouse = MouseState{};
    dispatch.process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 40, .y = 46 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 40, .y = 46 } },
    }, &mouse, style.Theme.default);

    try std.testing.expect(!tree.getConst(first).kind.selectable.selected);
    try std.testing.expect(tree.getConst(second).kind.selectable.selected);
    try std.testing.expect(mouse.focused.?.eql(second));

    dispatch.process(&tree, &.{.{ .key = .{ .scancode = 108, .keycode = .down, .state = .pressed } }}, &mouse, style.Theme.default);

    try std.testing.expect(!tree.getConst(second).kind.selectable.selected);
    try std.testing.expect(tree.getConst(third).kind.selectable.selected);
    try std.testing.expect(mouse.focused.?.eql(third));
}

test "multi-select list box supports ctrl-toggle and additive shift range" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const list_box = try tree.addChild(root, .{ .list_box = .{ .selection_mode = .multiple } });
    const first = try tree.addChild(list_box, .{ .selectable = .{
        .label = "Scene",
        .selected = true,
    } });
    const second = try tree.addChild(list_box, .{ .selectable = .{ .label = "Camera" } });
    const third = try tree.addChild(list_box, .{ .selectable = .{ .label = "Light" } });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 400, .h = 300 };
    tree.get(list_box).layout_rect = .{ .x = 10, .y = 10, .w = 220, .h = 90 };
    tree.get(first).layout_rect = .{ .x = 10, .y = 10, .w = 220, .h = 26 };
    tree.get(second).layout_rect = .{ .x = 10, .y = 36, .w = 220, .h = 26 };
    tree.get(third).layout_rect = .{ .x = 10, .y = 62, .w = 220, .h = 26 };

    var mouse = MouseState{};
    dispatch.process(&tree, &.{
        .{ .key = .{ .scancode = 29, .keycode = .left_ctrl, .state = .pressed } },
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 40, .y = 46 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 40, .y = 46 } },
        .{ .key = .{ .scancode = 29, .keycode = .left_ctrl, .state = .released } },
    }, &mouse, style.Theme.default);

    try std.testing.expect(tree.getConst(first).kind.selectable.selected);
    try std.testing.expect(tree.getConst(second).kind.selectable.selected);
    try std.testing.expect(!tree.getConst(third).kind.selectable.selected);
    try std.testing.expectEqual(@as(?u16, 1), tree.getConst(list_box).kind.list_box.internal.anchor_index);

    dispatch.process(&tree, &.{
        .{ .key = .{ .scancode = 29, .keycode = .left_ctrl, .state = .pressed } },
        .{ .key = .{ .scancode = 42, .keycode = .left_shift, .state = .pressed } },
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 40, .y = 72 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 40, .y = 72 } },
        .{ .key = .{ .scancode = 29, .keycode = .left_ctrl, .state = .released } },
        .{ .key = .{ .scancode = 42, .keycode = .left_shift, .state = .released } },
    }, &mouse, style.Theme.default);

    try std.testing.expect(tree.getConst(first).kind.selectable.selected);
    try std.testing.expect(tree.getConst(second).kind.selectable.selected);
    try std.testing.expect(tree.getConst(third).kind.selectable.selected);
}

test "grid selector marquee stays owned by its container across child hits" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const grid = try tree.addChild(root, .{ .grid_selector = .{
        .selection_mode = .multiple,
    } });
    const first = try tree.addChild(grid, .{ .grid_item = .{ .label = "Brick" } });
    const second = try tree.addChild(grid, .{ .grid_item = .{ .label = "Metal" } });
    const third = try tree.addChild(grid, .{ .grid_item = .{ .label = "Leaves" } });
    const fourth = try tree.addChild(grid, .{ .grid_item = .{ .label = "Icons" } });
    try tree.setElementId(grid, .init(91));
    try tree.setElementId(first, .init(92));
    try tree.setElementId(second, .init(93));
    try tree.setElementId(third, .init(94));
    try tree.setElementId(fourth, .init(95));

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 400, .h = 300 };
    tree.get(grid).layout_rect = .{ .x = 10, .y = 10, .w = 220, .h = 130 };
    tree.get(grid).kind.grid_selector.computed_columns = 2;
    tree.get(first).layout_rect = .{ .x = 18, .y = 18, .w = 80, .h = 44 };
    tree.get(second).layout_rect = .{ .x = 106, .y = 18, .w = 80, .h = 44 };
    tree.get(third).layout_rect = .{ .x = 18, .y = 74, .w = 80, .h = 44 };
    tree.get(fourth).layout_rect = .{ .x = 106, .y = 74, .w = 80, .h = 44 };

    var mouse = MouseState{};
    var journal: control_event.Journal = .{};
    defer journal.deinit(allocator);
    _ = try dispatch.processEvents(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 14, .y = 14 } },
    }, &mouse, style.Theme.default, &journal);

    const first_move = try dispatch.processEvents(&tree, &.{
        .{ .mouse_move = .{ .x = 94, .y = 40 } },
    }, &mouse, style.Theme.default, &journal);
    try std.testing.expectEqual(@as(usize, 0), first_move.items.len);
    try std.testing.expect(mouse.drag_target.?.eql(grid));
    try std.testing.expect(tree.getConst(grid).kind.grid_selector.internal.marquee_active);
    try std.testing.expect(tree.getConst(first).kind.grid_item.selected);
    try std.testing.expect(!tree.getConst(second).kind.grid_item.selected);

    const second_move = try dispatch.processEvents(&tree, &.{
        .{ .mouse_move = .{ .x = 170, .y = 40 } },
    }, &mouse, style.Theme.default, &journal);
    try std.testing.expectEqual(@as(usize, 0), second_move.items.len);
    try std.testing.expect(mouse.drag_target.?.eql(grid));

    try std.testing.expect(tree.getConst(first).kind.grid_item.selected);
    try std.testing.expect(tree.getConst(second).kind.grid_item.selected);
    try std.testing.expect(!tree.getConst(third).kind.grid_item.selected);
    try std.testing.expect(!tree.getConst(fourth).kind.grid_item.selected);

    const release = try dispatch.processEvents(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 170, .y = 40 } },
    }, &mouse, style.Theme.default, &journal);
    try std.testing.expectEqual(@as(usize, 1), release.items.len);
    try std.testing.expectEqualSlices(
        control_event.ElementId,
        &.{ control_event.ElementId.init(92), control_event.ElementId.init(93) },
        release.selection(release.items[0].selection_changed),
    );
    try std.testing.expect(mouse.drag_target == null);
    try std.testing.expect(!tree.getConst(grid).kind.grid_selector.internal.marquee_active);
}

test "grid item drag reports drop target" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const grid = try tree.addChild(root, .{ .grid_selector = .{
        .selection_mode = .multiple,
    } });
    const first = try tree.addChild(grid, .{ .grid_item = .{ .label = "Brick" } });
    const second = try tree.addChild(grid, .{ .grid_item = .{ .label = "Metal" } });
    try tree.setElementId(first, .init(101));
    try tree.setElementId(second, .init(102));

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 400, .h = 300 };
    tree.get(grid).layout_rect = .{ .x = 10, .y = 10, .w = 220, .h = 130 };
    tree.get(grid).kind.grid_selector.computed_columns = 2;
    tree.get(first).layout_rect = .{ .x = 18, .y = 18, .w = 80, .h = 44 };
    tree.get(second).layout_rect = .{ .x = 106, .y = 18, .w = 80, .h = 44 };

    var mouse = MouseState{};
    dispatch.process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 58, .y = 40 } },
    }, &mouse, style.Theme.default);

    try std.testing.expect(mouse.drag_target == null);

    dispatch.process(&tree, &.{
        .{ .mouse_move = .{ .x = 146, .y = 40 } },
    }, &mouse, style.Theme.default);

    try std.testing.expect(mouse.drag_target != null);
    try std.testing.expect(tree.getConst(first).kind.grid_item.internal.drag.active);
    try std.testing.expect(tree.getConst(second).kind.grid_item.internal.drop_preview);

    var journal: control_event.Journal = .{};
    defer journal.deinit(allocator);
    const output = try dispatch.processEvents(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 146, .y = 40 } },
    }, &mouse, style.Theme.default, &journal);

    try std.testing.expect(!tree.getConst(first).kind.grid_item.internal.drag.active);
    try std.testing.expect(!tree.getConst(second).kind.grid_item.internal.drop_preview);
    const drop = output.items[output.items.len - 1].drop;
    try std.testing.expectEqual(control_event.ElementId.init(101), drop.source);
    try std.testing.expectEqual(control_event.ElementId.init(102), drop.target);
    try std.testing.expectEqual(control_event.Drop.Position.item, drop.position);
}

test "cancel pointer gesture clears active grid drag" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const grid = try tree.addChild(root, .{ .grid_selector = .{
        .selection_mode = .multiple,
    } });
    const first = try tree.addChild(grid, .{ .grid_item = .{ .label = "Brick" } });
    const second = try tree.addChild(grid, .{ .grid_item = .{ .label = "Metal" } });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 400, .h = 300 };
    tree.get(grid).layout_rect = .{ .x = 10, .y = 10, .w = 220, .h = 130 };
    tree.get(grid).kind.grid_selector.computed_columns = 2;
    tree.get(first).layout_rect = .{ .x = 18, .y = 18, .w = 80, .h = 44 };
    tree.get(second).layout_rect = .{ .x = 106, .y = 18, .w = 80, .h = 44 };

    var mouse = MouseState{};
    dispatch.process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 58, .y = 40 } },
        .{ .mouse_move = .{ .x = 146, .y = 40 } },
    }, &mouse, style.Theme.default);

    try std.testing.expect(mouse.left_down);
    try std.testing.expect(mouse.drag_target != null);
    try std.testing.expect(mouse.grid_drop_preview != null);
    try std.testing.expect(tree.getConst(first).kind.grid_item.internal.drag.active);
    try std.testing.expect(tree.getConst(second).kind.grid_item.internal.drop_preview);

    dispatch.cancelPointerGesture(&tree, &mouse);

    try std.testing.expect(!mouse.left_down);
    try std.testing.expect(mouse.press_target == null);
    try std.testing.expect(mouse.drag_target == null);
    try std.testing.expect(mouse.grid_drop_preview == null);
    try std.testing.expect(!tree.getConst(first).kind.grid_item.internal.drag.active);
    try std.testing.expect(!tree.getConst(second).kind.grid_item.internal.drop_preview);
}

test "generic drop target receives item drag" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const grid = try tree.addChild(root, .{ .grid_selector = .{
        .selection_mode = .multiple,
    } });
    const first = try tree.addChild(grid, .{ .grid_item = .{ .label = "Brick" } });
    const drop_button = try tree.addChild(root, .{ .button = .{ .label = "Move Here" } });
    try tree.setElementId(first, .init(111));
    try tree.setElementId(drop_button, .init(112));

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 400, .h = 300 };
    tree.get(grid).layout_rect = .{ .x = 10, .y = 10, .w = 220, .h = 130 };
    tree.get(grid).kind.grid_selector.computed_columns = 1;
    tree.get(first).layout_rect = .{ .x = 18, .y = 18, .w = 80, .h = 44 };
    tree.get(drop_button).layout_rect = .{ .x = 18, .y = 170, .w = 120, .h = 32 };
    tree.get(drop_button).interaction.accepts_drop = true;

    var mouse = MouseState{};
    dispatch.process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 58, .y = 40 } },
        .{ .mouse_move = .{ .x = 60, .y = 186 } },
    }, &mouse, style.Theme.default);

    try std.testing.expect(tree.getConst(drop_button).interaction.drop_hovered);
    try std.testing.expect(mouse.widget_drop_preview != null);

    var journal: control_event.Journal = .{};
    defer journal.deinit(allocator);
    const output = try dispatch.processEvents(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 60, .y = 186 } },
    }, &mouse, style.Theme.default, &journal);

    try std.testing.expect(!tree.getConst(drop_button).interaction.drop_hovered);
    const drop = output.items[output.items.len - 1].drop;
    try std.testing.expectEqual(control_event.ElementId.init(111), drop.source);
    try std.testing.expectEqual(control_event.ElementId.init(112), drop.target);
    try std.testing.expectEqual(control_event.Drop.Position{ .point = .{ .x = 60, .y = 186 } }, drop.position);
}

test "table rows support multi-select and additive shift range" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const table = try tree.addChild(root, .{ .table = .{ .selection_mode = .multiple } });
    const header = try tree.addChild(table, .{ .table_row = .{ .header = true } });
    _ = try tree.addChild(header, .{ .table_cell = .{} });
    const first = try tree.addChild(table, .{ .table_row = .{ .selected = true } });
    _ = try tree.addChild(first, .{ .table_cell = .{} });
    const second = try tree.addChild(table, .{ .table_row = .{} });
    _ = try tree.addChild(second, .{ .table_cell = .{} });
    const third = try tree.addChild(table, .{ .table_row = .{} });
    _ = try tree.addChild(third, .{ .table_cell = .{} });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 400, .h = 300 };
    tree.get(table).layout_rect = .{ .x = 10, .y = 10, .w = 220, .h = 116 };
    tree.get(header).layout_rect = .{ .x = 10, .y = 10, .w = 220, .h = 28 };
    tree.get(first).layout_rect = .{ .x = 10, .y = 38, .w = 220, .h = 28 };
    tree.get(second).layout_rect = .{ .x = 10, .y = 66, .w = 220, .h = 28 };
    tree.get(third).layout_rect = .{ .x = 10, .y = 94, .w = 220, .h = 28 };

    var mouse = MouseState{};
    dispatch.process(&tree, &.{
        .{ .key = .{ .scancode = 29, .keycode = .left_ctrl, .state = .pressed } },
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 40, .y = 80 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 40, .y = 80 } },
        .{ .key = .{ .scancode = 29, .keycode = .left_ctrl, .state = .released } },
    }, &mouse, style.Theme.default);

    try std.testing.expect(tree.getConst(first).kind.table_row.selected);
    try std.testing.expect(tree.getConst(second).kind.table_row.selected);
    try std.testing.expect(!tree.getConst(third).kind.table_row.selected);
    try std.testing.expectEqual(@as(?u16, 1), tree.getConst(table).kind.table.internal.anchor_row);

    dispatch.process(&tree, &.{
        .{ .key = .{ .scancode = 29, .keycode = .left_ctrl, .state = .pressed } },
        .{ .key = .{ .scancode = 42, .keycode = .left_shift, .state = .pressed } },
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 40, .y = 108 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 40, .y = 108 } },
        .{ .key = .{ .scancode = 29, .keycode = .left_ctrl, .state = .released } },
        .{ .key = .{ .scancode = 42, .keycode = .left_shift, .state = .released } },
    }, &mouse, style.Theme.default);

    try std.testing.expect(tree.getConst(first).kind.table_row.selected);
    try std.testing.expect(tree.getConst(second).kind.table_row.selected);
    try std.testing.expect(tree.getConst(third).kind.table_row.selected);
}

test "table row keyboard navigation moves focus and extends selection" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const table = try tree.addChild(root, .{ .table = .{ .selection_mode = .multiple } });
    const header = try tree.addChild(table, .{ .table_row = .{ .header = true } });
    _ = try tree.addChild(header, .{ .table_cell = .{} });
    const first = try tree.addChild(table, .{ .table_row = .{ .selected = true } });
    _ = try tree.addChild(first, .{ .table_cell = .{} });
    const second = try tree.addChild(table, .{ .table_row = .{} });
    _ = try tree.addChild(second, .{ .table_cell = .{} });
    const third = try tree.addChild(table, .{ .table_row = .{} });
    _ = try tree.addChild(third, .{ .table_cell = .{} });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 400, .h = 300 };
    tree.get(table).layout_rect = .{ .x = 10, .y = 10, .w = 220, .h = 116 };
    tree.get(header).layout_rect = .{ .x = 10, .y = 10, .w = 220, .h = 28 };
    tree.get(first).layout_rect = .{ .x = 10, .y = 38, .w = 220, .h = 28 };
    tree.get(second).layout_rect = .{ .x = 10, .y = 66, .w = 220, .h = 28 };
    tree.get(third).layout_rect = .{ .x = 10, .y = 94, .w = 220, .h = 28 };

    var mouse = MouseState{ .focused = first };
    focus.syncFocusFlags(&tree, mouse.focused);
    tree.get(table).kind.table.internal.anchor_row = 0;

    dispatch.process(&tree, &.{.{ .key = .{ .scancode = 108, .keycode = .down, .state = .pressed } }}, &mouse, style.Theme.default);
    try std.testing.expect(mouse.focused.?.eql(second));
    try std.testing.expect(!tree.getConst(first).kind.table_row.selected);
    try std.testing.expect(tree.getConst(second).kind.table_row.selected);

    dispatch.process(&tree, &.{
        .{ .key = .{ .scancode = 42, .keycode = .left_shift, .state = .pressed } },
        .{ .key = .{ .scancode = 108, .keycode = .down, .state = .pressed } },
        .{ .key = .{ .scancode = 42, .keycode = .left_shift, .state = .released } },
    }, &mouse, style.Theme.default);

    try std.testing.expect(mouse.focused.?.eql(third));
    try std.testing.expect(tree.getConst(second).kind.table_row.selected);
    try std.testing.expect(tree.getConst(third).kind.table_row.selected);
}

test "tree item toggles and keyboard navigation follows visible items" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const parent = try tree.addChild(root, .{ .tree_item = .{ .label = "Parent", .group = 7 } });
    const child = try tree.addChild(parent, .{ .tree_item = .{ .label = "Child", .group = 7 } });
    const sibling = try tree.addChild(root, .{ .tree_item = .{ .label = "Sibling", .group = 7 } });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 400, .h = 300 };
    tree.get(parent).layout_rect = .{ .x = 10, .y = 10, .w = 220, .h = 26 };
    tree.get(child).layout_rect = .{ .x = 10, .y = 40, .w = 220, .h = 26 };
    tree.get(sibling).layout_rect = .{ .x = 10, .y = 70, .w = 220, .h = 26 };

    var mouse = MouseState{};

    // Click in the disclosure slot. This collapses the parent without also
    // activating the row.
    dispatch.process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 18, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 18, .y = 20 } },
    }, &mouse, style.Theme.default);

    try std.testing.expect(!tree.getConst(parent).kind.tree_item.expanded);
    try std.testing.expect(!tree.getConst(parent).kind.tree_item.selected);

    mouse.focused = parent;
    focus.syncFocusFlags(&tree, mouse.focused);

    // Right expands the focused tree item.
    dispatch.process(&tree, &.{.{ .key = .{ .scancode = 106, .keycode = .right, .state = .pressed } }}, &mouse, style.Theme.default);
    try std.testing.expect(tree.getConst(parent).kind.tree_item.expanded);

    // Down moves into the now-visible child, then to the sibling.
    dispatch.process(&tree, &.{.{ .key = .{ .scancode = 108, .keycode = .down, .state = .pressed } }}, &mouse, style.Theme.default);
    try std.testing.expect(mouse.focused.?.eql(child));
    dispatch.process(&tree, &.{.{ .key = .{ .scancode = 108, .keycode = .down, .state = .pressed } }}, &mouse, style.Theme.default);
    try std.testing.expect(mouse.focused.?.eql(sibling));
}

test "collapsed tree item can be reopened with the mouse" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const parent = try tree.addChild(root, .{ .tree_item = .{ .label = "Scene", .group = 11 } });
    _ = try tree.addChild(parent, .{ .tree_item = .{ .label = "Child", .group = 11 } });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 400, .h = 300 };
    tree.get(parent).layout_rect = .{ .x = 10, .y = 10, .w = 220, .h = 26 };

    var mouse = MouseState{};
    const click = [_]input_types.Event{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 18, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 18, .y = 20 } },
    };

    dispatch.process(&tree, &click, &mouse, style.Theme.default);
    try std.testing.expect(!tree.getConst(parent).kind.tree_item.expanded);

    dispatch.process(&tree, &click, &mouse, style.Theme.default);
    try std.testing.expect(tree.getConst(parent).kind.tree_item.expanded);
}

test "lazy tree item can toggle without materialized child nodes" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const parent = try tree.addChild(root, .{ .tree_item = .{
        .label = "Folder",
        .has_children = true,
        .expanded = false,
    } });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 400, .h = 300 };
    tree.get(parent).layout_rect = .{ .x = 10, .y = 10, .w = 220, .h = 26 };

    var mouse = MouseState{};
    dispatch.process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 18, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 18, .y = 20 } },
    }, &mouse, style.Theme.default);

    try std.testing.expect(tree.getConst(parent).kind.tree_item.expanded);
}

test "selected editable tree item can rename inline on click" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const item = try tree.addChild(root, .{ .tree_item = .{
        .label = "Scene",
        .group = 12,
        .editable = true,
        .rename_trigger = .selected_click,
        .selected = true,
    } });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 400, .h = 300 };
    tree.get(item).layout_rect = .{ .x = 10, .y = 10, .w = 220, .h = 26 };

    var mouse = MouseState{};

    dispatch.process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 40, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 40, .y = 20 } },
    }, &mouse, style.Theme.default);
    try std.testing.expect(tree.getConst(item).kind.tree_item.editing);

    dispatch.process(&tree, &.{
        .{ .text = .{ .codepoint = 'X' } },
        .{ .key = .{ .scancode = 28, .keycode = .enter, .state = .pressed } },
    }, &mouse, style.Theme.default);

    try std.testing.expectEqualStrings("X", tree.getConst(item).kind.tree_item.label);
    try std.testing.expect(!tree.getConst(item).kind.tree_item.editing);
}

test "editable tree item can rename on double click" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const item = try tree.addChild(root, .{ .tree_item = .{
        .label = "Camera",
        .group = 13,
        .editable = true,
        .rename_trigger = .double_click,
    } });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 400, .h = 300 };
    tree.get(item).layout_rect = .{ .x = 10, .y = 10, .w = 220, .h = 26 };

    var mouse = MouseState{};

    dispatch.process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 40, .y = 20, .timestamp_ms = 100 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 40, .y = 20, .timestamp_ms = 100 } },
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 40, .y = 20, .timestamp_ms = 250 } },
    }, &mouse, style.Theme.default);

    try std.testing.expect(tree.getConst(item).kind.tree_item.editing);
}

test "tree item drag reports drop target and position" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const first = try tree.addChild(root, .{ .tree_item = .{ .label = "Scene", .group = 14 } });
    const second = try tree.addChild(root, .{ .tree_item = .{ .label = "Camera", .group = 14 } });
    try tree.setElementId(first, .init(121));
    try tree.setElementId(second, .init(122));

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 400, .h = 300 };
    tree.get(first).layout_rect = .{ .x = 10, .y = 10, .w = 220, .h = 26 };
    tree.get(second).layout_rect = .{ .x = 10, .y = 44, .w = 220, .h = 26 };

    var mouse = MouseState{};
    dispatch.process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 40, .y = 20 } },
        .{ .mouse_move = .{ .x = 40, .y = 56 } },
    }, &mouse, style.Theme.default);

    try std.testing.expect(tree.getConst(first).kind.tree_item.internal.drag.active);
    try std.testing.expectEqual(widget.WidgetKind.TreeItem.DropPosition.into, tree.getConst(second).kind.tree_item.internal.drop_preview.?);

    var journal: control_event.Journal = .{};
    defer journal.deinit(allocator);
    const output = try dispatch.processEvents(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 40, .y = 56 } },
    }, &mouse, style.Theme.default, &journal);

    const drop = output.items[output.items.len - 1].drop;
    try std.testing.expectEqual(control_event.ElementId.init(121), drop.source);
    try std.testing.expectEqual(control_event.ElementId.init(122), drop.target);
    try std.testing.expectEqual(control_event.Drop.Position.inside, drop.position);
    try std.testing.expect(!tree.getConst(first).kind.tree_item.internal.drag.active);
    try std.testing.expect(tree.getConst(second).kind.tree_item.internal.drop_preview == null);
}

test "dropdown menu item selection updates dropdown state" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const dropdown = try tree.addChild(root, .{ .dropdown = .{ .placeholder = "Select item" } });
    const popup = try tree.addChild(dropdown, .{ .popup = .{ .placement = .below_start } });
    const a = try tree.addChild(popup, .{ .menu_item = .{ .label = "Alpha" } });
    const b = try tree.addChild(popup, .{ .menu_item = .{ .label = "Beta" } });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 400, .h = 300 };
    tree.get(dropdown).layout_rect = .{ .x = 10, .y = 10, .w = 220, .h = 26 };
    tree.get(popup).layout_rect = .{ .x = 10, .y = 36, .w = 220, .h = 52 };
    tree.get(a).layout_rect = .{ .x = 10, .y = 36, .w = 220, .h = 26 };
    tree.get(b).layout_rect = .{ .x = 10, .y = 62, .w = 220, .h = 26 };

    var mouse = MouseState{};

    // Open the dropdown.
    dispatch.process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 30, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 30, .y = 20 } },
    }, &mouse, style.Theme.default);
    try std.testing.expect(tree.getConst(dropdown).kind.dropdown.open);

    // Pick the second item.
    dispatch.process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 30, .y = 72 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 30, .y = 72 } },
    }, &mouse, style.Theme.default);

    try std.testing.expectEqualStrings("Beta", tree.getConst(dropdown).kind.dropdown.selected_text);
    try std.testing.expectEqual(@as(?u16, 1), tree.getConst(dropdown).kind.dropdown.selected_index);
    try std.testing.expect(!tree.getConst(dropdown).kind.dropdown.open);
    try std.testing.expect(!tree.getConst(popup).kind.popup.visible);
}

test "menu hover opens submenu and leaf selection closes the stack" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const bar = try tree.addChild(root, .{ .menu_bar = .{} });
    const file = try tree.addChild(bar, .{ .menu = .{ .label = "File" } });
    const file_popup = try tree.addChild(file, .{ .popup = .{ .placement = .below_start, .visible = false } });
    const open_recent = try tree.addChild(file_popup, .{ .menu_item = .{ .label = "Open Recent" } });
    const recent_popup = try tree.addChild(open_recent, .{ .popup = .{ .placement = .right_start, .visible = false } });
    const recent_a = try tree.addChild(recent_popup, .{ .menu_item = .{ .label = "Shot A" } });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 400, .h = 300 };
    tree.get(bar).layout_rect = .{ .x = 0, .y = 0, .w = 400, .h = 28 };
    tree.get(file).layout_rect = .{ .x = 10, .y = 4, .w = 48, .h = 20 };
    tree.get(file_popup).layout_rect = .{ .x = 10, .y = 28, .w = 140, .h = 26 };
    tree.get(open_recent).layout_rect = .{ .x = 10, .y = 28, .w = 140, .h = 26 };
    tree.get(recent_popup).layout_rect = .{ .x = 150, .y = 28, .w = 120, .h = 26 };
    tree.get(recent_a).layout_rect = .{ .x = 150, .y = 28, .w = 120, .h = 26 };

    var mouse = MouseState{};

    dispatch.process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 20, .y = 12 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 20, .y = 12 } },
    }, &mouse, style.Theme.default);
    try std.testing.expect(tree.getConst(file_popup).kind.popup.visible);

    dispatch.process(&tree, &.{
        .{ .mouse_move = .{ .x = 40, .y = 40 } },
    }, &mouse, style.Theme.default);
    try std.testing.expect(tree.getConst(recent_popup).kind.popup.visible);

    dispatch.process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 170, .y = 40 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 170, .y = 40 } },
    }, &mouse, style.Theme.default);

    try std.testing.expect(!tree.getConst(file_popup).kind.popup.visible);
    try std.testing.expect(!tree.getConst(recent_popup).kind.popup.visible);
}

test "splitter drag updates ratio" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const splitter = try tree.addChild(root, .{ .splitter = .{
        .direction = .row,
        .ratio = 0.5,
        .min_first = 40,
        .min_second = 40,
        .thickness = 8,
    } });
    const left = try tree.addChild(splitter, .{ .container = .{} });
    const right = try tree.addChild(splitter, .{ .container = .{} });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 400, .h = 300 };
    tree.get(splitter).layout_rect = .{ .x = 10, .y = 10, .w = 300, .h = 120 };
    tree.get(left).layout_rect = .{ .x = 16, .y = 16, .w = 140, .h = 108 };
    tree.get(right).layout_rect = .{ .x = 164, .y = 16, .w = 140, .h = 108 };

    var mouse = MouseState{};
    dispatch.process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 160, .y = 60 } },
        .{ .mouse_move = .{ .x = 210, .y = 60 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 210, .y = 60 } },
    }, &mouse, style.Theme.default);

    try std.testing.expect(tree.getConst(splitter).kind.splitter.ratio > 0.5);
}

test "secondary click is reported on the target widget" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const btn = try tree.addChild(root, .{ .button = .{ .label = "Context" } });
    try tree.setElementId(btn, .init(131));

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 400, .h = 300 };
    tree.get(btn).layout_rect = .{ .x = 10, .y = 10, .w = 120, .h = 30 };

    var mouse = MouseState{};
    var journal: control_event.Journal = .{};
    defer journal.deinit(allocator);
    const output = try dispatch.processEvents(&tree, &.{
        .{ .mouse_button = .{ .button = .right, .state = .pressed, .x = 30, .y = 20 } },
        .{ .mouse_button = .{ .button = .right, .state = .released, .x = 30, .y = 20 } },
    }, &mouse, style.Theme.default, &journal);

    try std.testing.expectEqual(@as(usize, 1), output.items.len);
    const activation = output.items[0].secondary_activated;
    try std.testing.expectEqual(control_event.ElementId.init(131), activation.element);
    try std.testing.expectApproxEqAbs(@as(f32, 30), activation.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 20), activation.y, 0.01);
}

test "list box marquee stays owned by its container across child hits" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const list_box = try tree.addChild(root, .{ .list_box = .{ .selection_mode = .multiple } });
    const first = try tree.addChild(list_box, .{ .selectable = .{ .label = "Scene" } });
    const second = try tree.addChild(list_box, .{ .selectable = .{ .label = "Camera" } });
    const third = try tree.addChild(list_box, .{ .selectable = .{ .label = "Light" } });
    try tree.setElementId(list_box, .init(141));
    try tree.setElementId(first, .init(142));
    try tree.setElementId(second, .init(143));
    try tree.setElementId(third, .init(144));

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 400, .h = 300 };
    tree.get(list_box).layout_rect = .{ .x = 10, .y = 10, .w = 220, .h = 110 };
    tree.get(first).layout_rect = .{ .x = 10, .y = 10, .w = 220, .h = 24 };
    tree.get(second).layout_rect = .{ .x = 10, .y = 38, .w = 220, .h = 24 };
    tree.get(third).layout_rect = .{ .x = 10, .y = 66, .w = 220, .h = 24 };

    var mouse = MouseState{};
    var journal: control_event.Journal = .{};
    defer journal.deinit(allocator);
    _ = try dispatch.processEvents(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 20, .y = 104 } },
    }, &mouse, style.Theme.default, &journal);

    const first_move = try dispatch.processEvents(&tree, &.{
        .{ .mouse_move = .{ .x = 210, .y = 78 } },
    }, &mouse, style.Theme.default, &journal);
    try std.testing.expectEqual(@as(usize, 0), first_move.items.len);
    try std.testing.expect(mouse.drag_target.?.eql(list_box));
    try std.testing.expect(tree.getConst(list_box).kind.list_box.internal.marquee_active);
    try std.testing.expect(!tree.getConst(second).kind.selectable.selected);
    try std.testing.expect(tree.getConst(third).kind.selectable.selected);

    const second_move = try dispatch.processEvents(&tree, &.{
        .{ .mouse_move = .{ .x = 210, .y = 50 } },
    }, &mouse, style.Theme.default, &journal);
    try std.testing.expectEqual(@as(usize, 0), second_move.items.len);
    try std.testing.expect(mouse.drag_target.?.eql(list_box));

    try std.testing.expect(!tree.getConst(first).kind.selectable.selected);
    try std.testing.expect(tree.getConst(second).kind.selectable.selected);
    try std.testing.expect(tree.getConst(third).kind.selectable.selected);

    const release = try dispatch.processEvents(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 210, .y = 50 } },
    }, &mouse, style.Theme.default, &journal);
    try std.testing.expectEqual(@as(usize, 1), release.items.len);
    try std.testing.expectEqualSlices(
        control_event.ElementId,
        &.{ control_event.ElementId.init(143), control_event.ElementId.init(144) },
        release.selection(release.items[0].selection_changed),
    );
    try std.testing.expect(mouse.drag_target == null);
    try std.testing.expect(!tree.getConst(list_box).kind.list_box.internal.marquee_active);
}

test "selectable drag reports list drop target" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const list_box = try tree.addChild(root, .{ .list_box = .{ .selection_mode = .multiple } });
    const first = try tree.addChild(list_box, .{ .selectable = .{ .label = "Scene" } });
    const second = try tree.addChild(list_box, .{ .selectable = .{ .label = "Camera" } });
    try tree.setElementId(first, .init(141));
    try tree.setElementId(second, .init(142));

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 400, .h = 300 };
    tree.get(list_box).layout_rect = .{ .x = 10, .y = 10, .w = 220, .h = 90 };
    tree.get(first).layout_rect = .{ .x = 10, .y = 10, .w = 220, .h = 24 };
    tree.get(second).layout_rect = .{ .x = 10, .y = 38, .w = 220, .h = 24 };

    var mouse = MouseState{};
    dispatch.process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 40, .y = 22 } },
        .{ .mouse_move = .{ .x = 40, .y = 50 } },
    }, &mouse, style.Theme.default);

    try std.testing.expect(tree.getConst(first).kind.selectable.internal.drag.active);
    try std.testing.expect(tree.getConst(second).kind.selectable.internal.drop_preview);

    var journal: control_event.Journal = .{};
    defer journal.deinit(allocator);
    const output = try dispatch.processEvents(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 40, .y = 50 } },
    }, &mouse, style.Theme.default, &journal);

    const drop = output.items[output.items.len - 1].drop;
    try std.testing.expectEqual(control_event.ElementId.init(141), drop.source);
    try std.testing.expectEqual(control_event.ElementId.init(142), drop.target);
    try std.testing.expectEqual(control_event.Drop.Position.item, drop.position);
    try std.testing.expect(!tree.getConst(first).kind.selectable.internal.drag.active);
    try std.testing.expect(!tree.getConst(second).kind.selectable.internal.drop_preview);
}

test "table marquee stays owned by its container across child hits" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const table = try tree.addChild(root, .{ .table = .{ .selection_mode = .multiple } });
    const first = try tree.addChild(table, .{ .table_row = .{} });
    const second = try tree.addChild(table, .{ .table_row = .{} });
    const third = try tree.addChild(table, .{ .table_row = .{} });
    try tree.setElementId(table, .init(151));
    try tree.setElementId(first, .init(152));
    try tree.setElementId(second, .init(153));
    try tree.setElementId(third, .init(154));

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 400, .h = 300 };
    tree.get(table).layout_rect = .{ .x = 10, .y = 10, .w = 240, .h = 110 };
    tree.get(first).layout_rect = .{ .x = 10, .y = 10, .w = 240, .h = 24 };
    tree.get(second).layout_rect = .{ .x = 10, .y = 38, .w = 240, .h = 24 };
    tree.get(third).layout_rect = .{ .x = 10, .y = 66, .w = 240, .h = 24 };

    var mouse = MouseState{};
    var journal: control_event.Journal = .{};
    defer journal.deinit(allocator);
    _ = try dispatch.processEvents(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 20, .y = 104 } },
    }, &mouse, style.Theme.default, &journal);

    const first_move = try dispatch.processEvents(&tree, &.{
        .{ .mouse_move = .{ .x = 230, .y = 78 } },
    }, &mouse, style.Theme.default, &journal);
    try std.testing.expectEqual(@as(usize, 0), first_move.items.len);
    try std.testing.expect(mouse.drag_target.?.eql(table));
    try std.testing.expect(tree.getConst(table).kind.table.internal.marquee_active);
    try std.testing.expect(!tree.getConst(second).kind.table_row.selected);
    try std.testing.expect(tree.getConst(third).kind.table_row.selected);

    const second_move = try dispatch.processEvents(&tree, &.{
        .{ .mouse_move = .{ .x = 230, .y = 50 } },
    }, &mouse, style.Theme.default, &journal);
    try std.testing.expectEqual(@as(usize, 0), second_move.items.len);
    try std.testing.expect(mouse.drag_target.?.eql(table));

    try std.testing.expect(!tree.getConst(first).kind.table_row.selected);
    try std.testing.expect(tree.getConst(second).kind.table_row.selected);
    try std.testing.expect(tree.getConst(third).kind.table_row.selected);

    const release = try dispatch.processEvents(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 230, .y = 50 } },
    }, &mouse, style.Theme.default, &journal);
    try std.testing.expectEqual(@as(usize, 1), release.items.len);
    try std.testing.expectEqualSlices(
        control_event.ElementId,
        &.{ control_event.ElementId.init(153), control_event.ElementId.init(154) },
        release.selection(release.items[0].selection_changed),
    );
    try std.testing.expect(mouse.drag_target == null);
    try std.testing.expect(!tree.getConst(table).kind.table.internal.marquee_active);
}

test "cancel active container marquees rolls provisional selection back without output" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 400, .h = 400 };

    const grid = try tree.addChild(root, .{ .grid_selector = .{ .selection_mode = .multiple } });
    const grid_first = try tree.addChild(grid, .{ .grid_item = .{ .label = "First", .selected = true } });
    const grid_second = try tree.addChild(grid, .{ .grid_item = .{ .label = "Second" } });
    try tree.setElementId(grid, .init(161));
    try tree.setElementId(grid_first, .init(162));
    try tree.setElementId(grid_second, .init(163));
    tree.get(grid).layout_rect = .{ .x = 10, .y = 10, .w = 220, .h = 60 };
    tree.get(grid_first).layout_rect = .{ .x = 18, .y = 18, .w = 80, .h = 40 };
    tree.get(grid_second).layout_rect = .{ .x = 106, .y = 18, .w = 80, .h = 40 };

    const list = try tree.addChild(root, .{ .list_box = .{ .selection_mode = .multiple } });
    const list_first = try tree.addChild(list, .{ .selectable = .{ .label = "First", .selected = true } });
    const list_second = try tree.addChild(list, .{ .selectable = .{ .label = "Second" } });
    try tree.setElementId(list, .init(171));
    try tree.setElementId(list_first, .init(172));
    try tree.setElementId(list_second, .init(173));
    tree.get(list).layout_rect = .{ .x = 10, .y = 90, .w = 220, .h = 90 };
    tree.get(list_first).layout_rect = .{ .x = 10, .y = 90, .w = 220, .h = 24 };
    tree.get(list_second).layout_rect = .{ .x = 10, .y = 120, .w = 220, .h = 24 };

    const table = try tree.addChild(root, .{ .table = .{ .selection_mode = .multiple } });
    const table_first = try tree.addChild(table, .{ .table_row = .{ .selected = true } });
    const table_second = try tree.addChild(table, .{ .table_row = .{} });
    try tree.setElementId(table, .init(181));
    try tree.setElementId(table_first, .init(182));
    try tree.setElementId(table_second, .init(183));
    tree.get(table).layout_rect = .{ .x = 10, .y = 200, .w = 220, .h = 90 };
    tree.get(table_first).layout_rect = .{ .x = 10, .y = 200, .w = 220, .h = 24 };
    tree.get(table_second).layout_rect = .{ .x = 10, .y = 230, .w = 220, .h = 24 };

    var mouse = MouseState{};
    var journal: control_event.Journal = .{};
    defer journal.deinit(allocator);

    _ = try dispatch.processEvents(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 220, .y = 65 } },
        .{ .mouse_move = .{ .x = 150, .y = 40 } },
    }, &mouse, style.Theme.default, &journal);
    try std.testing.expect(!tree.getConst(grid_first).kind.grid_item.selected);
    try std.testing.expect(tree.getConst(grid_second).kind.grid_item.selected);
    const grid_cancel = try dispatch.cancelPointerGestureEvents(&tree, &mouse, &journal);
    try std.testing.expectEqual(@as(usize, 0), grid_cancel.items.len);
    try std.testing.expect(tree.getConst(grid_first).kind.grid_item.selected);
    try std.testing.expect(!tree.getConst(grid_second).kind.grid_item.selected);
    try std.testing.expect(!tree.getConst(grid).kind.grid_selector.internal.marquee_active);

    _ = try dispatch.processEvents(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 20, .y = 170 } },
        .{ .mouse_move = .{ .x = 200, .y = 135 } },
    }, &mouse, style.Theme.default, &journal);
    try std.testing.expect(!tree.getConst(list_first).kind.selectable.selected);
    try std.testing.expect(tree.getConst(list_second).kind.selectable.selected);
    const list_cancel = try dispatch.cancelPointerGestureEvents(&tree, &mouse, &journal);
    try std.testing.expectEqual(@as(usize, 0), list_cancel.items.len);
    try std.testing.expect(tree.getConst(list_first).kind.selectable.selected);
    try std.testing.expect(!tree.getConst(list_second).kind.selectable.selected);
    try std.testing.expect(!tree.getConst(list).kind.list_box.internal.marquee_active);

    _ = try dispatch.processEvents(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 20, .y = 280 } },
        .{ .mouse_move = .{ .x = 200, .y = 245 } },
    }, &mouse, style.Theme.default, &journal);
    try std.testing.expect(!tree.getConst(table_first).kind.table_row.selected);
    try std.testing.expect(tree.getConst(table_second).kind.table_row.selected);
    const table_cancel = try dispatch.cancelPointerGestureEvents(&tree, &mouse, &journal);
    try std.testing.expectEqual(@as(usize, 0), table_cancel.items.len);
    try std.testing.expect(tree.getConst(table_first).kind.table_row.selected);
    try std.testing.expect(!tree.getConst(table_second).kind.table_row.selected);
    try std.testing.expect(!tree.getConst(table).kind.table.internal.marquee_active);
}

test "table row drag reports table drop target" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const table = try tree.addChild(root, .{ .table = .{ .selection_mode = .multiple } });
    const first = try tree.addChild(table, .{ .table_row = .{} });
    const second = try tree.addChild(table, .{ .table_row = .{} });
    try tree.setElementId(first, .init(151));
    try tree.setElementId(second, .init(152));

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 400, .h = 300 };
    tree.get(table).layout_rect = .{ .x = 10, .y = 10, .w = 240, .h = 90 };
    tree.get(first).layout_rect = .{ .x = 10, .y = 10, .w = 240, .h = 24 };
    tree.get(second).layout_rect = .{ .x = 10, .y = 38, .w = 240, .h = 24 };

    var mouse = MouseState{};
    dispatch.process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 40, .y = 22 } },
        .{ .mouse_move = .{ .x = 40, .y = 50 } },
    }, &mouse, style.Theme.default);

    try std.testing.expect(tree.getConst(first).kind.table_row.internal.drag.active);
    try std.testing.expect(tree.getConst(second).kind.table_row.internal.drop_preview);

    var journal: control_event.Journal = .{};
    defer journal.deinit(allocator);
    const output = try dispatch.processEvents(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 40, .y = 50 } },
    }, &mouse, style.Theme.default, &journal);

    const drop = output.items[output.items.len - 1].drop;
    try std.testing.expectEqual(control_event.ElementId.init(151), drop.source);
    try std.testing.expectEqual(control_event.ElementId.init(152), drop.target);
    try std.testing.expectEqual(control_event.Drop.Position.item, drop.position);
    try std.testing.expect(!tree.getConst(first).kind.table_row.internal.drag.active);
    try std.testing.expect(!tree.getConst(second).kind.table_row.internal.drop_preview);
}
