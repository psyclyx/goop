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

pub const Context = struct {
    allocator: std.mem.Allocator,
    clay_arena: []u8,
    tree: Tree,
    theme: Theme,
    events: std.ArrayListUnmanaged(Event),
    mouse: dispatch.MouseState = .{},

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
    /// detect clicks. Call after doLayout.
    pub fn processEvents(self: *Context) void {
        dispatch.process(&self.tree, self.events.items, &self.mouse, self.theme);
        self.events.clearRetainingCapacity();
    }

    /// Clear all button clicked flags. Call at the start of each frame
    /// so clicks are only observed for one frame.
    pub fn clearClickedFlags(self: *Context) void {
        for (self.tree.nodes.items) |*node| {
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

    /// Run layout: walk the widget tree through clay and write back rects.
    /// Pass a TextMeasureCtx for accurate snail-based text measurement,
    /// or null to use a rough character-width approximation.
    pub fn doLayout(self: *Context, text_ctx: ?*const TextMeasureCtx) void {
        layout.run(&self.tree, self.theme, text_ctx);
    }

    /// Generate draw commands from the laid-out widget tree.
    /// Caller must call freeDrawList when done.
    pub fn generateDrawList(self: *Context) !DrawList {
        return draw.generate(&self.tree, self.theme, self.allocator);
    }

    /// Free a DrawList returned by generateDrawList.
    pub fn freeDrawList(self: *Context, dl: *DrawList) void {
        draw.freeDrawList(dl, self.allocator);
    }

    /// Update layout dimensions (e.g. on window resize).
    pub fn setDimensions(self: *Context, width: u32, height: u32) void {
        _ = self;
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

test {
    _ = widget;
    _ = style;
    _ = layout;
    _ = draw;
    _ = dispatch;
}
