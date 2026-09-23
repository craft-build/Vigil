//! Raw translation of libghostty's embedder API (vendor/ghostty/include/ghostty.h).
//! That header explicitly documents itself as tailored to the macOS app, not a
//! stable public API -- this binding may need updates when vendor/ghostty is
//! bumped.
pub const c = @cImport({
    @cInclude("ghostty.h");
});
