#!/bin/bash
# Install or update the relay's host layer. Root-only, idempotent.
#
# Ordering is deliberate: the sudoers fragment is validated with `visudo -c` on a temporary
# copy BEFORE it is moved into place. A malformed file under /etc/sudoers.d breaks sudo for
# every user on the host, and this VM has no inbound administrative path - no SSH, no
# Bastion - so recovering means the Azure control plane and a lot of luck.
set -eu
umask 022

HOST_DIR=$(cd "$(dirname "$0")" && pwd)

[ "$(id -u)" = "0" ] || { echo "install.sh must run as root" >&2; exit 1; }

install -d -m 0755 /usr/local/bin
install -d -m 0700 /etc/stream-relay
install -d -m 0755 /opt/stream-relay-staging

# --- the two scripts the runner may call ------------------------------------------------
for s in relay-render.sh relay-apply.sh; do
  install -m 0755 -o root -g root "$HOST_DIR/bin/$s" "/usr/local/bin/$s"
  echo "  installed /usr/local/bin/$s"
done

# --- sudoers, validated first -----------------------------------------------------------
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
cp "$HOST_DIR/etc/sudoers.d-ghrunner-relay" "$tmp"
chmod 0440 "$tmp"
if ! visudo -c -f "$tmp" >/dev/null; then
  echo "REFUSING: the sudoers fragment does not parse. Nothing was changed." >&2
  visudo -c -f "$tmp" >&2 || true
  exit 1
fi
install -m 0440 -o root -g root "$tmp" /etc/sudoers.d/ghrunner-relay
echo "  installed /etc/sudoers.d/ghrunner-relay (visudo -c passed)"

# --- the IMDS block -----------------------------------------------------------------------
# DOCKER-USER only exists once dockerd has started, so the rule is applied by a unit ordered
# after docker.service rather than written into a static firewall config.
unit=block-imds-from-containers.service
install -m 0644 -o root -g root "$HOST_DIR/etc/$unit" "/etc/systemd/system/$unit"
systemctl daemon-reload
systemctl enable --now "$unit"
echo "  installed and enabled $unit"

# Prove the rule is actually in the chain rather than trusting that the unit reported
# success: it is a oneshot whose ExitStatus says the command ran, not that the rule holds.
if iptables -C DOCKER-USER -d 169.254.169.254/32 -j DROP 2>/dev/null; then
  echo "  IMDS is blocked from container networks"
else
  echo "WARNING: the IMDS DROP rule is not in DOCKER-USER. A container can mint the VM's" >&2
  echo "         Azure token until this is fixed." >&2
  exit 1
fi

echo
"$HOST_DIR/verify-installed.sh"
