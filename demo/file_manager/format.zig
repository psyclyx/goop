//! Pure file-browser text formatting.
//!
//! This module knows no filesystem, clock, renderer, or retained UI state.

const std = @import("std");
const types = @import("types.zig");

pub const DecodedTimestamp = struct {
    year: u16,
    yday: u16,
    month_index: u8,
    day: u8,
    hour: u8,
    minute: u8,
};

/// Convert a platform timestamp scalar into the model's bounded Unix-seconds
/// value. Keeping this arithmetic here lets filesystem/clock owners hand the
/// view plain time data without making formatting depend on `std.Io` types.
pub fn unixSecondsFromNanoseconds(nanoseconds: anytype) i64 {
    const seconds = @divFloor(nanoseconds, std.time.ns_per_s);
    return std.math.cast(i64, seconds) orelse if (seconds < 0)
        std.math.minInt(i64)
    else
        std.math.maxInt(i64);
}

pub fn decodeUnixSecondsUtc(unix_seconds: i64) ?DecodedTimestamp {
    if (unix_seconds < 0) return null;
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(unix_seconds) };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    return .{
        .year = year_day.year,
        .yday = year_day.day,
        .month_index = @intCast(@intFromEnum(month_day.month) - 1),
        .day = month_day.day_index + 1,
        .hour = day_seconds.getHoursIntoDay(),
        .minute = day_seconds.getMinutesIntoHour(),
    };
}

pub fn timestampMonthAbbrev(index: usize) []const u8 {
    const months = [_][]const u8{
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    };
    return months[@min(index, months.len - 1)];
}

pub fn formatTimestampCompactText(buffer: []u8, unix_seconds: i64, now_seconds: ?i64) []const u8 {
    if (unix_seconds <= 0) return "";

    const tm_buf = decodeUnixSecondsUtc(unix_seconds) orelse return "";
    const now_tm = if (now_seconds) |now| decodeUnixSecondsUtc(now) else null;
    const diff_seconds = if (now_seconds) |now| now - unix_seconds else std.math.maxInt(i64);

    if (now_tm) |now| if (tm_buf.year == now.year and tm_buf.yday == now.yday) {
        return std.fmt.bufPrint(buffer, "Today {d:0>2}:{d:0>2}", .{ tm_buf.hour, tm_buf.minute }) catch "";
    };
    if (now_tm != null and diff_seconds >= 0 and diff_seconds < 48 * 60 * 60) {
        return std.fmt.bufPrint(buffer, "Yesterday {d:0>2}:{d:0>2}", .{ tm_buf.hour, tm_buf.minute }) catch "";
    }
    if (now_tm) |now| if (tm_buf.year == now.year) {
        return std.fmt.bufPrint(buffer, "{s} {d} {d:0>2}:{d:0>2}", .{
            timestampMonthAbbrev(tm_buf.month_index),
            tm_buf.day,
            tm_buf.hour,
            tm_buf.minute,
        }) catch "";
    };

    return std.fmt.bufPrint(buffer, "{s} {d}, {d}", .{
        timestampMonthAbbrev(tm_buf.month_index),
        tm_buf.day,
        tm_buf.year,
    }) catch "";
}

pub fn formatTimestampDetailText(buffer: []u8, unix_seconds: i64) []const u8 {
    if (unix_seconds <= 0) return "";
    const tm_buf = decodeUnixSecondsUtc(unix_seconds) orelse return "";
    return std.fmt.bufPrint(buffer, "{s} {d}, {d} at {d:0>2}:{d:0>2}", .{
        timestampMonthAbbrev(tm_buf.month_index),
        tm_buf.day,
        tm_buf.year,
        tm_buf.hour,
        tm_buf.minute,
    }) catch "";
}

pub fn formatSizeText(buffer: []u8, kind: types.BrowserEntryKind, size_bytes: u64, target_kind: ?types.BrowserEntryKind) []const u8 {
    if (kind == .directory or target_kind == .directory) return "";
    if (size_bytes < 1024) return std.fmt.bufPrint(buffer, "{} B", .{size_bytes}) catch "";

    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB" };
    var scaled = @as(f64, @floatFromInt(size_bytes));
    var unit_index: usize = 0;
    while (scaled >= 1024 and unit_index + 1 < units.len) : (unit_index += 1) scaled /= 1024;
    return std.fmt.bufPrint(buffer, "{d:.1} {s}", .{ scaled, units[unit_index] }) catch "";
}

pub fn sortColumnLabel(column: types.BrowserSortColumn) []const u8 {
    return switch (column) {
        .name => "name",
        .modified => "modified time",
        .kind => "type",
        .size => "size",
    };
}

pub fn sortDirectionLabel(direction: types.BrowserSortDirection) []const u8 {
    return switch (direction) {
        .ascending => "ascending",
        .descending => "descending",
    };
}
