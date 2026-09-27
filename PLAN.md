# Vigil — remaining work

## Status

A vertical slice is done and working: a real libghostty-backed terminal (PTY, VT parsing,
GPU/Metal rendering — all libghostty's own code) renders inside custom AppKit chrome, driven
directly from Zig via [zig-objc](https://github.com/mitchellh/zig-objc), styled after Screen 01
("Main window") of the `Vigil.dc.html` prototype: pill tab bar, terminal + log-panel split,
status bar with a live status pill. See `README.md` for build/run instructions and
`src/ghostty/runtime.zig` / `src/app/TerminalSurface.zig` for the libghostty embedding itself.

Everything below is not built yet.

## Testing

`zig build test` runs unit tests (currently the keybinding registry, including one against a
real default libghostty config).

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
  reflect Vigil's *actual* keybindings, not just static prototype copy. The registry it needs now
  exists: `src/app/keybindings.zig` lists commands and resolves each one's shortcut from the live
  libghostty config (so user `keybind` overrides show), with `format` for ⌘⇧T-style glyphs and
  `perform` to run one. Remaining for this screen: the panel UI and the `⌘/` toggle. Vigil-owned
  shortcuts (⌘K palette, ⌘/) aren't libghostty actions, so they'll need a small static entry type
  alongside the existing `Command` when those screens land. ⌘K is unbound by default in
  libghostty's config, so it's free for the palette.

## Terminal engine integration gaps

Tracked as `TODO(roadmap)` comments in the source; listed here with more context.

- **Action routing / tabs**: done for tabs (`src/app/Window.zig`). `new_tab`, `close_tab` (this
  tab only), `goto_tab`, `move_tab`, `set_title`/`set_tab_title`, `ring_bell`, `toggle_fullscreen`,
  `quit`, `close_window` are handled; the tab bar is a live, clickable model. Still unhandled:
  `new_split`/`goto_split`/etc. (splits), `new_window`, `toggle_command_palette` (Screen 02),
  `pwd` (could feed the status bar), `desktop_notification`, `open_url`, `config_change`.
- **Clipboard**: done (`src/app/clipboard.zig`). Plain-text copy/paste via `NSPasteboard`;
  program-initiated access (OSC 52 / kitty) is denied until there's a confirmation prompt UI.
- **`close_surface_cb`**: closes the owning tab (quits on the last). No confirm prompt when a
  process is still running; splits will need per-pane handling.
- **Backing scale factor**: done — read from the window/screen at creation, and re-synced on
  resize and `viewDidChangeBackingProperties` (display changes).
- **Keyboard/mouse input**: `unshifted_codepoint`, mouse buttons/motion (with a tracking area),
  and scrolling (precision + momentum) are done. Still missing: IME/marked-text support
  (`ghostty_surface_preedit` is never called) and mouse pressure/force-touch.
- **Splits**: tabs exist (one `TerminalSurface` each), but there is no pane layout yet.
  `ghostty_surface_split` and the split actions need a per-tab pane tree and layout code.

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
