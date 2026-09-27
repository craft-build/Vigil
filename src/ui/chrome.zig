//! Screen 01 ("Main window") chrome from Vigil.dc.html: a pill-shaped tab
//! bar, a terminal pane + log side-panel split, and a bottom status bar.
//! Plain layer-backed NSViews + NSTextFields positioned by hand (no Auto
//! Layout) -- simple, and matches the prototype's fixed-geometry chrome.
const std = @import("std");
const objc = @import("objc");
const appkit = @import("../app/appkit.zig");
const theme = @import("theme.zig");

const NSViewMinXMargin: u64 = 1;
const NSViewWidthSizable: u64 = 2;
const NSViewMinYMargin: u64 = 8;
const NSViewHeightSizable: u64 = 16;
const NSViewMaxYMargin: u64 = 32;

fn setAutoresizing(view: objc.Object, mask: u64) void {
    view.msgSend(void, "setAutoresizingMask:", .{mask});
}

pub const tab_bar_height: f64 = 38;
pub const status_bar_height: f64 = 26;
pub const log_pane_width: f64 = 260;

// NSWindow's native close/minimize/zoom buttons still live at the leading
// edge of the full-size titlebar. Leave their area clear of the tab pills.
const window_controls_width: f64 = 78;
var tab_bar_class: ?objc.Class = null;

fn tabBarClass() objc.Class {
    if (tab_bar_class) |cls| return cls;
    const cls = objc.allocateClassPair(appkit.class("NSView"), "VigilTabBarView") orelse
        @panic("failed to register VigilTabBarView");
    std.debug.assert(cls.addMethod("mouseDownCanMoveWindow", mouseDownCanMoveWindow));
    objc.registerClassPair(cls);
    tab_bar_class = cls;
    return cls;
}

fn mouseDownCanMoveWindow(_: objc.c.id, _: objc.c.SEL) callconv(.c) bool {
    return true;
}

/// `index` value carried by the "+" item.
pub const plus_index: usize = 1 << 30;

/// Called on the main thread when a tab pill (or the "+" item, with
/// `plus_index`) is clicked.
pub var on_tab_click: ?*const fn (index: usize) void = null;

var tab_item_class: ?objc.Class = null;

fn tabItemClass() objc.Class {
    if (tab_item_class) |cls| return cls;
    const cls = objc.allocateClassPair(appkit.class("NSView"), "VigilTabItemView") orelse
        @panic("failed to register VigilTabItemView");
    _ = cls.addIvar("vigilIndex");
    std.debug.assert(cls.addMethod("mouseDown:", tabItemMouseDown));
    std.debug.assert(cls.addMethod("mouseDownCanMoveWindow", notMovable));
    std.debug.assert(cls.addMethod("hitTest:", tabItemHitTest));
    objc.registerClassPair(cls);
    tab_item_class = cls;
    return cls;
}

fn notMovable(_: objc.c.id, _: objc.c.SEL) callconv(.c) bool {
    return false;
}

/// Labels inside the item would otherwise swallow the click; claim any hit
/// that lands inside the item itself.
fn tabItemHitTest(id: objc.c.id, sel: objc.c.SEL, point: appkit.NSPoint) callconv(.c) objc.c.id {
    const obj = objc.Object{ .value = id };
    const hit = obj.msgSendSuper(appkit.class("NSView"), objc.Object, objc.Sel{ .value = sel }, .{point});
    return if (hit.value != null) id else null;
}

fn tabItemMouseDown(id: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) void {
    const stored = (objc.Object{ .value = id }).getInstanceVariable("vigilIndex");
    const raw = @intFromPtr(stored.value);
    if (raw == 0) return;
    // Stored shifted so the fake "pointer" is aligned (see `tabItem`).
    if (on_tab_click) |cb| cb((raw >> 4) - 1);
}

fn tabItem(frame: appkit.NSRect, index: usize, style: appkit.LayerStyle) objc.Object {
    const item = tabItemClass().msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "initWithFrame:", .{frame});
    appkit.styleLayer(appkit.layerBacked(item), style);
    item.setInstanceVariable("vigilIndex", .{ .value = @ptrFromInt((index + 1) << 4) });
    return item;
}

pub const TabBar = struct {
    group: objc.Object,
};

/// Builds the top pill tab bar and adds it to `parent`. `width` is the
/// parent's current width; the bar pins to the top edge and stretches with
/// window width via autoresizing. Call `populateTabs` to fill it.
pub fn buildTabBar(parent: objc.Object, width: f64, height: f64) TabBar {
    const bar = tabBarClass().msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "initWithFrame:", .{
        appkit.rect(0, height - tab_bar_height, width, tab_bar_height),
    });
    appkit.styleLayer(appkit.layerBacked(bar), .{ .background = theme.colors.bg_surface });
    setAutoresizing(bar, NSViewWidthSizable | NSViewMinYMargin);
    appkit.addSubview(parent, bar);

    // Bottom hairline border, matching the prototype's border-bottom.
    const border = appkit.panel(appkit.rect(0, 0, width, 1), .{ .background = theme.colors.border_subtle });
    setAutoresizing(border, NSViewWidthSizable);
    appkit.addSubview(bar, border);

    // Pill group container that holds the session tabs.
    const group = appkit.panel(
        appkit.rect(window_controls_width, (tab_bar_height - tab_group_height) / 2, 0, tab_group_height),
        .{ .background = theme.colors.bg_sunken, .corner_radius = theme.radius.pill },
    );
    appkit.addSubview(bar, group);
    return .{ .group = group };
}

const tab_group_height: f64 = 30;

/// Replaces the pills in `bar` with one per title, highlighting `active`.
pub fn populateTabs(bar: TabBar, titles: []const [:0]const u8, active: usize) void {
    const group = bar.group;
    const subviews = group.msgSend(objc.Object, "subviews", .{});
    // Iterate over a copy: removing from the live array while walking it skips items.
    const copy = subviews.msgSend(objc.Object, "copy", .{});
    defer copy.msgSend(void, "release", .{});
    var n = copy.msgSend(u64, "count", .{});
    while (n > 0) : (n -= 1) {
        copy.msgSend(objc.Object, "objectAtIndex:", .{n - 1}).msgSend(void, "removeFromSuperview", .{});
    }

    const mono = appkit.font(theme.fonts.mono, theme.text_size.xs, true);
    const label_h: f64 = 18;
    const count: f64 = @floatFromInt(@max(titles.len, 1));
    const tab_w: f64 = std.math.clamp(520.0 / count, 80, 150);
    var x: f64 = 3;
    for (titles, 0..) |title, i| {
        const is_active = i == active;
        const item = tabItem(
            appkit.rect(x, 3, tab_w, tab_group_height - 6),
            i,
            .{
                .background = if (is_active) theme.colors.bg_surface_raised else null,
                .corner_radius = theme.radius.pill,
            },
        );
        const label = appkit.label(
            appkit.rect(12, (tab_group_height - 6 - label_h) / 2, tab_w - 24, label_h),
            title,
            mono,
            if (is_active) theme.colors.text_primary else theme.colors.text_tertiary,
        );
        label.msgSend(void, "setLineBreakMode:", .{@as(u64, 4)}); // NSLineBreakByTruncatingTail
        appkit.addSubview(item, label);
        appkit.addSubview(group, item);
        x += tab_w;
    }

    const plus_w: f64 = 28;
    const plus = tabItem(appkit.rect(x, 3, plus_w, tab_group_height - 6), plus_index, .{});
    appkit.addSubview(plus, appkit.label(
        appkit.rect(0, 0, plus_w, tab_group_height - 8),
        "+",
        appkit.font(theme.fonts.display, theme.text_size.md, false),
        theme.colors.text_tertiary,
    ));
    appkit.addSubview(group, plus);
    x += plus_w + 3;

    var frame = group.msgSend(appkit.NSRect, "frame", .{});
    frame.size.width = x;
    group.msgSend(void, "setFrame:", .{frame});
    // The group's corner radius was clamped for its initial zero width.
    const layer = group.msgSend(objc.Object, "layer", .{});
    layer.msgSend(void, "setCornerRadius:", .{tab_group_height / 2});
    layer.msgSend(void, "setMasksToBounds:", .{true});
}

/// Builds the bottom status bar and adds it to `parent`, pinned to the
/// bottom edge.
pub fn buildStatusBar(parent: objc.Object, width: f64) void {
    const bar = appkit.panel(
        appkit.rect(0, 0, width, status_bar_height),
        .{ .background = theme.colors.bg_surface },
    );
    setAutoresizing(bar, NSViewWidthSizable | NSViewMaxYMargin);
    appkit.addSubview(parent, bar);

    const border = appkit.panel(
        appkit.rect(0, status_bar_height - 1, width, 1),
        .{ .background = theme.colors.border_subtle },
    );
    setAutoresizing(border, NSViewWidthSizable);
    appkit.addSubview(bar, border);

    const mono = appkit.font(theme.fonts.mono, 11, true);
    appkit.addSubview(bar, appkit.label(
        appkit.rect(12, 4, 220, 18),
        "\u{e0a0} feat/pane-resize \u{00b7} ~/craft/apps/web",
        mono,
        theme.colors.text_tertiary,
    ));

    const pill_w: f64 = 64;
    const pill = appkit.panel(
        appkit.rect(width - pill_w - 120, 4, pill_w, 18),
        .{ .background = theme.colors.bg_surface_raised, .corner_radius = theme.radius.pill },
    );
    setAutoresizing(pill, NSViewMinXMargin);
    appkit.addSubview(bar, pill);
    appkit.addSubview(pill, appkit.label(
        appkit.rect(0, 0, pill_w, 18),
        "\u{25cf} running",
        appkit.font(theme.fonts.mono, 10, true),
        theme.colors.green_500,
    ));

    const trailing = appkit.label(
        appkit.rect(width - 110, 4, 100, 18),
        "zsh \u{00b7} 128\u{00d7}34",
        mono,
        theme.colors.text_tertiary,
    );
    setAutoresizing(trailing, NSViewMinXMargin);
    appkit.addSubview(bar, trailing);
}

/// Builds the right-hand "logs -- tail -f" panel. `frame` is its initial
/// position/size within the parent (right-pinned via autoresizing).
pub fn buildLogPane(parent: objc.Object, frame: appkit.NSRect) void {
    const pane = appkit.panel(frame, .{ .background = theme.colors.bg_sunken });
    setAutoresizing(pane, NSViewMinXMargin | NSViewHeightSizable);
    appkit.addSubview(parent, pane);

    const border = appkit.panel(
        appkit.rect(0, 0, 1, frame.size.height),
        .{ .background = theme.colors.border_subtle },
    );
    setAutoresizing(border, NSViewHeightSizable);
    appkit.addSubview(pane, border);

    const header_font = appkit.font(theme.fonts.mono, theme.text_size.xs2, true);
    appkit.addSubview(pane, appkit.label(
        appkit.rect(12, frame.size.height - 30, frame.size.width - 24, 18),
        "logs \u{2014} tail -f",
        header_font,
        theme.colors.text_tertiary,
    ));

    const line_font = appkit.font(theme.fonts.mono, 11, true);
    const lines = [_][:0]const u8{
        "renderer: gpu backend metal",
        "pty: spawned zsh (pid 41213)",
        "session: attached pane 2",
    };
    var y = frame.size.height - 56;
    for (lines) |line| {
        appkit.addSubview(pane, appkit.label(
            appkit.rect(12, y, frame.size.width - 24, 16),
            line,
            line_font,
            theme.colors.text_tertiary,
        ));
        y -= 20;
    }
}
