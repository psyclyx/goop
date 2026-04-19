const std = @import("std");
const widget = @import("widget.zig");
const event = @import("event.zig");
const style = @import("style.zig");
const dispatch = @import("dispatch.zig");
const MouseState = dispatch.MouseState;
const Clipboard = dispatch.Clipboard;
const process = dispatch.process;
const processWithClipboard = dispatch.processWithClipboard;

/// Test clipboard that stores text in a static buffer.
const TestClipboard = struct {
    buf: [256]u8 = [_]u8{0} ** 256,
    len: usize = 0,

    fn clipboard(self: *TestClipboard) Clipboard {
        return .{
            .ptr = @ptrCast(self),
            .getTextFn = @ptrCast(&getText),
            .setTextFn = @ptrCast(&setText),
        };
    }

    fn getText(self: *TestClipboard) ?[]const u8 {
        if (self.len == 0) return null;
        return self.buf[0..self.len];
    }

    fn setText(self: *TestClipboard, text: []const u8) void {
        const count = @min(text.len, self.buf.len);
        @memcpy(self.buf[0..count], text[0..count]);
        self.len = count;
    }
};

test "text input receives character events" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const ti = try tree.addChild(root, .{ .text_input = .{} });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(ti).layout_rect = .{ .x = 10, .y = 10, .w = 300, .h = 30 };

    var mouse = MouseState{};

    // Click to focus the text input
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 50, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 50, .y = 20 } },
    }, &mouse, style.Theme.default);
    try std.testing.expect(mouse.focused.?.eql(ti));

    // Type "hi"
    process(&tree, &.{
        .{ .text = .{ .codepoint = 'h' } },
        .{ .text = .{ .codepoint = 'i' } },
    }, &mouse, style.Theme.default);

    try std.testing.expectEqualStrings("hi", tree.getConst(ti).kind.text_input.content());
}

test "text input backspace deletes characters" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const ti = try tree.addChild(root, .{ .text_input = .{} });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(ti).layout_rect = .{ .x = 10, .y = 10, .w = 300, .h = 30 };

    var mouse = MouseState{};

    // Click to focus
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 50, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 50, .y = 20 } },
    }, &mouse, style.Theme.default);

    // Type "abc" then backspace
    process(&tree, &.{
        .{ .text = .{ .codepoint = 'a' } },
        .{ .text = .{ .codepoint = 'b' } },
        .{ .text = .{ .codepoint = 'c' } },
        .{ .key = .{ .scancode = 14, .keycode = .backspace, .state = .pressed } },
    }, &mouse, style.Theme.default);

    try std.testing.expectEqualStrings("ab", tree.getConst(ti).kind.text_input.content());
}

test "text input delete key deletes forward" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const ti = try tree.addChild(root, .{ .text_input = .{} });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(ti).layout_rect = .{ .x = 10, .y = 10, .w = 300, .h = 30 };

    var mouse = MouseState{};

    // Click to focus
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 50, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 50, .y = 20 } },
    }, &mouse, style.Theme.default);

    // Type "abc", move cursor left twice, then delete forward
    process(&tree, &.{
        .{ .text = .{ .codepoint = 'a' } },
        .{ .text = .{ .codepoint = 'b' } },
        .{ .text = .{ .codepoint = 'c' } },
        .{ .key = .{ .scancode = 105, .keycode = .left, .state = .pressed } },
        .{ .key = .{ .scancode = 105, .keycode = .left, .state = .pressed } },
        .{ .key = .{ .scancode = 111, .keycode = .delete, .state = .pressed } },
    }, &mouse, style.Theme.default);

    // Should delete 'b', leaving "ac" with cursor at position 1
    try std.testing.expectEqualStrings("ac", tree.getConst(ti).kind.text_input.content());
    try std.testing.expectEqual(@as(u8, 1), tree.getConst(ti).kind.text_input.cursor);
}

test "text input ignores input when not focused" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const ti = try tree.addChild(root, .{ .text_input = .{} });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(ti).layout_rect = .{ .x = 10, .y = 10, .w = 300, .h = 30 };

    var mouse = MouseState{};

    // Type without focusing — should be ignored
    process(&tree, &.{
        .{ .text = .{ .codepoint = 'x' } },
    }, &mouse, style.Theme.default);

    try std.testing.expectEqualStrings("", tree.getConst(ti).kind.text_input.content());
}

test "text input arrow keys move cursor" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const ti = try tree.addChild(root, .{ .text_input = .{} });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(ti).layout_rect = .{ .x = 10, .y = 10, .w = 300, .h = 30 };

    var mouse = MouseState{};

    // Click to focus
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 50, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 50, .y = 20 } },
    }, &mouse, style.Theme.default);

    // Type "abc" — cursor at 3
    process(&tree, &.{
        .{ .text = .{ .codepoint = 'a' } },
        .{ .text = .{ .codepoint = 'b' } },
        .{ .text = .{ .codepoint = 'c' } },
    }, &mouse, style.Theme.default);
    try std.testing.expectEqual(@as(u8, 3), tree.getConst(ti).kind.text_input.cursor);

    // Left arrow twice — cursor at 1
    process(&tree, &.{
        .{ .key = .{ .scancode = 105, .keycode = .left, .state = .pressed } },
        .{ .key = .{ .scancode = 105, .keycode = .left, .state = .pressed } },
    }, &mouse, style.Theme.default);
    try std.testing.expectEqual(@as(u8, 1), tree.getConst(ti).kind.text_input.cursor);

    // Right arrow once — cursor at 2
    process(&tree, &.{
        .{ .key = .{ .scancode = 106, .keycode = .right, .state = .pressed } },
    }, &mouse, style.Theme.default);
    try std.testing.expectEqual(@as(u8, 2), tree.getConst(ti).kind.text_input.cursor);

    // Insert 'x' at cursor position 2 — "abxc"
    process(&tree, &.{
        .{ .text = .{ .codepoint = 'x' } },
    }, &mouse, style.Theme.default);
    try std.testing.expectEqualStrings("abxc", tree.getConst(ti).kind.text_input.content());

    // Left arrow at position 0 stays at 0
    process(&tree, &.{
        .{ .key = .{ .scancode = 105, .keycode = .left, .state = .pressed } },
        .{ .key = .{ .scancode = 105, .keycode = .left, .state = .pressed } },
        .{ .key = .{ .scancode = 105, .keycode = .left, .state = .pressed } },
        .{ .key = .{ .scancode = 105, .keycode = .left, .state = .pressed } },
        .{ .key = .{ .scancode = 105, .keycode = .left, .state = .pressed } },
    }, &mouse, style.Theme.default);
    try std.testing.expectEqual(@as(u8, 0), tree.getConst(ti).kind.text_input.cursor);

    // Right arrow past end stays at len
    process(&tree, &.{
        .{ .key = .{ .scancode = 106, .keycode = .right, .state = .pressed } },
        .{ .key = .{ .scancode = 106, .keycode = .right, .state = .pressed } },
        .{ .key = .{ .scancode = 106, .keycode = .right, .state = .pressed } },
        .{ .key = .{ .scancode = 106, .keycode = .right, .state = .pressed } },
        .{ .key = .{ .scancode = 106, .keycode = .right, .state = .pressed } },
    }, &mouse, style.Theme.default);
    try std.testing.expectEqual(@as(u8, 4), tree.getConst(ti).kind.text_input.cursor);
}

test "text input arrow keys move across UTF-8 codepoints" {
    const allocator = std.testing.allocator;
    var s = try setupTextInput(allocator);
    defer s.tree.deinit();

    var mouse = MouseState{};
    focusAndType(&s.tree, &mouse, s.ti, "aé🙂");

    try std.testing.expectEqualStrings("aé🙂", s.tree.get(s.ti).kind.text_input.content());
    try std.testing.expectEqual(@as(u8, 7), s.tree.get(s.ti).kind.text_input.cursor);

    process(&s.tree, &.{
        .{ .key = .{ .scancode = 105, .keycode = .left, .state = .pressed } },
    }, &mouse, style.Theme.default);
    try std.testing.expectEqual(@as(u8, 3), s.tree.get(s.ti).kind.text_input.cursor);

    process(&s.tree, &.{
        .{ .key = .{ .scancode = 105, .keycode = .left, .state = .pressed } },
    }, &mouse, style.Theme.default);
    try std.testing.expectEqual(@as(u8, 1), s.tree.get(s.ti).kind.text_input.cursor);

    process(&s.tree, &.{
        .{ .key = .{ .scancode = 106, .keycode = .right, .state = .pressed } },
    }, &mouse, style.Theme.default);
    try std.testing.expectEqual(@as(u8, 3), s.tree.get(s.ti).kind.text_input.cursor);

    process(&s.tree, &.{
        .{ .key = .{ .scancode = 106, .keycode = .right, .state = .pressed } },
    }, &mouse, style.Theme.default);
    try std.testing.expectEqual(@as(u8, 7), s.tree.get(s.ti).kind.text_input.cursor);
}

test "text input backspace and delete operate on UTF-8 codepoints" {
    const allocator = std.testing.allocator;
    var s = try setupTextInput(allocator);
    defer s.tree.deinit();

    var mouse = MouseState{};
    focusAndType(&s.tree, &mouse, s.ti, "aé🙂");

    process(&s.tree, &.{
        .{ .key = .{ .scancode = 14, .keycode = .backspace, .state = .pressed } },
    }, &mouse, style.Theme.default);
    try std.testing.expectEqualStrings("aé", s.tree.get(s.ti).kind.text_input.content());
    try std.testing.expectEqual(@as(u8, 3), s.tree.get(s.ti).kind.text_input.cursor);

    process(&s.tree, &.{
        .{ .key = .{ .scancode = 102, .keycode = .home, .state = .pressed } },
        .{ .key = .{ .scancode = 106, .keycode = .right, .state = .pressed } },
        .{ .key = .{ .scancode = 111, .keycode = .delete, .state = .pressed } },
    }, &mouse, style.Theme.default);
    try std.testing.expectEqualStrings("a", s.tree.get(s.ti).kind.text_input.content());
    try std.testing.expectEqual(@as(u8, 1), s.tree.get(s.ti).kind.text_input.cursor);
}

test "text input is focusable via tab" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const btn = try tree.addChild(root, .{ .button = .{ .label = "OK" } });
    const ti = try tree.addChild(root, .{ .text_input = .{} });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(btn).layout_rect = .{ .x = 10, .y = 10, .w = 100, .h = 30 };
    tree.get(ti).layout_rect = .{ .x = 10, .y = 50, .w = 300, .h = 30 };

    var mouse = MouseState{};
    const tab = event.Event{ .key = .{ .scancode = 15, .keycode = .tab, .state = .pressed } };

    // First tab: focus button
    process(&tree, &.{tab}, &mouse, style.Theme.default);
    try std.testing.expect(mouse.focused.?.eql(btn));

    // Second tab: focus text input
    process(&tree, &.{tab}, &mouse, style.Theme.default);
    try std.testing.expect(mouse.focused.?.eql(ti));
    try std.testing.expect(tree.getConst(ti).interaction.focused);
}

test "text input home/end keys move cursor" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const ti = try tree.addChild(root, .{ .text_input = .{} });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(ti).layout_rect = .{ .x = 10, .y = 10, .w = 300, .h = 30 };

    var mouse = MouseState{};

    // Click to focus
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 50, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 50, .y = 20 } },
    }, &mouse, style.Theme.default);

    // Type "hello" — cursor at 5
    process(&tree, &.{
        .{ .text = .{ .codepoint = 'h' } },
        .{ .text = .{ .codepoint = 'e' } },
        .{ .text = .{ .codepoint = 'l' } },
        .{ .text = .{ .codepoint = 'l' } },
        .{ .text = .{ .codepoint = 'o' } },
    }, &mouse, style.Theme.default);
    try std.testing.expectEqual(@as(u8, 5), tree.getConst(ti).kind.text_input.cursor);

    // Home — cursor at 0
    process(&tree, &.{
        .{ .key = .{ .scancode = 102, .keycode = .home, .state = .pressed } },
    }, &mouse, style.Theme.default);
    try std.testing.expectEqual(@as(u8, 0), tree.getConst(ti).kind.text_input.cursor);

    // Home when already at 0 — stays at 0
    process(&tree, &.{
        .{ .key = .{ .scancode = 102, .keycode = .home, .state = .pressed } },
    }, &mouse, style.Theme.default);
    try std.testing.expectEqual(@as(u8, 0), tree.getConst(ti).kind.text_input.cursor);

    // End — cursor at 5
    process(&tree, &.{
        .{ .key = .{ .scancode = 107, .keycode = .end, .state = .pressed } },
    }, &mouse, style.Theme.default);
    try std.testing.expectEqual(@as(u8, 5), tree.getConst(ti).kind.text_input.cursor);

    // End when already at end — stays at end
    process(&tree, &.{
        .{ .key = .{ .scancode = 107, .keycode = .end, .state = .pressed } },
    }, &mouse, style.Theme.default);
    try std.testing.expectEqual(@as(u8, 5), tree.getConst(ti).kind.text_input.cursor);
}

test "ctrl+left and ctrl+right move by word" {
    const allocator = std.testing.allocator;
    var s = try setupTextInput(allocator);
    defer s.tree.deinit();

    var mouse = MouseState{};
    focusAndType(&s.tree, &mouse, s.ti, "hello world");

    process(&s.tree, &.{
        .{ .key = .{ .scancode = 29, .keycode = .left_ctrl, .state = .pressed } },
        .{ .key = .{ .scancode = 105, .keycode = .left, .state = .pressed } },
    }, &mouse, style.Theme.default);
    try std.testing.expectEqual(@as(u8, 6), s.tree.get(s.ti).kind.text_input.cursor);

    process(&s.tree, &.{
        .{ .key = .{ .scancode = 105, .keycode = .left, .state = .pressed } },
    }, &mouse, style.Theme.default);
    try std.testing.expectEqual(@as(u8, 0), s.tree.get(s.ti).kind.text_input.cursor);

    process(&s.tree, &.{
        .{ .key = .{ .scancode = 106, .keycode = .right, .state = .pressed } },
    }, &mouse, style.Theme.default);
    try std.testing.expectEqual(@as(u8, 5), s.tree.get(s.ti).kind.text_input.cursor);

    process(&s.tree, &.{
        .{ .key = .{ .scancode = 106, .keycode = .right, .state = .pressed } },
        .{ .key = .{ .scancode = 29, .keycode = .left_ctrl, .state = .released } },
    }, &mouse, style.Theme.default);
    try std.testing.expectEqual(@as(u8, 11), s.tree.get(s.ti).kind.text_input.cursor);
}

test "ctrl+shift+arrow selects by word" {
    const allocator = std.testing.allocator;
    var s = try setupTextInput(allocator);
    defer s.tree.deinit();

    var mouse = MouseState{};
    focusAndType(&s.tree, &mouse, s.ti, "hello world");

    process(&s.tree, &.{
        .{ .key = .{ .scancode = 29, .keycode = .left_ctrl, .state = .pressed } },
        .{ .key = .{ .scancode = 42, .keycode = .left_shift, .state = .pressed } },
        .{ .key = .{ .scancode = 105, .keycode = .left, .state = .pressed } },
    }, &mouse, style.Theme.default);

    const input = &s.tree.get(s.ti).kind.text_input;
    try std.testing.expect(input.hasSelection());
    try std.testing.expectEqual(@as(?u8, 11), input.selection_anchor);
    try std.testing.expectEqual(@as(u8, 6), input.cursor);
    try std.testing.expectEqualStrings("world", input.selectedContent());

    process(&s.tree, &.{
        .{ .key = .{ .scancode = 105, .keycode = .left, .state = .pressed } },
        .{ .key = .{ .scancode = 42, .keycode = .left_shift, .state = .released } },
        .{ .key = .{ .scancode = 29, .keycode = .left_ctrl, .state = .released } },
    }, &mouse, style.Theme.default);

    try std.testing.expect(input.hasSelection());
    try std.testing.expectEqual(@as(u8, 0), input.selectionRange().start);
    try std.testing.expectEqual(@as(u8, 11), input.selectionRange().end);
}

test "ctrl+backspace deletes previous word" {
    const allocator = std.testing.allocator;
    var s = try setupTextInput(allocator);
    defer s.tree.deinit();

    var mouse = MouseState{};
    focusAndType(&s.tree, &mouse, s.ti, "hello world");

    process(&s.tree, &.{
        .{ .key = .{ .scancode = 29, .keycode = .left_ctrl, .state = .pressed } },
        .{ .key = .{ .scancode = 14, .keycode = .backspace, .state = .pressed } },
    }, &mouse, style.Theme.default);

    try std.testing.expectEqualStrings("hello ", s.tree.get(s.ti).kind.text_input.content());
    try std.testing.expectEqual(@as(u8, 6), s.tree.get(s.ti).kind.text_input.cursor);

    process(&s.tree, &.{
        .{ .key = .{ .scancode = 14, .keycode = .backspace, .state = .pressed } },
        .{ .key = .{ .scancode = 29, .keycode = .left_ctrl, .state = .released } },
    }, &mouse, style.Theme.default);

    try std.testing.expectEqualStrings("", s.tree.get(s.ti).kind.text_input.content());
    try std.testing.expectEqual(@as(u8, 0), s.tree.get(s.ti).kind.text_input.cursor);
}

test "ctrl+delete deletes next word" {
    const allocator = std.testing.allocator;
    var s = try setupTextInput(allocator);
    defer s.tree.deinit();

    var mouse = MouseState{};
    focusAndType(&s.tree, &mouse, s.ti, "hello world");

    process(&s.tree, &.{
        .{ .key = .{ .scancode = 102, .keycode = .home, .state = .pressed } },
        .{ .key = .{ .scancode = 29, .keycode = .left_ctrl, .state = .pressed } },
        .{ .key = .{ .scancode = 111, .keycode = .delete, .state = .pressed } },
    }, &mouse, style.Theme.default);

    try std.testing.expectEqualStrings(" world", s.tree.get(s.ti).kind.text_input.content());
    try std.testing.expectEqual(@as(u8, 0), s.tree.get(s.ti).kind.text_input.cursor);

    process(&s.tree, &.{
        .{ .key = .{ .scancode = 111, .keycode = .delete, .state = .pressed } },
        .{ .key = .{ .scancode = 29, .keycode = .left_ctrl, .state = .released } },
    }, &mouse, style.Theme.default);

    try std.testing.expectEqualStrings("", s.tree.get(s.ti).kind.text_input.content());
    try std.testing.expectEqual(@as(u8, 0), s.tree.get(s.ti).kind.text_input.cursor);
}

test "shift+arrow creates selection" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const ti = try tree.addChild(root, .{ .text_input = .{} });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(ti).layout_rect = .{ .x = 10, .y = 10, .w = 300, .h = 30 };

    var mouse = MouseState{};

    // Click to focus
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 50, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 50, .y = 20 } },
    }, &mouse, style.Theme.default);

    // Type "hello"
    process(&tree, &.{
        .{ .text = .{ .codepoint = 'h' } },
        .{ .text = .{ .codepoint = 'e' } },
        .{ .text = .{ .codepoint = 'l' } },
        .{ .text = .{ .codepoint = 'l' } },
        .{ .text = .{ .codepoint = 'o' } },
    }, &mouse, style.Theme.default);

    // Shift+Left twice — select "lo" (cursor 5->3, anchor 5)
    process(&tree, &.{
        .{ .key = .{ .scancode = 42, .keycode = .left_shift, .state = .pressed } },
        .{ .key = .{ .scancode = 105, .keycode = .left, .state = .pressed } },
        .{ .key = .{ .scancode = 105, .keycode = .left, .state = .pressed } },
    }, &mouse, style.Theme.default);

    const input = &tree.get(ti).kind.text_input;
    try std.testing.expect(input.hasSelection());
    try std.testing.expectEqual(@as(u8, 3), input.cursor);
    try std.testing.expectEqual(@as(?u8, 5), input.selection_anchor);
    try std.testing.expectEqualStrings("lo", input.selectedContent());
}

test "arrow without shift collapses selection" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const ti = try tree.addChild(root, .{ .text_input = .{} });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(ti).layout_rect = .{ .x = 10, .y = 10, .w = 300, .h = 30 };

    var mouse = MouseState{};

    // Click to focus
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 50, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 50, .y = 20 } },
    }, &mouse, style.Theme.default);

    // Type "abc"
    process(&tree, &.{
        .{ .text = .{ .codepoint = 'a' } },
        .{ .text = .{ .codepoint = 'b' } },
        .{ .text = .{ .codepoint = 'c' } },
    }, &mouse, style.Theme.default);

    // Shift+Left twice — select "bc"
    process(&tree, &.{
        .{ .key = .{ .scancode = 42, .keycode = .left_shift, .state = .pressed } },
        .{ .key = .{ .scancode = 105, .keycode = .left, .state = .pressed } },
        .{ .key = .{ .scancode = 105, .keycode = .left, .state = .pressed } },
    }, &mouse, style.Theme.default);

    // Release shift, press Left — collapse to start of selection
    process(&tree, &.{
        .{ .key = .{ .scancode = 42, .keycode = .left_shift, .state = .released } },
        .{ .key = .{ .scancode = 105, .keycode = .left, .state = .pressed } },
    }, &mouse, style.Theme.default);

    const input = &tree.get(ti).kind.text_input;
    try std.testing.expect(!input.hasSelection());
    try std.testing.expectEqual(@as(u8, 1), input.cursor);

    // Now right-collapse: re-select then press Right
    process(&tree, &.{
        .{ .key = .{ .scancode = 42, .keycode = .left_shift, .state = .pressed } },
        .{ .key = .{ .scancode = 106, .keycode = .right, .state = .pressed } },
        .{ .key = .{ .scancode = 106, .keycode = .right, .state = .pressed } },
        .{ .key = .{ .scancode = 42, .keycode = .left_shift, .state = .released } },
        .{ .key = .{ .scancode = 106, .keycode = .right, .state = .pressed } },
    }, &mouse, style.Theme.default);

    try std.testing.expect(!input.hasSelection());
    try std.testing.expectEqual(@as(u8, 3), input.cursor);
}

test "backspace deletes selection" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const ti = try tree.addChild(root, .{ .text_input = .{} });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(ti).layout_rect = .{ .x = 10, .y = 10, .w = 300, .h = 30 };

    var mouse = MouseState{};

    // Click to focus
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 50, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 50, .y = 20 } },
    }, &mouse, style.Theme.default);

    // Type "abcd"
    process(&tree, &.{
        .{ .text = .{ .codepoint = 'a' } },
        .{ .text = .{ .codepoint = 'b' } },
        .{ .text = .{ .codepoint = 'c' } },
        .{ .text = .{ .codepoint = 'd' } },
    }, &mouse, style.Theme.default);

    // Select "bc" (shift+left twice from end, then shift+right to deselect 'd', actually let's just select middle)
    // Move to position 1, then shift+right twice to select "bc"
    process(&tree, &.{
        .{ .key = .{ .scancode = 102, .keycode = .home, .state = .pressed } },
        .{ .key = .{ .scancode = 106, .keycode = .right, .state = .pressed } },
    }, &mouse, style.Theme.default);
    // cursor at 1
    process(&tree, &.{
        .{ .key = .{ .scancode = 42, .keycode = .left_shift, .state = .pressed } },
        .{ .key = .{ .scancode = 106, .keycode = .right, .state = .pressed } },
        .{ .key = .{ .scancode = 106, .keycode = .right, .state = .pressed } },
    }, &mouse, style.Theme.default);

    try std.testing.expectEqualStrings("bc", tree.get(ti).kind.text_input.selectedContent());

    // Backspace deletes the selection
    process(&tree, &.{
        .{ .key = .{ .scancode = 14, .keycode = .backspace, .state = .pressed } },
    }, &mouse, style.Theme.default);

    try std.testing.expectEqualStrings("ad", tree.get(ti).kind.text_input.content());
    try std.testing.expectEqual(@as(u8, 1), tree.get(ti).kind.text_input.cursor);
    try std.testing.expect(!tree.get(ti).kind.text_input.hasSelection());
}

test "typing replaces selection" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const ti = try tree.addChild(root, .{ .text_input = .{} });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(ti).layout_rect = .{ .x = 10, .y = 10, .w = 300, .h = 30 };

    var mouse = MouseState{};

    // Click to focus
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 50, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 50, .y = 20 } },
    }, &mouse, style.Theme.default);

    // Type "hello"
    process(&tree, &.{
        .{ .text = .{ .codepoint = 'h' } },
        .{ .text = .{ .codepoint = 'e' } },
        .{ .text = .{ .codepoint = 'l' } },
        .{ .text = .{ .codepoint = 'l' } },
        .{ .text = .{ .codepoint = 'o' } },
    }, &mouse, style.Theme.default);

    // Select all with Shift+Home
    process(&tree, &.{
        .{ .key = .{ .scancode = 42, .keycode = .left_shift, .state = .pressed } },
        .{ .key = .{ .scancode = 102, .keycode = .home, .state = .pressed } },
    }, &mouse, style.Theme.default);

    try std.testing.expect(tree.get(ti).kind.text_input.hasSelection());

    // Type "x" — replaces entire selection
    process(&tree, &.{
        .{ .text = .{ .codepoint = 'x' } },
    }, &mouse, style.Theme.default);

    try std.testing.expectEqualStrings("x", tree.get(ti).kind.text_input.content());
    try std.testing.expect(!tree.get(ti).kind.text_input.hasSelection());
}

test "ctrl+a selects all text" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const ti = try tree.addChild(root, .{ .text_input = .{} });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(ti).layout_rect = .{ .x = 10, .y = 10, .w = 300, .h = 30 };

    var mouse = MouseState{};

    // Click to focus
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 50, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 50, .y = 20 } },
    }, &mouse, style.Theme.default);

    // Type "hello"
    process(&tree, &.{
        .{ .text = .{ .codepoint = 'h' } },
        .{ .text = .{ .codepoint = 'e' } },
        .{ .text = .{ .codepoint = 'l' } },
        .{ .text = .{ .codepoint = 'l' } },
        .{ .text = .{ .codepoint = 'o' } },
    }, &mouse, style.Theme.default);

    // Ctrl+A
    process(&tree, &.{
        .{ .key = .{ .scancode = 29, .keycode = .left_ctrl, .state = .pressed } },
        .{ .key = .{ .scancode = 30, .keycode = .a, .state = .pressed } },
    }, &mouse, style.Theme.default);

    const input = &tree.get(ti).kind.text_input;
    try std.testing.expect(input.hasSelection());
    try std.testing.expectEqual(@as(?u8, 0), input.selection_anchor);
    try std.testing.expectEqual(@as(u8, 5), input.cursor);
    try std.testing.expectEqualStrings("hello", input.selectedContent());
}

test "ctrl+a on empty input is no-op" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const ti = try tree.addChild(root, .{ .text_input = .{} });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(ti).layout_rect = .{ .x = 10, .y = 10, .w = 300, .h = 30 };

    var mouse = MouseState{};

    // Click to focus
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 50, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 50, .y = 20 } },
    }, &mouse, style.Theme.default);

    // Ctrl+A on empty
    process(&tree, &.{
        .{ .key = .{ .scancode = 29, .keycode = .left_ctrl, .state = .pressed } },
        .{ .key = .{ .scancode = 30, .keycode = .a, .state = .pressed } },
    }, &mouse, style.Theme.default);

    const input = &tree.get(ti).kind.text_input;
    try std.testing.expect(!input.hasSelection());
    try std.testing.expectEqual(@as(u8, 0), input.cursor);
}

test "click positions cursor in text input" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const ti = try tree.addChild(root, .{ .text_input = .{} });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(ti).layout_rect = .{ .x = 10, .y = 10, .w = 300, .h = 30 };

    var mouse = MouseState{};

    // Click to focus and type "hello"
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 50, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 50, .y = 20 } },
    }, &mouse, style.Theme.default);
    process(&tree, &.{
        .{ .text = .{ .codepoint = 'h' } },
        .{ .text = .{ .codepoint = 'e' } },
        .{ .text = .{ .codepoint = 'l' } },
        .{ .text = .{ .codepoint = 'l' } },
        .{ .text = .{ .codepoint = 'o' } },
    }, &mouse, style.Theme.default);

    // Cursor should be at 5 (end). Now click at position 2.
    // Text starts at rect.x(10) + padding.left(6) = 16.
    // char_width = 14 * 0.6 = 8.4
    // To click at char 2: x = 16 + 2 * 8.4 = 32.8
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 32.8, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 32.8, .y = 20 } },
    }, &mouse, style.Theme.default);

    const input = &tree.get(ti).kind.text_input;
    try std.testing.expectEqual(@as(u8, 2), input.cursor);
    try std.testing.expect(!input.hasSelection());
}

test "click positions cursor on UTF-8 codepoint boundaries" {
    const allocator = std.testing.allocator;
    var s = try setupTextInput(allocator);
    defer s.tree.deinit();

    var mouse = MouseState{};
    focusAndType(&s.tree, &mouse, s.ti, "aé🙂");

    process(&s.tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 32.8, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 32.8, .y = 20 } },
    }, &mouse, style.Theme.default);

    const input = &s.tree.get(s.ti).kind.text_input;
    try std.testing.expectEqual(@as(u8, 3), input.cursor);
    try std.testing.expect(!input.hasSelection());
}

test "click before text positions cursor at 0" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const ti = try tree.addChild(root, .{ .text_input = .{} });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(ti).layout_rect = .{ .x = 10, .y = 10, .w = 300, .h = 30 };

    var mouse = MouseState{};

    // Focus and type
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 50, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 50, .y = 20 } },
    }, &mouse, style.Theme.default);
    process(&tree, &.{
        .{ .text = .{ .codepoint = 'a' } },
        .{ .text = .{ .codepoint = 'b' } },
        .{ .text = .{ .codepoint = 'c' } },
    }, &mouse, style.Theme.default);

    // Click at x=12 which is before text start (16), should clamp to 0
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 12, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 12, .y = 20 } },
    }, &mouse, style.Theme.default);

    try std.testing.expectEqual(@as(u8, 0), tree.get(ti).kind.text_input.cursor);
}

test "click past text end positions cursor at len" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const ti = try tree.addChild(root, .{ .text_input = .{} });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(ti).layout_rect = .{ .x = 10, .y = 10, .w = 300, .h = 30 };

    var mouse = MouseState{};

    // Focus and type "hi"
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 50, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 50, .y = 20 } },
    }, &mouse, style.Theme.default);
    process(&tree, &.{
        .{ .text = .{ .codepoint = 'h' } },
        .{ .text = .{ .codepoint = 'i' } },
    }, &mouse, style.Theme.default);

    // Click way past end of text
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 200, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 200, .y = 20 } },
    }, &mouse, style.Theme.default);

    try std.testing.expectEqual(@as(u8, 2), tree.get(ti).kind.text_input.cursor);
}

test "click clears existing selection" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const ti = try tree.addChild(root, .{ .text_input = .{} });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(ti).layout_rect = .{ .x = 10, .y = 10, .w = 300, .h = 30 };

    var mouse = MouseState{};

    // Focus and type "hello"
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 50, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 50, .y = 20 } },
    }, &mouse, style.Theme.default);
    process(&tree, &.{
        .{ .text = .{ .codepoint = 'h' } },
        .{ .text = .{ .codepoint = 'e' } },
        .{ .text = .{ .codepoint = 'l' } },
        .{ .text = .{ .codepoint = 'l' } },
        .{ .text = .{ .codepoint = 'o' } },
    }, &mouse, style.Theme.default);

    // Select all with Ctrl+A
    process(&tree, &.{
        .{ .key = .{ .scancode = 29, .keycode = .left_ctrl, .state = .pressed } },
        .{ .key = .{ .scancode = 30, .keycode = .a, .state = .pressed } },
        .{ .key = .{ .scancode = 30, .keycode = .a, .state = .released } },
        .{ .key = .{ .scancode = 29, .keycode = .left_ctrl, .state = .released } },
    }, &mouse, style.Theme.default);

    try std.testing.expect(tree.get(ti).kind.text_input.hasSelection());

    // Click to position — should clear selection
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 30, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 30, .y = 20 } },
    }, &mouse, style.Theme.default);

    const input = &tree.get(ti).kind.text_input;
    try std.testing.expect(!input.hasSelection());
}

test "mouse drag selects text" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const ti = try tree.addChild(root, .{ .text_input = .{} });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(ti).layout_rect = .{ .x = 10, .y = 10, .w = 300, .h = 30 };

    var mouse = MouseState{};

    // Focus and type "hello"
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 20, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 20, .y = 20 } },
    }, &mouse, style.Theme.default);
    process(&tree, &.{
        .{ .text = .{ .codepoint = 'h' } },
        .{ .text = .{ .codepoint = 'e' } },
        .{ .text = .{ .codepoint = 'l' } },
        .{ .text = .{ .codepoint = 'l' } },
        .{ .text = .{ .codepoint = 'o' } },
    }, &mouse, style.Theme.default);

    // Default theme: font_size=14, padding.left=6, char_width=8.4
    // text_x = 10 + 6 = 16
    // Click at x=16 -> char 0; drag to x=41 -> char 3 (round(25/8.4)=round(2.98)=3)
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 16, .y = 20 } },
    }, &mouse, style.Theme.default);
    process(&tree, &.{
        .{ .mouse_move = .{ .x = 41, .y = 20 } },
    }, &mouse, style.Theme.default);

    const input = &tree.get(ti).kind.text_input;
    try std.testing.expect(input.hasSelection());
    const range = input.selectionRange();
    try std.testing.expectEqual(@as(u8, 0), range.start);
    try std.testing.expectEqual(@as(u8, 3), range.end);

    // Release — selection persists
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 41, .y = 20 } },
    }, &mouse, style.Theme.default);
    try std.testing.expect(input.hasSelection());
}

test "mouse drag backward selects text" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const ti = try tree.addChild(root, .{ .text_input = .{} });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(ti).layout_rect = .{ .x = 10, .y = 10, .w = 300, .h = 30 };

    var mouse = MouseState{};

    // Focus and type "hello"
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 20, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 20, .y = 20 } },
    }, &mouse, style.Theme.default);
    process(&tree, &.{
        .{ .text = .{ .codepoint = 'h' } },
        .{ .text = .{ .codepoint = 'e' } },
        .{ .text = .{ .codepoint = 'l' } },
        .{ .text = .{ .codepoint = 'l' } },
        .{ .text = .{ .codepoint = 'o' } },
    }, &mouse, style.Theme.default);

    // text_x = 16, char_width = 8.4
    // Click at x=41 -> char 3; drag back to x=16 -> char 0
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 41, .y = 20 } },
    }, &mouse, style.Theme.default);
    process(&tree, &.{
        .{ .mouse_move = .{ .x = 16, .y = 20 } },
    }, &mouse, style.Theme.default);

    const input = &tree.get(ti).kind.text_input;
    try std.testing.expect(input.hasSelection());
    const range = input.selectionRange();
    try std.testing.expectEqual(@as(u8, 0), range.start);
    try std.testing.expectEqual(@as(u8, 3), range.end);
}

test "click after drag clears selection" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const ti = try tree.addChild(root, .{ .text_input = .{} });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(ti).layout_rect = .{ .x = 10, .y = 10, .w = 300, .h = 30 };

    var mouse = MouseState{};

    // Focus and type "hello"
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 20, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 20, .y = 20 } },
    }, &mouse, style.Theme.default);
    process(&tree, &.{
        .{ .text = .{ .codepoint = 'h' } },
        .{ .text = .{ .codepoint = 'e' } },
        .{ .text = .{ .codepoint = 'l' } },
        .{ .text = .{ .codepoint = 'l' } },
        .{ .text = .{ .codepoint = 'o' } },
    }, &mouse, style.Theme.default);

    // Drag to select
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 16, .y = 20 } },
    }, &mouse, style.Theme.default);
    process(&tree, &.{
        .{ .mouse_move = .{ .x = 41, .y = 20 } },
    }, &mouse, style.Theme.default);
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 41, .y = 20 } },
    }, &mouse, style.Theme.default);

    try std.testing.expect(tree.get(ti).kind.text_input.hasSelection());

    // Click to clear
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 30, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 30, .y = 20 } },
    }, &mouse, style.Theme.default);

    try std.testing.expect(!tree.get(ti).kind.text_input.hasSelection());
}

test "shift+click extends selection from cursor" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const ti = try tree.addChild(root, .{ .text_input = .{} });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(ti).layout_rect = .{ .x = 10, .y = 10, .w = 300, .h = 30 };

    var mouse = MouseState{};

    // Focus and type "hello"
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 20, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 20, .y = 20 } },
    }, &mouse, style.Theme.default);
    process(&tree, &.{
        .{ .text = .{ .codepoint = 'h' } },
        .{ .text = .{ .codepoint = 'e' } },
        .{ .text = .{ .codepoint = 'l' } },
        .{ .text = .{ .codepoint = 'l' } },
        .{ .text = .{ .codepoint = 'o' } },
    }, &mouse, style.Theme.default);

    // Move cursor to position 1 (Home, Right)
    process(&tree, &.{
        .{ .key = .{ .scancode = 102, .keycode = .home, .state = .pressed } },
        .{ .key = .{ .scancode = 106, .keycode = .right, .state = .pressed } },
    }, &mouse, style.Theme.default);
    try std.testing.expectEqual(@as(u8, 1), tree.get(ti).kind.text_input.cursor);

    // Shift+click at char 4: text_x=16, char_width=8.4, midpoint of char 4 = 16 + 4.5*8.4 = 53.8
    process(&tree, &.{
        .{ .key = .{ .scancode = 42, .keycode = .left_shift, .state = .pressed } },
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 54, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 54, .y = 20 } },
    }, &mouse, style.Theme.default);

    const input = &tree.get(ti).kind.text_input;
    try std.testing.expect(input.hasSelection());
    try std.testing.expectEqual(@as(?u8, 1), input.selection_anchor);
    try std.testing.expectEqual(@as(u8, 5), input.cursor);
    try std.testing.expectEqualStrings("ello", input.selectedContent());
}

test "shift+click extends existing selection" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const ti = try tree.addChild(root, .{ .text_input = .{} });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(ti).layout_rect = .{ .x = 10, .y = 10, .w = 300, .h = 30 };

    var mouse = MouseState{};

    // Focus and type "abcde"
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 20, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 20, .y = 20 } },
    }, &mouse, style.Theme.default);
    process(&tree, &.{
        .{ .text = .{ .codepoint = 'a' } },
        .{ .text = .{ .codepoint = 'b' } },
        .{ .text = .{ .codepoint = 'c' } },
        .{ .text = .{ .codepoint = 'd' } },
        .{ .text = .{ .codepoint = 'e' } },
    }, &mouse, style.Theme.default);

    // Move cursor to position 3
    process(&tree, &.{
        .{ .key = .{ .scancode = 102, .keycode = .home, .state = .pressed } },
        .{ .key = .{ .scancode = 106, .keycode = .right, .state = .pressed } },
        .{ .key = .{ .scancode = 106, .keycode = .right, .state = .pressed } },
        .{ .key = .{ .scancode = 106, .keycode = .right, .state = .pressed } },
    }, &mouse, style.Theme.default);
    // cursor at 3, shift+left to select "c"
    process(&tree, &.{
        .{ .key = .{ .scancode = 42, .keycode = .left_shift, .state = .pressed } },
        .{ .key = .{ .scancode = 105, .keycode = .left, .state = .pressed } },
    }, &mouse, style.Theme.default);
    // anchor=3, cursor=2, selection="c"

    // Shift+click at char 0 to extend: x = 16 + 0*8.4 = 16
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 16, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 16, .y = 20 } },
    }, &mouse, style.Theme.default);

    const input = &tree.get(ti).kind.text_input;
    try std.testing.expect(input.hasSelection());
    // Anchor should remain at 3 (original anchor), cursor at 0
    try std.testing.expectEqual(@as(?u8, 3), input.selection_anchor);
    try std.testing.expectEqual(@as(u8, 0), input.cursor);
    try std.testing.expectEqualStrings("abc", input.selectedContent());
}

test "double-click selects word in text input" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const ti = try tree.addChild(root, .{ .text_input = .{} });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(ti).layout_rect = .{ .x = 10, .y = 10, .w = 300, .h = 30 };

    var mouse = MouseState{};

    // Focus and type "hello world"
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 20, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 20, .y = 20 } },
    }, &mouse, style.Theme.default);
    for ("hello world") |c| {
        process(&tree, &.{.{ .text = .{ .codepoint = c } }}, &mouse, style.Theme.default);
    }

    // Default theme: font_size=14, padding.left=6, char_width=8.4
    // text_x = 10 + 6 = 16
    // Double-click on "world" at char 7 ('o'): x = 16 + 7*8.4 = 74.8
    const click_x: f32 = 74.8;

    // First click at t=1000
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = click_x, .y = 20, .timestamp_ms = 1000 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = click_x, .y = 20, .timestamp_ms = 1000 } },
    }, &mouse, style.Theme.default);

    // Second click at t=1200 (within 400ms threshold)
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = click_x, .y = 20, .timestamp_ms = 1200 } },
    }, &mouse, style.Theme.default);

    const input = &tree.get(ti).kind.text_input;
    try std.testing.expect(input.hasSelection());
    try std.testing.expectEqualStrings("world", input.selectedContent());
}

test "double-click selects first word" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const ti = try tree.addChild(root, .{ .text_input = .{} });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(ti).layout_rect = .{ .x = 10, .y = 10, .w = 300, .h = 30 };

    var mouse = MouseState{};

    // Focus and type "hello world"
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 20, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 20, .y = 20 } },
    }, &mouse, style.Theme.default);
    for ("hello world") |c| {
        process(&tree, &.{.{ .text = .{ .codepoint = c } }}, &mouse, style.Theme.default);
    }

    // Double-click on "hello" at char 2 ('l'): x = 16 + 2*8.4 = 32.8
    const click_x: f32 = 32.8;
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = click_x, .y = 20, .timestamp_ms = 100 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = click_x, .y = 20, .timestamp_ms = 100 } },
    }, &mouse, style.Theme.default);
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = click_x, .y = 20, .timestamp_ms = 300 } },
    }, &mouse, style.Theme.default);

    const input = &tree.get(ti).kind.text_input;
    try std.testing.expect(input.hasSelection());
    try std.testing.expectEqualStrings("hello", input.selectedContent());
}

test "double-click on space selects space run" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const ti = try tree.addChild(root, .{ .text_input = .{} });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(ti).layout_rect = .{ .x = 10, .y = 10, .w = 300, .h = 30 };

    var mouse = MouseState{};

    // Focus and type "a  b" (two spaces)
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 20, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 20, .y = 20 } },
    }, &mouse, style.Theme.default);
    for ("a  b") |c| {
        process(&tree, &.{.{ .text = .{ .codepoint = c } }}, &mouse, style.Theme.default);
    }

    // Double-click on first space at char 1: x = 16 + 1*8.4 = 24.4
    const click_x: f32 = 24.4;
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = click_x, .y = 20, .timestamp_ms = 100 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = click_x, .y = 20, .timestamp_ms = 100 } },
    }, &mouse, style.Theme.default);
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = click_x, .y = 20, .timestamp_ms = 300 } },
    }, &mouse, style.Theme.default);

    const input = &tree.get(ti).kind.text_input;
    try std.testing.expect(input.hasSelection());
    try std.testing.expectEqualStrings("  ", input.selectedContent());
}

test "slow double-click does not select word" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const ti = try tree.addChild(root, .{ .text_input = .{} });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(ti).layout_rect = .{ .x = 10, .y = 10, .w = 300, .h = 30 };

    var mouse = MouseState{};

    // Focus and type "hello"
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 20, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 20, .y = 20 } },
    }, &mouse, style.Theme.default);
    for ("hello") |c| {
        process(&tree, &.{.{ .text = .{ .codepoint = c } }}, &mouse, style.Theme.default);
    }

    const click_x: f32 = 32.8;
    // First click at t=1000
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = click_x, .y = 20, .timestamp_ms = 1000 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = click_x, .y = 20, .timestamp_ms = 1000 } },
    }, &mouse, style.Theme.default);

    // Second click at t=2000 (too slow — 1000ms > 400ms threshold)
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = click_x, .y = 20, .timestamp_ms = 2000 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = click_x, .y = 20, .timestamp_ms = 2000 } },
    }, &mouse, style.Theme.default);

    const input = &tree.get(ti).kind.text_input;
    try std.testing.expect(!input.hasSelection());
}

// --- Clipboard tests ---

fn focusAndType(tree: *widget.Tree, mouse: *MouseState, ti: widget.NodeHandle, text: []const u8) void {
    process(tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 50, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 50, .y = 20 } },
    }, mouse, style.Theme.default);
    const view = std.unicode.Utf8View.initUnchecked(text);
    var iter = view.iterator();
    while (iter.nextCodepoint()) |codepoint| {
        process(tree, &.{.{ .text = .{ .codepoint = codepoint } }}, mouse, style.Theme.default);
    }
    _ = ti;
}

fn setupTextInput(allocator: std.mem.Allocator) !struct { tree: widget.Tree, ti: widget.NodeHandle } {
    var tree = widget.Tree.init(allocator);
    const root = try tree.addRoot(.{ .container = .{} });
    const ti = try tree.addChild(root, .{ .text_input = .{} });
    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(ti).layout_rect = .{ .x = 10, .y = 10, .w = 300, .h = 30 };
    return .{ .tree = tree, .ti = ti };
}

test "ctrl+c copies selected text to clipboard" {
    const allocator = std.testing.allocator;
    var s = try setupTextInput(allocator);
    defer s.tree.deinit();

    var mouse = MouseState{};
    var cb = TestClipboard{};

    focusAndType(&s.tree, &mouse, s.ti, "hello");

    // Select all
    processWithClipboard(&s.tree, &.{
        .{ .key = .{ .scancode = 29, .keycode = .left_ctrl, .state = .pressed } },
        .{ .key = .{ .scancode = 30, .keycode = .a, .state = .pressed } },
    }, &mouse, style.Theme.default, cb.clipboard(), null);

    // Ctrl+C
    processWithClipboard(&s.tree, &.{
        .{ .key = .{ .scancode = 46, .keycode = .c, .state = .pressed } },
    }, &mouse, style.Theme.default, cb.clipboard(), null);

    try std.testing.expectEqualStrings("hello", cb.buf[0..cb.len]);
    // Text should still be there (copy, not cut)
    try std.testing.expectEqualStrings("hello", s.tree.get(s.ti).kind.text_input.content());
}

test "ctrl+x cuts selected text to clipboard" {
    const allocator = std.testing.allocator;
    var s = try setupTextInput(allocator);
    defer s.tree.deinit();

    var mouse = MouseState{};
    var cb = TestClipboard{};

    focusAndType(&s.tree, &mouse, s.ti, "hello");

    // Select all
    processWithClipboard(&s.tree, &.{
        .{ .key = .{ .scancode = 29, .keycode = .left_ctrl, .state = .pressed } },
        .{ .key = .{ .scancode = 30, .keycode = .a, .state = .pressed } },
    }, &mouse, style.Theme.default, cb.clipboard(), null);

    // Ctrl+X
    processWithClipboard(&s.tree, &.{
        .{ .key = .{ .scancode = 45, .keycode = .x, .state = .pressed } },
    }, &mouse, style.Theme.default, cb.clipboard(), null);

    try std.testing.expectEqualStrings("hello", cb.buf[0..cb.len]);
    // Text should be deleted
    try std.testing.expectEqualStrings("", s.tree.get(s.ti).kind.text_input.content());
}

test "ctrl+v pastes text from clipboard" {
    const allocator = std.testing.allocator;
    var s = try setupTextInput(allocator);
    defer s.tree.deinit();

    var mouse = MouseState{};
    var cb = TestClipboard{};
    cb.setText("world");

    focusAndType(&s.tree, &mouse, s.ti, "hello ");

    // Ctrl+V
    processWithClipboard(&s.tree, &.{
        .{ .key = .{ .scancode = 29, .keycode = .left_ctrl, .state = .pressed } },
        .{ .key = .{ .scancode = 47, .keycode = .v, .state = .pressed } },
    }, &mouse, style.Theme.default, cb.clipboard(), null);

    try std.testing.expectEqualStrings("hello world", s.tree.get(s.ti).kind.text_input.content());
}

test "ctrl+v pastes UTF-8 text from clipboard" {
    const allocator = std.testing.allocator;
    var s = try setupTextInput(allocator);
    defer s.tree.deinit();

    var mouse = MouseState{};
    var cb = TestClipboard{};
    cb.setText("世界🙂");

    focusAndType(&s.tree, &mouse, s.ti, "hi ");

    processWithClipboard(&s.tree, &.{
        .{ .key = .{ .scancode = 29, .keycode = .left_ctrl, .state = .pressed } },
        .{ .key = .{ .scancode = 47, .keycode = .v, .state = .pressed } },
    }, &mouse, style.Theme.default, cb.clipboard(), null);

    try std.testing.expectEqualStrings("hi 世界🙂", s.tree.get(s.ti).kind.text_input.content());
}

test "ctrl+v replaces selection" {
    const allocator = std.testing.allocator;
    var s = try setupTextInput(allocator);
    defer s.tree.deinit();

    var mouse = MouseState{};
    var cb = TestClipboard{};
    cb.setText("goodbye");

    focusAndType(&s.tree, &mouse, s.ti, "hello");

    // Select all, then paste
    processWithClipboard(&s.tree, &.{
        .{ .key = .{ .scancode = 29, .keycode = .left_ctrl, .state = .pressed } },
        .{ .key = .{ .scancode = 30, .keycode = .a, .state = .pressed } },
    }, &mouse, style.Theme.default, cb.clipboard(), null);

    processWithClipboard(&s.tree, &.{
        .{ .key = .{ .scancode = 47, .keycode = .v, .state = .pressed } },
    }, &mouse, style.Theme.default, cb.clipboard(), null);

    try std.testing.expectEqualStrings("goodbye", s.tree.get(s.ti).kind.text_input.content());
}

test "ctrl+c without selection is no-op" {
    const allocator = std.testing.allocator;
    var s = try setupTextInput(allocator);
    defer s.tree.deinit();

    var mouse = MouseState{};
    var cb = TestClipboard{};

    focusAndType(&s.tree, &mouse, s.ti, "hello");

    // Ctrl+C with no selection
    processWithClipboard(&s.tree, &.{
        .{ .key = .{ .scancode = 29, .keycode = .left_ctrl, .state = .pressed } },
        .{ .key = .{ .scancode = 46, .keycode = .c, .state = .pressed } },
    }, &mouse, style.Theme.default, cb.clipboard(), null);

    try std.testing.expectEqual(@as(usize, 0), cb.len);
}

test "ctrl+v with empty clipboard is no-op" {
    const allocator = std.testing.allocator;
    var s = try setupTextInput(allocator);
    defer s.tree.deinit();

    var mouse = MouseState{};
    var cb = TestClipboard{};

    focusAndType(&s.tree, &mouse, s.ti, "hello");

    // Ctrl+V with empty clipboard
    processWithClipboard(&s.tree, &.{
        .{ .key = .{ .scancode = 29, .keycode = .left_ctrl, .state = .pressed } },
        .{ .key = .{ .scancode = 47, .keycode = .v, .state = .pressed } },
    }, &mouse, style.Theme.default, cb.clipboard(), null);

    try std.testing.expectEqualStrings("hello", s.tree.get(s.ti).kind.text_input.content());
}

test "clipboard operations without clipboard provider are no-ops" {
    const allocator = std.testing.allocator;
    var s = try setupTextInput(allocator);
    defer s.tree.deinit();

    var mouse = MouseState{};

    focusAndType(&s.tree, &mouse, s.ti, "hello");

    // Select all, Ctrl+C without clipboard — should not crash
    process(&s.tree, &.{
        .{ .key = .{ .scancode = 29, .keycode = .left_ctrl, .state = .pressed } },
        .{ .key = .{ .scancode = 30, .keycode = .a, .state = .pressed } },
        .{ .key = .{ .scancode = 46, .keycode = .c, .state = .pressed } },
    }, &mouse, style.Theme.default);

    try std.testing.expectEqualStrings("hello", s.tree.get(s.ti).kind.text_input.content());
}

test "cut-paste round trip" {
    const allocator = std.testing.allocator;
    var s = try setupTextInput(allocator);
    defer s.tree.deinit();

    var mouse = MouseState{};
    var cb = TestClipboard{};

    focusAndType(&s.tree, &mouse, s.ti, "abcdef");

    // Select "cd" (positions 2-4): Home, Right, Right, Shift+Right, Shift+Right
    processWithClipboard(&s.tree, &.{
        .{ .key = .{ .scancode = 102, .keycode = .home, .state = .pressed } },
        .{ .key = .{ .scancode = 106, .keycode = .right, .state = .pressed } },
        .{ .key = .{ .scancode = 106, .keycode = .right, .state = .pressed } },
        .{ .key = .{ .scancode = 42, .keycode = .left_shift, .state = .pressed } },
        .{ .key = .{ .scancode = 106, .keycode = .right, .state = .pressed } },
        .{ .key = .{ .scancode = 106, .keycode = .right, .state = .pressed } },
    }, &mouse, style.Theme.default, cb.clipboard(), null);

    // Cut
    processWithClipboard(&s.tree, &.{
        .{ .key = .{ .scancode = 42, .keycode = .left_shift, .state = .released } },
        .{ .key = .{ .scancode = 29, .keycode = .left_ctrl, .state = .pressed } },
        .{ .key = .{ .scancode = 45, .keycode = .x, .state = .pressed } },
    }, &mouse, style.Theme.default, cb.clipboard(), null);

    try std.testing.expectEqualStrings("cd", cb.buf[0..cb.len]);
    try std.testing.expectEqualStrings("abef", s.tree.get(s.ti).kind.text_input.content());

    // Move to end, paste
    processWithClipboard(&s.tree, &.{
        .{ .key = .{ .scancode = 29, .keycode = .left_ctrl, .state = .released } },
        .{ .key = .{ .scancode = 107, .keycode = .end, .state = .pressed } },
        .{ .key = .{ .scancode = 29, .keycode = .left_ctrl, .state = .pressed } },
        .{ .key = .{ .scancode = 47, .keycode = .v, .state = .pressed } },
    }, &mouse, style.Theme.default, cb.clipboard(), null);

    try std.testing.expectEqualStrings("abefcd", s.tree.get(s.ti).kind.text_input.content());
}
