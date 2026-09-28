//! Built-in terminal color themes (Screen 03). Each is expressed as real
//! libghostty config keys (`background`, `foreground`, `cursor-color`,
//! `selection-*`, `palette = N=#rrggbb`), so choosing one is just a
//! settings change -- see settings.zig.
const std = @import("std");
const settings = @import("settings.zig");

pub const Theme = struct {
    name: [:0]const u8,
    bg: u24,
    fg: u24,
    cursor: u24,
    selection: u24,
    /// ANSI 0-7 then bright 8-15.
    ansi: [16]u24,
};

pub const themes = [_]Theme{
    .{
        .name = "Vigil Night",
        .bg = 0x0f1318,
        .fg = 0xc5cbd5,
        .cursor = 0xf7802a,
        // vg-iris-500 (#5b55e0) at 35% over the vg-ink-900 background,
        // pre-blended: this config format has no alpha channel.
        .selection = 0x2a2a5e,
        .ansi = .{
            0x1c2330, 0xf2555a, 0x5bd08c, 0xf2c14e, 0x5b8def, 0xc050e0, 0x4fc3d9, 0xc5cbd5,
            0x465163, 0xff7a7e, 0x86e3ac, 0xffd57a, 0x86aaf5, 0xd586f0, 0x7fd8e8, 0xf4f6f8,
        },
    },
    .{
        // The old Craft chrome's palette, kept as a terminal theme choice.
        .name = "Craft",
        .bg = 0x060911,
        .fg = 0xe6e9f2,
        .cursor = 0x4f8dff,
        .selection = 0x1b2338,
        .ansi = .{
            0x0a0e1a, 0xf0455f, 0x3ddc84, 0xf0a93e, 0x4f8dff, 0x9457f2, 0x22d3ee, 0xa6acc0,
            0x3a4664, 0xff6b81, 0x6ff0a4, 0xffc266, 0x6fa8ff, 0xb57fff, 0x67e8f9, 0xf7f8fb,
        },
    },
    .{
        .name = "Tokyo Night",
        .bg = 0x1a1b26,
        .fg = 0xc0caf5,
        .cursor = 0xc0caf5,
        .selection = 0x283457,
        .ansi = .{
            0x15161e, 0xf7768e, 0x9ece6a, 0xe0af68, 0x7aa2f7, 0xbb9af7, 0x7dcfff, 0xa9b1d6,
            0x414868, 0xf7768e, 0x9ece6a, 0xe0af68, 0x7aa2f7, 0xbb9af7, 0x7dcfff, 0xc0caf5,
        },
    },
    .{
        .name = "Nord",
        .bg = 0x2e3440,
        .fg = 0xd8dee9,
        .cursor = 0xd8dee9,
        .selection = 0x434c5e,
        .ansi = .{
            0x3b4252, 0xbf616a, 0xa3be8c, 0xebcb8b, 0x81a1c1, 0xb48ead, 0x88c0d0, 0xe5e9f0,
            0x4c566a, 0xbf616a, 0xa3be8c, 0xebcb8b, 0x81a1c1, 0xb48ead, 0x8fbcbb, 0xeceff4,
        },
    },
    .{
        .name = "Dracula",
        .bg = 0x282a36,
        .fg = 0xf8f8f2,
        .cursor = 0xf8f8f2,
        .selection = 0x44475a,
        .ansi = .{
            0x21222c, 0xff5555, 0x50fa7b, 0xf1fa8c, 0xbd93f9, 0xff79c6, 0x8be9fd, 0xf8f8f2,
            0x6272a4, 0xff6e6e, 0x69ff94, 0xffffa5, 0xd6acff, 0xff92df, 0xa4ffff, 0xffffff,
        },
    },
    .{
        .name = "Gruvbox Dark",
        .bg = 0x282828,
        .fg = 0xebdbb2,
        .cursor = 0xebdbb2,
        .selection = 0x3c3836,
        .ansi = .{
            0x282828, 0xcc241d, 0x98971a, 0xd79921, 0x458588, 0xb16286, 0x689d6a, 0xa89984,
            0x928374, 0xfb4934, 0xb8bb26, 0xfabd2f, 0x83a598, 0xd3869b, 0x8ec07c, 0xebdbb2,
        },
    },
    .{
        .name = "Solarized Dark",
        .bg = 0x002b36,
        .fg = 0x839496,
        .cursor = 0x839496,
        .selection = 0x073642,
        .ansi = .{
            0x073642, 0xdc322f, 0x859900, 0xb58900, 0x268bd2, 0xd33682, 0x2aa198, 0xeee8d5,
            0x002b36, 0xcb4b16, 0x586e75, 0x657b83, 0x839496, 0x6c71c4, 0x93a1a1, 0xfdf6e3,
        },
    },
};

/// The config keys a theme owns; applying a theme replaces exactly these.
const theme_keys = [_][]const u8{
    "theme", "background", "foreground", "cursor-color", "selection-background", "selection-foreground", "palette",
};

/// Writes `theme`'s keys into `store`, replacing any previous theme.
pub fn write(store: *settings.Store, alloc: std.mem.Allocator, theme: Theme) !void {
    for (theme_keys) |key| store.remove(alloc, key);

    var buf: [32]u8 = undefined;
    try store.add(alloc, "background", hex(&buf, theme.bg));
    try store.add(alloc, "foreground", hex(&buf, theme.fg));
    try store.add(alloc, "cursor-color", hex(&buf, theme.cursor));
    try store.add(alloc, "selection-background", hex(&buf, theme.selection));
    try store.add(alloc, "selection-foreground", hex(&buf, theme.fg));
    for (theme.ansi, 0..) |color, i| {
        const value = try std.fmt.bufPrint(&buf, "{d}=#{x:0>6}", .{ i, color });
        try store.add(alloc, "palette", value);
    }
}

fn hex(buf: []u8, color: u24) []const u8 {
    return std.fmt.bufPrint(buf, "#{x:0>6}", .{color}) catch unreachable;
}

/// Index of the theme currently written in `store`, judged by background.
pub fn currentIndex(store: *const settings.Store) ?usize {
    const bg = store.get("background") orelse return null;
    var buf: [16]u8 = undefined;
    for (themes, 0..) |t, i| {
        if (std.ascii.eqlIgnoreCase(bg, hex(&buf, t.bg))) return i;
    }
    return null;
}

test "writing a theme emits all its keys and is detectable" {
    const alloc = std.testing.allocator;
    var s: settings.Store = .{};
    defer s.deinit(alloc);
    try s.add(alloc, "font-size", "14"); // unrelated setting must survive

    try write(&s, alloc, themes[2]); // Tokyo Night
    try std.testing.expectEqual(@as(usize, 1 + 5 + 16), s.entries.items.len);
    try std.testing.expectEqualStrings("#1a1b26", s.get("background").?);
    try std.testing.expectEqual(@as(?usize, 2), currentIndex(&s));

    try write(&s, alloc, themes[4]); // Dracula; replaces, doesn't accumulate
    try std.testing.expectEqual(@as(usize, 1 + 5 + 16), s.entries.items.len);
    try std.testing.expectEqual(@as(?usize, 4), currentIndex(&s));
    try std.testing.expectEqualStrings("14", s.get("font-size").?);
}

test "palette entries use ghostty's N=#rrggbb form" {
    const alloc = std.testing.allocator;
    var s: settings.Store = .{};
    defer s.deinit(alloc);
    try write(&s, alloc, themes[0]); // Vigil Night
    var found = false;
    for (s.entries.items) |e| {
        if (std.mem.eql(u8, e.key, "palette") and std.mem.eql(u8, e.value, "1=#f2555a")) found = true;
    }
    try std.testing.expect(found);
}
