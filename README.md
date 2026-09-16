# stream-relay

SRT ingest, HLS delivery. An encoder publishes SRT to this service; viewers play HLS over
HTTPS. It exists so a department can run more concurrent streams than its upstream video
platform allows.

It is department-agnostic: this repo holds no resource names, addresses or channel
definitions. A deployment lives in its own config repo, which supplies all of those.

---

## Architecture

```
  encoder                          Azure VM
┌──────────────┐                   ┌────────────────────────────────────┐
│  publisher   │ ──SRT/UDP:8890──► │ MediaMTX      remux, no transcode  │
│  (1 or many) │   encrypted       │   └─ writes HLS to disk            │
└──────────────┘                   │ nginx :443    serves those files   │
                                   │ nginx :80     ACME challenge only  │
                                   │ certbot       renews on a loop     │
                                   └────────────────┬───────────────────┘
                                                    │ HTTPS
                                                 viewers
```

No CDN and no object store. For an audience close to the origin there is nothing for a CDN
to optimise, so nginx serves MediaMTX's `hlsDirectory` directly and the network security
group is the access control. At CDN-scale viewership that trade stops making sense.

MediaMTX's own HLS port is bound but never published. It gates variant playlists on a
per-viewer session and sends `Cache-Control: private, no-cache`; nginx serving the files
from disk has neither behaviour.

**The template adopts a VM rather than creating one.** It references the host, its network
and its vault as `existing`, so the relay can be added to a machine that already does other
work. Declaring an existing VM instead would let Azure decide to replace it, and replacement
destroys its disks. The resource group may be shared, which is why nothing here deletes by
group.

---

## Repository split

| | |
| :--- | :--- |
| **`pu-shd/stream-relay`** (this repo, public) | The engine. Bicep, deploy/verify/teardown scripts, local compose stack, test suites. Department-agnostic: no resource names, no addresses. |
| **`pu-shd/stream-relay-config`** (private) | The deployment. `<dept>/relay.yml` is the only file anyone edits; everything else in that directory is generated from it. |

`relay.yml` renders `mediamtx.yml.tmpl`, `docker-compose.yml`, `nginx.conf`, `deploy.env`,
`ingest-urls.env` and `infra.bicepparam`. A test asserts the generated files match the
source, so drift fails CI rather than surfacing mid-deploy.

---

## Quick start — local, no cloud, no spend

```bash
export SRT_PUBLISH_PASSPHRASE=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 40)
docker-compose -f docker-compose.local.yml --profile testsrc up -d
open http://127.0.0.1:8888/news/index.m3u8
```

Publish from page-stream instead of the built-in test pattern:

```bash
node dist/index.js --url https://example.edu/page \
  --ingest "srt://127.0.0.1:8890?streamid=publish:news&passphrase=$SRT_PUBLISH_PASSPHRASE&pbkeylen=32"
```

---

## Deploy

GitOps, from the config repo: **Deploy (GitOps)** is `workflow_dispatch` only. `plan` runs
read-only on a hosted runner and prints the what-if diff *before* the reviewer gate, so the
approval is informed. Azure jobs authenticate with OIDC; VM-side convergence runs on a
self-hosted runner on the VM itself.

Or run it directly:

```bash
scripts/deploy.sh --dry-run          # what-if only
scripts/deploy.sh                    # converge
scripts/deploy.sh --from infra       # resume after a failure
scripts/deploy.sh --list-steps
```

Seven steps, resumable, idempotent:

| Step | |
| :--- | :--- |
| `preflight` | tooling, login, role, quota |
| `register-providers` | resource providers |
| `resource-group` | confirms it exists — never creates it, the group is shared |
| `passphrase` | ensures the SRT passphrase is in Key Vault |
| `infra` | one Bicep deployment: NSG rules and the budget |
| `configure` | renders the relay config on the VM and brings the stack up |
| `verify` | asserts the deployment end to end |

`--with-role-assignments` is the one-time human bootstrap; it needs Owner or User Access
Administrator. Every other run, CI included, never touches RBAC.

---

## Scripts

| | |
| :--- | :--- |
| `bootstrap.sh` | interactive first run, including the role assignments CI may not create |
| `deploy.sh` | non-interactive, idempotent, CI-callable |
| `verify.sh` | asserts the deployed relay actually serves |
| `update.sh` | roll new config without touching infrastructure |
| `restrict.sh` | kill switch — narrow the viewer allowlist, or close it entirely |
| `allow-all.sh` | break glass — reopen after `restrict.sh` |
| `teardown.sh` | remove the relay's own resources (see below) |

---

## Access control

The NSG is the boundary. There is no WAF and no CDN in front of it.

| Port | Source |
| :--- | :--- |
| `8890/udp` | the publisher's network — SRT wire encryption is the publish credential |
| `443/tcp` | the viewer networks the config allows — nothing else reaches the HLS |
| `80/tcp` | the internet, serving `/.well-known/acme-challenge` and nothing else |
| `22` | **no rule** |

Port 80 is open because Let's Encrypt validates from undisclosed, rotating addresses, so the
rule cannot be narrowed to them. nginx 404s every other path on that port, so what is
exposed is a directory of ACME tokens.

There is no inbound administrative path. Administration is `az vm run-command` over the
Azure control plane, which is RBAC-gated and audited.

**Allowlisting a VPN needs the egress ranges, not the gateway addresses.** Cloud VPN
services commonly source-NAT clients from a pool that is not adjacent to the gateway a
client connected to, so a list built from resolved gateway addresses admits the gateways and
blocks every client behind them. Test from a real VPN connection before trusting one.

---

## Identities

Two, least privilege each.

| | |
| :--- | :--- |
| **CI** — federated to GitHub Actions via OIDC | Network Contributor and Cost Management Contributor on the resource group, Key Vault Secrets Officer on the vault. No stored credential. |
| **VM** — SystemAssigned | reads one Key Vault secret. Nothing else. |

Not Contributor: the resource group is shared, so Contributor would permit deleting the
machine the relay runs on.

CI cannot create role assignments. `deployRoleAssignments` defaults to `false`, and a
principal that can grant roles can grant itself any role in scope.

OIDC subjects carry GitHub's immutable org and repo IDs
(`repo:org@123/repo@456:ref:refs/heads/main`), which is what stops a renamed or transferred
repository inheriting the trust.

---

## TLS

certbot renews on a loop and nginx reloads on another, both as containers. A one-shot
`certbot certonly` issues a certificate that expires ninety days later with nobody watching.

The certificate must cover a real hostname. `*.cloudapp.azure.com` is absent from the Public
Suffix List, so Let's Encrypt counts it against `azure.com` — a rate limit shared with every
Azure tenant — and can never issue for the derived name. Enabling TLS without a `domain` is
a config error.

---

## Cost

Egress dominates, and it scales with **viewers**, not channels:

```
monthly egress GB ≈ viewers × bitrate_Mbps × 3600 × 24 × 30 / 8 / 1000
```

Egress is typically the larger line by several times. Run `tools/render-relay.py <dept>
--size` in the config repo for a projection from the actual channel count, bitrate and
expected viewers.

Bitrate is the highest-leverage lever. VM size is not: remuxing is an I/O job, and a
two-vCPU host carries eight simultaneous 1080p channels at around 13% of one core, so the
sizing model errs generous by design.

A budget with forecast alerts is provisioned by the deployment. Forecast matters — once
actual spend crosses a ceiling the money is already gone.

---

## Testing

```bash
tests/mock-az/run.sh                 # 33 assertions, offline, no cloud
tests/integration/test-live-relay.sh # against a real deployment
```

The offline suite proves the step machine is idempotent, resumable and state-free, that
preflight fails closed, that the passphrase never reaches an `az` argv, and that teardown
deletes nothing it does not own.

---

## Teardown

```bash
scripts/teardown.sh --keep-ip --keep-registry
```

Removes the SRT ingest rule, the budget, the CI identity and the relay container. Leaves the
VM, its NIC, vnet, NSG, public IP, Key Vault and disks, all of which are adopted — and
leaves the `:443` and `:80` rules, since other services on a shared host may serve on one
and renew certificates over the other.

Deleting the resource group is refused when `SHARED_RESOURCE_GROUP` is not exactly `false`,
and fails closed when the flag is absent.

---

## Troubleshooting

| Symptom | Cause |
| :--- | :--- |
| Publisher connects, then drops | Wrong passphrase. SRT wire encryption is the credential — `?passphrase=…&pbkeylen=32`, not the streamid's `user:pass` field. |
| Playlist stops advancing, ingest looks healthy | `hlsAlwaysRemux` is off. nginx reads the directory rather than connecting as a client, so MediaMTX sees no readers and closes the muxer. |
| Viewers blocked, allowlist looks right | VPN egress ranges. See Access control. |
| Every display dark at once | The `443` allowlist. Check a viewer's egress address against the configured ranges. |
| `BCP091` on deploy | The engine and config repos must be siblings; `infra.bicepparam` names its template relatively. |
| Container healthy, nothing on screen | The publisher is not publishing. `docker exec stream-relay wget -qO- http://127.0.0.1:9997/v3/paths/list` — the API answers only from inside the container. |

---

## License

See [LICENSE.md](LICENSE.md).
