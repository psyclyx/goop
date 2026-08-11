#include "goop.h"

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

enum {
    ROOT_ELEMENT = 1,
    INPUT_ELEMENT = 2,
    APPLY_ELEMENT = 3,
    APPLY_ACTION = 30,
};

typedef struct {
    size_t enters;
    size_t leaves;
    size_t depth;
    size_t max_depth;
    bool saw_apply_visual;
} look_summary_t;

static void look_enter(void *user_data, const goop_resolved_element_t *element) {
    look_summary_t *summary = user_data;
    ++summary->enters;
    ++summary->depth;
    if (summary->depth > summary->max_depth) summary->max_depth = summary->depth;

    if (element->id.has_value && element->id.value == APPLY_ELEMENT &&
        element->widget.kind == GOOP_WIDGET_BUTTON && element->bounds.w > 0) {
        const goop_string_t label = element->widget.data.button.label;
        summary->saw_apply_visual = label.len == 5 && label.ptr &&
            memcmp(label.ptr, "Apply", 5) == 0;
    }
}

static void look_leave(void *user_data, const goop_resolved_element_t *element) {
    look_summary_t *summary = user_data;
    (void)element;
    ++summary->leaves;
    if (summary->depth > 0) --summary->depth;
}

static bool push_mouse_click(goop_context_t *ctx, goop_rect_t rect) {
    const float x = rect.x + rect.w * 0.5f;
    const float y = rect.y + rect.h * 0.5f;
    const goop_event_t press = {
        .kind = GOOP_EVENT_MOUSE_BUTTON,
        .data.mouse_button = {
            .button = GOOP_MOUSE_LEFT,
            .state = GOOP_BUTTON_PRESSED,
            .x = x,
            .y = y,
            .timestamp_ms = 1,
        },
    };
    const goop_event_t release = {
        .kind = GOOP_EVENT_MOUSE_BUTTON,
        .data.mouse_button = {
            .button = GOOP_MOUSE_LEFT,
            .state = GOOP_BUTTON_RELEASED,
            .x = x,
            .y = y,
            .timestamp_ms = 2,
        },
    };
    return goop_context_push_event(ctx, &press) &&
           goop_context_push_event(ctx, &release);
}

static bool push_text(goop_context_t *ctx, uint32_t codepoint) {
    const goop_event_t text = {
        .kind = GOOP_EVENT_TEXT,
        .data.text = { .codepoint = codepoint },
    };
    return goop_context_push_event(ctx, &text);
}

int main(void) {
    goop_context_t *ctx = goop_context_create(&(goop_context_options_t){
        .width = 480,
        .height = 240,
    });
    if (!ctx) return 1;

    goop_node_handle_t root = {0};
    goop_node_handle_t input = {0};
    goop_node_handle_t button = {0};
    if (!goop_context_add_root(ctx, &(goop_control_desc_t){
            .identity = { .element_id = ROOT_ELEMENT },
            .widget = {
                .kind = GOOP_WIDGET_CONTAINER,
                .data.container = { .direction = GOOP_DIRECTION_COLUMN },
            },
        }, &root) ||
        !goop_context_add_child(ctx, root, &(goop_control_desc_t){
            .identity = { .element_id = INPUT_ELEMENT },
            .widget = {
                .kind = GOOP_WIDGET_TEXT_INPUT,
                .data.text_input = {
                    .placeholder = goop_string_from_cstr("Name"),
                },
            },
        }, &input) ||
        !goop_context_add_child(ctx, root, &(goop_control_desc_t){
            .identity = {
                .element_id = APPLY_ELEMENT,
                .action_id = { .value = APPLY_ACTION, .has_value = true },
            },
            .widget = {
                .kind = GOOP_WIDGET_BUTTON,
                .data.button = { .label = goop_string_from_cstr("Apply") },
            },
        }, &button) ||
        !goop_context_do_layout(ctx, NULL)) {
        goop_context_destroy(ctx);
        return 1;
    }

    look_summary_t look = {0};
    const goop_resolved_visitor_t visitor = {
        .enter = look_enter,
        .leave = look_leave,
        .user_data = &look,
    };
    if (!goop_context_visit_resolved(ctx, &visitor) ||
        look.enters != 3 || look.leaves != 3 || look.depth != 0 ||
        look.max_depth != 2 || !look.saw_apply_visual) {
        fprintf(stderr, "failed to consume resolved UI with a custom look\n");
        goop_context_destroy(ctx);
        return 1;
    }

    goop_node_view_t input_node = {0};
    goop_node_view_t button_node = {0};
    if (!goop_context_node(ctx, input, &input_node) ||
        !goop_context_node(ctx, button, &button_node) ||
        input_node.identity.element_id != INPUT_ELEMENT ||
        button_node.identity.element_id != APPLY_ELEMENT) {
        goop_context_destroy(ctx);
        return 1;
    }

    if (!push_mouse_click(ctx, input_node.rect) ||
        !push_text(ctx, 'R') ||
        !push_text(ctx, 'e') ||
        !push_text(ctx, 'n') ||
        !push_text(ctx, 0x00E9) ||
        !push_mouse_click(ctx, button_node.rect)) {
        goop_context_destroy(ctx);
        return 1;
    }

    goop_control_events_t events = {0};
    if (!goop_context_process_events(ctx, &events)) {
        goop_context_destroy(ctx);
        return 1;
    }

    goop_string_t final_text = {0};
    bool applied = false;
    size_t text_changes = 0;
    for (size_t i = 0; i < events.len; ++i) {
        const goop_control_event_t *event = &events.items[i];
        if (event->kind == GOOP_CONTROL_EVENT_TEXT_CHANGED &&
            event->data.text_changed.element == INPUT_ELEMENT) {
            final_text = goop_control_events_text(&events, event->data.text_changed.text);
            ++text_changes;
        } else if (event->kind == GOOP_CONTROL_EVENT_ACTIVATED &&
                   event->data.activated.element == APPLY_ELEMENT) {
            const goop_optional_action_id_t action = event->data.activated.action;
            applied = action.has_value && action.value == APPLY_ACTION && text_changes == 4;
        }
    }

    const bool text_ok = final_text.len == 5 && final_text.ptr &&
        final_text.ptr[0] == 'R' && final_text.ptr[1] == 'e' && final_text.ptr[2] == 'n' &&
        (unsigned char)final_text.ptr[3] == 0xC3 &&
        (unsigned char)final_text.ptr[4] == 0xA9;
    if (!applied || !text_ok) {
        fprintf(stderr, "unexpected semantic event batch\n");
        goop_context_destroy(ctx);
        return 1;
    }

    printf("goop core C example: resolved=%zu events=%zu text=%.*s action=%u\n",
           look.enters, events.len, (int)final_text.len, final_text.ptr, APPLY_ACTION);
    goop_context_destroy(ctx);
    return 0;
}
