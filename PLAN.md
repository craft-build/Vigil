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

- **Screen 02 — Command palette**: done (`src/ui/palette.zig`). Opens on libghostty's
  `toggle_command_palette` action (⇧⌘P by default; ⌘K stays with clear-screen), filters the
  keybinding registry (substring matches first, then in-order subsequences), ↑/↓/↩/⎋ to
  navigate/run/close. Vigil-owned commands (`VigilAction`, currently just the shortcuts sheet)
  live in the registry alongside libghostty actions. Known limits: the query is drawn by hand
  (no NSTextField), so no IME, paste or mid-string editing; there's no "Recent" section (needs
  usage tracking); running a command with a live process is unguarded.
- **Screen 03 — Theme gallery**: done (`src/ui/theme_gallery.zig`, `src/app/themes.zig`). Six
  built-in palettes (Vigil Midnight, Tokyo Night, Nord, Dracula, Gruvbox Dark, Solarized Dark —
  chosen by me; swap in the prototype's six if they differ) written as real config keys
  (`background`, `foreground`, `cursor-color`, `selection-*`, `palette = N=#hex`). Opened from the
  palette ("Choose theme…"; no dedicated shortcut yet); clicking a card or ↩ applies it live.
  Verified: applying a theme writes the overrides file and a rebuilt config reports the new
  background. Not covered: themes other than these six (e.g. ghostty's bundled `theme =` files,
  which need the resources dir) and light/dark auto-switching.

## Config layer (`src/app/settings.zig`)

Vigil-owned settings live in `~/Library/Application Support/Vigil/config` (ghostty `key = value`
syntax), loaded after the user's own Ghostty config so Vigil wins. Changing a setting =
`store` edit → `save()` → `apply(app)` (`ghostty_app_update_config`, which updates every
surface). `⇧⌘,` (`reload_config`) re-reads the file. Screen 04 (preferences) should build on this:
add a setter per control, call `settings.save()` + `settings.apply(app)`. Limits: configs handed
to libghostty are never freed (small leak per change); a hand-edited overrides file loses
comments on the next save.

- **Screen 04 — Preferences**: done (`src/ui/preferences_window.zig`, model in
  `src/app/preferences.zig`). A separate native window (⌘, or palette → "Preferences…") with a
  five-section sidebar and native AppKit controls generated from a settings table. Wired to real
  config: mouse-hide, window padding, cursor style, background opacity + blur, font family/size,
  ligatures (via `font-feature = -calt/-liga/-dlig`), shell integration; theme and shortcuts
  buttons open those screens. Verified end to end: values written through the model come back
  from libghostty's effective config, and opacity < 1 makes the window non-opaque.
  Limits: opacity/blur only affect the terminal area (chrome bars stay solid); blur and padding
  read only Vigil's overrides file (libghostty's C API can't return those types), so a value set
  in the user's own Ghostty config isn't reflected in the control; font family is free text with
  no font picker or validation; cursor blink, scrollback, and `command` aren't exposed;
  Keybindings is a pointer to the shortcuts sheet, not an editor. Not yet exercised by hand:
  clicking/dragging the controls themselves.
- **Screen 05 — First-run onboarding**: skipped by decision, not oversight. Vigil is for the
  author and other people already comfortable with Ghostty-based terminals, so a first-run wizard
  isn't worth building.
- **Screen 06 — Keyboard shortcuts sheet**: `⌘/` toggles a floating reference panel. Should
  reflect Vigil's *actual* keybindings, not just static prototype copy. The registry it needs now
  exists: `src/app/keybindings.zig` lists commands and resolves each one's shortcut from the live
  libghostty config (so user `keybind` overrides show), with `format` for ⌘⇧T-style glyphs and
  `perform` to run one. The panel and `⌘/` toggle are done (`src/ui/shortcuts_sheet.zig`, `src/app/keymonitor.zig` — an
  NSEvent local monitor, reusable for the palette). Caveats: libghostty's reverse lookup skips
  binds flagged `performable`, which is how its macOS defaults for ⌘C/⌘V/⌘K are declared, so
  Copy/Paste use a `fallback_keys` hint and Clear screen shows "—" although ⌘K does work.
  **⌘K is bound to `clear_screen` by default**, so the palette uses ⇧⌘P instead. Vigil-owned
  shortcuts (⌘/) are registry entries with `vigil` set, so they appear in the sheet and palette.

## Terminal engine integration gaps

Tracked as `TODO(roadmap)` comments in the source; listed here with more context.

- **Action routing / tabs**: done for tabs (`src/app/Window.zig`). `new_tab`, `close_tab` (whole
  tab, this-tab mode only), `goto_tab`, `move_tab`, `set_title`/`set_tab_title`, `ring_bell`,
  `toggle_fullscreen`, `quit`, `close_window` are handled; the tab bar is a live, clickable model.
  Splits are now handled too (see below). Still unhandled: `new_window`, `pwd` (could feed a status
  indicator), `desktop_notification`, `open_url`.
- **Tab titles**: done. `set_title`/`set_tab_title` (shell integration, OSC title sequences) update
  the tab live; double-clicking a tab pill opens an inline `NSTextField` to rename it by hand
  (Return or clicking away commits, Esc cancels, blank text reverts to automatic). A manually
  renamed tab stops accepting automatic updates (`Tab.manual_title` in `Window.zig`) until renamed
  blank again. Caught in testing: removing the rename field while it's still the active first
  responder makes AppKit resign it, which re-fires its commit action reentrantly (real path: our
  own `populateTabs` cleanup, not something a real Return keypress should hit, but guarded either
  way) -- see `handling_end` in `src/ui/chrome.zig`.
- **Clipboard**: done (`src/app/clipboard.zig`). Plain-text copy/paste via `NSPasteboard`;
  program-initiated access (OSC 52 / kitty) is denied until there's a confirmation prompt UI.
- **`close_surface_cb`**: closes the owning pane (`Window.closePane`) — collapses the split if the
  tab has others, else closes the whole tab (quits on the last tab). No confirm prompt when a
  process is still running.
- **Backing scale factor**: done — read from the window/screen at creation, and re-synced on
  resize and `viewDidChangeBackingProperties` (display changes).
- **Keyboard/mouse input**: `unshifted_codepoint`, mouse buttons/motion (with a tracking area),
  and scrolling (precision + momentum) are done. Still missing: IME/marked-text support
  (`ghostty_surface_preedit` is never called) and mouse pressure/force-touch.
- **Splits**: done. `src/app/pane.zig` holds the tree (`Tree(Leaf)`, generic so its shape/geometry
  logic is unit-tested — 14 tests — without touching AppKit) and the pure rect math
  (`splitRect`/`dividerRect`/`ratioForPoint`); `src/app/Window.zig` applies it to real
  `TerminalSurface`s. Handles: `new_split` (right/down/left/up), `goto_split`
  (previous/next by tree order; up/down/left/right by nearest-center geometric neighbor among the
  tab's panes — not a rigorous tiling-WM algorithm, but a reasonable fit for the 2-4 pane layouts
  this app is actually used with), `resize_split` (moves the nearest matching-axis ancestor split's
  divider by the given amount; a defensible reading of a keyboard-only secondary feature, not
  necessarily "grow the focused pane" the way tmux/Ghostty's own app might interpret it —
  unverified against the real app), `equalize_splits`, `toggle_split_zoom`. Dividers are draggable
  (`VigilSplitDivider`, plain `mouseDragged:`, no resize-cursor on hover yet). Clicking a pane
  focuses it (`TerminalSurface.on_click`). All of tabs.items[]'s leaves now have their
  autoresizing mask cleared and are laid out manually on every content resize (the window's content
  view is a custom `VigilContentView` whose `setFrameSize:` triggers `relayoutAll`), since ratio
  splits aren't expressible via autoresizing masks. Verified end to end via `handleAction`/
  `closePane` calls and a rendered snapshot (a 3-pane `[left | [top / bottom]]` layout came out
  with both dividers in the right places): split creates a pane and moves focus; a second split
  makes three; `goto_split next` moves focus; equalize and zoom/un-zoom toggle; closing a pane
  collapses the tree without touching the tab count; closing a tab's last pane closes the tab; the
  palette's "Close pane" (`ghostty_surface_binding_action(..., "close_surface", ...)`) reaches the
  same close path as a direct call. Not exercised interactively: dragging a divider by hand, and
  clicking between panes to change focus (both depend on live mouse events I can't synthesize
  here). No visual highlight on the focused pane. A real bug turned up in testing before any of
  this was wired up: `splitRect`'s vertical branch computed `ratio` as *second's* share while the
  horizontal branch used *first's* share — caught by adding an asymmetric-ratio test after a
  symmetric 0.5 one didn't reveal the inconsistency.

## Other polish

- **Window persistence**: window position/size, last-used tab, and preferences aren't saved
  between launches.
- **Font bundling**: `Space Grotesk` / `IBM Plex Sans` / `IBM Plex Mono` fall back to system fonts
  (`appkit.font()`) when not installed system-wide, which is the common case on a fresh machine.
  For a pixel-accurate match to the prototype, bundle the actual font files and register them via
  `CTFontManagerRegisterFontsForURL` at startup instead of relying on `fontWithName:size:` to find
  them on the system.
- **App icon / bundling**: done. `just app` assembles `zig-out/Vigil.app` (icon generated from
  `logo.png`, `packaging/Info.plist`, a bundled + rpath-fixed copy of `libghostty.dylib`, ad-hoc
  codesigned) and `just dmg` wraps that in a drag-to-`/Applications` `zig-out/Vigil-<version>.dmg`.
  See the justfile. Limits: ad-hoc signed only (no Developer ID/notarization, so Gatekeeper will
  still warn on another Mac); `LSMinimumSystemVersion` (13.0) is a guess, not verified against
  actual API usage.
- **Menu bar**: done (`src/app/menu.zig`). A real `NSMenu`-based main menu (Vigil/File/Edit/View/
  Window/Help), generated from `keybindings.commands` so its labels and key equivalents track the
  live config instead of being hand-duplicated; dispatch goes through the same `palette.on_run`
  path the command palette uses. Standard items (About, Hide, Quit, Minimize/Zoom/Bring All to
  Front) use the nil-targeted responder chain instead. Key equivalents are derived from each
  command's real trigger (letters uppercase for Shift, punctuation mapped to its shifted glyph,
  e.g. `[` → `{`) rather than guessed, since `-[NSMenu performKeyEquivalent:]` runs before
  `TerminalSurface`'s `keyDown:` and a wrong one would shadow the real binding. Limits: no
  `validateMenuItem:` (items are never disabled/checked, e.g. there's no checkmark for the active
  theme); assumes the single-window model everywhere else in the app already assumes.
