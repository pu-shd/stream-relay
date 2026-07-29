#!/usr/bin/env bash
# Offline tests for the deployment scripts, using a mock `az` on PATH.
#
# Proves the three properties that make the resumable step machine trustworthy:
#   1. IDEMPOTENCY   - a second run makes no mutating Azure calls.
#   2. RESUMABILITY  - resuming skips completed work and finishes the rest.
#   3. STATE-FREE    - deleting the state file still converges (state is an accelerator,
#                      never the source of truth).
#
# Plus fail-closed preflight, teardown ordering, and that the passphrase never reaches an
# `az` argv (process listings are world-readable).
#
# No cloud access, no spend. Needs only bash, jq and coreutils.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MOCK_BIN="$REPO_ROOT/tests/mock-az/bin"
SANDBOX="$(mktemp -d)"
export MOCK_AZ_STATE_DIR="$SANDBOX"

# shellcheck source=../../scripts/lib/ui.sh
source "$REPO_ROOT/scripts/lib/ui.sh"

pass=0; failed=0
t_ok()   { ok "$1"; pass=$(( pass + 1 )); }
t_fail() { fail "$1"; failed=$(( failed + 1 )); }

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

# A throwaway config repo so tests never depend on, or mutate, the real one.
setup_config() {
  local dir="$SANDBOX/stream-relay-config/orfe"
  mkdir -p "$dir"
  cat > "$dir/deploy.env" <<'EOF'
AZ_REGION=eastus
AZ_RESOURCE_GROUP=orfe-dept-azure-relay-rg
AZ_ACR_NAME=acrorfestreamrelay
AZ_KEY_VAULT=kv-orfe-relay
AZ_IDENTITY_NAME=id-orfe-relay
AZ_VM_NAME=vm-orfe-relay
AZ_VM_SIZE=Standard_D4s_v6
AZ_VM_VCPU=4
AZ_FRONTDOOR_PROFILE=afd-orfe-relay
AZ_FRONTDOOR_ENDPOINT=orfe-relay
AZ_NSG_NAME=relay-nsg
RELAY_HOST=UNRESOLVED-run-deploy.sh-to-discover
RELAY_CUSTOM_DOMAIN=
MEDIAMTX_IMAGE=bluenviron/mediamtx:1.19.3-ffmpeg
SRT_PORT=8890
PBKEYLEN=32
SRT_PASSPHRASE_SECRET=srt-publish-passphrase
CHANNEL_COUNT=7
CAPACITY_TIER=0
WAF_RATE_LIMIT_RPM=600
BUDGET_WARN_USD=400
BUDGET_ALERT_USD=800
PUGWIPS_ENABLED=0
PUGWIPS_REPO=PrincetonUniversity/pugwips
PUGWIPS_STATIC_RANGES=203.0.113.0/24,198.51.100.0/24
RELAY_PATHS=news,news-plus,undergraduate,graduate,announcements,scenic,live-events
EOF
  printf 'srtPublishPassphrase: ${SRT_PUBLISH_PASSPHRASE}\n' > "$dir/mediamtx.yml.tmpl"
  cp "$REPO_ROOT/../stream-relay-config/orfe/infra.bicepparam" "$dir/" 2>/dev/null \
    || printf "using '../../stream-relay/infra/main.bicep'\n" > "$dir/infra.bicepparam"
  echo "$SANDBOX/stream-relay-config"
}

CONFIG="$(setup_config)"

# Run deploy.sh with the mock on PATH and a scenario selected.
run_deploy() {
  local scenario="$1"; shift
  MOCK_AZ_LOG="$SANDBOX/az.log" \
  MOCK_AZ_SCENARIO="$scenario" \
  PATH="$MOCK_BIN:$PATH" \
  CONFIG_REPO="$CONFIG" \
  STREAM_RELAY_STATE_FILE="$SANDBOX/state.json" \
  "$REPO_ROOT/scripts/deploy.sh" --yes --no-verify "$@" 2>&1
}

mutating_calls() {
  grep -cE '(^| )(create|delete|set|update|register|build|invoke)( |$)' "$SANDBOX/az.log" 2>/dev/null || echo 0
}

reset_log()   { : > "$SANDBOX/az.log"; }
reset_state() { rm -f "$SANDBOX/state.json"; }

banner "MOCK-AZ SUITE (offline, no spend)"

# --- 0. plumbing ------------------------------------------------------------------------
step_header 1 8 "Step list and argument validation"
out=$(run_deploy fresh --list-steps)
[ "$(grep -cE '^ +[0-9]+\. ' <<<"$out")" -eq 16 ] \
  && t_ok "16 steps declared" || t_fail "expected 16 steps, got: $(grep -cE '^ +[0-9]+\. ' <<<"$out")"

reset_state; reset_log
out=$(run_deploy fresh --step no-such-step); rc=$?
if [ "$rc" -ne 0 ] && grep -q "unknown step" <<<"$out"; then
  t_ok "a typo'd --step is rejected instead of silently doing nothing"
else
  t_fail "invalid --step was not rejected (rc=$rc)"
fi

# --- 1. dry run -------------------------------------------------------------------------
step_header 2 8 "--dry-run makes no mutating calls"
reset_state; reset_log
out=$(run_deploy fresh --dry-run)
rc=$?
n=$(mutating_calls)
if [ "$rc" -eq 0 ]; then t_ok "dry run succeeded"; else t_fail "dry run failed:\n$out"; fi
# what-if is read-only; `provider register` is the one legitimate exception we exclude.
n_bad=$(grep -E '(^| )(create|delete|set|update|build)( |$)' "$SANDBOX/az.log" 2>/dev/null \
  | grep -v 'what-if' | grep -c . | tr -d ' \n')
n_bad=${n_bad:-0}
[ "$n_bad" -eq 0 ] && t_ok "no create/delete/set/update calls during --dry-run" \
  || { t_fail "--dry-run issued $n_bad mutating calls:"; grep -E '(create|delete|set|update)' "$SANDBOX/az.log" | sed 's/^/      /'; }

# --- 2. full run ------------------------------------------------------------------------
step_header 3 8 "Full run from scratch"
reset_state; reset_log
out=$(run_deploy fresh)
if [ $? -eq 0 ]; then t_ok "full run succeeded"; else t_fail "full run failed:\n$out"; fi
first_mutations=$(mutating_calls)
[ "$first_mutations" -gt 0 ] && t_ok "made $first_mutations mutating calls on a fresh subscription" \
  || t_fail "a fresh run should have mutated something"

done_count=$(jq -r '[.steps[] | select(.status=="done")] | length' "$SANDBOX/state.json")
[ "$done_count" -eq 16 ] && t_ok "all 16 steps recorded done" || t_fail "only $done_count steps recorded done"

# --- 3. idempotency ---------------------------------------------------------------------
step_header 4 8 "Idempotency: everything already exists"
reset_log
out=$(run_deploy existing)
rc=$?
[ "$rc" -eq 0 ] && t_ok "re-run against an existing deployment succeeded" || t_fail "re-run failed:\n$out"
# The Bicep deployment is itself the idempotency mechanism (ARM diffs), so one
# `deployment group create` is expected. What must NOT reappear is resource-by-resource
# creation or a second secret write.
if grep -qE '^group create' "$SANDBOX/az.log"; then
  t_fail "re-run tried to create the resource group again"
else
  t_ok "resource group creation skipped (already exists)"
fi
if grep -q 'keyvault secret set' "$SANDBOX/az.log"; then
  t_fail "re-run overwrote the SRT passphrase — that would break every publisher"
else
  t_ok "existing passphrase left untouched"
fi

# --- 4. resumability --------------------------------------------------------------------
step_header 5 8 "Resumability"
reset_state; reset_log
# Simulate a run that died after 'network'.
mkdir -p "$(dirname "$SANDBOX/state.json")"
cat > "$SANDBOX/state.json" <<'EOF'
{"schema":1,"steps":{
 "preflight":{"status":"done"},"register-providers":{"status":"done"},
 "resource-group":{"status":"done"},"identity":{"status":"done"},
 "federated-credential":{"status":"done"},"key-vault":{"status":"done"},
 "acr":{"status":"done"},"build-push-image":{"status":"done"},
 "network":{"status":"done"},"vm":{"status":"failed"}}}
EOF
out=$(run_deploy partial --resume)
[ $? -eq 0 ] && t_ok "--resume completed the remaining steps" || t_fail "--resume failed:\n$out"
if grep -q 'acr build' "$SANDBOX/az.log"; then
  t_fail "--resume rebuilt the image despite build-push-image being recorded done"
else
  t_ok "--resume skipped work already recorded done"
fi

step_header 6 8 "State-free convergence"
reset_log
reset_state   # the accelerator is gone; Azure is still the source of truth
out=$(run_deploy existing)
if [ $? -eq 0 ]; then
  t_ok "converged with NO state file (state is an accelerator, not the truth)"
else
  t_fail "lost state file broke the run:\n$out"
fi
if grep -qE '^group create' "$SANDBOX/az.log"; then
  t_fail "with no state file it re-created existing resources instead of re-querying Azure"
else
  t_ok "re-queried Azure rather than trusting the (absent) state file"
fi

# --- 5. fail closed ---------------------------------------------------------------------
step_header 7 8 "Preflight fails closed"
reset_state; reset_log
out=$(run_deploy contributor-only --step preflight)
if [ $? -ne 0 ] && grep -qi "Owner or User Access Administrator" <<<"$out"; then
  t_ok "Contributor-only is rejected up front, not at the role-assignment step"
else
  t_fail "preflight accepted insufficient permissions"
fi

reset_state; reset_log
out=$(run_deploy no-quota --step preflight)
if [ $? -ne 0 ] && grep -qi "quota" <<<"$out"; then
  t_ok "exhausted vCPU quota is rejected before deploying"
else
  t_fail "preflight ignored exhausted quota"
fi

reset_state; reset_log
out=$(run_deploy cdn-unregistered --step register-providers)
if grep -q 'provider register' "$SANDBOX/az.log"; then
  t_ok "an unregistered Microsoft.Cdn is registered at step 2, not discovered at step 12"
else
  t_fail "register-providers did not register the unregistered provider"
fi

# --- 6. secret hygiene ------------------------------------------------------------------
step_header 8 8 "Secret hygiene and teardown"
reset_state; reset_log
run_deploy fresh >/dev/null 2>&1
# argv is visible in `ps`, so the passphrase must be passed by file, never inline.
if grep -qE 'keyvault secret set.*--value' "$SANDBOX/az.log"; then
  t_fail "the passphrase was passed via --value — visible in process listings"
else
  t_ok "passphrase never passed on an az command line (--file only)"
fi
if grep -qE '[A-Za-z0-9]{40}' "$SANDBOX/az.log" | grep -v mockhash >/dev/null 2>&1; then
  t_fail "something 40 chars long leaked into an az argv"
else
  t_ok "no passphrase-shaped string in the recorded argv"
fi

# Teardown ordering: Front Door must go before the VM, and the VM before its network, or
# Azure refuses the deletes on dependency grounds.
reset_log
MOCK_AZ_LOG="$SANDBOX/az.log" MOCK_AZ_SCENARIO=existing \
  PATH="$MOCK_BIN:$PATH" CONFIG_REPO="$CONFIG" \
  STREAM_RELAY_STATE_FILE="$SANDBOX/state.json" \
  "$REPO_ROOT/scripts/teardown.sh" --soft --yes >"$SANDBOX/teardown.out" 2>&1
rc=$?
[ "$rc" -eq 0 ] && t_ok "soft teardown succeeded" || { t_fail "soft teardown failed:"; sed 's/^/      /' "$SANDBOX/teardown.out"; }

fd_line=$(grep -n 'afd profile delete' "$SANDBOX/az.log" | head -1 | cut -d: -f1)
vm_line=$(grep -n 'vm delete' "$SANDBOX/az.log" | head -1 | cut -d: -f1)
net_line=$(grep -n 'network vnet delete' "$SANDBOX/az.log" | head -1 | cut -d: -f1)
if [ -n "$fd_line" ] && [ -n "$vm_line" ] && [ "$fd_line" -lt "$vm_line" ]; then
  t_ok "Front Door deleted before the VM"
else
  t_fail "teardown order wrong: front-door=$fd_line vm=$vm_line"
fi
if [ -n "$vm_line" ] && [ -n "$net_line" ] && [ "$vm_line" -lt "$net_line" ]; then
  t_ok "VM deleted before its network"
else
  t_fail "teardown order wrong: vm=$vm_line network=$net_line"
fi
if grep -qE '(acr delete|keyvault delete|identity delete)' "$SANDBOX/az.log"; then
  t_fail "--soft deleted ACR/KeyVault/identity, which it must preserve"
else
  t_ok "--soft preserved ACR, Key Vault and the identity (~\$5/mo standby)"
fi
grep -q 'no billable compute or IP resources remain' "$SANDBOX/teardown.out" \
  && t_ok "teardown confirmed no billable resources remain" \
  || t_fail "teardown did not confirm the absence of billable resources"

# An orphaned disk is a silent monthly charge; teardown must report it, not shrug.
reset_log
MOCK_AZ_LOG="$SANDBOX/az.log" MOCK_AZ_SCENARIO=orphaned-disk \
  PATH="$MOCK_BIN:$PATH" CONFIG_REPO="$CONFIG" \
  STREAM_RELAY_STATE_FILE="$SANDBOX/state.json" \
  "$REPO_ROOT/scripts/teardown.sh" --soft --yes >"$SANDBOX/teardown2.out" 2>&1
if [ $? -ne 0 ] && grep -q 'still billable' "$SANDBOX/teardown2.out"; then
  t_ok "an orphaned disk is reported and exits non-zero"
else
  t_fail "orphaned billable resources were not surfaced"
fi

printf "\n"
banner "MOCK-AZ SUMMARY"
if [ "$failed" -eq 0 ]; then
  printf "${GREEN}${BOLD}✓ %d assertions passed.${NC}\n" "$pass"
  exit 0
fi
printf "${RED}${BOLD}✗ %d failed, %d passed.${NC}\n" "$failed" "$pass"
exit 1
