//! Design tokens pulled from the Vigil design system that the Vigil.dc.html
//! prototype (claude.ai/design project 40ad13c2-4512-40b3-b0f4-52c5a4ef375b)
//! imports: tokens/colors.css, tokens/typography.css, tokens/radius.css.
//! This is the app's only chrome skin ("the new normal") -- the design
//! system it replaces (Craft) lives on only as a terminal color theme, see
//! `themes.zig`'s "Craft" entry.

/// sRGB color with 0-1 float components, the form AppKit/Core Animation want
/// (NSColor colorWithSRGBRed:green:blue:alpha:, CGColor components).
pub const Color = struct {
    r: f64,
    g: f64,
    b: f64,
    a: f64 = 1.0,

    fn hex(comptime h: u24) Color {
        return hexA(h, 1.0);
    }

    /// `h` is the RGB part; `a` is applied on top -- used for the design
    /// system's white-alpha borders/surfaces (e.g. `rgba(255,255,255,.06)`).
    fn hexA(comptime h: u24, a: f64) Color {
        return .{
            .r = @as(f64, @floatFromInt((h >> 16) & 0xff)) / 255.0,
            .g = @as(f64, @floatFromInt((h >> 8) & 0xff)) / 255.0,
            .b = @as(f64, @floatFromInt(h & 0xff)) / 255.0,
            .a = a,
        };
    }
};

pub const colors = struct {
    // --surface-*
    pub const bg_app = Color.hex(0x0F1318); // --surface-window
    pub const bg_sunken = Color.hex(0x0A0D11); // --surface-sunken
    pub const bg_surface = Color.hex(0x131820); // --surface-titlebar
    pub const bg_surface_raised = Color.hex(0x171D26); // --surface-raised
    pub const bg_surface_overlay = Color.hexA(0x171D26, 0.88); // --surface-overlay

    // --border-* (white-alpha hairlines, drawn as inset box-shadows in the
    // prototype; a plain alpha-blended layer background reads the same way
    // over this app's uniformly dark chrome).
    pub const border_subtle = Color.hexA(0xFFFFFF, 0.06);
    pub const border_default = Color.hexA(0xFFFFFF, 0.10);
    pub const border_strong = Color.hexA(0xFFFFFF, 0.16);
    pub const hover = Color.hexA(0xFFFFFF, 0.05); // --surface-hover
    pub const selected = Color.hexA(0x5B55E0, 0.22); // --surface-selected (iris-500 @ 22%)

    // --text-*
    pub const text_primary = Color.hex(0xE6E9EE);
    pub const text_secondary = Color.hex(0x9AA3B2);
    pub const text_tertiary = Color.hex(0x6B7688);
    pub const text_disabled = Color.hex(0x465163);

    // Ember is the only UI accent (buttons, cursor, prompt symbol, focus
    // rings, selected states); success mirrors the terminal's ANSI green.
    pub const accent = Color.hex(0xF7802A); // --accent (ember-500)
    pub const accent_hover = Color.hex(0xFF9A4D); // --accent-hover (ember-400)
    pub const success = Color.hex(0x5BD08C); // --success (green-500)
};

/// tokens/typography.css font stacks. Real names for CTFontCreateWithName /
/// NSFont fontWithName:size:. Monaspace Radon and Geist are self-hosted web
/// fonts in the prototype, not guaranteed to be installed system-wide here;
/// `appkit.font()` falls back to a system font in the same voice when a
/// named family isn't found.
pub const fonts = struct {
    pub const display = "Monaspace Radon";
    pub const body = "Geist";
    pub const mono = "Monaspace Radon";
};

/// tokens/typography.css sizes, in points (1px == 1pt at AppKit's default
/// backing scale; Retina scaling is handled by the window's backing store).
/// Only the rungs Vigil's chrome actually uses.
pub const text_size = struct {
    pub const xs2: f64 = 10;
    pub const xs: f64 = 11;
    pub const sm: f64 = 12;
    pub const md: f64 = 13;
    pub const lg: f64 = 15;
};

/// tokens/radius.css corner radii. Only the rungs Vigil's chrome actually
/// uses; `pill` (999) is a "make it a capsule" sentinel, not a literal
/// point value -- see `appkit.panel`'s clamp.
pub const radius = struct {
    pub const xs: f64 = 3;
    pub const sm: f64 = 5;
    pub const md: f64 = 7;
    pub const lg: f64 = 10;
    pub const pill: f64 = 999;
};
