//! Optional stock look for Goop's resolved UI model.
//!
//! `Chrome` is caller-owned. It retains the last generated canonical visual
//! operation list and frees it on invalidation or deinitialization. Preparing a
//! dirty revision allocates; replay into a caller-owned encoder does not.

const std = @import("std");
const goop = @import("goop");
const visual = @import("goop_visual");
const stock = @import("chrome/stock.zig");

pub const Operation = visual.Operation;
pub const List = visual.List;
pub const Options = stock.VisualOptions;
pub const CustomVisualResolver = stock.CustomVisualResolver;
pub const Scope = stock.VisualScope;
pub const Error = stock.VisualError;

comptime {
    if (Operation != visual.Operation or List != visual.List or goop.Rect != visual.Rect) {
        @compileError("Chrome must use Goop's canonical goop_visual types exactly");
    }
}

pub const Chrome = struct {
    allocator: std.mem.Allocator,
    cached: ?List = null,
    key: ?Key = null,

    const Key = struct {
        tree: *const goop.Tree,
        revision: u64,
        text_measure: ?*const goop.TextMeasureCtx,
        options: Options,
    };

    pub fn init(allocator: std.mem.Allocator) Chrome {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Chrome) void {
        self.invalidate();
    }

    /// Explicitly discard retained operations. Any previously returned list
    /// becomes invalid immediately.
    pub fn invalidate(self: *Chrome) void {
        if (self.cached) |*list| stock.freeVisuals(list, self.allocator);
        self.cached = null;
        self.key = null;
    }

    /// Prepare and borrow stock visual operations for a resolved core state.
    /// A changed source, revision, text-measure capability, or scope rebuilds
    /// the list and may allocate. A cache hit performs no allocation.
    /// Returned text and operations borrow from core/Chrome respectively and
    /// remain valid until the next dirty `prepare`, `invalidate`, or `deinit`.
    pub fn prepare(self: *Chrome, state: goop.ChromeState, options: Options) Error!List {
        const next_key = Key{
            .tree = state.tree,
            .revision = state.revision,
            .text_measure = state.text_measure,
            .options = options,
        };
        if (self.key) |key| {
            if (key.tree == next_key.tree and
                key.revision == next_key.revision and
                key.text_measure == next_key.text_measure and
                std.meta.eql(key.options, next_key.options))
            {
                return self.cached.?;
            }
        }

        var generated = try stock.prepareVisuals(
            state.tree,
            state.theme,
            self.allocator,
            state.text_measure,
            options,
        );
        errdefer stock.freeVisuals(&generated, self.allocator);

        self.invalidate();
        self.cached = generated;
        self.key = next_key;
        return generated;
    }

    /// Prepare stock visuals, then replay them directly into a structural
    /// caller-owned encoder. Replay itself is allocation-free; preparation may
    /// allocate when the resolved revision or scope changed.
    pub fn emit(self: *Chrome, state: goop.ChromeState, options: Options, encoder: anytype) !void {
        const list = try self.prepare(state, options);
        try visual.emitAll(encoder, list.commands);
    }
};

test "Chrome owns and reuses canonical visual operations" {
    var context = try goop.Context.init(std.testing.allocator, .{ .width = 320, .height = 200 });
    defer context.deinit();

    const root = try context.tree.addRoot(.{ .container = .{} });
    _ = try context.tree.addChild(root, .{ .button = .{ .label = "OK" } });
    context.doLayout(null);

    var chrome = Chrome.init(std.testing.allocator);
    defer chrome.deinit();

    const first = try chrome.prepare(context.chromeState(), .{});
    const second = try chrome.prepare(context.chromeState(), .{});
    try std.testing.expect(first.commands.len > 0);
    try std.testing.expectEqual(first.commands.ptr, second.commands.ptr);

    _ = try context.processEvents();
    const after_idle_processing = try chrome.prepare(context.chromeState(), .{});
    try std.testing.expectEqual(first.commands.ptr, after_idle_processing.commands.ptr);

    context.invalidate();
    context.doLayout(null);
    const third = try chrome.prepare(context.chromeState(), .{});
    try std.testing.expect(third.commands.len > 0);
}

test "resolved visitor is handle-free and stock Chrome emits custom IDs" {
    var context = try goop.Context.init(std.testing.allocator, .{ .width = 320, .height = 200 });
    defer context.deinit();
    _ = try context.tree.addRootControl(.{
        .identity = .{ .element_id = .init(77) },
        .widget = .{ .custom = .{ .type_id = 9, .width = 32, .height = 16 } },
    });
    context.doLayout(null);

    const Capture = struct {
        count: usize = 0,
        element_id: ?goop.ElementId = null,

        pub fn enter(self: *@This(), value: goop.ResolvedElement) void {
            self.count += 1;
            self.element_id = value.id;
        }

        pub fn leave(_: *@This(), _: goop.ResolvedElement) void {}
    };
    var capture = Capture{};
    try context.visitResolved(&capture);
    try std.testing.expectEqual(@as(usize, 1), capture.count);
    try std.testing.expectEqual(goop.ElementId.init(77), capture.element_id.?);

    var chrome = Chrome.init(std.testing.allocator);
    defer chrome.deinit();
    const list = try chrome.prepare(context.chromeState(), .{});
    try std.testing.expectEqual(@as(usize, 1), list.commands.len);
    try std.testing.expectEqual(visual.CustomId.fromElementId(77), list.commands[0].custom.id);
}

test "caller resolves a stock custom leaf into a canonical image" {
    var context = try goop.Context.init(std.testing.allocator, .{ .width = 32, .height = 16 });
    defer context.deinit();
    _ = try context.tree.addRootControl(.{
        .identity = .{ .element_id = .init(91) },
        .widget = .{ .custom = .{ .width = 32, .height = 16 } },
    });
    context.doLayout(null);

    const Resolver = struct {
        fn resolve(_: *anyopaque, custom: visual.Custom) ?visual.Operation {
            const rgba = struct {
                const bytes = [_]u8{ 255, 0, 0, 255 };
            }.bytes;
            return .{ .image = .{
                .bounds = custom.bounds,
                .source = .{
                    .id = .{ .value = 91 },
                    .width = 1,
                    .height = 1,
                    .rgba = &rgba,
                },
            } };
        }
    };
    var resolver_context: u8 = 0;
    var chrome = Chrome.init(std.testing.allocator);
    defer chrome.deinit();
    const list = try chrome.prepare(context.chromeState(), .{
        .custom_visual = .{ .context = &resolver_context, .resolve_fn = Resolver.resolve },
    });
    try std.testing.expectEqual(@as(usize, 1), list.commands.len);
    try std.testing.expect(list.commands[0] == .image);
    try std.testing.expectEqual(@as(u64, 91), list.commands[0].image.source.id.value);
}

test {
    _ = stock;
}
