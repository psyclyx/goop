/// Input events pushed by the embedder.
pub const Event = union(enum) {
    mouse_move: MouseMove,
    mouse_button: MouseButton,
    mouse_scroll: MouseScroll,
    key: Key,
    text: Text,
    focus: Focus,
    resize: Resize,

    pub const MouseMove = struct {
        x: f32,
        y: f32,
    };

    pub const MouseButton = struct {
        button: Button,
        state: ButtonState,
        x: f32,
        y: f32,
        timestamp_ms: u64 = 0,

        pub const Button = enum { left, right, middle };
        pub const ButtonState = enum { pressed, released };
    };

    pub const MouseScroll = struct {
        dx: f32,
        dy: f32,
    };

    pub const Key = struct {
        scancode: u32,
        keycode: Keycode = .unknown,
        state: KeyState,

        pub const KeyState = enum { pressed, released, repeat };
    };

    /// Logical key identifiers, independent of platform scancodes.
    /// The embedder maps platform-specific scancodes to these.
    pub const Keycode = enum {
        tab,
        enter,
        space,
        escape,
        backspace,
        delete,
        left,
        right,
        home,
        end,
        left_shift,
        right_shift,
        left_ctrl,
        right_ctrl,
        a,
        unknown,
    };

    pub const Text = struct {
        codepoint: u21,
    };

    pub const Focus = struct {
        focused: bool,
    };

    pub const Resize = struct {
        width: u32,
        height: u32,
    };
};
