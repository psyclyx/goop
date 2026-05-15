//! Public root module for `goop`. Re-exports the everyday primitives and
//! the sub-namespaces embedders reach into. See `goop.zig` for the
//! authoritative docstring on each.

const goop = @import("goop.zig");
const c_api = @import("c_api.zig");

comptime {
    _ = c_api;
}

pub const widget = goop.widget;
pub const event = goop.event;
pub const style = goop.style;
pub const paint = goop.paint;
pub const layout = goop.layout;
pub const hittest = goop.hittest;

pub const Tree = goop.Tree;
pub const NodeHandle = goop.NodeHandle;
pub const WidgetKind = goop.WidgetKind;
pub const WidgetDesc = goop.WidgetDesc;
pub const WidgetView = goop.WidgetView;
pub const NodeView = goop.NodeView;
pub const Event = goop.Event;
pub const Theme = goop.Theme;
pub const Style = goop.Style;
pub const Color = goop.Color;
pub const Rect = goop.Rect;
pub const PaintCommand = goop.PaintCommand;
pub const PaintList = goop.PaintList;
pub const PaintOptions = goop.PaintOptions;
pub const PaintScope = goop.PaintScope;
pub const TextAlign = goop.TextAlign;
pub const TextOverflow = goop.TextOverflow;
pub const IconId = goop.IconId;
pub const TextMeasureCtx = goop.TextMeasureCtx;
pub const MeasureTextFn = goop.MeasureTextFn;
pub const TextDimensions = goop.TextDimensions;
pub const Clipboard = goop.Clipboard;
pub const SecondaryClick = goop.SecondaryClick;
pub const TreeDrop = goop.TreeDrop;
pub const ContainerDrop = goop.ContainerDrop;
pub const WidgetDrop = goop.WidgetDrop;
pub const Drop = goop.Drop;
pub const PointerPosition = goop.PointerPosition;
pub const FrameSnapshot = goop.FrameSnapshot;
pub const Runtime = goop.Runtime;
pub const Context = goop.Context;

test {
    _ = goop;
    _ = c_api;
}
