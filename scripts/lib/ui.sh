#!/usr/bin/env bash
# Shared terminal output. Matches page-stream's bootstrap-runner.sh conventions so the two
# projects look like one toolkit.
#
# TARGETS BASH 3.2. macOS still ships bash 3.2 as /bin/bash, and macOS is the primary
# development platform, so no bash 4+ constructs: no ${var^^}, no mapfile/readarray,
# no associative arrays. The mock-az suite runs these scripts under the system bash,
# so a regression here fails the tests rather than only breaking on someone's laptop.
# shellcheck disable=SC2034

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

# Honour NO_COLOR and non-TTY output, so logs captured by CI stay readable.
if [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then
  RED='' GREEN='' YELLOW='' BLUE='' CYAN='' DIM='' BOLD='' NC=''
fi

banner() {
  printf "${BLUE}${BOLD}======================================================================${NC}\n"
  printf "${CYAN}${BOLD}%s${NC}\n" "$(printf '%*s' $(( (70 + ${#1}) / 2 )) "$1")"
  printf "${BLUE}${BOLD}======================================================================${NC}\n"
}

step_header() { printf "\n${BOLD}[%s/%s] %s${NC}\n" "$1" "$2" "$3"; }
ok()      { printf "  ${GREEN}✓${NC} %s\n" "$1"; }
warn()    { printf "  ${YELLOW}⚠ %s${NC}\n" "$1"; }
fail()    { printf "  ${RED}✗ %s${NC}\n" "$1" >&2; }
info()    { printf "  ${CYAN}·${NC} %s\n" "$1"; }
detail()  { printf "    ${DIM}%s${NC}\n" "$1"; }
skipped() { printf "  ${DIM}– %s${NC}\n" "$1"; }

die() { fail "$1"; exit "${2:-1}"; }

# Confirm, unless --yes was passed. Default is NO: every caller here is destructive or
# spends money.
confirm() {
  local prompt="$1"
  if [ "${ASSUME_YES:-0}" = "1" ]; then
    info "$prompt — auto-confirmed (--yes)"
    return 0
  fi
  printf "${YELLOW}%s [y/N]: ${NC}" "$prompt"
  local reply
  read -r reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

# Poll until a command succeeds. Always states what it is waiting for, because these waits
# can be minutes long (provider registration, VM boot) and a silent spinner is
# indistinguishable from a hang.
wait_for() {
  local description="$1" timeout="$2"; shift 2
  local elapsed=0 interval=5
  printf "  ${CYAN}·${NC} waiting for %s (timeout %ss)" "$description" "$timeout"
  while ! "$@" >/dev/null 2>&1; do
    if [ "$elapsed" -ge "$timeout" ]; then
      printf "\n"
      fail "timed out after ${timeout}s waiting for $description"
      return 1
    fi
    printf "."
    sleep "$interval"
    elapsed=$(( elapsed + interval ))
  done
  printf "\n"
  ok "$description (after ${elapsed}s)"
}
