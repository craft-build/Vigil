//! A plain layer-backed view that reports mouse-downs with a caller-chosen
//! tag. `Kind` stamps out one Objective-C class (and one callback slot) per
//! use, so unrelated screens don't share a handler. Clicks anywhere inside
//! the view -- including on its label subviews -- land on the view itself.
const std = @import("std");
const objc = @import("objc");
const appkit = @import("../app/appkit.zig");

pub fn Kind(comptime class_name: [:0]const u8) type {
    return struct {
        pub var on_click: ?*const fn (tag: usize) void = null;

        var registered: ?objc.Class = null;

        fn viewClass() objc.Class {
            if (registered) |cls| return cls;
            const cls = objc.allocateClassPair(appkit.class("NSView"), class_name) orelse
                @panic("failed to register " ++ class_name);
            _ = cls.addIvar("vigilTag");
            std.debug.assert(cls.addMethod("mouseDown:", mouseDown));
            std.debug.assert(cls.addMethod("mouseDownCanMoveWindow", notMovable));
            std.debug.assert(cls.addMethod("hitTest:", hitTest));
            objc.registerClassPair(cls);
            registered = cls;
            return cls;
        }

        pub fn view(frame: appkit.NSRect, tag: usize, style: appkit.LayerStyle) objc.Object {
            const v = viewClass().msgSend(objc.Object, "alloc", .{})
                .msgSend(objc.Object, "initWithFrame:", .{frame});
            appkit.styleLayer(appkit.layerBacked(v), style);
            // Stored shifted (and +1) so the fake "pointer" is aligned and non-null.
            v.setInstanceVariable("vigilTag", .{ .value = @ptrFromInt((tag + 1) << 4) });
            return v;
        }

        fn notMovable(_: objc.c.id, _: objc.c.SEL) callconv(.c) bool {
            return false;
        }

        fn hitTest(id: objc.c.id, sel: objc.c.SEL, point: appkit.NSPoint) callconv(.c) objc.c.id {
            const obj = objc.Object{ .value = id };
            const hit = obj.msgSendSuper(appkit.class("NSView"), objc.Object, objc.Sel{ .value = sel }, .{point});
            return if (hit.value != null) id else null;
        }

        fn mouseDown(id: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) void {
            const stored = (objc.Object{ .value = id }).getInstanceVariable("vigilTag");
            const raw = @intFromPtr(stored.value);
            if (raw == 0) return;
            if (on_click) |cb| cb((raw >> 4) - 1);
        }
    };
}

/// Same as `Kind`, but also carries an owning `?*anyopaque` (an app-side
/// object pointer, e.g. a `*Window`) alongside the tag, for screens where
/// more than one instance of the owner can exist at once (multiple
/// windows) -- `Kind`'s single global `on_click` slot has no way to tell
/// those apart. Used by `chrome.zig`/`sidebar.zig`'s buttons; left as a
/// separate type rather than added to `Kind` so single-instance screens
/// (the theme gallery, preferences) don't have to carry an unused owner.
pub fn OwnedKind(comptime class_name: [:0]const u8) type {
    return struct {
        pub var on_click: ?*const fn (owner: ?*anyopaque, tag: usize) void = null;

        var registered: ?objc.Class = null;

        fn viewClass() objc.Class {
            if (registered) |cls| return cls;
            const cls = objc.allocateClassPair(appkit.class("NSView"), class_name) orelse
                @panic("failed to register " ++ class_name);
            _ = cls.addIvar("vigilTag");
            _ = cls.addIvar("vigilOwner");
            std.debug.assert(cls.addMethod("mouseDown:", mouseDown));
            std.debug.assert(cls.addMethod("mouseDownCanMoveWindow", notMovable));
            std.debug.assert(cls.addMethod("hitTest:", hitTest));
            objc.registerClassPair(cls);
            registered = cls;
            return cls;
        }

        pub fn view(frame: appkit.NSRect, owner: ?*anyopaque, tag: usize, style: appkit.LayerStyle) objc.Object {
            const v = viewClass().msgSend(objc.Object, "alloc", .{})
                .msgSend(objc.Object, "initWithFrame:", .{frame});
            appkit.styleLayer(appkit.layerBacked(v), style);
            // Stored shifted (and +1) so the fake "pointer" is aligned and non-null.
            v.setInstanceVariable("vigilTag", .{ .value = @ptrFromInt((tag + 1) << 4) });
            v.setInstanceVariable("vigilOwner", .{ .value = @ptrCast(@alignCast(owner)) });
            return v;
        }

        fn notMovable(_: objc.c.id, _: objc.c.SEL) callconv(.c) bool {
            return false;
        }

        fn hitTest(id: objc.c.id, sel: objc.c.SEL, point: appkit.NSPoint) callconv(.c) objc.c.id {
            const obj = objc.Object{ .value = id };
            const hit = obj.msgSendSuper(appkit.class("NSView"), objc.Object, objc.Sel{ .value = sel }, .{point});
            return if (hit.value != null) id else null;
        }

        fn mouseDown(id: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) void {
            const obj = objc.Object{ .value = id };
            const raw = @intFromPtr(obj.getInstanceVariable("vigilTag").value);
            if (raw == 0) return;
            const owner = obj.getInstanceVariable("vigilOwner").value;
            if (on_click) |cb| cb(owner, (raw >> 4) - 1);
        }
    };
}
