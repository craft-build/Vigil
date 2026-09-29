//! Screen 01 ("Main window") chrome from Vigil.dc.html: the titlebar tab
//! bar (an individually-shaped `Tab` per session, matching
//! `components/navigation/TabBar.jsx` in the design system bundle, not a
//! pill-group container), a terminal pane + log side-panel split, and a
//! bottom status bar. Plain layer-backed NSViews + NSTextFields positioned
//! by hand (no Auto Layout) -- simple, and matches the prototype's
//! fixed-geometry chrome.
//!
//! Vigil can have more than one window open, so every clickable/tracked
//! view here carries a `vigilOwner` ivar -- an opaque `*anyopaque` the
//! caller sets to its owning `*Window` -- alongside whatever tag/index it
//! already carried. That's what lets the callbacks below (`on_tab_click`
//! and friends) be wired *once*, app-wide, instead of being re-wired (and
//! clobbered) by every new window.
const std = @import("std");
const objc = @import("objc");
const appkit = @import("../app/appkit.zig");
const theme = @import("theme.zig");
const clickable = @import("clickable.zig");
const rename_field = @import("rename_field.zig");

const NSViewMinXMargin: u64 = 1;
const NSViewWidthSizable: u64 = 2;
const NSViewMinYMargin: u64 = 8;

fn setAutoresizing(view: objc.Object, mask: u64) void {
    view.msgSend(void, "setAutoresizingMask:", .{mask});
}

pub const tab_bar_height: f64 = 38; // --titlebar-height
const tab_row_height: f64 = 30; // --tabbar-height
const tab_min_w: f64 = 90;
const tab_max_w: f64 = 240;
const tab_gap: f64 = 4;
const new_tab_btn_size: f64 = 22;
const settings_btn_size: f64 = 22;
const trailing_pad: f64 = 14;

// NSWindow's native close/minimize/zoom buttons still live at the leading
// edge of the full-size titlebar. Leave their area clear of the tabs.
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

/// Called on the main thread when a tab (or the "+" button, with
/// `plus_index`) is clicked, with the owning `*Window` (as set by whoever
/// called `populateTabs`).
pub var on_tab_click: ?*const fn (owner: ?*anyopaque, index: usize) void = null;

/// Called when a tab (never the "+" button) is double-clicked -- starts a
/// rename. See `beginRename`.
pub var on_tab_double_click: ?*const fn (owner: ?*anyopaque, index: usize) void = null;

/// Called when an in-progress rename is committed (Return, or clicking away
/// -- `NSTextField`'s usual "end editing" triggers), with the field's text.
pub var on_rename_commit: ?*const fn (owner: ?*anyopaque, index: usize, text: []const u8) void = null;

/// Called when a tab's close button is clicked.
pub var on_tab_close: ?*const fn (owner: ?*anyopaque, index: usize) void = null;

// -- individual tab -----------------------------------------------------------
// Mirrors components/navigation/TabBar.jsx's `Tab`: a rounded rect (not a
// pill), centered title, a leading icon slot that swaps to a close button on
// hover, and a trailing ⌘-N hint slot.

var tab_item_class: ?objc.Class = null;

fn tabItemClass() objc.Class {
    if (tab_item_class) |cls| return cls;
    const cls = objc.allocateClassPair(appkit.class("NSView"), "VigilTabItemView") orelse
        @panic("failed to register VigilTabItemView");
    _ = cls.addIvar("vigilIndex");
    _ = cls.addIvar("vigilIcon");
    _ = cls.addIvar("vigilClose");
    _ = cls.addIvar("vigilActive");
    _ = cls.addIvar("vigilOwner");
    std.debug.assert(cls.addMethod("mouseDown:", tabItemMouseDown));
    std.debug.assert(cls.addMethod("mouseDownCanMoveWindow", notMovable));
    std.debug.assert(cls.addMethod("hitTest:", tabItemHitTest));
    std.debug.assert(cls.addMethod("mouseEntered:", tabItemMouseEntered));
    std.debug.assert(cls.addMethod("mouseExited:", tabItemMouseExited));
    std.debug.assert(cls.addMethod("updateTrackingAreas", tabItemUpdateTrackingAreas));
    objc.registerClassPair(cls);
    tab_item_class = cls;
    return cls;
}

fn notMovable(_: objc.c.id, _: objc.c.SEL) callconv(.c) bool {
    return false;
}

/// Labels inside the item would otherwise swallow the click; claim any hit
/// that lands inside the item itself. The close button is a sibling (not a
/// descendant), so this doesn't affect it -- normal top-down hit-testing
/// already routes its clicks there when it's the frontmost view at that
/// point.
fn tabItemHitTest(id: objc.c.id, sel: objc.c.SEL, point: appkit.NSPoint) callconv(.c) objc.c.id {
    const obj = objc.Object{ .value = id };
    const hit = obj.msgSendSuper(appkit.class("NSView"), objc.Object, objc.Sel{ .value = sel }, .{point});
    return if (hit.value != null) id else null;
}

fn tabItemMouseDown(id: objc.c.id, _: objc.c.SEL, event: objc.c.id) callconv(.c) void {
    const obj = objc.Object{ .value = id };
    const raw = @intFromPtr(obj.getInstanceVariable("vigilIndex").value);
    if (raw == 0) return;
    // Stored shifted so the fake "pointer" is aligned (see `buildTabItem`).
    const index = (raw >> 4) - 1;
    const owner = obj.getInstanceVariable("vigilOwner").value;
    if (on_tab_click) |cb| cb(owner, index);

    const click_count = (objc.Object{ .value = event }).msgSend(i64, "clickCount", .{});
    if (click_count >= 2 and index != plus_index) {
        if (on_tab_double_click) |cb| cb(owner, index);
    }
}

const tracking_mouse_entered_exited: u64 = 0x01;
const tracking_active_in_key_window: u64 = 0x20;
const tracking_in_visible_rect: u64 = 0x200;

fn tabItemUpdateTrackingAreas(id: objc.c.id, sel: objc.c.SEL) callconv(.c) void {
    const obj = objc.Object{ .value = id };
    obj.msgSendSuper(appkit.class("NSView"), void, objc.Sel{ .value = sel }, .{});

    const existing = obj.msgSend(objc.Object, "trackingAreas", .{});
    var i = existing.msgSend(u64, "count", .{});
    while (i > 0) : (i -= 1) {
        obj.msgSend(void, "removeTrackingArea:", .{existing.msgSend(objc.Object, "objectAtIndex:", .{i - 1})});
    }

    const area = appkit.class("NSTrackingArea").msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "initWithRect:options:owner:userInfo:", .{
        appkit.rect(0, 0, 0, 0),
        tracking_mouse_entered_exited | tracking_active_in_key_window | tracking_in_visible_rect,
        obj,
        @as(?*anyopaque, null),
    });
    obj.msgSend(void, "addTrackingArea:", .{area});
    area.msgSend(void, "release", .{});
}

fn tabItemMouseEntered(id: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) void {
    setHovered(id, true);
}

fn tabItemMouseExited(id: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) void {
    setHovered(id, false);
}

/// Swaps the leading icon slot for the close button (and back), and tints
/// the background for inactive tabs -- an active tab's background never
/// changes on hover, matching the prototype.
fn setHovered(id: objc.c.id, hovered: bool) void {
    const obj = objc.Object{ .value = id };
    if (obj.getInstanceVariable("vigilIcon").value) |v| (objc.Object{ .value = v }).msgSend(void, "setHidden:", .{hovered});
    if (obj.getInstanceVariable("vigilClose").value) |v| (objc.Object{ .value = v }).msgSend(void, "setHidden:", .{!hovered});

    if (@intFromPtr(obj.getInstanceVariable("vigilActive").value) != 0) return;
    const layer = obj.msgSend(objc.Object, "layer", .{});
    layer.msgSend(void, "setBackgroundColor:", .{
        if (hovered) appkit.cgColor(theme.colors.hover) else appkit.cgColor(.{ .r = 0, .g = 0, .b = 0, .a = 0 }),
    });
}

const CloseButton = clickable.OwnedKind("VigilTabCloseButton");

fn closeClicked(owner: ?*anyopaque, index: usize) void {
    if (on_tab_close) |cb| cb(owner, index);
}

/// `frame` is in `parent`'s coordinate space (`bar.group`); `index` is the
/// tab's index (never `plus_index`, which uses a plain `IconButton` instead).
fn buildTabItem(parent: objc.Object, frame: appkit.NSRect, index: usize, title: [:0]const u8, is_active: bool, owner: ?*anyopaque) void {
    const item = tabItemClass().msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "initWithFrame:", .{frame});
    appkit.styleLayer(appkit.layerBacked(item), .{
        .background = if (is_active) theme.colors.bg_app else null,
        .border = if (is_active) theme.colors.border_subtle else null,
        .border_width = 1,
        .corner_radius = theme.radius.md,
    });
    item.setInstanceVariable("vigilIndex", .{ .value = @ptrFromInt((index + 1) << 4) });
    item.setInstanceVariable("vigilActive", .{ .value = @ptrFromInt(@as(usize, @intFromBool(is_active)) << 4) });
    item.setInstanceVariable("vigilOwner", .{ .value = @ptrCast(@alignCast(owner)) });

    const slot: f64 = 16;
    const icon_slot = appkit.newView(appkit.rect(8, (tab_row_height - slot) / 2, slot, slot));
    appkit.addSubview(icon_slot, iconGlyph(slot, "terminal", title, "\u{276F}"));
    appkit.addSubview(item, icon_slot);
    item.setInstanceVariable("vigilIcon", .{ .value = icon_slot.value });

    // NSTextField needs headroom taller than the font's own line height to
    // center reliably -- a frame that only just fits the glyphs (16, for a
    // 12pt font) tends to draw a hair high. Matching the icon slot's own
    // 16-tall box (so title and icon share a center line) but giving the
    // *field* more room, offset so its visual center still lands on that
    // same line, fixes it without touching the icon/hint, which don't have
    // this NSTextField-specific bias.
    const label_h: f64 = 20;
    const label = appkit.label(
        appkit.rect(28, (tab_row_height - label_h) / 2, @max(0, frame.size.width - 52), label_h),
        title,
        appkit.font(theme.fonts.body, theme.text_size.sm, false),
        if (is_active) theme.colors.text_primary else theme.colors.text_tertiary,
    );
    appkit.setAlignment(label, .center);
    label.msgSend(void, "setLineBreakMode:", .{@as(u64, 4)}); // NSLineBreakByTruncatingTail
    appkit.addSubview(item, label);

    if (index < 9) {
        var buf: [4:0]u8 = undefined;
        const key = std.fmt.bufPrintZ(&buf, "\u{2318}{d}", .{index + 1}) catch "";
        const hint_h: f64 = 18;
        const hint = appkit.label(
            appkit.rect(frame.size.width - 24, (tab_row_height - hint_h) / 2, 20, hint_h),
            key,
            appkit.font(theme.fonts.body, theme.text_size.xs2, false),
            theme.colors.text_disabled,
        );
        appkit.setAlignment(hint, .center);
        appkit.addSubview(item, hint);
    }

    appkit.addSubview(parent, item);

    CloseButton.on_click = closeClicked;
    const close = iconButton(
        CloseButton,
        appkit.rect(frame.origin.x + 8, frame.origin.y + (tab_row_height - slot) / 2, slot, slot),
        owner,
        index,
        "xmark",
        "Close tab",
        "\u{d7}",
    );
    close.msgSend(void, "setHidden:", .{true});
    appkit.addSubview(parent, close);
    item.setInstanceVariable("vigilClose", .{ .value = close.value });
}

// -- settings gear / shared icon-button helpers --------------------------------

/// Called when the gear button at the trailing edge of the tab bar (or, in
/// vertical-tabs mode, the content header) is clicked. Opening Preferences
/// doesn't depend on which window's gear was clicked, so this ignores the
/// owner it's handed.
pub var on_settings_click: ?*const fn () void = null;

pub const SettingsButton = clickable.OwnedKind("VigilSettingsButton");

fn settingsClicked(_: ?*anyopaque, _: usize) void {
    if (on_settings_click) |cb| cb();
}

/// Draws an icon glyph sized to fit a `size`x`size` button: an SF Symbol
/// when available, else a plain text fallback glyph (pre-macOS 11, or a
/// symbol name that doesn't exist on the running OS version).
pub fn iconGlyph(size: f64, symbol_name: [:0]const u8, accessibility_label: [:0]const u8, fallback_glyph: [:0]const u8) objc.Object {
    const symbol = appkit.class("NSImage").msgSend(
        objc.Object,
        "imageWithSystemSymbolName:accessibilityDescription:",
        .{ appkit.nsString(symbol_name), appkit.nsString(accessibility_label) },
    );
    if (symbol.value != null) {
        const icon = appkit.class("NSImageView").msgSend(objc.Object, "imageViewWithImage:", .{symbol});
        icon.msgSend(void, "retain", .{});
        icon.msgSend(void, "setFrame:", .{appkit.rect(4, 4, size - 8, size - 8)});
        icon.msgSend(void, "setContentTintColor:", .{appkit.nsColor(theme.colors.text_tertiary)});
        return icon;
    }
    const glyph = appkit.label(
        appkit.rect(0, 3, size, 18),
        fallback_glyph,
        appkit.font(theme.fonts.display, theme.text_size.md, false),
        theme.colors.text_tertiary,
    );
    appkit.setAlignment(glyph, .center);
    return glyph;
}

/// A square icon button at `frame`, clickable via `Kind` (any
/// `clickable.OwnedKind(...)` instantiation) carrying `owner` and `tag`.
/// Shared by the tab bar's close/new-tab/settings buttons and the vertical
/// sidebar's own buttons.
pub fn iconButton(comptime Kind: type, frame: appkit.NSRect, owner: ?*anyopaque, tag: usize, symbol_name: [:0]const u8, accessibility_label: [:0]const u8, fallback_glyph: [:0]const u8) objc.Object {
    const button = Kind.view(frame, owner, tag, .{ .corner_radius = theme.radius.sm });
    appkit.addSubview(button, iconGlyph(frame.size.width, symbol_name, accessibility_label, fallback_glyph));
    return button;
}

/// A gear pinned to the tab bar's trailing edge.
fn addSettingsButton(bar: objc.Object, bar_width: f64) void {
    SettingsButton.on_click = settingsClicked;
    const button = iconButton(
        SettingsButton,
        appkit.rect(bar_width - settings_btn_size - trailing_pad, (tab_bar_height - settings_btn_size) / 2, settings_btn_size, settings_btn_size),
        null,
        0,
        "gearshape",
        "Preferences",
        "\u{2699}",
    );
    setAutoresizing(button, NSViewMinXMargin);
    appkit.addSubview(bar, button);
}

// -- tab bar container ---------------------------------------------------------

pub const TabBar = struct {
    /// The bar itself -- the rename field is added here (not to `group`,
    /// which `populateTabs` clears and rebuilds on every call).
    bar: objc.Object,
    /// Plain (unstyled) flex host for the tabs + "New tab" button; rebuilt
    /// wholesale by `populateTabs`.
    group: objc.Object,
    /// The frame (in `group`'s coordinate space) of each tab from the most
    /// recent `populateTabs`, indexed like `titles` was. Used by
    /// `beginRename` to place the rename field over the right tab.
    tab_item_frames: [64]appkit.NSRect = undefined,
    tab_item_count: usize = 0,
    /// Last tab count rendered into this bar -- see the `rename_field.cancel`
    /// guard in `populateTabs`. Per-bar, not file-global: a tab count change
    /// in one window must not disturb another window's bar (or its rename).
    /// Pill geometry depends on the count, not per-tab titles, so only a
    /// count change can strand an in-progress rename field.
    last_tab_count: ?usize = null,
    /// Content width the bar was last populated at -- lets a window resize
    /// repopulate only when the width actually changed (see
    /// `Window.reflowChrome`).
    last_bar_width: ?f64 = null,
};

/// Builds the top tab bar and adds it to `parent`. `width` is the parent's
/// current width; the bar pins to the top edge and stretches with window
/// width via autoresizing. Call `populateTabs` to fill it.
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

    const group = appkit.newView(appkit.rect(
        window_controls_width,
        (tab_bar_height - tab_row_height) / 2,
        width - window_controls_width,
        tab_row_height,
    ));
    appkit.addSubview(bar, group);
    addSettingsButton(bar, width);
    return .{ .bar = bar, .group = group };
}

const NewTabButton = clickable.OwnedKind("VigilNewTabButton");

fn newTabClicked(owner: ?*anyopaque, _: usize) void {
    if (on_tab_click) |cb| cb(owner, plus_index);
}

/// Replaces the tabs in `bar` with one per title, highlighting `active`.
/// `owner` is stashed on every tab/button built so the click callbacks
/// above can tell which window they're for.
pub fn populateTabs(bar: *TabBar, titles: []const [:0]const u8, active: usize, owner: ?*anyopaque) void {
    // A tab added/closed shifts every pill, stranding an in-progress rename
    // field (which lives on `bar.bar`, so it would otherwise survive
    // misplaced). A title-only refresh doesn't move anything -- let the
    // rename keep editing through shell title updates.
    if (bar.last_tab_count != titles.len) {
        rename_field.cancelIfInWindow(bar.bar.msgSend(objc.Object, "window", .{}));
        bar.last_tab_count = titles.len;
    }
    appkit.removeAllSubviews(bar.group);

    const bar_bounds = bar.bar.msgSend(appkit.NSRect, "bounds", .{});
    bar.last_bar_width = bar_bounds.size.width;
    bar.group.msgSend(void, "setFrame:", .{appkit.rect(
        window_controls_width,
        (tab_bar_height - tab_row_height) / 2,
        @max(0, bar_bounds.size.width - window_controls_width),
        tab_row_height,
    )});

    const trailing_reserved = settings_btn_size + trailing_pad + 8;
    const avail = @max(0, bar_bounds.size.width - window_controls_width - new_tab_btn_size - tab_gap - trailing_reserved);
    const count: f64 = @floatFromInt(@max(titles.len, 1));
    const tab_w: f64 = std.math.clamp(avail / count, tab_min_w, tab_max_w);

    var x: f64 = 0;
    for (titles, 0..) |title, i| {
        const frame = appkit.rect(x, 0, tab_w, tab_row_height);
        buildTabItem(bar.group, frame, i, title, i == active, owner);
        if (i < bar.tab_item_frames.len) bar.tab_item_frames[i] = frame;
        x += tab_w + tab_gap;
    }
    bar.tab_item_count = @min(titles.len, bar.tab_item_frames.len);

    NewTabButton.on_click = newTabClicked;
    const new_tab = iconButton(
        NewTabButton,
        appkit.rect(x, (tab_row_height - new_tab_btn_size) / 2, new_tab_btn_size, new_tab_btn_size),
        owner,
        0,
        "plus",
        "New tab",
        "+",
    );
    appkit.addSubview(bar.group, new_tab);
}

// -- inline rename ------------------------------------------------------------
// The actual text-field overlay lives in `rename_field.zig` (`isActive`/
// `cancel` there cover both this and the vertical sidebar); this just
// supplies the tab's frame and forwards the commit callback.

/// Stashed for the duration of one rename so `forwardRenameCommit` (called
/// back by `rename_field.zig`, which knows nothing about windows) can
/// still report the right owner. Safe because only one rename is ever in
/// flight app-wide -- `rename_field.zig` itself is built the same way.
var renaming_owner: ?*anyopaque = null;

/// Overlays an editable text field on tab `index` of `bar`, pre-filled
/// with `current_title` and with all of it selected.
pub fn beginRename(bar: TabBar, index: usize, current_title: [:0]const u8, owner: ?*anyopaque) void {
    if (index >= bar.tab_item_count) return;

    // Stored frames are in `group`'s coordinate space; the field itself is
    // added to `bar` so rebuilding `group`'s tabs can't sweep it away.
    const frame = bar.group.msgSend(appkit.NSRect, "convertRect:toView:", .{ bar.tab_item_frames[index], bar.bar });
    renaming_owner = owner;
    rename_field.begin(
        bar.bar,
        frame,
        current_title,
        appkit.font(theme.fonts.body, theme.text_size.sm, false),
        appkit.nsColor(theme.colors.bg_surface_overlay),
        appkit.nsColor(theme.colors.text_primary),
        index,
        forwardRenameCommit,
    );
}

fn forwardRenameCommit(index: usize, text: []const u8) void {
    if (on_rename_commit) |cb| cb(renaming_owner, index, text);
}
