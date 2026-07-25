//! Pure file-browser view: model snapshot to dumb components.

const std = @import("std");
const actions = @import("browser_actions");
const model_module = @import("file_browser_model");
const components = @import("goop_components");
const ui = @import("goop_ui");

pub const Viewport = struct {
    width: f32,
    height: f32,

    pub fn visibleRows(self: Viewport) usize {
        const body = @max(0, self.height - 128);
        return @max(1, @as(usize, @intFromFloat(@floor(body / row_height))));
    }
};

const row_height: f32 = 32;

pub fn build(
    allocator: std.mem.Allocator,
    model: *const model_module.Model,
    viewport: Viewport,
) !ui.Element {
    const toolbar_children = try allocator.alloc(ui.Element, 6);
    toolbar_children[0] = toolbarButton(10, .back, "Back");
    toolbar_children[1] = toolbarButton(11, .forward, "Forward");
    toolbar_children[2] = toolbarButton(12, .up, "Up");
    toolbar_children[3] = toolbarButton(13, .refresh, "Refresh");
    toolbar_children[4] = toolbarButton(14, .home, "Root");
    toolbar_children[5] = (components.Spacer{
        .common = .{
            .id = .init(15),
            .style = .{ .flex_grow = 1, .height = 36 },
        },
    }).element();

    const toolbar = (components.Container{
        .common = .{
            .id = .init(2),
            .style = .{
                .height = 52,
                .padding = .symmetric(8, 8),
                .gap = 6,
                .bg = .rgb(31, 38, 48),
            },
            .children = toolbar_children,
        },
        .direction = .row,
    }).element();

    const path = (components.Text{
        .common = .{
            .id = .init(3),
            .style = .{
                .height = 38,
                .padding = .symmetric(12, 9),
                .bg = .rgb(22, 27, 34),
                .fg = .rgb(205, 214, 224),
            },
        },
        .content = model.current_dir,
        .overflow = .ellipsis,
    }).element();

    const visible_rows = viewport.visibleRows();
    const start = @min(model.scroll_offset, model.entries.items.len);
    const end = @min(model.entries.items.len, start + visible_rows);
    const rows = try allocator.alloc(ui.Element, end - start);
    for (model.entries.items[start..end], 0..) |entry, local_index| {
        const index = start + local_index;
        const label = try std.fmt.allocPrint(
            allocator,
            "{s}  {s}",
            .{ kindGlyph(entry.kind), entry.name },
        );
        const selected = model.selected_index != null and model.selected_index.? == index;
        rows[local_index] = (components.Button{
            .common = .{
                .id = stableEntryId(entry.path),
                .action = .init(actions.entry(index)),
                .style = .{
                    .height = row_height,
                    .padding = .symmetric(12, 7),
                    .bg = if (selected) .rgb(42, 83, 130) else .rgb(18, 22, 28),
                    .bg_hover = if (selected) .rgb(50, 95, 148) else .rgb(32, 40, 50),
                    .border_width = 0,
                    .border_radius = 3,
                },
            },
            .label = label,
        }).element();
    }

    const list = (components.Container{
        .common = .{
            .id = .init(4),
            .style = .{
                .flex_grow = 1,
                .padding = .symmetric(8, 6),
                .gap = 2,
                .bg = .rgb(18, 22, 28),
            },
            .children = rows,
        },
    }).element();

    const status_text = try std.fmt.allocPrint(
        allocator,
        "{} items{s}",
        .{
            model.entries.items.len,
            if (model.selected_index != null) " · 1 selected" else "",
        },
    );
    const status = (components.Text{
        .common = .{
            .id = .init(5),
            .style = .{
                .height = 30,
                .padding = .symmetric(10, 6),
                .bg = .rgb(31, 38, 48),
                .fg = .rgb(155, 168, 184),
                .font_size = 12,
            },
        },
        .content = status_text,
    }).element();

    const root_children = try allocator.alloc(ui.Element, 4);
    root_children[0] = toolbar;
    root_children[1] = path;
    root_children[2] = list;
    root_children[3] = status;
    return (components.Container{
        .common = .{
            .id = .init(1),
            .style = .{
                .width = viewport.width,
                .height = viewport.height,
                .padding = .all(0),
                .gap = 0,
                .bg = .rgb(18, 22, 28),
            },
            .children = root_children,
        },
    }).element();
}

fn toolbarButton(id: u64, action: actions.Action, label: []const u8) ui.Element {
    return (components.Button{
        .common = .{
            .id = .init(id),
            .action = .init(actions.raw(action)),
            .style = .{
                .width = 78,
                .height = 36,
                .padding = .symmetric(10, 8),
                .bg = .rgb(47, 57, 70),
                .bg_hover = .rgb(61, 74, 91),
                .bg_active = .rgb(35, 43, 53),
                .border = .rgb(72, 84, 100),
            },
        },
        .label = label,
    }).element();
}

fn kindGlyph(kind: model_module.Entry.Kind) []const u8 {
    return switch (kind) {
        .directory => "▸",
        .file => "·",
        .symlink => "↗",
        .other => "◇",
    };
}

fn stableEntryId(path: []const u8) ui.ElementId {
    return .init(std.hash.Wyhash.hash(0x6272_6f77_7365_7200, path));
}

test "row count is bounded by the viewport" {
    try std.testing.expectEqual(@as(usize, 1), (Viewport{ .width = 10, .height = 100 }).visibleRows());
    try std.testing.expectEqual(@as(usize, 12), (Viewport{ .width = 10, .height = 512 }).visibleRows());
}
