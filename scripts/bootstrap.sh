#!/usr/bin/env bash
# bootstrap.sh — interactive first-run setup.
#
# A prompting front end over the SAME steps deploy.sh runs (scripts/lib/steps.sh). It
# gathers choices, shows what it will cost, then hands off. It does not implement any
# deployment logic of its own, so there is exactly one code path under test.
#
#   scripts/bootstrap.sh              # interactive
#   scripts/bootstrap.sh --resume     # continue where a previous run stopped
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/ui.sh
source "$REPO_ROOT/scripts/lib/ui.sh"

DEPT="${DEPT:-orfe}"
CONFIG_REPO="${CONFIG_REPO:-$REPO_ROOT/../stream-relay-config}"
PASSTHRU=()

while [ $# -gt 0 ]; do
  case "$1" in
    --resume|--dry-run|--yes|-y) PASSTHRU+=("$1") ;;
    --from|--step|--dept) PASSTHRU+=("$1" "${2:?}"); [ "$1" = "--dept" ] && DEPT="$2"; shift ;;
    -h|--help) sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

banner "STREAM-RELAY INTERACTIVE BOOTSTRAP"

cat <<'EOF'

  stream-relay is a COLD STANDBY for Kaltura. It is meant to be deployed when needed,
  verified, and torn down again — not left running.

      standby    ~$5/month    (container registry only)
      activated  ~$603/month  (VM + Front Door + egress for 10 viewers)

EOF

# --- 1. tooling -------------------------------------------------------------------------
step_header 1 6 "Checking tooling"
for tool in az docker jq openssl python3; do
  command -v "$tool" >/dev/null 2>&1 && ok "$tool" || die "$tool is required but not installed"
done
az bicep version >/dev/null 2>&1 && ok "bicep" || die "run: az bicep install"
docker info >/dev/null 2>&1 && ok "docker daemon" || warn "docker daemon not running (needed for build-push-image)"

# --- 2. config repo ---------------------------------------------------------------------
step_header 2 6 "Locating configuration"
if [ ! -d "$CONFIG_REPO/$DEPT" ]; then
  fail "no config found at $CONFIG_REPO/$DEPT"
  info "clone it beside this repo:"
  detail "git clone git@github.com:pu-shd/stream-relay-config.git $CONFIG_REPO"
  exit 1
fi
ok "config repo: $CONFIG_REPO"
ok "department:  $DEPT"

if [ ! -f "$CONFIG_REPO/$DEPT/deploy.env" ]; then
  warn "generated files are missing"
  if confirm "Render them now?"; then
    (cd "$CONFIG_REPO" && python3 tools/render-relay.py "$DEPT") || die "render failed"
  else
    die "cannot continue without $DEPT/deploy.env"
  fi
fi

# Refuse to deploy from a stale checkout: the generated files are what actually get
# deployed, so drift here means deploying something nobody reviewed.
if ! (cd "$CONFIG_REPO" && python3 tools/render-relay.py "$DEPT" --check >/dev/null 2>&1); then
  fail "generated files are STALE relative to relay.yml"
  info "run: (cd $CONFIG_REPO && tools/render-relay.py $DEPT) and commit the result"
  die "refusing to deploy a configuration that does not match relay.yml"
fi
ok "generated files match relay.yml"

set -a
# shellcheck disable=SC1090
source "$CONFIG_REPO/$DEPT/deploy.env"
set +a

# --- 3. azure account -------------------------------------------------------------------
step_header 3 6 "Azure account"
if ! az account show >/dev/null 2>&1; then
  info "not logged in — launching az login"
  az login >/dev/null || die "login failed"
fi

# while-read rather than mapfile: macOS ships bash 3.2 and mapfile is bash 4+.
subs=()
while IFS= read -r _line; do [ -n "$_line" ] && subs+=("$_line"); done < <(
  az account list --query "[].{name:name,id:id}" -o tsv)
current=$(az account show --query id -o tsv)
if [ "${#subs[@]}" -gt 1 ]; then
  printf "\n${BOLD}Available subscriptions:${NC}\n"
  i=0
  for s in "${subs[@]}"; do
    i=$(( i + 1 ))
    name="${s%%$'\t'*}"; id="${s##*$'\t'}"
    marker=" "; [ "$id" = "$current" ] && marker="*"
    printf "  %s %d) %-32s %s\n" "$marker" "$i" "$name" "$id"
  done
  printf "\nSelect [1-%d, blank keeps the current]: " "${#subs[@]}"
  read -r choice
  if [ -n "$choice" ]; then
    picked="${subs[$(( choice - 1 ))]}"
    az account set --subscription "${picked##*$'\t'}"
  fi
fi
ok "using: $(az account show --query name -o tsv)"

# --- 4. plan ----------------------------------------------------------------------------
step_header 4 6 "Deployment plan"
printf "\n"
(cd "$CONFIG_REPO" && python3 tools/render-relay.py "$DEPT" --size) | sed 's/^/  /'
printf "\n"
info "region        : $AZ_REGION  (deliberately not canadacentral — closer to Princeton)"
info "resource group: $AZ_RESOURCE_GROUP"
info "channels      : $CHANNEL_COUNT at tier $CAPACITY_TIER"
info "custom domain : ${RELAY_CUSTOM_DOMAIN:-<none yet — Phase A, serves on the Front Door hostname>}"
if [ "${PUGWIPS_ENABLED:-0}" = "1" ]; then
  info "access        : restricted to campus/VPN (pugwips enabled)"
else
  warn "access        : HLS is PUBLIC. Guardrails: WAF ${WAF_RATE_LIMIT_RPM} req/min/IP,"
  detail "budget warn \$${BUDGET_WARN_USD}, alert \$${BUDGET_ALERT_USD}, forecast alerts on"
fi

# --- 5. dry run offer -------------------------------------------------------------------
step_header 5 6 "Dry run"
if printf '%s\n' "${PASSTHRU[@]}" | grep -qx -- "--dry-run"; then
  info "--dry-run was passed through; no resources will be created"
elif confirm "Run a what-if first (recommended, creates nothing)?"; then
  "$REPO_ROOT/scripts/deploy.sh" --dry-run --dept "$DEPT" || die "what-if failed"
  printf "\n"
  confirm "what-if looked correct — continue to a REAL deployment?" || {
    ok "stopped after the dry run. Nothing was created."
    exit 0
  }
fi

# --- 6. hand off ------------------------------------------------------------------------
step_header 6 6 "Deploying"
info "handing off to deploy.sh — the single implementation of every step"
printf "\n"
exec "$REPO_ROOT/scripts/deploy.sh" --dept "$DEPT" "${PASSTHRU[@]}"
