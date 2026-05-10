const goop = @import("goop.zig");
const c_api = @import("c_api.zig");

comptime {
    _ = c_api;
}

pub const widget = goop.widget;
pub const event = goop.event;
pub const style = goop.style;
pub const draw = goop.draw;
pub const layout = goop.layout;
pub const dispatch = goop.dispatch;
pub const hittest = goop.hittest;

pub const Tree = goop.Tree;
pub const NodeHandle = goop.NodeHandle;
pub const WidgetKind = goop.WidgetKind;
pub const Event = goop.Event;
pub const Theme = goop.Theme;
pub const Style = goop.Style;
pub const Color = goop.Color;
pub const PaintCommand = goop.PaintCommand;
pub const PaintList = goop.PaintList;
pub const DrawCommand = goop.DrawCommand;
pub const DrawList = goop.DrawList;
pub const TextAlign = goop.TextAlign;
pub const TextOverflow = goop.TextOverflow;
pub const IconId = goop.IconId;
pub const TextMeasureCtx = goop.TextMeasureCtx;
pub const MeasureTextFn = goop.MeasureTextFn;
pub const TextDimensions = goop.TextDimensions;
pub const Clipboard = goop.Clipboard;
pub const SecondaryClick = goop.SecondaryClick;
pub const TreeDrop = goop.TreeDrop;
pub const GridDrop = goop.GridDrop;
pub const ListDrop = goop.ListDrop;
pub const TableDrop = goop.TableDrop;
pub const WidgetDrop = goop.WidgetDrop;
pub const Drop = goop.Drop;
pub const PointerPosition = goop.PointerPosition;
pub const SelectedChild = goop.SelectedChild;
pub const Runtime = goop.Runtime;
pub const Context = goop.Context;

test {
    _ = goop;
    _ = c_api;
}
