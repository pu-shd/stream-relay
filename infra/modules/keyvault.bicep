// Key Vault holding the single real secret: the SRT publish passphrase.
//
// Read at VM boot by the managed identity. No pipeline ever reads it, and it is never
// passed on an `az` command line (argv is visible in process listings).

@description('Vault name. Globally unique, max 24 characters.')
@maxLength(24)
param keyVaultName string

@description('Azure region.')
param location string

@description('Principal ID of the VM identity, the only principal that may read secrets. The CI identity deliberately has NO Key Vault access, so a compromised workflow cannot read the SRT passphrase.')
param readerPrincipalId string

@description('Whether to create role assignments (needs User Access Administrator). False for CI.')
param deployRoleAssignments bool = false

@description('Principal ID of the human/service operator that may SET secrets (bootstrap only). Empty to skip.')
param adminPrincipalId string = ''

// Purge protection is deliberately OFF. This is a cold standby that is torn down and
// redeployed by design; with purge protection enabled, a soft-deleted vault would block
// redeploying the same name for 90 days and break the rehearsal drill.
// Retention is kept at the 7-day minimum for the same reason.
resource vault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    // RBAC rather than access policies: the same role assignments model as everything
    // else here, and it composes with the managed identity.
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    enablePurgeProtection: null
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
  }
}

// Key Vault Secrets User: get/list secret values, nothing more.
var secretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'
// Key Vault Secrets Officer: needed to CREATE the secret during bootstrap.
var secretsOfficerRoleId = 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'

resource readerAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployRoleAssignments) {
  scope: vault
  name: guid(vault.id, readerPrincipalId, secretsUserRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', secretsUserRoleId)
    principalId: readerPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource adminAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployRoleAssignments && !empty(adminPrincipalId)) {
  scope: vault
  name: guid(vault.id, adminPrincipalId, secretsOfficerRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', secretsOfficerRoleId)
    principalId: adminPrincipalId
  }
}

output id string = vault.id
output name string = vault.name
output uri string = vault.properties.vaultUri
