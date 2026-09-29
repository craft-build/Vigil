//! Shared inline-rename text field: an editable `NSTextField` overlaid on
//! top of whatever "pill"/"row" is being renamed, pre-filled with the
//! current title and fully selected, committing on Return or losing first
//! responder (`NSTextField`'s "end editing", via `sendsActionOnEndEditing`).
//! Used by both the horizontal tab bar (`chrome.zig`) and the vertical
//! sidebar (`sidebar.zig`) -- the mechanics don't care whether the thing
//! being renamed is a pill or a row, only its frame and host view.
const std = @import("std");
const objc = @import("objc");
const appkit = @import("../app/appkit.zig");

pub const OnCommit = *const fn (tag: usize, text: []const u8) void;

var field: ?objc.Object = null;
var target_obj: ?objc.Object = null;
var target_class: ?objc.Class = null;
var commit_cb: ?OnCommit = null;
/// The NSWindow the active field is hosted in (nil when no rename is active).
/// Lets a window's teardown/refresh cancel only its *own* rename instead of
/// whichever one happens to be open app-wide.
var host_window: ?objc.Object = null;
/// True only while `end` is detaching the field. Removing a view that is
/// still the window's first responder makes AppKit resign it right there,
/// which -- since the field has `sendsActionOnEndEditing` -- re-fires
/// `renameCommit:` synchronously, reentrantly, with a title string the
/// outer call is still holding a (soon to be freed) pointer to. This flag
/// makes that reentrant fire (commit *or* cancel) a no-op instead of a
/// use-after-free.
var handling_end = false;

pub fn isActive() bool {
    return field != null;
}

/// Overlays an editable field at `frame` (in `host`'s coordinate space),
/// pre-filled with `current_text` and with all of it selected. Ends any
/// rename already in progress first. `tag` is handed back to `on_commit`
/// verbatim -- the caller's own index for whatever it was renaming.
pub fn begin(
    host: objc.Object,
    frame: appkit.NSRect,
    current_text: [:0]const u8,
    font: objc.Object,
    bg: objc.Object,
    text_color: objc.Object,
    tag: usize,
    on_commit: OnCommit,
) void {
    end();
    commit_cb = on_commit;

    const f = appkit.class("NSTextField").msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "initWithFrame:", .{frame});
    f.msgSend(void, "setBezeled:", .{false});
    f.msgSend(void, "setDrawsBackground:", .{true});
    f.msgSend(void, "setBackgroundColor:", .{bg});
    f.msgSend(void, "setFont:", .{font});
    f.msgSend(void, "setTextColor:", .{text_color});
    f.msgSend(void, "setStringValue:", .{appkit.nsString(current_text)});
    f.msgSend(objc.Object, "cell", .{}).msgSend(void, "setSendsActionOnEndEditing:", .{true});
    f.msgSend(void, "setTarget:", .{renameTarget()});
    f.msgSend(void, "setAction:", .{objc.sel("renameCommit:").value});
    f.msgSend(void, "setTag:", .{@as(i64, @intCast(tag))});
    appkit.addSubview(host, f);

    const window = host.msgSend(objc.Object, "window", .{});
    window.msgSend(void, "makeFirstResponder:", .{f});
    window.msgSend(objc.Object, "fieldEditor:forObject:", .{ true, f })
        .msgSend(void, "selectAll:", .{@as(?*anyopaque, null)});

    host_window = window;
    field = f;
}

/// Discards an in-progress rename without committing it.
pub fn cancel() void {
    end();
}

/// Ends an in-progress rename only when it is hosted in `win` (an NSWindow).
/// Used so one window closing or restructuring can't cancel a rename in
/// another window.
pub fn cancelIfInWindow(win: objc.Object) void {
    const w = host_window orelse return;
    if (w.value == win.value) end();
}

fn end() void {
    const f = field orelse return;
    field = null; // clear first: see `handling_end` above
    host_window = null;
    handling_end = true;
    f.msgSend(void, "removeFromSuperview", .{});
    handling_end = false;
}

fn renameTarget() objc.Object {
    if (target_obj) |t| return t;
    const t = renameTargetClass().msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});
    target_obj = t;
    return t;
}

fn renameTargetClass() objc.Class {
    if (target_class) |cls| return cls;
    const cls = objc.allocateClassPair(appkit.class("NSObject"), "VigilRenameTarget") orelse
        @panic("failed to register VigilRenameTarget");
    std.debug.assert(cls.addMethod("renameCommit:", renameCommit));
    objc.registerClassPair(cls);
    target_class = cls;
    return cls;
}

fn renameCommit(_: objc.c.id, _: objc.c.SEL, sender: objc.c.id) callconv(.c) void {
    if (handling_end) return; // see `handling_end`
    const f = objc.Object{ .value = sender };
    const tag = f.msgSend(i64, "tag", .{});
    if (tag < 0) return;
    const str = f.msgSend(objc.Object, "stringValue", .{});
    const cstr = str.msgSend(?[*:0]const u8, "UTF8String", .{}) orelse return;
    if (commit_cb) |cb| cb(@intCast(tag), std.mem.span(cstr));
}
