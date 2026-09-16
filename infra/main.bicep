// stream-relay Azure infrastructure.
//
// Deploy target is a resource group:
//   az deployment group create -g <rg> -f infra/main.bicep \
//       -p ../stream-relay-config/orfe/infra.bicepparam
//
// Parameters are bound from the config repo's GENERATED infra.bicepparam, which is
// rendered from relay.yml. Do not hand-edit that file.
//
// ---------------------------------------------------------------------------------------
// THIS TEMPLATE ADOPTS AN EXISTING VM. IT DOES NOT CREATE ONE.
//
// The relay runs on orfe-web-vm, which already existed (parked, deallocated) with its own
// vnet, subnet, NIC, static public IP, Key Vault, disk-encryption set, Log Analytics
// workspace and alert rules. None of that is declared here, because declaring an existing
// VM risks Azure deciding to replace it - and replacement destroys the disks.
//
// The resource group is SHARED. Nothing in this file may be written so that removing it
// would remove a sibling resource. teardown.sh enforces the same rule from the other side.
//
// What this file owns, and nothing else:
//   * the network security group's complete rule set
//   * the VM identity's right to read one Key Vault secret
//   * the subscription budget and its alerts
// ---------------------------------------------------------------------------------------

targetScope = 'resourceGroup'

@description('Azure region for all resources.')
param location string

@description('Container registry name. Retained for a future baked MediaMTX image; not deployed by this template - the relay runs the upstream image with a bind-mounted entrypoint.')
param acrName string

@description('EXISTING Key Vault, created with the VM. Holds the SRT publish passphrase. RBAC-authorized and purge-protected.')
param keyVaultName string

@description('CI identity name, federated to GitHub Actions. Not deployed here; created once by bootstrap.sh.')
param ciIdentityName string

@description('Unused. The VM carries a SystemAssigned identity, so no user-assigned identity is attached.')
param vmIdentityName string

@description('Role assignments require Owner/User Access Administrator. CI must never hold that, so the human bootstrap passes true once.')
param deployRoleAssignments bool = false

@description('EXISTING VM that hosts MediaMTX, nginx and certbot.')
param vmName string

@description('Derived from tier x channel count. Applied by deploy.sh with `az vm resize`, not here: resizing through a VM resource this template does not own risks replacement.')
param vmSize string

@description('EXISTING public-IP DNS label. The certificate name and every Apple TV URL derive from it.')
param dnsLabel string

@description('The name viewers use. REQUIRED: cloudapp.azure.com is absent from the Public Suffix List, so Let\'s Encrypt counts it against azure.com and can never issue for the derived name.')
param customDomain string

@description('SRT ingest port (UDP).')
param srtPort int = 8890

@description('Who may reach the SRT ingest port. The campus /16 rather than one host, because the encoder sits behind a NAT egress that may change; the SRT wire passphrase is the actual publish credential.')
param publisherCidr string

@description('Azure automatic guest patching. Already enabled on this VM and asserted by verify.sh.')
param autoPatch bool = true

@description('Reboot window, UTC. Reboots drop every channel at once; page-stream reconnects because its backoff is gated to srt://.')
param rebootWindowUtc string

@description('False creates NO rule for port 22. Administration is `az vm run-command` over the control plane, which needs no inbound path.')
param enableSsh bool = false

@description('ACME account address for certbot.')
param acmeEmail string

@description('Use the ACME staging CA. Staging has far higher rate limits; a failed HTTP-01 against production burns the weekly quota.')
param acmeStaging bool = false

@description('Warn threshold. Sized for a service that is always on, not a standby.')
param budgetWarnUsd int

@description('Alert threshold.')
param budgetAlertUsd int

@description('Restrict HLS delivery to campus. The GlobalProtect ranges are merged in at runtime by restrict.sh, because they change.')
param pugwipsEnabled bool = false

@description('Static campus ranges permitted to read HLS.')
param campusRanges array = []

@description('GlobalProtect VPN egress ranges permitted to read HLS. Kept separate from campusRanges because these are a dated snapshot of addresses that rotate, while campus ranges are institutional and stable.')
param gatewayRanges array = []

@description('MediaMTX paths, one per channel. Used to emit the viewer URLs.')
param relayPaths array

@description('Key Vault secret holding the SRT publish passphrase.')
param passphraseSecretName string = 'srt-publish-passphrase'

@description('Budget alert recipients.')
param alertEmails array = ['bino@princeton.edu']

@description('Budget start date. Must be the first of a month or Azure rejects it.')
param budgetStartDate string

@description('Object id of the human operator, for Key Vault administration. Passed at deploy time.')
param operatorObjectId string = ''

@description('Unused: no VM is created, so no key is set. Retained so the generated bicepparam stays valid.')
param sshPublicKey string = ''

@description('Legacy. Superseded by publisherCidr.')
param ingestAllowedSources array = []

var namePrefix = 'relay'
var nsgName = '${vmName}-nsg'

// ---------------------------------------------------------------------------------------
// Existing resources. Referenced, never declared.
// ---------------------------------------------------------------------------------------

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' existing = {
  name: vmName
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

// ---------------------------------------------------------------------------------------
// The network security group, declared in full.
//
// Declared completely rather than as individual child rules, because the requirement is
// as much about what is ABSENT as what is present: this VM's NSG carried two rules named
// SSH-HTTP and SSH-HTTPS, both opening port 22, and adding child rules would have left
// them in place. A full declaration makes the rule set exactly what this file says.
//
// The NSG is attached to the SUBNET, not the NIC, and is dedicated to this VM.
// ---------------------------------------------------------------------------------------

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: nsgName
  location: location
  properties: {
    securityRules: concat(
      [
        {
          // SRT ingest. UDP, so it never passes through any HTTP path.
          name: 'AllowSrtIngest'
          properties: {
            priority: 100
            direction: 'Inbound'
            access: 'Allow'
            protocol: 'Udp'
            sourceAddressPrefix: publisherCidr
            sourcePortRange: '*'
            destinationAddressPrefix: '*'
            destinationPortRange: string(srtPort)
            description: 'SRT publish from the on-prem encoder. Campus /16; the wire passphrase is the credential.'
          }
        }
        {
          // HLS delivery. Campus only when pugwips is on, otherwise open.
          name: 'AllowHlsDelivery'
          properties: {
            priority: 110
            direction: 'Inbound'
            access: 'Allow'
            protocol: 'Tcp'
            // Campus plus the VPN egress pools. The pools are the vendor's registered
            // blocks rather than the resolved gateway addresses, because Prisma Access
            // source-NATs clients from an egress pool that is not adjacent to the gateway
            // ingress - allowlisting the resolved /24s admits the gateway and blocks every
            // actual viewer.
            sourceAddressPrefixes: pugwipsEnabled ? concat(campusRanges, gatewayRanges) : []
            sourceAddressPrefix: pugwipsEnabled ? null : 'Internet'
            sourcePortRange: '*'
            destinationAddressPrefix: '*'
            destinationPortRange: '443'
            description: 'HLS to the Apple TVs. GlobalProtect ranges are merged in at runtime by restrict.sh.'
          }
        }
        {
          // ACME only. nginx serves /.well-known/acme-challenge here and 404s everything
          // else, so this port carries no media.
          //
          // Open to the Internet deliberately: Let's Encrypt validates from undisclosed,
          // rotating addresses, so the rule cannot be narrowed. Opening it per renewal
          // instead would require the VM's identity to write its own NSG - the privilege
          // the identity split withholds - and fails in the worse direction, since a hole
          // that fails to close is invisible while one that fails to open expires the
          // certificate and takes every display down.
          name: 'AllowAcmeHttp'
          properties: {
            priority: 120
            direction: 'Inbound'
            access: 'Allow'
            protocol: 'Tcp'
            sourceAddressPrefix: 'Internet'
            sourcePortRange: '*'
            destinationAddressPrefix: '*'
            destinationPortRange: '80'
            description: 'ACME HTTP-01 challenge only. nginx 404s every other path on :80.'
          }
        }
      ],
      // Deliberately absent unless asked for. The VM is administered with
      // `az vm run-command`, which travels the Azure control plane and needs no open port.
      enableSsh ? [
        {
          name: 'AllowSshFromCampus'
          properties: {
            priority: 130
            direction: 'Inbound'
            access: 'Allow'
            protocol: 'Tcp'
            sourceAddressPrefixes: campusRanges
            sourcePortRange: '*'
            destinationAddressPrefix: '*'
            destinationPortRange: '22'
            description: 'Opt-in only. Entra-gated via AADSSHLoginForLinux.'
          }
        }
      ] : []
    )
  }
}

// ---------------------------------------------------------------------------------------
// The VM's right to read the SRT passphrase.
//
// The vault is RBAC-authorized, so this is a role assignment rather than an access policy.
// Scoped to the vault, and only Secrets User: read one secret, nothing else.
// ---------------------------------------------------------------------------------------

var keyVaultSecretsUser = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '4633458b-17de-408a-b874-0445c86b69e6'
)

resource vmReadsPassphrase 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployRoleAssignments) {
  name: guid(keyVault.id, vm.id, keyVaultSecretsUser)
  scope: keyVault
  properties: {
    roleDefinitionId: keyVaultSecretsUser
    principalId: vm.identity.principalId
    principalType: 'ServicePrincipal'
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
// Outputs. Nothing here is a credential.
// ---------------------------------------------------------------------------------------

@description('The hostname the displays use and the certificate covers.')
output relayHostName string = customDomain

@description('Derived Azure name, kept for reference. NOT certifiable by Let\'s Encrypt.')
output azureHostName string = '${dnsLabel}.${location}.cloudapp.azure.com'

output ingestPort int = srtPort
output ingestUrlTemplate string = 'srt://${customDomain}:${srtPort}?streamid=publish:<path>&passphrase=<secret>&pbkeylen=32&latency=200000'
output keyVaultName string = keyVault.name
output passphraseSecretName string = passphraseSecretName
output vmName string = vm.name
output vmPrincipalId string = vm.identity.principalId
output nsgName string = nsg.name
output relayPathCount int = length(relayPaths)
output hlsUrls array = [for p in relayPaths: 'https://${customDomain}/${p}/index.m3u8']
output roleAssignmentsDeployed bool = deployRoleAssignments
output tenantId string = subscription().tenantId
output subscriptionId string = subscription().subscriptionId
