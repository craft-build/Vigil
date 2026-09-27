//! The main window's model: an ordered list of tabs, each owning one
//! TerminalSurface, plus the chrome (tab bar, log pane, status bar) around
//! them. libghostty drives tab operations through `action_cb`; those land in
//! `handleAction`, which mutates this model and re-renders the tab bar.
//!
//! Only one Window exists (`Window.instance`), since libghostty's callbacks
//! carry no per-window context beyond a surface pointer.
const std = @import("std");
const objc = @import("objc");
const ghc = @import("../ghostty/c.zig").c;
const appkit = @import("appkit.zig");
const TerminalSurface = @import("TerminalSurface.zig").TerminalSurface;
const chrome = @import("../ui/chrome.zig");
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

extern "c" var _dispatch_main_q: anyopaque;
extern "c" fn dispatch_async_f(
    queue: ?*anyopaque,
    context: ?*anyopaque,
    work: *const fn (?*anyopaque) callconv(.c) void,
) void;

const Tab = struct {
    surface: *TerminalSurface,
    /// Owned, NUL-terminated.
    title: [:0]u8,
};

pub const Window = struct {
    allocator: std.mem.Allocator,
    app: ghc.ghostty_app_t,
    window: objc.Object,
    content: objc.Object,
    tab_bar: chrome.TabBar,
    tabs: std.ArrayList(Tab) = .empty,
    active: usize = 0,

    pub var instance: ?*Window = null;

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
        window.msgSend(void, "setTitle:", .{appkit.nsString("Vigil")});
        window.msgSend(void, "setTitleVisibility:", .{@as(i64, 1)}); // NSWindowTitleHidden
        window.msgSend(void, "setTitlebarAppearsTransparent:", .{true});
        window.msgSend(void, "setBackgroundColor:", .{appkit.nsColor(theme.colors.bg_app)});
        window.msgSend(void, "center", .{});

        const content = window.msgSend(objc.Object, "contentView", .{});
        chrome.buildLogPane(
            content,
            appkit.rect(
                window_w - chrome.log_pane_width,
                chrome.status_bar_height,
                chrome.log_pane_width,
                window_h - chrome.tab_bar_height - chrome.status_bar_height,
            ),
        );
        const tab_bar = chrome.buildTabBar(content, window_w, window_h);
        chrome.buildStatusBar(content, window_w);

        self.* = .{
            .allocator = allocator,
            .app = app,
            .window = window,
            .content = content,
            .tab_bar = tab_bar,
        };
        instance = self;
        chrome.on_tab_click = onTabClick;
        keymonitor.install(onKeyEvent);
        palette.on_run = runCommand;
        theme_gallery.on_select = applyTheme;
        preferences_window.on_change = onPreferencesChanged;
        preferences_window.on_button = onPreferencesButton;

        try self.newTab(null);
        return self;
    }

    pub fn show(self: *Window) void {
        self.window.msgSend(void, "makeKeyAndOrderFront:", .{@as(?*anyopaque, null)});
        if (settings.current) |cfg| self.syncAppearance(cfg);
    }

    // -- tab operations ---------------------------------------------------

    /// Opens a tab after the active one, inheriting settings (and working
    /// directory) from `inherit` when given.
    pub fn newTab(self: *Window, inherit: ?ghc.ghostty_surface_t) !void {
        const bounds = self.content.msgSend(appkit.NSRect, "bounds", .{});
        const frame = appkit.rect(
            0,
            chrome.status_bar_height,
            bounds.size.width - chrome.log_pane_width,
            bounds.size.height - chrome.tab_bar_height - chrome.status_bar_height,
        );
        const surface = try TerminalSurface.create(self.allocator, self.app, frame, inherit);
        errdefer surface.destroy(self.allocator);
        surface.view.msgSend(void, "setAutoresizingMask:", .{@as(u64, 2 | 16)}); // WidthSizable | HeightSizable
        // Below the tab bar / status bar / log pane so chrome stays on top.
        self.content.msgSend(void, "addSubview:positioned:relativeTo:", .{
            surface.view,
            @as(i64, -1), // NSWindowBelow
            @as(?*anyopaque, null),
        });

        const title = try self.allocator.dupeZ(u8, "shell");
        errdefer self.allocator.free(title);
        const at = if (self.tabs.items.len == 0) 0 else self.active + 1;
        try self.tabs.insert(self.allocator, at, .{ .surface = surface, .title = title });
        self.select(at);
    }

    /// Removes the tab owning `surface`. Quits when it was the last one.
    pub fn closeTab(self: *Window, surface: *TerminalSurface) void {
        const index = self.indexOf(surface) orelse return;
        const tab = self.tabs.orderedRemove(index);
        self.allocator.free(tab.title);

        if (self.tabs.items.len == 0) {
            terminate();
            return;
        }

        tab.surface.view.msgSend(void, "removeFromSuperview", .{});
        // We're usually inside libghostty's own callback for this surface;
        // free it once that has unwound.
        dispatch_async_f(&_dispatch_main_q, tab.surface, freeSurface);

        if (index < self.active or self.active >= self.tabs.items.len) {
            self.active -|= 1;
        }
        self.select(@min(self.active, self.tabs.items.len - 1));
    }

    fn freeSurface(ctx: ?*anyopaque) callconv(.c) void {
        const surface: *TerminalSurface = @ptrCast(@alignCast(ctx orelse return));
        surface.destroy(std.heap.c_allocator);
    }

    fn select(self: *Window, index: usize) void {
        self.active = index;
        for (self.tabs.items, 0..) |tab, i| tab.surface.setVisible(i == index);
        const active = self.tabs.items[index].surface;
        self.window.msgSend(void, "makeFirstResponder:", .{active.view});
        self.refreshTabBar();
    }

    fn refreshTabBar(self: *Window) void {
        var stack: [64][:0]const u8 = undefined;
        const n = @min(self.tabs.items.len, stack.len);
        for (self.tabs.items[0..n], 0..) |tab, i| stack[i] = tab.title;
        chrome.populateTabs(self.tab_bar, stack[0..n], self.active);
    }

    fn indexOf(self: *Window, surface: *TerminalSurface) ?usize {
        for (self.tabs.items, 0..) |tab, i| if (tab.surface == surface) return i;
        return null;
    }

    fn setTitle(self: *Window, surface: *TerminalSurface, title: []const u8) void {
        const index = self.indexOf(surface) orelse return;
        const owned = self.allocator.dupeZ(u8, title) catch return;
        self.allocator.free(self.tabs.items[index].title);
        self.tabs.items[index].title = owned;
        self.refreshTabBar();
    }

    fn onTabClick(index: usize) void {
        const self = instance orelse return;
        if (index == chrome.plus_index) {
            self.newTab(self.tabs.items[self.active].surface.surface) catch {};
        } else if (index < self.tabs.items.len) {
            self.select(index);
        }
    }

    // -- Vigil-owned shortcuts --------------------------------------------

    /// ⌘/ toggles the shortcuts sheet; while it's open, Esc closes it and
    /// plain typing is swallowed so keystrokes don't reach the terminal
    /// hidden behind it. Returns true to consume the event.
    fn onKeyEvent(event: objc.Object) bool {
        const self = instance orelse return false;
        // The monitor sees every window's keys; only the main window's are ours,
        // except ⌘W/Esc in Preferences.
        const event_window = event.msgSend(objc.Object, "window", .{});
        if (event_window.value != self.window.value) {
            return preferences_window.isPreferencesWindow(event_window) and preferences_window.handleKey(event);
        }
        const mods = keymonitor.modifiers(event);
        const code = keymonitor.keyCode(event);

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
    /// action fired at the active surface.
    fn runCommand(cmd: keybindings.Command) void {
        const self = instance orelse return;
        if (cmd.vigil) |action| switch (action) {
            .show_shortcuts => shortcuts_sheet.show(self.content),
            .show_themes => theme_gallery.show(self.content, themes.currentIndex(&settings.store)),
            .show_preferences => preferences_window.show(),
        } else {
            _ = keybindings.perform(self.tabs.items[self.active].surface.surface, cmd);
        }
    }

    /// Writes the theme into Vigil's config, saves it, and pushes the new
    /// config to every surface.
    fn applyTheme(index: usize) void {
        const self = instance orelse return;
        if (index >= themes.themes.len) return;
        themes.write(&settings.store, std.heap.c_allocator, themes.themes[index]) catch return;
        settings.save();
        settings.apply(self.app);
        theme_gallery.setApplied(index);
    }

    fn onPreferencesChanged() void {
        const self = instance orelse return;
        settings.apply(self.app);
    }

    /// Preferences buttons open screens that live in the main window.
    fn onPreferencesButton(action: prefs.ButtonAction) void {
        const self = instance orelse return;
        self.window.msgSend(void, "makeKeyAndOrderFront:", .{@as(?*anyopaque, null)});
        switch (action) {
            .choose_theme => theme_gallery.show(self.content, themes.currentIndex(&settings.store)),
            .show_shortcuts => shortcuts_sheet.show(self.content),
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
                const from = if (target_surface) |ts| ts.surface else self.tabs.items[self.active].surface.surface;
                self.newTab(from) catch return false;
                return true;
            },
            ghc.GHOSTTY_ACTION_CLOSE_TAB => {
                // Only "this tab" is supported; other/right modes are unhandled.
                if (act.action.close_tab_mode != ghc.GHOSTTY_ACTION_CLOSE_TAB_MODE_THIS) return false;
                if (self.tabs.items.len == 0) return false;
                self.closeTab(target_surface orelse self.tabs.items[self.active].surface);
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
            ghc.GHOSTTY_ACTION_TOGGLE_COMMAND_PALETTE => {
                if (shortcuts_sheet.isVisible() or theme_gallery.isVisible()) return true;
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
                appkit.class("NSSound").msgSend(void, "beep", .{});
                return true;
            },
            ghc.GHOSTTY_ACTION_TOGGLE_FULLSCREEN => {
                self.window.msgSend(void, "toggleFullScreen:", .{@as(?*anyopaque, null)});
                return true;
            },
            ghc.GHOSTTY_ACTION_QUIT, ghc.GHOSTTY_ACTION_CLOSE_WINDOW => {
                terminate();
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

    fn terminate() void {
        const app = appkit.class("NSApplication").msgSend(objc.Object, "sharedApplication", .{});
        app.msgSend(void, "terminate:", .{@as(?*anyopaque, null)});
    }
};
