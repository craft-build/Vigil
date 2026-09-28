//! Vigil entry point: brings up a plain AppKit app (no Swift, no Xcode
//! project) with a window styled after Vigil.dc.html's Screen 01, hosting
//! real libghostty terminal surfaces. File > New Window (⌘N) can open more.
const std = @import("std");
const objc = @import("objc");
const ghc = @import("ghostty/c.zig").c;
const GhosttyApp = @import("ghostty/runtime.zig").App;
const appkit = @import("app/appkit.zig");
const Window = @import("app/Window.zig").Window;
const keybindings = @import("app/keybindings.zig");
const settings = @import("app/settings.zig");
const menu = @import("app/menu.zig");

/// File scope, not a local in `main`: the `GhosttyApp`'s address is handed
/// to libghostty as its runtime `userdata`, and that pointer must not
/// depend on a stack frame.
var app_storage: GhosttyApp = .{};

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

    settings.load();
    const config = settings.buildConfig() orelse return error.GhosttyConfigNewFailed;

    keybindings.init(config);

    const app = &app_storage;
    try app.init(config);
    defer app.deinit();
    ghc.ghostty_app_set_focus(app.app, true);

    const NSApp = appkit.class("NSApplication").msgSend(objc.Object, "sharedApplication", .{});
    NSApp.msgSend(void, "setActivationPolicy:", .{@as(i64, 0)}); // NSApplicationActivationPolicyRegular

    // `addSubview` drops references via `autorelease` (see appkit.zig);
    // anything built before the run loop starts (the first window's chrome)
    // would otherwise autorelease with no pool in place and leak.
    const pool = appkit.class("NSAutoreleasePool").msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});
    Window.installGlobalHandlers();
    const window = try Window.create(allocator, app.app);
    menu.install();
    window.show();
    pool.msgSend(void, "drain", .{});
    NSApp.msgSend(void, "activateIgnoringOtherApps:", .{true});
    NSApp.msgSend(void, "run", .{});
}

test {
    _ = keybindings;
    _ = @import("app/settings.zig");
    _ = @import("app/themes.zig");
    _ = @import("app/preferences.zig");
    _ = @import("app/pane.zig");
    _ = @import("ui/palette.zig");
}
