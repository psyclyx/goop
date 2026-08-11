//! Backend-neutral Snail integration.
//!
//! This module owns CPU font/shaping/atlas state and emitted draw records.
//! It deliberately owns no graphics objects and submits no commands.

const std = @import("std");
const visual = @import("goop_visual");
const image = @import("goop_image");
const snail = @import("snail");

pub const Binding = snail.render.records.Binding;
pub const Instance = snail.render.records.Instance;
pub const DrawBatch = snail.render.records.DrawBatch;
pub const DrawRecords = snail.render.records.DrawRecords;
pub const Atlas = snail.Atlas;
pub const AtlasIdentity = snail.Atlas.SnapshotIdentity;
pub const PagePool = snail.PagePool;
pub const Vec2 = snail.Vec2;
pub const Transform2D = snail.Transform2D;
pub const ImageDecoder = image.Decoder;
pub const DecodedImage = image.Pixels;

pub fn isColorBitmapShape(shape: snail.Shape) bool {
    return shape.key.namespace == snail.record_key.ns.color_bitmap_glyph;
}

const unit_rect_key = snail.record_key.RecordKey{
    .namespace = snail.record_key.ns.path_fill,
    .a = 0x676f_6f70,
};

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

/// One caller-owned font face in shaping priority order. The first face is
/// the primary UI face; later faces participate in Snail's per-cluster
/// fallback chain. Bytes and variation data remain owned by the caller and
/// must outlive the engine.
pub const FontFace = struct {
    bytes: []const u8,
    face_index: u32 = 0,
};

/// Scene placement plus the transform that maps scene coordinates onto the
/// renderer's device-pixel grid. The transform is required because hinted
/// glyph origins and ppem-specific TrueType records are device-pixel facts,
/// not properties of an abstract world coordinate system.
pub const TextPlacement = struct {
    baseline: Vec2,
    world_to_pixel: Transform2D,
};

/// Check whether Snail can parse a caller-provided face. Desktop composition
/// can use this to filter host fonts that Fontconfig considers outline fonts
/// but that the pinned Snail version cannot consume (for example a newer CFF
/// flavor). The decision remains explicit at the composition root.
pub fn validateFontFace(face: FontFace) !void {
    _ = try snail.Font.initFace(face.bytes, face.face_index);
}

const ShapeKey = struct {
    text: []const u8,
    ppem_26_6: u32,
};

const ShapeKeyContext = struct {
    pub fn hash(_: ShapeKeyContext, key: ShapeKey) u64 {
        var hasher = std.hash.Wyhash.init(0x676f_6f70_7368_6170);
        hasher.update(key.text);
        hasher.update(std.mem.asBytes(&key.ppem_26_6));
        return hasher.final();
    }

    pub fn eql(_: ShapeKeyContext, a: ShapeKey, b: ShapeKey) bool {
        return a.ppem_26_6 == b.ppem_26_6 and std.mem.eql(u8, a.text, b.text);
    }
};

const CachedShape = struct {
    shaped: snail.ShapedText,
    /// Font ids whose hinted advances and ppem-specific geometry were both
    /// prepared before `shaped` was cached. Other fallback faces retain their
    /// ordinary em-space advances and unhinted outline records.
    hinted_font_ids: []const u32 = &.{},
};

const ShapeCache = std.HashMapUnmanaged(
    ShapeKey,
    CachedShape,
    ShapeKeyContext,
    std.hash_map.default_max_load_percentage,
);

const TtSourceState = struct {
    /// Snail's TT interpreter is reusable but thread-confined. TextEngine is
    /// already a mutable preparation owner, so it keeps one context per face.
    context: ?snail.TtHintContext = null,
    /// `fpgm`/`prep` output is a ppem-specific runtime artifact. It is cached
    /// by exact packed x/y ppem and never shared with another font source.
    sizes: std.AutoHashMapUnmanaged(u32, snail.TtHintSize) = .empty,
};

const RecordKeyContext = struct {
    pub fn hash(_: RecordKeyContext, key: snail.record_key.RecordKey) u64 {
        return key.hash();
    }

    pub fn eql(_: RecordKeyContext, a: snail.record_key.RecordKey, b: snail.record_key.RecordKey) bool {
        return a.eql(b);
    }
};

const BitmapRecord = struct {
    image: *snail.Image,
    design_to_source: snail.Transform2D,
};

const BitmapCache = std.HashMapUnmanaged(
    snail.record_key.RecordKey,
    BitmapRecord,
    RecordKeyContext,
    std.hash_map.default_max_load_percentage,
);

const BitmapMisses = std.HashMapUnmanaged(
    snail.record_key.RecordKey,
    void,
    RecordKeyContext,
    std.hash_map.default_max_load_percentage,
);

/// Stable heap-owned state is required because `snail.Faces` and preparation
/// sources borrow addresses in the font/source arrays. Moving a `TextEngine`
/// handle never moves those pointees.
pub const TextEngine = struct {
    state: *State,

    /// Per-cache cap on shaped runs. Measurement and TT rendering deliberately
    /// have different caches: the former is size-independent, while the latter
    /// is keyed by the exact device ppem that determined hinted advances.
    const max_cached_shapes = 4096;

    const State = struct {
        allocator: std.mem.Allocator,
        fonts: []snail.Font,
        /// Stable prepared-record identities for this engine's ordered faces.
        /// Both arrays are heap-stable because `Faces`/`TtHintContext` APIs
        /// borrow their entries while doing work.
        font_sources: []snail.FontSource,
        tt_sources: []TtSourceState,
        /// Reused storage for the subset of sources that successfully
        /// prepared advances/geometry for the current TT cache miss.
        tt_source_scratch: []snail.FontSource,
        image_decoder: ?image.Decoder,
        /// Decoded strikes are heap-stable because Snail image paints borrow
        /// their address for the lifetime of every atlas snapshot.
        bitmap_cache: BitmapCache = .empty,
        bitmap_misses: BitmapMisses = .empty,
        faces: snail.Faces,
        pool: *snail.PagePool,
        atlas: snail.Atlas,
        unit_rect_design_to_source: snail.Transform2D,
        /// Native em-space shaping used by renderer-independent layout.
        shape_cache: ShapeCache = .empty,
        /// TT shaping after hinted advances have been prepared. The key owns
        /// the exact text and includes device ppem; it is never size-agnostic.
        tt_shape_cache: ShapeCache = .empty,
    };

    pub const Options = struct {
        max_pages: u16 = 32,
        curve_words_per_page: u32 = 1 << 18,
        band_words_per_page: u32 = 1 << 16,
        font_id: u32 = 0,
        /// Optional host codec capability. With no decoder, embedded bitmap
        /// glyphs simply retain their outline fallback.
        image_decoder: ?image.Decoder = null,
    };

    /// `font_bytes` are borrowed and must outlive the engine.
    pub fn init(
        allocator: std.mem.Allocator,
        font_bytes: []const u8,
        options: Options,
    ) !TextEngine {
        return initFaces(allocator, &.{.{ .bytes = font_bytes }}, options);
    }

    /// Build an engine over an explicit, ordered face chain. Font discovery
    /// is intentionally absent: desktop demos can use Fontconfig, games can
    /// use packed assets, and neither policy leaks into this adapter.
    pub fn initFaces(
        allocator: std.mem.Allocator,
        face_inputs: []const FontFace,
        options: Options,
    ) !TextEngine {
        if (face_inputs.len == 0) return error.NoFaces;
        if (face_inputs.len - 1 > std.math.maxInt(u32) - options.font_id) return error.TooManyFaces;

        const state = try allocator.create(State);
        errdefer allocator.destroy(state);
        state.* = undefined;
        state.allocator = allocator;
        state.shape_cache = .empty;
        state.tt_shape_cache = .empty;
        state.bitmap_cache = .empty;
        state.bitmap_misses = .empty;
        state.image_decoder = options.image_decoder;

        state.fonts = try allocator.alloc(snail.Font, face_inputs.len);
        errdefer allocator.free(state.fonts);
        state.font_sources = try allocator.alloc(snail.FontSource, face_inputs.len);
        errdefer allocator.free(state.font_sources);
        state.tt_sources = try allocator.alloc(TtSourceState, face_inputs.len);
        for (state.tt_sources) |*source| source.* = .{};
        errdefer deinitTtSources(allocator, state.tt_sources);
        state.tt_source_scratch = try allocator.alloc(snail.FontSource, face_inputs.len);
        errdefer allocator.free(state.tt_source_scratch);

        const face_specs = try allocator.alloc(snail.Face, face_inputs.len);
        defer allocator.free(face_specs);
        for (face_inputs, 0..) |input, index| {
            state.fonts[index] = try snail.Font.initFace(input.bytes, input.face_index);
            const font_id = options.font_id + @as(u32, @intCast(index));
            var hasher = std.hash.Wyhash.init(0x676f_6f70_666f_6e74);
            hasher.update(input.bytes);
            hasher.update(std.mem.asBytes(&input.face_index));
            const lo = hasher.final();
            hasher = std.hash.Wyhash.init(0x676f_6f70_6b65_7932);
            hasher.update(input.bytes);
            hasher.update(std.mem.asBytes(&input.face_index));
            const hi = hasher.final();
            state.font_sources[index] = .{
                .font_id = font_id,
                .font = &state.fonts[index],
                .cache_key = undefined,
            };
            std.mem.writeInt(u64, state.font_sources[index].cache_key[0..8], lo, .little);
            std.mem.writeInt(u64, state.font_sources[index].cache_key[8..16], hi, .little);
            face_specs[index] = .{
                .font = &state.fonts[index],
                .font_id = font_id,
                .fallback = index != 0,
            };
        }

        state.pool = try snail.PagePool.init(allocator, .{
            .max_pages = options.max_pages,
            .curve_words_per_page = options.curve_words_per_page,
            .band_words_per_page = options.band_words_per_page,
        });
        errdefer state.pool.deinit();

        state.atlas = try snail.Atlas.init(allocator, state.pool);
        errdefer state.atlas.deinit();

        state.faces = try snail.Faces.build(allocator, face_specs);
        errdefer state.faces.deinit();

        // Probe once per face. Other outline formats remain valid shaping
        // faces and use unhinted records; TrueType faces take the grid-fitted
        // record path in `prepareText`.
        for (state.font_sources, 0..) |*source, index| {
            state.tt_sources[index].context = snail.TtHintContext.init(
                allocator,
                allocator,
                source,
            ) catch null;
        }
        state.unit_rect_design_to_source = try recordUnitRect(state);
        return .{ .state = state };
    }

    pub fn deinit(self: *TextEngine) void {
        const state = self.state;
        const allocator = state.allocator;
        clearShapeCache(allocator, &state.tt_shape_cache);
        clearShapeCache(allocator, &state.shape_cache);
        state.tt_shape_cache.deinit(allocator);
        state.shape_cache.deinit(allocator);
        state.faces.deinit();
        state.atlas.deinit();
        deinitBitmapCache(allocator, &state.bitmap_cache);
        state.bitmap_cache.deinit(allocator);
        state.bitmap_misses.deinit(allocator);
        state.pool.deinit();
        allocator.free(state.tt_source_scratch);
        deinitTtSources(allocator, state.tt_sources);
        allocator.free(state.font_sources);
        allocator.free(state.fonts);
        allocator.destroy(state);
        self.* = undefined;
    }

    /// Shape `text` once in native em space for renderer-independent layout.
    /// The returned pointer is valid until the next `shapedFor` call.
    fn shapedFor(self: *TextEngine, text: []const u8) !*const snail.ShapedText {
        const state = self.state;
        const lookup_key = ShapeKey{ .text = text, .ppem_26_6 = 0 };
        if (state.shape_cache.getPtr(lookup_key)) |existing| return &existing.shaped;

        if (state.shape_cache.count() >= max_cached_shapes) {
            clearShapeCache(state.allocator, &state.shape_cache);
        }

        var shaped = try snail.shape(state.allocator, &state.faces, text, .{});
        errdefer shaped.deinit();
        const cached = try cacheShape(state, &state.shape_cache, text, 0, shaped, &.{});
        return &cached.shaped;
    }

    /// Shape a run using Snail's TT advance contract. A native-em shape first
    /// discovers the glyphs; missing advances are prepared and committed;
    /// HarfBuzz then reshapes against the cache-only provider. The final run
    /// is cached only under its exact device ppem.
    fn hintedShapedFor(
        self: *TextEngine,
        text: []const u8,
        ppem_26_6: u32,
    ) !*const CachedShape {
        const state = self.state;
        const lookup_key = ShapeKey{ .text = text, .ppem_26_6 = ppem_26_6 };
        if (state.tt_shape_cache.getPtr(lookup_key)) |existing| return existing;

        if (state.tt_shape_cache.count() >= max_cached_shapes) {
            clearShapeCache(state.allocator, &state.tt_shape_cache);
        }

        const native = try self.shapedFor(text);
        const ppem = snail.TtHintPpem.uniform(ppem_26_6);
        const advance_sources = try prepareTtAdvances(state, native, ppem);
        var advance_source = snail.TtAdvanceSource{
            .atlas = &state.atlas,
            .sources = advance_sources,
        };
        var shaped = try snail.shape(state.allocator, &state.faces, text, .{
            .advance_provider = advance_source.advanceProvider(),
            .target_ppem = ppem,
        });
        errdefer shaped.deinit();

        // Fallback faces without TT bytecode still need ordinary outline
        // records. The planner makes this a no-op for glyphs already resident.
        try recordUnhintedRun(state, &shaped);
        const hinted_sources = try recordTtGeometry(state, &shaped, ppem, advance_sources);
        return cacheShape(
            state,
            &state.tt_shape_cache,
            text,
            ppem_26_6,
            shaped,
            hinted_sources,
        );
    }

    pub fn atlas(self: *const TextEngine) *const snail.Atlas {
        return &self.state.atlas;
    }

    pub fn atlasIdentity(self: *const TextEngine) AtlasIdentity {
        return self.state.atlas.snapshotIdentity();
    }

    pub fn pool(self: *const TextEngine) *snail.PagePool {
        return self.state.pool;
    }

    /// Number of distinct runs currently shaped-and-cached. Exposed for tests
    /// and diagnostics that want to confirm repeated frames reuse shaping.
    pub fn shapeCacheSize(self: *const TextEngine) usize {
        return self.state.shape_cache.count() + self.state.tt_shape_cache.count();
    }

    pub fn measure(self: *TextEngine, text: []const u8, font_size: f32) !Metrics {
        const shaped = try self.shapedFor(text);
        return metricsFor(self.state, shaped, font_size);
    }

    /// Device-aware metrics for visual preparation. Unlike `measure`, this may
    /// populate ppem-specific Snail records and caches; callers use it when
    /// painted alignment must match hinted advances exactly.
    pub fn prepareMetrics(
        self: *TextEngine,
        text: []const u8,
        font_size: f32,
        world_to_pixel: Transform2D,
    ) !Metrics {
        const shaped = if (try hintPpem26Dot6(font_size, world_to_pixel)) |ppem_26_6|
            &((try self.hintedShapedFor(text, ppem_26_6)).shaped)
        else
            try self.shapedFor(text);
        return metricsFor(self.state, shaped, font_size);
    }

    /// Shape, record any missing glyphs, and return backend-neutral placed
    /// shapes. Repeated calls reuse the persistent atlas.
    pub fn prepareText(
        self: *TextEngine,
        allocator: std.mem.Allocator,
        text: []const u8,
        text_placement: TextPlacement,
        font_size: f32,
        color: visual.Color,
    ) !PreparedText {
        if (try hintPpem26Dot6(font_size, text_placement.world_to_pixel)) |ppem_26_6| {
            return self.prepareHintedText(
                allocator,
                text,
                text_placement,
                font_size,
                ppem_26_6,
                color,
            );
        }

        const shaped = try self.shapedFor(text);
        try recordUnhintedRun(self.state, shaped);
        const shapes = try snail.placeRunAlloc(allocator, shaped, null, .{
            .baseline = text_placement.baseline,
            .em = font_size,
            .color = linearColor(color),
            .y_axis = .down,
        });
        errdefer allocator.free(shapes);
        if (bitmapPpem(font_size, text_placement.world_to_pixel)) |ppem| {
            try applyColorBitmaps(self.state, shaped, shapes, ppem);
        }
        return .{
            .allocator = allocator,
            .shapes = shapes,
        };
    }

    fn prepareHintedText(
        self: *TextEngine,
        allocator: std.mem.Allocator,
        text: []const u8,
        text_placement: TextPlacement,
        font_size: f32,
        ppem_26_6: u32,
        color: visual.Color,
    ) !PreparedText {
        const cached = try self.hintedShapedFor(text, ppem_26_6);
        const shaped = &cached.shaped;

        const placement = snail.RunPlacement{
            .baseline = text_placement.baseline,
            .em = font_size,
            .color = linearColor(color),
            .y_axis = .down,
        };
        const shapes = try snail.placeRunAlloc(allocator, shaped, null, placement);
        errdefer allocator.free(shapes);

        const bitmap_ppem = ppemFrom26Dot6(ppem_26_6);
        try applyColorBitmaps(self.state, shaped, shapes, bitmap_ppem);

        // Placement is one shape per glyph here (`colr = false`). Only glyphs
        // with TT records use grid-fitted geometry and device-origin snapping;
        // other fallback formats keep natural origins and unhinted records.
        const hinted_scale = font_size / (@as(f32, @floatFromInt(ppem_26_6)) / 64.0);
        for (shaped.glyphs, shapes) |glyph, *shape| {
            if (shape.key.namespace == snail.record_key.ns.color_bitmap_glyph) continue;
            if (!containsFontId(cached.hinted_font_ids, glyph.font_id)) continue;
            const snapped = snail.snap.origin(.{
                .x = shape.local_transform.tx,
                .y = shape.local_transform.ty,
            }, text_placement.world_to_pixel);
            shape.key = snail.record_key.ttHintedGlyph(glyph.font_id, glyph.glyph_id, ppem_26_6);
            shape.local_transform.xx = hinted_scale;
            shape.local_transform.yy = -hinted_scale;
            shape.local_transform.tx = snapped.x;
            shape.local_transform.ty = snapped.y;
        }

        return .{
            .allocator = allocator,
            .shapes = shapes,
        };
    }

    /// Prepare a solid rectangle through the same backend-neutral shape
    /// stream as text. Render backends can therefore use their normal blend
    /// pipeline for translucent UI surfaces instead of replacing attachment
    /// pixels with a clear operation.
    pub fn prepareRect(
        self: *const TextEngine,
        allocator: std.mem.Allocator,
        bounds: visual.Rect,
        color: visual.Color,
    ) !PreparedText {
        const shapes = try allocator.alloc(snail.Shape, 1);
        shapes[0] = .{
            .key = unit_rect_key,
            .local_transform = snail.Transform2D.multiply(.{
                .xx = bounds.w,
                .yy = bounds.h,
                .tx = bounds.x,
                .ty = bounds.y,
            }, self.state.unit_rect_design_to_source),
            .local_color = linearColor(color),
        };
        return .{ .allocator = allocator, .shapes = shapes };
    }

    /// Build one rectangle shape in caller-owned storage. Unlike
    /// `prepareRect`, this performs no allocation and is suitable for direct
    /// command encoding after resources have been prepared.
    pub fn rectShape(
        self: *const TextEngine,
        bounds: visual.Rect,
        color: visual.Color,
    ) snail.Shape {
        return .{
            .key = unit_rect_key,
            .local_transform = snail.Transform2D.multiply(.{
                .xx = bounds.w,
                .yy = bounds.h,
                .tx = bounds.x,
                .ty = bounds.y,
            }, self.state.unit_rect_design_to_source),
            .local_color = linearColor(color),
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
        return self.emitShapes(
            binding,
            prepared.shapes,
            instances,
            batches,
            instance_len,
            batch_len,
        );
    }

    pub fn emitShapes(
        self: *const TextEngine,
        binding: Binding,
        shapes: []const snail.Shape,
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
            shapes,
            .identity,
            .{ 1, 1, 1, 1 },
        );
    }
};

const ImageKeyContext = struct {
    pub fn hash(_: ImageKeyContext, key: image.ResourceId) u64 {
        var hasher = std.hash.Wyhash.init(0x676f_6f70_696d_6167);
        hasher.update(std.mem.asBytes(&key));
        return hasher.final();
    }

    pub fn eql(_: ImageKeyContext, a: image.ResourceId, b: image.ResourceId) bool {
        return a.value == b.value and a.revision == b.revision;
    }
};

const CachedImage = struct {
    image: *snail.Image,
    design_to_source: snail.Transform2D,
    width: u32,
    height: u32,
};

const ImageCache = std.HashMapUnmanaged(
    image.ResourceId,
    CachedImage,
    ImageKeyContext,
    std.hash_map.default_max_load_percentage,
);

/// Backend-neutral Snail image resource preparation. It shares a page pool
/// with a text engine but owns an independent atlas and cache, so generic
/// application images never become text-engine state.
pub const ImageEngine = struct {
    allocator: std.mem.Allocator,
    pool_ptr: *snail.PagePool,
    image_atlas: snail.Atlas,
    cache: ImageCache = .empty,

    pub fn init(allocator: std.mem.Allocator, pool_ptr: *snail.PagePool) !ImageEngine {
        return .{
            .allocator = allocator,
            .pool_ptr = pool_ptr,
            .image_atlas = try snail.Atlas.init(allocator, pool_ptr),
        };
    }

    pub fn deinit(self: *ImageEngine) void {
        self.image_atlas.deinit();
        deinitImageCache(self.allocator, &self.cache);
        self.* = undefined;
    }

    pub fn atlas(self: *const ImageEngine) *const snail.Atlas {
        return &self.image_atlas;
    }

    pub fn atlasIdentity(self: *const ImageEngine) AtlasIdentity {
        return self.image_atlas.snapshotIdentity();
    }

    pub fn resourceCount(self: *const ImageEngine) usize {
        return self.cache.count();
    }

    /// Make the image atlas describe exactly the resources used by the next
    /// prepared stream. Matching sets are a no-allocation cache hit. A changed
    /// set is rebuilt atomically, bounding retained CPU/GPU image resources by
    /// the visible stream rather than navigation history.
    ///
    /// `ResourceId` is the caller's content contract: pixel changes must
    /// advance its revision. The engine deliberately does not hash every image
    /// on every frame to second-guess that identity.
    pub fn syncResources(self: *ImageEngine, sources: []const image.View) !void {
        if (try self.resourcesMatch(sources)) return;

        var next_cache: ImageCache = .empty;
        errdefer deinitImageCache(self.allocator, &next_cache);
        var next_atlas = try snail.Atlas.init(self.allocator, self.pool_ptr);
        errdefer next_atlas.deinit();

        for (sources, 0..) |source, index| {
            try source.validate();
            if (firstResourceIndex(sources[0..index], source.id) != null) continue;
            _ = try recordImage(self.allocator, &next_atlas, &next_cache, source);
        }

        var old_atlas = self.image_atlas;
        var old_cache = self.cache;
        self.image_atlas = next_atlas;
        self.cache = next_cache;
        old_atlas.deinit();
        deinitImageCache(self.allocator, &old_cache);
    }

    pub fn prepareImage(
        self: *ImageEngine,
        allocator: std.mem.Allocator,
        value: visual.Image,
    ) !PreparedText {
        try value.source.validate();
        const record = try self.recordFor(value.source);
        const destination = fittedImageBounds(value.bounds, value.source.width, value.source.height, value.fit);
        const shapes = try allocator.alloc(snail.Shape, 1);
        shapes[0] = .{
            .key = imageRecordKey(value.source.id),
            .local_transform = snail.Transform2D.multiply(.{
                .xx = destination.w,
                .yy = destination.h,
                .tx = destination.x,
                .ty = destination.y,
            }, record.design_to_source),
            .local_color = .{ 1, 1, 1, 1 },
        };
        return .{ .allocator = allocator, .shapes = shapes };
    }

    pub fn emitShapes(
        self: *const ImageEngine,
        binding: Binding,
        shapes: []const snail.Shape,
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
            &self.image_atlas,
            shapes,
            .identity,
            .{ 1, 1, 1, 1 },
        );
    }

    fn recordFor(self: *ImageEngine, source: image.View) !CachedImage {
        if (self.cache.get(source.id)) |record| {
            if (record.width != source.width or record.height != source.height) {
                return error.ResourceIdentityCollision;
            }
            return record;
        }

        return recordImage(self.allocator, &self.image_atlas, &self.cache, source);
    }

    fn resourcesMatch(self: *const ImageEngine, sources: []const image.View) !bool {
        var unique_count: usize = 0;
        for (sources, 0..) |source, index| {
            try source.validate();
            if (firstResourceIndex(sources[0..index], source.id)) |previous| {
                if (previous.width != source.width or previous.height != source.height) {
                    return error.ResourceIdentityCollision;
                }
                continue;
            }
            unique_count += 1;
            const record = self.cache.get(source.id) orelse return false;
            if (record.width != source.width or record.height != source.height) {
                return error.ResourceIdentityCollision;
            }
        }
        return unique_count == self.cache.count();
    }
};

fn firstResourceIndex(sources: []const image.View, id: image.ResourceId) ?image.View {
    for (sources) |source| if (std.meta.eql(source.id, id)) return source;
    return null;
}

fn deinitImageCache(allocator: std.mem.Allocator, cache: *ImageCache) void {
    var records = cache.valueIterator();
    while (records.next()) |record| {
        record.image.deinit();
        allocator.destroy(record.image);
    }
    cache.deinit(allocator);
    cache.* = .empty;
}

fn recordImage(
    allocator: std.mem.Allocator,
    atlas: *snail.Atlas,
    cache: *ImageCache,
    source: image.View,
) !CachedImage {
    try source.validate();

    const decoded = try allocator.create(snail.Image);
    errdefer allocator.destroy(decoded);
    decoded.* = try snail.Image.init(allocator, source.width, source.height, source.rgba);
    errdefer decoded.deinit();

    var path = snail.Path.init(allocator);
    defer path.deinit();
    try path.addRect(.{ .x = 0, .y = 0, .w = 1, .h = 1 });
    var prepared_path = try path.prepare(allocator);
    defer prepared_path.deinit();
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    var curves = try prepared_path.fillCurves(allocator, scratch.allocator());
    defer curves.deinit();

    const record = CachedImage{
        .image = decoded,
        .design_to_source = prepared_path.design_to_source,
        .width = source.width,
        .height = source.height,
    };
    try cache.put(allocator, source.id, record);
    errdefer {
        _ = cache.remove(source.id);
        decoded.deinit();
        allocator.destroy(decoded);
    }
    try atlas.extendInPlace(allocator, .{ .entries = &.{.{
        .geometry = .{
            .key = imageRecordKey(source.id),
            .curves = curves.view(),
            .paint = try prepared_path.paintForDesign(.{ .image = .{
                .image = decoded,
                .filter = .linear,
            } }),
        },
    }} });
    return record;
}

fn imageRecordKey(id: image.ResourceId) snail.record_key.RecordKey {
    return .{
        .namespace = snail.record_key.ns.user_base,
        .a = @truncate(id.value),
        .b = @truncate(id.value >> 32),
        .c = id.revision,
    };
}

fn fittedImageBounds(
    bounds: visual.Rect,
    source_width: u32,
    source_height: u32,
    fit: visual.ImageFit,
) visual.Rect {
    if (fit == .stretch) return bounds;
    const width: f32 = @floatFromInt(source_width);
    const height: f32 = @floatFromInt(source_height);
    const scale = switch (fit) {
        .contain => @min(bounds.w / width, bounds.h / height),
        .cover => @max(bounds.w / width, bounds.h / height),
        .stretch => unreachable,
    };
    const fitted_w = width * scale;
    const fitted_h = height * scale;
    return .{
        .x = bounds.x + (bounds.w - fitted_w) * 0.5,
        .y = bounds.y + (bounds.h - fitted_h) * 0.5,
        .w = fitted_w,
        .h = fitted_h,
    };
}

fn clearShapeCache(allocator: std.mem.Allocator, cache: *ShapeCache) void {
    var it = cache.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.text);
        entry.value_ptr.shaped.deinit();
        if (entry.value_ptr.hinted_font_ids.len > 0) {
            allocator.free(entry.value_ptr.hinted_font_ids);
        }
    }
    cache.clearRetainingCapacity();
}

fn deinitTtSources(allocator: std.mem.Allocator, sources: []TtSourceState) void {
    for (sources) |*source| {
        var sizes = source.sizes.valueIterator();
        while (sizes.next()) |size| size.deinit();
        source.sizes.deinit(allocator);
        if (source.context) |*context| context.deinit();
    }
    allocator.free(sources);
}

fn deinitBitmapCache(allocator: std.mem.Allocator, cache: *BitmapCache) void {
    var records = cache.valueIterator();
    while (records.next()) |record| {
        record.image.deinit();
        allocator.destroy(record.image);
    }
}

fn cacheShape(
    state: *TextEngine.State,
    cache: *ShapeCache,
    text: []const u8,
    ppem_26_6: u32,
    shaped: snail.ShapedText,
    hinted_sources: []const snail.FontSource,
) !*const CachedShape {
    const owned_text = try state.allocator.dupe(u8, text);
    errdefer state.allocator.free(owned_text);

    const hinted_font_ids: []const u32 = if (hinted_sources.len == 0)
        &.{}
    else blk: {
        const ids = try state.allocator.alloc(u32, hinted_sources.len);
        errdefer state.allocator.free(ids);
        for (hinted_sources, ids) |source, *font_id| font_id.* = source.font_id;
        break :blk ids;
    };
    errdefer if (hinted_font_ids.len > 0) state.allocator.free(hinted_font_ids);

    const key = ShapeKey{ .text = owned_text, .ppem_26_6 = ppem_26_6 };
    try cache.putNoClobber(state.allocator, key, .{
        .shaped = shaped,
        .hinted_font_ids = hinted_font_ids,
    });
    return cache.getPtr(key).?;
}

fn recordUnitRect(state: *TextEngine.State) !snail.Transform2D {
    var scratch = std.heap.ArenaAllocator.init(state.allocator);
    defer scratch.deinit();

    var path = snail.Path.init(state.allocator);
    defer path.deinit();
    try path.addRect(.{ .x = 0, .y = 0, .w = 1, .h = 1 });

    var prepared = try path.prepare(state.allocator);
    defer prepared.deinit();
    var curves = try prepared.fillCurves(state.allocator, scratch.allocator());
    defer curves.deinit();

    // Register the unit rect as a coverage mask (no baked paint) so it renders
    // in the atlas's `.regular` mode and is tinted by each instance's
    // `local_color`. Baking a solid paint instead makes it a `.colr_solid`
    // record whose color comes from the atlas, ignoring the per-instance color —
    // which silently drops the tint on every translucent surface fill.
    try state.atlas.extendInPlace(state.allocator, .{ .entries = &.{.{
        .geometry = .{
            .key = unit_rect_key,
            .curves = curves.view(),
        },
    }} });
    return prepared.design_to_source;
}

/// Record every missing glyph of a shaped run into the atlas along the
/// ppem-independent unhinted path. Snail splits this into
/// plan → per-request prepare → apply; goop prepares its explicit face chain
/// synchronously on one thread, so an outline-only executor covers it.
fn recordUnhintedRun(state: *TextEngine.State, shaped: *const snail.ShapedText) !void {
    const allocator = state.allocator;
    var plan = try snail.planRuns(&state.atlas, allocator, state.font_sources, &.{shaped}, .{ .unhinted = .{} });
    defer plan.deinit();
    const requests = plan.requests();

    const owned = try allocator.alloc(?snail.prepared.OwnedRecord, requests.len);
    defer allocator.free(owned);
    @memset(owned, null);
    defer for (owned) |*record| if (record.*) |*value| value.deinit();
    const results = try allocator.alloc(?snail.prepared.RecordView, requests.len);
    defer allocator.free(results);
    @memset(results, null);

    // Unhinted planning emits outline requests only.
    var outlines = snail.OutlineContext.init(allocator, allocator);
    defer outlines.deinit();
    for (requests, 0..) |request, index| {
        owned[index] = try outlines.prepare(request);
        results[index] = owned[index].?.view();
    }
    try plan.applyInPlace(allocator, &state.atlas, results);
}

fn rememberBitmapMiss(state: *TextEngine.State, key: snail.record_key.RecordKey) !void {
    try state.bitmap_misses.put(state.allocator, key, {});
}

fn prepareColorBitmap(
    state: *TextEngine.State,
    glyph: snail.ShapedText.Glyph,
    ppem: u16,
) !?BitmapRecord {
    const key = snail.record_key.colorBitmapGlyph(glyph.font_id, glyph.glyph_id, ppem);
    if (state.bitmap_cache.get(key)) |record| return record;
    if (state.bitmap_misses.contains(key)) return null;
    const decoder = state.image_decoder orelse return null;
    const face_index: usize = @intCast(glyph.face_index);
    if (face_index >= state.fonts.len) {
        try rememberBitmapMiss(state, key);
        return null;
    }

    var strike = state.fonts[face_index].colorBitmap(
        state.allocator,
        glyph.glyph_id,
        ppem,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try rememberBitmapMiss(state, key);
            return null;
        },
    } orelse {
        try rememberBitmapMiss(state, key);
        return null;
    };
    defer strike.deinit();

    const format: image.EncodedFormat = switch (strike.format) {
        .png => .png,
    };
    var pixels = decoder.decode(format, strike.data, state.allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnsupportedFormat, error.InvalidData => {
            try rememberBitmapMiss(state, key);
            return null;
        },
    };
    defer pixels.deinit();

    const width = strike.bbox.max.x - strike.bbox.min.x;
    const height = strike.bbox.max.y - strike.bbox.min.y;
    if (!std.math.isFinite(width) or !std.math.isFinite(height) or width <= 0 or height <= 0) {
        try rememberBitmapMiss(state, key);
        return null;
    }

    const decoded = try state.allocator.create(snail.Image);
    errdefer state.allocator.destroy(decoded);
    decoded.* = snail.Image.init(
        state.allocator,
        pixels.width,
        pixels.height,
        pixels.rgba,
    ) catch return error.OutOfMemory;
    errdefer decoded.deinit();

    var path = snail.Path.init(state.allocator);
    defer path.deinit();
    try path.addRect(.{
        .x = strike.bbox.min.x,
        .y = strike.bbox.min.y,
        .w = width,
        .h = height,
    });
    var prepared_path = try path.prepare(state.allocator);
    defer prepared_path.deinit();
    var scratch = std.heap.ArenaAllocator.init(state.allocator);
    defer scratch.deinit();
    var curves = try prepared_path.fillCurves(state.allocator, scratch.allocator());
    defer curves.deinit();

    const record = BitmapRecord{
        .image = decoded,
        .design_to_source = prepared_path.design_to_source,
    };
    try state.bitmap_cache.put(state.allocator, key, record);
    errdefer {
        _ = state.bitmap_cache.remove(key);
        decoded.deinit();
        state.allocator.destroy(decoded);
    }

    const source_paint = snail.Paint{
        .image = .{
            .image = decoded,
            .uv_transform = snail.font.color_bitmap.imageUvTransform(strike.bbox),
            // Embedded strikes are authored for a particular ppem; nearest
            // preserves their pixel grid instead of inventing subpixel color.
            .filter = .nearest,
        },
    };
    try state.atlas.extendInPlace(state.allocator, .{ .entries = &.{.{
        .geometry = .{
            .key = key,
            .curves = curves.view(),
            .paint = try prepared_path.paintForDesign(source_paint),
        },
    }} });
    return record;
}

fn applyColorBitmaps(
    state: *TextEngine.State,
    shaped: *const snail.ShapedText,
    shapes: []snail.Shape,
    ppem: u16,
) !void {
    for (shaped.glyphs, shapes) |glyph, *shape| {
        const bitmap = try prepareColorBitmap(state, glyph, ppem) orelse continue;
        shape.key = snail.record_key.colorBitmapGlyph(glyph.font_id, glyph.glyph_id, ppem);
        shape.local_color = .{ 1, 1, 1, 1 };
        shape.local_transform = snail.Transform2D.multiply(
            shape.local_transform,
            bitmap.design_to_source,
        );
    }
}

fn ppemFrom26Dot6(ppem_26_6: u32) u16 {
    const rounded = @max((ppem_26_6 + 32) / 64, 1);
    return @intCast(@min(rounded, std.math.maxInt(u16)));
}

fn bitmapPpem(font_size: f32, world_to_pixel: snail.Transform2D) ?u16 {
    if (!std.math.isFinite(font_size) or font_size <= 0 or !finiteTransform(world_to_pixel)) return null;
    const x_scale = std.math.hypot(world_to_pixel.xx, world_to_pixel.yx);
    const y_scale = std.math.hypot(world_to_pixel.xy, world_to_pixel.yy);
    const device_em = font_size * @max(x_scale, y_scale);
    if (!std.math.isFinite(device_em) or device_em <= 0) return null;
    const rounded: u32 = if (device_em >= @as(f32, @floatFromInt(std.math.maxInt(u16))))
        std.math.maxInt(u16)
    else
        @max(@as(u32, @intFromFloat(@round(device_em))), 1);
    return @intCast(rounded);
}

fn containsFontId(font_ids: []const u32, font_id: u32) bool {
    for (font_ids) |candidate| if (candidate == font_id) return true;
    return false;
}

fn metricsFor(
    state: *const TextEngine.State,
    shaped: *const snail.ShapedText,
    font_size: f32,
) !Metrics {
    if (!std.math.isFinite(font_size) or font_size <= 0) return error.InvalidFontSize;
    const primary = &state.fonts[0];
    const units_per_em: f32 = @floatFromInt(primary.unitsPerEm());
    const line = try primary.lineMetrics();
    return .{
        .width = shaped.advanceX() * font_size,
        .ascent = @as(f32, @floatFromInt(line.ascent)) / units_per_em * font_size,
        .descent = @as(f32, @floatFromInt(line.descent)) / units_per_em * font_size,
        .line_gap = @as(f32, @floatFromInt(line.line_gap)) / units_per_em * font_size,
    };
}

/// Select TT hinting only when the caller's transform preserves the font's
/// x/y axes at one uniform device scale. Shear, rotation, and anisotropy have
/// no single ppem whose grid-fitted geometry matches the final device grid, so
/// those compositions explicitly take the unhinted path.
fn hintPpem26Dot6(font_size: f32, world_to_pixel: snail.Transform2D) !?u32 {
    if (!std.math.isFinite(font_size) or font_size <= 0) return error.InvalidFontSize;
    if (!finiteTransform(world_to_pixel)) return null;
    if (world_to_pixel.xy != 0 or world_to_pixel.yx != 0) return null;

    const x_scale = @abs(world_to_pixel.xx);
    const y_scale = @abs(world_to_pixel.yy);
    if (x_scale <= 0 or x_scale != y_scale) return null;
    const device_em = font_size * y_scale;
    if (!std.math.isFinite(device_em) or device_em < 1) return null;

    const max_26_6 = snail.TtHintPpem.max_26_6;
    const max_ppem = @as(f32, @floatFromInt(max_26_6)) / 64.0;
    if (device_em >= max_ppem) return max_26_6;
    return @intFromFloat(@round(device_em * 64.0));
}

fn finiteTransform(transform: snail.Transform2D) bool {
    return std.math.isFinite(transform.xx) and
        std.math.isFinite(transform.xy) and
        std.math.isFinite(transform.tx) and
        std.math.isFinite(transform.yx) and
        std.math.isFinite(transform.yy) and
        std.math.isFinite(transform.ty);
}

/// Prepare the hinted advances HarfBuzz will consume during the second shape
/// pass. Sources that cannot produce advances are omitted from the provider,
/// so Snail naturally leaves those fallback faces in native em space.
fn prepareTtAdvances(
    state: *TextEngine.State,
    shaped: *const snail.ShapedText,
    ppem: snail.TtHintPpem,
) ![]const snail.FontSource {
    var prepared_count: usize = 0;
    for (state.font_sources, state.tt_sources) |*source, *tt_source| {
        if (tt_source.context == null) continue;
        prepareTtSource(state, shaped, source, ppem, .advances) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        state.tt_source_scratch[prepared_count] = source.*;
        prepared_count += 1;
    }
    return state.tt_source_scratch[0..prepared_count];
}

/// Prepare grid-fitted curves for sources whose hinted advances participated
/// in shaping. The scratch slice is compacted in place to the sources whose
/// geometry also succeeded; only those font ids are emitted as TT records.
fn recordTtGeometry(
    state: *TextEngine.State,
    shaped: *const snail.ShapedText,
    ppem: snail.TtHintPpem,
    advance_sources: []const snail.FontSource,
) ![]const snail.FontSource {
    var prepared_count: usize = 0;
    for (advance_sources) |source| {
        const stable_source = sourceForFontId(state, source.font_id) orelse continue;
        prepareTtSource(state, shaped, stable_source, ppem, .geometry) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        state.tt_source_scratch[prepared_count] = stable_source.*;
        prepared_count += 1;
    }
    return state.tt_source_scratch[0..prepared_count];
}

const TtArtifact = enum { advances, geometry };

fn prepareTtSource(
    state: *TextEngine.State,
    shaped: *const snail.ShapedText,
    source: *const snail.FontSource,
    ppem: snail.TtHintPpem,
    artifact: TtArtifact,
) !void {
    const allocator = state.allocator;
    const source_index = sourceIndexForFontId(state, source.font_id) orelse
        return error.UnknownFontSource;
    const selected_sources = state.font_sources[source_index .. source_index + 1];
    var plan = switch (artifact) {
        .advances => try snail.planTtAdvances(
            &state.atlas,
            allocator,
            selected_sources,
            &.{shaped},
            ppem,
        ),
        .geometry => try snail.planRuns(
            &state.atlas,
            allocator,
            selected_sources,
            &.{shaped},
            .{ .tt_hint = ppem },
        ),
    };
    defer plan.deinit();
    const requests = plan.requests();
    if (requests.len == 0) return;

    const owned = try allocator.alloc(?snail.prepared.OwnedRecord, requests.len);
    defer allocator.free(owned);
    @memset(owned, null);
    defer for (owned) |*record| if (record.*) |*value| value.deinit();
    const results = try allocator.alloc(?snail.prepared.RecordView, requests.len);
    defer allocator.free(results);
    @memset(results, null);

    const tt_source = &state.tt_sources[source_index];
    const hint_context = if (tt_source.context) |*context| context else return error.TtUnsupported;
    const packed_ppem = try ppem.packed26Dot6();
    const size_entry = try tt_source.sizes.getOrPut(allocator, packed_ppem);
    if (!size_entry.found_existing) {
        size_entry.value_ptr.* = hint_context.prepareSize(ppem) catch |err| {
            _ = tt_source.sizes.remove(packed_ppem);
            return err;
        };
    }
    for (requests, 0..) |request, request_index| {
        owned[request_index] = try hint_context.prepare(size_entry.value_ptr, request);
        results[request_index] = owned[request_index].?.view();
    }
    try plan.applyInPlace(allocator, &state.atlas, results);
}

fn sourceForFontId(state: *TextEngine.State, font_id: u32) ?*const snail.FontSource {
    const index = sourceIndexForFontId(state, font_id) orelse return null;
    return &state.font_sources[index];
}

fn sourceIndexForFontId(state: *const TextEngine.State, font_id: u32) ?usize {
    for (state.font_sources, 0..) |source, index| {
        if (source.font_id == font_id) return index;
    }
    return null;
}

pub fn linearColor(color: visual.Color) [4]f32 {
    const scale = 1.0 / 255.0;
    return snail.color.srgbToLinearColor(.{
        @as(f32, @floatFromInt(color.r)) * scale,
        @as(f32, @floatFromInt(color.g)) * scale,
        @as(f32, @floatFromInt(color.b)) * scale,
        @as(f32, @floatFromInt(color.a)) * scale,
    });
}

test "visual colors cross the Snail boundary once" {
    const linear = linearColor(.rgba(128, 64, 0, 128));
    try std.testing.expectApproxEqAbs(@as(f32, 0.21586), linear[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.05127), linear[1], 0.0001);
    try std.testing.expectEqual(@as(f32, 0), linear[2]);
    try std.testing.expectApproxEqAbs(@as(f32, 128.0 / 255.0), linear[3], 0.0001);
}
