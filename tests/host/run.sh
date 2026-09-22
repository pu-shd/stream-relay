#!/bin/bash
# Offline suite for the host layer. No cloud, no root, no VM.
#
# verify-installed.sh is the only thing standing between "the repo describes the host" and
# "the repo describes what the host used to be", so it is RUN against a fake install tree
# rather than grepped. Its three outcomes - match, drift, cannot-check - are each exercised,
# because the failure that matters most is the third one being reported as either of the
# other two.
set -eu

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
HOST_DIR="$REPO_ROOT/host"

pass=0
fail=0
t_ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$(( pass + 1 )); }
t_fail() { printf '  \033[31m✗\033[0m %s\n' "$1"; fail=$(( fail + 1 )); }

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

# A fake install tree mirroring the manifest's absolute paths under a prefix.
plant() {
  root=$1
  mkdir -p "$root/usr/local/bin" "$root/etc/sudoers.d" "$root/etc/systemd/system"
  # Driven off the manifest rather than a hand-written list, so adding a file to host/bin
  # cannot leave the fixture silently behind the thing it is meant to exercise.
  grep -oE '^(bin|etc)/[^:]+:[^:]+' "$HOST_DIR/verify-installed.sh" | while IFS=: read -r src dst; do
    mkdir -p "$root$(dirname "$dst")"
    cp "$HOST_DIR/$src" "$root$dst"
  done
}

run_verify() {
  DESTROOT="$1" "$HOST_DIR/verify-installed.sh" 2>&1
}

echo "host layer"

# --- 1. a faithful install reports OK ---------------------------------------------------
GOOD="$SANDBOX/good"
plant "$GOOD"
if out=$(run_verify "$GOOD"); then
  case "$out" in
    *HOST_LAYER_OK*) t_ok "a faithful install reports OK and says how many it checked" ;;
    *) t_fail "expected HOST_LAYER_OK, got: $(echo "$out" | tail -1)" ;;
  esac
else
  t_fail "a faithful install was reported as drift: $out"
fi

# --- 1b. off root, the sudoers file is SKIPPED and SAID SO, not silently passed ---------
# It is 0440 and it constrains the runner, so the runner cannot read it - by design, not by
# accident. The risk is the summary reading as a clean bill of health for four files when
# only three were looked at.
if [ "$(id -u)" = "0" ]; then
  t_ok "skipped: running as root, so nothing is root-only (the VM covers this)"
else
  out=$(run_verify "$GOOD")
  # Derived from the manifest, not hardcoded: a literal count here goes stale the moment
  # a file is added, and the failure reads as a regression rather than a stale test.
  total=$(grep -cE '^(bin|etc)/[^:]+:' "$HOST_DIR/verify-installed.sh")
  rootonly=$(grep -cE '^(bin|etc)/[^:]+:[^:]+:yes$' "$HOST_DIR/verify-installed.sh")
  want=$(( total - rootonly ))
  if [ "${out#*SKIPPED-NEEDS-ROOT}" != "$out" ] \
     && [ "${out#*ghrunner-relay}" != "$out" ] \
     && [ "${out#*HOST_LAYER_OK $want}" != "$out" ]; then
    t_ok "off root: $want checked, the root-only file named, not counted as passed"
  else
    t_fail "expected 'HOST_LAYER_OK $want' and a named SKIPPED-NEEDS-ROOT, got: $out"
  fi
fi

# --- 2. a hand-edit on the host is drift, and is NAMED ----------------------------------
# The whole point of versioning these files. An edit that survives silently is the status
# quo this directory exists to end.
EDITED="$SANDBOX/edited"
plant "$EDITED"
echo '# someone fixed it live at 2am' >> "$EDITED/usr/local/bin/relay-apply.sh"
if out=$(run_verify "$EDITED"); then
  t_fail "a hand-edited relay-apply.sh passed verification"
else
  code=$?
  if [ "$code" = "1" ] && [ "${out#*DRIFT}" != "$out" ] \
     && [ "${out#*relay-apply.sh}" != "$out" ]; then
    t_ok "a hand-edited script is drift (exit 1) and the report names the file"
  else
    t_fail "expected exit 1 naming relay-apply.sh, got exit $code: $out"
  fi
fi

# --- 3. a missing install is reported as missing, not as a match ------------------------
ABSENT="$SANDBOX/absent"
plant "$ABSENT"
rm "$ABSENT/etc/systemd/system/block-imds-from-containers.service"
if out=$(run_verify "$ABSENT"); then
  t_fail "a missing systemd unit passed verification"
else
  if [ "${out#*NOT-INSTALLED}" != "$out" ]; then
    t_ok "a file that was never installed is reported as NOT-INSTALLED"
  else
    t_fail "expected NOT-INSTALLED, got: $out"
  fi
fi

# --- 4. cannot-check is its own outcome, not a pass and not a failure -------------------
# Exit 2, distinct from 0 and 1. Reporting an unreadable file as either is how a monitor
# starts lying: as a pass it hides drift, as a failure it cries wolf on every non-root run.
UNREADABLE="$SANDBOX/unreadable"
plant "$UNREADABLE"
chmod 000 "$UNREADABLE/usr/local/bin/relay-render.sh"
if [ "$(id -u)" = "0" ]; then
  t_ok "skipped: running as root, nothing is unreadable (checked on the VM instead)"
else
  set +e
  out=$(run_verify "$UNREADABLE")
  code=$?
  set -e
  chmod 644 "$UNREADABLE/usr/local/bin/relay-render.sh"
  if [ "$code" = "2" ] && [ "${out#*UNVERIFIED}" != "$out" ]; then
    t_ok "an unreadable file exits 2 as UNVERIFIED, distinct from pass and from drift"
  else
    t_fail "expected exit 2 with UNVERIFIED, got exit $code: $out"
  fi
fi

# --- 4b. drift outranks cannot-check ----------------------------------------------------
# Both conditions at once must report the one that is a hard fact. Reporting UNVERIFIED
# here would turn a file that demonstrably differs into "re-run as root" and lose it.
BOTH="$SANDBOX/both"
plant "$BOTH"
echo '# edited live' >> "$BOTH/usr/local/bin/relay-apply.sh"
chmod 000 "$BOTH/usr/local/bin/relay-render.sh"
if [ "$(id -u)" = "0" ]; then
  t_ok "skipped: running as root, nothing is unreadable"
else
  set +e
  out=$(run_verify "$BOTH")
  code=$?
  set -e
  chmod 644 "$BOTH/usr/local/bin/relay-render.sh"
  if [ "$code" = "1" ] && [ "${out#*HOST_LAYER_DRIFT}" != "$out" ]; then
    t_ok "drift outranks cannot-check: exit 1, not 2"
  else
    t_fail "expected exit 1 HOST_LAYER_DRIFT, got exit $code: $out"
  fi
fi

# --- 4c. relay-apply.sh validates against the image that will actually run --------------
# `nginx -t` OPENS every access_log, so the validation container needs the telemetry log
# directory or it fails on a config the real nginx accepts - which is how the first deploy
# after adding that log would have broken. And validating against whatever nginx:alpine
# resolves to today, then running a digest-pinned image, tests the wrong binary.
apply=$(cat "$HOST_DIR/bin/relay-apply.sh")
if [ "${apply#*--tmpfs /var/log/relay}" != "$apply" ]; then
  t_ok "relay-apply.sh gives nginx -t somewhere to open the telemetry log"
else
  t_fail "relay-apply.sh validates without /var/log/relay; nginx -t will fail on it"
fi
directives=$(grep -v '^[[:space:]]*#' "$HOST_DIR/bin/relay-apply.sh")
if [ "${directives#*NGINX_IMAGE}" != "$directives" ] \
   && [ "${directives%%nginx:alpine nginx -t*}" = "$directives" ]; then
  t_ok "relay-apply.sh validates against the compose's pinned image, not a mutable tag"
else
  t_fail "relay-apply.sh validates against an unpinned nginx:alpine"
fi

# --- 4d. a config-only change must actually reach MediaMTX --------------------------------
# mediamtx.yml is a bind-mounted file, and `compose up -d` recreates a container only when
# its SERVICE DEFINITION changes. Adding a path to the template therefore converged
# "successfully" while the relay kept serving the config it booted with - green deploy,
# green healthcheck, and a publisher rejected for a path that did not exist. The container
# was 26 hours older than the config it was supposedly running.
if grep -q 'before=\$(sha256sum' "$HOST_DIR/bin/relay-apply.sh"; then
  t_ok "relay-apply.sh hashes the rendered config either side of rendering"
else
  t_fail "relay-apply.sh cannot tell whether the config changed"
fi
if [ "${apply#*docker restart stream-relay}" != "$apply" ]; then
  t_ok "relay-apply.sh restarts the relay when the config changed"
else
  t_fail "a config-only change would never reach MediaMTX"
fi
# Conditional, not unconditional: every no-op converge would otherwise drop every
# publisher, and those run far more often than real changes.
if grep -q 'if \[ "\$before" != "\$after" \]' "$HOST_DIR/bin/relay-apply.sh"; then
  t_ok "the restart is conditional on the config actually changing"
else
  t_fail "the relay restarts on every converge, dropping publishers needlessly"
fi

# --- 5. the manifest covers every committed artifact ------------------------------------
# A file added to host/ but not to MANIFEST is never checked, and the suite above would
# still be green - so the set itself is asserted.
committed=$(cd "$HOST_DIR" && find bin etc -type f | sort)
listed=$(grep -oE '^(bin|etc)/[^:]+:' "$HOST_DIR/verify-installed.sh" | tr -d ':' | sort)
if [ "$committed" = "$listed" ]; then
  t_ok "every file under host/bin and host/etc is in the manifest"
else
  t_fail "manifest and host/ disagree:
    only committed: $(comm -23 <(echo "$committed") <(echo "$listed") | tr '\n' ' ')
    only listed:    $(comm -13 <(echo "$committed") <(echo "$listed") | tr '\n' ' ')"
fi

# --- 6. install.sh validates sudoers before installing it -------------------------------
# Ordering, not presence: a visudo check after the install has already happened protects
# nothing, and the blast radius is sudo for every user on a host with no inbound access.
body=$(cat "$HOST_DIR/install.sh")
before=${body%%install -m 0440*}
if [ "${before#*visudo -c}" != "$before" ]; then
  t_ok "install.sh runs visudo -c before the sudoers file is moved into place"
else
  t_fail "install.sh installs the sudoers fragment without validating it first"
fi

# --- 7. install.sh proves the IMDS rule, rather than trusting systemd -------------------
if [ "${body#*iptables -C DOCKER-USER}" != "$body" ]; then
  t_ok "install.sh confirms the IMDS DROP rule is actually in the chain"
else
  t_fail "install.sh trusts the oneshot unit's exit status for the IMDS rule"
fi

# --- 8. the sudoers grant is still exactly two scripts, with no wildcard ----------------
# This is the privilege boundary. A wildcard or an extra path here is root on the host for
# anyone who can land a workflow on the runner.
sudoers=$(cat "$HOST_DIR/etc/sudoers.d-ghrunner-relay")
case "$sudoers" in
  *'*'*|*ALL\ ALL*|*'(ALL : ALL)'*)
    t_fail "the sudoers grant contains a wildcard: $sudoers" ;;
  *)
    n=$(printf '%s' "$sudoers" | tr ',' '\n' | grep -c '/usr/local/bin/')
    if [ "$n" = "2" ]; then
      t_ok "the runner may run exactly two root scripts, no wildcard"
    else
      t_fail "expected 2 permitted scripts, found $n: $sudoers"
    fi ;;
esac

echo
if [ "$fail" -eq 0 ]; then
  printf '\033[32m%d passed.\033[0m\n' "$pass"
  exit 0
fi
printf '\033[31m%d failed, %d passed.\033[0m\n' "$fail" "$pass"
exit 1
