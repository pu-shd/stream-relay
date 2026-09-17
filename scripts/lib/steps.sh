#!/usr/bin/env bash
# The 16 deployment steps.
#
# ONE implementation, shared by bootstrap.sh (interactive prompting wrapper) and deploy.sh
# (non-interactive, CI-callable). Two code paths would mean two things to test and one of
# them would rot.
#
# EVERY STEP MUST:
#   1. Re-query Azure to decide whether work is needed (never trust the state file).
#   2. Be safe to run twice - a second run makes no mutating calls.
#   3. Write state only after verifying its own result.
#
# The mock-az suite asserts all three.

# Seven steps, down from seventeen.
#
# Ten were retired when the topology changed, not merely disabled: storage, front-door,
# discover-hostname and custom-domain belonged to a CDN delivery plane that no longer
# exists; acr and build-push-image to a custom image replaced by the upstream one with a
# bind-mounted entrypoint; identity, federated-credential, network and vm to resources this
# deployment now ADOPTS rather than creates. Their work is either gone or folded into the
# single Bicep deployment, which is idempotent on its own.
STEPS=(
  preflight
  register-providers
  resource-group
  passphrase
  infra
  configure
  verify
)

step_description() {
  case "$1" in
    preflight)          echo "Check tooling, login and role" ;;
    register-providers) echo "Register the resource providers this deployment uses" ;;
    resource-group)     echo "Confirm the resource group exists (never creates: it is shared)" ;;
    passphrase)         echo "Ensure the SRT passphrase exists in Key Vault" ;;
    infra)              echo "Deploy the NSG rules and the budget" ;;
    configure)          echo "Render the relay config on the VM and bring the stack up" ;;
    verify)             echo "Assert the deployment end to end" ;;
  esac
}

# --- helpers ---------------------------------------------------------------------------

# Every Azure mutation goes through this, so --dry-run is enforced in exactly one place
# rather than remembered at 40 call sites.
az_do() {
  if [ "${DRY_RUN:-0}" = "1" ]; then
    printf "    ${DIM}[dry-run] az %s${NC}\n" "$*"
    return 0
  fi
  az "$@"
}

az_query() { az "$@" 2>/dev/null; }

exists() { az "$@" >/dev/null 2>&1; }

require_env() {
  for var in "$@"; do
    [ -n "${!var:-}" ] || die "$var is not set. Is ${DEPT_DIR:-<dept>}/deploy.env present and sourced?"
  done
}

# --- steps -----------------------------------------------------------------------------

do_preflight() {
  local missing=0
  for tool in az docker jq; do
    if command -v "$tool" >/dev/null 2>&1; then
      ok "$tool present"
    else
      fail "$tool not found"
      missing=1
    fi
  done
  [ "$missing" -eq 0 ] || die "install the missing tools and re-run"

  az bicep version >/dev/null 2>&1 && ok "bicep present" || die "run: az bicep install"

  local account
  account=$(az_query account show -o json) || die "not logged in. Run: az login"
  local sub_id sub_name user
  sub_id=$(jq -r .id <<<"$account")
  sub_name=$(jq -r .name <<<"$account")
  user=$(jq -r .user.name <<<"$account")
  ok "subscription: $sub_name ($sub_id)"
  info "signed in as $user"

  if [ -n "${AZ_SUBSCRIPTION_ID:-}" ] && [ "$AZ_SUBSCRIPTION_ID" != "$sub_id" ]; then
    die "active subscription $sub_id does not match AZ_SUBSCRIPTION_ID=$AZ_SUBSCRIPTION_ID.
    Run: az account set --subscription $AZ_SUBSCRIPTION_ID"
  fi

  # Role check, keyed to whether THIS run creates role assignments.
  #
  # DEPLOY_ROLE_ASSIGNMENTS=1 is the one-time human bootstrap: it creates the RBAC and so
  # needs Owner or User Access Administrator. Everything afterwards (including every CI
  # deploy) runs with 0 and needs only Contributor - deliberately, because a principal that
  # can create role assignments can grant itself any role in the scope.
  # Scoped to the resource group, because that is where the roles are granted; an
  # unscoped list also misses nothing but costs a subscription-wide enumeration.
  local roles rg_scope
  rg_scope="/subscriptions/$sub_id/resourceGroups/${AZ_RESOURCE_GROUP:?}"
  roles=$(az_query role assignment list --assignee "$user" --scope "$rg_scope" \
    --include-inherited --query "[].roleDefinitionName" -o tsv || true)

  if [ "${DEPLOY_ROLE_ASSIGNMENTS:-0}" = "1" ]; then
    if grep -qE '^(Owner|User Access Administrator)$' <<<"$roles"; then
      ok "role permits creating role assignments (bootstrap mode)"
    else
      fail "you have: $(tr '\n' ',' <<<"$roles")"
      die "--with-role-assignments needs Owner or User Access Administrator.
    Contributor cannot create the RBAC this template establishes."
    fi
  else
    # NOT Contributor. The resource group is shared - it holds orfe-web-vm, its Key Vault,
    # vnet, disks and alerts - so Contributor there would permit deleting the machine the
    # relay runs on. The narrow pair is exactly what main.bicep deploys: Network
    # Contributor for the NSG (and Microsoft.Resources/deployments/*), Cost Management
    # Contributor for the budget.
    if grep -qE '^(Owner|Contributor)$' <<<"$roles"; then
      ok "role permits deploying (no RBAC changes in this run)"
    elif grep -qx 'Network Contributor' <<<"$roles" \
      && grep -qx 'Cost Management Contributor' <<<"$roles"; then
      ok "role permits deploying (narrow grant: Network + Cost Management Contributor)"
    elif [ -z "${roles//[[:space:]]/}" ]; then
      # Inconclusive, not negative. Listing role assignments needs
      # Microsoft.Authorization/*/read, and a principal can be perfectly able to deploy
      # while unable to enumerate its own grants. Dying here would block a deploy on a
      # check that proved nothing; the deployment itself fails clearly if it truly cannot.
      warn "could not enumerate role assignments for this principal at $rg_scope"
      detail "continuing: the deployment will fail plainly if the role is genuinely absent"
    else
      fail "you have: $(tr '\n' ',' <<<"$roles")"
      die "this principal cannot deploy. Grant either Contributor, or the narrow pair
    Network Contributor + Cost Management Contributor, on $AZ_RESOURCE_GROUP."
    fi

    # Fail CLOSED if the RBAC this deployment depends on was never established. Otherwise
    # a first-ever CI deploy would "succeed" and produce a VM that cannot read its own
    # passphrase from Key Vault - a failure that surfaces much later, as a dead stream.
    if [ "$(az_query group exists -n "${AZ_RESOURCE_GROUP:-}")" = "true" ] \
       && exists identity show -g "$AZ_RESOURCE_GROUP" -n "${AZ_IDENTITY_VM:-}"; then
      local vm_principal kv_roles
      vm_principal=$(az_query identity show -g "$AZ_RESOURCE_GROUP" -n "$AZ_IDENTITY_VM" \
        --query principalId -o tsv || true)
      kv_roles=$(az_query role assignment list --assignee "$vm_principal" --all \
        --query "[].roleDefinitionName" -o tsv || true)
      if grep -q 'Key Vault Secrets User' <<<"$kv_roles"; then
        ok "VM identity already holds Key Vault Secrets User"
      else
        die "the VM identity exists but has no 'Key Vault Secrets User' role.
    RBAC was never established, so the relay would start and fail to read its passphrase.
    Run the one-time bootstrap first:
        scripts/bootstrap.sh --with-role-assignments"
      fi
    fi
  fi

  # Capability checks, not role-name checks.
  #
  # The template ADOPTS the VM and the vault - it references both as `existing` - and
  # reading an existing resource needs read permission on it. No role name implies that:
  # Network Contributor and Cost Management Contributor between them cover everything this
  # deployment WRITES and nothing it READS, which is a combination that looks complete and
  # is not.
  #
  # `az deployment group what-if` does not catch it either. What-if computes a diff; it does
  # not evaluate authorization for resources the template merely reads, so it returns
  # success and the deployment then fails mid-flight with AuthorizationFailed. Asking the
  # question directly is the only cheap way to fail before anything is attempted.
  if [ -n "${AZ_VM_NAME:-}" ] && ! exists vm show -g "$AZ_RESOURCE_GROUP" -n "$AZ_VM_NAME"; then
    fail "cannot read the adopted VM $AZ_VM_NAME"
    die "the template references it as \`existing\`, so the deployment needs
    Microsoft.Compute/virtualMachines/read on it. Grant Reader scoped to the VM:

      az role assignment create --assignee-object-id <principal> \\
        --assignee-principal-type ServicePrincipal --role Reader \\
        --scope \$(az vm show -g $AZ_RESOURCE_GROUP -n $AZ_VM_NAME --query id -o tsv)"
  fi
  [ -n "${AZ_VM_NAME:-}" ] && ok "can read the adopted VM $AZ_VM_NAME"

  if [ -n "${AZ_KEY_VAULT:-}" ] && ! exists keyvault show -n "$AZ_KEY_VAULT"; then
    fail "cannot read the adopted Key Vault $AZ_KEY_VAULT"
    die "the template references it as \`existing\`. Grant Reader scoped to the vault."
  fi
  [ -n "${AZ_KEY_VAULT:-}" ] && ok "can read the adopted Key Vault $AZ_KEY_VAULT"

  # Quota for the *derived* size, not a hardcoded one.
  require_env AZ_REGION AZ_VM_SIZE AZ_VM_VCPU
  local family_used family_limit
  local family_json
  family_json=$(az_query vm list-usage -l "$AZ_REGION" -o json || echo '[]')
  # Match the family by the SKU's series letter+number, e.g. Standard_D4s_v6 -> Dsv6.
  local series
  series=$(sed -E 's/^Standard_([A-Za-z]+)[0-9]+([a-z]*)_(v[0-9]+)$/\1\2\3/' <<<"$AZ_VM_SIZE")
  family_limit=$(jq -r --arg s "$series" \
    '[.[] | select((.localName|ascii_downcase) | contains($s|ascii_downcase))][0].limit // empty' <<<"$family_json")
  family_used=$(jq -r --arg s "$series" \
    '[.[] | select((.localName|ascii_downcase) | contains($s|ascii_downcase))][0].currentValue // 0' <<<"$family_json")
  if [ -n "$family_limit" ]; then
    local available=$(( family_limit - family_used ))
    if [ "$available" -ge "$AZ_VM_VCPU" ]; then
      ok "quota: $AZ_VM_SIZE needs $AZ_VM_VCPU vCPU, $available available in $AZ_REGION"
    else
      die "quota: $AZ_VM_SIZE needs $AZ_VM_VCPU vCPU but only $available available in $AZ_REGION.
    Request an increase, or lower capacity.tier in relay.yml."
    fi
  else
    warn "could not determine family quota for $AZ_VM_SIZE; proceeding"
  fi

  if exists vm list-skus -l "$AZ_REGION" --size "$AZ_VM_SIZE" --query "[?name=='$AZ_VM_SIZE']" -o tsv; then
    local restrictions
    restrictions=$(az_query vm list-skus -l "$AZ_REGION" --size "$AZ_VM_SIZE" \
      --query "[?name=='$AZ_VM_SIZE'].restrictions[].reasonCode" -o tsv || true)
    [ -z "$restrictions" ] && ok "$AZ_VM_SIZE available in $AZ_REGION" \
      || die "$AZ_VM_SIZE is restricted in $AZ_REGION: $restrictions"
  fi

  state_record_output subscription_id "$sub_id"
  state_record_output operator_upn "$user"
}

do_register-providers() {
  # Microsoft.Cdn and Microsoft.ContainerRegistry are no longer here: Front Door and ACR
  # were both retired with the delivery-plane change.
  local needed=(Microsoft.Compute Microsoft.Network Microsoft.KeyVault
                Microsoft.ManagedIdentity Microsoft.Consumption)
  local to_register=()
  for ns in "${needed[@]}"; do
    local st
    st=$(az_query provider show -n "$ns" --query registrationState -o tsv || echo Unknown)
    if [ "$st" = "Registered" ]; then
      skipped "$ns already registered"
    else
      info "$ns is $st — registering"
      to_register+=("$ns")
      az_do provider register -n "$ns" >/dev/null
    fi
  done

  [ "${DRY_RUN:-0}" = "1" ] && return 0

  if [ ${#to_register[@]} -eq 0 ]; then
    ok "all providers already registered"
    return 0
  fi

  for ns in "${to_register[@]}"; do
    # Note the closing bracket: an earlier version omitted it, so the test never parsed
    # and the wait silently spun until timeout.
    wait_for "$ns registration" 300 bash -c \
      "[ \"\$(az provider show -n $ns --query registrationState -o tsv 2>/dev/null)\" = Registered ]" \
      || die "$ns did not reach Registered"
  done
  # Explicit success: a trailing '[ ... ] && ok' would make this function return 1 on the
  # path where providers WERE registered, and run_steps would record a false failure.
  return 0
}

do_resource-group() {
  require_env AZ_RESOURCE_GROUP
  # CONFIRMS. Never creates, and never deletes.
  #
  # orfe-dept-azure-rg is shared: it holds orfe-web-vm, that VM's Key Vault, vnet, disks and
  # alert rules, none of which this project created. An earlier version of this step created
  # the group when absent, which was right when the group was dedicated and is wrong now -
  # a missing group here means the config points somewhere unexpected, and inventing it
  # would scatter relay resources into a group nobody meant.
  if [ "$(az_query group exists -n "$AZ_RESOURCE_GROUP")" = "true" ]; then
    ok "resource group $AZ_RESOURCE_GROUP exists"
    return 0
  fi
  die "resource group $AZ_RESOURCE_GROUP does not exist.

  This deployment adopts existing resources and will not create the group. Either the
  configured name is wrong, or the group was deleted - in which case the VM, its vault and
  its disks went with it and this is a restore, not a deploy."
}


do_passphrase() { ensure_passphrase; }


# One `az deployment group create` for the whole template: the NSG rule set and the budget.
# ARM computes the diff, so re-running is inherently idempotent.
do_infra() { deploy_bicep "infra"; }


# identity, key-vault, acr, network, vm, front-door and guardrails are all created by the
# single Bicep deployment, which is itself idempotent. Splitting them into separate steps
# would mean reimplementing Bicep's dependency graph in bash.


# One `az deployment group create` for the whole template. ARM computes the diff, so
# re-running is inherently idempotent and a partially-failed deployment resumes correctly.
deploy_bicep() {
  require_env AZ_RESOURCE_GROUP
  # NOTE: --template-file is deliberately NOT passed.
  #
  # A .bicepparam names its own template in a `using` declaration, and the CLI resolves it
  # relative to the parameter file. Passing --template-file as well makes the CLI compare
  # the two paths TEXTUALLY and refuse when they differ - which they do the moment the same
  # file is reachable two ways, as in CI where the engine is checked out at ./engine and
  # symlinked to the sibling path the parameter file expects:
  #
  #   Bicep file .../engine/infra/main.bicep provided with --bicep-file option doesn't
  #   match the Bicep file .../stream-relay/infra/main.bicep referenced by the "using"
  #   declaration in the parameters file.
  #
  # Same file, same content, two spellings. Letting `using` be the single source avoids the
  # class entirely.
  local param_file="$DEPT_DIR/infra.bicepparam"
  [ -f "$param_file" ] || die "missing $param_file — run render-relay.py in the config repo"

  local operator_oid
  operator_oid=$(az_query ad signed-in-user show --query id -o tsv || echo "")

  # Azure REQUIRES a Linux VM to have either a password or an SSH key:
  #   InvalidParameter linuxConfiguration:
  #   "Authentication using either SSH or by user name and password must be enabled"
  # The intended posture - no inbound administrative path whatsoever - is therefore not
  # expressible. Closest equivalent: generate an EPHEMERAL keypair, hand Azure the public
  # half, and discard the private half. The NSG has no SSH rule, so there is no network path
  # to the port regardless; and because nobody holds the private key, opening that port by
  # accident still grants nobody access.
  #
  # Set SSH_PUBLIC_KEY yourself if you want a real break-glass path. Recovery otherwise is
  # Azure Run Command (RBAC-gated), or delete-and-redeploy - the VM is disposable by design:
  # its config comes from the config repo and its secret from Key Vault.
  if [ -z "${SSH_PUBLIC_KEY:-}" ]; then
    # The key must be STABLE across deployments. Azure rejects any change to
    # linuxConfiguration.ssh.publicKeys on an existing VM (PropertyChangeNotAllowed), so
    # generating a fresh ephemeral key each run made every redeploy fail against a live VM.
    # Order: reuse what the state file recorded, else read it back off the running VM, else
    # generate one.
    SSH_PUBLIC_KEY=$(state_get_output sshPublicKey || true)

    if [ -z "$SSH_PUBLIC_KEY" ] && [ "$(az_query group exists -n "${AZ_RESOURCE_GROUP:-}")" = "true" ]; then
      SSH_PUBLIC_KEY=$(az_query vm show -g "$AZ_RESOURCE_GROUP" -n "${AZ_VM_NAME:-}" \
        --query "osProfile.linuxConfiguration.ssh.publicKeys[0].keyData" -o tsv || true)
      [ -n "$SSH_PUBLIC_KEY" ] && info "reusing the existing VM's SSH key (Azure forbids changing it)"
    fi

    if [ -z "$SSH_PUBLIC_KEY" ]; then
      local ephemeral_key
      ephemeral_key=$(mktemp -u)
      ssh-keygen -t ed25519 -N '' -C 'stream-relay-ephemeral-discarded' -f "$ephemeral_key" >/dev/null 2>&1
      SSH_PUBLIC_KEY=$(cat "${ephemeral_key}.pub")
      shred -u "$ephemeral_key" 2>/dev/null || rm -f "$ephemeral_key"
      rm -f "${ephemeral_key}.pub"
      info "generated an ephemeral SSH key and discarded the private half"
      detail "Azure requires some Linux auth method; the NSG exposes no SSH port."
      detail "Set SSH_PUBLIC_KEY to keep a break-glass path instead."
    fi
    # Record it so the next deploy presents the SAME key rather than a new one.
    state_record_output sshPublicKey "$SSH_PUBLIC_KEY"
  fi

  # deployRoleAssignments defaults to false in the generated .bicepparam; only an explicit
  # bootstrap run overrides it to true.
  local rbac_param=()
  [ "${DEPLOY_ROLE_ASSIGNMENTS:-0}" = "1" ] && rbac_param=(--parameters "deployRoleAssignments=true")

  local args=(deployment group create
    --resource-group "$AZ_RESOURCE_GROUP"
    --name "stream-relay-$(date -u +%Y%m%d%H%M%S)"
    --parameters "$param_file"
    "${rbac_param[@]+"${rbac_param[@]}"}")
  [ -n "$operator_oid" ] && args+=(--parameters "operatorObjectId=$operator_oid")
  [ -n "${SSH_PUBLIC_KEY:-}" ] && args+=(--parameters "sshPublicKey=$SSH_PUBLIC_KEY")

  if [ "${DRY_RUN:-0}" = "1" ]; then
    if [ "$(az_query group exists -n "$AZ_RESOURCE_GROUP")" != "true" ]; then
      warn "skipping what-if: resource group $AZ_RESOURCE_GROUP does not exist"
      detail "The template still compiled cleanly (az bicep build)."
      detail "For a real what-if: scripts/deploy.sh --dry-run --allow-rg"
      return 0
    fi
    info "running what-if instead of deploying (--dry-run)"
    if ! az deployment group what-if \
      --resource-group "$AZ_RESOURCE_GROUP" \
      --parameters "$param_file" \
      "${rbac_param[@]+"${rbac_param[@]}"}" \
      ${operator_oid:+--parameters "operatorObjectId=$operator_oid"} \
      --no-pretty-print > "$REPO_ROOT/.what-if.json" 2>&1; then
      fail "what-if failed:"
      # azure-cli 2.88 crashes while rendering template errors ("The content for this
      # response was already consumed"), which buries the actual cause. When that happens,
      # fall back to `validate`, whose error path still works.
      if grep -q 'already consumed' "$REPO_ROOT/.what-if.json"; then
        warn "azure-cli could not render the error (known CLI bug) — retrying with validate"
        az deployment group validate \
          --resource-group "$AZ_RESOURCE_GROUP" \
          --parameters "$param_file" \
          ${operator_oid:+--parameters "operatorObjectId=$operator_oid"} \
          -o json > "$REPO_ROOT/.validate.json" 2>&1 || true
        tail -40 "$REPO_ROOT/.validate.json" >&2
      else
        tail -40 "$REPO_ROOT/.what-if.json" >&2
      fi
      return 1
    fi
    ok "what-if succeeded — see .what-if.json"
    return 0
  fi

  local out err_file
  err_file=$(mktemp)
  # stdout and stderr are captured SEPARATELY. Merging them (2>&1) meant Bicep's
  # "WARNING: A new Bicep release is available" lines landed inside the JSON, so every
  # `jq` read of the deployment outputs failed silently and nothing was recorded - which
  # surfaced much later as "no ingest IP in state".
  if ! out=$(az "${args[@]}" -o json 2>"$err_file"); then
    out="$out$(cat "$err_file")"
    # Azure refuses to change cloud-init on an existing VM:
    #   PropertyChangeNotAllowed: Changing property 'osProfile.customData' is not allowed.
    # Any edit to the cloud-init block therefore requires REPLACING the VM. That is cheap
    # here by design - the VM holds no state, its config comes from the config repo and its
    # secret from Key Vault - but the deployment cannot do it implicitly, because deleting
    # someone's running relay as a side effect of a template edit would be unforgivable.
    if grep -q "osProfile.customData" <<<"$out"; then
      fail "the VM's cloud-init changed, and Azure does not permit that on an existing VM"
      info "the VM is disposable (no state on it). Recreate it with:"
      detail "az vm delete -g $AZ_RESOURCE_GROUP -n $AZ_VM_NAME --yes"
      detail "scripts/deploy.sh --from identity"
      die "refusing to delete a running VM implicitly"
    fi
    printf '%s\n' "$out" | tail -20 >&2
    rm -f "$err_file"
    die "bicep deployment failed"
  fi
  rm -f "$err_file"
  for key in frontDoorHostName ingestIpAddress acrLoginServer keyVaultName \
             ciIdentityClientId vmIdentityClientId storageAccountName staticWebsiteHostName; do
    local v
    v=$(jq -r --arg k "$key" '.properties.outputs[$k].value // empty' <<<"$out")
    [ -n "$v" ] && state_record_output "$key" "$v"
  done
  ok "bicep deployment complete"
}

# The passphrase is generated here rather than by a human, so it always conforms to the
# entrypoint's constraints (10-79 chars, [A-Za-z0-9_-]). Written via --file so it never
# appears in an `az` argv, which is visible in process listings.
ensure_passphrase() {
  require_env AZ_KEY_VAULT SRT_PASSPHRASE_SECRET
  if [ "${DRY_RUN:-0}" = "1" ]; then
    info "[dry-run] would ensure secret $SRT_PASSPHRASE_SECRET exists in $AZ_KEY_VAULT"
    return 0
  fi
  if exists keyvault secret show --vault-name "$AZ_KEY_VAULT" --name "$SRT_PASSPHRASE_SECRET"; then
    skipped "passphrase already present in $AZ_KEY_VAULT"
    return 0
  fi
  local tmp
  tmp=$(mktemp)
  chmod 600 "$tmp"
  openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 40 > "$tmp"
  az keyvault secret set --vault-name "$AZ_KEY_VAULT" --name "$SRT_PASSPHRASE_SECRET" \
    --file "$tmp" -o none || { rm -f "$tmp"; die "could not store the passphrase"; }
  rm -f "$tmp"
  ok "generated and stored a 40-character passphrase (never echoed, never in argv)"
}

do_configure() {
  require_env AZ_VM_NAME
  local tmpl="$DEPT_DIR/mediamtx.yml.tmpl"
  [ -f "$tmpl" ] || die "missing $tmpl"

  # Convergence runs ON the relay host, not remotely.
  #
  # The alternative is `az vm run-command` from wherever this script happens to run, which
  # means granting the deploying principal Microsoft.Compute/virtualMachines/runCommand -
  # arbitrary root command execution on the VM. That is a larger privilege than everything
  # else this deployment holds combined, and CI does not get it. The self-hosted runner on
  # the host does this step instead, through one audited script.
  if [ ! -x /usr/local/bin/relay-apply.sh ]; then
    skipped "not running on the relay host; convergence is the self-hosted runner's job"
    detail "this host has no /usr/local/bin/relay-apply.sh, so there is nothing to apply"
    return 0
  fi

  if [ "${DRY_RUN:-0}" = "1" ]; then
    info "[dry-run] would stage the generated config and run relay-apply.sh"
    return 0
  fi

  local stage=/opt/stream-relay-staging
  install -m 0644 "$DEPT_DIR/docker-compose.yml" "$stage/docker-compose.yml"
  install -m 0644 "$DEPT_DIR/nginx.conf"         "$stage/nginx.conf"
  install -m 0644 "$tmpl"                        "$stage/mediamtx.yml.tmpl"

  local out
  if out=$(sudo -n /usr/local/bin/relay-apply.sh 2>&1); then
    ok "relay converged: $(grep -o 'RELAY_HEALTHY.*' <<<"$out" || echo healthy)"
  else
    printf '%s\n' "$out" | sed 's/^/      /'
    die "relay-apply.sh failed; the stack is not healthy"
  fi
}


do_verify() {
  if [ "${SKIP_VERIFY:-0}" = "1" ]; then
    skipped "--no-verify: run scripts/verify.sh separately"
    return 0
  fi
  if [ "${DRY_RUN:-0}" = "1" ]; then
    info "[dry-run] would run scripts/verify.sh against the deployed endpoint"
    return 0
  fi
  "$REPO_ROOT/scripts/verify.sh"
}

# --- runner ----------------------------------------------------------------------------

is_valid_step() {
  local candidate="$1"
  for s in "${STEPS[@]}"; do [ "$s" = "$candidate" ] && return 0; done
  return 1
}

run_steps() {
  local total=${#STEPS[@]} index=0

  # Validate step names up front. A typo would otherwise match nothing and the run would
  # "succeed" having done absolutely nothing, which is the worst possible outcome for a
  # script whose whole job is to converge infrastructure.
  if [ -n "${ONLY_STEP:-}" ] && ! is_valid_step "$ONLY_STEP"; then
    fail "unknown step: $ONLY_STEP"
    info "valid steps: ${STEPS[*]}"
    return 1
  fi
  if [ -n "${FROM_STEP:-}" ] && ! is_valid_step "$FROM_STEP"; then
    fail "unknown step: $FROM_STEP"
    info "valid steps: ${STEPS[*]}"
    return 1
  fi
  for step in "${STEPS[@]}"; do
    index=$(( index + 1 ))

    if [ -n "${ONLY_STEP:-}" ] && [ "$step" != "$ONLY_STEP" ]; then continue; fi
    if [ -n "${FROM_STEP:-}" ] && [ "${_reached_from:-0}" != "1" ]; then
      if [ "$step" = "$FROM_STEP" ]; then _reached_from=1; else continue; fi
    fi

    step_header "$index" "$total" "$step — $(step_description "$step")"

    if [ "${RESUME:-0}" = "1" ] && state_is_done "$step"; then
      skipped "already recorded done (--resume); re-run with --step $step to force"
      continue
    fi

    if ! "do_$step"; then
      state_mark "$step" "failed"
      printf "\n"
      fail "step '$step' failed"
      info "resume with: $(basename "$0") --from $step"
      return 1
    fi
    [ "${DRY_RUN:-0}" = "1" ] || state_mark "$step" "done"
  done
}
