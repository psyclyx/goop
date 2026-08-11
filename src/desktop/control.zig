//! Pure constructors for common core control descriptions.
//!
//! These helpers only remove the repeated identity/widget envelope. They do
//! not retain nodes, mutate a context, install callbacks, or own children.

const std = @import("std");
const goop = @import("goop");

pub const ElementId = goop.ElementId;
pub const ActionId = goop.ActionId;
pub const ControlDesc = goop.ControlDesc;
pub const WidgetDesc = goop.WidgetDesc;

pub fn button(element: ElementId, action: ?ActionId, description: WidgetDesc.Button) ControlDesc {
    return describe(element, action, .{ .button = description });
}

pub fn menuItem(element: ElementId, action: ?ActionId, description: WidgetDesc.MenuItem) ControlDesc {
    return describe(element, action, .{ .menu_item = description });
}

pub fn toggle(element: ElementId, action: ?ActionId, description: WidgetDesc.Checkbox) ControlDesc {
    return describe(element, action, .{ .checkbox = description });
}

pub fn textInput(element: ElementId, action: ?ActionId, description: WidgetDesc.TextInput) ControlDesc {
    return describe(element, action, .{ .text_input = description });
}

/// Describe a list-box selection owner. Item descriptions remain separate
/// because the caller owns item identity and tree structure.
pub fn selection(element: ElementId, action: ?ActionId, description: WidgetDesc.ListBox) ControlDesc {
    return describe(element, action, .{ .list_box = description });
}

pub fn table(element: ElementId, action: ?ActionId, description: WidgetDesc.Table) ControlDesc {
    return describe(element, action, .{ .table = description });
}

pub fn split(element: ElementId, action: ?ActionId, description: WidgetDesc.Splitter) ControlDesc {
    return describe(element, action, .{ .splitter = description });
}

/// Attach semantic identity to any exact core widget description.
pub fn describe(element: ElementId, action: ?ActionId, widget: WidgetDesc) ControlDesc {
    return .{
        .identity = .{ .element_id = element, .action_id = action },
        .widget = widget,
    };
}

test "constructors return exact core descriptions" {
    comptime {
        if (ControlDesc != goop.ControlDesc) @compileError("desktop controls must return core ControlDesc");
        if (WidgetDesc != goop.WidgetDesc) @compileError("desktop controls must contain core WidgetDesc");
    }

    const open = button(.init(1), .init(2), .{ .label = "Open" });
    try std.testing.expectEqual(ElementId.init(1), open.identity.element_id);
    try std.testing.expectEqual(ActionId.init(2), open.identity.action_id.?);
    try std.testing.expectEqualStrings("Open", open.widget.button.label);

    const chooser = selection(.init(3), null, .{ .selection_mode = .multiple });
    try std.testing.expect(chooser.widget.list_box.selection_mode == .multiple);

    const divider = split(.init(4), null, .{ .ratio = 0.25 });
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), divider.widget.splitter.ratio, 0.0001);
}

test "constructors expose no retained handles or callbacks" {
    comptime {
        if (@hasDecl(@This(), "NodeHandle")) @compileError("control descriptions must not expose handles");
        if (@hasDecl(@This(), "Callback")) @compileError("control descriptions must not expose callbacks");
        if (@hasDecl(@This(), "Context")) @compileError("constructors must not mutate a context");
    }
}
