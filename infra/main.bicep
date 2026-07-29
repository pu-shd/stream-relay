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

@description('Key Vault holding the SRT publish passphrase. Read by the VM\'s managed identity; never by a pipeline.')
param keyVaultName string

@description('User-assigned managed identity used for BOTH the GitHub Actions federated credential and the VM\'s ACR pull. No client secret exists anywhere.')
param identityName string

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
    identityName: identityName
    location: location
  }
}

module keyVault 'modules/keyvault.bicep' = {
  name: 'keyvault-deploy'
  params: {
    keyVaultName: keyVaultName
    location: location
    readerPrincipalId: identity.outputs.principalId
    adminPrincipalId: operatorObjectId
  }
}

module registry 'modules/acr.bicep' = {
  name: 'acr-deploy'
  params: {
    acrName: acrName
    location: location
    pullPrincipalId: identity.outputs.principalId
  }
}

module network 'modules/network.bicep' = {
  name: 'network-deploy'
  params: {
    namePrefix: namePrefix
    location: location
    srtPort: srtPort
    ingestAllowedSources: ingestAllowedSources
    // pugwipsEnabled tightens HLS egress to campus ranges instead of allowing the whole
    // Front Door backend tag.
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
    identityId: identity.outputs.id
    identityClientId: identity.outputs.clientId
    acrLoginServer: registry.outputs.loginServer
    keyVaultName: keyVault.outputs.name
    passphraseSecretName: passphraseSecretName
    sshPublicKey: sshPublicKey
  }
}

module frontDoor 'modules/frontdoor.bicep' = {
  name: 'frontdoor-deploy'
  params: {
    profileName: frontDoorProfileName
    endpointName: frontDoorEndpointName
    originHostName: network.outputs.publicIpAddress
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
output keyVaultName string = keyVault.outputs.name
output identityClientId string = identity.outputs.clientId
output identityPrincipalId string = identity.outputs.principalId
output vmName string = relayVm.outputs.name
output nsgName string = network.outputs.nsgName
output wafPolicyName string = frontDoor.outputs.wafPolicyName
output customDomainValidationToken string = frontDoor.outputs.customDomainValidationToken
output relayPathCount int = length(relayPaths)
output hlsUrls array = [for p in relayPaths: 'https://${frontDoor.outputs.endpointHostName}/${p}/index.m3u8']
