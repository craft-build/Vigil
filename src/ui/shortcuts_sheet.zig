//! Screen 06 -- the keyboard shortcuts reference. A dimmed backdrop over the
//! whole window with a centered panel listing every command from
//! `keybindings.zig`, grouped, with keycap chips. The panel is rebuilt each
//! time it opens, so it always reflects the live config.
const std = @import("std");
const objc = @import("objc");
const appkit = @import("../app/appkit.zig");
const keybindings = @import("../app/keybindings.zig");
const theme = @import("theme.zig");
const keycaps = @import("keycaps.zig");
const overlay_ui = @import("overlay.zig");

const panel_w: f64 = 680;
const pad: f64 = 24;
const col_gap: f64 = 32;
const row_h: f64 = 28;
const group_gap: f64 = 14;
const header_h: f64 = 26;
const title_h: f64 = 56;

// All four margins flexible: keeps the panel centered as the window resizes.
const centered_mask: u64 = 1 | 4 | 8 | 32;

var overlay: ?objc.Object = null;
/// The content view the sheet is hosted in -- needed so a closing window
/// can hide it (and only if it's its own sheet), like the other overlays.
var host: ?objc.Object = null;

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
    host = null;
}

/// Hides only if the sheet is hosted by `parent` -- see palette.zig's
/// `hideIfHostedBy`.
pub fn hideIfHostedBy(parent: objc.Object) void {
    const h = host orelse return;
    if (h.value == parent.value) hide();
}

pub fn show(parent: objc.Object) void {
    if (isVisible()) return;
    host = parent;

    const bounds = parent.msgSend(appkit.NSRect, "bounds", .{});
    const backdrop = overlay_ui.backdrop(bounds, hide);

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
    appkit.addSubview(panel, keycaps.chip(panel_w - pad - 40, panel_h - 38, "esc"));

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
        appkit.setAlignment(dash, .right);
        appkit.addSubview(panel, dash);
        return;
    };

    keycaps.addShortcut(panel, text, x + width, y + 3);
}
