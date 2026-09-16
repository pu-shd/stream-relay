> **This is the ORIGINAL design plan, kept for its reasoning — not as current truth.**
>
> For what actually exists and what was proven against live Azure, read the
> [README status section](../README.md#status). Later phases are in
> [PHASE-2-PLAN.md](PHASE-2-PLAN.md) and [PHASE-3-PLAN.md](PHASE-3-PLAN.md).
>
> Two things below were overtaken by events. The cost model assumed CDN caching that
> MediaMTX's own HLS server could never provide, which is why delivery moved to Blob
> Storage; and the teardown design has since been inverted to complete-by-default. The
> Azure-vs-GCP decision, the capacity model and the egress arithmetic all still stand.

# stream-relay — Kaltura fallback plan

A MediaMTX-based SRT ingest + optional transcode + CDN egress service, built as a **cold
standby** for `pu-orfe/page-stream` should the institutional Kaltura license lapse.

Status: **Phases 0–1 built and verified. Phases 2–5 designed, not implemented.** No cloud
resources have been created; cost to date $0.

## 0. Findings from building it (2026-07-29)

Five things in the original design were wrong, and only running MediaMTX revealed them. All are
now fixed, encoded in tests, and reflected below.

1. **The publish credential is SRT wire encryption, not a streamid field.** The original design
   put the secret in `streamid=publish:<path>:<user>:<pass>`. That **fails** with
   `connection is encrypted, but no passphrase is defined in configuration` — `srtPublishPassphrase`
   is an AES passphrase, while `user:pass` drives MediaMTX's separate `authInternalUsers`
   mechanism. The working form is `streamid=publish:<path>&passphrase=<secret>&pbkeylen=32`.
   Encryption is the better choice anyway: `page-stream` publishes across the open internet.
2. **MediaMTX does not expand `${VAR}` in its YAML.** Only `MTX_*` env overrides, which cannot
   express a path named `news-plus`. The generated file is therefore `mediamtx.yml.tmpl`, and the
   container entrypoint substitutes the passphrase at start-up. Shipping it as `mediamtx.yml`
   would have authenticated every publisher against the literal placeholder string.
3. **MoQ (Media over QUIC) is on by default** and was listening on `:8892` over TCP *and* HTTP/3,
   self-generating a certificate. Now explicitly `moq: no`. Unknown config keys also abort
   startup outright — an invented `srtp: no` key was caught this way.
4. **`?session=<uuid>` defeats CDN caching.** MediaMTX appends a per-viewer session query string
   to every variant-playlist URL in **every** `hlsVariant` (verified on `mpegts`, `fmp4` and
   `lowLatency`). Front Door's cache key must be configured to *ignore* `session`, or the hit
   rate is ~0 and origin egress roughly doubles the bill. Front Door Standard supports exactly
   this control.
5. **`hlsVariant` defaults to `lowLatency`, which is the wrong default here.** Latency is
   irrelevant for signage; `mpegts` gives the widest VLC/Apple TV compatibility
   (`EXT-X-VERSION:3`, one muxed playlist) and the fewest CDN requests. Now a `relay.yml` knob
   defaulting to `mpegts`.

Also confirmed by running it: Front Door **Standard** supports custom WAF rules *and* rate
limiting (only managed rule sets need Premium), so the guardrails need no tier upgrade.

---

## 1. Decision: Azure

Recommendation: **Azure**, using Bicep + `az` CLI. Reasons, in order of weight:

1. **The architecture is a wash, so the tiebreaker is operational reuse.** SRT is UDP, and
   neither Azure Front Door nor GCP Media CDN will carry UDP — both are L7 HTTP proxies. On
   *both* clouds, SRT ingest must hit a public IP (or an L4 UDP load balancer) directly while
   only the HLS egress goes through the CDN. There is no architectural advantage either way.
2. **GCP's one real differentiator is priced out of range.** GCP has a managed encoder
   (Live Stream API, which does accept SRT push); Azure has nothing — Azure Media Services was
   retired 2024-06-30 with no first-party replacement. But a realistic 1080p ladder on Live
   Stream API runs ≈$1.26/hr/channel ≈ **$920/mo per channel**. Seven channels would be
   ~$6.4k/mo before egress, versus ~$150/mo for one VM running MediaMTX + ffmpeg. And the ask
   is explicitly MediaMTX-based, which forgoes the managed service anyway.
3. **Secretless chains already exist here, on Azure.** `pu-orfe/azure-gh-token-func` and
   `pugwips` are both Azure Function/Logic App + Entra patterns. GitHub Actions → Azure via
   OIDC federated credential, and VM → ACR via user-assigned managed identity, are both
   documented zero-secret flows. Princeton's IdP is Entra.
4. **A fallback you never rehearse must run on infrastructure you touch weekly.** Every other
   ORFE project defaults to Azure. Novelty is a failure mode for cold standby.

Azure caveats to design around, not discover later:

- AFD Standard assigns a **random 1–3 day cache TTL when the origin sends no `Cache-Control`**.
  Live manifests must send explicit short TTLs or you will serve stale playlists for days.
- **No ETag support** (only `Last-Modified`), **no documented origin shield / request
  coalescing** — each POP fills independently. Fine for a single-campus audience.
- Chunked-transfer responses >8 MB are unsupported. MediaMTX sends known-length segments, so
  this only matters if a proxy is inserted later.
- Use **Standard/Premium only**. AFD (classic) managed certs retired 2026-04-14; AFD (classic)
  itself retires 2027-03-31.

GCP stays documented as an escape hatch in the README (§ "Porting to GCP"): swap Bicep for
Deployment Manager/Terraform, AFD for Media CDN, UAMI for Workload Identity Federation. The
MediaMTX layer is unchanged. Do not build it twice.

## 2. The cost finding that shapes everything: build it cold

Egress dominates, and it dominates by an order of magnitude over compute.

```
monthly egress GB ≈ viewers × bitrate_Mbps × hours_per_day × 30 × 0.45
```

**Viewers drive egress; channel count drives CPU.** The two scale independently — 10 Apple TVs
pull 10 concurrent streams whether you publish 7 channels or 20. Don't conflate them when
sizing.

At the confirmed **10 Apple TVs**, 24/7, Azure's ~$0.087/GB:

| Bitrate | Egress/mo | Egress cost | + VM (D4s v6) + AFD base | **Total activated** |
| :--- | :--- | :--- | :--- | :--- |
| 2500k (current Kaltura profile) | 8.1 TB | $705 | $148 + $35 | **~$890/mo** |
| **1500k (proposed relay default)** | 4.86 TB | $423 | $148 + $35 | **~$610/mo** |

Dropping to 1500k saves **~$280/mo** for content that is mostly static web pages — the single
highest-leverage tuning decision in this design. Compute is ~$150/mo either way. Serving
straight off the VM does **not** help; Azure VM egress is billed at the same rate. AFD earns its
keep on free managed TLS, custom domain, and DDoS protection, not on bandwidth savings.

| Posture | What's running | Cost/mo |
| :--- | :--- | :--- |
| **Cold standby** (recommended default) | ACR Basic holding built images; IaC in git; nothing else | **~$5** |
| Warm standby | + VM up, no streams flowing | ~$155 |
| Activated, 7ch @1500k, 10 TVs | VM + AFD + egress | ~$610 |
| Activated, 20ch @1500k, 30 viewers | D8s v6 + egress | ~$1.6k |

**Therefore: the deliverable is a service that deploys from nothing in under 30 minutes and
tears down to ~$0, not a service that idles.** This elevates three things from
nice-to-have to load-bearing:

- `teardown.sh` is a first-class, tested, routinely-exercised script — not an afterthought.
- A **quarterly rehearsal drill** (deploy → verify → tear down) is the only thing that keeps
  a cold standby real. Put it in CI on a schedule.
- Bitrate is a cost lever. 1080p30 of a mostly-static web page looks identical at 1500k with a
  longer GOP. Default the relay profile lower than the Kaltura profile and note why.

## 3. Architecture

```
 page-stream stack (existing, on-prem Mac)                    Azure
┌──────────────────────────────────────┐   SRT/UDP   ┌─────────────────────────────────┐
│ standard-1..6, compositor            │────────────▶│ Public IP  :8890/udp            │
│   ffmpeg -f mpegts srt://…           │   8890/udp  │   NSG: campus + VPN + runner    │
│   streamid=publish:<path>:<u>:<p>    │             │ ┌─────────────────────────────┐ │
└──────────────────────────────────────┘             │ │ VM (Fasv6 / Dsv6)           │ │
                                                     │ │  mediamtx  ← remux only     │ │
 ORFE Apple TVs (VLC)                                │ │   runOnAvailable →          │ │
┌──────────────────────────────────────┐             │ │     ffmpeg (opt. transcode) │ │
│ https://stream.orfe.princeton.edu/   │◀────────────│ │  :8888 LL-HLS               │ │
│        <path>/index.m3u8             │    HTTPS    │ └─────────────────────────────┘ │
└──────────────────────────────────────┘             │ Azure Front Door Standard       │
                                                     │   custom domain + managed TLS   │
                                                     │ Key Vault (SRT passphrases)     │
                                                     │ ACR (images, MI pull)           │
                                                     └─────────────────────────────────┘
```

Facts this rests on (all verified):

- MediaMTX **does not transcode** — it remuxes. Transcoding is an external ffmpeg process
  launched per stream via the **`runOnAvailable`** hook (renamed from `runOnReady` in v1.19.3,
  2026-07-23; old name still accepted as a deprecated alias). Pin the version and use the new
  name.
- SRT publish streamid syntax is **`publish:<path>:<user>:<pass>`**, default port **8890/udp**.
  Note this contains **no `#`** — the entire `.env.secrets.sh` workaround that Kaltura's
  `streamid=#:::e=…` forces on `page-stream-config` becomes unnecessary in relay mode. Keep the
  file for the Kaltura path; relay ingest URLs can live in plain `.env`.
- HLS output is `http://host:8888/<path>/index.m3u8`, `hlsVariant` defaults to `lowLatency`.
- Existing `page-stream` code needs **zero changes**: relay ingest stays `srt://…?streamid=…`
  with `-f mpegts`, so `isRetryProtocol()`, the exit-10 backoff contract, and the `latency=`
  tuning all carry over untouched. This is the whole reason MediaMTX beats YouTube here.

### Channel → path mapping

Derive the relay path from the existing `orfe.princeton.edu/live/*` alias slug already in
`channels.yml`, so the two naming schemes cannot drift:

| Channel | Existing alias | Relay path |
| :--- | :--- | :--- |
| ORFE News | `/live/news` | `news` |
| ORFE News Plus | `/live/news-plus` | `news-plus` |
| ORFE Graduate | `/live/graduate` | `graduate` |
| ORFE Announcements | `/live/announcements` | `announcements` |
| ORFE Scenic | `/live/scenic` | `scenic` |
| ORFE Undergraduate | *(none — Kaltura URL direct)* | `undergraduate` ← explicit |
| ORFE Live Events | *(none — Kaltura URL direct)* | `live-events` ← explicit |

Channels lacking an alias get an explicit `relay_path:` key; tests fail if a channel has
neither.

## 4. Capacity model (tunable, sized from ORFE's 7 channels, headroom to 20)

MediaMTX remuxing is nearly free; **x264 is the entire CPU cost**. Because every current
consumer is an Apple TV on campus wired ethernet at fixed 1080p, **passthrough is genuinely
sufficient** — an ABR ladder only serves a hypothetical phone viewer. Default to Tier 0.

Sizes below are computed by `tools/render-relay.py --size`, which is the authoritative
sizing model (`BASELINE_VCPU` 1.5 + per-channel tier cost, × 1.25 headroom):

| Tier | Renditions per channel | ~vCPU/channel | 7 ch → SKU | 20 ch → SKU |
| :--- | :--- | :--- | :--- | :--- |
| **0 — passthrough** *(default)* | source only, remux | ~0.1 | **D4s v6** (4 vCPU, $0.20/hr) | D8s v6 ($0.40/hr) |
| 1 — +720p | source + 720p | ~1.3 | F16als v6 ($0.97/hr) | F32als v6 |
| 2 — +720p +480p | source + 720p + 480p | ~2.1 | F32als v6 ($1.94/hr) | F48als v6 |

**Tiers >0 are not an adaptive ladder.** MediaMTX serves one HLS playlist per path, so a
transcode hook publishes *additional* paths (`news-720`, `news-480`) at their own URLs —
alternate fixed renditions, not a single ABR manifest. True ABR would need an external
packager writing a master playlist, replacing MediaMTX's HLS muxer. Tier 0 is what the Apple
TVs need, so this is a documented limit rather than a problem — but it must not be discovered
during a cutover.

Prefer the **v6 F-family (Fasv6/Falsv6, AMD EPYC 9004)** for any transcode tier: no SMT, so
1 vCPU = 1 physical core, which is materially better for x264 throughput and per-core
determinism. D-series runs 2 vCPU per core — fine for Tier 0, misleading for Tier 1+.

Exposed as knobs in the config repo, not hardcoded:

```yaml
capacity:
  tier: 0                    # 0 | 1 | 2  — global default
  vm_size: Standard_D4s_v6   # null = derive from tier × channel count
  bitrate_default: 1500k     # relay profile; lower than the Kaltura profile on purpose
  gop_seconds: 2
channels:
  - path: news
    tier: 0                  # per-channel override
```

`tools/size-vm.py` prints the derived SKU and projected monthly cost for a given tier +
channel count, and CI asserts the committed `vm_size` is not undersized for the declared
channel set. Spot instances are ~80% off but evictable — viable for Tier 1+ transcode workers
later, never for the ingest endpoint. 3-year RIs are −61% and worth it only if this stops
being a standby.

## 5. Repository split (mirrors page-stream / page-stream-config)

| Repo | Visibility | Contents |
| :--- | :--- | :--- |
| **`pu-shd/stream-relay`** | **private** | The engine. `mediamtx.yml` template, transcode profiles, Dockerfiles, `infra/*.bicep`, `scripts/{bootstrap,deploy,update,teardown}.sh`, `docker-compose.local.yml`, mock + integration test suites, thorough README. Department-agnostic — no ORFE specifics, no resource names. |
| **`pu-shd/stream-relay-config`** | **private** | The deployment. `orfe/relay.yml` (single source of truth: channels, paths, tier, Azure resource names, domain), generated `orfe/mediamtx.yml` + `orfe/.env` + `orfe/infra.bicepparam`, `.github/workflows/{deploy,tests,rehearsal}.yml`, per-department dirs for future units. |

Both private (decided). The split is therefore **structural, not a visibility boundary**: engine
vs. deployment, mirroring `page-stream` / `page-stream-config` in shape so the idioms transfer.
Two consequences: the optional pugwips module can live in `stream-relay` rather than being
hidden away in the config repo, and `stream-relay` may be relicensed/opened later without
untangling ORFE specifics — keep it department-agnostic anyway.

Same discipline as `page-stream-config`: **`relay.yml` is the only file anyone edits**;
everything derivable is generated by `tools/render-relay.py`, with `--check` failing CI on
drift. That convention already prevented a repeat of the July 2026 channel mix-up; reuse it
rather than inventing a second idiom.

`gh` is authenticated as `pubino` with `repo` + `workflow` + `delete_repo` scope and
`pu-orfe` membership, so both repos can be created without new grants. (No `admin:org` —
fine, the org exists.)

## 6. Local scripts: friendly, colorful, interactive, resumable

Four scripts in `stream-relay/scripts/`, matching `bootstrap-runner.sh` conventions already in
`page-stream` (same ANSI palette, `[n/N]` step headers, `✓`/`✗`/`⚠` glyphs, numbered menu):

| Script | Does |
| :--- | :--- |
| `bootstrap.sh` | Interactive first-run: preflight (`az`, `docker`, `jq`, `gh`, versions), Azure login + subscription picker, region picker, name/tier/domain prompts with defaults, creates RG → ACR → Key Vault → UAMI → federated credential → VM → AFD, prints the DNS block and the GitOps `vars` to set. |
| `deploy.sh` | Non-interactive, idempotent, CI-callable. `--tier`, `--channels`, `--dry-run` (renders Bicep `what-if` and exits). |
| `update.sh` | Rolling config/image update without recreating infra: push image → `az acr` → restart the systemd unit → verify each path serves HLS → roll back on failure. |
| `teardown.sh` | Two-phase: `--soft` (delete VM + AFD, keep ACR/KV/UAMI → back to ~$5/mo) and `--hard` (delete the RG). Requires typing the resource group name to confirm; `--yes` for CI. |

**Resumability design** — the part that's easy to get wrong:

- A JSON state file `.stream-relay-state.json` (gitignored) records `{step, status, resource_ids,
  started_at}` per step. Every step is a named function in an ordered array.
- Each step is **idempotent and independently verifiable**: it re-queries Azure for the resource
  before acting, so a resumed run converges even if the state file is stale or deleted. State
  is an accelerator, not the source of truth.
- Flags: `--resume` (skip completed), `--step <name>` (run one), `--from <name>`, `--list-steps`,
  `--reset-state`.
- A `trap` on ERR/INT writes the failed step and prints the exact `--from` command to resume.
  Steps are never left half-recorded (write state *after* verifying, not before acting).
- Slow steps (VM provision, AFD propagation, cert issuance) poll with a spinner and a real
  timeout, and print what they're waiting on. AFD managed cert issuance can take 24–48 h — that
  step must be resumable across days, which is precisely why state is on disk.

## 7. Domain and the not-yet-existing CNAME

`--domain` is optional throughout. Two-phase by design, because AFD needs DNS before it will
issue a certificate:

**Phase A (now, no DNS):** deploy with no custom domain. Service is live and testable at
`https://<endpoint>.azurefd.net/<path>/index.m3u8`. `relay.yml` carries
`domain: null`. Everything works; only the hostname is ugly.

**Phase B (when `stream.orfe.princeton.edu` is available):** set `domain:` in `relay.yml`,
re-run `deploy.sh`. It adds the custom domain, then **prints a copy-pasteable DNS request
block** for whoever runs Princeton DNS:

```
TXT    _dnsauth.stream.orfe.princeton.edu   <validation-token>
CNAME  stream.orfe.princeton.edu            <endpoint>.azurefd.net
CAA    orfe.princeton.edu                   0 issue "digicert.com"   # if CAA is enforced
```

AFD requires **both** the `_dnsauth` TXT (ownership) and the CNAME. `deploy.sh` then polls
validation state and reports `Pending → Approved → Certificate issued`, resumable across days.
A `--print-dns-only` flag emits the block without touching anything, so the DNS ticket can be
filed before any Azure spend. `tools/check-dns.sh` verifies both records from the outside.

Design note: keep the `*.azurefd.net` hostname working permanently as a fallback, and have
`render-relay.py` emit whichever hostname is currently valid into `mdm/vlc.xml`. The Apple TVs
should never be the thing blocked on a DNS ticket.

## 8. GitOps, zero pipeline secrets

`stream-relay-config/.github/workflows/deploy.yml`, `runs-on: ubuntu-latest` (not the
self-hosted `orfe` runner — this targets Azure, not the display host):

```yaml
permissions: { id-token: write, contents: read }
steps:
  - uses: azure/login@v2
    with:
      client-id:       ${{ vars.AZURE_CLIENT_ID }}       # vars, not secrets
      tenant-id:       ${{ vars.AZURE_TENANT_ID }}
      subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}
```

- **GitHub → Azure:** user-assigned managed identity + federated identity credential scoped to
  `repo:pu-shd/stream-relay-config:environment:production`. No client secret exists. The three
  IDs are non-sensitive and live in `vars`. Avoid wildcard/flexible FIC subjects — GA status
  unconfirmed; enumerate branch + environment subjects explicitly.
- **VM → ACR:** the VM's UAMI plus `Container Registry Repository Reader` (the current
  ABAC-registry role; `AcrPull` on non-ABAC registries). `az login --identity` →
  `az acr login` → `docker pull`, no credentials on disk. A systemd timer refreshes the
  short-lived token. **Not GHCR** — GHCR has no managed-identity path and would force a stored
  PAT; CI pushes to ACR instead.
- **The one real secret**, SRT publish passphrases, lives in **Key Vault**, read at boot by the
  VM's managed identity. Nothing in a pipeline. The publisher side reuses
  `page-stream-config`'s existing repository secrets, which is the config repo, not a cloud
  pipeline — the stated constraint holds.
- `environment: production` with a required reviewer gates real spend behind a human click.

## 9. Optional pugwips integration

Gated on `pugwips.enabled: false` in `relay.yml` — **off by default**, since HLS is public by
default (decided). Entirely absent from the deployment when false, documented in the README as
optional with its own failure modes. It stays available as the lever to pull if the open
endpoint ever gets abused.

`pugwips` already resolves Princeton GlobalProtect gateway IPs, publishes them as a signed
`gateways.json` release, and ships both an `update_nsg` Function and an
`update-ip-restrictions.sh` example.

- **Ingest side:** NSG rule on `8890/udp` restricted to the runner host's egress IP + campus
  ranges + VPN gateway IPs. Reuse pugwips' `update_nsg`.
- **Egress side:** AFD WAF custom rule allowlisting campus + VPN IPs for `/`*`/index.m3u8`.
- **Refresh:** scheduled workflow following pugwips' own pattern, with its **fail-safe
  retained** — if `gateways.json` can't be fetched, keep existing rules rather than locking
  everyone out. Reading the release needs a token, which is why this is opt-in.
- A documented **break-glass** `scripts/allow-all.sh` for the case where the allowlist locks out
  the displays during an incident.

### 9b. Cost guardrails — required, because HLS is public by default

Choosing a public endpoint makes the egress downside **unbounded**: §2's ~$423/mo assumes 10
Apple TVs, but nothing stops a scraper from multiplying it. Public-by-default is fine *provided*
the blast radius is capped, so these are not optional:

- **AFD WAF custom rate-limit rule** — per-socket-IP request ceiling. Verified available on
  **Front Door Standard**; only managed rule sets (OWASP CRS) require Premium, so no tier
  upgrade is needed. Threshold is per 1- or 5-minute window; set it well above a legitimate
  LL-HLS player's segment cadence and alert before blocking.
- **Azure Budget + cost anomaly alert** on the resource group, provisioned by Bicep as part of
  the deployment rather than added by hand. Two thresholds: warn, then notify at a hard number.
- **A documented kill switch** — `scripts/restrict.sh` flips the endpoint to the campus + VPN
  allowlist immediately (the pugwips path, usable even with `pugwips.enabled: false` by falling
  back to the static campus ranges). This is the response to a bandwidth incident, and it must be
  tested in the rehearsal drill, not first attempted during one.
- `relay.yml` carries `egress.expected_viewers: 10` so `tools/size-vm.py` can print the projected
  bill and CI can flag a config whose declared viewers imply spend above a committed ceiling.

## 10. Testing (mock-first, containerized, no cloud spend in CI)

Per the standing preference for mocked tests and containerized suites:

1. **`tests/unit/`** — pytest over `render-relay.py`: `relay.yml` → `mediamtx.yml` / `.env` /
   `.bicepparam`; path-slug derivation; tier→SKU sizing; drift `--check`; rejects duplicate
   paths, missing `relay_path`, undersized `vm_size`.
2. **`tests/mock-az/`** — an `az` shim earlier on `PATH` returning canned JSON, so
   `bootstrap.sh` / `deploy.sh` / `update.sh` / `teardown.sh` run end-to-end offline. Asserts:
   correct `az` argv, **idempotency** (second run makes no mutating calls), **resumability**
   (kill at step *n*, `--resume`, converge), teardown ordering, and that `--soft` leaves
   ACR/KV/UAMI alive. This is where the resume logic actually gets proven.
3. **`tests/integration/`** — `docker-compose.local.yml` runs a real `mediamtx` + a real
   `page-stream` container publishing SRT to it, then ffprobe reads
   `http://mediamtx:8888/<path>/index.m3u8` and asserts a valid manifest, ≥2 segments, expected
   resolution, and non-zero frames. Also asserts the `runOnAvailable` hook fired for Tier 1.
   Runs in CI (no cloud), and doubles as the local dev loop.
4. **`tests/bicep/`** — `az bicep build` + `az deployment group what-if` against a
   throwaway RG, behind `LIVE=1` (mirroring the `LIVE=1` convention already in
   `page-stream-config`). Not in default CI.
5. **`tests/Dockerfile`** + `run-tests.sh` so the whole suite runs with nothing but Docker on
   the host, matching `orfe/tests/Dockerfile`.
6. **Scheduled rehearsal workflow** — quarterly: full deploy → integration assertions against
   the real endpoint → teardown → report. The only real defense against standby rot.

## 11. Cutover: one flag in page-stream-config

The fallback is worthless if activating it is an archaeology exercise. Add an ingest-profile
switch to the *existing* renderer:

```bash
python3 tools/render-config.py orfe --profile relay   # or: kaltura (default)
```

- `kaltura` → today's behavior: `*_INGEST` from `.env.secrets.sh`, `mdm/vlc.xml` carries Kaltura
  HLS URLs.
- `relay` → `*_INGEST` becomes `srt://stream-relay.../?streamid=publish:<path>:...`,
  `mdm/vlc.xml` carries `https://stream.orfe.princeton.edu/<path>/index.m3u8`.

`channels.yml` gains `relay_path:` per channel and keeps `entry_id:` — both profiles stay
described, so cutover is a flag flip plus a deploy, and reverting is the same. Existing
invariant tests extend to assert both profiles render completely.

**Runbook** (goes in the relay README, with measured timings from the rehearsal drill):
`bootstrap.sh --resume` → verify paths → `render-config.py orfe --profile relay` → deploy
page-stream stack → push MDM profile to Apple TVs → verify each display. Target: under 30
minutes with images pre-built in ACR, plus MDM propagation.

## 12. Build phases

| Phase | Deliverable | Cloud spend |
| :--- | :--- | :--- |
| **0** | Both repos created; skeleton; `relay.yml` schema; `render-relay.py` + unit tests; README outline | none |
| **1** | `docker-compose.local.yml` + integration suite; real page-stream → MediaMTX → HLS proven locally; transcode profiles for tiers 0–2 | none |
| **2** | Bicep modules; `bootstrap/deploy/update/teardown` + mock-az suite; first real deploy on `*.azurefd.net`; teardown verified | first real spend, torn down same day |
| **3** | UAMI + federated credential + ACR MI pull; GitOps `deploy.yml`; `environment: production` gate | ~$5/mo (ACR) |
| **4** | Domain phase A/B; `--print-dns-only`; DNS ticket filed for `stream.orfe.princeton.edu`; optional pugwips module | ~$5/mo |
| **5** | `render-config.py --profile relay` in page-stream-config; cutover runbook; quarterly rehearsal workflow; README complete | ~$5/mo standby |

Phases 0–1 are pure local work and worth doing regardless — they give a tested local SRT
target that beats the current `linuxserver/ffmpeg` `srt-test-listener` (which just writes `.ts`
files you inspect afterward) with something you can actually watch in a browser during
development. That's a standalone win even if Kaltura never goes anywhere.

## 13. Decisions (resolved 2026-07-29)

| # | Decision | Consequence |
| :--- | :--- | :--- |
| 1 | Repo names **`stream-relay`** / **`stream-relay-config`** | Engine-vs-config split by name, not tied to `page-stream`'s lifecycle |
| 2 | **10 Apple TVs** baseline | Egress model in §2 is concrete: ~$423/mo at 1500k. `egress.expected_viewers: 10` in `relay.yml` |
| 3 | **HLS public by default** | pugwips flips to opt-**out** (§9); §9b cost guardrails become mandatory |
| 4 | **Both repos private** | Split is structural, not a visibility boundary; pugwips module can live in the engine repo (§5) |
| 5 | **Cold standby** (~$5/mo) + quarterly rehearsal | `teardown.sh` and the rehearsal workflow are load-bearing (§2, §10.6) |

### Still open (not blocking)

- **Region.** `eastus` assumed for all pricing. If Princeton has a preferred Azure region or a
  data-residency constraint, `bootstrap.sh`'s region picker defaults change and pricing shifts
  slightly.
- **Reserved vs on-demand.** Irrelevant while cold; a 3-yr RI is −61% and only worth it if this
  ever stops being a standby.
- **Rate-limit threshold** (§9b) — pick after the rehearsal drill measures real LL-HLS request
  cadence per player, rather than guessing now.
