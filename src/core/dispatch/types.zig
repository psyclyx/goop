const widget = @import("../widget.zig");
const scrollbar = @import("../scrollbar.zig");
const control_event = @import("../control_event.zig");

pub const TreeDrop = struct {
    source: widget.NodeHandle,
    target: widget.NodeHandle,
    position: widget.WidgetKind.TreeItem.DropPosition,
};

/// A drop reported on a list-box, grid-selector, or table. The three
/// container kinds share an item/background target shape; the source
/// container kind stays distinguishable through the `Drop` union arm.
pub const ContainerDrop = struct {
    source: widget.NodeHandle,
    target: widget.NodeHandle,
    position: Position,

    pub const Position = enum {
        /// Dropped onto an item / row inside the container.
        item,
        /// Dropped onto the empty container background.
        background,
    };
};

pub const WidgetDrop = struct {
    source: widget.NodeHandle,
    target: widget.NodeHandle,
    x: f32,
    y: f32,
    ctrl_down: bool,
    shift_down: bool,
};

pub const Drop = union(enum) {
    tree: TreeDrop,
    grid: ContainerDrop,
    list: ContainerDrop,
    table: ContainerDrop,
    widget: WidgetDrop,

    pub fn source(self: Drop) widget.NodeHandle {
        return switch (self) {
            inline else => |drop| drop.source,
        };
    }

    pub fn target(self: Drop) widget.NodeHandle {
        return switch (self) {
            inline else => |drop| drop.target,
        };
    }
};

pub const ScrollbarAxis = scrollbar.Axis;

pub const MouseState = struct {
    x: f32 = 0,
    y: f32 = 0,
    left_down: bool = false,
    right_down: bool = false,
    middle_down: bool = false,
    /// The widget that the left button went down on (for click detection).
    press_target: ?widget.NodeHandle = null,
    right_press_target: ?widget.NodeHandle = null,
    /// Stable semantic element IDs captured at press time. A click spans many
    /// frames; if the tree is rebuilt in between, these let the logical press
    /// target be re-resolved instead of being lost. Null when the target has no
    /// semantic identity.
    press_target_element_id: ?widget.ElementId = null,
    right_press_target_element_id: ?widget.ElementId = null,
    press_origin_x: f32 = 0,
    press_origin_y: f32 = 0,
    press_can_defer_drag: bool = false,
    /// The widget currently being dragged, if any.
    drag_target: ?widget.NodeHandle = null,
    drag_origin_x: f32 = 0,
    drag_origin_y: f32 = 0,
    drag_origin_value: f32 = 0,
    drag_origin_secondary_value: f32 = 0,
    drag_origin_extent: f32 = 0,
    drag_column_index: ?u8 = null,
    scroll_drag_axis: ScrollbarAxis = .vertical,
    /// The currently keyboard-focused widget, if any.
    focused: ?widget.NodeHandle = null,
    /// The widget currently hovered by the pointer, if any.
    hovered: ?widget.NodeHandle = null,
    /// Set when dispatch changes widget state that affects layout.
    layout_changed: bool = false,
    /// Active tree drop preview while dragging an outline row.
    tree_drop_preview: ?TreeDrop = null,
    /// Active grid drop preview while dragging a grid item.
    grid_drop_preview: ?ContainerDrop = null,
    /// Active list drop preview while dragging a selectable row.
    list_drop_preview: ?ContainerDrop = null,
    /// Active table drop preview while dragging a table row.
    table_drop_preview: ?ContainerDrop = null,
    /// Active generic drop target while dragging an item.
    widget_drop_preview: ?WidgetDrop = null,
    /// Whether a shift key is currently held.
    shift_down: bool = false,
    /// Whether a ctrl key is currently held.
    ctrl_down: bool = false,
    /// Double-click detection state.
    last_click_time_ms: u64 = 0,
    last_click_x: f32 = 0,
    last_click_y: f32 = 0,
    /// Present only while the fallible semantic-output dispatch path runs.
    /// Capacity is reserved before each input event, so emitters never allocate.
    control_journal: ?*control_event.Journal = null,

    /// Maximum time between clicks for a double-click (milliseconds).
    pub const double_click_time_ms: u64 = 400;
    /// Maximum distance between clicks for a double-click (pixels).
    pub const double_click_dist: f32 = 5;
    /// Minimum drag distance before deferred drags activate (pixels).
    pub const drag_threshold: f32 = 4;

    pub fn emitActivation(self: *MouseState, tree: *const widget.Tree, handle: widget.NodeHandle) void {
        const journal = self.control_journal orelse return;
        const node = tree.getConst(handle);
        const element = node.element_id orelse return;
        journal.emit(.{ .activated = .{ .element = element, .action = node.action_id } });
    }

    pub fn emitSecondaryActivation(self: *MouseState, tree: *const widget.Tree, handle: widget.NodeHandle) void {
        const journal = self.control_journal orelse return;
        const node = tree.getConst(handle);
        const element = node.element_id orelse return;
        journal.emit(.{ .secondary_activated = .{
            .element = element,
            .action = node.action_id,
            .x = self.x,
            .y = self.y,
        } });
    }

    pub fn emitScalar(self: *MouseState, tree: *const widget.Tree, handle: widget.NodeHandle, value: f32) void {
        const journal = self.control_journal orelse return;
        const element = tree.elementId(handle) orelse return;
        journal.emit(.{ .value_changed = .{ .element = element, .value = .{ .scalar = value } } });
    }

    pub fn emitIndex(self: *MouseState, tree: *const widget.Tree, handle: widget.NodeHandle, value: ?u16) void {
        const journal = self.control_journal orelse return;
        const element = tree.elementId(handle) orelse return;
        journal.emit(.{ .value_changed = .{ .element = element, .value = .{ .index = value } } });
    }

    pub fn emitColumnFraction(self: *MouseState, tree: *const widget.Tree, handle: widget.NodeHandle, column: u8, fraction: f32) void {
        const journal = self.control_journal orelse return;
        const element = tree.elementId(handle) orelse return;
        journal.emit(.{ .value_changed = .{ .element = element, .value = .{ .column_fraction = .{
            .column = column,
            .fraction = fraction,
        } } } });
    }

    pub fn emitToggle(self: *MouseState, tree: *const widget.Tree, handle: widget.NodeHandle, value: bool) void {
        const journal = self.control_journal orelse return;
        const element = tree.elementId(handle) orelse return;
        journal.emit(.{ .toggle_changed = .{ .element = element, .value = value } });
    }

    pub fn emitText(self: *MouseState, tree: *const widget.Tree, handle: widget.NodeHandle, value: []const u8, committed: bool) void {
        const journal = self.control_journal orelse return;
        const element = tree.elementId(handle) orelse return;
        const span = journal.appendText(value);
        journal.emit(.{ .text_changed = .{
            .element = element,
            .text = span,
            .committed = committed,
        } });
    }

    pub fn emitSort(self: *MouseState, tree: *const widget.Tree, handle: widget.NodeHandle, column: u8, direction: widget.WidgetKind.Table.SortDirection) void {
        const journal = self.control_journal orelse return;
        const element = tree.elementId(handle) orelse return;
        journal.emit(.{ .sort_changed = .{
            .element = element,
            .column = column,
            .direction = switch (direction) {
                .ascending => .ascending,
                .descending => .descending,
            },
        } });
    }

    pub fn emitScroll(self: *MouseState, tree: *const widget.Tree, handle: widget.NodeHandle) void {
        const journal = self.control_journal orelse return;
        const element = tree.elementId(handle) orelse return;
        const scroll = tree.getConst(handle).kind.scroll_area;
        journal.emit(.{ .scroll_changed = .{
            .element = element,
            .x = scroll.scroll_x,
            .y = scroll.scroll_y,
        } });
    }

    /// Record the complete selected-ID state for a list/grid/table control.
    /// IDs are copied into retained journal storage; no node handles escape.
    pub fn emitSelection(self: *MouseState, tree: *const widget.Tree, container: widget.NodeHandle) void {
        const journal = self.control_journal orelse return;
        const element = tree.elementId(container) orelse return;
        const start = journal.beginSelection();

        var iter = tree.children(container);
        while (iter.next()) |child| {
            const child_node = tree.getConst(child);
            const selected = switch (child_node.kind) {
                .selectable => |item| item.selected,
                .grid_item => |item| item.selected,
                .table_row => |item| !item.header and item.selected,
                .tree_item => |item| item.selected,
                else => false,
            };
            if (selected) {
                if (child_node.element_id) |id| journal.appendSelected(id);
            }
        }

        journal.emit(.{ .selection_changed = .{
            .element = element,
            .selected = journal.finishSelection(start),
        } });
    }

    pub fn emitItemSelection(self: *MouseState, tree: *const widget.Tree, item: widget.NodeHandle, selected: bool) void {
        const journal = self.control_journal orelse return;
        const element = tree.elementId(item) orelse return;
        const start = journal.beginSelection();
        if (selected) journal.appendSelected(element);
        journal.emit(.{ .selection_changed = .{
            .element = element,
            .selected = journal.finishSelection(start),
        } });
    }

    pub fn emitDrop(self: *MouseState, tree: *const widget.Tree, committed: Drop) void {
        const journal = self.control_journal orelse return;
        const source = tree.elementId(committed.source()) orelse return;
        const target = tree.elementId(committed.target()) orelse return;
        const output: control_event.Drop = switch (committed) {
            .tree => |drop| .{
                .source = source,
                .target = target,
                .position = switch (drop.position) {
                    .before => .before,
                    .into => .inside,
                    .after => .after,
                },
            },
            .grid, .list, .table => |drop| .{
                .source = source,
                .target = target,
                .position = switch (drop.position) {
                    .item => .item,
                    .background => .background,
                },
            },
            .widget => |drop| .{
                .source = source,
                .target = target,
                .position = .{ .point = .{ .x = drop.x, .y = drop.y } },
                .modifiers = .{ .ctrl = drop.ctrl_down, .shift = drop.shift_down },
            },
        };
        journal.emit(.{ .drop = output });
    }

    /// Commit a drop to the semantic output journal.
    pub fn commitDrop(self: *MouseState, tree: *const widget.Tree, committed: Drop) void {
        self.emitDrop(tree, committed);
    }
};

/// Clipboard interface for copy/paste. Provided by the embedder.
pub const Clipboard = struct {
    ptr: *anyopaque,
    getTextFn: *const fn (*anyopaque) ?[]const u8,
    setTextFn: *const fn (*anyopaque, []const u8) void,

    pub fn getText(self: Clipboard) ?[]const u8 {
        return self.getTextFn(self.ptr);
    }

    pub fn setText(self: Clipboard, text: []const u8) void {
        self.setTextFn(self.ptr, text);
    }
};
