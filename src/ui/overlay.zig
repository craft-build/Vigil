//! Full-window dimmed backdrop used by modal panels (shortcuts sheet,
//! command palette). Clicking the backdrop -- but not the panel on top of
//! it -- calls the dismiss callback.
//!
//! Only one modal is ever on screen *app-wide*, not per window: every overlay
//! module (palette, theme gallery, shortcuts sheet) has a single process-global
//! instance, and the show sites hide the other two before showing one (see
//! `Window.runCommand`). So opening an overlay in a second window moves it
//! there, dismissing one open in the first. That is deliberate: a single
//! `dismiss_cb` and a single host view keep this file trivial, and the
//! workflows these panels serve are one-shot (pick a command/theme, read the
//! shortcut list). Only Preferences is a genuine second window, and it is
//! never hidden by this rule.
const std = @import("std");
const objc = @import("objc");
const appkit = @import("../app/appkit.zig");

const NSViewWidthSizable: u64 = 2;
const NSViewHeightSizable: u64 = 16;

pub const Dismiss = *const fn () void;

var backdrop_class: ?objc.Class = null;
/// Only one modal is ever on screen, so a single callback suffices (and
/// avoids stuffing a 4-aligned function pointer into an object ivar).
var dismiss_cb: ?Dismiss = null;

pub fn backdrop(bounds: appkit.NSRect, on_dismiss: Dismiss) objc.Object {
    const view = backdropClass().msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "initWithFrame:", .{bounds});
    dismiss_cb = on_dismiss;
    appkit.styleLayer(appkit.layerBacked(view), .{
        .background = .{ .r = 0.01, .g = 0.015, .b = 0.03, .a = 0.72 },
    });
    view.msgSend(void, "setAutoresizingMask:", .{NSViewWidthSizable | NSViewHeightSizable});
    return view;
}

fn backdropClass() objc.Class {
    if (backdrop_class) |cls| return cls;
    const cls = objc.allocateClassPair(appkit.class("NSView"), "VigilBackdrop") orelse
        @panic("failed to register VigilBackdrop");
    std.debug.assert(cls.addMethod("mouseDown:", mouseDown));
    objc.registerClassPair(cls);
    backdrop_class = cls;
    return cls;
}

fn mouseDown(_: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) void {
    if (dismiss_cb) |cb| cb();
}
