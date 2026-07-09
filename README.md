# ClaudeManager

A native macOS floating panel that shows all your live [Claude Code](https://claude.com/claude-code) sessions at a glance — on every desktop/Space, over fullscreen apps — with live status and click-to-focus.

## What it shows

- One row per live Claude Code session: **terminal tab title** (iTerm2) or session name, project folder, host-app glyph
- Status dot + written label:
  - 🟢 **Working** (pulsing) — Claude is running
  - 🟡 **Waiting** — Claude is waiting on your input (question / permission)
  - 🟠 **Done** — finished, you haven't looked yet (clears when you click it)
  - 🔴 **Error** — the turn failed
  - ⚪ **Idle**
- Header counts (`2 working · 1 waiting`); panel dims to 30% when everything is idle
- **Click a row** to jump to that session: exact iTerm2 tab (matched by tty), VS Code / PyCharm project window
- Right-click: Pause updates · Launch at Login · Quit

## How it works

Two parts, one contract:

1. **Hook script** (`hooks/session-status.sh`) — registered for `UserPromptSubmit`, `Notification`, `Stop`, `StopFailure`, `SessionEnd` in `~/.claude/settings.json`. Writes one JSON status file per session to `~/.claude/session-status/`. The `Stop` handler only marks **Done** when the session is genuinely finished (no running background tasks, no scheduled wakeups).
2. **Panel app** (`src/main.swift`, single-file AppKit) — polls `claude agents --json` every 2s for live sessions, overlays the hook statuses, reaps stale files.

## Install

```bash
git clone https://github.com/Armin2708/ClaudeManager.git
cd ClaudeManager
bash scripts/package.sh          # builds ~/Applications/ClaudeSessions.app + dist/ClaudeSessions.zip
ln -sf "$PWD/hooks/session-status.sh" ~/.claude/hooks/session-status.sh
open ~/Applications/ClaudeSessions.app
```

Then register the hook for the five events in `~/.claude/settings.json`:

```json
"hooks": {
  "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "~/.claude/hooks/session-status.sh", "timeout": 5 }] }],
  "Notification":     [{ "hooks": [{ "type": "command", "command": "~/.claude/hooks/session-status.sh", "timeout": 5 }] }],
  "Stop":             [{ "hooks": [{ "type": "command", "command": "~/.claude/hooks/session-status.sh", "timeout": 5 }] }],
  "StopFailure":      [{ "hooks": [{ "type": "command", "command": "~/.claude/hooks/session-status.sh", "timeout": 5 }] }],
  "SessionEnd":       [{ "hooks": [{ "type": "command", "command": "~/.claude/hooks/session-status.sh", "timeout": 5 }] }]
}
```

Requires: macOS 13+, `jq`, Claude Code.

### Permissions

- **Automation → iTerm2** (prompted on first click / title fetch): tab titles and exact-tab focus. The app is ad-hoc signed, so rebuilding re-prompts once.
- **Accessibility** (optional): exact-window raising when VS Code/PyCharm has several windows open.

## Development

```bash
bash scripts/build.sh     # compile + assemble the .app
bash scripts/make-icon.sh # regenerate assets/ClaudeSessions.icns
```

Design spec: `docs/superpowers/specs/2026-07-09-claude-sessions-panel-design.md`

Built with Claude Code.
