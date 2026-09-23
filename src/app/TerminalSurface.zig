//! Wraps one ghostty_surface_t bound to a plain NSView. libghostty itself
//! makes the view layer-backed and attaches its own CAMetalLayer + Metal
//! renderer the moment ghostty_surface_new() is called with the view's
//! pointer -- confirmed by vendor/ghostty's Swift SurfaceView_AppKit.swift,
//! which never touches CALayer/CAMetalLayer itself. Our job is just: give it
//! a view, and forward keyboard input + resize/focus notifications.
//!
//! Mouse handling, IME (marked text/preedit), and precise unshifted-codepoint
//! computation are not implemented in this vertical slice -- see the roadmap
//! in the project plan. Typed text (including Ctrl-chars) and non-text keys
//! (arrows, enter, backspace, function keys) are forwarded, which is enough
//! to drive a real interactive shell.
const std = @import("std");
const objc = @import("objc");
const ghc = @import("../ghostty/c.zig").c;
const appkit = @import("appkit.zig");

const NSEventModifierFlagCapsLock: u64 = 1 << 16;
const NSEventModifierFlagShift: u64 = 1 << 17;
const NSEventModifierFlagControl: u64 = 1 << 18;
const NSEventModifierFlagOption: u64 = 1 << 19;
const NSEventModifierFlagCommand: u64 = 1 << 20;

pub const TerminalSurface = struct {
    view: objc.Object,
    surface: ghc.ghostty_surface_t,

    var registered_class: ?objc.Class = null;

    /// `app` must already be initialized. `frame` is the view's initial
    /// frame in points; the caller adds the returned view to the window's
    /// view hierarchy.
    pub fn create(
        allocator: std.mem.Allocator,
        app: ghc.ghostty_app_t,
        frame: appkit.NSRect,
    ) !*TerminalSurface {
        const self = try allocator.create(TerminalSurface);
        errdefer allocator.destroy(self);

        const cls = viewClass();
        const view = cls.msgSend(objc.Object, "alloc", .{})
            .msgSend(objc.Object, "initWithFrame:", .{frame});

        // Stash a raw pointer back to `self` on the Objective-C object so
        // our method overrides (keyDown:, setFrameSize:, ...) can recover
        // it. This ivar never holds a real retained object -- never treat
        // it as one.
        view.setInstanceVariable("vigilSelf", .{ .value = @ptrCast(self) });

        var cfg = ghc.ghostty_surface_config_new();
        cfg.platform_tag = ghc.GHOSTTY_PLATFORM_MACOS;
        cfg.platform = .{ .macos = .{ .nsview = view.value } };
        cfg.userdata = self;
        cfg.scale_factor = 2.0; // TODO(roadmap): query the real backing scale factor.
        cfg.font_size = 13;
        cfg.context = ghc.GHOSTTY_SURFACE_CONTEXT_WINDOW;

        const surface = ghc.ghostty_surface_new(app, &cfg) orelse
            return error.GhosttySurfaceNewFailed;

        self.* = .{ .view = view, .surface = surface };
        return self;
    }

    pub fn destroy(self: *TerminalSurface, allocator: std.mem.Allocator) void {
        ghc.ghostty_surface_free(self.surface);
        allocator.destroy(self);
    }

    fn viewClass() objc.Class {
        if (registered_class) |cls| return cls;

        const super = appkit.class("NSView");
        const cls = objc.allocateClassPair(super, "VigilTerminalView") orelse
            @panic("failed to register VigilTerminalView");
        _ = cls.addIvar("vigilSelf");

        std.debug.assert(cls.addMethod("acceptsFirstResponder", acceptsFirstResponder));
        std.debug.assert(cls.addMethod("keyDown:", keyDown));
        std.debug.assert(cls.addMethod("keyUp:", keyUp));
        std.debug.assert(cls.addMethod("setFrameSize:", setFrameSize));

        objc.registerClassPair(cls);
        registered_class = cls;
        return cls;
    }

    fn selfOf(id: objc.c.id) *TerminalSurface {
        const obj = objc.Object{ .value = id };
        const stored = obj.getInstanceVariable("vigilSelf");
        return @ptrCast(@alignCast(stored.value));
    }

    fn acceptsFirstResponder(id: objc.c.id, sel: objc.c.SEL) callconv(.c) bool {
        _ = id;
        _ = sel;
        return true;
    }

    fn setFrameSize(id: objc.c.id, sel: objc.c.SEL, size: appkit.NSSize) callconv(.c) void {
        const obj = objc.Object{ .value = id };
        const super_cls = appkit.class("NSView");
        obj.msgSendSuper(super_cls, void, objc.Sel{ .value = sel }, .{size});

        const self = selfOf(id);
        // TODO(roadmap): use the view's real backingScaleFactor instead of
        // the scale_factor assumption baked in at creation.
        const scale: f64 = 2.0;
        ghc.ghostty_surface_set_size(
            self.surface,
            @intFromFloat(size.width * scale),
            @intFromFloat(size.height * scale),
        );
    }

    fn keyDown(id: objc.c.id, sel: objc.c.SEL, event: objc.c.id) callconv(.c) void {
        _ = sel;
        handleKey(selfOf(id), .{ .value = event }, ghc.GHOSTTY_ACTION_PRESS);
    }

    fn keyUp(id: objc.c.id, sel: objc.c.SEL, event: objc.c.id) callconv(.c) void {
        _ = sel;
        handleKey(selfOf(id), .{ .value = event }, ghc.GHOSTTY_ACTION_RELEASE);
    }

    fn handleKey(self: *TerminalSurface, event: objc.Object, action: c_uint) void {
        const raw_mods = event.msgSend(u64, "modifierFlags", .{});

        var key_ev = std.mem.zeroes(ghc.ghostty_input_key_s);
        key_ev.action = action;
        key_ev.keycode = event.msgSend(u16, "keyCode", .{});
        key_ev.mods = ghosttyMods(raw_mods);
        key_ev.consumed_mods = ghosttyMods(
            raw_mods & ~(NSEventModifierFlagControl | NSEventModifierFlagCommand),
        );
        key_ev.unshifted_codepoint = unshiftedCodepoint(event);

        const text = eventText(event, raw_mods);
        if (text) |t| {
            const cstr = t.msgSend([*:0]const u8, "UTF8String", .{});
            key_ev.text = cstr;
            _ = ghc.ghostty_surface_key(self.surface, key_ev);
        } else {
            _ = ghc.ghostty_surface_key(self.surface, key_ev);
        }
    }

    fn ghosttyMods(raw: u64) c_uint {
        var mods: c_uint = ghc.GHOSTTY_MODS_NONE;
        if (raw & NSEventModifierFlagShift != 0) mods |= ghc.GHOSTTY_MODS_SHIFT;
        if (raw & NSEventModifierFlagControl != 0) mods |= ghc.GHOSTTY_MODS_CTRL;
        if (raw & NSEventModifierFlagOption != 0) mods |= ghc.GHOSTTY_MODS_ALT;
        if (raw & NSEventModifierFlagCommand != 0) mods |= ghc.GHOSTTY_MODS_SUPER;
        if (raw & NSEventModifierFlagCapsLock != 0) mods |= ghc.GHOSTTY_MODS_CAPS;
        return mods;
    }

    fn decodeFirstScalar(bytes: []const u8) ?u21 {
        if (bytes.len == 0) return null;
        const len = std.unicode.utf8ByteSequenceLength(bytes[0]) catch return null;
        if (len > bytes.len) return null;
        return std.unicode.utf8Decode(bytes[0..len]) catch null;
    }

    fn nsStringBytes(str: objc.Object) []const u8 {
        if (str.value == null) return &.{};
        const cstr = str.msgSend([*:0]const u8, "UTF8String", .{});
        return std.mem.sliceTo(cstr, 0);
    }

    fn unshiftedCodepoint(event: objc.Object) u32 {
        const plain = event.msgSend(objc.Object, "charactersByApplyingModifiers:", .{@as(u64, 0)});
        return decodeFirstScalar(nsStringBytes(plain)) orelse 0;
    }

    /// Mirrors NSEvent.ghosttyCharacters from the Swift app: strip control
    /// characters (ghostty encodes those itself from `mods`) and private-use
    /// glyphs (arrow/function keys -- those are driven by `keycode` instead).
    fn eventText(event: objc.Object, raw_mods: u64) ?objc.Object {
        const chars = event.msgSend(objc.Object, "characters", .{});
        const bytes = nsStringBytes(chars);
        if (bytes.len == 0) return null;

        if (decodeFirstScalar(bytes)) |cp| {
            if (bytes.len == std.unicode.utf8CodepointSequenceLength(cp) catch 0) {
                if (cp < 0x20) {
                    return event.msgSend(objc.Object, "charactersByApplyingModifiers:", .{
                        raw_mods & ~NSEventModifierFlagControl,
                    });
                }
                if (cp >= 0xF700 and cp <= 0xF8FF) return null;
            }
        }
        return chars;
    }
};
