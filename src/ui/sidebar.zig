//! Screen 01b ("Main window, vertical tabs") from Vigil.dc.html: tabs move
//! into a full-height sidebar that runs up through the titlebar, and the
//! main content column gets its own thin header (title + split/settings).
//! An alternative to `chrome.zig`'s titlebar tab bar, chosen once at
//! startup by the "Vertical tabs" preference (see `Window.create`) -- not
//! hot-swappable, so this file doesn't need to coexist with `chrome.zig`'s
//! views at runtime, only share its click/rename plumbing conventions so
//! `Window` can treat either one uniformly. The sidebar itself is always
//! visible in this mode (no collapse control).
//!
//! Same `vigilOwner`-ivar convention as `chrome.zig` (see its header
//! comment) so every callback below can be wired once, app-wide, no
//! matter how many windows are open.
const std = @import("std");
const objc = @import("objc");
const appkit = @import("../app/appkit.zig");
const theme = @import("theme.zig");
const clickable = @import("clickable.zig");
const chrome = @import("chrome.zig");
const rename_field = @import("rename_field.zig");

const NSViewMinXMargin: u64 = 1;
const NSViewWidthSizable: u64 = 2;
const NSViewHeightSizable: u64 = 16;
const NSViewMaxYMargin: u64 = 32;

fn setAutoresizing(view: objc.Object, mask: u64) void {
    view.msgSend(void, "setAutoresizingMask:", .{mask});
}

pub const sidebar_width: f64 = 240;
/// The main content column's own thin header strip -- the vertical-tabs
/// counterpart of `chrome.tab_bar_height`.
pub const content_header_height: f64 = chrome.tab_bar_height;
pub const plus_index = chrome.plus_index;

const new_tab_button_h: f64 = 38;
const row_h: f64 = 40;
const row_step: f64 = row_h + 1;
const close_btn_size: f64 = 18;
const row_icon_slot: f64 = 18;

/// Called when a row (or the "New tab" row, with `plus_index`) is clicked.
pub var on_tab_click: ?*const fn (owner: ?*anyopaque, index: usize) void = null;
/// Called when a row (never "New tab") is double-clicked -- starts a rename.
pub var on_tab_double_click: ?*const fn (owner: ?*anyopaque, index: usize) void = null;
pub var on_rename_commit: ?*const fn (owner: ?*anyopaque, index: usize, text: []const u8) void = null;
/// Called when a row's close button is clicked.
pub var on_tab_close: ?*const fn (owner: ?*anyopaque, index: usize) void = null;
/// Called when the content header's split-right button is clicked.
pub var on_split_right_click: ?*const fn (owner: ?*anyopaque) void = null;

pub const Sidebar = struct {
    container: objc.Object,
    list: objc.Object,
    header: objc.Object,
    header_title: objc.Object,
    /// Frames of the most recent `populate`'s rows, in `list`'s coordinate
    /// space -- used by `beginRename` to place the rename field.
    row_frames: [64]appkit.NSRect = undefined,
    row_count: usize = 0,
};

/// Builds the sidebar column and the main content column's header strip,
/// both added to `parent` (the window's content view). Called once; call
/// `layout` on every resize and `populate` whenever the tab list changes.
/// `owner` is stashed on every button built (the split-right one needs it;
/// the others don't strictly, but take it too for one consistent API).
pub fn build(parent: objc.Object, width: f64, height: f64, owner: ?*anyopaque) Sidebar {
    const container = appkit.panel(
        appkit.rect(0, 0, sidebar_width, height),
        .{ .background = theme.colors.bg_surface },
    );
    appkit.addSubview(parent, container);
    appkit.addSubview(container, appkit.panel(
        appkit.rect(sidebar_width - 1, 0, 1, height),
        .{ .background = theme.colors.border_subtle },
    ));

    const list = appkit.newView(appkit.rect(
        6,
        new_tab_button_h,
        sidebar_width - 12,
        height - content_header_height - new_tab_button_h,
    ));
    setAutoresizing(list, NSViewHeightSizable);
    appkit.addSubview(container, list);

    NewTabButton.on_click = newTabClicked;
    const new_tab = NewTabButton.view(appkit.rect(8, 8, sidebar_width - 16, 22), owner, 0, .{ .corner_radius = theme.radius.sm });
    appkit.addSubview(new_tab, chrome.iconGlyph(20, "plus", "New tab", "+"));
    appkit.addSubview(new_tab, appkit.label(
        appkit.rect(24, 3, sidebar_width - 16 - 24, 16),
        "New tab",
        appkit.font(theme.fonts.body, theme.text_size.sm, false),
        theme.colors.text_secondary,
    ));
    setAutoresizing(new_tab, NSViewMaxYMargin);
    appkit.addSubview(container, new_tab);

    const header = appkit.panel(
        appkit.rect(sidebar_width, height - content_header_height, width - sidebar_width, content_header_height),
        .{ .background = theme.colors.bg_surface },
    );
    appkit.addSubview(parent, header);
    appkit.addSubview(header, appkit.panel(
        appkit.rect(0, 0, width - sidebar_width, 1),
        .{ .background = theme.colors.border_subtle },
    ));

    const title = appkit.label(
        appkit.rect(14, (content_header_height - 18) / 2, 300, 18),
        "",
        appkit.font(theme.fonts.body, theme.text_size.sm, false),
        theme.colors.text_secondary,
    );
    setAutoresizing(title, NSViewWidthSizable);
    appkit.addSubview(header, title);

    var trailing_x = width - sidebar_width - 14 - 22;
    SettingsHeaderButton.on_click = settingsClicked;
    const settings = chrome.iconButton(
        SettingsHeaderButton,
        appkit.rect(trailing_x, (content_header_height - 22) / 2, 22, 22),
        owner,
        0,
        "gearshape",
        "Preferences",
        "\u{2699}",
    );
    setAutoresizing(settings, NSViewMinXMargin);
    appkit.addSubview(header, settings);

    trailing_x -= 26;
    SplitButton.on_click = splitClicked;
    const split = chrome.iconButton(
        SplitButton,
        appkit.rect(trailing_x, (content_header_height - 22) / 2, 22, 22),
        owner,
        0,
        "square.split.2x1",
        "Split right",
        "\u{2016}",
    );
    setAutoresizing(split, NSViewMinXMargin);
    appkit.addSubview(header, split);

    return .{ .container = container, .list = list, .header = header, .header_title = title };
}

/// Repositions the header against `bounds` (the content view's current
/// bounds) and returns the rect left over for the terminal area. The
/// sidebar itself is a fixed-width column, so only its height tracks
/// `bounds` (via its own autoresizing-free rebuild in `Window.relayoutAll`
/// -- it's not resized here since `sidebar_width` never changes).
pub fn layout(self: *Sidebar, bounds: appkit.NSRect) appkit.NSRect {
    self.container.msgSend(void, "setFrame:", .{appkit.rect(0, 0, sidebar_width, bounds.size.height)});
    self.header.msgSend(void, "setFrame:", .{appkit.rect(sidebar_width, bounds.size.height - content_header_height, bounds.size.width - sidebar_width, content_header_height)});
    return appkit.rect(sidebar_width, 0, bounds.size.width - sidebar_width, bounds.size.height - content_header_height);
}

/// Replaces the rows with one per title, highlighting `active`, and updates
/// the content header's title to match. `owner` is stashed on every row/
/// close button built.
pub fn populate(self: *Sidebar, titles: []const [:0]const u8, active: usize, owner: ?*anyopaque) void {
    rename_field.cancel(); // the row layout is about to change under it
    appkit.removeAllSubviews(self.list);

    const bounds = self.list.msgSend(appkit.NSRect, "bounds", .{});
    const hint_font = appkit.font(theme.fonts.body, theme.text_size.xs2, false);
    const label_font = appkit.font(theme.fonts.body, theme.text_size.sm, false);
    // Reserve the trailing edge for the hint + close button so the title
    // never runs under them.
    const trailing_reserved: f64 = 22 + 4 + close_btn_size + 6;
    const icon_x: f64 = 8;
    const label_x: f64 = icon_x + row_icon_slot + 8;

    var y = bounds.size.height - row_h;
    for (titles, 0..) |title, i| {
        if (y + row_h < 0) break; // no scrolling yet -- stop once we'd draw off the bottom
        const is_active = i == active;
        const frame = appkit.rect(0, y, bounds.size.width, row_h);
        // Screen 01b's active row uses `--surface-selected` (a translucent
        // iris tint), not a solid fill -- distinct from the horizontal tab
        // bar's solid `--surface-tab-active`, which is the right call: it's
        // a *selection* highlight in a list, not a "this is the frontmost
        // pane" indicator.
        const row = rowView(frame, i, .{
            .background = if (is_active) theme.colors.selected else null,
            .border = if (is_active) theme.colors.border_subtle else null,
            .corner_radius = theme.radius.md,
        }, is_active, owner);

        const icon_slot = appkit.newView(appkit.rect(icon_x, (row_h - row_icon_slot) / 2, row_icon_slot, row_icon_slot));
        appkit.addSubview(icon_slot, chrome.iconGlyph(row_icon_slot, "terminal", title, "\u{276F}"));
        appkit.addSubview(row, icon_slot);

        const label_h: f64 = 20;
        const label = appkit.label(
            appkit.rect(label_x, (row_h - label_h) / 2, @max(0, bounds.size.width - label_x - trailing_reserved), label_h),
            title,
            label_font,
            if (is_active) theme.colors.text_primary else theme.colors.text_secondary,
        );
        label.msgSend(void, "setLineBreakMode:", .{@as(u64, 4)}); // NSLineBreakByTruncatingTail
        appkit.addSubview(row, label);

        if (i < 9) {
            var buf: [4:0]u8 = undefined;
            const key = std.fmt.bufPrintZ(&buf, "\u{2318}{d}", .{i + 1}) catch "";
            const hint_h: f64 = 18;
            const hint = appkit.label(
                appkit.rect(bounds.size.width - trailing_reserved, (row_h - hint_h) / 2, 22, hint_h),
                key,
                hint_font,
                theme.colors.text_disabled,
            );
            appkit.setAlignment(hint, .right);
            appkit.addSubview(row, hint);
        }

        appkit.addSubview(self.list, row);

        // The close button is a sibling of the row (not a child) so its
        // clicks aren't swallowed by the row's own "claim any hit inside"
        // `hitTest:` override -- same reasoning as chrome.zig's tab close
        // button.
        CloseButton.on_click = closeClicked;
        const close = chrome.iconButton(
            CloseButton,
            appkit.rect(bounds.size.width - close_btn_size - 4, y + (row_h - close_btn_size) / 2, close_btn_size, close_btn_size),
            owner,
            i,
            "trash",
            "Close tab",
            "\u{d7}",
        );
        appkit.addSubview(self.list, close);

        if (i < self.row_frames.len) self.row_frames[i] = frame;
        y -= row_step;
    }
    self.row_count = @min(titles.len, self.row_frames.len);

    var buf: [64:0]u8 = undefined;
    const title_text = if (active < titles.len) titles[active] else "";
    const shown = std.fmt.bufPrintZ(&buf, "{s}", .{title_text}) catch "";
    self.header_title.msgSend(void, "setStringValue:", .{appkit.nsString(shown)});
}

/// Stashed for the duration of one rename -- see chrome.zig's
/// `renaming_owner` doc comment for why this is safe.
var renaming_owner: ?*anyopaque = null;

/// Overlays an editable field on row `index`, pre-filled with
/// `current_title` and fully selected.
pub fn beginRename(self: *Sidebar, index: usize, current_title: [:0]const u8, owner: ?*anyopaque) void {
    if (index >= self.row_count) return;
    // Stored frames are in `list`'s coordinate space; the field itself is
    // added to `container` (never cleared by `populate`) so it survives.
    const frame = self.list.msgSend(appkit.NSRect, "convertRect:toView:", .{ self.row_frames[index], self.container });
    renaming_owner = owner;
    rename_field.begin(
        self.container,
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

// -- click plumbing -----------------------------------------------------------

const NewTabButton = clickable.OwnedKind("VigilSidebarNewTab");
const SettingsHeaderButton = clickable.OwnedKind("VigilSidebarSettings");
const SplitButton = clickable.OwnedKind("VigilSidebarSplit");
const CloseButton = clickable.OwnedKind("VigilSidebarClose");

fn newTabClicked(owner: ?*anyopaque, _: usize) void {
    if (on_tab_click) |cb| cb(owner, plus_index);
}

fn settingsClicked(_: ?*anyopaque, _: usize) void {
    if (chrome.on_settings_click) |cb| cb();
}

fn splitClicked(owner: ?*anyopaque, _: usize) void {
    if (on_split_right_click) |cb| cb(owner);
}

fn closeClicked(owner: ?*anyopaque, index: usize) void {
    if (on_tab_close) |cb| cb(owner, index);
}

var row_class: ?objc.Class = null;

fn rowClass() objc.Class {
    if (row_class) |cls| return cls;
    const cls = objc.allocateClassPair(appkit.class("NSView"), "VigilSidebarRowView") orelse
        @panic("failed to register VigilSidebarRowView");
    _ = cls.addIvar("vigilIndex");
    _ = cls.addIvar("vigilActive");
    _ = cls.addIvar("vigilOwner");
    std.debug.assert(cls.addMethod("mouseDown:", rowMouseDown));
    std.debug.assert(cls.addMethod("mouseDownCanMoveWindow", notMovable));
    std.debug.assert(cls.addMethod("hitTest:", rowHitTest));
    std.debug.assert(cls.addMethod("mouseEntered:", rowMouseEntered));
    std.debug.assert(cls.addMethod("mouseExited:", rowMouseExited));
    std.debug.assert(cls.addMethod("updateTrackingAreas", rowUpdateTrackingAreas));
    objc.registerClassPair(cls);
    row_class = cls;
    return cls;
}

fn notMovable(_: objc.c.id, _: objc.c.SEL) callconv(.c) bool {
    return false;
}

fn rowHitTest(id: objc.c.id, sel: objc.c.SEL, point: appkit.NSPoint) callconv(.c) objc.c.id {
    const obj = objc.Object{ .value = id };
    const hit = obj.msgSendSuper(appkit.class("NSView"), objc.Object, objc.Sel{ .value = sel }, .{point});
    return if (hit.value != null) id else null;
}

fn rowMouseDown(id: objc.c.id, _: objc.c.SEL, event: objc.c.id) callconv(.c) void {
    const obj = objc.Object{ .value = id };
    const raw = @intFromPtr(obj.getInstanceVariable("vigilIndex").value);
    if (raw == 0) return;
    const index = (raw >> 4) - 1;
    const owner = obj.getInstanceVariable("vigilOwner").value;
    if (on_tab_click) |cb| cb(owner, index);

    const click_count = (objc.Object{ .value = event }).msgSend(i64, "clickCount", .{});
    if (click_count >= 2) {
        if (on_tab_double_click) |cb| cb(owner, index);
    }
}

const tracking_mouse_entered_exited: u64 = 0x01;
const tracking_active_in_key_window: u64 = 0x20;
const tracking_in_visible_rect: u64 = 0x200;

fn rowUpdateTrackingAreas(id: objc.c.id, sel: objc.c.SEL) callconv(.c) void {
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

fn rowMouseEntered(id: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) void {
    setRowHovered(id, true);
}

fn rowMouseExited(id: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) void {
    setRowHovered(id, false);
}

/// The active row's background never changes on hover, matching the
/// horizontal tab bar's `Tab` component (and the prototype's own
/// `style-hover` on the sidebar row, which only tints non-selected rows).
fn setRowHovered(id: objc.c.id, hovered: bool) void {
    const obj = objc.Object{ .value = id };
    if (@intFromPtr(obj.getInstanceVariable("vigilActive").value) != 0) return;
    const layer = obj.msgSend(objc.Object, "layer", .{});
    layer.msgSend(void, "setBackgroundColor:", .{
        if (hovered) appkit.cgColor(theme.colors.hover) else appkit.cgColor(.{ .r = 0, .g = 0, .b = 0, .a = 0 }),
    });
}

fn rowView(frame: appkit.NSRect, index: usize, style: appkit.LayerStyle, is_active: bool, owner: ?*anyopaque) objc.Object {
    const view = rowClass().msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "initWithFrame:", .{frame});
    appkit.styleLayer(appkit.layerBacked(view), style);
    view.setInstanceVariable("vigilIndex", .{ .value = @ptrFromInt((index + 1) << 4) });
    view.setInstanceVariable("vigilActive", .{ .value = @ptrFromInt(@as(usize, @intFromBool(is_active)) << 4) });
    view.setInstanceVariable("vigilOwner", .{ .value = @ptrCast(@alignCast(owner)) });
    return view;
}
