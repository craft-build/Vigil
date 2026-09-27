//! Screen 04 -- Preferences: a sidebar of sections next to a panel of rows,
//! each row a native AppKit control wired to a real libghostty config key
//! through `app/preferences.zig`. It's a separate NSWindow (not an overlay)
//! so text fields get normal keyboard handling; every change is written to
//! Vigil's overrides file and applied live via `on_change`.
const std = @import("std");
const objc = @import("objc");
const appkit = @import("../app/appkit.zig");
const keymonitor = @import("../app/keymonitor.zig");
const prefs = @import("../app/preferences.zig");
const settings = @import("../app/settings.zig");
const theme = @import("theme.zig");
const clickable = @import("clickable.zig");

const SectionItem = clickable.Kind("VigilPrefsSection");

const win_w: f64 = 780;
const win_h: f64 = 540;
const sidebar_w: f64 = 188;
const pane_pad: f64 = 28;
const row_h: f64 = 64;
const section_count = @typeInfo(prefs.Section).@"enum".fields.len;

var window: ?objc.Object = null;
var content: objc.Object = undefined;
var pane: ?objc.Object = null;
var sidebar_items: [section_count]objc.Object = undefined;
var current: prefs.Section = .general;
var target: objc.Object = undefined;
var target_class: ?objc.Class = null;
/// The value readout beside a slider/stepper, by setting index.
var value_labels: [prefs.all.len]?objc.Object = @splat(null);

/// Called after a setting was written to disk; the owner rebuilds and
/// applies the config.
pub var on_change: ?*const fn () void = null;
pub var on_button: ?*const fn (prefs.ButtonAction) void = null;

pub fn show() void {
    if (window == null) build();
    const win = window.?;
    win.msgSend(void, "makeKeyAndOrderFront:", .{@as(?*anyopaque, null)});
    appkit.class("NSApplication").msgSend(objc.Object, "sharedApplication", .{})
        .msgSend(void, "activateIgnoringOtherApps:", .{true});
}

pub fn isPreferencesWindow(win: objc.Object) bool {
    const w = window orelse return false;
    return w.value == win.value;
}

/// ⌘W and (when not typing in a field) Esc close the window. Returns true
/// if consumed.
pub fn handleKey(event: objc.Object) bool {
    const win = window orelse return false;
    const code = keymonitor.keyCode(event);
    const mods = keymonitor.modifiers(event);
    const editing = win.msgSend(objc.Object, "firstResponder", .{})
        .msgSend(bool, "isKindOfClass:", .{appkit.class("NSText").value});

    if ((mods == .command and code == key_w) or (mods == .none and code == keymonitor.key_escape and !editing)) {
        win.msgSend(void, "performClose:", .{@as(?*anyopaque, null)});
        return true;
    }
    return false;
}

const key_w: u16 = 13;

fn build() void {
    const style_mask: u64 = 1 | 2 | 4; // Titled | Closable | Miniaturizable
    const win = appkit.class("NSWindow")
        .msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "initWithContentRect:styleMask:backing:defer:", .{
        appkit.rect(0, 0, win_w, win_h),
        style_mask,
        @as(u64, 2),
        false,
    });
    win.msgSend(void, "setTitle:", .{appkit.nsString("Preferences")});
    // The window is kept and reused, so closing must not release it.
    win.msgSend(void, "setReleasedWhenClosed:", .{false});
    // Native controls follow the window's appearance; this UI is dark.
    win.msgSend(void, "setAppearance:", .{
        appkit.class("NSAppearance").msgSend(objc.Object, "appearanceNamed:", .{
            appkit.nsString("NSAppearanceNameDarkAqua"),
        }),
    });
    win.msgSend(void, "setBackgroundColor:", .{appkit.nsColor(theme.colors.bg_surface)});
    win.msgSend(void, "center", .{});
    window = win;
    content = win.msgSend(objc.Object, "contentView", .{});

    target = targetClass().msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});
    SectionItem.on_click = onSectionClick;

    buildSidebar();
    buildPane();
}

fn targetClass() objc.Class {
    if (target_class) |cls| return cls;
    const cls = objc.allocateClassPair(appkit.class("NSObject"), "VigilPrefsTarget") orelse
        @panic("failed to register VigilPrefsTarget");
    std.debug.assert(cls.addMethod("changed:", changed));
    objc.registerClassPair(cls);
    target_class = cls;
    return cls;
}

// -- sidebar ------------------------------------------------------------------

fn buildSidebar() void {
    const bar = appkit.panel(
        appkit.rect(0, 0, sidebar_w, win_h),
        .{ .background = theme.colors.bg_sunken },
    );
    appkit.addSubview(content, bar);
    appkit.addSubview(bar, appkit.panel(
        appkit.rect(sidebar_w - 1, 0, 1, win_h),
        .{ .background = theme.colors.border_subtle },
    ));

    inline for (@typeInfo(prefs.Section).@"enum".fields, 0..) |f, i| {
        const section: prefs.Section = @enumFromInt(f.value);
        const item = SectionItem.view(
            appkit.rect(10, win_h - 56 - @as(f64, @floatFromInt(i)) * 36, sidebar_w - 20, 30),
            i,
            .{ .corner_radius = theme.radius.md },
        );
        appkit.addSubview(item, appkit.label(
            appkit.rect(12, 5, sidebar_w - 44, 18),
            section.title(),
            appkit.font(theme.fonts.body, theme.text_size.sm, false),
            theme.colors.text_primary,
        ));
        appkit.addSubview(bar, item);
        sidebar_items[i] = item;
    }
    highlightSidebar();
}

fn highlightSidebar() void {
    for (sidebar_items, 0..) |item, i| {
        const selected = i == @intFromEnum(current);
        const layer = item.msgSend(objc.Object, "layer", .{});
        layer.msgSend(void, "setBackgroundColor:", .{
            if (selected) appkit.cgColor(theme.colors.bg_surface_raised) else appkit.cgColor(.{ .r = 0, .g = 0, .b = 0, .a = 0 }),
        });
    }
}

/// Only the pane is rebuilt: the clicked sidebar item must survive its own
/// mouse-down handler.
fn onSectionClick(tag: usize) void {
    if (tag >= section_count) return;
    current = @enumFromInt(tag);
    highlightSidebar();
    buildPane();
}

// -- pane ---------------------------------------------------------------------

fn buildPane() void {
    if (pane) |old| old.msgSend(void, "removeFromSuperview", .{});
    value_labels = @splat(null);

    const pane_w = win_w - sidebar_w;
    const view = appkit.panel(
        appkit.rect(sidebar_w, 0, pane_w, win_h),
        .{ .background = theme.colors.bg_surface },
    );
    appkit.addSubview(content, view);
    pane = view;

    appkit.addSubview(view, appkit.label(
        appkit.rect(pane_pad, win_h - 64, pane_w - 2 * pane_pad, 28),
        current.title(),
        appkit.font(theme.fonts.display, theme.text_size.lg, false),
        theme.colors.text_primary,
    ));

    var y = win_h - 96 - row_h;
    for (prefs.all, 0..) |setting, i| {
        if (setting.section != current) continue;
        buildRow(view, i, setting, y, pane_w);
        y -= row_h;
    }
}

fn buildRow(view: objc.Object, index: usize, setting: prefs.Setting, y: f64, pane_w: f64) void {
    appkit.addSubview(view, appkit.panel(
        appkit.rect(pane_pad, y + row_h - 1, pane_w - 2 * pane_pad, 1),
        .{ .background = theme.colors.border_subtle },
    ));

    const control_w = controlWidth(setting.kind);
    const text_w = pane_w - 2 * pane_pad - control_w - 24;
    const has_hint = setting.hint.len > 0;

    appkit.addSubview(view, appkit.label(
        appkit.rect(pane_pad, y + (if (has_hint) @as(f64, 34) else 22), text_w, 18),
        setting.label,
        appkit.font(theme.fonts.body, theme.text_size.sm, false),
        theme.colors.text_primary,
    ));
    if (has_hint) {
        const hint = appkit.label(
            appkit.rect(pane_pad, y + 6, text_w, 28),
            setting.hint,
            appkit.font(theme.fonts.body, 11, false),
            theme.colors.text_tertiary,
        );
        hint.msgSend(void, "setLineBreakMode:", .{@as(u64, 0)}); // word wrap
        appkit.addSubview(view, hint);
    }

    const right = pane_w - pane_pad;
    const cy = y + (row_h - 28) / 2;
    switch (setting.kind) {
        .toggle => {
            const sw = appkit.class("NSSwitch").msgSend(objc.Object, "alloc", .{})
                .msgSend(objc.Object, "initWithFrame:", .{appkit.rect(0, 0, 40, 24)});
            // NSSwitch draws at its own intrinsic size; let it pick that,
            // then pin its trailing edge to the row's.
            sw.msgSend(void, "sizeToFit", .{});
            const sw_size = sw.msgSend(appkit.NSRect, "frame", .{}).size;
            sw.msgSend(void, "setFrame:", .{appkit.rect(right - sw_size.width, y + (row_h - sw_size.height) / 2, sw_size.width, sw_size.height)});
            sw.msgSend(void, "setState:", .{@as(i64, @intFromBool(setting.read.?(&settings.store).on))});
            wire(sw, index);
            appkit.addSubview(view, sw);
        },
        .choice => |options| {
            var labels: [4]objc.c.id = undefined;
            for (options, 0..) |o, i| labels[i] = appkit.nsString(o).value;
            const array = appkit.class("NSArray").msgSend(objc.Object, "arrayWithObjects:count:", .{
                @as([*]objc.c.id, &labels),
                @as(u64, options.len),
            });
            const seg = appkit.class("NSSegmentedControl").msgSend(
                objc.Object,
                "segmentedControlWithLabels:trackingMode:target:action:",
                .{ array, @as(i64, 0), target, objc.sel("changed:").value },
            );
            seg.msgSend(void, "setFrame:", .{appkit.rect(right - control_w, cy, control_w, 28)});
            seg.msgSend(void, "setSelectedSegment:", .{@as(i64, @intCast(setting.read.?(&settings.store).index))});
            seg.msgSend(void, "setTag:", .{@as(i64, @intCast(index))});
            appkit.addSubview(view, seg);
        },
        .slider => |range| {
            const value = setting.read.?(&settings.store).number;
            const slider = appkit.class("NSSlider").msgSend(objc.Object, "alloc", .{})
                .msgSend(objc.Object, "initWithFrame:", .{appkit.rect(right - 160, cy + 4, 160, 20)});
            slider.msgSend(void, "setMinValue:", .{range.min});
            slider.msgSend(void, "setMaxValue:", .{range.max});
            slider.msgSend(void, "setDoubleValue:", .{value});
            // One apply per drag (on release), not one per tick.
            slider.msgSend(void, "setContinuous:", .{false});
            wire(slider, index);
            appkit.addSubview(view, slider);
            addValueLabel(view, index, right - 160 - 52, cy + 5, setting, value);
        },
        .stepper => |range| {
            const value = setting.read.?(&settings.store).number;
            const stepper = appkit.class("NSStepper").msgSend(objc.Object, "alloc", .{})
                .msgSend(objc.Object, "initWithFrame:", .{appkit.rect(right - 19, cy, 19, 28)});
            stepper.msgSend(void, "setMinValue:", .{range.min});
            stepper.msgSend(void, "setMaxValue:", .{range.max});
            stepper.msgSend(void, "setIncrement:", .{range.step});
            stepper.msgSend(void, "setDoubleValue:", .{value});
            wire(stepper, index);
            appkit.addSubview(view, stepper);
            addValueLabel(view, index, right - 19 - 52, cy + 5, setting, value);
        },
        .text => {
            const field = appkit.class("NSTextField").msgSend(objc.Object, "alloc", .{})
                .msgSend(objc.Object, "initWithFrame:", .{appkit.rect(right - control_w, cy + 2, control_w, 24)});
            field.msgSend(void, "setBezeled:", .{true});
            field.msgSend(void, "setBezelStyle:", .{@as(u64, 1)}); // rounded
            field.msgSend(void, "setEditable:", .{true});
            field.msgSend(void, "setFont:", .{appkit.font(theme.fonts.mono, theme.text_size.xs, true)});
            var buf: [256:0]u8 = undefined;
            const current_text = setting.read.?(&settings.store).text;
            const shown = std.fmt.bufPrintZ(&buf, "{s}", .{current_text}) catch "";
            field.msgSend(void, "setStringValue:", .{appkit.nsString(shown)});
            field.msgSend(void, "setPlaceholderString:", .{appkit.nsString("System default")});
            field.msgSend(objc.Object, "cell", .{}).msgSend(void, "setSendsActionOnEndEditing:", .{true});
            wire(field, index);
            appkit.addSubview(view, field);
        },
        .button => |b| {
            const button = appkit.class("NSButton").msgSend(
                objc.Object,
                "buttonWithTitle:target:action:",
                .{ appkit.nsString(b.title), target, objc.sel("changed:").value },
            );
            button.msgSend(void, "setFrame:", .{appkit.rect(right - control_w, cy, control_w, 28)});
            button.msgSend(void, "setTag:", .{@as(i64, @intCast(index))});
            appkit.addSubview(view, button);
        },
        .info => {
            const env = std.c.getenv("SHELL");
            var buf: [128:0]u8 = undefined;
            const text = std.fmt.bufPrintZ(&buf, "{s}", .{if (env) |e| std.mem.span(e) else "unknown"}) catch "unknown";
            const label = appkit.label(
                appkit.rect(right - control_w, cy + 5, control_w, 18),
                text,
                appkit.font(theme.fonts.mono, theme.text_size.xs, true),
                theme.colors.text_secondary,
            );
            appkit.setAlignment(label, .right);
            appkit.addSubview(view, label);
        },
    }
}

fn controlWidth(kind: prefs.Kind) f64 {
    return switch (kind) {
        .toggle => 40,
        .choice => |options| 84 * @as(f64, @floatFromInt(options.len)),
        .slider => 212,
        .stepper => 71,
        .text => 220,
        .button => 150,
        .info => 220,
    };
}

fn wire(control: objc.Object, index: usize) void {
    control.msgSend(void, "setTarget:", .{target});
    control.msgSend(void, "setAction:", .{objc.sel("changed:").value});
    control.msgSend(void, "setTag:", .{@as(i64, @intCast(index))});
}

fn addValueLabel(view: objc.Object, index: usize, x: f64, y: f64, setting: prefs.Setting, value: f64) void {
    const label = appkit.label(
        appkit.rect(x, y, 48, 18),
        "",
        appkit.font(theme.fonts.mono, theme.text_size.xs, true),
        theme.colors.text_secondary,
    );
    appkit.setAlignment(label, .right);
    setValueText(label, setting, value);
    appkit.addSubview(view, label);
    value_labels[index] = label;
}

fn setValueText(label: objc.Object, setting: prefs.Setting, value: f64) void {
    var buf: [24:0]u8 = undefined;
    const text = switch (setting.kind) {
        .slider => std.fmt.bufPrintZ(&buf, "{d:.0}%", .{value * 100}),
        else => std.fmt.bufPrintZ(&buf, "{d:.0}", .{value}),
    } catch return;
    label.msgSend(void, "setStringValue:", .{appkit.nsString(text)});
}

// -- control action -------------------------------------------------------------

fn changed(_: objc.c.id, _: objc.c.SEL, sender: objc.c.id) callconv(.c) void {
    const control = objc.Object{ .value = sender };
    const tag = control.msgSend(i64, "tag", .{});
    if (tag < 0 or tag >= prefs.all.len) return;
    const index: usize = @intCast(tag);
    const setting = prefs.all[index];

    var value: prefs.Value = undefined;
    switch (setting.kind) {
        .toggle => value = .{ .on = control.msgSend(i64, "state", .{}) != 0 },
        .choice => value = .{ .index = @intCast(control.msgSend(i64, "selectedSegment", .{})) },
        .slider, .stepper => |range| {
            // Snap to the step so 0.8500001 never reaches the config file.
            const raw = control.msgSend(f64, "doubleValue", .{});
            const snapped = @round(raw / range.step) * range.step;
            control.msgSend(void, "setDoubleValue:", .{snapped});
            value = .{ .number = snapped };
        },
        .text => {
            const str = control.msgSend(objc.Object, "stringValue", .{});
            value = .{ .text = std.mem.span(str.msgSend([*:0]const u8, "UTF8String", .{})) };
        },
        .button => |b| {
            if (on_button) |cb| cb(b.action);
            return;
        },
        .info => return,
    }

    setting.write.?(&settings.store, std.heap.c_allocator, value) catch return;
    settings.save();
    if (value_labels[index]) |label| setValueText(label, setting, value.number);
    if (on_change) |cb| cb();
}
