//! Screen 03 -- the theme gallery: a grid of cards, each previewing a
//! palette as a tiny terminal. Choosing a card applies it live (via
//! `on_select`, which rewrites Vigil's config and updates every surface).
//! Arrow keys move focus, Return applies, Esc closes; clicking a card
//! applies it too. The panel stays open so themes can be compared.
const std = @import("std");
const objc = @import("objc");
const appkit = @import("../app/appkit.zig");
const keymonitor = @import("../app/keymonitor.zig");
const themes = @import("../app/themes.zig");
const theme = @import("theme.zig");
const clickable = @import("clickable.zig");
const overlay_ui = @import("overlay.zig");

const Card = clickable.Kind("VigilThemeCard");

const columns: usize = 3;
const card_w: f64 = 208;
const card_h: f64 = 148;
const preview_h: f64 = 100;
const gap: f64 = 16;
const pad: f64 = 24;
const title_h: f64 = 56;

const key_left: u16 = 123;
const key_right: u16 = 124;

var overlay: ?objc.Object = null;
var host: ?objc.Object = null;
var focus: usize = 0;
var applied: ?usize = null;

/// Called with the chosen theme index; the caller applies it and reports
/// the new current index back via `setApplied`.
pub var on_select: ?*const fn (index: usize) void = null;

pub fn isVisible() bool {
    return overlay != null;
}

pub fn toggle(parent: objc.Object, current: ?usize) void {
    if (isVisible()) hide() else show(parent, current);
}

pub fn show(parent: objc.Object, current: ?usize) void {
    if (isVisible()) return;
    host = parent;
    applied = current;
    focus = current orelse 0;
    Card.on_click = onCardClick;
    render();
}

pub fn hide() void {
    if (overlay) |view| view.msgSend(void, "removeFromSuperview", .{});
    overlay = null;
    host = null;
}

/// Hides only if the gallery is hosted by `parent` -- see palette.zig's
/// `hideIfHostedBy`.
pub fn hideIfHostedBy(parent: objc.Object) void {
    const h = host orelse return;
    if (h.value == parent.value) hide();
}

pub fn setApplied(index: ?usize) void {
    applied = index;
    if (isVisible()) render();
}

/// Returns true if the key was consumed. ⌘/⌃ shortcuts pass through.
pub fn handleKey(event: objc.Object) bool {
    if (!isVisible()) return false;
    if (keymonitor.isShortcut(event)) return false;

    const count = themes.themes.len;
    switch (keymonitor.keyCode(event)) {
        keymonitor.key_escape => hide(),
        keymonitor.key_return, keymonitor.key_keypad_enter => choose(focus),
        key_left => moveFocus(if (focus > 0) focus - 1 else focus),
        key_right => moveFocus(@min(focus + 1, count - 1)),
        keymonitor.key_up => moveFocus(if (focus >= columns) focus - columns else focus),
        keymonitor.key_down => moveFocus(if (focus + columns < count) focus + columns else focus),
        else => {},
    }
    return true;
}

fn moveFocus(next: usize) void {
    if (next == focus) return;
    focus = next;
    render();
}

fn onCardClick(tag: usize) void {
    focus = tag;
    choose(tag);
}

fn choose(index: usize) void {
    if (on_select) |cb| cb(index);
}

fn render() void {
    const parent = host orelse return;
    if (overlay) |old| old.msgSend(void, "removeFromSuperview", .{});

    const bounds = parent.msgSend(appkit.NSRect, "bounds", .{});
    const backdrop = overlay_ui.backdrop(bounds, hide);

    const rows = (themes.themes.len + columns - 1) / columns;
    const panel_w = 2 * pad + @as(f64, @floatFromInt(columns)) * card_w + @as(f64, @floatFromInt(columns - 1)) * gap;
    const panel_h = title_h + @as(f64, @floatFromInt(rows)) * card_h + @as(f64, @floatFromInt(rows - 1)) * gap + pad;
    const panel = appkit.panel(
        appkit.rect(
            @round((bounds.size.width - panel_w) / 2),
            @round((bounds.size.height - panel_h) / 2),
            panel_w,
            panel_h,
        ),
        .{
            .background = theme.colors.bg_surface_raised,
            .border = theme.colors.border_default,
            .corner_radius = theme.radius.lg,
        },
    );
    // All four margins flexible: stays centered as the window resizes.
    panel.msgSend(void, "setAutoresizingMask:", .{@as(u64, 1 | 4 | 8 | 32)});
    appkit.addSubview(backdrop, panel);

    appkit.addSubview(panel, appkit.label(
        appkit.rect(pad, panel_h - 40, panel_w - 2 * pad, 22),
        "Themes",
        appkit.font(theme.fonts.display, theme.text_size.md, false),
        theme.colors.text_primary,
    ));

    for (themes.themes, 0..) |t, i| {
        const col = i % columns;
        const row = i / columns;
        const x = pad + @as(f64, @floatFromInt(col)) * (card_w + gap);
        const y = panel_h - title_h - @as(f64, @floatFromInt(row + 1)) * card_h - @as(f64, @floatFromInt(row)) * gap;
        appkit.addSubview(panel, buildCard(t, i, x, y));
    }

    appkit.addSubview(parent, backdrop);
    overlay = backdrop;
}

fn color(rgb: u24) theme.Color {
    return .{
        .r = @as(f64, @floatFromInt((rgb >> 16) & 0xff)) / 255.0,
        .g = @as(f64, @floatFromInt((rgb >> 8) & 0xff)) / 255.0,
        .b = @as(f64, @floatFromInt(rgb & 0xff)) / 255.0,
    };
}

fn buildCard(t: themes.Theme, index: usize, x: f64, y: f64) objc.Object {
    const is_focus = index == focus;
    const is_applied = applied != null and applied.? == index;

    const card = Card.view(appkit.rect(x, y, card_w, card_h), index, .{
        .background = theme.colors.bg_surface,
        .border = if (is_focus) theme.colors.accent else theme.colors.border_default,
        .border_width = if (is_focus) 2 else 1,
        .corner_radius = theme.radius.md,
    });

    // Preview: a few lines drawn with the theme's own colors.
    const preview = appkit.panel(
        appkit.rect(6, card_h - preview_h - 6, card_w - 12, preview_h),
        .{ .background = color(t.bg), .corner_radius = theme.radius.sm },
    );
    appkit.addSubview(card, preview);

    const mono = appkit.font(theme.fonts.mono, 11, true);
    const lines = [_]struct { text: [:0]const u8, fg: u24 }{
        .{ .text = "$ git status", .fg = t.ansi[2] },
        .{ .text = "On branch main", .fg = t.fg },
        .{ .text = "  modified: app.zig", .fg = t.ansi[3] },
        .{ .text = "  new file: theme.zig", .fg = t.ansi[4] },
        .{ .text = "$ _", .fg = t.ansi[5] },
    };
    var ly: f64 = preview_h - 22;
    for (lines) |line| {
        appkit.addSubview(preview, appkit.label(
            appkit.rect(10, ly, card_w - 32, 16),
            line.text,
            mono,
            color(line.fg),
        ));
        ly -= 18;
    }

    appkit.addSubview(card, appkit.label(
        appkit.rect(12, 10, card_w - 48, 18),
        t.name,
        appkit.font(theme.fonts.body, theme.text_size.sm, false),
        if (is_applied) theme.colors.text_primary else theme.colors.text_secondary,
    ));
    if (is_applied) {
        const check = appkit.label(
            appkit.rect(card_w - 32, 10, 20, 18),
            "\u{2713}",
            appkit.font(theme.fonts.body, theme.text_size.sm, false),
            theme.colors.success,
        );
        appkit.setAlignment(check, .right);
        appkit.addSubview(card, check);
    }
    return card;
}
