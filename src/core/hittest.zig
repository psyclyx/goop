const std = @import("std");
const widget = @import("widget.zig");
const visual_types = @import("visual_types.zig");
const style = @import("style.zig");
const geometry = @import("geometry.zig");

const HitState = struct {
    offset_x: f32 = 0,
    offset_y: f32 = 0,
    clip: ?visual_types.Rect = null,
};

/// Find the topmost interactive widget at (x, y), giving floating popup
/// subtrees precedence over the regular layout tree.
pub fn hitTest(tree: *const widget.Tree, x: f32, y: f32) ?widget.NodeHandle {
    return hitTestWithTheme(tree, x, y, style.Theme.default);
}

pub fn hitTestWithTheme(tree: *const widget.Tree, x: f32, y: f32, theme: style.Theme) ?widget.NodeHandle {
    var result: ?widget.NodeHandle = null;

    for (tree.nodes.items, 0..) |node, i| {
        if (!node.alive or node.parent != null or node.kind == .popup or node.kind == .tooltip) continue;
        if (hitTestSubtree(tree, tree.handleFromIndex(@intCast(i)), x, y, null, false, .{}, theme)) |found| {
            result = found;
        }
    }

    for (tree.nodes.items, 0..) |node, i| {
        if (!node.alive or node.parent != null) continue;
        if (hitTestFloatingSubtrees(tree, tree.handleFromIndex(@intCast(i)), x, y, null, theme)) |found| {
            result = found;
        }
    }

    return result;
}

/// Find the topmost widget of a specific kind at (x, y).
pub fn hitTestKind(tree: *const widget.Tree, x: f32, y: f32, kind_tag: std.meta.Tag(widget.WidgetKind)) ?widget.NodeHandle {
    return hitTestKindWithTheme(tree, x, y, kind_tag, style.Theme.default);
}

pub fn hitTestKindWithTheme(tree: *const widget.Tree, x: f32, y: f32, kind_tag: std.meta.Tag(widget.WidgetKind), theme: style.Theme) ?widget.NodeHandle {
    var result: ?widget.NodeHandle = null;

    for (tree.nodes.items, 0..) |node, i| {
        if (!node.alive or node.parent != null or node.kind == .popup or node.kind == .tooltip) continue;
        if (hitTestSubtree(tree, tree.handleFromIndex(@intCast(i)), x, y, kind_tag, false, .{}, theme)) |found| {
            result = found;
        }
    }

    for (tree.nodes.items, 0..) |node, i| {
        if (!node.alive or node.parent != null) continue;
        if (hitTestFloatingSubtrees(tree, tree.handleFromIndex(@intCast(i)), x, y, kind_tag, theme)) |found| {
            result = found;
        }
    }

    return result;
}

pub fn isInteractive(kind: widget.WidgetKind) bool {
    return interactiveKind(kind)(kind);
}

const InteractiveKind = *const fn (widget.WidgetKind) bool;

fn interactiveKind(kind: widget.WidgetKind) InteractiveKind {
    const tag: std.meta.Tag(widget.WidgetKind) = kind;
    return interactive_kinds[@intFromEnum(tag)];
}

const interactive_kinds = blk: {
    const Tag = std.meta.Tag(widget.WidgetKind);
    var kinds: [std.meta.fields(Tag).len]InteractiveKind = undefined;
    kinds[@intFromEnum(Tag.container)] = trueInteractive;
    kinds[@intFromEnum(Tag.text)] = falseInteractive;
    kinds[@intFromEnum(Tag.icon)] = falseInteractive;
    kinds[@intFromEnum(Tag.button)] = trueInteractive;
    kinds[@intFromEnum(Tag.checkbox)] = trueInteractive;
    kinds[@intFromEnum(Tag.radio_button)] = trueInteractive;
    kinds[@intFromEnum(Tag.tree_item)] = trueInteractive;
    kinds[@intFromEnum(Tag.dropdown)] = trueInteractive;
    kinds[@intFromEnum(Tag.list_box)] = trueInteractive;
    kinds[@intFromEnum(Tag.selectable)] = trueInteractive;
    kinds[@intFromEnum(Tag.grid_selector)] = trueInteractive;
    kinds[@intFromEnum(Tag.grid_item)] = trueInteractive;
    kinds[@intFromEnum(Tag.table)] = trueInteractive;
    kinds[@intFromEnum(Tag.table_row)] = trueInteractive;
    kinds[@intFromEnum(Tag.table_cell)] = falseInteractive;
    kinds[@intFromEnum(Tag.toolbar)] = falseInteractive;
    kinds[@intFromEnum(Tag.status_bar)] = falseInteractive;
    kinds[@intFromEnum(Tag.menu_bar)] = falseInteractive;
    kinds[@intFromEnum(Tag.menu)] = trueInteractive;
    kinds[@intFromEnum(Tag.popup)] = trueInteractive;
    kinds[@intFromEnum(Tag.tooltip)] = falseInteractive;
    kinds[@intFromEnum(Tag.menu_item)] = trueInteractive;
    kinds[@intFromEnum(Tag.drag_value)] = trueInteractive;
    kinds[@intFromEnum(Tag.spinbox)] = trueInteractive;
    kinds[@intFromEnum(Tag.tab_bar)] = falseInteractive;
    kinds[@intFromEnum(Tag.tab_item)] = trueInteractive;
    kinds[@intFromEnum(Tag.splitter)] = trueInteractive;
    kinds[@intFromEnum(Tag.slider)] = trueInteractive;
    kinds[@intFromEnum(Tag.spacer)] = falseInteractive;
    kinds[@intFromEnum(Tag.scroll_area)] = trueInteractive;
    kinds[@intFromEnum(Tag.text_input)] = trueInteractive;
    kinds[@intFromEnum(Tag.custom)] = trueInteractive;
    break :blk kinds;
};

fn trueInteractive(_: widget.WidgetKind) bool {
    return true;
}

fn falseInteractive(_: widget.WidgetKind) bool {
    return false;
}

pub fn pointInRect(x: f32, y: f32, rect: visual_types.Rect) bool {
    return geometry.pointInRect(x, y, rect);
}

fn hitTestFloatingSubtrees(
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    x: f32,
    y: f32,
    kind_tag: ?std.meta.Tag(widget.WidgetKind),
    theme: style.Theme,
) ?widget.NodeHandle {
    if (!isVisible(tree, handle)) return null;
    const node = tree.getConst(handle);
    if (node.kind == .popup) {
        return hitTestSubtree(tree, handle, x, y, kind_tag, true, .{}, theme);
    }
    if (node.kind == .tooltip) return null;

    var result: ?widget.NodeHandle = null;
    var iter = tree.children(handle);
    while (iter.next()) |child| {
        if (node.kind == .tree_item and !node.kind.tree_item.expanded and tree.getConst(child).kind != .popup and tree.getConst(child).kind != .tooltip) continue;
        if (node.kind == .tab_item and !node.kind.tab_item.selected) continue;
        if (hitTestFloatingSubtrees(tree, child, x, y, kind_tag, theme)) |found| {
            result = found;
        }
    }
    return result;
}

fn hitTestSubtree(
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    x: f32,
    y: f32,
    kind_tag: ?std.meta.Tag(widget.WidgetKind),
    in_floating_subtree: bool,
    state: HitState,
    theme: style.Theme,
) ?widget.NodeHandle {
    if (!isVisible(tree, handle)) return null;
    const node = tree.getConst(handle);
    if (!in_floating_subtree and (node.kind == .popup or node.kind == .tooltip)) return null;
    if (state.clip) |clip| {
        if (!pointInRect(x, y, clip)) return null;
    }

    var result: ?widget.NodeHandle = null;
    if ((kind_tag == null or node.kind == kind_tag.?) and isInteractive(node.kind) and pointHitsWidget(tree, handle, x, y, state, theme)) {
        result = handle;
    }

    // A splitter's handle is an interaction overlay on its pane children.
    // Descendant containers must not steal the expanded grab region.
    if (node.kind == .splitter and result != null) return result;

    const child_state = childHitState(node, state);
    var iter = tree.children(handle);
    while (iter.next()) |child| {
        if (!in_floating_subtree and (tree.getConst(child).kind == .popup or tree.getConst(child).kind == .tooltip)) continue;
        if (node.kind == .tree_item and !node.kind.tree_item.expanded and tree.getConst(child).kind != .popup and tree.getConst(child).kind != .tooltip) continue;
        if (node.kind == .tab_item and !node.kind.tab_item.selected) continue;
        if (hitTestSubtree(tree, child, x, y, kind_tag, in_floating_subtree, child_state, theme)) |found| {
            result = found;
        }
    }
    return result;
}

fn isVisible(tree: *const widget.Tree, handle: widget.NodeHandle) bool {
    const node = tree.getConst(handle);
    return visibilityTester(node.kind)(tree, handle, node);
}

const VisibilityTester = *const fn (*const widget.Tree, widget.NodeHandle, *const widget.Node) bool;

fn visibilityTester(kind: widget.WidgetKind) VisibilityTester {
    const tag: std.meta.Tag(widget.WidgetKind) = kind;
    return visibility_testers[@intFromEnum(tag)];
}

const visibility_testers = blk: {
    const Tag = std.meta.Tag(widget.WidgetKind);
    var testers: [std.meta.fields(Tag).len]VisibilityTester = undefined;
    testers[@intFromEnum(Tag.container)] = rectVisible;
    testers[@intFromEnum(Tag.text)] = rectVisible;
    testers[@intFromEnum(Tag.icon)] = rectVisible;
    testers[@intFromEnum(Tag.button)] = rectVisible;
    testers[@intFromEnum(Tag.checkbox)] = rectVisible;
    testers[@intFromEnum(Tag.radio_button)] = rectVisible;
    testers[@intFromEnum(Tag.tree_item)] = rectVisible;
    testers[@intFromEnum(Tag.dropdown)] = rectVisible;
    testers[@intFromEnum(Tag.list_box)] = rectVisible;
    testers[@intFromEnum(Tag.selectable)] = rectVisible;
    testers[@intFromEnum(Tag.grid_selector)] = rectVisible;
    testers[@intFromEnum(Tag.grid_item)] = rectVisible;
    testers[@intFromEnum(Tag.table)] = rectVisible;
    testers[@intFromEnum(Tag.table_row)] = rectVisible;
    testers[@intFromEnum(Tag.table_cell)] = rectVisible;
    testers[@intFromEnum(Tag.toolbar)] = rectVisible;
    testers[@intFromEnum(Tag.status_bar)] = rectVisible;
    testers[@intFromEnum(Tag.menu_bar)] = rectVisible;
    testers[@intFromEnum(Tag.menu)] = rectVisible;
    testers[@intFromEnum(Tag.popup)] = popupVisible;
    testers[@intFromEnum(Tag.tooltip)] = tooltipVisible;
    testers[@intFromEnum(Tag.menu_item)] = rectVisible;
    testers[@intFromEnum(Tag.drag_value)] = rectVisible;
    testers[@intFromEnum(Tag.spinbox)] = rectVisible;
    testers[@intFromEnum(Tag.tab_bar)] = rectVisible;
    testers[@intFromEnum(Tag.tab_item)] = rectVisible;
    testers[@intFromEnum(Tag.splitter)] = rectVisible;
    testers[@intFromEnum(Tag.slider)] = rectVisible;
    testers[@intFromEnum(Tag.spacer)] = rectVisible;
    testers[@intFromEnum(Tag.scroll_area)] = rectVisible;
    testers[@intFromEnum(Tag.text_input)] = rectVisible;
    testers[@intFromEnum(Tag.custom)] = rectVisible;
    break :blk testers;
};

fn rectVisible(_: *const widget.Tree, _: widget.NodeHandle, node: *const widget.Node) bool {
    return node.layout_rect.w > 0 and node.layout_rect.h > 0;
}

fn popupVisible(tree: *const widget.Tree, _: widget.NodeHandle, node: *const widget.Node) bool {
    if (!node.kind.popup.visible) return false;
    if (node.parent) |parent_handle| {
        const parent = tree.getConst(parent_handle);
        if (parent.kind == .dropdown) {
            return parent.kind.dropdown.open and node.layout_rect.w > 0 and node.layout_rect.h > 0;
        }
    }
    return node.layout_rect.w > 0 and node.layout_rect.h > 0;
}

fn tooltipVisible(tree: *const widget.Tree, handle: widget.NodeHandle, node: *const widget.Node) bool {
    const owner_handle = node.parent orelse return false;
    const owner = tree.getConst(owner_handle);
    _ = handle;
    return (owner.interaction.hovered or owner.interaction.focused) and node.layout_rect.w > 0 and node.layout_rect.h > 0;
}

fn pointHitsWidget(tree: *const widget.Tree, handle: widget.NodeHandle, x: f32, y: f32, state: HitState, theme: style.Theme) bool {
    const node = tree.getConst(handle);
    const local_x = x - state.offset_x;
    const local_y = y - state.offset_y;
    return pointHitTester(node.kind)(tree, handle, node, local_x, local_y, theme);
}

const PointHitTester = *const fn (*const widget.Tree, widget.NodeHandle, *const widget.Node, f32, f32, style.Theme) bool;

fn pointHitTester(kind: widget.WidgetKind) PointHitTester {
    const tag: std.meta.Tag(widget.WidgetKind) = kind;
    return point_hit_testers[@intFromEnum(tag)];
}

const point_hit_testers = blk: {
    const Tag = std.meta.Tag(widget.WidgetKind);
    var testers: [std.meta.fields(Tag).len]PointHitTester = undefined;
    testers[@intFromEnum(Tag.container)] = rectPointHit;
    testers[@intFromEnum(Tag.text)] = rectPointHit;
    testers[@intFromEnum(Tag.icon)] = rectPointHit;
    testers[@intFromEnum(Tag.button)] = rectPointHit;
    testers[@intFromEnum(Tag.checkbox)] = rectPointHit;
    testers[@intFromEnum(Tag.radio_button)] = rectPointHit;
    testers[@intFromEnum(Tag.tree_item)] = rectPointHit;
    testers[@intFromEnum(Tag.dropdown)] = rectPointHit;
    testers[@intFromEnum(Tag.list_box)] = rectPointHit;
    testers[@intFromEnum(Tag.selectable)] = rectPointHit;
    testers[@intFromEnum(Tag.grid_selector)] = rectPointHit;
    testers[@intFromEnum(Tag.grid_item)] = rectPointHit;
    testers[@intFromEnum(Tag.table)] = rectPointHit;
    testers[@intFromEnum(Tag.table_row)] = tableRowPointHit;
    testers[@intFromEnum(Tag.table_cell)] = rectPointHit;
    testers[@intFromEnum(Tag.toolbar)] = rectPointHit;
    testers[@intFromEnum(Tag.status_bar)] = rectPointHit;
    testers[@intFromEnum(Tag.menu_bar)] = rectPointHit;
    testers[@intFromEnum(Tag.menu)] = rectPointHit;
    testers[@intFromEnum(Tag.popup)] = rectPointHit;
    testers[@intFromEnum(Tag.tooltip)] = rectPointHit;
    testers[@intFromEnum(Tag.menu_item)] = rectPointHit;
    testers[@intFromEnum(Tag.drag_value)] = rectPointHit;
    testers[@intFromEnum(Tag.spinbox)] = rectPointHit;
    testers[@intFromEnum(Tag.tab_bar)] = rectPointHit;
    testers[@intFromEnum(Tag.tab_item)] = rectPointHit;
    testers[@intFromEnum(Tag.splitter)] = splitterPointHit;
    testers[@intFromEnum(Tag.slider)] = rectPointHit;
    testers[@intFromEnum(Tag.spacer)] = rectPointHit;
    testers[@intFromEnum(Tag.scroll_area)] = rectPointHit;
    testers[@intFromEnum(Tag.text_input)] = rectPointHit;
    testers[@intFromEnum(Tag.custom)] = rectPointHit;
    break :blk testers;
};

fn rectPointHit(_: *const widget.Tree, _: widget.NodeHandle, node: *const widget.Node, x: f32, y: f32, _: style.Theme) bool {
    return pointInRect(x, y, node.layout_rect);
}

fn tableRowPointHit(tree: *const widget.Tree, handle: widget.NodeHandle, node: *const widget.Node, x: f32, y: f32, _: style.Theme) bool {
    return widget.tableRowSelectable(tree, handle) and pointInRect(x, y, node.layout_rect);
}

fn splitterPointHit(_: *const widget.Tree, _: widget.NodeHandle, node: *const widget.Node, x: f32, y: f32, theme: style.Theme) bool {
    const resolved = node.style_override.resolve(theme);
    return pointInRect(x, y, geometry.splitterInteractionRect(node.layout_rect, node.kind.splitter, resolved));
}

fn childHitState(node: *const widget.Node, state: HitState) HitState {
    if (node.kind != .scroll_area) return state;

    const scroll = node.kind.scroll_area;
    const node_rect = translatedRect(node.layout_rect, state);
    return .{
        .offset_x = state.offset_x - scroll.effectiveScrollX(),
        .offset_y = state.offset_y - scroll.effectiveScrollY(),
        .clip = if (state.clip) |clip| geometry.intersectRects(clip, node_rect) else node_rect,
    };
}

fn translatedRect(rect: visual_types.Rect, state: HitState) visual_types.Rect {
    return .{
        .x = rect.x + state.offset_x,
        .y = rect.y + state.offset_y,
        .w = rect.w,
        .h = rect.h,
    };
}

test "floating popup subtree wins hit testing over regular content" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const button = try tree.addChild(root, .{ .button = .{ .label = "Behind" } });
    const popup = try tree.addRoot(.{ .popup = .{ .placement = .absolute, .x = 20, .y = 20 } });
    const item = try tree.addChild(popup, .{ .menu_item = .{ .label = "Front" } });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 400, .h = 300 };
    tree.get(button).layout_rect = .{ .x = 10, .y = 10, .w = 120, .h = 30 };
    tree.get(popup).layout_rect = .{ .x = 0, .y = 0, .w = 140, .h = 80 };
    tree.get(item).layout_rect = .{ .x = 0, .y = 0, .w = 140, .h = 30 };

    try std.testing.expect(hitTest(&tree, 30, 20).?.eql(item));
}

test "scroll area hit testing follows visual child offset" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const scroll = try tree.addRoot(.{ .scroll_area = .{ .scroll_y = 40 } });
    const button = try tree.addChild(scroll, .{ .button = .{ .label = "Scrolled" } });

    tree.get(scroll).layout_rect = .{ .x = 0, .y = 0, .w = 200, .h = 80 };
    tree.get(button).layout_rect = .{ .x = 10, .y = 60, .w = 100, .h = 24 };

    try std.testing.expect(hitTest(&tree, 20, 30).?.eql(button));
    try std.testing.expect(hitTestKind(&tree, 20, 30, .button).?.eql(button));
    try std.testing.expect(hitTestKind(&tree, 20, 70, .button) == null);
}

test "scroll area clips hit testing to viewport" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const scroll = try tree.addRoot(.{ .scroll_area = .{ .scroll_y = 40 } });
    const button = try tree.addChild(scroll, .{ .button = .{ .label = "Clipped" } });

    tree.get(scroll).layout_rect = .{ .x = 0, .y = 0, .w = 200, .h = 40 };
    tree.get(button).layout_rect = .{ .x = 10, .y = 70, .w = 100, .h = 24 };

    try std.testing.expect(hitTestKind(&tree, 20, 35, .button).?.eql(button));
    try std.testing.expect(hitTestKind(&tree, 20, 45, .button) == null);
}

test "splitter handle wins over overlapping pane descendants" {
    const allocator = std.testing.allocator;
    for ([_]widget.WidgetKind.Container.Direction{ .row, .column }) |direction| {
        for ([_]f32{ 0.2, 0.5, 0.8 }) |ratio| {
            var tree = widget.Tree.init(allocator);
            defer tree.deinit();
            const splitter = try tree.addRoot(.{ .splitter = .{
                .direction = direction,
                .ratio = ratio,
                .thickness = 12,
                .gap_thickness = 1,
            } });
            const first = try tree.addChild(splitter, .{ .container = .{} });
            const second = try tree.addChild(splitter, .{ .container = .{} });
            const bounds = visual_types.Rect{ .x = 17, .y = 23, .w = 301, .h = 199 };
            tree.get(splitter).layout_rect = bounds;
            tree.get(first).layout_rect = bounds;
            tree.get(second).layout_rect = bounds;
            const theme = style.Theme{ .padding = .all(3) };
            const resolved = tree.getConst(splitter).style_override.resolve(theme);
            const handle = geometry.splitterInteractionRect(bounds, tree.getConst(splitter).kind.splitter, resolved);
            for (0..7) |across_sample| {
                for (0..11) |along_sample| {
                    const across = (@as(f32, @floatFromInt(across_sample)) + 0.5) / 7;
                    const along = (@as(f32, @floatFromInt(along_sample)) + 0.5) / 11;
                    const x = handle.x + handle.w * (if (direction == .row) across else along);
                    const y = handle.y + handle.h * (if (direction == .column) across else along);
                    try std.testing.expect(hitTestWithTheme(&tree, x, y, theme).?.eql(splitter));
                }
            }
        }
    }
}

test "table column interaction strips win over header descendants" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();
    const table = try tree.addRoot(.{ .table = .{ .columns = 2, .resizable = true } });
    tree.get(table).kind.table.syncColumns(2);
    const header = try tree.addChild(table, .{ .table_row = .{ .header = true } });
    const left = try tree.addChild(header, .{ .table_cell = .{} });
    const right = try tree.addChild(header, .{ .table_cell = .{} });
    const left_label = try tree.addChild(left, .{ .text = .{ .content = "Name" } });
    const right_label = try tree.addChild(right, .{ .text = .{ .content = "Type" } });
    tree.get(table).layout_rect = .{ .x = 10, .y = 20, .w = 300, .h = 30 };
    tree.get(header).layout_rect = tree.getConst(table).layout_rect;
    tree.get(left).layout_rect = .{ .x = 10, .y = 20, .w = 180, .h = 30 };
    tree.get(right).layout_rect = .{ .x = 190, .y = 20, .w = 120, .h = 30 };
    tree.get(left_label).layout_rect = tree.getConst(left).layout_rect;
    tree.get(right_label).layout_rect = tree.getConst(right).layout_rect;

    const handle = widget.tableResizeHandleRect(&tree, table, 0).?;
    for (0..11) |x_sample| {
        for (0..7) |y_sample| {
            const x = handle.x + handle.w * (@as(f32, @floatFromInt(x_sample)) + 0.5) / 11;
            const y = handle.y + handle.h * (@as(f32, @floatFromInt(y_sample)) + 0.5) / 7;
            try std.testing.expect(hitTestWithTheme(&tree, x, y, style.Theme.default).?.eql(table));
            try std.testing.expectEqual(@as(?u8, 0), widget.tableResizeHandleIndexAtPoint(&tree, table, x, y));
        }
    }
}
