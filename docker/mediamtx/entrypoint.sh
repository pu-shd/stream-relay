#!/bin/sh
# Entrypoint for the stream-relay MediaMTX image.
#
# MediaMTX does NOT expand ${VAR} placeholders inside its YAML config - it only supports
# MTX_* environment overrides, and those cannot express a path named 'news-plus'. So the
# config repo generates mediamtx.yml.tmpl and this script performs the substitution at
# start-up, with the passphrase supplied by the VM's managed identity out of Key Vault.
#
# Feeding the template straight to MediaMTX would authenticate every publisher against
# the literal string '${SRT_PUBLISH_PASSPHRASE}', so this script fails closed instead.
set -eu

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

TEMPLATE="${RELAY_CONFIG_TEMPLATE:-/config/mediamtx.yml.tmpl}"
RENDERED="${RELAY_CONFIG_RENDERED:-/tmp/mediamtx.yml}"
PLACEHOLDER='${SRT_PUBLISH_PASSPHRASE}'

die() { printf "${RED}[entrypoint] ✗ %s${NC}\n" "$1" >&2; exit 1; }
ok()  { printf "${GREEN}[entrypoint] ✓ %s${NC}\n" "$1"; }

[ -f "$TEMPLATE" ] || die "config template not found at $TEMPLATE (mount the config repo's <dept>/ directory at /config)"

[ -n "${SRT_PUBLISH_PASSPHRASE:-}" ] || die "SRT_PUBLISH_PASSPHRASE is unset. Read it from Key Vault:
    az keyvault secret show --vault-name <kv> --name srt-publish-passphrase --query value -o tsv"

# SRT requires a 10-79 character passphrase; shorter ones are rejected by libsrt at
# handshake time, which surfaces as an unexplained publisher disconnect.
len=$(printf '%s' "$SRT_PUBLISH_PASSPHRASE" | wc -c | tr -d ' ')
[ "$len" -ge 10 ] || die "SRT_PUBLISH_PASSPHRASE is $len chars; SRT requires at least 10"
[ "$len" -le 79 ] || die "SRT_PUBLISH_PASSPHRASE is $len chars; SRT allows at most 79"

# Restrict the charset deliberately. The substitution below runs through sed, and '&',
# '\' and the delimiter would otherwise need escaping - a silent corruption risk on a
# credential. bootstrap.sh generates conforming passphrases, so this only ever fires on
# a hand-set value.
case "$SRT_PUBLISH_PASSPHRASE" in
  *[!A-Za-z0-9_-]*)
    die "SRT_PUBLISH_PASSPHRASE must contain only A-Z a-z 0-9 _ - (got a disallowed character).
    Regenerate with: openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 40" ;;
esac

ok "template $TEMPLATE"
sed "s|\${SRT_PUBLISH_PASSPHRASE}|${SRT_PUBLISH_PASSPHRASE}|g" "$TEMPLATE" > "$RENDERED"

# Fail closed: if any placeholder survived, MediaMTX would start with a literal
# placeholder as a credential. Comments are stripped from the check since the header
# documents the placeholder by name on purpose.
if grep -v '^[[:space:]]*#' "$RENDERED" | grep -q '\${'; then
  grep -n -v '^[[:space:]]*#' "$RENDERED" | grep '\${' >&2
  die "unexpanded placeholder(s) remain in $RENDERED - refusing to start"
fi
if grep -v '^[[:space:]]*#' "$RENDERED" | grep -q "$PLACEHOLDER"; then
  die "passphrase placeholder survived substitution - refusing to start"
fi
ok "rendered $RENDERED (passphrase substituted, no placeholders remain)"

# Never print the rendered config; it now contains a credential.
printf "${CYAN}[entrypoint] starting mediamtx${NC}\n"
exec /mediamtx "$RENDERED"
