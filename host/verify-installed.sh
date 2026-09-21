#!/bin/bash
# Compare the installed host layer against what this repo says it should be.
#
# Read-only: reports drift, changes nothing. The converge job runs it so a hand-edit on the
# VM fails the next deploy rather than living on as the real configuration while the repo
# quietly describes something else.
#
# Three of the four artifacts are world-readable and can be checked by anyone; the sudoers
# fragment is 0440 and needs root. That is deliberate and is not a defect to route around:
# the file constrains the Actions runner, so the runner has no business reading it, and
# `sudo`-ing a script out of the runner's own workspace to get at it would hand that runner
# arbitrary root - a far larger hole than the drift it was meant to detect.
#
# So a root-only entry is SKIPPED, named, and counted separately when the caller is not
# root. Skipped is not passed: the summary says what was not checked and from where it can
# be. Run as root over the control plane for all four.
set -eu

HOST_DIR=$(cd "$(dirname "$0")" && pwd)

# Prefix for the installed paths. Empty in production, so they are the real absolute
# paths; the offline suite points it at a temporary tree so the drift logic can be
# exercised without a VM and without root. A monitor whose only test is "it ran once in
# production" has no test.
DESTROOT=${DESTROOT:-}

# committed path : installed path : root-only
MANIFEST="
bin/relay-render.sh:/usr/local/bin/relay-render.sh:no
bin/relay-apply.sh:/usr/local/bin/relay-apply.sh:no
etc/sudoers.d-ghrunner-relay:/etc/sudoers.d/ghrunner-relay:yes
etc/block-imds-from-containers.service:/etc/systemd/system/block-imds-from-containers.service:no
"

AM_ROOT=0
[ "$(id -u)" = "0" ] && AM_ROOT=1

if command -v sha256sum >/dev/null 2>&1; then
  sum() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }
else
  # macOS has no sha256sum. The relay host is Linux; this is for the offline suite.
  sum() { shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1; }
fi

drift=0
unreadable=0
checked=0
skipped=0
skipped_names=""

for entry in $MANIFEST; do
  src="$HOST_DIR/${entry%%:*}"
  rest="${entry#*:}"
  dst="$DESTROOT${rest%:*}"
  rootonly="${rest##*:}"

  if [ "$rootonly" = "yes" ] && [ "$AM_ROOT" = "0" ]; then
    echo "  SKIPPED-NEEDS-ROOT $dst"
    skipped=$(( skipped + 1 ))
    skipped_names="$skipped_names $dst"
    continue
  fi

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

# Drift is reported before UNVERIFIED: a file that demonstrably differs is a harder fact
# than one that could not be read, and burying it under "re-run as root" would lose it.
if [ "$drift" -gt 0 ]; then
  echo "HOST_LAYER_DRIFT $drift file(s) differ from the repo; run host/install.sh as root" >&2
  exit 1
fi
if [ "$unreadable" -gt 0 ]; then
  echo "HOST_LAYER_UNVERIFIED $unreadable file(s) could not be read; re-run as root" >&2
  exit 2
fi
if [ "$skipped" -gt 0 ]; then
  echo "HOST_LAYER_OK $checked file(s) match the repo;$skipped_names needs root (expected off-root)"
  exit 0
fi
echo "HOST_LAYER_OK $checked file(s) match the repo"
