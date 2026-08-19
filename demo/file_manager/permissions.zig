//! Permission presentation and parsing, independent of widgets and I/O.

const std = @import("std");

pub const mode_mask: u64 = 0o7777;

pub const Bit = struct {
    element: @import("ids.zig").Fixed,
    mask: u16,
};

/// UI ordering is deliberately data, not twelve controller branches. Rows are
/// owner/group/everyone; columns are read/write/execute/special.
pub const bits = [12]Bit{
    .{ .element = .permission_owner_read, .mask = 0o400 },
    .{ .element = .permission_owner_write, .mask = 0o200 },
    .{ .element = .permission_owner_execute, .mask = 0o100 },
    .{ .element = .permission_owner_special, .mask = 0o4000 },
    .{ .element = .permission_group_read, .mask = 0o040 },
    .{ .element = .permission_group_write, .mask = 0o020 },
    .{ .element = .permission_group_execute, .mask = 0o010 },
    .{ .element = .permission_group_special, .mask = 0o2000 },
    .{ .element = .permission_other_read, .mask = 0o004 },
    .{ .element = .permission_other_write, .mask = 0o002 },
    .{ .element = .permission_other_execute, .mask = 0o001 },
    .{ .element = .permission_other_special, .mask = 0o1000 },
};

pub fn maskForElement(element: @import("ids.zig").ElementId) ?u16 {
    for (bits) |bit| if (element == @import("ids.zig").fixed(bit.element)) return bit.mask;
    return null;
}

pub fn withBit(mode: u16, mask: u16, enabled: bool) u16 {
    return if (enabled) mode | mask else mode & ~mask;
}

pub fn normalized(mode: u64) u16 {
    return @intCast(mode & mode_mask);
}

pub fn format(buffer: *[24]u8, mode: u64) []const u8 {
    const value = normalized(mode);
    const rwx = rwxText(value);
    return std.fmt.bufPrint(buffer, "0o{0o:0>4}  {1s}", .{ value, &rwx }) catch unreachable;
}

pub fn formatOctal(buffer: *[8]u8, mode: u64) []const u8 {
    return std.fmt.bufPrint(buffer, "{o:0>4}", .{normalized(mode)}) catch unreachable;
}

pub fn parseOctal(raw: []const u8) !u16 {
    var text = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.startsWith(u8, text, "0o") or std.mem.startsWith(u8, text, "0O")) text = text[2..];
    if (text.len == 0 or text.len > 4) return error.InvalidPermissions;
    for (text) |char| if (char < '0' or char > '7') return error.InvalidPermissions;
    const value = std.fmt.parseInt(u16, text, 8) catch return error.InvalidPermissions;
    if (value > mode_mask) return error.InvalidPermissions;
    return value;
}

pub fn rwxText(mode: u16) [9]u8 {
    var result = [_]u8{'-'} ** 9;
    const rwx_bits = [_]u16{ 0o400, 0o200, 0o100, 0o040, 0o020, 0o010, 0o004, 0o002, 0o001 };
    const letters = "rwxrwxrwx";
    for (rwx_bits, 0..) |bit, index| if (mode & bit != 0) {
        result[index] = letters[index];
    };
    if (mode & 0o4000 != 0) result[2] = if (mode & 0o100 != 0) 's' else 'S';
    if (mode & 0o2000 != 0) result[5] = if (mode & 0o010 != 0) 's' else 'S';
    if (mode & 0o1000 != 0) result[8] = if (mode & 0o001 != 0) 't' else 'T';
    return result;
}

test "permission octal round trips exhaustively" {
    var value: u16 = 0;
    while (value <= mode_mask) : (value += 1) {
        var buffer: [8]u8 = undefined;
        try std.testing.expectEqual(value, try parseOctal(formatOctal(&buffer, value)));
        if (value == mode_mask) break;
    }
}

test "permission text includes special bits and rejects invalid input" {
    try std.testing.expectEqualStrings("rwsr-xr-t", &rwxText(0o5755));
    try std.testing.expectEqual(@as(u16, 0o755), try parseOctal("0o755"));
    try std.testing.expectError(error.InvalidPermissions, parseOctal("888"));
    try std.testing.expectError(error.InvalidPermissions, parseOctal("07555"));
}

test "permission editor bit projection round trips every bit" {
    var mode: u16 = 0;
    for (bits) |bit| mode = withBit(mode, bit.mask, true);
    try std.testing.expectEqual(@as(u16, mode_mask), mode);
    for (bits) |bit| mode = withBit(mode, bit.mask, false);
    try std.testing.expectEqual(@as(u16, 0), mode);
}
