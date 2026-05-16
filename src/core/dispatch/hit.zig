const widget = @import("../widget.zig");
const style = @import("../style.zig");
const navigation = @import("navigation.zig");

pub fn clickInTreeDisclosure(tree: *const widget.Tree, handle: widget.NodeHandle, mouse_x: f32, theme: style.Theme) bool {
    if (!navigation.hasTreeItemChildren(tree, handle)) return false;
    const left = treeDisclosureX(tree, handle, theme);
    const right = left + treeDisclosureWidth(tree, handle, theme);
    return mouse_x >= left and mouse_x <= right;
}

pub fn clickInTreeLabel(tree: *const widget.Tree, handle: widget.NodeHandle, mouse_x: f32, theme: style.Theme) bool {
    const left = treeLabelX(tree, handle, theme);
    const node = tree.getConst(handle);
    const resolved = node.style_override.resolve(theme);
    const right = node.layout_rect.x + node.layout_rect.w - resolved.padding.right;
    return mouse_x >= left and mouse_x <= right;
}

pub fn clickInSpinBoxDecrement(tree: *const widget.Tree, handle: widget.NodeHandle, mouse_x: f32) bool {
    return mouse_x < spinBoxMiddleStart(tree, handle);
}

pub fn clickInSpinBoxIncrement(tree: *const widget.Tree, handle: widget.NodeHandle, mouse_x: f32) bool {
    return mouse_x > spinBoxMiddleEnd(tree, handle);
}

fn treeDepth(tree: *const widget.Tree, handle: widget.NodeHandle) u32 {
    var depth: u32 = 0;
    var current = tree.getConst(handle).parent;
    while (current) |parent_handle| {
        const parent = tree.getConst(parent_handle);
        if (parent.kind == .tree_item) depth += 1;
        current = parent.parent;
    }
    return depth;
}

fn spinBoxButtonWidth(tree: *const widget.Tree, handle: widget.NodeHandle) f32 {
    const rect = tree.getConst(handle).layout_rect;
    return @min(rect.h, 28);
}

fn spinBoxMiddleStart(tree: *const widget.Tree, handle: widget.NodeHandle) f32 {
    return tree.getConst(handle).layout_rect.x + spinBoxButtonWidth(tree, handle);
}

fn spinBoxMiddleEnd(tree: *const widget.Tree, handle: widget.NodeHandle) f32 {
    const rect = tree.getConst(handle).layout_rect;
    return rect.x + rect.w - spinBoxButtonWidth(tree, handle);
}

fn treeDisclosureX(tree: *const widget.Tree, handle: widget.NodeHandle, theme: style.Theme) f32 {
    const node = tree.getConst(handle);
    const resolved = node.style_override.resolve(theme);
    const indent = @as(f32, @floatFromInt(treeDepth(tree, handle))) * (resolved.font_size + theme.spacing);
    return node.layout_rect.x + resolved.padding.left + indent;
}

fn treeDisclosureWidth(tree: *const widget.Tree, handle: widget.NodeHandle, theme: style.Theme) f32 {
    const node = tree.getConst(handle);
    return node.style_override.resolve(theme).font_size + 4;
}

fn treeLabelX(tree: *const widget.Tree, handle: widget.NodeHandle, theme: style.Theme) f32 {
    return treeDisclosureX(tree, handle, theme) + treeDisclosureWidth(tree, handle, theme);
}

fn treeTextX(tree: *const widget.Tree, handle: widget.NodeHandle, theme: style.Theme) f32 {
    const label_x = treeLabelX(tree, handle, theme);
    const node = tree.getConst(handle);
    if (node.kind != .tree_item or node.kind.tree_item.icon == null) return label_x;
    const resolved = node.style_override.resolve(theme);
    const inner_h = @max(node.layout_rect.h - resolved.padding.top - resolved.padding.bottom, 0);
    const icon_size = @min(@max(resolved.font_size, 10), inner_h);
    return label_x + icon_size + @max(theme.spacing * 0.5, 4);
}

pub fn textEditorTextX(tree: *const widget.Tree, handle: widget.NodeHandle, theme: style.Theme) ?f32 {
    const node = tree.getConst(handle);
    const resolved = node.style_override.resolve(theme);
    return switch (node.kind) {
        .text_input => node.layout_rect.x + resolved.padding.left,
        .tree_item => if (node.kind.tree_item.editing) treeTextX(tree, handle, theme) else null,
        .drag_value => if (node.kind.drag_value.editing) node.layout_rect.x + resolved.padding.left else null,
        .spinbox => if (node.kind.spinbox.editing) spinBoxMiddleStart(tree, handle) + resolved.padding.left else null,
        else => null,
    };
}
