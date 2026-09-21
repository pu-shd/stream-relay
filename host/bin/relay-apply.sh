#!/bin/bash
# Apply staged relay config and converge the stack. Root-only, and the second of exactly
# two things the Actions runner may do as root.
#
# The runner stages generated files into /opt/stream-relay-staging (which it owns) and
# calls this. Nothing else about the host is writable by it, and the passphrase is fetched
# here from the VM's own managed identity rather than passing through the runner.
set -eu
umask 077
STAGE=/opt/stream-relay-staging
PROJECT=/home/orfe-web

for f in docker-compose.yml nginx.conf mediamtx.yml.tmpl; do
  [ -s "$STAGE/$f" ] || { echo "missing $STAGE/$f" >&2; exit 1; }
done

install -m 0644 "$STAGE/docker-compose.yml" "$PROJECT/docker-compose.yml"
install -m 0644 "$STAGE/nginx.conf"         "$PROJECT/nginx.conf"
install -m 0600 "$STAGE/mediamtx.yml.tmpl"  /etc/stream-relay/mediamtx.yml.tmpl

# Renders mediamtx.yml from the template plus the Key Vault passphrase.
/usr/local/bin/relay-render.sh

# Validate before restarting anything: a bad nginx.conf takes /meet/ down with the relay.
#
# --tmpfs for the telemetry log directory. `nginx -t` does not merely parse: it OPENS every
# access_log, so a config naming a directory this throwaway container does not have fails
# validation with "No such file or directory" and blocks the deploy, while the real nginx -
# which has the relay-logs volume mounted there - would have been perfectly happy.
#
# The image is read from the staged compose rather than written here as nginx:alpine. The
# compose pins by digest precisely because a tag is a mutable pointer; validating against
# whatever :alpine resolves to today, then running something else, tests the wrong binary.
NGINX_IMAGE=$(grep -oE 'image: (nginx:[^[:space:]]+)' "$STAGE/docker-compose.yml" \
  | head -1 | cut -d' ' -f2)
[ -n "$NGINX_IMAGE" ] || { echo "no nginx image in the staged compose" >&2; exit 1; }

docker run --rm -v "$PROJECT/nginx.conf:/etc/nginx/nginx.conf:ro" \
  -v /srv/hls:/hls:ro -v orfe-web_certbot-certs:/etc/letsencrypt:ro \
  --tmpfs /var/log/relay \
  "$NGINX_IMAGE" nginx -t

cd "$PROJECT"
if command -v docker-compose >/dev/null 2>&1; then DC="docker-compose"; else DC="docker compose"; fi
$DC up -d --remove-orphans

for _ in $(seq 1 24); do
  if [ "$(docker inspect stream-relay --format '{{.State.Health.Status}}' 2>/dev/null)" = healthy ]; then
    echo "RELAY_HEALTHY paths=$(docker exec stream-relay wget -qO- http://127.0.0.1:9997/v3/paths/list \
      | python3 -c 'import sys,json;print(json.load(sys.stdin)["itemCount"])')"
    exit 0
  fi
  sleep 5
done
echo "relay did not become healthy" >&2
docker logs stream-relay 2>&1 | tail -20 >&2
exit 1
