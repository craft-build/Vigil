//! NSPasteboard bridge for libghostty's clipboard callbacks. Only plain
//! text on the general pasteboard is supported; Vigil doesn't advertise
//! the selection clipboard (`supports_selection_clipboard = false`).
const std = @import("std");
const objc = @import("objc");
const appkit = @import("appkit.zig");

const utf8_type = "public.utf8-plain-text";
const NSUTF8StringEncoding: u64 = 4;

fn generalPasteboard() objc.Object {
    return appkit.class("NSPasteboard").msgSend(objc.Object, "generalPasteboard", .{});
}

/// Returns the pasteboard's text as a NUL-terminated UTF-8 string, valid
/// until the enclosing autorelease pool drains (i.e. for the current
/// callback), or null if the pasteboard holds no text.
pub fn readText() ?[*:0]const u8 {
    const str = generalPasteboard().msgSend(objc.Object, "stringForType:", .{
        appkit.nsString(utf8_type),
    });
    if (str.value == null) return null;
    return str.msgSend([*:0]const u8, "UTF8String", .{});
}

/// Replaces the pasteboard contents with `text` (not required to be
/// NUL-terminated).
pub fn writeText(text: []const u8) void {
    const str = appkit.class("NSString")
        .msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "initWithBytes:length:encoding:", .{
        text.ptr, @as(u64, text.len), NSUTF8StringEncoding,
    });
    if (str.value == null) return;
    defer str.msgSend(void, "release", .{});

    const pb = generalPasteboard();
    _ = pb.msgSend(i64, "clearContents", .{});
    _ = pb.msgSend(bool, "setString:forType:", .{ str, appkit.nsString(utf8_type) });
}
