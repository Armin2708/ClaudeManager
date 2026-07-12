# Claude Sessions Panel — Design

Approved 2026-07-09. Native macOS floating panel showing all live Claude Code sessions with 4-state status; hook-driven data layer; click-to-focus across host apps.

## 1. Placement & look

- Borderless non-activating `NSPanel`, HUD-style; `NSVisualEffectView` (`.hudWindow` material) frosted glass; auto light/dark.
- 12pt rounded corners, SF Pro, SF Symbols, system shadow.
- `level = .floating`; `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]` — visible on all Spaces and over fullscreen apps.
- Never steals focus (`.nonactivatingPanel`). Draggable; frame persisted in `UserDefaults`.
- Width ~280pt; height grows with rows. All-idle → panel fades to 30% opacity; any activity restores.

## 2. Row anatomy

`● name — project` + host-app glyph.

- Status dots: green pulsing = working; yellow (+soft row highlight) = waiting on you; orange ring = done-unseen; gray = idle.
- Sort: waiting → working → done-unseen → idle.
- Header: counts summary (e.g. "2 working · 1 waiting").

## 3. Data layer

Hook script `~/.claude/hooks/session-status.sh`, registered in global `~/.claude/settings.json`, writes `~/.claude/session-status/<session_id>.json`:

```json
{"session_id":"…","status":"working|waiting|done_unseen","cwd":"…","updated_at":1234567890,"event":"Stop"}
```

| Event | Effect |
|---|---|
| UserPromptSubmit | status=working (clears done-unseen) |
| Notification | status=waiting |
| Stop | done_unseen — but ONLY when the stop-sound guard passes (no running `background_tasks`, empty `session_crons`); otherwise stays working |
| SessionEnd | delete file |

Hook always exits 0; jq-missing or malformed stdin → no-op.

Panel polls `claude agents --json` every 2s (authoritative for which sessions exist; busy/idle fallback when no status file). Hook state overlays it. Status files with no matching live session are deleted by the panel.

## 4. Click-to-focus

Resolve host app by walking process ancestry from the session `pid`:

- iTerm2 / Terminal.app → AppleScript tab-level match by tty working directory (fallback: tab title contains session name).
- VS Code → `open -a "Visual Studio Code" <cwd>` (focuses existing per-folder window).
- PyCharm / JetBrains → `open -a PyCharm <cwd>`.
- Unknown → activate host app.

Click also rewrites done_unseen → idle (seen). One-time macOS Automation permission for iTerm2 scripting.

## 5. App lifecycle

- Single Swift file (`src/main.swift`), compiled by `scripts/build.sh` into `~/Applications/ClaudeSessions.app` (`LSUIElement=true` — no Dock icon).
- Launch at login via `SMAppService.mainApp`.
- Right-click context menu: Pause polling · Launch at login toggle · Quit.

## 6. Error handling & testing

- `claude agents` failing → keep last state, show "daemon unreachable" footer.
- Hook: never blocks Claude Code, exits 0 always.
- Tests: pipe-test hook with synthetic payloads per event; drive panel with fake status dir; live end-to-end.

## 7. v1.2 session-management extension (2026-07-12)

- Row context menus add Focus, Interrupt (`SIGINT`), confirmed Terminate (`SIGTERM`), persistent panel labels, and copyable resume commands. PID ownership is revalidated immediately before a signal is sent.
- Recently observed stable session IDs are retained locally for 30 days; a background-menu toggle shows up to eight recent rows per source. Clicking a recent row launches the documented `claude --resume <id>` or `codex resume <id>` command in Terminal/iTerm.
- Codex lifecycle hooks in `~/.codex/hooks.json` overlay process discovery with stable IDs and rich status: SessionStart→idle, UserPromptSubmit/PreToolUse→working, PermissionRequest→waiting, failed PostToolUse→error, Stop→done-unseen, plus subagent lifecycle rows. Hooks require one-time trust through Codex `/hooks`; CPU remains the fallback.
- Terminal.app focus now matches the process TTY before falling back to title. Warp, WezTerm, kitty, and Alacritty receive best-available window focus through process ancestry and Accessibility.
- Packaging strips extended attributes and resource forks before signing, prevents AppleDouble entries, then extracts and verifies the final ZIP. The installer verifies before replacing an existing app.
- `tests/run.sh` is the release gate, mirrored by macOS GitHub Actions: Swift typecheck/compile, shell syntax, Claude/Codex hook lifecycle, installer idempotence, snapshot mapping, resume commands, guarded process control, package extraction, and signature verification.
