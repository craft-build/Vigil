//! Vigil's own config layer. libghostty has no "load config from a string"
//! call, so Vigil-owned settings (theme now; preferences later) live in a
//! real file in ghostty's `key = value` syntax at
//! `~/Library/Application Support/Vigil/config`, loaded *after* the user's
//! own Ghostty config so Vigil's choices win. Changing a setting rewrites
//! that file, builds a fresh config, and pushes it to every surface with
//! `ghostty_app_update_config`.
//!
//! Configs handed to libghostty are deliberately never freed: libghostty
//! owns its own copies, but the lifetime rules for the app-level pointer
//! aren't documented, and the leak is a few KB per settings change.
const std = @import("std");
const ghc = @import("../ghostty/c.zig").c;
const keybindings = @import("keybindings.zig");

const log = std.log.scoped(.settings);
const allocator = std.heap.c_allocator;

pub const Entry = struct {
    key: []u8,
    value: []u8,
};

/// Ordered `key = value` lines. Keys may repeat (`palette` does).
pub const Store = struct {
    entries: std.ArrayList(Entry) = .empty,

    pub fn deinit(self: *Store, alloc: std.mem.Allocator) void {
        self.clear(alloc);
        self.entries.deinit(alloc);
    }

    pub fn clear(self: *Store, alloc: std.mem.Allocator) void {
        for (self.entries.items) |e| {
            alloc.free(e.key);
            alloc.free(e.value);
        }
        self.entries.clearRetainingCapacity();
    }

    pub fn add(self: *Store, alloc: std.mem.Allocator, key: []const u8, value: []const u8) !void {
        const k = try alloc.dupe(u8, key);
        errdefer alloc.free(k);
        const v = try alloc.dupe(u8, value);
        errdefer alloc.free(v);
        try self.entries.append(alloc, .{ .key = k, .value = v });
    }

    /// Removes every entry for `key`.
    pub fn remove(self: *Store, alloc: std.mem.Allocator, key: []const u8) void {
        var i = self.entries.items.len;
        while (i > 0) {
            i -= 1;
            const e = self.entries.items[i];
            if (!std.mem.eql(u8, e.key, key)) continue;
            alloc.free(e.key);
            alloc.free(e.value);
            _ = self.entries.orderedRemove(i);
        }
    }

    /// Replaces all entries for `key` with a single `value`.
    pub fn set(self: *Store, alloc: std.mem.Allocator, key: []const u8, value: []const u8) !void {
        self.remove(alloc, key);
        try self.add(alloc, key, value);
    }

    /// Removes only the entries for `key` whose value is exactly `value`.
    pub fn removeExact(self: *Store, alloc: std.mem.Allocator, key: []const u8, value: []const u8) void {
        var i = self.entries.items.len;
        while (i > 0) {
            i -= 1;
            const e = self.entries.items[i];
            if (!std.mem.eql(u8, e.key, key) or !std.mem.eql(u8, e.value, value)) continue;
            alloc.free(e.key);
            alloc.free(e.value);
            _ = self.entries.orderedRemove(i);
        }
    }

    pub fn has(self: *const Store, key: []const u8, value: []const u8) bool {
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, e.key, key) and std.mem.eql(u8, e.value, value)) return true;
        }
        return false;
    }

    pub fn get(self: *const Store, key: []const u8) ?[]const u8 {
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, e.key, key)) return e.value;
        }
        return null;
    }

    /// Replaces the store's contents with the entries in `text`. Blank
    /// lines, `#` comments and lines without `=` are ignored.
    pub fn parse(self: *Store, alloc: std.mem.Allocator, text: []const u8) !void {
        self.clear(alloc);
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = std.mem.trim(u8, line[0..eq], " \t");
            const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
            if (key.len == 0) continue;
            try self.add(alloc, key, value);
        }
    }

    pub fn serialize(self: *const Store, alloc: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);
        try out.appendSlice(alloc, "# Managed by Vigil. Layered on top of your Ghostty config.\n");
        for (self.entries.items) |e| {
            try out.appendSlice(alloc, e.key);
            try out.appendSlice(alloc, " = ");
            try out.appendSlice(alloc, e.value);
            try out.append(alloc, '\n');
        }
        return out.toOwnedSlice(alloc);
    }
};

pub var store: Store = .{};

// -- files (plain libc: this app is macOS-only and this avoids std.Io plumbing) --

extern "c" fn open(path: [*:0]const u8, oflag: c_int, ...) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn rename(from: [*:0]const u8, to: [*:0]const u8) c_int;

const O_RDONLY: c_int = 0;
const O_WRONLY: c_int = 1;
const O_CREAT: c_int = 0x200;
const O_TRUNC: c_int = 0x400;

fn dirPath(buf: []u8) ?[:0]const u8 {
    const home = std.c.getenv("HOME") orelse return null;
    return std.fmt.bufPrintZ(buf, "{s}/Library/Application Support/Vigil", .{std.mem.span(home)}) catch null;
}

fn configPath(buf: []u8) ?[:0]const u8 {
    const home = std.c.getenv("HOME") orelse return null;
    return std.fmt.bufPrintZ(buf, "{s}/Library/Application Support/Vigil/config", .{std.mem.span(home)}) catch null;
}

fn uiConfigPath(buf: []u8) ?[:0]const u8 {
    const home = std.c.getenv("HOME") orelse return null;
    return std.fmt.bufPrintZ(buf, "{s}/Library/Application Support/Vigil/ui-config", .{std.mem.span(home)}) catch null;
}

fn readFile(path: [:0]const u8) ?[]u8 {
    const fd = open(path.ptr, O_RDONLY);
    if (fd < 0) return null;
    defer _ = close(fd);

    var out: std.ArrayList(u8) = .empty;
    var chunk: [4096]u8 = undefined;
    while (out.items.len < 1 << 20) {
        const n = read(fd, &chunk, chunk.len);
        if (n <= 0) break;
        out.appendSlice(allocator, chunk[0..@intCast(n)]) catch {
            out.deinit(allocator);
            return null;
        };
    }
    return out.toOwnedSlice(allocator) catch null;
}

/// Vigil-only preferences that aren't real libghostty keys (currently just
/// "vigil-vertical-tabs"). Kept in their own store/file (`ui_store`,
/// `ui-config`) so they never reach `ghostty_config_load_file`, which is
/// libghostty's own strict parser and logs an "unknown field" diagnostic
/// for anything it doesn't recognize.
pub var ui_store: Store = .{};

fn loadInto(target: *Store, path: [:0]const u8) void {
    const text = readFile(path) orelse return;
    defer allocator.free(text);
    target.parse(allocator, text) catch |err| log.warn("could not parse {s}: {s}", .{ path, @errorName(err) });
}

/// Writes `target` to `path` (temp file + rename, so a crash can't leave a
/// half-written config).
fn saveFrom(target: *const Store, path: [:0]const u8) void {
    var dir_buf: [1024]u8 = undefined;
    var tmp_buf: [1032]u8 = undefined;
    const dir = dirPath(&dir_buf) orelse return;
    const tmp = std.fmt.bufPrintZ(&tmp_buf, "{s}.tmp", .{path}) catch return;

    _ = mkdir(dir.ptr, 0o755); // already existing is fine

    const text = target.serialize(allocator) catch return;
    defer allocator.free(text);

    const fd = open(tmp.ptr, O_WRONLY | O_CREAT | O_TRUNC, @as(c_uint, 0o644));
    if (fd < 0) {
        log.warn("could not write {s}", .{tmp});
        return;
    }
    var written: usize = 0;
    while (written < text.len) {
        const n = write(fd, text.ptr + written, text.len - written);
        if (n <= 0) break;
        written += @intCast(n);
    }
    _ = close(fd);
    if (written != text.len or rename(tmp.ptr, path.ptr) != 0) {
        log.warn("could not save {s}", .{path});
    }
}

/// Loads Vigil's overrides file into `store` (no file yet is fine), the
/// UI-only preferences file into `ui_store`, and migrates any Vigil-only
/// keys an earlier build left in `store` into `ui_store`.
pub fn load() void {
    var buf: [1024]u8 = undefined;
    if (configPath(&buf)) |path| loadInto(&store, path);
    var ui_buf: [1024]u8 = undefined;
    if (uiConfigPath(&ui_buf)) |path| loadInto(&ui_store, path);
    if (migrateUiKeys()) {
        save();
        saveUi();
    }
}

/// Writes `store` to disk. See `load`'s doc comment for why this file
/// never holds Vigil-only keys.
pub fn save() void {
    var buf: [1024]u8 = undefined;
    const path = configPath(&buf) orelse return;
    saveFrom(&store, path);
}

/// Writes `ui_store` to disk.
pub fn saveUi() void {
    var buf: [1024]u8 = undefined;
    const path = uiConfigPath(&buf) orelse return;
    saveFrom(&ui_store, path);
}

/// Keys that used to be written straight into the ghostty-parsed config
/// file by mistake. Extend this list if another Vigil-only key is added.
const ui_only_keys = [_][]const u8{"vigil-vertical-tabs"};

/// Moves any of `ui_only_keys` found in `store` into `ui_store` (unless
/// already migrated) and removes them from `store`. Returns true if either
/// store changed, so the caller knows to re-save.
fn migrateUiKeys() bool {
    var changed = false;
    for (ui_only_keys) |key| {
        const value = store.get(key) orelse continue;
        if (ui_store.get(key) == null) ui_store.set(allocator, key, value) catch continue;
        store.remove(allocator, key);
        changed = true;
    }
    return changed;
}

// -- building and applying configs ------------------------------------------

/// The most recently built config; lets the preferences UI show *effective*
/// values (including ones from the user's own Ghostty config) rather than
/// only what Vigil's overrides file says.
pub var current: ghc.ghostty_config_t = null;

/// Effective numeric value of `key` (f32 or f64 config fields).
pub fn effectiveFloat(comptime T: type, key: [:0]const u8) ?T {
    const cfg = current orelse return null;
    var out: T = 0;
    if (!ghc.ghostty_config_get(cfg, &out, key.ptr, key.len)) return null;
    return out;
}

pub fn effectiveBool(key: [:0]const u8) ?bool {
    const cfg = current orelse return null;
    var out: bool = false;
    if (!ghc.ghostty_config_get(cfg, &out, key.ptr, key.len)) return null;
    return out;
}

/// Effective value of an enum-typed key, as its tag name ("block", ...).
pub fn effectiveEnum(key: [:0]const u8) ?[]const u8 {
    const cfg = current orelse return null;
    var out: ?[*:0]const u8 = null;
    if (!ghc.ghostty_config_get(cfg, @ptrCast(&out), key.ptr, key.len)) return null;
    return std.mem.span(out orelse return null);
}

/// A finalized config: the user's Ghostty config files, then Vigil's
/// overrides file on top.
pub fn buildConfig() ?ghc.ghostty_config_t {
    const cfg = ghc.ghostty_config_new() orelse return null;
    ghc.ghostty_config_load_default_files(cfg);

    var buf: [1024]u8 = undefined;
    if (configPath(&buf)) |path| {
        // Loading a missing file just yields nothing; probe first to keep
        // the log quiet on a fresh install.
        const fd = open(path.ptr, O_RDONLY);
        if (fd >= 0) {
            _ = close(fd);
            ghc.ghostty_config_load_file(cfg, path.ptr);
        }
    }
    ghc.ghostty_config_finalize(cfg);

    const n = ghc.ghostty_config_diagnostics_count(cfg);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const d = ghc.ghostty_config_get_diagnostic(cfg, i);
        if (d.message != null) log.warn("config: {s}", .{d.message});
    }
    current = cfg;
    return cfg;
}

/// Rebuilds the config from disk + `store` and pushes it to every surface.
pub fn apply(app: ghc.ghostty_app_t) void {
    const cfg = buildConfig() orelse return;
    ghc.ghostty_app_update_config(app, cfg);
    keybindings.init(cfg);
}

test "parse and serialize round-trip" {
    const alloc = std.testing.allocator;
    var s: Store = .{};
    defer s.deinit(alloc);
    try s.parse(alloc,
        \\# comment
        \\background = 1a1b26
        \\
        \\palette = 0=#15161e
        \\palette=1=#f7768e
        \\  not a setting
    );
    try std.testing.expectEqual(@as(usize, 3), s.entries.items.len);
    try std.testing.expectEqualStrings("1a1b26", s.get("background").?);
    try std.testing.expectEqualStrings("1=#f7768e", s.entries.items[2].value);

    const text = try s.serialize(alloc);
    defer alloc.free(text);
    var again: Store = .{};
    defer again.deinit(alloc);
    try again.parse(alloc, text);
    try std.testing.expectEqual(s.entries.items.len, again.entries.items.len);
}

test "set replaces every entry for a key" {
    const alloc = std.testing.allocator;
    var s: Store = .{};
    defer s.deinit(alloc);
    try s.add(alloc, "palette", "0=#000000");
    try s.add(alloc, "palette", "1=#111111");
    try s.add(alloc, "background", "000000");
    try s.set(alloc, "palette", "2=#222222");
    try std.testing.expectEqual(@as(usize, 2), s.entries.items.len);
    try std.testing.expectEqualStrings("2=#222222", s.get("palette").?);
}
