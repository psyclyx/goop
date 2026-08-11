//! Public package surface for the file-manager example.
//!
//! Importing the example through this root keeps all seams on one Zig module
//! graph, so state and capability types have one identity for every consumer.

pub const state = @import("state.zig");
pub const capabilities = @import("capabilities.zig");
pub const controller = @import("controller.zig");
pub const view = @import("view.zig");
pub const projection = @import("projection.zig");
pub const ids = @import("ids.zig");
pub const commands = @import("commands.zig");
pub const model = @import("model.zig");
pub const presentation = @import("presentation.zig");
pub const format = @import("format.zig");
pub const virtualization = @import("virtualization.zig");
pub const detail_text = @import("detail_text.zig");
pub const filesystem = @import("fs.zig");
pub const preview = @import("preview.zig");
pub const style = @import("style.zig");
pub const transfer = @import("transfer.zig");
pub const types = @import("types.zig");

test {
    _ = controller;
    _ = view;
    _ = @import("browser_test.zig");
}
