//! Public Zig API surface for `goop`.
//!
//! This file intentionally contains no runtime implementation. Core
//! orchestration lives in `core/runtime.zig`; this root only names the
//! modules and everyday types callers import.

const runtime = @import("core/runtime.zig");

pub const widget = runtime.widget;
pub const input = @import("goop_input");
pub const style = runtime.style;
pub const visual = runtime.visual;
pub const layout = runtime.layout;
pub const hittest = runtime.hittest;
pub const geometry = runtime.geometry;
pub const scrollbar = runtime.scrollbar;

pub const Tree = runtime.Tree;
pub const NodeHandle = runtime.NodeHandle;
pub const WidgetKind = runtime.WidgetKind;
pub const WidgetDesc = runtime.WidgetDesc;
pub const ControlDesc = runtime.ControlDesc;
pub const ControlIdentity = runtime.ControlIdentity;
pub const WidgetView = runtime.WidgetView;
pub const NodeView = runtime.NodeView;
pub const TextEditState = runtime.TextEditState;
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
pub const Event = input.Event;
pub const Theme = runtime.Theme;
pub const Style = runtime.Style;
pub const Color = runtime.Color;
pub const TextAlign = runtime.TextAlign;
pub const TextOverflow = runtime.TextOverflow;
pub const IconId = runtime.IconId;
pub const TextMeasureCtx = runtime.TextMeasureCtx;
pub const MeasureTextFn = runtime.MeasureTextFn;
pub const TextDimensions = runtime.TextDimensions;
pub const ElementId = runtime.ElementId;
pub const ActionId = runtime.ActionId;
pub const ControlEvent = runtime.ControlEvent;
pub const ControlEvents = runtime.ControlEvents;
pub const Activation = runtime.Activation;
pub const SecondaryActivation = runtime.SecondaryActivation;
pub const ValueChanged = runtime.ValueChanged;
pub const ToggleChanged = runtime.ToggleChanged;
pub const TextChanged = runtime.TextChanged;
pub const SortChanged = runtime.SortChanged;
pub const SelectionChanged = runtime.SelectionChanged;
pub const ScrollChanged = runtime.ScrollChanged;
pub const ControlDrop = runtime.ControlDrop;

pub const Clipboard = runtime.Clipboard;
pub const ResolvedElement = runtime.ResolvedElement;
pub const ChromeState = runtime.ChromeState;
pub const Runtime = runtime.Runtime;
pub const Context = runtime.Context;

test {
    _ = runtime;
}

test "goop and normalized input share one event identity" {
    comptime {
        if (Event != input.Event) @compileError("goop.Event must be goop_input.Event");
        if (runtime.Event != input.Event) @compileError("core dispatch must consume goop_input.Event");
        if (Event.Key != input.Key) @compileError("goop key input identity split");
        if (Event.Modifiers != input.Modifiers) @compileError("goop modifier input identity split");
        if (Event.Keycode != input.Keycode) @compileError("goop keycode input identity split");
    }
}

test "legacy occurrence and presentation surfaces stay absent" {
    comptime {
        const old_process = "processEventsWith" ++ "Output";
        const old_clear_clicks = "clearClicked" ++ "Flags";
        const old_clear_events = "clearControl" ++ "Events";
        const old_frame = "Frame" ++ "Snapshot";
        const old_tree_snapshot = "Tree" ++ "Snapshot";
        const old_node_snapshot = "Node" ++ "Snapshot";
        const legacy_overlay_setter = "setCustom" ++ "Paint";
        const legacy_identity_reader = "user" ++ "Id";
        const legacy_identity_setter = "setUser" ++ "Id";
        const legacy_identity_lookup = "findByUser" ++ "Id";

        if (@hasDecl(Runtime, old_process) or @hasDecl(Context, old_process)) @compileError("semantic processing has one canonical name");
        if (@hasDecl(Runtime, old_clear_clicks) or @hasDecl(Context, old_clear_clicks)) @compileError("retained click polling returned");
        if (@hasDecl(Runtime, old_clear_events) or @hasDecl(Context, old_clear_events)) @compileError("manual semantic-journal clearing returned");
        if (@hasDecl(runtime, old_frame)) @compileError("handle-bearing frame snapshot returned");
        if (@hasDecl(widget, old_tree_snapshot) or @hasDecl(widget, old_node_snapshot)) @compileError("handle-bearing tree snapshot returned");
        if (@hasDecl(Runtime, legacy_overlay_setter) or @hasDecl(Context, legacy_overlay_setter)) @compileError("standard-control paint overlay returned");
        if (@hasDecl(Tree, legacy_identity_reader) or @hasDecl(Tree, legacy_identity_setter) or @hasDecl(Tree, legacy_identity_lookup)) @compileError("parallel identity vocabulary returned");

        const Interaction = widget.InteractionState;
        if (@hasField(Interaction, "primary_" ++ "clicked")) @compileError("primary occurrence stored on a node");
        if (@hasField(Interaction, "secondary_" ++ "clicked")) @compileError("secondary occurrence stored on a node");
        if (@hasField(Interaction, "drop_" ++ "received")) @compileError("drop occurrence stored on a node");
        if (@hasField(Interaction, "changed") or @hasField(Interaction, "toggled")) @compileError("change occurrence stored on a node");
        if (@hasField(widget.Node, "custom_" ++ "paint")) @compileError("standard-control paint policy stored in core");
        if (@hasField(WidgetView.TreeItem, "rename_" ++ "committed")) @compileError("rename occurrence stored in the read model");
        if (@hasField(WidgetView.Table, "resized_" ++ "column")) @compileError("resize occurrence stored in the read model");
        if (@hasField(WidgetView.Table, "sort_" ++ "changed")) @compileError("sort occurrence stored in the read model");
        if (@hasField(WidgetView.Table, "selection_" ++ "changed")) @compileError("selection occurrence stored in the read model");
    }
}
