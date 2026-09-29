# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.2] - 2026-09-28

### Fixed

- Committing a tab rename with Return (or by clicking away) now dismisses the
  inline edit field. The rename was applied, but the overlay stayed up until
  something else changed the tab list, making it look as though Enter did
  nothing.

## [0.1.1] - 2026-09-28

### Fixed

- No longer crashes on shell tab completion that rings the terminal bell
  (seen in zsh). The ring-bell action messaged a nonexistent
  `+[NSSound beep]` selector and now calls `NSBeep()`.
- The theme selector and keyboard-shortcuts sheet can be opened from the
  Preferences window, and from the menu while Preferences holds key focus.
  App-level commands now resolve to the most recently keyed main window
  instead of requiring a main window to currently be key.
- The terminal surface stays correctly scaled when the window moves between
  displays of different DPI. The backing layer's `contentsScale` is updated
  and the content scale and size are re-synced on screen changes, instead of
  the terminal appearing blown up or shrunk.
- App-wide (non-surface) engine actions are no longer dropped while
  Preferences holds key focus.
- The horizontal tab bar reflows when the window is resized, keeping its tabs
  and the new-tab button correctly positioned (previously they kept the width
  from the last tab-list update).
- The tab-bar rename guard is now per window, and an in-flight rename is no
  longer cancelled by a window closing or its tab list changing elsewhere.
- The terminal reports keyboard focus to the engine only while its window is
  key and the pane is the first responder. A visible pane in a background
  window was previously reported as focused.
- Guarded against `NSSegmentedControl` reporting no selected segment, which
  could previously panic while reading a preference.

### Changed

- Terminal surfaces are freed with the allocator they were created with,
  rather than an assumed global allocator.
- Documented that the overlays (command palette, theme gallery, shortcuts
  sheet) are intentionally single-instance app-wide, so opening one in a
  second window moves it rather than showing two at once.

## [0.1.0] - 2026-09-28

### Added

- Initial release: a native macOS terminal emulator built on libghostty with
  custom AppKit chrome. Includes tabs, split panes, a command palette, a
  theme gallery, a Preferences window, a keyboard-shortcuts sheet, and
  multi-window support.

[Unreleased]: https://github.com/craft-build/Vigil/compare/v0.1.2...HEAD
[0.1.2]: https://github.com/craft-build/Vigil/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/craft-build/Vigil/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/craft-build/Vigil/releases/tag/v0.1.0
