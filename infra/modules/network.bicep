// Network for the relay VM.
//
// The asymmetry here is the whole point of the architecture: SRT ingest is UDP, which
// Front Door cannot carry (it is an L7 HTTP proxy), so ingest terminates on this public
// IP and the NSG is the access control. Only HLS egress goes through the CDN.

@description('Base name for network resources.')
param namePrefix string

@description('Azure region.')
param location string

@description('SRT ingest port (UDP).')
param srtPort int

@description('Source CIDRs allowed to PUBLISH via SRT. Empty means Internet, which is acceptable only because the stream is encrypted and the passphrase gates publishing.')
param ingestAllowedSources array = []

@description('Whether to open the MediaMTX HTTP port at all. FALSE once HLS is delivered from Blob Storage: nothing outside the VM needs it, and closing it removes the only way to bypass the CDN, WAF and cache.')
param exposeHlsPort bool = false

@description('Whether to restrict HLS egress to campus/VPN ranges instead of allowing Front Door broadly. Only meaningful when exposeHlsPort is true.')
param restrictEgressToCampus bool = false

@description('Campus/VPN CIDRs, used when restrictEgressToCampus is true.')
param campusRanges array = []

var addressSpace = '10.42.0.0/16'
var subnetPrefix = '10.42.1.0/24'

// STATIC, not Dynamic. The page-stream producers embed this address in their ingest
// URLs; a dynamic IP would silently break every publisher on VM restart - a failure that
// would look like a relay bug rather than an addressing change.
resource publicIp 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: '${namePrefix}-pip'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
    idleTimeoutInMinutes: 4
  }
}

resource nsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: '${namePrefix}-nsg'
  location: location
  properties: {
    securityRules: [
      {
        // SRT ingest. UDP, from the publishers.
        name: 'allow-srt-ingest'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Udp'
          sourceAddressPrefix: empty(ingestAllowedSources) ? 'Internet' : null
          sourceAddressPrefixes: empty(ingestAllowedSources) ? null : ingestAllowedSources
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: string(srtPort)
        }
      }
      {
        // Retained only for the legacy topology where MediaMTX served HLS directly. With
        // delivery on Blob this rule is DENY, so the media server is unreachable over HTTP.
        name: 'allow-hls-from-frontdoor'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: exposeHlsPort ? 'Allow' : 'Deny'
          protocol: 'Tcp'
          sourceAddressPrefix: restrictEgressToCampus ? null : 'AzureFrontDoor.Backend'
          sourceAddressPrefixes: restrictEgressToCampus ? campusRanges : null
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '8888'
        }
      }
      {
        // Explicit deny for the control surfaces. They already bind to loopback inside
        // the container, so this is defence in depth: if a future config change exposed
        // them, the NSG still refuses. MediaMTX's API can reconfigure paths at runtime.
        name: 'deny-mediamtx-control-surfaces'
        properties: {
          priority: 200
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRanges: ['9997', '9998', '8892']
        }
      }
      {
        // No SSH rule. Management is via Azure Run Command / Serial Console, so there is
        // no standing inbound administrative path on a machine that lives on a public IP.
        name: 'deny-all-other-inbound'
        properties: {
          priority: 4000
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: '${namePrefix}-vnet'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [addressSpace]
    }
    subnets: [
      {
        name: 'relay'
        properties: {
          addressPrefix: subnetPrefix
          networkSecurityGroup: {
            id: nsg.id
          }
        }
      }
    ]
  }
}

output publicIpId string = publicIp.id
output publicIpAddress string = publicIp.properties.ipAddress
output subnetId string = '${vnet.id}/subnets/relay'
output nsgId string = nsg.id
output nsgName string = nsg.name
