//! `goop` is a retained-mode GUI library. The embedder owns the native
//! window, input pump, text shaper, and renderer; `goop` owns widget
//! state, layout, hit testing, event dispatch, and draw-list generation.
//!
//! Public surface, in rough import order:
//!
//! - `Runtime` is the primitive: it owns clay state, the event queue,
//!   draw caches, and hit/dispatch state for one or more caller-owned
//!   `Tree`s. Embedders that drive multiple trees (e.g. main window plus
//!   detached popup surfaces) wire up `Runtime` directly.
//! - `Context` is the single-tree convenience layer over `Runtime`. It
//!   bundles a `Tree`, `Theme`, optional `Clipboard`, and a `Runtime` so
//!   the common case is one type. Anything `Context` exposes is a thin
//!   forward over `Runtime` plus its bundled tree.
//! - `Tree` holds widget nodes. Add and remove go through `Tree`
//!   directly (`tree.addRoot`, `tree.addChild`, `tree.remove`); the
//!   runtime watches the live-node count and re-runs layout when it
//!   changes. *In-place* mutations (style overrides, kind payload,
//!   per-frame flags) must go through `Runtime.setStyle`,
//!   `Runtime.updateWidget`, `Runtime.mutateKind`, or
//!   `Runtime.setCustomDraw` (or the matching `Context` method) so the
//!   layout/draw caches invalidate. Reaching into `tree.get(h).foo = ...`
//!   silently bypasses invalidation and may produce stale frames.
//! - The everyday primitives (`NodeHandle`, `WidgetKind`, `WidgetView`,
//!   `Style`, `Theme`, `Event`, `DrawCommand`, …) are re-exported at
//!   this level so most code only imports `goop`.
//! - Sub-namespaces (`widget`, `style`, `draw`, `layout`, `hittest`,
//!   `event`) hold the helpers and types embedders reach for less often
//!   (rect math, text measurement, hit testing, paint command shape).
//!   `dispatch` is intentionally private — it runs through `Runtime`.

const std = @import("std");
const c = @cImport({
    @cInclude("clay.h");
});

pub const widget = @import("core/widget.zig");
pub const event = @import("core/event.zig");
pub const style = @import("core/style.zig");
pub const draw = @import("core/draw.zig");
pub const layout = @import("core/layout.zig");
pub const hittest = @import("core/hittest.zig");

const dispatch = @import("core/dispatch.zig");

pub const Tree = widget.Tree;
pub const NodeHandle = widget.NodeHandle;
pub const WidgetKind = widget.WidgetKind;
pub const WidgetDesc = widget.WidgetDesc;
pub const WidgetView = widget.WidgetView;
pub const kindFromDesc = widget.kindFromDesc;
pub const Rect = draw.Rect;
pub const Event = event.Event;
pub const Theme = style.Theme;
pub const Style = style.Style;
pub const Color = style.Color;
pub const PaintCommand = draw.PaintCommand;
pub const PaintList = draw.PaintList;
pub const PaintOptions = draw.PaintOptions;
pub const PaintScope = draw.PaintScope;
pub const DrawCommand = draw.DrawCommand;
pub const DrawList = draw.DrawList;
pub const TextAlign = draw.TextAlign;
pub const TextOverflow = draw.TextOverflow;
pub const IconId = draw.IconId;
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
    ///
    /// Consecutive `.mouse_move` events collapse into the latest position.
    /// Consecutive `.mouse_scroll` events collapse into a summed delta.
    /// All other events are appended verbatim. If your embedder needs a
    /// per-event trail (e.g. handwriting, freehand drawing), push a
    /// terminator event between samples or process events synchronously
    /// rather than queuing.
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
        self.mouse.last_drop = null;
        for (tree.nodes.items) |*node| {
            if (!node.alive) continue;
            node.interaction.primary_clicked = false;
            node.interaction.secondary_clicked = false;
            node.interaction.drop_received = false;
            node.interaction.changed = false;
            node.interaction.toggled = false;
            switch (node.kind) {
                .tree_item => |*tree_item| {
                    tree_item.rename_committed = false;
                },
                .table => |*table| {
                    table.resized_column = null;
                    table.sort_changed = false;
                    table.selection_changed = false;
                },
                else => {},
            }
        }
    }

    /// Snapshot a widget's read-only state. Returns null if the handle
    /// is dead. The slices in the returned view borrow from the tree
    /// and stay valid until the next mutation that touches this widget.
    pub fn widget(_: *const Runtime, tree: *const Tree, handle: NodeHandle) ?WidgetView {
        if (!tree.isAlive(handle)) return null;
        return WidgetView.fromNode(tree.getConst(handle));
    }

    /// Get the laid-out rectangle for a widget. Returns null if the
    /// handle is dead. The rectangle is from the most recent layout
    /// pass; call `doLayout` first if state has changed since.
    pub fn layoutRect(_: *const Runtime, tree: *const Tree, handle: NodeHandle) ?Rect {
        if (!tree.isAlive(handle)) return null;
        return tree.getConst(handle).layout_rect;
    }

    /// Get a single column's normalized width for a table, in [0, 1].
    /// Returns null if the handle is not a table or the column index
    /// exceeds the table's active column count.
    pub fn tableColumnFraction(_: *const Runtime, tree: *const Tree, handle: NodeHandle, index: u8) ?f32 {
        if (!tree.isAlive(handle)) return null;
        const node = tree.getConst(handle);
        if (node.kind != .table) return null;
        return node.kind.table.columnWeight(index);
    }

    /// Replace a widget's payload with the provided descriptor. The
    /// desc tag must match the widget's current kind. Returns true on
    /// success, false if the handle is dead or the tag does not match.
    /// Marks the runtime dirty. Per-frame interaction state (clicked,
    /// dragging, etc.) is reset to defaults; for surgical edits to
    /// existing state use `mutateKind` instead.
    pub fn updateWidget(self: *Runtime, tree: *Tree, handle: NodeHandle, desc: WidgetDesc) bool {
        const widget_mod = @import("core/widget.zig");
        if (!tree.isAlive(handle)) return false;
        const node = tree.get(handle);
        if (@as(std.meta.Tag(WidgetKind), node.kind) != @as(std.meta.Tag(WidgetDesc), desc)) return false;
        node.kind = widget_mod.kindFromDesc(desc);
        widget_mod.syncDerivedState(&node.kind);
        self.invalidate();
        return true;
    }

    /// Replace a widget's per-node style overrides. Returns false if
    /// the handle is dead. Marks the runtime dirty so the change
    /// re-lays-out and re-renders on the next frame.
    pub fn setStyle(self: *Runtime, tree: *Tree, handle: NodeHandle, override: Style) bool {
        if (!tree.isAlive(handle)) return false;
        tree.get(handle).style_override = override;
        self.invalidate();
        return true;
    }

    /// Borrow a mutable pointer to a widget's payload for in-place
    /// edits (e.g. scroll position, popup visibility). Returns null if
    /// the handle is dead. Always pessimistically marks the runtime
    /// dirty — the runtime cannot tell which fields the caller will
    /// touch, so it assumes layout and draw both need to rerun.
    pub fn mutateKind(self: *Runtime, tree: *Tree, handle: NodeHandle) ?*WidgetKind {
        if (!tree.isAlive(handle)) return null;
        self.invalidate();
        return &tree.get(handle).kind;
    }

    /// Mark a widget as embedder-rendered. The library still emits a
    /// `.custom` draw command for it, but skips its built-in painting.
    /// Returns false if the handle is dead.
    pub fn setCustomDraw(self: *Runtime, tree: *Tree, handle: NodeHandle, custom: bool) bool {
        if (!tree.isAlive(handle)) return false;
        tree.get(handle).custom_draw = custom;
        self.invalidate();
        return true;
    }

    /// Check if a widget was activated with the primary button this frame.
    pub fn wasClicked(_: *const Runtime, tree: *const Tree, handle: NodeHandle) bool {
        if (!tree.isAlive(handle)) return false;
        return tree.getConst(handle).interaction.primary_clicked;
    }

    /// Check if a widget was activated with the secondary button this frame.
    pub fn wasSecondaryClicked(_: *const Runtime, tree: *const Tree, handle: NodeHandle) bool {
        if (!tree.isAlive(handle)) return false;
        return tree.getConst(handle).interaction.secondary_clicked;
    }

    /// Get the most recent secondary click that occurred this frame, if any.
    pub fn lastSecondaryClick(self: *const Runtime) ?SecondaryClick {
        return self.mouse.last_secondary_click;
    }

    /// Get the most recent completed drop that occurred this frame, if
    /// any. The returned `Drop` is a tagged union — switch on it to get
    /// the specific drop kind (tree, grid, list, table, widget).
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

    /// Mark a widget as a generic drop target for active item drags.
    pub fn setDropTarget(_: *Runtime, tree: *Tree, handle: NodeHandle, accepts_drop: bool) void {
        if (!tree.isAlive(handle)) return;
        tree.get(handle).interaction.accepts_drop = accepts_drop;
    }

    /// Check whether a generic drop is currently hovering this widget.
    pub fn isDropHovered(_: *const Runtime, tree: *const Tree, handle: NodeHandle) bool {
        if (!tree.isAlive(handle)) return false;
        return tree.getConst(handle).interaction.drop_hovered;
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

    /// Generate the renderer-facing draw command list.
    ///
    /// The returned slice is owned by the Runtime. It stays valid until
    /// the next call to `generateDrawList`, `generatePaintList`, or
    /// `deinit` on this runtime — those are the only paths that free
    /// the underlying memory. Other state changes (events, tree
    /// mutation, theme/dimension changes) only set the dirty flag; the
    /// previous list keeps pointing at allocated memory until you
    /// regenerate. Copy the slice if you need it to outlive the next
    /// regeneration.
    pub fn generateDrawList(self: *Runtime, tree: *const Tree, theme: Theme) !DrawList {
        if (!self.draw_dirty) {
            if (self.cached_draw_list) |cached| return cached;
        }
        const paint_list = try self.generatePaintList(tree, theme);
        const dl = try draw.lowerPaintList(paint_list, self.allocator, self.text_measure_ctx);
        self.cached_draw_list = dl;
        return dl;
    }

    /// Generate the semantic paint command list. Same lifetime rules as
    /// `generateDrawList`.
    pub fn generatePaintList(self: *Runtime, tree: *const Tree, theme: Theme) !PaintList {
        if (!self.draw_dirty) {
            if (self.cached_paint_list) |cached| return cached;
        }
        self.invalidateDrawCache();
        const paint_list = try draw.generatePaint(tree, theme, self.allocator, self.text_measure_ctx, .{});
        self.cached_paint_list = paint_list;
        self.draw_dirty = false;
        return paint_list;
    }

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

/// `Context` is a thin lifecycle layer over `Runtime`. It owns one
/// `Tree`, one `Theme`, an optional `Clipboard`, and a `Runtime` —
/// just enough so the common single-tree case doesn't have to declare
/// each piece separately.
///
/// The methods on `Context` are intentionally minimal: only the
/// frame-loop entry points that bundle multiple fields (events,
/// layout, draw, dimensions) and the constructor/destructor. Per-
/// handle queries and mutations live on `Runtime` and are reached
/// through `ctx.runtime.foo(&ctx.tree, ...)`. Embedders that drive
/// multiple trees use `Runtime` directly with caller-owned trees.
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

    /// Queue an input event for processing. See `Runtime.pushEvent` for
    /// the coalescing contract on consecutive mouse_move and mouse_scroll
    /// events.
    pub fn pushEvent(self: *Context, ev: Event) !void {
        try self.runtime.pushEvent(ev);
    }

    /// Process all queued events. Call after `doLayout`.
    pub fn processEvents(self: *Context) void {
        self.runtime.processEvents(&self.tree, self.theme, self.clipboard);
    }

    /// Clear transient activation/change flags. Call at the start of each
    /// frame so clicks, toggles, and selection changes are only observed
    /// for one frame.
    pub fn clearClickedFlags(self: *Context) void {
        self.runtime.clearClickedFlags(&self.tree);
    }

    /// Run layout. Pass a `TextMeasureCtx` for accurate text sizing or
    /// null for a rough character-width estimate.
    pub fn doLayout(self: *Context, text_ctx: ?*const TextMeasureCtx) void {
        self.runtime.doLayout(&self.tree, self.theme, text_ctx);
    }

    /// Generate the renderer-facing draw list. See
    /// `Runtime.generateDrawList` for lifetime rules.
    pub fn generateDrawList(self: *Context) !DrawList {
        return self.runtime.generateDrawList(&self.tree, self.theme);
    }

    /// Generate the semantic paint list. See `Runtime.generatePaintList`
    /// for lifetime rules.
    pub fn generatePaintList(self: *Context) !PaintList {
        return self.runtime.generatePaintList(&self.tree, self.theme);
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

// Small view-based helpers used by tests below. Embedders that want
// the same conveniences are expected to write their own — these are
// intentionally not part of the public API.

fn testIsChecked(ctx: *const Context, h: NodeHandle) bool {
    const v = ctx.runtime.widget(&ctx.tree, h) orelse return false;
    return switch (v) {
        .checkbox => |w| w.checked,
        .menu_item => |w| w.checked,
        else => false,
    };
}

fn testIsSelected(ctx: *const Context, h: NodeHandle) bool {
    const v = ctx.runtime.widget(&ctx.tree, h) orelse return false;
    return switch (v) {
        .radio_button => |w| w.selected,
        .tree_item => |w| w.selected,
        .selectable => |w| w.selected,
        .grid_item => |w| w.selected,
        .table_row => |w| w.selected,
        .tab_item => |w| w.selected,
        else => false,
    };
}

fn testCountSelectedChildren(ctx: *const Context, parent: NodeHandle) u16 {
    var count: u16 = 0;
    var iter = ctx.tree.children(parent);
    while (iter.next()) |child| {
        if (testIsSelected(ctx, child)) count += 1;
    }
    return count;
}

fn testFirstSelectedChildIndex(ctx: *const Context, parent: NodeHandle) ?u16 {
    var index: u16 = 0;
    var iter = ctx.tree.children(parent);
    while (iter.next()) |child| {
        if (testIsSelected(ctx, child)) return index;
        index += 1;
    }
    return null;
}

fn testFirstSelectedSelectableIndex(ctx: *const Context, parent: NodeHandle) ?u16 {
    var index: u16 = 0;
    var iter = ctx.tree.children(parent);
    while (iter.next()) |child| {
        const v = ctx.runtime.widget(&ctx.tree, child) orelse continue;
        if (v != .selectable) continue;
        if (v.selectable.selected) return index;
        index += 1;
    }
    return null;
}

fn testFirstSelectedGridItemIndex(ctx: *const Context, parent: NodeHandle) ?u16 {
    var index: u16 = 0;
    var iter = ctx.tree.children(parent);
    while (iter.next()) |child| {
        const v = ctx.runtime.widget(&ctx.tree, child) orelse continue;
        if (v != .grid_item) continue;
        if (v.grid_item.selected) return index;
        index += 1;
    }
    return null;
}

fn testCountSelectedGridItems(ctx: *const Context, parent: NodeHandle) u16 {
    var count: u16 = 0;
    var iter = ctx.tree.children(parent);
    while (iter.next()) |child| {
        const v = ctx.runtime.widget(&ctx.tree, child) orelse continue;
        if (v == .grid_item and v.grid_item.selected) count += 1;
    }
    return count;
}

fn testCountSelectedDataRows(ctx: *const Context, parent: NodeHandle) u16 {
    var count: u16 = 0;
    var iter = ctx.tree.children(parent);
    while (iter.next()) |child| {
        const v = ctx.runtime.widget(&ctx.tree, child) orelse continue;
        if (v != .table_row) continue;
        if (v.table_row.header) continue;
        if (v.table_row.selected) count += 1;
    }
    return count;
}

fn testFirstSelectedDataRowIndex(ctx: *const Context, parent: NodeHandle) ?u16 {
    var index: u16 = 0;
    var iter = ctx.tree.children(parent);
    while (iter.next()) |child| {
        const v = ctx.runtime.widget(&ctx.tree, child) orelse continue;
        if (v != .table_row) continue;
        if (v.table_row.header) continue;
        if (v.table_row.selected) return index;
        index += 1;
    }
    return null;
}

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
    const draw_list = try runtime.generateDrawList(&tree, .{});

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
    const dl = try ctx.generateDrawList();

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

    try std.testing.expect(ctx.runtime.wasClicked(&ctx.tree, btn));

    // After clearing, clicked should be false
    ctx.clearClickedFlags();
    try std.testing.expect(!ctx.runtime.wasClicked(&ctx.tree, btn));
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

    try std.testing.expect(!testIsChecked(&ctx, cb));

    try ctx.pushEvent(.{ .mouse_button = .{ .button = .left, .state = .pressed, .x = click_x, .y = click_y } });
    try ctx.pushEvent(.{ .mouse_button = .{ .button = .left, .state = .released, .x = click_x, .y = click_y } });
    ctx.processEvents();

    try std.testing.expect(testIsChecked(&ctx, cb));
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

    try std.testing.expect(testIsSelected(&ctx, rb1));
    try std.testing.expect(!testIsSelected(&ctx, rb2));
    try std.testing.expect(ctx.runtime.wasClicked(&ctx.tree, rb1));

    ctx.clearClickedFlags();
    try std.testing.expect(!ctx.runtime.wasClicked(&ctx.tree, rb1));

    // Click rb2 — should deselect rb1
    const rb2_rect = ctx.tree.getConst(rb2).layout_rect;
    try ctx.pushEvent(.{ .mouse_button = .{ .button = .left, .state = .pressed, .x = rb2_rect.x + 5, .y = rb2_rect.y + 5 } });
    try ctx.pushEvent(.{ .mouse_button = .{ .button = .left, .state = .released, .x = rb2_rect.x + 5, .y = rb2_rect.y + 5 } });
    ctx.processEvents();

    try std.testing.expect(!testIsSelected(&ctx, rb1));
    try std.testing.expect(testIsSelected(&ctx, rb2));
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

    const dl1 = try ctx.generateDrawList();
    try std.testing.expect(!ctx.runtime.draw_dirty);

    // Second call without changes returns the cached pointer
    const dl2 = try ctx.generateDrawList();
    try std.testing.expectEqual(dl1.commands.ptr, dl2.commands.ptr);
}

test "draw list regenerated after events" {
    var ctx = try Context.init(std.testing.allocator, .{ .width = 800, .height = 600 });
    defer ctx.deinit();

    const root = try ctx.tree.addRoot(.{ .container = .{} });
    _ = try ctx.tree.addChild(root, .{ .button = .{ .label = "OK" } });

    ctx.doLayout(null);
    const dl1 = try ctx.generateDrawList();
    const ptr1 = dl1.commands.ptr;

    // Pushing an event and processing marks draw dirty
    try ctx.pushEvent(.{ .mouse_move = .{ .x = 50, .y = 50 } });
    ctx.processEvents();
    try std.testing.expect(ctx.runtime.draw_dirty);

    // Regeneration produces a new list (old cache freed internally)
    _ = try ctx.generateDrawList();
    try std.testing.expect(!ctx.runtime.draw_dirty);
    _ = ptr1;
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
    try std.testing.expect(!ctx.runtime.widget(&ctx.tree, parent).?.tree_item.expanded);

    ctx.clearClickedFlags();
    ctx.doLayout(null);
    try std.testing.expectEqual(draw.Rect{ .x = 0, .y = 0, .w = 0, .h = 0 }, ctx.tree.getConst(child).layout_rect);

    try ctx.pushEvent(.{ .mouse_button = .{ .button = .left, .state = .pressed, .x = disclosure_x, .y = disclosure_y } });
    try ctx.pushEvent(.{ .mouse_button = .{ .button = .left, .state = .released, .x = disclosure_x, .y = disclosure_y } });
    ctx.processEvents();
    try std.testing.expect(ctx.runtime.widget(&ctx.tree, parent).?.tree_item.expanded);
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

    const drop = ctx.runtime.lastDrop().?.tree;
    try std.testing.expect(drop.source.eql(first));
    try std.testing.expect(drop.target.eql(second));
    try std.testing.expectEqual(widget.WidgetKind.TreeItem.DropPosition.into, drop.position);

    ctx.clearClickedFlags();
    try std.testing.expect(ctx.runtime.lastDrop() == null);
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

    try std.testing.expect(testIsSelected(&ctx, render));
    try std.testing.expect(!testIsSelected(&ctx, scene));

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
    try std.testing.expectEqual(@as(?u16, 0), testFirstSelectedSelectableIndex(&ctx, list_box));

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

    try std.testing.expect(ctx.runtime.widget(&ctx.tree, list_box).?.list_box.changed);
    try std.testing.expectEqual(@as(?u16, 1), testFirstSelectedSelectableIndex(&ctx, list_box));
    try std.testing.expect(testIsSelected(&ctx, camera));
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
    try std.testing.expectEqual(@as(?u16, 0), testFirstSelectedGridItemIndex(&ctx, grid));

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

    try std.testing.expect(ctx.runtime.widget(&ctx.tree, grid).?.grid_selector.changed);
    try std.testing.expectEqual(@as(u16, 2), testCountSelectedGridItems(&ctx, grid));
    try std.testing.expect(testIsSelected(&ctx, metal));
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
    ctx.runtime.setUserId(&ctx.tree, first, 101);
    ctx.runtime.setUserId(&ctx.tree, second, 102);

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

    const pointer = ctx.runtime.pointerPosition();
    try std.testing.expect(ctx.runtime.isPointerButtonDown(.left));
    try std.testing.expect(ctx.runtime.activeDragSource().?.eql(first));
    try std.testing.expectApproxEqAbs(second_rect.x + second_rect.w * 0.5, pointer.x, 0.01);
    try std.testing.expectEqual(@as(u64, 101), ctx.runtime.userId(&ctx.tree, first));

    try ctx.pushEvent(.{ .mouse_button = .{
        .button = .left,
        .state = .released,
        .x = second_rect.x + second_rect.w * 0.5,
        .y = second_rect.y + second_rect.h * 0.5,
    } });
    ctx.processEvents();

    const drop = ctx.runtime.lastDrop().?.grid;
    try std.testing.expect(drop.source.eql(first));
    try std.testing.expect(drop.target.eql(second));
    try std.testing.expectEqual(dispatch.GridDrop.Position.item, drop.position);
    try std.testing.expect(!ctx.runtime.isPointerButtonDown(.left));

    ctx.clearClickedFlags();
    try std.testing.expect(ctx.runtime.lastDrop() == null);
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
    ctx.runtime.setUserId(&ctx.tree, scene, 201);
    ctx.runtime.setUserId(&ctx.tree, camera, 202);
    ctx.runtime.setUserId(&ctx.tree, light, 203);

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

    try std.testing.expect(ctx.runtime.widget(&ctx.tree, list_box).?.list_box.changed);
    try std.testing.expect(testIsSelected(&ctx, scene));
    try std.testing.expect(testIsSelected(&ctx, camera));
    try std.testing.expectEqual(@as(u16, 2), testCountSelectedChildren(&ctx, list_box));
    {
        // The second selected selectable child of list_box: walk children
        // (selectable-only) and pick ordinal index 1.
        var ordinal: u16 = 0;
        var found: ?NodeHandle = null;
        var found_index: u16 = 0;
        var idx: u16 = 0;
        var iter = ctx.tree.children(list_box);
        while (iter.next()) |child| {
            const v = ctx.runtime.widget(&ctx.tree, child) orelse continue;
            if (v != .selectable) continue;
            if (v.selectable.selected) {
                if (ordinal == 1) {
                    found = child;
                    found_index = idx;
                    break;
                }
                ordinal += 1;
            }
            idx += 1;
        }
        try std.testing.expect(found.?.eql(camera));
        try std.testing.expectEqual(@as(u16, 1), found_index);
        try std.testing.expectEqual(@as(u64, 202), ctx.runtime.userId(&ctx.tree, found.?));
    }

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

    try std.testing.expect(ctx.runtime.widget(&ctx.tree, list_box).?.list_box.changed);
    try std.testing.expect(testIsSelected(&ctx, scene));
    try std.testing.expect(testIsSelected(&ctx, camera));
    try std.testing.expect(testIsSelected(&ctx, light));
    try std.testing.expectEqual(@as(u16, 3), testCountSelectedChildren(&ctx, list_box));
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

    try std.testing.expect(ctx.runtime.widget(&ctx.tree, table).?.table.selection_changed);
    try std.testing.expectEqual(@as(u16, 2), testCountSelectedDataRows(&ctx, table));
    try std.testing.expectEqual(@as(?u16, 0), testFirstSelectedDataRowIndex(&ctx, table));
    try std.testing.expect(testIsSelected(&ctx, first));
    try std.testing.expect(testIsSelected(&ctx, second));

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

    try std.testing.expect(ctx.runtime.widget(&ctx.tree, table).?.table.selection_changed);
    try std.testing.expectEqual(@as(u16, 3), testCountSelectedDataRows(&ctx, table));
    try std.testing.expectEqual(@as(?u16, 0), testFirstSelectedDataRowIndex(&ctx, table));
    try std.testing.expect(testIsSelected(&ctx, third));
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

    try std.testing.expect(ctx.runtime.widget(&ctx.tree, table).?.table.changed);
    try std.testing.expectEqual(@as(?u8, 0), ctx.runtime.widget(&ctx.tree, table).?.table.resized_column);
    try std.testing.expect(ctx.runtime.tableColumnFraction(&ctx.tree, table, 0).? > (1.0 / 3.0));
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

    try std.testing.expect(ctx.runtime.wasClicked(&ctx.tree, table));
    try std.testing.expect(ctx.runtime.widget(&ctx.tree, table).?.table.sort_changed);
    try std.testing.expectEqual(@as(?u8, 1), ctx.runtime.widget(&ctx.tree, table).?.table.sorted_column);
    try std.testing.expectEqual(widget.WidgetKind.Table.SortDirection.ascending, ctx.runtime.widget(&ctx.tree, table).?.table.sort_direction);

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

    try std.testing.expect(ctx.runtime.widget(&ctx.tree, table).?.table.sort_changed);
    try std.testing.expectEqual(@as(?u8, 1), ctx.runtime.widget(&ctx.tree, table).?.table.sorted_column);
    try std.testing.expectEqual(widget.WidgetKind.Table.SortDirection.descending, ctx.runtime.widget(&ctx.tree, table).?.table.sort_direction);
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
