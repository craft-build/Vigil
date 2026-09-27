# Vigil

A native macOS terminal emulator: custom AppKit chrome (built directly in Zig via
[zig-objc](https://github.com/mitchellh/zig-objc)) around a real
[libghostty](https://github.com/ghostty-org/ghostty) terminal engine (PTY, VT parsing, GPU/Metal
rendering, font shaping). UI is styled to match the Craft-design-system `Vigil.dc.html`
prototype. See `.claude` plan history for the full design rationale.

This is AI-assisted work (Claude Code) -- see `AI_POLICY.md` conventions from the vendored
ghostty project for the spirit of that disclosure, applied here to Vigil itself.

## Building

One-time setup:

```sh
git submodule update --init
brew install glslang
./scripts/build-ghostty.sh   # builds libghostty + relinks it as a dylib (~10-20 min cold)
```

Then, day to day:

```sh
zig build run
```

### Why the build is a two-step process

`scripts/build-ghostty.sh` builds `vendor/ghostty` (the vendored libghostty submodule) into
`vendor/ghostty/macos/GhosttyKit.xcframework`, then re-links its static archive into
`libghostty.dylib` with Apple's own `clang++`/`ld`. That relink step exists because several of
libghostty's largest bundled C++ translation units (glslang's parser, spirv-cross's GLSL
backend) overflow Zig 0.16's self-hosted Mach-O linker (`relocation ... Overflow`) when linked
directly into another Zig executable -- a Zig 0.16 linker limitation, not a libghostty problem.
Apple's linker doesn't have this bug, so we let it do that one link instead.

Re-run `scripts/build-ghostty.sh` after updating the `vendor/ghostty` submodule; `zig build run`
alone is enough for changes to Vigil's own `src/`.

## Packaging a `.app` / `.dmg`

Day-to-day development runs the bare `zig-out/bin/vigil` binary via `zig build run`. To build a
double-clickable app bundle and a distributable installer image instead, use the
[`just`](https://github.com/casey/just) recipes in `justfile`:

```sh
just app   # -> zig-out/Vigil.app (icon from logo.png, Info.plist, bundled libghostty.dylib)
just dmg   # -> zig-out/Vigil-<version>.dmg (Vigil.app + an Applications shortcut to drag into)
```

Both are ad-hoc codesigned (`codesign --sign -`) so Gatekeeper runs them on the machine that built
them; distributing further would need a real Developer ID signature and notarization, which isn't
set up here. Run `just` with no arguments to list all recipes.

## Status

A vertical slice: a real, interactive libghostty-backed shell renders inside chrome styled after
prototype Screen 01 ("Main window") -- pill tab bar, terminal + log-panel split, status bar.
Screens 02-06 (command palette, theme gallery, preferences, onboarding, shortcuts sheet) are not
built yet.
