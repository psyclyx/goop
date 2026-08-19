//! Time-driven tooltip presentation state.
//!
//! Pointer dispatch owns hover/focus. This module turns that input state plus
//! an explicit monotonic clock into tooltip visibility and a next wake-up
//! deadline. Hosts therefore do not need timers per widget, and layout/chrome
//! consume one already-resolved `Tooltip.visible` flag.

const std = @import("std");
const widget = @import("../widget.zig");
const types = @import("types.zig");

const MouseState = types.MouseState;

pub const State = struct {
    owner: ?widget.NodeHandle = null,
    owner_element_id: ?widget.ElementId = null,
    started_at_ms: u64 = 0,
};

pub const UpdateResult = struct {
    changed: bool = false,
    next_deadline_ms: ?u64 = null,
};

const Candidate = struct {
    owner: widget.NodeHandle,
    owner_element_id: ?widget.ElementId,
    tooltip: widget.NodeHandle,
};

pub fn update(tree: *widget.Tree, mouse: *const MouseState, state: *State, now_ms: u64) UpdateResult {
    const candidate = findCandidate(tree, mouse);
    if (candidate == null) {
        const changed = setOnlyVisibleTooltip(tree, null);
        state.* = .{};
        return .{ .changed = changed };
    }

    const current = candidate.?;
    const same_owner = sameLogicalOwner(state.*, current);
    if (!same_owner) state.started_at_ms = now_ms;
    state.owner = current.owner;
    state.owner_element_id = current.owner_element_id;

    const delay_ms: u64 = tree.getConst(current.tooltip).kind.tooltip.delay_ms;
    const deadline = state.started_at_ms +| delay_ms;
    const should_show = now_ms >= deadline;
    const changed = setOnlyVisibleTooltip(tree, if (should_show) current.tooltip else null);
    return .{
        .changed = changed,
        .next_deadline_ms = if (should_show) null else deadline,
    };
}

fn findCandidate(tree: *const widget.Tree, mouse: *const MouseState) ?Candidate {
    if (tooltipCandidate(tree, mouse.hovered)) |candidate| return candidate;
    return tooltipCandidate(tree, mouse.focused);
}

fn tooltipCandidate(tree: *const widget.Tree, owner: ?widget.NodeHandle) ?Candidate {
    const owner_handle = owner orelse return null;
    if (!tree.isAlive(owner_handle)) return null;
    var children = tree.children(owner_handle);
    while (children.next()) |child| {
        if (tree.getConst(child).kind == .tooltip) return .{
            .owner = owner_handle,
            .owner_element_id = tree.elementId(owner_handle),
            .tooltip = child,
        };
    }
    return null;
}

fn sameLogicalOwner(state: State, candidate: Candidate) bool {
    if (state.owner) |owner| {
        if (owner.eql(candidate.owner)) return true;
    }
    if (state.owner_element_id) |id| {
        if (candidate.owner_element_id) |candidate_id| return id == candidate_id;
    }
    return false;
}

fn setOnlyVisibleTooltip(tree: *widget.Tree, visible: ?widget.NodeHandle) bool {
    var changed = false;
    for (tree.nodes.items, 0..) |*node, index| {
        if (!node.alive or node.kind != .tooltip) continue;
        const handle = tree.handleFromIndex(@intCast(index));
        const next = if (visible) |shown| shown.eql(handle) else false;
        if (node.kind.tooltip.visible != next) {
            node.kind.tooltip.visible = next;
            changed = true;
        }
    }
    return changed;
}

test "tooltip delay is monotonic and moving between owners restarts it" {
    var tree = widget.Tree.init(std.testing.allocator);
    defer tree.deinit();
    const root = try tree.addRoot(.{ .container = .{} });
    const first = try tree.addChild(root, .{ .button = .{ .label = "First" } });
    const first_tip = try tree.addChild(first, .{ .tooltip = .{ .delay_ms = 500 } });
    const second = try tree.addChild(root, .{ .button = .{ .label = "Second" } });
    const second_tip = try tree.addChild(second, .{ .tooltip = .{ .delay_ms = 200 } });
    var mouse: MouseState = .{ .hovered = first };
    var state: State = .{};

    try std.testing.expectEqual(@as(?u64, 600), update(&tree, &mouse, &state, 100).next_deadline_ms);
    try std.testing.expect(!tree.getConst(first_tip).kind.tooltip.visible);
    try std.testing.expect(!update(&tree, &mouse, &state, 599).changed);
    try std.testing.expect(update(&tree, &mouse, &state, 600).changed);
    try std.testing.expect(tree.getConst(first_tip).kind.tooltip.visible);

    mouse.hovered = second;
    const moved = update(&tree, &mouse, &state, 700);
    try std.testing.expect(moved.changed);
    try std.testing.expectEqual(@as(?u64, 900), moved.next_deadline_ms);
    try std.testing.expect(!tree.getConst(first_tip).kind.tooltip.visible);
    try std.testing.expect(!tree.getConst(second_tip).kind.tooltip.visible);
    try std.testing.expect(update(&tree, &mouse, &state, 900).changed);
    try std.testing.expect(tree.getConst(second_tip).kind.tooltip.visible);
}

test "tooltip deadline survives a tree rebuild with stable owner identity" {
    var tree = widget.Tree.init(std.testing.allocator);
    defer tree.deinit();
    var owner = try tree.addRoot(.{ .button = .{ .label = "Owner" } });
    try tree.setElementId(owner, .init(41));
    _ = try tree.addChild(owner, .{ .tooltip = .{ .delay_ms = 500 } });
    var mouse: MouseState = .{ .hovered = owner };
    var state: State = .{};
    _ = update(&tree, &mouse, &state, 100);

    try tree.remove(owner);
    owner = try tree.addRoot(.{ .button = .{ .label = "Owner" } });
    try tree.setElementId(owner, .init(41));
    const tooltip = try tree.addChild(owner, .{ .tooltip = .{ .delay_ms = 500 } });
    mouse.hovered = owner;

    try std.testing.expectEqual(@as(?u64, 600), update(&tree, &mouse, &state, 400).next_deadline_ms);
    try std.testing.expect(update(&tree, &mouse, &state, 600).changed);
    try std.testing.expect(tree.getConst(tooltip).kind.tooltip.visible);
}
