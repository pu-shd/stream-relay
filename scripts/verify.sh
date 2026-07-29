#!/usr/bin/env bash
# verify.sh — assert the deployed relay actually works.
#
# Runs against the FRONT DOOR hostname, not the VM, because most of what can go wrong here
# is in the CDN layer. Two assertions exist because the failure they catch is expensive
# rather than merely broken:
#
#   * CACHE HIT on a repeated manifest request. MediaMTX appends '?session=<uuid>' per
#     viewer, so without the Ignore-Specified-Query-Strings rule every viewer is a distinct
#     cache key, the hit rate collapses, and origin egress roughly doubles the bill. This
#     is invisible in the portal and only shows up on an invoice.
#
#   * HOSTNAME STABILITY across teardown/redeploy (--check-hostname-stability). If Front
#     Door's pseudorandom hash changed on redeploy, every Apple TV's vlc.xml would break at
#     the exact moment the fallback was being activated.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/ui.sh
source "$REPO_ROOT/scripts/lib/ui.sh"

DEPT="${DEPT:-orfe}"
CONFIG_REPO="${CONFIG_REPO:-$REPO_ROOT/../stream-relay-config}"
DEPT_DIR="$CONFIG_REPO/$DEPT"
EXPECT_HOSTNAME=""

while [ $# -gt 0 ]; do
  case "$1" in
    --expect-hostname) EXPECT_HOSTNAME="${2:?}"; shift ;;
    --dept) DEPT="${2:?}"; DEPT_DIR="$CONFIG_REPO/$DEPT"; shift ;;
    -h|--help) sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

[ -f "$DEPT_DIR/deploy.env" ] || die "missing $DEPT_DIR/deploy.env"
set -a
# shellcheck disable=SC1090
source "$DEPT_DIR/deploy.env"
set +a

# shellcheck source=lib/state.sh
source "$REPO_ROOT/scripts/lib/state.sh"

pass=0; failed=0
check_ok()   { ok "$1"; pass=$(( pass + 1 )); }
check_fail() { fail "$1"; failed=$(( failed + 1 )); }

banner "STREAM-RELAY VERIFICATION"

HOST="$(state_get_output frontDoorHostName || true)"
[ -n "$HOST" ] || HOST="${RELAY_HOST:-}"
case "$HOST" in
  ""|UNRESOLVED*) die "no Front Door hostname known. Run: scripts/deploy.sh --step discover-hostname" ;;
esac
info "endpoint: https://$HOST"

IP="$(state_get_output ingestIpAddress || true)"
[ -n "$IP" ] && info "ingest:   srt://$IP:${SRT_PORT}"

# --- 1. hostname shape ------------------------------------------------------------------
step_header 1 6 "Hostname"
if [ "$HOST" = "${AZ_FRONTDOOR_ENDPOINT}.azurefd.net" ]; then
  check_fail "hostname is the un-hashed form — contradicts the documented AFD naming"
else
  check_ok "hostname carries the expected pseudorandom hash"
fi
if [ -n "$EXPECT_HOSTNAME" ]; then
  # The teardown/redeploy stability check. This is what proves TenantReuse works.
  [ "$HOST" = "$EXPECT_HOSTNAME" ] \
    && check_ok "hostname unchanged across redeploy ($HOST)" \
    || check_fail "HOSTNAME CHANGED: expected $EXPECT_HOSTNAME, got $HOST — every vlc.xml would break"
fi

# --- 2. reachability --------------------------------------------------------------------
step_header 2 6 "Reachability and TLS"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "https://$HOST/" || echo 000)
[ "$code" != "000" ] && check_ok "TLS handshake and HTTP response ($code)" \
  || check_fail "no HTTPS response from $HOST"

# --- 3. per-path manifests --------------------------------------------------------------
step_header 3 6 "Channel manifests"
IFS=',' read -ra paths <<< "${RELAY_PATHS:-}"
served=0
for p in "${paths[@]}"; do
  body=$(curl -s --max-time 20 "https://$HOST/$p/index.m3u8" || true)
  if grep -q '#EXTM3U' <<<"$body"; then
    check_ok "$p serves a manifest"
    served=$(( served + 1 ))
    FIRST_SERVED="${FIRST_SERVED:-$p}"
  else
    # Not a failure on its own: a path with no publisher legitimately 404s.
    skipped "$p has no publisher (expected when page-stream is not pointed here yet)"
  fi
done
[ "$served" -gt 0 ] && check_ok "$served/${#paths[@]} channels live" \
  || warn "no channels are publishing — start page-stream in relay mode to test fully"

# --- 4. the cache rule ------------------------------------------------------------------
step_header 4 6 "Cache behaviour (the expensive one)"
if [ -n "${FIRST_SERVED:-}" ]; then
  url="https://$HOST/$FIRST_SERVED/index.m3u8"
  curl -s -o /dev/null --max-time 20 "$url" || true
  sleep 1
  hdrs=$(curl -s -D - -o /dev/null --max-time 20 "$url" || true)
  xcache=$(grep -i '^x-cache:' <<<"$hdrs" | tr -d '\r' | head -1)
  if grep -qiE 'x-cache:.*(HIT|TCP_HIT|PARTIAL_HIT)' <<<"$hdrs"; then
    check_ok "second request was a cache HIT (${xcache:-x-cache present})"
  else
    check_fail "no cache hit (${xcache:-no X-Cache header}) — the session query-string rule may be missing; origin egress will roughly double"
  fi

  # A per-session query string must NOT split the cache key.
  curl -s -o /dev/null --max-time 20 "${url}?session=aaaa" || true   # prime
  s2=$(curl -s -D - -o /dev/null --max-time 20 "${url}?session=bbbb" || true)
  if grep -qiE 'x-cache:.*(HIT|TCP_HIT|PARTIAL_HIT)' <<<"$s2"; then
    check_ok "differing ?session values share one cache key"
  else
    check_fail "?session=bbbb missed after ?session=aaaa — IgnoreSpecifiedQueryStrings is not in effect"
  fi

  # Explicit TTL, not Front Door's random 1-3 day default.
  cc=$(grep -i '^cache-control:' <<<"$hdrs" | tr -d '\r' || true)
  if grep -qiE 'max-age=([0-9]|[1-5][0-9])\b' <<<"$cc"; then
    check_ok "manifest carries a short explicit TTL ($cc)"
  else
    check_fail "manifest TTL looks wrong (${cc:-none}) — a random multi-day TTL would freeze the displays"
  fi
else
  skipped "no live channel, so cache behaviour cannot be asserted"
  warn "cache correctness is UNVERIFIED — re-run with a publisher active"
fi

# --- 5. control surfaces must not be exposed --------------------------------------------
step_header 5 6 "Attack surface"
if [ -n "$IP" ]; then
  for port in 9997 9998 8892; do
    if timeout 5 bash -c "</dev/tcp/$IP/$port" 2>/dev/null; then
      check_fail "port $port is REACHABLE on the public IP — it must be loopback-only"
    else
      check_ok "port $port not reachable from the internet"
    fi
  done
  # 8888 should only be reachable via Front Door, not directly.
  if timeout 5 bash -c "</dev/tcp/$IP/8888" 2>/dev/null; then
    check_fail "origin port 8888 is reachable directly — the CDN, WAF and cache can be bypassed"
  else
    check_ok "origin 8888 not directly reachable (Front Door only)"
  fi
else
  skipped "ingest IP unknown; skipping port checks"
fi

# --- 6. guardrails present --------------------------------------------------------------
step_header 6 6 "Cost guardrails"
if az consumption budget show --budget-name relay-budget >/dev/null 2>&1 \
  || az consumption budget list --query "[?name=='relay-budget']" -o tsv 2>/dev/null | grep -q .; then
  check_ok "budget exists"
else
  check_fail "no budget found — an unbounded public endpoint with no cost alarm"
fi
waf="${AZ_FRONTDOOR_PROFILE//-/}waf"
if az network front-door waf-policy show -g "$AZ_RESOURCE_GROUP" -n "$waf" >/dev/null 2>&1; then
  check_ok "WAF rate-limit policy exists"
else
  check_fail "no WAF policy — the rate limit is not enforced"
fi

printf "\n"
banner "VERIFICATION SUMMARY"
if [ "$failed" -eq 0 ]; then
  printf "${GREEN}${BOLD}✓ %d checks passed.${NC}\n" "$pass"
  exit 0
fi
printf "${RED}${BOLD}✗ %d failed, %d passed.${NC}\n" "$failed" "$pass"
exit 1
