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

# Session title: Claude Code appends {"type":"ai-title","aiTitle":...} entries
# to the transcript — the last one is the current topic title (works for every
# host app, no macOS permissions needed).
TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // ""' 2>/dev/null || echo "")
TITLE=""
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  TITLE=$(grep '"type":"ai-title"' "$TRANSCRIPT" 2>/dev/null | tail -1 | jq -r '.aiTitle // ""' 2>/dev/null || echo "")
fi

# Atomic write of arbitrary JSON produced by a jq program over the EXISTING
# file content (or {} if none), so fields like .children survive updates.
# $1 = jq program; extra args passed through.
update_file() {
  local prog="$1"; shift
  mkdir -p "$STATUS_DIR" || exit 0
  local now tmp existing
  now=$(date +%s)
  existing="{}"
  [ -f "$FILE" ] && existing=$(cat "$FILE" 2>/dev/null || echo "{}")
  echo "$existing" | jq empty 2>/dev/null || existing="{}"
  tmp=$(mktemp "$STATUS_DIR/.tmp.XXXXXX" 2>/dev/null) || exit 0
  echo "$existing" | jq \
    --arg session_id "$SESSION_ID" \
    --arg cwd "$CWD" \
    --arg title "$TITLE" \
    --argjson updated_at "$now" \
    --arg event "$EVENT" \
    "$@" \
    ".session_id = \$session_id
     | (if \$cwd != \"\" then .cwd = \$cwd else . end)
     | (if \$title != \"\" then .title = \$title else . end)
     | .updated_at = \$updated_at
     | .event = \$event
     | $prog" \
    > "$tmp" 2>/dev/null || { rm -f "$tmp"; exit 0; }
  mv -f "$tmp" "$FILE" 2>/dev/null || { rm -f "$tmp"; exit 0; }
}

write_status() {
  update_file ".status = \"$1\""
}

case "$EVENT" in
  SessionStart)
    update_file '.status = "idle" | .children = []'
    ;;
  UserPromptSubmit)
    # New turn: reset children (fresh turn starts clean).
    update_file '.status = "working" | .children = []'
    ;;
  Notification)
    write_status "waiting"
    ;;
  Stop)
    # Reuse the stop-sound guard exactly: still "working" if any background
    # task is running or any scheduled wakeup (cron) is pending. Running
    # background tasks are published as children for the panel to nest.
    RUNNING_TASKS=$(echo "$INPUT" | jq -r '[(.background_tasks // [])[] | select(.status == "running")] | length' 2>/dev/null || echo 0)
    PENDING_CRONS=$(echo "$INPUT" | jq -r '(.session_crons // []) | length' 2>/dev/null || echo 0)
    # Teammate/agent tasks are excluded here: agents are tracked by the
    # SubagentStart/SubagentStop lifecycle (which knows their given name);
    # a lingering idle teammate would only duplicate them with a prompt
    # snippet as its name.
    TASK_CHILDREN=$(echo "$INPUT" | jq -c '[(.background_tasks // [])[] | select(.status == "running") | select((.type // "") | test("teammate|agent") | not) | {id: (.id // "task"), kind: (.type // "task"), name: (.description // .command // .type // "background task")}]' 2>/dev/null || echo "[]")
    if [ "${RUNNING_TASKS:-0}" -gt 0 ] || [ "${PENDING_CRONS:-0}" -gt 0 ]; then
      update_file '.status = "working"
         | .children = ((.children // []) | map(select(.kind == "agent"))) + $tasks' \
        --argjson tasks "$TASK_CHILDREN"
    else
      update_file '.status = "done_unseen" | .children = ((.children // []) | map(select(.kind == "agent")))'
    fi
    ;;
  StopFailure)
    write_status "error"
    ;;
  SubagentStart)
    CHILD=$(echo "$INPUT" | jq -c '{id: (.agent_id // .agentId // .task_id // .id // "agent"), kind: "agent", name: (.agent_name // .name // .description // .agent_type // .subagent_type // "subagent")}' 2>/dev/null || echo '{}')
    update_file '.children = ((.children // []) | map(select(.id != $child.id))) + [$child]' \
      --argjson child "$CHILD"
    ;;
  SubagentStop)
    CHILD_ID=$(echo "$INPUT" | jq -r '(.agent_id // .agentId // .task_id // .id // "agent")' 2>/dev/null || echo "agent")
    update_file '.children = ((.children // []) | map(select(.id != $cid)))' \
      --arg cid "$CHILD_ID"
    ;;
  SessionEnd)
    rm -f "$FILE" 2>/dev/null || true
    ;;
  *)
    exit 0
    ;;
esac

exit 0
