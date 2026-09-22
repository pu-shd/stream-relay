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

# The watchdog's build context, when the deploy staged one. Optional so an older config
# repo still converges against this script rather than failing on a directory it has
# never heard of.
if [ -d "$STAGE/watchdog" ]; then
  install -d -m 0755 "$PROJECT/watchdog"
  install -m 0644 "$STAGE/watchdog/Dockerfile"  "$PROJECT/watchdog/Dockerfile"
  install -m 0644 "$STAGE/watchdog/watchdog.py" "$PROJECT/watchdog/watchdog.py"
fi

# The watchdog's two writable directories, owned by the uid it runs as.
#
# nginx runs as root and creates the access log root:root, which an unprivileged watchdog
# cannot truncate - and truncating is the only thing bounding a file that Docker's log
# rotation does not touch. Pre-creating the file here, owned by the watchdog, means nginx
# opens the existing inode O_APPEND (root can write a file it does not own) and the
# watchdog can still drain it.
#
# WATCHDOG_UID must match the Dockerfile. A cross-repo test pins the two together, after
# a mismatch produced a watchdog that started, reported permission errors every pass, and
# wrote no snapshot at all.
WATCHDOG_UID=10001
install -d -m 0755 -o "$WATCHDOG_UID" -g "$WATCHDOG_UID" /srv/relay-status
install -d -m 0755 -o "$WATCHDOG_UID" -g "$WATCHDOG_UID" /srv/relay-logs
[ -e /srv/relay-logs/access.log ] || install -m 0644 -o "$WATCHDOG_UID" -g "$WATCHDOG_UID" \
  /dev/null /srv/relay-logs/access.log
chown "$WATCHDOG_UID:$WATCHDOG_UID" /srv/relay-logs/access.log

# The Healthchecks.io ping URL, fetched the same way the SRT passphrase is: from the VM's
# own managed identity over IMDS, which containers cannot reach. The runner never sees it,
# and it never reaches the generated compose file.
#
# A MISSING PING URL MUST NOT BREAK DELIVERY. The secret is optional in Key Vault and the
# compose entry is `required: false`, so the worst case is a watchdog that runs and reports
# it has nowhere to ping - not nginx and MediaMTX refusing to start over telemetry.
: > /etc/stream-relay/watchdog.env
chmod 0600 /etc/stream-relay/watchdog.env
if ping_url=$(/usr/local/bin/relay-secret.sh "${WATCHDOG_PING_SECRET:-watchdog-ping-url}" 2>/dev/null) \
   && [ -n "$ping_url" ]; then
  printf 'HEALTHCHECKS_URL=%s\n' "$ping_url" > /etc/stream-relay/watchdog.env
  chmod 0600 /etc/stream-relay/watchdog.env
  echo "watchdog ping URL loaded from Key Vault"
else
  echo "no watchdog ping URL in Key Vault; the watchdog will report locally only" >&2
fi

# Renders mediamtx.yml from the template plus the Key Vault passphrase.
#
# The hash is taken either side, because a CONFIG-ONLY change never reaches MediaMTX on
# its own: mediamtx.yml is a bind-mounted file, and `compose up -d` recreates a container
# only when its SERVICE DEFINITION changes. Adding a path to the template therefore
# converged "successfully" while the relay kept serving the config it booted with -
# green deploy, green healthcheck, and a publisher rejected because its path did not
# exist. Found with a container 26 hours older than the config it was supposedly running.
CFG=/etc/stream-relay/mediamtx.yml
before=$(sha256sum "$CFG" 2>/dev/null | cut -d' ' -f1 || true)
/usr/local/bin/relay-render.sh
after=$(sha256sum "$CFG" 2>/dev/null | cut -d' ' -f1 || true)

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
# --build so a changed watchdog.py is actually rebuilt. No other service declares
# `build:`, so this is a no-op for them.
$DC up -d --build --remove-orphans

# Restart only when the config actually changed. Unconditional would drop every
# publisher on every deploy, including the no-op converges that run far more often.
if [ "$before" != "$after" ]; then
  echo "mediamtx.yml changed; restarting the relay to load it"
  docker restart stream-relay >/dev/null
fi

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
