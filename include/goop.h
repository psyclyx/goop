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

typedef uint64_t goop_element_id_t;
typedef uint64_t goop_action_id_t;

typedef struct {
    goop_action_id_t value;
    bool has_value;
} goop_optional_action_id_t;

typedef struct {
    goop_element_id_t value;
    bool has_value;
} goop_optional_element_id_t;

typedef struct {
    goop_element_id_t element_id;
    goop_optional_action_id_t action_id;
} goop_control_identity_t;

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

/* A resolved style contains no optionals: every field is ready for a look to
 * consume. It intentionally shares the theme's concrete value layout. */
typedef goop_theme_t goop_resolved_style_t;

typedef struct {
    bool has_bg;
    goop_color_t bg;
    bool has_fg;
    goop_color_t fg;
    bool has_accent;
    goop_color_t accent;
    bool has_border;
    goop_color_t border;
    bool has_bg_hover;
    goop_color_t bg_hover;
    bool has_bg_active;
    goop_color_t bg_active;
    bool has_focus_ring;
    goop_color_t focus_ring;
    bool has_placeholder_fg;
    goop_color_t placeholder_fg;
    bool has_selection_bg;
    goop_color_t selection_bg;
    bool has_tree_guide;
    goop_color_t tree_guide;
    bool has_font_size;
    float font_size;
    bool has_padding;
    goop_edges_t padding;
    bool has_border_radius;
    float border_radius;
    bool has_border_width;
    float border_width;
    bool has_spacing;
    float spacing;
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
    GOOP_WIDGET_ICON = 2,
    GOOP_WIDGET_BUTTON = 3,
    GOOP_WIDGET_CHECKBOX = 4,
    GOOP_WIDGET_RADIO_BUTTON = 5,
    GOOP_WIDGET_TREE_ITEM = 6,
    GOOP_WIDGET_DROPDOWN = 7,
    GOOP_WIDGET_LIST_BOX = 8,
    GOOP_WIDGET_SELECTABLE = 9,
    GOOP_WIDGET_GRID_SELECTOR = 10,
    GOOP_WIDGET_GRID_ITEM = 11,
    GOOP_WIDGET_TABLE = 12,
    GOOP_WIDGET_TABLE_ROW = 13,
    GOOP_WIDGET_TABLE_CELL = 14,
    GOOP_WIDGET_TOOLBAR = 15,
    GOOP_WIDGET_STATUS_BAR = 16,
    GOOP_WIDGET_MENU_BAR = 17,
    GOOP_WIDGET_MENU = 18,
    GOOP_WIDGET_POPUP = 19,
    GOOP_WIDGET_TOOLTIP = 20,
    GOOP_WIDGET_MENU_ITEM = 21,
    GOOP_WIDGET_DRAG_VALUE = 22,
    GOOP_WIDGET_SPINBOX = 23,
    GOOP_WIDGET_TAB_BAR = 24,
    GOOP_WIDGET_TAB_ITEM = 25,
    GOOP_WIDGET_SPLITTER = 26,
    GOOP_WIDGET_SLIDER = 27,
    GOOP_WIDGET_SCROLL_AREA = 28,
    GOOP_WIDGET_TEXT_INPUT = 29,
    GOOP_WIDGET_SPACER = 30,
    GOOP_WIDGET_CUSTOM = 31,
} goop_widget_kind_t;

typedef struct {
    bool has_value;
    uint32_t value;
} goop_optional_u32_t;

typedef struct {
    bool has_value;
    uint16_t value;
} goop_optional_u16_t;

typedef struct {
    bool has_value;
    uint8_t value;
} goop_optional_u8_t;

typedef struct {
    bool has_value;
    goop_color_t value;
} goop_optional_color_t;

typedef struct {
    goop_direction_t direction;
} goop_container_widget_t;

typedef struct {
    goop_string_t content;
} goop_text_widget_t;

typedef struct {
    uint32_t kind;
    goop_optional_color_t color;
} goop_icon_widget_t;

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
    goop_optional_u32_t icon;
    goop_optional_color_t icon_color;
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
    goop_list_selection_mode_t selection_mode;
    float item_width;
    float item_height;
    float column_gap;
    float row_gap;
} goop_grid_selector_widget_t;

typedef struct {
    goop_string_t label;
    goop_optional_u32_t icon;
    goop_optional_color_t icon_color;
    bool selected;
} goop_grid_item_widget_t;

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
    uint32_t delay_ms;
} goop_tooltip_widget_t;

typedef struct {
    goop_string_t label;
} goop_menu_widget_t;

typedef struct {
    goop_string_t label;
    goop_string_t shortcut;
    bool checked;
    bool disabled;
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
    bool disable_horizontal_scroll;
    bool disable_vertical_scroll;
} goop_scroll_area_widget_t;

typedef struct {
    goop_string_t placeholder;
    goop_string_t value;
} goop_text_input_widget_t;

typedef struct {
    float width;
    float height;
} goop_spacer_widget_t;

typedef struct {
    uint64_t type_id;
    float width;
    float height;
    float min_width;
    float min_height;
    bool grow_width;
    bool grow_height;
    bool focusable;
} goop_custom_widget_t;

typedef struct {
    uint8_t _reserved;
} goop_unit_widget_t;

typedef struct {
    goop_widget_kind_t kind;
    union {
        goop_container_widget_t container;
        goop_text_widget_t text;
        goop_icon_widget_t icon;
        goop_button_widget_t button;
        goop_checkbox_widget_t checkbox;
        goop_radio_button_widget_t radio_button;
        goop_tree_item_widget_t tree_item;
        goop_dropdown_widget_t dropdown;
        goop_list_box_widget_t list_box;
        goop_selectable_widget_t selectable;
        goop_grid_selector_widget_t grid_selector;
        goop_grid_item_widget_t grid_item;
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
        goop_spacer_widget_t spacer;
        goop_custom_widget_t custom;
    } data;
} goop_widget_t;

/* Every live element_id must be unique. action_id is optional application
 * routing metadata and does not determine widget identity. */
typedef struct {
    goop_control_identity_t identity;
    goop_widget_t widget;
} goop_control_desc_t;

/* Read-only persistent/current widget state returned by goop_context_node(). */

typedef struct { goop_direction_t direction; } goop_container_view_t;
typedef struct { goop_string_t content; } goop_text_view_t;
typedef struct {
    uint32_t kind;
    goop_optional_color_t color;
} goop_icon_view_t;
typedef struct { goop_string_t label; } goop_button_view_t;

typedef struct {
    goop_string_t label;
    bool checked;
} goop_checkbox_view_t;

typedef struct {
    goop_string_t label;
    uint32_t group;
    bool selected;
} goop_radio_button_view_t;

typedef struct {
    goop_string_t label;
    uint32_t group;
    goop_optional_u32_t icon;
    goop_optional_color_t icon_color;
    bool has_children;
    bool expanded;
    bool selected;
    bool editing;
    bool dragging;
} goop_tree_item_view_t;

typedef struct {
    goop_string_t placeholder;
    goop_string_t selected_text;
    goop_optional_u16_t selected_index;
    bool open;
} goop_dropdown_view_t;

typedef struct { uint8_t _reserved; } goop_list_box_view_t;

typedef struct {
    goop_string_t label;
    uint32_t group;
    bool selected;
    bool dragging;
} goop_selectable_view_t;

typedef struct {
    uint16_t computed_columns;
} goop_grid_selector_view_t;

typedef struct {
    goop_string_t label;
    goop_optional_u32_t icon;
    goop_optional_color_t icon_color;
    bool selected;
    bool dragging;
} goop_grid_item_view_t;

typedef struct {
    uint8_t active_columns;
    goop_optional_u8_t sorted_column;
    goop_sort_direction_t sort_direction;
} goop_table_view_t;

typedef struct {
    bool header;
    bool selected;
    bool dragging;
} goop_table_row_view_t;

typedef struct { goop_string_t label; } goop_menu_view_t;

typedef struct {
    goop_popup_placement_t placement;
    float x;
    float y;
    bool visible;
    int16_t z_index;
} goop_popup_view_t;

typedef struct {
    goop_popup_placement_t placement;
    float x;
    float y;
    int16_t z_index;
    bool visible;
} goop_tooltip_view_t;

typedef struct {
    bool changed;
    bool has_next_deadline;
    uint64_t next_deadline_ms;
} goop_update_result_t;

typedef struct {
    goop_string_t label;
    goop_string_t shortcut;
    bool checked;
    bool disabled;
} goop_menu_item_view_t;

typedef struct {
    float value;
    bool editing;
    goop_string_t display_text;
} goop_drag_value_view_t;

typedef struct {
    float value;
    bool editing;
    goop_string_t display_text;
} goop_spinbox_view_t;

typedef struct {
    goop_string_t label;
    bool selected;
} goop_tab_item_view_t;

typedef struct {
    float ratio;
} goop_splitter_view_t;

typedef struct { float value; } goop_slider_view_t;

typedef struct {
    float scroll_x;
    float scroll_y;
} goop_scroll_area_view_t;

typedef struct {
    goop_string_t content;
    uint8_t cursor;
    goop_optional_u8_t selection_anchor;
} goop_text_input_view_t;

typedef struct {
    uint64_t type_id;
    float width;
    float height;
    float min_width;
    float min_height;
    bool grow_width;
    bool grow_height;
    bool focusable;
} goop_custom_view_t;

typedef struct {
    goop_widget_kind_t kind;
    union {
        goop_container_view_t container;
        goop_text_view_t text;
        goop_icon_view_t icon;
        goop_button_view_t button;
        goop_checkbox_view_t checkbox;
        goop_radio_button_view_t radio_button;
        goop_tree_item_view_t tree_item;
        goop_dropdown_view_t dropdown;
        goop_list_box_view_t list_box;
        goop_selectable_view_t selectable;
        goop_grid_selector_view_t grid_selector;
        goop_grid_item_view_t grid_item;
        goop_table_view_t table;
        goop_table_row_view_t table_row;
        goop_unit_widget_t table_cell;
        goop_unit_widget_t toolbar;
        goop_unit_widget_t status_bar;
        goop_unit_widget_t menu_bar;
        goop_menu_view_t menu;
        goop_popup_view_t popup;
        goop_tooltip_view_t tooltip;
        goop_menu_item_view_t menu_item;
        goop_drag_value_view_t drag_value;
        goop_spinbox_view_t spinbox;
        goop_unit_widget_t tab_bar;
        goop_tab_item_view_t tab_item;
        goop_splitter_view_t splitter;
        goop_slider_view_t slider;
        goop_scroll_area_view_t scroll_area;
        goop_text_input_view_t text_input;
        goop_unit_widget_t spacer;
        goop_custom_view_t custom;
    } data;
} goop_widget_view_t;

typedef struct {
    goop_optional_element_id_t id;
    goop_optional_element_id_t parent_id;
    goop_optional_action_id_t action_id;
    goop_rect_t bounds;
    goop_resolved_style_t style;
    goop_widget_view_t widget;
    bool focused;
    bool hovered;
    bool pressed;
    bool drop_hovered;
} goop_resolved_element_t;

typedef void (*goop_resolved_element_fn)(void *user_data, const goop_resolved_element_t *element);

typedef struct {
    goop_resolved_element_fn enter;
    goop_resolved_element_fn leave;
    void *user_data;
} goop_resolved_visitor_t;

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
    GOOP_KEYCODE_A = 0, GOOP_KEYCODE_B, GOOP_KEYCODE_C, GOOP_KEYCODE_D,
    GOOP_KEYCODE_E, GOOP_KEYCODE_F, GOOP_KEYCODE_G, GOOP_KEYCODE_H,
    GOOP_KEYCODE_I, GOOP_KEYCODE_J, GOOP_KEYCODE_K, GOOP_KEYCODE_L,
    GOOP_KEYCODE_M, GOOP_KEYCODE_N, GOOP_KEYCODE_O, GOOP_KEYCODE_P,
    GOOP_KEYCODE_Q, GOOP_KEYCODE_R, GOOP_KEYCODE_S, GOOP_KEYCODE_T,
    GOOP_KEYCODE_U, GOOP_KEYCODE_V, GOOP_KEYCODE_W, GOOP_KEYCODE_X,
    GOOP_KEYCODE_Y, GOOP_KEYCODE_Z,
    GOOP_KEYCODE_DIGIT_0, GOOP_KEYCODE_DIGIT_1, GOOP_KEYCODE_DIGIT_2,
    GOOP_KEYCODE_DIGIT_3, GOOP_KEYCODE_DIGIT_4, GOOP_KEYCODE_DIGIT_5,
    GOOP_KEYCODE_DIGIT_6, GOOP_KEYCODE_DIGIT_7, GOOP_KEYCODE_DIGIT_8,
    GOOP_KEYCODE_DIGIT_9,
    GOOP_KEYCODE_F1, GOOP_KEYCODE_F2, GOOP_KEYCODE_F3, GOOP_KEYCODE_F4,
    GOOP_KEYCODE_F5, GOOP_KEYCODE_F6, GOOP_KEYCODE_F7, GOOP_KEYCODE_F8,
    GOOP_KEYCODE_F9, GOOP_KEYCODE_F10, GOOP_KEYCODE_F11, GOOP_KEYCODE_F12,
    GOOP_KEYCODE_F13, GOOP_KEYCODE_F14, GOOP_KEYCODE_F15, GOOP_KEYCODE_F16,
    GOOP_KEYCODE_F17, GOOP_KEYCODE_F18, GOOP_KEYCODE_F19, GOOP_KEYCODE_F20,
    GOOP_KEYCODE_F21, GOOP_KEYCODE_F22, GOOP_KEYCODE_F23, GOOP_KEYCODE_F24,
    GOOP_KEYCODE_SPACE, GOOP_KEYCODE_TAB, GOOP_KEYCODE_ENTER,
    GOOP_KEYCODE_BACKSPACE, GOOP_KEYCODE_DELETE, GOOP_KEYCODE_INSERT,
    GOOP_KEYCODE_LEFT, GOOP_KEYCODE_RIGHT, GOOP_KEYCODE_UP, GOOP_KEYCODE_DOWN,
    GOOP_KEYCODE_HOME, GOOP_KEYCODE_END, GOOP_KEYCODE_PAGE_UP, GOOP_KEYCODE_PAGE_DOWN,
    GOOP_KEYCODE_ESCAPE,
    GOOP_KEYCODE_MINUS, GOOP_KEYCODE_EQUAL,
    GOOP_KEYCODE_LEFT_BRACKET, GOOP_KEYCODE_RIGHT_BRACKET,
    GOOP_KEYCODE_BACKSLASH, GOOP_KEYCODE_SEMICOLON, GOOP_KEYCODE_APOSTROPHE,
    GOOP_KEYCODE_COMMA, GOOP_KEYCODE_PERIOD, GOOP_KEYCODE_SLASH, GOOP_KEYCODE_GRAVE,
    GOOP_KEYCODE_LEFT_SHIFT, GOOP_KEYCODE_RIGHT_SHIFT,
    GOOP_KEYCODE_LEFT_CTRL, GOOP_KEYCODE_RIGHT_CTRL,
    GOOP_KEYCODE_LEFT_ALT, GOOP_KEYCODE_RIGHT_ALT,
    GOOP_KEYCODE_LEFT_SUPER, GOOP_KEYCODE_RIGHT_SUPER,
    GOOP_KEYCODE_CAPS_LOCK, GOOP_KEYCODE_NUM_LOCK,
    GOOP_KEYCODE_UNKNOWN,
} goop_keycode_t;

/* Modifier-key state bitmask. The embedder fills `mods` on key,
 * mouse_button, and mouse_scroll events to communicate which modifiers
 * are held at the time of the event. Bit layout matches Zig's
 * `Event.Modifiers` packed struct. */
typedef uint32_t goop_modifiers_t;
#define GOOP_MOD_NONE        ((goop_modifiers_t)0)
#define GOOP_MOD_SHIFT       ((goop_modifiers_t)(1u << 0))
#define GOOP_MOD_CTRL        ((goop_modifiers_t)(1u << 1))
#define GOOP_MOD_ALT         ((goop_modifiers_t)(1u << 2))
#define GOOP_MOD_SUPER       ((goop_modifiers_t)(1u << 3))
#define GOOP_MOD_CAPS_LOCK   ((goop_modifiers_t)(1u << 4))
#define GOOP_MOD_NUM_LOCK    ((goop_modifiers_t)(1u << 5))

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
    goop_modifiers_t mods;
} goop_mouse_button_event_t;

typedef struct {
    float dx;
    float dy;
    goop_modifiers_t mods;
} goop_mouse_scroll_event_t;

typedef struct {
    goop_keycode_t keycode;
    goop_modifiers_t mods;
    goop_key_state_t state;
    uint32_t scancode;
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
    size_t start;
    size_t len;
} goop_payload_span_t;

typedef enum {
    GOOP_CONTROL_EVENT_ACTIVATED = 0,
    GOOP_CONTROL_EVENT_SECONDARY_ACTIVATED = 1,
    GOOP_CONTROL_EVENT_VALUE_CHANGED = 2,
    GOOP_CONTROL_EVENT_TOGGLE_CHANGED = 3,
    GOOP_CONTROL_EVENT_TEXT_CHANGED = 4,
    GOOP_CONTROL_EVENT_SORT_CHANGED = 5,
    GOOP_CONTROL_EVENT_SELECTION_CHANGED = 6,
    GOOP_CONTROL_EVENT_SCROLL_CHANGED = 7,
    GOOP_CONTROL_EVENT_DROP = 8,
    GOOP_CONTROL_EVENT_POPUP_VISIBILITY_CHANGED = 9,
} goop_control_event_kind_t;

typedef struct {
    goop_element_id_t element;
    goop_optional_action_id_t action;
} goop_activation_t;

typedef struct {
    goop_element_id_t element;
    goop_optional_action_id_t action;
    float x;
    float y;
} goop_secondary_activation_t;

typedef enum {
    GOOP_CONTROL_VALUE_SCALAR = 0,
    GOOP_CONTROL_VALUE_INDEX = 1,
    GOOP_CONTROL_VALUE_COLUMN_FRACTION = 2,
} goop_control_value_kind_t;

typedef struct {
    uint8_t column;
    float fraction;
} goop_column_fraction_t;

typedef struct {
    goop_control_value_kind_t kind;
    union {
        float scalar;
        goop_optional_u16_t index;
        goop_column_fraction_t column_fraction;
    } data;
} goop_control_value_t;

typedef struct {
    goop_element_id_t element;
    goop_control_value_t value;
} goop_value_changed_t;

typedef struct {
    goop_element_id_t element;
    bool value;
} goop_toggle_changed_t;

typedef struct {
    goop_element_id_t element;
    goop_payload_span_t text;
    bool committed;
} goop_text_changed_t;

typedef struct {
    goop_element_id_t element;
    uint8_t column;
    goop_sort_direction_t direction;
} goop_sort_changed_t;

typedef struct {
    goop_element_id_t element;
    goop_payload_span_t selected;
} goop_selection_changed_t;

typedef struct {
    goop_element_id_t element;
    float x;
    float y;
} goop_scroll_changed_t;

typedef struct {
    goop_element_id_t element;
    bool visible;
} goop_popup_visibility_changed_t;

typedef enum {
    GOOP_DROP_POSITION_BEFORE = 0,
    GOOP_DROP_POSITION_INSIDE = 1,
    GOOP_DROP_POSITION_AFTER = 2,
    GOOP_DROP_POSITION_ITEM = 3,
    GOOP_DROP_POSITION_BACKGROUND = 4,
    GOOP_DROP_POSITION_POINT = 5,
} goop_drop_position_kind_t;

typedef struct {
    goop_drop_position_kind_t kind;
    float x;
    float y;
} goop_drop_position_t;

typedef struct {
    goop_element_id_t source;
    goop_element_id_t target;
    goop_drop_position_t position;
    goop_modifiers_t modifiers;
} goop_control_drop_t;

typedef struct {
    goop_control_event_kind_t kind;
    union {
        goop_activation_t activated;
        goop_secondary_activation_t secondary_activated;
        goop_value_changed_t value_changed;
        goop_toggle_changed_t toggle_changed;
        goop_text_changed_t text_changed;
        goop_sort_changed_t sort_changed;
        goop_selection_changed_t selection_changed;
        goop_scroll_changed_t scroll_changed;
        goop_popup_visibility_changed_t popup_visibility_changed;
        goop_control_drop_t drop;
    } data;
} goop_control_event_t;

/* Borrowed ordered output. Every pointer remains valid until the next call to
 * goop_context_process_events or goop_context_destroy. Copy payloads that
 * must live longer. Text is UTF-8 and is not NUL-terminated. */
typedef struct {
    const goop_control_event_t *items;
    size_t len;
    const uint8_t *text_bytes;
    size_t text_bytes_len;
    const goop_element_id_t *selection_ids;
    size_t selection_ids_len;
} goop_control_events_t;

static inline goop_string_t goop_control_events_text(
    const goop_control_events_t *events,
    goop_payload_span_t span) {
    goop_string_t result = {0};
    if (!events || (span.len != 0 && !events->text_bytes) ||
        span.start > events->text_bytes_len ||
        span.len > events->text_bytes_len - span.start) return result;
    result.ptr = span.len == 0 ? NULL : (const char *)(events->text_bytes + span.start);
    result.len = span.len;
    return result;
}

typedef struct {
    const goop_element_id_t *ptr;
    size_t len;
} goop_element_id_list_t;

static inline goop_element_id_list_t goop_control_events_selection(
    const goop_control_events_t *events,
    goop_payload_span_t span) {
    goop_element_id_list_t result = {0};
    if (!events || (span.len != 0 && !events->selection_ids) ||
        span.start > events->selection_ids_len ||
        span.len > events->selection_ids_len - span.start) return result;
    result.ptr = span.len == 0 ? NULL : events->selection_ids + span.start;
    result.len = span.len;
    return result;
}

typedef struct {
    goop_rect_t rect;
    goop_control_identity_t identity;
    bool focused;
    bool accepts_drop;
    bool drop_hovered;
    goop_widget_view_t kind;
} goop_node_view_t;

goop_theme_t goop_default_theme(void);

goop_context_t *goop_context_create(const goop_context_options_t *opts);
void goop_context_destroy(goop_context_t *ctx);

bool goop_context_set_theme(goop_context_t *ctx, const goop_theme_t *theme);
bool goop_context_set_clipboard(goop_context_t *ctx, const goop_clipboard_t *clipboard);
bool goop_context_push_event(goop_context_t *ctx, const goop_event_t *ev);
bool goop_context_process_events(goop_context_t *ctx, goop_control_events_t *out_events);
bool goop_context_update(goop_context_t *ctx, uint64_t now_ms, goop_update_result_t *out_result);
bool goop_context_do_layout(goop_context_t *ctx, const goop_text_measure_ctx_t *measure);
bool goop_context_set_dimensions(goop_context_t *ctx, uint32_t width, uint32_t height);

bool goop_context_add_root(goop_context_t *ctx, const goop_control_desc_t *desc, goop_node_handle_t *out_handle);
bool goop_context_add_child(goop_context_t *ctx, goop_node_handle_t parent, const goop_control_desc_t *desc, goop_node_handle_t *out_handle);
bool goop_context_update_widget(goop_context_t *ctx, goop_node_handle_t handle, const goop_widget_t *desc);
bool goop_context_set_style(goop_context_t *ctx, goop_node_handle_t handle, const goop_style_t *style);
bool goop_context_remove_widget(goop_context_t *ctx, goop_node_handle_t handle);
bool goop_context_is_alive(const goop_context_t *ctx, goop_node_handle_t handle);
bool goop_context_find_element(const goop_context_t *ctx, goop_element_id_t element, goop_node_handle_t *out_handle);

bool goop_context_invalidate(goop_context_t *ctx);

/* Allocation-free, synchronous depth-first traversal for custom looks.
 * enter and leave are both required and receive equivalent resolved values for
 * each element. The element pointer is valid only during its callback.
 * Callbacks must not mutate ctx or retain borrowed strings. */
bool goop_context_visit_resolved(const goop_context_t *ctx, const goop_resolved_visitor_t *visitor);

/* Read-only persistent/current state; occurrence output is returned only by
 * goop_context_process_events. */
bool goop_context_node(const goop_context_t *ctx, goop_node_handle_t handle, goop_node_view_t *out_node);
bool goop_context_table_column_fraction(const goop_context_t *ctx, goop_node_handle_t handle, uint8_t index, float *out_fraction);

bool goop_context_set_accepts_drop(goop_context_t *ctx, goop_element_id_t element, bool accepts_drop);

bool goop_context_focus_element(goop_context_t *ctx, goop_element_id_t element);
bool goop_context_clear_focus(goop_context_t *ctx);
bool goop_context_cancel_pointer_gesture(goop_context_t *ctx);

#ifdef __cplusplus
}
#endif

#endif
