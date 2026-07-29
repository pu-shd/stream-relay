// Container registry for the relay image.
//
// ACR rather than GHCR: GHCR has no managed-identity path and would force a stored PAT
// onto the VM. CI pushes here; the VM pulls with its identity and no credential on disk.
//
// Basic SKU is the standby's only standing cost (~$5/mo), and it is worth paying so the
// image is ready to run at cutover rather than needing a build first.

@description('Registry name. Globally unique, alphanumeric only.')
@minLength(5)
@maxLength(50)
param acrName string

@description('Azure region.')
param location string

@description('Principal ID of the identity that pulls images.')
param pullPrincipalId string

resource registry 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: acrName
  location: location
  sku: {
    name: 'Basic'
  }
  properties: {
    // Admin user disabled: it is a shared password, which is exactly what this design
    // avoids. Pulls authenticate via managed identity.
    adminUserEnabled: false
    publicNetworkAccess: 'Enabled'
  }
}

// AcrPull. Note: on ABAC-enabled registries Microsoft now leads with
// 'Container Registry Repository Reader' instead. AcrPull remains valid for non-ABAC
// registries, which is what a Basic SKU registry created this way is.
var acrPullRoleId = '7f951dda-4ed3-4680-a7ca-43fe172d538d'

resource pullAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: registry
  name: guid(registry.id, pullPrincipalId, acrPullRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRoleId)
    principalId: pullPrincipalId
    principalType: 'ServicePrincipal'
  }
}

output id string = registry.id
output name string = registry.name
output loginServer string = registry.properties.loginServer
