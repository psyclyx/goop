//! Font discovery for the browser composition root.

const std = @import("std");

pub fn load(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
) ![]u8 {
    if (environment.get("GOOP_DEMO_FONT_PATH")) |path| {
        return read(allocator, io, path);
    }
    if (try fontconfigPath(allocator, io)) |path| {
        defer allocator.free(path);
        if (read(allocator, io, path)) |bytes| return bytes else |_| {}
    }
    const candidates = [_][]const u8{
        "/run/current-system/sw/share/X11/fonts/DejaVuSans.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/TTF/DejaVuSans.ttf",
    };
    for (candidates) |path| {
        return read(allocator, io, path) catch continue;
    }
    return error.FontNotFound;
}

fn fontconfigPath(allocator: std.mem.Allocator, io: std.Io) !?[]u8 {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "fc-match", "-f", "%{file}\n", "sans-serif:style=Regular" },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch return null;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }
    const path = std.mem.trimEnd(u8, result.stdout, "\r\n");
    if (path.len == 0) return null;
    return @as(?[]u8, try allocator.dupe(u8, path));
}

fn read(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(256 * 1024 * 1024),
    );
}
