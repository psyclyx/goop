//! Normalized input values supplied by an embedding host.
//!
//! This leaf module has no window-system, renderer, UI-tree, or allocator
//! dependency. Platform integrations translate their native events into these
//! values; core interaction and desktop shortcuts consume this exact type.

const MouseMovePayload = struct {
    x: f32,
    y: f32,
};

const ButtonCode = enum { left, right, middle };
const ButtonStateValue = enum { pressed, released };

const ModifiersValue = packed struct(u32) {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    super: bool = false,
    caps_lock: bool = false,
    num_lock: bool = false,
    _padding: u26 = 0,

    pub const none: ModifiersValue = .{};
};

const MouseButtonPayload = struct {
    button: ButtonCode,
    state: ButtonStateValue,
    x: f32,
    y: f32,
    timestamp_ms: u64 = 0,
    mods: ModifiersValue = .{},

    pub const Button = ButtonCode;
    pub const ButtonState = ButtonStateValue;
};

const MouseScrollPayload = struct {
    dx: f32,
    dy: f32,
    mods: ModifiersValue = .{},
};

const KeycodeValue = enum(u16) {
    a,
    b,
    c,
    d,
    e,
    f,
    g,
    h,
    i,
    j,
    k,
    l,
    m,
    n,
    o,
    p,
    q,
    r,
    s,
    t,
    u,
    v,
    w,
    x,
    y,
    z,

    digit_0,
    digit_1,
    digit_2,
    digit_3,
    digit_4,
    digit_5,
    digit_6,
    digit_7,
    digit_8,
    digit_9,

    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
    f13,
    f14,
    f15,
    f16,
    f17,
    f18,
    f19,
    f20,
    f21,
    f22,
    f23,
    f24,

    space,
    tab,
    enter,
    backspace,
    delete,
    insert,
    left,
    right,
    up,
    down,
    home,
    end,
    page_up,
    page_down,

    escape,
    minus,
    equal,
    left_bracket,
    right_bracket,
    backslash,
    semicolon,
    apostrophe,
    comma,
    period,
    slash,
    grave,

    left_shift,
    right_shift,
    left_ctrl,
    right_ctrl,
    left_alt,
    right_alt,
    left_super,
    right_super,
    caps_lock,
    num_lock,

    unknown,
};

const KeyStateValue = enum { pressed, released, repeat };

const KeyPayload = struct {
    keycode: KeycodeValue = .unknown,
    mods: ModifiersValue = .{},
    state: KeyStateValue,
    /// Raw platform scancode for keys outside the normalized vocabulary.
    scancode: u32 = 0,

    pub const KeyState = KeyStateValue;
};

const TextPayload = struct {
    codepoint: u21,
};

const FocusPayload = struct {
    focused: bool,
};

const ResizePayload = struct {
    width: u32,
    height: u32,
};

pub const Event = union(enum) {
    mouse_move: MouseMovePayload,
    mouse_button: MouseButtonPayload,
    mouse_scroll: MouseScrollPayload,
    key: KeyPayload,
    text: TextPayload,
    focus: FocusPayload,
    resize: ResizePayload,

    pub const MouseMove = MouseMovePayload;
    pub const MouseButton = MouseButtonPayload;
    pub const MouseScroll = MouseScrollPayload;
    pub const Key = KeyPayload;
    pub const Text = TextPayload;
    pub const Focus = FocusPayload;
    pub const Resize = ResizePayload;
    /// Modifier-key state at the time of the event. Consumers read this
    /// snapshot rather than inferring it from a platform-specific key stream.
    pub const Modifiers = ModifiersValue;
    /// Logical key identifiers. Native integrations map their key vocabulary
    /// here; unknown keys retain their raw value in `Key.scancode`.
    pub const Keycode = KeycodeValue;
};

// Exact aliases for consumers that deal in one kind of input value without
// spelling the Event namespace. These introduce no second representation.
pub const MouseMove = Event.MouseMove;
pub const MouseButton = Event.MouseButton;
pub const MouseScroll = Event.MouseScroll;
pub const Key = Event.Key;
pub const Text = Event.Text;
pub const Focus = Event.Focus;
pub const Resize = Event.Resize;
pub const Modifiers = Event.Modifiers;
pub const Keycode = Event.Keycode;
pub const Button = Event.MouseButton.Button;
pub const ButtonState = Event.MouseButton.ButtonState;
pub const KeyState = Event.Key.KeyState;

/// The same normalized key vocabulary is used by shortcut descriptions.
pub const Shortcut = struct {
    keycode: Keycode,
    modifiers: Modifiers = .{},
};

test "top-level input names are exact Event member aliases" {
    if (MouseMove != Event.MouseMove) @compileError("MouseMove identity split");
    if (MouseButton != Event.MouseButton) @compileError("MouseButton identity split");
    if (Key != Event.Key) @compileError("Key identity split");
    if (Modifiers != Event.Modifiers) @compileError("Modifiers identity split");
    if (Keycode != Event.Keycode) @compileError("Keycode identity split");

    const event = Event{ .key = .{
        .keycode = .o,
        .mods = .{ .ctrl = true },
        .state = .pressed,
    } };
    try @import("std").testing.expect(event.key.mods.ctrl);
    try @import("std").testing.expectEqual(Keycode.o, event.key.keycode);
}

test "shortcuts use normalized key and modifier values" {
    const shortcut = Shortcut{
        .keycode = .f4,
        .modifiers = .{ .alt = true },
    };
    try @import("std").testing.expect(shortcut.modifiers.alt);
}
