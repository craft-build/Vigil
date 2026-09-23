//! The "runtime" side of libghostty's embedder API: the callbacks libghostty
//! calls into its host (us) for things it can't do itself (scheduling work on
//! the main thread, clipboard access, routing UI actions). Modeled directly
//! on macos/Sources/Ghostty/Ghostty.App.swift's `wakeup`/`action` wiring,
//! reimplemented against the C API instead of Swift.
const std = @import("std");
const c = @import("c.zig").c;

extern "c" var _dispatch_main_q: anyopaque;
extern "c" fn dispatch_async_f(
    queue: ?*anyopaque,
    context: ?*anyopaque,
    work: *const fn (?*anyopaque) callconv(.c) void,
) void;

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
        dispatch_async_f(&_dispatch_main_q, userdata, tickTrampoline);
    }

    fn tickTrampoline(userdata: ?*anyopaque) callconv(.c) void {
        const self: *App = @ptrCast(@alignCast(userdata orelse return));
        self.tick();
    }

    // TODO(roadmap): route actions (new_tab, close_tab, set_title, bell,
    // toggle_fullscreen, ...) into our own window/tab-bar state once
    // screens 02-06 exist. For this vertical slice we report every action
    // as unhandled; libghostty logs a warning and otherwise continues fine.
    fn action(
        app: c.ghostty_app_t,
        target: c.ghostty_target_s,
        act: c.ghostty_action_s,
    ) callconv(.c) bool {
        _ = app;
        _ = target;
        _ = act;
        return false;
    }

    fn readClipboard(
        userdata: ?*anyopaque,
        location: c.ghostty_clipboard_e,
        state: ?*anyopaque,
        mimes: [*c]const [*c]const u8,
        mimes_len: usize,
        immediate: bool,
    ) callconv(.c) c.ghostty_clipboard_read_result_e {
        _ = userdata;
        _ = location;
        _ = state;
        _ = mimes;
        _ = mimes_len;
        _ = immediate;
        // TODO(roadmap): bridge to NSPasteboard.
        return c.GHOSTTY_CLIPBOARD_READ_UNAVAILABLE;
    }

    fn confirmReadClipboard(
        userdata: ?*anyopaque,
        confirm: [*c]const c.ghostty_clipboard_confirm_s,
        state: ?*anyopaque,
        request: c.ghostty_clipboard_request_e,
    ) callconv(.c) void {
        _ = userdata;
        _ = confirm;
        _ = state;
        _ = request;
    }

    fn writeClipboard(
        userdata: ?*anyopaque,
        location: c.ghostty_clipboard_e,
        content: [*c]const c.ghostty_clipboard_content_s,
        content_len: usize,
        confirm: bool,
    ) callconv(.c) void {
        _ = userdata;
        _ = location;
        _ = content;
        _ = content_len;
        _ = confirm;
        // TODO(roadmap): bridge to NSPasteboard.
    }

    fn closeSurface(userdata: ?*anyopaque, process_alive: bool) callconv(.c) void {
        _ = userdata;
        _ = process_alive;
        // TODO(roadmap): close the owning window/tab once we have >1 surface.
    }
};
