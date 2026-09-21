# Host layer

The privileged pieces that live on the relay VM rather than in a container.

These four artifacts ran in production for months without existing in any repository. They
were captured off `orfe-web-vm` and committed **verbatim** — the first commit here changed
nothing on the host. That matters because everything in this directory runs as root, and
code that runs as root and cannot be reviewed is the weakest part of the deployment.

| Committed | Installed as | Mode |
| :--- | :--- | :--- |
| `bin/relay-render.sh` | `/usr/local/bin/relay-render.sh` | `0755 root:root` |
| `bin/relay-apply.sh` | `/usr/local/bin/relay-apply.sh` | `0755 root:root` |
| `etc/sudoers.d-ghrunner-relay` | `/etc/sudoers.d/ghrunner-relay` | `0440 root:root` |
| `etc/block-imds-from-containers.service` | `/etc/systemd/system/block-imds-from-containers.service` | `0644 root:root` |

## Why these, and only these

`relay-render.sh` fetches the SRT passphrase from Key Vault over IMDS and substitutes it
into `mediamtx.yml`. `relay-apply.sh` stages generated config, validates nginx, and brings
the stack up. Together they are the **entire** privileged surface: the sudoers rule grants
the Actions runner those two paths with no arguments and nothing else.

They cannot be containers. `block-imds-from-containers.service` drops traffic to
`169.254.169.254` from container networks, so a container cannot mint the VM's Azure token
— which is exactly why the two scripts that need one run on the host.

## Drift

`verify-installed.sh` compares the installed copies against these by SHA-256 and exits
non-zero on a mismatch. The converge job runs it, so a hand-edit on the VM fails the next
deploy instead of surviving indefinitely.

```sh
host/install.sh          # install or update, then reload systemd
host/verify-installed.sh # report drift, change nothing
```

`install.sh` validates the sudoers file with `visudo -c` **before** moving it into place.
A malformed file in `/etc/sudoers.d` breaks `sudo` for every user on the host, and on a VM
with no inbound administrative path that is unrecoverable without the Azure control plane.

## Not versioned here

`/etc/cron.d/orfe-web` drives the VDO.Ninja updater. It came with the adopted VM, is
unrelated to the relay, and is left alone.
