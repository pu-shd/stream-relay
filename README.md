# stream-relay

A MediaMTX-based SRT ingest, optional transcode, and CDN egress service — built as a **cold
standby** for [`page-stream`](https://github.com/pu-orfe/page-stream) should an institutional
Kaltura license lapse.

`page-stream` captures web pages and pushes SRT to an ingest. Today that ingest is Kaltura,
which also transcodes, packages HLS, and fronts a CDN. `stream-relay` replaces that
distribution plane on Azure with MediaMTX + ffmpeg + Azure Front Door, **without changing a
single line of `page-stream`**.

> **This is a fallback, not production.** It is designed to be deployed from nothing in under
> 30 minutes and torn down to ~$5/month. If you found it running and nobody is mid-cutover,
> something is wrong — see [Cost posture](#cost-posture).

---

## Status

**Phases 0–2 complete. Phases 3–5 designed but not implemented.** This table is the honest
picture of what exists today; everything else below is documented as designed.

| Component | State |
| :--- | :--- |
| `relay.yml` schema + `render-relay.py` (config repo) | ✅ 103 tests passing |
| MediaMTX image + fail-closed entrypoint | ✅ verified against a real MediaMTX |
| Local stack (`docker-compose.local.yml`) | ✅ verified |
| Integration test: encrypted SRT → HLS → ffprobe | ✅ 18 assertions passing |
| `infra/main.bicep` + 7 modules | ✅ compiles; 22 resource creations validated by what-if |
| `scripts/{bootstrap,deploy,update,teardown,restrict,allow-all,verify}.sh` | ✅ written, bash 3.2-safe |
| `tests/mock-az/` | ✅ 25 assertions passing (offline) |
| **Behaviour of the deployed service** | ⚠️ **UNPROVEN — needs a real deploy** |
| GitOps deploy workflow + OIDC | ❌ Phase 3 |
| pugwips module | ❌ Phase 4 |
| `page-stream-config --profile relay` cutover flag | ❌ Phase 5 |

**No billable Azure resource has ever been created. Cost to date: $0.** An empty resource group
(`orfe-dept-azure-relay-rg`) exists in `ORFE-dept-azure` so that `what-if` has a scope to run in;
resource groups are free and it holds nothing. Remove it any time with
`az group delete -n orfe-dept-azure-relay-rg --yes`.

### What "Phase 2 complete" does not mean

`what-if` validates the *shape* of a deployment, not its *behaviour*. Two of the most expensive
things in this design remain unverified until someone actually deploys:

- whether the cache rule really collapses the `?session=` key (get it wrong and egress roughly
  doubles);
- whether the Front Door hostname survives a teardown/redeploy cycle.

`scripts/verify.sh` asserts both, but it needs a live endpoint. Also note that what-if happily
evaluated `Microsoft.Cdn` resources while that provider was still **NotRegistered** on the
subscription — so what-if would not have caught a real blocker, which is exactly why
`preflight` and `register-providers` are separate steps.

## Contents

- [Why MediaMTX (and not YouTube)](#why-mediamtx-and-not-youtube)
- [Why Azure](#why-azure)
- [Cost posture](#cost-posture)
- [Architecture](#architecture)
- [Capacity tiers](#capacity-tiers)
- [Repository split](#repository-split)
- [Quick start](#quick-start)
- [Scripts](#scripts)
- [Custom domain](#custom-domain-two-phase)
- [Security model](#security-model)
- [Cost guardrails](#cost-guardrails)
- [Optional: pugwips allowlist](#optional-pugwips-allowlist)
- [Testing](#testing)
- [Cutover runbook](#cutover-runbook)
- [Rehearsal drill](#rehearsal-drill)
- [Porting to GCP](#porting-to-gcp)
- [Troubleshooting](#troubleshooting)

---

## Why MediaMTX (and not YouTube)

YouTube Live was evaluated first, because it costs nothing. It is not a drop-in:

| | Kaltura (today) | YouTube Live | **MediaMTX** |
| :--- | :--- | :--- | :--- |
| SRT ingest | ✅ | ❌ RTMP/RTMPS/HLS/DASH only | ✅ native |
| `page-stream` changes | — | `--format flv` + RTMPS URLs in every service block | **none** |
| Audio required | no | **yes** (silent AAC track needed) | no |
| Streams per endpoint | many, by `streamid` | one broadcast per stream key | many, by path |
| Latency control | `latency=` tunable | 20–60 s normal | `latency=` tunable |
| Retry semantics | exit-10 backoff | preserved (`rtmps://` matches) | preserved |

MediaMTX keeps `srt://…?streamid=…` with `-f mpegts`, so `isRetryProtocol()`, the exit-code
contract (`0` graceful / `10` retry exhausted / `11` non-retry), and the `latency=` buffer all
carry over untouched.

**Bonus:** no `#` appears anywhere in a relay ingest URL. The entire `.env.secrets.sh` workaround
that Kaltura's `streamid=#:::e=…` forces on `page-stream-config` is unnecessary in relay mode.

### The publish credential is SRT wire encryption

This is the single easiest thing to get wrong, so it is stated plainly. MediaMTX has **two
unrelated** mechanisms:

| Mechanism | Config | Client |
| :--- | :--- | :--- |
| **SRT wire encryption** ← *what we use* | `srtPublishPassphrase` on the path | `?passphrase=<secret>&pbkeylen=32` |
| MediaMTX internal auth | `authInternalUsers` | `streamid=publish:<path>:<user>:<pass>` |

So the working ingest URL is:

```
srt://<host>:8890?streamid=publish:news&passphrase=<secret>&pbkeylen=32&latency=200000
```

Putting the secret in the streamid's fourth field **fails the handshake** with
`connection is encrypted, but no passphrase is defined in configuration`. Encryption is the
right choice here regardless: `page-stream` publishes to a public IP across the open internet,
so the stream should be encrypted on the wire, and the passphrase doubles as the shared secret.

Passphrases must be **10–79 characters** (an SRT requirement) and are constrained to
`[A-Za-z0-9_-]` by the container entrypoint, which fails closed rather than risk corrupting a
credential during substitution. Generate one with:

```bash
openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 40
```

### What MediaMTX does *not* do

**It does not transcode.** It is a media router — it remuxes and repackages. Transcoding is an
external `ffmpeg` process launched per stream via the `runOnAvailable` hook. Consequently:

- **Tiers >0 are not an adaptive bitrate ladder.** MediaMTX serves one HLS playlist per path, so
  a transcode hook publishes *additional* paths (`news-720`) at their own URLs. True ABR needs
  an external packager writing a master playlist, replacing MediaMTX's HLS muxer.
- There is no ABR fallback for a viewer on a bad connection — they buffer. Acceptable here
  because every consumer is an Apple TV on campus wired ethernet.

> **Version note:** `runOnReady` was renamed **`runOnAvailable`** in MediaMTX v1.19.3
> (2026-07-23). The old name still works as a deprecated alias; generated configs use the
> current one. The image is pinned to `bluenviron/mediamtx:1.19.3-ffmpeg` — the `-ffmpeg`
> variant is required for the transcode hooks.

## Why Azure

1. **The architecture is identical on both clouds, so reuse decides.** SRT is UDP; neither Azure
   Front Door nor GCP Media CDN carries UDP. On both, ingest hits a public IP directly and only
   HLS egress goes through the CDN.
2. **GCP's one differentiator is priced out of range.** GCP has a managed encoder (Live Stream
   API, which does accept SRT); Azure has none since Azure Media Services retired 2024-06-30.
   But a 1080p ladder there is ≈$1.26/hr/channel ≈ **$920/mo per channel** — versus ~$145/mo for
   one VM running all seven.
3. **The secretless chains already exist on Azure.** GitHub → Azure via OIDC federated
   credential; VM → ACR via user-assigned managed identity. Both zero-secret, both already used
   by `pu-orfe/azure-gh-token-func` and `pugwips`.
4. **A fallback you never rehearse must run on infrastructure you touch weekly.** Novelty is a
   failure mode for cold standby.

## Cost posture

**Egress dominates by an order of magnitude over compute.** Viewers drive egress; channel count
drives CPU. The two scale independently — 10 Apple TVs pull 10 concurrent streams whether you
publish 7 channels or 20.

```
monthly egress GB ≈ viewers × bitrate_Mbps × 3600 × 24 × 30 / 8 / 1000
```

| Posture | What's running | Cost/mo |
| :--- | :--- | :--- |
| **Cold standby** (default) | ACR Basic holding built images; IaC in git | **~$5** |
| Warm standby | + VM up, no streams | ~$150 |
| Activated: 7 ch, tier 0, 10 viewers @1500k | VM + AFD + egress | **~$603** |

Run `tools/render-relay.py orfe --size` in the config repo for the current projection.

Serving straight off the VM does **not** save money — Azure VM egress bills at the same
~$0.087/GB. Front Door earns its place on free managed TLS, custom domain, and DDoS protection.

**Bitrate is the highest-leverage lever.** The relay defaults to `1500k` rather than Kaltura's
`2500k`: for mostly-static web pages the difference is invisible and saves ~$280/mo at 10
viewers.

## Architecture

```
 page-stream stack (on-prem Mac)                              Azure
┌──────────────────────────────────────┐   SRT/UDP   ┌─────────────────────────────────┐
│ standard-1..6, compositor            │────────────▶│ Public IP  :8890/udp            │
│   ffmpeg -f mpegts srt://…            │  encrypted  │   NSG: allowlisted sources      │
│   streamid=publish:<path>             │             │ ┌─────────────────────────────┐ │
│   &passphrase=…&pbkeylen=32           │             │ │                             │ │
└──────────────────────────────────────┘             │ │ VM  (D4s v6 at tier 0)      │ │
                                                     │ │  mediamtx — remux only      │ │
 ORFE Apple TVs (VLC)                                │ │   runOnAvailable →          │ │
┌──────────────────────────────────────┐             │ │     ffmpeg (tiers >0 only)  │ │
│ https://<host>/<path>/index.m3u8     │◀────────────│ │  :8888 LL-HLS               │ │
└──────────────────────────────────────┘    HTTPS    │ └─────────────────────────────┘ │
                                                     │ Front Door Std — TLS + cache    │
                                                     │ Key Vault — SRT passphrase      │
                                                     │ ACR — images, MI pull           │
                                                     └─────────────────────────────────┘
```

Why SRT bypasses Front Door: Front Door is a Layer-7 HTTP/HTTPS/HTTP‑2 proxy with no UDP
support. UDP ingest therefore terminates on the VM's public IP (or an Azure Standard Load
Balancer, which does support UDP rules), and the NSG is the access control.

### HLS variant, and the cache-key trap that costs real money

`capacity.hls_variant` defaults to **`mpegts`**, deliberately *not* MediaMTX's own `lowLatency`
default. Latency is irrelevant to a signage display, while `mpegts` gives the widest VLC/Apple TV
compatibility (`EXT-X-VERSION:3`, one muxed playlist) and the fewest CDN requests.

**MediaMTX appends a per-viewer `?session=<uuid>` to every variant-playlist URL, in every
variant** — verified on `mpegts`, `fmp4` *and* `lowLatency`. Unless Front Door's cache key is
configured to **ignore the `session` query parameter**, every viewer is a distinct cache key, the
hit rate collapses to ~0, and you pay origin egress on top of edge egress — roughly doubling the
bill. Front Door Standard supports *Ignore Specified Query Strings*, which is exactly the needed
control. The rule lives in `infra/main.bicep` and is load-bearing.

## Capacity tiers

`capacity.tier` in `relay.yml`, overridable per channel. Sizes come from
`tools/render-relay.py --size`, which is the authoritative model.

| Tier | Renditions | ~vCPU/ch | 7 ch | 20 ch |
| :--- | :--- | :--- | :--- | :--- |
| **0 — passthrough** *(default)* | source, remux | ~0.1 | D4s v6 | D8s v6 |
| 1 | + 720p | ~1.3 | F16als v6 | F32als v6 |
| 2 | + 720p + 480p | ~2.1 | F32als v6 | F48als v6 |

**Tier 0 is genuinely sufficient** for campus Apple TVs at fixed 1080p; higher tiers exist for a
future phone/off-campus audience.

Tier 0 uses the SMT-enabled **D-series** (cheaper per vCPU, and remuxing is not CPU-bound).
Tiers >0 use the **v6 F-family** (Fasv6/Falsv6, AMD EPYC 9004) because it ships *without SMT* —
1 vCPU = 1 physical core, which matters materially for x264 throughput and per-core determinism.
Pinning a D-series size at tier >0 is rejected by validation.

## Repository split

Mirrors `page-stream` / `page-stream-config` in shape, so the idioms transfer.

| Repo | Contents |
| :--- | :--- |
| **`pu-orfe/stream-relay`** (this repo) | The engine. Bicep IaC, scripts, MediaMTX Dockerfile, local compose stack, engine tests. Department-agnostic — no ORFE specifics, no resource names. |
| **`pu-orfe/stream-relay-config`** | The deployment. `<dept>/relay.yml` (the only file anyone edits), generated `mediamtx.yml` / `deploy.env` / `ingest-urls.env` / `infra.bicepparam`, GitOps workflows, validation suite. |

Both are private. The split is structural, not a visibility boundary.

**`relay.yml` is the single source of truth.** Everything derivable is generated, and
`--check` fails CI on drift. Two of the three faults behind the July 2026 channel mix-up in
`page-stream` were dual-maintenance drift; this is the same guard.

## Quick start

```bash
# 1. Validate the config and see what it would cost
cd ../stream-relay-config
orfe/tests/run-tests.sh                # containerized; needs only Docker
orfe/tests/run-tests.sh --size         # derived VM size + projected monthly bill

# 2. Prove the whole path works locally — no cloud, no spend
cd ../stream-relay
tests/integration/test-publish-to-hls.sh    # 18 assertions, SRT -> MediaMTX -> ffprobe

# 3. Bring the local stack up to watch it
export SRT_PUBLISH_PASSPHRASE=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 40)
docker-compose -f docker-compose.local.yml --profile testsrc up -d
open http://127.0.0.1:8888/news/index.m3u8

#    Publish from page-stream instead of the test pattern:
#    node dist/index.js --url https://orfe.princeton.edu/news \
#      --ingest "srt://127.0.0.1:8890?streamid=publish:news&passphrase=$SRT_PUBLISH_PASSPHRASE&pbkeylen=32"

# 4. Deploy to Azure (interactive, resumable) — NOT YET IMPLEMENTED, see Status
scripts/bootstrap.sh
```

## Scripts

All follow the same conventions as `page-stream`'s `bootstrap-runner.sh`: ANSI colour, `[n/N]`
step headers, `✓`/`✗`/`⚠` glyphs, numbered menus.

| Script | Purpose |
| :--- | :--- |
| `bootstrap.sh` | Interactive first run: preflight, `az login`, subscription/region pickers, name and tier prompts, then RG → ACR → Key Vault → UAMI → federated credential → VM → Front Door. Prints the DNS block and the GitOps `vars` to set. |
| `deploy.sh` | Non-interactive, idempotent, CI-callable. `--tier`, `--dry-run` (Bicep `what-if`), `--print-dns-only`. |
| `update.sh` | Config/image roll without recreating infra. Verifies every path serves HLS; rolls back on failure. |
| `teardown.sh` | `--soft` (delete VM + Front Door, keep ACR/KV/UAMI → back to ~$5/mo) or `--hard` (delete the resource group). Requires typing the RG name; `--yes` for CI. |
| `restrict.sh` | **Kill switch.** Flips the endpoint to the campus + VPN allowlist immediately. Works even with `pugwips.enabled: false`, falling back to the static ranges. |
| `allow-all.sh` | Break-glass: removes the allowlist when it has locked out the displays. |

### Resumability

Every script is resumable, because Front Door certificate issuance alone can take 24–48 hours.

- State lives in `.stream-relay-state.json` (gitignored): `{step, status, resource_ids}`.
- **Every step is idempotent and independently verifiable** — it re-queries Azure before acting,
  so a resumed run converges even if the state file is stale or deleted. **State is an
  accelerator, not the source of truth.**
- Flags: `--resume`, `--step <name>`, `--from <name>`, `--list-steps`, `--reset-state`.
- A `trap` on `ERR`/`INT` records the failed step and prints the exact `--from` command to
  resume. State is written *after* verification, never before acting, so a step is never
  recorded half-done.
- Slow steps poll with a spinner, a real timeout, and a note about what they are waiting on.

## Custom domain (two-phase)

`domain` is optional throughout. Front Door will not issue a certificate until DNS exists, so:

**Phase A — no DNS yet (`domain: null`).** Live and fully testable at
`https://<endpoint>.azurefd.net/<path>/index.m3u8`. Only the hostname is ugly.

**Phase B — when `stream.orfe.princeton.edu` exists.** Set `domain:` in `relay.yml`, re-run
`deploy.sh`. It prints a copy-pasteable request for whoever runs Princeton DNS:

```
TXT    _dnsauth.stream.orfe.princeton.edu   <validation-token>
CNAME  stream.orfe.princeton.edu            <endpoint>.azurefd.net
CAA    orfe.princeton.edu                   0 issue "digicert.com"   # if CAA is enforced
```

Front Door needs **both** the TXT (ownership) and the CNAME. `deploy.sh` then polls
`Pending → Approved → Certificate issued`, resumable across days.
`--print-dns-only` emits the block without touching anything, so the DNS ticket can be filed
before any spend.

> Keep the `*.azurefd.net` hostname working permanently as a fallback. The rendered
> `mdm/vlc.xml` uses whichever hostname is currently valid — **the Apple TVs must never be
> blocked on a DNS ticket.**

## Security model

**No secrets in any cloud deployment pipeline.**

| Hop | Mechanism | Secret stored? |
| :--- | :--- | :--- |
| GitHub Actions → Azure | User-assigned managed identity + federated credential; `azure/login@v2` with `client-id`/`tenant-id`/`subscription-id` in **`vars`** | none |
| VM → ACR | Same UAMI + `Container Registry Repository Reader` (ABAC registries) or `AcrPull`; `az login --identity` → `az acr login` | none |
| VM → SRT passphrase | **Key Vault**, read at boot by the VM's managed identity | in Key Vault only |
| `page-stream` → relay | Publisher-side passphrase from the config repo's existing repository secrets | pre-existing |

Notes:

- The three Azure IDs are **not sensitive**; `vars` is deliberate. Microsoft's docs store them as
  secrets, which is unnecessary and obscures diffs.
- **GHCR is not used.** It has no managed-identity path and would force a stored PAT on the VM.
  CI pushes to ACR; the VM pulls from ACR with its identity.
- Avoid wildcard ("flexible") federated credential subjects — GA status unconfirmed. Enumerate
  branch and environment subjects explicitly.
- `az acr login` mints a short-lived token, so a systemd timer refreshes it on long-running hosts.
- The GitOps workflow uses `environment: production` with a required reviewer, so real spend is
  gated behind a human click.
- MediaMTX's API and metrics bind to **loopback only** and are never exposed by the NSG.

## Cost guardrails

**HLS is public by default**, which makes the egress downside unbounded — the ~$423/mo egress
figure assumes 10 Apple TVs, and nothing stops a scraper from multiplying it. These are
provisioned by Bicep, not added by hand:

- **Front Door WAF rate-limit rule**, per socket IP. Available on **Front Door Standard** —
  only *managed* rule sets (OWASP CRS) require Premium, so no tier upgrade is needed. Set the
  threshold well above a legitimate LL-HLS player's segment cadence; alert before blocking.
- **Azure Budget + cost anomaly alert** on the resource group, at two thresholds
  (`budget_warn_usd`, `budget_alert_usd`).
- **`scripts/restrict.sh`** as the documented response to a bandwidth incident — tested in the
  rehearsal drill, not first attempted during one.
- `egress.expected_viewers` in `relay.yml` feeds the projection, and CI flags a config whose
  declared viewers imply spend above `monthly_cost_ceiling_usd`.

## Optional: pugwips allowlist

Off by default (`pugwips.enabled: false`), since HLS is public by default. It is the lever to
pull if the open endpoint is abused.

[`pugwips`](https://github.com/PrincetonUniversity/pugwips) resolves Princeton GlobalProtect
gateway IPs and publishes them as a signed `gateways.json` release, with an `update_nsg` Function
and an `update-ip-restrictions.sh` example already written.

- **Ingest side:** NSG rule on `8890/udp` limited to the runner's egress IP + campus + VPN ranges.
- **Egress side:** Front Door WAF custom rule allowlisting campus + VPN for `/*/index.m3u8`.
- **Refresh:** scheduled workflow, **retaining pugwips' fail-safe** — if `gateways.json` cannot be
  fetched, keep the existing rules rather than locking everyone out.
- Reading the release needs a token, which is why this is opt-in rather than default.

## Testing

Mock-first. Nothing in the default suite touches Azure or spends money.

| Suite | What it proves | Needs |
| :--- | :--- | :--- |
| `stream-relay-config/orfe/tests` | `relay.yml` → generated files; path/producer uniqueness; tier→SKU sizing; drift `--check`; secret hygiene; agreement with `page-stream-config` | Docker |
| `tests/mock-az/` | An `az` shim earlier on `PATH` returns canned JSON, so all four scripts run offline. Asserts argv, **idempotency** (a second run makes no mutating calls), **resumability** (kill at step *n*, `--resume`, converge), teardown ordering, and that `--soft` leaves ACR/KV/UAMI alive. | bash |
| `tests/integration/` | Real `page-stream` container publishes SRT to a real MediaMTX; `ffprobe` asserts a valid manifest, ≥2 segments, expected resolution, non-zero frames, and that `runOnAvailable` fired at tier 1 | Docker |
| `tests/bicep/` | `az bicep build` + `az deployment group what-if`. Gated on `LIVE=1`, matching the existing convention. | `az`, a subscription |

```bash
cd ../stream-relay-config && orfe/tests/run-tests.sh   # config validation
tests/run-tests.sh                                     # engine: mock-az + integration
LIVE=1 tests/run-tests.sh                              # + real Bicep what-if
```

## Cutover runbook

Activating the fallback is a flag flip, not an archaeology exercise.

```bash
# 1. Stand up the relay (resumable; ~30 min with images already in ACR)
scripts/bootstrap.sh --resume

# 2. Verify every path serves HLS
scripts/verify.sh

# 3. Repoint page-stream at the relay
cd ../page-stream-config
python3 tools/render-config.py orfe --profile relay
git commit -am "Cut over to stream-relay" && git push

# 4. Deploy the page-stream stack (existing GitOps workflow)
gh workflow run deploy.yml

# 5. Push the regenerated mdm/vlc.xml to the Apple TVs, then verify each display
```

Reverting is the same sequence with `--profile kaltura`. `channels.yml` keeps both `entry_id`
and `relay_path`, so both profiles stay fully described at all times and neither is a
reconstruction job.

## Rehearsal drill

**A cold standby nobody rehearses is not a fallback.** A scheduled workflow runs quarterly:
full deploy → integration assertions against the live endpoint → `restrict.sh` exercise →
teardown → report. It is the only defence against standby rot, and it is where the real
cutover timings in this README come from.

## Porting to GCP

Should Azure become unavailable, the MediaMTX layer is unchanged. Swap:

| Azure | GCP |
| :--- | :--- |
| Bicep | Terraform / Deployment Manager |
| Front Door Standard | Media CDN (has a documented livestream optimization Front Door lacks) |
| Public IP / Standard LB (UDP) | Regional external passthrough Network LB (UDP) |
| UAMI + federated credential | Workload Identity Federation |
| Key Vault | Secret Manager |
| ACR | Artifact Registry |

Do not build both. This table exists so the choice can be revisited, not hedged.

## Troubleshooting

**Publisher connects then immediately drops with `connection is encrypted, but no passphrase is
defined in configuration`.** The secret is in the wrong place. It belongs in the URL's
`?passphrase=` parameter, **not** as a fourth `streamid` field — see
[the publish credential](#the-publish-credential-is-srt-wire-encryption). Also confirm the relay
actually loaded a passphrase: the entrypoint logs `rendered … (passphrase substituted)`.

**Publisher is rejected with no useful message.** Passphrase shorter than 10 or longer than 79
characters — libsrt rejects it at handshake time. The entrypoint catches this server-side, but the
publisher's copy is unchecked.

**Container exits immediately with `config template not found`.** The config repo's `<dept>/`
directory is not mounted at `/config`. On macOS + Colima, note that `/tmp` is **not** a shared
path — mount from somewhere under `$HOME`.

**`index.m3u8` returns 404.** Nothing is publishing to that path yet. MediaMTX creates the HLS
muxer on first publish. Check `mediamtx` logs and `RELAY_PATHS` in `deploy.env`.

**Stale playlist for hours or days.** The Front Door cache rule is missing. MediaMTX emits no
`Cache-Control`, and Front Door then assigns a **random 1–3 day TTL**. The explicit rule in
`infra/main.bicep` is load-bearing — do not remove it.

**Viewers buffer on one channel only.** That channel is at tier 0 while its source is above the
VM's headroom, or a tier >0 hook is thrashing. Check `runOnAvailableRestart` loops in the logs
and re-run `--size`.

**Certificate stuck `Pending`.** Both DNS records must exist — the `_dnsauth` TXT *and* the
CNAME. Verify from outside with `tools/check-dns.sh`; issuance takes 24–48 h after validation.

**`az acr login` fails on the VM.** The managed-identity token expired. Confirm the systemd
refresh timer, and that the identity holds `Container Registry Repository Reader` (ABAC
registries) or `AcrPull` (non-ABAC).

**Everything locked out after enabling pugwips.** Run `scripts/allow-all.sh`. Then check whether
the `gateways.json` fetch failed and the fail-safe did not engage.

---

## License

MIT — see [LICENSE.md](LICENSE.md).
