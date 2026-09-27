//! Screen 02 -- the command palette. A dimmed backdrop with a search box
//! and a filtered list of registry commands. There is no NSTextField:
//! while the palette is open the window-wide key monitor feeds keystrokes
//! here (`handleKey`), which keeps the query, selection and rendering in
//! one place and leaves the terminal's first-responder status untouched.
//! (Trade-off: no IME, text selection or paste in the query box.)
//!
//! Opened by libghostty's `toggle_command_palette` action (⇧⌘P by
//! default); ⌘K stays with clear-screen.
const std = @import("std");
const objc = @import("objc");
const appkit = @import("../app/appkit.zig");
const keybindings = @import("../app/keybindings.zig");
const keymonitor = @import("../app/keymonitor.zig");
const theme = @import("theme.zig");
const keycaps = @import("keycaps.zig");
const overlay_ui = @import("overlay.zig");

const panel_w: f64 = 560;
const search_h: f64 = 52;
const row_h: f64 = 36;
const pad: f64 = 8;
const max_rows: usize = 8;
const top_margin: f64 = 96;
// Left/right/bottom margins flexible => the panel stays pinned to the top.
const top_anchored_mask: u64 = 1 | 4 | 8;

const max_query = 64;
var query_buf: [max_query]u8 = undefined;
var query_len: usize = 0;
var selected: usize = 0;
var scroll: usize = 0;
var matches: [keybindings.commands.len]usize = undefined;
var match_count: usize = 0;

var overlay: ?objc.Object = null;
var host: ?objc.Object = null;

/// Called (after the palette closes) with the chosen command.
pub var on_run: ?*const fn (keybindings.Command) void = null;

pub fn isVisible() bool {
    return overlay != null;
}

pub fn toggle(parent: objc.Object) void {
    if (isVisible()) hide() else show(parent);
}

pub fn show(parent: objc.Object) void {
    if (isVisible()) return;
    host = parent;
    query_len = 0;
    refilter();
    render();
}

pub fn hide() void {
    if (overlay) |view| view.msgSend(void, "removeFromSuperview", .{});
    overlay = null;
}

/// Feeds a key event to the open palette. Returns true if consumed;
/// ⌘/⌃ shortcuts pass through so ⇧⌘P (toggle) and friends still work.
pub fn handleKey(event: objc.Object) bool {
    if (!isVisible()) return false;
    if (keymonitor.isShortcut(event)) return false;

    switch (keymonitor.keyCode(event)) {
        keymonitor.key_escape => hide(),
        keymonitor.key_return, keymonitor.key_keypad_enter => runSelected(),
        keymonitor.key_up => move(-1),
        keymonitor.key_down => move(1),
        keymonitor.key_backspace => {
            if (query_len > 0) {
                query_len -= 1;
                while (query_len > 0 and query_buf[query_len] & 0xC0 == 0x80) query_len -= 1;
                refilter();
                render();
            }
        },
        else => appendText(keymonitor.characters(event)),
    }
    return true;
}

fn appendText(text: []const u8) void {
    if (text.len == 0 or query_len + text.len > max_query) return;
    const cp_len = std.unicode.utf8ByteSequenceLength(text[0]) catch return;
    const cp = std.unicode.utf8Decode(text[0..@min(cp_len, text.len)]) catch return;
    // Skip control characters and AppKit's private-use codes for arrow /
    // function keys.
    if (cp < 0x20 or cp == 0x7f or (cp >= 0xF700 and cp <= 0xF8FF)) return;
    @memcpy(query_buf[query_len..][0..text.len], text);
    query_len += text.len;
    refilter();
    render();
}

fn move(delta: i32) void {
    if (match_count == 0) return;
    const next: i64 = @as(i64, @intCast(selected)) + delta;
    selected = @intCast(std.math.clamp(next, 0, @as(i64, @intCast(match_count)) - 1));
    if (selected < scroll) scroll = selected;
    if (selected >= scroll + max_rows) scroll = selected + 1 - max_rows;
    render();
}

fn runSelected() void {
    if (match_count == 0) return;
    const cmd = keybindings.commands[matches[selected]];
    hide();
    if (on_run) |cb| cb(cmd);
}

/// Substring matches first (in registry order), then looser in-order
/// subsequence matches ("nt" -> "New tab").
fn refilter() void {
    const query = query_buf[0..query_len];
    match_count = 0;
    selected = 0;
    scroll = 0;

    for (keybindings.commands, 0..) |cmd, i| {
        if (!cmd.in_palette) continue;
        if (query.len == 0 or std.ascii.indexOfIgnoreCase(cmd.title, query) != null) {
            matches[match_count] = i;
            match_count += 1;
        }
    }
    if (query.len == 0) return;
    for (keybindings.commands, 0..) |cmd, i| {
        if (!cmd.in_palette or std.ascii.indexOfIgnoreCase(cmd.title, query) != null) continue;
        if (isSubsequence(query, cmd.title)) {
            matches[match_count] = i;
            match_count += 1;
        }
    }
}

fn isSubsequence(needle: []const u8, hay: []const u8) bool {
    var n: usize = 0;
    for (hay) |ch| {
        if (n < needle.len and std.ascii.toLower(ch) == std.ascii.toLower(needle[n])) n += 1;
    }
    return n == needle.len;
}

fn render() void {
    const parent = host orelse return;
    if (overlay) |old| old.msgSend(void, "removeFromSuperview", .{});

    const bounds = parent.msgSend(appkit.NSRect, "bounds", .{});
    const backdrop = overlay_ui.backdrop(bounds, hide);

    const visible = @min(match_count, max_rows);
    const list_h = @as(f64, @floatFromInt(@max(visible, 1))) * row_h + 2 * pad;
    const panel_h = search_h + list_h;
    const panel = appkit.panel(
        appkit.rect(
            @round((bounds.size.width - panel_w) / 2),
            bounds.size.height - top_margin - panel_h,
            panel_w,
            panel_h,
        ),
        .{
            .background = theme.colors.bg_surface_raised,
            .border = theme.colors.border_default,
            .corner_radius = theme.radius.lg,
        },
    );
    panel.msgSend(void, "setAutoresizingMask:", .{top_anchored_mask});
    appkit.addSubview(backdrop, panel);

    buildSearchRow(panel, panel_h);
    appkit.addSubview(panel, appkit.panel(
        appkit.rect(0, list_h, panel_w, 1),
        .{ .background = theme.colors.border_subtle },
    ));

    if (match_count == 0) {
        appkit.addSubview(panel, appkit.label(
            appkit.rect(20, pad + 8, panel_w - 40, 18),
            "No matching commands",
            appkit.font(theme.fonts.body, theme.text_size.sm, false),
            theme.colors.text_tertiary,
        ));
    }

    const font = appkit.font(theme.fonts.body, theme.text_size.sm, false);
    var row: usize = 0;
    while (row < visible) : (row += 1) {
        const index = scroll + row;
        const cmd = keybindings.commands[matches[index]];
        const y = list_h - pad - @as(f64, @floatFromInt(row + 1)) * row_h;
        const is_selected = index == selected;

        if (is_selected) {
            appkit.addSubview(panel, appkit.panel(
                appkit.rect(pad, y, panel_w - 2 * pad, row_h),
                .{ .background = theme.colors.bg_surface_overlay, .corner_radius = theme.radius.md },
            ));
        }

        var title_buf: [64:0]u8 = undefined;
        const title = std.fmt.bufPrintZ(&title_buf, "{s}", .{cmd.title}) catch continue;
        appkit.addSubview(panel, appkit.label(
            appkit.rect(pad + 12, y + 9, 300, 18),
            title,
            font,
            if (is_selected) theme.colors.text_primary else theme.colors.text_secondary,
        ));

        var keys_buf: [keybindings.max_format_len]u8 = undefined;
        if (keybindings.display(cmd, &keys_buf)) |keys| {
            keycaps.addShortcut(panel, keys, panel_w - pad - 12, y + 7);
        }
    }

    parent.msgSend(void, "addSubview:", .{backdrop});
    overlay = backdrop;
}

fn buildSearchRow(panel: objc.Object, panel_h: f64) void {
    const y = panel_h - search_h;
    appkit.addSubview(panel, appkit.label(
        appkit.rect(20, y + 15, 20, 22),
        ">",
        appkit.font(theme.fonts.mono, theme.text_size.md, true),
        theme.colors.blue_400,
    ));

    if (query_len == 0) {
        appkit.addSubview(panel, appkit.label(
            appkit.rect(44, y + 15, panel_w - 64, 22),
            "Type a command\u{2026}",
            appkit.font(theme.fonts.body, theme.text_size.md, false),
            theme.colors.text_tertiary,
        ));
        return;
    }

    // The trailing caret stands in for a real insertion point.
    var buf: [max_query + 4:0]u8 = undefined;
    const text = std.fmt.bufPrintZ(&buf, "{s}\u{258f}", .{query_buf[0..query_len]}) catch return;
    appkit.addSubview(panel, appkit.label(
        appkit.rect(44, y + 15, panel_w - 64, 22),
        text,
        appkit.font(theme.fonts.body, theme.text_size.md, false),
        theme.colors.text_primary,
    ));
}

test "filter prefers substring matches, then subsequences" {
    query_len = 0;
    for ("nt") |ch| {
        query_buf[query_len] = ch;
        query_len += 1;
    }
    refilter();
    try std.testing.expect(match_count > 0);
    // "nt" is a substring of "Next tab"'s "Next"? no -- but is a subsequence of "New tab".
    var found_new_tab = false;
    for (matches[0..match_count]) |i| {
        if (std.mem.eql(u8, keybindings.commands[i].title, "New tab")) found_new_tab = true;
        try std.testing.expect(keybindings.commands[i].in_palette);
    }
    try std.testing.expect(found_new_tab);
    query_len = 0;
}
