#!/usr/bin/env bash
# deploy.sh — non-interactive, idempotent, CI-callable deployment.
#
#   scripts/deploy.sh --dry-run              # what-if only; creates nothing, spends nothing
#   scripts/deploy.sh                        # deploy
#   scripts/deploy.sh --resume               # skip steps already recorded done
#   scripts/deploy.sh --from front-door      # resume from a step onwards
#   scripts/deploy.sh --step discover-hostname
#   scripts/deploy.sh --no-verify           # deploy, leave verification to a separate gate
#                                           # so what-if has a scope to run in
#   scripts/deploy.sh --with-role-assignments  # ONE-TIME human bootstrap: creates RBAC,
#                                             # needs Owner/UAA. CI never uses this.
#   scripts/deploy.sh --list-steps
#
# bootstrap.sh is the interactive front end to the same steps. There is deliberately one
# implementation: see scripts/lib/steps.sh.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/ui.sh
source "$REPO_ROOT/scripts/lib/ui.sh"

DEPT="${DEPT:-orfe}"
CONFIG_REPO="${CONFIG_REPO:-$REPO_ROOT/../stream-relay-config}"
DEPT_DIR="$CONFIG_REPO/$DEPT"

DRY_RUN=0
RESUME=0
SKIP_VERIFY=0
DEPLOY_ROLE_ASSIGNMENTS=0
ONLY_STEP=""
FROM_STEP=""
ASSUME_YES=0

usage() {
  sed -n '2,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 0
}

# Flags assigned here are read by the sourced libraries (lib/steps.sh, lib/state.sh),
# which shellcheck cannot follow through a dynamic source path. Scoped to this loop
# rather than the whole file, so a genuine unused variable elsewhere still gets caught.
# shellcheck disable=SC2034
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)     DRY_RUN=1 ;;
    --resume)      RESUME=1 ;;
    --no-verify)   SKIP_VERIFY=1 ;;
    # Retained as a no-op: the resource group is adopted, never created, so there is
    # nothing for this to allow. Accepting it keeps older invocations working.
    --allow-rg)    warn "--allow-rg is a no-op: the resource group is adopted, not created" ;;
    --with-role-assignments) DEPLOY_ROLE_ASSIGNMENTS=1 ;;
    --step)        ONLY_STEP="${2:?--step needs a step name}"; shift ;;
    --from)        FROM_STEP="${2:?--from needs a step name}"; shift ;;
    --reset-state) RESET_STATE=1 ;;
    --yes|-y)      ASSUME_YES=1 ;;
    --dept)        DEPT="${2:?--dept needs a name}"; DEPT_DIR="$CONFIG_REPO/$DEPT"; shift ;;
    --list-steps)  LIST_STEPS=1 ;;
    -h|--help)     usage ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done

# shellcheck source=lib/state.sh
source "$REPO_ROOT/scripts/lib/state.sh"
# shellcheck source=lib/steps.sh
source "$REPO_ROOT/scripts/lib/steps.sh"

if [ "${LIST_STEPS:-0}" = "1" ]; then
  printf "${BOLD}Steps (in order):${NC}\n"
  i=0
  for s in "${STEPS[@]}"; do
    i=$(( i + 1 ))
    printf "  %2d. %-22s %s\n" "$i" "$s" "$(step_description "$s")"
  done
  exit 0
fi

[ -d "$DEPT_DIR" ] || die "config directory not found: $DEPT_DIR
    Check out stream-relay-config beside this repo, or set CONFIG_REPO."
[ -f "$DEPT_DIR/deploy.env" ] || die "missing $DEPT_DIR/deploy.env
    Run: (cd $CONFIG_REPO && tools/render-relay.py $DEPT)"

# deploy.env holds deployment targets only, never credentials.
set -a
# shellcheck disable=SC1090
source "$DEPT_DIR/deploy.env"
set +a

[ "${RESET_STATE:-0}" = "1" ] && { state_reset; ok "state reset"; }
state_init

if [ "$DRY_RUN" = "1" ] && [ "${ALLOW_RG:-0}" = "1" ]; then
  # Be exact. --allow-rg does create something, even though a resource group is free and
  # empty. Claiming "nothing will be created" here would be a small lie that erodes trust
  # in every other message this script prints.
  banner "DRY RUN — creates ONLY the empty resource group"
elif [ "$DRY_RUN" = "1" ]; then
  banner "STREAM-RELAY DEPLOY — DRY RUN (nothing will be created)"
else
  banner "STREAM-RELAY DEPLOY — $DEPT"
fi

info "subscription target : ${AZ_SUBSCRIPTION_ID:-<active>}"
info "resource group      : ${AZ_RESOURCE_GROUP}"
info "region              : ${AZ_REGION}"
info "vm size             : ${AZ_VM_SIZE} (${AZ_VM_VCPU} vCPU, tier ${CAPACITY_TIER})"
info "channels            : ${CHANNEL_COUNT}"
info "custom domain       : ${RELAY_CUSTOM_DOMAIN:-<none, Phase A>}"
state_summary

# Real deployments cost money. Dry runs do not, so they never prompt.
if [ "$DRY_RUN" != "1" ] && [ -z "$ONLY_STEP" ]; then
  printf "\n"
  warn "This creates billable Azure resources (~\$${BUDGET_WARN_USD:-?}/mo warn threshold)."
  confirm "Proceed with a real deployment?" || die "aborted" 0
fi

trap 'printf "\n"; fail "interrupted"; info "resume with: $(basename "$0") --resume"; exit 130' INT TERM

if run_steps; then
  printf "\n"
  banner "DEPLOY COMPLETE"
  if [ "$DRY_RUN" = "1" ]; then
    if [ "${ALLOW_RG:-0}" = "1" ]; then
      ok "dry run finished — only the empty resource group exists (free)"
      info "remove it with: az group delete -n $AZ_RESOURCE_GROUP --yes"
    else
      ok "dry run finished — no resources were created, \$0 spent"
    fi
    info "what-if output: $REPO_ROOT/.what-if.json"
  else
    host=$(state_get_output frontDoorHostName || echo "<unknown>")
    ip=$(state_get_output ingestIpAddress || echo "<unknown>")
    ok "HLS:    https://$host/<path>/index.m3u8"
    ok "ingest: srt://$ip:${SRT_PORT}?streamid=publish:<path>&passphrase=<secret>&pbkeylen=${PBKEYLEN:-32}"
    printf "\n"
    warn "This is a COLD STANDBY. Tear it down when the exercise is over:"
    info "  scripts/teardown.sh --soft    # back to ~\$5/mo"
  fi
else
  exit 1
fi
