const std = @import("std");
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
    return textXGetter(node.kind)(tree, handle, node, resolved, theme);
}

const TextXGetter = *const fn (*const widget.Tree, widget.NodeHandle, *const widget.Node, style.ResolvedStyle, style.Theme) ?f32;

fn textXGetter(kind: widget.WidgetKind) TextXGetter {
    const tag: std.meta.Tag(widget.WidgetKind) = kind;
    return text_x_getters[@intFromEnum(tag)];
}

const text_x_getters = blk: {
    const Tag = std.meta.Tag(widget.WidgetKind);
    var getters: [std.meta.fields(Tag).len]TextXGetter = undefined;
    for (&getters) |*getter| getter.* = noTextX;
    getters[@intFromEnum(Tag.text_input)] = textInputTextX;
    getters[@intFromEnum(Tag.tree_item)] = treeItemTextX;
    getters[@intFromEnum(Tag.drag_value)] = dragValueTextX;
    getters[@intFromEnum(Tag.spinbox)] = spinBoxTextX;
    break :blk getters;
};

fn noTextX(_: *const widget.Tree, _: widget.NodeHandle, _: *const widget.Node, _: style.ResolvedStyle, _: style.Theme) ?f32 {
    return null;
}

fn textInputTextX(_: *const widget.Tree, _: widget.NodeHandle, node: *const widget.Node, resolved: style.ResolvedStyle, _: style.Theme) ?f32 {
    return node.layout_rect.x + resolved.padding.left;
}

fn treeItemTextX(tree: *const widget.Tree, handle: widget.NodeHandle, node: *const widget.Node, _: style.ResolvedStyle, theme: style.Theme) ?f32 {
    return if (node.kind.tree_item.editing) treeTextX(tree, handle, theme) else null;
}

fn dragValueTextX(_: *const widget.Tree, _: widget.NodeHandle, node: *const widget.Node, resolved: style.ResolvedStyle, _: style.Theme) ?f32 {
    return if (node.kind.drag_value.editing) node.layout_rect.x + resolved.padding.left else null;
}

fn spinBoxTextX(tree: *const widget.Tree, handle: widget.NodeHandle, node: *const widget.Node, resolved: style.ResolvedStyle, _: style.Theme) ?f32 {
    return if (node.kind.spinbox.editing) spinBoxMiddleStart(tree, handle) + resolved.padding.left else null;
}
