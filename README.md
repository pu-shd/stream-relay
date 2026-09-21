# stream-relay

SRT ingest, HLS delivery. An encoder publishes SRT; viewers play HLS over HTTPS. It exists
so a department can run more concurrent streams than its upstream video platform allows.

Department-agnostic: this repo holds no resource names, addresses or channel definitions.
A deployment lives in its own config repo, which supplies all of those.

## Architecture

```
  encoder                       Azure VM
┌────────────┐                  ┌─────────────────────────────────────────┐
│ publisher  │ ─SRT/UDP:8890──► │ MediaMTX        remux, no transcode     │
│ (1..n)     │   encrypted      │   └─ writes HLS segments to disk        │
└────────────┘                  │ nginx :443      serves those files      │
                                │ nginx :80       ACME challenge only     │
                                │ certbot         renews on a loop        │
                                │ watchdog        reports, never restarts │
                                └────────────┬────────────────────────────┘
                                             │ HTTPS
                                          viewers
```

No CDN, no object store. For an audience close to the origin there is nothing for a CDN to
optimise, so nginx serves MediaMTX's `hlsDirectory` directly and the NSG is the access
control. At CDN-scale viewership that trade stops making sense.

MediaMTX's own HLS port is bound but never published: it gates variant playlists per viewer
and sends `Cache-Control: private, no-cache`. Files on disk have neither behaviour.

**The template adopts a VM rather than creating one.** Host, network and vault are
referenced as `existing`, so the relay can join a machine that already does other work.
Declaring an existing VM instead invites Azure to replace it, and replacement destroys its
disks. The resource group may be shared, which is why nothing here deletes by group.

## Repository split

| | |
| :--- | :--- |
| **`pu-shd/stream-relay`** (this repo, public) | The engine: Bicep, scripts, the host layer, the watchdog image, test suites. |
| **`pu-shd/stream-relay-config`** (private) | The deployment. `<dept>/relay.yml` is the only file anyone edits. |

`relay.yml` renders `mediamtx.yml.tmpl`, `docker-compose.yml`, `nginx.conf`, `deploy.env`,
`ingest-urls.env` and `infra.bicepparam`. A test asserts the generated files match the
source, so drift fails CI instead of surfacing mid-deploy.

## Quick start — local, no cloud, no spend

```bash
export SRT_PUBLISH_PASSPHRASE=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 40)
docker-compose -f docker-compose.local.yml --profile testsrc up -d
```

## Deploy

GitOps from the config repo: **Deploy (GitOps)**, `workflow_dispatch` only. `plan` runs
read-only and prints the what-if diff *before* the reviewer gate, so the approval is
informed. Azure jobs use OIDC; VM-side convergence runs on a self-hosted runner on the VM.

```bash
scripts/deploy.sh --dry-run      # what-if only
scripts/deploy.sh                # converge
scripts/deploy.sh --from infra   # resume after a failure
```

Seven steps, resumable and idempotent: `preflight`, `register-providers`,
`resource-group` (confirms, never creates — the group is shared), `passphrase`, `infra`
(one Bicep deployment: NSG rules and the budget), `configure`, `verify`.

`--with-role-assignments` is the one-time human bootstrap and needs Owner or User Access
Administrator. Every other run, CI included, never touches RBAC.

| Script | |
| :--- | :--- |
| `bootstrap.sh` | interactive first run, including role assignments CI may not create |
| `deploy.sh` | non-interactive, idempotent, CI-callable |
| `verify.sh` | one-shot gate: did this deployment come up correctly |
| `update.sh` | roll new config without touching infrastructure |
| `restrict.sh` / `allow-all.sh` | kill switch and break glass for the viewer allowlist |
| `teardown.sh` | remove the relay's own resources |

## Host layer

`host/` holds the privileged artifacts that run as root on the VM: `relay-secret.sh` (one
Key Vault fetch over IMDS), `relay-render.sh`, `relay-apply.sh`, the sudoers fragment, and
the systemd unit that blocks IMDS from container networks.

They ran in production for months existing in no repository. They are committed verbatim,
and `host/verify-installed.sh` compares the installed copies by SHA-256 — the converge job
runs it before anything privileged, so a hand-edit on the VM fails the next deploy rather
than surviving indefinitely. It reports three outcomes, not two: match, drift, and
cannot-check.

`host/install.sh` is deliberately **not** in the sudoers grant. Updating the host layer is
an operator action over the control plane:

```bash
az vm run-command invoke -g <rg> -n <vm> --command-id RunShellScript \
  --scripts 'cd /opt/stream-relay-src && sudo host/install.sh'
```

The runner still has exactly two paths to root; `relay-secret.sh` is a third script called
*by* those two rather than a third grant.

## Monitoring

Two halves, answering different questions.

**`docker/watchdog/`** runs on the relay every `interval_seconds`. It reads MediaMTX's
Prometheus metrics (never the control API — `metrics` is read-only, while `api` would let
its holder rewrite the relay's config) and the nginx access log, and pings a
Healthchecks.io dead-man's switch. If the VM is off the pings stop, and silence raises the
alarm.

It reports and never restarts anything. Three severities, kept apart:

| | |
| :--- | :--- |
| **problem** | an expected publisher absent or **not advancing**; nginx not serving; certificate near expiry |
| **warn** | SRT loss over threshold, certificate three weeks out — rides the *success* ping |
| **fault** | the monitor could not see. Not healthy, not broken; its own thing |

Rising byte counters, not non-zero ones: a wedged publisher leaves `ready: true` and a
frozen counter, which one reading cannot distinguish from health.

The certificate is read off the **TLS handshake**, not the file — a renewal nginx has not
reloaded leaves the old certificate on the wire while a fresh one sits on disk.

**The `Watchdog` workflow** in the config repo renders the snapshot into a step summary on
a schedule. It cannot report that the VM is off — it would queue against an offline runner
— which is why the dead-man's switch exists alongside it.

Viewer counts come from the nginx log and nowhere else: nginx serves the segments, so
MediaMTX's `readers` is permanently 0. Client addresses are retained only for device
classes declaring `retain_address`; everyone else is counted and discarded.

## Access control

The NSG is the boundary. No WAF, no CDN.

| Port | Source |
| :--- | :--- |
| `8890/udp` | the publisher's network — SRT wire encryption is the publish credential |
| `443/tcp` | the viewer networks the config allows |
| `80/tcp` | the internet, serving `/.well-known/acme-challenge` and nothing else |
| `22` | **no rule** |

Port 80 is open because Let's Encrypt validates from undisclosed, rotating addresses.
nginx 404s every other path there, so what is exposed is a directory of ACME tokens.

There is no inbound administrative path; administration is `az vm run-command`, RBAC-gated
and audited.

**Allowlisting a VPN needs its egress ranges, not its gateway addresses.** Cloud VPN
services commonly source-NAT clients from a pool not adjacent to the gateway they connected
to, so a list built from resolved gateways admits the gateways and blocks every client
behind them. Test from a real connection before trusting one.

## Identities

| | |
| :--- | :--- |
| **CI**, federated via OIDC | Network Contributor + Cost Management Contributor on the group, Key Vault Secrets Officer on the vault. No stored credential. |
| **VM**, SystemAssigned | reads one Key Vault secret. Nothing else. |

Not Contributor: the group is shared, and Contributor would permit deleting the machine the
relay runs on. CI cannot create role assignments — `deployRoleAssignments` defaults to
`false`, and a principal that can grant roles can grant itself any role in scope.

OIDC subjects carry GitHub's immutable org and repo IDs
(`repo:org@123/repo@456:ref:refs/heads/main`), so a renamed or transferred repository does
not inherit the trust.

## Accepted risks

**A self-hosted runner is root on its host.** Its user is in the `docker` group, which is
root-equivalent, so the narrow sudoers rule bounds nothing. Accepted rather than fixed — it
is a property of self-hosted runners generally. What bounds it instead: only
`workflow_dispatch` workflows reach the runner, all gated on a `production` environment
with a required reviewer; no `pull_request` or `push` trigger targets it; actions are
pinned to commit SHAs and images to digests.

If the host later runs something that must not share a blast radius with CI, move the
runner to a dedicated machine rather than de-privileging it in place.

**IMDS is blocked for container networks.** Otherwise any container could mint a token for
the VM's identity and read the passphrase, defeating the design where the runner never sees
it. A `DOCKER-USER` rule drops traffic to `169.254.169.254` from container networks while
leaving the host's own path working — which is how the config is rendered. Reapplied at
boot by a systemd unit, because `DOCKER-USER` exists only once dockerd has started.

**One passphrase, server-wide.** MediaMTX supports a distinct passphrase per path, but this
renders the same value into all of them, so a rotation is an N-channel outage and a leak
costs the estate rather than one channel. Worth splitting once a publisher appears that you
do not control.

## TLS

certbot renews on a loop and nginx reloads on another, both as containers. A one-shot
`certbot certonly` issues a certificate that expires ninety days later with nobody
watching — which is exactly what the adopted deployment had done.

The certificate must cover a real hostname. `*.cloudapp.azure.com` is absent from the
Public Suffix List, so Let's Encrypt counts it against `azure.com` and can never issue for
the derived name. Enabling TLS without a `domain` is a config error.

## Cost

Egress dominates and scales with **viewers**, not channels:

```
monthly egress GB ≈ viewers × bitrate_Mbps × 3600 × 24 × 30 / 8 / 1000
```

Bitrate is the highest-leverage lever, and the relay pays for exactly what a producer sends
— tier 0 is passthrough, no re-encode. VM size is not a lever: remuxing is an I/O job, and
a two-vCPU host carries eight simultaneous 1080p channels at ~13% of one core.

`tools/render-relay.py <dept> --size` in the config repo projects from the real channel
count, bitrate and expected viewers. A budget with **forecast** alerts is provisioned by
the deployment; forecast matters, because once actual spend crosses a ceiling the money is
already gone.

## Testing

```bash
tests/mock-az/run.sh                      # 37 assertions, offline, no cloud
tests/host/run.sh                         # the host layer's drift logic
python3 tests/watchdog/test_watchdog.py   # 27 tests, stdlib, no network
tests/integration/test-live-relay.sh      # against a real deployment
```

The offline suites prove the step machine is idempotent, resumable and state-free; that
preflight fails closed; that the passphrase never reaches an `az` argv; that teardown
deletes nothing it does not own and refuses while channels are live; and that the watchdog
tells wedged from healthy from cannot-see.

## Teardown

```bash
scripts/teardown.sh --keep-ip --keep-registry     # selective: the normal call
scripts/teardown.sh --dry-run                     # show what would go
```

Removes the SRT ingest rule, the budget, the CI identity, and the relay and watchdog
containers. Leaves the VM, NIC, vnet, NSG, public IP, Key Vault and disks — all adopted —
and leaves `:443` and `:80`, since other services on a shared host may serve on one and
renew certificates over the other.

**Refused while any channel declares `publishing: true`.** Tearing down takes live channels
off the air and the producers will not notice: SRT backoff reconnects forever rather than
exiting, so every container stays healthy while the displays hold their last frame.
`--abandon-channels` overrides it. The watchdog is stopped *before* the relay, so planned
work does not page.

Deleting the resource group is refused unless `SHARED_RESOURCE_GROUP` is exactly `false`,
and fails closed when the flag is absent.

## Troubleshooting

| Symptom | Cause |
| :--- | :--- |
| Publisher connects, then drops | Wrong passphrase. SRT wire encryption is the credential — `?passphrase=…&pbkeylen=32`, not the streamid's `user:pass`. |
| Playlist stops advancing, ingest looks healthy | `hlsAlwaysRemux` is off. nginx reads the directory rather than connecting as a client, so MediaMTX sees no readers and closes the muxer. |
| Container healthy, nothing on screen | The publisher is not publishing. `docker exec stream-relay wget -qO- http://127.0.0.1:9997/v3/paths/list` — the API answers only from inside the container. |
| Viewers blocked, allowlist looks right | VPN egress ranges. See Access control. |
| Every display dark at once | The `443` allowlist. Check a viewer's egress address against the configured ranges. |
| `401` reading metrics from another container | Expected. MediaMTX admits api/metrics from its own loopback; the watchdog has an explicit `/32` grant for `metrics` only. |
| Watchdog up but writing no snapshot | Ownership. It runs unprivileged, so `/srv/relay-logs` and `/srv/relay-status` must belong to its uid. |
| `BCP091` on deploy | The engine and config repos must be siblings; `infra.bicepparam` names its template relatively. |

## License

See [LICENSE.md](LICENSE.md).
