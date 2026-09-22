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
CFG=/etc/stream-relay/mediamtx.yml
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
# --build so a changed watchdog.py is actually rebuilt. No other service declares
# `build:`, so this is a no-op for them.
$DC up -d --build --remove-orphans

# IS THE RUNNING RELAY OLDER THAN ITS CONFIG?
#
# A config-only change never reaches MediaMTX on its own: mediamtx.yml is a bind-mounted
# file, and `compose up -d` recreates a container only when its SERVICE DEFINITION
# changes. Adding a path rendered, staged and installed correctly while the relay kept
# serving what it booted with - green deploy, green healthcheck, and a publisher rejected
# for a path that did not exist.
#
# The obvious check is whether this run changed the file, and it is WRONG: the first
# attempt at this fix compared hashes either side of relay-render.sh, which sees nothing
# when a PREVIOUS run already updated the config and failed to restart. The drift
# outlives the run that caused it.
#
# So compare state, not events: if the config is newer than the process, the process
# cannot be running it. That is true whenever it is true, regardless of which run left it
# that way, and it is naturally a no-op once they agree.
started=$(docker inspect stream-relay --format '{{.State.StartedAt}}' 2>/dev/null || echo "")
if [ -n "$started" ] && [ -f "$CFG" ]; then
  started_epoch=$(date -d "$started" +%s 2>/dev/null || echo 0)
  cfg_epoch=$(stat -c %Y "$CFG" 2>/dev/null || echo 0)
  if [ "$cfg_epoch" -gt "$started_epoch" ]; then
    echo "mediamtx.yml is newer than the running relay; restarting to load it"
    docker restart stream-relay >/dev/null
  fi
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
