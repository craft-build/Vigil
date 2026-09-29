//! A window's model: an ordered list of tabs, each holding a tree of
//! terminal surfaces (splits) laid out and drawn by this file. libghostty
//! drives tab and split operations through `action_cb`; those land in
//! `handleAction`, which mutates this model and re-lays-out/re-renders.
//!
//! libghostty's embedded C API has no layout engine of its own --
//! `ghostty_surface_split` just performs the `new_split` binding action,
//! which arrives back here as `GHOSTTY_ACTION_NEW_SPLIT`. Actually arranging
//! panes (and their dividers) is entirely on us, same as the Swift app's own
//! `Ghostty.SplitTree`. See `pane.zig` for the tree/geometry this file
//! applies to real views.
//!
//! Every leaf view has its autoresizing mask cleared (`setAutoresizingMask:
//! 0`); nothing here relies on AppKit's automatic resizing, since it can't
//! express ratio-based splits. Instead, the window's content view is a
//! custom class whose `setFrameSize:` triggers `relayoutAll`, and every
//! split/close/equalize/zoom operation calls it directly.
//!
//! More than one `Window` can exist at once (File > New Window / ⌘N).
//! libghostty's own callbacks (`action_cb`, `close_surface_cb`) carry no
//! per-window context, only a surface pointer, so every view that can
//! originate a click/drag/key event and needs to know "which window" --
//! tab items, split dividers, the content view itself -- carries a
//! `vigilOwner` ivar (an opaque pointer to its `*Window`, stashed when
//! built) instead of reaching for a single global instance. That's also
//! why the UI callbacks this file hands to `chrome.zig`/`sidebar.zig`
//! (`on_tab_click` and friends) are wired exactly once, in
//! `installGlobalHandlers`, rather than per-window: their signatures all
//! take the owner back as a parameter, so one wiring covers every window.
const std = @import("std");
const objc = @import("objc");
const ghc = @import("../ghostty/c.zig").c;
const appkit = @import("appkit.zig");
const TerminalSurface = @import("TerminalSurface.zig").TerminalSurface;
const pane = @import("pane.zig");
const chrome = @import("../ui/chrome.zig");
const sidebar = @import("../ui/sidebar.zig");
const rename_field = @import("../ui/rename_field.zig");
const theme = @import("../ui/theme.zig");
const shortcuts_sheet = @import("../ui/shortcuts_sheet.zig");
const palette = @import("../ui/palette.zig");
const theme_gallery = @import("../ui/theme_gallery.zig");
const preferences_window = @import("../ui/preferences_window.zig");
const prefs = @import("preferences.zig");
const settings = @import("settings.zig");
const themes = @import("themes.zig");
const keybindings = @import("keybindings.zig");
const keymonitor = @import("keymonitor.zig");
const gcd = @import("../gcd.zig");

const PaneTree = pane.Tree(*TerminalSurface);
const Pane = PaneTree.Pane;
const Split = PaneTree.Split;

fn surfaceEq(a: *TerminalSurface, b: *TerminalSurface) bool {
    return a == b;
}

fn containsLeaf(p: Pane, target: *TerminalSurface) bool {
    return switch (p) {
        .leaf => |l| l == target,
        .split => |s| containsLeaf(s.first, target) or containsLeaf(s.second, target),
    };
}

const DividerView = struct {
    view: objc.Object,
    split: *Split,
};

const Tab = struct {
    tree: PaneTree,
    /// The pane keyboard input and new splits target within this tab.
    focused: *TerminalSurface,
    /// One entry per `Split` currently in `tree`; rebuilt wholesale on any
    /// change to the tree's *shape* (split/close), reused across plain
    /// resizes and divider drags.
    dividers: std.ArrayList(DividerView) = .empty,
    /// Set by `toggle_split_zoom`: only this pane is shown/laid out until
    /// zoomed back out.
    zoomed: ?*TerminalSurface = null,
    /// Owned, NUL-terminated.
    title: [:0]u8,
    /// Set once the user renames the tab by hand; from then on, libghostty's
    /// own `set_title`/`set_tab_title` actions (from the shell reporting its
    /// prompt or cwd) no longer overwrite it.
    manual_title: bool = false,
};

const VisibilityCtx = struct { tab: *Tab, visible: bool };

/// The two mutually-exclusive tab-bar chrome layouts, chosen once (see
/// `Window.create`) by the "Vertical tabs" preference and never
/// hot-swapped -- switching it takes effect on the next launch.
const ChromeUI = union(enum) {
    horizontal: chrome.TabBar,
    vertical: sidebar.Sidebar,
};

pub const Window = struct {
    allocator: std.mem.Allocator,
    app: ghc.ghostty_app_t,
    window: objc.Object,
    content: objc.Object,
    chrome_ui: ChromeUI,
    tabs: std.ArrayList(Tab) = .empty,
    active: usize = 0,

    /// Every open window, in creation order. `keyWindow`/`forNSWindow`
    /// resolve "which window is this event/click for" against this list;
    /// `windowWillClose` removes a window when it closes.
    pub var all: std.ArrayList(*Window) = .empty;
    /// The most recent main window to hold key focus. `keyWindow()` refreshes
    /// it; `mainWindow()` falls back to it when a non-main window (e.g.
    /// Preferences) is key. Validated against `all` before use, so a closed
    /// window is never returned.
    var last_key: ?*Window = null;
    /// The one `ghostty_app_t`, shared by every window (set on the first
    /// `create`). App-wide operations (`settings.apply`, theme changes)
    /// key off this instead of any particular window's `.app`.
    pub var shared_app: ghc.ghostty_app_t = null;

    const window_w: f64 = 1120;
    const window_h: f64 = 700;

    pub fn create(allocator: std.mem.Allocator, app: ghc.ghostty_app_t) !*Window {
        const self = try allocator.create(Window);
        errdefer allocator.destroy(self);

        // Keep native window controls and resizing, but let our content
        // occupy the titlebar so the tab bar is the visible window chrome.
        const style_mask: u64 = 1 | 2 | 4 | 8 | (1 << 15); // Titled | Closable | Miniaturizable | Resizable | FullSizeContentView
        const window = appkit.class("NSWindow")
            .msgSend(objc.Object, "alloc", .{})
            .msgSend(objc.Object, "initWithContentRect:styleMask:backing:defer:", .{
            appkit.rect(0, 0, window_w, window_h),
            style_mask,
            @as(u64, 2), // NSBackingStoreBuffered
            false,
        });
        // On the failed-create path, drop the whole window (and its view
        // tree) without firing `windowWillClose` -- `close` would tear
        // down against half-initialized `self`.
        errdefer window.msgSend(void, "release", .{});
        window.msgSend(void, "setTitle:", .{appkit.nsString("Vigil")});
        window.msgSend(void, "setTitleVisibility:", .{@as(i64, 1)}); // NSWindowTitleHidden
        window.msgSend(void, "setTitlebarAppearsTransparent:", .{true});
        window.msgSend(void, "setBackgroundColor:", .{appkit.nsColor(theme.colors.bg_app)});
        window.msgSend(void, "center", .{});
        // `center` alone puts every window at the exact same point, so a
        // second (or third, ...) window would land perfectly on top of an
        // existing one -- nudge each successive window down and to the
        // right a bit, wrapping after a few so it doesn't walk off-screen.
        if (all.items.len > 0) {
            var frame = window.msgSend(appkit.NSRect, "frame", .{});
            const step: f64 = @floatFromInt(28 * (all.items.len % 8));
            frame.origin.x += step;
            frame.origin.y -= step;
            window.msgSend(void, "setFrameOrigin:", .{frame.origin});
        }

        // Runs the real teardown when this window closes (native red
        // button, or `close`/`performClose:` called programmatically --
        // see `windowWillClose`). Leaked deliberately, like the other
        // small per-window AppKit objects this file never releases: one
        // delegate for the process lifetime of its window is negligible.
        const delegate = delegateClass().msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});
        delegate.setInstanceVariable("vigilOwner", .{ .value = @ptrCast(self) });
        window.msgSend(void, "setDelegate:", .{delegate});

        // A plain NSView can't express "tell Zig when I resize"; a custom
        // subclass can. Panes are laid out manually (ratio splits aren't
        // expressible via autoresizing masks), so every content resize has
        // to re-run that layout -- see `contentSetFrameSize`.
        const content = contentViewClass().msgSend(objc.Object, "alloc", .{})
            .msgSend(objc.Object, "initWithFrame:", .{appkit.rect(0, 0, window_w, window_h)});
        // `setContentView:` below synchronously triggers our `setFrameSize:`
        // override, before `self`'s fields are populated -- leave the
        // `vigilOwner` ivar at its zero-initialized nil (Objective-C zeroes
        // every ivar on `alloc`) until after `self.* = .{...}` so
        // `contentSetFrameSize` safely no-ops during construction instead
        // of calling `relayoutAll` against not-yet-initialized fields.
        window.msgSend(void, "setContentView:", .{content});
        // The window retains its content view; our alloc-time +1 goes to
        // the pool (same reasoning as `appkit.addSubview`).
        content.msgSend(void, "autorelease", .{});

        // Vigil-only preference (not a libghostty key, so it lives in
        // `settings.ui_store`); read once here -- changing it takes effect
        // on the next launch, not live.
        const vertical_tabs = if (settings.ui_store.get("vigil-vertical-tabs")) |v| std.mem.eql(u8, v, "true") else false;
        const chrome_ui: ChromeUI = if (vertical_tabs)
            .{ .vertical = sidebar.build(content, window_w, window_h, @ptrCast(self)) }
        else
            .{ .horizontal = chrome.buildTabBar(content, window_w, window_h) };

        self.* = .{
            .allocator = allocator,
            .app = app,
            .window = window,
            .content = content,
            .chrome_ui = chrome_ui,
        };
        content.setInstanceVariable("vigilOwner", .{ .value = @ptrCast(self) });
        shared_app = app;

        // Register in `all` only once construction can no longer fail, so
        // the `forNSWindow`/`keyWindow`/`isLive` scans never see a pointer
        // the `errdefer` above is about to free.
        try self.newTab(null);
        try all.append(std.heap.c_allocator, self);
        return self;
    }

    /// Wires every callback `chrome.zig`/`sidebar.zig`/`TerminalSurface`/
    /// `palette.zig`/`theme_gallery.zig`/`preferences_window.zig` expose,
    /// exactly once for the process's lifetime -- call before the first
    /// `create`. Safe to call regardless of how many windows end up
    /// existing, since every handler below resolves its own window from
    /// an owner ivar or `keyWindow()` rather than closing over one.
    pub fn installGlobalHandlers() void {
        keymonitor.install(onKeyEvent);
        chrome.on_settings_click = preferences_window.show;
        chrome.on_tab_click = dispatchTabClick;
        chrome.on_tab_double_click = dispatchTabDoubleClick;
        chrome.on_rename_commit = dispatchRenameCommit;
        chrome.on_tab_close = dispatchTabClose;
        sidebar.on_tab_click = dispatchTabClick;
        sidebar.on_tab_double_click = dispatchTabDoubleClick;
        sidebar.on_rename_commit = dispatchRenameCommit;
        sidebar.on_tab_close = dispatchTabClose;
        sidebar.on_split_right_click = dispatchSidebarSplitRight;
        TerminalSurface.on_click = dispatchSurfaceClick;
        palette.on_run = runCommand;
        theme_gallery.on_select = applyTheme;
        preferences_window.on_change = onPreferencesChanged;
        preferences_window.on_button = onPreferencesButton;
    }

    /// The window `NSApp.keyWindow` currently belongs to, or `null` if
    /// none of ours is key (e.g. only Preferences is focused, or no
    /// window is open at all). App-level UI actions resolve their window
    /// through `mainWindow` instead, which falls back when this is null.
    pub fn keyWindow() ?*Window {
        const key = appkit.class("NSApplication").msgSend(objc.Object, "sharedApplication", .{})
            .msgSend(objc.Object, "keyWindow", .{});
        if (key.value == null) return null;
        for (all.items) |w| {
            if (w.window.value == key.value) {
                last_key = w;
                return w;
            }
        }
        return null;
    }

    /// The main window app-level UI actions should act on: the key main
    /// window when one is key, otherwise the most recently keyed (or, before
    /// any has been keyed, the first) main window. Unlike `keyWindow()`, this
    /// is non-null while a non-main window holds focus -- notably
    /// Preferences, whose own "Choose theme…"/"Show shortcuts" buttons, and
    /// View-menu commands invoked while it is focused, still need a main
    /// window to host their overlay.
    pub fn mainWindow() ?*Window {
        if (keyWindow()) |w| return w;
        if (last_key) |w| {
            for (all.items) |open| {
                if (open == w) return w;
            }
        }
        return if (all.items.len > 0) all.items[0] else null;
    }

    /// The `*Window` that owns NSWindow `win`, if any (`win` may belong to
    /// some other panel entirely, e.g. Preferences).
    pub fn forNSWindow(win: objc.Object) ?*Window {
        for (all.items) |w| {
            if (w.window.value == win.value) return w;
        }
        return null;
    }

    pub fn show(self: *Window) void {
        self.window.msgSend(void, "makeKeyAndOrderFront:", .{@as(?*anyopaque, null)});
        if (settings.current) |cfg| self.syncAppearance(cfg);
    }

    // -- window close ---------------------------------------------------------

    var delegate_class: ?objc.Class = null;

    fn delegateClass() objc.Class {
        if (delegate_class) |cls| return cls;
        const cls = objc.allocateClassPair(appkit.class("NSObject"), "VigilWindowDelegate") orelse
            @panic("failed to register VigilWindowDelegate");
        _ = cls.addIvar("vigilOwner");
        std.debug.assert(cls.addMethod("windowWillClose:", windowWillClose));
        objc.registerClassPair(cls);
        delegate_class = cls;
        return cls;
    }

    /// The one real teardown path for a window: reached from the native
    /// red button and from `close`/`performClose:` called programmatically
    /// (`closeWholeTab`'s "last tab" branch, `GHOSTTY_ACTION_CLOSE_WINDOW`)
    /// -- both just ask AppKit to close the window and let this run,
    /// rather than tearing down twice. Frees every remaining tab's
    /// surfaces (deferred, like `closeWholeTab` does, since libghostty may
    /// still be unwinding a call that originated from one of them), drops
    /// `self` from `all`, and frees `self`. Does *not* terminate the app,
    /// even if this was the last window -- that's `GHOSTTY_ACTION_QUIT`
    /// alone now, matching normal macOS app behavior.
    /// True while `p` still points at an open window. Late callbacks
    /// (rename commits, queued click handlers) can fire after
    /// `windowWillClose` freed their owner; every owner-ivar trampoline
    /// below guards on this before casting.
    pub fn isLive(p: ?*anyopaque) bool {
        const w: *Window = @ptrCast(@alignCast(p orelse return false));
        for (all.items) |open| {
            if (open == w) return true;
        }
        return false;
    }

    fn windowWillClose(id: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) void {
        const owner = (objc.Object{ .value = id }).getInstanceVariable("vigilOwner").value orelse return;
        const self: *Window = @ptrCast(@alignCast(owner));

        // Kill anything that outlives this window and would otherwise
        // fire against a freed `*Window`: an in-flight rename, and any
        // modal hosted by this window (only this window's -- an overlay or
        // rename in another window must stay up).
        rename_field.cancelIfInWindow(self.window);
        palette.hideIfHostedBy(self.content);
        shortcuts_sheet.hideIfHostedBy(self.content);
        theme_gallery.hideIfHostedBy(self.content);

        for (all.items, 0..) |w, i| {
            if (w == self) {
                _ = all.orderedRemove(i);
                break;
            }
        }

        while (self.tabs.items.len > 0) {
            var tab = self.tabs.orderedRemove(self.tabs.items.len - 1);
            self.allocator.free(tab.title);
            for (tab.dividers.items) |d| d.view.msgSend(void, "removeFromSuperview", .{});
            tab.dividers.deinit(self.allocator);
            tab.tree.walk(self, detachLeaf);
            tab.tree.deinit();
        }
        self.tabs.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    // -- content view / layout ---------------------------------------------

    var content_view_class: ?objc.Class = null;

    fn contentViewClass() objc.Class {
        if (content_view_class) |cls| return cls;
        const cls = objc.allocateClassPair(appkit.class("NSView"), "VigilContentView") orelse
            @panic("failed to register VigilContentView");
        _ = cls.addIvar("vigilOwner");
        std.debug.assert(cls.addMethod("setFrameSize:", contentSetFrameSize));
        objc.registerClassPair(cls);
        content_view_class = cls;
        return cls;
    }

    fn contentSetFrameSize(id: objc.c.id, sel: objc.c.SEL, size: appkit.NSSize) callconv(.c) void {
        const obj = objc.Object{ .value = id };
        obj.msgSendSuper(appkit.class("NSView"), void, objc.Sel{ .value = sel }, .{size});
        const owner = obj.getInstanceVariable("vigilOwner").value orelse return;
        const self: *Window = @ptrCast(@alignCast(owner));
        self.relayoutAll();
        self.reflowChrome();
    }

    /// The horizontal tab bar is laid out by hand (no Auto Layout), so a
    /// content resize doesn't move its pills or "+" button -- its `group` and
    /// each pill keep the width computed at the last `populateTabs`, and the
    /// `tab_item_frames` a later rename reads go stale. Repopulate it at the
    /// new width, but only when the width actually changed (a live resize
    /// fires this on every step). The vertical sidebar is a fixed-width
    /// column, so its rows need no reflow. The rename field lives on the bar
    /// itself (not `group`), so this never sweeps an in-progress rename away
    /// -- and the per-bar count guard keeps it from being cancelled either.
    fn reflowChrome(self: *Window) void {
        if (self.chrome_ui == .vertical) return;
        const width = self.content.msgSend(appkit.NSRect, "bounds", .{}).size.width;
        if (self.chrome_ui.horizontal.last_bar_width == width) return;
        self.refreshTabBar();
    }

    /// Re-lays-out every tab's pane tree against the current content size.
    /// Cheap enough (small trees, small tab counts) to run unconditionally
    /// rather than tracking which tabs are dirty -- notably including
    /// hidden tabs, so switching to one after a resize shows it correctly
    /// sized immediately instead of on its next own resize.
    pub fn relayoutAll(self: *Window) void {
        const bounds = self.content.msgSend(appkit.NSRect, "bounds", .{});
        const area = if (self.chrome_ui == .vertical)
            sidebar.layout(&self.chrome_ui.vertical, bounds)
        else
            appkit.rect(0, 0, bounds.size.width, bounds.size.height - chrome.tab_bar_height);
        for (self.tabs.items) |*tab| self.layoutTab(tab, area);
    }

    fn layoutTab(self: *Window, tab: *Tab, area: appkit.NSRect) void {
        if (tab.zoomed) |z| {
            self.setLeafFrame(z, area);
        } else {
            self.layoutPane(tab, tab.tree.root, area);
        }
    }

    fn layoutPane(self: *Window, tab: *Tab, p: Pane, rect: appkit.NSRect) void {
        switch (p) {
            .leaf => |ts| self.setLeafFrame(ts, rect),
            .split => |s| {
                s.last_rect = rect;
                const parts = pane.splitRect(rect, s.direction, s.ratio);
                self.layoutPane(tab, s.first, parts.first);
                self.layoutPane(tab, s.second, parts.second);
                if (self.dividerFor(tab, s)) |view| {
                    view.msgSend(void, "setFrame:", .{pane.dividerRect(rect, s.direction, s.ratio)});
                }
            },
        }
    }

    /// `setFrame:` does not call our `setFrameSize:` override (Apple's docs
    /// are explicit about this), which is how libghostty learns a surface
    /// resized -- so origin and size are set as two separate calls.
    fn setLeafFrame(self: *Window, ts: *TerminalSurface, rect: appkit.NSRect) void {
        _ = self;
        ts.view.msgSend(void, "setFrameOrigin:", .{rect.origin});
        ts.view.msgSend(void, "setFrameSize:", .{rect.size});
        ts.last_frame = rect;
    }

    fn dividerFor(self: *Window, tab: *Tab, s: *Split) ?objc.Object {
        _ = self;
        for (tab.dividers.items) |d| {
            if (d.split == s) return d.view;
        }
        return null;
    }

    // -- dividers -------------------------------------------------------------

    var divider_class: ?objc.Class = null;

    fn dividerClass() objc.Class {
        if (divider_class) |cls| return cls;
        const cls = objc.allocateClassPair(appkit.class("NSView"), "VigilSplitDivider") orelse
            @panic("failed to register VigilSplitDivider");
        _ = cls.addIvar("vigilSplit");
        _ = cls.addIvar("vigilOwner");
        std.debug.assert(cls.addMethod("mouseDragged:", dividerMouseDragged));
        objc.registerClassPair(cls);
        divider_class = cls;
        return cls;
    }

    fn splitOf(id: objc.c.id) *Split {
        const stored = (objc.Object{ .value = id }).getInstanceVariable("vigilSplit");
        return @ptrCast(@alignCast(stored.value));
    }

    fn dividerMouseDragged(id: objc.c.id, _: objc.c.SEL, event: objc.c.id) callconv(.c) void {
        const obj = objc.Object{ .value = id };
        const owner = obj.getInstanceVariable("vigilOwner").value orelse return;
        const self: *Window = @ptrCast(@alignCast(owner));
        const s = splitOf(id);
        const window_pt = (objc.Object{ .value = event }).msgSend(appkit.NSPoint, "locationInWindow", .{});
        const pt = self.content.msgSend(appkit.NSPoint, "convertPoint:fromView:", .{ window_pt, @as(?*anyopaque, null) });
        s.setRatio(pane.ratioForPoint(s.last_rect, s.direction, pt));
        self.relayoutAll();
    }

    fn makeDivider(self: *Window, s: *Split) objc.Object {
        const view = dividerClass().msgSend(objc.Object, "alloc", .{})
            .msgSend(objc.Object, "initWithFrame:", .{appkit.rect(0, 0, 0, 0)});
        view.setInstanceVariable("vigilSplit", .{ .value = @ptrCast(s) });
        view.setInstanceVariable("vigilOwner", .{ .value = @ptrCast(self) });
        appkit.styleLayer(appkit.layerBacked(view), .{ .background = theme.colors.border_default });
        self.content.msgSend(void, "addSubview:positioned:relativeTo:", .{
            view,
            @as(i64, -1), // NSWindowBelow
            @as(?*anyopaque, null),
        });
        // Hand the alloc-time +1 to the superview (via the pool, like
        // `appkit.addSubview` -- `rebuildDividers` can run mid-drag, so a
        // straight `release` could dealloc the view mid-event).
        view.msgSend(void, "autorelease", .{});
        return view;
    }

    /// Discards and recreates every divider view for `tab`. Simple and
    /// correct: called only when the tree's *shape* changes (split/close),
    /// which is rare next to plain resizes and drags that reuse these.
    fn rebuildDividers(self: *Window, tab: *Tab) void {
        for (tab.dividers.items) |d| d.view.msgSend(void, "removeFromSuperview", .{});
        tab.dividers.clearRetainingCapacity();
        self.collectDividers(tab, tab.tree.root) catch {};
    }

    fn collectDividers(self: *Window, tab: *Tab, p: Pane) !void {
        switch (p) {
            .leaf => {},
            .split => |s| {
                const view = self.makeDivider(s);
                try tab.dividers.append(self.allocator, .{ .view = view, .split = s });
                try self.collectDividers(tab, s.first);
                try self.collectDividers(tab, s.second);
            },
        }
    }

    // -- tab operations ---------------------------------------------------

    /// Opens a tab after the active one, inheriting settings (and working
    /// directory) from `inherit` when given.
    pub fn newTab(self: *Window, inherit: ?ghc.ghostty_surface_t) !void {
        const bounds = self.content.msgSend(appkit.NSRect, "bounds", .{});
        const frame = appkit.rect(0, 0, bounds.size.width, bounds.size.height - chrome.tab_bar_height);
        const surface = try TerminalSurface.create(self.allocator, self.app, frame, inherit, @ptrCast(self));
        errdefer surface.destroy(self.allocator);
        surface.view.msgSend(void, "setAutoresizingMask:", .{@as(u64, 0)}); // laid out manually
        // Below the tab bar so chrome stays on top.
        self.content.msgSend(void, "addSubview:positioned:relativeTo:", .{
            surface.view,
            @as(i64, -1), // NSWindowBelow
            @as(?*anyopaque, null),
        });

        const title = try self.allocator.dupeZ(u8, "shell");
        errdefer self.allocator.free(title);
        const at = if (self.tabs.items.len == 0) 0 else self.active + 1;
        try self.tabs.insert(self.allocator, at, .{
            .tree = PaneTree.init(self.allocator, surface),
            .focused = surface,
            .title = title,
        });
        self.select(at);
    }

    /// Removes the pane owning `surface`. If it was its tab's only pane,
    /// the whole tab closes (closing the window if it was the last tab).
    pub fn closePane(self: *Window, surface: *TerminalSurface) void {
        const tab_index = self.tabIndexFor(surface) orelse return;
        const tab = &self.tabs.items[tab_index];

        const focus_after = tab.tree.remove(surface, surfaceEq) catch |err| switch (err) {
            error.LastLeaf => {
                self.closeWholeTab(tab_index);
                return;
            },
            error.NotFound => return,
        };

        surface.view.msgSend(void, "removeFromSuperview", .{});
        gcd.dispatch_async_f(&gcd._dispatch_main_q, surface, freeSurface);

        if (tab.zoomed == surface) tab.zoomed = null;
        tab.focused = focus_after;
        self.rebuildDividers(tab);
        if (tab_index == self.active) {
            self.window.msgSend(void, "makeFirstResponder:", .{focus_after.view});
            self.relayoutAll();
        }
    }

    fn closeWholeTab(self: *Window, index: usize) void {
        var tab = self.tabs.orderedRemove(index);
        self.allocator.free(tab.title);
        for (tab.dividers.items) |d| d.view.msgSend(void, "removeFromSuperview", .{});
        tab.dividers.deinit(self.allocator);
        // Detach and defer-free every remaining leaf; `tree.deinit` only
        // frees the Split nodes, not the surfaces themselves (see its doc).
        tab.tree.walk(self, detachLeaf);
        tab.tree.deinit();

        if (self.tabs.items.len == 0) {
            // Closes *this* window only -- `windowWillClose` does the real
            // teardown; the app itself keeps running (other windows, or
            // none at all) until an explicit Quit.
            self.window.msgSend(void, "close", .{});
            return;
        }

        if (index < self.active or self.active >= self.tabs.items.len) {
            self.active -|= 1;
        }
        self.select(@min(self.active, self.tabs.items.len - 1));
    }

    fn detachLeaf(self: *Window, ts: *TerminalSurface) void {
        _ = self;
        // The owning Window is gone by the time the deferred free runs;
        // null this so any late libghostty callback (`closeSurface`,
        // `resolveWindow`) hits its `owner orelse return` guard instead of
        // dereferencing the freed `*Window`.
        ts.owner = null;
        ts.view.msgSend(void, "removeFromSuperview", .{});
        gcd.dispatch_async_f(&gcd._dispatch_main_q, ts, freeSurface);
    }

    fn freeSurface(ctx: ?*anyopaque) callconv(.c) void {
        const surface: *TerminalSurface = @ptrCast(@alignCast(ctx orelse return));
        surface.destroy(std.heap.c_allocator);
    }

    fn select(self: *Window, index: usize) void {
        self.active = index;
        for (self.tabs.items, 0..) |*tab, i| self.setTabVisible(tab, i == index);
        const tab = &self.tabs.items[index];
        self.window.msgSend(void, "makeFirstResponder:", .{tab.focused.view});
        // Covers a tab that was hidden through a content resize: its tree
        // was still laid out against the stale size until now.
        self.relayoutAll();
        self.refreshTabBar();
    }

    fn setTabVisible(self: *Window, tab: *Tab, visible: bool) void {
        _ = self;
        const ctx = VisibilityCtx{ .tab = tab, .visible = visible };
        tab.tree.walk(ctx, applyVisibility);
        for (tab.dividers.items) |d| d.view.msgSend(void, "setHidden:", .{ !visible or tab.zoomed != null });
    }

    fn applyVisibility(ctx: VisibilityCtx, ts: *TerminalSurface) void {
        const shown = ctx.visible and (ctx.tab.zoomed == null or ctx.tab.zoomed.? == ts);
        ts.setVisible(shown);
    }

    fn refreshTabBar(self: *Window) void {
        var stack: [64][:0]const u8 = undefined;
        const n = @min(self.tabs.items.len, stack.len);
        for (self.tabs.items[0..n], 0..) |tab, i| stack[i] = tab.title;
        const owner: ?*anyopaque = @ptrCast(self);
        if (self.chrome_ui == .vertical) {
            sidebar.populate(&self.chrome_ui.vertical, stack[0..n], self.active, owner);
        } else {
            chrome.populateTabs(&self.chrome_ui.horizontal, stack[0..n], self.active, owner);
        }
    }

    fn tabIndexFor(self: *Window, surface: *TerminalSurface) ?usize {
        for (self.tabs.items, 0..) |*tab, i| if (tab.tree.contains(surface, surfaceEq)) return i;
        return null;
    }

    /// Applied when libghostty reports a title (shell integration, OSC
    /// title sequences, ...). Only the focused pane's title reaches the tab
    /// label; a background pane's title change is silently dropped. Skipped
    /// entirely once the tab has a manual name.
    fn setTitle(self: *Window, surface: *TerminalSurface, title: []const u8) void {
        const index = self.tabIndexFor(surface) orelse return;
        if (self.tabs.items[index].focused != surface) return;
        if (self.tabs.items[index].manual_title) return;
        const owned = self.allocator.dupeZ(u8, title) catch return;
        self.allocator.free(self.tabs.items[index].title);
        self.tabs.items[index].title = owned;
        self.refreshTabBar();
    }

    /// Applied from the tab-bar rename field (double-click a tab). Blank
    /// text reverts to automatic titles instead of setting an empty name.
    fn renameTab(self: *Window, index: usize, new_title: []const u8) void {
        if (index >= self.tabs.items.len) return;
        const trimmed = std.mem.trim(u8, new_title, " \t");
        if (trimmed.len == 0) {
            self.tabs.items[index].manual_title = false;
            self.refreshTabBar();
            return;
        }
        const owned = self.allocator.dupeZ(u8, trimmed) catch return;
        self.allocator.free(self.tabs.items[index].title);
        self.tabs.items[index].title = owned;
        self.tabs.items[index].manual_title = true;
        self.refreshTabBar();
    }

    // -- owner-ivar trampolines -------------------------------------------
    // Wired once in `installGlobalHandlers`; each resolves the owning
    // `*Window` from the ivar the click/event originated on and forwards
    // to the real (per-instance) method below.

    fn dispatchTabClick(owner: ?*anyopaque, index: usize) void {
        if (!isLive(owner)) return;
        const self: *Window = @ptrCast(@alignCast(owner.?));
        self.onTabClick(index);
    }

    fn dispatchTabDoubleClick(owner: ?*anyopaque, index: usize) void {
        if (!isLive(owner)) return;
        const self: *Window = @ptrCast(@alignCast(owner.?));
        self.onTabDoubleClick(index);
    }

    fn dispatchTabClose(owner: ?*anyopaque, index: usize) void {
        if (!isLive(owner)) return;
        const self: *Window = @ptrCast(@alignCast(owner.?));
        self.onTabCloseClick(index);
    }

    fn dispatchRenameCommit(owner: ?*anyopaque, index: usize, text: []const u8) void {
        if (!isLive(owner)) return;
        const self: *Window = @ptrCast(@alignCast(owner.?));
        self.onRenameCommit(index, text);
    }

    fn dispatchSidebarSplitRight(owner: ?*anyopaque) void {
        const self: *Window = @ptrCast(@alignCast(owner orelse return));
        self.onSidebarSplitRight();
    }

    /// `TerminalSurface.on_click`'s single global handler: the surface
    /// itself already carries `.owner`, so no ivar lookup is needed here.
    fn dispatchSurfaceClick(ts: *TerminalSurface) void {
        if (!isLive(ts.owner)) return;
        const self: *Window = @ptrCast(@alignCast(ts.owner.?));
        self.onSurfaceClicked(ts);
    }

    fn onTabDoubleClick(self: *Window, index: usize) void {
        if (index >= self.tabs.items.len) return;
        const owner: ?*anyopaque = @ptrCast(self);
        if (self.chrome_ui == .vertical) {
            sidebar.beginRename(&self.chrome_ui.vertical, index, self.tabs.items[index].title, owner);
        } else {
            chrome.beginRename(self.chrome_ui.horizontal, index, self.tabs.items[index].title, owner);
        }
    }

    fn onRenameCommit(self: *Window, index: usize, text: []const u8) void {
        self.renameTab(index, text);
    }

    fn onTabClick(self: *Window, index: usize) void {
        if (index == chrome.plus_index) {
            self.newTab(self.tabs.items[self.active].focused.surface) catch {};
        } else if (index < self.tabs.items.len) {
            self.select(index);
        }
    }

    /// Moves keyboard focus to whichever pane the user actually clicked --
    /// only ever fires for the active tab, since hidden panes' views don't
    /// receive mouse events.
    fn onSurfaceClicked(self: *Window, ts: *TerminalSurface) void {
        const tab = &self.tabs.items[self.active];
        if (!tab.tree.contains(ts, surfaceEq)) return; // e.g. a click during teardown
        self.focusPane(tab, ts);
    }

    fn focusPane(self: *Window, tab: *Tab, ts: *TerminalSurface) void {
        tab.focused = ts;
        self.window.msgSend(void, "makeFirstResponder:", .{ts.view});
    }

    // -- Vigil-owned shortcuts --------------------------------------------

    /// ⌘/ toggles the shortcuts sheet; while it's open, Esc closes it and
    /// plain typing is swallowed so keystrokes don't reach the terminal
    /// hidden behind it. Returns true to consume the event. Installed once
    /// (see `installGlobalHandlers`); resolves which window an event
    /// belongs to from the event's own NSWindow, since the key monitor
    /// sees every window's keys.
    fn onKeyEvent(event: objc.Object) bool {
        const event_window = event.msgSend(objc.Object, "window", .{});
        const self = forNSWindow(event_window) orelse {
            return preferences_window.isPreferencesWindow(event_window) and preferences_window.handleKey(event);
        };
        const mods = keymonitor.modifiers(event);
        const code = keymonitor.keyCode(event);

        // A tab rename in progress takes priority: only Esc is ours to
        // handle (cancels it); every other key must reach the field editor
        // normally (typing, Return-to-commit, ...).
        if (rename_field.isActive()) {
            if (mods == .none and code == keymonitor.key_escape) {
                rename_field.cancel();
                return true;
            }
            return false;
        }

        if (mods == .command and code == keymonitor.key_slash) {
            palette.hide();
            theme_gallery.hide();
            shortcuts_sheet.toggle(self.content);
            return true;
        }
        if (palette.isVisible()) return palette.handleKey(event);
        if (theme_gallery.isVisible()) return theme_gallery.handleKey(event);
        if (!shortcuts_sheet.isVisible()) return false;
        if (mods == .none and code == keymonitor.key_escape) {
            shortcuts_sheet.hide();
            return true;
        }
        // Let other ⌘ shortcuts (quit, new tab, ...) through.
        return mods != .command;
    }

    /// Runs a palette-chosen command: Vigil's own, or a libghostty binding
    /// action fired at the active tab's focused pane. `new_window` is the
    /// one Vigil action that doesn't need an existing window at all, so
    /// it's special-cased before resolving one.
    fn runCommand(cmd: keybindings.Command) void {
        if (cmd.vigil) |action| {
            if (action == .new_window) {
                const w = create(std.heap.c_allocator, shared_app) catch return;
                w.show();
                return;
            }
            const self = mainWindow() orelse return;
            // One modal at a time (overlay.zig's single dismiss callback
            // assumes it): hide the others before showing any overlay.
            switch (action) {
                .show_shortcuts => {
                    palette.hide();
                    theme_gallery.hide();
                    shortcuts_sheet.show(self.content);
                },
                .show_themes => {
                    palette.hide();
                    shortcuts_sheet.hide();
                    theme_gallery.show(self.content, themes.currentIndex(&settings.store));
                },
                .show_preferences => preferences_window.show(),
                .new_window => unreachable, // handled above
            }
        } else {
            const self = mainWindow() orelse return;
            _ = keybindings.perform(self.tabs.items[self.active].focused.surface, cmd);
        }
    }

    /// Writes the theme into Vigil's config, saves it, and pushes the new
    /// config to every surface (in every window -- one shared
    /// `ghostty_app_t`, so no window reference is needed).
    fn applyTheme(index: usize) void {
        if (index >= themes.themes.len) return;
        themes.write(&settings.store, std.heap.c_allocator, themes.themes[index]) catch return;
        settings.save();
        settings.apply(shared_app);
        theme_gallery.setApplied(index);
    }

    fn onPreferencesChanged() void {
        settings.apply(shared_app);
    }

    /// The vertical sidebar's content-header split-right button -- the same
    /// operation ⌘D performs, just reachable without a keyboard.
    fn onSidebarSplitRight(self: *Window) void {
        if (self.tabs.items.len == 0) return;
        self.newSplit(self.tabs.items[self.active].focused, ghc.GHOSTTY_SPLIT_DIRECTION_RIGHT) catch {};
    }

    /// A tab's close button (chrome.zig's per-tab "x", or the sidebar's
    /// per-row bin icon) -- closes every pane in that tab, same as
    /// libghostty's `close_tab` binding action.
    fn onTabCloseClick(self: *Window, index: usize) void {
        if (index >= self.tabs.items.len) return;
        self.closeWholeTab(index);
    }

    /// Preferences' buttons open overlays in the main window. Preferences is
    /// its own NSWindow and is key while a button is clicked, so `keyWindow`
    /// finds no main window; `mainWindow` falls back to the last-keyed one.
    fn onPreferencesButton(action: prefs.ButtonAction) void {
        const self = mainWindow() orelse return;
        self.window.msgSend(void, "makeKeyAndOrderFront:", .{@as(?*anyopaque, null)});
        // One modal at a time -- see runCommand.
        switch (action) {
            .choose_theme => {
                palette.hide();
                shortcuts_sheet.hide();
                theme_gallery.show(self.content, themes.currentIndex(&settings.store));
            },
            .show_shortcuts => {
                palette.hide();
                theme_gallery.hide();
                shortcuts_sheet.show(self.content);
            },
        }
    }

    /// Makes the window translucent (and blurred, per config) when
    /// `background-opacity` < 1, following what Ghostty's own macOS app does:
    /// a non-opaque window with a near-clear background, then libghostty
    /// applies the blur. Vigil's chrome bars stay solid; the terminal area
    /// shows through.
    pub fn syncAppearance(self: *Window, cfg: ghc.ghostty_config_t) void {
        var opacity: f64 = 1;
        _ = ghc.ghostty_config_get(cfg, &opacity, "background-opacity", "background-opacity".len);
        if (opacity < 1) {
            self.window.msgSend(void, "setOpaque:", .{false});
            self.window.msgSend(void, "setBackgroundColor:", .{
                appkit.class("NSColor").msgSend(objc.Object, "colorWithWhite:alpha:", .{ @as(f64, 1), @as(f64, 0.001) }),
            });
            ghc.ghostty_set_window_background_blur(self.app, self.window.value);
        } else {
            self.window.msgSend(void, "setOpaque:", .{true});
            self.window.msgSend(void, "setBackgroundColor:", .{appkit.nsColor(theme.colors.bg_app)});
        }
    }

    // -- libghostty action routing ---------------------------------------

    /// Returns true when the action was handled.
    pub fn handleAction(
        self: *Window,
        target: ghc.ghostty_target_s,
        act: ghc.ghostty_action_s,
    ) bool {
        const target_surface: ?*TerminalSurface = if (target.tag == ghc.GHOSTTY_TARGET_SURFACE)
            TerminalSurface.fromHandle(target.target.surface)
        else
            null;

        switch (act.tag) {
            ghc.GHOSTTY_ACTION_NEW_TAB => {
                // Actions can also arrive mid-creation (before any tab exists).
                if (self.tabs.items.len == 0) return false;
                const from = if (target_surface) |ts| ts.surface else self.tabs.items[self.active].focused.surface;
                self.newTab(from) catch return false;
                return true;
            },
            ghc.GHOSTTY_ACTION_CLOSE_TAB => {
                // Closes the *whole* tab (all its panes), unlike
                // close_surface/`closePane`. Only "this tab" is supported;
                // other/right modes are unhandled.
                if (act.action.close_tab_mode != ghc.GHOSTTY_ACTION_CLOSE_TAB_MODE_THIS) return false;
                if (self.tabs.items.len == 0) return false;
                const index = if (target_surface) |ts| (self.tabIndexFor(ts) orelse self.active) else self.active;
                self.closeWholeTab(index);
                return true;
            },
            ghc.GHOSTTY_ACTION_GOTO_TAB => {
                if (self.tabs.items.len == 0) return false;
                self.gotoTab(@intCast(act.action.goto_tab));
                return true;
            },
            ghc.GHOSTTY_ACTION_MOVE_TAB => {
                if (self.tabs.items.len == 0) return false;
                self.moveActiveTab(@intCast(act.action.move_tab.amount));
                return true;
            },
            ghc.GHOSTTY_ACTION_SET_TITLE, ghc.GHOSTTY_ACTION_SET_TAB_TITLE => {
                const ts = target_surface orelse return false;
                const title = act.action.set_title.title orelse return false;
                self.setTitle(ts, std.mem.span(title));
                return true;
            },
            ghc.GHOSTTY_ACTION_NEW_SPLIT => {
                if (self.tabs.items.len == 0) return false;
                const ts = target_surface orelse self.tabs.items[self.active].focused;
                self.newSplit(ts, act.action.new_split) catch return false;
                return true;
            },
            ghc.GHOSTTY_ACTION_GOTO_SPLIT => {
                if (self.tabs.items.len == 0) return false;
                self.gotoSplit(act.action.goto_split);
                return true;
            },
            ghc.GHOSTTY_ACTION_RESIZE_SPLIT => {
                if (self.tabs.items.len == 0) return false;
                self.resizeFocusedSplit(
                    &self.tabs.items[self.active],
                    @floatFromInt(act.action.resize_split.amount),
                    act.action.resize_split.direction,
                );
                return true;
            },
            ghc.GHOSTTY_ACTION_EQUALIZE_SPLITS => {
                if (self.tabs.items.len == 0) return false;
                self.tabs.items[self.active].tree.equalize();
                self.relayoutAll();
                return true;
            },
            ghc.GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM => {
                if (self.tabs.items.len == 0) return false;
                self.toggleZoom(&self.tabs.items[self.active]);
                return true;
            },
            ghc.GHOSTTY_ACTION_TOGGLE_COMMAND_PALETTE => {
                // Opening the palette dismisses any other overlay (one
                // modal at a time -- see runCommand); toggling an open
                // palette closed is unaffected by the extra hides.
                shortcuts_sheet.hide();
                theme_gallery.hide();
                palette.toggle(self.content);
                return true;
            },
            ghc.GHOSTTY_ACTION_RELOAD_CONFIG => {
                // Re-read Vigil's overrides from disk, then rebuild everything.
                settings.load();
                settings.apply(self.app);
                return true;
            },
            ghc.GHOSTTY_ACTION_CONFIG_CHANGE => {
                if (act.action.config_change.config) |cfg| self.syncAppearance(cfg);
                return true;
            },
            // ⌘, is bound to open_config by default; Vigil's own Preferences
            // takes its place rather than opening a config file in an editor.
            ghc.GHOSTTY_ACTION_OPEN_CONFIG => {
                preferences_window.show();
                return true;
            },
            ghc.GHOSTTY_ACTION_RING_BELL => {
                appkit.NSBeep();
                return true;
            },
            ghc.GHOSTTY_ACTION_TOGGLE_FULLSCREEN => {
                self.window.msgSend(void, "toggleFullScreen:", .{@as(?*anyopaque, null)});
                return true;
            },
            // Only Quit terminates the app now; closing a window (even the
            // last one) just closes it -- see `windowWillClose`.
            ghc.GHOSTTY_ACTION_QUIT => {
                terminate();
                return true;
            },
            ghc.GHOSTTY_ACTION_CLOSE_WINDOW => {
                self.window.msgSend(void, "close", .{});
                return true;
            },
            else => return false,
        }
    }

    /// Positive values are 1-based tab numbers (clamped to the last tab, as
    /// with ⌘9); negative ones are libghostty's relative/last sentinels.
    fn gotoTab(self: *Window, value: i32) void {
        const count = self.tabs.items.len;
        const target: usize = switch (value) {
            ghc.GHOSTTY_GOTO_TAB_PREVIOUS => (self.active + count - 1) % count,
            ghc.GHOSTTY_GOTO_TAB_NEXT => (self.active + 1) % count,
            ghc.GHOSTTY_GOTO_TAB_LAST => count - 1,
            else => if (value > 0) @min(@as(usize, @intCast(value)) - 1, count - 1) else return,
        };
        self.select(target);
    }

    fn moveActiveTab(self: *Window, amount: i64) void {
        const count: i64 = @intCast(self.tabs.items.len);
        if (count < 2) return;
        const to: usize = @intCast(@mod(@as(i64, @intCast(self.active)) + amount, count));
        const tab = self.tabs.orderedRemove(self.active);
        self.tabs.insertAssumeCapacity(to, tab);
        self.active = to;
        self.refreshTabBar();
    }

    // -- splits -------------------------------------------------------------

    /// Splits `target`'s pane in `dir`, creating a new sibling surface that
    /// inherits `target`'s settings and working directory.
    fn newSplit(self: *Window, target: *TerminalSurface, dir: c_uint) !void {
        const tab_index = self.tabIndexFor(target) orelse return error.NotFound;
        const tab = &self.tabs.items[tab_index];

        const placement = pane.placementFor(switch (dir) {
            ghc.GHOSTTY_SPLIT_DIRECTION_RIGHT => .right,
            ghc.GHOSTTY_SPLIT_DIRECTION_DOWN => .down,
            ghc.GHOSTTY_SPLIT_DIRECTION_LEFT => .left,
            ghc.GHOSTTY_SPLIT_DIRECTION_UP => .up,
            else => .right,
        });

        // Size the new leaf to roughly its final half up front (an even
        // split of `target`'s current rect) so its very first rendered
        // frame isn't a flash of the wrong size; `relayoutAll` below still
        // does the authoritative layout pass for both panes.
        const halves = pane.splitRect(target.last_frame, placement.direction, 0.5);
        const initial_frame = if (placement.new_is_first) halves.first else halves.second;

        const new_ts = try TerminalSurface.create(self.allocator, self.app, initial_frame, target.surface, @ptrCast(self));
        errdefer new_ts.destroy(self.allocator);
        new_ts.view.msgSend(void, "setAutoresizingMask:", .{@as(u64, 0)});
        self.content.msgSend(void, "addSubview:positioned:relativeTo:", .{
            new_ts.view,
            @as(i64, -1), // NSWindowBelow
            @as(?*anyopaque, null),
        });

        try tab.tree.split(target, surfaceEq, new_ts, placement);
        if (tab.zoomed != null) tab.zoomed = new_ts; // stay zoomed, now on the new pane
        self.rebuildDividers(tab);
        self.focusPane(tab, new_ts);
        self.relayoutAll();
    }

    fn toggleZoom(self: *Window, tab: *Tab) void {
        if (tab.tree.isSingleLeaf()) return;
        tab.zoomed = if (tab.zoomed != null) null else tab.focused;
        self.setTabVisible(tab, true); // this tab is already the active/visible one
        self.relayoutAll();
    }

    /// Tree-order neighbor (`previous`/`next`) or geometric nearest
    /// neighbor (`up`/`down`/`left`/`right`) of the tab's focused pane.
    fn gotoSplit(self: *Window, value: c_uint) void {
        const tab = &self.tabs.items[self.active];
        if (tab.tree.isSingleLeaf()) return;
        const target = switch (value) {
            ghc.GHOSTTY_GOTO_SPLIT_PREVIOUS => self.orderNeighbor(tab, false),
            ghc.GHOSTTY_GOTO_SPLIT_NEXT => self.orderNeighbor(tab, true),
            ghc.GHOSTTY_GOTO_SPLIT_UP => self.geometricNeighbor(tab, .up),
            ghc.GHOSTTY_GOTO_SPLIT_DOWN => self.geometricNeighbor(tab, .down),
            ghc.GHOSTTY_GOTO_SPLIT_LEFT => self.geometricNeighbor(tab, .left),
            ghc.GHOSTTY_GOTO_SPLIT_RIGHT => self.geometricNeighbor(tab, .right),
            else => null,
        } orelse return;
        self.focusPane(tab, target);
    }

    const max_panes = 64;
    const LeafList = struct { items: []*TerminalSurface, len: usize = 0 };

    fn collectLeaf(list: *LeafList, ts: *TerminalSurface) void {
        if (list.len < list.items.len) {
            list.items[list.len] = ts;
            list.len += 1;
        }
    }

    fn orderNeighbor(self: *Window, tab: *Tab, forward: bool) ?*TerminalSurface {
        _ = self;
        var buf: [max_panes]*TerminalSurface = undefined;
        var list = LeafList{ .items = &buf };
        tab.tree.walk(&list, collectLeaf);
        if (list.len < 2) return null;

        var idx: usize = 0;
        for (list.items[0..list.len], 0..) |ts, i| {
            if (ts == tab.focused) {
                idx = i;
                break;
            }
        }
        const n = list.len;
        return list.items[if (forward) (idx + 1) % n else (idx + n - 1) % n];
    }

    const GeoDirection = enum { up, down, left, right };

    /// The nearest other pane whose center lies in `dir` from the focused
    /// pane's center, by straight-line distance. Not a rigorous tiling-WM
    /// algorithm, but a good match for the common 2-4 pane layouts this app
    /// is used with.
    fn geometricNeighbor(self: *Window, tab: *Tab, dir: GeoDirection) ?*TerminalSurface {
        _ = self;
        var buf: [max_panes]*TerminalSurface = undefined;
        var list = LeafList{ .items = &buf };
        tab.tree.walk(&list, collectLeaf);

        const from = tab.focused.last_frame;
        const from_cx = from.origin.x + from.size.width / 2;
        const from_cy = from.origin.y + from.size.height / 2;

        var best: ?*TerminalSurface = null;
        var best_dist = std.math.inf(f64);
        for (list.items[0..list.len]) |ts| {
            if (ts == tab.focused) continue;
            const r = ts.last_frame;
            const cx = r.origin.x + r.size.width / 2;
            const cy = r.origin.y + r.size.height / 2;
            // AppKit's y-axis points up: "up" means a larger y.
            const matches_axis = switch (dir) {
                .left => cx < from_cx - 1,
                .right => cx > from_cx + 1,
                .up => cy > from_cy + 1,
                .down => cy < from_cy - 1,
            };
            if (!matches_axis) continue;
            const dx = cx - from_cx;
            const dy = cy - from_cy;
            const dist = dx * dx + dy * dy;
            if (dist < best_dist) {
                best_dist = dist;
                best = ts;
            }
        }
        return best;
    }

    fn findResizeTarget(p: Pane, focus: *TerminalSurface, axis: pane.Direction) ?*Split {
        const s = switch (p) {
            .leaf => return null,
            .split => |sp| sp,
        };
        const in_first = containsLeaf(s.first, focus);
        if (!in_first and !containsLeaf(s.second, focus)) return null; // focus isn't under this split
        if (findResizeTarget(if (in_first) s.first else s.second, focus, axis)) |deeper| return deeper;
        return if (s.direction == axis) s else null;
    }

    /// Moves the divider of the nearest matching-axis ancestor split of the
    /// focused pane by `amount_pts` in the given screen direction (LEFT/UP
    /// shrink `first`, RIGHT/DOWN grow it) -- i.e. arrow-key-style divider
    /// movement, not "grow the focused pane specifically" (which depends on
    /// which side of the split it's on). A reasonable reading of a
    /// secondary, keyboard-only feature; dragging a divider is the primary
    /// way to resize.
    fn resizeFocusedSplit(self: *Window, tab: *Tab, amount_pts: f64, direction: c_uint) void {
        const axis: pane.Direction = switch (direction) {
            ghc.GHOSTTY_RESIZE_SPLIT_LEFT, ghc.GHOSTTY_RESIZE_SPLIT_RIGHT => .horizontal,
            else => .vertical,
        };
        const target = findResizeTarget(tab.tree.root, tab.focused, axis) orelse return;
        const dimension = if (axis == .horizontal) target.last_rect.size.width else target.last_rect.size.height;
        if (dimension <= 0) return;

        const grows_first = direction == ghc.GHOSTTY_RESIZE_SPLIT_RIGHT or direction == ghc.GHOSTTY_RESIZE_SPLIT_DOWN;
        const delta = (amount_pts / dimension) * (if (grows_first) @as(f64, 1) else -1);
        target.setRatio(target.ratio + delta);
        self.relayoutAll();
    }

    fn terminate() void {
        const app = appkit.class("NSApplication").msgSend(objc.Object, "sharedApplication", .{});
        app.msgSend(void, "terminate:", .{@as(?*anyopaque, null)});
    }
};
