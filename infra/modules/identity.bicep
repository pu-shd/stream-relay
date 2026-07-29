// User-assigned managed identity, used by BOTH:
//   * GitHub Actions, via a federated credential (no client secret anywhere), and
//   * the relay VM, to pull from ACR and read the SRT passphrase from Key Vault.
//
// One identity for both is deliberate: it keeps the RBAC surface small and means a
// teardown/redeploy cycle does not invalidate the GitHub side.

@description('Identity name.')
param identityName string

@description('Azure region.')
param location string

@description('GitHub org/user owning the repositories.')
param githubOwner string = 'pu-orfe'

@description('Config repository whose workflow deploys this. The federated credential subject is scoped to it.')
param githubConfigRepo string = 'stream-relay-config'

@description('Branches allowed to deploy. Enumerated explicitly - wildcard ("flexible") FIC subjects are avoided because their GA status is unconfirmed.')
param allowedBranches array = ['main']

@description('GitHub Environments allowed to deploy. The production environment carries a required reviewer, so real spend needs a human click.')
param allowedEnvironments array = ['production']

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: identityName
  location: location
}

// One credential per subject. GitHub sends exactly one `sub` claim per run, so each
// branch and each environment needs its own credential.
resource branchCredentials 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = [
  for branch in allowedBranches: {
    parent: identity
    name: 'gh-branch-${replace(branch, '/', '-')}'
    properties: {
      issuer: 'https://token.actions.githubusercontent.com'
      subject: 'repo:${githubOwner}/${githubConfigRepo}:ref:refs/heads/${branch}'
      audiences: ['api://AzureADTokenExchange']
    }
  }
]

resource environmentCredentials 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = [
  for env in allowedEnvironments: {
    parent: identity
    name: 'gh-env-${env}'
    properties: {
      issuer: 'https://token.actions.githubusercontent.com'
      subject: 'repo:${githubOwner}/${githubConfigRepo}:environment:${env}'
      audiences: ['api://AzureADTokenExchange']
    }
  }
]

output id string = identity.id
output principalId string = identity.properties.principalId
output clientId string = identity.properties.clientId
output name string = identity.name
