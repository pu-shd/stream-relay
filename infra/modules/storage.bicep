// HLS delivery origin: Blob Storage static website.
//
// WHY THIS EXISTS. MediaMTX's own HLS server cannot be served through a CDN. Verified
// against a live deployment:
//   * /<path>/index.m3u8 302-redirects to ?cookieCheck=1
//   * responses carry "Cache-Control: private, no-cache", so Front Door answers
//     X-Cache: PRIVATE_NOSTORE - and private/no-cache is ALWAYS honoured, so no
//     rules-engine override can make it cacheable
//   * the variant playlist returns 401 through the CDN even with a cookie jar, because
//     delivery is gated on a per-viewer session
//
// So delivery is moved off MediaMTX entirely. MediaMTX writes segments to hlsDirectory on
// the VM; those files are mirrored into this account's $web container; Front Door serves
// them as ordinary static files. Consequences:
//   * caching actually works, so origin pulls collapse to roughly one per POP per segment
//     rather than one per viewer
//   * the VM's HTTP port no longer needs to be reachable at all - the NSG can drop to
//     SRT-only, removing the origin-bypass surface
//   * the VM becomes ingest-and-package only, and can be replaced without touching delivery

@description('Storage account name. Globally unique, 3-24 chars, lowercase alphanumeric only.')
@minLength(3)
@maxLength(24)
param storageAccountName string

@description('Azure region.')
param location string

@description('Principal ID of the VM identity, which WRITES segments. The only writer.')
param writerPrincipalId string

@description('Whether to create role assignments (needs User Access Administrator). False for CI.')
param deployRoleAssignments bool = false

@description('Days after which stale HLS files are deleted. Live segments are rewritten constantly; anything older than this is debris from a previous activation.')
param segmentRetentionDays int = 1

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  sku: {
    // Locally redundant is correct: every byte here is reconstructible from the live
    // stream within seconds, so paying for geo-redundancy would be paying to protect
    // data that is worthless the moment it is stale.
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: true
    // Keys are disabled outright: the VM writes with its managed identity, and Front Door
    // reads the public static-website endpoint. Leaving shared keys enabled would leave a
    // credential lying around that nothing needs.
    allowSharedKeyAccess: false
    publicNetworkAccess: 'Enabled'
  }
}

// Static website hosting serves $web over a plain HTTPS endpoint with no SAS and no
// session semantics - which is the entire point.
resource blobServices 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
  properties: {
    cors: {
      corsRules: [
        {
          // HLS players fetch playlists and segments cross-origin when embedded.
          allowedOrigins: ['*']
          allowedMethods: ['GET', 'HEAD', 'OPTIONS']
          allowedHeaders: ['*']
          exposedHeaders: ['*']
          maxAgeInSeconds: 3600
        }
      ]
    }
    // Versioning and change feed are deliberately OFF. Segments are rewritten every second
    // per channel; retaining versions would grow storage without bound and cost money to
    // keep data that is stale on arrival.
    isVersioningEnabled: false
  }
}

// Lifecycle rule: sweep debris. If an activation ends abruptly, the last segments linger.
resource lifecycle 'Microsoft.Storage/storageAccounts/managementPolicies@2023-05-01' = {
  parent: storage
  name: 'default'
  properties: {
    policy: {
      rules: [
        {
          name: 'expire-stale-hls'
          enabled: true
          type: 'Lifecycle'
          definition: {
            filters: {
              blobTypes: ['blockBlob']
            }
            actions: {
              baseBlob: {
                delete: {
                  daysAfterModificationGreaterThan: segmentRetentionDays
                }
              }
            }
          }
        }
      ]
    }
  }
}

// Storage Blob Data Contributor, scoped to this account only: the VM must create, replace
// and delete segment blobs. It gets no rights anywhere else in the subscription.
var blobContributorRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'

resource writerAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployRoleAssignments) {
  scope: storage
  name: guid(storage.id, writerPrincipalId, blobContributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', blobContributorRoleId)
    principalId: writerPrincipalId
    principalType: 'ServicePrincipal'
  }
}

output id string = storage.id
output name string = storage.name

@description('The static-website host Front Door uses as its origin. NOT the blob endpoint - they are different hostnames.')
output staticWebsiteHostName string = replace(replace(storage.properties.primaryEndpoints.web, 'https://', ''), '/', '')

@description('Blob endpoint, used by the VM uploader.')
output blobEndpoint string = storage.properties.primaryEndpoints.blob
