#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/ClaudeSessions"
CLAUDE_NATIVE="$TMP/status-claude-native"
CLAUDE_BASH="$TMP/status-claude-bash"
CODEX_STATUS="$TMP/status-codex"
mkdir -p "$CLAUDE_NATIVE" "$CLAUDE_BASH" "$CODEX_STATUS"

cd "$ROOT"

swiftc -typecheck src/main.swift
swiftc src/main.swift -o "$BIN"
bash -n hooks/session-status.sh install.sh scripts/build.sh scripts/package.sh scripts/make-icon.sh

run_claude_event() {
  local payload="$1"
  printf '%s' "$payload" | env \
    SESSION_STATUS_DIR="$CLAUDE_NATIVE" \
    CLAUDE_SESSION_AGENT_PID=4343 \
    "$BIN" --hook
  printf '%s' "$payload" | env SESSION_STATUS_DIR="$CLAUDE_BASH" bash hooks/session-status.sh
}

compare_claude_status() {
  diff \
    <(jq -S 'del(.updated_at, .pid, .source)' "$CLAUDE_NATIVE/session-claude.json") \
    <(jq -S 'del(.updated_at, .pid, .source)' "$CLAUDE_BASH/session-claude.json")
}

run_claude_event '{"hook_event_name":"SessionStart","session_id":"session-claude","cwd":"/tmp/demo","source":"startup"}'
compare_claude_status
jq -e '.status == "idle" and .children == []' "$CLAUDE_NATIVE/session-claude.json" >/dev/null

run_claude_event '{"hook_event_name":"UserPromptSubmit","session_id":"session-claude","cwd":"/tmp/demo"}'
compare_claude_status
jq -e '.status == "working"' "$CLAUDE_NATIVE/session-claude.json" >/dev/null

run_claude_event '{"hook_event_name":"SubagentStart","session_id":"session-claude","cwd":"/tmp/demo","agent_id":"agent-1","agent_name":"reviewer"}'
compare_claude_status
jq -e '.children == [{"id":"agent-1","kind":"agent","name":"reviewer"}]' "$CLAUDE_NATIVE/session-claude.json" >/dev/null

run_claude_event '{"hook_event_name":"Stop","session_id":"session-claude","cwd":"/tmp/demo","background_tasks":[{"id":"task-1","type":"shell","status":"running","description":"build"}],"session_crons":[]}'
compare_claude_status
jq -e '.status == "working" and ([.children[].id] | sort) == ["agent-1","task-1"]' "$CLAUDE_NATIVE/session-claude.json" >/dev/null

run_claude_event '{"hook_event_name":"Stop","session_id":"session-claude","cwd":"/tmp/demo","background_tasks":[],"session_crons":[]}'
compare_claude_status
jq -e '.status == "done_unseen" and [.children[].id] == ["agent-1"]' "$CLAUDE_NATIVE/session-claude.json" >/dev/null

run_claude_event '{"hook_event_name":"SubagentStop","session_id":"session-claude","cwd":"/tmp/demo","agent_id":"agent-1"}'
compare_claude_status
jq -e '.children == []' "$CLAUDE_NATIVE/session-claude.json" >/dev/null

run_claude_event '{"hook_event_name":"Notification","session_id":"session-claude","cwd":"/tmp/demo"}'
compare_claude_status
jq -e '.status == "waiting"' "$CLAUDE_NATIVE/session-claude.json" >/dev/null

run_claude_event '{"hook_event_name":"StopFailure","session_id":"session-claude","cwd":"/tmp/demo"}'
compare_claude_status
jq -e '.status == "error"' "$CLAUDE_NATIVE/session-claude.json" >/dev/null

run_claude_event '{"hook_event_name":"SessionEnd","session_id":"session-claude","cwd":"/tmp/demo"}'
test ! -e "$CLAUDE_NATIVE/session-claude.json"
test ! -e "$CLAUDE_BASH/session-claude.json"

run_codex_event() {
  local payload="$1"
  local output
  output=$(printf '%s' "$payload" | env \
    CODEX_SESSION_STATUS_DIR="$CODEX_STATUS" \
    CODEX_SESSION_AGENT_PID=4242 \
    "$BIN" --codex-hook)
  test "$output" = "{}"
}

run_codex_event '{"hook_event_name":"SessionStart","session_id":"session-codex","cwd":"/tmp/codex-demo","source":"startup"}'
jq -e '.status == "idle" and .pid == 4242 and .source == "codex"' "$CODEX_STATUS/session-codex.json" >/dev/null
run_codex_event '{"hook_event_name":"UserPromptSubmit","session_id":"session-codex","cwd":"/tmp/codex-demo","turn_id":"turn-1","prompt":"ship it"}'
jq -e '.status == "working" and .turn_id == "turn-1"' "$CODEX_STATUS/session-codex.json" >/dev/null
run_codex_event '{"hook_event_name":"PermissionRequest","session_id":"session-codex","cwd":"/tmp/codex-demo","turn_id":"turn-1","tool_name":"Bash"}'
jq -e '.status == "waiting"' "$CODEX_STATUS/session-codex.json" >/dev/null
run_codex_event '{"hook_event_name":"PreToolUse","session_id":"session-codex","cwd":"/tmp/codex-demo","turn_id":"turn-1","tool_name":"Bash","tool_input":{"command":"false"}}'
jq -e '.status == "working"' "$CODEX_STATUS/session-codex.json" >/dev/null
run_codex_event '{"hook_event_name":"PostToolUse","session_id":"session-codex","cwd":"/tmp/codex-demo","turn_id":"turn-1","tool_name":"Bash","tool_response":{"success":false,"exit_code":1}}'
jq -e '.status == "error"' "$CODEX_STATUS/session-codex.json" >/dev/null
run_codex_event '{"hook_event_name":"SubagentStart","session_id":"session-codex","cwd":"/tmp/codex-demo","agent_id":"agent-c","agent_type":"reviewer"}'
run_codex_event '{"hook_event_name":"Stop","session_id":"session-codex","cwd":"/tmp/codex-demo","turn_id":"turn-1"}'
jq -e '.status == "working" and .stop_pending and [.children[].id] == ["agent-c"]' "$CODEX_STATUS/session-codex.json" >/dev/null
run_codex_event '{"hook_event_name":"SubagentStop","session_id":"session-codex","cwd":"/tmp/codex-demo","agent_id":"agent-c","agent_type":"reviewer"}'
jq -e '.status == "done_unseen" and (.stop_pending | not)' "$CODEX_STATUS/session-codex.json" >/dev/null
run_codex_event '{"hook_event_name":"Stop","session_id":"session-codex","cwd":"/tmp/codex-demo","turn_id":"turn-1"}'
jq -e '.status == "done_unseen" and .children == []' "$CODEX_STATUS/session-codex.json" >/dev/null

CLAUDE_SETTINGS="$TMP/claude-settings.json"
CODEX_HOOKS="$TMP/codex-hooks.json"
env CLAUDE_SETTINGS_PATH="$CLAUDE_SETTINGS" "$BIN" --install-hooks >/dev/null
env CLAUDE_SETTINGS_PATH="$CLAUDE_SETTINGS" "$BIN" --install-hooks >/dev/null
jq -e '[.hooks[] | length] | length == 8 and all(. == 1)' "$CLAUDE_SETTINGS" >/dev/null
env CODEX_HOOKS_PATH="$CODEX_HOOKS" "$BIN" --install-codex-hooks >/dev/null
env CODEX_HOOKS_PATH="$CODEX_HOOKS" "$BIN" --install-codex-hooks >/dev/null
jq -e '[.hooks[] | length] | length == 8 and all(. == 1)' "$CODEX_HOOKS" >/dev/null
jq -e '.hooks.SessionStart[0].matcher == "startup|resume|clear|compact"' "$CODEX_HOOKS" >/dev/null

HISTORY="$TMP/recent-sessions.json"
CLAUDE_AGENTS_CMD="printf '%s' '[{\"sessionId\":\"session-claude\",\"pid\":4343,\"cwd\":\"/tmp/demo\",\"name\":\"Claude demo\",\"status\":\"busy\"}]'"
run_claude_event '{"hook_event_name":"UserPromptSubmit","session_id":"session-claude","cwd":"/tmp/demo"}'
env SESSION_STATUS_DIR="$CLAUDE_NATIVE" \
  CLAUDE_SESSION_STATUS_DIR="$CLAUDE_NATIVE" \
  CLAUDE_AGENTS_CMD="$CLAUDE_AGENTS_CMD" \
  CLAUDE_SESSIONS_HISTORY_PATH="$HISTORY" \
  "$BIN" --snapshot-json claude >"$TMP/claude-snapshot.json"
jq -e '.reachable and .sessions[0].session_id == "session-claude" and .sessions[0].status == "working"' "$TMP/claude-snapshot.json" >/dev/null
jq -e '.[0].resumeId == "session-claude"' "$HISTORY" >/dev/null

CODEX_PS_CMD="printf '%s\n' '4242 1 0.0 ttys001 codex'"
env CODEX_SESSION_STATUS_DIR="$CODEX_STATUS" \
  CODEX_PS_CMD="$CODEX_PS_CMD" \
  CODEX_CWD_OVERRIDE="/tmp/codex-demo" \
  CLAUDE_SESSIONS_HISTORY_PATH="$HISTORY" \
  "$BIN" --snapshot-json codex >"$TMP/codex-snapshot.json"
jq -e '.reachable and .sessions[0].session_id == "session-codex" and .sessions[0].resume_id == "session-codex" and .sessions[0].status == "done"' "$TMP/codex-snapshot.json" >/dev/null

claude_resume=$(env CLAUDE_BIN_OVERRIDE=/usr/bin/true "$BIN" --resume-command claude session-claude "/tmp/space dir")
test "$claude_resume" = "cd '/tmp/space dir' && exec '/usr/bin/true' '--resume' 'session-claude'"
codex_resume=$(env CODEX_BIN_OVERRIDE=/usr/bin/true "$BIN" --resume-command codex session-codex "/tmp/space dir")
test "$codex_resume" = "cd '/tmp/space dir' && exec '/usr/bin/true' 'resume' 'session-codex'"

{
  ln -s /bin/sleep "$TMP/codex-test-process"
  "$TMP/codex-test-process" 30 &
  managed_pid=$!
  "$BIN" --terminate-pid codex "$managed_pid"
  wait "$managed_pid" || true
  if kill -0 "$managed_pid"; then
    exit 1
  fi
} 2>/dev/null

APP_DIR_OVERRIDE="$TMP/build/ClaudeSessions.app" \
  DIST_DIR_OVERRIDE="$TMP/dist" \
  bash scripts/package.sh >/dev/null 2>&1
test -f "$TMP/dist/ClaudeSessions.zip"
if unzip -Z1 "$TMP/dist/ClaudeSessions.zip" | grep -E '(^|/)\._|(^|/)__MACOSX/' >/dev/null; then
  echo "package contains AppleDouble metadata" >&2
  exit 1
fi
mkdir "$TMP/release"
unzip -q "$TMP/dist/ClaudeSessions.zip" -d "$TMP/release"
codesign --verify --deep --strict "$TMP/release/ClaudeSessions.app"

CLAUDE_SESSIONS_RELEASE_URL="file://$TMP/dist/ClaudeSessions.zip" \
  CLAUDE_SESSIONS_INSTALL_DIR="$TMP/installed" \
  CLAUDE_SESSIONS_SKIP_LAUNCH=1 \
  bash install.sh >/dev/null
codesign --verify --deep --strict "$TMP/installed/ClaudeSessions.app"

mkdir -p "$TMP/bad-release"
ditto --norsrc --noextattr "$TMP/release/ClaudeSessions.app" "$TMP/bad-release/ClaudeSessions.app"
touch "$TMP/bad-release/ClaudeSessions.app/Contents/._invalid"
ditto -c -k --norsrc --noextattr --keepParent \
  "$TMP/bad-release/ClaudeSessions.app" "$TMP/bad-release.zip"
if CLAUDE_SESSIONS_RELEASE_URL="file://$TMP/bad-release.zip" \
  CLAUDE_SESSIONS_INSTALL_DIR="$TMP/should-not-install" \
  CLAUDE_SESSIONS_SKIP_LAUNCH=1 \
  bash install.sh >/dev/null 2>&1; then
  echo "installer accepted an invalid AppleDouble package" >&2
  exit 1
fi
test ! -e "$TMP/should-not-install/ClaudeSessions.app"

echo "PASS: Swift compile and shell syntax"
echo "PASS: Claude and Codex lifecycle tracking"
echo "PASS: idempotent hook installers"
echo "PASS: stable session discovery, history, and resume commands"
echo "PASS: guarded process termination"
echo "PASS: clean package, extracted signature, and installer verification"
echo "PASS: installer rejects invalid metadata before replacement"
