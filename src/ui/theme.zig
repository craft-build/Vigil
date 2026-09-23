//! Design tokens pulled from the Craft design system that the Vigil.dc.html
//! prototype (claude.ai/design project 40ad13c2-4512-40b3-b0f4-52c5a4ef375b)
//! imports: tokens/colors.css, tokens/typography.css, tokens/spacing.css,
//! tokens/effects.css.

/// sRGB color with 0-1 float components, the form AppKit/Core Animation want
/// (NSColor colorWithSRGBRed:green:blue:alpha:, CGColor components).
pub const Color = struct {
    r: f64,
    g: f64,
    b: f64,
    a: f64 = 1.0,

    fn hex(comptime h: u24) Color {
        return .{
            .r = @as(f64, @floatFromInt((h >> 16) & 0xff)) / 255.0,
            .g = @as(f64, @floatFromInt((h >> 8) & 0xff)) / 255.0,
            .b = @as(f64, @floatFromInt(h & 0xff)) / 255.0,
        };
    }
};

pub const colors = struct {
    // --bg-*
    pub const bg_app = Color.hex(0x060911);
    pub const bg_canvas = Color.hex(0x03050a);
    pub const bg_sunken = Color.hex(0x02040a);
    pub const bg_surface = Color.hex(0x0a0e1a);
    pub const bg_surface_raised = Color.hex(0x0f1424);
    pub const bg_surface_overlay = Color.hex(0x161d30);

    // --border-*
    pub const border_subtle = Color.hex(0x1b2338);
    pub const border_default = Color.hex(0x28324c);
    pub const border_strong = Color.hex(0x3a4664);

    // --text-*
    pub const text_primary = Color.hex(0xf7f8fb);
    pub const text_secondary = Color.hex(0xa6acc0);
    pub const text_tertiary = Color.hex(0x5b6784);
    pub const text_disabled = Color.hex(0x40485f);

    // brand gradient stops + accents
    pub const blue_500 = Color.hex(0x4f8dff);
    pub const blue_400 = Color.hex(0x6fa8ff);
    pub const violet_500 = Color.hex(0x9457f2);
    pub const magenta_500 = Color.hex(0xe13fea);
    pub const cyan_500 = Color.hex(0x22d3ee);
    pub const green_500 = Color.hex(0x3ddc84);
    pub const amber_500 = Color.hex(0xf0a93e);
    pub const red_500 = Color.hex(0xf0455f);
};

/// tokens/typography.css font stacks. Real names for CTFontCreateWithName /
/// NSFont fontWithName:size:.
pub const fonts = struct {
    pub const display = "Space Grotesk";
    pub const body = "IBM Plex Sans";
    pub const mono = "IBM Plex Mono";
};

/// tokens/typography.css sizes, in points (1px == 1pt at AppKit's default
/// backing scale; Retina scaling is handled by the window's backing store).
pub const text_size = struct {
    pub const xs2: f64 = 11;
    pub const xs: f64 = 12;
    pub const sm: f64 = 13;
    pub const base: f64 = 14.5;
    pub const md: f64 = 16;
    pub const lg: f64 = 19;
    pub const xl: f64 = 24;
    pub const xl2: f64 = 32;
    pub const xl3: f64 = 44;
};

/// tokens/spacing.css near-4px scale.
pub const space = struct {
    pub const s1: f64 = 2;
    pub const s2: f64 = 4;
    pub const s3: f64 = 6;
    pub const s4: f64 = 8;
    pub const s5: f64 = 12;
    pub const s6: f64 = 16;
    pub const s7: f64 = 20;
    pub const s8: f64 = 24;
};

/// tokens/spacing.css corner radii.
pub const radius = struct {
    pub const xs: f64 = 4;
    pub const sm: f64 = 6;
    pub const md: f64 = 8;
    pub const lg: f64 = 12;
    pub const xl: f64 = 16;
    pub const pill: f64 = 999;
};
