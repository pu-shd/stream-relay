#!/usr/bin/env bash
# allow-all.sh — break glass.
#
# Restores the default HLS ingress rule after restrict.sh has locked something out. Exists
# because the realistic failure mode of an allowlist is locking out the displays, and the
# recovery path must be one obvious command rather than portal archaeology.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/ui.sh
source "$REPO_ROOT/scripts/lib/ui.sh"

DEPT="${DEPT:-orfe}"
CONFIG_REPO="${CONFIG_REPO:-$REPO_ROOT/../stream-relay-config}"
DEPT_DIR="$CONFIG_REPO/$DEPT"

while [ $# -gt 0 ]; do
  case "$1" in
    --dept) DEPT="${2:?}"; DEPT_DIR="$CONFIG_REPO/$DEPT"; shift ;;
    -h|--help) sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

[ -f "$DEPT_DIR/deploy.env" ] || die "missing $DEPT_DIR/deploy.env"
set -a
# shellcheck disable=SC1090
source "$DEPT_DIR/deploy.env"
set +a

banner "STREAM-RELAY BREAK GLASS — RESTORE DEFAULT ACCESS"

warn "This restores HLS ingress from Front Door's backend range, making the stream"
warn "publicly reachable again through the CDN."
info "Guardrails that remain in force: WAF ${WAF_RATE_LIMIT_RPM:-?} req/min/IP,"
detail "budget warn \$${BUDGET_WARN_USD:-?}, alert \$${BUDGET_ALERT_USD:-?}"

az network nsg rule update \
  -g "$AZ_RESOURCE_GROUP" --nsg-name "${AZ_NSG_NAME:-relay-nsg}" \
  -n allow-hls-from-frontdoor \
  --source-address-prefixes AzureFrontDoor.Backend \
  -o none
ok "default access restored"

printf "  %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ) allow-all restored" >> "$REPO_ROOT/.restrict-history"
info "If this was an incident response, check the budget before walking away:"
detail "az consumption budget list -o table"
