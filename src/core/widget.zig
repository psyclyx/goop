const std = @import("std");
const style = @import("style.zig");
const draw = @import("draw.zig");

/// Handle to a widget node. Carries an index into the tree's node array
/// and a generation counter for stale-handle detection.
pub const NodeHandle = struct {
    index: u32,
    generation: u32,

    /// Two handles are equal iff both index and generation match.
    pub fn eql(a: NodeHandle, b: NodeHandle) bool {
        return a.index == b.index and a.generation == b.generation;
    }
};

/// Interaction state tracked per widget.
pub const InteractionState = struct {
    hovered: bool = false,
    pressed: bool = false,
    focused: bool = false,
};

/// Widget-specific data.
pub const WidgetKind = union(enum) {
    container: Container,
    text: Text,
    button: Button,
    checkbox: Checkbox,
    radio_button: RadioButton,
    slider: Slider,
    scroll_area: ScrollArea,
    text_input: TextInput,

    pub const Container = struct {
        direction: Direction = .column,

        pub const Direction = enum { row, column };
    };

    pub const Text = struct {
        content: []const u8,
    };

    pub const Button = struct {
        label: []const u8,
        clicked: bool = false,
    };

    pub const Checkbox = struct {
        label: []const u8,
        checked: bool = false,
        clicked: bool = false,
    };

    pub const RadioButton = struct {
        label: []const u8,
        group: u32,
        selected: bool = false,
        clicked: bool = false,
    };

    pub const Slider = struct {
        value: f32 = 0,
        min: f32 = 0,
        max: f32 = 1,
    };

    pub const ScrollArea = struct {
        scroll_x: f32 = 0,
        scroll_y: f32 = 0,
    };

    pub const TextInput = struct {
        buffer: [256]u8 = [_]u8{0} ** 256,
        len: u8 = 0,
        cursor: u8 = 0,
        selection_anchor: ?u8 = null,
        placeholder: []const u8 = "",

        pub fn content(self: *const TextInput) []const u8 {
            return self.buffer[0..self.len];
        }

        pub fn hasSelection(self: *const TextInput) bool {
            if (self.selection_anchor) |anchor| {
                return anchor != self.cursor;
            }
            return false;
        }

        pub fn selectionRange(self: *const TextInput) struct { start: u8, end: u8 } {
            const anchor = self.selection_anchor orelse self.cursor;
            return if (anchor < self.cursor)
                .{ .start = anchor, .end = self.cursor }
            else
                .{ .start = self.cursor, .end = anchor };
        }

        pub fn selectedContent(self: *const TextInput) []const u8 {
            const range = self.selectionRange();
            return self.buffer[range.start..range.end];
        }

        pub fn deleteSelection(self: *TextInput) void {
            const range = self.selectionRange();
            self.deleteRange(range.start, range.end);
        }

        pub fn clearSelection(self: *TextInput) void {
            self.selection_anchor = null;
        }

        pub fn deleteRange(self: *TextInput, start: u8, end: u8) void {
            if (start >= end) return;
            const count = end - start;
            var i: usize = start;
            while (i < self.len - count) : (i += 1) {
                self.buffer[i] = self.buffer[i + count];
            }
            self.len -= count;
            self.cursor = start;
            self.clearSelection();
        }

        pub fn insert(self: *TextInput, byte: u8) void {
            if (self.hasSelection()) self.deleteSelection();
            if (self.len >= self.buffer.len) return;
            // Shift bytes right to make room at cursor
            var i: usize = self.len;
            while (i > self.cursor) : (i -= 1) {
                self.buffer[i] = self.buffer[i - 1];
            }
            self.buffer[self.cursor] = byte;
            self.len += 1;
            self.cursor += 1;
            self.clearSelection();
        }

        pub fn insertSlice(self: *TextInput, text: []const u8) void {
            if (self.hasSelection()) self.deleteSelection();
            const available = self.buffer.len - self.len;
            const count: u8 = @intCast(@min(text.len, available));
            if (count == 0) return;
            // Shift existing bytes right
            var i: usize = self.len + count - 1;
            while (i >= self.cursor + count) : (i -= 1) {
                self.buffer[i] = self.buffer[i - count];
            }
            // Copy new text in
            @memcpy(self.buffer[self.cursor .. self.cursor + count], text[0..count]);
            self.len += count;
            self.cursor += count;
            self.clearSelection();
        }

        pub fn deleteBack(self: *TextInput) void {
            if (self.hasSelection()) {
                self.deleteSelection();
                return;
            }
            if (self.cursor == 0) return;
            // Shift bytes left over the deleted character
            const pos = self.cursor - 1;
            var i: usize = pos;
            while (i < self.len - 1) : (i += 1) {
                self.buffer[i] = self.buffer[i + 1];
            }
            self.len -= 1;
            self.cursor -= 1;
        }

        pub fn prevWordBoundary(self: *const TextInput, pos: u8) u8 {
            if (pos == 0 or self.len == 0) return 0;

            var i: usize = @min(pos, self.len);

            while (i > 0 and charClass(self.buffer[i - 1]) == .space) : (i -= 1) {}
            if (i == 0) return 0;

            const cls = charClass(self.buffer[i - 1]);
            while (i > 0 and charClass(self.buffer[i - 1]) == cls) : (i -= 1) {}

            return @intCast(i);
        }

        pub fn nextWordBoundary(self: *const TextInput, pos: u8) u8 {
            var i: usize = @min(pos, self.len);
            if (i >= self.len) return self.len;

            while (i < self.len and charClass(self.buffer[i]) == .space) : (i += 1) {}
            if (i >= self.len) return self.len;

            const cls = charClass(self.buffer[i]);
            while (i < self.len and charClass(self.buffer[i]) == cls) : (i += 1) {}

            return @intCast(i);
        }

        pub fn deleteBackWord(self: *TextInput) void {
            if (self.hasSelection()) {
                self.deleteSelection();
                return;
            }
            if (self.cursor == 0) return;
            const start = self.prevWordBoundary(self.cursor);
            self.deleteRange(start, self.cursor);
        }

        pub fn deleteForwardWord(self: *TextInput) void {
            if (self.hasSelection()) {
                self.deleteSelection();
                return;
            }
            if (self.cursor >= self.len) return;
            const end = self.nextWordBoundary(self.cursor);
            self.deleteRange(self.cursor, end);
        }

        /// Find the word boundaries around the given position.
        /// Words are runs of alphanumeric/underscore characters.
        pub fn wordBounds(self: *const TextInput, pos: u8) struct { start: u8, end: u8 } {
            if (self.len == 0) return .{ .start = 0, .end = 0 };
            const p: usize = if (pos >= self.len) self.len - 1 else pos;
            const text = self.buffer[0..self.len];
            const is_word = isWordChar(text[p]);
            // Scan left
            var start: usize = p;
            while (start > 0 and isWordChar(text[start - 1]) == is_word) start -= 1;
            // Scan right
            var end: usize = p;
            while (end < self.len and isWordChar(text[end]) == is_word) end += 1;
            return .{ .start = @intCast(start), .end = @intCast(end) };
        }

        fn isWordChar(c: u8) bool {
            return std.ascii.isAlphanumeric(c) or c == '_';
        }

        const CharClass = enum { word, space, other };

        fn charClass(c: u8) CharClass {
            if (std.ascii.isWhitespace(c)) return .space;
            if (isWordChar(c)) return .word;
            return .other;
        }

        pub fn deleteForward(self: *TextInput) void {
            if (self.hasSelection()) {
                self.deleteSelection();
                return;
            }
            if (self.cursor >= self.len) return;
            var i: usize = self.cursor;
            while (i < self.len - 1) : (i += 1) {
                self.buffer[i] = self.buffer[i + 1];
            }
            self.len -= 1;
        }
    };
};

/// A single node in the widget tree.
pub const Node = struct {
    kind: WidgetKind,
    style_override: style.Style = .{},
    interaction: InteractionState = .{},
    layout_rect: draw.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },

    parent: ?NodeHandle = null,
    first_child: ?NodeHandle = null,
    last_child: ?NodeHandle = null,
    next_sibling: ?NodeHandle = null,
    prev_sibling: ?NodeHandle = null,

    generation: u32 = 0,
    alive: bool = true,
};

/// The retained widget tree.
pub const Tree = struct {
    nodes: std.ArrayListUnmanaged(Node) = .empty,
    free_list: std.ArrayListUnmanaged(u32) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Tree {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Tree) void {
        self.free_list.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
    }

    /// Add a root-level widget. Returns its handle.
    pub fn addRoot(self: *Tree, kind: WidgetKind) !NodeHandle {
        return self.addNode(kind, null);
    }

    /// Add a child widget under the given parent. Returns its handle.
    pub fn addChild(self: *Tree, parent: NodeHandle, kind: WidgetKind) !NodeHandle {
        return self.addNode(kind, parent);
    }

    /// Remove a node and all its descendants from the tree.
    /// The handle becomes invalid after this call.
    pub fn remove(self: *Tree, handle: NodeHandle) !void {
        const node = self.getMut(handle);

        // Recursively remove children first
        var child = node.first_child;
        while (child) |ch| {
            const next = self.nodes.items[ch.index].next_sibling;
            try self.remove(ch);
            child = next;
        }

        // Unlink from parent's child list
        if (node.parent) |ph| {
            const parent = &self.nodes.items[ph.index];
            if (parent.first_child) |fc| {
                if (fc.eql(handle)) {
                    parent.first_child = node.next_sibling;
                }
            }
            if (parent.last_child) |lc| {
                if (lc.eql(handle)) {
                    parent.last_child = node.prev_sibling;
                }
            }
        }

        // Unlink from sibling chain
        if (node.prev_sibling) |prev| {
            self.nodes.items[prev.index].next_sibling = node.next_sibling;
        }
        if (node.next_sibling) |nxt| {
            self.nodes.items[nxt.index].prev_sibling = node.prev_sibling;
        }

        // Mark dead, bump generation, push to free list
        node.alive = false;
        node.generation +%= 1;
        node.parent = null;
        node.first_child = null;
        node.last_child = null;
        node.next_sibling = null;
        node.prev_sibling = null;
        try self.free_list.append(self.allocator, handle.index);
    }

    /// Get a pointer to a node by handle.
    /// Asserts the handle is valid (generation matches and node is alive).
    pub fn get(self: *Tree, handle: NodeHandle) *Node {
        const node = &self.nodes.items[handle.index];
        std.debug.assert(node.alive and node.generation == handle.generation);
        return node;
    }

    /// Get a const pointer to a node by handle.
    pub fn getConst(self: *const Tree, handle: NodeHandle) *const Node {
        const node = &self.nodes.items[handle.index];
        std.debug.assert(node.alive and node.generation == handle.generation);
        return node;
    }

    /// Check whether a handle refers to a living node.
    pub fn isAlive(self: *const Tree, handle: NodeHandle) bool {
        if (handle.index >= self.nodes.items.len) return false;
        const node = &self.nodes.items[handle.index];
        return node.alive and node.generation == handle.generation;
    }

    /// Build a handle for a live node at the given index.
    /// Used by modules that iterate nodes by index.
    pub fn handleFromIndex(self: *const Tree, index: u32) NodeHandle {
        return .{ .index = index, .generation = self.nodes.items[index].generation };
    }

    /// Number of live nodes in the tree.
    pub fn count(self: *const Tree) u32 {
        return @as(u32, @intCast(self.nodes.items.len)) - @as(u32, @intCast(self.free_list.items.len));
    }

    /// Total number of slots (live + dead). Used for layout dirty checks.
    pub fn slotCount(self: *const Tree) u32 {
        return @intCast(self.nodes.items.len);
    }

    /// Iterate children of a node.
    pub fn children(self: *const Tree, parent: NodeHandle) ChildIterator {
        return .{
            .tree = self,
            .current = self.getConst(parent).first_child,
        };
    }

    fn addNode(self: *Tree, kind: WidgetKind, parent_handle: ?NodeHandle) !NodeHandle {
        var index: u32 = undefined;
        var generation: u32 = undefined;

        if (self.free_list.pop()) |reuse_index| {
            // Reuse a dead slot
            index = reuse_index;
            generation = self.nodes.items[index].generation;
            self.nodes.items[index] = .{
                .kind = kind,
                .parent = parent_handle,
                .generation = generation,
            };
        } else {
            // Append new slot
            index = @intCast(self.nodes.items.len);
            generation = 0;
            try self.nodes.append(self.allocator, .{
                .kind = kind,
                .parent = parent_handle,
            });
        }

        const handle: NodeHandle = .{ .index = index, .generation = generation };

        if (parent_handle) |ph| {
            const parent = self.get(ph);
            if (parent.last_child) |last| {
                self.nodes.items[last.index].next_sibling = handle;
                self.nodes.items[index].prev_sibling = last;
            } else {
                parent.first_child = handle;
            }
            parent.last_child = handle;
        }

        return handle;
    }

    /// Internal: get a mutable pointer without generation check (for remove).
    fn getMut(self: *Tree, handle: NodeHandle) *Node {
        const node = &self.nodes.items[handle.index];
        std.debug.assert(node.alive and node.generation == handle.generation);
        return node;
    }

    pub const ChildIterator = struct {
        tree: *const Tree,
        current: ?NodeHandle,

        pub fn next(self: *ChildIterator) ?NodeHandle {
            const cur = self.current orelse return null;
            self.current = self.tree.getConst(cur).next_sibling;
            return cur;
        }
    };
};

test "build and traverse widget tree" {
    const allocator = std.testing.allocator;
    var tree = Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const btn = try tree.addChild(root, .{ .button = .{ .label = "OK" } });
    const txt = try tree.addChild(root, .{ .text = .{ .content = "hello" } });

    try std.testing.expectEqual(@as(u32, 3), tree.count());
    try std.testing.expect(tree.getConst(root).parent == null);
    try std.testing.expect(tree.getConst(btn).parent.?.eql(root));

    var iter = tree.children(root);
    const first = iter.next().?;
    try std.testing.expect(first.eql(btn));
    const second = iter.next().?;
    try std.testing.expect(second.eql(txt));
    try std.testing.expect(iter.next() == null);
}

test "remove leaf node" {
    const allocator = std.testing.allocator;
    var tree = Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const btn = try tree.addChild(root, .{ .button = .{ .label = "A" } });
    _ = try tree.addChild(root, .{ .text = .{ .content = "B" } });

    try std.testing.expectEqual(@as(u32, 3), tree.count());

    try tree.remove(btn);
    try std.testing.expectEqual(@as(u32, 2), tree.count());
    try std.testing.expect(!tree.isAlive(btn));

    // Remaining child is still reachable
    var iter = tree.children(root);
    try std.testing.expect(iter.next() != null);
    try std.testing.expect(iter.next() == null);
}

test "remove subtree recursively" {
    const allocator = std.testing.allocator;
    var tree = Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const group = try tree.addChild(root, .{ .container = .{} });
    _ = try tree.addChild(group, .{ .text = .{ .content = "child1" } });
    _ = try tree.addChild(group, .{ .text = .{ .content = "child2" } });

    try std.testing.expectEqual(@as(u32, 4), tree.count());

    try tree.remove(group);
    try std.testing.expectEqual(@as(u32, 1), tree.count());

    // Root has no children
    var iter = tree.children(root);
    try std.testing.expect(iter.next() == null);
}

test "slot reuse after removal" {
    const allocator = std.testing.allocator;
    var tree = Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const btn = try tree.addChild(root, .{ .button = .{ .label = "old" } });
    const old_index = btn.index;

    try tree.remove(btn);

    // Adding a new node should reuse the freed slot
    const new_btn = try tree.addChild(root, .{ .button = .{ .label = "new" } });
    try std.testing.expectEqual(old_index, new_btn.index);
    // Generation must differ
    try std.testing.expect(new_btn.generation != btn.generation);
    try std.testing.expect(!btn.eql(new_btn));
    try std.testing.expect(tree.isAlive(new_btn));
    try std.testing.expect(!tree.isAlive(btn));
}

test "remove middle sibling preserves order" {
    const allocator = std.testing.allocator;
    var tree = Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const a = try tree.addChild(root, .{ .text = .{ .content = "A" } });
    const b = try tree.addChild(root, .{ .text = .{ .content = "B" } });
    const cc = try tree.addChild(root, .{ .text = .{ .content = "C" } });

    try tree.remove(b);

    var iter = tree.children(root);
    const first = iter.next().?;
    try std.testing.expect(first.eql(a));
    const second = iter.next().?;
    try std.testing.expect(second.eql(cc));
    try std.testing.expect(iter.next() == null);
}

test "wordBounds finds word boundaries" {
    var ti = WidgetKind.TextInput{};
    for ("hello world") |c| ti.insert(c);

    // In middle of "hello"
    const b1 = ti.wordBounds(2);
    try std.testing.expectEqual(@as(u8, 0), b1.start);
    try std.testing.expectEqual(@as(u8, 5), b1.end);

    // On the space
    const b2 = ti.wordBounds(5);
    try std.testing.expectEqual(@as(u8, 5), b2.start);
    try std.testing.expectEqual(@as(u8, 6), b2.end);

    // In "world"
    const b3 = ti.wordBounds(8);
    try std.testing.expectEqual(@as(u8, 6), b3.start);
    try std.testing.expectEqual(@as(u8, 11), b3.end);

    // At start
    const b4 = ti.wordBounds(0);
    try std.testing.expectEqual(@as(u8, 0), b4.start);
    try std.testing.expectEqual(@as(u8, 5), b4.end);

    // Past end (clamped)
    const b5 = ti.wordBounds(20);
    try std.testing.expectEqual(@as(u8, 6), b5.start);
    try std.testing.expectEqual(@as(u8, 11), b5.end);
}

test "wordBounds on empty input" {
    const ti = WidgetKind.TextInput{};
    const b = ti.wordBounds(0);
    try std.testing.expectEqual(@as(u8, 0), b.start);
    try std.testing.expectEqual(@as(u8, 0), b.end);
}
