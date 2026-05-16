const std = @import("std");
const widget = @import("../../widget.zig");
const paint = @import("../../paint.zig");
const types = @import("../types.zig");

const MouseState = types.MouseState;

pub fn beginListBoxMarquee(tree: *widget.Tree, list_box: widget.NodeHandle, mouse: *MouseState) void {
    if (!tree.isAlive(list_box) or tree.getConst(list_box).kind != .list_box) return;
    if (tree.getConst(list_box).kind.list_box.selection_mode != .multiple) return;
    mouse.press_can_defer_drag = false;
    mouse.drag_target = list_box;
    mouse.drag_origin_x = mouse.press_origin_x;
    mouse.drag_origin_y = mouse.press_origin_y;
    snapshotListBoxSelection(tree, list_box);
    tree.get(list_box).kind.list_box.internal.marquee_active = true;
    updateListBoxMarquee(tree, list_box, mouse);
}

pub fn updateListBoxMarquee(tree: *widget.Tree, list_box: widget.NodeHandle, mouse: *const MouseState) void {
    if (!tree.isAlive(list_box) or tree.getConst(list_box).kind != .list_box) return;
    if (!tree.getConst(list_box).kind.list_box.internal.marquee_active) return;

    const list_rect = tree.getConst(list_box).layout_rect;
    const marquee_rect = clampRectToBounds(normalizedRect(mouse.drag_origin_x, mouse.drag_origin_y, mouse.x, mouse.y), list_rect);
    tree.get(list_box).kind.list_box.internal.marquee_rect = marquee_rect;

    var changed = false;
    var iter = tree.children(list_box);
    while (iter.next()) |child| {
        if (tree.getConst(child).kind != .selectable) continue;
        const child_node = tree.getConst(child);
        const should_select = rectsIntersect(marquee_rect, child_node.layout_rect) or
            (mouse.ctrl_down and child_node.kind.selectable.internal.marquee_base_selected);
        if (child_node.kind.selectable.selected != should_select) {
            tree.get(child).kind.selectable.selected = should_select;
            changed = true;
        }
    }
    if (changed) tree.get(list_box).interaction.changed = true;
}

pub fn finalizeListBoxMarquee(tree: *widget.Tree, list_box: widget.NodeHandle) void {
    if (!tree.isAlive(list_box) or tree.getConst(list_box).kind != .list_box) return;
    const node = &tree.get(list_box).kind.list_box;
    node.internal.marquee_active = false;
    node.internal.marquee_rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };

    var iter = tree.children(list_box);
    while (iter.next()) |child| {
        if (tree.getConst(child).kind != .selectable) continue;
        tree.get(child).kind.selectable.internal.marquee_base_selected = false;
    }
}

pub fn snapshotListBoxSelection(tree: *widget.Tree, list_box: widget.NodeHandle) void {
    var iter = tree.children(list_box);
    while (iter.next()) |child| {
        if (tree.getConst(child).kind != .selectable) continue;
        tree.get(child).kind.selectable.internal.marquee_base_selected = tree.getConst(child).kind.selectable.selected;
    }
}

pub fn beginGridSelectorMarquee(tree: *widget.Tree, selector: widget.NodeHandle, mouse: *MouseState) void {
    if (!tree.isAlive(selector) or tree.getConst(selector).kind != .grid_selector) return;
    mouse.press_can_defer_drag = false;
    mouse.drag_target = selector;
    mouse.drag_origin_x = mouse.press_origin_x;
    mouse.drag_origin_y = mouse.press_origin_y;
    snapshotGridSelectorSelection(tree, selector);
    tree.get(selector).kind.grid_selector.internal.marquee_active = true;
    updateGridSelectorMarquee(tree, selector, mouse);
}

pub fn updateGridSelectorMarquee(tree: *widget.Tree, selector: widget.NodeHandle, mouse: *const MouseState) void {
    if (!tree.isAlive(selector) or tree.getConst(selector).kind != .grid_selector) return;

    const selector_rect = tree.getConst(selector).layout_rect;
    const marquee_rect = clampRectToBounds(normalizedRect(mouse.drag_origin_x, mouse.drag_origin_y, mouse.x, mouse.y), selector_rect);
    tree.get(selector).kind.grid_selector.internal.marquee_rect = marquee_rect;

    var changed = false;
    var iter = tree.children(selector);
    while (iter.next()) |child| {
        if (tree.getConst(child).kind != .grid_item) continue;
        const child_node = tree.getConst(child);
        const should_select = rectsIntersect(marquee_rect, child_node.layout_rect) or
            (mouse.ctrl_down and child_node.kind.grid_item.internal.marquee_base_selected);
        if (child_node.kind.grid_item.selected != should_select) {
            tree.get(child).kind.grid_item.selected = should_select;
            changed = true;
        }
    }
    if (changed) tree.get(selector).interaction.changed = true;
}

pub fn finalizeGridSelectorMarquee(tree: *widget.Tree, selector: widget.NodeHandle) void {
    if (!tree.isAlive(selector) or tree.getConst(selector).kind != .grid_selector) return;
    const grid_selector = &tree.get(selector).kind.grid_selector;
    grid_selector.internal.marquee_active = false;
    grid_selector.internal.marquee_rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };

    var iter = tree.children(selector);
    while (iter.next()) |child| {
        if (tree.getConst(child).kind != .grid_item) continue;
        tree.get(child).kind.grid_item.internal.marquee_base_selected = false;
    }
}

pub fn snapshotGridSelectorSelection(tree: *widget.Tree, selector: widget.NodeHandle) void {
    var iter = tree.children(selector);
    while (iter.next()) |child| {
        if (tree.getConst(child).kind != .grid_item) continue;
        tree.get(child).kind.grid_item.internal.marquee_base_selected = tree.getConst(child).kind.grid_item.selected;
    }
}

pub fn beginTableMarquee(tree: *widget.Tree, table: widget.NodeHandle, mouse: *MouseState) void {
    if (!tree.isAlive(table) or tree.getConst(table).kind != .table) return;
    if (tree.getConst(table).kind.table.selection_mode != .multiple) return;
    mouse.press_can_defer_drag = false;
    mouse.drag_target = table;
    mouse.drag_origin_x = mouse.press_origin_x;
    mouse.drag_origin_y = mouse.press_origin_y;
    snapshotTableSelection(tree, table);
    tree.get(table).kind.table.internal.marquee_active = true;
    updateTableMarquee(tree, table, mouse);
}

pub fn updateTableMarquee(tree: *widget.Tree, table: widget.NodeHandle, mouse: *const MouseState) void {
    if (!tree.isAlive(table) or tree.getConst(table).kind != .table) return;
    if (!tree.getConst(table).kind.table.internal.marquee_active) return;

    const table_rect = tree.getConst(table).layout_rect;
    const marquee_rect = clampRectToBounds(normalizedRect(mouse.drag_origin_x, mouse.drag_origin_y, mouse.x, mouse.y), table_rect);
    tree.get(table).kind.table.internal.marquee_rect = marquee_rect;

    var changed = false;
    var iter = tree.children(table);
    while (iter.next()) |child| {
        const child_node = tree.getConst(child);
        if (child_node.kind != .table_row or child_node.kind.table_row.header) continue;
        const should_select = rectsIntersect(marquee_rect, child_node.layout_rect) or
            (mouse.ctrl_down and child_node.kind.table_row.internal.marquee_base_selected);
        if (child_node.kind.table_row.selected != should_select) {
            tree.get(child).kind.table_row.selected = should_select;
            changed = true;
        }
    }
    if (changed) tree.get(table).kind.table.selection_changed = true;
}

pub fn finalizeTableMarquee(tree: *widget.Tree, table: widget.NodeHandle) void {
    if (!tree.isAlive(table) or tree.getConst(table).kind != .table) return;
    const node = &tree.get(table).kind.table;
    node.internal.marquee_active = false;
    node.internal.marquee_rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };

    var iter = tree.children(table);
    while (iter.next()) |child| {
        if (tree.getConst(child).kind != .table_row) continue;
        tree.get(child).kind.table_row.internal.marquee_base_selected = false;
    }
}

pub fn snapshotTableSelection(tree: *widget.Tree, table: widget.NodeHandle) void {
    var iter = tree.children(table);
    while (iter.next()) |child| {
        const child_node = tree.getConst(child);
        if (child_node.kind != .table_row or child_node.kind.table_row.header) continue;
        tree.get(child).kind.table_row.internal.marquee_base_selected = child_node.kind.table_row.selected;
    }
}

pub fn normalizedRect(x0: f32, y0: f32, x1: f32, y1: f32) paint.Rect {
    return .{
        .x = @min(x0, x1),
        .y = @min(y0, y1),
        .w = @abs(x1 - x0),
        .h = @abs(y1 - y0),
    };
}

pub fn clampRectToBounds(rect: paint.Rect, bounds: paint.Rect) paint.Rect {
    const left = std.math.clamp(rect.x, bounds.x, bounds.x + bounds.w);
    const top = std.math.clamp(rect.y, bounds.y, bounds.y + bounds.h);
    const right = std.math.clamp(rect.x + rect.w, bounds.x, bounds.x + bounds.w);
    const bottom = std.math.clamp(rect.y + rect.h, bounds.y, bounds.y + bounds.h);
    return .{
        .x = left,
        .y = top,
        .w = @max(right - left, 0),
        .h = @max(bottom - top, 0),
    };
}

pub fn rectsIntersect(a: paint.Rect, b: paint.Rect) bool {
    return a.x < b.x + b.w and a.x + a.w > b.x and a.y < b.y + b.h and a.y + a.h > b.y;
}
