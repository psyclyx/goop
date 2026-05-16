const std = @import("std");
const widget = @import("../widget.zig");
const style = @import("../style.zig");
const geometry = @import("../geometry.zig");
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
    return mouse_x < geometry.spinBoxMiddleStart(tree.getConst(handle).layout_rect);
}

pub fn clickInSpinBoxIncrement(tree: *const widget.Tree, handle: widget.NodeHandle, mouse_x: f32) bool {
    return mouse_x > geometry.spinBoxMiddleEnd(tree.getConst(handle).layout_rect);
}

fn treeDisclosureX(tree: *const widget.Tree, handle: widget.NodeHandle, theme: style.Theme) f32 {
    return geometry.treeDisclosureX(tree, handle, theme);
}

fn treeDisclosureWidth(tree: *const widget.Tree, handle: widget.NodeHandle, theme: style.Theme) f32 {
    return geometry.treeDisclosureWidth(tree, handle, theme);
}

fn treeLabelX(tree: *const widget.Tree, handle: widget.NodeHandle, theme: style.Theme) f32 {
    return geometry.treeLabelX(tree, handle, theme);
}

fn treeTextX(tree: *const widget.Tree, handle: widget.NodeHandle, theme: style.Theme) f32 {
    return geometry.treeTextX(tree, handle, theme);
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

fn spinBoxTextX(_: *const widget.Tree, _: widget.NodeHandle, node: *const widget.Node, resolved: style.ResolvedStyle, _: style.Theme) ?f32 {
    return if (node.kind.spinbox.editing) geometry.spinBoxMiddleStart(node.layout_rect) + resolved.padding.left else null;
}
