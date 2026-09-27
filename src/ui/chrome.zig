//! Screen 01 ("Main window") chrome from Vigil.dc.html: a pill-shaped tab
//! bar, a terminal pane + log side-panel split, and a bottom status bar.
//! Plain layer-backed NSViews + NSTextFields positioned by hand (no Auto
//! Layout) -- simple, and matches the prototype's fixed-geometry chrome.
const std = @import("std");
const objc = @import("objc");
const appkit = @import("../app/appkit.zig");
const theme = @import("theme.zig");
const clickable = @import("clickable.zig");

const NSViewMinXMargin: u64 = 1;
const NSViewWidthSizable: u64 = 2;
const NSViewMinYMargin: u64 = 8;

fn setAutoresizing(view: objc.Object, mask: u64) void {
    view.msgSend(void, "setAutoresizingMask:", .{mask});
}

pub const tab_bar_height: f64 = 38;

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

/// Called when a tab pill (never the "+" item) is double-clicked -- starts a
/// rename. See `beginRename`.
pub var on_tab_double_click: ?*const fn (index: usize) void = null;

/// Called when an in-progress rename is committed (Return, or clicking away
/// -- `NSTextField`'s usual "end editing" triggers), with the field's text.
pub var on_rename_commit: ?*const fn (index: usize, text: []const u8) void = null;

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

fn tabItemMouseDown(id: objc.c.id, _: objc.c.SEL, event: objc.c.id) callconv(.c) void {
    const stored = (objc.Object{ .value = id }).getInstanceVariable("vigilIndex");
    const raw = @intFromPtr(stored.value);
    if (raw == 0) return;
    // Stored shifted so the fake "pointer" is aligned (see `tabItem`).
    const index = (raw >> 4) - 1;
    if (on_tab_click) |cb| cb(index);

    const click_count = (objc.Object{ .value = event }).msgSend(i64, "clickCount", .{});
    if (click_count >= 2 and index != plus_index) {
        if (on_tab_double_click) |cb| cb(index);
    }
}

fn tabItem(frame: appkit.NSRect, index: usize, style: appkit.LayerStyle) objc.Object {
    const item = tabItemClass().msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "initWithFrame:", .{frame});
    // `radius.pill` is a "make it a capsule" sentinel, not a real radius; like
    // `appkit.panel`, clamp it to half the height or the layer mask clips
    // the item's contents away.
    var clamped = style;
    clamped.corner_radius = @min(clamped.corner_radius, @min(frame.size.width, frame.size.height) / 2);
    appkit.styleLayer(appkit.layerBacked(item), clamped);
    item.setInstanceVariable("vigilIndex", .{ .value = @ptrFromInt((index + 1) << 4) });
    return item;
}

/// Called when the gear button at the trailing edge of the tab bar is clicked.
pub var on_settings_click: ?*const fn () void = null;

const SettingsButton = clickable.Kind("VigilSettingsButton");

fn settingsClicked(_: usize) void {
    if (on_settings_click) |cb| cb();
}

/// A gear (SF Symbol) pinned to the tab bar's trailing edge.
fn addSettingsButton(bar: objc.Object, bar_width: f64) void {
    const size: f64 = 26;
    SettingsButton.on_click = settingsClicked;
    const button = SettingsButton.view(
        appkit.rect(bar_width - size - 14, (tab_bar_height - size) / 2, size, size),
        0,
        .{ .corner_radius = theme.radius.sm },
    );
    setAutoresizing(button, NSViewMinXMargin);

    const symbol = appkit.class("NSImage").msgSend(
        objc.Object,
        "imageWithSystemSymbolName:accessibilityDescription:",
        .{ appkit.nsString("gearshape"), appkit.nsString("Preferences") },
    );
    if (symbol.value != null) {
        const icon = appkit.class("NSImageView").msgSend(objc.Object, "imageViewWithImage:", .{symbol});
        icon.msgSend(void, "setFrame:", .{appkit.rect(4, 4, size - 8, size - 8)});
        icon.msgSend(void, "setContentTintColor:", .{appkit.nsColor(theme.colors.text_tertiary)});
        appkit.addSubview(button, icon);
    } else {
        // No SF Symbols (pre-macOS 11): fall back to the gear glyph.
        const glyph = appkit.label(
            appkit.rect(0, 3, size, 18),
            "\u{2699}",
            appkit.font(theme.fonts.display, theme.text_size.md, false),
            theme.colors.text_tertiary,
        );
        appkit.setAlignment(glyph, .center);
        appkit.addSubview(button, glyph);
    }
    appkit.addSubview(bar, button);
}

pub const TabBar = struct {
    /// The bar itself -- the rename field is added here (not to `group`,
    /// which `populateTabs` clears and rebuilds on every call).
    bar: objc.Object,
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
    addSettingsButton(bar, width);
    const result = TabBar{ .bar = bar, .group = group };
    current_bar = result;
    return result;
}

const tab_group_height: f64 = 30;

/// One entry in the tab bar; a singleton since there is only ever one
/// window, cached so `beginRename` can locate a pill without `Window`
/// having to hand back its own bar reference on every call.
var current_bar: ?TabBar = null;

/// The frame (in `group`'s coordinate space) of each pill from the most
/// recent `populateTabs`, indexed like `titles` was. Used by `beginRename`
/// to place the rename field over the right pill.
var tab_item_frames: [64]appkit.NSRect = undefined;
var tab_item_count: usize = 0;

/// Replaces the pills in `bar` with one per title, highlighting `active`.
pub fn populateTabs(bar: TabBar, titles: []const [:0]const u8, active: usize) void {
    // The pill layout is about to change under any in-progress rename field
    // (which lives on `bar.bar`, so it would otherwise survive misplaced).
    endRename();
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
    x += 4; // breathing room after the last pill
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

    tab_item_count = @min(titles.len, tab_item_frames.len);
    for (0..tab_item_count) |i| tab_item_frames[i] = appkit.rect(3 + @as(f64, @floatFromInt(i)) * tab_w, 3, tab_w, tab_group_height - 6);
}

// -- inline rename ------------------------------------------------------------

var rename_field: ?objc.Object = null;
var rename_target_obj: ?objc.Object = null;
var rename_target_class: ?objc.Class = null;
/// True only while `endRename` is detaching the field. Removing a view that
/// is still the window's first responder makes AppKit resign it right there,
/// which -- since the field has `sendsActionOnEndEditing` -- re-fires
/// `renameCommit:` synchronously, reentrantly, with a title string the outer
/// call is still holding a (soon to be freed) pointer to. This flag makes
/// that reentrant fire (commit *or* cancel) a no-op instead of a use-after-free.
var handling_end = false;

pub fn isRenaming() bool {
    return rename_field != null;
}

/// Overlays an editable text field on tab `index`'s pill, pre-filled with
/// `current_title` and with all of it selected. Ends any rename already in
/// progress first.
pub fn beginRename(index: usize, current_title: [:0]const u8) void {
    const bar = current_bar orelse return;
    if (index >= tab_item_count) return;
    endRename();

    // Stored frames are in `group`'s coordinate space; the field itself is
    // added to `bar` so rebuilding `group`'s pills can't sweep it away.
    const frame = bar.group.msgSend(appkit.NSRect, "convertRect:toView:", .{ tab_item_frames[index], bar.bar });

    const field = appkit.class("NSTextField").msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "initWithFrame:", .{frame});
    field.msgSend(void, "setBezeled:", .{false});
    field.msgSend(void, "setDrawsBackground:", .{true});
    field.msgSend(void, "setBackgroundColor:", .{appkit.nsColor(theme.colors.bg_surface_overlay)});
    field.msgSend(void, "setFont:", .{appkit.font(theme.fonts.mono, theme.text_size.xs, true)});
    field.msgSend(void, "setTextColor:", .{appkit.nsColor(theme.colors.text_primary)});
    field.msgSend(void, "setStringValue:", .{appkit.nsString(current_title)});
    field.msgSend(objc.Object, "cell", .{}).msgSend(void, "setSendsActionOnEndEditing:", .{true});
    field.msgSend(void, "setTarget:", .{renameTarget()});
    field.msgSend(void, "setAction:", .{objc.sel("renameCommit:").value});
    field.msgSend(void, "setTag:", .{@as(i64, @intCast(index))});
    appkit.addSubview(bar.bar, field);

    const window = bar.bar.msgSend(objc.Object, "window", .{});
    window.msgSend(void, "makeFirstResponder:", .{field});
    window.msgSend(objc.Object, "fieldEditor:forObject:", .{ true, field })
        .msgSend(void, "selectAll:", .{@as(?*anyopaque, null)});

    rename_field = field;
}

/// Discards an in-progress rename without committing it.
pub fn cancelRename() void {
    endRename();
}

fn endRename() void {
    const f = rename_field orelse return;
    rename_field = null; // clear first: see `handling_end` above
    handling_end = true;
    f.msgSend(void, "removeFromSuperview", .{});
    handling_end = false;
}

fn renameTarget() objc.Object {
    if (rename_target_obj) |t| return t;
    const t = renameTargetClass().msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});
    rename_target_obj = t;
    return t;
}

fn renameTargetClass() objc.Class {
    if (rename_target_class) |cls| return cls;
    const cls = objc.allocateClassPair(appkit.class("NSObject"), "VigilTabRenameTarget") orelse
        @panic("failed to register VigilTabRenameTarget");
    std.debug.assert(cls.addMethod("renameCommit:", renameCommit));
    objc.registerClassPair(cls);
    rename_target_class = cls;
    return cls;
}

fn renameCommit(_: objc.c.id, _: objc.c.SEL, sender: objc.c.id) callconv(.c) void {
    if (handling_end) return; // see `handling_end`
    const field = objc.Object{ .value = sender };
    const tag = field.msgSend(i64, "tag", .{});
    if (tag < 0) return;
    const str = field.msgSend(objc.Object, "stringValue", .{});
    const text = std.mem.span(str.msgSend([*:0]const u8, "UTF8String", .{}));
    if (on_rename_commit) |cb| cb(@intCast(tag), text);
}
