#!/usr/bin/env bash
# restrict.sh — the kill switch.
#
# Immediately limits HLS egress to campus + VPN ranges. This is the response to a bandwidth
# incident on the public endpoint, and it must work even when pugwips.enabled is false:
# in that case it falls back to the STATIC campus ranges from relay.yml, which need no
# token and no network fetch.
#
#   scripts/restrict.sh              # static campus ranges (always available)
#   scripts/restrict.sh --pugwips    # also pull live GlobalProtect VPN IPs
#
# Reverse with scripts/allow-all.sh.
#
# Exercised by the rehearsal drill on purpose: an incident is a bad time to discover that
# the kill switch was never run.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/ui.sh
source "$REPO_ROOT/scripts/lib/ui.sh"

DEPT="${DEPT:-orfe}"
CONFIG_REPO="${CONFIG_REPO:-$REPO_ROOT/../stream-relay-config}"
DEPT_DIR="$CONFIG_REPO/$DEPT"
USE_PUGWIPS=0
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --pugwips) USE_PUGWIPS=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --dept) DEPT="${2:?}"; DEPT_DIR="$CONFIG_REPO/$DEPT"; shift ;;
    -h|--help) sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

[ -f "$DEPT_DIR/deploy.env" ] || die "missing $DEPT_DIR/deploy.env"
set -a
# shellcheck disable=SC1090
source "$DEPT_DIR/deploy.env"
set +a

banner "STREAM-RELAY ACCESS RESTRICTION"

IFS=',' read -ra ranges <<< "${PUGWIPS_STATIC_RANGES:-}"
[ "${#ranges[@]}" -gt 0 ] || die "no static campus ranges in deploy.env — cannot restrict safely"
ok "${#ranges[@]} static campus ranges from relay.yml"

if [ "$USE_PUGWIPS" = "1" ]; then
  repo="${PUGWIPS_REPO:-PrincetonUniversity/pugwips}"
  info "fetching live VPN gateway IPs from $repo"
  if gw=$(gh release download latest --repo "$repo" --pattern gateways.json --output - 2>/dev/null); then
    # while-read rather than mapfile: macOS ships bash 3.2 and mapfile is bash 4+.
    vpn=()
    while IFS= read -r _ip; do [ -n "$_ip" ] && vpn+=("$_ip"); done < <(
      jq -r '.gateways | to_entries[] | .value.ips[]' <<<"$gw" 2>/dev/null | sort -u)
    if [ "${#vpn[@]}" -gt 0 ]; then
      ok "${#vpn[@]} VPN gateway IPs"
      for ip in "${vpn[@]}"; do ranges+=("$ip/32"); done
    else
      warn "gateways.json contained no IPs — continuing with static ranges only"
    fi
  else
    # pugwips' own fail-safe, preserved: never lock everyone out because a fetch failed.
    warn "could not fetch gateways.json (private repo needs an authenticated gh)"
    warn "FAIL-SAFE: continuing with static campus ranges rather than locking everyone out"
  fi
fi

printf "\n${BOLD}Allowlist to apply (%d entries):${NC}\n" "${#ranges[@]}"
printf '  %s\n' "${ranges[@]}"

if [ "$DRY_RUN" = "1" ]; then
  printf "\n"; info "[dry-run] no changes made"; exit 0
fi

printf "\n"
warn "This will block HLS access from everywhere else, including off-campus staff."
confirm "Apply the allowlist?" || die "aborted" 0

# Applied at the NSG (origin) rather than the WAF, because it takes effect immediately and
# does not depend on Front Door rule propagation.
step_header 1 2 "Updating NSG rule"
az network nsg rule update \
  -g "$AZ_RESOURCE_GROUP" --nsg-name "${AZ_NSG_NAME:-relay-nsg}" \
  -n allow-hls-from-frontdoor \
  --source-address-prefixes "${ranges[@]}" \
  -o none
ok "HLS ingress restricted to the allowlist"

step_header 2 2 "Recording the change"
printf "  %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ) restricted to ${#ranges[@]} ranges" \
  >> "$REPO_ROOT/.restrict-history"
ok "logged to .restrict-history"

printf "\n"
warn "Note: restricting the NSG to campus ranges also blocks Front Door's own backend"
warn "range, so the CDN path will stop working. This is a BREAK-GLASS control for stopping"
warn "an active bandwidth incident, not a steady-state access policy."
info "For a steady-state campus-only posture, set pugwips.enabled: true in relay.yml and"
info "redeploy, which applies the allowlist at the WAF while keeping the CDN path intact."
info "Reverse with: scripts/allow-all.sh"
