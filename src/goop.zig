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

pub const Tree = widget.Tree;
pub const NodeHandle = widget.NodeHandle;
pub const WidgetKind = widget.WidgetKind;
pub const Event = event.Event;
pub const Theme = style.Theme;
pub const Style = style.Style;
pub const Color = style.Color;
pub const DrawCommand = draw.DrawCommand;
pub const DrawList = draw.DrawList;
pub const TextMeasureCtx = layout.TextMeasureCtx;
pub const MeasureTextFn = layout.MeasureTextFn;
pub const TextDimensions = layout.TextDimensions;

pub const Clipboard = dispatch.Clipboard;
pub const SecondaryClick = dispatch.SecondaryClick;

pub const Context = struct {
    allocator: std.mem.Allocator,
    clay_arena: []u8,
    tree: Tree,
    theme: Theme,
    events: std.ArrayListUnmanaged(Event),
    mouse: dispatch.MouseState = .{},
    clipboard: ?Clipboard = null,
    text_measure_ctx: ?*const TextMeasureCtx = null,
    layout_dirty: bool = true,
    draw_dirty: bool = true,
    last_node_count: u32 = 0,
    cached_draw_list: ?DrawList = null,

    pub fn init(allocator: std.mem.Allocator, opts: InitOptions) !Context {
        const min_memory = c.Clay_MinMemorySize();
        const arena = try allocator.alloc(u8, min_memory);
        const clay_arena = c.Clay_Arena{
            .capacity = min_memory,
            .memory = arena.ptr,
        };
        _ = c.Clay_Initialize(clay_arena, .{
            .width = @floatFromInt(opts.width),
            .height = @floatFromInt(opts.height),
        }, .{});
        return .{
            .allocator = allocator,
            .clay_arena = arena,
            .tree = Tree.init(allocator),
            .theme = opts.theme,
            .events = .empty,
        };
    }

    pub fn deinit(self: *Context) void {
        self.invalidateDrawCache();
        self.events.deinit(self.allocator);
        self.tree.deinit();
        c.Clay_SetCurrentContext(null);
        self.allocator.free(self.clay_arena);
    }

    /// Queue an input event for processing.
    pub fn pushEvent(self: *Context, ev: Event) !void {
        try self.events.append(self.allocator, ev);
    }

    /// Process all queued events: hit test, update interaction state,
    /// detect clicks. Call after doLayout. Marks layout dirty if any
    /// events could affect layout (text input, scroll, resize).
    pub fn processEvents(self: *Context) void {
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
        dispatch.processWithClipboard(&self.tree, self.events.items, &self.mouse, self.theme, self.clipboard, self.text_measure_ctx);
        if (self.layout_dirty or self.mouse.layout_changed) {
            layout.run(&self.tree, self.theme, self.text_measure_ctx);
            self.layout_dirty = false;
            self.draw_dirty = true;
            self.last_node_count = self.tree.count();
            self.mouse.layout_changed = false;
        }
        self.events.clearRetainingCapacity();
    }

    /// Clear transient activation/change flags. Call at the start of each
    /// frame so clicks, toggles, and selection changes are only observed
    /// for one frame.
    pub fn clearClickedFlags(self: *Context) void {
        self.mouse.last_secondary_click = null;
        for (self.tree.nodes.items) |*node| {
            if (!node.alive) continue;
            node.interaction.primary_clicked = false;
            node.interaction.secondary_clicked = false;
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
                .table => |*table| {
                    table.changed = false;
                    table.resized_column = null;
                    table.sort_changed = false;
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
    pub fn wasClicked(self: *const Context, handle: NodeHandle) bool {
        return self.tree.getConst(handle).interaction.primary_clicked;
    }

    /// Check if a widget was activated with the secondary button this frame.
    pub fn wasSecondaryClicked(self: *const Context, handle: NodeHandle) bool {
        return self.tree.getConst(handle).interaction.secondary_clicked;
    }

    /// Check if a checkbox is currently checked.
    pub fn isChecked(self: *const Context, handle: NodeHandle) bool {
        return self.tree.getConst(handle).kind.checkbox.checked;
    }

    /// Check if a radio button is currently selected.
    pub fn isSelected(self: *const Context, handle: NodeHandle) bool {
        const node = self.tree.getConst(handle);
        return switch (node.kind) {
            .radio_button => node.kind.radio_button.selected,
            .tree_item => node.kind.tree_item.selected,
            .selectable => node.kind.selectable.selected,
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

    /// Get the most recent secondary click that occurred this frame, if any.
    pub fn lastSecondaryClick(self: *const Context) ?SecondaryClick {
        return self.mouse.last_secondary_click;
    }

    /// Remove a widget and its entire subtree from the tree.
    /// The handle becomes invalid after this call.
    pub fn removeWidget(self: *Context, handle: NodeHandle) !void {
        self.layout_dirty = true;
        self.draw_dirty = true;
        try self.tree.remove(handle);
    }

    /// Check whether a handle still refers to a living widget.
    pub fn isAlive(self: *const Context, handle: NodeHandle) bool {
        return self.tree.isAlive(handle);
    }

    /// Run layout: walk the widget tree through clay and write back rects.
    /// Skips the full clay pass if nothing layout-affecting has changed.
    /// Pass a TextMeasureCtx for accurate snail-based text measurement,
    /// or null to use a rough character-width approximation.
    pub fn doLayout(self: *Context, text_ctx: ?*const TextMeasureCtx) void {
        self.text_measure_ctx = text_ctx;
        const current_count = self.tree.count();
        if (!self.layout_dirty and current_count == self.last_node_count) return;
        layout.run(&self.tree, self.theme, text_ctx);
        self.layout_dirty = false;
        self.draw_dirty = true;
        self.last_node_count = current_count;
    }

    /// Generate draw commands from the laid-out widget tree.
    /// Returns a cached list when nothing has changed. Caller must
    /// call freeDrawList when done — cached lists are ref-shared and
    /// only freed when the cache is invalidated or the context is deinited.
    pub fn generateDrawList(self: *Context) !DrawList {
        if (!self.draw_dirty) {
            if (self.cached_draw_list) |cached| return cached;
        }
        self.invalidateDrawCache();
        const dl = try draw.generate(&self.tree, self.theme, self.allocator, self.text_measure_ctx);
        self.cached_draw_list = dl;
        self.draw_dirty = false;
        return dl;
    }

    /// Free a DrawList returned by generateDrawList.
    /// This is a no-op — the Context owns the draw list memory and
    /// manages its lifetime internally. Retained for API compatibility.
    pub fn freeDrawList(_: *Context, _: *DrawList) void {}

    /// Invalidate and free the cached draw list.
    fn invalidateDrawCache(self: *Context) void {
        if (self.cached_draw_list) |*cached| {
            draw.freeDrawList(cached, self.allocator);
            self.cached_draw_list = null;
        }
    }

    /// Update layout dimensions (e.g. on window resize).
    pub fn setDimensions(self: *Context, width: u32, height: u32) void {
        self.layout_dirty = true;
        c.Clay_SetLayoutDimensions(.{
            .width = @floatFromInt(width),
            .height = @floatFromInt(height),
        });
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
    try std.testing.expect(!ctx.layout_dirty);

    const rect_after_first = ctx.tree.getConst(root).layout_rect;
    try std.testing.expect(rect_after_first.w > 0);

    // Second layout with no changes — should be a no-op
    ctx.doLayout(null);
    try std.testing.expect(!ctx.layout_dirty);

    // Mouse-only events don't dirty layout
    try ctx.pushEvent(.{ .mouse_move = .{ .x = 50, .y = 50 } });
    ctx.processEvents();
    try std.testing.expect(!ctx.layout_dirty);

    // Key events trigger a follow-up layout inside processEvents
    try ctx.pushEvent(.{ .key = .{ .scancode = 0, .keycode = .backspace, .state = .pressed } });
    ctx.processEvents();
    try std.testing.expect(!ctx.layout_dirty);
}

test "setDimensions dirties layout" {
    var ctx = try Context.init(std.testing.allocator, .{ .width = 800, .height = 600 });
    defer ctx.deinit();

    _ = try ctx.tree.addRoot(.{ .container = .{} });
    ctx.doLayout(null);
    try std.testing.expect(!ctx.layout_dirty);

    ctx.setDimensions(1024, 768);
    try std.testing.expect(ctx.layout_dirty);
}

test "adding nodes triggers layout" {
    var ctx = try Context.init(std.testing.allocator, .{ .width = 800, .height = 600 });
    defer ctx.deinit();

    const root = try ctx.tree.addRoot(.{ .container = .{} });
    ctx.doLayout(null);
    try std.testing.expect(!ctx.layout_dirty);

    // Adding a node changes tree count — doLayout should detect and run
    _ = try ctx.tree.addChild(root, .{ .text = .{ .content = "new" } });
    ctx.doLayout(null);
    // After running, dirty is cleared and count is updated
    try std.testing.expect(!ctx.layout_dirty);
    try std.testing.expectEqual(@as(u32, 2), ctx.last_node_count);
}

test "draw list caching returns same list when clean" {
    var ctx = try Context.init(std.testing.allocator, .{ .width = 800, .height = 600 });
    defer ctx.deinit();

    const root = try ctx.tree.addRoot(.{ .container = .{} });
    _ = try ctx.tree.addChild(root, .{ .button = .{ .label = "OK" } });

    ctx.doLayout(null);

    var dl1 = try ctx.generateDrawList();
    try std.testing.expect(!ctx.draw_dirty);

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
    try std.testing.expect(ctx.draw_dirty);

    // Regeneration produces a new list (old cache freed internally)
    var dl2 = try ctx.generateDrawList();
    try std.testing.expect(!ctx.draw_dirty);
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
