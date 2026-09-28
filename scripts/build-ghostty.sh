#!/usr/bin/env bash
# Builds GhosttyKit.xcframework from the vendored libghostty checkout.
# This is the terminal engine (PTY, VT parsing, GPU/Metal rendering, font
# shaping) that Vigil's AppKit shell embeds. Run once after cloning, and
# again after updating the vendor/ghostty submodule; the nested `zig build`
# is incrementally cached so repeat runs after the first are fast.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../vendor/ghostty"

zig build \
  -Demit-xcframework=true \
  -Dxcframework-target=native \
  -Demit-macos-app=false \
  -Doptimize=ReleaseSmall

# A handful of libghostty-internal.a's largest C++ translation units
# (glslang's parser, spirv-cross's GLSL backend) overflow Zig 0.16's
# self-hosted Mach-O linker (relocation "Overflow") when linked directly
# into another Zig executable, regardless of optimize level or -fsys
# system-integration attempts (tried and abandoned -- see git history).
# Apple's own linker doesn't have this bug, so pre-link the static archive
# into a dylib with it; Vigil's build.zig links against that dylib instead
# of the raw .a.
# Discover the slice like build.zig's findXcframeworkSlice does -- the
# directory name varies ("macos-arm64", "macos-arm64_x86_64", ...) with the
# xcframework target, so don't hardcode an arch string.
SLICE_DIR="$(find "$(dirname "${BASH_SOURCE[0]}")/../vendor/ghostty/macos/GhosttyKit.xcframework" \
  -maxdepth 1 -type d -name 'macos-*' | head -n1)"
[[ -n "$SLICE_DIR" ]] || { echo "no macos-* slice found"; exit 1; }
# Write to a temp file and rename so an interrupted clang++ can't leave a
# half-written dylib behind.
clang++ -shared \
  -o "$SLICE_DIR/libghostty.dylib.tmp" \
  -Wl,-force_load,"$SLICE_DIR/libghostty-internal.a" \
  -framework AppKit -framework Foundation -framework Metal -framework MetalKit \
  -framework QuartzCore -framework CoreText -framework CoreGraphics \
  -framework CoreFoundation -framework CoreVideo -framework IOSurface -framework Carbon \
  -framework GameController \
  -lobjc -lc++ \
  -install_name "@rpath/libghostty.dylib"
mv "$SLICE_DIR/libghostty.dylib.tmp" "$SLICE_DIR/libghostty.dylib"

echo "libghostty.dylib relinked at $SLICE_DIR/libghostty.dylib"

echo "GhosttyKit.xcframework ready at vendor/ghostty/macos/GhosttyKit.xcframework"
