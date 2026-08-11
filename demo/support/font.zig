//! Demo-owned native Fontconfig composition.
//!
//! This is deliberately outside Goop/Snail: a desktop demo asks the host for
//! an ordered face chain, while games can pass packed faces directly to
//! `goop_snail.TextEngine.initFaces` without linking Fontconfig.

const std = @import("std");

const c = @cImport({
    @cInclude("fontconfig/fontconfig.h");
});

pub const Face = struct {
    path: []u8,
    bytes: []u8,
    face_index: u32,
};

pub const FontSet = struct {
    allocator: std.mem.Allocator,
    faces: []Face,

    pub fn deinit(self: *FontSet) void {
        for (self.faces) |face| {
            self.allocator.free(face.bytes);
            self.allocator.free(face.path);
        }
        self.allocator.free(self.faces);
        self.* = undefined;
    }
};

pub fn load(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
) !FontSet {
    var faces: std.ArrayList(Face) = .empty;
    errdefer {
        for (faces.items) |face| {
            allocator.free(face.bytes);
            allocator.free(face.path);
        }
        faces.deinit(allocator);
    }

    if (environment.get("GOOP_DEMO_FONT_PATH")) |path| {
        try appendFile(allocator, io, &faces, path, 0);
    }

    const query = environment.get("GOOP_DEMO_FONT_FAMILY") orelse
        "sans-serif:style=Regular";
    appendFontconfigMatch(allocator, io, &faces, query) catch {};
    // A generic sans-serif sort may consider an outline emoji face adequate
    // coverage before reaching the color bitmap face. Put the host's explicit
    // emoji match immediately after the requested primary, then append the
    // ordinary sorted fallback chain. This policy stays in desktop
    // composition; neither Goop nor Snail needs to know font family names.
    appendFontconfigMatch(allocator, io, &faces, "emoji") catch {};
    appendFontconfigChain(allocator, io, &faces, query) catch {};

    if (faces.items.len == 0) {
        const candidates = [_][]const u8{
            "/run/current-system/sw/share/X11/fonts/DejaVuSans.ttf",
            "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
            "/usr/share/fonts/TTF/DejaVuSans.ttf",
        };
        for (candidates) |path| {
            appendFile(allocator, io, &faces, path, 0) catch continue;
            break;
        }
    }
    if (faces.items.len == 0) return error.FontNotFound;

    return .{
        .allocator = allocator,
        .faces = try faces.toOwnedSlice(allocator),
    };
}

/// Ask Fontconfig for its priority-sorted, charset-trimmed face chain.
/// `FcFontSort(..., trim = true)` removes faces whose coverage is redundant,
/// so this is a real fallback chain without eagerly loading every installed
/// weight and alias. Bitmap-only color faces deliberately remain eligible;
/// Snail validation decides what it can consume.
fn appendFontconfigChain(
    allocator: std.mem.Allocator,
    io: std.Io,
    out: *std.ArrayList(Face),
    query: []const u8,
) !void {
    const query_z = try allocator.dupeZ(u8, query);
    defer allocator.free(query_z);

    const pattern = c.FcNameParse(query_z.ptr) orelse return error.FontNotFound;
    defer c.FcPatternDestroy(pattern);
    _ = c.FcConfigSubstitute(null, pattern, c.FcMatchPattern);
    c.FcDefaultSubstitute(pattern);

    var charset: ?*c.FcCharSet = null;
    var result: c.FcResult = undefined;
    const set = c.FcFontSort(null, pattern, c.FcTrue, &charset, &result) orelse
        return error.FontNotFound;
    defer c.FcFontSetDestroy(set);
    if (charset) |value| c.FcCharSetDestroy(value);

    const patterns = set.*.fonts[0..@intCast(set.*.nfont)];
    for (patterns) |maybe_candidate| {
        const candidate = maybe_candidate orelse continue;
        appendPattern(allocator, io, out, candidate) catch continue;
    }
}

fn appendFontconfigMatch(
    allocator: std.mem.Allocator,
    io: std.Io,
    out: *std.ArrayList(Face),
    query: []const u8,
) !void {
    const query_z = try allocator.dupeZ(u8, query);
    defer allocator.free(query_z);

    const pattern = c.FcNameParse(query_z.ptr) orelse return error.FontNotFound;
    defer c.FcPatternDestroy(pattern);
    _ = c.FcConfigSubstitute(null, pattern, c.FcMatchPattern);
    c.FcDefaultSubstitute(pattern);

    var result: c.FcResult = undefined;
    const match = c.FcFontMatch(null, pattern, &result) orelse return error.FontNotFound;
    defer c.FcPatternDestroy(match);
    try appendPattern(allocator, io, out, match);
}

fn appendPattern(
    allocator: std.mem.Allocator,
    io: std.Io,
    out: *std.ArrayList(Face),
    candidate: *c.FcPattern,
) !void {
    var file_ptr: [*c]u8 = undefined;
    if (c.FcPatternGetString(candidate, c.FC_FILE, 0, &file_ptr) != c.FcResultMatch) {
        return error.FontNotFound;
    }
    var face_index: c_int = 0;
    _ = c.FcPatternGetInteger(candidate, c.FC_INDEX, 0, &face_index);
    if (face_index < 0) return error.FontNotFound;
    // Fontconfig/FreeType pack a variable named-instance selector into the
    // high 16 bits. Snail's `initFace` wants only the collection face index;
    // variation coordinates are a separate, explicit concern.
    const collection_index = @as(u32, @intCast(face_index)) & 0xffff;
    try appendFile(
        allocator,
        io,
        out,
        std.mem.sliceTo(file_ptr, 0),
        collection_index,
    );
}

fn appendFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    out: *std.ArrayList(Face),
    path: []const u8,
    face_index: u32,
) !void {
    for (out.items) |face| {
        if (sameFace(face.path, face.face_index, path, face_index)) return;
    }
    const bytes = try read(allocator, io, path);
    errdefer allocator.free(bytes);
    const owned_path = try allocator.dupe(u8, path);
    errdefer allocator.free(owned_path);
    try out.append(allocator, .{
        .path = owned_path,
        .bytes = bytes,
        .face_index = face_index,
    });
}

fn sameFace(a_path: []const u8, a_index: u32, b_path: []const u8, b_index: u32) bool {
    return a_index == b_index and std.mem.eql(u8, a_path, b_path);
}

fn read(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(256 * 1024 * 1024),
    );
}

test "candidate identity includes collection face index" {
    try std.testing.expect(sameFace("collection.ttc", 1, "collection.ttc", 1));
    try std.testing.expect(!sameFace("collection.ttc", 0, "collection.ttc", 1));
    try std.testing.expect(!sameFace("a.ttf", 0, "b.ttf", 0));
}

test "native Fontconfig resolves a readable primary and fallback chain" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    var fonts = try load(std.testing.allocator, std.testing.io, &environment);
    defer fonts.deinit();

    try std.testing.expect(fonts.faces.len > 0);
    try std.testing.expect(fonts.faces[0].bytes.len > 0);
    try std.testing.expect(fonts.faces[0].path.len > 0);
}
