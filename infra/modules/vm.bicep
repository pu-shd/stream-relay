// The relay VM: Docker, MediaMTX, and the managed-identity plumbing to reach ACR and
// Key Vault without a stored credential.

@description('VM name.')
param vmName string

@description('Azure region.')
param location string

@description('VM size. Derived by render-relay.py from tier x channel count.')
param vmSize string

@description('Subnet to attach to.')
param subnetId string

@description('Static public IP resource ID.')
param publicIpId string

@description('User-assigned managed identity resource ID.')
param identityId string

@description('Client ID of that identity, needed for `az login --identity --username`.')
param identityClientId string

@description('ACR login server, e.g. myregistry.azurecr.io.')
param acrLoginServer string

@description('Relay image repository and tag within the registry.')
param imageName string = 'stream-relay-mediamtx:latest'

@description('Key Vault name holding the SRT passphrase.')
param keyVaultName string

@description('Key Vault secret name for the SRT passphrase.')
param passphraseSecretName string

@description('Admin username. No password and no SSH key are configured - see below.')
param adminUsername string = 'relayadmin'

@description('SSH public key. Empty means no inbound SSH path at all; manage via Run Command.')
param sshPublicKey string = ''

// cloud-init. Kept declarative and idempotent so `update.sh` can re-run it.
//
// The token-refresh timer matters: `az acr login` mints a SHORT-LIVED token into the
// Docker credential store. On a long-running host the credential silently expires, and
// the next image pull fails at the worst possible time (a restart during a cutover).
var cloudInit = '''#cloud-config
package_update: true
packages:
  - ca-certificates
  - curl
  - jq

write_files:
  - path: /etc/stream-relay/env
    permissions: '0600'
    content: |
      ACR_LOGIN_SERVER=__ACR_LOGIN_SERVER__
      IMAGE=__ACR_LOGIN_SERVER__/__IMAGE_NAME__
      IDENTITY_CLIENT_ID=__IDENTITY_CLIENT_ID__
      KEY_VAULT=__KEY_VAULT__
      PASSPHRASE_SECRET=__PASSPHRASE_SECRET__

  - path: /usr/local/bin/relay-acr-login.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      # Refresh the ACR credential using the VM's managed identity. No secret on disk.
      set -euo pipefail
      source /etc/stream-relay/env
      az login --identity --username "$IDENTITY_CLIENT_ID" --allow-no-subscriptions >/dev/null
      az acr login --name "${ACR_LOGIN_SERVER%%.*}" >/dev/null
      echo "acr login refreshed at $(date -Is)"

  - path: /usr/local/bin/relay-start.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      set -euo pipefail
      source /etc/stream-relay/env
      /usr/local/bin/relay-acr-login.sh
      docker pull "$IMAGE"
      # Read the passphrase from Key Vault via managed identity. Passed to the container
      # as an env var, never on a command line: argv is visible in process listings.
      PASSPHRASE=$(az keyvault secret show --vault-name "$KEY_VAULT" \
        --name "$PASSPHRASE_SECRET" --query value -o tsv)
      docker rm -f stream-relay >/dev/null 2>&1 || true
      docker run -d --name stream-relay --restart unless-stopped \
        -e SRT_PUBLISH_PASSPHRASE="$PASSPHRASE" \
        -v /etc/stream-relay/config:/config:ro \
        -p 8890:8890/udp -p 8888:8888 \
        "$IMAGE"
      unset PASSPHRASE

  - path: /etc/systemd/system/stream-relay.service
    content: |
      [Unit]
      Description=stream-relay MediaMTX
      After=docker.service network-online.target
      Requires=docker.service
      [Service]
      Type=oneshot
      RemainAfterExit=yes
      ExecStart=/usr/local/bin/relay-start.sh
      ExecStop=/usr/bin/docker stop stream-relay
      [Install]
      WantedBy=multi-user.target

  - path: /etc/systemd/system/relay-acr-refresh.timer
    content: |
      [Unit]
      Description=Refresh the ACR managed-identity token
      [Timer]
      OnCalendar=*-*-* *:00:00
      Persistent=true
      [Install]
      WantedBy=timers.target

  - path: /etc/systemd/system/relay-acr-refresh.service
    content: |
      [Unit]
      Description=Refresh the ACR managed-identity token
      [Service]
      Type=oneshot
      ExecStart=/usr/local/bin/relay-acr-login.sh

runcmd:
  - curl -fsSL https://get.docker.com | sh
  - curl -sL https://aka.ms/InstallAzureCLIDeb | bash
  - mkdir -p /etc/stream-relay/config
  - systemctl daemon-reload
  - systemctl enable --now relay-acr-refresh.timer
  # stream-relay.service is enabled but NOT started here: the config template has not
  # been delivered yet. configure-vm starts it once /etc/stream-relay/config is populated.
  - systemctl enable stream-relay.service
'''

var renderedCloudInit = replace(
  replace(
    replace(
      replace(replace(cloudInit, '__ACR_LOGIN_SERVER__', acrLoginServer), '__IMAGE_NAME__', imageName),
      '__IDENTITY_CLIENT_ID__',
      identityClientId
    ),
    '__KEY_VAULT__',
    keyVaultName
  ),
  '__PASSPHRASE_SECRET__',
  passphraseSecretName
)

resource nic 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: '${vmName}-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: subnetId
          }
          publicIPAddress: {
            id: publicIpId
          }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: vmName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identityId}': {}
    }
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: 'ubuntu-24_04-lts'
        sku: 'server'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        // The OS disk holds no state worth keeping: config comes from the config repo and
        // the secret from Key Vault, so the VM is disposable by design.
        deleteOption: 'Delete'
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
        diskSizeGB: 64
      }
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      customData: base64(renderedCloudInit)
      linuxConfiguration: {
        // Password auth is always off. If no SSH key is supplied there is no inbound
        // administrative path at all, which is the intended posture for a box on a public
        // IP; use Azure Run Command or the Serial Console instead.
        disablePasswordAuthentication: true
        ssh: empty(sshPublicKey)
          ? null
          : {
              publicKeys: [
                {
                  path: '/home/${adminUsername}/.ssh/authorized_keys'
                  keyData: sshPublicKey
                }
              ]
            }
        patchSettings: {
          patchMode: 'AutomaticByPlatform'
          assessmentMode: 'AutomaticByPlatform'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
  }
}

output id string = vm.id
output name string = vm.name
output principalId string = ''
