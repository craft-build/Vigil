//! Wraps one ghostty_surface_t bound to a plain NSView. libghostty itself
//! makes the view layer-backed and attaches its own CAMetalLayer + Metal
//! renderer the moment ghostty_surface_new() is called with the view's
//! pointer -- confirmed by vendor/ghostty's Swift SurfaceView_AppKit.swift,
//! which never creates the layer itself. It does, however, keep the layer's
//! `contentsScale` in step with the window's backing scale (see its
//! `viewDidChangeBackingProperties`); we mirror that here so moving the
//! window between displays of different DPI doesn't leave Core Animation
//! compositing the surface at the old scale. Our job is otherwise: give it a
//! view, and forward keyboard input + resize/focus notifications.
//!
//! IME (marked text/preedit) is not implemented yet -- see the roadmap in the
//! project plan. Typed text (including Ctrl-chars), non-text keys (arrows,
//! enter, backspace, function keys), mouse buttons/motion and scrolling are
//! forwarded.
const std = @import("std");
const objc = @import("objc");
const ghc = @import("../ghostty/c.zig").c;
const appkit = @import("appkit.zig");
const gcd = @import("../gcd.zig");

const NSEventModifierFlagCapsLock: u64 = 1 << 16;
const NSEventModifierFlagShift: u64 = 1 << 17;
const NSEventModifierFlagControl: u64 = 1 << 18;
const NSEventModifierFlagOption: u64 = 1 << 19;
const NSEventModifierFlagCommand: u64 = 1 << 20;

pub const TerminalSurface = struct {
    /// The allocator this surface was created with; `destroy` frees with the
    /// same one rather than assuming a particular global.
    allocator: std.mem.Allocator,
    view: objc.Object,
    surface: ghc.ghostty_surface_t,
    /// The frame `Window`'s pane layout last placed this surface at, in the
    /// content view's coordinate space. Used for geometric pane navigation
    /// (`goto_split up/down/left/right`) and to size a freshly-split
    /// sibling before its own first layout pass. Meaningless until the
    /// first layout after creation sets it for real.
    last_frame: appkit.NSRect = std.mem.zeroes(appkit.NSRect),
    /// The `*Window` this surface belongs to, as an opaque pointer so this
    /// file doesn't need to import `Window.zig` (which imports this file) --
    /// every reader casts it back with the type it already knows. Set by
    /// `Window.newTab`/`newSplit` right after `create` returns; used to
    /// route libghostty's per-surface callbacks (click, close, actions) to
    /// the right window now that more than one can exist.
    owner: ?*anyopaque = null,

    var registered_class: ?objc.Class = null;

    /// `app` must already be initialized. `frame` is the view's initial
    /// frame in points; the caller adds the returned view to the window's
    /// view hierarchy. `inherit` is an existing surface whose settings
    /// (font size, working directory) the new tab starts from. `owner` is
    /// the `*Window` this surface belongs to (opaque here -- see the
    /// `owner` field's doc comment).
    pub fn create(
        allocator: std.mem.Allocator,
        app: ghc.ghostty_app_t,
        frame: appkit.NSRect,
        inherit: ?ghc.ghostty_surface_t,
        owner: ?*anyopaque,
    ) !*TerminalSurface {
        const self = try allocator.create(TerminalSurface);
        errdefer allocator.destroy(self);
        // Set before `ghostty_surface_new` below, not after: libghostty can
        // reenter our action/clipboard callbacks with this surface's
        // `userdata` before that call even returns (e.g. `Window.newTab`'s
        // very first surface, mid-construction of both the surface and its
        // window) -- see `handleAction`'s "actions can arrive mid-creation"
        // comment. Those callbacks resolve their `*Window` from `.owner`,
        // so it has to be valid already; the rest of `self` isn't read by
        // them and can be filled in once `ghostty_surface_new` succeeds.
        self.owner = owner;

        const cls = viewClass();
        const view = cls.msgSend(objc.Object, "alloc", .{})
            .msgSend(objc.Object, "initWithFrame:", .{frame});
        // Never added to any superview on the failure path, so this plain
        // release deallocs it; on success `destroy` holds the pairing.
        errdefer view.msgSend(void, "release", .{});

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

        self.* = .{ .allocator = allocator, .view = view, .surface = surface, .last_frame = frame, .owner = owner };

        // A window that merely moves between screens doesn't reliably get a
        // `viewDidChangeBackingProperties` (Ghostty issue #2731), so watch for
        // the screen change and re-sync the backing explicitly. The same
        // notification carries the screen whose display ID libghostty wants
        // (for vsync / refresh-rate matching). Become/resign-key are watched
        // so libghostty's notion of focus tracks the window, not just which
        // pane is first responder.
        observe(view, "windowDidChangeScreen:", "NSWindowDidChangeScreenNotification");
        observe(view, "windowDidBecomeKey:", "NSWindowDidBecomeKeyNotification");
        observe(view, "windowDidResignKey:", "NSWindowDidResignKeyNotification");
        return self;
    }

    fn observe(view: objc.Object, selector: [:0]const u8, name: [:0]const u8) void {
        appkit.class("NSNotificationCenter")
            .msgSend(objc.Object, "defaultCenter", .{})
            .msgSend(void, "addObserver:selector:name:object:", .{
            view,
            objc.sel(selector),
            appkit.nsString(name),
            @as(?*anyopaque, null),
        });
    }

    /// Recovers the TerminalSurface from a libghostty surface handle
    /// (via the `userdata` set at creation).
    pub fn fromHandle(handle: ghc.ghostty_surface_t) ?*TerminalSurface {
        const ud = ghc.ghostty_surface_userdata(handle) orelse return null;
        return @ptrCast(@alignCast(ud));
    }

    /// Shows or hides the tab's view and tells libghostty so it can pause
    /// rendering for hidden tabs. Keyboard focus is *not* decided here:
    /// `syncFocus` derives it from the window's key state and first responder
    /// (see `becomeFirstResponder`/`resignFirstResponder` and the key
    /// notifications), so a visible tab in a background window isn't reported
    /// as focused.
    pub fn setVisible(self: *TerminalSurface, visible: bool) void {
        self.view.msgSend(void, "setHidden:", .{!visible});
        ghc.ghostty_surface_set_occlusion(self.surface, visible);
    }

    /// The view is always removed from its superview (by `detachLeaf` or
    /// `closePane`) before `destroy` runs -- `destroy` is only ever invoked
    /// via the deferred `freeSurface` dispatch or an error path after a
    /// positioned-add -- so releasing the alloc-time +1 here is the final
    /// release and deallocs it.
    pub fn destroy(self: *TerminalSurface) void {
        // The center holds the view unretained; drop the registration before
        // the final release so a late screen-change notification can't be
        // delivered to a dangling object.
        appkit.class("NSNotificationCenter")
            .msgSend(objc.Object, "defaultCenter", .{})
            .msgSend(void, "removeObserver:", .{self.view});
        ghc.ghostty_surface_free(self.surface);
        self.view.msgSend(void, "release", .{});
        self.allocator.destroy(self);
    }

    fn viewClass() objc.Class {
        if (registered_class) |cls| return cls;

        const super = appkit.class("NSView");
        const cls = objc.allocateClassPair(super, "VigilTerminalView") orelse
            @panic("failed to register VigilTerminalView");
        _ = cls.addIvar("vigilSelf");

        std.debug.assert(cls.addMethod("acceptsFirstResponder", acceptsFirstResponder));
        std.debug.assert(cls.addMethod("becomeFirstResponder", becomeFirstResponder));
        std.debug.assert(cls.addMethod("resignFirstResponder", resignFirstResponder));
        std.debug.assert(cls.addMethod("keyDown:", keyDown));
        std.debug.assert(cls.addMethod("keyUp:", keyUp));
        std.debug.assert(cls.addMethod("setFrameSize:", setFrameSize));
        std.debug.assert(cls.addMethod("viewDidChangeBackingProperties", viewDidChangeBackingProperties));
        std.debug.assert(cls.addMethod("windowDidChangeScreen:", windowDidChangeScreen));
        std.debug.assert(cls.addMethod("windowDidBecomeKey:", windowDidBecomeKey));
        std.debug.assert(cls.addMethod("windowDidResignKey:", windowDidResignKey));
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

    fn becomeFirstResponder(id: objc.c.id, sel: objc.c.SEL) callconv(.c) bool {
        const obj = objc.Object{ .value = id };
        const result = obj.msgSendSuper(appkit.class("NSView"), bool, objc.Sel{ .value = sel }, .{});
        if (result) syncFocus(selfOf(id));
        return result;
    }

    /// Force focus off on resignation. `syncFocus` can't be used here: AppKit
    /// still reports this view as the window's first responder while
    /// `resignFirstResponder` runs, so it would re-report focus as on.
    fn resignFirstResponder(id: objc.c.id, sel: objc.c.SEL) callconv(.c) bool {
        const obj = objc.Object{ .value = id };
        const result = obj.msgSendSuper(appkit.class("NSView"), bool, objc.Sel{ .value = sel }, .{});
        if (result) ghc.ghostty_surface_set_focus(selfOf(id).surface, false);
        return result;
    }

    /// Tells libghostty this surface has keyboard focus only when its window
    /// is actually key and this view is the window's first responder (which
    /// it is while editing a rename field, for instance, so the terminal is
    /// correctly *not* focused then).
    fn syncFocus(self: *TerminalSurface) void {
        const window = self.view.msgSend(objc.Object, "window", .{});
        var focused = false;
        if (window.value != null) {
            const first = window.msgSend(objc.Object, "firstResponder", .{});
            focused = window.msgSend(bool, "isKeyWindow", .{}) and first.value == self.view.value;
        }
        ghc.ghostty_surface_set_focus(self.surface, focused);
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
        const bounds = self.view.msgSend(appkit.NSRect, "bounds", .{});
        // Once attached, derive the scale from the actual backing rect -- it
        // reflects the window's current screen, so it can't disagree with the
        // size we send. Before attachment (mid-construction) there is no
        // window to ask; fall back to the screen scale as before.
        const window = self.view.msgSend(objc.Object, "window", .{});
        if (window.value != null) {
            const backing = self.view.msgSend(appkit.NSRect, "convertRectToBacking:", .{bounds});
            const x_scale = if (bounds.size.width > 0) backing.size.width / bounds.size.width else 1;
            const y_scale = if (bounds.size.height > 0) backing.size.height / bounds.size.height else 1;
            ghc.ghostty_surface_set_content_scale(self.surface, x_scale, y_scale);
            ghc.ghostty_surface_set_size(
                self.surface,
                @intFromFloat(@max(backing.size.width, 1)),
                @intFromFloat(@max(backing.size.height, 1)),
            );
            return;
        }
        const scale = backingScale(self.view);
        ghc.ghostty_surface_set_content_scale(self.surface, scale, scale);
        ghc.ghostty_surface_set_size(
            self.surface,
            @intFromFloat(@max(bounds.size.width * scale, 1)),
            @intFromFloat(@max(bounds.size.height * scale, 1)),
        );
    }

    fn setFrameSize(id: objc.c.id, sel: objc.c.SEL, size: appkit.NSSize) callconv(.c) void {
        const obj = objc.Object{ .value = id };
        const super_cls = appkit.class("NSView");
        obj.msgSendSuper(super_cls, void, objc.Sel{ .value = sel }, .{size});
        syncSize(selfOf(id));
    }

    /// Keeps the surface's render scale in step with the window's backing
    /// scale. Core Animation composites a layer using its `contentsScale`;
    /// left at the old display's value, the Metal contents get scaled by the
    /// compositor and the terminal appears blown up or shrunk. libghostty
    /// manages the rendering resolution, so the layer scale is ours to set.
    fn updateBacking(self: *TerminalSurface) void {
        const window = self.view.msgSend(objc.Object, "window", .{});
        if (window.value != null) {
            setLayerContentsScale(self.view, window.msgSend(f64, "backingScaleFactor", .{}));
        }
        syncSize(self);
    }

    fn setLayerContentsScale(view: objc.Object, scale: f64) void {
        const layer = view.msgSend(objc.Object, "layer", .{});
        if (layer.value == null) return;
        const transaction = objc.getClass("CATransaction") orelse return;
        transaction.msgSend(void, "begin", .{});
        // Disable the implicit contentsScale animation; it looks like a
        // jarring zoom of the terminal contents.
        transaction.msgSend(void, "setDisableActions:", .{true});
        layer.msgSend(void, "setContentsScale:", .{scale});
        transaction.msgSend(void, "commit", .{});
    }

    fn viewDidChangeBackingProperties(id: objc.c.id, sel: objc.c.SEL) callconv(.c) void {
        const obj = objc.Object{ .value = id };
        obj.msgSendSuper(appkit.class("NSView"), void, objc.Sel{ .value = sel }, .{});
        updateBacking(selfOf(id));
    }

    /// A window that only moves screens may not get a backing-properties
    /// change (Ghostty issue #2731), so re-sync from the screen notification
    /// too. Deferred to the next main-queue turn: AppKit hasn't necessarily
    /// installed the new screen's backing scale by the time the notification
    /// fires.
    fn windowDidChangeScreen(id: objc.c.id, _: objc.c.SEL, note: objc.c.id) callconv(.c) void {
        const self = selfOf(id);
        const window = self.view.msgSend(objc.Object, "window", .{});
        if (window.value == null) return;
        if ((objc.Object{ .value = note }).msgSend(objc.Object, "object", .{}).value != window.value) return;

        const screen = window.msgSend(objc.Object, "screen", .{});
        if (screen.value != null) ghc.ghostty_surface_set_display_id(self.surface, displayId(screen));
        gcd.dispatch_async_f(&gcd._dispatch_main_q, self, resyncBacking);
    }

    /// The window's first responder doesn't change when the window gains or
    /// loses key, so become/resign-first-responder alone can't track app
    /// activation -- these notifications close that gap.
    fn windowDidBecomeKey(id: objc.c.id, _: objc.c.SEL, note: objc.c.id) callconv(.c) void {
        const self = selfOf(id);
        if (notificationWindow(note, self.view)) syncFocus(self);
    }

    fn windowDidResignKey(id: objc.c.id, _: objc.c.SEL, note: objc.c.id) callconv(.c) void {
        const self = selfOf(id);
        if (notificationWindow(note, self.view)) ghc.ghostty_surface_set_focus(self.surface, false);
    }

    /// True when `note` was posted by `view`'s own window (observers are
    /// registered with a nil object, so every surface sees every window's
    /// notifications).
    fn notificationWindow(note: objc.c.id, view: objc.Object) bool {
        const window = view.msgSend(objc.Object, "window", .{});
        if (window.value == null) return false;
        return (objc.Object{ .value = note }).msgSend(objc.Object, "object", .{}).value == window.value;
    }

    fn resyncBacking(ctx: ?*anyopaque) callconv(.c) void {
        const self: *TerminalSurface = @ptrCast(@alignCast(ctx orelse return));
        updateBacking(self);
    }

    /// `NSScreen`'s CoreGraphics display ID: `deviceDescription[NSScreenNumber]`.
    fn displayId(screen: objc.Object) u32 {
        const desc = screen.msgSend(objc.Object, "deviceDescription", .{});
        if (desc.value == null) return 0;
        const number = desc.msgSend(objc.Object, "objectForKey:", .{appkit.nsString("NSScreenNumber")});
        if (number.value == null) return 0;
        return number.msgSend(u32, "unsignedIntValue", .{});
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
