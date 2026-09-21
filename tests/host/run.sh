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
  cp "$HOST_DIR/bin/relay-render.sh" "$root/usr/local/bin/relay-render.sh"
  cp "$HOST_DIR/bin/relay-apply.sh"  "$root/usr/local/bin/relay-apply.sh"
  cp "$HOST_DIR/etc/sudoers.d-ghrunner-relay" "$root/etc/sudoers.d/ghrunner-relay"
  cp "$HOST_DIR/etc/block-imds-from-containers.service" \
     "$root/etc/systemd/system/block-imds-from-containers.service"
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
    *HOST_LAYER_OK*4*) t_ok "a faithful install reports OK and says how many it checked" ;;
    *) t_fail "expected HOST_LAYER_OK with a count, got: $(echo "$out" | tail -1)" ;;
  esac
else
  t_fail "a faithful install was reported as drift: $out"
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
rm "$ABSENT/etc/sudoers.d/ghrunner-relay"
if out=$(run_verify "$ABSENT"); then
  t_fail "a missing sudoers fragment passed verification"
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
chmod 000 "$UNREADABLE/etc/sudoers.d/ghrunner-relay"
if [ "$(id -u)" = "0" ]; then
  t_ok "skipped: running as root, nothing is unreadable (checked on the VM instead)"
else
  set +e
  out=$(run_verify "$UNREADABLE")
  code=$?
  set -e
  chmod 644 "$UNREADABLE/etc/sudoers.d/ghrunner-relay"
  if [ "$code" = "2" ] && [ "${out#*UNVERIFIED}" != "$out" ]; then
    t_ok "an unreadable file exits 2 as UNVERIFIED, distinct from pass and from drift"
  else
    t_fail "expected exit 2 with UNVERIFIED, got exit $code: $out"
  fi
fi

# --- 5. the manifest covers every committed artifact ------------------------------------
# A file added to host/ but not to MANIFEST is never checked, and the suite above would
# still be green - so the set itself is asserted.
committed=$(cd "$HOST_DIR" && find bin etc -type f | sort)
listed=$(grep -oE '^(bin|etc)/[^:]+' "$HOST_DIR/verify-installed.sh" | sort)
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
