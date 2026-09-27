//! Keycap chips ("⌘", "⇧", "T") shared by the shortcuts sheet and the
//! command palette.
const std = @import("std");
const objc = @import("objc");
const appkit = @import("../app/appkit.zig");
const theme = @import("theme.zig");

pub fn chipWidth(text: []const u8) f64 {
    const chars: f64 = @floatFromInt(std.unicode.utf8CountCodepoints(text) catch text.len);
    return @max(22, 12 + chars * 7);
}

pub fn chip(x: f64, y: f64, text: [:0]const u8) objc.Object {
    const w = chipWidth(text);
    const view = appkit.panel(
        appkit.rect(x, y, w, 22),
        .{
            .background = theme.colors.bg_surface_overlay,
            .border = theme.colors.border_default,
            .corner_radius = theme.radius.xs + 1,
        },
    );
    const label = appkit.label(
        appkit.rect(0, 3, w, 16),
        text,
        appkit.font(theme.fonts.mono, theme.text_size.xs2, true),
        theme.colors.text_primary,
    );
    label.msgSend(void, "setAlignment:", .{@as(i64, 2)}); // NSTextAlignmentCenter
    appkit.addSubview(view, label);
    return view;
}

fn isModifierGlyph(s: []const u8) bool {
    inline for (.{ "⌃", "⌥", "⇧", "⌘" }) |g| {
        if (std.mem.eql(u8, s, g)) return true;
    }
    return false;
}

/// Adds chips for a formatted shortcut ("⇧⌘T": one chip per modifier, then
/// one for the key), right-aligned so the last chip's trailing edge is at
/// `right`. `y` is the chips' bottom edge.
pub fn addShortcut(parent: objc.Object, keys: []const u8, right_edge: f64, y: f64) void {
    var chips: [6][]const u8 = undefined;
    var n: usize = 0;
    var rest = keys;
    while (rest.len >= 3 and n < chips.len - 1 and isModifierGlyph(rest[0..3])) {
        chips[n] = rest[0..3];
        n += 1;
        rest = rest[3..];
    }
    if (rest.len > 0) {
        chips[n] = rest;
        n += 1;
    }

    var right = right_edge;
    var i = n;
    while (i > 0) {
        i -= 1;
        right -= chipWidth(chips[i]);
        var z: [24:0]u8 = undefined;
        const s = std.fmt.bufPrintZ(&z, "{s}", .{chips[i]}) catch continue;
        appkit.addSubview(parent, chip(right, y, s));
        right -= 4;
    }
}
