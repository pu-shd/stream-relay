// stream-relay Azure infrastructure.
//
// Deploy target is a resource group:
//   az deployment group create -g <rg> -f infra/main.bicep \
//       -p ../stream-relay-config/orfe/infra.bicepparam
//
// Parameters are bound from the config repo's GENERATED infra.bicepparam, which is
// rendered from relay.yml. Do not hand-edit that file.
//
// Read the module headers before changing anything. Several settings look cosmetic and
// are not: the Front Door cache rules, the endpoint hash-reuse scope, and the static
// public IP each prevent a specific, expensive failure.

targetScope = 'resourceGroup'

@description('Azure region for all resources.')
param location string

@description('Container registry name (globally unique, alphanumeric only).')
param acrName string

@description('Storage account serving HLS. MediaMTX cannot be served through a CDN (session-gated, private/no-cache), so delivery is static files from this account instead.')
param storageAccountName string

@description('Key Vault holding the SRT publish passphrase. Read by the VM\'s managed identity; never by a pipeline.')
param keyVaultName string

@description('Identity federated to GitHub Actions. Contributor on this RG + AcrPush. No Key Vault access, so a compromised workflow cannot read the SRT passphrase.')
param ciIdentityName string

@description('Identity attached to the relay VM. AcrPull + Key Vault Secrets User only, so a compromised VM (public IP, internet-facing UDP listener) cannot redeploy or push images.')
param vmIdentityName string

@description('Whether this deployment creates role assignments. Creating them needs User Access Administrator; granting that to CI would let a compromised workflow grant itself any role. A human with Owner sets this true once during bootstrap; CI always runs with false.')
param deployRoleAssignments bool = false

@description('Relay VM name.')
param vmName string

@description('Relay VM size. Derived by render-relay.py from capacity.tier x channel count; D-series at tier 0 (remux), the no-SMT v6 F-family at tiers >0 (x264).')
param vmSize string

@description('Front Door Standard profile name. Standard is required and sufficient: it supports custom WAF rules, rate limiting, and Ignore-Specified-Query-Strings. Only managed rule sets need Premium.')
param frontDoorProfileName string

@description('Front Door endpoint name. Yields <name>-<hash>.z01.azurefd.net; the hash is NOT predictable and is discovered post-deploy.')
param frontDoorEndpointName string

@description('Custom domain, or empty string for Phase A. Front Door needs BOTH a _dnsauth TXT record and the CNAME before it will issue a managed certificate.')
param customDomain string = ''

@description('SRT ingest port (UDP). Bypasses Front Door entirely, since Front Door is HTTP-only.')
param srtPort int = 8890

@description('WAF rate-limit ceiling per socket IP. Required because HLS is public by default, making egress cost otherwise unbounded.')
param wafRateLimitRpm int

@description('Budget threshold for a warning alert, USD/month.')
param budgetWarnUsd int

@description('Budget threshold for the hard alert, USD/month.')
param budgetAlertUsd int

@description('Whether the pugwips campus/VPN allowlist is active. Off by default because HLS is public by default.')
param pugwipsEnabled bool = false

@description('Static Princeton campus CIDRs, used by restrict.sh as a fallback even when pugwipsEnabled is false.')
param campusRanges array = []

@description('MediaMTX path names, one per channel. Used to build per-path health probes and cache rules.')
param relayPaths array

@description('Key Vault secret name for the SRT publish passphrase.')
param passphraseSecretName string = 'srt-publish-passphrase'

@description('Emails for budget alerts.')
param alertEmails array = ['bino@princeton.edu']

@description('Budget start date, YYYY-MM-01. Passed in because Bicep cannot compute a deterministic first-of-month without utcNow(), which is disallowed outside parameter defaults.')
param budgetStartDate string

@description('Object ID of the operator who bootstraps the vault (needs Secrets Officer to CREATE the passphrase). Empty to skip.')
param operatorObjectId string = ''

@description('Optional SSH public key. Empty means no inbound SSH path at all; manage the VM via Run Command.')
param sshPublicKey string = ''

@description('Source CIDRs allowed to publish via SRT. Empty means Internet - acceptable only because the stream is encrypted and the passphrase gates publishing.')
param ingestAllowedSources array = []

var namePrefix = 'relay'

module identity 'modules/identity.bicep' = {
  name: 'identity-deploy'
  params: {
    ciIdentityName: ciIdentityName
    vmIdentityName: vmIdentityName
    location: location
    deployRoleAssignments: deployRoleAssignments
  }
}

module keyVault 'modules/keyvault.bicep' = {
  name: 'keyvault-deploy'
  params: {
    keyVaultName: keyVaultName
    location: location
    readerPrincipalId: identity.outputs.vmPrincipalId
    adminPrincipalId: operatorObjectId
    deployRoleAssignments: deployRoleAssignments
  }
}

module registry 'modules/acr.bicep' = {
  name: 'acr-deploy'
  params: {
    acrName: acrName
    location: location
    pullPrincipalId: identity.outputs.vmPrincipalId
    pushPrincipalId: identity.outputs.ciPrincipalId
    deployRoleAssignments: deployRoleAssignments
  }
}

module storage 'modules/storage.bicep' = {
  name: 'storage-deploy'
  params: {
    storageAccountName: storageAccountName
    location: location
    writerPrincipalId: identity.outputs.vmPrincipalId
    deployRoleAssignments: deployRoleAssignments
  }
}

module network 'modules/network.bicep' = {
  name: 'network-deploy'
  params: {
    namePrefix: namePrefix
    location: location
    srtPort: srtPort
    ingestAllowedSources: ingestAllowedSources
    // HLS is served from Blob now, so NOTHING needs to reach the VM over HTTP. Closing
    // 8888 removes the origin-bypass surface entirely: there is no longer a way to reach
    // the media server directly and sidestep the CDN, WAF and cache.
    exposeHlsPort: false
    restrictEgressToCampus: pugwipsEnabled
    campusRanges: campusRanges
  }
}

module relayVm 'modules/vm.bicep' = {
  name: 'vm-deploy'
  params: {
    vmName: vmName
    location: location
    vmSize: vmSize
    subnetId: network.outputs.subnetId
    publicIpId: network.outputs.publicIpId
    identityId: identity.outputs.vmId
    identityClientId: identity.outputs.vmClientId
    acrLoginServer: registry.outputs.loginServer
    keyVaultName: keyVault.outputs.name
    passphraseSecretName: passphraseSecretName
    storageAccountName: storage.outputs.name
    storageBlobEndpoint: storage.outputs.blobEndpoint
    sshPublicKey: sshPublicKey
  }
}

module frontDoor 'modules/frontdoor.bicep' = {
  name: 'frontdoor-deploy'
  params: {
    profileName: frontDoorProfileName
    endpointName: frontDoorEndpointName
    // Origin is the storage static-website host, NOT the VM. This is the whole point of
    // the delivery split.
    originHostName: storage.outputs.staticWebsiteHostName
    customDomain: customDomain
    wafRateLimitRpm: wafRateLimitRpm
  }
}

module guardrails 'modules/guardrails.bicep' = {
  name: 'guardrails-deploy'
  params: {
    budgetName: '${namePrefix}-budget'
    budgetAlertUsd: budgetAlertUsd
    budgetWarnUsd: budgetWarnUsd
    notificationEmails: alertEmails
    startDate: budgetStartDate
  }
}

// ---------------------------------------------------------------------------------------
// Outputs. deploy.sh consumes these; discover-hostname writes frontDoorHostName back into
// relay.yml. Nothing here is a credential.
// ---------------------------------------------------------------------------------------

@description('THE authoritative Front Door hostname. Never construct <endpoint>.azurefd.net - that name does not resolve.')
output frontDoorHostName string = frontDoor.outputs.endpointHostName

@description('Static public IP for SRT ingest. The page-stream producers embed this.')
output ingestIpAddress string = network.outputs.publicIpAddress

output ingestPort int = srtPort
output ingestUrlTemplate string = 'srt://${network.outputs.publicIpAddress}:${srtPort}?streamid=publish:<path>&passphrase=<secret>&pbkeylen=32&latency=200000'
output acrLoginServer string = registry.outputs.loginServer
output storageAccountName string = storage.outputs.name
output staticWebsiteHostName string = storage.outputs.staticWebsiteHostName
output keyVaultName string = keyVault.outputs.name
// The CI client id is what goes into the AZURE_CLIENT_ID repository variable.
output ciIdentityClientId string = identity.outputs.ciClientId
output ciIdentityPrincipalId string = identity.outputs.ciPrincipalId
output vmIdentityClientId string = identity.outputs.vmClientId
output vmIdentityPrincipalId string = identity.outputs.vmPrincipalId
output tenantId string = subscription().tenantId
output subscriptionId string = subscription().subscriptionId
output roleAssignmentsDeployed bool = deployRoleAssignments
output vmName string = relayVm.outputs.name
output nsgName string = network.outputs.nsgName
output wafPolicyName string = frontDoor.outputs.wafPolicyName
output customDomainValidationToken string = frontDoor.outputs.customDomainValidationToken
output relayPathCount int = length(relayPaths)
output hlsUrls array = [for p in relayPaths: 'https://${frontDoor.outputs.endpointHostName}/${p}/index.m3u8']
