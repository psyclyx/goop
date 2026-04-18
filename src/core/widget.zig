const std = @import("std");
const style = @import("style.zig");
const draw = @import("draw.zig");

/// Handle to a widget node. Index into the tree's node array.
pub const NodeHandle = enum(u32) {
    root = 0,
    _,
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
    slider: Slider,
    scroll_area: ScrollArea,

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

    pub const Slider = struct {
        value: f32 = 0,
        min: f32 = 0,
        max: f32 = 1,
    };

    pub const ScrollArea = struct {
        scroll_x: f32 = 0,
        scroll_y: f32 = 0,
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
};

/// The retained widget tree.
pub const Tree = struct {
    nodes: std.ArrayListUnmanaged(Node) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Tree {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Tree) void {
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

    /// Get a pointer to a node by handle.
    pub fn get(self: *Tree, handle: NodeHandle) *Node {
        return &self.nodes.items[@intFromEnum(handle)];
    }

    /// Get a const pointer to a node by handle.
    pub fn getConst(self: *const Tree, handle: NodeHandle) *const Node {
        return &self.nodes.items[@intFromEnum(handle)];
    }

    /// Number of nodes in the tree.
    pub fn count(self: *const Tree) u32 {
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
        const index: u32 = @intCast(self.nodes.items.len);
        const handle: NodeHandle = @enumFromInt(index);

        try self.nodes.append(self.allocator, .{
            .kind = kind,
            .parent = parent_handle,
        });

        if (parent_handle) |ph| {
            const parent = self.get(ph);
            if (parent.last_child) |last| {
                self.get(last).next_sibling = handle;
                self.nodes.items[index].prev_sibling = last;
            } else {
                parent.first_child = handle;
            }
            parent.last_child = handle;
        }

        return handle;
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
    try std.testing.expectEqual(@as(?NodeHandle, null), tree.getConst(root).parent);
    try std.testing.expectEqual(@as(?NodeHandle, root), tree.getConst(btn).parent);

    var iter = tree.children(root);
    try std.testing.expectEqual(@as(?NodeHandle, btn), iter.next());
    try std.testing.expectEqual(@as(?NodeHandle, txt), iter.next());
    try std.testing.expectEqual(@as(?NodeHandle, null), iter.next());
}
