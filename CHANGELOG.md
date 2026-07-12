# Changelog

## 1.2.0 — 2026-07-12

### Added

- Per-session Focus, Interrupt, Terminate, Rename Panel Label, Copy Resume Command, and Forget actions.
- Optional recent Claude/Codex rows with one-click resume in Terminal or iTerm2.
- Codex lifecycle-hook installer and hook-backed working, waiting, error, done, and subagent states.
- Stable local recent-session history with no transcript content.
- Warp, WezTerm, kitty, and Alacritty host detection.
- Automated macOS CI and end-to-end release verification.

### Fixed

- Strip extended attributes/resource forks so release ZIPs no longer contain AppleDouble files that invalidate the app signature.
- Verify downloaded release integrity before replacing an installed copy.
- Match Terminal.app tabs by TTY before title fallback.
- Enforce process timeouts and coalesce overlapping polling work.
- Preserve hook metadata and child rows when marking a session as seen.
