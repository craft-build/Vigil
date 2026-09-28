//! The pane tree: how one tab's terminal surfaces are arranged into splits.
//! libghostty has no layout engine of its own for the embedded C API --
//! `ghostty_surface_split` just performs the `new_split` binding action,
//! which arrives back at us as `GHOSTTY_ACTION_NEW_SPLIT`. Actually laying
//! surfaces out (and dividers, dragging, closing panes, ...) is entirely
//! on the host, same as the Swift app's own `Ghostty.SplitTree`.
//!
//! Deliberately split into two layers so the tree/geometry logic is
//! testable without AppKit or a real `ghostty_surface_t`:
//!   - `Pane`/`Split`: the tree shape and its mutations (insert, remove,
//!     equalize, traverse). Generic over the tree's `Leaf` type.
//!   - `splitRect`: the pure rect math one `Split` uses to place its two
//!     children. `Window.zig` walks a `Pane(*TerminalSurface)` and applies
//!     these rects to real views; that walk itself isn't tested here since
//!     it's a thin, low-risk AppKit loop.
const std = @import("std");
const appkit = @import("appkit.zig");

pub const Direction = enum {
    /// Side by side (left | right).
    horizontal,
    /// Stacked (top / bottom).
    vertical,
};

/// A binding action's split direction, e.g. from
/// `ghostty_action_split_direction_e`.
pub const NewSplitDirection = enum { right, down, left, up };

/// Where the newly created leaf lands relative to the one being split.
pub const NewSplitPlacement = struct {
    direction: Direction,
    /// True if the new leaf becomes `first` (left/top); false for
    /// `second` (right/bottom).
    new_is_first: bool,
};

pub fn placementFor(dir: NewSplitDirection) NewSplitPlacement {
    return switch (dir) {
        .right => .{ .direction = .horizontal, .new_is_first = false },
        .left => .{ .direction = .horizontal, .new_is_first = true },
        .down => .{ .direction = .vertical, .new_is_first = false },
        .up => .{ .direction = .vertical, .new_is_first = true },
    };
}

/// One tab's pane tree, generic over the type stored at each leaf (real
/// code uses `*TerminalSurface`; tests use a dummy tag type so tree
/// mutation can be checked without touching AppKit).
pub fn Tree(comptime Leaf: type) type {
    return struct {
        pub const Split = struct {
            direction: Direction,
            /// Fraction of the split's rect given to `first`; the rest
            /// goes to `second` (minus the divider). Kept away from the
            /// edges so neither side can be dragged to nothing.
            ratio: f64 = 0.5,
            first: Pane,
            second: Pane,
            /// The rect this split last occupied, in whatever coordinate
            /// space the caller lays out in. Set by `Window`'s layout walk
            /// after every layout pass; read back by divider-drag handling
            /// to turn a mouse position into a new ratio.
            last_rect: appkit.NSRect = std.mem.zeroes(appkit.NSRect),

            pub const min_ratio = 0.1;
            pub const max_ratio = 0.9;

            pub fn setRatio(self: *Split, ratio: f64) void {
                self.ratio = std.math.clamp(ratio, min_ratio, max_ratio);
            }
        };

        pub const Pane = union(enum) {
            leaf: Leaf,
            split: *Split,
        };

        allocator: std.mem.Allocator,
        root: Pane,

        pub fn init(allocator: std.mem.Allocator, first_leaf: Leaf) @This() {
            return .{ .allocator = allocator, .root = .{ .leaf = first_leaf } };
        }

        /// Frees every `Split` node. Does *not* touch leaves -- the caller
        /// (`Window`) owns and frees `*TerminalSurface`s itself, since
        /// closing one is more than freeing memory (PTY, Metal surface, ...).
        pub fn deinit(self: *@This()) void {
            freeSplits(self.allocator, self.root);
            self.root = undefined;
        }

        fn freeSplits(allocator: std.mem.Allocator, pane: Pane) void {
            switch (pane) {
                .leaf => {},
                .split => |s| {
                    freeSplits(allocator, s.first);
                    freeSplits(allocator, s.second);
                    allocator.destroy(s);
                },
            }
        }

        pub fn isSingleLeaf(self: *const @This()) bool {
            return self.root == .leaf;
        }

        /// True if `leaf` (compared with `eq`) appears anywhere in the tree.
        pub fn contains(self: *const @This(), leaf: Leaf, eq: *const fn (Leaf, Leaf) bool) bool {
            return containsIn(self.root, leaf, eq);
        }

        fn containsIn(pane: Pane, leaf: Leaf, eq: *const fn (Leaf, Leaf) bool) bool {
            return switch (pane) {
                .leaf => |l| eq(l, leaf),
                .split => |s| containsIn(s.first, leaf, eq) or containsIn(s.second, leaf, eq),
            };
        }

        /// Replaces the leaf matching `target` with a new split holding it
        /// and `new_leaf`, placed per `placement`. Returns `error.NotFound`
        /// if `target` isn't in the tree.
        pub fn split(
            self: *@This(),
            target: Leaf,
            eq: *const fn (Leaf, Leaf) bool,
            new_leaf: Leaf,
            placement: NewSplitPlacement,
        ) !void {
            const slot = findSlot(&self.root, target, eq) orelse return error.NotFound;
            const old = slot.*;
            const node = try self.allocator.create(Split);
            node.* = .{
                .direction = placement.direction,
                .first = if (placement.new_is_first) .{ .leaf = new_leaf } else old,
                .second = if (placement.new_is_first) old else .{ .leaf = new_leaf },
            };
            slot.* = .{ .split = node };
        }

        /// Removes the leaf matching `target`, collapsing its parent split
        /// into the surviving sibling. Returns `error.LastLeaf` if `target`
        /// is the tree's only pane (the caller should close the whole tab
        /// instead of calling this) and `error.NotFound` if it isn't in the
        /// tree at all. On success, returns the leaf that should take focus.
        pub fn remove(self: *@This(), target: Leaf, eq: *const fn (Leaf, Leaf) bool) !Leaf {
            if (isLeafEq(self.root, target, eq)) return error.LastLeaf;
            if (!removeChild(self.allocator, &self.root, target, eq)) return error.NotFound;
            return firstLeaf(self.root);
        }

        fn removeChild(allocator: std.mem.Allocator, slot: *Pane, target: Leaf, eq: *const fn (Leaf, Leaf) bool) bool {
            const s = switch (slot.*) {
                .leaf => return false,
                .split => |sp| sp,
            };
            if (isLeafEq(s.first, target, eq)) {
                slot.* = s.second;
                allocator.destroy(s);
                return true;
            }
            if (isLeafEq(s.second, target, eq)) {
                slot.* = s.first;
                allocator.destroy(s);
                return true;
            }
            return removeChild(allocator, &s.first, target, eq) or removeChild(allocator, &s.second, target, eq);
        }

        fn isLeafEq(pane: Pane, target: Leaf, eq: *const fn (Leaf, Leaf) bool) bool {
            return switch (pane) {
                .leaf => |l| eq(l, target),
                .split => false,
            };
        }

        fn findSlot(slot: *Pane, target: Leaf, eq: *const fn (Leaf, Leaf) bool) ?*Pane {
            switch (slot.*) {
                .leaf => |l| return if (eq(l, target)) slot else null,
                .split => |s| return findSlot(&s.first, target, eq) orelse findSlot(&s.second, target, eq),
            }
        }

        pub fn firstLeaf(pane: Pane) Leaf {
            return switch (pane) {
                .leaf => |l| l,
                .split => |s| firstLeaf(s.first),
            };
        }

        /// Resets every split in the tree to an even 50/50 ratio.
        pub fn equalize(self: *@This()) void {
            equalizeIn(self.root);
        }

        fn equalizeIn(pane: Pane) void {
            switch (pane) {
                .leaf => {},
                .split => |s| {
                    s.ratio = 0.5;
                    equalizeIn(s.first);
                    equalizeIn(s.second);
                },
            }
        }

        /// Calls `visit(leaf)` for every leaf, in tree order.
        pub fn walk(self: *const @This(), context: anytype, visit: *const fn (@TypeOf(context), Leaf) void) void {
            walkIn(self.root, context, visit);
        }

        fn walkIn(pane: Pane, context: anytype, visit: *const fn (@TypeOf(context), Leaf) void) void {
            switch (pane) {
                .leaf => |l| visit(context, l),
                .split => |s| {
                    walkIn(s.first, context, visit);
                    walkIn(s.second, context, visit);
                },
            }
        }
    };
}

pub const divider_thickness: f64 = 3;

/// Splits `rect` into two child rects for a split with `direction` and
/// `ratio`, separated by a `divider_thickness`-wide gap. Pure geometry --
/// no AppKit calls -- so it's directly unit-testable.
///
/// AppKit's y-axis points up (origin bottom-left); `first` is always the
/// visually left/top child, so for a vertical split `first` sits at the
/// *higher* y.
pub fn splitRect(rect: appkit.NSRect, direction: Direction, ratio: f64) struct { first: appkit.NSRect, second: appkit.NSRect } {
    const half_gap = divider_thickness / 2;
    switch (direction) {
        .horizontal => {
            const first_w = @max(0, rect.size.width * ratio - half_gap);
            const second_x = rect.origin.x + rect.size.width * ratio + half_gap;
            const second_w = @max(0, rect.origin.x + rect.size.width - second_x);
            return .{
                .first = appkit.rect(rect.origin.x, rect.origin.y, first_w, rect.size.height),
                .second = appkit.rect(second_x, rect.origin.y, second_w, rect.size.height),
            };
        },
        .vertical => {
            // `first` is top-aligned and owns the top `ratio` share of the
            // height; `second` is bottom-aligned with the rest. (Both
            // branches must treat `ratio` as "first's share" consistently
            // -- this one originally computed `second`'s share instead,
            // which only an asymmetric-ratio test caught.)
            const first_h = @max(0, rect.size.height * ratio - half_gap);
            const first_y = rect.origin.y + rect.size.height - first_h;
            const second_h = @max(0, rect.size.height * (1 - ratio) - half_gap);
            return .{
                .first = appkit.rect(rect.origin.x, first_y, rect.size.width, first_h),
                .second = appkit.rect(rect.origin.x, rect.origin.y, rect.size.width, second_h),
            };
        },
    }
}

/// The divider's own rect for a split occupying `rect`, between the two
/// children `splitRect` would produce.
pub fn dividerRect(rect: appkit.NSRect, direction: Direction, ratio: f64) appkit.NSRect {
    const half = divider_thickness / 2;
    switch (direction) {
        .horizontal => {
            const cx = rect.origin.x + rect.size.width * ratio;
            return appkit.rect(cx - half, rect.origin.y, divider_thickness, rect.size.height);
        },
        .vertical => {
            const cy = rect.origin.y + rect.size.height * (1 - ratio);
            return appkit.rect(rect.origin.x, cy - half, rect.size.width, divider_thickness);
        },
    }
}

/// Inverse of `dividerRect`/`splitRect`: given a drag to `point` (in the
/// same coordinate space as `rect`), the ratio that would put the divider
/// there.
pub fn ratioForPoint(rect: appkit.NSRect, direction: Direction, point: appkit.NSPoint) f64 {
    return switch (direction) {
        .horizontal => if (rect.size.width == 0) 0.5 else (point.x - rect.origin.x) / rect.size.width,
        .vertical => if (rect.size.height == 0) 0.5 else 1 - (point.y - rect.origin.y) / rect.size.height,
    };
}

// -- tests --------------------------------------------------------------------

const TestTree = Tree(u32);

fn eqU32(a: u32, b: u32) bool {
    return a == b;
}

test "single leaf tree has no splits" {
    var tree = TestTree.init(std.testing.allocator, 1);
    defer tree.deinit();
    try std.testing.expect(tree.isSingleLeaf());
    try std.testing.expect(tree.contains(1, eqU32));
    try std.testing.expect(!tree.contains(2, eqU32));
}

test "split replaces a leaf with first/second per placement" {
    var tree = TestTree.init(std.testing.allocator, 1);
    defer tree.deinit();

    try tree.split(1, eqU32, 2, placementFor(.right));
    try std.testing.expect(!tree.isSingleLeaf());
    try std.testing.expect(tree.contains(1, eqU32) and tree.contains(2, eqU32));
    switch (tree.root) {
        .split => |s| {
            try std.testing.expectEqual(TestTree.Pane{ .leaf = 1 }, s.first);
            try std.testing.expectEqual(TestTree.Pane{ .leaf = 2 }, s.second);
            try std.testing.expectEqual(Direction.horizontal, s.direction);
        },
        .leaf => unreachable,
    }

    try std.testing.expectError(error.NotFound, tree.split(99, eqU32, 3, placementFor(.down)));
}

test "left/up placements put the new leaf first" {
    var tree = TestTree.init(std.testing.allocator, 1);
    defer tree.deinit();
    try tree.split(1, eqU32, 2, placementFor(.up));
    switch (tree.root) {
        .split => |s| {
            try std.testing.expectEqual(TestTree.Pane{ .leaf = 2 }, s.first);
            try std.testing.expectEqual(Direction.vertical, s.direction);
        },
        .leaf => unreachable,
    }
}

test "removing the only leaf is an error, not a crash" {
    var tree = TestTree.init(std.testing.allocator, 1);
    defer tree.deinit();
    try std.testing.expectError(error.LastLeaf, tree.remove(1, eqU32));
}

test "remove collapses the split into the surviving sibling" {
    var tree = TestTree.init(std.testing.allocator, 1);
    defer tree.deinit();
    try tree.split(1, eqU32, 2, placementFor(.right));

    const focus_after = try tree.remove(2, eqU32);
    try std.testing.expectEqual(@as(u32, 1), focus_after);
    try std.testing.expect(tree.isSingleLeaf());
    try std.testing.expectEqual(TestTree.Pane{ .leaf = 1 }, tree.root);
}

test "remove from a nested split leaves the rest of the tree intact" {
    var tree = TestTree.init(std.testing.allocator, 1);
    defer tree.deinit();
    try tree.split(1, eqU32, 2, placementFor(.right)); // [1 | 2]
    try tree.split(2, eqU32, 3, placementFor(.down)); // [1 | [2 / 3]]

    _ = try tree.remove(3, eqU32); // -> [1 | 2]
    try std.testing.expect(tree.contains(1, eqU32));
    try std.testing.expect(tree.contains(2, eqU32));
    try std.testing.expect(!tree.contains(3, eqU32));
    switch (tree.root) {
        .split => |s| {
            try std.testing.expectEqual(TestTree.Pane{ .leaf = 1 }, s.first);
            try std.testing.expectEqual(TestTree.Pane{ .leaf = 2 }, s.second);
        },
        .leaf => unreachable,
    }

    try std.testing.expectError(error.NotFound, tree.remove(42, eqU32));
}

test "equalize resets every split's ratio" {
    var tree = TestTree.init(std.testing.allocator, 1);
    defer tree.deinit();
    try tree.split(1, eqU32, 2, placementFor(.right));
    try tree.split(2, eqU32, 3, placementFor(.down));
    tree.root.split.ratio = 0.8;
    tree.root.split.second.split.ratio = 0.2;

    tree.equalize();
    try std.testing.expectEqual(@as(f64, 0.5), tree.root.split.ratio);
    try std.testing.expectEqual(@as(f64, 0.5), tree.root.split.second.split.ratio);
}

test "walk visits every leaf" {
    var tree = TestTree.init(std.testing.allocator, 1);
    defer tree.deinit();
    try tree.split(1, eqU32, 2, placementFor(.right));
    try tree.split(1, eqU32, 3, placementFor(.down));

    var sum: u32 = 0;
    tree.walk(&sum, struct {
        fn visit(s: *u32, leaf: u32) void {
            s.* += leaf;
        }
    }.visit);
    try std.testing.expectEqual(@as(u32, 1 + 2 + 3), sum);
}

test "setRatio clamps away from the edges" {
    var s: TestTree.Split = .{ .direction = .horizontal, .first = .{ .leaf = 1 }, .second = .{ .leaf = 2 } };
    s.setRatio(-1);
    try std.testing.expectEqual(TestTree.Split.min_ratio, s.ratio);
    s.setRatio(5);
    try std.testing.expectEqual(TestTree.Split.max_ratio, s.ratio);
    s.setRatio(0.3);
    try std.testing.expectEqual(@as(f64, 0.3), s.ratio);
}

test "splitRect: horizontal divides width, keeps full height, leaves a gap" {
    const rect = appkit.rect(0, 0, 100, 50);
    const parts = splitRect(rect, .horizontal, 0.5);
    try std.testing.expectEqual(@as(f64, 48.5), parts.first.size.width); // 50 - half_gap(1.5)
    try std.testing.expectEqual(@as(f64, 50), parts.first.size.height);
    try std.testing.expectEqual(@as(f64, 0), parts.first.origin.x);
    try std.testing.expectEqual(@as(f64, 51.5), parts.second.origin.x);
    try std.testing.expectEqual(@as(f64, 48.5), parts.second.size.width);
}

test "splitRect: vertical puts first at the top (higher y)" {
    const rect = appkit.rect(0, 0, 100, 50);
    const parts = splitRect(rect, .vertical, 0.5);
    try std.testing.expectEqual(@as(f64, 26.5), parts.first.origin.y); // 25 + half_gap(1.5)
    try std.testing.expectEqual(@as(f64, 23.5), parts.first.size.height);
    try std.testing.expectEqual(@as(f64, 0), parts.second.origin.y);
    try std.testing.expectEqual(@as(f64, 23.5), parts.second.size.height);
}

test "splitRect: ratio is consistently first's share on both axes" {
    // A 0.5 ratio can't distinguish "first's share" from "second's share"
    // (symmetric); this pins down the asymmetric case on both axes.
    const rect = appkit.rect(0, 0, 100, 100);

    const h = splitRect(rect, .horizontal, 0.25);
    try std.testing.expectEqual(@as(f64, 23.5), h.first.size.width); // 100*0.25 - half_gap(1.5)
    try std.testing.expectEqual(@as(f64, 73.5), h.second.size.width); // 100*0.75 - 1.5

    const v = splitRect(rect, .vertical, 0.25);
    try std.testing.expectEqual(@as(f64, 23.5), v.first.size.height); // top: 100*0.25 - 1.5
    try std.testing.expectEqual(@as(f64, 73.5), v.second.size.height); // bottom: 100*0.75 - 1.5
    try std.testing.expectEqual(@as(f64, 76.5), v.first.origin.y); // 100 - 23.5
}

test "splitRect never produces a negative size at extreme ratios" {
    const rect = appkit.rect(0, 0, 10, 10);
    const parts = splitRect(rect, .horizontal, 0.99);
    try std.testing.expect(parts.second.size.width >= 0);
}

test "ratioForPoint inverts dividerRect" {
    const rect = appkit.rect(0, 0, 200, 100);
    for ([_]f64{ 0.2, 0.5, 0.8 }) |ratio| {
        const div = dividerRect(rect, .horizontal, ratio);
        const mid = appkit.NSPoint{ .x = div.origin.x + div.size.width / 2, .y = 0 };
        try std.testing.expectApproxEqAbs(ratio, ratioForPoint(rect, .horizontal, mid), 0.0001);

        const divv = dividerRect(rect, .vertical, ratio);
        const midv = appkit.NSPoint{ .x = 0, .y = divv.origin.y + divv.size.height / 2 };
        try std.testing.expectApproxEqAbs(ratio, ratioForPoint(rect, .vertical, midv), 0.0001);
    }
}
