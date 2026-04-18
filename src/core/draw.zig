const std = @import("std");
const style = @import("style.zig");
const widget = @import("widget.zig");

/// Axis-aligned rectangle.
pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

/// A single draw command emitted by the core.
pub const DrawCommand = union(enum) {
    rect: DrawRect,
    text: DrawText,
    clip: ClipRect,

    pub const DrawRect = struct {
        bounds: Rect,
        color: style.Color,
        border_color: style.Color,
        border_width: f32,
        corner_radius: f32,
    };

    pub const DrawText = struct {
        x: f32,
        y: f32,
        text: []const u8,
        color: style.Color,
        font_size: f32,
    };

    pub const ClipRect = struct {
        bounds: ?Rect,
    };
};

/// Accumulated draw output from a frame.
pub const DrawList = struct {
    commands: []const DrawCommand,
};

/// Generate draw commands from a laid-out widget tree.
pub fn generate(tree: *const widget.Tree, theme: style.Theme, allocator: std.mem.Allocator) !DrawList {
    var commands: std.ArrayListUnmanaged(DrawCommand) = .empty;
    errdefer commands.deinit(allocator);

    for (tree.nodes.items, 0..) |node, i| {
        if (node.parent == null) {
            try emitNode(tree, @enumFromInt(@as(u32, @intCast(i))), theme, &commands, allocator);
        }
    }

    return .{ .commands = try commands.toOwnedSlice(allocator) };
}

/// Free a DrawList's command slice.
pub fn freeDrawList(draw_list: *DrawList, allocator: std.mem.Allocator) void {
    allocator.free(draw_list.commands);
    draw_list.commands = &.{};
}

fn emitNode(
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(DrawCommand),
    allocator: std.mem.Allocator,
) std.mem.Allocator.Error!void {
    const node = tree.getConst(handle);
    const resolved = node.style_override.resolve(theme);

    switch (node.kind) {
        .container => try emitContainer(tree, handle, node, resolved, theme, commands, allocator),
        .text => |txt| try emitText(node, txt, resolved, commands, allocator),
        .button => |btn| try emitButton(tree, handle, node, btn, resolved, theme, commands, allocator),
        .slider => |sl| try emitSlider(node, sl, resolved, theme, commands, allocator),
        .scroll_area => try emitScrollArea(tree, handle, node, resolved, theme, commands, allocator),
    }
}

fn emitContainer(
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    node: *const widget.Node,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(DrawCommand),
    allocator: std.mem.Allocator,
) !void {
    // Background rect
    try commands.append(allocator, .{ .rect = .{
        .bounds = node.layout_rect,
        .color = resolved.bg,
        .border_color = resolved.border,
        .border_width = resolved.border_width,
        .corner_radius = resolved.border_radius,
    } });

    try emitChildren(tree, handle, theme, commands, allocator);
}

fn emitText(
    node: *const widget.Node,
    txt: widget.WidgetKind.Text,
    resolved: style.ResolvedStyle,
    commands: *std.ArrayListUnmanaged(DrawCommand),
    allocator: std.mem.Allocator,
) !void {
    try commands.append(allocator, .{ .text = .{
        .x = node.layout_rect.x,
        .y = node.layout_rect.y,
        .text = txt.content,
        .color = resolved.fg,
        .font_size = resolved.font_size,
    } });
}

fn emitButton(
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    node: *const widget.Node,
    btn: widget.WidgetKind.Button,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(DrawCommand),
    allocator: std.mem.Allocator,
) !void {
    // Pick bg based on interaction state
    const bg = if (node.interaction.pressed)
        theme.bg_active
    else if (node.interaction.hovered)
        theme.bg_hover
    else
        resolved.bg;

    // Background rect
    try commands.append(allocator, .{ .rect = .{
        .bounds = node.layout_rect,
        .color = bg,
        .border_color = resolved.border,
        .border_width = resolved.border_width,
        .corner_radius = resolved.border_radius,
    } });

    // Label text — centered within the button rect
    try commands.append(allocator, .{ .text = .{
        .x = node.layout_rect.x + resolved.padding.left,
        .y = node.layout_rect.y + resolved.padding.top,
        .text = btn.label,
        .color = resolved.fg,
        .font_size = resolved.font_size,
    } });

    try emitChildren(tree, handle, theme, commands, allocator);
}

fn emitSlider(
    node: *const widget.Node,
    sl: widget.WidgetKind.Slider,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(DrawCommand),
    allocator: std.mem.Allocator,
) !void {
    const rect = node.layout_rect;

    // Track
    try commands.append(allocator, .{ .rect = .{
        .bounds = rect,
        .color = resolved.bg,
        .border_color = resolved.border,
        .border_width = resolved.border_width,
        .corner_radius = resolved.border_radius,
    } });

    // Thumb
    const range = sl.max - sl.min;
    const t = if (range > 0) (sl.value - sl.min) / range else 0;
    const thumb_w: f32 = 16;
    const usable = rect.w - thumb_w;
    const thumb_x = rect.x + usable * t;

    try commands.append(allocator, .{ .rect = .{
        .bounds = .{ .x = thumb_x, .y = rect.y, .w = thumb_w, .h = rect.h },
        .color = theme.accent,
        .border_color = resolved.border,
        .border_width = 0,
        .corner_radius = resolved.border_radius,
    } });
}

fn emitScrollArea(
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    node: *const widget.Node,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(DrawCommand),
    allocator: std.mem.Allocator,
) !void {
    // Background
    try commands.append(allocator, .{ .rect = .{
        .bounds = node.layout_rect,
        .color = resolved.bg,
        .border_color = resolved.border,
        .border_width = resolved.border_width,
        .corner_radius = resolved.border_radius,
    } });

    // Push clip
    try commands.append(allocator, .{ .clip = .{ .bounds = node.layout_rect } });

    try emitChildren(tree, handle, theme, commands, allocator);

    // Pop clip
    try commands.append(allocator, .{ .clip = .{ .bounds = null } });
}

fn emitChildren(
    tree: *const widget.Tree,
    parent: widget.NodeHandle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(DrawCommand),
    allocator: std.mem.Allocator,
) !void {
    var iter = tree.children(parent);
    while (iter.next()) |child| {
        try emitNode(tree, child, theme, commands, allocator);
    }
}

test "generate draw commands from tree" {
    const allocator = std.testing.allocator;

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    _ = try tree.addChild(root, .{ .button = .{ .label = "OK" } });
    _ = try tree.addChild(root, .{ .text = .{ .content = "hello" } });

    // Set some layout rects so draw has something to work with
    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };

    const theme = style.Theme.default;
    var dl = try generate(&tree, theme, allocator);
    defer freeDrawList(&dl, allocator);

    // Container bg + button bg + button text + text label = 4 commands
    try std.testing.expectEqual(@as(usize, 4), dl.commands.len);
    try std.testing.expect(dl.commands[0] == .rect); // container bg
    try std.testing.expect(dl.commands[1] == .rect); // button bg
    try std.testing.expect(dl.commands[2] == .text); // button label
    try std.testing.expect(dl.commands[3] == .text); // text widget
}

test "slider emits track and thumb" {
    const allocator = std.testing.allocator;

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const sl = try tree.addRoot(.{ .slider = .{ .value = 0.5, .min = 0, .max = 1 } });
    tree.get(sl).layout_rect = .{ .x = 10, .y = 20, .w = 200, .h = 24 };

    const theme = style.Theme.default;
    var dl = try generate(&tree, theme, allocator);
    defer freeDrawList(&dl, allocator);

    // Track + thumb = 2 rects
    try std.testing.expectEqual(@as(usize, 2), dl.commands.len);
    try std.testing.expect(dl.commands[0] == .rect); // track
    try std.testing.expect(dl.commands[1] == .rect); // thumb

    // Thumb should be roughly centered for value=0.5
    const thumb = dl.commands[1].rect;
    const expected_x = 10.0 + (200.0 - 16.0) * 0.5;
    try std.testing.expectApproxEqAbs(expected_x, thumb.bounds.x, 0.01);
}

test "scroll area emits clip commands" {
    const allocator = std.testing.allocator;

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const scroll = try tree.addRoot(.{ .scroll_area = .{} });
    _ = try tree.addChild(scroll, .{ .text = .{ .content = "inside" } });
    tree.get(scroll).layout_rect = .{ .x = 0, .y = 0, .w = 300, .h = 200 };

    const theme = style.Theme.default;
    var dl = try generate(&tree, theme, allocator);
    defer freeDrawList(&dl, allocator);

    // bg rect + clip push + text + clip pop = 4
    try std.testing.expectEqual(@as(usize, 4), dl.commands.len);
    try std.testing.expect(dl.commands[0] == .rect); // bg
    try std.testing.expect(dl.commands[1] == .clip); // push
    try std.testing.expect(dl.commands[1].clip.bounds != null);
    try std.testing.expect(dl.commands[2] == .text); // child text
    try std.testing.expect(dl.commands[3] == .clip); // pop
    try std.testing.expect(dl.commands[3].clip.bounds == null);
}
