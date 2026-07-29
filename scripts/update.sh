#!/usr/bin/env bash
# update.sh — roll new config or a new image without recreating infrastructure.
#
# The common case: someone edited relay.yml (a new channel, a different tier) or the
# MediaMTX image needs bumping. Recreating the VM would change nothing useful and would
# drop the stream for minutes.
#
#   scripts/update.sh              # re-render check, push image, redeliver config, verify
#   scripts/update.sh --config-only
#   scripts/update.sh --image-only
#
# Rolls back on failure: the previous image digest is captured first and restored if the
# new one does not come up healthy, because a failed update during a cutover is the worst
# possible time to be debugging.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/ui.sh
source "$REPO_ROOT/scripts/lib/ui.sh"

DEPT="${DEPT:-orfe}"
CONFIG_REPO="${CONFIG_REPO:-$REPO_ROOT/../stream-relay-config}"
DEPT_DIR="$CONFIG_REPO/$DEPT"
DO_CONFIG=1
DO_IMAGE=1

while [ $# -gt 0 ]; do
  case "$1" in
    --config-only) DO_IMAGE=0 ;;
    --image-only)  DO_CONFIG=0 ;;
    --dept) DEPT="${2:?}"; DEPT_DIR="$CONFIG_REPO/$DEPT"; shift ;;
    -h|--help) sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

[ -f "$DEPT_DIR/deploy.env" ] || die "missing $DEPT_DIR/deploy.env"
set -a
# shellcheck disable=SC1090
source "$DEPT_DIR/deploy.env"
set +a

banner "STREAM-RELAY UPDATE — $DEPT"

az account show >/dev/null 2>&1 || die "not logged in"
[ "$(az group exists -n "$AZ_RESOURCE_GROUP")" = "true" ] \
  || die "$AZ_RESOURCE_GROUP does not exist — this is a fresh deploy, use scripts/bootstrap.sh"

TOTAL=5

step_header 1 "$TOTAL" "Checking configuration is current"
(cd "$CONFIG_REPO" && python3 tools/render-relay.py "$DEPT" --check >/dev/null 2>&1) \
  || die "generated files are stale — run render-relay.py and commit before updating"
ok "generated files match relay.yml"

step_header 2 "$TOTAL" "Capturing the current image for rollback"
PREV_DIGEST=$(az vm run-command invoke -g "$AZ_RESOURCE_GROUP" -n "$AZ_VM_NAME" \
  --command-id RunShellScript \
  --scripts "docker inspect --format '{{index .RepoDigests 0}}' stream-relay 2>/dev/null || echo none" \
  --query "value[0].message" -o tsv 2>/dev/null | grep -oE '[a-z0-9./:-]+@sha256:[0-9a-f]+' | head -1 || echo "")
if [ -n "$PREV_DIGEST" ]; then
  ok "current image: $PREV_DIGEST"
else
  warn "could not determine the current image digest — rollback will be unavailable"
fi

step_header 3 "$TOTAL" "Building and pushing the image"
if [ "$DO_IMAGE" = "1" ]; then
  az acr build --registry "$AZ_ACR_NAME" --image "stream-relay-mediamtx:latest" \
    --platform linux/amd64 "$REPO_ROOT/docker/mediamtx" >/dev/null
  ok "image rebuilt in ACR (linux/amd64)"
else
  skipped "--config-only"
fi

step_header 4 "$TOTAL" "Delivering config and restarting"
if [ "$DO_CONFIG" = "1" ]; then
  encoded=$(base64 < "$DEPT_DIR/mediamtx.yml.tmpl" | tr -d '\n')
  az vm run-command invoke -g "$AZ_RESOURCE_GROUP" -n "$AZ_VM_NAME" \
    --command-id RunShellScript \
    --scripts "mkdir -p /etc/stream-relay/config && echo '$encoded' | base64 -d > /etc/stream-relay/config/mediamtx.yml.tmpl" \
    -o none
  ok "config template delivered"
else
  skipped "--image-only"
fi

az vm run-command invoke -g "$AZ_RESOURCE_GROUP" -n "$AZ_VM_NAME" \
  --command-id RunShellScript --scripts "systemctl restart stream-relay.service" -o none
ok "service restarted"

step_header 5 "$TOTAL" "Verifying"
sleep 15
if "$REPO_ROOT/scripts/verify.sh" --dept "$DEPT"; then
  ok "update verified"
else
  fail "verification FAILED after update"
  if [ -n "$PREV_DIGEST" ]; then
    warn "rolling back to $PREV_DIGEST"
    az vm run-command invoke -g "$AZ_RESOURCE_GROUP" -n "$AZ_VM_NAME" \
      --command-id RunShellScript \
      --scripts "docker rm -f stream-relay; docker run -d --name stream-relay --restart unless-stopped -e SRT_PUBLISH_PASSPHRASE=\"\$(az keyvault secret show --vault-name $AZ_KEY_VAULT --name $SRT_PASSPHRASE_SECRET --query value -o tsv)\" -v /etc/stream-relay/config:/config:ro -p 8890:8890/udp -p 8888:8888 $PREV_DIGEST" \
      -o none
    warn "rolled back — investigate before retrying"
  else
    fail "no rollback target was captured; the relay may be down"
  fi
  exit 1
fi
