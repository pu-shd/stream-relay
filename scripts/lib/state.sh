#!/usr/bin/env bash
# Resumable step state.
#
# THE CENTRAL RULE: state is an accelerator, never the source of truth. Every step
# re-queries Azure before acting, so deleting this file must still converge. That is what
# makes a 24-48h Front Door certificate wait survivable across days and machines - and it
# means a stale or corrupt state file can never wedge a deployment.
#
# Corollary: state is written only AFTER a step verifies, never before acting, so a step is
# never recorded half-done.

STATE_FILE="${STREAM_RELAY_STATE_FILE:-$REPO_ROOT/.stream-relay-state.json}"
STATE_SCHEMA=1

state_init() {
  [ -f "$STATE_FILE" ] && return 0
  cat > "$STATE_FILE" <<EOF
{
  "schema": $STATE_SCHEMA,
  "subscription": "${AZ_SUBSCRIPTION_ID:-}",
  "resource_group": "${AZ_RESOURCE_GROUP:-}",
  "steps": {}
}
EOF
}

state_reset() {
  rm -f "$STATE_FILE"
  state_init
}

# Deliberately tolerant: an unreadable or hand-mangled state file degrades to "nothing is
# done" rather than aborting, because Azure is re-queried anyway.
state_status() {
  local step="$1"
  [ -f "$STATE_FILE" ] || { echo "pending"; return; }
  jq -r --arg s "$step" '.steps[$s].status // "pending"' "$STATE_FILE" 2>/dev/null || echo "pending"
}

state_is_done() { [ "$(state_status "$1")" = "done" ]; }

state_mark() {
  local step="$1" status="$2" note="${3:-}"
  state_init
  local tmp="${STATE_FILE}.tmp"
  jq --arg s "$step" --arg st "$status" --arg note "$note" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '.steps[$s] = {status: $st, at: $at, note: $note}' "$STATE_FILE" > "$tmp" \
    && mv "$tmp" "$STATE_FILE"
}

state_record_output() {
  local key="$1" value="$2"
  state_init
  local tmp="${STATE_FILE}.tmp"
  jq --arg k "$key" --arg v "$value" '.outputs[$k] = $v' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

state_get_output() {
  [ -f "$STATE_FILE" ] || return 1
  jq -r --arg k "$1" '.outputs[$k] // empty' "$STATE_FILE" 2>/dev/null
}

state_summary() {
  [ -f "$STATE_FILE" ] || { info "no state file yet"; return; }
  local done_count total
  done_count=$(jq -r '[.steps[] | select(.status == "done")] | length' "$STATE_FILE" 2>/dev/null || echo 0)
  total=${#STEPS[@]}
  info "state: ${done_count}/${total} steps recorded done ($STATE_FILE)"
  local failed
  failed=$(jq -r '.steps | to_entries[] | select(.value.status == "failed") | .key' "$STATE_FILE" 2>/dev/null)
  if [ -n "$failed" ]; then
    while IFS= read -r f; do
      warn "last failure recorded at step: $f  →  resume with --from $f"
    done <<< "$failed"
  fi
}
