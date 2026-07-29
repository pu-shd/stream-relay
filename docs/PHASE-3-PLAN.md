# Phase 3 — GitOps deployment with no stored credentials

Phase 2 made the relay deployable from a laptop. Phase 3 makes it deployable from GitHub
Actions **without a single stored credential**, and — more importantly — without handing a
CI workflow the ability to grant itself arbitrary Azure permissions.

Two findings from inspecting the Phase 2 output change the shape of this work. Both are
security-relevant, so they lead.

---

## 1. Finding: as designed, CI would need privilege-escalation rights

`main.bicep` creates **three role assignments** (`acr.bicep` → AcrPull, `keyvault.bicep` →
Secrets User and Secrets Officer). Creating a role assignment requires **User Access
Administrator or Owner** on the scope.

So if the GitHub Actions identity runs the deployment as written, that identity must be able
to create role assignments — which means a compromised workflow (a malicious PR to a
workflow file, a compromised action, a bad `npm`-style dependency in a step) can grant itself
or any other principal **any role within the resource group**. For a service whose whole
purpose is standing by unattended, that is the wrong default.

### Fix: separate the control plane from the data plane

Add a `deployRoleAssignments bool = false` parameter to `main.bicep`, threaded into the
modules that create assignments.

| Runner | Sets | Needs | Creates RBAC? |
| :--- | :--- | :--- | :--- |
| **Human bootstrap** (once, `scripts/bootstrap.sh`) | `deployRoleAssignments=true` | Owner / UAA | yes |
| **CI** (`deploy.yml`, every deploy thereafter) | `deployRoleAssignments=false` | **Contributor only** | no |

RBAC is established once by a human who already has Owner, and every subsequent automated
deployment converges the infrastructure with no ability to touch permissions. This costs
nothing in convenience — role assignments are idempotent and do not change between deploys —
and removes the escalation path entirely.

`preflight` gains a matching check: when `deployRoleAssignments=true` it requires Owner/UAA
(as today); when `false` it requires only Contributor, and **fails closed** if the expected
role assignments are absent, with a message pointing at the one-time bootstrap. Otherwise a
first-ever CI deploy would succeed and produce a VM that cannot read its own passphrase.

## 2. Finding: one identity is doing two jobs with the wrong permissions

Today a single UAMI (`id-orfe-relay`) is used for **both** the GitHub federated credential
and the VM's ACR pull, and it holds only **AcrPull**. That is wrong in both directions:

- **Too little for CI.** `build-push-image` runs `az acr build`, which needs push and
  task-run rights — `AcrPush` at minimum, `Contributor` on the registry in practice. It would
  fail at step 8.
- **Too much for the VM.** The VM sits on a public IP with an internet-facing UDP listener.
  If it is compromised, its identity should not be able to deploy infrastructure or push
  images that the VM itself will later execute.

### Fix: two identities, least privilege each

| Identity | Used by | Roles | Scope |
| :--- | :--- | :--- | :--- |
| `id-orfe-relay-vm` | the VM only | `AcrPull`, `Key Vault Secrets User` | ACR, Key Vault |
| `id-orfe-relay-ci` | GitHub Actions only (federated) | `Contributor`, `AcrPush` | resource group, ACR |

Only `-ci` carries a federated credential; only `-vm` is attached to the VM. Neither can do
the other's job. A leaked VM identity cannot redeploy or poison the image; a compromised
workflow cannot read the SRT passphrase.

> Note on ABAC: Microsoft now leads with `Container Registry Repository Reader`/`Writer` for
> ABAC-enabled registries, with `AcrPull`/`AcrPush` remaining valid for non-ABAC ones. A Basic
> SKU registry created by this template is non-ABAC, so the classic roles apply — but
> `preflight` should assert the pull actually works rather than assuming the role name.

## 3. The federated credentials

Already present in `identity.bicep`, and both subjects are required — they are not
redundant:

| Subject | Sent when |
| :--- | :--- |
| `repo:pu-orfe/stream-relay-config:environment:production` | a job declares `environment: production` |
| `repo:pu-orfe/stream-relay-config:ref:refs/heads/main` | a job on `main` with **no** environment |

GitHub sends exactly one `sub` per job, and the environment form **replaces** the ref form
rather than adding to it. The deploy job uses the environment (so it inherits the reviewer
gate); the read-only what-if job does not. Wildcard/"flexible" subjects are deliberately
avoided — their GA status is unconfirmed, and a wildcard subject is the one mistake that
would let any branch assume the CI identity.

Auth wiring, with the three IDs as **`vars`, not `secrets`** — they are not sensitive, and
putting them in `secrets` only obscures diffs:

```yaml
permissions: { id-token: write, contents: read }
steps:
  - uses: azure/login@v2
    with:
      client-id:       ${{ vars.AZURE_CLIENT_ID }}
      tenant-id:       ${{ vars.AZURE_TENANT_ID }}
      subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}
```

## 4. Workflows to add (in `stream-relay-config`)

The repo currently has only `tests.yml`, and **no environments exist yet**.

### `deploy.yml` — `workflow_dispatch` only

Never on push. A cold standby that redeploys itself because someone edited a comment is a
cost incident waiting to happen.

```
job 1  plan     ubuntu-latest, no environment  → render --check, az bicep build,
                                                  deploy.sh --dry-run  (read-only, $0)
job 2  deploy   environment: production        → deploy.sh --resume --no-verify
                 (required reviewer gate)
job 3  verify   environment: production        → verify.sh
```

Splitting `plan` from `deploy` means the reviewer approving real spend sees a what-if diff
first. `verify` is a separate job so a deployment that comes up broken is visibly red rather
than buried in deploy logs — and `--no-verify` already exists for exactly this.

### `teardown.yml` — `workflow_dispatch`, typed confirmation

The cost model depends on teardown actually happening, so it must be as easy as deploying.
Requires typing the resource-group name as an input (mirroring `teardown.sh`), and defaults
to `--soft`.

### `plan.yml` — `pull_request`

Read-only what-if on PRs that touch `relay.yml` or `infra/`, posting the diff as a comment.
No environment, no write access, so it is safe on untrusted PRs — but note it must **not**
run on `pull_request_target` and must not check out PR head with the CI identity available.

### GitHub environment: `production`

Created with a **required reviewer**. This is the human gate on real spend; the OIDC subject
also depends on it, so it is load-bearing rather than decorative.

## 5. Cost, and the approval boundary

Phase 3 cannot be fully proven at $0: exercising the OIDC chain requires the identity, ACR
and Key Vault to exist. ACR Basic is **~$5/month**; identities, Key Vault (standard, a single
secret) and role assignments are free or negligible.

Proposed staging, so the spend decision stays explicit:

| Stage | Work | Cost |
| :--- | :--- | :--- |
| **3a** | Split identities, `deployRoleAssignments`, all three workflows, mock-az CI scenarios, actionlint, secret-scanning check. Validate with `--dry-run --allow-rg` and the offline suite. | **$0** |
| **3b** | Human bootstrap creates identity + ACR + Key Vault; set the three `vars`; run `deploy.yml`'s `plan` job to prove the OIDC chain end to end. | **~$5/mo** |
| **3c** | Full `deploy.yml` run creating the VM and Front Door, then `teardown.yml --soft`. | ~$1–2 one-off |

**Recommendation: do 3a now and stop.** It is the majority of the work, it is all reviewable,
and it leaves the spend decision — and the privilege-escalation review above — to a separate
explicit approval.

## 6. Testing

The constraint "no secrets in cloud deployment pipelines" should be **mechanically enforced**,
not merely intended. Otherwise it degrades the first time someone hits an auth problem at
11pm and pastes in a client secret.

- **`actionlint`** on all workflows, in both repos' CI.
- **No-Azure-secret assertion**: fail if any workflow references a secret for Azure auth
  (`client-secret`, `AZURE_CREDENTIALS`, `ARM_CLIENT_SECRET`, `creds:`). This is the test that
  keeps the design honest.
- **Permissions assertion**: every workflow declares an explicit top-level `permissions:`
  block, and only the deploy/verify jobs carry `id-token: write`.
- **No `pull_request_target`** anywhere, and no `workflow_dispatch`-less `deploy.yml`.
- **New mock-az scenarios**: `contributor-only` must now *succeed* with
  `deployRoleAssignments=false` (it currently fails closed for Owner), and must fail with a
  pointer to bootstrap when the expected role assignments are missing.
- **Two-identity assertions** in `tests/bicep`: the VM identity has no `Contributor`, the CI
  identity is not attached to the VM, and only the CI identity has federated credentials.

## 7. Risks

| Risk | Mitigation |
| :--- | :--- |
| Compromised workflow escalates privileges | `deployRoleAssignments=false` in CI; Contributor only; RBAC established once by a human (§1) |
| Compromised VM deploys or poisons images | Separate `-vm` identity with no RG or push rights (§2) |
| Wildcard FIC subject lets any branch deploy | Subjects enumerated explicitly; a test asserts no `*` appears in any FIC |
| Someone "fixes" auth by adding a client secret | CI fails on any Azure-auth secret reference (§6) |
| Reviewer approves a deploy without seeing the diff | `plan` job runs what-if before the gated `deploy` job (§4) |
| A first CI deploy silently produces a VM that cannot read its passphrase | `preflight` fails closed when expected role assignments are absent (§1) |
| Standby quietly becomes a running service | `teardown.yml` is as easy as deploy; §5 keeps 3c explicitly separate |

## 8. Deliverables (stage 3a)

- [ ] `deployRoleAssignments` parameter threaded through `main.bicep`, `acr.bicep`, `keyvault.bicep`
- [ ] Split `identity.bicep` into `-vm` and `-ci` identities; `AcrPush` + `Contributor` for CI
- [ ] `preflight` role logic keyed to `deployRoleAssignments`, failing closed on missing RBAC
- [ ] `stream-relay-config/.github/workflows/{deploy,teardown,plan}.yml`
- [ ] `production` environment with a required reviewer
- [ ] `bootstrap.sh --print-gitops-vars` emitting the three IDs to set
- [ ] actionlint + no-Azure-secret + permissions assertions in both repos' CI
- [ ] New mock-az scenarios; two-identity Bicep assertions
- [ ] `az bicep build` clean; `--dry-run --allow-rg` clean; offline suite green
- [ ] README Status table updated; security model section rewritten for two identities

## 9. Out of scope

- pugwips allowlist (Phase 4)
- `stream.orfe.princeton.edu` custom domain (Phase 4) — though the DNS request can be filed
  at any time and is not blocked by any of this
- `render-config.py --profile relay` cutover flag and the quarterly rehearsal workflow
  (Phase 5)
- The unresolved cross-repo CI token, which still leaves three agreement tests skipping

## 10. Decisions needed

1. **Two identities, or one with broader rights?** Recommendation: two (§2). One identity is
   simpler but gives an internet-facing VM the ability to redeploy itself.
2. **Stop after 3a ($0), or continue to 3b (~$5/mo) to prove the OIDC chain?**
3. **Who is the required reviewer** on the `production` environment? If it is only ever the
   same person who triggers the deploy, the gate is documentation rather than control.
