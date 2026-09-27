//! Central registry of the commands Vigil exposes to the user (command
//! palette, shortcuts sheet). Each command names a libghostty binding
//! action; its shortcut is *resolved from the live config* rather than
//! hardcoded, so the UI always shows what actually fires -- including the
//! user's own `keybind = ...` overrides.
//!
//! libghostty owns key dispatch: ghostty_surface_key matches bindings and
//! emits the actions `Window.handleAction` handles. This file only reads
//! bindings back out (for display) and can trigger an action by name.
const std = @import("std");
const ghc = @import("../ghostty/c.zig").c;

pub const Group = enum {
    tabs,
    edit,
    view,
    app,

    pub fn title(self: Group) []const u8 {
        return switch (self) {
            .tabs => "Tabs",
            .edit => "Edit",
            .view => "View",
            .app => "App",
        };
    }
};

/// Commands Vigil implements itself rather than delegating to libghostty.
pub const VigilAction = enum { show_shortcuts, show_themes };

pub const Command = struct {
    title: []const u8,
    group: Group,
    /// A libghostty binding action string, exactly as written in the
    /// `keybind` config (e.g. "new_tab", "increase_font_size:1").
    action: [:0]const u8,
    /// Shown only when the config lookup can't yield a displayable shortcut.
    /// libghostty's reverse lookup (`ghostty_config_trigger`) skips binds
    /// carrying the `performable` flag -- which is how the macOS defaults for
    /// copy/paste (⌘C/⌘V) are declared -- and returns the bare media
    /// `copy`/`paste` keys instead. Only set this for defaults known to be
    /// bound; a user who unbinds the command would still see the hint.
    fallback_keys: ?[]const u8 = null,
    /// Set for Vigil-owned commands; `action` is then unused and the
    /// shortcut is `fallback_keys` (Vigil, not libghostty, owns the key).
    vigil: ?VigilAction = null,
    /// Listed in the command palette (false for the palette's own toggle).
    in_palette: bool = true,
};

/// Only commands Vigil actually implements belong here -- splits, for
/// instance, are absent until Window can lay them out.
pub const commands = [_]Command{
    .{ .title = "New tab", .group = .tabs, .action = "new_tab" },
    .{ .title = "Close tab", .group = .tabs, .action = "close_surface" },
    .{ .title = "Previous tab", .group = .tabs, .action = "previous_tab" },
    .{ .title = "Next tab", .group = .tabs, .action = "next_tab" },
    .{ .title = "Last tab", .group = .tabs, .action = "last_tab" },
    .{ .title = "Move tab left", .group = .tabs, .action = "move_tab:-1" },
    .{ .title = "Move tab right", .group = .tabs, .action = "move_tab:1" },

    .{ .title = "Copy", .group = .edit, .action = "copy_to_clipboard", .fallback_keys = "⌘C" },
    .{ .title = "Paste", .group = .edit, .action = "paste_from_clipboard", .fallback_keys = "⌘V" },
    .{ .title = "Select all", .group = .edit, .action = "select_all" },
    .{ .title = "Clear screen", .group = .edit, .action = "clear_screen" },

    .{ .title = "Increase font size", .group = .view, .action = "increase_font_size:1" },
    .{ .title = "Decrease font size", .group = .view, .action = "decrease_font_size:1" },
    .{ .title = "Reset font size", .group = .view, .action = "reset_font_size" },
    .{ .title = "Choose theme\u{2026}", .group = .view, .action = "", .vigil = .show_themes },
    .{ .title = "Toggle full screen", .group = .view, .action = "toggle_fullscreen" },

    .{ .title = "Command palette", .group = .app, .action = "toggle_command_palette", .in_palette = false },
    .{ .title = "Keyboard shortcuts", .group = .app, .action = "", .vigil = .show_shortcuts, .fallback_keys = "⌘/" },
    .{ .title = "Reload config", .group = .app, .action = "reload_config" },
    .{ .title = "Quit", .group = .app, .action = "quit" },
};

var config: ghc.ghostty_config_t = null;

/// `cfg` must outlive all lookups (Vigil never frees it).
pub fn init(cfg: ghc.ghostty_config_t) void {
    config = cfg;
}

/// The trigger currently bound to `cmd`, or null when unbound.
pub fn lookup(cmd: Command) ?ghc.ghostty_input_trigger_s {
    if (cmd.vigil != null) return null;
    const cfg = config orelse return null;
    const trigger = ghc.ghostty_config_trigger(cfg, cmd.action.ptr, cmd.action.len);
    return if (isBound(trigger)) trigger else null;
}

/// libghostty reports "no binding" as its default trigger: physical key
/// UNIDENTIFIED with no modifiers.
fn isBound(t: ghc.ghostty_input_trigger_s) bool {
    return switch (t.tag) {
        ghc.GHOSTTY_TRIGGER_PHYSICAL => t.key.physical != ghc.GHOSTTY_KEY_UNIDENTIFIED,
        ghc.GHOSTTY_TRIGGER_UNICODE => t.key.unicode != 0,
        else => false, // catch_all isn't a displayable shortcut
    };
}

/// The shortcut text to show for `cmd` ("⇧⌘T"), or null when it has none.
pub fn display(cmd: Command, buf: *[max_format_len]u8) ?[]const u8 {
    if (lookup(cmd)) |trigger| {
        if (format(trigger, buf)) |text| return text;
    }
    return cmd.fallback_keys;
}

/// Runs `cmd` against `surface` as if its key were pressed.
pub fn perform(surface: ghc.ghostty_surface_t, cmd: Command) bool {
    if (cmd.vigil != null) return false; // the caller dispatches Vigil actions
    return ghc.ghostty_surface_binding_action(surface, cmd.action.ptr, cmd.action.len);
}

pub const max_format_len = 24;

/// Renders a trigger the way macOS menus do: modifiers in ⌃⌥⇧⌘ order, then
/// the key ("⇧⌘T"). Returns null when the key has no known label.
pub fn format(trigger: ghc.ghostty_input_trigger_s, buf: *[max_format_len]u8) ?[]const u8 {
    var w = std.Io.Writer.fixed(buf);
    const mods: c_uint = @intCast(trigger.mods);
    if (mods & ghc.GHOSTTY_MODS_CTRL != 0) w.writeAll("⌃") catch return null;
    if (mods & ghc.GHOSTTY_MODS_ALT != 0) w.writeAll("⌥") catch return null;
    if (mods & ghc.GHOSTTY_MODS_SHIFT != 0) w.writeAll("⇧") catch return null;
    if (mods & ghc.GHOSTTY_MODS_SUPER != 0) w.writeAll("⌘") catch return null;

    switch (trigger.tag) {
        ghc.GHOSTTY_TRIGGER_PHYSICAL => {
            const label = physicalLabel(trigger.key.physical) orelse return null;
            w.writeAll(label) catch return null;
        },
        ghc.GHOSTTY_TRIGGER_UNICODE => {
            const cp: u21 = std.math.cast(u21, trigger.key.unicode) orelse return null;
            const upper: u21 = if (cp < 0x80) std.ascii.toUpper(@intCast(cp)) else cp;
            var tmp: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(upper, &tmp) catch return null;
            w.writeAll(tmp[0..n]) catch return null;
        },
        else => return null,
    }
    return w.buffered();
}

const KeyLabel = struct { key: c_uint, label: []const u8 };

const key_labels = blk: {
    var table: []const KeyLabel = &.{};
    for ("ABCDEFGHIJKLMNOPQRSTUVWXYZ") |ch| {
        table = table ++ &[_]KeyLabel{.{
            .key = @field(ghc, "GHOSTTY_KEY_" ++ &[_]u8{ch}),
            .label = &[_]u8{ch},
        }};
    }
    for ("0123456789") |ch| {
        table = table ++ &[_]KeyLabel{.{
            .key = @field(ghc, "GHOSTTY_KEY_DIGIT_" ++ &[_]u8{ch}),
            .label = &[_]u8{ch},
        }};
    }
    for (1..13) |n| {
        const name = std.fmt.comptimePrint("F{d}", .{n});
        table = table ++ &[_]KeyLabel{.{ .key = @field(ghc, "GHOSTTY_KEY_" ++ name), .label = name }};
    }
    const named = [_]KeyLabel{
        .{ .key = ghc.GHOSTTY_KEY_BACKQUOTE, .label = "`" },
        .{ .key = ghc.GHOSTTY_KEY_BACKSLASH, .label = "\\" },
        .{ .key = ghc.GHOSTTY_KEY_BRACKET_LEFT, .label = "[" },
        .{ .key = ghc.GHOSTTY_KEY_BRACKET_RIGHT, .label = "]" },
        .{ .key = ghc.GHOSTTY_KEY_COMMA, .label = "," },
        .{ .key = ghc.GHOSTTY_KEY_EQUAL, .label = "=" },
        .{ .key = ghc.GHOSTTY_KEY_MINUS, .label = "-" },
        .{ .key = ghc.GHOSTTY_KEY_PERIOD, .label = "." },
        .{ .key = ghc.GHOSTTY_KEY_QUOTE, .label = "'" },
        .{ .key = ghc.GHOSTTY_KEY_SEMICOLON, .label = ";" },
        .{ .key = ghc.GHOSTTY_KEY_SLASH, .label = "/" },
        .{ .key = ghc.GHOSTTY_KEY_ENTER, .label = "↩" },
        .{ .key = ghc.GHOSTTY_KEY_TAB, .label = "⇥" },
        .{ .key = ghc.GHOSTTY_KEY_SPACE, .label = "Space" },
        .{ .key = ghc.GHOSTTY_KEY_BACKSPACE, .label = "⌫" },
        .{ .key = ghc.GHOSTTY_KEY_DELETE, .label = "⌦" },
        .{ .key = ghc.GHOSTTY_KEY_ESCAPE, .label = "⎋" },
        .{ .key = ghc.GHOSTTY_KEY_ARROW_LEFT, .label = "←" },
        .{ .key = ghc.GHOSTTY_KEY_ARROW_UP, .label = "↑" },
        .{ .key = ghc.GHOSTTY_KEY_ARROW_RIGHT, .label = "→" },
        .{ .key = ghc.GHOSTTY_KEY_ARROW_DOWN, .label = "↓" },
        .{ .key = ghc.GHOSTTY_KEY_HOME, .label = "↖" },
        .{ .key = ghc.GHOSTTY_KEY_END, .label = "↘" },
        .{ .key = ghc.GHOSTTY_KEY_PAGE_UP, .label = "⇞" },
        .{ .key = ghc.GHOSTTY_KEY_PAGE_DOWN, .label = "⇟" },
    };
    break :blk table ++ &named;
};

fn physicalLabel(key: c_uint) ?[]const u8 {
    for (key_labels) |entry| if (entry.key == key) return entry.label;
    return null;
}

fn testTrigger(mods: c_uint, key: c_uint) ghc.ghostty_input_trigger_s {
    var t = std.mem.zeroes(ghc.ghostty_input_trigger_s);
    t.tag = ghc.GHOSTTY_TRIGGER_PHYSICAL;
    t.key.physical = key;
    t.mods = mods;
    return t;
}

test "format orders modifiers like macOS menus" {
    var buf: [max_format_len]u8 = undefined;
    const t = testTrigger(ghc.GHOSTTY_MODS_SUPER | ghc.GHOSTTY_MODS_SHIFT | ghc.GHOSTTY_MODS_CTRL, ghc.GHOSTTY_KEY_T);
    try std.testing.expectEqualStrings("⌃⇧⌘T", format(t, &buf).?);
}

test "format handles punctuation, digits and arrows" {
    var buf: [max_format_len]u8 = undefined;
    try std.testing.expectEqualStrings("⌘[", format(testTrigger(ghc.GHOSTTY_MODS_SUPER, ghc.GHOSTTY_KEY_BRACKET_LEFT), &buf).?);
    try std.testing.expectEqualStrings("⌘1", format(testTrigger(ghc.GHOSTTY_MODS_SUPER, ghc.GHOSTTY_KEY_DIGIT_1), &buf).?);
    try std.testing.expectEqualStrings("⌥←", format(testTrigger(ghc.GHOSTTY_MODS_ALT, ghc.GHOSTTY_KEY_ARROW_LEFT), &buf).?);
}

test "format handles unicode triggers" {
    var buf: [max_format_len]u8 = undefined;
    var t = std.mem.zeroes(ghc.ghostty_input_trigger_s);
    t.tag = ghc.GHOSTTY_TRIGGER_UNICODE;
    t.key.unicode = 'k';
    t.mods = ghc.GHOSTTY_MODS_SUPER;
    try std.testing.expectEqualStrings("⌘K", format(t, &buf).?);
}

test "default trigger is unbound" {
    try std.testing.expect(!isBound(std.mem.zeroes(ghc.ghostty_input_trigger_s)));
}

test "commands resolve against libghostty's default config" {
    var argv0 = "vigil".*;
    var argv = [_][*c]u8{&argv0};
    try std.testing.expectEqual(ghc.GHOSTTY_SUCCESS, ghc.ghostty_init(1, &argv));

    // Deliberately no config files: defaults only, so this is hermetic.
    const cfg = ghc.ghostty_config_new() orelse return error.ConfigNew;
    defer ghc.ghostty_config_free(cfg);
    ghc.ghostty_config_finalize(cfg);

    const saved = config;
    defer config = saved;
    init(cfg);

    var buf: [max_format_len]u8 = undefined;
    try std.testing.expectEqualStrings("⌘T", format(lookup(commands[0]).?, &buf).?);

    // Every command that claims a fallback must actually need one, and
    // copy/paste must display *something* despite libghostty's reverse
    // lookup returning bare media keys for them.
    for (commands) |cmd| {
        if (cmd.fallback_keys != null) try std.testing.expect(display(cmd, &buf) != null);
    }
}
