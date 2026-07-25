//! Browser behavior: semantic action in, model mutation out.

const actions = @import("browser_actions");
const model_module = @import("file_browser_model");

pub const Outcome = struct {
    model_changed: bool = false,
    quit: bool = false,
};

pub const Controller = struct {
    model: *model_module.Model,

    pub fn apply(self: Controller, raw_action: u64) !Outcome {
        const decoded = actions.decode(raw_action) orelse return .{};
        return switch (decoded) {
            .entry => |index| blk: {
                try self.model.activate(index);
                break :blk .{ .model_changed = true };
            },
            .action => |action| self.applyAction(action),
        };
    }

    pub fn scroll(self: Controller, delta_rows: i32, visible_rows: usize) Outcome {
        const before = self.model.scroll_offset;
        self.model.scrollRows(delta_rows, visible_rows);
        return .{ .model_changed = before != self.model.scroll_offset };
    }

    fn applyAction(self: Controller, action: actions.Action) !Outcome {
        return switch (action) {
            .back => .{ .model_changed = try self.model.back() },
            .forward => .{ .model_changed = try self.model.forward() },
            .up => .{ .model_changed = try self.model.up() },
            .refresh => blk: {
                try self.model.refresh();
                break :blk .{ .model_changed = true };
            },
            .home => blk: {
                try self.model.navigate("/", true);
                break :blk .{ .model_changed = true };
            },
            .quit => .{ .quit = true },
        };
    }
};
