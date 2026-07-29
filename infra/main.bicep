// stream-relay Azure infrastructure.
//
// PHASE 2 — NOT YET IMPLEMENTED. This file currently declares only the PARAMETER
// CONTRACT that the config repo's generated infra.bicepparam binds to, so the two stay
// in sync and `az bicep build` succeeds before any resources exist. Adding resources is
// Phase 2 work; the notes below are the binding design constraints for whoever does it.
//
// Deploy target is a resource group:
//   az deployment group create -g <rg> -f infra/main.bicep -p ../stream-relay-config/orfe/infra.bicepparam

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

@description('Front Door endpoint name. Yields <name>.azurefd.net, which must keep working permanently as a fallback hostname.')
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

// ---------------------------------------------------------------------------------------
// TODO(phase-2): resources. Binding constraints, each learned the hard way:
//
//  1. FRONT DOOR CACHE KEY — MUST ignore the 'session' query parameter. MediaMTX appends
//     a per-viewer '?session=<uuid>' to every variant playlist URL in EVERY hlsVariant.
//     Without this the cache hit rate is ~0 and origin egress roughly doubles the bill.
//
//  2. FRONT DOOR CACHE TTL — MUST be set explicitly on manifests. MediaMTX emits no
//     Cache-Control, and Front Door then assigns a RANDOM 1-3 day TTL, which would pin a
//     stale playlist for days. Short TTL on *.m3u8, longer on segments.
//
//  3. NSG — open ONLY srtPort/UDP (ingest) and 8888/TCP from the Front Door service tag
//     (egress). MediaMTX's API (9997) and metrics (9998) bind to loopback in the
//     generated config; never add NSG rules for them.
//
//  4. ACR PULL — grant the identity 'Container Registry Repository Reader' on
//     ABAC-enabled registries, or 'AcrPull' on non-ABAC ones. Not GHCR: it has no
//     managed-identity path and would force a stored PAT onto the VM.
//
//  5. BUDGET — provision the budget + anomaly alert here rather than by hand, so a
//     teardown/redeploy cycle cannot silently drop the cost guardrail.
//
//  6. PUBLIC IP — must be static. The page-stream producers hold it in their ingest URLs,
//     and a dynamic IP would silently break every publisher on VM restart.
// ---------------------------------------------------------------------------------------

// Surfaced so `what-if` and the mock-az tests can assert the contract before resources
// exist. Every value here is a deployment target, never a credential.
output plannedVmSize string = vmSize
output plannedRegion string = location
output relayPathCount int = length(relayPaths)
output customDomainConfigured bool = !empty(customDomain)
output defaultHostname string = '${frontDoorEndpointName}.azurefd.net'
output pugwipsActive bool = pugwipsEnabled
output campusRangeCount int = length(campusRanges)
output ingestPort int = srtPort
output guardrails object = {
  wafRateLimitRpm: wafRateLimitRpm
  budgetWarnUsd: budgetWarnUsd
  budgetAlertUsd: budgetAlertUsd
}
output identityNames object = {
  identity: identityName
  keyVault: keyVaultName
  acr: acrName
  vm: vmName
  frontDoorProfile: frontDoorProfileName
}
