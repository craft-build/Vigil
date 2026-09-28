//! The two Grand Central Dispatch entry points Vigil needs to bounce work
//! onto the main queue: libghostty's `wakeup` hop (`ghostty/runtime.zig`)
//! and `Window`'s deferred surface teardown. These are the only C
//! signatures in the project that aren't @cImport-verified, so they are
//! declared in exactly one place.
pub extern "c" var _dispatch_main_q: anyopaque;
pub extern "c" fn dispatch_async_f(
    queue: ?*anyopaque,
    context: ?*anyopaque,
    work: *const fn (?*anyopaque) callconv(.c) void,
) void;
