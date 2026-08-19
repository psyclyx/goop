//! `goop` is a retained-mode GUI library. The embedder owns the native
//! window, input pump, text shaper, and renderer; `goop` owns widget
//! state, layout, hit testing, and event dispatch. Visual looks are separate
//! consumers of the resolved UI read model exposed here.
//!
//! Public surface, in rough import order:
//!
//! - `Runtime` is the primitive for one interaction/layout domain: it owns
//!   clay state, the event queue, visual revisions, and hit/dispatch state for
//!   one caller-owned `Tree`. A tree must not move between runtimes while an
//!   interaction is active.
//! - `Context` is the single-tree convenience layer over `Runtime`. It
//!   bundles a `Tree`, `Theme`, optional `Clipboard`, and a `Runtime` so
//!   the common case is one type. Anything `Context` exposes is a thin
//!   forward over `Runtime` plus its bundled tree.
//! - `Tree` holds widget nodes. Add and remove go through `Tree`
//!   directly (`tree.addRoot`, `tree.addChild`, `tree.remove`); the
//!   runtime watches the tree revision and re-runs layout when topology
//!   changes. *In-place* mutations (style overrides, kind payload,
//!   persistent interaction state) must go through `Runtime.setStyle`,
//!   `Runtime.updateWidget`, or `Runtime.mutateKind` (or the matching
//!   `Context` method) so layout and resolved-UI revisions advance.
//!   Reaching into `tree.get(h).foo = ...` silently bypasses invalidation and
//!   may produce stale resolved output.
//! - The everyday primitives (`NodeHandle`, `WidgetKind`, `WidgetView`,
//!   `Style`, `Theme`, `Event`, …) are re-exported at
//!   this level so most code only imports `goop`.
//! - Sub-namespaces (`widget`, `style`, `layout`, `hittest`,
//!   `control_event`) hold helpers and types embedders reach for less often
//!   (rect math, text measurement, hit testing, semantic output payloads).
//!   `dispatch` is intentionally private — it runs through `Runtime`.

const std = @import("std");
const c = @cImport({
    @cInclude("clay.h");
});

pub const widget = @import("widget.zig");
const input_types = @import("goop_input");
pub const style = @import("style.zig");
pub const layout = @import("layout.zig");
pub const hittest = @import("hittest.zig");
pub const geometry = @import("geometry.zig");
pub const scrollbar = @import("scrollbar.zig");
pub const control_event = @import("control_event.zig");
pub const visual = @import("goop_visual");

const dispatch = @import("dispatch.zig");

pub const Tree = widget.Tree;
pub const NodeHandle = widget.NodeHandle;
pub const WidgetKind = widget.WidgetKind;
pub const WidgetDesc = widget.WidgetDesc;
pub const WidgetView = widget.WidgetView;
pub const NodeView = widget.NodeView;
pub const TextEditState = widget.TextEditState;
pub const kindFromDesc = widget.kindFromDesc;

// Tree-walking helpers commonly reached for by embedders. Internal
// helpers (gridItemParentSelector, tableEffectiveColumnCount,
// syncDerivedState) intentionally stay in the `widget` namespace.
pub const tableHeaderRow = widget.tableHeaderRow;
pub const tableReferenceRow = widget.tableReferenceRow;
pub const tableRowCellCount = widget.tableRowCellCount;
pub const tableCellAt = widget.tableCellAt;
pub const tableResizeHandleRect = widget.tableResizeHandleRect;
pub const tableResizeHandleIndexAtPoint = widget.tableResizeHandleIndexAtPoint;
pub const tableHeaderCellIndexAtPoint = widget.tableHeaderCellIndexAtPoint;
pub const tableRowSelectable = widget.tableRowSelectable;
pub const tableDataRowIndex = widget.tableDataRowIndex;
pub const gridSelectorItemCount = widget.gridSelectorItemCount;
pub const gridItemAt = widget.gridItemAt;
pub const gridItemIndex = widget.gridItemIndex;
pub const Rect = visual.Rect;
pub const Event = input_types.Event;
pub const Theme = style.Theme;
pub const Style = style.Style;
pub const Color = style.Color;
pub const TextAlign = visual.TextAlign;
pub const TextOverflow = visual.TextOverflow;
pub const IconId = visual.IconId;
pub const StockIcon = visual.StockIcon;
pub const PointerCursor = enum {
    default,
    text,
    resize_horizontal,
    resize_vertical,
};
pub const UpdateResult = dispatch.UpdateResult;
pub const TextMeasureCtx = layout.TextMeasureCtx;
pub const MeasureTextFn = layout.MeasureTextFn;
pub const TextDimensions = layout.TextDimensions;
pub const ElementId = control_event.ElementId;
pub const ActionId = control_event.ActionId;
pub const ControlEvent = control_event.ControlEvent;
pub const ControlEvents = control_event.ControlEvents;
pub const Activation = control_event.Activation;
pub const SecondaryActivation = control_event.SecondaryActivation;
pub const ValueChanged = control_event.ValueChanged;
pub const ToggleChanged = control_event.ToggleChanged;
pub const TextChanged = control_event.TextChanged;
pub const SortChanged = control_event.SortChanged;
pub const SelectionChanged = control_event.SelectionChanged;
pub const ScrollChanged = control_event.ScrollChanged;
pub const PopupVisibilityChanged = control_event.PopupVisibilityChanged;
pub const ControlDrop = control_event.Drop;
pub const ControlIdentity = widget.ControlIdentity;
pub const ControlDesc = widget.ControlDesc;

pub const Clipboard = dispatch.Clipboard;
/// Plain resolved UI state supplied to a custom look.
///
/// The value contains no retained storage identity. String slices inside
/// `widget` borrow from the tree and remain valid only until the next mutation
/// that touches their source node.
pub const ResolvedElement = struct {
    id: ?ElementId,
    parent_id: ?ElementId,
    action_id: ?ActionId,
    bounds: Rect,
    style: style.ResolvedStyle,
    widget: WidgetView,
    focused: bool,
    hovered: bool,
    pressed: bool,
    drop_hovered: bool,
};

fn visitResolvedSubtree(
    tree: *const Tree,
    theme: Theme,
    handle: NodeHandle,
    visitor: anytype,
) !void {
    const node = tree.getConst(handle);
    const resolved: ResolvedElement = .{
        .id = node.element_id,
        .parent_id = if (node.parent) |parent|
            tree.getConst(parent).element_id
        else
            null,
        .action_id = node.action_id,
        .bounds = node.layout_rect,
        .style = node.style_override.resolve(theme),
        .widget = WidgetView.fromNode(node),
        .focused = node.interaction.focused,
        .hovered = node.interaction.hovered,
        .pressed = node.interaction.pressed,
        .drop_hovered = node.interaction.drop_hovered,
    };
    try deliverResolvedEnter(visitor, resolved);

    var child = node.first_child;
    while (child) |current| {
        try visitResolvedSubtree(tree, theme, current, visitor);
        child = tree.getConst(current).next_sibling;
    }
    try deliverResolvedLeave(visitor, resolved);
}

fn deliverResolvedEnter(visitor: anytype, element: ResolvedElement) !void {
    const Return = @TypeOf(visitor.enter(element));
    switch (@typeInfo(Return)) {
        .void => visitor.enter(element),
        .error_union => |error_union| {
            if (error_union.payload != void) {
                @compileError("resolved enter visitor must return void or an error union with void payload");
            }
            try visitor.enter(element);
        },
        else => @compileError("resolved enter visitor must return void or an error union with void payload"),
    }
}

fn deliverResolvedLeave(visitor: anytype, element: ResolvedElement) !void {
    const Return = @TypeOf(visitor.leave(element));
    switch (@typeInfo(Return)) {
        .void => visitor.leave(element),
        .error_union => |error_union| {
            if (error_union.payload != void) {
                @compileError("resolved leave visitor must return void or an error union with void payload");
            }
            try visitor.leave(element);
        },
        else => @compileError("resolved leave visitor must return void or an error union with void payload"),
    }
}

/// Read-only capability used by `goop_chrome` for hierarchy-aware stock
/// visuals. Custom looks should consume `ResolvedElement` values through
/// `Context.visitResolved`. This capability owns nothing and cannot mutate
/// core state.
pub const ChromeState = struct {
    tree: *const Tree,
    theme: Theme,
    text_measure: ?*const TextMeasureCtx,
    revision: u64,
};

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    clay_arena: []u8,
    clay_context: *c.Clay_Context,
    events: std.ArrayListUnmanaged(Event),
    control_journal: control_event.Journal = .{},
    mouse: dispatch.MouseState = .{},
    tooltips: dispatch.TooltipState = .{},
    now_ms: u64 = 0,
    text_measure_ctx: ?*const TextMeasureCtx = null,
    layout_dirty: bool = true,
    visual_revision: u64 = 1,
    last_tree_revision: u64 = 0,

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
        self.control_journal.deinit(self.allocator);
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
    /// All other events are appended verbatim. If an embedder needs every
    /// pointer sample (for example, freehand drawing), process the current
    /// batch before queuing the next sample.
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

    /// Mark layout and resolved visual state stale after caller-owned changes.
    pub fn invalidate(self: *Runtime) void {
        self.layout_dirty = true;
        self.bumpVisualRevision();
    }

    /// Process queued input and return semantic control output in occurrence
    /// order. The returned batch borrows Runtime storage and remains valid
    /// until the next call to this method or `deinit`.
    /// Variable-size text and selection payloads are resolved with
    /// `ControlEvents.text` and `ControlEvents.selection`.
    ///
    /// Output storage for the full queued batch grows before dispatch starts
    /// and is retained across calls. Callers with strict frame-time allocation
    /// requirements can warm the runtime by processing representative input
    /// during setup.
    pub fn processEvents(self: *Runtime, tree: *Tree, theme: Theme, clipboard: ?Clipboard) !ControlEvents {
        self.control_journal.clearRetainingCapacity();
        try self.control_journal.prepareBatch(self.allocator, tree.count(), self.events.items.len);
        const had_input = self.events.items.len != 0;
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
        // Input can revise persistent visual state such as hover, press,
        // focus, selection, or an open popup. Idle batches remain stable so
        // caller-owned look caches can be reused.
        if (had_input) self.bumpVisualRevision();
        dispatch.process(
            tree,
            self.events.items,
            &self.mouse,
            theme,
            clipboard,
            self.text_measure_ctx,
            &self.control_journal,
        );
        const timed = dispatch.updateTimedState(tree, &self.mouse, &self.tooltips, self.now_ms);
        if (timed.changed) {
            self.layout_dirty = true;
            self.bumpVisualRevision();
        }
        if (self.layout_dirty or self.mouse.layout_changed) {
            const previous = self.bindClayContext();
            defer c.Clay_SetCurrentContext(previous);
            layout.run(tree, theme, self.text_measure_ctx);
            self.layout_dirty = false;
            self.bumpVisualRevision();
            self.last_tree_revision = tree.revision();
            self.mouse.layout_changed = false;
        }
        self.events.clearRetainingCapacity();
        return self.control_journal.view();
    }

    /// Replace a widget's payload with the provided descriptor. The
    /// desc tag must match the widget's current kind. Returns true on
    /// success, false if the handle is dead or the tag does not match.
    /// Marks the runtime dirty. Runtime-owned interaction state is reset to
    /// defaults; for surgical edits to
    /// existing state use `mutateKind` instead.
    pub fn updateWidget(self: *Runtime, tree: *Tree, handle: NodeHandle, desc: WidgetDesc) bool {
        if (!tree.isAlive(handle)) return false;
        const node = tree.get(handle);
        if (@as(std.meta.Tag(WidgetKind), node.kind) != @as(std.meta.Tag(WidgetDesc), desc)) return false;
        node.kind = widget.kindFromDesc(desc);
        widget.syncDerivedState(&node.kind);
        self.invalidate();
        return true;
    }

    /// Replace a widget's per-node style overrides. Returns false if
    /// the handle is dead. Marks the runtime dirty so the change
    /// advances layout and resolved visual state.
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
    /// touch, so it advances both layout and resolved visual state.
    pub fn mutateKind(self: *Runtime, tree: *Tree, handle: NodeHandle) ?*WidgetKind {
        if (!tree.isAlive(handle)) return null;
        self.invalidate();
        return &tree.get(handle).kind;
    }

    /// Advance runtime-owned time-driven interaction state.
    ///
    /// `now_ms` is an absolute monotonic timestamp supplied by the host. Time
    /// never moves backwards if a host clock sample regresses. The returned
    /// absolute deadline is the next time calling `update` can change state;
    /// hosts may sleep until it instead of continuously repainting.
    pub fn update(self: *Runtime, tree: *Tree, now_ms: u64) UpdateResult {
        self.now_ms = @max(self.now_ms, now_ms);
        const result = dispatch.updateTimedState(tree, &self.mouse, &self.tooltips, self.now_ms);
        if (result.changed) {
            self.layout_dirty = true;
            self.bumpVisualRevision();
        }
        return result;
    }

    /// Return the caller-owned semantic identity of the focused control.
    /// Stale retained handles are contained inside the runtime and surface as
    /// null rather than crossing this boundary.
    pub fn focusedElementId(self: *const Runtime, tree: *const Tree) ?ElementId {
        const focused = self.mouse.focused orelse return null;
        return tree.elementId(focused);
    }

    /// Return the semantic identity of the active drag source, if it has one.
    /// Hosts can use this stable ID to begin native drag-and-drop without
    /// exposing retained node handles across the runtime boundary.
    pub fn draggedElementId(self: *const Runtime, tree: *const Tree) ?ElementId {
        const dragged = self.mouse.drag_target orelse return null;
        if (!tree.isAlive(dragged)) return null;
        return tree.elementId(dragged);
    }

    /// Backend-neutral cursor intent for the current pointer/capture state.
    /// The host maps this value to its native cursor resources.
    pub fn pointerCursor(self: *const Runtime, tree: *const Tree, theme: Theme) PointerCursor {
        const target = self.mouse.drag_target orelse hittest.hitTestWithTheme(tree, self.mouse.x, self.mouse.y, theme) orelse return .default;
        if (!tree.isAlive(target)) return .default;
        const node = tree.getConst(target);
        return switch (node.kind) {
            .text_input => .text,
            .splitter => |splitter| switch (splitter.direction) {
                .row => .resize_horizontal,
                .column => .resize_vertical,
            },
            .table => if (widget.tableResizeHandleIndexAtPoint(tree, target, self.mouse.x, self.mouse.y) != null)
                .resize_horizontal
            else if (self.mouse.drag_target != null and self.mouse.drag_column_index != null)
                .resize_horizontal
            else
                .default,
            else => .default,
        };
    }

    /// True while the pointer is captured by a pressed/dragging control.
    /// Hosts use this to avoid synthesizing a hover-leave position in the
    /// middle of a native implicit pointer grab.
    pub fn pointerGestureActive(self: *const Runtime) bool {
        return self.mouse.left_down or self.mouse.right_down or self.mouse.drag_target != null;
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
        self.bumpVisualRevision();
        return true;
    }

    /// Clear keyboard focus.
    pub fn clearFocus(self: *Runtime, tree: *Tree) void {
        for (tree.nodes.items) |*node| {
            if (node.alive) node.interaction.focused = false;
        }
        self.mouse.focused = null;
        self.bumpVisualRevision();
    }

    /// Cancel the active pointer gesture, clearing any drag or marquee state.
    pub fn cancelPointerGesture(self: *Runtime, tree: *Tree) void {
        dispatch.cancelPointerGesture(tree, &self.mouse);
        self.bumpVisualRevision();
    }

    /// Run layout: walk the widget tree through clay and write back rects.
    /// Skips the full clay pass if nothing layout-affecting has changed.
    /// Pass a TextMeasureCtx for accurate snail-based text measurement,
    /// or null to use a rough character-width approximation.
    pub fn doLayout(self: *Runtime, tree: *Tree, theme: Theme, text_ctx: ?*const TextMeasureCtx) void {
        self.text_measure_ctx = text_ctx;
        const current_revision = tree.revision();
        if (!self.layout_dirty and current_revision == self.last_tree_revision) return;
        const previous = self.bindClayContext();
        defer c.Clay_SetCurrentContext(previous);
        layout.run(tree, theme, text_ctx);
        self.layout_dirty = false;
        self.bumpVisualRevision();
        self.last_tree_revision = current_revision;
    }

    /// Visit resolved UI values for a custom look.
    ///
    /// The visitor is statically dispatched and must provide exact
    /// `enter(ResolvedElement)` and `leave(ResolvedElement)` methods returning `void` or
    /// `!void`. Every successful enter receives one leave after its descendants,
    /// allowing custom looks to emit balanced clips and surfaces without
    /// reconstructing the hierarchy. Traversal is allocation-free and
    /// depth-first in logical sibling order.
    /// The visitor must not mutate `tree` during the call: resolved strings
    /// borrow node storage and traversal holds the current structural position.
    /// Multiple root order is deliberately unspecified. Floating subtrees stay
    /// inline at their logical position; the custom look owns layering policy.
    pub fn visitResolved(
        self: *const Runtime,
        tree: *const Tree,
        theme: Theme,
        visitor: anytype,
    ) !void {
        _ = self;
        for (tree.nodes.items, 0..) |*node, index| {
            if (!node.alive or node.parent != null) continue;
            try visitResolvedSubtree(tree, theme, tree.handleFromIndex(@intCast(index)), visitor);
        }
    }

    /// Borrow the hierarchy-aware capability consumed by stock Chrome.
    pub fn chromeState(self: *const Runtime, tree: *const Tree, theme: Theme) ChromeState {
        return .{
            .tree = tree,
            .theme = theme,
            .text_measure = self.text_measure_ctx,
            .revision = self.visual_revision,
        };
    }

    fn bumpVisualRevision(self: *Runtime) void {
        self.visual_revision +%= 1;
        if (self.visual_revision == 0) self.visual_revision = 1;
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
/// Every method here is a thin forward to the matching `Runtime` /
/// `Tree` method, with the bundled tree/theme/clipboard supplied
/// implicitly. `Runtime` is still available when the caller wants to own its
/// tree/theme separately, but one Runtime represents one interaction/layout
/// domain and its one active tree.
///
/// Read-only access to `tree`, `theme`, `runtime`, and `clipboard` is
/// fine. Mutating state should go through the methods below
/// (especially `setTheme` / `setClipboard`) so layout and visual revisions
/// stay correct.
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

    // --- Frame loop ----------------------------------------------------

    /// Queue an input event for processing. See `Runtime.pushEvent` for
    /// the coalescing contract on consecutive mouse_move and mouse_scroll
    /// events.
    pub fn pushEvent(self: *Context, ev: Event) !void {
        try self.runtime.pushEvent(ev);
    }

    /// Process queued input and borrow the ordered semantic output batch.
    /// See `Runtime.processEvents` for lifetime and allocation rules.
    pub fn processEvents(self: *Context) !ControlEvents {
        return self.runtime.processEvents(&self.tree, self.theme, self.clipboard);
    }

    /// Run layout. Pass a `TextMeasureCtx` for accurate text sizing or
    /// null for a rough character-width estimate.
    pub fn doLayout(self: *Context, text_ctx: ?*const TextMeasureCtx) void {
        self.runtime.doLayout(&self.tree, self.theme, text_ctx);
    }

    /// Visit the allocation-free, handle-free values used by custom looks.
    /// See `Runtime.visitResolved` for the visitor and ordering contract.
    pub fn visitResolved(self: *const Context, visitor: anytype) !void {
        return self.runtime.visitResolved(&self.tree, self.theme, visitor);
    }

    /// Borrow the hierarchy-aware, read-only capability used by stock Chrome.
    pub fn chromeState(self: *const Context) ChromeState {
        return self.runtime.chromeState(&self.tree, self.theme);
    }

    /// Update layout dimensions (e.g. on window resize).
    pub fn setDimensions(self: *Context, width: u32, height: u32) void {
        self.runtime.setDimensions(width, height);
    }

    // --- Settings ------------------------------------------------------

    /// Replace the active theme. Advances layout and resolved visual state.
    pub fn setTheme(self: *Context, theme: Theme) void {
        self.theme = theme;
        self.runtime.invalidate();
    }

    /// Set or clear the embedder-supplied clipboard provider. Pass null
    /// to detach. No invalidation needed — clipboard only takes effect on
    /// the next event dispatch.
    pub fn setClipboard(self: *Context, clipboard: ?Clipboard) void {
        self.clipboard = clipboard;
    }

    // --- Per-handle mutations (forward to Runtime) --------------------

    /// Replace a widget's payload. See `Runtime.updateWidget`.
    pub fn updateWidget(self: *Context, handle: NodeHandle, desc: WidgetDesc) bool {
        return self.runtime.updateWidget(&self.tree, handle, desc);
    }

    /// Replace a widget's per-node style overrides. See `Runtime.setStyle`.
    pub fn setStyle(self: *Context, handle: NodeHandle, override: Style) bool {
        return self.runtime.setStyle(&self.tree, handle, override);
    }

    /// Borrow a mutable pointer to a widget's payload for in-place
    /// edits. See `Runtime.mutateKind`.
    pub fn mutateKind(self: *Context, handle: NodeHandle) ?*WidgetKind {
        return self.runtime.mutateKind(&self.tree, handle);
    }

    /// Advance layout and resolved visual state after caller-owned changes.
    /// See `Runtime.invalidate`.
    pub fn invalidate(self: *Context) void {
        self.runtime.invalidate();
    }

    /// Advance the host-supplied monotonic clock and time-driven UI state.
    pub fn update(self: *Context, now_ms: u64) UpdateResult {
        return self.runtime.update(&self.tree, now_ms);
    }

    // --- Focus / gestures ----------------------------------------------

    pub fn focusedElementId(self: *const Context) ?ElementId {
        return self.runtime.focusedElementId(&self.tree);
    }

    pub fn draggedElementId(self: *const Context) ?ElementId {
        return self.runtime.draggedElementId(&self.tree);
    }

    pub fn pointerCursor(self: *const Context) PointerCursor {
        return self.runtime.pointerCursor(&self.tree, self.theme);
    }

    pub fn pointerGestureActive(self: *const Context) bool {
        return self.runtime.pointerGestureActive();
    }

    /// Set keyboard focus to a live widget. See `Runtime.focusWidget`.
    pub fn focusWidget(self: *Context, handle: NodeHandle) bool {
        return self.runtime.focusWidget(&self.tree, handle);
    }

    /// Clear keyboard focus. See `Runtime.clearFocus`.
    pub fn clearFocus(self: *Context) void {
        self.runtime.clearFocus(&self.tree);
    }

    /// Cancel the active pointer gesture. See `Runtime.cancelPointerGesture`.
    pub fn cancelPointerGesture(self: *Context) void {
        self.runtime.cancelPointerGesture(&self.tree);
    }

    pub const InitOptions = struct {
        width: u32 = 800,
        height: u32 = 600,
        theme: Theme = .{},
    };
};

// =============================================================
// Test-only helpers (file-private, used by the tests below this
// block). Not part of the public API. Embedders that want similar
// conveniences should write their own off the `WidgetView` /
// `NodeView` values returned by `tree.node(handle)`.
// =============================================================

fn testIsChecked(ctx: *const Context, h: NodeHandle) bool {
    const n = ctx.tree.node(h) orelse return false;
    return switch (n.kind) {
        .checkbox => |w| w.checked,
        .menu_item => |w| w.checked,
        else => false,
    };
}

fn testIsSelected(ctx: *const Context, h: NodeHandle) bool {
    const n = ctx.tree.node(h) orelse return false;
    return switch (n.kind) {
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
        const n = ctx.tree.node(child) orelse continue;
        if (n.kind != .selectable) continue;
        if (n.kind.selectable.selected) return index;
        index += 1;
    }
    return null;
}

fn testFirstSelectedGridItemIndex(ctx: *const Context, parent: NodeHandle) ?u16 {
    var index: u16 = 0;
    var iter = ctx.tree.children(parent);
    while (iter.next()) |child| {
        const n = ctx.tree.node(child) orelse continue;
        if (n.kind != .grid_item) continue;
        if (n.kind.grid_item.selected) return index;
        index += 1;
    }
    return null;
}

fn testCountSelectedGridItems(ctx: *const Context, parent: NodeHandle) u16 {
    var count: u16 = 0;
    var iter = ctx.tree.children(parent);
    while (iter.next()) |child| {
        const n = ctx.tree.node(child) orelse continue;
        if (n.kind == .grid_item and n.kind.grid_item.selected) count += 1;
    }
    return count;
}

fn testCountSelectedDataRows(ctx: *const Context, parent: NodeHandle) u16 {
    var count: u16 = 0;
    var iter = ctx.tree.children(parent);
    while (iter.next()) |child| {
        const n = ctx.tree.node(child) orelse continue;
        if (n.kind != .table_row) continue;
        if (n.kind.table_row.header) continue;
        if (n.kind.table_row.selected) count += 1;
    }
    return count;
}

fn testFirstSelectedDataRowIndex(ctx: *const Context, parent: NodeHandle) ?u16 {
    var index: u16 = 0;
    var iter = ctx.tree.children(parent);
    while (iter.next()) |child| {
        const n = ctx.tree.node(child) orelse continue;
        if (n.kind != .table_row) continue;
        if (n.kind.table_row.header) continue;
        if (n.kind.table_row.selected) return index;
        index += 1;
    }
    return null;
}

test "context initializes" {
    var ctx = try Context.init(std.testing.allocator, .{});
    defer ctx.deinit();

    try std.testing.expectEqual(@as(u32, 0), ctx.tree.count());
}

test "pointer cursor follows interactive geometry" {
    var ctx = try Context.init(std.testing.allocator, .{ .width = 480, .height = 240 });
    defer ctx.deinit();

    const splitter = try ctx.tree.addRoot(.{ .splitter = .{
        .direction = .row,
        .ratio = 0.5,
        .thickness = 12,
        .gap_thickness = 1,
    } });
    const left = try ctx.tree.addChild(splitter, .{ .container = .{} });
    _ = try ctx.tree.addChild(left, .{ .text_input = .{ .placeholder = "Path" } });
    _ = try ctx.tree.addChild(splitter, .{ .container = .{} });
    ctx.doLayout(null);

    const splitter_node = ctx.tree.getConst(splitter);
    const resolved = splitter_node.style_override.resolve(ctx.theme);
    const handle = geometry.splitterHandleRect(
        geometry.splitterDividerRect(splitter_node.layout_rect, splitter_node.kind.splitter, resolved),
        splitter_node.kind.splitter,
    );
    try ctx.pushEvent(.{ .mouse_move = .{ .x = handle.x + handle.w * 0.5, .y = handle.y + handle.h * 0.5 } });
    _ = try ctx.processEvents();
    try std.testing.expectEqual(PointerCursor.resize_horizontal, ctx.pointerCursor());

    const input = ctx.tree.getConst(left).first_child.?;
    const input_rect = ctx.tree.getConst(input).layout_rect;
    try ctx.pushEvent(.{ .mouse_move = .{ .x = input_rect.x + 2, .y = input_rect.y + 2 } });
    _ = try ctx.processEvents();
    try std.testing.expectEqual(PointerCursor.text, ctx.pointerCursor());
}

test "dragged element ID exposes semantic identity without retained handles" {
    var ctx = try Context.init(std.testing.allocator, .{ .width = 240, .height = 120 });
    defer ctx.deinit();
    const source = try ctx.tree.addRoot(.{ .button = .{ .label = "Source" } });
    try ctx.tree.setElementId(source, .init(73));
    try std.testing.expect(ctx.draggedElementId() == null);

    ctx.runtime.mouse.drag_target = source;
    try std.testing.expectEqual(ElementId.init(73), ctx.draggedElementId().?);
    try ctx.tree.remove(source);
    try std.testing.expect(ctx.draggedElementId() == null);
}

test "runtime lays out a caller-owned tree" {
    var runtime = try Runtime.init(std.testing.allocator, .{ .width = 800, .height = 600 });
    defer runtime.deinit();

    var tree = Tree.init(std.testing.allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    _ = try tree.addChild(root, .{ .button = .{ .label = "OK" } });

    runtime.doLayout(&tree, .{}, null);
    try std.testing.expect(tree.getConst(root).layout_rect.w > 0);
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

test "custom widgets expose resolved semantic state" {
    var ctx = try Context.init(std.testing.allocator, .{ .width = 320, .height = 200 });
    defer ctx.deinit();

    const custom = try ctx.tree.addRoot(.{ .custom = .{
        .type_id = 42,
        .width = 96,
        .height = 32,
        .focusable = true,
    } });

    ctx.doLayout(null);
    const rect = ctx.tree.getConst(custom).layout_rect;
    try std.testing.expectApproxEqAbs(@as(f32, 96), rect.w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 32), rect.h, 0.01);

    const Collector = struct {
        resolved: ?ResolvedElement = null,

        fn enter(self: *@This(), resolved: ResolvedElement) void {
            std.debug.assert(self.resolved == null);
            self.resolved = resolved;
        }

        fn leave(_: *@This(), _: ResolvedElement) void {}
    };
    var collector: Collector = .{};
    try ctx.visitResolved(&collector);
    const resolved = collector.resolved.?;
    try std.testing.expect(resolved.widget == .custom);
    try std.testing.expectEqual(@as(u32, 42), resolved.widget.custom.type_id);

    try ctx.tree.setControlIdentity(custom, .{ .element_id = .init(900), .action_id = .init(901) });
    try ctx.pushEvent(.{ .mouse_button = .{ .button = .left, .state = .pressed, .x = rect.x + 4, .y = rect.y + 4 } });
    try ctx.pushEvent(.{ .mouse_button = .{ .button = .left, .state = .released, .x = rect.x + 4, .y = rect.y + 4 } });
    const output = try ctx.processEvents();

    try std.testing.expectEqual(@as(usize, 1), output.items.len);
    try std.testing.expect(output.items[0] == .activated);
    try std.testing.expectEqual(ElementId.init(900), output.items[0].activated.element);
    try std.testing.expectEqual(ActionId.init(901), output.items[0].activated.action.?);

    const view = ctx.tree.node(custom).?;
    try std.testing.expect(view.focused);
    try std.testing.expectEqual(WidgetView{ .custom = .{
        .type_id = 42,
        .width = 96,
        .height = 32,
        .min_width = 0,
        .min_height = 0,
        .grow_width = true,
        .grow_height = false,
        .focusable = true,
    } }, view.kind);
}

test "resolved visitor projects nested siblings without handles or allocation" {
    var ctx = try Context.init(std.testing.allocator, .{ .width = 320, .height = 200 });
    defer ctx.deinit();

    const root = try ctx.tree.addRootControl(.{
        .identity = .{ .element_id = .init(10) },
        .widget = .{ .container = .{} },
    });
    const first = try ctx.tree.addChildControl(root, .{
        .identity = .{ .element_id = .init(11), .action_id = .init(111) },
        .widget = .{ .button = .{ .label = "first" } },
    });
    const nested = try ctx.tree.addChildControl(first, .{
        .identity = .{ .element_id = .init(12) },
        .widget = .{ .text = .{ .content = "nested" } },
    });
    _ = try ctx.tree.addChildControl(root, .{
        .identity = .{ .element_id = .init(13) },
        .widget = .{ .custom = .{ .type_id = 7, .width = 20, .height = 10 } },
    });
    try std.testing.expect(ctx.focusWidget(nested));
    ctx.doLayout(null);

    const Draw = struct {
        id: ?ElementId,
        parent_id: ?ElementId,
        action_id: ?ActionId,
        bounds: Rect,
        widget: std.meta.Tag(WidgetView),
        bg: Color,
        focused: bool,
    };
    const CustomRenderer = struct {
        draws: [4]Draw = undefined,
        len: usize = 0,
        depth: usize = 0,
        order: [8]i64 = undefined,
        order_len: usize = 0,

        fn enter(self: *@This(), resolved: ResolvedElement) error{TooManyElements}!void {
            if (self.len == self.draws.len) return error.TooManyElements;
            self.draws[self.len] = .{
                .id = resolved.id,
                .parent_id = resolved.parent_id,
                .action_id = resolved.action_id,
                .bounds = resolved.bounds,
                .widget = resolved.widget,
                .bg = resolved.style.bg,
                .focused = resolved.focused,
            };
            self.depth += 1;
            self.order[self.order_len] = @intCast(resolved.id.?.value());
            self.order_len += 1;
            self.len += 1;
        }

        fn leave(self: *@This(), resolved: ResolvedElement) void {
            self.depth -= 1;
            self.order[self.order_len] = -@as(i64, @intCast(resolved.id.?.value()));
            self.order_len += 1;
        }
    };
    var renderer: CustomRenderer = .{};

    // Once the runtime and tree are set up, the visit must not consult either
    // allocator. Replacing both with an allocator that rejects every request
    // turns a hidden traversal allocation into an immediate test failure.
    const runtime_allocator = ctx.runtime.allocator;
    const tree_allocator = ctx.tree.allocator;
    ctx.runtime.allocator = std.testing.failing_allocator;
    ctx.tree.allocator = std.testing.failing_allocator;
    defer {
        ctx.runtime.allocator = runtime_allocator;
        ctx.tree.allocator = tree_allocator;
    }
    try ctx.visitResolved(&renderer);

    try std.testing.expectEqual(@as(usize, 4), renderer.len);
    try std.testing.expectEqual(@as(usize, 0), renderer.depth);
    try std.testing.expectEqualSlices(i64, &.{ 10, 11, 12, -12, -11, 13, -13, -10 }, renderer.order[0..renderer.order_len]);
    try std.testing.expectEqualSlices(?ElementId, &.{
        ElementId.init(10),
        ElementId.init(11),
        ElementId.init(12),
        ElementId.init(13),
    }, &.{
        renderer.draws[0].id,
        renderer.draws[1].id,
        renderer.draws[2].id,
        renderer.draws[3].id,
    });
    try std.testing.expectEqualSlices(?ElementId, &.{
        null,
        ElementId.init(10),
        ElementId.init(11),
        ElementId.init(10),
    }, &.{
        renderer.draws[0].parent_id,
        renderer.draws[1].parent_id,
        renderer.draws[2].parent_id,
        renderer.draws[3].parent_id,
    });
    try std.testing.expectEqual(ActionId.init(111), renderer.draws[1].action_id.?);
    try std.testing.expectEqual(std.meta.Tag(WidgetView).text, renderer.draws[2].widget);
    try std.testing.expect(renderer.draws[2].focused);
    try std.testing.expect(renderer.draws[0].bounds.w > 0);
}

test "resolved output public data contains no tree or retained handle" {
    comptime {
        if (@hasDecl(@This(), "ResolvedUi")) {
            @compileError("the retained ResolvedUi capability must not be public");
        }
        if (containsType(ResolvedElement, Tree)) {
            @compileError("ResolvedElement must not contain Tree");
        }
        if (containsType(ResolvedElement, NodeHandle)) {
            @compileError("ResolvedElement must not contain NodeHandle");
        }
    }
}

test "icon is a passive resolved leaf and cannot emit semantic events" {
    var ctx = try Context.init(std.testing.allocator, .{ .width = 160, .height = 80 });
    defer ctx.deinit();

    const root = try ctx.tree.addRoot(.{ .container = .{} });
    const icon = try ctx.tree.addChildControl(root, .{
        .identity = .{ .element_id = .init(91), .action_id = .init(92) },
        .widget = .{ .icon = .{ .kind = 17, .color = .rgb(4, 5, 6) } },
    });
    _ = ctx.setStyle(icon, .{ .font_size = 24 });
    ctx.doLayout(null);

    const node = ctx.tree.node(icon).?;
    try std.testing.expect(node.kind == .icon);
    try std.testing.expectEqual(@as(IconId, 17), node.kind.icon.kind);
    try std.testing.expectEqual(Color.rgb(4, 5, 6), node.kind.icon.color.?);
    try std.testing.expect(!@import("focus.zig").isFocusable(ctx.tree.getConst(icon).kind));

    const rect = node.rect;
    const x = rect.x + rect.w * 0.5;
    const y = rect.y + rect.h * 0.5;
    try ctx.pushEvent(.{ .mouse_button = .{ .button = .left, .state = .pressed, .x = x, .y = y } });
    try ctx.pushEvent(.{ .mouse_button = .{ .button = .left, .state = .released, .x = x, .y = y } });
    const output = try ctx.processEvents();
    try std.testing.expectEqual(@as(usize, 0), output.items.len);
    try std.testing.expect(ctx.focusedElementId() == null);
}

test "semantic control output preserves activation order and clears between borrows" {
    var ctx = try Context.init(std.testing.allocator, .{ .width = 800, .height = 600 });
    defer ctx.deinit();

    const root = try ctx.tree.addRoot(.{ .container = .{} });
    const open = try ctx.tree.addChildControl(root, .{
        .identity = .{ .element_id = .init(10), .action_id = .init(100) },
        .widget = .{ .button = .{ .label = "Open" } },
    });
    const hidden = try ctx.tree.addChildControl(root, .{
        .identity = .{ .element_id = .init(20), .action_id = .init(200) },
        .widget = .{ .checkbox = .{ .label = "Hidden" } },
    });
    ctx.doLayout(null);

    const open_rect = ctx.tree.getConst(open).layout_rect;
    const hidden_rect = ctx.tree.getConst(hidden).layout_rect;
    inline for (.{ open_rect, hidden_rect }) |rect| {
        const x = rect.x + rect.w / 2;
        const y = rect.y + rect.h / 2;
        try ctx.pushEvent(.{ .mouse_button = .{ .button = .left, .state = .pressed, .x = x, .y = y } });
        try ctx.pushEvent(.{ .mouse_button = .{ .button = .left, .state = .released, .x = x, .y = y } });
    }

    const output = try ctx.processEvents();
    try std.testing.expectEqual(@as(usize, 3), output.items.len);
    try std.testing.expectEqual(ElementId.init(10), output.items[0].activated.element);
    try std.testing.expectEqual(ActionId.init(100), output.items[0].activated.action.?);
    try std.testing.expectEqual(ElementId.init(20), output.items[1].activated.element);
    try std.testing.expectEqual(ActionId.init(200), output.items[1].activated.action.?);
    try std.testing.expectEqual(ElementId.init(20), output.items[2].toggle_changed.element);
    try std.testing.expect(output.items[2].toggle_changed.value);
    // A new processing call ends the previous borrow and starts a fresh batch,
    // even when the input queue is empty.
    const empty = try ctx.processEvents();
    try std.testing.expectEqual(@as(usize, 0), empty.items.len);
}

test "semantic output reports committed grid drop with stable IDs" {
    var ctx = try Context.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer ctx.deinit();

    const root = try ctx.tree.addRoot(.{ .container = .{} });
    const grid = try ctx.tree.addChildControl(root, .{
        .identity = .{ .element_id = .init(30) },
        .widget = .{ .grid_selector = .{ .selection_mode = .multiple } },
    });
    const source = try ctx.tree.addChildControl(grid, .{
        .identity = .{ .element_id = .init(31) },
        .widget = .{ .grid_item = .{ .label = "Brick" } },
    });
    const target = try ctx.tree.addChildControl(grid, .{
        .identity = .{ .element_id = .init(32) },
        .widget = .{ .grid_item = .{ .label = "Metal" } },
    });

    ctx.tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 400, .h = 300 };
    ctx.tree.get(grid).layout_rect = .{ .x = 10, .y = 10, .w = 220, .h = 130 };
    ctx.tree.get(grid).kind.grid_selector.computed_columns = 2;
    ctx.tree.get(source).layout_rect = .{ .x = 18, .y = 18, .w = 80, .h = 44 };
    ctx.tree.get(target).layout_rect = .{ .x = 106, .y = 18, .w = 80, .h = 44 };

    try ctx.pushEvent(.{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 58, .y = 40 } });
    try ctx.pushEvent(.{ .mouse_move = .{ .x = 146, .y = 40 } });
    try ctx.pushEvent(.{ .mouse_button = .{ .button = .left, .state = .released, .x = 146, .y = 40 } });

    const output = try ctx.processEvents();
    var found_drop: ?control_event.Drop = null;
    for (output.items) |control_output| {
        if (control_output == .drop) found_drop = control_output.drop;
    }
    const drop = found_drop orelse return error.TestExpectedDrop;
    try std.testing.expectEqual(ElementId.init(31), drop.source);
    try std.testing.expectEqual(ElementId.init(32), drop.target);
    try std.testing.expect(drop.position == .item);
}

test "semantic output reports secondary activation and scalar and text values" {
    var ctx = try Context.init(std.testing.allocator, .{ .width = 400, .height = 240 });
    defer ctx.deinit();

    const root = try ctx.tree.addRoot(.{ .container = .{} });
    const button = try ctx.tree.addChildControl(root, .{
        .identity = .{ .element_id = .init(40), .action_id = .init(400) },
        .widget = .{ .button = .{ .label = "Context" } },
    });
    const slider = try ctx.tree.addChildControl(root, .{
        .identity = .{ .element_id = .init(41) },
        .widget = .{ .slider = .{ .min = 0, .max = 100 } },
    });
    const input = try ctx.tree.addChildControl(root, .{
        .identity = .{ .element_id = .init(42) },
        .widget = .{ .text_input = .{ .placeholder = "Name" } },
    });

    ctx.tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 400, .h = 240 };
    ctx.tree.get(button).layout_rect = .{ .x = 10, .y = 10, .w = 100, .h = 30 };
    ctx.tree.get(slider).layout_rect = .{ .x = 10, .y = 50, .w = 200, .h = 30 };
    ctx.tree.get(input).layout_rect = .{ .x = 10, .y = 90, .w = 200, .h = 30 };

    try ctx.pushEvent(.{ .mouse_button = .{ .button = .right, .state = .pressed, .x = 30, .y = 20 } });
    try ctx.pushEvent(.{ .mouse_button = .{ .button = .right, .state = .released, .x = 30, .y = 20 } });
    const secondary = try ctx.processEvents();
    try std.testing.expectEqual(@as(usize, 1), secondary.items.len);
    try std.testing.expectEqual(ElementId.init(40), secondary.items[0].secondary_activated.element);
    try std.testing.expectEqual(ActionId.init(400), secondary.items[0].secondary_activated.action.?);
    try std.testing.expectApproxEqAbs(@as(f32, 30), secondary.items[0].secondary_activated.x, 0.01);

    // Layout has now run, so use the resolved slider rectangle for the click.
    const slider_rect = ctx.tree.getConst(slider).layout_rect;
    const slider_x = slider_rect.x + slider_rect.w * 0.75;
    const slider_y = slider_rect.y + slider_rect.h * 0.5;
    try ctx.pushEvent(.{ .mouse_button = .{ .button = .left, .state = .pressed, .x = slider_x, .y = slider_y } });
    try ctx.pushEvent(.{ .mouse_button = .{ .button = .left, .state = .released, .x = slider_x, .y = slider_y } });
    const scalar = try ctx.processEvents();
    var scalar_value: ?f32 = null;
    for (scalar.items) |output| {
        if (output == .value_changed and output.value_changed.value == .scalar) {
            try std.testing.expectEqual(ElementId.init(41), output.value_changed.element);
            scalar_value = output.value_changed.value.scalar;
        }
    }
    try std.testing.expect(scalar_value != null);
    try std.testing.expect(scalar_value.? > 50);

    try std.testing.expect(ctx.focusWidget(input));
    try ctx.pushEvent(.{ .text = .{ .codepoint = 'h' } });
    try ctx.pushEvent(.{ .text = .{ .codepoint = 'i' } });
    const text_output = try ctx.processEvents();
    try std.testing.expectEqual(@as(usize, 2), text_output.items.len);
    try std.testing.expectEqualStrings("h", text_output.text(text_output.items[0].text_changed));
    try std.testing.expectEqualStrings("hi", text_output.text(text_output.items[1].text_changed));
    try std.testing.expectEqual(ElementId.init(42), text_output.items[1].text_changed.element);
}

test "semantic output reports dropdown index and table sort" {
    var ctx = try Context.init(std.testing.allocator, .{ .width = 640, .height = 360 });
    defer ctx.deinit();

    const root = try ctx.tree.addRoot(.{ .container = .{} });
    const dropdown = try ctx.tree.addChildControl(root, .{
        .identity = .{ .element_id = .init(50) },
        .widget = .{ .dropdown = .{ .placeholder = "Select item" } },
    });
    const popup = try ctx.tree.addChild(dropdown, .{ .popup = .{ .placement = .below_start } });
    const alpha = try ctx.tree.addChild(popup, .{ .menu_item = .{ .label = "Alpha" } });
    const beta = try ctx.tree.addChildControl(popup, .{
        .identity = .{ .element_id = .init(51) },
        .widget = .{ .menu_item = .{ .label = "Beta" } },
    });

    ctx.tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 640, .h = 360 };
    ctx.tree.get(dropdown).layout_rect = .{ .x = 10, .y = 10, .w = 220, .h = 26 };
    ctx.tree.get(popup).layout_rect = .{ .x = 10, .y = 36, .w = 220, .h = 52 };
    ctx.tree.get(alpha).layout_rect = .{ .x = 10, .y = 36, .w = 220, .h = 26 };
    ctx.tree.get(beta).layout_rect = .{ .x = 10, .y = 62, .w = 220, .h = 26 };

    try ctx.pushEvent(.{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 30, .y = 20 } });
    try ctx.pushEvent(.{ .mouse_button = .{ .button = .left, .state = .released, .x = 30, .y = 20 } });
    try ctx.pushEvent(.{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 30, .y = 72 } });
    try ctx.pushEvent(.{ .mouse_button = .{ .button = .left, .state = .released, .x = 30, .y = 72 } });
    const index_output = try ctx.processEvents();
    var selected_index: ?u16 = null;
    for (index_output.items) |output| {
        if (output == .value_changed and output.value_changed.value == .index) {
            try std.testing.expectEqual(ElementId.init(50), output.value_changed.element);
            selected_index = output.value_changed.value.index;
        }
    }
    try std.testing.expectEqual(@as(?u16, 1), selected_index);

    const table = try ctx.tree.addChildControl(root, .{
        .identity = .{ .element_id = .init(52) },
        .widget = .{ .table = .{ .columns = 2, .sortable = true } },
    });
    const header = try ctx.tree.addChild(table, .{ .table_row = .{ .header = true } });
    const name = try ctx.tree.addChild(header, .{ .table_cell = .{} });
    const kind = try ctx.tree.addChild(header, .{ .table_cell = .{} });
    _ = try ctx.tree.addChild(name, .{ .text = .{ .content = "Name" } });
    _ = try ctx.tree.addChild(kind, .{ .text = .{ .content = "Kind" } });
    ctx.invalidate();
    ctx.doLayout(null);

    const kind_rect = ctx.tree.getConst(kind).layout_rect;
    const sort_x = kind_rect.x + kind_rect.w * 0.5;
    const sort_y = kind_rect.y + kind_rect.h * 0.5;
    try ctx.pushEvent(.{ .mouse_button = .{ .button = .left, .state = .pressed, .x = sort_x, .y = sort_y } });
    try ctx.pushEvent(.{ .mouse_button = .{ .button = .left, .state = .released, .x = sort_x, .y = sort_y } });
    const sort_output = try ctx.processEvents();
    try std.testing.expectEqual(@as(usize, 2), sort_output.items.len);
    try std.testing.expectEqual(ElementId.init(52), sort_output.items[0].activated.element);
    try std.testing.expectEqual(ElementId.init(52), sort_output.items[1].sort_changed.element);
    try std.testing.expectEqual(@as(u8, 1), sort_output.items[1].sort_changed.column);
    try std.testing.expectEqual(control_event.SortChanged.Direction.ascending, sort_output.items[1].sort_changed.direction);
}

test "keyboard selection and tree disclosure emit semantic state" {
    var ctx = try Context.init(std.testing.allocator, .{ .width = 640, .height = 480 });
    defer ctx.deinit();

    const root = try ctx.tree.addRoot(.{ .container = .{} });
    const list = try ctx.tree.addChildControl(root, .{
        .identity = .{ .element_id = .init(60) },
        .widget = .{ .list_box = .{} },
    });
    const list_first = try ctx.tree.addChildControl(list, .{
        .identity = .{ .element_id = .init(61) },
        .widget = .{ .selectable = .{ .label = "First", .selected = true } },
    });
    _ = try ctx.tree.addChildControl(list, .{
        .identity = .{ .element_id = .init(62) },
        .widget = .{ .selectable = .{ .label = "Second" } },
    });

    const grid = try ctx.tree.addChildControl(root, .{
        .identity = .{ .element_id = .init(70) },
        .widget = .{ .grid_selector = .{} },
    });
    const grid_first = try ctx.tree.addChildControl(grid, .{
        .identity = .{ .element_id = .init(71) },
        .widget = .{ .grid_item = .{ .label = "First", .selected = true } },
    });
    _ = try ctx.tree.addChildControl(grid, .{
        .identity = .{ .element_id = .init(72) },
        .widget = .{ .grid_item = .{ .label = "Second" } },
    });

    const table = try ctx.tree.addChildControl(root, .{
        .identity = .{ .element_id = .init(80) },
        .widget = .{ .table = .{ .selection_mode = .single } },
    });
    const table_first = try ctx.tree.addChildControl(table, .{
        .identity = .{ .element_id = .init(81) },
        .widget = .{ .table_row = .{ .selected = true } },
    });
    _ = try ctx.tree.addChildControl(table, .{
        .identity = .{ .element_id = .init(82) },
        .widget = .{ .table_row = .{} },
    });

    const tree_item = try ctx.tree.addChildControl(root, .{
        .identity = .{ .element_id = .init(90) },
        .widget = .{ .tree_item = .{ .label = "Parent", .has_children = true, .expanded = true } },
    });
    _ = try ctx.tree.addChild(tree_item, .{ .tree_item = .{ .label = "Child" } });

    try std.testing.expect(ctx.focusWidget(list_first));
    try ctx.pushEvent(.{ .key = .{ .keycode = .down, .state = .pressed } });
    const list_output = try ctx.processEvents();
    try std.testing.expectEqualSlices(ElementId, &.{ElementId.init(62)}, list_output.selection(list_output.items[0].selection_changed));

    try std.testing.expect(ctx.focusWidget(grid_first));
    try ctx.pushEvent(.{ .key = .{ .keycode = .right, .state = .pressed } });
    const grid_output = try ctx.processEvents();
    try std.testing.expectEqualSlices(ElementId, &.{ElementId.init(72)}, grid_output.selection(grid_output.items[0].selection_changed));

    try std.testing.expect(ctx.focusWidget(table_first));
    try ctx.pushEvent(.{ .key = .{ .keycode = .down, .state = .pressed } });
    const table_output = try ctx.processEvents();
    try std.testing.expectEqualSlices(ElementId, &.{ElementId.init(82)}, table_output.selection(table_output.items[0].selection_changed));

    try std.testing.expect(ctx.focusWidget(tree_item));
    try ctx.pushEvent(.{ .key = .{ .keycode = .left, .state = .pressed } });
    const tree_output = try ctx.processEvents();
    try std.testing.expectEqual(@as(usize, 1), tree_output.items.len);
    try std.testing.expectEqual(ElementId.init(90), tree_output.items[0].toggle_changed.element);
    try std.testing.expect(!tree_output.items[0].toggle_changed.value);
}

test "wheel scrolling emits observable scroll position" {
    var ctx = try Context.init(std.testing.allocator, .{ .width = 320, .height = 240 });
    defer ctx.deinit();

    const scroll = try ctx.tree.addRootControl(.{
        .identity = .{ .element_id = .init(100) },
        .widget = .{ .scroll_area = .{} },
    });
    const content = try ctx.tree.addChild(scroll, .{ .text = .{ .content = "tall" } });
    ctx.tree.get(scroll).layout_rect = .{ .x = 10, .y = 10, .w = 100, .h = 80 };
    ctx.tree.get(content).layout_rect = .{ .x = 10, .y = 10, .w = 100, .h = 300 };

    try ctx.pushEvent(.{ .mouse_move = .{ .x = 40, .y = 40 } });
    try ctx.pushEvent(.{ .mouse_scroll = .{ .dx = 0, .dy = 35 } });
    const output = try ctx.processEvents();
    try std.testing.expectEqual(@as(usize, 1), output.items.len);
    try std.testing.expectEqual(ElementId.init(100), output.items[0].scroll_changed.element);
    try std.testing.expectApproxEqAbs(@as(f32, 0), output.items[0].scroll_changed.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 35), output.items[0].scroll_changed.y, 0.01);
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
    _ = try ctx.processEvents();

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
    _ = try ctx.processEvents();

    try std.testing.expect(testIsSelected(&ctx, rb1));
    try std.testing.expect(!testIsSelected(&ctx, rb2));
    // Click rb2 — should deselect rb1
    const rb2_rect = ctx.tree.getConst(rb2).layout_rect;
    try ctx.pushEvent(.{ .mouse_button = .{ .button = .left, .state = .pressed, .x = rb2_rect.x + 5, .y = rb2_rect.y + 5 } });
    try ctx.pushEvent(.{ .mouse_button = .{ .button = .left, .state = .released, .x = rb2_rect.x + 5, .y = rb2_rect.y + 5 } });
    _ = try ctx.processEvents();

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
    _ = try ctx.processEvents();
    try std.testing.expect(!ctx.runtime.layout_dirty);

    // Key events trigger a follow-up layout inside processEvents
    try ctx.pushEvent(.{ .key = .{ .scancode = 0, .keycode = .backspace, .state = .pressed } });
    _ = try ctx.processEvents();
    try std.testing.expect(!ctx.runtime.layout_dirty);
}

test "visual revision is stable when idle and advances for input and cleared focus" {
    var ctx = try Context.init(std.testing.allocator, .{ .width = 320, .height = 200 });
    defer ctx.deinit();

    const button = try ctx.tree.addRootControl(.{
        .identity = .{ .element_id = .init(501) },
        .widget = .{ .button = .{ .label = "focus" } },
    });
    ctx.doLayout(null);

    const settled = ctx.chromeState().revision;
    _ = try ctx.processEvents();
    try std.testing.expectEqual(settled, ctx.chromeState().revision);

    try ctx.pushEvent(.{ .mouse_move = .{ .x = 4, .y = 4 } });
    _ = try ctx.processEvents();
    const after_input = ctx.chromeState().revision;
    try std.testing.expect(after_input != settled);

    try std.testing.expect(ctx.focusWidget(button));
    const focused = ctx.chromeState().revision;
    ctx.clearFocus();
    try std.testing.expect(ctx.chromeState().revision != focused);
    try std.testing.expect(ctx.focusedElementId() == null);
}

test "journal allocation failure leaves queued input and control state untouched" {
    var ctx = try Context.init(std.testing.allocator, .{ .width = 320, .height = 200 });
    defer ctx.deinit();

    const checkbox = try ctx.tree.addRootControl(.{
        .identity = .{ .element_id = .init(601) },
        .widget = .{ .checkbox = .{ .label = "atomic" } },
    });
    ctx.doLayout(null);
    const rect = ctx.tree.getConst(checkbox).layout_rect;
    const x = rect.x + rect.w * 0.5;
    const y = rect.y + rect.h * 0.5;
    try ctx.pushEvent(.{ .mouse_button = .{ .button = .left, .state = .pressed, .x = x, .y = y } });
    try ctx.pushEvent(.{ .mouse_button = .{ .button = .left, .state = .released, .x = x, .y = y } });

    const allocator = ctx.runtime.allocator;
    ctx.runtime.allocator = std.testing.failing_allocator;
    defer ctx.runtime.allocator = allocator;
    try std.testing.expectError(error.OutOfMemory, ctx.processEvents());
    ctx.runtime.allocator = allocator;

    try std.testing.expect(!ctx.tree.getConst(checkbox).kind.checkbox.checked);
    try std.testing.expectEqual(@as(usize, 2), ctx.runtime.events.items.len);

    const output = try ctx.processEvents();
    try std.testing.expect(ctx.tree.getConst(checkbox).kind.checkbox.checked);
    try std.testing.expectEqual(@as(usize, 2), output.items.len);
    try std.testing.expectEqual(ElementId.init(601), output.items[0].activated.element);
    try std.testing.expectEqual(ElementId.init(601), output.items[1].toggle_changed.element);
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

    // Adding a node changes tree revision — doLayout should detect and run
    _ = try ctx.tree.addChild(root, .{ .text = .{ .content = "new" } });
    ctx.doLayout(null);
    // After running, dirty is cleared and revision is updated
    try std.testing.expect(!ctx.runtime.layout_dirty);
    try std.testing.expectEqual(ctx.tree.revision(), ctx.runtime.last_tree_revision);
}

test "same-count topology changes trigger layout" {
    var ctx = try Context.init(std.testing.allocator, .{ .width = 800, .height = 600 });
    defer ctx.deinit();

    const root = try ctx.tree.addRoot(.{ .container = .{} });
    const first = try ctx.tree.addChild(root, .{ .text = .{ .content = "first" } });
    ctx.doLayout(null);

    const previous_revision = ctx.runtime.last_tree_revision;
    try ctx.tree.remove(first);
    const second = try ctx.tree.addChild(root, .{ .button = .{ .label = "second" } });
    try std.testing.expectEqual(@as(u32, 2), ctx.tree.count());
    try std.testing.expect(ctx.tree.revision() != previous_revision);

    ctx.doLayout(null);
    try std.testing.expectEqual(ctx.tree.revision(), ctx.runtime.last_tree_revision);
    try std.testing.expect(ctx.tree.getConst(second).layout_rect.w > 0);
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

    ctx.doLayout(null);

    const parent_rect = ctx.tree.getConst(parent).layout_rect;
    const disclosure_x = parent_rect.x + 8;
    const disclosure_y = parent_rect.y + parent_rect.h * 0.5;

    try ctx.pushEvent(.{ .mouse_button = .{ .button = .left, .state = .pressed, .x = disclosure_x, .y = disclosure_y } });
    try ctx.pushEvent(.{ .mouse_button = .{ .button = .left, .state = .released, .x = disclosure_x, .y = disclosure_y } });
    _ = try ctx.processEvents();
    try std.testing.expect(!ctx.tree.node(parent).?.kind.tree_item.expanded);

    ctx.doLayout(null);
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 0, .h = 0 }, ctx.tree.getConst(child).layout_rect);

    try ctx.pushEvent(.{ .mouse_button = .{ .button = .left, .state = .pressed, .x = disclosure_x, .y = disclosure_y } });
    try ctx.pushEvent(.{ .mouse_button = .{ .button = .left, .state = .released, .x = disclosure_x, .y = disclosure_y } });
    _ = try ctx.processEvents();
    try std.testing.expect(ctx.tree.node(parent).?.kind.tree_item.expanded);
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
    try ctx.tree.setElementId(first, .init(301));
    try ctx.tree.setElementId(second, .init(302));

    ctx.doLayout(null);

    const first_rect = ctx.tree.getConst(first).layout_rect;
    const second_rect = ctx.tree.getConst(second).layout_rect;

    try ctx.pushEvent(.{ .mouse_button = .{ .button = .left, .state = .pressed, .x = first_rect.x + 12, .y = first_rect.y + first_rect.h * 0.5 } });
    try ctx.pushEvent(.{ .mouse_move = .{ .x = second_rect.x + 12, .y = second_rect.y + second_rect.h * 0.5 } });
    try ctx.pushEvent(.{ .mouse_button = .{ .button = .left, .state = .released, .x = second_rect.x + 12, .y = second_rect.y + second_rect.h * 0.5 } });
    const output = try ctx.processEvents();
    const drop = output.items[output.items.len - 1].drop;
    try std.testing.expectEqual(ElementId.init(301), drop.source);
    try std.testing.expectEqual(ElementId.init(302), drop.target);
    try std.testing.expectEqual(control_event.Drop.Position.inside, drop.position);
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

    ctx.doLayout(null);

    try std.testing.expect(ctx.tree.getConst(scene_text).layout_rect.w > 0);
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 0, .h = 0 }, ctx.tree.getConst(render_text).layout_rect);

    const render_rect = ctx.tree.getConst(render).layout_rect;
    try ctx.pushEvent(.{ .mouse_button = .{ .button = .left, .state = .pressed, .x = render_rect.x + 5, .y = render_rect.y + 5 } });
    try ctx.pushEvent(.{ .mouse_button = .{ .button = .left, .state = .released, .x = render_rect.x + 5, .y = render_rect.y + 5 } });
    _ = try ctx.processEvents();

    try std.testing.expect(testIsSelected(&ctx, render));
    try std.testing.expect(!testIsSelected(&ctx, scene));

    ctx.doLayout(null);

    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 0, .h = 0 }, ctx.tree.getConst(scene_text).layout_rect);
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
    _ = try ctx.processEvents();

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
    _ = try ctx.processEvents();

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
    try ctx.tree.setElementId(first, .init(101));
    try ctx.tree.setElementId(second, .init(102));

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
    _ = try ctx.processEvents();
    try std.testing.expect(ctx.tree.getConst(first).kind.grid_item.internal.drag.active);
    try std.testing.expectEqual(ElementId.init(101), ctx.tree.elementId(first).?);

    try ctx.pushEvent(.{ .mouse_button = .{
        .button = .left,
        .state = .released,
        .x = second_rect.x + second_rect.w * 0.5,
        .y = second_rect.y + second_rect.h * 0.5,
    } });
    const output = try ctx.processEvents();
    const drop = output.items[output.items.len - 1].drop;
    try std.testing.expectEqual(ElementId.init(101), drop.source);
    try std.testing.expectEqual(ElementId.init(102), drop.target);
    try std.testing.expectEqual(control_event.Drop.Position.item, drop.position);
    try std.testing.expect(!ctx.tree.getConst(first).kind.grid_item.internal.drag.active);
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
    try ctx.tree.setElementId(scene, .init(201));
    try ctx.tree.setElementId(camera, .init(202));
    try ctx.tree.setElementId(light, .init(203));

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
    _ = try ctx.processEvents();

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
            const v = ctx.tree.node(child) orelse continue;
            if (v.kind != .selectable) continue;
            if (v.kind.selectable.selected) {
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
        try std.testing.expectEqual(ElementId.init(202), ctx.tree.elementId(found.?).?);
    }

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
    _ = try ctx.processEvents();

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
    _ = try ctx.processEvents();

    try std.testing.expectEqual(@as(u16, 2), testCountSelectedDataRows(&ctx, table));
    try std.testing.expectEqual(@as(?u16, 0), testFirstSelectedDataRowIndex(&ctx, table));
    try std.testing.expect(testIsSelected(&ctx, first));
    try std.testing.expect(testIsSelected(&ctx, second));

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
    _ = try ctx.processEvents();

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
    _ = try ctx.processEvents();

    const resized_name = ctx.tree.getConst(header_name).layout_rect;
    const resized_type = ctx.tree.getConst(header_type).layout_rect;
    const resized_row_name = ctx.tree.getConst(row_name).layout_rect;
    const resized_row_type = ctx.tree.getConst(row_type).layout_rect;

    try std.testing.expect(ctx.tree.tableColumnFraction(table, 0).? > (1.0 / 3.0));
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
    _ = try ctx.processEvents();

    try std.testing.expectEqual(@as(?u8, 1), ctx.tree.node(table).?.kind.table.sorted_column);
    try std.testing.expectEqual(widget.WidgetKind.Table.SortDirection.ascending, ctx.tree.node(table).?.kind.table.sort_direction);

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
    _ = try ctx.processEvents();

    try std.testing.expectEqual(@as(?u8, 1), ctx.tree.node(table).?.kind.table.sorted_column);
    try std.testing.expectEqual(widget.WidgetKind.Table.SortDirection.descending, ctx.tree.node(table).?.kind.table.sort_direction);
}

test "tooltip layout waits for the runtime clock deadline" {
    var ctx = try Context.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer ctx.deinit();

    const root = try ctx.tree.addRoot(.{ .container = .{ .direction = .column } });
    const owner = try ctx.tree.addChild(root, .{ .tree_item = .{ .label = "Hover me", .group = 1 } });
    const tooltip = try ctx.tree.addChild(owner, .{ .tooltip = .{ .placement = .below_start, .y = 4 } });
    _ = try ctx.tree.addChild(tooltip, .{ .text = .{ .content = "Tooltip body" } });

    _ = ctx.update(100);
    ctx.doLayout(null);
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 0, .h = 0 }, ctx.tree.getConst(tooltip).layout_rect);

    const owner_rect = ctx.tree.getConst(owner).layout_rect;
    try ctx.pushEvent(.{ .mouse_move = .{
        .x = owner_rect.x + 5,
        .y = owner_rect.y + 5,
    } });
    _ = try ctx.processEvents();

    try std.testing.expectEqual(@as(?u64, 600), ctx.update(599).next_deadline_ms);
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 0, .h = 0 }, ctx.tree.getConst(tooltip).layout_rect);
    try std.testing.expect(ctx.update(600).changed);
    ctx.doLayout(null);
    const tooltip_rect = ctx.tree.getConst(tooltip).layout_rect;
    try std.testing.expect(tooltip_rect.w > 0);
    try std.testing.expect(tooltip_rect.h > 0);

    try ctx.pushEvent(.{ .mouse_move = .{ .x = 390, .y = 290 } });
    _ = try ctx.processEvents();
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 0, .h = 0 }, ctx.tree.getConst(tooltip).layout_rect);
}

test "runtime clock is monotonic and zero-delay tooltips need no timer" {
    var ctx = try Context.init(std.testing.allocator, .{ .width = 240, .height = 120 });
    defer ctx.deinit();
    const owner = try ctx.tree.addRoot(.{ .button = .{ .label = "Hover" } });
    const tooltip = try ctx.tree.addChild(owner, .{ .tooltip = .{ .delay_ms = 0 } });
    _ = try ctx.tree.addChild(tooltip, .{ .text = .{ .content = "Now" } });
    ctx.doLayout(null);
    const rect = ctx.tree.getConst(owner).layout_rect;

    _ = ctx.update(900);
    try ctx.pushEvent(.{ .mouse_move = .{ .x = rect.x + 1, .y = rect.y + 1 } });
    _ = try ctx.processEvents();
    try std.testing.expect(ctx.tree.getConst(tooltip).kind.tooltip.visible);
    try std.testing.expect(ctx.update(100).next_deadline_ms == null);
    try std.testing.expect(ctx.runtime.now_ms == 900);
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
    _ = try ctx.processEvents();

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
    _ = try ctx.processEvents();

    const recent_rect = ctx.tree.getConst(recent).layout_rect;
    try ctx.pushEvent(.{ .mouse_move = .{
        .x = recent_rect.x + 5,
        .y = recent_rect.y + 5,
    } });
    _ = try ctx.processEvents();

    const recent_popup_rect = ctx.tree.getConst(recent_popup).layout_rect;
    try std.testing.expect(recent_popup_rect.w > 0);
    try std.testing.expect(recent_popup_rect.x >= recent_rect.x + recent_rect.w - 0.01);
}

test "focused semantic identity hides retained handle lifetime" {
    var ctx = try Context.init(std.testing.allocator, .{ .width = 320, .height = 200 });
    defer ctx.deinit();

    try std.testing.expectEqual(@as(?ElementId, null), ctx.focusedElementId());
    const root = try ctx.tree.addRoot(.{ .container = .{} });
    const input_handle = try ctx.tree.addChildControl(root, .{
        .identity = .{ .element_id = .init(77) },
        .widget = .{ .text_input = .{} },
    });
    try std.testing.expect(ctx.focusWidget(input_handle));
    try std.testing.expectEqual(ElementId.init(77), ctx.focusedElementId().?);

    try ctx.tree.remove(input_handle);
    try std.testing.expectEqual(@as(?ElementId, null), ctx.focusedElementId());
}

fn containsType(comptime T: type, comptime Needle: type) bool {
    if (T == Needle) return true;
    return switch (@typeInfo(T)) {
        .pointer => |pointer| containsType(pointer.child, Needle),
        .optional => |optional| containsType(optional.child, Needle),
        .array => |array| containsType(array.child, Needle),
        .vector => |vector| containsType(vector.child, Needle),
        .@"struct" => |structure| contains: {
            inline for (structure.fields) |field| {
                if (containsType(field.type, Needle)) break :contains true;
            }
            break :contains false;
        },
        .@"union" => |union_info| contains: {
            inline for (union_info.fields) |field| {
                if (containsType(field.type, Needle)) break :contains true;
            }
            break :contains false;
        },
        else => false,
    };
}

test {
    _ = widget;
    _ = style;
    _ = layout;
    _ = dispatch;
    _ = @import("focus.zig");
    _ = @import("hittest.zig");
}
