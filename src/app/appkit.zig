//! Small AppKit helpers shared across Vigil's UI code. Everything here is
//! thin, direct Objective-C runtime calls via zig-objc. Vigil uses manual
//! retain/release: fresh `alloc`/`init` views start at +1, and `addSubview`
//! hands that reference to the new superview (see its comment) -- this is
//! deliberately *not* "everything leaks", because several containers
//! (command palette, tab bar, sidebar) rebuild their contents wholesale on
//! ordinary user actions. What does remain autoreleased-only
//! (NSStrings/NSColors used as immediate arguments) is a deliberate,
//! acceptable simplification.
const objc = @import("objc");
const theme = @import("../ui/theme.zig");

/// AppKit's system alert sound. This is a plain C function, not an
/// `NSSound` class method -- `+[NSSound beep]` does not exist and throws
/// `NSInvalidArgumentException` if messaged.
pub extern "c" fn NSBeep() void;

pub const NSPoint = extern struct { x: f64, y: f64 };
pub const NSSize = extern struct { width: f64, height: f64 };
pub const NSRect = extern struct { origin: NSPoint, size: NSSize };

pub fn rect(x: f64, y: f64, w: f64, h: f64) NSRect {
    return .{ .origin = .{ .x = x, .y = y }, .size = .{ .width = w, .height = h } };
}

pub fn class(comptime name: [:0]const u8) objc.Class {
    return objc.getClass(name) orelse @panic("missing Objective-C class: " ++ name);
}

pub fn nsString(s: [:0]const u8) objc.Object {
    return class("NSString").msgSend(objc.Object, "stringWithUTF8String:", .{s.ptr});
}

pub fn nsColor(col: theme.Color) objc.Object {
    return class("NSColor").msgSend(objc.Object, "colorWithSRGBRed:green:blue:alpha:", .{
        col.r, col.g, col.b, col.a,
    });
}

pub fn cgColor(col: theme.Color) ?*anyopaque {
    return nsColor(col).msgSend(?*anyopaque, "CGColor", .{});
}

/// Makes `view` layer-backed and returns its CALayer.
pub fn layerBacked(view: objc.Object) objc.Object {
    view.msgSend(void, "setWantsLayer:", .{true});
    return view.msgSend(objc.Object, "layer", .{});
}

pub const LayerStyle = struct {
    background: ?theme.Color = null,
    border: ?theme.Color = null,
    border_width: f64 = 1.0,
    corner_radius: f64 = 0,
};

pub fn styleLayer(layer: objc.Object, opts: LayerStyle) void {
    if (opts.background) |bg| layer.msgSend(void, "setBackgroundColor:", .{cgColor(bg)});
    if (opts.border) |bc| {
        layer.msgSend(void, "setBorderColor:", .{cgColor(bc)});
        layer.msgSend(void, "setBorderWidth:", .{opts.border_width});
    }
    if (opts.corner_radius > 0) {
        layer.msgSend(void, "setCornerRadius:", .{opts.corner_radius});
        layer.msgSend(void, "setMasksToBounds:", .{true});
    }
}

/// Convenience: a plain layer-backed NSView styled in one call (used for tab
/// pills, panel backgrounds, the status pill, etc.). `theme.radius.pill`
/// (999) is a "make it a capsule" sentinel from the CSS prototype, not a
/// literal point value -- clamp it to the view's own half-height so CALayer
/// gets a real corner radius instead of a wildly out-of-range one.
pub fn panel(frame: NSRect, style: LayerStyle) objc.Object {
    const view = newView(frame);
    var clamped = style;
    if (clamped.corner_radius > 0) {
        const half = @min(frame.size.width, frame.size.height) / 2;
        clamped.corner_radius = @min(clamped.corner_radius, half);
    }
    styleLayer(layerBacked(view), clamped);
    return view;
}

pub fn newView(frame: NSRect) objc.Object {
    return class("NSView")
        .msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "initWithFrame:", .{frame});
}

/// Adds `child` to `parent` and transfers ownership of the caller's
/// alloc-time +1 to the superview. Only safe because every call site adds a
/// freshly-allocated view that never gets re-parented. Dropping the +1 via
/// `autorelease` (rather than `release`) means a rebuild triggered from an
/// event handler can't dealloc the view mid-dispatch.
pub fn addSubview(parent: objc.Object, child: objc.Object) void {
    parent.msgSend(void, "addSubview:", .{child});
    // Superview now owns it; drop our alloc-time +1 via the pool so
    // in-event rebuilds can't dealloc the view mid-dispatch.
    child.msgSend(void, "autorelease", .{});
}

/// Removes every subview of `view`. Used before rebuilding a container's
/// contents wholesale (tab pills, sidebar rows, ...).
pub fn removeAllSubviews(view: objc.Object) void {
    const subviews = view.msgSend(objc.Object, "subviews", .{});
    // Iterate over a copy: removing from the live array while walking it skips items.
    const copy = subviews.msgSend(objc.Object, "copy", .{});
    defer copy.msgSend(void, "release", .{});
    var n = copy.msgSend(u64, "count", .{});
    while (n > 0) : (n -= 1) {
        copy.msgSend(objc.Object, "objectAtIndex:", .{n - 1}).msgSend(void, "removeFromSuperview", .{});
    }
}

/// Looks up `family` at `size`; falls back to a system font in the same
/// voice if it isn't installed. The prototype's Space Grotesk / IBM Plex
/// fonts are Google Fonts pulled in over CSS in the browser mockup -- they
/// are not guaranteed to be installed system-wide here.
pub fn font(family: [:0]const u8, size: f64, mono: bool) objc.Object {
    const named = class("NSFont").msgSend(objc.Object, "fontWithName:size:", .{
        nsString(family), size,
    });
    if (named.value != null) return named;
    if (mono) {
        return class("NSFont").msgSend(objc.Object, "monospacedSystemFontOfSize:weight:", .{
            size, @as(f64, 0),
        });
    }
    return class("NSFont").msgSend(objc.Object, "systemFontOfSize:", .{size});
}

/// NSTextAlignment on this SDK: left 0, center 1, right 2 (measured, not
/// assumed -- it is the reverse of what the constant names' order suggests
/// on iOS-derived docs).
pub const TextAlign = enum(i64) { left = 0, center = 1, right = 2 };

pub fn setAlignment(view: objc.Object, alignment: TextAlign) void {
    view.msgSend(void, "setAlignment:", .{@intFromEnum(alignment)});
}

pub fn label(frame: NSRect, text: [:0]const u8, f: objc.Object, color: theme.Color) objc.Object {
    const field = class("NSTextField")
        .msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "initWithFrame:", .{frame});
    field.msgSend(void, "setStringValue:", .{nsString(text)});
    field.msgSend(void, "setBezeled:", .{false});
    field.msgSend(void, "setDrawsBackground:", .{false});
    field.msgSend(void, "setEditable:", .{false});
    field.msgSend(void, "setSelectable:", .{false});
    field.msgSend(void, "setFont:", .{f});
    field.msgSend(void, "setTextColor:", .{nsColor(color)});
    return field;
}
