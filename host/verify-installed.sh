#!/bin/bash
# Compare the installed host layer against what this repo says it should be.
#
# Read-only: reports drift, changes nothing. The converge job runs it so a hand-edit on the
# VM fails the next deploy rather than living on as the real configuration while the repo
# quietly describes something else.
#
# Reading the files needs root (the sudoers fragment is 0440), so this is invoked through
# sudo by install.sh, or run directly as root. Without root it reports UNVERIFIED and exits
# 2 - "could not check" is neither pass nor fail, and calling it either is how a monitor
# starts lying.
set -eu

HOST_DIR=$(cd "$(dirname "$0")" && pwd)

# Prefix for the installed paths. Empty in production, so they are the real absolute
# paths; the offline suite points it at a temporary tree so the drift logic can be
# exercised without a VM and without root. A monitor whose only test is "it ran once in
# production" has no test.
DESTROOT=${DESTROOT:-}

# committed path : installed path
MANIFEST="
bin/relay-render.sh:/usr/local/bin/relay-render.sh
bin/relay-apply.sh:/usr/local/bin/relay-apply.sh
etc/sudoers.d-ghrunner-relay:/etc/sudoers.d/ghrunner-relay
etc/block-imds-from-containers.service:/etc/systemd/system/block-imds-from-containers.service
"

if command -v sha256sum >/dev/null 2>&1; then
  sum() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }
else
  # macOS has no sha256sum. The relay host is Linux; this is for the offline suite.
  sum() { shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1; }
fi

drift=0
unreadable=0
checked=0

for entry in $MANIFEST; do
  src="$HOST_DIR/${entry%%:*}"
  dst="$DESTROOT${entry##*:}"

  if [ ! -f "$src" ]; then
    echo "  MISSING-IN-REPO  $src"
    drift=$(( drift + 1 ))
    continue
  fi
  if [ ! -e "$dst" ]; then
    echo "  NOT-INSTALLED    $dst"
    drift=$(( drift + 1 ))
    continue
  fi

  want=$(sum "$src")
  got=$(sum "$dst")
  if [ -z "$got" ]; then
    # Unreadable is not the same as different. Say so rather than guessing either way.
    echo "  UNREADABLE       $dst (need root)"
    unreadable=$(( unreadable + 1 ))
    continue
  fi

  checked=$(( checked + 1 ))
  if [ "$want" = "$got" ]; then
    echo "  OK               $dst"
  else
    echo "  DRIFT            $dst"
    echo "                   repo     ${want:0:16}"
    echo "                   host     ${got:0:16}"
    drift=$(( drift + 1 ))
  fi
done

if [ "$unreadable" -gt 0 ]; then
  echo "HOST_LAYER_UNVERIFIED $unreadable of $(( checked + unreadable + drift )) unreadable; re-run as root" >&2
  exit 2
fi
if [ "$drift" -gt 0 ]; then
  echo "HOST_LAYER_DRIFT $drift file(s) differ from the repo; run host/install.sh" >&2
  exit 1
fi
echo "HOST_LAYER_OK $checked file(s) match the repo"
