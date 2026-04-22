const std = @import("std");
const goop = @import("goop");
const c = @cImport({
    @cInclude("time.h");
});

const BenchConfig = struct {
    width: u32 = 1440,
    height: u32 = 900,
    table_rows: usize = 320,
    layout_iters: usize = 120,
    paint_iters: usize = 240,
    lower_iters: usize = 240,
    redraw_iters: usize = 240,
    cache_iters: usize = 20_000,
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const config = BenchConfig{};

    var ctx = try goop.Context.init(std.heap.page_allocator, .{
        .width = config.width,
        .height = config.height,
        .theme = .{
            .bg = .rgb(243, 246, 251),
            .fg = .rgb(24, 29, 38),
            .accent = .rgb(58, 126, 219),
            .border = .rgb(203, 210, 223),
            .bg_hover = .rgb(231, 238, 248),
            .bg_active = .rgb(220, 229, 243),
            .focus_ring = .rgba(58, 126, 219, 210),
            .placeholder_fg = .rgb(123, 133, 148),
            .selection_bg = .rgba(58, 126, 219, 84),
            .tree_guide = .rgba(145, 152, 165, 180),
            .font_size = 14,
            .padding = goop.style.Edges.symmetric(8, 6),
            .border_radius = 6,
            .border_width = 1,
            .spacing = 6,
            .thumb_width = 14,
        },
    });
    defer ctx.deinit();

    try buildExplorerWorkload(&ctx, alloc, config.table_rows);

    ctx.doLayout(null);
    const initial_paint_list = try ctx.generatePaintList();
    const initial_draw_list = try ctx.generateDrawList();

    const node_count = ctx.tree.count();
    const paint_count = initial_paint_list.commands.len;
    const draw_count = initial_draw_list.commands.len;

    // Warm caches before timing.
    for (0..16) |i| {
        ctx.setDimensions(config.width + @as(u32, @intCast(i & 1)), config.height);
        ctx.doLayout(null);
        _ = try ctx.generatePaintList();
        _ = try ctx.generateDrawList();
    }
    for (0..32) |i| {
        try ctx.pushEvent(.{ .mouse_move = .{
            .x = 320 + @as(f32, @floatFromInt(i % 17)),
            .y = 180 + @as(f32, @floatFromInt(i % 11)),
        } });
        ctx.processEvents();
        _ = try ctx.generatePaintList();
        _ = try ctx.generateDrawList();
    }
    _ = try ctx.generatePaintList();
    _ = try ctx.generateDrawList();

    const layout_paint_total_ns = try benchLayoutAndPaint(&ctx, config);
    const paint_regen_total_ns = try benchPaintRegen(&ctx, config);
    const lower_total_ns = try benchLowerCachedPaint(&ctx, config);
    const draw_regen_total_ns = try benchDrawRegen(&ctx, config);
    const paint_cache_total_ns = try benchCachedPaint(&ctx, config);
    const draw_cache_total_ns = try benchCachedDraw(&ctx, config);

    printSummary("layout+paint (resize invalidation)", layout_paint_total_ns, config.layout_iters);
    printSummary("paint regen (mouse move)", paint_regen_total_ns, config.paint_iters);
    printSummary("lower cached paint -> draw", lower_total_ns, config.lower_iters);
    printSummary("full draw regen (mouse move)", draw_regen_total_ns, config.redraw_iters);
    printSummary("cached paint list hit", paint_cache_total_ns, config.cache_iters);
    printSummary("cached draw list hit", draw_cache_total_ns, config.cache_iters);

    std.debug.print(
        "scene summary: nodes={}, paint_commands={}, draw_commands={}, table_rows={}\n",
        .{ node_count, paint_count, draw_count, config.table_rows },
    );
}

fn benchLayoutAndPaint(ctx: *goop.Context, config: BenchConfig) !u64 {
    const start_ns = monotonicNs();
    var paint_accum: usize = 0;

    for (0..config.layout_iters) |i| {
        const width = config.width + @as(u32, @intCast(i & 1));
        ctx.setDimensions(width, config.height);
        ctx.doLayout(null);
        const paint_list = try ctx.generatePaintList();
        paint_accum +%= paint_list.commands.len;
    }

    std.mem.doNotOptimizeAway(paint_accum);
    return monotonicNs() - start_ns;
}

fn benchPaintRegen(ctx: *goop.Context, config: BenchConfig) !u64 {
    ctx.setDimensions(config.width, config.height);
    ctx.doLayout(null);
    _ = try ctx.generatePaintList();

    const start_ns = monotonicNs();
    var paint_accum: usize = 0;

    for (0..config.paint_iters) |i| {
        try ctx.pushEvent(.{ .mouse_move = .{
            .x = 280 + @as(f32, @floatFromInt((i * 7) % 91)),
            .y = 160 + @as(f32, @floatFromInt((i * 13) % 57)),
        } });
        ctx.processEvents();
        const paint_list = try ctx.generatePaintList();
        paint_accum +%= paint_list.commands.len;
    }

    std.mem.doNotOptimizeAway(paint_accum);
    return monotonicNs() - start_ns;
}

fn benchLowerCachedPaint(ctx: *goop.Context, config: BenchConfig) !u64 {
    ctx.setDimensions(config.width, config.height);
    ctx.doLayout(null);
    const paint_list = try ctx.generatePaintList();

    const start_ns = monotonicNs();
    var draw_accum: usize = 0;

    for (0..config.lower_iters) |_| {
        var draw_list = try goop.draw.lowerPaintList(paint_list, std.heap.page_allocator, null);
        draw_accum +%= draw_list.commands.len;
        goop.draw.freeDrawList(&draw_list, std.heap.page_allocator);
    }

    std.mem.doNotOptimizeAway(draw_accum);
    return monotonicNs() - start_ns;
}

fn benchCachedPaint(ctx: *goop.Context, config: BenchConfig) !u64 {
    ctx.setDimensions(config.width, config.height);
    ctx.doLayout(null);
    _ = try ctx.generatePaintList();

    const start_ns = monotonicNs();
    var paint_accum: usize = 0;

    for (0..config.cache_iters) |_| {
        const paint_list = try ctx.generatePaintList();
        paint_accum +%= paint_list.commands.len;
    }

    std.mem.doNotOptimizeAway(paint_accum);
    return monotonicNs() - start_ns;
}

fn benchDrawRegen(ctx: *goop.Context, config: BenchConfig) !u64 {
    ctx.setDimensions(config.width, config.height);
    ctx.doLayout(null);
    _ = try ctx.generateDrawList();

    const start_ns = monotonicNs();
    var draw_accum: usize = 0;

    for (0..config.redraw_iters) |i| {
        try ctx.pushEvent(.{ .mouse_move = .{
            .x = 280 + @as(f32, @floatFromInt((i * 7) % 91)),
            .y = 160 + @as(f32, @floatFromInt((i * 13) % 57)),
        } });
        ctx.processEvents();
        const draw_list = try ctx.generateDrawList();
        draw_accum +%= draw_list.commands.len;
    }

    std.mem.doNotOptimizeAway(draw_accum);
    return monotonicNs() - start_ns;
}

fn benchCachedDraw(ctx: *goop.Context, config: BenchConfig) !u64 {
    ctx.setDimensions(config.width, config.height);
    ctx.doLayout(null);
    _ = try ctx.generateDrawList();

    const start_ns = monotonicNs();
    var draw_accum: usize = 0;

    for (0..config.cache_iters) |_| {
        const draw_list = try ctx.generateDrawList();
        draw_accum +%= draw_list.commands.len;
    }

    std.mem.doNotOptimizeAway(draw_accum);
    return monotonicNs() - start_ns;
}

fn printSummary(label: []const u8, total_ns: u64, iterations: usize) void {
    const total_ms = @as(f64, @floatFromInt(total_ns)) / @as(f64, std.time.ns_per_ms);
    const avg_us = @as(f64, @floatFromInt(total_ns)) / @as(f64, @floatFromInt(iterations)) / @as(f64, std.time.ns_per_us);
    const ops_per_s = @as(f64, @floatFromInt(iterations)) * @as(f64, std.time.ns_per_s) / @as(f64, @floatFromInt(total_ns));
    std.debug.print(
        "{s}: total={d:.2}ms avg={d:.2}us ops/s={d:.1}\n",
        .{ label, total_ms, avg_us, ops_per_s },
    );
}

fn labelf(alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![]const u8 {
    return std.fmt.allocPrint(alloc, fmt, args);
}

fn monotonicNs() u64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(u64, @intCast(ts.tv_sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.tv_nsec));
}

fn buildExplorerWorkload(ctx: *goop.Context, alloc: std.mem.Allocator, table_rows: usize) !void {
    const root = try ctx.tree.addRoot(.{ .container = .{ .direction = .column } });

    const menu_bar = try ctx.tree.addChild(root, .{ .menu_bar = .{} });
    _ = try ctx.tree.addChild(menu_bar, .{ .menu = .{ .label = "File" } });
    _ = try ctx.tree.addChild(menu_bar, .{ .menu = .{ .label = "Edit" } });
    _ = try ctx.tree.addChild(menu_bar, .{ .menu = .{ .label = "View" } });
    _ = try ctx.tree.addChild(menu_bar, .{ .menu = .{ .label = "Go" } });
    _ = try ctx.tree.addChild(menu_bar, .{ .menu = .{ .label = "Help" } });

    const toolbar = try ctx.tree.addChild(root, .{ .toolbar = .{} });
    ctx.tree.get(toolbar).style_override = .{
        .bg = .rgb(232, 236, 243),
        .border = .rgb(203, 210, 223),
        .padding = goop.style.Edges.symmetric(10, 8),
        .border_radius = 0,
    };
    _ = try ctx.tree.addChild(toolbar, .{ .button = .{ .label = "Back" } });
    _ = try ctx.tree.addChild(toolbar, .{ .button = .{ .label = "Forward" } });
    _ = try ctx.tree.addChild(toolbar, .{ .button = .{ .label = "Up" } });
    _ = try ctx.tree.addChild(toolbar, .{ .button = .{ .label = "New" } });
    _ = try ctx.tree.addChild(toolbar, .{ .button = .{ .label = "Sort" } });
    _ = try ctx.tree.addChild(toolbar, .{ .button = .{ .label = "View" } });
    const address_input = try ctx.tree.addChild(toolbar, .{ .text_input = .{} });
    ctx.tree.get(address_input).kind.text_input.insertSlice("C:\\Workspace\\goop\\assets\\mock-project");
    _ = try ctx.tree.addChild(toolbar, .{ .text_input = .{ .placeholder = "Search mock-project" } });

    const content_split = try ctx.tree.addChild(root, .{ .splitter = .{
        .direction = .row,
        .ratio = 0.26,
        .min_first = 220,
        .min_second = 640,
        .thickness = 8,
    } });

    const nav_panel = try ctx.tree.addChild(content_split, .{ .container = .{ .direction = .column } });
    ctx.tree.get(nav_panel).style_override = .{
        .bg = .rgb(247, 249, 252),
        .border = .rgb(214, 220, 230),
        .padding = goop.style.Edges.symmetric(10, 10),
        .border_radius = 0,
    };
    _ = try ctx.tree.addChild(nav_panel, .{ .text = .{ .content = "Folders" } });
    try addNavTree(ctx, alloc, nav_panel);

    const main_panel = try ctx.tree.addChild(content_split, .{ .container = .{ .direction = .column } });
    ctx.tree.get(main_panel).style_override = .{
        .bg = .rgb(250, 252, 255),
        .border = .rgb(214, 220, 230),
        .padding = goop.style.Edges.symmetric(10, 10),
        .border_radius = 0,
    };

    const crumb_bar = try ctx.tree.addChild(main_panel, .{ .toolbar = .{} });
    ctx.tree.get(crumb_bar).style_override = .{
        .bg = .rgb(255, 255, 255),
        .border = .rgb(214, 220, 230),
        .padding = goop.style.Edges.symmetric(10, 7),
        .border_radius = 4,
    };
    _ = try ctx.tree.addChild(crumb_bar, .{ .text = .{ .content = "This PC" } });
    _ = try ctx.tree.addChild(crumb_bar, .{ .text = .{ .content = ">" } });
    _ = try ctx.tree.addChild(crumb_bar, .{ .text = .{ .content = "Workspace" } });
    _ = try ctx.tree.addChild(crumb_bar, .{ .text = .{ .content = ">" } });
    _ = try ctx.tree.addChild(crumb_bar, .{ .text = .{ .content = "goop" } });
    _ = try ctx.tree.addChild(crumb_bar, .{ .text = .{ .content = ">" } });
    _ = try ctx.tree.addChild(crumb_bar, .{ .text = .{ .content = "assets" } });
    _ = try ctx.tree.addChild(crumb_bar, .{ .text = .{ .content = ">" } });
    _ = try ctx.tree.addChild(crumb_bar, .{ .text = .{ .content = "mock-project" } });

    const detail_split = try ctx.tree.addChild(main_panel, .{ .splitter = .{
        .direction = .column,
        .ratio = 0.82,
        .min_first = 380,
        .min_second = 110,
        .thickness = 8,
    } });

    const table_container = try ctx.tree.addChild(detail_split, .{ .container = .{ .direction = .column } });
    const file_table = try ctx.tree.addChild(table_container, .{ .table = .{
        .columns = 4,
        .resizable = true,
        .sortable = true,
        .selection_mode = .multiple,
        .min_column_width = 92,
    } });
    {
        const table = &ctx.tree.get(file_table).kind.table;
        table.column_weights[0] = 0.50;
        table.column_weights[1] = 0.20;
        table.column_weights[2] = 0.18;
        table.column_weights[3] = 0.12;
    }
    try addFileTable(ctx, alloc, file_table, table_rows);

    const preview = try ctx.tree.addChild(detail_split, .{ .container = .{ .direction = .column } });
    ctx.tree.get(preview).style_override = .{
        .bg = .rgb(246, 248, 252),
        .border = .rgb(214, 220, 230),
        .padding = goop.style.Edges.symmetric(10, 10),
    };
    _ = try ctx.tree.addChild(preview, .{ .text = .{ .content = "Details Pane" } });
    _ = try ctx.tree.addChild(preview, .{ .text = .{ .content = "Selected: render-cache-017.bin" } });
    _ = try ctx.tree.addChild(preview, .{ .text = .{ .content = "Type: Binary Cache" } });
    _ = try ctx.tree.addChild(preview, .{ .text = .{ .content = "Size: 18.4 MB" } });
    _ = try ctx.tree.addChild(preview, .{ .text = .{ .content = "Tags: Generated, Preview, Shared" } });

    const status_bar = try ctx.tree.addChild(root, .{ .status_bar = .{} });
    ctx.tree.get(status_bar).style_override = .{
        .bg = .rgb(232, 236, 243),
        .border = .rgb(203, 210, 223),
        .padding = goop.style.Edges.symmetric(10, 7),
        .border_radius = 0,
    };
    _ = try ctx.tree.addChild(status_bar, .{ .text = .{ .content = "1,284 items" } });
    _ = try ctx.tree.addChild(status_bar, .{ .text = .{ .content = "146 selected" } });
    _ = try ctx.tree.addChild(status_bar, .{ .text = .{ .content = "Status: Indexed" } });
}

fn addNavTree(ctx: *goop.Context, alloc: std.mem.Allocator, parent: goop.NodeHandle) !void {
    const quick = try ctx.tree.addChild(parent, .{ .tree_item = .{
        .label = "Quick Access",
        .group = 1,
        .selected = true,
    } });
    _ = try ctx.tree.addChild(quick, .{ .tree_item = .{ .label = "Desktop", .group = 1 } });
    _ = try ctx.tree.addChild(quick, .{ .tree_item = .{ .label = "Downloads", .group = 1 } });
    _ = try ctx.tree.addChild(quick, .{ .tree_item = .{ .label = "Documents", .group = 1 } });
    _ = try ctx.tree.addChild(quick, .{ .tree_item = .{ .label = "Pictures", .group = 1 } });

    const this_pc = try ctx.tree.addChild(parent, .{ .tree_item = .{
        .label = "This PC",
        .group = 1,
    } });
    _ = try ctx.tree.addChild(this_pc, .{ .tree_item = .{ .label = "Desktop", .group = 1 } });
    _ = try ctx.tree.addChild(this_pc, .{ .tree_item = .{ .label = "Documents", .group = 1 } });
    _ = try ctx.tree.addChild(this_pc, .{ .tree_item = .{ .label = "Downloads", .group = 1 } });
    _ = try ctx.tree.addChild(this_pc, .{ .tree_item = .{ .label = "Pictures", .group = 1 } });
    _ = try ctx.tree.addChild(this_pc, .{ .tree_item = .{ .label = "Music", .group = 1 } });
    _ = try ctx.tree.addChild(this_pc, .{ .tree_item = .{ .label = "Videos", .group = 1 } });

    const workspace = try ctx.tree.addChild(parent, .{ .tree_item = .{
        .label = "Workspace",
        .group = 1,
    } });
    for (0..10) |section| {
        const folder = try labelf(alloc, "Client {:0>2}", .{section + 1});
        const branch = try ctx.tree.addChild(workspace, .{ .tree_item = .{
            .label = folder,
            .group = 1,
        } });
        for (0..4) |sub| {
            const child = try labelf(alloc, "Shot {:0>2}.{:0>2}", .{ section + 1, sub + 1 });
            _ = try ctx.tree.addChild(branch, .{ .tree_item = .{
                .label = child,
                .group = 1,
            } });
        }
    }
}

fn addFileTable(ctx: *goop.Context, alloc: std.mem.Allocator, table: goop.NodeHandle, table_rows: usize) !void {
    const header = try ctx.tree.addChild(table, .{ .table_row = .{ .header = true } });
    try addHeaderCell(ctx, header, "Name");
    try addHeaderCell(ctx, header, "Date modified");
    try addHeaderCell(ctx, header, "Type");
    try addHeaderCell(ctx, header, "Size");

    for (0..table_rows) |i| {
        const row = try ctx.tree.addChild(table, .{ .table_row = .{
            .selected = i % 19 == 0,
        } });

        const kind = switch (i % 6) {
            0 => "Folder",
            1 => "PNG File",
            2 => "Zig Source",
            3 => "Markdown",
            4 => "Binary Cache",
            else => "JSON File",
        };
        const ext = switch (i % 6) {
            0 => "",
            1 => ".png",
            2 => ".zig",
            3 => ".md",
            4 => ".bin",
            else => ".json",
        };
        const name = try labelf(alloc, "render-cache-{:0>3}{s}", .{ i + 1, ext });
        const month = @as(u8, @intCast((i % 12) + 1));
        const day = @as(u8, @intCast((i % 28) + 1));
        const date = try labelf(alloc, "2026-{d:0>2}-{d:0>2}  {d:0>2}:{d:0>2}", .{
            month,
            day,
            @as(u8, @intCast((i * 3) % 24)),
            @as(u8, @intCast((i * 7) % 60)),
        });
        const size = if (i % 6 == 0)
            ""
        else
            try labelf(alloc, "{d}.{d} MB", .{
                1 + (i % 97),
                (i * 3) % 10,
            });

        try addBodyCell(ctx, row, name);
        try addBodyCell(ctx, row, date);
        try addBodyCell(ctx, row, kind);
        try addBodyCell(ctx, row, size);
    }
}

fn addHeaderCell(ctx: *goop.Context, row: goop.NodeHandle, label: []const u8) !void {
    const cell = try ctx.tree.addChild(row, .{ .table_cell = .{} });
    _ = try ctx.tree.addChild(cell, .{ .text = .{ .content = label } });
}

fn addBodyCell(ctx: *goop.Context, row: goop.NodeHandle, label: []const u8) !void {
    const cell = try ctx.tree.addChild(row, .{ .table_cell = .{} });
    _ = try ctx.tree.addChild(cell, .{ .text = .{ .content = label } });
}
