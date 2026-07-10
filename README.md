# ClaudeSessions

A native macOS panel that lives in and under your MacBook notch and shows every live [Claude Code](https://claude.com/claude-code) session at a glance — on every desktop/Space, over fullscreen apps — with live status and click-to-focus.

- One row per live session: terminal tab title (iTerm2) or session name, project folder, host-app glyph
- Status dot + label:
  - 🟢 **Working** (pulsing) — Claude is running
  - 🟡 **Waiting** — Claude is waiting on your input (question / permission)
  - 🟠 **Done** — finished, you haven't looked yet (clears when you click it)
  - 🔴 **Error** — the turn failed
  - ⚪ **Idle**
- Dynamic-Island-style collapse into the notch; drag the panel out into a floating card
- **Click a row** to jump to that session: exact iTerm2 tab (matched by tty), Terminal, VS Code / PyCharm project window
- **CLAUDE / CODEX** toggle in the header — also shows live OpenAI Codex CLI sessions
- Subagents appear nested inline under their parent session
- Header counts (`2 working · 1 waiting`); panel dims when everything is idle
- Right-click: Install Claude Code Hooks… · Pause updates · Launch at Login · Quit

## Install (30 seconds)

Requires macOS 13+ and Claude Code. No Homebrew, no jq, no terminal knowledge beyond option A's one command.

### Option A — one-liner

```bash
curl -fsSL https://raw.githubusercontent.com/Armin2708/ClaudeManager/main/install.sh | bash
```

Downloads the latest release, installs to `~/Applications`, removes the quarantine flag, and launches the app.

### Option B — manual

1. Download `ClaudeSessions.zip` from the [Releases page](https://github.com/Armin2708/ClaudeManager/releases)
2. Unzip and move `ClaudeSessions.app` to Applications
3. **Right-click the app → Open** the first time (needed once because the app is ad-hoc signed, not notarized, so Gatekeeper quarantines the download)
4. Click **"Install Hooks"** when the app prompts

Either way, on first launch the app offers to register its Claude Code hooks in `~/.claude/settings.json` (backing it up to `settings.json.bak` first). You can re-run this anytime from the right-click menu ("Install Claude Code Hooks…").

## Permissions

- **Automation → iTerm2** (prompted on first click / title fetch): tab titles and exact-tab focus. The app is ad-hoc signed, so rebuilding re-prompts once.
- **Accessibility** (optional): exact-window raising when VS Code/PyCharm has several windows open.

## How it works

Two parts, one contract:

1. **Hook** — the app binary doubles as the Claude Code hook: `ClaudeSessions --hook` reads the hook JSON on stdin and writes one status file per session to `~/.claude/session-status/<session_id>.json`. It's registered for 7 events (`UserPromptSubmit`, `Notification`, `Stop`, `StopFailure`, `SessionEnd`, `SubagentStart`, `SubagentStop`). The `Stop` handler only marks **Done** when the session is genuinely finished (no running background tasks, no scheduled wakeups).
2. **Panel** (`src/main.swift`, single-file AppKit) — polls `claude agents --json` every 2s for live sessions, overlays the hook statuses, reaps stale files.

Codex sessions need no hooks at all — the panel finds live OpenAI Codex CLI sessions via a process scan.

## For developers

```bash
git clone https://github.com/Armin2708/ClaudeManager.git
cd ClaudeManager
bash scripts/build.sh       # compile + assemble the .app
bash scripts/package.sh     # build + produce dist/ClaudeSessions.zip
bash scripts/make-icon.sh   # regenerate assets/ClaudeSessions.icns
```

Prefer a shell hook instead of the built-in binary hook? The bash route still works (requires `jq`): symlink `hooks/session-status.sh` to `~/.claude/hooks/` and register it for the same events in `~/.claude/settings.json`. The app detects either install.

Design spec: `docs/superpowers/specs/2026-07-09-claude-sessions-panel-design.md`

Built with Claude Code.
