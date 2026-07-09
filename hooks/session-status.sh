#!/usr/bin/env bash
# Sessions-panel data layer: translate Claude Code hook events into a per-session
# status file the panel polls. Never blocks Claude Code — always exits 0.
set -uo pipefail

# Status dir override for tests; defaults to the real location.
STATUS_DIR="${SESSION_STATUS_DIR:-$HOME/.claude/session-status}"

# Any failure past here is a no-op, not an error.
INPUT=$(cat 2>/dev/null || true)

# No jq → can't parse the payload → no-op.
command -v jq &> /dev/null || exit 0

# Empty or malformed JSON → no-op.
[ -n "$INPUT" ] || exit 0
echo "$INPUT" | jq empty 2>/dev/null || exit 0

EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // ""' 2>/dev/null || echo "")
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""' 2>/dev/null || echo "")
CWD=$(echo "$INPUT" | jq -r '.cwd // ""' 2>/dev/null || echo "")

# No session to key on → nothing to write.
[ -n "$SESSION_ID" ] || exit 0

FILE="$STATUS_DIR/$SESSION_ID.json"

# Atomic-ish write: build in a temp file, then mv into place so the panel
# never observes a partially written status file.
write_status() {
  local status="$1"
  mkdir -p "$STATUS_DIR" || exit 0
  local now tmp
  now=$(date +%s)
  tmp=$(mktemp "$STATUS_DIR/.tmp.XXXXXX" 2>/dev/null) || exit 0
  jq -n \
    --arg session_id "$SESSION_ID" \
    --arg status "$status" \
    --arg cwd "$CWD" \
    --argjson updated_at "$now" \
    --arg event "$EVENT" \
    '{session_id:$session_id,status:$status,cwd:$cwd,updated_at:$updated_at,event:$event}' \
    > "$tmp" 2>/dev/null || { rm -f "$tmp"; exit 0; }
  mv -f "$tmp" "$FILE" 2>/dev/null || { rm -f "$tmp"; exit 0; }
}

case "$EVENT" in
  UserPromptSubmit)
    write_status "working"
    ;;
  Notification)
    write_status "waiting"
    ;;
  Stop)
    # Reuse the stop-sound guard exactly: still "working" if any background
    # task is running or any scheduled wakeup (cron) is pending.
    RUNNING_TASKS=$(echo "$INPUT" | jq -r '[(.background_tasks // [])[] | select(.status == "running")] | length' 2>/dev/null || echo 0)
    PENDING_CRONS=$(echo "$INPUT" | jq -r '(.session_crons // []) | length' 2>/dev/null || echo 0)
    if [ "${RUNNING_TASKS:-0}" -gt 0 ] || [ "${PENDING_CRONS:-0}" -gt 0 ]; then
      write_status "working"
    else
      write_status "done_unseen"
    fi
    ;;
  StopFailure)
    write_status "error"
    ;;
  SessionEnd)
    rm -f "$FILE" 2>/dev/null || true
    ;;
  *)
    exit 0
    ;;
esac

exit 0
