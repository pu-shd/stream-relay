#!/bin/bash
# Print one Key Vault secret to stdout, fetched with the VM's own managed identity.
#
#   relay-secret.sh <secret-name>
#
# NOT in the sudoers grant, deliberately. It is called BY relay-render.sh and
# relay-apply.sh, which already run as root; giving the Actions runner a third path to
# root would widen the privilege boundary to fetch a value the runner must never see.
# So: a third script, and still exactly two things the runner may do.
#
# It exists because both callers needed the same IMDS dance and a copy each is a copy
# each to get wrong. The token is never written down; the value goes to stdout and the
# caller decides where it lands - relay-render.sh into a 0600 config, relay-apply.sh into
# a 0600 env file. Neither echoes it.
#
# IMDS is unreachable from containers (block-imds-from-containers.service drops it in
# DOCKER-USER), which is exactly why this runs on the host.
set -eu
umask 077

SECRET=${1:?usage: relay-secret.sh <secret-name>}
KV="${KV_NAME:-orfeweb-jfg2rn-kv}"

TOK=$(curl -s -H Metadata:true --max-time 10 \
  "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')
[ -n "$TOK" ] || { echo "IMDS returned no token" >&2; exit 1; }

# The error body is printed, the value never is. A vault error that reached stdout would
# be captured by the caller as though it were the secret - which is how a 68-character
# "Forbidden" JSON blob once got reported as a working credential.
curl -s --max-time 10 -H "Authorization: Bearer $TOK" \
  "https://$KV.vault.azure.net/secrets/$SECRET?api-version=7.4" \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);sys.stdout.write(d["value"]) if "value" in d else sys.exit("vault: "+json.dumps(d)[:200])'
