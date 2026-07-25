//! Opinionated, declarative display components.
//!
//! Constructors in this module are pure: props in, `goop_ui.Element` out.

const ui = @import("goop_ui");

pub const Common = struct {
    id: ui.ElementId,
    style: ui.Style = .{},
    action: ?ui.ActionId = null,
    children: []const ui.Element = &.{},
};

pub const Button = struct {
    common: Common,
    label: []const u8,

    pub fn element(self: Button) ui.Element {
        return .{
            .id = self.common.id,
            .widget = .{ .button = .{ .label = self.label } },
            .style = self.common.style,
            .action = self.common.action,
            .children = self.common.children,
        };
    }
};

pub const Text = struct {
    common: Common,
    content: []const u8,
    overflow: ui.TextOverflow = .visible,

    pub fn element(self: Text) ui.Element {
        return .{
            .id = self.common.id,
            .widget = .{ .text = .{
                .content = self.content,
                .overflow = self.overflow,
            } },
            .style = self.common.style,
            .children = self.common.children,
        };
    }
};

pub const Container = struct {
    common: Common,
    direction: ui.WidgetKind.Container.Direction = .column,

    pub fn element(self: Container) ui.Element {
        return .{
            .id = self.common.id,
            .widget = .{ .container = .{ .direction = self.direction } },
            .style = self.common.style,
            .children = self.common.children,
        };
    }
};

pub const Icon = struct {
    common: Common,
    kind: ui.IconId,

    pub fn element(self: Icon) ui.Element {
        return .{
            .id = self.common.id,
            .widget = .{ .icon = .{ .kind = self.kind } },
            .style = self.common.style,
            .action = self.common.action,
            .children = self.common.children,
        };
    }
};

pub const Spacer = struct {
    common: Common,

    pub fn element(self: Spacer) ui.Element {
        return .{
            .id = self.common.id,
            .widget = .spacer,
            .style = self.common.style,
        };
    }
};

test "button is a pure declarative value" {
    const action = ui.ActionId.init(4);
    const element = (Button{
        .common = .{ .id = .init(3), .action = action },
        .label = "Refresh",
    }).element();

    try @import("std").testing.expectEqual(action, element.action.?);
    try @import("std").testing.expectEqualStrings("Refresh", element.widget.button.label);
}
