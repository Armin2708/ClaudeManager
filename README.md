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
- **Right-click a session** to focus, interrupt the current turn, terminate it safely, rename its panel label, or copy its resume command
- Optional recent-session rows let you resume finished Claude or Codex sessions in a new terminal tab
- Header counts (`2 working · 1 waiting`); panel dims when everything is idle
- Background right-click: install Claude/Codex tracking · show recent sessions · pause updates · launch at login · quit

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
4. Click **"Install Tracking"** when the app prompts

Either way, on first launch the app offers to register lifecycle tracking for both CLIs:

- Claude Code hooks in `~/.claude/settings.json`
- Codex hooks in `~/.codex/hooks.json`

Both files are backed up before modification. Codex requires one additional trust step: run `/hooks` inside Codex and approve the new ClaudeSessions entries. Until then, Codex discovery still works with the process/CPU fallback.

## Permissions

- **Automation → iTerm2 / Terminal** (prompted on first click / resume): exact-tab focus and opening resumed sessions. The app is ad-hoc signed, so rebuilding re-prompts once.
- **Accessibility** (optional): exact-window raising when VS Code/PyCharm has several windows open.

## How it works

Three parts, one contract:

1. **Lifecycle hooks** — the app binary handles both `--hook` (Claude) and `--codex-hook`. Claude writes to `~/.claude/session-status/`; Codex writes to `~/.codex/session-status/`. Events cover startup, prompts, permission waits, tools, stops, failures, session end, and subagents. Claude's `Stop` handler only marks **Done** when the session is genuinely finished (no running background tasks or scheduled wakeups).
2. **Panel** (`src/main.swift`, single-file AppKit) — polls `claude agents --json` every 2s for live sessions, overlays the hook statuses, reaps stale files.
3. **Local history** — recently observed resumable IDs and optional panel labels live in `~/Library/Application Support/ClaudeSessions/recent-sessions.json`. This is local-only and stores no transcript content.

Codex sessions remain visible without hooks through an interactive-process scan. With hooks installed and trusted, they gain stable IDs plus working, waiting, error, done, and subagent state instead of the CPU-only approximation.

Live management is deliberately process-safe: **Interrupt** sends `SIGINT` only after re-validating that the PID is still a Claude/Codex process; **Terminate** confirms first and sends `SIGTERM`. Resume uses the documented `claude --resume <id>` or `codex resume <id>` command in Terminal/iTerm.

## For developers

```bash
git clone https://github.com/Armin2708/ClaudeManager.git
cd ClaudeManager
bash scripts/build.sh       # compile + assemble the .app
bash scripts/package.sh     # build + produce dist/ClaudeSessions.zip
bash scripts/make-icon.sh   # regenerate assets/ClaudeSessions.icns
bash tests/run.sh           # compile + hooks + actions + package/install verification
```

`scripts/package.sh` rejects AppleDouble metadata, extracts the finished ZIP, and verifies the app's resource seal before succeeding.

Prefer a shell hook for Claude instead of the built-in binary hook? The bash route still works (requires `jq`): symlink `hooks/session-status.sh` to `~/.claude/hooks/` and register it for the same events in `~/.claude/settings.json`. The app detects either install.

Design spec: `docs/superpowers/specs/2026-07-09-claude-sessions-panel-design.md`

Built with Claude Code.
