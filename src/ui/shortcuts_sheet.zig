//! Screen 06 -- the keyboard shortcuts reference. A dimmed backdrop over the
//! whole window with a centered panel listing every command from
//! `keybindings.zig`, grouped, with keycap chips. The panel is rebuilt each
//! time it opens, so it always reflects the live config.
const std = @import("std");
const objc = @import("objc");
const appkit = @import("../app/appkit.zig");
const keybindings = @import("../app/keybindings.zig");
const theme = @import("theme.zig");

const panel_w: f64 = 680;
const pad: f64 = 24;
const col_gap: f64 = 32;
const row_h: f64 = 28;
const group_gap: f64 = 14;
const header_h: f64 = 26;
const title_h: f64 = 56;

const NSViewWidthSizable: u64 = 2;
const NSViewHeightSizable: u64 = 16;
// All four margins flexible: keeps the panel centered as the window resizes.
const centered_mask: u64 = 1 | 4 | 8 | 32;

var overlay: ?objc.Object = null;
var backdrop_class: ?objc.Class = null;

pub fn isVisible() bool {
    return overlay != null;
}

pub fn toggle(parent: objc.Object) void {
    if (isVisible()) hide() else show(parent);
}

pub fn hide() void {
    const view = overlay orelse return;
    view.msgSend(void, "removeFromSuperview", .{});
    overlay = null;
}

pub fn show(parent: objc.Object) void {
    if (isVisible()) return;

    const bounds = parent.msgSend(appkit.NSRect, "bounds", .{});
    const backdrop = backdropClass().msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "initWithFrame:", .{bounds});
    appkit.styleLayer(appkit.layerBacked(backdrop), .{
        .background = .{ .r = 0.01, .g = 0.015, .b = 0.03, .a = 0.72 },
    });
    backdrop.msgSend(void, "setAutoresizingMask:", .{NSViewWidthSizable | NSViewHeightSizable});

    const col_w = (panel_w - 2 * pad - col_gap) / 2;
    const left = [_]keybindings.Group{ .tabs, .app };
    const right = [_]keybindings.Group{ .edit, .view };
    const body_h = @max(columnHeight(&left), columnHeight(&right));
    const panel_h = title_h + body_h + pad;

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
    panel.msgSend(void, "setAutoresizingMask:", .{centered_mask});
    appkit.addSubview(backdrop, panel);

    appkit.addSubview(panel, appkit.label(
        appkit.rect(pad, panel_h - 40, panel_w - 2 * pad - 60, 22),
        "Keyboard shortcuts",
        appkit.font(theme.fonts.display, theme.text_size.md, false),
        theme.colors.text_primary,
    ));
    appkit.addSubview(panel, keyChip(panel_w - pad - 40, panel_h - 38, "esc"));

    buildColumn(panel, &left, pad, panel_h - title_h, col_w);
    buildColumn(panel, &right, pad + col_w + col_gap, panel_h - title_h, col_w);

    appkit.addSubview(parent, backdrop);
    overlay = backdrop;
}

fn groupCount(group: keybindings.Group) usize {
    var n: usize = 0;
    for (keybindings.commands) |cmd| {
        if (cmd.group == group) n += 1;
    }
    return n;
}

fn columnHeight(groups: []const keybindings.Group) f64 {
    var h: f64 = 0;
    for (groups) |g| {
        h += header_h + @as(f64, @floatFromInt(groupCount(g))) * row_h + group_gap;
    }
    return h;
}

/// Lays a column of groups out top-down starting at `top` (AppKit y).
fn buildColumn(
    panel: objc.Object,
    groups: []const keybindings.Group,
    x: f64,
    top: f64,
    width: f64,
) void {
    const header_font = appkit.font(theme.fonts.mono, theme.text_size.xs2, true);
    const row_font = appkit.font(theme.fonts.body, theme.text_size.sm, false);
    var y = top;
    for (groups) |group| {
        y -= header_h;
        appkit.addSubview(panel, appkit.label(
            appkit.rect(x, y + 4, width, 16),
            headerText(group),
            header_font,
            theme.colors.text_tertiary,
        ));
        for (keybindings.commands) |cmd| {
            if (cmd.group != group) continue;
            y -= row_h;
            buildRow(panel, cmd, row_font, x, y, width);
        }
        y -= group_gap;
    }
}

fn headerText(group: keybindings.Group) [:0]const u8 {
    return switch (group) {
        .tabs => "TABS",
        .edit => "EDIT",
        .view => "VIEW",
        .app => "APP",
    };
}

/// One row: command title on the left, keycap chips right-aligned.
fn buildRow(
    panel: objc.Object,
    cmd: keybindings.Command,
    font: objc.Object,
    x: f64,
    y: f64,
    width: f64,
) void {
    var title_buf: [64:0]u8 = undefined;
    const title = std.fmt.bufPrintZ(&title_buf, "{s}", .{cmd.title}) catch return;
    appkit.addSubview(panel, appkit.label(
        appkit.rect(x, y + 4, width - 110, 18),
        title,
        font,
        theme.colors.text_secondary,
    ));

    var buf: [keybindings.max_format_len]u8 = undefined;
    const keys = keybindings.display(cmd, &buf);
    const text = keys orelse {
        const dash = appkit.label(
            appkit.rect(x + width - 110, y + 4, 110, 18),
            "\u{2014}",
            font,
            theme.colors.text_disabled,
        );
        dash.msgSend(void, "setAlignment:", .{@as(i64, 1)}); // NSTextAlignmentRight
        appkit.addSubview(panel, dash);
        return;
    };

    // Modifiers are one chip each; whatever follows is the key chip.
    var chips: [6][]const u8 = undefined;
    var n: usize = 0;
    var rest: []const u8 = text;
    while (rest.len >= 3 and n < chips.len - 1 and isModifierGlyph(rest[0..3])) {
        chips[n] = rest[0..3];
        n += 1;
        rest = rest[3..];
    }
    if (rest.len > 0) {
        chips[n] = rest;
        n += 1;
    }

    // Right-align: place from the trailing edge going left.
    var right = x + width;
    var i = n;
    while (i > 0) {
        i -= 1;
        const w = chipWidth(chips[i]);
        right -= w;
        var z: [24:0]u8 = undefined;
        const s = std.fmt.bufPrintZ(&z, "{s}", .{chips[i]}) catch continue;
        appkit.addSubview(panel, keyChip(right, y + 3, s));
        right -= 4;
    }
}

fn isModifierGlyph(s: []const u8) bool {
    inline for (.{ "⌃", "⌥", "⇧", "⌘" }) |g| {
        if (std.mem.eql(u8, s, g)) return true;
    }
    return false;
}

fn chipWidth(text: []const u8) f64 {
    const chars: f64 = @floatFromInt(std.unicode.utf8CountCodepoints(text) catch text.len);
    return @max(22, 12 + chars * 7);
}

fn keyChip(x: f64, y: f64, text: [:0]const u8) objc.Object {
    const w = chipWidth(text);
    const chip = appkit.panel(
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
    appkit.addSubview(chip, label);
    return chip;
}

fn backdropClass() objc.Class {
    if (backdrop_class) |cls| return cls;
    const cls = objc.allocateClassPair(appkit.class("NSView"), "VigilSheetBackdrop") orelse
        @panic("failed to register VigilSheetBackdrop");
    std.debug.assert(cls.addMethod("mouseDown:", backdropMouseDown));
    objc.registerClassPair(cls);
    backdrop_class = cls;
    return cls;
}

/// Clicking the dimmed area dismisses the sheet (clicks on the panel itself
/// land on the panel's subviews first and don't reach here).
fn backdropMouseDown(_: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) void {
    hide();
}
