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
        .checkbox => |cb| try emitCheckbox(node, cb, resolved, theme, commands, allocator),
        .radio_button => |rb| try emitRadioButton(node, rb, resolved, theme, commands, allocator),
        .slider => |sl| try emitSlider(node, sl, resolved, theme, commands, allocator),
        .text_input => try emitTextInput(node, resolved, theme, commands, allocator),
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
    // Background rect
    try commands.append(allocator, .{ .rect = .{
        .bounds = node.layout_rect,
        .color = interactionBg(node, resolved, theme),
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

    try emitFocusRing(node, theme, resolved.border_radius, commands, allocator);
    try emitChildren(tree, handle, theme, commands, allocator);
}

fn emitCheckbox(
    node: *const widget.Node,
    cb: widget.WidgetKind.Checkbox,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(DrawCommand),
    allocator: std.mem.Allocator,
) !void {
    const rect = node.layout_rect;
    const box_size = resolved.font_size;

    // Checkbox box
    try commands.append(allocator, .{ .rect = .{
        .bounds = .{
            .x = rect.x + resolved.padding.left,
            .y = rect.y + resolved.padding.top,
            .w = box_size,
            .h = box_size,
        },
        .color = interactionBg(node, resolved, theme),
        .border_color = resolved.border,
        .border_width = resolved.border_width,
        .corner_radius = resolved.border_radius,
    } });

    // Check indicator (filled inner rect when checked)
    if (cb.checked) {
        const inset: f32 = 3;
        try commands.append(allocator, .{ .rect = .{
            .bounds = .{
                .x = rect.x + resolved.padding.left + inset,
                .y = rect.y + resolved.padding.top + inset,
                .w = box_size - inset * 2,
                .h = box_size - inset * 2,
            },
            .color = theme.accent,
            .border_color = theme.accent,
            .border_width = 0,
            .corner_radius = @max(resolved.border_radius - inset, 0),
        } });
    }

    // Label text
    try commands.append(allocator, .{ .text = .{
        .x = rect.x + resolved.padding.left + box_size + resolved.padding.left,
        .y = rect.y + resolved.padding.top,
        .text = cb.label,
        .color = resolved.fg,
        .font_size = resolved.font_size,
    } });

    try emitFocusRing(node, theme, resolved.border_radius, commands, allocator);
}

fn emitRadioButton(
    node: *const widget.Node,
    rb: widget.WidgetKind.RadioButton,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(DrawCommand),
    allocator: std.mem.Allocator,
) !void {
    const rect = node.layout_rect;
    const box_size = resolved.font_size;
    const circle_radius = box_size / 2;

    // Outer circle
    try commands.append(allocator, .{ .rect = .{
        .bounds = .{
            .x = rect.x + resolved.padding.left,
            .y = rect.y + resolved.padding.top,
            .w = box_size,
            .h = box_size,
        },
        .color = interactionBg(node, resolved, theme),
        .border_color = resolved.border,
        .border_width = resolved.border_width,
        .corner_radius = circle_radius,
    } });

    // Inner dot when selected
    if (rb.selected) {
        const inset: f32 = 3;
        try commands.append(allocator, .{ .rect = .{
            .bounds = .{
                .x = rect.x + resolved.padding.left + inset,
                .y = rect.y + resolved.padding.top + inset,
                .w = box_size - inset * 2,
                .h = box_size - inset * 2,
            },
            .color = theme.accent,
            .border_color = theme.accent,
            .border_width = 0,
            .corner_radius = circle_radius - inset,
        } });
    }

    // Label text
    try commands.append(allocator, .{ .text = .{
        .x = rect.x + resolved.padding.left + box_size + resolved.padding.left,
        .y = rect.y + resolved.padding.top,
        .text = rb.label,
        .color = resolved.fg,
        .font_size = resolved.font_size,
    } });

    try emitFocusRing(node, theme, circle_radius, commands, allocator);
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
    const thumb_w = resolved.thumb_width;
    const usable = rect.w - thumb_w;
    const thumb_x = rect.x + usable * t;

    try commands.append(allocator, .{ .rect = .{
        .bounds = .{ .x = thumb_x, .y = rect.y, .w = thumb_w, .h = rect.h },
        .color = theme.accent,
        .border_color = resolved.border,
        .border_width = 0,
        .corner_radius = resolved.border_radius,
    } });

    try emitFocusRing(node, theme, resolved.border_radius, commands, allocator);
}

fn emitTextInput(
    node: *const widget.Node,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(DrawCommand),
    allocator: std.mem.Allocator,
) !void {
    const ti = &node.kind.text_input;
    const rect = node.layout_rect;

    // Background
    try commands.append(allocator, .{ .rect = .{
        .bounds = rect,
        .color = interactionBg(node, resolved, theme),
        .border_color = resolved.border,
        .border_width = resolved.border_width,
        .corner_radius = resolved.border_radius,
    } });

    // Text content or placeholder
    const content = ti.content();
    if (content.len > 0) {
        try commands.append(allocator, .{ .text = .{
            .x = rect.x + resolved.padding.left,
            .y = rect.y + resolved.padding.top,
            .text = content,
            .color = resolved.fg,
            .font_size = resolved.font_size,
        } });
    } else if (ti.placeholder.len > 0) {
        try commands.append(allocator, .{ .text = .{
            .x = rect.x + resolved.padding.left,
            .y = rect.y + resolved.padding.top,
            .text = ti.placeholder,
            .color = theme.placeholder_fg,
            .font_size = resolved.font_size,
        } });
    }

    // Selection highlight and cursor (when focused)
    if (node.interaction.focused) {
        const char_width = resolved.font_size * 0.6;
        const text_y = rect.y + resolved.padding.top;

        // Selection highlight
        if (ti.hasSelection()) {
            const range = ti.selectionRange();
            const sel_x = rect.x + resolved.padding.left + @as(f32, @floatFromInt(range.start)) * char_width;
            const sel_w = @as(f32, @floatFromInt(range.end - range.start)) * char_width;
            try commands.append(allocator, .{ .rect = .{
                .bounds = .{ .x = sel_x, .y = text_y, .w = sel_w, .h = resolved.font_size },
                .color = theme.selection_bg,
                .border_color = theme.selection_bg,
                .border_width = 0,
                .corner_radius = 0,
            } });
        }

        // Cursor
        const cursor_x = rect.x + resolved.padding.left + @as(f32, @floatFromInt(ti.cursor)) * char_width;
        try commands.append(allocator, .{ .rect = .{
            .bounds = .{ .x = cursor_x, .y = text_y, .w = 1, .h = resolved.font_size },
            .color = resolved.fg,
            .border_color = resolved.fg,
            .border_width = 0,
            .corner_radius = 0,
        } });
    }

    try emitFocusRing(node, theme, resolved.border_radius, commands, allocator);
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

/// Emit a focus ring around a widget's layout rect if it has focus.
fn emitFocusRing(
    node: *const widget.Node,
    theme: style.Theme,
    corner_radius: f32,
    commands: *std.ArrayListUnmanaged(DrawCommand),
    allocator: std.mem.Allocator,
) !void {
    if (!node.interaction.focused) return;
    const r = node.layout_rect;
    const inset: f32 = -2;
    try commands.append(allocator, .{ .rect = .{
        .bounds = .{
            .x = r.x + inset,
            .y = r.y + inset,
            .w = r.w - inset * 2,
            .h = r.h - inset * 2,
        },
        .color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .border_color = theme.focus_ring,
        .border_width = 2,
        .corner_radius = corner_radius + 2,
    } });
}

/// Resolve the background color for an interactive widget, accounting for
/// pressed/hovered state.
fn interactionBg(node: *const widget.Node, resolved: style.ResolvedStyle, theme: style.Theme) style.Color {
    return if (node.interaction.pressed)
        theme.bg_active
    else if (node.interaction.hovered)
        theme.bg_hover
    else
        resolved.bg;
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

test "checkbox emits box and label" {
    const allocator = std.testing.allocator;

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const cb = try tree.addRoot(.{ .checkbox = .{ .label = "Enable", .checked = false } });
    tree.get(cb).layout_rect = .{ .x = 10, .y = 20, .w = 200, .h = 26 };

    const theme = style.Theme.default;
    var dl = try generate(&tree, theme, allocator);
    defer freeDrawList(&dl, allocator);

    // Unchecked: box rect + label text = 2 commands
    try std.testing.expectEqual(@as(usize, 2), dl.commands.len);
    try std.testing.expect(dl.commands[0] == .rect); // box
    try std.testing.expect(dl.commands[1] == .text); // label
}

test "checked checkbox emits indicator" {
    const allocator = std.testing.allocator;

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const cb = try tree.addRoot(.{ .checkbox = .{ .label = "Enable", .checked = true } });
    tree.get(cb).layout_rect = .{ .x = 10, .y = 20, .w = 200, .h = 26 };

    const theme = style.Theme.default;
    var dl = try generate(&tree, theme, allocator);
    defer freeDrawList(&dl, allocator);

    // Checked: box rect + indicator rect + label text = 3 commands
    try std.testing.expectEqual(@as(usize, 3), dl.commands.len);
    try std.testing.expect(dl.commands[0] == .rect); // box
    try std.testing.expect(dl.commands[1] == .rect); // check indicator
    try std.testing.expect(dl.commands[2] == .text); // label
}

test "radio button emits circle and label" {
    const allocator = std.testing.allocator;

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const rb = try tree.addRoot(.{ .radio_button = .{ .label = "Option A", .group = 1 } });
    tree.get(rb).layout_rect = .{ .x = 10, .y = 20, .w = 200, .h = 26 };

    const theme = style.Theme.default;
    var dl = try generate(&tree, theme, allocator);
    defer freeDrawList(&dl, allocator);

    // Unselected: circle rect + label text = 2 commands
    try std.testing.expectEqual(@as(usize, 2), dl.commands.len);
    try std.testing.expect(dl.commands[0] == .rect);
    try std.testing.expect(dl.commands[1] == .text);

    // Corner radius should be half the box size (circular)
    const circle = dl.commands[0].rect;
    try std.testing.expectApproxEqAbs(circle.bounds.w / 2, circle.corner_radius, 0.01);
}

test "selected radio button emits indicator dot" {
    const allocator = std.testing.allocator;

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const rb = try tree.addRoot(.{ .radio_button = .{ .label = "Option A", .group = 1, .selected = true } });
    tree.get(rb).layout_rect = .{ .x = 10, .y = 20, .w = 200, .h = 26 };

    const theme = style.Theme.default;
    var dl = try generate(&tree, theme, allocator);
    defer freeDrawList(&dl, allocator);

    // Selected: circle rect + indicator dot + label text = 3 commands
    try std.testing.expectEqual(@as(usize, 3), dl.commands.len);
    try std.testing.expect(dl.commands[0] == .rect);
    try std.testing.expect(dl.commands[1] == .rect);
    try std.testing.expect(dl.commands[2] == .text);
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

test "text input emits bg and text" {
    const allocator = std.testing.allocator;

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const ti = try tree.addRoot(.{ .text_input = .{} });
    tree.get(ti).layout_rect = .{ .x = 10, .y = 20, .w = 300, .h = 30 };

    const theme = style.Theme.default;
    var dl = try generate(&tree, theme, allocator);
    defer freeDrawList(&dl, allocator);

    // Unfocused, empty, no placeholder: bg rect only = 1 command
    try std.testing.expectEqual(@as(usize, 1), dl.commands.len);
    try std.testing.expect(dl.commands[0] == .rect); // bg
}

test "focused text input emits cursor" {
    const allocator = std.testing.allocator;

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const ti = try tree.addRoot(.{ .text_input = .{} });
    tree.get(ti).layout_rect = .{ .x = 10, .y = 20, .w = 300, .h = 30 };
    tree.get(ti).interaction.focused = true;

    const theme = style.Theme.default;
    var dl = try generate(&tree, theme, allocator);
    defer freeDrawList(&dl, allocator);

    // Focused, empty, no placeholder: bg rect + cursor rect + focus ring = 3 commands
    try std.testing.expectEqual(@as(usize, 3), dl.commands.len);
    try std.testing.expect(dl.commands[0] == .rect); // bg
    try std.testing.expect(dl.commands[1] == .rect); // cursor
    try std.testing.expect(dl.commands[2] == .rect); // focus ring
}

test "empty text input shows placeholder" {
    const allocator = std.testing.allocator;

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const ti = try tree.addRoot(.{ .text_input = .{ .placeholder = "Enter name" } });
    tree.get(ti).layout_rect = .{ .x = 10, .y = 20, .w = 300, .h = 30 };

    const theme = style.Theme.default;
    var dl = try generate(&tree, theme, allocator);
    defer freeDrawList(&dl, allocator);

    // Empty with placeholder: bg rect + placeholder text = 2 commands
    try std.testing.expectEqual(@as(usize, 2), dl.commands.len);
    try std.testing.expect(dl.commands[0] == .rect); // bg
    try std.testing.expect(dl.commands[1] == .text); // placeholder
    try std.testing.expectEqualStrings("Enter name", dl.commands[1].text.text);
    try std.testing.expectEqual(theme.placeholder_fg, dl.commands[1].text.color);
}

test "text input with content shows content not placeholder" {
    const allocator = std.testing.allocator;

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const ti = try tree.addRoot(.{ .text_input = .{ .placeholder = "Enter name" } });
    tree.get(ti).layout_rect = .{ .x = 10, .y = 20, .w = 300, .h = 30 };
    tree.get(ti).kind.text_input.insert('H');
    tree.get(ti).kind.text_input.insert('i');

    const theme = style.Theme.default;
    var dl = try generate(&tree, theme, allocator);
    defer freeDrawList(&dl, allocator);

    // Has content: bg rect + content text = 2 commands
    try std.testing.expectEqual(@as(usize, 2), dl.commands.len);
    try std.testing.expect(dl.commands[0] == .rect); // bg
    try std.testing.expect(dl.commands[1] == .text); // content, not placeholder
    try std.testing.expectEqualStrings("Hi", dl.commands[1].text.text);
    try std.testing.expectEqual(theme.fg, dl.commands[1].text.color);
}

test "focused text input with selection emits highlight rect" {
    const allocator = std.testing.allocator;

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const ti = try tree.addRoot(.{ .text_input = .{} });
    tree.get(ti).layout_rect = .{ .x = 10, .y = 20, .w = 300, .h = 30 };
    tree.get(ti).interaction.focused = true;

    // Insert "hello" then select positions 1..3 ("el")
    const input = &tree.get(ti).kind.text_input;
    input.insert('h');
    input.insert('e');
    input.insert('l');
    input.insert('l');
    input.insert('o');
    input.cursor = 3;
    input.selection_anchor = 1;

    const theme = style.Theme.default;
    var dl = try generate(&tree, theme, allocator);
    defer freeDrawList(&dl, allocator);

    // bg rect + text + selection highlight + cursor + focus ring = 5 commands
    try std.testing.expectEqual(@as(usize, 5), dl.commands.len);
    try std.testing.expect(dl.commands[0] == .rect); // bg
    try std.testing.expect(dl.commands[1] == .text); // content
    try std.testing.expect(dl.commands[2] == .rect); // selection highlight
    try std.testing.expect(dl.commands[3] == .rect); // cursor
    try std.testing.expect(dl.commands[4] == .rect); // focus ring

    // Verify selection highlight color
    try std.testing.expectEqual(theme.selection_bg, dl.commands[2].rect.color);
}
