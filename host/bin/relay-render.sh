#!/bin/bash
# Render /etc/stream-relay/mediamtx.yml from the template and the Key Vault passphrase,
# then restart the relay. Root-only, and the ONE thing the Actions runner may do as root.
#
# The runner never sees the passphrase: it is fetched here, from the VM's own managed
# identity via IMDS, written 0600, and substituted into a 0600 config. Nothing is stored.
set -eu
umask 077
KV="${KV_NAME:-orfeweb-jfg2rn-kv}"
SECRET="${KV_SECRET:-srt-publish-passphrase}"
TMPL=/etc/stream-relay/mediamtx.yml.tmpl
[ -f "$TMPL" ] || { echo "missing $TMPL" >&2; exit 1; }

# The IMDS dance lives in relay-secret.sh now, shared with relay-apply.sh. One copy to
# get right rather than two that drift.
KV_NAME="$KV" /usr/local/bin/relay-secret.sh "$SECRET" > /etc/stream-relay/srt.passphrase
chmod 0600 /etc/stream-relay/srt.passphrase
[ -s /etc/stream-relay/srt.passphrase ] || { echo "vault returned an empty passphrase" >&2; exit 1; }
grep -qE '^[A-Za-z0-9_-]{10,79}$' /etc/stream-relay/srt.passphrase \
  || { echo "passphrase fails the shape the entrypoint enforces" >&2; exit 1; }

SRT_PUBLISH_PASSPHRASE="$(cat /etc/stream-relay/srt.passphrase)" \
  envsubst '$SRT_PUBLISH_PASSPHRASE' < "$TMPL" > /etc/stream-relay/mediamtx.yml
chmod 0600 /etc/stream-relay/mediamtx.yml
echo "rendered /etc/stream-relay/mediamtx.yml from $KV/$SECRET"
