//! Window-wide key interception via an NSEvent local monitor
//! (`addLocalMonitorForEventsMatchingMask:handler:`). This sees key events
//! before they reach the first responder, so Vigil's own shortcuts (⌘/, and
//! later ⌘K) work no matter what has focus, without routing through the
//! terminal view's `keyDown:`.
const std = @import("std");
const objc = @import("objc");
const appkit = @import("appkit.zig");

const NSEventMaskKeyDown: u64 = 1 << 10;

/// Return true to consume the event (it never reaches the responder chain).
pub const Handler = *const fn (event: objc.Object) bool;

var handler: ?Handler = null;

const MonitorBlock = objc.Block(struct {}, .{objc.c.id}, objc.c.id);

fn invoke(_: *const MonitorBlock.Context, event: objc.c.id) callconv(.c) objc.c.id {
    const h = handler orelse return event;
    return if (h(.{ .value = event })) null else event;
}

/// Installs the monitor once for the process lifetime.
pub fn install(h: Handler) void {
    handler = h;
    var block = MonitorBlock.init(.{}, invoke);
    _ = appkit.class("NSEvent").msgSend(
        objc.Object,
        "addLocalMonitorForEventsMatchingMask:handler:",
        .{ NSEventMaskKeyDown, &block },
    );
}

pub const key_escape: u16 = 53;
pub const key_slash: u16 = 44;

const device_independent_mask: u64 = 0xFFFF0000;
const flag_shift: u64 = 1 << 17;
const flag_control: u64 = 1 << 18;
const flag_option: u64 = 1 << 19;
const flag_command: u64 = 1 << 20;

pub const Modifiers = enum { none, command, other };

/// Classifies an event's modifiers: exactly ⌘, nothing at all, or anything else.
pub fn modifiers(event: objc.Object) Modifiers {
    const flags = event.msgSend(u64, "modifierFlags", .{}) & device_independent_mask;
    const relevant = flags & (flag_shift | flag_control | flag_option | flag_command);
    if (relevant == 0) return .none;
    if (relevant == flag_command) return .command;
    return .other;
}

pub fn keyCode(event: objc.Object) u16 {
    return event.msgSend(u16, "keyCode", .{});
}

/// True when ⌘ or ⌃ is held -- i.e. a shortcut rather than text entry.
pub fn isShortcut(event: objc.Object) bool {
    const flags = event.msgSend(u64, "modifierFlags", .{}) & device_independent_mask;
    return flags & (flag_command | flag_control) != 0;
}

/// The event's typed text as UTF-8 (empty for pure modifier/function keys).
pub fn characters(event: objc.Object) []const u8 {
    const chars = event.msgSend(objc.Object, "characters", .{});
    if (chars.value == null) return &.{};
    return std.mem.sliceTo(chars.msgSend([*:0]const u8, "UTF8String", .{}), 0);
}

pub const key_return: u16 = 36;
pub const key_keypad_enter: u16 = 76;
pub const key_backspace: u16 = 51;
pub const key_up: u16 = 126;
pub const key_down: u16 = 125;
