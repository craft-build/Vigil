# Vigil build & packaging tasks. `zig build` / `zig build run` still work
# directly for day-to-day development (see README.md); these wrap that plus
# the native macOS packaging steps that turn the raw binary into a
# double-clickable `.app` and a distributable `.dmg`.

app_name := "Vigil"
bundle_id := "com.vigil.Vigil"
version := `awk -F'"' '/\.version = /{print $2; exit}' build.zig.zon`
out_dir := "zig-out"
app_bundle := out_dir / (app_name + ".app")
ghostty_slice := "vendor/ghostty/macos/GhosttyKit.xcframework/macos-arm64"

# List available recipes.
default:
    @just --list

# Day-to-day dev build (unoptimized); see README.md for the one-time setup.
build:
    zig build

# Build and run Vigil directly from zig-out, not from the .app bundle.
run *args:
    zig build run -- {{ args }}

# Run the unit test suite.
test:
    zig build test --summary all

# One-time, and again after updating the vendor/ghostty submodule.
# Build vendored libghostty.dylib.
ghostty:
    ./scripts/build-ghostty.sh

# Regenerate zig-out/AppIcon.icns from logo.png.
icon:
    #!/usr/bin/env bash
    set -euo pipefail
    rm -rf {{ out_dir }}/AppIcon.iconset
    mkdir -p {{ out_dir }}/AppIcon.iconset
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    # logo.png is pre-squircled but not quite square (a few dozen px off) --
    # crop it centered to square rather than stretch, so the squircle
    # corners stay uniform.
    w=$(sips -g pixelWidth logo.png | awk '/pixelWidth/{print $2}')
    h=$(sips -g pixelHeight logo.png | awk '/pixelHeight/{print $2}')
    side=$(( w < h ? w : h ))
    sips -c "$side" "$side" logo.png --out "$tmp/square.png" >/dev/null
    for size in 16 32 128 256 512; do
        sips -z "$size" "$size" "$tmp/square.png" \
            --out "{{ out_dir }}/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
        double=$((size * 2))
        sips -z "$double" "$double" "$tmp/square.png" \
            --out "{{ out_dir }}/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns {{ out_dir }}/AppIcon.iconset -o {{ out_dir }}/AppIcon.icns
    echo "Wrote {{ out_dir }}/AppIcon.icns"

# Ad-hoc signed so Gatekeeper on this machine runs it without complaint;
# distributing it further would need a real Developer ID signature and
# notarization, which is out of scope here.
# Assemble zig-out/Vigil.app (binary, icon, Info.plist, bundled libghostty.dylib).
app: build icon
    #!/usr/bin/env bash
    set -euo pipefail
    rm -rf "{{ app_bundle }}"
    mkdir -p "{{ app_bundle }}/Contents/MacOS" "{{ app_bundle }}/Contents/Resources" "{{ app_bundle }}/Contents/Frameworks"
    cp {{ out_dir }}/bin/vigil "{{ app_bundle }}/Contents/MacOS/{{ app_name }}"
    cp {{ out_dir }}/AppIcon.icns "{{ app_bundle }}/Contents/Resources/AppIcon.icns"
    sed -e 's/__VERSION__/{{ version }}/g' -e 's/__BUNDLE_ID__/{{ bundle_id }}/g' \
        packaging/Info.plist > "{{ app_bundle }}/Contents/Info.plist"
    cp {{ ghostty_slice }}/libghostty.dylib "{{ app_bundle }}/Contents/Frameworks/libghostty.dylib"
    # The dev binary's rpath points at this checkout's vendor/ directory
    # (see build.zig); repoint the bundled copy at its own Frameworks dir
    # instead so the .app doesn't depend on this machine's file layout.
    install_name_tool -add_rpath "@executable_path/../Frameworks" "{{ app_bundle }}/Contents/MacOS/{{ app_name }}"
    install_name_tool -delete_rpath "$(pwd)/{{ ghostty_slice }}" "{{ app_bundle }}/Contents/MacOS/{{ app_name }}"
    codesign --force --sign - "{{ app_bundle }}/Contents/Frameworks/libghostty.dylib"
    codesign --force --sign - "{{ app_bundle }}"
    echo "Built {{ app_bundle }}"

# Contains Vigil.app and an Applications shortcut to drag it into.
# Build a distributable zig-out/Vigil-<version>.dmg installer image.
dmg: app
    #!/usr/bin/env bash
    set -euo pipefail
    stage=$(mktemp -d)
    trap 'rm -rf "$stage"' EXIT
    cp -R "{{ app_bundle }}" "$stage/{{ app_name }}.app"
    ln -s /Applications "$stage/Applications"
    dmg_path="{{ out_dir }}/{{ app_name }}-{{ version }}.dmg"
    rm -f "$dmg_path"
    hdiutil create -volname "{{ app_name }}" -srcfolder "$stage" -ov -format UDZO "$dmg_path"
    echo "Wrote $dmg_path"

# Remove all build output.
clean:
    rm -rf {{ out_dir }} .zig-cache
