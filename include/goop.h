#ifndef GOOP_H
#define GOOP_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct goop_context goop_context_t;

typedef struct {
    const char *ptr;
    size_t len;
} goop_string_t;

static inline goop_string_t goop_string_from_cstr(const char *text) {
    goop_string_t str;
    str.ptr = text;
    str.len = text ? strlen(text) : 0;
    return str;
}

typedef struct {
    uint32_t index;
    uint32_t generation;
} goop_node_handle_t;

typedef struct {
    float x;
    float y;
    float w;
    float h;
} goop_rect_t;

typedef struct {
    uint8_t r;
    uint8_t g;
    uint8_t b;
    uint8_t a;
} goop_color_t;

typedef struct {
    float top;
    float right;
    float bottom;
    float left;
} goop_edges_t;

typedef struct {
    goop_color_t bg;
    goop_color_t fg;
    goop_color_t accent;
    goop_color_t border;
    goop_color_t bg_hover;
    goop_color_t bg_active;
    goop_color_t focus_ring;
    goop_color_t placeholder_fg;
    goop_color_t selection_bg;
    goop_color_t tree_guide;
    float font_size;
    goop_edges_t padding;
    float border_radius;
    float border_width;
    float spacing;
    float thumb_width;
} goop_theme_t;

typedef struct {
    bool has_bg;
    goop_color_t bg;
    bool has_fg;
    goop_color_t fg;
    bool has_border;
    goop_color_t border;
    bool has_font_size;
    float font_size;
    bool has_padding;
    goop_edges_t padding;
    bool has_border_radius;
    float border_radius;
    bool has_border_width;
    float border_width;
    bool has_thumb_width;
    float thumb_width;
} goop_style_t;

typedef enum {
    GOOP_DIRECTION_ROW = 0,
    GOOP_DIRECTION_COLUMN = 1,
} goop_direction_t;

typedef enum {
    GOOP_TREE_RENAME_NONE = 0,
    GOOP_TREE_RENAME_SELECTED_CLICK = 1,
    GOOP_TREE_RENAME_DOUBLE_CLICK = 2,
} goop_tree_rename_trigger_t;

typedef enum {
    GOOP_POPUP_ABSOLUTE = 0,
    GOOP_POPUP_BELOW_START = 1,
    GOOP_POPUP_BELOW_END = 2,
    GOOP_POPUP_RIGHT_START = 3,
} goop_popup_placement_t;

typedef enum {
    GOOP_LIST_SELECTION_SINGLE = 0,
    GOOP_LIST_SELECTION_MULTIPLE = 1,
} goop_list_selection_mode_t;

typedef enum {
    GOOP_TABLE_SELECTION_NONE = 0,
    GOOP_TABLE_SELECTION_SINGLE = 1,
    GOOP_TABLE_SELECTION_MULTIPLE = 2,
} goop_table_selection_mode_t;

typedef enum {
    GOOP_SORT_ASCENDING = 0,
    GOOP_SORT_DESCENDING = 1,
} goop_sort_direction_t;

typedef enum {
    GOOP_WIDGET_CONTAINER = 0,
    GOOP_WIDGET_TEXT = 1,
    GOOP_WIDGET_BUTTON = 2,
    GOOP_WIDGET_CHECKBOX = 3,
    GOOP_WIDGET_RADIO_BUTTON = 4,
    GOOP_WIDGET_TREE_ITEM = 5,
    GOOP_WIDGET_DROPDOWN = 6,
    GOOP_WIDGET_LIST_BOX = 7,
    GOOP_WIDGET_SELECTABLE = 8,
    GOOP_WIDGET_TABLE = 9,
    GOOP_WIDGET_TABLE_ROW = 10,
    GOOP_WIDGET_TABLE_CELL = 11,
    GOOP_WIDGET_TOOLBAR = 12,
    GOOP_WIDGET_STATUS_BAR = 13,
    GOOP_WIDGET_MENU_BAR = 14,
    GOOP_WIDGET_MENU = 15,
    GOOP_WIDGET_POPUP = 16,
    GOOP_WIDGET_TOOLTIP = 17,
    GOOP_WIDGET_MENU_ITEM = 18,
    GOOP_WIDGET_DRAG_VALUE = 19,
    GOOP_WIDGET_SPINBOX = 20,
    GOOP_WIDGET_TAB_BAR = 21,
    GOOP_WIDGET_TAB_ITEM = 22,
    GOOP_WIDGET_SPLITTER = 23,
    GOOP_WIDGET_SLIDER = 24,
    GOOP_WIDGET_SCROLL_AREA = 25,
    GOOP_WIDGET_TEXT_INPUT = 26,
} goop_widget_kind_t;

typedef struct {
    bool has_value;
    uint16_t value;
} goop_optional_u16_t;

typedef struct {
    bool has_value;
    uint8_t value;
} goop_optional_u8_t;

typedef struct {
    goop_direction_t direction;
} goop_container_widget_t;

typedef struct {
    goop_string_t content;
} goop_text_widget_t;

typedef struct {
    goop_string_t label;
} goop_button_widget_t;

typedef struct {
    goop_string_t label;
    bool checked;
} goop_checkbox_widget_t;

typedef struct {
    goop_string_t label;
    uint32_t group;
    bool selected;
} goop_radio_button_widget_t;

typedef struct {
    goop_string_t label;
    uint32_t group;
    bool editable;
    goop_tree_rename_trigger_t rename_trigger;
    bool expanded;
    bool selected;
} goop_tree_item_widget_t;

typedef struct {
    goop_string_t placeholder;
    goop_string_t selected_text;
    goop_optional_u16_t selected_index;
    bool open;
} goop_dropdown_widget_t;

typedef struct {
    goop_list_selection_mode_t selection_mode;
} goop_list_box_widget_t;

typedef struct {
    goop_string_t label;
    uint32_t group;
    bool selected;
} goop_selectable_widget_t;

typedef struct {
    uint8_t columns;
    bool striped;
    bool resizable;
    bool sortable;
    goop_table_selection_mode_t selection_mode;
    float min_column_width;
    goop_optional_u8_t sorted_column;
    goop_sort_direction_t sort_direction;
} goop_table_widget_t;

typedef struct {
    bool header;
    bool selected;
} goop_table_row_widget_t;

typedef struct {
    goop_popup_placement_t placement;
    float x;
    float y;
    bool visible;
    bool close_on_outside_click;
    int16_t z_index;
    bool pointer_passthrough;
} goop_popup_widget_t;

typedef struct {
    goop_popup_placement_t placement;
    float x;
    float y;
    int16_t z_index;
} goop_tooltip_widget_t;

typedef struct {
    goop_string_t label;
} goop_menu_widget_t;

typedef struct {
    goop_string_t label;
} goop_menu_item_widget_t;

typedef struct {
    float value;
    float min;
    float max;
    float speed;
    uint8_t precision;
} goop_drag_value_widget_t;

typedef struct {
    float value;
    float min;
    float max;
    float step;
    uint8_t precision;
} goop_spinbox_widget_t;

typedef struct {
    goop_string_t label;
    bool selected;
} goop_tab_item_widget_t;

typedef struct {
    goop_direction_t direction;
    float ratio;
    float min_first;
    float min_second;
    float thickness;
    float keyboard_step;
} goop_splitter_widget_t;

typedef struct {
    float value;
    float min;
    float max;
} goop_slider_widget_t;

typedef struct {
    float scroll_x;
    float scroll_y;
} goop_scroll_area_widget_t;

typedef struct {
    goop_string_t placeholder;
    goop_string_t value;
} goop_text_input_widget_t;

typedef struct {
    uint8_t _reserved;
} goop_unit_widget_t;

typedef struct {
    goop_widget_kind_t kind;
    union {
        goop_container_widget_t container;
        goop_text_widget_t text;
        goop_button_widget_t button;
        goop_checkbox_widget_t checkbox;
        goop_radio_button_widget_t radio_button;
        goop_tree_item_widget_t tree_item;
        goop_dropdown_widget_t dropdown;
        goop_list_box_widget_t list_box;
        goop_selectable_widget_t selectable;
        goop_table_widget_t table;
        goop_table_row_widget_t table_row;
        goop_unit_widget_t table_cell;
        goop_unit_widget_t toolbar;
        goop_unit_widget_t status_bar;
        goop_unit_widget_t menu_bar;
        goop_menu_widget_t menu;
        goop_popup_widget_t popup;
        goop_tooltip_widget_t tooltip;
        goop_menu_item_widget_t menu_item;
        goop_drag_value_widget_t drag_value;
        goop_spinbox_widget_t spinbox;
        goop_unit_widget_t tab_bar;
        goop_tab_item_widget_t tab_item;
        goop_splitter_widget_t splitter;
        goop_slider_widget_t slider;
        goop_scroll_area_widget_t scroll_area;
        goop_text_input_widget_t text_input;
    } data;
} goop_widget_t;

typedef enum {
    GOOP_MOUSE_LEFT = 0,
    GOOP_MOUSE_RIGHT = 1,
    GOOP_MOUSE_MIDDLE = 2,
} goop_mouse_button_t;

typedef enum {
    GOOP_BUTTON_PRESSED = 0,
    GOOP_BUTTON_RELEASED = 1,
} goop_mouse_button_state_t;

typedef enum {
    GOOP_KEY_PRESSED = 0,
    GOOP_KEY_RELEASED = 1,
    GOOP_KEY_REPEAT = 2,
} goop_key_state_t;

typedef enum {
    GOOP_KEYCODE_TAB = 0,
    GOOP_KEYCODE_ENTER = 1,
    GOOP_KEYCODE_SPACE = 2,
    GOOP_KEYCODE_ESCAPE = 3,
    GOOP_KEYCODE_BACKSPACE = 4,
    GOOP_KEYCODE_DELETE = 5,
    GOOP_KEYCODE_LEFT = 6,
    GOOP_KEYCODE_RIGHT = 7,
    GOOP_KEYCODE_UP = 8,
    GOOP_KEYCODE_DOWN = 9,
    GOOP_KEYCODE_HOME = 10,
    GOOP_KEYCODE_END = 11,
    GOOP_KEYCODE_LEFT_SHIFT = 12,
    GOOP_KEYCODE_RIGHT_SHIFT = 13,
    GOOP_KEYCODE_LEFT_CTRL = 14,
    GOOP_KEYCODE_RIGHT_CTRL = 15,
    GOOP_KEYCODE_A = 16,
    GOOP_KEYCODE_C = 17,
    GOOP_KEYCODE_V = 18,
    GOOP_KEYCODE_X = 19,
    GOOP_KEYCODE_UNKNOWN = 20,
} goop_keycode_t;

typedef enum {
    GOOP_EVENT_MOUSE_MOVE = 0,
    GOOP_EVENT_MOUSE_BUTTON = 1,
    GOOP_EVENT_MOUSE_SCROLL = 2,
    GOOP_EVENT_KEY = 3,
    GOOP_EVENT_TEXT = 4,
    GOOP_EVENT_FOCUS = 5,
    GOOP_EVENT_RESIZE = 6,
} goop_event_kind_t;

typedef struct {
    float x;
    float y;
} goop_mouse_move_event_t;

typedef struct {
    goop_mouse_button_t button;
    goop_mouse_button_state_t state;
    float x;
    float y;
    uint64_t timestamp_ms;
} goop_mouse_button_event_t;

typedef struct {
    float dx;
    float dy;
} goop_mouse_scroll_event_t;

typedef struct {
    uint32_t scancode;
    goop_keycode_t keycode;
    goop_key_state_t state;
} goop_key_event_t;

typedef struct {
    uint32_t codepoint;
} goop_text_event_t;

typedef struct {
    bool focused;
} goop_focus_event_t;

typedef struct {
    uint32_t width;
    uint32_t height;
} goop_resize_event_t;

typedef struct {
    goop_event_kind_t kind;
    union {
        goop_mouse_move_event_t mouse_move;
        goop_mouse_button_event_t mouse_button;
        goop_mouse_scroll_event_t mouse_scroll;
        goop_key_event_t key;
        goop_text_event_t text;
        goop_focus_event_t focus;
        goop_resize_event_t resize;
    } data;
} goop_event_t;

typedef enum {
    GOOP_DRAW_RECT = 0,
    GOOP_DRAW_TEXT = 1,
    GOOP_DRAW_CLIP = 2,
} goop_draw_command_kind_t;

typedef struct {
    goop_rect_t bounds;
    goop_color_t color;
    goop_color_t border_color;
    float border_width;
    float corner_radius;
} goop_draw_rect_t;

typedef struct {
    float x;
    float y;
    goop_rect_t bounds;
    float baseline_y;
    goop_string_t text;
    goop_color_t color;
    float font_size;
} goop_draw_text_t;

typedef struct {
    bool has_bounds;
    goop_rect_t bounds;
} goop_clip_rect_t;

typedef struct {
    goop_draw_command_kind_t kind;
    union {
        goop_draw_rect_t rect;
        goop_draw_text_t text;
        goop_clip_rect_t clip;
    } data;
} goop_draw_command_t;

typedef struct {
    const goop_draw_command_t *commands;
    size_t len;
} goop_draw_list_t;

typedef struct {
    float width;
    float height;
    float ascent;
    float descent;
} goop_text_dimensions_t;

typedef goop_text_dimensions_t (*goop_measure_text_fn)(goop_string_t text, float font_size, void *user_data);

typedef struct {
    goop_measure_text_fn measure_fn;
    void *user_data;
} goop_text_measure_ctx_t;

typedef goop_string_t (*goop_clipboard_get_text_fn)(void *ptr);
typedef void (*goop_clipboard_set_text_fn)(void *ptr, goop_string_t text);

typedef struct {
    void *ptr;
    goop_clipboard_get_text_fn get_text_fn;
    goop_clipboard_set_text_fn set_text_fn;
} goop_clipboard_t;

typedef struct {
    uint32_t width;
    uint32_t height;
    bool has_theme;
    goop_theme_t theme;
} goop_context_options_t;

typedef struct {
    goop_node_handle_t target;
    float x;
    float y;
} goop_secondary_click_t;

goop_theme_t goop_default_theme(void);

goop_context_t *goop_context_create(const goop_context_options_t *opts);
void goop_context_destroy(goop_context_t *ctx);

bool goop_context_set_theme(goop_context_t *ctx, const goop_theme_t *theme);
bool goop_context_set_clipboard(goop_context_t *ctx, const goop_clipboard_t *clipboard);
bool goop_context_clear_clicked_flags(goop_context_t *ctx);
bool goop_context_push_event(goop_context_t *ctx, const goop_event_t *ev);
bool goop_context_process_events(goop_context_t *ctx);
bool goop_context_do_layout(goop_context_t *ctx, const goop_text_measure_ctx_t *measure);
bool goop_context_generate_draw_list(goop_context_t *ctx, goop_draw_list_t *out_draw_list);
void goop_context_free_draw_list(goop_context_t *ctx, goop_draw_list_t *draw_list);
bool goop_context_set_dimensions(goop_context_t *ctx, uint32_t width, uint32_t height);

bool goop_context_add_root(goop_context_t *ctx, const goop_widget_t *desc, goop_node_handle_t *out_handle);
bool goop_context_add_child(goop_context_t *ctx, goop_node_handle_t parent, const goop_widget_t *desc, goop_node_handle_t *out_handle);
bool goop_context_update_widget(goop_context_t *ctx, goop_node_handle_t handle, const goop_widget_t *desc);
bool goop_context_set_style(goop_context_t *ctx, goop_node_handle_t handle, const goop_style_t *style);
bool goop_context_remove_widget(goop_context_t *ctx, goop_node_handle_t handle);
bool goop_context_is_alive(const goop_context_t *ctx, goop_node_handle_t handle);
bool goop_context_layout_rect(const goop_context_t *ctx, goop_node_handle_t handle, goop_rect_t *out_rect);

bool goop_context_was_clicked(const goop_context_t *ctx, goop_node_handle_t handle);
bool goop_context_was_secondary_clicked(const goop_context_t *ctx, goop_node_handle_t handle);
bool goop_context_is_checked(const goop_context_t *ctx, goop_node_handle_t handle);
bool goop_context_is_selected(const goop_context_t *ctx, goop_node_handle_t handle);
bool goop_context_is_expanded(const goop_context_t *ctx, goop_node_handle_t handle);
bool goop_context_tree_item_toggled(const goop_context_t *ctx, goop_node_handle_t handle);
goop_string_t goop_context_tree_item_label(const goop_context_t *ctx, goop_node_handle_t handle);
bool goop_context_tree_item_editing(const goop_context_t *ctx, goop_node_handle_t handle);
bool goop_context_tree_item_rename_committed(const goop_context_t *ctx, goop_node_handle_t handle);
float goop_context_slider_value(const goop_context_t *ctx, goop_node_handle_t handle);
float goop_context_drag_value(const goop_context_t *ctx, goop_node_handle_t handle);
bool goop_context_drag_value_changed(const goop_context_t *ctx, goop_node_handle_t handle);
float goop_context_spinbox_value(const goop_context_t *ctx, goop_node_handle_t handle);
bool goop_context_spinbox_changed(const goop_context_t *ctx, goop_node_handle_t handle);
float goop_context_splitter_ratio(const goop_context_t *ctx, goop_node_handle_t handle);
bool goop_context_splitter_changed(const goop_context_t *ctx, goop_node_handle_t handle);
goop_string_t goop_context_text_input_value(const goop_context_t *ctx, goop_node_handle_t handle);
goop_string_t goop_context_dropdown_value(const goop_context_t *ctx, goop_node_handle_t handle);
bool goop_context_dropdown_selected_index(const goop_context_t *ctx, goop_node_handle_t handle, uint16_t *out_index);
bool goop_context_dropdown_changed(const goop_context_t *ctx, goop_node_handle_t handle);
bool goop_context_list_box_selected_index(const goop_context_t *ctx, goop_node_handle_t handle, uint16_t *out_index);
bool goop_context_list_box_changed(const goop_context_t *ctx, goop_node_handle_t handle);
uint16_t goop_context_list_box_selection_count(const goop_context_t *ctx, goop_node_handle_t handle);
bool goop_context_table_column_fraction(const goop_context_t *ctx, goop_node_handle_t handle, uint8_t index, float *out_fraction);
bool goop_context_table_changed(const goop_context_t *ctx, goop_node_handle_t handle);
bool goop_context_table_resized_column(const goop_context_t *ctx, goop_node_handle_t handle, uint8_t *out_index);
bool goop_context_table_sorted_column(const goop_context_t *ctx, goop_node_handle_t handle, uint8_t *out_index);
bool goop_context_table_sort_direction(const goop_context_t *ctx, goop_node_handle_t handle, goop_sort_direction_t *out_direction);
bool goop_context_table_sort_changed(const goop_context_t *ctx, goop_node_handle_t handle);
bool goop_context_table_selection_changed(const goop_context_t *ctx, goop_node_handle_t handle);
uint16_t goop_context_table_selection_count(const goop_context_t *ctx, goop_node_handle_t handle);
bool goop_context_table_selected_row_index(const goop_context_t *ctx, goop_node_handle_t handle, uint16_t *out_index);
bool goop_context_last_secondary_click(const goop_context_t *ctx, goop_secondary_click_t *out_click);

#ifdef __cplusplus
}
#endif

#endif
