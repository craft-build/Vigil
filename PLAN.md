# Vigil — remaining work

## Status

A vertical slice is done and working: a real libghostty-backed terminal (PTY, VT parsing,
GPU/Metal rendering — all libghostty's own code) renders inside custom AppKit chrome, driven
directly from Zig via [zig-objc](https://github.com/mitchellh/zig-objc), styled after Screen 01
("Main window") of the `Vigil.dc.html` prototype: pill tab bar, terminal + log-panel split,
status bar with a live status pill. See `README.md` for build/run instructions and
`src/ghostty/runtime.zig` / `src/app/TerminalSurface.zig` for the libghostty embedding itself.

Everything below is not built yet.

## Screens 02–06 (prototype UI not yet implemented)

Each should reuse `src/ui/theme.zig`'s tokens and the `appkit.panel`/`appkit.label` helpers in
`src/app/appkit.zig`, following the pattern in `src/ui/chrome.zig`.

- **Screen 02 — Command palette**: `⌘K` overlay over a dimmed/blurred session
  (`NSVisualEffectView` or a manually blurred layer), a search field, "Recent"/"Actions" sections
  with keycap chips. Needs a way to intercept `⌘K` globally within the window — likely an
  `NSEvent` local monitor (`addLocalMonitorForEventsMatchingMask:handler:`) rather than routing
  through the terminal surface's `keyDown:`.
- **Screen 03 — Theme gallery**: six palette cards. Wire selection to real libghostty config —
  `ghostty_surface_update_config` / `ghostty_config_t` palette fields — not just a visual swap.
- **Screen 04 — Preferences**: a settings sidebar (General/Appearance/Text/Keybindings/Shell)
  next to a rows-and-controls panel. Wire controls to real config: cursor style, background
  opacity/blur, font family/size, ligatures. Check `ghostty_config_get`/`ghostty_surface_update_config`
  in `vendor/ghostty/include/ghostty.h` for the config surface.
- **Screen 05 — First-run onboarding**: single window, "Import shell config" vs. "Start fresh".
  The import path needs to actually read the user's existing shell profile (zsh/bash/fish) —
  scope what "import" means concretely before implementing.
- **Screen 06 — Keyboard shortcuts sheet**: `⌘/` toggles a floating reference panel. Should
  reflect Vigil's *actual* keybindings, not just static prototype copy — implies keybindings need
  to be centrally defined first rather than hardcoded per-feature.

## Terminal engine integration gaps

Tracked as `TODO(roadmap)` comments in the source; listed here with more context.

- **`src/ghostty/runtime.zig` `action_cb`**: currently reports every libghostty action as
  unhandled. Needs to route `new_tab`, `close_tab`, `set_title`, `bell`, `toggle_fullscreen`, etc.
  into Vigil's own window/tab-bar state — this is the actual wiring needed before tabs/splits (see
  below) can work, since libghostty drives those via actions, not direct calls.
- **Clipboard**: done (`src/app/clipboard.zig`). Plain-text copy/paste via `NSPasteboard`;
  program-initiated access (OSC 52 / kitty) is denied until there's a confirmation prompt UI.
- **`close_surface_cb`**: currently terminates the app (single surface). Once there's more than
  one surface (tabs/splits), this needs to actually close the right pane/tab.
- **Backing scale factor**: done — read from the window/screen at creation, and re-synced on
  resize and `viewDidChangeBackingProperties` (display changes).
- **Keyboard/mouse input**: `unshifted_codepoint`, mouse buttons/motion (with a tracking area),
  and scrolling (precision + momentum) are done. Still missing: IME/marked-text support
  (`ghostty_surface_preedit` is never called) and mouse pressure/force-touch.
- **Multiple surfaces**: only one `ghostty_surface_t` ever exists. Real tabs (the tab bar is
  currently static labels, not functional) and splits (`ghostty_surface_split`) need a
  `TerminalSurface` per pane and a window/tab-bar model that tracks them, wired through the
  `action_cb` routing above.

## Other polish

- **Log pane** (`src/ui/chrome.zig` `buildLogPane`): static demo text. Real `tail -f`-style
  logging would need Vigil to actually emit structured logs somewhere and read them back, or hook
  into libghostty's own logging if it exposes one.
- **Window persistence**: window position/size, last-used tab, and preferences aren't saved
  between launches.
- **Font bundling**: `Space Grotesk` / `IBM Plex Sans` / `IBM Plex Mono` fall back to system fonts
  (`appkit.font()`) when not installed system-wide, which is the common case on a fresh machine.
  For a pixel-accurate match to the prototype, bundle the actual font files and register them via
  `CTFontManagerRegisterFontsForURL` at startup instead of relying on `fontWithName:size:` to find
  them on the system.
- **App icon / bundling**: currently runs as a bare `zig-out/bin/vigil` executable, not a signed
  `.app` bundle. Needs an `Info.plist`, icon, and `addInstallStep`-driven `.app` bundle assembly if
  this is meant to be a distributable Mac app rather than a dev binary.
