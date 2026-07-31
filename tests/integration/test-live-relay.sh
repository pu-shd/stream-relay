#!/usr/bin/env bash
# Live end-to-end test against a DEPLOYED relay.
#
# This is the test that actually answers "would the fallback work if Kaltura vanished?".
# verify.sh alone cannot: with no publisher, the cache assertions - the expensive ones -
# skip, and a skipped assertion looks deceptively like a passing one.
#
# So this publishes a real encrypted SRT stream from this machine to the relay's PUBLIC
# ingest, exactly as a page-stream producer would, then verifies HLS through Front Door.
#
#   tests/integration/test-live-relay.sh
#   tests/integration/test-live-relay.sh --duration 180
#
# Requires: a deployed relay (scripts/deploy.sh), az login, docker.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../scripts/lib/ui.sh
source "$REPO_ROOT/scripts/lib/ui.sh"

DEPT="${DEPT:-orfe}"
CONFIG_REPO="${CONFIG_REPO:-$REPO_ROOT/../stream-relay-config}"
DEPT_DIR="$CONFIG_REPO/$DEPT"
DURATION=180
PUB_PATH="${RELAY_TEST_PATH:-news}"
PUB_NAME="stream-relay-live-pub"

while [ $# -gt 0 ]; do
  case "$1" in
    --duration) DURATION="${2:?}"; shift ;;
    --path) PUB_PATH="${2:?}"; shift ;;
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
# shellcheck source=../../scripts/lib/state.sh
source "$REPO_ROOT/scripts/lib/state.sh"

pass=0; failed=0
t_ok()   { ok "$1"; pass=$(( pass + 1 )); }
t_fail() { fail "$1"; failed=$(( failed + 1 )); }

cleanup() { docker rm -f "$PUB_NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM

banner "LIVE RELAY TEST — publish, then verify through Front Door"

IP=$(state_get_output ingestIpAddress || true)
HOST=$(state_get_output frontDoorHostName || true)
[ -n "$IP" ]   || die "no ingest IP in state; run scripts/deploy.sh first"
[ -n "$HOST" ] || die "no Front Door hostname in state; run: scripts/deploy.sh --step discover-hostname"
info "ingest : srt://$IP:${SRT_PORT}"
info "egress : https://$HOST/$PUB_PATH/index.m3u8"

step_header 1 5 "Fetching the publish passphrase from Key Vault"
# Read via the operator's own credentials. The VM reads the same secret with its managed
# identity; nothing is stored on either side.
PASS=$(az keyvault secret show --vault-name "$AZ_KEY_VAULT" --name "$SRT_PASSPHRASE_SECRET" \
  --query value -o tsv 2>/dev/null)
[ -n "$PASS" ] || die "could not read $SRT_PASSPHRASE_SECRET from $AZ_KEY_VAULT"
t_ok "passphrase retrieved (${#PASS} chars, not echoed)"

step_header 2 5 "Publishing encrypted SRT from this machine"
# Exactly the URL form the generated ingest-urls.env prescribes.
URL="srt://$IP:${SRT_PORT}?streamid=publish:${PUB_PATH}&passphrase=${PASS}&pbkeylen=${PBKEYLEN:-32}&latency=200000"
docker rm -f "$PUB_NAME" >/dev/null 2>&1 || true
docker run -d --name "$PUB_NAME" --entrypoint ffmpeg bluenviron/mediamtx:1.19.3-ffmpeg \
  -hide_banner -loglevel warning -re \
  -f lavfi -i "testsrc=size=1920x1080:rate=30" \
  -f lavfi -i "anullsrc=channel_layout=stereo:sample_rate=44100" \
  -c:v libx264 -preset veryfast -tune zerolatency -pix_fmt yuv420p \
  -b:v 1500k -maxrate 1500k -bufsize 3000k -g 60 -c:a aac -b:a 128k \
  -t "$DURATION" -f mpegts "$URL" >/dev/null 2>&1
sleep 5
if docker ps --filter "name=$PUB_NAME" --format '{{.Names}}' | grep -q "$PUB_NAME"; then
  t_ok "publisher running (${DURATION}s of 1080p30)"
else
  t_fail "publisher exited immediately:"
  docker logs "$PUB_NAME" 2>&1 | tail -8 | sed 's/^/      /'
  # Almost always the NSG blocking this machine's egress IP, or a passphrase mismatch.
  info "check: does the NSG allow 8890/udp from $(curl -s --max-time 10 https://api.ipify.org || echo '<your ip>')?"
fi

step_header 3 5 "Waiting for the stream to appear through the CDN"
# Front Door needs a moment on first request per POP, plus MediaMTX's segment buildup.
appeared=0
for _ in $(seq 1 24); do
  if curl -fsS --max-time 15 "https://$HOST/$PUB_PATH/index.m3u8" 2>/dev/null | grep -q '#EXTM3U'; then
    appeared=1; break
  fi
  sleep 5
done
[ "$appeared" = "1" ] && t_ok "manifest served through Front Door" \
  || t_fail "manifest never appeared at https://$HOST/$PUB_PATH/index.m3u8"

step_header 4 5 "Decoding the stream through the CDN"
if [ "$appeared" = "1" ]; then
  probe=$(docker run --rm --entrypoint ffprobe bluenviron/mediamtx:1.19.3-ffmpeg -v error \
    -show_entries stream=codec_name,width,height -of csv=p=0 \
    -i "https://$HOST/$PUB_PATH/index.m3u8" 2>&1 | head -4 || true)
  grep -q 'h264,1920,1080' <<<"$probe" \
    && t_ok "ffprobe decoded 1920x1080 h264 via Front Door" \
    || t_fail "ffprobe output: $probe"
  grep -q 'aac' <<<"$probe" && t_ok "aac track present" || t_fail "no aac track"
else
  skipped "no manifest, so nothing to decode"
fi

step_header 5 5 "Full verification (cache rules now testable)"
# With a live publisher, verify.sh's cache-hit and session-key assertions actually run
# instead of skipping - which is the entire reason this script exists.
if "$REPO_ROOT/scripts/verify.sh" --dept "$DEPT"; then
  t_ok "verify.sh passed with a live channel"
else
  t_fail "verify.sh reported failures (see above)"
fi

printf "\n"
banner "LIVE RELAY SUMMARY"
if [ "$failed" -eq 0 ]; then
  printf "${GREEN}${BOLD}✓ %d checks passed. The fallback works end to end.${NC}\n" "$pass"
  exit 0
fi
printf "${RED}${BOLD}✗ %d failed, %d passed.${NC}\n" "$failed" "$pass"
exit 1
