const std = @import("std");
const c = @cImport({
    @cInclude("clay.h");
});

pub const widget = @import("core/widget.zig");
pub const event = @import("core/event.zig");
pub const style = @import("core/style.zig");
pub const draw = @import("core/draw.zig");
pub const layout = @import("core/layout.zig");
pub const dispatch = @import("core/dispatch.zig");
pub const hittest = @import("core/hittest.zig");

pub const Tree = widget.Tree;
pub const NodeHandle = widget.NodeHandle;
pub const WidgetKind = widget.WidgetKind;
pub const Event = event.Event;
pub const Theme = style.Theme;
pub const Style = style.Style;
pub const Color = style.Color;
pub const PaintCommand = draw.PaintCommand;
pub const PaintList = draw.PaintList;
pub const DrawCommand = draw.DrawCommand;
pub const DrawList = draw.DrawList;
pub const TextAlign = draw.TextAlign;
pub const TextOverflow = draw.TextOverflow;
pub const IconKind = draw.IconKind;
pub const TextMeasureCtx = layout.TextMeasureCtx;
pub const MeasureTextFn = layout.MeasureTextFn;
pub const TextDimensions = layout.TextDimensions;

pub const Clipboard = dispatch.Clipboard;
pub const SecondaryClick = dispatch.SecondaryClick;
pub const TreeDrop = dispatch.TreeDrop;
pub const GridDrop = dispatch.GridDrop;
pub const ListDrop = dispatch.ListDrop;
pub const TableDrop = dispatch.TableDrop;
pub const WidgetDrop = dispatch.WidgetDrop;
pub const Drop = dispatch.Drop;

pub const PointerPosition = struct {
    x: f32,
    y: f32,
};

pub const SelectedChild = struct {
    handle: NodeHandle,
    index: u16,
    user_id: u64,
};

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    clay_arena: []u8,
    clay_context: *c.Clay_Context,
    events: std.ArrayListUnmanaged(Event),
    mouse: dispatch.MouseState = .{},
    text_measure_ctx: ?*const TextMeasureCtx = null,
    layout_dirty: bool = true,
    draw_dirty: bool = true,
    last_node_count: u32 = 0,
    cached_paint_list: ?PaintList = null,
    cached_draw_list: ?DrawList = null,

    pub fn init(allocator: std.mem.Allocator, opts: InitOptions) !Runtime {
        const min_memory = c.Clay_MinMemorySize();
        const arena = try allocator.alloc(u8, min_memory);
        const clay_arena = c.Clay_Arena{
            .capacity = min_memory,
            .memory = arena.ptr,
        };
        const clay_context = c.Clay_Initialize(clay_arena, .{
            .width = @floatFromInt(opts.width),
            .height = @floatFromInt(opts.height),
        }, .{}) orelse return error.OutOfMemory;
        return .{
            .allocator = allocator,
            .clay_arena = arena,
            .clay_context = clay_context,
            .events = .empty,
        };
    }

    pub fn deinit(self: *Runtime) void {
        self.invalidateDrawCache();
        self.events.deinit(self.allocator);
        if (c.Clay_GetCurrentContext() == self.clay_context) {
            c.Clay_SetCurrentContext(null);
        }
        self.allocator.free(self.clay_arena);
    }

    /// Queue an input event for processing.
    pub fn pushEvent(self: *Runtime, ev: Event) !void {
        switch (ev) {
            .mouse_move => |move| {
                if (self.events.items.len > 0) {
                    const last = &self.events.items[self.events.items.len - 1];
                    switch (last.*) {
                        .mouse_move => {
                            last.* = .{ .mouse_move = move };
                            return;
                        },
                        else => {},
                    }
                }
            },
            .mouse_scroll => |scroll| {
                if (self.events.items.len > 0) {
                    const last = &self.events.items[self.events.items.len - 1];
                    switch (last.*) {
                        .mouse_scroll => |*queued| {
                            queued.dx += scroll.dx;
                            queued.dy += scroll.dy;
                            return;
                        },
                        else => {},
                    }
                }
            },
            else => {},
        }
        try self.events.append(self.allocator, ev);
    }

    /// Mark cached layout and draw output stale after caller-owned state changes.
    pub fn invalidate(self: *Runtime) void {
        self.layout_dirty = true;
        self.draw_dirty = true;
    }

    /// Process all queued events: hit test, update interaction state,
    /// detect clicks. Call after doLayout. Marks layout dirty if any
    /// events could affect layout (text input, scroll, resize).
    pub fn processEvents(self: *Runtime, tree: *Tree, theme: Theme, clipboard: ?Clipboard) void {
        self.mouse.layout_changed = false;
        for (self.events.items) |ev| {
            switch (ev) {
                .key, .text, .mouse_button, .mouse_scroll, .resize => {
                    self.layout_dirty = true;
                    break;
                },
                else => {},
            }
        }
        if (self.events.items.len > 0) self.draw_dirty = true;
        dispatch.processWithClipboard(tree, self.events.items, &self.mouse, theme, clipboard, self.text_measure_ctx);
        if (self.layout_dirty or self.mouse.layout_changed) {
            const previous = self.bindClayContext();
            defer c.Clay_SetCurrentContext(previous);
            layout.run(tree, theme, self.text_measure_ctx);
            self.layout_dirty = false;
            self.draw_dirty = true;
            self.last_node_count = tree.count();
            self.mouse.layout_changed = false;
        }
        self.events.clearRetainingCapacity();
    }

    /// Clear transient activation/change flags. Call at the start of each
    /// frame so clicks, toggles, and selection changes are only observed
    /// for one frame.
    pub fn clearClickedFlags(self: *Runtime, tree: *Tree) void {
        self.mouse.last_secondary_click = null;
        self.mouse.last_tree_drop = null;
        self.mouse.last_grid_drop = null;
        self.mouse.last_list_drop = null;
        self.mouse.last_table_drop = null;
        self.mouse.last_widget_drop = null;
        self.mouse.last_drop = null;
        for (tree.nodes.items) |*node| {
            if (!node.alive) continue;
            node.interaction.primary_clicked = false;
            node.interaction.secondary_clicked = false;
            node.interaction.drop_received = false;
            switch (node.kind) {
                .button => {
                    node.kind.button.clicked = false;
                },
                .checkbox => {
                    node.kind.checkbox.clicked = false;
                },
                .radio_button => {
                    node.kind.radio_button.clicked = false;
                },
                .tree_item => |*tree_item| {
                    tree_item.clicked = false;
                    tree_item.toggled = false;
                    tree_item.drop_received = false;
                    tree_item.rename_committed = false;
                },
                .dropdown => |*dropdown| {
                    dropdown.clicked = false;
                    dropdown.changed = false;
                },
                .list_box => |*list_box| {
                    list_box.changed = false;
                },
                .selectable => |*selectable| {
                    selectable.clicked = false;
                },
                .grid_selector => |*grid_selector| {
                    grid_selector.changed = false;
                },
                .grid_item => |*grid_item| {
                    grid_item.clicked = false;
                },
                .table => |*table| {
                    table.changed = false;
                    table.resized_column = null;
                    table.sort_changed = false;
                    table.selection_changed = false;
                },
                .menu => |*menu| {
                    menu.clicked = false;
                },
                .menu_item => {
                    node.kind.menu_item.clicked = false;
                },
                .drag_value => |*drag_value| {
                    drag_value.changed = false;
                },
                .spinbox => |*spinbox| {
                    spinbox.changed = false;
                },
                .tab_item => |*tab_item| {
                    tab_item.clicked = false;
                },
                .splitter => |*splitter| {
                    splitter.changed = false;
                },
                else => {},
            }
        }
    }

    /// Check if a widget was activated with the primary button this frame.
    pub fn wasClicked(_: *const Runtime, tree: *const Tree, handle: NodeHandle) bool {
        return tree.getConst(handle).interaction.primary_clicked;
    }

    /// Check if a widget was activated with the secondary button this frame.
    pub fn wasSecondaryClicked(_: *const Runtime, tree: *const Tree, handle: NodeHandle) bool {
        return tree.getConst(handle).interaction.secondary_clicked;
    }

    /// Get the most recent secondary click that occurred this frame, if any.
    pub fn lastSecondaryClick(self: *const Runtime) ?SecondaryClick {
        return self.mouse.last_secondary_click;
    }

    /// Get the most recent completed tree-item drop that occurred this frame, if any.
    pub fn lastTreeDrop(self: *const Runtime) ?TreeDrop {
        return self.mouse.last_tree_drop;
    }

    /// Get the most recent completed grid-item drop that occurred this frame, if any.
    pub fn lastGridDrop(self: *const Runtime) ?GridDrop {
        return self.mouse.last_grid_drop;
    }

    /// Get the most recent completed list-box drop that occurred this frame, if any.
    pub fn lastListDrop(self: *const Runtime) ?ListDrop {
        return self.mouse.last_list_drop;
    }

    /// Get the most recent completed table-row drop that occurred this frame, if any.
    pub fn lastTableDrop(self: *const Runtime) ?TableDrop {
        return self.mouse.last_table_drop;
    }

    /// Get the most recent generic widget drop that occurred this frame, if any.
    pub fn lastWidgetDrop(self: *const Runtime) ?WidgetDrop {
        return self.mouse.last_widget_drop;
    }

    /// Get the most recent completed drop that occurred this frame, if any.
    pub fn lastDrop(self: *const Runtime) ?Drop {
        return self.mouse.last_drop;
    }

    /// Get the timestamp from the most recent primary-button press event.
    pub fn lastPrimaryPressTimestampMs(self: *const Runtime) u64 {
        return self.mouse.last_click_time_ms;
    }

    /// Get the current pointer position in context coordinates.
    pub fn pointerPosition(self: *const Runtime) PointerPosition {
        return .{ .x = self.mouse.x, .y = self.mouse.y };
    }

    /// Check whether a pointer button is currently held.
    pub fn isPointerButtonDown(self: *const Runtime, button: Event.MouseButton.Button) bool {
        return switch (button) {
            .left => self.mouse.left_down,
            .right => self.mouse.right_down,
            .middle => self.mouse.middle_down,
        };
    }

    /// Get the widget currently being dragged, if any.
    pub fn activeDragSource(self: *const Runtime) ?NodeHandle {
        return self.mouse.drag_target;
    }

    /// Get the currently focused widget, if it is still alive.
    pub fn focusedWidget(self: *const Runtime, tree: *const Tree) ?NodeHandle {
        if (self.mouse.focused) |handle| {
            if (tree.isAlive(handle)) return handle;
        }
        return null;
    }

    /// Set keyboard focus to a live widget.
    pub fn focusWidget(self: *Runtime, tree: *Tree, handle: NodeHandle) bool {
        if (!tree.isAlive(handle)) {
            self.clearFocus(tree);
            return false;
        }
        for (tree.nodes.items) |*node| {
            if (node.alive) node.interaction.focused = false;
        }
        tree.get(handle).interaction.focused = true;
        self.mouse.focused = handle;
        self.draw_dirty = true;
        return true;
    }

    /// Clear keyboard focus.
    pub fn clearFocus(self: *Runtime, tree: *Tree) void {
        for (tree.nodes.items) |*node| {
            if (node.alive) node.interaction.focused = false;
        }
        self.mouse.focused = null;
        self.draw_dirty = true;
    }

    /// Cancel the active pointer gesture, clearing any drag or marquee state.
    pub fn cancelPointerGesture(self: *Runtime, tree: *Tree) void {
        dispatch.cancelPointerGesture(tree, &self.mouse);
        self.draw_dirty = true;
    }

    /// Remove a widget and its entire subtree from the tree.
    /// The handle becomes invalid after this call.
    pub fn removeWidget(self: *Runtime, tree: *Tree, handle: NodeHandle) !void {
        self.invalidate();
        try tree.remove(handle);
    }

    /// Check whether a handle still refers to a living widget.
    pub fn isAlive(_: *const Runtime, tree: *const Tree, handle: NodeHandle) bool {
        return tree.isAlive(handle);
    }

    /// Attach an application-defined stable identifier to a widget.
    pub fn setUserId(_: *Runtime, tree: *Tree, handle: NodeHandle, user_id: u64) void {
        if (!tree.isAlive(handle)) return;
        tree.get(handle).user_id = user_id;
    }

    /// Get an application-defined stable identifier attached to a widget.
    pub fn userId(_: *const Runtime, tree: *const Tree, handle: NodeHandle) u64 {
        if (!tree.isAlive(handle)) return 0;
        return tree.getConst(handle).user_id;
    }

    /// Run layout: walk the widget tree through clay and write back rects.
    /// Skips the full clay pass if nothing layout-affecting has changed.
    /// Pass a TextMeasureCtx for accurate snail-based text measurement,
    /// or null to use a rough character-width approximation.
    pub fn doLayout(self: *Runtime, tree: *Tree, theme: Theme, text_ctx: ?*const TextMeasureCtx) void {
        self.text_measure_ctx = text_ctx;
        const current_count = tree.count();
        if (!self.layout_dirty and current_count == self.last_node_count) return;
        const previous = self.bindClayContext();
        defer c.Clay_SetCurrentContext(previous);
        layout.run(tree, theme, text_ctx);
        self.layout_dirty = false;
        self.draw_dirty = true;
        self.last_node_count = current_count;
    }

    /// Generate draw commands from the laid-out widget tree.
    /// Returns a cached list when nothing has changed. Caller must
    /// call freeDrawList when done — cached lists are ref-shared and
    /// only freed when the cache is invalidated or the context is deinited.
    pub fn generateDrawList(self: *Runtime, tree: *const Tree, theme: Theme) !DrawList {
        if (!self.draw_dirty) {
            if (self.cached_draw_list) |cached| return cached;
        }
        const paint_list = try self.generatePaintList(tree, theme);
        if (self.cached_draw_list) |cached| return cached;
        const dl = try draw.lowerPaintList(paint_list, self.allocator, self.text_measure_ctx);
        self.cached_draw_list = dl;
        self.draw_dirty = false;
        return dl;
    }

    pub fn generatePaintList(self: *Runtime, tree: *const Tree, theme: Theme) !PaintList {
        if (!self.draw_dirty) {
            if (self.cached_paint_list) |cached| return cached;
        }
        self.invalidateDrawCache();
        const paint_list = try draw.generatePaint(tree, theme, self.allocator, self.text_measure_ctx);
        self.cached_paint_list = paint_list;
        self.draw_dirty = false;
        return paint_list;
    }

    /// Free a DrawList returned by generateDrawList.
    /// This is a no-op — the Context owns the draw list memory and
    /// manages its lifetime internally. Retained for API compatibility.
    pub fn freeDrawList(_: *Runtime, _: *DrawList) void {}

    pub fn freePaintList(_: *Runtime, _: *PaintList) void {}

    /// Invalidate and free the cached draw list.
    fn invalidateDrawCache(self: *Runtime) void {
        if (self.cached_paint_list) |*cached| {
            draw.freePaintList(cached, self.allocator);
            self.cached_paint_list = null;
        }
        if (self.cached_draw_list) |*cached| {
            draw.freeDrawList(cached, self.allocator);
            self.cached_draw_list = null;
        }
        self.draw_dirty = true;
    }

    /// Update layout dimensions (e.g. on window resize).
    pub fn setDimensions(self: *Runtime, width: u32, height: u32) void {
        self.layout_dirty = true;
        const previous = self.bindClayContext();
        defer c.Clay_SetCurrentContext(previous);
        c.Clay_SetLayoutDimensions(.{
            .width = @floatFromInt(width),
            .height = @floatFromInt(height),
        });
    }

    fn bindClayContext(self: *Runtime) ?*c.Clay_Context {
        const previous = c.Clay_GetCurrentContext();
        if (previous != self.clay_context) c.Clay_SetCurrentContext(self.clay_context);
        return previous;
    }

    pub const InitOptions = struct {
        width: u32 = 800,
        height: u32 = 600,
    };
};

pub const Context = struct {
    tree: Tree,
    theme: Theme,
    runtime: Runtime,
    clipboard: ?Clipboard = null,

    pub fn init(allocator: std.mem.Allocator, opts: InitOptions) !Context {
        return .{
            .tree = Tree.init(allocator),
            .theme = opts.theme,
            .runtime = try Runtime.init(allocator, .{
                .width = opts.width,
                .height = opts.height,
            }),
        };
    }

    pub fn deinit(self: *Context) void {
        self.runtime.deinit();
        self.tree.deinit();
    }

    pub fn invalidate(self: *Context) void {
        self.runtime.invalidate();
    }

    /// Queue an input event for processing.
    pub fn pushEvent(self: *Context, ev: Event) !void {
        try self.runtime.pushEvent(ev);
    }

    /// Process all queued events: hit test, update interaction state,
    /// detect clicks. Call after doLayout.
    pub fn processEvents(self: *Context) void {
        self.runtime.processEvents(&self.tree, self.theme, self.clipboard);
    }

    /// Clear transient activation/change flags. Call at the start of each
    /// frame so clicks, toggles, and selection changes are only observed
    /// for one frame.
    pub fn clearClickedFlags(self: *Context) void {
        self.runtime.clearClickedFlags(&self.tree);
    }

    /// Attach an application-defined stable identifier to a widget.
    pub fn setUserId(self: *Context, handle: NodeHandle, user_id: u64) void {
        self.runtime.setUserId(&self.tree, handle, user_id);
    }

    /// Get an application-defined stable identifier attached to a widget.
    pub fn userId(self: *const Context, handle: NodeHandle) u64 {
        return self.runtime.userId(&self.tree, handle);
    }

    /// Mark a widget as a generic drop target for active item drags.
    pub fn setDropTarget(self: *Context, handle: NodeHandle, accepts_drop: bool) void {
        if (!self.tree.isAlive(handle)) return;
        self.tree.get(handle).interaction.accepts_drop = accepts_drop;
    }

    /// Check whether a generic drop is currently hovering this widget.
    pub fn isDropHovered(self: *const Context, handle: NodeHandle) bool {
        if (!self.tree.isAlive(handle)) return false;
        return self.tree.getConst(handle).interaction.drop_hovered;
    }

    /// Get the current pointer position in context coordinates.
    pub fn pointerPosition(self: *const Context) PointerPosition {
        return self.runtime.pointerPosition();
    }

    /// Check whether a pointer button is currently held.
    pub fn isPointerButtonDown(self: *const Context, button: Event.MouseButton.Button) bool {
        return self.runtime.isPointerButtonDown(button);
    }

    /// Get the widget currently being dragged, if any.
    pub fn activeDragSource(self: *const Context) ?NodeHandle {
        return self.runtime.activeDragSource();
    }

    /// Get the currently focused widget, if it is still alive.
    pub fn focusedWidget(self: *const Context) ?NodeHandle {
        return self.runtime.focusedWidget(&self.tree);
    }

    /// Set keyboard focus to a live widget.
    pub fn focusWidget(self: *Context, handle: NodeHandle) bool {
        return self.runtime.focusWidget(&self.tree, handle);
    }

    /// Clear keyboard focus.
    pub fn clearFocus(self: *Context) void {
        self.runtime.clearFocus(&self.tree);
    }

    /// Cancel the active pointer gesture, clearing any drag or marquee state.
    pub fn cancelPointerGesture(self: *Context) void {
        self.runtime.cancelPointerGesture(&self.tree);
    }

    /// Check if a widget was activated with the primary button this frame.
    pub fn wasClicked(self: *const Context, handle: NodeHandle) bool {
        return self.runtime.wasClicked(&self.tree, handle);
    }

    /// Check if a widget was activated with the secondary button this frame.
    pub fn wasSecondaryClicked(self: *const Context, handle: NodeHandle) bool {
        return self.runtime.wasSecondaryClicked(&self.tree, handle);
    }

    /// Check if a checkbox is currently checked.
    pub fn isChecked(self: *const Context, handle: NodeHandle) bool {
        const node = self.tree.getConst(handle);
        return switch (node.kind) {
            .checkbox => node.kind.checkbox.checked,
            .menu_item => node.kind.menu_item.checked,
            else => false,
        };
    }

    /// Check if a radio button is currently selected.
    pub fn isSelected(self: *const Context, handle: NodeHandle) bool {
        const node = self.tree.getConst(handle);
        return switch (node.kind) {
            .radio_button => node.kind.radio_button.selected,
            .tree_item => node.kind.tree_item.selected,
            .selectable => node.kind.selectable.selected,
            .grid_item => node.kind.grid_item.selected,
            .table_row => node.kind.table_row.selected,
            .tab_item => node.kind.tab_item.selected,
            else => false,
        };
    }

    /// Check whether a tree item is currently expanded.
    pub fn isExpanded(self: *const Context, handle: NodeHandle) bool {
        return self.tree.getConst(handle).kind.tree_item.expanded;
    }

    /// Check whether a tree item toggled this frame.
    pub fn treeItemToggled(self: *const Context, handle: NodeHandle) bool {
        return self.tree.getConst(handle).kind.tree_item.toggled;
    }

    /// Get the current label content of a tree item.
    pub fn treeItemLabel(self: *const Context, handle: NodeHandle) []const u8 {
        return self.tree.getConst(handle).kind.tree_item.label;
    }

    /// Check whether a tree item is currently in inline rename mode.
    pub fn treeItemEditing(self: *const Context, handle: NodeHandle) bool {
        return self.tree.getConst(handle).kind.tree_item.editing;
    }

    /// Check whether a tree item committed a rename this frame.
    pub fn treeItemRenameCommitted(self: *const Context, handle: NodeHandle) bool {
        return self.tree.getConst(handle).kind.tree_item.rename_committed;
    }

    /// Get the current value of a slider.
    pub fn sliderValue(self: *const Context, handle: NodeHandle) f32 {
        return self.tree.getConst(handle).kind.slider.value;
    }

    /// Get the current value of a drag value widget.
    pub fn dragValue(self: *const Context, handle: NodeHandle) f32 {
        return self.tree.getConst(handle).kind.drag_value.value;
    }

    /// Check whether a drag value changed this frame.
    pub fn dragValueChanged(self: *const Context, handle: NodeHandle) bool {
        return self.tree.getConst(handle).kind.drag_value.changed;
    }

    /// Get the current value of a spinbox.
    pub fn spinboxValue(self: *const Context, handle: NodeHandle) f32 {
        return self.tree.getConst(handle).kind.spinbox.value;
    }

    /// Check whether a spinbox changed this frame.
    pub fn spinboxChanged(self: *const Context, handle: NodeHandle) bool {
        return self.tree.getConst(handle).kind.spinbox.changed;
    }

    /// Get the current ratio of a splitter.
    pub fn splitterRatio(self: *const Context, handle: NodeHandle) f32 {
        return self.tree.getConst(handle).kind.splitter.ratio;
    }

    /// Check whether a splitter changed this frame.
    pub fn splitterChanged(self: *const Context, handle: NodeHandle) bool {
        return self.tree.getConst(handle).kind.splitter.changed;
    }

    /// Get the current text content of a text input.
    pub fn textInputValue(self: *const Context, handle: NodeHandle) []const u8 {
        return self.tree.getConst(handle).kind.text_input.content();
    }

    /// Get the current selected text of a dropdown.
    pub fn dropdownValue(self: *const Context, handle: NodeHandle) []const u8 {
        return self.tree.getConst(handle).kind.dropdown.selected_text;
    }

    /// Get the selected item index of a dropdown, if any.
    pub fn dropdownSelectedIndex(self: *const Context, handle: NodeHandle) ?u16 {
        return self.tree.getConst(handle).kind.dropdown.selected_index;
    }

    /// Check whether a dropdown selection changed this frame.
    pub fn dropdownChanged(self: *const Context, handle: NodeHandle) bool {
        return self.tree.getConst(handle).kind.dropdown.changed;
    }

    /// Get the selected direct child index of a list box, if any.
    pub fn listBoxSelectedIndex(self: *const Context, handle: NodeHandle) ?u16 {
        var index: u16 = 0;
        var iter = self.tree.children(handle);
        while (iter.next()) |child| {
            if (self.tree.getConst(child).kind != .selectable) continue;
            if (self.tree.getConst(child).kind.selectable.selected) return index;
            index += 1;
        }
        return null;
    }

    /// Check whether a list box selection changed this frame.
    pub fn listBoxChanged(self: *const Context, handle: NodeHandle) bool {
        return self.tree.getConst(handle).kind.list_box.changed;
    }

    /// Count selected direct child rows in a list box.
    pub fn listBoxSelectionCount(self: *const Context, handle: NodeHandle) u16 {
        var count: u16 = 0;
        var iter = self.tree.children(handle);
        while (iter.next()) |child| {
            if (self.tree.getConst(child).kind != .selectable) continue;
            if (self.tree.getConst(child).kind.selectable.selected) count += 1;
        }
        return count;
    }

    /// Get the selected direct child at the given selected ordinal.
    ///
    /// For list boxes and grid selectors, index counts selectable/grid-item
    /// children. For tables, index counts non-header rows.
    pub fn selectedChild(self: *const Context, handle: NodeHandle, selected_ordinal: u16) ?SelectedChild {
        if (!self.tree.isAlive(handle)) return null;
        const parent_kind = self.tree.getConst(handle).kind;
        var child_index: u16 = 0;
        var selected_index: u16 = 0;
        var iter = self.tree.children(handle);
        while (iter.next()) |child| {
            const node = self.tree.getConst(child);
            const selected = switch (parent_kind) {
                .list_box => blk: {
                    if (node.kind != .selectable) continue;
                    break :blk node.kind.selectable.selected;
                },
                .grid_selector => blk: {
                    if (node.kind != .grid_item) continue;
                    break :blk node.kind.grid_item.selected;
                },
                .table => blk: {
                    if (node.kind != .table_row or node.kind.table_row.header) continue;
                    break :blk node.kind.table_row.selected;
                },
                else => return null,
            };
            if (selected) {
                if (selected_index == selected_ordinal) {
                    return .{
                        .handle = child,
                        .index = child_index,
                        .user_id = node.user_id,
                    };
                }
                selected_index += 1;
            }
            child_index += 1;
        }
        return null;
    }

    /// Get the direct child index at the given selected ordinal.
    pub fn selectedChildIndex(self: *const Context, handle: NodeHandle, selected_ordinal: u16) ?u16 {
        const child = self.selectedChild(handle, selected_ordinal) orelse return null;
        return child.index;
    }

    /// Get the selected direct child index of a grid selector, if any.
    pub fn gridSelectorSelectedIndex(self: *const Context, handle: NodeHandle) ?u16 {
        var index: u16 = 0;
        var iter = self.tree.children(handle);
        while (iter.next()) |child| {
            if (self.tree.getConst(child).kind != .grid_item) continue;
            if (self.tree.getConst(child).kind.grid_item.selected) return index;
            index += 1;
        }
        return null;
    }

    /// Check whether a grid selector selection changed this frame.
    pub fn gridSelectorChanged(self: *const Context, handle: NodeHandle) bool {
        return self.tree.getConst(handle).kind.grid_selector.changed;
    }

    /// Count selected direct child tiles in a grid selector.
    pub fn gridSelectorSelectionCount(self: *const Context, handle: NodeHandle) u16 {
        var count: u16 = 0;
        var iter = self.tree.children(handle);
        while (iter.next()) |child| {
            if (self.tree.getConst(child).kind != .grid_item) continue;
            if (self.tree.getConst(child).kind.grid_item.selected) count += 1;
        }
        return count;
    }

    /// Get the retained width fraction for a table column, if present.
    pub fn tableColumnFraction(self: *const Context, handle: NodeHandle, index: u8) ?f32 {
        return self.tree.getConst(handle).kind.table.columnWeight(index);
    }

    /// Check whether a table resized this frame.
    pub fn tableChanged(self: *const Context, handle: NodeHandle) bool {
        return self.tree.getConst(handle).kind.table.changed;
    }

    /// Get the divider index that was resized this frame, if any.
    pub fn tableResizedColumn(self: *const Context, handle: NodeHandle) ?u8 {
        return self.tree.getConst(handle).kind.table.resized_column;
    }

    /// Get the currently sorted table column, if any.
    pub fn tableSortedColumn(self: *const Context, handle: NodeHandle) ?u8 {
        return self.tree.getConst(handle).kind.table.sorted_column;
    }

    /// Get the current table sort direction, if sorting is active.
    pub fn tableSortDirection(self: *const Context, handle: NodeHandle) ?widget.WidgetKind.Table.SortDirection {
        const table = self.tree.getConst(handle).kind.table;
        if (table.sorted_column == null) return null;
        return table.sort_direction;
    }

    /// Check whether table sorting changed this frame.
    pub fn tableSortChanged(self: *const Context, handle: NodeHandle) bool {
        return self.tree.getConst(handle).kind.table.sort_changed;
    }

    /// Check whether table row selection changed this frame.
    pub fn tableSelectionChanged(self: *const Context, handle: NodeHandle) bool {
        return self.tree.getConst(handle).kind.table.selection_changed;
    }

    /// Count selected non-header rows in a table.
    pub fn tableSelectionCount(self: *const Context, handle: NodeHandle) u16 {
        var count: u16 = 0;
        var iter = self.tree.children(handle);
        while (iter.next()) |child| {
            const node = self.tree.getConst(child);
            if (node.kind != .table_row or node.kind.table_row.header) continue;
            if (node.kind.table_row.selected) count += 1;
        }
        return count;
    }

    /// Get the first selected non-header row index in a table, if any.
    pub fn tableSelectedRowIndex(self: *const Context, handle: NodeHandle) ?u16 {
        var index: u16 = 0;
        var iter = self.tree.children(handle);
        while (iter.next()) |child| {
            const node = self.tree.getConst(child);
            if (node.kind != .table_row or node.kind.table_row.header) continue;
            if (node.kind.table_row.selected) return index;
            index += 1;
        }
        return null;
    }

    /// Get the most recent secondary click that occurred this frame, if any.
    pub fn lastSecondaryClick(self: *const Context) ?SecondaryClick {
        return self.runtime.lastSecondaryClick();
    }

    /// Get the most recent completed tree-item drop that occurred this frame, if any.
    pub fn lastTreeDrop(self: *const Context) ?TreeDrop {
        return self.runtime.lastTreeDrop();
    }

    /// Get the most recent completed grid-item drop that occurred this frame, if any.
    pub fn lastGridDrop(self: *const Context) ?GridDrop {
        return self.runtime.lastGridDrop();
    }

    /// Get the most recent completed list-box drop that occurred this frame, if any.
    pub fn lastListDrop(self: *const Context) ?ListDrop {
        return self.runtime.lastListDrop();
    }

    /// Get the most recent completed table-row drop that occurred this frame, if any.
    pub fn lastTableDrop(self: *const Context) ?TableDrop {
        return self.runtime.lastTableDrop();
    }

    /// Get the most recent generic widget drop that occurred this frame, if any.
    pub fn lastWidgetDrop(self: *const Context) ?WidgetDrop {
        return self.runtime.lastWidgetDrop();
    }

    /// Get the most recent completed drop that occurred this frame, if any.
    pub fn lastDrop(self: *const Context) ?Drop {
        return self.runtime.lastDrop();
    }

    /// Get the timestamp from the most recent primary-button press event.
    pub fn lastPrimaryPressTimestampMs(self: *const Context) u64 {
        return self.runtime.lastPrimaryPressTimestampMs();
    }

    /// Remove a widget and its entire subtree from the tree.
    /// The handle becomes invalid after this call.
    pub fn removeWidget(self: *Context, handle: NodeHandle) !void {
        try self.runtime.removeWidget(&self.tree, handle);
    }

    /// Check whether a handle still refers to a living widget.
    pub fn isAlive(self: *const Context, handle: NodeHandle) bool {
        return self.runtime.isAlive(&self.tree, handle);
    }

    /// Run layout: walk the widget tree through clay and write back rects.
    pub fn doLayout(self: *Context, text_ctx: ?*const TextMeasureCtx) void {
        self.runtime.doLayout(&self.tree, self.theme, text_ctx);
    }

    /// Generate draw commands from the laid-out widget tree.
    pub fn generateDrawList(self: *Context) !DrawList {
        return self.runtime.generateDrawList(&self.tree, self.theme);
    }

    pub fn generatePaintList(self: *Context) !PaintList {
        return self.runtime.generatePaintList(&self.tree, self.theme);
    }

    /// Free a DrawList returned by generateDrawList.
    pub fn freeDrawList(self: *Context, draw_list: *DrawList) void {
        self.runtime.freeDrawList(draw_list);
    }

    pub fn freePaintList(self: *Context, paint_list: *PaintList) void {
        self.runtime.freePaintList(paint_list);
    }

    /// Update layout dimensions (e.g. on window resize).
    pub fn setDimensions(self: *Context, width: u32, height: u32) void {
        self.runtime.setDimensions(width, height);
    }

    pub const InitOptions = struct {
        width: u32 = 800,
        height: u32 = 600,
        theme: Theme = .{},
    };
};

test "context initializes" {
    var ctx = try Context.init(std.testing.allocator, .{});
    defer ctx.deinit();

    try std.testing.expectEqual(@as(u32, 0), ctx.tree.count());
}

test "runtime operates on caller-owned tree" {
    var runtime = try Runtime.init(std.testing.allocator, .{ .width = 800, .height = 600 });
    defer runtime.deinit();

    var tree = Tree.init(std.testing.allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    _ = try tree.addChild(root, .{ .button = .{ .label = "OK" } });

    runtime.doLayout(&tree, .{}, null);
    var draw_list = try runtime.generateDrawList(&tree, .{});
    defer runtime.freeDrawList(&draw_list);

    try std.testing.expect(draw_list.commands.len > 0);
}

test "runtime restores previous clay context" {
    var primary = try Runtime.init(std.testing.allocator, .{ .width = 800, .height = 600 });
    defer primary.deinit();

    var secondary = try Runtime.init(std.testing.allocator, .{ .width = 640, .height = 480 });
    defer secondary.deinit();

    var tree = Tree.init(std.testing.allocator);
    defer tree.deinit();

    _ = try tree.addRoot(.{ .container = .{} });
    c.Clay_SetCurrentContext(primary.clay_context);
    defer c.Clay_SetCurrentContext(null);

    secondary.doLayout(&tree, .{}, null);
    try std.testing.expect(c.Clay_GetCurrentContext() == primary.clay_context);
}

test "layout produces non-zero rects" {
    var ctx = try Context.init(std.testing.allocator, .{ .width = 800, .height = 600 });
    defer ctx.deinit();

    const root = try ctx.tree.addRoot(.{ .container = .{} });
    _ = try ctx.tree.addChild(root, .{ .button = .{ .label = "OK" } });
    _ = try ctx.tree.addChild(root, .{ .text = .{ .content = "hello" } });

    ctx.doLayout(null);

    const root_rect = ctx.tree.getConst(root).layout_rect;
    try std.testing.expect(root_rect.w > 0);
    try std.testing.expect(root_rect.h > 0);
}

test "layout then draw produces commands" {
    var ctx = try Context.init(std.testing.allocator, .{ .width = 800, .height = 600 });
    defer ctx.deinit();

    const root = try ctx.tree.addRoot(.{ .container = .{} });
    _ = try ctx.tree.addChild(root, .{ .button = .{ .label = "OK" } });
    _ = try ctx.tree.addChild(root, .{ .text = .{ .content = "hello" } });

    ctx.doLayout(null);
    var dl = try ctx.generateDrawList();
    defer ctx.freeDrawList(&dl);

    // Should have at least: container bg, button bg, button text, text label
    try std.testing.expect(dl.commands.len >= 4);
}

test "event dispatch detects button click" {
    var ctx = try Context.init(std.testing.allocator, .{ .width = 800, .height = 600 });
    defer ctx.deinit();

    const root = try ctx.tree.addRoot(.{ .container = .{} });
    const btn = try ctx.tree.addChild(root, .{ .button = .{ .label = "OK" } });

    ctx.doLayout(null);

    // Button should have a non-zero rect after layout
    const btn_rect = ctx.tree.getConst(btn).layout_rect;
    const click_x = btn_rect.x + btn_rect.w / 2;
    const click_y = btn_rect.y + btn_rect.h / 2;

    try ctx.pushEvent(.{ .mouse_button = .{ .button = .left, .state = .pressed, .x = click_x, .y = click_y } });
    try ctx.pushEvent(.{ .mouse_button = .{ .button = .left, .state = .released, .x = click_x, .y = click_y } });
    ctx.processEvents();

    try std.testing.expect(ctx.wasClicked(btn));

    // After clearing, clicked should be false
    ctx.clearClickedFlags();
    try std.testing.expect(!ctx.wasClicked(btn));
}

test "checkbox toggle via events" {
    var ctx = try Context.init(std.testing.allocator, .{ .width = 800, .height = 600 });
    defer ctx.deinit();

    const root = try ctx.tree.addRoot(.{ .container = .{} });
    const cb = try ctx.tree.addChild(root, .{ .checkbox = .{ .label = "Enable" } });

    ctx.doLayout(null);

    const cb_rect = ctx.tree.getConst(cb).layout_rect;
    const click_x = cb_rect.x + cb_rect.w / 2;
    const click_y = cb_rect.y + cb_rect.h / 2;

    try std.testing.expect(!ctx.isChecked(cb));

    try ctx.pushEvent(.{ .mouse_button = .{ .button = .left, .state = .pressed, .x = click_x, .y = click_y } });
    try ctx.pushEvent(.{ .mouse_button = .{ .button = .left, .state = .released, .x = click_x, .y = click_y } });
    ctx.processEvents();

    try std.testing.expect(ctx.isChecked(cb));
}

test "radio button group selection via events" {
    var ctx = try Context.init(std.testing.allocator, .{ .width = 800, .height = 600 });
    defer ctx.deinit();

    const root = try ctx.tree.addRoot(.{ .container = .{} });
    const rb1 = try ctx.tree.addChild(root, .{ .radio_button = .{ .label = "A", .group = 1 } });
    const rb2 = try ctx.tree.addChild(root, .{ .radio_button = .{ .label = "B", .group = 1 } });

    ctx.doLayout(null);

    const rb1_rect = ctx.tree.getConst(rb1).layout_rect;
    try ctx.pushEvent(.{ .mouse_button = .{ .button = .left, .state = .pressed, .x = rb1_rect.x + 5, .y = rb1_rect.y + 5 } });
    try ctx.pushEvent(.{ .mouse_button = .{ .button = .left, .state = .released, .x = rb1_rect.x + 5, .y = rb1_rect.y + 5 } });
    ctx.processEvents();

    try std.testing.expect(ctx.isSelected(rb1));
    try std.testing.expect(!ctx.isSelected(rb2));
    try std.testing.expect(ctx.wasClicked(rb1));

    ctx.clearClickedFlags();
    try std.testing.expect(!ctx.wasClicked(rb1));

    // Click rb2 — should deselect rb1
    const rb2_rect = ctx.tree.getConst(rb2).layout_rect;
    try ctx.pushEvent(.{ .mouse_button = .{ .button = .left, .state = .pressed, .x = rb2_rect.x + 5, .y = rb2_rect.y + 5 } });
    try ctx.pushEvent(.{ .mouse_button = .{ .button = .left, .state = .released, .x = rb2_rect.x + 5, .y = rb2_rect.y + 5 } });
    ctx.processEvents();

    try std.testing.expect(!ctx.isSelected(rb1));
    try std.testing.expect(ctx.isSelected(rb2));
}

test "layout skips when not dirty" {
    var ctx = try Context.init(std.testing.allocator, .{ .width = 800, .height = 600 });
    defer ctx.deinit();

    const root = try ctx.tree.addRoot(.{ .container = .{} });
    _ = try ctx.tree.addChild(root, .{ .button = .{ .label = "OK" } });

    // First layout runs (dirty by default)
    ctx.doLayout(null);
    try std.testing.expect(!ctx.runtime.layout_dirty);

    const rect_after_first = ctx.tree.getConst(root).layout_rect;
    try std.testing.expect(rect_after_first.w > 0);

    // Second layout with no changes — should be a no-op
    ctx.doLayout(null);
    try std.testing.expect(!ctx.runtime.layout_dirty);

    // Mouse-only events don't dirty layout
    try ctx.pushEvent(.{ .mouse_move = .{ .x = 50, .y = 50 } });
    ctx.processEvents();
    try std.testing.expect(!ctx.runtime.layout_dirty);

    // Key events trigger a follow-up layout inside processEvents
    try ctx.pushEvent(.{ .key = .{ .scancode = 0, .keycode = .backspace, .state = .pressed } });
    ctx.processEvents();
    try std.testing.expect(!ctx.runtime.layout_dirty);
}

test "runtime coalesces consecutive mouse scroll events" {
    var runtime = try Runtime.init(std.testing.allocator, .{ .width = 320, .height = 240 });
    defer runtime.deinit();

    try runtime.pushEvent(.{ .mouse_scroll = .{ .dx = 0, .dy = 15 } });
    try runtime.pushEvent(.{ .mouse_scroll = .{ .dx = 0, .dy = 30 } });
    try std.testing.expectEqual(@as(usize, 1), runtime.events.items.len);
    try std.testing.expectApproxEqAbs(@as(f32, 45), runtime.events.items[0].mouse_scroll.dy, 0.01);

    try runtime.pushEvent(.{ .mouse_move = .{ .x = 10, .y = 10 } });
    try runtime.pushEvent(.{ .mouse_scroll = .{ .dx = 5, .dy = 10 } });
    try std.testing.expectEqual(@as(usize, 3), runtime.events.items.len);
    try std.testing.expectApproxEqAbs(@as(f32, 10), runtime.events.items[2].mouse_scroll.dy, 0.01);
}

test "runtime coalesces consecutive mouse move events" {
    var runtime = try Runtime.init(std.testing.allocator, .{ .width = 320, .height = 240 });
    defer runtime.deinit();

    try runtime.pushEvent(.{ .mouse_move = .{ .x = 10, .y = 20 } });
    try runtime.pushEvent(.{ .mouse_move = .{ .x = 30, .y = 40 } });
    try std.testing.expectEqual(@as(usize, 1), runtime.events.items.len);
    try std.testing.expectApproxEqAbs(@as(f32, 30), runtime.events.items[0].mouse_move.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 40), runtime.events.items[0].mouse_move.y, 0.01);

    try runtime.pushEvent(.{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 30, .y = 40 } });
    try runtime.pushEvent(.{ .mouse_move = .{ .x = 50, .y = 60 } });
    try runtime.pushEvent(.{ .mouse_move = .{ .x = 70, .y = 80 } });
    try std.testing.expectEqual(@as(usize, 3), runtime.events.items.len);
    try std.testing.expectApproxEqAbs(@as(f32, 70), runtime.events.items[2].mouse_move.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 80), runtime.events.items[2].mouse_move.y, 0.01);
}

test "setDimensions dirties layout" {
    var ctx = try Context.init(std.testing.allocator, .{ .width = 800, .height = 600 });
    defer ctx.deinit();

    _ = try ctx.tree.addRoot(.{ .container = .{} });
    ctx.doLayout(null);
    try std.testing.expect(!ctx.runtime.layout_dirty);

    ctx.setDimensions(1024, 768);
    try std.testing.expect(ctx.runtime.layout_dirty);
}

test "retained context rebinds after another context deinit" {
    var primary = try Context.init(std.testing.allocator, .{ .width = 800, .height = 600 });
    defer primary.deinit();

    _ = try primary.tree.addRoot(.{ .container = .{} });
    primary.doLayout(null);
    try std.testing.expect(!primary.runtime.layout_dirty);

    {
        var secondary = try Context.init(std.testing.allocator, .{ .width = 640, .height = 480 });
        defer secondary.deinit();

        _ = try secondary.tree.addRoot(.{ .container = .{} });
        secondary.doLayout(null);
        try std.testing.expect(!secondary.runtime.layout_dirty);
    }

    primary.setDimensions(1024, 768);
    primary.doLayout(null);
    try std.testing.expect(!primary.runtime.layout_dirty);
}

test "adding nodes triggers layout" {
    var ctx = try Context.init(std.testing.allocator, .{ .width = 800, .height = 600 });
    defer ctx.deinit();

    const root = try ctx.tree.addRoot(.{ .container = .{} });
    ctx.doLayout(null);
    try std.testing.expect(!ctx.runtime.layout_dirty);

    // Adding a node changes tree count — doLayout should detect and run
    _ = try ctx.tree.addChild(root, .{ .text = .{ .content = "new" } });
    ctx.doLayout(null);
    // After running, dirty is cleared and count is updated
    try std.testing.expect(!ctx.runtime.layout_dirty);
    try std.testing.expectEqual(@as(u32, 2), ctx.runtime.last_node_count);
}

test "draw list caching returns same list when clean" {
    var ctx = try Context.init(std.testing.allocator, .{ .width = 800, .height = 600 });
    defer ctx.deinit();

    const root = try ctx.tree.addRoot(.{ .container = .{} });
    _ = try ctx.tree.addChild(root, .{ .button = .{ .label = "OK" } });

    ctx.doLayout(null);

    var dl1 = try ctx.generateDrawList();
    try std.testing.expect(!ctx.runtime.draw_dirty);

    // Second call without changes returns the cached pointer
    var dl2 = try ctx.generateDrawList();
    try std.testing.expectEqual(dl1.commands.ptr, dl2.commands.ptr);

    // freeDrawList is a no-op for the cached list
    ctx.freeDrawList(&dl1);
    ctx.freeDrawList(&dl2);
}

test "draw list regenerated after events" {
    var ctx = try Context.init(std.testing.allocator, .{ .width = 800, .height = 600 });
    defer ctx.deinit();

    const root = try ctx.tree.addRoot(.{ .container = .{} });
    _ = try ctx.tree.addChild(root, .{ .button = .{ .label = "OK" } });

    ctx.doLayout(null);
    var dl1 = try ctx.generateDrawList();
    const ptr1 = dl1.commands.ptr;

    // Pushing an event and processing marks draw dirty
    try ctx.pushEvent(.{ .mouse_move = .{ .x = 50, .y = 50 } });
    ctx.processEvents();
    try std.testing.expect(ctx.runtime.draw_dirty);

    // Regeneration produces a new list (old cache freed internally)
    var dl2 = try ctx.generateDrawList();
    try std.testing.expect(!ctx.runtime.draw_dirty);
    _ = ptr1;

    ctx.freeDrawList(&dl1);
    ctx.freeDrawList(&dl2);
}

test "collapsed tree item can be reopened across context frames" {
    var ctx = try Context.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer ctx.deinit();

    const root = try ctx.tree.addRoot(.{ .container = .{ .direction = .column } });
    const parent = try ctx.tree.addChild(root, .{ .tree_item = .{
        .label = "Scene",
        .group = 1,
    } });
    const child = try ctx.tree.addChild(parent, .{ .tree_item = .{
        .label = "Camera",
        .group = 1,
    } });

    ctx.clearClickedFlags();
    ctx.doLayout(null);

    const parent_rect = ctx.tree.getConst(parent).layout_rect;
    const disclosure_x = parent_rect.x + 8;
    const disclosure_y = parent_rect.y + parent_rect.h * 0.5;

    try ctx.pushEvent(.{ .mouse_button = .{ .button = .left, .state = .pressed, .x = disclosure_x, .y = disclosure_y } });
    try ctx.pushEvent(.{ .mouse_button = .{ .button = .left, .state = .released, .x = disclosure_x, .y = disclosure_y } });
    ctx.processEvents();
    try std.testing.expect(!ctx.isExpanded(parent));

    ctx.clearClickedFlags();
    ctx.doLayout(null);
    try std.testing.expectEqual(draw.Rect{ .x = 0, .y = 0, .w = 0, .h = 0 }, ctx.tree.getConst(child).layout_rect);

    try ctx.pushEvent(.{ .mouse_button = .{ .button = .left, .state = .pressed, .x = disclosure_x, .y = disclosure_y } });
    try ctx.pushEvent(.{ .mouse_button = .{ .button = .left, .state = .released, .x = disclosure_x, .y = disclosure_y } });
    ctx.processEvents();
    try std.testing.expect(ctx.isExpanded(parent));
}

test "tree item drop is reported across context frames" {
    var ctx = try Context.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer ctx.deinit();

    const root = try ctx.tree.addRoot(.{ .container = .{ .direction = .column } });
    const first = try ctx.tree.addChild(root, .{ .tree_item = .{
        .label = "Scene",
        .group = 2,
    } });
    const second = try ctx.tree.addChild(root, .{ .tree_item = .{
        .label = "Camera",
        .group = 2,
    } });

    ctx.clearClickedFlags();
    ctx.doLayout(null);

    const first_rect = ctx.tree.getConst(first).layout_rect;
    const second_rect = ctx.tree.getConst(second).layout_rect;

    try ctx.pushEvent(.{ .mouse_button = .{ .button = .left, .state = .pressed, .x = first_rect.x + 12, .y = first_rect.y + first_rect.h * 0.5 } });
    try ctx.pushEvent(.{ .mouse_move = .{ .x = second_rect.x + 12, .y = second_rect.y + second_rect.h * 0.5 } });
    try ctx.pushEvent(.{ .mouse_button = .{ .button = .left, .state = .released, .x = second_rect.x + 12, .y = second_rect.y + second_rect.h * 0.5 } });
    ctx.processEvents();

    const drop = ctx.lastTreeDrop().?;
    try std.testing.expect(drop.source.eql(first));
    try std.testing.expect(drop.target.eql(second));
    try std.testing.expectEqual(widget.WidgetKind.TreeItem.DropPosition.into, drop.position);

    ctx.clearClickedFlags();
    try std.testing.expect(ctx.lastTreeDrop() == null);
}

test "tab panels switch visibility across context frames" {
    var ctx = try Context.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer ctx.deinit();

    const root = try ctx.tree.addRoot(.{ .container = .{ .direction = .column } });
    const tabs = try ctx.tree.addChild(root, .{ .tab_bar = .{} });
    const scene = try ctx.tree.addChild(tabs, .{ .tab_item = .{
        .label = "Scene",
        .selected = true,
    } });
    const render = try ctx.tree.addChild(tabs, .{ .tab_item = .{
        .label = "Render",
    } });
    const scene_text = try ctx.tree.addChild(scene, .{ .text = .{ .content = "Scene panel" } });
    const render_text = try ctx.tree.addChild(render, .{ .text = .{ .content = "Render panel" } });

    ctx.clearClickedFlags();
    ctx.doLayout(null);

    try std.testing.expect(ctx.tree.getConst(scene_text).layout_rect.w > 0);
    try std.testing.expectEqual(draw.Rect{ .x = 0, .y = 0, .w = 0, .h = 0 }, ctx.tree.getConst(render_text).layout_rect);

    const render_rect = ctx.tree.getConst(render).layout_rect;
    try ctx.pushEvent(.{ .mouse_button = .{ .button = .left, .state = .pressed, .x = render_rect.x + 5, .y = render_rect.y + 5 } });
    try ctx.pushEvent(.{ .mouse_button = .{ .button = .left, .state = .released, .x = render_rect.x + 5, .y = render_rect.y + 5 } });
    ctx.processEvents();

    try std.testing.expect(ctx.isSelected(render));
    try std.testing.expect(!ctx.isSelected(scene));

    ctx.clearClickedFlags();
    ctx.doLayout(null);

    try std.testing.expectEqual(draw.Rect{ .x = 0, .y = 0, .w = 0, .h = 0 }, ctx.tree.getConst(scene_text).layout_rect);
    try std.testing.expect(ctx.tree.getConst(render_text).layout_rect.w > 0);
}

test "list box reports selected index and change across context frames" {
    var ctx = try Context.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer ctx.deinit();

    const root = try ctx.tree.addRoot(.{ .container = .{ .direction = .column } });
    const list_box = try ctx.tree.addChild(root, .{ .list_box = .{} });
    _ = try ctx.tree.addChild(list_box, .{ .selectable = .{
        .label = "Scene",
        .selected = true,
    } });
    const camera = try ctx.tree.addChild(list_box, .{ .selectable = .{
        .label = "Camera",
    } });

    ctx.clearClickedFlags();
    ctx.doLayout(null);
    try std.testing.expectEqual(@as(?u16, 0), ctx.listBoxSelectedIndex(list_box));

    const camera_rect = ctx.tree.getConst(camera).layout_rect;
    try ctx.pushEvent(.{ .mouse_button = .{
        .button = .left,
        .state = .pressed,
        .x = camera_rect.x + 5,
        .y = camera_rect.y + 5,
    } });
    try ctx.pushEvent(.{ .mouse_button = .{
        .button = .left,
        .state = .released,
        .x = camera_rect.x + 5,
        .y = camera_rect.y + 5,
    } });
    ctx.processEvents();

    try std.testing.expect(ctx.listBoxChanged(list_box));
    try std.testing.expectEqual(@as(?u16, 1), ctx.listBoxSelectedIndex(list_box));
    try std.testing.expect(ctx.isSelected(camera));
}

test "grid selector reports selection count and change across context frames" {
    var ctx = try Context.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer ctx.deinit();

    const root = try ctx.tree.addRoot(.{ .container = .{ .direction = .column } });
    const grid = try ctx.tree.addChild(root, .{ .grid_selector = .{
        .selection_mode = .multiple,
        .item_width = 96,
        .item_height = 72,
        .column_gap = 8,
        .row_gap = 8,
    } });
    _ = try ctx.tree.addChild(grid, .{ .grid_item = .{
        .label = "Brick",
        .selected = true,
    } });
    const metal = try ctx.tree.addChild(grid, .{ .grid_item = .{ .label = "Metal" } });

    ctx.clearClickedFlags();
    ctx.doLayout(null);
    try std.testing.expectEqual(@as(?u16, 0), ctx.gridSelectorSelectedIndex(grid));

    const metal_rect = ctx.tree.getConst(metal).layout_rect;
    try ctx.pushEvent(.{ .key = .{ .scancode = 29, .keycode = .left_ctrl, .state = .pressed } });
    try ctx.pushEvent(.{ .mouse_button = .{
        .button = .left,
        .state = .pressed,
        .x = metal_rect.x + 5,
        .y = metal_rect.y + 5,
    } });
    try ctx.pushEvent(.{ .mouse_button = .{
        .button = .left,
        .state = .released,
        .x = metal_rect.x + 5,
        .y = metal_rect.y + 5,
    } });
    try ctx.pushEvent(.{ .key = .{ .scancode = 29, .keycode = .left_ctrl, .state = .released } });
    ctx.processEvents();

    try std.testing.expect(ctx.gridSelectorChanged(grid));
    try std.testing.expectEqual(@as(u16, 2), ctx.gridSelectorSelectionCount(grid));
    try std.testing.expect(ctx.isSelected(metal));
}

test "grid item drop is reported across context frames" {
    var ctx = try Context.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer ctx.deinit();

    const root = try ctx.tree.addRoot(.{ .container = .{ .direction = .column } });
    const grid = try ctx.tree.addChild(root, .{ .grid_selector = .{
        .item_width = 96,
        .item_height = 72,
        .column_gap = 8,
        .row_gap = 8,
    } });
    const first = try ctx.tree.addChild(grid, .{ .grid_item = .{ .label = "Brick" } });
    const second = try ctx.tree.addChild(grid, .{ .grid_item = .{ .label = "Metal" } });
    ctx.setUserId(first, 101);
    ctx.setUserId(second, 102);

    ctx.clearClickedFlags();
    ctx.doLayout(null);

    const first_rect = ctx.tree.getConst(first).layout_rect;
    const second_rect = ctx.tree.getConst(second).layout_rect;

    try ctx.pushEvent(.{ .mouse_button = .{
        .button = .left,
        .state = .pressed,
        .x = first_rect.x + first_rect.w * 0.5,
        .y = first_rect.y + first_rect.h * 0.5,
    } });
    try ctx.pushEvent(.{ .mouse_move = .{
        .x = second_rect.x + second_rect.w * 0.5,
        .y = second_rect.y + second_rect.h * 0.5,
    } });
    ctx.processEvents();

    const pointer = ctx.pointerPosition();
    try std.testing.expect(ctx.isPointerButtonDown(.left));
    try std.testing.expect(ctx.activeDragSource().?.eql(first));
    try std.testing.expectApproxEqAbs(second_rect.x + second_rect.w * 0.5, pointer.x, 0.01);
    try std.testing.expectEqual(@as(u64, 101), ctx.userId(first));

    try ctx.pushEvent(.{ .mouse_button = .{
        .button = .left,
        .state = .released,
        .x = second_rect.x + second_rect.w * 0.5,
        .y = second_rect.y + second_rect.h * 0.5,
    } });
    ctx.processEvents();

    const drop = ctx.lastGridDrop().?;
    try std.testing.expect(drop.source.eql(first));
    try std.testing.expect(drop.target.eql(second));
    try std.testing.expectEqual(dispatch.GridDrop.Position.item, drop.position);
    try std.testing.expect(!ctx.isPointerButtonDown(.left));
    try std.testing.expect(ctx.lastDrop().?.grid.source.eql(first));

    ctx.clearClickedFlags();
    try std.testing.expect(ctx.lastGridDrop() == null);
    try std.testing.expect(ctx.lastDrop() == null);
}

test "multi-select list box supports ctrl-toggle and shift-range selection" {
    var ctx = try Context.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer ctx.deinit();

    const root = try ctx.tree.addRoot(.{ .container = .{ .direction = .column } });
    const list_box = try ctx.tree.addChild(root, .{ .list_box = .{ .selection_mode = .multiple } });
    const scene = try ctx.tree.addChild(list_box, .{ .selectable = .{
        .label = "Scene",
        .selected = true,
    } });
    const camera = try ctx.tree.addChild(list_box, .{ .selectable = .{ .label = "Camera" } });
    const light = try ctx.tree.addChild(list_box, .{ .selectable = .{ .label = "Light" } });
    ctx.setUserId(scene, 201);
    ctx.setUserId(camera, 202);
    ctx.setUserId(light, 203);

    ctx.clearClickedFlags();
    ctx.doLayout(null);

    const camera_rect = ctx.tree.getConst(camera).layout_rect;
    try ctx.pushEvent(.{ .key = .{ .scancode = 29, .keycode = .left_ctrl, .state = .pressed } });
    try ctx.pushEvent(.{ .mouse_button = .{
        .button = .left,
        .state = .pressed,
        .x = camera_rect.x + 5,
        .y = camera_rect.y + 5,
    } });
    try ctx.pushEvent(.{ .mouse_button = .{
        .button = .left,
        .state = .released,
        .x = camera_rect.x + 5,
        .y = camera_rect.y + 5,
    } });
    try ctx.pushEvent(.{ .key = .{ .scancode = 29, .keycode = .left_ctrl, .state = .released } });
    ctx.processEvents();

    try std.testing.expect(ctx.listBoxChanged(list_box));
    try std.testing.expect(ctx.isSelected(scene));
    try std.testing.expect(ctx.isSelected(camera));
    try std.testing.expectEqual(@as(u16, 2), ctx.listBoxSelectionCount(list_box));
    const selected = ctx.selectedChild(list_box, 1).?;
    try std.testing.expect(selected.handle.eql(camera));
    try std.testing.expectEqual(@as(u16, 1), selected.index);
    try std.testing.expectEqual(@as(u64, 202), selected.user_id);

    ctx.clearClickedFlags();
    const light_rect = ctx.tree.getConst(light).layout_rect;
    try ctx.pushEvent(.{ .key = .{ .scancode = 29, .keycode = .left_ctrl, .state = .pressed } });
    try ctx.pushEvent(.{ .key = .{ .scancode = 42, .keycode = .left_shift, .state = .pressed } });
    try ctx.pushEvent(.{ .mouse_button = .{
        .button = .left,
        .state = .pressed,
        .x = light_rect.x + 5,
        .y = light_rect.y + 5,
    } });
    try ctx.pushEvent(.{ .mouse_button = .{
        .button = .left,
        .state = .released,
        .x = light_rect.x + 5,
        .y = light_rect.y + 5,
    } });
    try ctx.pushEvent(.{ .key = .{ .scancode = 29, .keycode = .left_ctrl, .state = .released } });
    try ctx.pushEvent(.{ .key = .{ .scancode = 42, .keycode = .left_shift, .state = .released } });
    ctx.processEvents();

    try std.testing.expect(ctx.listBoxChanged(list_box));
    try std.testing.expect(ctx.isSelected(scene));
    try std.testing.expect(ctx.isSelected(camera));
    try std.testing.expect(ctx.isSelected(light));
    try std.testing.expectEqual(@as(u16, 3), ctx.listBoxSelectionCount(list_box));
}

test "table row selection reports count and first selected row" {
    var ctx = try Context.init(std.testing.allocator, .{ .width = 640, .height = 360 });
    defer ctx.deinit();

    const root = try ctx.tree.addRoot(.{ .container = .{ .direction = .column } });
    const table = try ctx.tree.addChild(root, .{ .table = .{
        .columns = 2,
        .selection_mode = .multiple,
    } });
    const header = try ctx.tree.addChild(table, .{ .table_row = .{ .header = true } });
    const header_name = try ctx.tree.addChild(header, .{ .table_cell = .{} });
    const header_type = try ctx.tree.addChild(header, .{ .table_cell = .{} });
    _ = try ctx.tree.addChild(header_name, .{ .text = .{ .content = "Name" } });
    _ = try ctx.tree.addChild(header_type, .{ .text = .{ .content = "Type" } });

    const first = try ctx.tree.addChild(table, .{ .table_row = .{ .selected = true } });
    const first_name = try ctx.tree.addChild(first, .{ .table_cell = .{} });
    const first_type = try ctx.tree.addChild(first, .{ .table_cell = .{} });
    _ = try ctx.tree.addChild(first_name, .{ .text = .{ .content = "SceneRoot" } });
    _ = try ctx.tree.addChild(first_type, .{ .text = .{ .content = "Collection" } });

    const second = try ctx.tree.addChild(table, .{ .table_row = .{} });
    const second_name = try ctx.tree.addChild(second, .{ .table_cell = .{} });
    const second_type = try ctx.tree.addChild(second, .{ .table_cell = .{} });
    _ = try ctx.tree.addChild(second_name, .{ .text = .{ .content = "CameraRig" } });
    _ = try ctx.tree.addChild(second_type, .{ .text = .{ .content = "Object" } });

    const third = try ctx.tree.addChild(table, .{ .table_row = .{} });
    const third_name = try ctx.tree.addChild(third, .{ .table_cell = .{} });
    const third_type = try ctx.tree.addChild(third, .{ .table_cell = .{} });
    _ = try ctx.tree.addChild(third_name, .{ .text = .{ .content = "KeyLight" } });
    _ = try ctx.tree.addChild(third_type, .{ .text = .{ .content = "Light" } });

    ctx.clearClickedFlags();
    ctx.doLayout(null);

    const second_rect = ctx.tree.getConst(second).layout_rect;
    try ctx.pushEvent(.{ .key = .{ .scancode = 29, .keycode = .left_ctrl, .state = .pressed } });
    try ctx.pushEvent(.{ .mouse_button = .{
        .button = .left,
        .state = .pressed,
        .x = second_rect.x + 5,
        .y = second_rect.y + 5,
    } });
    try ctx.pushEvent(.{ .mouse_button = .{
        .button = .left,
        .state = .released,
        .x = second_rect.x + 5,
        .y = second_rect.y + 5,
    } });
    try ctx.pushEvent(.{ .key = .{ .scancode = 29, .keycode = .left_ctrl, .state = .released } });
    ctx.processEvents();

    try std.testing.expect(ctx.tableSelectionChanged(table));
    try std.testing.expectEqual(@as(u16, 2), ctx.tableSelectionCount(table));
    try std.testing.expectEqual(@as(?u16, 0), ctx.tableSelectedRowIndex(table));
    try std.testing.expect(ctx.isSelected(first));
    try std.testing.expect(ctx.isSelected(second));

    ctx.clearClickedFlags();
    const third_rect = ctx.tree.getConst(third).layout_rect;
    try ctx.pushEvent(.{ .key = .{ .scancode = 29, .keycode = .left_ctrl, .state = .pressed } });
    try ctx.pushEvent(.{ .key = .{ .scancode = 42, .keycode = .left_shift, .state = .pressed } });
    try ctx.pushEvent(.{ .mouse_button = .{
        .button = .left,
        .state = .pressed,
        .x = third_rect.x + 5,
        .y = third_rect.y + 5,
    } });
    try ctx.pushEvent(.{ .mouse_button = .{
        .button = .left,
        .state = .released,
        .x = third_rect.x + 5,
        .y = third_rect.y + 5,
    } });
    try ctx.pushEvent(.{ .key = .{ .scancode = 29, .keycode = .left_ctrl, .state = .released } });
    try ctx.pushEvent(.{ .key = .{ .scancode = 42, .keycode = .left_shift, .state = .released } });
    ctx.processEvents();

    try std.testing.expect(ctx.tableSelectionChanged(table));
    try std.testing.expectEqual(@as(u16, 3), ctx.tableSelectionCount(table));
    try std.testing.expectEqual(@as(?u16, 0), ctx.tableSelectedRowIndex(table));
    try std.testing.expect(ctx.isSelected(third));
}

test "table layout keeps columns aligned across rows" {
    var ctx = try Context.init(std.testing.allocator, .{ .width = 480, .height = 320 });
    defer ctx.deinit();

    const root = try ctx.tree.addRoot(.{ .container = .{ .direction = .column } });
    const table = try ctx.tree.addChild(root, .{ .table = .{ .columns = 3 } });
    const header = try ctx.tree.addChild(table, .{ .table_row = .{ .header = true } });
    const header_name = try ctx.tree.addChild(header, .{ .table_cell = .{} });
    const header_type = try ctx.tree.addChild(header, .{ .table_cell = .{} });
    const header_vis = try ctx.tree.addChild(header, .{ .table_cell = .{} });
    _ = try ctx.tree.addChild(header_name, .{ .text = .{ .content = "Name" } });
    _ = try ctx.tree.addChild(header_type, .{ .text = .{ .content = "Type" } });
    _ = try ctx.tree.addChild(header_vis, .{ .text = .{ .content = "Visible" } });

    const row = try ctx.tree.addChild(table, .{ .table_row = .{} });
    const row_name = try ctx.tree.addChild(row, .{ .table_cell = .{} });
    const row_type = try ctx.tree.addChild(row, .{ .table_cell = .{} });
    const row_vis = try ctx.tree.addChild(row, .{ .table_cell = .{} });
    _ = try ctx.tree.addChild(row_name, .{ .text = .{ .content = "Cube" } });
    _ = try ctx.tree.addChild(row_type, .{ .text = .{ .content = "Mesh" } });
    _ = try ctx.tree.addChild(row_vis, .{ .text = .{ .content = "Yes" } });

    ctx.clearClickedFlags();
    ctx.doLayout(null);

    const header_name_rect = ctx.tree.getConst(header_name).layout_rect;
    const header_type_rect = ctx.tree.getConst(header_type).layout_rect;
    const header_vis_rect = ctx.tree.getConst(header_vis).layout_rect;
    const row_name_rect = ctx.tree.getConst(row_name).layout_rect;
    const row_type_rect = ctx.tree.getConst(row_type).layout_rect;
    const row_vis_rect = ctx.tree.getConst(row_vis).layout_rect;

    try std.testing.expect(header_name_rect.w > 0);
    try std.testing.expectApproxEqAbs(header_name_rect.x, row_name_rect.x, 0.01);
    try std.testing.expectApproxEqAbs(header_type_rect.x, row_type_rect.x, 0.01);
    try std.testing.expectApproxEqAbs(header_vis_rect.x, row_vis_rect.x, 0.01);
    try std.testing.expectApproxEqAbs(header_name_rect.w, header_type_rect.w, 0.01);
    try std.testing.expectApproxEqAbs(header_type_rect.w, header_vis_rect.w, 0.01);
}

test "resizable table columns update widths in the same frame as drag" {
    var ctx = try Context.init(std.testing.allocator, .{ .width = 640, .height = 360 });
    defer ctx.deinit();

    const root = try ctx.tree.addRoot(.{ .container = .{ .direction = .column } });
    const table = try ctx.tree.addChild(root, .{ .table = .{
        .columns = 3,
        .resizable = true,
    } });
    const header = try ctx.tree.addChild(table, .{ .table_row = .{ .header = true } });
    const header_name = try ctx.tree.addChild(header, .{ .table_cell = .{} });
    const header_type = try ctx.tree.addChild(header, .{ .table_cell = .{} });
    const header_vis = try ctx.tree.addChild(header, .{ .table_cell = .{} });
    _ = try ctx.tree.addChild(header_name, .{ .text = .{ .content = "Name" } });
    _ = try ctx.tree.addChild(header_type, .{ .text = .{ .content = "Type" } });
    _ = try ctx.tree.addChild(header_vis, .{ .text = .{ .content = "Visible" } });

    const row = try ctx.tree.addChild(table, .{ .table_row = .{} });
    const row_name = try ctx.tree.addChild(row, .{ .table_cell = .{} });
    const row_type = try ctx.tree.addChild(row, .{ .table_cell = .{} });
    const row_vis = try ctx.tree.addChild(row, .{ .table_cell = .{} });
    _ = try ctx.tree.addChild(row_name, .{ .text = .{ .content = "Cube" } });
    _ = try ctx.tree.addChild(row_type, .{ .text = .{ .content = "Mesh" } });
    _ = try ctx.tree.addChild(row_vis, .{ .text = .{ .content = "Yes" } });

    ctx.clearClickedFlags();
    ctx.doLayout(null);

    const initial_name = ctx.tree.getConst(header_name).layout_rect;
    const initial_type = ctx.tree.getConst(header_type).layout_rect;
    const divider_x = initial_name.x + initial_name.w;
    const divider_y = initial_name.y + initial_name.h * 0.5;

    try ctx.pushEvent(.{ .mouse_button = .{
        .button = .left,
        .state = .pressed,
        .x = divider_x,
        .y = divider_y,
    } });
    try ctx.pushEvent(.{ .mouse_move = .{
        .x = divider_x + 48,
        .y = divider_y,
    } });
    try ctx.pushEvent(.{ .mouse_button = .{
        .button = .left,
        .state = .released,
        .x = divider_x + 48,
        .y = divider_y,
    } });
    ctx.processEvents();

    const resized_name = ctx.tree.getConst(header_name).layout_rect;
    const resized_type = ctx.tree.getConst(header_type).layout_rect;
    const resized_row_name = ctx.tree.getConst(row_name).layout_rect;
    const resized_row_type = ctx.tree.getConst(row_type).layout_rect;

    try std.testing.expect(ctx.tableChanged(table));
    try std.testing.expectEqual(@as(?u8, 0), ctx.tableResizedColumn(table));
    try std.testing.expect(ctx.tableColumnFraction(table, 0).? > (1.0 / 3.0));
    try std.testing.expect(resized_name.w > initial_name.w);
    try std.testing.expect(resized_type.w < initial_type.w);
    try std.testing.expectApproxEqAbs(resized_name.x, resized_row_name.x, 0.01);
    try std.testing.expectApproxEqAbs(resized_type.x, resized_row_type.x, 0.01);
}

test "sortable table headers update retained sort state" {
    var ctx = try Context.init(std.testing.allocator, .{ .width = 640, .height = 360 });
    defer ctx.deinit();

    const root = try ctx.tree.addRoot(.{ .container = .{ .direction = .column } });
    const table = try ctx.tree.addChild(root, .{ .table = .{
        .columns = 3,
        .sortable = true,
    } });
    const header = try ctx.tree.addChild(table, .{ .table_row = .{ .header = true } });
    const header_name = try ctx.tree.addChild(header, .{ .table_cell = .{} });
    const header_type = try ctx.tree.addChild(header, .{ .table_cell = .{} });
    const header_vis = try ctx.tree.addChild(header, .{ .table_cell = .{} });
    _ = try ctx.tree.addChild(header_name, .{ .text = .{ .content = "Name" } });
    _ = try ctx.tree.addChild(header_type, .{ .text = .{ .content = "Type" } });
    _ = try ctx.tree.addChild(header_vis, .{ .text = .{ .content = "Visible" } });

    const row = try ctx.tree.addChild(table, .{ .table_row = .{} });
    const row_name = try ctx.tree.addChild(row, .{ .table_cell = .{} });
    const row_type = try ctx.tree.addChild(row, .{ .table_cell = .{} });
    const row_vis = try ctx.tree.addChild(row, .{ .table_cell = .{} });
    _ = try ctx.tree.addChild(row_name, .{ .text = .{ .content = "Cube" } });
    _ = try ctx.tree.addChild(row_type, .{ .text = .{ .content = "Mesh" } });
    _ = try ctx.tree.addChild(row_vis, .{ .text = .{ .content = "Yes" } });

    ctx.clearClickedFlags();
    ctx.doLayout(null);

    const header_type_rect = ctx.tree.getConst(header_type).layout_rect;
    const click_x = header_type_rect.x + 12;
    const click_y = header_type_rect.y + header_type_rect.h * 0.5;

    try ctx.pushEvent(.{ .mouse_button = .{
        .button = .left,
        .state = .pressed,
        .x = click_x,
        .y = click_y,
        .timestamp_ms = 10,
    } });
    try ctx.pushEvent(.{ .mouse_button = .{
        .button = .left,
        .state = .released,
        .x = click_x,
        .y = click_y,
        .timestamp_ms = 20,
    } });
    ctx.processEvents();

    try std.testing.expect(ctx.wasClicked(table));
    try std.testing.expect(ctx.tableSortChanged(table));
    try std.testing.expectEqual(@as(?u8, 1), ctx.tableSortedColumn(table));
    try std.testing.expectEqual(widget.WidgetKind.Table.SortDirection.ascending, ctx.tableSortDirection(table).?);

    ctx.clearClickedFlags();
    try ctx.pushEvent(.{ .mouse_button = .{
        .button = .left,
        .state = .pressed,
        .x = click_x,
        .y = click_y,
        .timestamp_ms = 30,
    } });
    try ctx.pushEvent(.{ .mouse_button = .{
        .button = .left,
        .state = .released,
        .x = click_x,
        .y = click_y,
        .timestamp_ms = 40,
    } });
    ctx.processEvents();

    try std.testing.expect(ctx.tableSortChanged(table));
    try std.testing.expectEqual(@as(?u8, 1), ctx.tableSortedColumn(table));
    try std.testing.expectEqual(widget.WidgetKind.Table.SortDirection.descending, ctx.tableSortDirection(table).?);
}

test "tooltip layout updates in the same frame as hover" {
    var ctx = try Context.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer ctx.deinit();

    const root = try ctx.tree.addRoot(.{ .container = .{ .direction = .column } });
    const owner = try ctx.tree.addChild(root, .{ .tree_item = .{ .label = "Hover me", .group = 1 } });
    const tooltip = try ctx.tree.addChild(owner, .{ .tooltip = .{ .placement = .below_start, .y = 4 } });
    _ = try ctx.tree.addChild(tooltip, .{ .text = .{ .content = "Tooltip body" } });

    ctx.clearClickedFlags();
    ctx.doLayout(null);
    try std.testing.expectEqual(draw.Rect{ .x = 0, .y = 0, .w = 0, .h = 0 }, ctx.tree.getConst(tooltip).layout_rect);

    const owner_rect = ctx.tree.getConst(owner).layout_rect;
    try ctx.pushEvent(.{ .mouse_move = .{
        .x = owner_rect.x + 5,
        .y = owner_rect.y + 5,
    } });
    ctx.processEvents();

    const tooltip_rect = ctx.tree.getConst(tooltip).layout_rect;
    try std.testing.expect(tooltip_rect.w > 0);
    try std.testing.expect(tooltip_rect.h > 0);

    try ctx.pushEvent(.{ .mouse_move = .{ .x = 390, .y = 290 } });
    ctx.processEvents();
    try std.testing.expectEqual(draw.Rect{ .x = 0, .y = 0, .w = 0, .h = 0 }, ctx.tree.getConst(tooltip).layout_rect);
}

test "menu popup layout updates in the same frame as activation" {
    var ctx = try Context.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer ctx.deinit();

    const root = try ctx.tree.addRoot(.{ .container = .{ .direction = .column } });
    const bar = try ctx.tree.addChild(root, .{ .menu_bar = .{} });
    const file = try ctx.tree.addChild(bar, .{ .menu = .{ .label = "File" } });
    const popup = try ctx.tree.addChild(file, .{ .popup = .{
        .placement = .below_start,
        .visible = false,
    } });
    _ = try ctx.tree.addChild(popup, .{ .menu_item = .{ .label = "Open" } });

    ctx.clearClickedFlags();
    ctx.doLayout(null);

    const file_rect = ctx.tree.getConst(file).layout_rect;
    try ctx.pushEvent(.{ .mouse_button = .{
        .button = .left,
        .state = .pressed,
        .x = file_rect.x + 5,
        .y = file_rect.y + 5,
    } });
    try ctx.pushEvent(.{ .mouse_button = .{
        .button = .left,
        .state = .released,
        .x = file_rect.x + 5,
        .y = file_rect.y + 5,
    } });
    ctx.processEvents();

    const popup_rect = ctx.tree.getConst(popup).layout_rect;
    try std.testing.expect(popup_rect.w > 0);
    try std.testing.expect(popup_rect.h > 0);
    try std.testing.expect(popup_rect.y >= file_rect.y + file_rect.h - 0.01);
}

test "submenu hover updates layout in the same frame" {
    var ctx = try Context.init(std.testing.allocator, .{ .width = 480, .height = 320 });
    defer ctx.deinit();

    const root = try ctx.tree.addRoot(.{ .container = .{ .direction = .column } });
    const bar = try ctx.tree.addChild(root, .{ .menu_bar = .{} });
    const file = try ctx.tree.addChild(bar, .{ .menu = .{ .label = "File" } });
    const file_popup = try ctx.tree.addChild(file, .{ .popup = .{
        .placement = .below_start,
        .visible = false,
    } });
    const recent = try ctx.tree.addChild(file_popup, .{ .menu_item = .{ .label = "Open Recent" } });
    const recent_popup = try ctx.tree.addChild(recent, .{ .popup = .{
        .placement = .right_start,
        .visible = false,
    } });
    _ = try ctx.tree.addChild(recent_popup, .{ .menu_item = .{ .label = "shot.blend" } });

    ctx.clearClickedFlags();
    ctx.doLayout(null);

    const file_rect = ctx.tree.getConst(file).layout_rect;
    try ctx.pushEvent(.{ .mouse_button = .{
        .button = .left,
        .state = .pressed,
        .x = file_rect.x + 5,
        .y = file_rect.y + 5,
    } });
    try ctx.pushEvent(.{ .mouse_button = .{
        .button = .left,
        .state = .released,
        .x = file_rect.x + 5,
        .y = file_rect.y + 5,
    } });
    ctx.processEvents();

    const recent_rect = ctx.tree.getConst(recent).layout_rect;
    try ctx.pushEvent(.{ .mouse_move = .{
        .x = recent_rect.x + 5,
        .y = recent_rect.y + 5,
    } });
    ctx.processEvents();

    const recent_popup_rect = ctx.tree.getConst(recent_popup).layout_rect;
    try std.testing.expect(recent_popup_rect.w > 0);
    try std.testing.expect(recent_popup_rect.x >= recent_rect.x + recent_rect.w - 0.01);
}

test {
    _ = widget;
    _ = style;
    _ = layout;
    _ = draw;
    _ = dispatch;
    _ = @import("core/focus.zig");
    _ = @import("core/hittest.zig");
}
