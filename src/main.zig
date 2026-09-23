//! Vigil entry point: brings up a plain AppKit app (no Swift, no Xcode
//! project) with one window styled after Vigil.dc.html's Screen 01, hosting
//! one real libghostty terminal surface.
const std = @import("std");
const objc = @import("objc");
const ghc = @import("ghostty/c.zig").c;
const GhosttyApp = @import("ghostty/runtime.zig").App;
const appkit = @import("app/appkit.zig");
const TerminalSurface = @import("app/TerminalSurface.zig").TerminalSurface;
const chrome = @import("ui/chrome.zig");
const theme = @import("ui/theme.zig");

const window_w: f64 = 1120;
const window_h: f64 = 700;

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    // ghostty_init's argc/argv are for parsing Ghostty's own CLI flags,
    // which this vertical slice doesn't use; a stable single-element argv
    // sidesteps std.os.argv's platform-specific availability.
    var argv0 = "vigil".*;
    var argv_ptrs = [_][*c]u8{&argv0};
    if (ghc.ghostty_init(1, &argv_ptrs) != ghc.GHOSTTY_SUCCESS) {
        return error.GhosttyInitFailed;
    }

    const config = ghc.ghostty_config_new() orelse return error.GhosttyConfigNewFailed;
    ghc.ghostty_config_load_default_files(config);
    ghc.ghostty_config_finalize(config);

    var app: GhosttyApp = .{};
    try app.init(config);
    defer app.deinit();
    ghc.ghostty_app_set_focus(app.app, true);

    const NSApp = appkit.class("NSApplication").msgSend(objc.Object, "sharedApplication", .{});
    NSApp.msgSend(void, "setActivationPolicy:", .{@as(i64, 0)}); // NSApplicationActivationPolicyRegular

    const style_mask: u64 = 1 | 2 | 4 | 8; // Titled | Closable | Miniaturizable | Resizable
    const window = appkit.class("NSWindow")
        .msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "initWithContentRect:styleMask:backing:defer:", .{
            appkit.rect(0, 0, window_w, window_h),
            style_mask,
            @as(u64, 2), // NSBackingStoreBuffered
            false,
        });
    window.msgSend(void, "setTitle:", .{appkit.nsString("Vigil")});
    window.msgSend(void, "setBackgroundColor:", .{appkit.nsColor(theme.colors.bg_app)});
    window.msgSend(void, "center", .{});

    const content = window.msgSend(objc.Object, "contentView", .{});

    // Terminal pane fills the middle area, left of the log side-panel,
    // between the tab bar and status bar.
    const mid_h = window_h - chrome.tab_bar_height - chrome.status_bar_height;
    const term_w = window_w - chrome.log_pane_width;
    const surface = try TerminalSurface.create(
        allocator,
        app.app,
        appkit.rect(0, chrome.status_bar_height, term_w, mid_h),
    );
    surface.view.msgSend(void, "setAutoresizingMask:", .{@as(u64, 2 | 16)}); // WidthSizable | HeightSizable
    appkit.addSubview(content, surface.view);

    chrome.buildLogPane(
        content,
        appkit.rect(term_w, chrome.status_bar_height, chrome.log_pane_width, mid_h),
    );
    chrome.buildTabBar(content, window_w, window_h);
    chrome.buildStatusBar(content, window_w);

    window.msgSend(void, "makeFirstResponder:", .{surface.view});
    ghc.ghostty_surface_set_focus(surface.surface, true);

    window.msgSend(void, "makeKeyAndOrderFront:", .{@as(?*anyopaque, null)});
    NSApp.msgSend(void, "activateIgnoringOtherApps:", .{true});
    NSApp.msgSend(void, "run", .{});
}
