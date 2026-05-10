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
        mods: Modifiers = .{},

        pub const Button = enum { left, right, middle };
        pub const ButtonState = enum { pressed, released };
    };

    pub const MouseScroll = struct {
        dx: f32,
        dy: f32,
        mods: Modifiers = .{},
    };

    pub const Key = struct {
        keycode: Keycode = .unknown,
        mods: Modifiers = .{},
        state: KeyState,
        /// Raw platform scancode. Useful for keys not represented in
        /// `Keycode` (set `keycode` to `.unknown` and forward the
        /// scancode to your embedder's own shortcut handling).
        scancode: u32 = 0,

        pub const KeyState = enum { pressed, released, repeat };
    };

    /// Modifier-key state at the time of the event. `goop` reads `mods`
    /// from each key/mouse event to decide shortcut behavior, so an
    /// embedder that fills these in once at translation time does not
    /// need to send separate `left_shift` / `left_ctrl` press events.
    pub const Modifiers = packed struct(u32) {
        shift: bool = false,
        ctrl: bool = false,
        alt: bool = false,
        super: bool = false,
        caps_lock: bool = false,
        num_lock: bool = false,
        _padding: u26 = 0,

        pub const none: Modifiers = .{};
    };

    /// Logical key identifiers. The embedder maps platform scancodes to
    /// these; unknown keys can be forwarded as `.unknown` plus a raw
    /// scancode in `Key.scancode` for embedder-specific handling.
    pub const Keycode = enum(u16) {
        // Letters
        a, b, c, d, e, f, g, h, i, j, k, l, m,
        n, o, p, q, r, s, t, u, v, w, x, y, z,

        // Digits (top row)
        digit_0, digit_1, digit_2, digit_3, digit_4,
        digit_5, digit_6, digit_7, digit_8, digit_9,

        // Function row
        f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12,
        f13, f14, f15, f16, f17, f18, f19, f20, f21, f22, f23, f24,

        // Whitespace
        space, tab, enter,

        // Editing
        backspace, delete, insert,

        // Navigation
        left, right, up, down, home, end, page_up, page_down,

        // Misc
        escape,
        minus, equal, left_bracket, right_bracket,
        backslash, semicolon, apostrophe, comma, period, slash, grave,

        // Modifier keys (sent by embedders that translate them as
        // distinct key events; the modifier state itself lives in
        // `Key.mods`).
        left_shift, right_shift,
        left_ctrl, right_ctrl,
        left_alt, right_alt,
        left_super, right_super,
        caps_lock, num_lock,

        /// No matching named key — see `Key.scancode` for the raw value.
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
