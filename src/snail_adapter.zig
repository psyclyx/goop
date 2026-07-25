//! Backend-neutral Snail integration.
//!
//! This module owns CPU font/shaping/atlas state and emitted draw records.
//! It deliberately owns no graphics objects and submits no commands.

const std = @import("std");
const display = @import("goop_display");
const snail = @import("snail");

pub const Binding = snail.render.records.Binding;
pub const Instance = snail.render.records.Instance;
pub const DrawBatch = snail.render.records.DrawBatch;
pub const DrawRecords = snail.render.records.DrawRecords;
pub const Atlas = snail.Atlas;
pub const PagePool = snail.PagePool;

pub const Metrics = struct {
    width: f32,
    ascent: f32,
    descent: f32,
    line_gap: f32,

    pub fn height(self: Metrics) f32 {
        return self.ascent - self.descent + self.line_gap;
    }
};

pub const PreparedText = struct {
    allocator: std.mem.Allocator,
    shapes: []snail.Shape,

    pub fn deinit(self: *PreparedText) void {
        self.allocator.free(self.shapes);
        self.* = undefined;
    }
};

/// Stable heap-owned state is required because `snail.Faces` borrows the
/// address of `font`. Moving a `TextEngine` handle never moves that pointee.
pub const TextEngine = struct {
    state: *State,

    const State = struct {
        allocator: std.mem.Allocator,
        font: snail.Font,
        faces: snail.Faces,
        pool: *snail.PagePool,
        atlas: snail.Atlas,
    };

    pub const Options = struct {
        max_layers: u16 = 32,
        curve_words_per_page: u32 = 1 << 18,
        band_words_per_page: u32 = 1 << 16,
        font_id: u32 = 0,
    };

    /// `font_bytes` are borrowed and must outlive the engine.
    pub fn init(
        allocator: std.mem.Allocator,
        font_bytes: []const u8,
        options: Options,
    ) !TextEngine {
        const state = try allocator.create(State);
        errdefer allocator.destroy(state);
        state.* = undefined;
        state.allocator = allocator;
        state.font = try snail.Font.init(font_bytes);

        state.pool = try snail.PagePool.init(allocator, .{
            .max_layers = options.max_layers,
            .curve_words_per_page = options.curve_words_per_page,
            .band_words_per_page = options.band_words_per_page,
        });
        errdefer state.pool.deinit();

        state.atlas = try snail.Atlas.init(allocator, state.pool);
        errdefer state.atlas.deinit();

        state.faces = try snail.Faces.build(allocator, &.{
            .{ .font = &state.font, .font_id = options.font_id },
        });
        return .{ .state = state };
    }

    pub fn deinit(self: *TextEngine) void {
        const state = self.state;
        const allocator = state.allocator;
        state.faces.deinit();
        state.atlas.deinit();
        state.pool.deinit();
        allocator.destroy(state);
        self.* = undefined;
    }

    pub fn atlas(self: *const TextEngine) *const snail.Atlas {
        return &self.state.atlas;
    }

    pub fn pool(self: *const TextEngine) *snail.PagePool {
        return self.state.pool;
    }

    pub fn measure(self: *TextEngine, text: []const u8, font_size: f32) !Metrics {
        var shaped = try snail.shape(self.state.allocator, &self.state.faces, text, .{});
        defer shaped.deinit();

        const units_per_em: f32 = @floatFromInt(self.state.font.unitsPerEm());
        const line = try self.state.font.lineMetrics();
        return .{
            .width = shaped.advanceX() * font_size,
            .ascent = @as(f32, @floatFromInt(line.ascent)) / units_per_em * font_size,
            .descent = @as(f32, @floatFromInt(line.descent)) / units_per_em * font_size,
            .line_gap = @as(f32, @floatFromInt(line.line_gap)) / units_per_em * font_size,
        };
    }

    /// Shape, record any missing glyphs, and return backend-neutral placed
    /// shapes. Repeated calls reuse the persistent atlas.
    pub fn prepareText(
        self: *TextEngine,
        allocator: std.mem.Allocator,
        text: []const u8,
        baseline: struct { x: f32, y: f32 },
        font_size: f32,
        color: display.Color,
    ) !PreparedText {
        var shaped = try snail.shape(self.state.allocator, &self.state.faces, text, .{});
        defer shaped.deinit();

        try snail.recordUnhintedRun(
            &self.state.atlas,
            self.state.allocator,
            &self.state.faces,
            &shaped,
            .{},
        );

        return .{
            .allocator = allocator,
            .shapes = try snail.placeRunAlloc(allocator, &shaped, null, .{
                .baseline = .{ .x = baseline.x, .y = baseline.y },
                .em = font_size,
                .color = linearColor(color),
                .y_axis = .down,
            }),
        };
    }

    /// Emit one prepared run into caller-owned buffers. Vulkan, software, and
    /// future backends all consume this same record stream.
    pub fn emit(
        self: *const TextEngine,
        binding: Binding,
        prepared: *const PreparedText,
        instances: []Instance,
        batches: []DrawBatch,
        instance_len: *usize,
        batch_len: *usize,
    ) !snail.emit.EmitResult {
        return snail.emit.emit(
            instances,
            batches,
            instance_len,
            batch_len,
            binding,
            &self.state.atlas,
            prepared.shapes,
            .identity,
            .{ 1, 1, 1, 1 },
        );
    }
};

pub fn linearColor(color: display.Color) [4]f32 {
    const scale = 1.0 / 255.0;
    return snail.color.srgbToLinearColor(.{
        @as(f32, @floatFromInt(color.r)) * scale,
        @as(f32, @floatFromInt(color.g)) * scale,
        @as(f32, @floatFromInt(color.b)) * scale,
        @as(f32, @floatFromInt(color.a)) * scale,
    });
}

test "display colors cross the Snail boundary once" {
    const linear = linearColor(.rgba(128, 64, 0, 128));
    try std.testing.expectApproxEqAbs(@as(f32, 0.21586), linear[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.05127), linear[1], 0.0001);
    try std.testing.expectEqual(@as(f32, 0), linear[2]);
    try std.testing.expectApproxEqAbs(@as(f32, 128.0 / 255.0), linear[3], 0.0001);
}
