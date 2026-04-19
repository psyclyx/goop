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
    last_node_count: u32 = 0,

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
        for (self.events.items) |ev| {
            switch (ev) {
                .key, .text, .mouse_scroll, .resize => {
                    self.layout_dirty = true;
                    break;
                },
                else => {},
            }
        }
        dispatch.processWithClipboard(&self.tree, self.events.items, &self.mouse, self.theme, self.clipboard, self.text_measure_ctx);
        self.events.clearRetainingCapacity();
    }

    /// Clear all button clicked flags. Call at the start of each frame
    /// so clicks are only observed for one frame.
    pub fn clearClickedFlags(self: *Context) void {
        for (self.tree.nodes.items) |*node| {
            if (!node.alive) continue;
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
                else => {},
            }
        }
    }

    /// Check if a widget was clicked this frame (buttons and checkboxes).
    pub fn wasClicked(self: *const Context, handle: NodeHandle) bool {
        const node = self.tree.getConst(handle);
        return switch (node.kind) {
            .button => node.kind.button.clicked,
            .checkbox => node.kind.checkbox.clicked,
            .radio_button => node.kind.radio_button.clicked,
            else => false,
        };
    }

    /// Check if a checkbox is currently checked.
    pub fn isChecked(self: *const Context, handle: NodeHandle) bool {
        return self.tree.getConst(handle).kind.checkbox.checked;
    }

    /// Check if a radio button is currently selected.
    pub fn isSelected(self: *const Context, handle: NodeHandle) bool {
        return self.tree.getConst(handle).kind.radio_button.selected;
    }

    /// Get the current value of a slider.
    pub fn sliderValue(self: *const Context, handle: NodeHandle) f32 {
        return self.tree.getConst(handle).kind.slider.value;
    }

    /// Get the current text content of a text input.
    pub fn textInputValue(self: *const Context, handle: NodeHandle) []const u8 {
        return self.tree.getConst(handle).kind.text_input.content();
    }

    /// Remove a widget and its entire subtree from the tree.
    /// The handle becomes invalid after this call.
    pub fn removeWidget(self: *Context, handle: NodeHandle) !void {
        self.layout_dirty = true;
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
        self.last_node_count = current_count;
    }

    /// Generate draw commands from the laid-out widget tree.
    /// Caller must call freeDrawList when done.
    pub fn generateDrawList(self: *Context) !DrawList {
        return draw.generate(&self.tree, self.theme, self.allocator, self.text_measure_ctx);
    }

    /// Free a DrawList returned by generateDrawList.
    pub fn freeDrawList(self: *Context, dl: *DrawList) void {
        draw.freeDrawList(dl, self.allocator);
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

    // Key events dirty layout
    try ctx.pushEvent(.{ .key = .{ .scancode = 0, .keycode = .backspace, .state = .pressed } });
    ctx.processEvents();
    try std.testing.expect(ctx.layout_dirty);

    // Layout clears dirty flag
    ctx.doLayout(null);
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

test {
    _ = widget;
    _ = style;
    _ = layout;
    _ = draw;
    _ = dispatch;
    _ = @import("core/focus.zig");
    _ = @import("core/hittest.zig");
}
