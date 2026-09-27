//! Vigil entry point: brings up a plain AppKit app (no Swift, no Xcode
//! project) with one window styled after Vigil.dc.html's Screen 01, hosting
//! one real libghostty terminal surface.
const std = @import("std");
const objc = @import("objc");
const ghc = @import("ghostty/c.zig").c;
const GhosttyApp = @import("ghostty/runtime.zig").App;
const appkit = @import("app/appkit.zig");
const Window = @import("app/Window.zig").Window;

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

    const window = try Window.create(allocator, app.app);
    window.show();
    NSApp.msgSend(void, "activateIgnoringOtherApps:", .{true});
    NSApp.msgSend(void, "run", .{});
}
