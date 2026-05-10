const std = @import("std");
const style = @import("style.zig");
const draw = @import("draw.zig");

/// Handle to a widget node. Carries an index into the tree's node array
/// and a generation counter for stale-handle detection.
pub const NodeHandle = struct {
    index: u32,
    generation: u32,

    /// Two handles are equal iff both index and generation match.
    pub fn eql(a: NodeHandle, b: NodeHandle) bool {
        return a.index == b.index and a.generation == b.generation;
    }
};

/// Drag state shared by widget kinds that participate in pointer-driven
/// reordering (tree items, selectables, grid items, table rows). All
/// fields are owned and reset by the dispatch layer; embedders only
/// observe `active` (via `WidgetView.<kind>.dragging`).
pub const DragState = struct {
    active: bool = false,
    rect: draw.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    offset_x: f32 = 0,
    offset_y: f32 = 0,
};

/// Interaction state tracked per widget.
pub const InteractionState = struct {
    hovered: bool = false,
    pressed: bool = false,
    focused: bool = false,
    accepts_drop: bool = false,
    drop_hovered: bool = false,
    drop_received: bool = false,
    primary_clicked: bool = false,
    secondary_clicked: bool = false,
};

/// Widget-specific data.
pub const WidgetKind = union(enum) {
    container: Container,
    text: Text,
    button: Button,
    checkbox: Checkbox,
    radio_button: RadioButton,
    tree_item: TreeItem,
    dropdown: Dropdown,
    list_box: ListBox,
    selectable: Selectable,
    grid_selector: GridSelector,
    grid_item: GridItem,
    table: Table,
    table_row: TableRow,
    table_cell: TableCell,
    toolbar: Toolbar,
    status_bar: StatusBar,
    menu_bar: MenuBar,
    menu: Menu,
    popup: Popup,
    tooltip: Tooltip,
    menu_item: MenuItem,
    drag_value: DragValue,
    spinbox: SpinBox,
    tab_bar: TabBar,
    tab_item: TabItem,
    splitter: Splitter,
    slider: Slider,
    spacer: Spacer,
    scroll_area: ScrollArea,
    text_input: TextInput,

    pub const Container = struct {
        direction: Direction = .column,

        pub const Direction = enum { row, column };
    };

    pub const Text = struct {
        content: []const u8,
        overflow: draw.TextOverflow = .visible,
    };

    pub const Button = struct {
        label: []const u8,
        clicked: bool = false,
    };

    pub const Checkbox = struct {
        label: []const u8,
        checked: bool = false,
        clicked: bool = false,
    };

    pub const RadioButton = struct {
        label: []const u8,
        group: u32,
        selected: bool = false,
        clicked: bool = false,
    };

    pub const TreeItem = struct {
        label: []const u8,
        group: u32 = 0,
        icon: ?draw.IconId = null,
        icon_color: ?style.Color = null,
        editable: bool = false,
        rename_trigger: RenameTrigger = .none,
        has_children: bool = false,
        expanded: bool = true,
        selected: bool = false,
        editing: bool = false,
        clicked: bool = false,
        toggled: bool = false,
        drag: DragState = .{},
        drop_preview: ?DropPosition = null,
        drop_received: bool = false,
        rename_committed: bool = false,
        editor: TextInput = .{},

        pub const RenameTrigger = enum {
            none,
            selected_click,
            double_click,
        };

        pub const DropPosition = enum {
            before,
            into,
            after,
        };

        pub fn displayLabel(self: *const TreeItem) []const u8 {
            return if (self.editing) self.editor.content() else self.label;
        }

        pub fn beginRename(self: *TreeItem) void {
            self.editor = .{};
            self.editor.insertSlice(self.label);
            self.editor.selection_anchor = 0;
            self.editor.cursor = self.editor.len;
            self.rename_committed = false;
            self.editing = true;
        }

        pub fn cancelRename(self: *TreeItem) void {
            self.editor = .{};
            self.rename_committed = false;
            self.editing = false;
        }

        pub fn commitRename(self: *TreeItem) void {
            self.label = self.editor.content();
            self.rename_committed = true;
            self.editing = false;
        }
    };

    pub const Dropdown = struct {
        placeholder: []const u8 = "Select...",
        selected_text: []const u8 = "",
        selected_index: ?u16 = null,
        open: bool = false,
        clicked: bool = false,
        changed: bool = false,
    };

    pub const ListBox = struct {
        selection_mode: SelectionMode = .single,
        anchor_index: ?u16 = null,
        changed: bool = false,
        marquee_active: bool = false,
        marquee_rect: draw.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        drop_preview_background: bool = false,

        pub const SelectionMode = enum {
            single,
            multiple,
        };
    };

    pub const Selectable = struct {
        label: []const u8,
        group: u32 = 0,
        selected: bool = false,
        clicked: bool = false,
        marquee_base_selected: bool = false,
        drag: DragState = .{},
        drop_preview: bool = false,
    };

    pub const GridSelector = struct {
        selection_mode: ListBox.SelectionMode = .single,
        item_width: f32 = 96,
        item_height: f32 = 96,
        column_gap: f32 = 8,
        row_gap: f32 = 8,
        anchor_index: ?u16 = null,
        changed: bool = false,
        computed_columns: u16 = 1,
        content_height: f32 = 0,
        marquee_active: bool = false,
        marquee_rect: draw.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        drop_preview_background: bool = false,

        pub fn layoutHeight(self: *const GridSelector, padding: style.Edges) f32 {
            if (self.content_height > 0) return self.content_height;
            return padding.top + padding.bottom + @max(self.item_height, 1);
        }
    };

    pub const GridItem = struct {
        label: []const u8,
        icon: []const u8 = "",
        selected: bool = false,
        clicked: bool = false,
        marquee_base_selected: bool = false,
        drag: DragState = .{},
        drop_preview: bool = false,
    };

    pub const Table = struct {
        pub const max_columns: usize = 32;
        pub const resize_handle_width: f32 = 8;
        pub const resize_grip_width: f32 = 2;
        pub const resize_grip_height: f32 = 12;

        columns: u8 = 0,
        striped: bool = true,
        resizable: bool = false,
        sortable: bool = false,
        selection_mode: SelectionMode = .none,
        min_column_width: f32 = 96,
        changed: bool = false,
        resized_column: ?u8 = null,
        sort_changed: bool = false,
        sorted_column: ?u8 = null,
        sort_direction: SortDirection = .ascending,
        selection_changed: bool = false,
        anchor_row: ?u16 = null,
        marquee_active: bool = false,
        marquee_rect: draw.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        drop_preview_background: bool = false,
        active_columns: u8 = 0,
        column_weights: [max_columns]f32 = [_]f32{0} ** max_columns,

        pub const SortDirection = enum {
            ascending,
            descending,
        };

        pub const SelectionMode = enum {
            none,
            single,
            multiple,
        };

        pub fn syncColumns(self: *Table, columns: u8) void {
            const clamped: u8 = @intCast(@min(@as(usize, columns), max_columns));
            if (clamped == 0) {
                self.active_columns = 0;
                self.sorted_column = null;
                self.anchor_row = null;
                @memset(&self.column_weights, 0);
                return;
            }

            var sum: f32 = 0;
            var reset = self.active_columns != clamped;
            if (!reset) {
                for (self.column_weights[0..clamped]) |weight| {
                    if (!std.math.isFinite(weight) or weight <= 0) {
                        reset = true;
                        break;
                    }
                    sum += weight;
                }
                if (sum <= 0.0001) reset = true;
            }

            self.active_columns = clamped;
            if (self.sorted_column) |sorted| {
                if (sorted >= clamped) self.sorted_column = null;
            }
            @memset(self.column_weights[clamped..], 0);

            if (reset) {
                const equal = 1.0 / @as(f32, @floatFromInt(clamped));
                for (self.column_weights[0..clamped]) |*weight| weight.* = equal;
                return;
            }

            if (@abs(sum - 1.0) > 0.0001) {
                for (self.column_weights[0..clamped]) |*weight| weight.* /= sum;
            }
        }

        pub fn columnWeight(self: *const Table, index: usize) ?f32 {
            if (index >= self.active_columns) return null;
            return self.column_weights[index];
        }

        pub fn resizeColumns(
            self: *Table,
            divider_index: u8,
            total_width: f32,
            origin_left_width: f32,
            origin_right_width: f32,
            delta_px: f32,
        ) bool {
            if (divider_index + 1 >= self.active_columns or total_width <= 0) return false;

            const pair_total = origin_left_width + origin_right_width;
            if (pair_total <= 0) return false;

            const min_width = @min(self.min_column_width, pair_total * 0.5);
            const new_left = std.math.clamp(origin_left_width + delta_px, min_width, pair_total - min_width);
            if (@abs(new_left - origin_left_width) <= 0.01) return false;

            const new_right = pair_total - new_left;
            self.column_weights[divider_index] = new_left / total_width;
            self.column_weights[divider_index + 1] = new_right / total_width;
            self.changed = true;
            self.resized_column = divider_index;
            return true;
        }

        pub fn toggleSort(self: *Table, column: u8) bool {
            if (!self.sortable or column >= self.active_columns) return false;

            if (self.sorted_column) |sorted| {
                if (sorted == column) {
                    self.sort_direction = switch (self.sort_direction) {
                        .ascending => .descending,
                        .descending => .ascending,
                    };
                    self.sort_changed = true;
                    return true;
                }
            }

            self.sorted_column = column;
            self.sort_direction = .ascending;
            self.sort_changed = true;
            return true;
        }
    };

    pub const TableRow = struct {
        header: bool = false,
        selected: bool = false,
        marquee_base_selected: bool = false,
        drag: DragState = .{},
        drop_preview: bool = false,
    };

    pub const TableCell = struct {};

    pub const Toolbar = struct {};

    pub const StatusBar = struct {};

    pub const MenuBar = struct {};

    pub const Menu = struct {
        label: []const u8,
        clicked: bool = false,
    };

    pub const Popup = struct {
        placement: Placement = .absolute,
        x: f32 = 0,
        y: f32 = 0,
        visible: bool = true,
        close_on_outside_click: bool = true,
        z_index: i16 = 100,
        pointer_passthrough: bool = false,

        pub const Placement = enum {
            absolute,
            below_start,
            below_end,
            right_start,
        };
    };

    pub const Tooltip = struct {
        placement: Popup.Placement = .below_start,
        x: f32 = 0,
        y: f32 = 0,
        z_index: i16 = 120,
    };

    pub const MenuItem = struct {
        label: []const u8,
        shortcut: []const u8 = "",
        checked: bool = false,
        disabled: bool = false,
        clicked: bool = false,
    };

    pub const DragValue = struct {
        value: f32 = 0,
        min: f32 = -1000000,
        max: f32 = 1000000,
        speed: f32 = 0.1,
        precision: u8 = 2,
        changed: bool = false,
        editing: bool = false,
        label_buf: [64]u8 = [_]u8{0} ** 64,
        label_len: u8 = 0,
        editor: TextInput = .{},

        pub fn displayValue(self: *const DragValue) []const u8 {
            return self.label_buf[0..self.label_len];
        }

        pub fn syncLabel(self: *DragValue) void {
            const label = formatScalarLabel(&self.label_buf, self.value, self.precision);
            self.label_len = @intCast(label.len);
        }

        pub fn beginEdit(self: *DragValue) void {
            self.editor = .{};
            self.editor.insertSlice(self.displayValue());
            self.editor.selection_anchor = 0;
            self.editor.cursor = self.editor.len;
            self.editing = true;
        }

        pub fn cancelEdit(self: *DragValue) void {
            self.editor = .{};
            self.editing = false;
        }

        pub fn commitEdit(self: *DragValue) bool {
            const next_value = std.fmt.parseFloat(f32, self.editor.content()) catch return false;
            const clamped = std.math.clamp(next_value, self.min, self.max);
            if (clamped != self.value) {
                self.value = clamped;
                self.changed = true;
            }
            self.syncLabel();
            self.editing = false;
            return true;
        }
    };

    pub const SpinBox = struct {
        value: f32 = 0,
        min: f32 = -1000000,
        max: f32 = 1000000,
        step: f32 = 1,
        precision: u8 = 2,
        changed: bool = false,
        editing: bool = false,
        label_buf: [64]u8 = [_]u8{0} ** 64,
        label_len: u8 = 0,
        editor: TextInput = .{},

        pub fn displayValue(self: *const SpinBox) []const u8 {
            return self.label_buf[0..self.label_len];
        }

        pub fn syncLabel(self: *SpinBox) void {
            const label = formatScalarLabel(&self.label_buf, self.value, self.precision);
            self.label_len = @intCast(label.len);
        }

        pub fn beginEdit(self: *SpinBox) void {
            self.editor = .{};
            self.editor.insertSlice(self.displayValue());
            self.editor.selection_anchor = 0;
            self.editor.cursor = self.editor.len;
            self.editing = true;
        }

        pub fn cancelEdit(self: *SpinBox) void {
            self.editor = .{};
            self.editing = false;
        }

        pub fn commitEdit(self: *SpinBox) bool {
            const next_value = std.fmt.parseFloat(f32, self.editor.content()) catch return false;
            const clamped = std.math.clamp(next_value, self.min, self.max);
            if (clamped != self.value) {
                self.value = clamped;
                self.changed = true;
            }
            self.syncLabel();
            self.editing = false;
            return true;
        }
    };

    pub const TabBar = struct {};

    pub const TabItem = struct {
        label: []const u8,
        selected: bool = false,
        clicked: bool = false,
    };

    pub const Splitter = struct {
        direction: Container.Direction = .row,
        ratio: f32 = 0.5,
        min_first: f32 = 120,
        min_second: f32 = 120,
        thickness: f32 = 6,
        gap_thickness: f32 = 1,
        keyboard_step: f32 = 0.02,
        changed: bool = false,
    };

    pub const Slider = struct {
        value: f32 = 0,
        min: f32 = 0,
        max: f32 = 1,
    };

    pub const ScrollArea = struct {
        scroll_x: f32 = 0,
        scroll_y: f32 = 0,
        disable_horizontal_scroll: bool = false,
        disable_vertical_scroll: bool = false,

        pub fn effectiveScrollX(self: ScrollArea) f32 {
            return if (self.disable_horizontal_scroll) 0 else self.scroll_x;
        }

        pub fn effectiveScrollY(self: ScrollArea) f32 {
            return if (self.disable_vertical_scroll) 0 else self.scroll_y;
        }
    };

    pub const Spacer = struct {
        width: f32 = 0,
        height: f32 = 0,
    };

    pub const TextInput = struct {
        buffer: [256]u8 = [_]u8{0} ** 256,
        len: u8 = 0,
        cursor: u8 = 0,
        selection_anchor: ?u8 = null,
        placeholder: []const u8 = "",

        pub fn content(self: *const TextInput) []const u8 {
            return self.buffer[0..self.len];
        }

        pub fn hasSelection(self: *const TextInput) bool {
            if (self.selection_anchor) |anchor| {
                return anchor != self.cursor;
            }
            return false;
        }

        pub fn selectionRange(self: *const TextInput) struct { start: u8, end: u8 } {
            const anchor = self.selection_anchor orelse self.cursor;
            return if (anchor < self.cursor)
                .{ .start = anchor, .end = self.cursor }
            else
                .{ .start = self.cursor, .end = anchor };
        }

        pub fn selectedContent(self: *const TextInput) []const u8 {
            const range = self.selectionRange();
            return self.buffer[range.start..range.end];
        }

        pub fn deleteSelection(self: *TextInput) void {
            const range = self.selectionRange();
            self.deleteRange(range.start, range.end);
        }

        pub fn clearSelection(self: *TextInput) void {
            self.selection_anchor = null;
        }

        pub fn deleteRange(self: *TextInput, start: u8, end: u8) void {
            if (start >= end) return;
            const count: usize = end - start;
            std.mem.copyForwards(u8, self.buffer[start .. self.len - @as(u8, @intCast(count))], self.buffer[end..self.len]);
            self.len -= @intCast(count);
            self.cursor = start;
            self.clearSelection();
        }

        pub fn insert(self: *TextInput, byte: u8) void {
            self.insertCodepoint(byte);
        }

        pub fn insertCodepoint(self: *TextInput, codepoint: u21) void {
            if (!std.unicode.utf8ValidCodepoint(codepoint)) return;
            var encoded: [4]u8 = undefined;
            const encoded_len = std.unicode.utf8Encode(codepoint, &encoded) catch return;
            self.insertSlice(encoded[0..encoded_len]);
        }

        pub fn insertSlice(self: *TextInput, text: []const u8) void {
            if (self.hasSelection()) self.deleteSelection();
            const available: usize = self.buffer.len - self.len;
            const count = insertableUtf8PrefixLen(text, available);
            if (count == 0) return;
            std.mem.copyBackwards(u8, self.buffer[self.cursor + @as(u8, @intCast(count)) .. self.len + @as(u8, @intCast(count))], self.buffer[self.cursor..self.len]);
            @memcpy(self.buffer[self.cursor .. self.cursor + count], text[0..count]);
            self.len += @intCast(count);
            self.cursor += @intCast(count);
            self.clearSelection();
        }

        pub fn deleteBack(self: *TextInput) void {
            if (self.hasSelection()) {
                self.deleteSelection();
                return;
            }
            if (self.cursor == 0) return;
            const start = self.prevCodepointBoundary(self.cursor);
            self.deleteRange(start, self.cursor);
        }

        pub fn prevCodepointBoundary(self: *const TextInput, pos: u8) u8 {
            if (pos == 0) return 0;
            var i: usize = @min(pos, self.len) - 1;
            while (i > 0 and isContinuationByte(self.buffer[i])) : (i -= 1) {}
            return @intCast(i);
        }

        pub fn nextCodepointBoundary(self: *const TextInput, pos: u8) u8 {
            if (pos >= self.len) return self.len;
            const start = self.clampToCodepointBoundary(pos);
            const seq_len = std.unicode.utf8ByteSequenceLength(self.buffer[start]) catch 1;
            return @intCast(@min(@as(usize, self.len), @as(usize, start) + seq_len));
        }

        pub fn clampToCodepointBoundary(self: *const TextInput, pos: u8) u8 {
            var i: usize = @min(pos, self.len);
            while (i > 0 and i < self.len and isContinuationByte(self.buffer[i])) : (i -= 1) {}
            return @intCast(i);
        }

        pub fn prevWordBoundary(self: *const TextInput, pos: u8) u8 {
            if (pos == 0 or self.len == 0) return 0;

            var boundary = self.clampToCodepointBoundary(pos);

            while (boundary > 0) {
                const previous = self.prevCodepointBoundary(boundary);
                if (charClass(codepointAt(self, previous)) != .space) break;
                boundary = previous;
            }
            if (boundary == 0) return 0;

            var start = self.prevCodepointBoundary(boundary);
            const cls = charClass(codepointAt(self, start));
            while (start > 0) {
                const previous = self.prevCodepointBoundary(start);
                if (charClass(codepointAt(self, previous)) != cls) break;
                start = previous;
            }

            return start;
        }

        pub fn nextWordBoundary(self: *const TextInput, pos: u8) u8 {
            var boundary = self.clampToCodepointBoundary(pos);
            if (boundary >= self.len) return self.len;

            while (boundary < self.len and charClass(codepointAt(self, boundary)) == .space) {
                boundary = self.nextCodepointBoundary(boundary);
            }
            if (boundary >= self.len) return self.len;

            const cls = charClass(codepointAt(self, boundary));
            while (boundary < self.len and charClass(codepointAt(self, boundary)) == cls) {
                boundary = self.nextCodepointBoundary(boundary);
            }

            return boundary;
        }

        pub fn deleteBackWord(self: *TextInput) void {
            if (self.hasSelection()) {
                self.deleteSelection();
                return;
            }
            if (self.cursor == 0) return;
            const start = self.prevWordBoundary(self.cursor);
            self.deleteRange(start, self.cursor);
        }

        pub fn deleteForwardWord(self: *TextInput) void {
            if (self.hasSelection()) {
                self.deleteSelection();
                return;
            }
            if (self.cursor >= self.len) return;
            const end = self.nextWordBoundary(self.cursor);
            self.deleteRange(self.cursor, end);
        }

        /// Find the word boundaries around the given position.
        /// Words are runs of alphanumeric/underscore characters.
        pub fn wordBounds(self: *const TextInput, pos: u8) struct { start: u8, end: u8 } {
            if (self.len == 0) return .{ .start = 0, .end = 0 };
            var start = if (pos >= self.len) self.prevCodepointBoundary(self.len) else self.clampToCodepointBoundary(pos);
            const cls = charClass(codepointAt(self, start));

            while (start > 0) {
                const previous = self.prevCodepointBoundary(start);
                if (charClass(codepointAt(self, previous)) != cls) break;
                start = previous;
            }

            var end = self.nextCodepointBoundary(start);
            while (end < self.len) {
                if (charClass(codepointAt(self, end)) != cls) break;
                end = self.nextCodepointBoundary(end);
            }

            return .{ .start = start, .end = end };
        }

        fn isWordChar(codepoint: u21) bool {
            if (codepoint < 128) {
                const c: u8 = @intCast(codepoint);
                return std.ascii.isAlphanumeric(c) or c == '_';
            }
            return true;
        }

        const CharClass = enum { word, space, other };

        fn charClass(codepoint: u21) CharClass {
            if (isWhitespaceCodepoint(codepoint)) return .space;
            if (isWordChar(codepoint)) return .word;
            return .other;
        }

        pub fn deleteForward(self: *TextInput) void {
            if (self.hasSelection()) {
                self.deleteSelection();
                return;
            }
            if (self.cursor >= self.len) return;
            const end = self.nextCodepointBoundary(self.cursor);
            self.deleteRange(self.cursor, end);
        }

        fn codepointAt(self: *const TextInput, start: u8) u21 {
            if (start >= self.len) return 0;
            const seq_len = std.unicode.utf8ByteSequenceLength(self.buffer[start]) catch 1;
            const end = @min(@as(usize, self.len), @as(usize, start) + seq_len);
            return std.unicode.utf8Decode(self.buffer[start..end]) catch self.buffer[start];
        }

        fn isContinuationByte(byte: u8) bool {
            return (byte & 0b1100_0000) == 0b1000_0000;
        }

        fn isWhitespaceCodepoint(codepoint: u21) bool {
            return switch (codepoint) {
                ' ', '\t', '\n', '\r', 0x0B, 0x0C, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 => true,
                else => false,
            };
        }

        fn insertableUtf8PrefixLen(text: []const u8, available: usize) usize {
            if (available == 0 or text.len == 0) return 0;

            const view = std.unicode.Utf8View.init(text) catch return 0;
            var iter = view.iterator();
            var prefix_len: usize = 0;
            while (iter.nextCodepointSlice()) |slice| {
                if (prefix_len + slice.len > available) break;
                prefix_len += slice.len;
            }
            return prefix_len;
        }
    };
};

/// User-authored construction inputs for a widget node.
///
/// `WidgetDesc` is the type the embedder hands to `Tree.addRoot` and
/// `Tree.addChild`. It mirrors the shape of `WidgetKind` but contains
/// only the fields the embedder is responsible for: identifying data
/// (label, group), embedder-supplied configuration (min/max/precision,
/// item_width, etc.), and persistent input state the embedder controls
/// (checked, expanded, ratio, scroll position, etc.).
///
/// Per-frame interaction state (`clicked`, `toggled`, `changed`,
/// `dragging`, `editing`, drag rectangles, label buffers, marquee
/// state, and so on) is *not* part of `WidgetDesc` — goop owns those
/// fields and resets them each frame. Trying to set them at
/// construction time is a compile error.
pub const WidgetDesc = union(enum) {
    container: Container,
    text: Text,
    button: Button,
    checkbox: Checkbox,
    radio_button: RadioButton,
    tree_item: TreeItem,
    dropdown: Dropdown,
    list_box: ListBox,
    selectable: Selectable,
    grid_selector: GridSelector,
    grid_item: GridItem,
    table: Table,
    table_row: TableRow,
    table_cell: TableCell,
    toolbar: Toolbar,
    status_bar: StatusBar,
    menu_bar: MenuBar,
    menu: Menu,
    popup: Popup,
    tooltip: Tooltip,
    menu_item: MenuItem,
    drag_value: DragValue,
    spinbox: SpinBox,
    tab_bar: TabBar,
    tab_item: TabItem,
    splitter: Splitter,
    slider: Slider,
    spacer: Spacer,
    scroll_area: ScrollArea,
    text_input: TextInput,

    pub const Container = struct {
        direction: WidgetKind.Container.Direction = .column,
    };

    pub const Text = struct {
        content: []const u8,
        overflow: draw.TextOverflow = .visible,
    };

    pub const Button = struct {
        label: []const u8,
    };

    pub const Checkbox = struct {
        label: []const u8,
        checked: bool = false,
    };

    pub const RadioButton = struct {
        label: []const u8,
        group: u32,
        selected: bool = false,
    };

    pub const TreeItem = struct {
        label: []const u8,
        group: u32 = 0,
        icon: ?draw.IconId = null,
        icon_color: ?style.Color = null,
        editable: bool = false,
        rename_trigger: WidgetKind.TreeItem.RenameTrigger = .none,
        has_children: bool = false,
        expanded: bool = true,
        selected: bool = false,
    };

    pub const Dropdown = struct {
        placeholder: []const u8 = "Select...",
        selected_text: []const u8 = "",
        selected_index: ?u16 = null,
        open: bool = false,
    };

    pub const ListBox = struct {
        selection_mode: WidgetKind.ListBox.SelectionMode = .single,
    };

    pub const Selectable = struct {
        label: []const u8,
        group: u32 = 0,
        selected: bool = false,
    };

    pub const GridSelector = struct {
        selection_mode: WidgetKind.ListBox.SelectionMode = .single,
        item_width: f32 = 96,
        item_height: f32 = 96,
        column_gap: f32 = 8,
        row_gap: f32 = 8,
    };

    pub const GridItem = struct {
        label: []const u8,
        icon: []const u8 = "",
        selected: bool = false,
    };

    pub const Table = struct {
        columns: u8 = 0,
        striped: bool = true,
        resizable: bool = false,
        sortable: bool = false,
        selection_mode: WidgetKind.Table.SelectionMode = .none,
        min_column_width: f32 = 96,
        sorted_column: ?u8 = null,
        sort_direction: WidgetKind.Table.SortDirection = .ascending,
    };

    pub const TableRow = struct {
        header: bool = false,
        selected: bool = false,
    };

    pub const TableCell = struct {};

    pub const Toolbar = struct {};

    pub const StatusBar = struct {};

    pub const MenuBar = struct {};

    pub const Menu = struct {
        label: []const u8,
    };

    pub const Popup = struct {
        placement: WidgetKind.Popup.Placement = .absolute,
        x: f32 = 0,
        y: f32 = 0,
        visible: bool = true,
        close_on_outside_click: bool = true,
        z_index: i16 = 100,
        pointer_passthrough: bool = false,
    };

    pub const Tooltip = struct {
        placement: WidgetKind.Popup.Placement = .below_start,
        x: f32 = 0,
        y: f32 = 0,
        z_index: i16 = 120,
    };

    pub const MenuItem = struct {
        label: []const u8,
        shortcut: []const u8 = "",
        checked: bool = false,
        disabled: bool = false,
    };

    pub const DragValue = struct {
        value: f32 = 0,
        min: f32 = -1000000,
        max: f32 = 1000000,
        speed: f32 = 0.1,
        precision: u8 = 2,
    };

    pub const SpinBox = struct {
        value: f32 = 0,
        min: f32 = -1000000,
        max: f32 = 1000000,
        step: f32 = 1,
        precision: u8 = 2,
    };

    pub const TabBar = struct {};

    pub const TabItem = struct {
        label: []const u8,
        selected: bool = false,
    };

    pub const Splitter = struct {
        direction: WidgetKind.Container.Direction = .row,
        ratio: f32 = 0.5,
        min_first: f32 = 120,
        min_second: f32 = 120,
        thickness: f32 = 6,
        gap_thickness: f32 = 1,
        keyboard_step: f32 = 0.02,
    };

    pub const Slider = struct {
        value: f32 = 0,
        min: f32 = 0,
        max: f32 = 1,
    };

    pub const Spacer = struct {
        width: f32 = 0,
        height: f32 = 0,
    };

    pub const ScrollArea = struct {
        scroll_x: f32 = 0,
        scroll_y: f32 = 0,
        disable_horizontal_scroll: bool = false,
        disable_vertical_scroll: bool = false,
    };

    pub const TextInput = struct {
        placeholder: []const u8 = "",
    };
};

/// Build a `WidgetKind` from a user-authored `WidgetDesc`. Copies the
/// embedder-supplied fields and leaves all per-frame state at its
/// default (zero/none/false). `Tree.addNode` calls `syncDerivedState`
/// after construction, so any state that is *derived* from desc input
/// (table column weights, drag-value labels) is filled in there.
pub fn kindFromDesc(desc: WidgetDesc) WidgetKind {
    return switch (desc) {
        .container => |d| .{ .container = .{ .direction = d.direction } },
        .text => |d| .{ .text = .{ .content = d.content, .overflow = d.overflow } },
        .button => |d| .{ .button = .{ .label = d.label } },
        .checkbox => |d| .{ .checkbox = .{ .label = d.label, .checked = d.checked } },
        .radio_button => |d| .{ .radio_button = .{
            .label = d.label,
            .group = d.group,
            .selected = d.selected,
        } },
        .tree_item => |d| .{ .tree_item = .{
            .label = d.label,
            .group = d.group,
            .icon = d.icon,
            .icon_color = d.icon_color,
            .editable = d.editable,
            .rename_trigger = d.rename_trigger,
            .has_children = d.has_children,
            .expanded = d.expanded,
            .selected = d.selected,
        } },
        .dropdown => |d| .{ .dropdown = .{
            .placeholder = d.placeholder,
            .selected_text = d.selected_text,
            .selected_index = d.selected_index,
            .open = d.open,
        } },
        .list_box => |d| .{ .list_box = .{ .selection_mode = d.selection_mode } },
        .selectable => |d| .{ .selectable = .{
            .label = d.label,
            .group = d.group,
            .selected = d.selected,
        } },
        .grid_selector => |d| .{ .grid_selector = .{
            .selection_mode = d.selection_mode,
            .item_width = d.item_width,
            .item_height = d.item_height,
            .column_gap = d.column_gap,
            .row_gap = d.row_gap,
        } },
        .grid_item => |d| .{ .grid_item = .{
            .label = d.label,
            .icon = d.icon,
            .selected = d.selected,
        } },
        .table => |d| .{ .table = .{
            .columns = d.columns,
            .striped = d.striped,
            .resizable = d.resizable,
            .sortable = d.sortable,
            .selection_mode = d.selection_mode,
            .min_column_width = d.min_column_width,
            .sorted_column = d.sorted_column,
            .sort_direction = d.sort_direction,
        } },
        .table_row => |d| .{ .table_row = .{ .header = d.header, .selected = d.selected } },
        .table_cell => .{ .table_cell = .{} },
        .toolbar => .{ .toolbar = .{} },
        .status_bar => .{ .status_bar = .{} },
        .menu_bar => .{ .menu_bar = .{} },
        .menu => |d| .{ .menu = .{ .label = d.label } },
        .popup => |d| .{ .popup = .{
            .placement = d.placement,
            .x = d.x,
            .y = d.y,
            .visible = d.visible,
            .close_on_outside_click = d.close_on_outside_click,
            .z_index = d.z_index,
            .pointer_passthrough = d.pointer_passthrough,
        } },
        .tooltip => |d| .{ .tooltip = .{
            .placement = d.placement,
            .x = d.x,
            .y = d.y,
            .z_index = d.z_index,
        } },
        .menu_item => |d| .{ .menu_item = .{
            .label = d.label,
            .shortcut = d.shortcut,
            .checked = d.checked,
            .disabled = d.disabled,
        } },
        .drag_value => |d| .{ .drag_value = .{
            .value = d.value,
            .min = d.min,
            .max = d.max,
            .speed = d.speed,
            .precision = d.precision,
        } },
        .spinbox => |d| .{ .spinbox = .{
            .value = d.value,
            .min = d.min,
            .max = d.max,
            .step = d.step,
            .precision = d.precision,
        } },
        .tab_bar => .{ .tab_bar = .{} },
        .tab_item => |d| .{ .tab_item = .{ .label = d.label, .selected = d.selected } },
        .splitter => |d| .{ .splitter = .{
            .direction = d.direction,
            .ratio = d.ratio,
            .min_first = d.min_first,
            .min_second = d.min_second,
            .thickness = d.thickness,
            .gap_thickness = d.gap_thickness,
            .keyboard_step = d.keyboard_step,
        } },
        .slider => |d| .{ .slider = .{ .value = d.value, .min = d.min, .max = d.max } },
        .spacer => |d| .{ .spacer = .{ .width = d.width, .height = d.height } },
        .scroll_area => |d| .{ .scroll_area = .{
            .scroll_x = d.scroll_x,
            .scroll_y = d.scroll_y,
            .disable_horizontal_scroll = d.disable_horizontal_scroll,
            .disable_vertical_scroll = d.disable_vertical_scroll,
        } },
        .text_input => |d| .{ .text_input = .{ .placeholder = d.placeholder } },
    };
}

/// Read-only projection of a widget node's per-kind state.
///
/// `WidgetView` is the supported way to query widget state from the
/// outside. It carries identifying fields, mutable interaction state
/// (value, selected, expanded, …), and one-frame flags (clicked,
/// changed, toggled, …). Pure configuration the embedder set at
/// construction (min/max/precision/min_first/etc) is intentionally
/// omitted — the embedder is the source of truth for that.
///
/// The view is built by `WidgetView.fromKind` and is a snapshot of the
/// kind data at one moment. Slices it carries (labels, content) point
/// into the tree's storage and stay valid until the next mutation that
/// touches the same widget.
pub const WidgetView = union(enum) {
    container: Container,
    text: Text,
    button: Button,
    checkbox: Checkbox,
    radio_button: RadioButton,
    tree_item: TreeItem,
    dropdown: Dropdown,
    list_box: ListBox,
    selectable: Selectable,
    grid_selector: GridSelector,
    grid_item: GridItem,
    table: Table,
    table_row: TableRow,
    table_cell: void,
    toolbar: void,
    status_bar: void,
    menu_bar: void,
    menu: Menu,
    popup: Popup,
    tooltip: Tooltip,
    menu_item: MenuItem,
    drag_value: DragValue,
    spinbox: SpinBox,
    tab_bar: void,
    tab_item: TabItem,
    splitter: Splitter,
    slider: Slider,
    spacer: void,
    scroll_area: ScrollArea,
    text_input: TextInput,

    pub const Container = struct { direction: WidgetKind.Container.Direction };

    pub const Text = struct { content: []const u8 };

    pub const Button = struct {
        label: []const u8,
        clicked: bool,
    };

    pub const Checkbox = struct {
        label: []const u8,
        checked: bool,
        clicked: bool,
    };

    pub const RadioButton = struct {
        label: []const u8,
        group: u32,
        selected: bool,
        clicked: bool,
    };

    pub const TreeItem = struct {
        label: []const u8,
        group: u32,
        has_children: bool,
        expanded: bool,
        selected: bool,
        editing: bool,
        clicked: bool,
        toggled: bool,
        dragging: bool,
        drop_received: bool,
        rename_committed: bool,
    };

    pub const Dropdown = struct {
        placeholder: []const u8,
        selected_text: []const u8,
        selected_index: ?u16,
        open: bool,
        clicked: bool,
        changed: bool,
    };

    pub const ListBox = struct { changed: bool };

    pub const Selectable = struct {
        label: []const u8,
        group: u32,
        selected: bool,
        clicked: bool,
        dragging: bool,
    };

    pub const GridSelector = struct {
        changed: bool,
        computed_columns: u16,
    };

    pub const GridItem = struct {
        label: []const u8,
        selected: bool,
        clicked: bool,
        dragging: bool,
    };

    pub const Table = struct {
        active_columns: u8,
        changed: bool,
        resized_column: ?u8,
        sorted_column: ?u8,
        sort_direction: WidgetKind.Table.SortDirection,
        sort_changed: bool,
        selection_changed: bool,
    };

    pub const TableRow = struct {
        header: bool,
        selected: bool,
        dragging: bool,
    };

    pub const Menu = struct {
        label: []const u8,
        clicked: bool,
    };

    pub const Popup = struct {
        placement: WidgetKind.Popup.Placement,
        x: f32,
        y: f32,
        visible: bool,
        z_index: i16,
    };

    pub const Tooltip = struct {
        placement: WidgetKind.Popup.Placement,
        x: f32,
        y: f32,
        z_index: i16,
    };

    pub const MenuItem = struct {
        label: []const u8,
        shortcut: []const u8,
        checked: bool,
        disabled: bool,
        clicked: bool,
    };

    pub const DragValue = struct {
        value: f32,
        changed: bool,
        editing: bool,
        display_text: []const u8,
    };

    pub const SpinBox = struct {
        value: f32,
        changed: bool,
        editing: bool,
        display_text: []const u8,
    };

    pub const TabItem = struct {
        label: []const u8,
        selected: bool,
        clicked: bool,
    };

    pub const Splitter = struct {
        ratio: f32,
        changed: bool,
    };

    pub const Slider = struct { value: f32 };

    pub const ScrollArea = struct {
        scroll_x: f32,
        scroll_y: f32,
    };

    pub const TextInput = struct {
        content: []const u8,
        cursor: u8,
        selection_anchor: ?u8,
    };

    pub fn fromKind(kind: *const WidgetKind) WidgetView {
        // We read fields through the `kind` pointer rather than via value
        // captures so that slices the view exposes (label, content, …)
        // borrow from the tree's storage and not a temporary copy.
        return switch (kind.*) {
            .container => .{ .container = .{ .direction = kind.container.direction } },
            .text => .{ .text = .{ .content = kind.text.content } },
            .button => .{ .button = .{ .label = kind.button.label, .clicked = kind.button.clicked } },
            .checkbox => .{ .checkbox = .{
                .label = kind.checkbox.label,
                .checked = kind.checkbox.checked,
                .clicked = kind.checkbox.clicked,
            } },
            .radio_button => .{ .radio_button = .{
                .label = kind.radio_button.label,
                .group = kind.radio_button.group,
                .selected = kind.radio_button.selected,
                .clicked = kind.radio_button.clicked,
            } },
            .tree_item => .{ .tree_item = .{
                .label = kind.tree_item.displayLabel(),
                .group = kind.tree_item.group,
                .has_children = kind.tree_item.has_children,
                .expanded = kind.tree_item.expanded,
                .selected = kind.tree_item.selected,
                .editing = kind.tree_item.editing,
                .clicked = kind.tree_item.clicked,
                .toggled = kind.tree_item.toggled,
                .dragging = kind.tree_item.drag.active,
                .drop_received = kind.tree_item.drop_received,
                .rename_committed = kind.tree_item.rename_committed,
            } },
            .dropdown => .{ .dropdown = .{
                .placeholder = kind.dropdown.placeholder,
                .selected_text = kind.dropdown.selected_text,
                .selected_index = kind.dropdown.selected_index,
                .open = kind.dropdown.open,
                .clicked = kind.dropdown.clicked,
                .changed = kind.dropdown.changed,
            } },
            .list_box => .{ .list_box = .{ .changed = kind.list_box.changed } },
            .selectable => .{ .selectable = .{
                .label = kind.selectable.label,
                .group = kind.selectable.group,
                .selected = kind.selectable.selected,
                .clicked = kind.selectable.clicked,
                .dragging = kind.selectable.drag.active,
            } },
            .grid_selector => .{ .grid_selector = .{
                .changed = kind.grid_selector.changed,
                .computed_columns = kind.grid_selector.computed_columns,
            } },
            .grid_item => .{ .grid_item = .{
                .label = kind.grid_item.label,
                .selected = kind.grid_item.selected,
                .clicked = kind.grid_item.clicked,
                .dragging = kind.grid_item.drag.active,
            } },
            .table => .{ .table = .{
                .active_columns = kind.table.active_columns,
                .changed = kind.table.changed,
                .resized_column = kind.table.resized_column,
                .sorted_column = kind.table.sorted_column,
                .sort_direction = kind.table.sort_direction,
                .sort_changed = kind.table.sort_changed,
                .selection_changed = kind.table.selection_changed,
            } },
            .table_row => .{ .table_row = .{
                .header = kind.table_row.header,
                .selected = kind.table_row.selected,
                .dragging = kind.table_row.drag.active,
            } },
            .table_cell => .{ .table_cell = {} },
            .toolbar => .{ .toolbar = {} },
            .status_bar => .{ .status_bar = {} },
            .menu_bar => .{ .menu_bar = {} },
            .menu => .{ .menu = .{ .label = kind.menu.label, .clicked = kind.menu.clicked } },
            .popup => .{ .popup = .{
                .placement = kind.popup.placement,
                .x = kind.popup.x,
                .y = kind.popup.y,
                .visible = kind.popup.visible,
                .z_index = kind.popup.z_index,
            } },
            .tooltip => .{ .tooltip = .{
                .placement = kind.tooltip.placement,
                .x = kind.tooltip.x,
                .y = kind.tooltip.y,
                .z_index = kind.tooltip.z_index,
            } },
            .menu_item => .{ .menu_item = .{
                .label = kind.menu_item.label,
                .shortcut = kind.menu_item.shortcut,
                .checked = kind.menu_item.checked,
                .disabled = kind.menu_item.disabled,
                .clicked = kind.menu_item.clicked,
            } },
            .drag_value => .{ .drag_value = .{
                .value = kind.drag_value.value,
                .changed = kind.drag_value.changed,
                .editing = kind.drag_value.editing,
                .display_text = kind.drag_value.displayValue(),
            } },
            .spinbox => .{ .spinbox = .{
                .value = kind.spinbox.value,
                .changed = kind.spinbox.changed,
                .editing = kind.spinbox.editing,
                .display_text = kind.spinbox.displayValue(),
            } },
            .tab_bar => .{ .tab_bar = {} },
            .tab_item => .{ .tab_item = .{
                .label = kind.tab_item.label,
                .selected = kind.tab_item.selected,
                .clicked = kind.tab_item.clicked,
            } },
            .splitter => .{ .splitter = .{ .ratio = kind.splitter.ratio, .changed = kind.splitter.changed } },
            .slider => .{ .slider = .{ .value = kind.slider.value } },
            .spacer => .{ .spacer = {} },
            .scroll_area => .{ .scroll_area = .{
                .scroll_x = kind.scroll_area.scroll_x,
                .scroll_y = kind.scroll_area.scroll_y,
            } },
            .text_input => .{ .text_input = .{
                .content = kind.text_input.content(),
                .cursor = kind.text_input.cursor,
                .selection_anchor = kind.text_input.selection_anchor,
            } },
        };
    }
};

/// A single node in the widget tree.
pub const Node = struct {
    kind: WidgetKind,
    style_override: style.Style = .{},
    interaction: InteractionState = .{},
    user_id: u64 = 0,
    layout_rect: draw.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    custom_draw: bool = false,

    parent: ?NodeHandle = null,
    first_child: ?NodeHandle = null,
    last_child: ?NodeHandle = null,
    next_sibling: ?NodeHandle = null,
    prev_sibling: ?NodeHandle = null,

    generation: u32 = 0,
    alive: bool = true,
};

/// The retained widget tree.
pub const Tree = struct {
    nodes: std.ArrayListUnmanaged(Node) = .empty,
    free_list: std.ArrayListUnmanaged(u32) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Tree {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Tree) void {
        self.free_list.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
    }

    /// Add a root-level widget. Returns its handle.
    pub fn addRoot(self: *Tree, desc: WidgetDesc) !NodeHandle {
        return self.addNode(kindFromDesc(desc), null);
    }

    /// Add a child widget under the given parent. Returns its handle.
    pub fn addChild(self: *Tree, parent: NodeHandle, desc: WidgetDesc) !NodeHandle {
        return self.addNode(kindFromDesc(desc), parent);
    }

    /// Remove a node and all its descendants from the tree.
    /// The handle becomes invalid after this call.
    pub fn remove(self: *Tree, handle: NodeHandle) !void {
        const node = self.getMut(handle);

        // Recursively remove children first
        var child = node.first_child;
        while (child) |ch| {
            const next = self.nodes.items[ch.index].next_sibling;
            try self.remove(ch);
            child = next;
        }

        // Unlink from parent's child list
        if (node.parent) |ph| {
            const parent = &self.nodes.items[ph.index];
            if (parent.first_child) |fc| {
                if (fc.eql(handle)) {
                    parent.first_child = node.next_sibling;
                }
            }
            if (parent.last_child) |lc| {
                if (lc.eql(handle)) {
                    parent.last_child = node.prev_sibling;
                }
            }
        }

        // Unlink from sibling chain
        if (node.prev_sibling) |prev| {
            self.nodes.items[prev.index].next_sibling = node.next_sibling;
        }
        if (node.next_sibling) |nxt| {
            self.nodes.items[nxt.index].prev_sibling = node.prev_sibling;
        }

        // Mark dead, bump generation, push to free list
        node.alive = false;
        node.generation +%= 1;
        node.parent = null;
        node.first_child = null;
        node.last_child = null;
        node.next_sibling = null;
        node.prev_sibling = null;
        try self.free_list.append(self.allocator, handle.index);
    }

    /// Get a pointer to a node by handle.
    /// Asserts the handle is valid (generation matches and node is alive).
    pub fn get(self: *Tree, handle: NodeHandle) *Node {
        const node = &self.nodes.items[handle.index];
        std.debug.assert(node.alive and node.generation == handle.generation);
        return node;
    }

    /// Get a const pointer to a node by handle.
    pub fn getConst(self: *const Tree, handle: NodeHandle) *const Node {
        const node = &self.nodes.items[handle.index];
        std.debug.assert(node.alive and node.generation == handle.generation);
        return node;
    }

    /// Check whether a handle refers to a living node.
    pub fn isAlive(self: *const Tree, handle: NodeHandle) bool {
        if (handle.index >= self.nodes.items.len) return false;
        const node = &self.nodes.items[handle.index];
        return node.alive and node.generation == handle.generation;
    }

    /// Build a handle for a live node at the given index.
    /// Used by modules that iterate nodes by index.
    pub fn handleFromIndex(self: *const Tree, index: u32) NodeHandle {
        return .{ .index = index, .generation = self.nodes.items[index].generation };
    }

    /// Number of live nodes in the tree.
    pub fn count(self: *const Tree) u32 {
        return @as(u32, @intCast(self.nodes.items.len)) - @as(u32, @intCast(self.free_list.items.len));
    }

    /// Total number of slots (live + dead). Used for layout dirty checks.
    pub fn slotCount(self: *const Tree) u32 {
        return @intCast(self.nodes.items.len);
    }

    /// Iterate children of a node.
    pub fn children(self: *const Tree, parent: NodeHandle) ChildIterator {
        return .{
            .tree = self,
            .current = self.getConst(parent).first_child,
        };
    }

    fn addNode(self: *Tree, kind: WidgetKind, parent_handle: ?NodeHandle) !NodeHandle {
        var index: u32 = undefined;
        var generation: u32 = undefined;

        if (self.free_list.pop()) |reuse_index| {
            // Reuse a dead slot
            index = reuse_index;
            generation = self.nodes.items[index].generation;
            self.nodes.items[index] = .{
                .kind = kind,
                .parent = parent_handle,
                .generation = generation,
            };
        } else {
            // Append new slot
            index = @intCast(self.nodes.items.len);
            generation = 0;
            try self.nodes.append(self.allocator, .{
                .kind = kind,
                .parent = parent_handle,
            });
        }

        syncDerivedState(&self.nodes.items[index].kind);

        const handle: NodeHandle = .{ .index = index, .generation = generation };

        if (parent_handle) |ph| {
            const parent = self.get(ph);
            if (parent.last_child) |last| {
                self.nodes.items[last.index].next_sibling = handle;
                self.nodes.items[index].prev_sibling = last;
            } else {
                parent.first_child = handle;
            }
            parent.last_child = handle;
        }

        return handle;
    }

    /// Internal: get a mutable pointer without generation check (for remove).
    fn getMut(self: *Tree, handle: NodeHandle) *Node {
        const node = &self.nodes.items[handle.index];
        std.debug.assert(node.alive and node.generation == handle.generation);
        return node;
    }

    pub const ChildIterator = struct {
        tree: *const Tree,
        current: ?NodeHandle,

        pub fn next(self: *ChildIterator) ?NodeHandle {
            const cur = self.current orelse return null;
            self.current = self.tree.getConst(cur).next_sibling;
            return cur;
        }
    };
};

pub fn tableEffectiveColumnCount(tree: *const Tree, table: NodeHandle) u16 {
    const node = tree.getConst(table);
    std.debug.assert(node.kind == .table);

    var count: u16 = @as(u16, node.kind.table.columns);
    var iter = tree.children(table);
    while (iter.next()) |child| {
        if (tree.getConst(child).kind != .table_row) continue;
        count = @max(count, tableRowCellCount(tree, child));
    }
    return @max(count, 1);
}

pub fn gridSelectorItemCount(tree: *const Tree, selector: NodeHandle) u16 {
    var count: u16 = 0;
    var iter = tree.children(selector);
    while (iter.next()) |child| {
        if (tree.getConst(child).kind == .grid_item) count += 1;
    }
    return count;
}

pub fn gridItemAt(tree: *const Tree, selector: NodeHandle, index: u16) ?NodeHandle {
    var current_index: u16 = 0;
    var iter = tree.children(selector);
    while (iter.next()) |child| {
        if (tree.getConst(child).kind != .grid_item) continue;
        if (current_index == index) return child;
        current_index += 1;
    }
    return null;
}

pub fn gridItemParentSelector(tree: *const Tree, item: NodeHandle) ?NodeHandle {
    const parent_handle = tree.getConst(item).parent orelse return null;
    if (tree.getConst(parent_handle).kind != .grid_selector) return null;
    return parent_handle;
}

pub fn gridItemIndex(tree: *const Tree, item: NodeHandle) ?u16 {
    const selector = gridItemParentSelector(tree, item) orelse return null;
    var index: u16 = 0;
    var iter = tree.children(selector);
    while (iter.next()) |child| {
        if (tree.getConst(child).kind != .grid_item) continue;
        if (child.eql(item)) return index;
        index += 1;
    }
    return null;
}

pub fn tableRowCellCount(tree: *const Tree, row: NodeHandle) u16 {
    var count: u16 = 0;
    var iter = tree.children(row);
    while (iter.next()) |child| {
        if (tree.getConst(child).kind == .table_cell) count += 1;
    }
    return count;
}

pub fn tableCellAt(tree: *const Tree, row: NodeHandle, index: usize) ?NodeHandle {
    var current_index: usize = 0;
    var iter = tree.children(row);
    while (iter.next()) |child| {
        if (tree.getConst(child).kind != .table_cell) continue;
        if (current_index == index) return child;
        current_index += 1;
    }
    return null;
}

pub fn tableReferenceRow(tree: *const Tree, table: NodeHandle) ?NodeHandle {
    var best: ?NodeHandle = null;
    var best_is_header = false;
    var best_cell_count: u16 = 0;

    var iter = tree.children(table);
    while (iter.next()) |child| {
        const node = tree.getConst(child);
        if (node.kind != .table_row) continue;

        const cell_count = tableRowCellCount(tree, child);
        if (cell_count == 0) continue;

        const is_header = node.kind.table_row.header;
        if (best == null or (is_header and !best_is_header) or (is_header == best_is_header and cell_count > best_cell_count)) {
            best = child;
            best_is_header = is_header;
            best_cell_count = cell_count;
        }
    }

    return best;
}

pub fn tableHeaderRow(tree: *const Tree, table: NodeHandle) ?NodeHandle {
    var best: ?NodeHandle = null;
    var best_cell_count: u16 = 0;

    var iter = tree.children(table);
    while (iter.next()) |child| {
        const node = tree.getConst(child);
        if (node.kind != .table_row or !node.kind.table_row.header) continue;

        const cell_count = tableRowCellCount(tree, child);
        if (cell_count == 0) continue;
        if (best == null or cell_count > best_cell_count) {
            best = child;
            best_cell_count = cell_count;
        }
    }

    return best;
}

pub fn tableResizeHandleRect(tree: *const Tree, table: NodeHandle, divider_index: u8) ?draw.Rect {
    const node = tree.getConst(table);
    if (node.kind != .table or !node.kind.table.resizable) return null;

    const row = tableReferenceRow(tree, table) orelse return null;
    const left = tableCellAt(tree, row, divider_index) orelse return null;
    _ = tableCellAt(tree, row, divider_index + 1) orelse return null;

    const left_rect = tree.getConst(left).layout_rect;
    if (left_rect.w <= 0 or left_rect.h <= 0) return null;

    const row_rect = tree.getConst(row).layout_rect;
    return .{
        .x = left_rect.x + left_rect.w - WidgetKind.Table.resize_handle_width * 0.5,
        .y = row_rect.y,
        .w = WidgetKind.Table.resize_handle_width,
        .h = row_rect.h,
    };
}

pub fn tableResizeHandleIndexAtPoint(tree: *const Tree, table: NodeHandle, x: f32, y: f32) ?u8 {
    const node = tree.getConst(table);
    if (node.kind != .table or !node.kind.table.resizable or node.kind.table.active_columns < 2) return null;

    var index: u8 = 0;
    while (index + 1 < node.kind.table.active_columns) : (index += 1) {
        const rect = tableResizeHandleRect(tree, table, index) orelse continue;
        if (x >= rect.x and x < rect.x + rect.w and y >= rect.y and y < rect.y + rect.h) return index;
    }
    return null;
}

pub fn tableHeaderCellIndexAtPoint(tree: *const Tree, table: NodeHandle, x: f32, y: f32) ?u8 {
    const node = tree.getConst(table);
    if (node.kind != .table or !node.kind.table.sortable) return null;
    if (tableResizeHandleIndexAtPoint(tree, table, x, y) != null) return null;

    const row = tableHeaderRow(tree, table) orelse return null;
    const row_rect = tree.getConst(row).layout_rect;
    if (!(x >= row_rect.x and x < row_rect.x + row_rect.w and y >= row_rect.y and y < row_rect.y + row_rect.h)) return null;

    var index: u8 = 0;
    while (index < node.kind.table.active_columns) : (index += 1) {
        const cell = tableCellAt(tree, row, index) orelse continue;
        const rect = tree.getConst(cell).layout_rect;
        if (x >= rect.x and x < rect.x + rect.w and y >= rect.y and y < rect.y + rect.h) return index;
    }
    return null;
}

pub fn tableRowSelectable(tree: *const Tree, row: NodeHandle) bool {
    const node = tree.getConst(row);
    if (node.kind != .table_row or node.kind.table_row.header) return false;
    const table_handle = node.parent orelse return false;
    const table = tree.getConst(table_handle);
    return table.kind == .table and table.kind.table.selection_mode != .none;
}

pub fn tableDataRowIndex(tree: *const Tree, row: NodeHandle) ?u16 {
    const node = tree.getConst(row);
    if (node.kind != .table_row or node.kind.table_row.header) return null;

    const table_handle = node.parent orelse return null;
    var index: u16 = 0;
    var iter = tree.children(table_handle);
    while (iter.next()) |child| {
        const child_node = tree.getConst(child);
        if (child_node.kind != .table_row or child_node.kind.table_row.header) continue;
        if (child.eql(row)) return index;
        index += 1;
    }
    return null;
}

pub fn syncDerivedState(kind: *WidgetKind) void {
    switch (kind.*) {
        .table => |*table| table.syncColumns(table.columns),
        .drag_value => |*drag_value| drag_value.syncLabel(),
        .spinbox => |*spinbox| spinbox.syncLabel(),
        else => {},
    }
}

fn formatScalarLabel(buf: *[64]u8, value: f32, precision: u8) []const u8 {
    return switch (@min(precision, 4)) {
        0 => std.fmt.bufPrint(buf, "{d:.0}", .{value}) catch "0",
        1 => std.fmt.bufPrint(buf, "{d:.1}", .{value}) catch "0.0",
        2 => std.fmt.bufPrint(buf, "{d:.2}", .{value}) catch "0.00",
        3 => std.fmt.bufPrint(buf, "{d:.3}", .{value}) catch "0.000",
        else => std.fmt.bufPrint(buf, "{d:.4}", .{value}) catch "0.0000",
    };
}

test "build and traverse widget tree" {
    const allocator = std.testing.allocator;
    var tree = Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const btn = try tree.addChild(root, .{ .button = .{ .label = "OK" } });
    const txt = try tree.addChild(root, .{ .text = .{ .content = "hello" } });

    try std.testing.expectEqual(@as(u32, 3), tree.count());
    try std.testing.expect(tree.getConst(root).parent == null);
    try std.testing.expect(tree.getConst(btn).parent.?.eql(root));

    var iter = tree.children(root);
    const first = iter.next().?;
    try std.testing.expect(first.eql(btn));
    const second = iter.next().?;
    try std.testing.expect(second.eql(txt));
    try std.testing.expect(iter.next() == null);
}

test "remove leaf node" {
    const allocator = std.testing.allocator;
    var tree = Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const btn = try tree.addChild(root, .{ .button = .{ .label = "A" } });
    _ = try tree.addChild(root, .{ .text = .{ .content = "B" } });

    try std.testing.expectEqual(@as(u32, 3), tree.count());

    try tree.remove(btn);
    try std.testing.expectEqual(@as(u32, 2), tree.count());
    try std.testing.expect(!tree.isAlive(btn));

    // Remaining child is still reachable
    var iter = tree.children(root);
    try std.testing.expect(iter.next() != null);
    try std.testing.expect(iter.next() == null);
}

test "remove subtree recursively" {
    const allocator = std.testing.allocator;
    var tree = Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const group = try tree.addChild(root, .{ .container = .{} });
    _ = try tree.addChild(group, .{ .text = .{ .content = "child1" } });
    _ = try tree.addChild(group, .{ .text = .{ .content = "child2" } });

    try std.testing.expectEqual(@as(u32, 4), tree.count());

    try tree.remove(group);
    try std.testing.expectEqual(@as(u32, 1), tree.count());

    // Root has no children
    var iter = tree.children(root);
    try std.testing.expect(iter.next() == null);
}

test "slot reuse after removal" {
    const allocator = std.testing.allocator;
    var tree = Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const btn = try tree.addChild(root, .{ .button = .{ .label = "old" } });
    const old_index = btn.index;

    try tree.remove(btn);

    // Adding a new node should reuse the freed slot
    const new_btn = try tree.addChild(root, .{ .button = .{ .label = "new" } });
    try std.testing.expectEqual(old_index, new_btn.index);
    // Generation must differ
    try std.testing.expect(new_btn.generation != btn.generation);
    try std.testing.expect(!btn.eql(new_btn));
    try std.testing.expect(tree.isAlive(new_btn));
    try std.testing.expect(!tree.isAlive(btn));
}

test "remove middle sibling preserves order" {
    const allocator = std.testing.allocator;
    var tree = Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const a = try tree.addChild(root, .{ .text = .{ .content = "A" } });
    const b = try tree.addChild(root, .{ .text = .{ .content = "B" } });
    const cc = try tree.addChild(root, .{ .text = .{ .content = "C" } });

    try tree.remove(b);

    var iter = tree.children(root);
    const first = iter.next().?;
    try std.testing.expect(first.eql(a));
    const second = iter.next().?;
    try std.testing.expect(second.eql(cc));
    try std.testing.expect(iter.next() == null);
}

test "wordBounds finds word boundaries" {
    var ti = WidgetKind.TextInput{};
    for ("hello world") |c| ti.insert(c);

    // In middle of "hello"
    const b1 = ti.wordBounds(2);
    try std.testing.expectEqual(@as(u8, 0), b1.start);
    try std.testing.expectEqual(@as(u8, 5), b1.end);

    // On the space
    const b2 = ti.wordBounds(5);
    try std.testing.expectEqual(@as(u8, 5), b2.start);
    try std.testing.expectEqual(@as(u8, 6), b2.end);

    // In "world"
    const b3 = ti.wordBounds(8);
    try std.testing.expectEqual(@as(u8, 6), b3.start);
    try std.testing.expectEqual(@as(u8, 11), b3.end);

    // At start
    const b4 = ti.wordBounds(0);
    try std.testing.expectEqual(@as(u8, 0), b4.start);
    try std.testing.expectEqual(@as(u8, 5), b4.end);

    // Past end (clamped)
    const b5 = ti.wordBounds(20);
    try std.testing.expectEqual(@as(u8, 6), b5.start);
    try std.testing.expectEqual(@as(u8, 11), b5.end);
}

test "wordBounds on empty input" {
    const ti = WidgetKind.TextInput{};
    const b = ti.wordBounds(0);
    try std.testing.expectEqual(@as(u8, 0), b.start);
    try std.testing.expectEqual(@as(u8, 0), b.end);
}
