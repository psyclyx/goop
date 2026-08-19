const std = @import("std");
const widget = @import("../widget.zig");
const input = @import("goop_input");
const style = @import("../style.zig");
const dispatch = @import("../dispatch.zig");
const control_event = @import("../control_event.zig");

const inside = input.Event.MouseMove{ .x = 30, .y = 20 };
const outside = input.Event.MouseMove{ .x = 180, .y = 100 };

fn process(
    tree: *widget.Tree,
    mouse: *dispatch.MouseState,
    journal: *control_event.Journal,
    events: []const input.Event,
) !control_event.ControlEvents {
    journal.clearRetainingCapacity();
    try journal.prepareBatch(std.testing.allocator, tree.count(), events.len);
    dispatch.process(tree, events, mouse, .default, null, null, journal);
    return journal.view();
}

fn setup(tree: *widget.Tree) !widget.NodeHandle {
    const root = try tree.addRoot(.{ .container = .{} });
    const button = try tree.addChild(root, .{ .button = .{ .label = "OK" } });
    try tree.setElementId(button, .init(91));
    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 240, .h = 140 };
    tree.get(button).layout_rect = .{ .x = 10, .y = 10, .w = 80, .h = 30 };
    return button;
}

test "captured button press visual clears outside and restores on re-entry" {
    var tree = widget.Tree.init(std.testing.allocator);
    defer tree.deinit();
    const button = try setup(&tree);
    var mouse: dispatch.MouseState = .{};
    var journal: control_event.Journal = .{};
    defer journal.deinit(std.testing.allocator);

    _ = try process(&tree, &mouse, &journal, &.{.{ .mouse_button = .{
        .button = .left,
        .state = .pressed,
        .x = inside.x,
        .y = inside.y,
    } }});
    try std.testing.expect(tree.getConst(button).interaction.pressed);

    _ = try process(&tree, &mouse, &journal, &.{.{ .mouse_move = outside }});
    try std.testing.expect(!tree.getConst(button).interaction.pressed);
    try std.testing.expect(mouse.press_target.?.eql(button));

    _ = try process(&tree, &mouse, &journal, &.{.{ .mouse_move = inside }});
    try std.testing.expect(tree.getConst(button).interaction.pressed);

    const output = try process(&tree, &mouse, &journal, &.{.{ .mouse_button = .{
        .button = .left,
        .state = .released,
        .x = inside.x,
        .y = inside.y,
    } }});
    try std.testing.expectEqual(@as(usize, 1), output.items.len);
    try std.testing.expect(output.items[0] == .activated);
    try std.testing.expect(!tree.getConst(button).interaction.pressed);
}

test "captured button invariants hold for every short inside-outside path" {
    // Exhaust all 3-move paths. This is deliberately a state-machine property,
    // not a single blessed coordinate trace.
    for (0..8) |path_bits| {
        var tree = widget.Tree.init(std.testing.allocator);
        defer tree.deinit();
        const button = try setup(&tree);
        var mouse: dispatch.MouseState = .{};
        var journal: control_event.Journal = .{};
        defer journal.deinit(std.testing.allocator);

        _ = try process(&tree, &mouse, &journal, &.{.{ .mouse_button = .{
            .button = .left,
            .state = .pressed,
            .x = inside.x,
            .y = inside.y,
        } }});

        var final_inside = true;
        for (0..3) |step| {
            final_inside = path_bits & (@as(usize, 1) << @intCast(step)) != 0;
            const move = if (final_inside) inside else outside;
            _ = try process(&tree, &mouse, &journal, &.{.{ .mouse_move = move }});
            try std.testing.expectEqual(final_inside, tree.getConst(button).interaction.pressed);
            try std.testing.expect(mouse.left_down);
            try std.testing.expect(mouse.press_target.?.eql(button));
        }

        const release = if (final_inside) inside else outside;
        const output = try process(&tree, &mouse, &journal, &.{.{ .mouse_button = .{
            .button = .left,
            .state = .released,
            .x = release.x,
            .y = release.y,
        } }});
        try std.testing.expectEqual(@as(usize, if (final_inside) 1 else 0), output.items.len);
        try std.testing.expect(!tree.getConst(button).interaction.pressed);
        try std.testing.expect(!mouse.left_down);
        try std.testing.expect(mouse.press_target == null);
    }
}
