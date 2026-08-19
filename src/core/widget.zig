const std = @import("std");
const ui = @import("goop_ui");
const style = @import("style.zig");
const visual_types = @import("visual_types.zig");
const handle_mod = @import("handle.zig");

pub const NodeHandle = handle_mod.NodeHandle;

/// Outcome of committing an inline numeric editor (`DragValue`,
/// `SpinBox`). Lets dispatch distinguish parse failure from a clean
/// commit, and a clean commit from one that actually moved the value.
pub const CommitResult = enum {
    /// Parse failed. The editor stays in editing state.
    invalid,
    /// Parsed successfully; value was unchanged.
    unchanged,
    /// Parsed successfully; value changed.
    changed,
};

/// Drag state shared by widget kinds that participate in pointer-driven
/// reordering (tree items, selectables, grid items, table rows). All
/// fields are owned and reset by the dispatch layer; embedders only
/// observe `active` (via `WidgetView.<kind>.dragging`).
pub const DragState = struct {
    active: bool = false,
    rect: visual_types.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    offset_x: f32 = 0,
    offset_y: f32 = 0,
};

/// Persistent interaction state tracked per widget. Occurrences such as
/// activation, value changes, and drops are emitted only through the semantic
/// control-event journal; they are never stored on retained nodes.
pub const InteractionState = struct {
    hovered: bool = false,
    pressed: bool = false,
    focused: bool = false,
    accepts_drop: bool = false,
    drop_hovered: bool = false,
};

/// Widget-specific data.
pub const WidgetKind = union(enum) {
    container: Container,
    text: Text,
    icon: Icon,
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
    custom: Custom,

    pub const Container = struct {
        direction: Direction = .column,
        /// Size to children along the main axis (fit-content) instead of
        /// growing to fill the parent. Use for stacks that should pack at the
        /// start and leave surplus space empty, rather than distributing it
        /// between children (e.g. a details column in a tall pane).
        fit_main: bool = false,

        pub const Direction = enum { row, column };
    };

    pub const Text = struct {
        content: []const u8,
        overflow: visual_types.TextOverflow = .visible,
    };

    /// Passive visual identity. The active look decides how an IconId maps to
    /// pixels; core owns no icon resources or drawing behavior.
    pub const Icon = struct {
        kind: visual_types.IconId,
        color: ?style.Color = null,
    };

    pub const Button = struct {
        label: []const u8,
        icon: ?visual_types.IconId = null,
        label_visible: bool = true,
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
        icon: ?visual_types.IconId = null,
        icon_color: ?style.Color = null,
        editable: bool = false,
        rename_trigger: RenameTrigger = .none,
        has_children: bool = false,
        expanded: bool = true,
        disclosure: Disclosure = .automatic,
        selected: bool = false,
        editing: bool = false,
        /// Internal state owned by dispatch/visual_types. Embedders should not
        /// touch this field directly — use the public methods.
        internal: Internal = .{},

        pub const Internal = struct {
            drag: DragState = .{},
            drop_preview: ?DropPosition = null,
            editor: TextInput = .{},
        };

        pub const RenameTrigger = enum {
            none,
            selected_click,
            double_click,
        };

        /// Visual disclosure state is separate from child visibility. Partial
        /// is useful for ancestor paths whose selected branch is revealed
        /// without treating the folder as explicitly expanded.
        pub const Disclosure = enum { automatic, collapsed, partial, expanded };

        pub fn disclosureState(self: TreeItem) Disclosure {
            return if (self.disclosure == .automatic)
                if (self.expanded) .expanded else .collapsed
            else
                self.disclosure;
        }

        pub const DropPosition = enum {
            before,
            into,
            after,
        };

        pub fn displayLabel(self: *const TreeItem) []const u8 {
            return if (self.editing) self.internal.editor.content() else self.label;
        }

        pub fn beginRename(self: *TreeItem) void {
            self.internal.editor = .{};
            self.internal.editor.insertSlice(self.label);
            self.internal.editor.selection_anchor = 0;
            self.internal.editor.cursor = self.internal.editor.len;
            self.editing = true;
        }

        pub fn cancelRename(self: *TreeItem) void {
            self.internal.editor = .{};
            self.editing = false;
        }

        pub fn commitRename(self: *TreeItem) void {
            self.label = self.internal.editor.content();
            self.editing = false;
        }
    };

    pub const Dropdown = struct {
        placeholder: []const u8 = "Select...",
        selected_text: []const u8 = "",
        selected_index: ?u16 = null,
        open: bool = false,
    };

    pub const ListBox = struct {
        selection_mode: SelectionMode = .single,
        /// Internal state owned by dispatch/visual_types. Don't touch.
        internal: Internal = .{},

        pub const Internal = struct {
            anchor_index: ?u16 = null,
            marquee_active: bool = false,
            marquee_rect: visual_types.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
            drop_preview_background: bool = false,
        };

        pub const SelectionMode = enum {
            single,
            multiple,
        };
    };

    pub const Selectable = struct {
        label: []const u8,
        group: u32 = 0,
        selected: bool = false,
        /// Internal state owned by dispatch/visual_types. Don't touch.
        internal: Internal = .{},

        pub const Internal = struct {
            marquee_base_selected: bool = false,
            drag: DragState = .{},
            drop_preview: bool = false,
        };
    };

    pub const GridSelector = struct {
        selection_mode: ListBox.SelectionMode = .single,
        item_width: f32 = 96,
        item_height: f32 = 96,
        column_gap: f32 = 8,
        row_gap: f32 = 8,
        computed_columns: u16 = 1,
        /// Internal state owned by dispatch/look/layout. Don't touch.
        internal: Internal = .{},

        pub const Internal = struct {
            anchor_index: ?u16 = null,
            content_height: f32 = 0,
            marquee_active: bool = false,
            marquee_rect: visual_types.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
            drop_preview_background: bool = false,
        };

        pub fn layoutHeight(self: *const GridSelector, padding: style.Edges) f32 {
            if (self.internal.content_height > 0) return self.internal.content_height;
            return padding.top + padding.bottom + @max(self.item_height, 1);
        }
    };

    pub const GridItem = struct {
        label: []const u8,
        icon: ?visual_types.IconId = null,
        icon_color: ?style.Color = null,
        selected: bool = false,
        selected_label_action: ?ui.ActionId = null,
        /// Internal state owned by dispatch/visual_types. Don't touch.
        internal: Internal = .{},

        pub const Internal = struct {
            marquee_base_selected: bool = false,
            drag: DragState = .{},
            drop_preview: bool = false,
        };
    };

    pub const Table = struct {
        pub const max_columns: usize = 32;
        /// Pointer interaction width around a column divider. The visible grip
        /// remains narrow; this larger transparent strip is the grab target.
        pub const resize_handle_width: f32 = 12;
        pub const resize_grip_width: f32 = 2;
        pub const resize_grip_height: f32 = 12;

        columns: u8 = 0,
        striped: bool = true,
        resizable: bool = false,
        sortable: bool = false,
        selection_mode: SelectionMode = .none,
        min_column_width: f32 = 96,
        sorted_column: ?u8 = null,
        sort_direction: SortDirection = .ascending,
        active_columns: u8 = 0,
        /// Internal state owned by dispatch/look/layout. Don't touch.
        internal: Internal = .{},

        pub const Internal = struct {
            anchor_row: ?u16 = null,
            marquee_active: bool = false,
            marquee_rect: visual_types.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
            drop_preview_background: bool = false,
            column_weights: [max_columns]f32 = [_]f32{0} ** max_columns,
        };

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
                self.internal.anchor_row = null;
                @memset(&self.internal.column_weights, 0);
                return;
            }

            var sum: f32 = 0;
            var reset = self.active_columns != clamped;
            if (!reset) {
                for (self.internal.column_weights[0..clamped]) |weight| {
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
            @memset(self.internal.column_weights[clamped..], 0);

            if (reset) {
                const equal = 1.0 / @as(f32, @floatFromInt(clamped));
                for (self.internal.column_weights[0..clamped]) |*weight| weight.* = equal;
                return;
            }

            if (@abs(sum - 1.0) > 0.0001) {
                for (self.internal.column_weights[0..clamped]) |*weight| weight.* /= sum;
            }
        }

        pub fn columnWeight(self: *const Table, index: usize) ?f32 {
            if (index >= self.active_columns) return null;
            return self.internal.column_weights[index];
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
            self.internal.column_weights[divider_index] = new_left / total_width;
            self.internal.column_weights[divider_index + 1] = new_right / total_width;
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
                    return true;
                }
            }

            self.sorted_column = column;
            self.sort_direction = .ascending;
            return true;
        }
    };

    pub const TableRow = struct {
        header: bool = false,
        selected: bool = false,
        selected_label_action: ?ui.ActionId = null,
        label_action_column: u8 = 0,
        /// Internal state owned by dispatch/visual_types. Don't touch.
        internal: Internal = .{},

        pub const Internal = struct {
            marquee_base_selected: bool = false,
            drag: DragState = .{},
            drop_preview: bool = false,
        };
    };

    pub const TableCell = struct {};

    pub const Toolbar = struct {};

    pub const StatusBar = struct {};

    pub const MenuBar = struct {};

    pub const Menu = struct {
        label: []const u8,
        /// Access key for win32-style mnemonics: the first matching character
        /// in `label` is underlined and Alt+<char> opens this menu.
        mnemonic: ?u8 = null,
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
        delay_ms: u32 = 500,
        /// Runtime-owned presentation state. Callers configure the delay;
        /// dispatch decides when the tooltip becomes visible.
        visible: bool = false,
    };

    pub const MenuItem = struct {
        label: []const u8,
        shortcut: []const u8 = "",
        checked: bool = false,
        disabled: bool = false,
        /// Access key: when this item's menu is open, pressing <char> activates
        /// it. The matching character in `label` is underlined.
        mnemonic: ?u8 = null,
    };

    pub const DragValue = struct {
        value: f32 = 0,
        min: f32 = -1000000,
        max: f32 = 1000000,
        speed: f32 = 0.1,
        precision: u8 = 2,
        editing: bool = false,
        /// Internal state owned by dispatch. Don't touch.
        internal: Internal = .{},

        pub const Internal = struct {
            label_buf: [64]u8 = [_]u8{0} ** 64,
            label_len: u8 = 0,
            editor: TextInput = .{},
        };

        pub fn displayValue(self: *const DragValue) []const u8 {
            return self.internal.label_buf[0..self.internal.label_len];
        }

        pub fn syncLabel(self: *DragValue) void {
            const label = formatScalarLabel(&self.internal.label_buf, self.value, self.precision);
            self.internal.label_len = @intCast(label.len);
        }

        pub fn beginEdit(self: *DragValue) void {
            self.internal.editor = .{};
            self.internal.editor.insertSlice(self.displayValue());
            self.internal.editor.selection_anchor = 0;
            self.internal.editor.cursor = self.internal.editor.len;
            self.editing = true;
        }

        pub fn cancelEdit(self: *DragValue) void {
            self.internal.editor = .{};
            self.editing = false;
        }

        pub fn commitEdit(self: *DragValue) CommitResult {
            const next_value = std.fmt.parseFloat(f32, self.internal.editor.content()) catch return .invalid;
            const clamped = std.math.clamp(next_value, self.min, self.max);
            const did_change = clamped != self.value;
            self.value = clamped;
            self.syncLabel();
            self.editing = false;
            return if (did_change) .changed else .unchanged;
        }
    };

    pub const SpinBox = struct {
        value: f32 = 0,
        min: f32 = -1000000,
        max: f32 = 1000000,
        step: f32 = 1,
        precision: u8 = 2,
        editing: bool = false,
        /// Internal state owned by dispatch. Don't touch.
        internal: Internal = .{},

        pub const Internal = struct {
            label_buf: [64]u8 = [_]u8{0} ** 64,
            label_len: u8 = 0,
            editor: TextInput = .{},
        };

        pub fn displayValue(self: *const SpinBox) []const u8 {
            return self.internal.label_buf[0..self.internal.label_len];
        }

        pub fn syncLabel(self: *SpinBox) void {
            const label = formatScalarLabel(&self.internal.label_buf, self.value, self.precision);
            self.internal.label_len = @intCast(label.len);
        }

        pub fn beginEdit(self: *SpinBox) void {
            self.internal.editor = .{};
            self.internal.editor.insertSlice(self.displayValue());
            self.internal.editor.selection_anchor = 0;
            self.internal.editor.cursor = self.internal.editor.len;
            self.editing = true;
        }

        pub fn cancelEdit(self: *SpinBox) void {
            self.internal.editor = .{};
            self.editing = false;
        }

        pub fn commitEdit(self: *SpinBox) CommitResult {
            const next_value = std.fmt.parseFloat(f32, self.internal.editor.content()) catch return .invalid;
            const clamped = std.math.clamp(next_value, self.min, self.max);
            const did_change = clamped != self.value;
            self.value = clamped;
            self.syncLabel();
            self.editing = false;
            return if (did_change) .changed else .unchanged;
        }
    };

    pub const TabBar = struct {};

    pub const TabItem = struct {
        label: []const u8,
        selected: bool = false,
    };

    pub const Splitter = struct {
        direction: Container.Direction = .row,
        ratio: f32 = 0.5,
        min_first: f32 = 120,
        min_second: f32 = 120,
        thickness: f32 = 8,
        gap_thickness: f32 = 1,
        keyboard_step: f32 = 0.02,
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
        content_width: ?f32 = null,
        content_height: ?f32 = null,
        internal: Internal = .{},

        pub const ScrollbarAxis = enum { vertical, horizontal };
        pub const Internal = struct {
            hovered_scrollbar: ?ScrollbarAxis = null,
            active_scrollbar: ?ScrollbarAxis = null,
        };

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

    pub const Custom = struct {
        type_id: u64 = 0,
        width: f32 = 0,
        height: f32 = 0,
        min_width: f32 = 0,
        min_height: f32 = 0,
        grow_width: bool = true,
        grow_height: bool = false,
        focusable: bool = false,
    };
};

pub const TextEditState = WidgetKind.TextInput;
/// Byte index of the first case-insensitive occurrence of `mnemonic` in
/// `label` — where the access-key underline is drawn and what Alt/letter keys
/// match. Returns null when there is no mnemonic or the character is absent.
pub fn mnemonicIndex(label: []const u8, mnemonic: ?u8) ?usize {
    const key = mnemonic orelse return null;
    const lowered = std.ascii.toLower(key);
    for (label, 0..) |c, i| {
        if (std.ascii.toLower(c) == lowered) return i;
    }
    return null;
}

test "mnemonicIndex finds the access key case-insensitively" {
    try std.testing.expectEqual(@as(?usize, 0), mnemonicIndex("File", 'f'));
    try std.testing.expectEqual(@as(?usize, 3), mnemonicIndex("Go To", 'T'));
    try std.testing.expectEqual(@as(?usize, null), mnemonicIndex("File", 'z'));
    try std.testing.expectEqual(@as(?usize, null), mnemonicIndex("File", null));
}

pub const ElementId = ui.ElementId;
pub const ActionId = ui.ActionId;

/// Stable semantic metadata attached to an interactive node. `element_id`
/// identifies the source control; `action_id` identifies an application
/// command presented by that control.
pub const ControlIdentity = struct {
    element_id: ElementId,
    action_id: ?ActionId = null,
};

/// Construction input for a semantic control. This keeps identity/action
/// orthogonal to the visual widget descriptor instead of duplicating those
/// fields across every widget kind.
pub const ControlDesc = struct {
    identity: ControlIdentity,
    widget: WidgetDesc,
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
/// Runtime-owned interaction state (`dragging`, `editing`, drag rectangles,
/// label buffers, marquee state, and so on) is *not* part of `WidgetDesc`.
/// Occurrences are reported through `ControlEvents`, never descriptors.
pub const WidgetDesc = union(enum) {
    container: Container,
    text: Text,
    icon: Icon,
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
    custom: Custom,

    pub const Container = struct {
        direction: WidgetKind.Container.Direction = .column,
        fit_main: bool = false,
    };

    pub const Text = struct {
        content: []const u8,
        overflow: visual_types.TextOverflow = .visible,
    };

    pub const Icon = struct {
        kind: visual_types.IconId,
        color: ?style.Color = null,
    };

    pub const Button = struct {
        label: []const u8,
        icon: ?visual_types.IconId = null,
        label_visible: bool = true,
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
        icon: ?visual_types.IconId = null,
        icon_color: ?style.Color = null,
        editable: bool = false,
        rename_trigger: WidgetKind.TreeItem.RenameTrigger = .none,
        has_children: bool = false,
        expanded: bool = true,
        disclosure: WidgetKind.TreeItem.Disclosure = .automatic,
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
        icon: ?visual_types.IconId = null,
        icon_color: ?style.Color = null,
        selected: bool = false,
        selected_label_action: ?ui.ActionId = null,
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
        selected_label_action: ?ui.ActionId = null,
        label_action_column: u8 = 0,
    };

    pub const TableCell = struct {};

    pub const Toolbar = struct {};

    pub const StatusBar = struct {};

    pub const MenuBar = struct {};

    pub const Menu = struct {
        label: []const u8,
        mnemonic: ?u8 = null,
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
        delay_ms: u32 = 500,
    };

    pub const MenuItem = struct {
        label: []const u8,
        shortcut: []const u8 = "",
        checked: bool = false,
        disabled: bool = false,
        /// Access key: when this item's menu is open, pressing <char> activates
        /// it. The matching character in `label` is underlined.
        mnemonic: ?u8 = null,
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
        thickness: f32 = 8,
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
        content_width: ?f32 = null,
        content_height: ?f32 = null,
    };

    pub const TextInput = struct {
        placeholder: []const u8 = "",
    };

    pub const Custom = struct {
        type_id: u64 = 0,
        width: f32 = 0,
        height: f32 = 0,
        min_width: f32 = 0,
        min_height: f32 = 0,
        grow_width: bool = true,
        grow_height: bool = false,
        focusable: bool = false,
    };
};

/// Read a struct field's compile-time default value. Errors at
/// comptime if the field has no default. Used by the `WidgetKind` /
/// `WidgetView` projections to fill in fields that don't appear on
/// the source struct.
fn fieldDefault(comptime T: type, comptime name: []const u8) @FieldType(T, name) {
    inline for (std.meta.fields(T)) |f| {
        if (comptime std.mem.eql(u8, f.name, name)) {
            const ptr = f.default_value_ptr orelse @compileError(
                @typeName(T) ++ "." ++ name ++ " has no compile-time default",
            );
            const typed: *const f.type = @ptrCast(@alignCast(ptr));
            return typed.*;
        }
    }
    @compileError(@typeName(T) ++ " has no field named " ++ name);
}

/// Build a `WidgetKind` from a user-authored `WidgetDesc`. For each
/// kind, fields named in the desc are copied verbatim; fields that
/// only exist on the kind (per-frame state, derived caches) take
/// their compile-time default. `Tree.addNode` then calls
/// `syncDerivedState` to fill computed-from-desc fields like table
/// column weights and drag-value labels.
pub fn kindFromDesc(desc: WidgetDesc) WidgetKind {
    return switch (desc) {
        inline else => |desc_payload, tag| build: {
            const KindPayload = @FieldType(WidgetKind, @tagName(tag));
            const fields = std.meta.fields(KindPayload);
            if (fields.len == 0) {
                break :build @unionInit(WidgetKind, @tagName(tag), .{});
            }
            const DescPayload = @TypeOf(desc_payload);
            var k: KindPayload = undefined;
            inline for (fields) |kf| {
                if (@hasField(DescPayload, kf.name)) {
                    @field(k, kf.name) = @field(desc_payload, kf.name);
                } else {
                    @field(k, kf.name) = fieldDefault(KindPayload, kf.name);
                }
            }
            break :build @unionInit(WidgetKind, @tagName(tag), k);
        },
    };
}

/// Read-only projection of a widget node's kind-specific state.
///
/// `WidgetView` carries identifying fields and persistent state
/// (label, value, selected, expanded, …). Occurrence data lives only in the
/// semantic event journal. Pure construction-time configuration
/// (min/max/precision/min_first) is also omitted — the embedder is
/// the source of truth for that.
///
/// Slices borrow from the tree's storage and stay valid until the
/// next mutation that touches the widget.
pub const WidgetView = union(enum) {
    container: Container,
    text: Text,
    icon: Icon,
    button: Button,
    checkbox: Checkbox,
    radio_button: RadioButton,
    tree_item: TreeItem,
    dropdown: Dropdown,
    list_box: void,
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
    custom: Custom,

    pub const Container = struct { direction: WidgetKind.Container.Direction, fit_main: bool };

    pub const Text = struct { content: []const u8 };

    pub const Icon = struct {
        kind: visual_types.IconId,
        color: ?style.Color,
    };

    pub const Button = struct {
        label: []const u8,
        icon: ?visual_types.IconId,
        label_visible: bool,
    };

    pub const Checkbox = struct {
        label: []const u8,
        checked: bool,
    };

    pub const RadioButton = struct {
        label: []const u8,
        group: u32,
        selected: bool,
    };

    pub const TreeItem = struct {
        label: []const u8,
        group: u32,
        icon: ?visual_types.IconId,
        icon_color: ?style.Color,
        has_children: bool,
        expanded: bool,
        disclosure: WidgetKind.TreeItem.Disclosure,
        selected: bool,
        editing: bool,
        dragging: bool,
    };

    pub const Dropdown = struct {
        placeholder: []const u8,
        selected_text: []const u8,
        selected_index: ?u16,
        open: bool,
    };

    pub const Selectable = struct {
        label: []const u8,
        group: u32,
        selected: bool,
        dragging: bool,
    };

    pub const GridSelector = struct {
        computed_columns: u16,
    };

    pub const GridItem = struct {
        label: []const u8,
        icon: ?visual_types.IconId,
        icon_color: ?style.Color,
        selected: bool,
        dragging: bool,
    };

    pub const Table = struct {
        active_columns: u8,
        sorted_column: ?u8,
        sort_direction: WidgetKind.Table.SortDirection,
    };

    pub const TableRow = struct {
        header: bool,
        selected: bool,
        dragging: bool,
    };

    pub const Menu = struct {
        label: []const u8,
        mnemonic: ?u8,
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
        visible: bool,
    };

    pub const MenuItem = struct {
        label: []const u8,
        shortcut: []const u8,
        checked: bool,
        disabled: bool,
        mnemonic: ?u8,
    };

    pub const DragValue = struct {
        value: f32,
        editing: bool,
        display_text: []const u8,
    };

    pub const SpinBox = struct {
        value: f32,
        editing: bool,
        display_text: []const u8,
    };

    pub const TabItem = struct {
        label: []const u8,
        selected: bool,
    };

    pub const Splitter = struct {
        ratio: f32,
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

    pub const Custom = struct {
        type_id: u64,
        width: f32,
        height: f32,
        min_width: f32,
        min_height: f32,
        grow_width: bool,
        grow_height: bool,
        focusable: bool,
    };

    pub fn fromNode(node: *const Node) WidgetView {
        // Slice fields borrow from tree storage rather than a copy.
        // This projection contains persistent state only. Occurrences are
        // carried by the semantic event journal.
        const kind = &node.kind;
        return switch (kind.*) {
            // Bespoke arms: rename `drag.active` to `dragging`, route
            // dynamic labels through helper methods, expose text
            // input content through the buffer accessor.
            .tree_item => .{ .tree_item = .{
                .label = kind.tree_item.displayLabel(),
                .group = kind.tree_item.group,
                .icon = kind.tree_item.icon,
                .icon_color = kind.tree_item.icon_color,
                .has_children = kind.tree_item.has_children,
                .expanded = kind.tree_item.expanded,
                .disclosure = kind.tree_item.disclosureState(),
                .selected = kind.tree_item.selected,
                .editing = kind.tree_item.editing,
                .dragging = kind.tree_item.internal.drag.active,
            } },
            .selectable => .{ .selectable = .{
                .label = kind.selectable.label,
                .group = kind.selectable.group,
                .selected = kind.selectable.selected,
                .dragging = kind.selectable.internal.drag.active,
            } },
            .grid_item => .{ .grid_item = .{
                .label = kind.grid_item.label,
                .icon = kind.grid_item.icon,
                .icon_color = kind.grid_item.icon_color,
                .selected = kind.grid_item.selected,
                .dragging = kind.grid_item.internal.drag.active,
            } },
            .table_row => .{ .table_row = .{
                .header = kind.table_row.header,
                .selected = kind.table_row.selected,
                .dragging = kind.table_row.internal.drag.active,
            } },
            .drag_value => .{ .drag_value = .{
                .value = kind.drag_value.value,
                .editing = kind.drag_value.editing,
                .display_text = kind.drag_value.displayValue(),
            } },
            .spinbox => .{ .spinbox = .{
                .value = kind.spinbox.value,
                .editing = kind.spinbox.editing,
                .display_text = kind.spinbox.displayValue(),
            } },
            .text_input => .{ .text_input = .{
                .content = kind.text_input.content(),
                .cursor = kind.text_input.cursor,
                .selection_anchor = kind.text_input.selection_anchor,
            } },
            // All other arms are pure field copies — derive them by
            // walking the View arm's fields and pulling the same name
            // from the kind payload.
            inline else => |kind_payload, tag| build: {
                const ViewPayload = @FieldType(WidgetView, @tagName(tag));
                if (ViewPayload == void) {
                    break :build @unionInit(WidgetView, @tagName(tag), {});
                }
                var v: ViewPayload = undefined;
                inline for (std.meta.fields(ViewPayload)) |vf| {
                    @field(v, vf.name) = @field(kind_payload, vf.name);
                }
                break :build @unionInit(WidgetView, @tagName(tag), v);
            },
        };
    }
};

/// Read-only view of a single node — bundles layout, persistent
/// interaction state, and the kind-specific `WidgetView`.
/// Returned by `Tree.node`. Slices borrow from tree storage and stay
/// valid until the next mutation that touches the node.
pub const NodeView = struct {
    rect: visual_types.Rect,
    element_id: ?ElementId,
    action_id: ?ActionId,
    focused: bool,
    accepts_drop: bool,
    drop_hovered: bool,
    kind: WidgetView,

    pub fn fromNode(node: *const Node) NodeView {
        return .{
            .rect = node.layout_rect,
            .element_id = node.element_id,
            .action_id = node.action_id,
            .focused = node.interaction.focused,
            .accepts_drop = node.interaction.accepts_drop,
            .drop_hovered = node.interaction.drop_hovered,
            .kind = WidgetView.fromNode(node),
        };
    }
};

/// A single node in the widget tree.
pub const Node = struct {
    kind: WidgetKind,
    style_override: style.Style = .{},
    interaction: InteractionState = .{},
    element_id: ?ElementId = null,
    action_id: ?ActionId = null,
    layout_rect: visual_types.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },

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
    element_index: std.AutoHashMapUnmanaged(ElementId, NodeHandle) = .empty,
    structural_revision: u64 = 0,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Tree {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Tree) void {
        self.element_index.deinit(self.allocator);
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

    /// Add a root widget with stable semantic identity and optional action.
    pub fn addRootControl(self: *Tree, desc: ControlDesc) !NodeHandle {
        if (self.findByElementId(desc.identity.element_id) != null) return error.DuplicateElementId;
        try self.element_index.ensureUnusedCapacity(self.allocator, 1);
        const handle = try self.addRoot(desc.widget);
        const target = self.get(handle);
        target.element_id = desc.identity.element_id;
        target.action_id = desc.identity.action_id;
        self.element_index.putAssumeCapacity(desc.identity.element_id, handle);
        return handle;
    }

    /// Add a child widget with stable semantic identity and optional action.
    pub fn addChildControl(self: *Tree, parent: NodeHandle, desc: ControlDesc) !NodeHandle {
        if (self.findByElementId(desc.identity.element_id) != null) return error.DuplicateElementId;
        try self.element_index.ensureUnusedCapacity(self.allocator, 1);
        const handle = try self.addChild(parent, desc.widget);
        const target = self.get(handle);
        target.element_id = desc.identity.element_id;
        target.action_id = desc.identity.action_id;
        self.element_index.putAssumeCapacity(desc.identity.element_id, handle);
        return handle;
    }

    /// Remove a node and all its descendants from the tree.
    /// The handle becomes invalid after this call.
    pub fn remove(self: *Tree, handle: NodeHandle) !void {
        const n = self.getMut(handle);

        // Recursively remove children first
        var child = n.first_child;
        while (child) |ch| {
            const next = self.nodes.items[ch.index].next_sibling;
            try self.remove(ch);
            child = next;
        }

        // Unlink from parent's child list
        if (n.parent) |ph| {
            const parent = &self.nodes.items[ph.index];
            if (parent.first_child) |fc| {
                if (fc.eql(handle)) {
                    parent.first_child = n.next_sibling;
                }
            }
            if (parent.last_child) |lc| {
                if (lc.eql(handle)) {
                    parent.last_child = n.prev_sibling;
                }
            }
        }

        // Unlink from sibling chain
        if (n.prev_sibling) |prev| {
            self.nodes.items[prev.index].next_sibling = n.next_sibling;
        }
        if (n.next_sibling) |nxt| {
            self.nodes.items[nxt.index].prev_sibling = n.prev_sibling;
        }

        if (n.element_id) |element_id| {
            std.debug.assert(self.element_index.remove(element_id));
        }

        // Mark dead, bump generation, push to free list
        n.alive = false;
        n.generation +%= 1;
        n.parent = null;
        n.first_child = null;
        n.last_child = null;
        n.next_sibling = null;
        n.prev_sibling = null;
        try self.free_list.append(self.allocator, handle.index);
        self.bumpRevision();
    }

    /// Get a pointer to a node by handle.
    /// Asserts the handle is valid (generation matches and node is alive).
    pub fn get(self: *Tree, handle: NodeHandle) *Node {
        const n = &self.nodes.items[handle.index];
        std.debug.assert(n.alive and n.generation == handle.generation);
        return n;
    }

    /// Get a const pointer to a node by handle.
    pub fn getConst(self: *const Tree, handle: NodeHandle) *const Node {
        const n = &self.nodes.items[handle.index];
        std.debug.assert(n.alive and n.generation == handle.generation);
        return n;
    }

    /// Check whether a handle refers to a living node.
    pub fn isAlive(self: *const Tree, handle: NodeHandle) bool {
        if (handle.index >= self.nodes.items.len) return false;
        const n = &self.nodes.items[handle.index];
        return n.alive and n.generation == handle.generation;
    }

    /// Read view of a node's state. Returns null if the handle is dead.
    /// Slices in the view borrow from tree
    /// storage and stay valid until the next mutation on this node.
    pub fn node(self: *const Tree, handle: NodeHandle) ?NodeView {
        if (!self.isAlive(handle)) return null;
        return NodeView.fromNode(self.getConst(handle));
    }

    /// Attach stable semantic identity and an optional application action.
    pub fn setControlIdentity(self: *Tree, handle: NodeHandle, identity: ControlIdentity) !void {
        if (!self.isAlive(handle)) return;
        if (self.findByElementId(identity.element_id)) |existing| {
            if (!existing.eql(handle)) return error.DuplicateElementId;
        }
        const target = self.get(handle);
        if (target.element_id == identity.element_id and target.action_id == identity.action_id) return;
        if (target.element_id == null) try self.element_index.ensureUnusedCapacity(self.allocator, 1);
        if (target.element_id) |old| std.debug.assert(self.element_index.remove(old));
        target.element_id = identity.element_id;
        target.action_id = identity.action_id;
        self.element_index.putAssumeCapacity(identity.element_id, handle);
        self.bumpRevision();
    }

    pub fn setElementId(self: *Tree, handle: NodeHandle, element_id: ?ElementId) !void {
        if (!self.isAlive(handle)) return;
        if (element_id) |id| {
            if (self.findByElementId(id)) |existing| {
                if (!existing.eql(handle)) return error.DuplicateElementId;
            }
        }
        const target = self.get(handle);
        if (target.element_id == element_id) return;
        if (target.element_id == null and element_id != null) try self.element_index.ensureUnusedCapacity(self.allocator, 1);
        if (target.element_id) |old| std.debug.assert(self.element_index.remove(old));
        target.element_id = element_id;
        if (element_id) |id| self.element_index.putAssumeCapacity(id, handle);
        self.bumpRevision();
    }

    pub fn setActionId(self: *Tree, handle: NodeHandle, action_id: ?ActionId) void {
        if (!self.isAlive(handle)) return;
        const target = self.get(handle);
        if (target.action_id == action_id) return;
        target.action_id = action_id;
        self.bumpRevision();
    }

    pub fn elementId(self: *const Tree, handle: NodeHandle) ?ElementId {
        if (!self.isAlive(handle)) return null;
        return self.getConst(handle).element_id;
    }

    pub fn actionId(self: *const Tree, handle: NodeHandle) ?ActionId {
        if (!self.isAlive(handle)) return null;
        return self.getConst(handle).action_id;
    }

    /// Find a live node by semantic identity. Element IDs are caller-owned and
    /// must be unique within a tree.
    pub fn findByElementId(self: *const Tree, element_id: ElementId) ?NodeHandle {
        const handle = self.element_index.get(element_id) orelse return null;
        std.debug.assert(self.isAlive(handle));
        std.debug.assert(self.getConst(handle).element_id == element_id);
        return handle;
    }

    /// Mark a widget as a generic drop target for active drags. Pure
    /// field write; does not invalidate caches.
    pub fn setDropTarget(self: *Tree, handle: NodeHandle, accepts_drop: bool) void {
        if (!self.isAlive(handle)) return;
        self.get(handle).interaction.accepts_drop = accepts_drop;
    }

    /// Get a single column's normalized width for a table, in [0, 1].
    /// Returns null if the handle is dead, not a table, or the column
    /// index exceeds the active column count.
    pub fn tableColumnFraction(self: *const Tree, handle: NodeHandle, index: u8) ?f32 {
        if (!self.isAlive(handle)) return null;
        const n = self.getConst(handle);
        if (n.kind != .table) return null;
        return n.kind.table.columnWeight(index);
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

    /// Monotonic structural revision. Bumped whenever parent/child topology
    /// changes so runtime cache checks don't infer topology from live counts.
    pub fn revision(self: *const Tree) u64 {
        return self.structural_revision;
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

        self.bumpRevision();
        return handle;
    }

    /// Internal: get a mutable pointer without generation check (for remove).
    fn getMut(self: *Tree, handle: NodeHandle) *Node {
        const n = &self.nodes.items[handle.index];
        std.debug.assert(n.alive and n.generation == handle.generation);
        return n;
    }

    fn bumpRevision(self: *Tree) void {
        self.structural_revision +%= 1;
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

pub fn tableResizeHandleRect(tree: *const Tree, table: NodeHandle, divider_index: u8) ?visual_types.Rect {
    const node = tree.getConst(table);
    if (node.kind != .table or !node.kind.table.resizable) return null;

    const row = tableReferenceRow(tree, table) orelse return null;
    const left = tableCellAt(tree, row, divider_index) orelse return null;
    _ = tableCellAt(tree, row, divider_index + 1) orelse return null;

    const left_rect = tree.getConst(left).layout_rect;
    if (left_rect.w <= 0 or left_rect.h <= 0) return null;

    const row_rect = tree.getConst(row).layout_rect;
    const divider_x = left_rect.x + left_rect.w;
    const desired_left = divider_x - WidgetKind.Table.resize_handle_width * 0.5;
    const left_edge = @max(desired_left, row_rect.x);
    const right_edge = @min(desired_left + WidgetKind.Table.resize_handle_width, row_rect.x + row_rect.w);
    return .{
        .x = left_edge,
        .y = row_rect.y,
        .w = @max(right_edge - left_edge, 0),
        .h = @max(row_rect.h, 0),
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
    kindOps(kind.*).sync(kind);
}

const KindOps = struct {
    sync: KindMutFn = kindMutNoop,
};

const KindMutFn = *const fn (*WidgetKind) void;

fn kindOps(kind: WidgetKind) KindOps {
    const tag: std.meta.Tag(WidgetKind) = kind;
    return kind_ops[@intFromEnum(tag)];
}

const kind_ops = blk: {
    const Tag = std.meta.Tag(WidgetKind);
    var ops: [std.meta.fields(Tag).len]KindOps = undefined;
    for (&ops) |*op| op.* = .{};
    ops[@intFromEnum(Tag.table)] = .{ .sync = syncTableState };
    ops[@intFromEnum(Tag.drag_value)] = .{ .sync = syncDragValueState };
    ops[@intFromEnum(Tag.spinbox)] = .{ .sync = syncSpinBoxState };
    break :blk ops;
};

fn kindMutNoop(_: *WidgetKind) void {}

fn syncTableState(kind: *WidgetKind) void {
    kind.table.syncColumns(kind.table.columns);
}

fn syncDragValueState(kind: *WidgetKind) void {
    kind.drag_value.syncLabel();
}

fn syncSpinBoxState(kind: *WidgetKind) void {
    kind.spinbox.syncLabel();
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

test "semantic element identities are unique within a tree" {
    var tree = Tree.init(std.testing.allocator);
    defer tree.deinit();

    const first = try tree.addRootControl(.{
        .identity = .{ .element_id = .init(41) },
        .widget = .{ .button = .{ .label = "first" } },
    });
    try std.testing.expectError(error.DuplicateElementId, tree.addRootControl(.{
        .identity = .{ .element_id = .init(41) },
        .widget = .{ .button = .{ .label = "duplicate" } },
    }));
    try std.testing.expectEqual(@as(u32, 1), tree.count());

    const second = try tree.addRoot(.{ .button = .{ .label = "second" } });
    const before_duplicate = tree.revision();
    try std.testing.expectError(error.DuplicateElementId, tree.setElementId(second, .init(41)));
    try std.testing.expect(tree.elementId(second) == null);
    try std.testing.expectEqual(before_duplicate, tree.revision());
    try tree.setElementId(second, .init(42));
    try std.testing.expect(tree.revision() != before_duplicate);
    try tree.setControlIdentity(first, .{ .element_id = .init(41), .action_id = .init(9) });
    try std.testing.expectError(
        error.DuplicateElementId,
        tree.setControlIdentity(second, .{ .element_id = .init(41) }),
    );
    try std.testing.expectEqual(ElementId.init(42), tree.elementId(second).?);

    try tree.remove(first);
    const replacement = try tree.addRootControl(.{
        .identity = .{ .element_id = .init(41) },
        .widget = .{ .button = .{ .label = "replacement" } },
    });
    try std.testing.expect(tree.findByElementId(.init(41)).?.eql(replacement));
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
