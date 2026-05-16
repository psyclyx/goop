const widget = @import("../widget.zig");

/// Transient input state tracked across events.
pub const SecondaryClick = struct {
    target: widget.NodeHandle,
    x: f32,
    y: f32,
};

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

pub const ScrollbarAxis = enum { vertical, horizontal };

pub const MouseState = struct {
    x: f32 = 0,
    y: f32 = 0,
    left_down: bool = false,
    right_down: bool = false,
    middle_down: bool = false,
    /// The widget that the left button went down on (for click detection).
    press_target: ?widget.NodeHandle = null,
    right_press_target: ?widget.NodeHandle = null,
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
    /// The most recent secondary click observed this frame.
    last_secondary_click: ?SecondaryClick = null,
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
    /// The most recent completed drop committed this frame.
    last_drop: ?Drop = null,
    /// Whether a shift key is currently held.
    shift_down: bool = false,
    /// Whether a ctrl key is currently held.
    ctrl_down: bool = false,
    /// Double-click detection state.
    last_click_time_ms: u64 = 0,
    last_click_x: f32 = 0,
    last_click_y: f32 = 0,

    /// Maximum time between clicks for a double-click (milliseconds).
    pub const double_click_time_ms: u64 = 400;
    /// Maximum distance between clicks for a double-click (pixels).
    pub const double_click_dist: f32 = 5;
    /// Minimum drag distance before deferred drags activate (pixels).
    pub const drag_threshold: f32 = 4;
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
