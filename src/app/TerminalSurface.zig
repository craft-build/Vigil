//! Wraps one ghostty_surface_t bound to a plain NSView. libghostty itself
//! makes the view layer-backed and attaches its own CAMetalLayer + Metal
//! renderer the moment ghostty_surface_new() is called with the view's
//! pointer -- confirmed by vendor/ghostty's Swift SurfaceView_AppKit.swift,
//! which never touches CALayer/CAMetalLayer itself. Our job is just: give it
//! a view, and forward keyboard input + resize/focus notifications.
//!
//! IME (marked text/preedit) is not implemented yet -- see the roadmap in the
//! project plan. Typed text (including Ctrl-chars), non-text keys (arrows,
//! enter, backspace, function keys), mouse buttons/motion and scrolling are
//! forwarded.
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
    /// The frame `Window`'s pane layout last placed this surface at, in the
    /// content view's coordinate space. Used for geometric pane navigation
    /// (`goto_split up/down/left/right`) and to size a freshly-split
    /// sibling before its own first layout pass. Meaningless until the
    /// first layout after creation sets it for real.
    last_frame: appkit.NSRect = std.mem.zeroes(appkit.NSRect),

    var registered_class: ?objc.Class = null;

    /// `app` must already be initialized. `frame` is the view's initial
    /// frame in points; the caller adds the returned view to the window's
    /// view hierarchy. `inherit` is an existing surface whose settings
    /// (font size, working directory) the new tab starts from.
    pub fn create(
        allocator: std.mem.Allocator,
        app: ghc.ghostty_app_t,
        frame: appkit.NSRect,
        inherit: ?ghc.ghostty_surface_t,
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

        var cfg = if (inherit) |from|
            ghc.ghostty_surface_inherited_config(from, ghc.GHOSTTY_SURFACE_CONTEXT_TAB)
        else blk: {
            var fresh = ghc.ghostty_surface_config_new();
            fresh.font_size = 13;
            fresh.context = ghc.GHOSTTY_SURFACE_CONTEXT_WINDOW;
            break :blk fresh;
        };
        cfg.platform_tag = ghc.GHOSTTY_PLATFORM_MACOS;
        cfg.platform = .{ .macos = .{ .nsview = view.value } };
        cfg.userdata = self;
        cfg.scale_factor = backingScale(view);

        const surface = ghc.ghostty_surface_new(app, &cfg) orelse
            return error.GhosttySurfaceNewFailed;

        self.* = .{ .view = view, .surface = surface, .last_frame = frame };
        return self;
    }

    /// Recovers the TerminalSurface from a libghostty surface handle
    /// (via the `userdata` set at creation).
    pub fn fromHandle(handle: ghc.ghostty_surface_t) ?*TerminalSurface {
        const ud = ghc.ghostty_surface_userdata(handle) orelse return null;
        return @ptrCast(@alignCast(ud));
    }

    /// Shows or hides the tab's view and tells libghostty so it can pause
    /// rendering for hidden tabs.
    pub fn setVisible(self: *TerminalSurface, visible: bool) void {
        self.view.msgSend(void, "setHidden:", .{!visible});
        ghc.ghostty_surface_set_occlusion(self.surface, visible);
        ghc.ghostty_surface_set_focus(self.surface, visible);
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
        std.debug.assert(cls.addMethod("viewDidChangeBackingProperties", viewDidChangeBackingProperties));
        std.debug.assert(cls.addMethod("updateTrackingAreas", updateTrackingAreas));
        std.debug.assert(cls.addMethod("mouseDown:", mouseDown));
        std.debug.assert(cls.addMethod("mouseUp:", mouseUp));
        std.debug.assert(cls.addMethod("rightMouseDown:", rightMouseDown));
        std.debug.assert(cls.addMethod("rightMouseUp:", rightMouseUp));
        std.debug.assert(cls.addMethod("otherMouseDown:", otherMouseDown));
        std.debug.assert(cls.addMethod("otherMouseUp:", otherMouseUp));
        std.debug.assert(cls.addMethod("mouseMoved:", mouseMoved));
        std.debug.assert(cls.addMethod("mouseDragged:", mouseMoved));
        std.debug.assert(cls.addMethod("rightMouseDragged:", mouseMoved));
        std.debug.assert(cls.addMethod("otherMouseDragged:", mouseMoved));
        std.debug.assert(cls.addMethod("scrollWheel:", scrollWheel));

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

    /// The view's window scale when attached, else the main screen's --
    /// covers creation time, before the view is in a window.
    fn backingScale(view: objc.Object) f64 {
        const window = view.msgSend(objc.Object, "window", .{});
        if (window.value != null) return window.msgSend(f64, "backingScaleFactor", .{});
        const screen = appkit.class("NSScreen").msgSend(objc.Object, "mainScreen", .{});
        if (screen.value != null) return screen.msgSend(f64, "backingScaleFactor", .{});
        return 2.0;
    }

    fn syncSize(self: *TerminalSurface) void {
        const scale = backingScale(self.view);
        const size = self.view.msgSend(appkit.NSRect, "bounds", .{}).size;
        ghc.ghostty_surface_set_content_scale(self.surface, scale, scale);
        ghc.ghostty_surface_set_size(
            self.surface,
            @intFromFloat(size.width * scale),
            @intFromFloat(size.height * scale),
        );
    }

    fn setFrameSize(id: objc.c.id, sel: objc.c.SEL, size: appkit.NSSize) callconv(.c) void {
        const obj = objc.Object{ .value = id };
        const super_cls = appkit.class("NSView");
        obj.msgSendSuper(super_cls, void, objc.Sel{ .value = sel }, .{size});
        syncSize(selfOf(id));
    }

    fn viewDidChangeBackingProperties(id: objc.c.id, sel: objc.c.SEL) callconv(.c) void {
        const obj = objc.Object{ .value = id };
        obj.msgSendSuper(appkit.class("NSView"), void, objc.Sel{ .value = sel }, .{});
        syncSize(selfOf(id));
    }

    /// One tracking area covering the visible rect so `mouseMoved:` fires
    /// (needed for mouse-reporting apps and hover) without a button held.
    fn updateTrackingAreas(id: objc.c.id, sel: objc.c.SEL) callconv(.c) void {
        const obj = objc.Object{ .value = id };
        obj.msgSendSuper(appkit.class("NSView"), void, objc.Sel{ .value = sel }, .{});

        const existing = obj.msgSend(objc.Object, "trackingAreas", .{});
        const count = existing.msgSend(u64, "count", .{});
        var i: u64 = count;
        while (i > 0) : (i -= 1) {
            obj.msgSend(void, "removeTrackingArea:", .{
                existing.msgSend(objc.Object, "objectAtIndex:", .{i - 1}),
            });
        }

        const mouse_moved: u64 = 0x02;
        const active_in_key_window: u64 = 0x20;
        const in_visible_rect: u64 = 0x200;
        const area = appkit.class("NSTrackingArea")
            .msgSend(objc.Object, "alloc", .{})
            .msgSend(objc.Object, "initWithRect:options:owner:userInfo:", .{
            appkit.rect(0, 0, 0, 0),
            mouse_moved | active_in_key_window | in_visible_rect,
            obj,
            @as(?*anyopaque, null),
        });
        obj.msgSend(void, "addTrackingArea:", .{area});
        area.msgSend(void, "release", .{});
    }

    /// Fired on every mouse-down (any button) so `Window` can move pane
    /// focus to whichever split the user actually clicked in.
    pub var on_click: ?*const fn (*TerminalSurface) void = null;

    fn mouseButton(id: objc.c.id, event: objc.c.id, state: c_uint, button: c_uint) void {
        const self = selfOf(id);
        if (state == ghc.GHOSTTY_MOUSE_PRESS) {
            if (on_click) |cb| cb(self);
        }
        const ev = objc.Object{ .value = event };
        const mods = ghosttyMods(ev.msgSend(u64, "modifierFlags", .{}));
        // Update the position first so the click lands where the cursor is.
        sendPos(self, ev);
        _ = ghc.ghostty_surface_mouse_button(self.surface, state, button, mods);
    }

    fn mouseDown(id: objc.c.id, sel: objc.c.SEL, event: objc.c.id) callconv(.c) void {
        _ = sel;
        mouseButton(id, event, ghc.GHOSTTY_MOUSE_PRESS, ghc.GHOSTTY_MOUSE_LEFT);
    }
    fn mouseUp(id: objc.c.id, sel: objc.c.SEL, event: objc.c.id) callconv(.c) void {
        _ = sel;
        mouseButton(id, event, ghc.GHOSTTY_MOUSE_RELEASE, ghc.GHOSTTY_MOUSE_LEFT);
    }
    fn rightMouseDown(id: objc.c.id, sel: objc.c.SEL, event: objc.c.id) callconv(.c) void {
        _ = sel;
        mouseButton(id, event, ghc.GHOSTTY_MOUSE_PRESS, ghc.GHOSTTY_MOUSE_RIGHT);
    }
    fn rightMouseUp(id: objc.c.id, sel: objc.c.SEL, event: objc.c.id) callconv(.c) void {
        _ = sel;
        mouseButton(id, event, ghc.GHOSTTY_MOUSE_RELEASE, ghc.GHOSTTY_MOUSE_RIGHT);
    }
    fn otherMouseDown(id: objc.c.id, sel: objc.c.SEL, event: objc.c.id) callconv(.c) void {
        _ = sel;
        mouseButton(id, event, ghc.GHOSTTY_MOUSE_PRESS, ghc.GHOSTTY_MOUSE_MIDDLE);
    }
    fn otherMouseUp(id: objc.c.id, sel: objc.c.SEL, event: objc.c.id) callconv(.c) void {
        _ = sel;
        mouseButton(id, event, ghc.GHOSTTY_MOUSE_RELEASE, ghc.GHOSTTY_MOUSE_MIDDLE);
    }

    fn mouseMoved(id: objc.c.id, sel: objc.c.SEL, event: objc.c.id) callconv(.c) void {
        _ = sel;
        sendPos(selfOf(id), .{ .value = event });
    }

    /// Ghostty wants view-local points with a top-left origin; AppKit's
    /// origin is bottom-left.
    fn sendPos(self: *TerminalSurface, event: objc.Object) void {
        const window_pt = event.msgSend(appkit.NSPoint, "locationInWindow", .{});
        const pt = self.view.msgSend(appkit.NSPoint, "convertPoint:fromView:", .{
            window_pt, @as(?*anyopaque, null),
        });
        const height = self.view.msgSend(appkit.NSRect, "bounds", .{}).size.height;
        const mods = ghosttyMods(event.msgSend(u64, "modifierFlags", .{}));
        ghc.ghostty_surface_mouse_pos(self.surface, pt.x, height - pt.y, mods);
    }

    fn scrollWheel(id: objc.c.id, sel: objc.c.SEL, event: objc.c.id) callconv(.c) void {
        _ = sel;
        const self = selfOf(id);
        const ev = objc.Object{ .value = event };

        var x = ev.msgSend(f64, "scrollingDeltaX", .{});
        var y = ev.msgSend(f64, "scrollingDeltaY", .{});
        const precise = ev.msgSend(bool, "hasPreciseScrollingDeltas", .{});
        if (precise) {
            // Same 2x feel multiplier as Ghostty's own macOS app.
            x *= 2;
            y *= 2;
        }

        // ghostty_input_scroll_mods_t: bit 0 = precision, bits 1-3 = momentum.
        // NSEventPhase is a one-hot bitmask; ghostty's momentum enum is the
        // 1-based index of that bit (began=1 .. mayBegin=6).
        const phase = ev.msgSend(u64, "momentumPhase", .{});
        const momentum: c_int = if (phase == 0) 0 else @as(c_int, @intCast(@ctz(phase))) + 1;
        const scroll_mods: c_int = @intFromBool(precise) | (momentum << 1);
        ghc.ghostty_surface_mouse_scroll(self.surface, x, y, scroll_mods);
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
