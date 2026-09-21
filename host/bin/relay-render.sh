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

TOK=$(curl -s -H Metadata:true --max-time 10 \
  "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')
[ -n "$TOK" ] || { echo "IMDS returned no token" >&2; exit 1; }

curl -s --max-time 10 -H "Authorization: Bearer $TOK" \
  "https://$KV.vault.azure.net/secrets/$SECRET?api-version=7.4" \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);sys.stdout.write(d["value"]) if "value" in d else sys.exit("vault: "+json.dumps(d)[:200])' \
  > /etc/stream-relay/srt.passphrase
chmod 0600 /etc/stream-relay/srt.passphrase
[ -s /etc/stream-relay/srt.passphrase ] || { echo "vault returned an empty passphrase" >&2; exit 1; }
grep -qE '^[A-Za-z0-9_-]{10,79}$' /etc/stream-relay/srt.passphrase \
  || { echo "passphrase fails the shape the entrypoint enforces" >&2; exit 1; }

SRT_PUBLISH_PASSPHRASE="$(cat /etc/stream-relay/srt.passphrase)" \
  envsubst '$SRT_PUBLISH_PASSPHRASE' < "$TMPL" > /etc/stream-relay/mediamtx.yml
chmod 0600 /etc/stream-relay/mediamtx.yml
echo "rendered /etc/stream-relay/mediamtx.yml from $KV/$SECRET"
