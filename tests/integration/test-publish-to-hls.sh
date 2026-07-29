#!/usr/bin/env bash
# Integration test: encrypted SRT publish -> MediaMTX -> decodable HLS.
#
# Everything here was first run by hand, and each assertion corresponds to a real defect
# found that way:
#   * `srtp: no`            - not a MediaMTX field; unknown keys abort startup
#   * MoQ on :8892          - enabled by default, self-signing a cert; now disabled
#   * streamid publish:p:u:p - the 4-field form FAILS. The credential is SRT wire
#                              encryption (passphrase=), not a streamid user:pass
#
# Needs only Docker. No cloud, no spend.
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONFIG_DIR="${RELAY_CONFIG_DIR:-$REPO_ROOT/../stream-relay-config/orfe}"
NET="stream-relay-itest-net"
RELAY="stream-relay-itest"
PUB="stream-relay-itest-pub"
IMAGE="stream-relay-mediamtx:itest"
PUBLISH_PATH="${RELAY_TEST_PATH:-news}"
IDLE_PATH="${RELAY_IDLE_PATH:-scenic}"

PASS=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 40)

pass_count=0
fail_count=0

ok()   { printf "  ${GREEN}✓${NC} %s\n" "$1"; pass_count=$((pass_count + 1)); }
bad()  { printf "  ${RED}✗ %s${NC}\n" "$1"; fail_count=$((fail_count + 1)); }
info() { printf "  ${CYAN}·${NC} %s\n" "$1"; }

cleanup() {
  docker rm -f "$RELAY" "$PUB" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

printf "${BLUE}${BOLD}======================================================================${NC}\n"
printf "${CYAN}${BOLD}        STREAM-RELAY INTEGRATION: SRT -> MediaMTX -> HLS             ${NC}\n"
printf "${BLUE}${BOLD}======================================================================${NC}\n"

command -v docker >/dev/null || { printf "${RED}docker not found${NC}\n"; exit 1; }
docker info >/dev/null 2>&1 || { printf "${RED}Docker daemon not running${NC}\n"; exit 1; }

if [ ! -f "$CONFIG_DIR/mediamtx.yml.tmpl" ]; then
  printf "${YELLOW}⚠ No config template at %s${NC}\n" "$CONFIG_DIR/mediamtx.yml.tmpl"
  printf "  Check out stream-relay-config beside this repo, or set RELAY_CONFIG_DIR.\n"
  exit 77   # distinct code so CI can treat "not configured" separately from "failed"
fi

printf "\n${BOLD}[1/6] Building image...${NC}\n"
docker build -q -t "$IMAGE" "$REPO_ROOT/docker/mediamtx" >/dev/null
ok "$IMAGE"

printf "\n${BOLD}[2/6] Entrypoint must fail closed on a bad passphrase...${NC}\n"
docker network create "$NET" >/dev/null 2>&1 || true

run_relay() { docker run -d --name "$RELAY" --network "$NET" -e SRT_PUBLISH_PASSPHRASE="$1" \
    -v "$CONFIG_DIR":/config:ro "$IMAGE" >/dev/null 2>&1; }

for bad_pass in "" "short" 'has/slash&amp'; do
  docker rm -f "$RELAY" >/dev/null 2>&1 || true
  if [ -z "$bad_pass" ]; then
    docker run --rm --network "$NET" -v "$CONFIG_DIR":/config:ro "$IMAGE" >/dev/null 2>&1 \
      && bad "empty passphrase was accepted" || ok "empty passphrase rejected"
  else
    docker run --rm --network "$NET" -e SRT_PUBLISH_PASSPHRASE="$bad_pass" \
      -v "$CONFIG_DIR":/config:ro "$IMAGE" >/dev/null 2>&1 \
      && bad "invalid passphrase '$bad_pass' was accepted" \
      || ok "invalid passphrase rejected: '$bad_pass'"
  fi
done

printf "\n${BOLD}[3/6] Starting relay...${NC}\n"
docker rm -f "$RELAY" >/dev/null 2>&1 || true
run_relay "$PASS"
for _ in $(seq 1 30); do
  status=$(docker inspect "$RELAY" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' 2>/dev/null || echo gone)
  [ "$status" = "healthy" ] && break
  sleep 1
done
[ "$status" = "healthy" ] && ok "relay healthy" || bad "relay never became healthy (status=$status)"

logs=$(docker logs "$RELAY" 2>&1)
grep -q 'ERR' <<<"$logs" && bad "MediaMTX reported an error: $(grep ERR <<<"$logs" | head -1)" \
  || ok "no MediaMTX config errors"
grep -q 'MoQ' <<<"$logs" && bad "MoQ is listening - it must be disabled (moq: no)" \
  || ok "MoQ disabled (no :8892 listener)"
grep -q '\[SRT\] started' <<<"$logs" && ok "SRT listener up" || bad "no SRT listener"
grep -q '\[HLS\] started' <<<"$logs" && ok "HLS listener up" || bad "no HLS listener"
grep -q '127.0.0.1:9997' <<<"$logs" && ok "API bound to loopback only" || bad "API not loopback-bound"
grep -qF "$PASS" <<<"$logs" && bad "PASSPHRASE LEAKED INTO LOGS" || ok "no passphrase in logs"

printf "\n${BOLD}[4/6] Rejecting an unauthenticated publish...${NC}\n"
docker run --rm --network "$NET" --entrypoint ffmpeg "$IMAGE" \
  -hide_banner -loglevel error -f lavfi -i "testsrc=size=320x180:rate=5" -t 2 \
  -c:v libx264 -preset ultrafast -f mpegts \
  "srt://$RELAY:8890?streamid=publish:$PUBLISH_PATH&latency=200000" >/dev/null 2>&1 \
  && bad "unencrypted publish was ACCEPTED - the passphrase is not enforced" \
  || ok "unencrypted publish rejected"

printf "\n${BOLD}[5/6] Publishing with the generated URL form...${NC}\n"
URL="srt://$RELAY:8890?streamid=publish:$PUBLISH_PATH&passphrase=$PASS&pbkeylen=32&latency=200000"
info "streamid=publish:$PUBLISH_PATH (credential is SRT encryption, not a streamid field)"
docker run -d --name "$PUB" --network "$NET" --entrypoint ffmpeg "$IMAGE" \
  -hide_banner -loglevel error -re \
  -f lavfi -i "testsrc=size=1920x1080:rate=30" \
  -f lavfi -i "anullsrc=channel_layout=stereo:sample_rate=44100" \
  -c:v libx264 -preset veryfast -tune zerolatency -pix_fmt yuv420p \
  -b:v 1500k -maxrate 1500k -bufsize 3000k -g 60 -c:a aac -b:a 128k \
  -t 60 -f mpegts "$URL" >/dev/null

for _ in $(seq 1 25); do
  docker logs "$RELAY" 2>&1 | grep -q "is publishing to path '$PUBLISH_PATH'" && break
  sleep 1
done
docker logs "$RELAY" 2>&1 | grep -q "is publishing to path '$PUBLISH_PATH'" \
  && ok "encrypted publish accepted on '$PUBLISH_PATH'" \
  || { bad "publish never succeeded"; docker logs "$PUB" 2>&1 | tail -5; }

printf "\n${BOLD}[6/6] Reading HLS back...${NC}\n"
sleep 6
manifest=$(docker run --rm --network "$NET" --entrypoint sh "$IMAGE" \
  -c "wget -qO- http://$RELAY:8888/$PUBLISH_PATH/index.m3u8" 2>/dev/null || true)
grep -q '#EXTM3U' <<<"$manifest" && ok "manifest served" || bad "no valid manifest"
grep -q 'RESOLUTION=1920x1080' <<<"$manifest" && ok "1080p advertised" \
  || bad "expected RESOLUTION=1920x1080, got: $(grep RESOLUTION <<<"$manifest" || echo none)"

probe=$(docker run --rm --network "$NET" --entrypoint ffprobe "$IMAGE" -v error \
  -show_entries stream=codec_name,width,height -of csv=p=0 \
  -i "http://$RELAY:8888/$PUBLISH_PATH/index.m3u8" 2>/dev/null | head -4 || true)
grep -q 'h264,1920,1080' <<<"$probe" && ok "decodable 1920x1080 h264" || bad "ffprobe: $probe"
grep -q 'aac' <<<"$probe" && ok "aac audio track present" || bad "no aac track"

idle_rc=$(docker run --rm --network "$NET" --entrypoint sh "$IMAGE" \
  -c "wget -q -O/dev/null http://$RELAY:8888/$IDLE_PATH/index.m3u8 2>/dev/null; echo \$?" || true)
[ "$idle_rc" != "0" ] && ok "unpublished path '$IDLE_PATH' returns an error, not an empty stream" \
  || bad "unpublished path served something"

printf "\n${BLUE}${BOLD}======================================================================${NC}\n"
if [ "$fail_count" -eq 0 ]; then
  printf "${GREEN}${BOLD}✓ %d assertions passed.${NC}\n" "$pass_count"
  exit 0
fi
printf "${RED}${BOLD}✗ %d failed, %d passed.${NC}\n" "$fail_count" "$pass_count"
exit 1
