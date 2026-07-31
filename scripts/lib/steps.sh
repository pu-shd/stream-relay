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

STEPS=(
  preflight
  register-providers
  resource-group
  identity
  federated-credential
  key-vault
  acr
  storage
  build-push-image
  network
  vm
  configure-vm
  front-door
  discover-hostname
  guardrails
  custom-domain
  verify
)

step_description() {
  case "$1" in
    preflight)            echo "Check tooling, login, role, quota and providers" ;;
    register-providers)   echo "Register Microsoft.Cdn and friends" ;;
    resource-group)       echo "Create the resource group" ;;
    identity)             echo "Create the user-assigned managed identity" ;;
    federated-credential) echo "Trust GitHub Actions via OIDC (no secret)" ;;
    key-vault)            echo "Create the vault and store the SRT passphrase" ;;
    acr)                  echo "Create the registry and grant pull to the identity" ;;
    storage)              echo "Enable static-website hosting on the delivery account" ;;
    build-push-image)     echo "Build the relay image and push it to ACR" ;;
    network)              echo "Create vnet, NSG and the STATIC public IP" ;;
    vm)                   echo "Create the relay VM with its managed identity" ;;
    configure-vm)         echo "Deliver the config template and start MediaMTX" ;;
    front-door)           echo "Create Front Door, cache rules and the WAF rate limit" ;;
    discover-hostname)    echo "Read the real hostname and write it into relay.yml" ;;
    guardrails)           echo "Provision the budget and forecast alerts" ;;
    custom-domain)        echo "Add the custom domain and print the DNS request" ;;
    verify)               echo "Assert the deployment end to end" ;;
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
  local roles
  roles=$(az_query role assignment list --assignee "$user" --include-inherited \
    --query "[].roleDefinitionName" -o tsv || true)

  if [ "${DEPLOY_ROLE_ASSIGNMENTS:-0}" = "1" ]; then
    if grep -qE '^(Owner|User Access Administrator)$' <<<"$roles"; then
      ok "role permits creating role assignments (bootstrap mode)"
    else
      fail "you have: $(tr '\n' ',' <<<"$roles")"
      die "--with-role-assignments needs Owner or User Access Administrator.
    Contributor cannot create the RBAC this template establishes."
    fi
  else
    if grep -qE '^(Owner|Contributor|User Access Administrator)$' <<<"$roles"; then
      ok "role permits deploying (no RBAC changes in this run)"
    else
      fail "you have: $(tr '\n' ',' <<<"$roles")"
      die "Contributor (or higher) on the resource group is required."
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
  # Microsoft.Cdn was NotRegistered on ORFE-dept-azure. Without this step the whole
  # deployment runs to step 12 and then fails on Front Door.
  local needed=(Microsoft.Cdn Microsoft.Compute Microsoft.Network Microsoft.KeyVault
                Microsoft.ManagedIdentity Microsoft.ContainerRegistry Microsoft.Consumption)
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
  require_env AZ_RESOURCE_GROUP AZ_REGION
  if [ "$(az_query group exists -n "$AZ_RESOURCE_GROUP")" = "true" ]; then
    skipped "resource group $AZ_RESOURCE_GROUP already exists"
    return 0
  fi

  # A resource group costs nothing and holds nothing, but `az deployment group what-if`
  # cannot run without one. So --dry-run alone reports the limitation, and --allow-rg
  # opts into creating just the (free) group so the what-if is actually meaningful.
  if [ "${DRY_RUN:-0}" = "1" ] && [ "${ALLOW_RG:-0}" != "1" ]; then
    warn "resource group $AZ_RESOURCE_GROUP does not exist, and --dry-run will not create it"
    detail "what-if is scoped to a resource group, so it cannot run without one."
    detail "Re-run with --allow-rg to create the (free, empty) group and get a real what-if."
    return 0
  fi

  az group create -n "$AZ_RESOURCE_GROUP" -l "$AZ_REGION" \
    --tags project=stream-relay managed-by=stream-relay posture=cold-standby >/dev/null
  # An earlier version reported "created" even on the dry-run path, which was simply
  # untrue. Only claim it after actually doing it.
  if [ "${DRY_RUN:-0}" = "1" ]; then
    ok "created resource group $AZ_RESOURCE_GROUP (empty and free; --allow-rg)"
  else
    ok "created resource group $AZ_RESOURCE_GROUP"
  fi
}

# identity, key-vault, acr, network, vm, front-door and guardrails are all created by the
# single Bicep deployment, which is itself idempotent. Splitting them into separate steps
# would mean reimplementing Bicep's dependency graph in bash.
do_identity()             { deploy_bicep "identity"; }
do_federated-credential() { skipped "created by the Bicep deployment (identity module)"; }
do_key-vault()            { ensure_passphrase; }
do_acr()                  { skipped "created by the Bicep deployment (acr module)"; }

do_storage() {
  require_env AZ_STORAGE_ACCOUNT
  if [ "${DRY_RUN:-0}" = "1" ]; then
    info "[dry-run] would enable static-website hosting on $AZ_STORAGE_ACCOUNT"
    return 0
  fi

  # Static-website hosting is a DATA-PLANE property, not an ARM one: there is no Bicep or
  # template equivalent, so it has to be switched on with a CLI call after the account
  # exists. Miss this and the $web endpoint 404s everything while every resource looks
  # perfectly healthy in the portal.
  local enabled
  enabled=$(az_query storage blob service-properties show \
    --account-name "$AZ_STORAGE_ACCOUNT" --auth-mode login \
    --query "staticWebsite.enabled" -o tsv || echo "")

  if [ "$enabled" = "true" ]; then
    skipped "static-website hosting already enabled"
  else
    # --auth-mode login because the account has shared-key access disabled: there is no
    # account key to fall back on, by design.
    az_do storage blob service-properties update \
      --account-name "$AZ_STORAGE_ACCOUNT" --auth-mode login \
      --static-website true \
      --index-document index.m3u8 \
      --404-document index.m3u8 -o none \
      || die "could not enable static-website hosting on $AZ_STORAGE_ACCOUNT.
    This needs 'Storage Blob Data Contributor' (or Owner) on the account for YOUR account,
    not just the VM identity, because it is a data-plane call."
    ok "enabled static-website hosting"
  fi

  local host
  host=$(az_query storage account show -n "$AZ_STORAGE_ACCOUNT" \
    --query "primaryEndpoints.web" -o tsv || echo "")
  [ -n "$host" ] && info "delivery origin: $host"
  state_record_output staticWebsiteEndpoint "$host"
  return 0
}
do_network()              { skipped "created by the Bicep deployment (network module)"; }
do_vm()                   { skipped "created by the Bicep deployment (vm module)"; }
do_front-door()           { skipped "created by the Bicep deployment (frontdoor module)"; }
do_guardrails()           { skipped "created by the Bicep deployment (guardrails module)"; }

# One `az deployment group create` for the whole template. ARM computes the diff, so
# re-running is inherently idempotent and a partially-failed deployment resumes correctly.
deploy_bicep() {
  require_env AZ_RESOURCE_GROUP
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

  # deployRoleAssignments defaults to false in the generated .bicepparam; only an explicit
  # bootstrap run overrides it to true.
  local rbac_param=()
  [ "${DEPLOY_ROLE_ASSIGNMENTS:-0}" = "1" ] && rbac_param=(--parameters "deployRoleAssignments=true")

  local args=(deployment group create
    --resource-group "$AZ_RESOURCE_GROUP"
    --name "stream-relay-$(date -u +%Y%m%d%H%M%S)"
    --template-file "$REPO_ROOT/infra/main.bicep"
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
      --template-file "$REPO_ROOT/infra/main.bicep" \
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
          --template-file "$REPO_ROOT/infra/main.bicep" \
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

  local out
  out=$(az "${args[@]}" -o json) || die "bicep deployment failed"
  for key in frontDoorHostName ingestIpAddress acrLoginServer keyVaultName identityClientId; do
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

do_build-push-image() {
  require_env AZ_ACR_NAME
  if [ "${DRY_RUN:-0}" = "1" ]; then
    info "[dry-run] would build and push stream-relay-mediamtx to $AZ_ACR_NAME"
    return 0
  fi
  docker info >/dev/null 2>&1 || die "Docker daemon is not running"
  # ACR build runs server-side, so no local docker push and no cross-architecture surprise
  # from building on an arm64 Mac for an amd64 VM.
  az_do acr build --registry "$AZ_ACR_NAME" \
    --image "stream-relay-mediamtx:latest" \
    --platform linux/amd64 \
    "$REPO_ROOT/docker/mediamtx" >/dev/null
  ok "image built in ACR for linux/amd64"
}

do_configure-vm() {
  require_env AZ_RESOURCE_GROUP AZ_VM_NAME
  local tmpl="$DEPT_DIR/mediamtx.yml.tmpl"
  [ -f "$tmpl" ] || die "missing $tmpl"
  if [ "${DRY_RUN:-0}" = "1" ]; then
    info "[dry-run] would upload $(basename "$tmpl") and start stream-relay.service"
    return 0
  fi
  # Run Command rather than SSH: there is no inbound SSH rule in the NSG by design.
  local encoded
  encoded=$(base64 < "$tmpl" | tr -d '\n')

  # Wait for cloud-init BEFORE touching the service. Starting it early raced cloud-init's
  # Azure CLI install and died with "az: command not found", while this step still reported
  # success - a deployment that looks green with the relay down.
  info "waiting for cloud-init to finish on the VM (docker + az install)"
  local ci_status=""
  local _i
  for _i in $(seq 1 40); do
    ci_status=$(az_query vm run-command invoke -g "$AZ_RESOURCE_GROUP" -n "$AZ_VM_NAME" \
      --command-id RunShellScript --scripts "cloud-init status 2>/dev/null | head -1" \
      --query "value[0].message" -o tsv 2>/dev/null | grep -o 'status: [a-z]*' | head -1 || true)
    case "$ci_status" in
      *done|*disabled) break ;;
      *error) die "cloud-init failed on the VM; inspect with:
    az vm run-command invoke -g $AZ_RESOURCE_GROUP -n $AZ_VM_NAME --command-id RunShellScript \\
      --scripts 'cloud-init status --long; journalctl -u cloud-final --no-pager | tail -40'" ;;
    esac
    sleep 15
  done
  unset _i
  ok "cloud-init: ${ci_status:-unknown}"

  # Run Command rather than SSH: there is no inbound SSH rule in the NSG by design.
  local result
  result=$(az vm run-command invoke -g "$AZ_RESOURCE_GROUP" -n "$AZ_VM_NAME" \
    --command-id RunShellScript \
    --scripts "set -e
mkdir -p /etc/stream-relay/config
echo '$encoded' | base64 -d > /etc/stream-relay/config/mediamtx.yml.tmpl
systemctl restart stream-relay.service || true
for i in \$(seq 1 24); do
  if docker ps --filter name=stream-relay --filter health=healthy --format '{{.Names}}' | grep -q stream-relay; then
    echo RELAY_HEALTHY; break
  fi
  sleep 5
done
echo \"service=\$(systemctl is-active stream-relay)\"
docker ps --filter name=stream-relay --format '{{.Status}}' || true
journalctl -u stream-relay --no-pager -n 12 2>&1 | tail -12" \
    --query "value[0].message" -o tsv 2>&1)

  if grep -q 'RELAY_HEALTHY' <<<"$result"; then
    ok "config delivered; MediaMTX container is healthy"
    return 0
  fi

  fail "the relay did not become healthy after config delivery"
  printf '%s\n' "$result" | sed 's/^/      /' >&2
  die "configure-vm failed. Common causes: Key Vault RBAC still propagating (retry the step),
    or the image tag missing from ACR (re-run --step build-push-image)."
}

do_discover-hostname() {
  require_env AZ_RESOURCE_GROUP AZ_FRONTDOOR_PROFILE AZ_FRONTDOOR_ENDPOINT
  if [ "${DRY_RUN:-0}" = "1" ]; then
    info "[dry-run] would read the Front Door hostname and write it into relay.yml"
    return 0
  fi
  local host
  host=$(az_query afd endpoint show -g "$AZ_RESOURCE_GROUP" \
    --profile-name "$AZ_FRONTDOOR_PROFILE" --endpoint-name "$AZ_FRONTDOOR_ENDPOINT" \
    --query hostName -o tsv)
  [ -n "$host" ] || die "could not read the Front Door hostname"

  # Sanity-check the shape. A bare '<endpoint>.azurefd.net' would mean Azure changed its
  # naming, and silently accepting it would resurrect the very bug this step exists for.
  case "$host" in
    "$AZ_FRONTDOOR_ENDPOINT.azurefd.net")
      die "Front Door returned the un-hashed form '$host', which contradicts the documented
    <endpoint>-<hash>.z01.azurefd.net format. Investigate before trusting it." ;;
    *.azurefd.net) ok "discovered hostname: $host" ;;
    *) die "unexpected hostname from Front Door: $host" ;;
  esac

  local config_repo="${CONFIG_REPO:-$REPO_ROOT/../stream-relay-config}"
  if [ -f "$config_repo/tools/render-relay.py" ]; then
    (cd "$config_repo" && python3 tools/render-relay.py "$DEPT" --set-frontdoor-hostname "$host") \
      || warn "could not update relay.yml automatically; set azure.frontdoor_hostname to $host"
  else
    warn "config repo not found; set azure.frontdoor_hostname to $host by hand"
  fi
  state_record_output frontDoorHostName "$host"
}

do_custom-domain() {
  if [ -z "${RELAY_CUSTOM_DOMAIN:-}" ]; then
    skipped "no custom domain configured (Phase A) — serving on the Front Door hostname"
    return 0
  fi
  require_env AZ_RESOURCE_GROUP AZ_FRONTDOOR_PROFILE
  local domain_res="${RELAY_CUSTOM_DOMAIN//./-}"
  local token state
  token=$(az_query afd custom-domain show -g "$AZ_RESOURCE_GROUP" \
    --profile-name "$AZ_FRONTDOOR_PROFILE" --custom-domain-name "$domain_res" \
    --query validationProperties.validationToken -o tsv || echo "")
  state=$(az_query afd custom-domain show -g "$AZ_RESOURCE_GROUP" \
    --profile-name "$AZ_FRONTDOOR_PROFILE" --custom-domain-name "$domain_res" \
    --query domainValidationState -o tsv || echo Unknown)

  local host
  host=$(state_get_output frontDoorHostName || echo "<run discover-hostname first>")
  local sub="${RELAY_CUSTOM_DOMAIN%%.*}"
  local parent="${RELAY_CUSTOM_DOMAIN#*.}"

  printf "\n${BOLD}Request these DNS records for %s:${NC}\n\n" "$RELAY_CUSTOM_DOMAIN"
  printf "  TXT    _dnsauth.%s    %s\n" "$sub" "${token:-<pending>}"
  printf "  CNAME  %s    %s\n" "$sub" "$host"
  printf "  CAA    %s    0 issue \"digicert.com\"   # only if CAA is enforced\n\n" "$parent"
  info "validation state: $state"
  if [ "$state" != "Approved" ]; then
    warn "Front Door needs BOTH records before it issues a certificate."
    warn "This step is resumable: re-run with --from custom-domain once DNS is live."
    warn "Issuance then takes a further 24-48h."
  else
    ok "domain validated"
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
