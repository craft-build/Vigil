//! Native macOS menu bar, generated from the same command registry the
//! command palette and shortcuts sheet read (`keybindings.zig`), so its
//! labels and key equivalents always match what's actually bound instead of
//! duplicating them by hand. A handful of standard macOS items (About,
//! Hide, Quit-adjacent window basics) use the default nil-targeted
//! responder chain instead, since AppKit already implements those
//! correctly and nothing in the registry covers them.
//!
//! Menu items backed by a registry command carry that command's index (in
//! `keybindings.commands`) as their `tag`; one small target object's
//! `runCommand:` reads the tag back out and dispatches through
//! `palette.on_run` -- the same path the command palette uses, so there is
//! exactly one place (`Window.runCommand`) that decides what each command
//! actually does.
//!
//! Key equivalents matter here beyond cosmetics: AppKit resolves a key-down
//! event against the main menu (`-[NSMenu performKeyEquivalent:]`) *before*
//! it would otherwise reach `TerminalSurface`'s `keyDown:`. So giving an
//! item a real key equivalent doesn't risk double-handling that shortcut --
//! either the menu consumes the event and runs this same dispatch, or (no
//! matching item) it falls through to libghostty's own key handling
//! completely unchanged.
const std = @import("std");
const objc = @import("objc");
const ghc = @import("../ghostty/c.zig").c;
const appkit = @import("appkit.zig");
const keybindings = @import("keybindings.zig");
const palette = @import("../ui/palette.zig");

// NSEventModifierFlags. Stable across SDKs; zig-objc doesn't expose them.
const mod_shift: u64 = 1 << 17;
const mod_control: u64 = 1 << 18;
const mod_option: u64 = 1 << 19;
const mod_command: u64 = 1 << 20;

var target_class: ?objc.Class = null;
var target: objc.Object = .{ .value = null };

/// Builds and installs the main menu bar. Call once at startup, after
/// `Window.create` (so `palette.on_run` is already wired to it).
pub fn install() void {
    target = registerTarget().msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});

    const main_menu = appkit.class("NSMenu").msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});
    addSubmenu(main_menu, "Vigil", buildAppMenu());
    addSubmenu(main_menu, "File", buildFileMenu());
    addSubmenu(main_menu, "Edit", buildEditMenu());
    addSubmenu(main_menu, "View", buildViewMenu());
    const window_menu = buildWindowMenu();
    addSubmenu(main_menu, "Window", window_menu);
    const help_menu = buildHelpMenu();
    addSubmenu(main_menu, "Help", help_menu);

    const NSApp = appkit.class("NSApplication").msgSend(objc.Object, "sharedApplication", .{});
    NSApp.msgSend(void, "setMainMenu:", .{main_menu});
    // Lets AppKit append the live window list and manage Minimize/Zoom
    // checkmarks; lets the Help menu grow Spotlight-style search for free.
    NSApp.msgSend(void, "setWindowsMenu:", .{window_menu});
    NSApp.msgSend(void, "setHelpMenu:", .{help_menu});
}

fn registerTarget() objc.Class {
    if (target_class) |cls| return cls;
    const cls = objc.allocateClassPair(appkit.class("NSObject"), "VigilMenuTarget") orelse
        @panic("failed to register VigilMenuTarget");
    std.debug.assert(cls.addMethod("runCommand:", runCommandAction));
    objc.registerClassPair(cls);
    target_class = cls;
    return cls;
}

fn runCommandAction(_: objc.c.id, _: objc.c.SEL, sender: objc.c.id) callconv(.c) void {
    const tag = (objc.Object{ .value = sender }).msgSend(i64, "tag", .{});
    if (tag < 0 or @as(usize, @intCast(tag)) >= keybindings.commands.len) return;
    if (palette.on_run) |run| run(keybindings.commands[@intCast(tag)]);
}

// -- Menu construction -----------------------------------------------------

fn buildAppMenu() objc.Object {
    const menu = newMenu("Vigil");
    standardItem(menu, "About Vigil", "orderFrontStandardAboutPanel:", "", mod_command);
    addSeparator(menu);
    commandItem(menu, "Preferences\u{2026}", "Preferences\u{2026}");
    commandItem(menu, "Reload config", "Reload Config");
    addSeparator(menu);
    standardItem(menu, "Hide Vigil", "hide:", "h", mod_command);
    standardItem(menu, "Hide Others", "hideOtherApplications:", "h", mod_command | mod_option);
    standardItem(menu, "Show All", "unhideAllApplications:", "", mod_command);
    addSeparator(menu);
    commandItem(menu, "Quit", "Quit Vigil");
    return menu;
}

fn buildFileMenu() objc.Object {
    const menu = newMenu("File");
    commandItem(menu, "New window", "New Window");
    commandItem(menu, "New tab", "New Tab");
    addSeparator(menu);
    commandItem(menu, "Split right", "Split Right");
    commandItem(menu, "Split down", "Split Down");
    addSeparator(menu);
    commandItem(menu, "Close tab", "Close Tab");
    return menu;
}

fn buildEditMenu() objc.Object {
    const menu = newMenu("Edit");
    commandItem(menu, "Copy", "Copy");
    commandItem(menu, "Paste", "Paste");
    addSeparator(menu);
    commandItem(menu, "Select all", "Select All");
    commandItem(menu, "Clear screen", "Clear Screen");
    return menu;
}

fn buildViewMenu() objc.Object {
    const menu = newMenu("View");
    commandItem(menu, "Command palette", "Command Palette");
    addSeparator(menu);
    commandItem(menu, "Previous tab", "Previous Tab");
    commandItem(menu, "Next tab", "Next Tab");
    commandItem(menu, "Last tab", "Last Tab");
    commandItem(menu, "Move tab left", "Move Tab Left");
    commandItem(menu, "Move tab right", "Move Tab Right");
    addSeparator(menu);
    commandItem(menu, "Next pane", "Next Pane");
    commandItem(menu, "Previous pane", "Previous Pane");
    commandItem(menu, "Equalize panes", "Equalize Panes");
    commandItem(menu, "Zoom pane", "Zoom Pane");
    commandItem(menu, "Close pane", "Close Pane");
    addSeparator(menu);
    commandItem(menu, "Increase font size", "Increase Font Size");
    commandItem(menu, "Decrease font size", "Decrease Font Size");
    commandItem(menu, "Reset font size", "Reset Font Size");
    addSeparator(menu);
    commandItem(menu, "Choose theme\u{2026}", "Choose Theme\u{2026}");
    addSeparator(menu);
    commandItem(menu, "Toggle full screen", "Toggle Full Screen");
    return menu;
}

/// Standard macOS window menu: Minimize/Zoom/Bring All to Front, then
/// AppKit appends the live window list once this is set as `NSApp`'s
/// `windowsMenu` (see `install`).
fn buildWindowMenu() objc.Object {
    const menu = newMenu("Window");
    standardItem(menu, "Minimize", "performMiniaturize:", "m", mod_command);
    standardItem(menu, "Zoom", "performZoom:", "", mod_command);
    addSeparator(menu);
    standardItem(menu, "Bring All to Front", "arrangeInFront:", "", mod_command);
    return menu;
}

fn buildHelpMenu() objc.Object {
    const menu = newMenu("Help");
    commandItem(menu, "Keyboard shortcuts", "Keyboard Shortcuts");
    return menu;
}

// -- Menu-building helpers --------------------------------------------------

fn newMenu(title: [:0]const u8) objc.Object {
    return appkit.class("NSMenu").msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "initWithTitle:", .{appkit.nsString(title)});
}

/// Wraps `submenu` in a top-level item and appends it to `main_menu`. Sets
/// the title on both the item and the submenu: the menu bar renders the
/// item's title, but leaving the submenu's own title empty looks wrong in
/// places (window tabbing UI, accessibility) that read it directly.
fn addSubmenu(main_menu: objc.Object, title: [:0]const u8, submenu: objc.Object) void {
    submenu.msgSend(void, "setTitle:", .{appkit.nsString(title)});
    const item = appkit.class("NSMenuItem").msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});
    item.msgSend(void, "setTitle:", .{appkit.nsString(title)});
    item.msgSend(void, "setSubmenu:", .{submenu});
    main_menu.msgSend(void, "addItem:", .{item});
}

fn addSeparator(menu: objc.Object) void {
    menu.msgSend(void, "addItem:", .{
        appkit.class("NSMenuItem").msgSend(objc.Object, "separatorItem", .{}),
    });
}

fn newItem(title: [:0]const u8, action_sel: [:0]const u8, key: [:0]const u8, mask: u64) objc.Object {
    const item = appkit.class("NSMenuItem").msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "initWithTitle:action:keyEquivalent:", .{
        appkit.nsString(title), objc.sel(action_sel), appkit.nsString(key),
    });
    item.msgSend(void, "setKeyEquivalentModifierMask:", .{mask});
    return item;
}

/// A plain AppKit action (About, Hide, Minimize, ...): target stays nil, so
/// AppKit sends it up the responder chain to whichever object (usually
/// `NSApp` itself) implements it.
fn standardItem(menu: objc.Object, title: [:0]const u8, action_sel: [:0]const u8, key: [:0]const u8, mask: u64) void {
    menu.msgSend(void, "addItem:", .{newItem(title, action_sel, key, mask)});
}

/// A registry-backed command: looked up by its exact `keybindings.Command`
/// title (a compile-time check -- a typo here is a build failure, not a
/// silently-missing menu item), shown under `display_title` with a live key
/// equivalent, and dispatched by index through `runCommand:`.
fn commandItem(menu: objc.Object, comptime lookup_title: []const u8, display_title: [:0]const u8) void {
    const idx = comptime findCommand(lookup_title);
    const sc = shortcutFor(keybindings.commands[idx]);
    var buf: [2]u8 = undefined;
    const item = newItem(display_title, "runCommand:", sc.str(&buf), sc.mask);
    item.msgSend(void, "setTarget:", .{target});
    item.msgSend(void, "setTag:", .{@as(i64, idx)});
    menu.msgSend(void, "addItem:", .{item});
}

fn findCommand(comptime title: []const u8) usize {
    comptime {
        for (keybindings.commands, 0..) |cmd, i| {
            if (std.mem.eql(u8, cmd.title, title)) return i;
        }
        @compileError("menu references unknown command: " ++ title);
    }
}

// -- Key equivalents ---------------------------------------------------------

const Shortcut = struct {
    key_char: u8 = 0,
    mask: u64 = mod_command,

    fn str(self: Shortcut, buf: *[2]u8) [:0]const u8 {
        if (self.key_char == 0) return "";
        buf.* = .{ self.key_char, 0 };
        return buf[0..1 :0];
    }
};

/// The key equivalent to show for `cmd`, derived from the same live trigger
/// the command palette and shortcuts sheet display -- so a user's own
/// `keybind` override shows up here too, not just Vigil's defaults.
fn shortcutFor(cmd: keybindings.Command) Shortcut {
    if (cmd.vigil) |v| return switch (v) {
        // Vigil owns these, so there's no libghostty trigger to read;
        // mirror `Command.fallback_keys` (show_themes has none).
        .show_preferences => .{ .key_char = ',', .mask = mod_command },
        .show_shortcuts => .{ .key_char = '/', .mask = mod_command },
        .show_themes => .{},
        .new_window => .{ .key_char = 'n', .mask = mod_command },
    };
    if (keybindings.lookup(cmd)) |trigger| {
        if (fromTrigger(trigger)) |sc| return sc;
    }
    // ghostty_config_trigger's reverse lookup skips binds flagged
    // `performable`, which is how the macOS defaults for these two are
    // declared (see `Command.fallback_keys`'s doc comment) -- hardcode the
    // two known-good defaults rather than show nothing.
    if (std.mem.eql(u8, cmd.action, "copy_to_clipboard")) return .{ .key_char = 'c' };
    if (std.mem.eql(u8, cmd.action, "paste_from_clipboard")) return .{ .key_char = 'v' };
    return .{};
}

fn baseMods(raw: anytype) u64 {
    const mods: c_uint = @intCast(raw);
    var mask: u64 = 0;
    if (mods & ghc.GHOSTTY_MODS_CTRL != 0) mask |= mod_control;
    if (mods & ghc.GHOSTTY_MODS_ALT != 0) mask |= mod_option;
    if (mods & ghc.GHOSTTY_MODS_SUPER != 0) mask |= mod_command;
    return mask;
}

/// Shift needs care: NSMenuItem's docs warn that a lowercase keyEquivalent
/// plus an explicit Shift flag gives "unpredictable results" -- the
/// documented-safe way to require Shift is to pass the character Shift
/// actually produces (uppercase for letters, the shifted glyph for
/// punctuation) and leave the Shift bit out of the mask. Only keys with no
/// such alternate glyph (Return, arrows, ...) fall back to an explicit
/// Shift bit.
fn fromTrigger(t: ghc.ghostty_input_trigger_s) ?Shortcut {
    const mods: c_uint = @intCast(t.mods);
    const shift = mods & ghc.GHOSTTY_MODS_SHIFT != 0;
    const mask = baseMods(t.mods);
    switch (t.tag) {
        ghc.GHOSTTY_TRIGGER_UNICODE => {
            // A unicode trigger's codepoint already reflects any shift
            // needed to type it (e.g. '+'), so `mods` here shouldn't carry
            // Shift too -- but tolerate it the same way as a bare flag.
            const cp: u21 = std.math.cast(u21, t.key.unicode) orelse return null;
            if (cp == 0 or cp >= 128) return null;
            return .{ .key_char = @intCast(cp), .mask = if (shift) mask | mod_shift else mask };
        },
        ghc.GHOSTTY_TRIGGER_PHYSICAL => {
            const base = physicalChar(t.key.physical) orelse return null;
            if (!shift) return .{ .key_char = base, .mask = mask };
            if (std.ascii.isAlphabetic(base)) return .{ .key_char = std.ascii.toUpper(base), .mask = mask };
            if (shiftedPunct(base)) |sp| return .{ .key_char = sp, .mask = mask };
            return .{ .key_char = base, .mask = mask | mod_shift };
        },
        else => return null,
    }
}

/// The character Shift produces on a US keyboard for keys where it changes
/// the glyph entirely rather than just casing a letter.
fn shiftedPunct(ch: u8) ?u8 {
    return switch (ch) {
        '[' => '{',
        ']' => '}',
        ',' => '<',
        '.' => '>',
        '/' => '?',
        ';' => ':',
        '\'' => '"',
        '-' => '_',
        '=' => '+',
        '`' => '~',
        '\\' => '|',
        '1' => '!',
        '2' => '@',
        '3' => '#',
        '4' => '$',
        '5' => '%',
        '6' => '^',
        '7' => '&',
        '8' => '*',
        '9' => '(',
        '0' => ')',
        else => null,
    };
}

const PhysChar = struct { key: c_uint, ch: u8 };

/// Unshifted character a physical key types, for the physical keys Vigil's
/// own commands actually bind to (see `keybindings.key_labels` for the
/// display-label counterpart of this table).
const phys_chars = blk: {
    var table: []const PhysChar = &.{};
    for ("ABCDEFGHIJKLMNOPQRSTUVWXYZ") |ch| {
        table = table ++ &[_]PhysChar{.{
            .key = @field(ghc, "GHOSTTY_KEY_" ++ &[_]u8{ch}),
            .ch = std.ascii.toLower(ch),
        }};
    }
    for ("0123456789") |ch| {
        table = table ++ &[_]PhysChar{.{ .key = @field(ghc, "GHOSTTY_KEY_DIGIT_" ++ &[_]u8{ch}), .ch = ch }};
    }
    const named = [_]PhysChar{
        .{ .key = ghc.GHOSTTY_KEY_BACKQUOTE, .ch = '`' },
        .{ .key = ghc.GHOSTTY_KEY_BACKSLASH, .ch = '\\' },
        .{ .key = ghc.GHOSTTY_KEY_BRACKET_LEFT, .ch = '[' },
        .{ .key = ghc.GHOSTTY_KEY_BRACKET_RIGHT, .ch = ']' },
        .{ .key = ghc.GHOSTTY_KEY_COMMA, .ch = ',' },
        .{ .key = ghc.GHOSTTY_KEY_EQUAL, .ch = '=' },
        .{ .key = ghc.GHOSTTY_KEY_MINUS, .ch = '-' },
        .{ .key = ghc.GHOSTTY_KEY_PERIOD, .ch = '.' },
        .{ .key = ghc.GHOSTTY_KEY_QUOTE, .ch = '\'' },
        .{ .key = ghc.GHOSTTY_KEY_SEMICOLON, .ch = ';' },
        .{ .key = ghc.GHOSTTY_KEY_SLASH, .ch = '/' },
        .{ .key = ghc.GHOSTTY_KEY_ENTER, .ch = '\r' },
    };
    break :blk table ++ &named;
};

fn physicalChar(key: c_uint) ?u8 {
    for (phys_chars) |entry| if (entry.key == key) return entry.ch;
    return null;
}
