//! The "runtime" side of libghostty's embedder API: the callbacks libghostty
//! calls into its host (us) for things it can't do itself (scheduling work on
//! the main thread, clipboard access, routing UI actions). Modeled directly
//! on macos/Sources/Ghostty/Ghostty.App.swift's `wakeup`/`action` wiring,
//! reimplemented against the C API instead of Swift.
const std = @import("std");
const c = @import("c.zig").c;
const clipboard = @import("../app/clipboard.zig");
const TerminalSurface = @import("../app/TerminalSurface.zig").TerminalSurface;
const Window = @import("../app/Window.zig").Window;
const gcd = @import("../gcd.zig");

pub const App = struct {
    app: c.ghostty_app_t = null,

    pub fn init(self: *App, config: c.ghostty_config_t) !void {
        var runtime_cfg = c.ghostty_runtime_config_s{
            .userdata = self,
            .supports_selection_clipboard = false,
            .wakeup_cb = wakeup,
            .action_cb = action,
            .read_clipboard_cb = readClipboard,
            .confirm_read_clipboard_cb = confirmReadClipboard,
            .write_clipboard_cb = writeClipboard,
            .close_surface_cb = closeSurface,
        };

        self.app = c.ghostty_app_new(&runtime_cfg, config) orelse
            return error.GhosttyAppNewFailed;
    }

    pub fn deinit(self: *App) void {
        if (self.app) |app| c.ghostty_app_free(app);
        self.app = null;
    }

    pub fn tick(self: *App) void {
        if (self.app) |app| c.ghostty_app_tick(app);
    }

    fn wakeup(userdata: ?*anyopaque) callconv(.c) void {
        // May be called from any thread (a PTY read thread, a renderer
        // thread, ...). ghostty_app_tick must run on the main thread, so we
        // hop over via GCD exactly like the Swift app does.
        gcd.dispatch_async_f(&gcd._dispatch_main_q, userdata, tickTrampoline);
    }

    fn tickTrampoline(userdata: ?*anyopaque) callconv(.c) void {
        const self: *App = @ptrCast(@alignCast(userdata orelse return));
        self.tick();
    }

    /// Tab/window actions are routed into `Window`; anything else is
    /// reported unhandled, which libghostty tolerates.
    fn action(
        app: c.ghostty_app_t,
        target: c.ghostty_target_s,
        act: c.ghostty_action_s,
    ) callconv(.c) bool {
        _ = app;
        const window = resolveWindow(target) orelse return false;
        return window.handleAction(target, act);
    }

    /// More than one `Window` can exist now, so an action naming a specific
    /// surface is routed to that surface's own window; anything else (no
    /// surface target -- app-wide actions) falls back to whichever window
    /// is currently key.
    fn resolveWindow(target: c.ghostty_target_s) ?*Window {
        if (target.tag == c.GHOSTTY_TARGET_SURFACE) {
            if (TerminalSurface.fromHandle(target.target.surface)) |ts| {
                if (ts.owner) |owner| return @ptrCast(@alignCast(owner));
            }
        }
        return Window.keyWindow();
    }

    /// Legality hinges on two invariants, both documented in
    /// vendor/ghostty's embedded API (embedded.zig / c.zig); if either
    /// changes, this must be refactored (dupe + async completion), not
    /// patched:
    /// 1. `ghostty_surface_complete_clipboard_request` must be called
    ///    synchronously from within the read callback on the main thread
    ///    (we return STARTED only after it completes).
    /// 2. The clipboard text is only *borrowed* for the duration of that
    ///    complete call, so `text` never needs to outlive this function.
    fn readClipboard(
        userdata: ?*anyopaque,
        location: c.ghostty_clipboard_e,
        state: ?*anyopaque,
        mimes: [*c]const [*c]const u8,
        mimes_len: usize,
        immediate: bool,
    ) callconv(.c) c.ghostty_clipboard_read_result_e {
        _ = mimes;
        _ = mimes_len;
        _ = immediate;
        if (location != c.GHOSTTY_CLIPBOARD_STANDARD) return c.GHOSTTY_CLIPBOARD_READ_UNAVAILABLE;
        const surface = surfaceOf(userdata) orelse return c.GHOSTTY_CLIPBOARD_READ_UNAVAILABLE;
        const text = clipboard.readText() orelse return c.GHOSTTY_CLIPBOARD_READ_UNAVAILABLE;

        const content = c.ghostty_clipboard_content_s{
            .mime = "text/plain",
            .data = text,
            .len = std.mem.len(text),
        };
        const complete = c.ghostty_clipboard_complete_s{
            .contents = &content,
            .contents_len = 1,
            .available = null,
            .available_len = 0,
            .confirmed = false,
            .remember = false,
        };
        c.ghostty_surface_complete_clipboard_request(surface, &complete, state);
        return c.GHOSTTY_CLIPBOARD_READ_STARTED;
    }

    /// libghostty asks for confirmation on unsafe pastes and on OSC 52 /
    /// kitty clipboard access. Plain pastes are user-initiated, so approve
    /// them; deny program-initiated clipboard access until there is a
    /// prompt UI for it.
    fn confirmReadClipboard(
        userdata: ?*anyopaque,
        confirm: [*c]const c.ghostty_clipboard_confirm_s,
        state: ?*anyopaque,
        request: c.ghostty_clipboard_request_e,
    ) callconv(.c) void {
        const surface = surfaceOf(userdata) orelse return;
        if (request != c.GHOSTTY_CLIPBOARD_REQUEST_PASTE or confirm == null) {
            c.ghostty_surface_deny_clipboard_request(surface, state);
            return;
        }
        const complete = c.ghostty_clipboard_complete_s{
            .contents = confirm.*.contents,
            .contents_len = confirm.*.contents_len,
            .available = confirm.*.available,
            .available_len = confirm.*.available_len,
            .confirmed = true,
            .remember = false,
        };
        c.ghostty_surface_complete_clipboard_request(surface, &complete, state);
    }

    fn writeClipboard(
        userdata: ?*anyopaque,
        location: c.ghostty_clipboard_e,
        content: [*c]const c.ghostty_clipboard_content_s,
        content_len: usize,
        confirm: bool,
    ) callconv(.c) void {
        _ = userdata;
        _ = confirm;
        if (location != c.GHOSTTY_CLIPBOARD_STANDARD or content == null) return;
        for (content[0..content_len]) |item| {
            const mime = std.mem.span(item.mime orelse continue);
            if (!std.mem.eql(u8, mime, "text/plain")) continue;
            if (item.data == null) continue;
            clipboard.writeText(item.data[0..item.len]);
            return;
        }
    }

    /// The surface's shell exited (or it was closed): drop its pane (and,
    /// if it was the tab's only one, the whole tab).
    fn closeSurface(userdata: ?*anyopaque, process_alive: bool) callconv(.c) void {
        _ = process_alive; // TODO(roadmap): confirm before closing a live process.
        const ts: *TerminalSurface = @ptrCast(@alignCast(userdata orelse return));
        const window: *Window = @ptrCast(@alignCast(ts.owner orelse return));
        window.closePane(ts);
    }

    /// Surface-scoped callbacks receive the `userdata` set on the surface
    /// config, which is our `*TerminalSurface`.
    fn surfaceOf(userdata: ?*anyopaque) ?c.ghostty_surface_t {
        const ts: *TerminalSurface = @ptrCast(@alignCast(userdata orelse return null));
        return ts.surface;
    }
};
