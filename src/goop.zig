//! Public Zig API surface for `goop`.
//!
//! This file intentionally contains no runtime implementation. Core
//! orchestration lives in `core/runtime.zig`; this root only names the
//! modules and everyday types callers import.

const runtime = @import("core/runtime.zig");

pub const widget = runtime.widget;
pub const event = runtime.event;
pub const style = runtime.style;
pub const paint = runtime.paint;
pub const layout = runtime.layout;
pub const hittest = runtime.hittest;

pub const Tree = runtime.Tree;
pub const NodeHandle = runtime.NodeHandle;
pub const WidgetKind = runtime.WidgetKind;
pub const WidgetDesc = runtime.WidgetDesc;
pub const WidgetView = runtime.WidgetView;
pub const NodeView = runtime.NodeView;
pub const NodeSnapshot = runtime.NodeSnapshot;
pub const TreeSnapshot = runtime.TreeSnapshot;
pub const kindFromDesc = runtime.kindFromDesc;

pub const tableHeaderRow = runtime.tableHeaderRow;
pub const tableReferenceRow = runtime.tableReferenceRow;
pub const tableRowCellCount = runtime.tableRowCellCount;
pub const tableCellAt = runtime.tableCellAt;
pub const tableResizeHandleRect = runtime.tableResizeHandleRect;
pub const tableResizeHandleIndexAtPoint = runtime.tableResizeHandleIndexAtPoint;
pub const tableHeaderCellIndexAtPoint = runtime.tableHeaderCellIndexAtPoint;
pub const tableRowSelectable = runtime.tableRowSelectable;
pub const tableDataRowIndex = runtime.tableDataRowIndex;
pub const gridSelectorItemCount = runtime.gridSelectorItemCount;
pub const gridItemAt = runtime.gridItemAt;
pub const gridItemIndex = runtime.gridItemIndex;

pub const Rect = runtime.Rect;
pub const Event = runtime.Event;
pub const Theme = runtime.Theme;
pub const Style = runtime.Style;
pub const Color = runtime.Color;
pub const PaintCommand = runtime.PaintCommand;
pub const PaintList = runtime.PaintList;
pub const PaintOptions = runtime.PaintOptions;
pub const PaintScope = runtime.PaintScope;
pub const TextAlign = runtime.TextAlign;
pub const TextOverflow = runtime.TextOverflow;
pub const IconId = runtime.IconId;
pub const TextMeasureCtx = runtime.TextMeasureCtx;
pub const MeasureTextFn = runtime.MeasureTextFn;
pub const TextDimensions = runtime.TextDimensions;

pub const Clipboard = runtime.Clipboard;
pub const SecondaryClick = runtime.SecondaryClick;
pub const TreeDrop = runtime.TreeDrop;
pub const ContainerDrop = runtime.ContainerDrop;
pub const WidgetDrop = runtime.WidgetDrop;
pub const Drop = runtime.Drop;
pub const PointerPosition = runtime.PointerPosition;
pub const FrameSnapshot = runtime.FrameSnapshot;
pub const Runtime = runtime.Runtime;
pub const Context = runtime.Context;

test {
    _ = runtime;
}
