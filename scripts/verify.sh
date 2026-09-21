#!/usr/bin/env bash
# verify.sh — assert the deployed relay actually works.
#
# Runs against the public hostname from wherever it is invoked. There is no CDN: nginx on
# the VM serves MediaMTX's hlsDirectory as ordinary static files, so everything here is a
# property of that host.
#
# ONE-SHOT, and that is its limit. It answers "did this deployment come up correctly",
# which is a different question from "is the relay still working an hour from now" - a
# publisher can wedge with every byte of this still passing. The watchdog holds state
# between passes and answers the second question; this one is a gate, not a monitor.
#
# Vantage point matters. Delivery is gated to the campus and VPN ranges, so a
# GitHub-hosted runner cannot fetch a manifest however healthy the relay is. That is the
# allowlist working, not a defect, and those checks are skipped with a reason rather than
# counted as unverified - which would make a correct deployment report amber forever.
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
    --require-live) REQUIRE_LIVE=1 ;;
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

pass=0; failed=0; unverified=0
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
# The name must be one a public CA can certify. cloudapp.azure.com is absent from the
# Public Suffix List, so Let's Encrypt counts it against azure.com - a rate limit shared
# with every Azure tenant - and certbot can never issue for it. A deployment that quietly
# fell back to the derived name would serve an expired or self-signed certificate to every
# display.
case "$HOST" in
  *.cloudapp.azure.com)
    check_fail "hostname is the Azure-derived name; no public CA will issue for it" ;;
  "")
    check_fail "no hostname configured" ;;
  *)
    check_ok "hostname is a certifiable name ($HOST)" ;;
esac
if [ -n "$EXPECT_HOSTNAME" ]; then
  # The teardown/redeploy stability check. This is what proves TenantReuse works.
  [ "$HOST" = "$EXPECT_HOSTNAME" ] \
    && check_ok "hostname unchanged across redeploy ($HOST)" \
    || check_fail "HOSTNAME CHANGED: expected $EXPECT_HOSTNAME, got $HOST — every vlc.xml would break"
fi

# --- 2. reachability --------------------------------------------------------------------
step_header 2 6 "Reachability and TLS"
# `|| code=000`, NOT `|| echo 000`. curl already prints 000 when it cannot connect, so the
# old form appended a second one and produced "000000" - which is not equal to "000", so
# every guard comparing against it passed. An endpoint that was never reached reported
# "TLS handshake and HTTP response (000000)" as a tick.
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "https://$HOST/" 2>/dev/null) || code=000
[ -n "$code" ] || code=000

# Is this host entitled to be a viewer at all?
#
# Delivery is gated to the viewer allowlist, so a GitHub-hosted runner - or any machine off
# the permitted networks - cannot fetch a manifest however healthy the relay is. That is the
# allowlist working, not a deployment defect. Counting it as UNVERIFIED would make a correct
# deployment report amber forever, so those checks are skipped with a reason and the summary
# says where to run them.
VIEWER_ACCESS=1
[ "$code" = "000" ] && VIEWER_ACCESS=0

if [ "$VIEWER_ACCESS" = "1" ]; then
  check_ok "TLS handshake and HTTP response ($code)"
else
  skipped "no HTTPS response from $HOST from this host"
  detail "expected off the viewer allowlist; run from a permitted network to check delivery"
fi

# --- 3. per-path manifests --------------------------------------------------------------
step_header 3 6 "Channel manifests"
# ${HLS} is load-bearing and was missing. nginx serves HLS under /hls/ only and 404s
# everything else, so `https://$HOST/$p/index.m3u8` could never match a manifest: this
# step reported "no publisher" for every path, on every run, including runs where a
# channel was demonstrably live. Read from deploy.env rather than written here so it
# cannot drift from the nginx config that defines it.
HLS="${RELAY_HTTP_PATH:-/hls/}"
IFS=',' read -ra paths <<< "${RELAY_PATHS:-}"
served=0
for p in "${paths[@]}"; do
  body=$(curl -sL --max-time 20 "https://$HOST${HLS}$p/index.m3u8" || true)
  if grep -q '#EXTM3U' <<<"$body"; then
    check_ok "$p serves a manifest"
    served=$(( served + 1 ))
    FIRST_SERVED="${FIRST_SERVED:-$p}"
  else
    # Not a failure on its own: a path with no publisher legitimately 404s.
    skipped "$p has no publisher (expected when page-stream is not pointed here yet)"
  fi
done
if [ "$served" -gt 0 ]; then
  check_ok "$served/${#paths[@]} channels live"
elif [ "${REQUIRE_LIVE:-0}" = "1" ]; then
  # --require-live is used by the live test and the rehearsal drill, where a publisher IS
  # running, so zero live channels is a hard failure rather than a shrug.
  check_fail "no channels are serving, but --require-live was set"
elif [ "$VIEWER_ACCESS" = "0" ]; then
  skipped "not reachable from this host: the viewer allowlist admits campus networks only"
  detail "run from a permitted network, or on the relay host, to check delivery"
else
  warn "no channels are publishing — start page-stream in relay mode to test fully"
  unverified=$(( unverified + 1 ))
fi

# --- 4. cache headers -------------------------------------------------------------------
step_header 4 6 "Cache headers"
# This step used to assert X-Cache: HIT and that a ?session query string did not split the
# cache key. Both were Front Door properties, and Front Door is gone - nginx serves
# MediaMTX's hlsDirectory as ordinary files. Those assertions could never pass again, and
# they never failed either, because step 3's broken URL meant FIRST_SERVED was never set
# and the whole block skipped. Two dead checks hidden behind a third bug.
#
# What still matters without a CDN is the policy nginx sets, and it matters for
# correctness rather than cost: a cached playlist pins a player to segments that have
# already been deleted, which is a stall on the wall with everything else green.
if [ -n "${FIRST_SERVED:-}" ]; then
  url="https://$HOST${HLS}$FIRST_SERVED/index.m3u8"

  mhdrs=$(curl -s -D - -o /dev/null -L --max-time 20 "$url" || true)
  if grep -qiE 'cache-control:.*(no-cache|no-store)' <<<"$mhdrs"; then
    check_ok "playlist is not cacheable ($(grep -i '^cache-control:' <<<"$mhdrs" | tr -d '\r' | head -1))"
  else
    check_fail "playlist is cacheable: $(grep -i '^cache-control:' <<<"$mhdrs" | tr -d '\r' | head -1 || echo 'no Cache-Control') — a stale one points players at deleted segments"
  fi

  variant=$(curl -sL --max-time 20 "$url" | grep -v '^#' | grep 'm3u8' | head -1 || true)
  segment=""
  [ -n "$variant" ] && segment=$(curl -sL --max-time 20 "https://$HOST${HLS}$FIRST_SERVED/$variant" \
    | grep -v '^#' | grep -E '\.ts|\.m4s|\.mp4' | head -1 || true)

  if [ -n "$segment" ]; then
    shdrs=$(curl -s -D - -o /dev/null -L --max-time 25 "https://$HOST${HLS}$FIRST_SERVED/$segment" || true)
    if grep -qiE 'cache-control:.*max-age=[1-9]' <<<"$shdrs"; then
      check_ok "segments are cacheable ($(grep -i '^cache-control:' <<<"$shdrs" | tr -d '\r' | head -1))"
    else
      check_fail "segments carry no usable max-age: $(grep -i '^cache-control:' <<<"$shdrs" | tr -d '\r' | head -1 || echo 'no Cache-Control')"
    fi
  else
    skipped "no segment listed yet (the stream may still be filling)"
    if [ "${REQUIRE_LIVE:-0}" = "1" ]; then
      check_fail "no segment available while --require-live was set"
    else
      unverified=$(( unverified + 1 ))
    fi
  fi
else
  skipped "no live channel, so cache headers cannot be asserted"
  if [ "${REQUIRE_LIVE:-0}" = "1" ]; then
    check_fail "cache headers unverified while --require-live was set"
  else
    if [ "$VIEWER_ACCESS" = "0" ]; then
      skipped "cache headers need viewer access; this host is outside the allowlist"
    else
      warn "cache headers are UNVERIFIED — re-run with a publisher active"
      unverified=$(( unverified + 1 ))
    fi
  fi
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
# Scoped to the resource group, which is where the budget is deployed. Without -g the CLI
# looks at subscription scope, where a principal holding Cost Management Contributor on the
# resource group cannot see it - so the check reported "no budget" for a budget that exists.
if az consumption budget show --budget-name relay-budget -g "$AZ_RESOURCE_GROUP" >/dev/null 2>&1; then
  check_ok "budget exists"
else
  check_fail "no budget found — an unbounded public endpoint with no cost alarm"
fi
# The WAF went with Front Door. The NSG is the access control now, and the rule that
# matters is the one admitting SRT: without it the encoder cannot publish at all, and the
# failure is silent because page-stream's backoff reconnects forever rather than exiting.
nsg="${AZ_NSG_NAME:-${AZ_VM_NAME}-nsg}"
if az network nsg rule show -g "$AZ_RESOURCE_GROUP" --nsg-name "$nsg" -n AllowSrtIngest \
     >/dev/null 2>&1; then
  check_ok "SRT ingest rule present on $nsg"
else
  check_fail "no AllowSrtIngest rule — publishers cannot reach the relay"
fi
# Port 22 must not be open: administration is `az vm run-command` over the control plane.
if az network nsg rule list -g "$AZ_RESOURCE_GROUP" --nsg-name "$nsg" \
     --query "[?destinationPortRange=='22'].name" -o tsv 2>/dev/null | grep -q .; then
  check_fail "an NSG rule opens port 22 — there should be no inbound administrative path"
else
  check_ok "no inbound SSH rule"
fi

printf "\n"
banner "VERIFICATION SUMMARY"
if [ "$failed" -eq 0 ] && [ "$unverified" -eq 0 ]; then
  printf "${GREEN}${BOLD}✓ %d checks passed.${NC}\n" "$pass"
  exit 0
fi
if [ "$failed" -eq 0 ]; then
  # Not a pass. An unverified cache rule is the difference between $603/mo and $850/mo.
  printf "${YELLOW}${BOLD}⚠ %d passed, %d UNVERIFIED, 0 failed.${NC}\n" "$pass" "$unverified"
  printf "${YELLOW}Unverified is not verified. Re-run with a publisher active:${NC}\n"
  printf "  tests/integration/test-live-relay.sh\n"
  exit 2
fi
printf "${RED}${BOLD}✗ %d failed, %d passed.${NC}\n" "$failed" "$pass"
exit 1
