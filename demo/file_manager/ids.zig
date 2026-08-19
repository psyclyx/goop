//! Stable semantic identities for the file-manager projection.
//!
//! The high byte names an element family; the low 56 bits carry either a
//! fixed value or a session-long monotonic token. These are application
//! identities, not tree-node identities or projection positions.

const std = @import("std");
const desktop = @import("goop_desktop");
const types = @import("types.zig");

pub const ElementId = desktop.ElementId;
pub const ActionId = desktop.ActionId;

pub const Family = enum(u8) {
    fixed = 1,
    asset = 2,
    place = 3,
    folder = 4,
    breadcrumb = 5,
    command = 6,
};

pub const Fixed = enum(u56) {
    root = 1,
    address_input,
    address_go,
    nav_splitter,
    detail_splitter,
    preview_splitter,
    sidebar_scroll,
    file_panel_scroll,
    asset_header_table,
    asset_body_table,
    asset_grid,
    rename_input,
    permission_edit,
    permission_owner_read,
    permission_owner_write,
    permission_owner_execute,
    permission_owner_special,
    permission_group_read,
    permission_group_write,
    permission_group_execute,
    permission_group_special,
    permission_other_read,
    permission_other_write,
    permission_other_execute,
    permission_other_special,
    permission_apply,
    permission_cancel,
    preview_image,
    context_popup,
    context_open,
    context_paste,
    context_rename,
    context_copy_path,
    context_open_link_target,
    menu_file,
    menu_file_popup,
    menu_edit,
    menu_edit_popup,
    menu_view,
    menu_view_popup,
    menu_go,
    menu_go_popup,
    menu_help,
    menu_help_popup,
};

pub fn fixed(value: Fixed) ElementId {
    return encode(.fixed, @intFromEnum(value));
}

pub const CommandSurface = enum(u8) {
    toolbar = 1,
    sidebar_header,
    preview_header,
    details_header,
    breadcrumb,
    file_menu,
    edit_menu,
    view_menu,
    go_menu,
    help_menu,
    context_menu,
};

pub fn commandElement(surface: CommandSurface, command_value: types.BrowserCommand) ElementId {
    const payload = (@as(u64, @intFromEnum(surface)) << 16) | (@as(u64, @intFromEnum(command_value)) + 1);
    return encode(.command, payload);
}

pub fn commandAction(command_value: types.BrowserCommand) ActionId {
    return .init(@intFromEnum(command_value) + 1);
}

pub fn commandFromAction(action: ActionId) ?types.BrowserCommand {
    const raw = action.value();
    if (raw == 0 or raw > @typeInfo(types.BrowserCommand).@"enum".fields.len) return null;
    return @enumFromInt(raw - 1);
}

pub fn family(id: ElementId) Family {
    return @enumFromInt(@as(u8, @intCast(id.value() >> 56)));
}

pub fn token(id: ElementId) u64 {
    return @intCast(id.value() & 0x00ff_ffff_ffff_ffff);
}

fn encode(kind: Family, payload: u64) ElementId {
    return .init((@as(u64, @intFromEnum(kind)) << 56) | (payload & 0x00ff_ffff_ffff_ffff));
}

/// Collision-free identities for durable domain paths.
///
/// Tokens are monotonic and never derived from ordering or a hash. Records are
/// retained for the session, so rebuilding, filtering, or sorting a projection
/// cannot make an in-flight activation identify a different path.
pub const Registry = struct {
    allocator: std.mem.Allocator = std.heap.smp_allocator,
    next_token: u64 = 1,
    records: std.ArrayListUnmanaged(Record) = .empty,
    by_path: [family_count]std.StringHashMapUnmanaged(ElementId) = [_]std.StringHashMapUnmanaged(ElementId){.empty} ** family_count,
    by_id: std.AutoHashMapUnmanaged(u64, u32) = .empty,

    const family_count = @typeInfo(Family).@"enum".fields.len;

    pub const Record = struct {
        id: ElementId,
        path: []u8,
    };

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Registry) void {
        self.by_id.deinit(self.allocator);
        for (&self.by_path) |*map| map.deinit(self.allocator);
        for (self.records.items) |record| self.allocator.free(record.path);
        self.records.deinit(self.allocator);
        self.* = .{};
    }

    pub fn idForPath(
        self: *Registry,
        path_family: Family,
        path_value: []const u8,
    ) !ElementId {
        std.debug.assert(switch (path_family) {
            .asset, .place, .folder, .breadcrumb => true,
            else => false,
        });
        const map = &self.by_path[@intFromEnum(path_family)];
        if (map.get(path_value)) |id| return id;
        if (self.next_token > 0x00ff_ffff_ffff_ffff) return error.ElementIdExhausted;
        const id = encode(path_family, self.next_token);
        self.next_token += 1;
        const owned_path = try self.allocator.dupe(u8, path_value);
        errdefer self.allocator.free(owned_path);
        try self.records.ensureUnusedCapacity(self.allocator, 1);
        try map.ensureUnusedCapacity(self.allocator, 1);
        try self.by_id.ensureUnusedCapacity(self.allocator, 1);
        const record_index: u32 = @intCast(self.records.items.len);
        self.records.appendAssumeCapacity(.{ .id = id, .path = owned_path });
        map.putAssumeCapacity(owned_path, id);
        self.by_id.putAssumeCapacity(id.value(), record_index);
        return id;
    }

    pub fn path(self: *const Registry, id: ElementId) ?[]const u8 {
        const record_index = self.by_id.get(id.value()) orelse return null;
        return self.records.items[record_index].path;
    }

    pub fn existingIdForPath(self: *const Registry, path_family: Family, path_value: []const u8) ?ElementId {
        return self.by_path[@intFromEnum(path_family)].get(path_value);
    }
};

test "dynamic identities survive reorder and reject path collisions" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    const a = try registry.idForPath(.asset, "/a");
    const b = try registry.idForPath(.asset, "/b");
    try std.testing.expect(a != b);
    try std.testing.expectEqual(a, try registry.idForPath(.asset, "/a"));
    try std.testing.expectEqualStrings("/a", registry.path(a).?);
    try std.testing.expectEqual(Family.asset, family(a));
}

test "command actions round trip" {
    const action = commandAction(.toggle_preview);
    try @import("std").testing.expectEqual(types.BrowserCommand.toggle_preview, commandFromAction(action).?);
}

test "command presentations have distinct elements and shared actions" {
    try std.testing.expect(commandElement(.toolbar, .refresh) != commandElement(.file_menu, .refresh));
    try std.testing.expect(commandElement(.preview_header, .toggle_preview) != commandElement(.breadcrumb, .toggle_preview));
}
