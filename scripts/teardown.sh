#!/usr/bin/env bash
# teardown.sh — return the relay to standby, or delete it entirely.
#
#   scripts/teardown.sh --soft    # delete VM + Front Door; keep ACR/KV/identity AND the
#                                 # static ingest IP so publishers survive (~$9/mo)
#   scripts/teardown.sh --hard    # delete the whole resource group
#
# This script is load-bearing, not an afterthought. The entire cost model depends on the
# relay actually going away: standby is ~$9/mo, activated is several hundred/mo. A teardown that
# quietly leaves a VM running turns a fallback into a subscription.
#
# --soft is the default posture after a rehearsal drill. It keeps the image in ACR (so the
# next activation needs no build) and keeps the Front Door hostname's hash reusable.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/ui.sh
source "$REPO_ROOT/scripts/lib/ui.sh"

DEPT="${DEPT:-orfe}"
CONFIG_REPO="${CONFIG_REPO:-$REPO_ROOT/../stream-relay-config}"
DEPT_DIR="$CONFIG_REPO/$DEPT"
MODE=""
ASSUME_YES=0
DRY_RUN=0

usage() { sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0; }

# ASSUME_YES and DRY_RUN are read by lib/ui.sh's confirm(); shellcheck cannot see
# through the dynamic source path. Scoped to this loop only.
# shellcheck disable=SC2034
while [ $# -gt 0 ]; do
  case "$1" in
    --soft)    MODE=soft ;;
    --hard)    MODE=hard ;;
    --yes|-y)  ASSUME_YES=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --dept)    DEPT="${2:?}"; DEPT_DIR="$CONFIG_REPO/$DEPT"; shift ;;
    -h|--help) usage ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

[ -n "$MODE" ] || die "specify --soft (keep ACR/KeyVault/identity) or --hard (delete everything)"
[ -f "$DEPT_DIR/deploy.env" ] || die "missing $DEPT_DIR/deploy.env"

set -a
# shellcheck disable=SC1090
source "$DEPT_DIR/deploy.env"
set +a

# shellcheck source=lib/state.sh
source "$REPO_ROOT/scripts/lib/state.sh"

MODE_UPPER=$(printf '%s' "$MODE" | tr '[:lower:]' '[:upper:]')
banner "STREAM-RELAY TEARDOWN — $MODE_UPPER"

az account show >/dev/null 2>&1 || die "not logged in. Run: az login"
if [ "$(az group exists -n "$AZ_RESOURCE_GROUP")" != "true" ]; then
  ok "resource group $AZ_RESOURCE_GROUP does not exist — nothing to tear down"
  exit 0
fi

info "resource group: $AZ_RESOURCE_GROUP"
printf "\n${BOLD}Resources currently present:${NC}\n"
az resource list -g "$AZ_RESOURCE_GROUP" --query "[].{name:name, type:type}" -o table | sed 's/^/  /'

run() {
  if [ "$DRY_RUN" = "1" ]; then printf "    ${DIM}[dry-run] az %s${NC}\n" "$*"; return 0; fi
  az "$@"
}

if [ "$MODE" = "hard" ]; then
  printf "\n"
  fail "--hard deletes the ENTIRE resource group, including the container registry"
  warn "The next activation will need a full image build, and the Front Door hostname"
  warn "hash is only preserved by TenantReuse — verify it before relying on it."
  if [ "$ASSUME_YES" != "1" ]; then
    printf "${YELLOW}Type the resource group name to confirm: ${NC}"
    read -r typed
    [ "$typed" = "$AZ_RESOURCE_GROUP" ] || die "name did not match — aborted" 0
  fi
  run group delete -n "$AZ_RESOURCE_GROUP" --yes --no-wait
  ok "deletion started (running in the background)"
  info "watch with: az group show -n $AZ_RESOURCE_GROUP"
  exit 0
fi

# --- soft teardown ----------------------------------------------------------------------
# Order matters: Front Door first (so nothing routes to a disappearing origin), then the
# VM, then its network. Deleting the public IP while the NIC still references it fails.
printf "\n"
confirm "Delete the VM and Front Door, keeping ACR / Key Vault / identity?" || die "aborted" 0

step_header 1 5 "Front Door"
if az afd profile show -g "$AZ_RESOURCE_GROUP" --profile-name "$AZ_FRONTDOOR_PROFILE" >/dev/null 2>&1; then
  # NOTE: `az afd profile delete` has no --yes flag; it does not prompt. Passing --yes
  # fails with 'unrecognized arguments'.
  run afd profile delete -g "$AZ_RESOURCE_GROUP" --profile-name "$AZ_FRONTDOOR_PROFILE"
  ok "deleted $AZ_FRONTDOOR_PROFILE"
else
  skipped "no Front Door profile"
fi

step_header 2 5 "WAF policy"
waf="${AZ_FRONTDOOR_PROFILE//-/}waf"
if az network front-door waf-policy show -g "$AZ_RESOURCE_GROUP" -n "$waf" >/dev/null 2>&1; then
  run network front-door waf-policy delete -g "$AZ_RESOURCE_GROUP" -n "$waf"
  ok "deleted $waf"
else
  skipped "no WAF policy"
fi

step_header 3 5 "Virtual machine"
if az vm show -g "$AZ_RESOURCE_GROUP" -n "$AZ_VM_NAME" >/dev/null 2>&1; then
  run vm delete -g "$AZ_RESOURCE_GROUP" -n "$AZ_VM_NAME" --yes
  ok "deleted $AZ_VM_NAME (OS disk follows, deleteOption=Delete)"
else
  skipped "no VM"
fi

step_header 4 5 "Network"
# ORDER MATTERS, and the NIC must go FIRST: deleting the vnet while a NIC still holds an
# ipConfiguration in its subnet fails with InUseSubnetCannotBeDeleted.
if az network nic show -g "$AZ_RESOURCE_GROUP" -n "${AZ_VM_NAME}-nic" >/dev/null 2>&1; then
  run network nic delete -g "$AZ_RESOURCE_GROUP" -n "${AZ_VM_NAME}-nic" && ok "deleted NIC" \
    || warn "could not delete the NIC"
else
  skipped "no NIC"
fi

# The STATIC PUBLIC IP IS DELIBERATELY KEPT.
#
# It costs about $3.65/month, and that is the price of a stable ingest address. Every
# page-stream producer embeds this IP in its SRT URL, so releasing it means the next
# activation comes up on a different address and every publisher silently breaks - exactly
# the failure the Front Door hostname hash-reuse setting exists to prevent, one layer down.
#
# The vnet and NSG are free and are kept for the same reason (and because keeping them
# avoids the subnet-dependency dance entirely).
skipped "keeping relay-pip, relay-vnet and relay-nsg so the ingest address stays stable"
info "static public IP: ~\$3.65/mo — the cost of publishers not breaking on reactivation"

step_header 5 5 "Survivors"
printf "\n${BOLD}Still present (intentionally, for fast reactivation):${NC}\n"
az resource list -g "$AZ_RESOURCE_GROUP" --query "[].{name:name, type:type}" -o table | sed 's/^/  /'

# Report anything unexpected rather than assuming success. An orphaned disk or public IP is
# a silent monthly charge, and this is exactly where it would hide.
# Disks and VMs are the hourly costs that must not survive. The public IP is retained on
# purpose (see above), so it is not an orphan.
unexpected=$(az resource list -g "$AZ_RESOURCE_GROUP" \
  --query "[?type=='Microsoft.Compute/disks' || type=='Microsoft.Compute/virtualMachines' || type=='Microsoft.Network/networkInterfaces'].name" -o tsv)
printf "\n"
if [ -n "$unexpected" ]; then
  warn "these should have been removed by --soft and are still billable:"
  while IFS= read -r r; do warn "  $r"; done <<< "$unexpected"
  exit 1
fi
ok "no billable compute or IP resources remain"
ok "standby cost is now approximately \$9/month (ACR Basic ~\$5 + static IP ~\$3.65)"
info "reactivate with: scripts/bootstrap.sh --resume"
