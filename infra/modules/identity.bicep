// TWO user-assigned managed identities, least privilege each.
//
// A single identity previously served both GitHub Actions and the VM, holding only AcrPull.
// That was wrong in both directions: too little for CI (`az acr build` needs push and
// task-run rights) and far too much for the VM, which sits on a public IP with an
// internet-facing UDP listener. If that VM is compromised, its identity must not be able to
// redeploy infrastructure or push the very image it will later execute.
//
//   -ci  federated to GitHub Actions. Contributor on the RG + AcrPush. No Key Vault access,
//        so a compromised workflow cannot read the SRT passphrase.
//   -vm  attached to the VM. AcrPull + Key Vault Secrets User. No RG rights, so a
//        compromised VM cannot deploy anything.
//
// Only -ci carries federated credentials. Only -vm is attached to the VM.

@description('Identity used by GitHub Actions via OIDC. Never attached to a VM.')
param ciIdentityName string

@description('Identity attached to the relay VM. Never federated to GitHub.')
param vmIdentityName string

@description('Azure region.')
param location string

@description('GitHub org/user owning the repositories.')
param githubOwner string = 'pu-orfe'

@description('Config repository whose workflow deploys this. The federated credential subject is scoped to it.')
param githubConfigRepo string = 'stream-relay-config'

@description('Branches allowed to deploy. Enumerated explicitly - wildcard ("flexible") FIC subjects are avoided because their GA status is unconfirmed, and a wildcard subject would let any branch assume this identity.')
param allowedBranches array = ['main']

@description('GitHub Environments allowed to deploy.')
param allowedEnvironments array = ['production']

@description('Whether to create role assignments. FALSE for CI: creating role assignments needs User Access Administrator, and granting that to a workflow means a compromised workflow can grant itself anything. A human with Owner sets this true once during bootstrap.')
param deployRoleAssignments bool = false

resource ciIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: ciIdentityName
  location: location
}

resource vmIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: vmIdentityName
  location: location
}

// One credential per subject. GitHub sends exactly ONE `sub` claim per job, and the
// environment form REPLACES the ref form rather than adding to it - so a job declaring
// `environment: production` needs the environment credential, and a job without one needs
// the ref credential. Both are required; neither is redundant.
//
// SERIALIZED ON PURPOSE. Azure rejects concurrent federated-credential writes under one
// managed identity:
//
//   ConcurrentFederatedIdentityCredentialsWritesForSingleManagedIdentity
//   "Concurrent Federated Identity Credentials writes under the same managed identity are
//    not supported."
//
// Two separate resource loops deployed in parallel and hit exactly that. Flattening them
// into a single loop with @batchSize(1) forces ARM to create them one at a time. Do not
// split this back into per-kind loops, and do not remove the decorator.
var federatedSubjects = concat(
  map(allowedBranches, branch => {
    name: 'gh-branch-${replace(branch, '/', '-')}'
    subject: 'repo:${githubOwner}/${githubConfigRepo}:ref:refs/heads/${branch}'
  }),
  map(allowedEnvironments, env => {
    name: 'gh-env-${env}'
    subject: 'repo:${githubOwner}/${githubConfigRepo}:environment:${env}'
  })
)

@batchSize(1)
resource federatedCredentials 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = [
  for fic in federatedSubjects: {
    parent: ciIdentity
    name: fic.name
    properties: {
      issuer: 'https://token.actions.githubusercontent.com'
      subject: fic.subject
      audiences: ['api://AzureADTokenExchange']
    }
  }
]

// Contributor on the resource group for CI: enough to converge every resource in this
// template, and deliberately NOT User Access Administrator, so the workflow cannot alter
// permissions - including its own.
var contributorRoleId = 'b24988ac-6180-42a0-ab88-20f7382dd24c'

resource ciContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployRoleAssignments) {
  scope: resourceGroup()
  name: guid(resourceGroup().id, ciIdentity.id, contributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', contributorRoleId)
    principalId: ciIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

output ciId string = ciIdentity.id
output ciPrincipalId string = ciIdentity.properties.principalId
output ciClientId string = ciIdentity.properties.clientId
output ciName string = ciIdentity.name

output vmId string = vmIdentity.id
output vmPrincipalId string = vmIdentity.properties.principalId
output vmClientId string = vmIdentity.properties.clientId
output vmName string = vmIdentity.name
