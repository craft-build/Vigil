//! The model behind Screen 04 (Preferences): a table of user-facing settings,
//! each mapping a control kind to real libghostty config keys in Vigil's
//! overrides store (see settings.zig). No UI here -- the preferences window
//! builds controls from this table and calls `read`/`write`.
const std = @import("std");
const settings = @import("settings.zig");

pub const Section = enum {
    general,
    appearance,
    text,
    keybindings,
    shell,

    pub fn title(self: Section) [:0]const u8 {
        return switch (self) {
            .general => "General",
            .appearance => "Appearance",
            .text => "Text",
            .keybindings => "Keybindings",
            .shell => "Shell",
        };
    }
};

pub const Value = union(enum) {
    on: bool,
    index: usize,
    number: f64,
    text: []const u8,
};

pub const Range = struct { min: f64, max: f64, step: f64 = 1 };

/// Buttons in the preferences window that open other Vigil screens.
pub const ButtonAction = enum { choose_theme, show_shortcuts };

pub const Kind = union(enum) {
    toggle,
    choice: []const [:0]const u8,
    slider: Range,
    stepper: Range,
    text,
    button: struct { title: [:0]const u8, action: ButtonAction },
    /// Read-only line of text (see `Setting.info`).
    info,
};

pub const ReadFn = *const fn (store: *const settings.Store) Value;
pub const WriteFn = *const fn (store: *settings.Store, alloc: std.mem.Allocator, value: Value) anyerror!void;

/// Which `settings.Store` a setting's `read`/`write` operate on.
/// `.ui` is for Vigil-only preferences that must never reach
/// `ghostty_config_load_file` -- see `settings.zig`'s `ui_store` doc comment.
pub const StoreTarget = enum { ghostty, ui };

pub const Setting = struct {
    section: Section,
    label: [:0]const u8,
    hint: [:0]const u8 = "",
    kind: Kind,
    read: ?ReadFn = null,
    write: ?WriteFn = null,
    target: StoreTarget = .ghostty,
};

// -- per-key read/write builders --------------------------------------------

fn BoolKey(comptime key: [:0]const u8, comptime default: bool, comptime use_effective: bool) type {
    return struct {
        fn read(store: *const settings.Store) Value {
            if (store.get(key)) |v| return .{ .on = std.mem.eql(u8, v, "true") };
            if (use_effective) if (settings.effectiveBool(key)) |b| return .{ .on = b };
            return .{ .on = default };
        }
        fn write(store: *settings.Store, alloc: std.mem.Allocator, v: Value) anyerror!void {
            try store.set(alloc, key, if (v.on) "true" else "false");
        }
    };
}

fn ChoiceKey(comptime key: [:0]const u8, comptime values: []const []const u8, comptime default: usize, comptime use_effective: bool) type {
    return struct {
        fn indexOf(name: []const u8) ?usize {
            for (values, 0..) |candidate, i| {
                if (std.mem.eql(u8, candidate, name)) return i;
            }
            return null;
        }
        fn read(store: *const settings.Store) Value {
            if (store.get(key)) |v| if (indexOf(v)) |i| return .{ .index = i };
            if (use_effective) if (settings.effectiveEnum(key)) |v| if (indexOf(v)) |i| return .{ .index = i };
            return .{ .index = default };
        }
        fn write(store: *settings.Store, alloc: std.mem.Allocator, v: Value) anyerror!void {
            if (v.index >= values.len) return error.OutOfRange;
            try store.set(alloc, key, values[v.index]);
        }
    };
}

fn NumberKey(comptime key: [:0]const u8, comptime T: type, comptime default: f64, comptime decimals: u8) type {
    const fmt = std.fmt.comptimePrint("{{d:.{d}}}", .{decimals});
    return struct {
        fn read(store: *const settings.Store) Value {
            if (store.get(key)) |v| {
                if (std.fmt.parseFloat(f64, v)) |n| return .{ .number = n } else |_| {}
            }
            if (settings.effectiveFloat(T, key)) |n| return .{ .number = @floatCast(n) };
            return .{ .number = default };
        }
        fn write(store: *settings.Store, alloc: std.mem.Allocator, v: Value) anyerror!void {
            var buf: [32]u8 = undefined;
            try store.set(alloc, key, try std.fmt.bufPrint(&buf, fmt, .{v.number}));
        }
    };
}

const CursorStyle = ChoiceKey("cursor-style", &.{ "block", "bar", "underline" }, 0, true);
const ShellIntegration = ChoiceKey("shell-integration", &.{ "detect", "none" }, 0, false);
const MouseHide = BoolKey("mouse-hide-while-typing", false, true);
const Blur = BoolKey("background-blur", false, false);
/// Vigil-only, not a real libghostty key -- lives in `settings.ui_store`
/// (see its doc comment), never in the file libghostty parses. Read once
/// at window creation (`Window.create`); changing it takes effect on the
/// next launch.
const VerticalTabs = BoolKey("vigil-vertical-tabs", false, false);
const Opacity = NumberKey("background-opacity", f64, 1.0, 2);
const FontSize = NumberKey("font-size", f32, 13, 1);

const FontFamily = struct {
    fn read(store: *const settings.Store) Value {
        const v = store.get("font-family") orelse return .{ .text = "" };
        return .{ .text = std.mem.trim(u8, v, "\"") };
    }
    fn write(store: *settings.Store, alloc: std.mem.Allocator, v: Value) anyerror!void {
        const name = std.mem.trim(u8, v.text, " \t\"");
        if (name.len == 0) {
            store.remove(alloc, "font-family");
            return;
        }
        var buf: [256]u8 = undefined;
        try store.set(alloc, "font-family", try std.fmt.bufPrint(&buf, "\"{s}\"", .{name}));
    }
};

/// Ligatures are on unless the calt/liga/dlig features are switched off.
/// Only the entries Vigil itself writes are touched, so a user's other
/// `font-feature` lines survive.
const Ligatures = struct {
    const off_features = [_][]const u8{ "-calt", "-liga", "-dlig" };

    fn read(store: *const settings.Store) Value {
        return .{ .on = !store.has("font-feature", "-calt") };
    }
    fn write(store: *settings.Store, alloc: std.mem.Allocator, v: Value) anyerror!void {
        for (off_features) |f| store.removeExact(alloc, "font-feature", f);
        if (!v.on) {
            for (off_features) |f| try store.add(alloc, "font-feature", f);
        }
    }
};

/// One number drives both padding axes.
const Padding = struct {
    fn read(store: *const settings.Store) Value {
        if (store.get("window-padding-x")) |v| {
            if (std.fmt.parseFloat(f64, v)) |n| return .{ .number = n } else |_| {}
        }
        return .{ .number = 2 };
    }
    fn write(store: *settings.Store, alloc: std.mem.Allocator, v: Value) anyerror!void {
        var buf: [16]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "{d:.0}", .{v.number});
        try store.set(alloc, "window-padding-x", text);
        try store.set(alloc, "window-padding-y", text);
    }
};

pub const all = [_]Setting{
    .{
        .section = .general,
        .label = "Hide mouse while typing",
        .hint = "Hides the pointer over the terminal until it moves.",
        .kind = .toggle,
        .read = MouseHide.read,
        .write = MouseHide.write,
    },
    .{
        .section = .general,
        .label = "Window padding",
        .hint = "Space between the terminal text and its edges, in points.",
        .kind = .{ .stepper = .{ .min = 0, .max = 40, .step = 1 } },
        .read = Padding.read,
        .write = Padding.write,
    },

    .{
        .section = .appearance,
        .label = "Theme",
        .hint = "Colors for text, background and the 16 ANSI slots.",
        .kind = .{ .button = .{ .title = "Choose theme\u{2026}", .action = .choose_theme } },
    },
    .{
        .section = .appearance,
        .label = "Cursor style",
        .kind = .{ .choice = &.{ "Block", "Bar", "Underline" } },
        .read = CursorStyle.read,
        .write = CursorStyle.write,
    },
    .{
        .section = .appearance,
        .label = "Background opacity",
        .hint = "Below 100% the terminal area becomes translucent.",
        .kind = .{ .slider = .{ .min = 0.3, .max = 1.0, .step = 0.05 } },
        .read = Opacity.read,
        .write = Opacity.write,
    },
    .{
        .section = .appearance,
        .label = "Background blur",
        .hint = "Blurs what's behind the window. Only visible when opacity is below 100%.",
        .kind = .toggle,
        .read = Blur.read,
        .write = Blur.write,
    },
    .{
        .section = .appearance,
        .label = "Vertical tabs",
        .hint = "Move tabs into a sidebar. Takes effect the next time Vigil starts.",
        .kind = .toggle,
        .read = VerticalTabs.read,
        .write = VerticalTabs.write,
        .target = .ui,
    },

    .{
        .section = .text,
        .label = "Font family",
        .hint = "Leave empty for the default. Press Return to apply.",
        .kind = .text,
        .read = FontFamily.read,
        .write = FontFamily.write,
    },
    .{
        .section = .text,
        .label = "Font size",
        .kind = .{ .stepper = .{ .min = 8, .max = 36, .step = 1 } },
        .read = FontSize.read,
        .write = FontSize.write,
    },
    .{
        .section = .text,
        .label = "Ligatures",
        .hint = "Combine sequences like -> and != into single glyphs (needs a font that has them).",
        .kind = .toggle,
        .read = Ligatures.read,
        .write = Ligatures.write,
    },

    .{
        .section = .keybindings,
        .label = "Keyboard shortcuts",
        .hint = "Shortcuts come from your Ghostty config; edit its keybind lines to change them.",
        .kind = .{ .button = .{ .title = "Show shortcuts", .action = .show_shortcuts } },
    },

    .{
        .section = .shell,
        .label = "Shell integration",
        .hint = "Lets the shell report its directory and prompts. Applies to new tabs.",
        .kind = .{ .choice = &.{ "Auto", "Off" } },
        .read = ShellIntegration.read,
        .write = ShellIntegration.write,
    },
    .{
        .section = .shell,
        .label = "Login shell",
        .hint = "Set by macOS. Change it with chsh.",
        .kind = .info,
    },
};

// -- tests ------------------------------------------------------------------

fn find(label: []const u8) *const Setting {
    for (&all) |*s| if (std.mem.eql(u8, s.label, label)) return s;
    unreachable;
}

test "every non-static setting has read and write" {
    for (all) |s| switch (s.kind) {
        .button, .info => {},
        else => try std.testing.expect(s.read != null and s.write != null),
    };
}

test "toggle round-trips through the store" {
    const alloc = std.testing.allocator;
    var store: settings.Store = .{};
    defer store.deinit(alloc);
    const s = find("Background blur");
    try std.testing.expect(!s.read.?(&store).on);
    try s.write.?(&store, alloc, .{ .on = true });
    try std.testing.expectEqualStrings("true", store.get("background-blur").?);
    try std.testing.expect(s.read.?(&store).on);
}

test "choice maps index to config value" {
    const alloc = std.testing.allocator;
    var store: settings.Store = .{};
    defer store.deinit(alloc);
    const s = find("Cursor style");
    try s.write.?(&store, alloc, .{ .index = 1 });
    try std.testing.expectEqualStrings("bar", store.get("cursor-style").?);
    try std.testing.expectEqual(@as(usize, 1), s.read.?(&store).index);
    try std.testing.expectError(error.OutOfRange, s.write.?(&store, alloc, .{ .index = 9 }));
}

test "numbers are written with sensible precision" {
    const alloc = std.testing.allocator;
    var store: settings.Store = .{};
    defer store.deinit(alloc);
    try find("Background opacity").write.?(&store, alloc, .{ .number = 0.85 });
    try std.testing.expectEqualStrings("0.85", store.get("background-opacity").?);
    try find("Font size").write.?(&store, alloc, .{ .number = 14 });
    try std.testing.expectEqualStrings("14.0", store.get("font-size").?);
    try std.testing.expectEqual(@as(f64, 14), find("Font size").read.?(&store).number);
}

test "padding sets both axes" {
    const alloc = std.testing.allocator;
    var store: settings.Store = .{};
    defer store.deinit(alloc);
    try find("Window padding").write.?(&store, alloc, .{ .number = 12 });
    try std.testing.expectEqualStrings("12", store.get("window-padding-x").?);
    try std.testing.expectEqualStrings("12", store.get("window-padding-y").?);
}

test "font family quotes names and empty clears it" {
    const alloc = std.testing.allocator;
    var store: settings.Store = .{};
    defer store.deinit(alloc);
    const s = find("Font family");
    try s.write.?(&store, alloc, .{ .text = "JetBrains Mono" });
    try std.testing.expectEqualStrings("\"JetBrains Mono\"", store.get("font-family").?);
    try std.testing.expectEqualStrings("JetBrains Mono", s.read.?(&store).text);
    try s.write.?(&store, alloc, .{ .text = "  " });
    try std.testing.expect(store.get("font-family") == null);
}

test "ligatures toggle only touches the features Vigil owns" {
    const alloc = std.testing.allocator;
    var store: settings.Store = .{};
    defer store.deinit(alloc);
    try store.add(alloc, "font-feature", "ss01"); // the user's own
    const s = find("Ligatures");
    try std.testing.expect(s.read.?(&store).on);

    try s.write.?(&store, alloc, .{ .on = false });
    try std.testing.expect(!s.read.?(&store).on);
    try std.testing.expectEqual(@as(usize, 4), store.entries.items.len);

    try s.write.?(&store, alloc, .{ .on = false }); // idempotent, no duplicates
    try std.testing.expectEqual(@as(usize, 4), store.entries.items.len);

    try s.write.?(&store, alloc, .{ .on = true });
    try std.testing.expectEqual(@as(usize, 1), store.entries.items.len);
    try std.testing.expect(store.has("font-feature", "ss01"));
}
