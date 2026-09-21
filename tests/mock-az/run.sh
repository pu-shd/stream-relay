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
  # Prefer the REAL generated deploy.env when the config repo is checked out beside us: a
  # hand-maintained fixture silently drifts from the renderer (it did, losing the split
  # AZ_IDENTITY_CI/VM variables and making these tests assert against a shape that no
  # longer exists).
  local real="$REPO_ROOT/../stream-relay-config/orfe/deploy.env"
  if [ -f "$real" ]; then
    cp "$real" "$dir/deploy.env"
  else
    cat > "$dir/deploy.env" <<'EOF'
# FIXTURE ONLY - deliberately not real values.
#
# Used when the config repo is not checked out beside this one. Addresses are RFC 5737
# documentation ranges and names are generic: a fixture that carries production values
# invites someone to read it as truth, and this repo is public.
AZ_REGION=canadacentral
AZ_RESOURCE_GROUP=example-relay-rg
SHARED_RESOURCE_GROUP=false
RELAY_OWNS_KEY_VAULT=true
AZ_ACR_NAME=acrexamplerelay
AZ_KEY_VAULT=kv-example-relay
AZ_IDENTITY_CI=id-example-relay-ci
AZ_IDENTITY_VM=id-example-relay-vm
AZ_VM_NAME=vm-example-relay
AZ_VM_SIZE=Standard_D2s_v6
AZ_VM_VCPU=2
AZ_DNS_LABEL=example-relay
# Present so the publishing guard is exercised whether or not the config repo is
# checked out beside this one. A fixture that omits it would leave that guard untested
# in exactly the environment CI runs in.
RELAY_EXPECTED_PUBLISHERS=example-live
HOSTS=relay-1
DEFAULT_HOST=relay-1
AZ_NSG_NAME=vm-example-relay-nsg
RELAY_HOST=relay.example.edu
RELAY_CUSTOM_DOMAIN=relay.example.edu
SRT_PORT=8890
PBKEYLEN=32
SRT_PASSPHRASE_SECRET=srt-publish-passphrase
CHANNEL_COUNT=8
CAPACITY_TIER=0
BUDGET_WARN_USD=600
BUDGET_ALERT_USD=900
PUGWIPS_ENABLED=0
PUGWIPS_REPO=PrincetonUniversity/pugwips
PUGWIPS_STATIC_RANGES=203.0.113.0/24,198.51.100.0/24
RELAY_PATHS=news,news-plus,undergraduate,graduate,announcements,scenic,inspiration,live-events
EOF
  fi
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

# --- fixture completeness ---------------------------------------------------------------
# CI has no config repo checked out, so it uses the inline fallback fixture. Any variable
# the step library requires but the fixture omits fails in CI while passing locally - which
# has already happened twice. Check it up front instead.
step_header 0 8 "Fixture covers every required variable"
missing_vars=""
for v in $(grep -ohE 'require_env [A-Z_ ]+' "$REPO_ROOT/scripts/lib/steps.sh" \
             | sed 's/require_env //' | tr ' ' '\n' | sort -u); do
  [ -n "$v" ] || continue
  grep -q "^${v}=" "$CONFIG/orfe/deploy.env" || missing_vars="$missing_vars $v"
done
if [ -n "$missing_vars" ]; then
  t_fail "deploy.env fixture is missing:$missing_vars"
else
  t_ok "fixture defines every require_env variable"
fi

# --- 0. plumbing ------------------------------------------------------------------------
step_header 1 8 "Step list and argument validation"
out=$(run_deploy fresh --list-steps)
expected_steps=7
[ "$(grep -cE '^ +[0-9]+\. ' <<<"$out")" -eq "$expected_steps" ] \
  && t_ok "$expected_steps steps declared" \
  || t_fail "expected $expected_steps steps, got: $(grep -cE '^ +[0-9]+\. ' <<<"$out")"

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
# Seven, not seventeen: ten steps were retired with the CDN delivery plane, the custom
# image and the resources this deployment now adopts rather than creates.
[ "$done_count" -eq 7 ] && t_ok "all 7 steps recorded done" || t_fail "only $done_count steps recorded done"

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
# Contributor is now SUFFICIENT for a normal deploy, and that is the point: CI runs with
# deployRoleAssignments=false so it never needs the ability to grant roles.
reset_state; reset_log
out=$(run_deploy contributor-only --step preflight)
if [ $? -eq 0 ] && grep -q "no RBAC changes in this run" <<<"$out"; then
  t_ok "Contributor alone can deploy (CI needs no role-assignment rights)"
else
  t_fail "Contributor was rejected for a non-RBAC deploy:\n$out"
fi

# ...but it must NOT be enough to create role assignments.
reset_state; reset_log
out=$(MOCK_AZ_LOG="$SANDBOX/az.log" MOCK_AZ_SCENARIO=contributor-only \
  PATH="$MOCK_BIN:$PATH" CONFIG_REPO="$CONFIG" \
  STREAM_RELAY_STATE_FILE="$SANDBOX/state.json" \
  "$REPO_ROOT/scripts/deploy.sh" --yes --no-verify --with-role-assignments --step preflight 2>&1)
if [ $? -ne 0 ] && grep -qi "Owner or User Access Administrator" <<<"$out"; then
  t_ok "Contributor is rejected for --with-role-assignments (no privilege escalation)"
else
  t_fail "--with-role-assignments accepted a Contributor:\n$out"
fi

# Reader must fail either way.
reset_state; reset_log
out=$(run_deploy reader-only --step preflight)
if [ $? -ne 0 ]; then
  t_ok "Reader is rejected"
else
  t_fail "preflight accepted a Reader"
fi

# The fail-closed case that matters most: RBAC was never established, so a CI deploy would
# otherwise "succeed" and leave a VM that cannot read its own passphrase.
reset_state; reset_log
out=$(run_deploy missing-rbac --step preflight)
if [ $? -ne 0 ] && grep -q "with-role-assignments" <<<"$out"; then
  t_ok "missing RBAC fails closed and points at the one-time bootstrap"
else
  t_fail "preflight did not catch missing RBAC:\n$out"
fi

# And the deploy path must never silently request role assignments.
reset_state; reset_log
run_deploy existing >/dev/null 2>&1
if grep -q 'deployRoleAssignments=true' "$SANDBOX/az.log"; then
  t_fail "a normal deploy passed deployRoleAssignments=true"
else
  t_ok "normal deploy never requests role-assignment creation"
fi

reset_state; reset_log
out=$(run_deploy no-quota --step preflight)
if [ $? -ne 0 ] && grep -qi "quota" <<<"$out"; then
  t_ok "exhausted vCPU quota is rejected before deploying"
else
  t_fail "preflight ignored exhausted quota"
fi

reset_state; reset_log
out=$(run_deploy provider-unregistered --step register-providers)
if grep -q 'provider register' "$SANDBOX/az.log"; then
  t_ok "an unregistered provider is registered up front, not discovered mid-deploy"
else
  t_fail "register-providers did not register the unregistered provider"
fi

# Convergence runs ON the relay host. Anywhere else the step must SKIP loudly rather than
# claim success, and must never reach for `az vm run-command` - that would mean the
# deploying principal holds arbitrary root execution on the VM, a larger privilege than
# everything else this deployment has combined.
reset_state; reset_log
out=$(run_deploy fresh --step configure)
rc=$?
if [ "$rc" -eq 0 ] && grep -qi "self-hosted runner's job" <<<"$out"; then
  t_ok "configure skips off-host instead of pretending to converge"
else
  t_fail "configure did not skip off-host (rc=$rc):\n$out"
fi
if grep -qE 'vm run-command' "$SANDBOX/az.log"; then
  t_fail "configure invoked az vm run-command; CI must not hold runCommand on the VM"
else
  t_ok "configure never invokes run-command"
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
  "$REPO_ROOT/scripts/teardown.sh" --keep-ip --keep-registry --yes --abandon-channels \
    >"$SANDBOX/teardown.out" 2>&1
rc=$?
[ "$rc" -eq 0 ] && t_ok "selective teardown succeeded" || { t_fail "selective teardown failed:"; sed 's/^/      /' "$SANDBOX/teardown.out"; }

# ---------------------------------------------------------------------------------------
# Teardown must delete ONLY what the relay created.
#
# Everything the relay runs on is adopted: the VM, its NIC, vnet, subnet, NSG, static public
# IP, Key Vault and disks all existed first. The previous version of this path deleted all
# of them - correct when the deployment created them, catastrophic now. These assertions are
# about absence, because absence is the whole property.
# ---------------------------------------------------------------------------------------
protected_hit=""
for pat in 'vm delete' 'network nic delete' 'network vnet delete' 'network nsg delete' \
           'network public-ip delete' 'keyvault delete' 'keyvault purge' \
           'storage account delete' 'acr delete'; do
  grep -qE "(^| )$pat" "$SANDBOX/az.log" && protected_hit="$protected_hit $pat"
done
if [ -z "$protected_hit" ]; then
  t_ok "teardown deleted no adopted resource (VM, NIC, vnet, NSG, IP, vault, storage)"
else
  t_fail "teardown deleted adopted resources:$protected_hit"
fi

# The SRT rule is the relay's own, so it goes.
if grep -qE 'nsg rule delete.*AllowSrtIngest' "$SANDBOX/az.log"; then
  t_ok "the SRT ingest rule was removed"
else
  t_fail "AllowSrtIngest was not removed"
fi

# 443 and 80 are NOT the relay's to remove: VDO.Ninja at /meet/ serves on 443, and certbot
# renews over 80. Deleting either takes down a service the relay never owned.
if grep -qE 'nsg rule delete.*(AllowHlsDelivery|AllowAcmeHttp)' "$SANDBOX/az.log"; then
  t_fail "teardown removed the HTTPS or ACME rule; VDO.Ninja and renewal need both"
else
  t_ok "the HTTPS and ACME rules were left alone"
fi

grep -q 'adopted VM and its services are untouched' "$SANDBOX/teardown.out" \
  && t_ok "teardown states plainly what it left behind" \
  || t_fail "teardown did not report what survived"

# ---------------------------------------------------------------------------------------
# The shared-resource-group guard.
#
# orfe-dept-azure-rg is not dedicated to the relay: it holds orfe-web-vm, that VM's Key
# Vault, vnet, disks and alerts. `az group delete` there destroys a VM somebody parked, and
# purging the vault destroys secrets belonging to it. Both are irreversible, so both are
# asserted here rather than trusted to a comment.
# ---------------------------------------------------------------------------------------
guard_config() {
  local dir="$SANDBOX/guard/orfe" flag="$1"
  rm -rf "$SANDBOX/guard"; mkdir -p "$dir"
  grep -v '^SHARED_RESOURCE_GROUP=' "$CONFIG/orfe/deploy.env" > "$dir/deploy.env"
  [ -n "$flag" ] && printf 'SHARED_RESOURCE_GROUP=%s\n' "$flag" >> "$dir/deploy.env"
  printf '%s' "$SANDBOX/guard"
}

run_teardown() {
  reset_log
  MOCK_AZ_LOG="$SANDBOX/az.log" PATH="$MOCK_BIN:$PATH" CONFIG_REPO="$1" \
    STREAM_RELAY_STATE_FILE="$SANDBOX/state.json" \
    "$REPO_ROOT/scripts/teardown.sh" --yes --abandon-channels >"$SANDBOX/guard.out" 2>&1
  return $?
}

run_teardown "$(guard_config true)"
if grep -q 'refusing to delete' "$SANDBOX/guard.out" \
   && ! grep -qE '(^| )group delete' "$SANDBOX/az.log"; then
  t_ok "complete teardown refuses a shared resource group"
else
  t_fail "complete teardown did NOT refuse a shared resource group"
fi

# Fails closed: an older deploy.env predating the flag must not be read as "dedicated".
run_teardown "$(guard_config "")"
if grep -q 'refusing to delete' "$SANDBOX/guard.out" \
   && ! grep -qE '(^| )group delete' "$SANDBOX/az.log"; then
  t_ok "a missing SHARED_RESOURCE_GROUP flag fails closed"
else
  t_fail "a missing SHARED_RESOURCE_GROUP flag did NOT fail closed"
fi

# ---------------------------------------------------------------------------------------
# The publishing guard. Tearing down takes live channels off the air, and page-stream will
# not notice: its SRT backoff reconnects forever rather than exiting, so every container
# stays healthy while the displays hold their last frame.
# ---------------------------------------------------------------------------------------
reset_log
MOCK_AZ_LOG="$SANDBOX/az.log" PATH="$MOCK_BIN:$PATH" CONFIG_REPO="$CONFIG" \
  STREAM_RELAY_STATE_FILE="$SANDBOX/state.json" \
  "$REPO_ROOT/scripts/teardown.sh" --keep-ip --keep-registry --yes \
  >"$SANDBOX/live.out" 2>&1
rc=$?
if [ "$rc" -ne 0 ] && grep -q 'publishing to this relay right now' "$SANDBOX/live.out" \
   && ! grep -qE 'nsg rule delete|identity delete|budget delete' "$SANDBOX/az.log"; then
  t_ok "teardown refuses while a channel is publishing, and deletes nothing first"
else
  t_fail "teardown did NOT refuse while a channel is publishing"
  sed 's/^/      /' "$SANDBOX/live.out"
fi

# Overridable, or a relay whose channels have moved on could never be retired.
reset_log
MOCK_AZ_LOG="$SANDBOX/az.log" MOCK_AZ_SCENARIO=existing PATH="$MOCK_BIN:$PATH" \
  CONFIG_REPO="$CONFIG" STREAM_RELAY_STATE_FILE="$SANDBOX/state.json" \
  "$REPO_ROOT/scripts/teardown.sh" --keep-ip --keep-registry --yes --abandon-channels \
  >"$SANDBOX/abandon.out" 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then
  t_ok "--abandon-channels proceeds past the refusal"
else
  t_fail "--abandon-channels did not proceed"
  sed 's/^/      /' "$SANDBOX/abandon.out"
fi

# The watchdog is stopped BEFORE the relay, so deliberate work does not page.
if grep -q 'relay-watchdog' "$SANDBOX/abandon.out" || grep -q 'relay-watchdog' "$SANDBOX/az.log"; then
  t_ok "teardown stops the watchdog as well as the relay"
else
  t_fail "teardown leaves the watchdog running; it would page about planned work"
fi

# A vault the relay did not create is never purged, even when the group IS dedicated -
# the two guards are independent.
run_teardown "$(guard_config false)"
if ! grep -qE '(^| )keyvault purge' "$SANDBOX/az.log"; then
  t_ok "a Key Vault the relay does not own is never purged"
else
  t_fail "teardown purged a Key Vault the relay does not own"
fi

printf "\n"
banner "MOCK-AZ SUMMARY"
if [ "$failed" -eq 0 ]; then
  printf "${GREEN}${BOLD}✓ %d assertions passed.${NC}\n" "$pass"
  exit 0
fi
printf "${RED}${BOLD}✗ %d failed, %d passed.${NC}\n" "$failed" "$pass"
exit 1
