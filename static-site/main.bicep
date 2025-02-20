metadata description = 'Creates a hosting for a static site'

@description('name of the site')
param appName string = 'demo'

@description('location of the data')
param location string = resourceGroup().location

var uniqueId = uniqueString(resourceGroup().id)
var publicIpAddressName = 'pip-${appName}-${uniqueId}-${location}'
var vnetName = 'vnet-${appName}-${uniqueId}-${location}'
var applicationGatewayName = 'agw-${appName}-${uniqueId}-${location}'
var storageAccountForStaticFilesName = 'stwww${toLower(appName)}${uniqueId}'

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.0.0.0/16'
      ]
    }
    subnets: [
      {
        name: 'subnet-agw'
        properties: {
          addressPrefix: '10.0.0.0/24'
          serviceEndpoints:[
            {
              locations: [location]
              service: 'Microsoft.Storage'
            }
          ]
        }
      }
    ]
  }
}

resource publicIPAddress 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: publicIpAddressName
  location: location
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAddressVersion: 'IPv4'
    publicIPAllocationMethod: 'Static'
  }
}

resource applicationGateway 'Microsoft.Network/applicationGateways@2024-05-01' = {
  name: applicationGatewayName
  location: location
  properties: {
    sku: {
      name: 'Standard_v2'
      tier: 'Standard_v2'
    }
    enableHttp2: true

    autoscaleConfiguration: {
      minCapacity: 0
      maxCapacity: 2
    }

    sslCertificates: []

    frontendIPConfigurations: [
      {
        name: 'publicFrontEndIP'
        properties: {
          publicIPAddress: {
            id: publicIPAddress.id
          }
        }
      }
    ]

    frontendPorts: [
      {
        name: 'publicFrontEndHttpPort'
        properties: {
          port: 80
        }
      }
    ]

    gatewayIPConfigurations: [
      {
        name: 'subnet-agw'
        properties: {
          subnet: {
            id: resourceId('Microsoft.Network/virtualNetworks/subnets', virtualNetwork.name, 'subnet-agw')
          }
        }
      }
    ]

    httpListeners: [
      {
        name: 'publicHttpListener'
        properties: {
          protocol: 'Http'
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendIPConfigurations', applicationGatewayName, 'publicFrontEndIP')
          }
          frontendPort: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendPorts', applicationGatewayName, 'publicFrontEndHttpPort')
          }
        }
      }
    ]

    backendHttpSettingsCollection: [
      {
        name: 'staticSiteBackendHttpsSettings'
        properties: {
          protocol: 'Https'
          port: 443
          pickHostNameFromBackendAddress: true
          probeEnabled: true
          probe: {
            id: resourceId('Microsoft.Network/applicationGateways/probes', applicationGatewayName, 'staticSiteProbe')
          }
        }
      }
    ]

    probes: [
      {
        name: 'staticSiteProbe'
        properties: {
          pickHostNameFromBackendHttpSettings: true
          protocol: 'Https'
          port: 443
          timeout: 30
          interval: 60
          unhealthyThreshold: 3
          path: '/public/index.html'
          match: {
            statusCodes: ['200-399', '404']
          }
        }
      }
    ]

    backendAddressPools: [
      {
        name: 'staticSiteBackendAddressPool'
        properties: {
          backendAddresses: [
            {
              fqdn: '${storageAccountForStaticFiles.name}.blob.${environment().suffixes.storage}'
            }
          ]
        }
      }
    ]

    rewriteRuleSets: [
      {
        name: 'rewritePathToStaticSite'
        properties: {
           rewriteRules: [
            {
              name: 'slashToHome'
              ruleSequence: 1
              conditions: [
                {
                  pattern: '^/$'
                  variable: 'var_uri_path'
                }
              ]
              actionSet: {
                urlConfiguration: {
                  modifiedPath: '/index.html'
                }
              }
            }
            {
              name: 'addContainerPath'
              ruleSequence: 100
              actionSet: {
                urlConfiguration: {
                  modifiedPath: '/public{var_uri_path}'
                }
              }
            }
          ]
        }
      }
    ]

    requestRoutingRules: [
      {
        name: 'staticSiteRequestRoutingRule'
        properties: {
          ruleType: 'Basic'
          priority: 100
          rewriteRuleSet: {
            id: resourceId('Microsoft.Network/applicationGateways/rewriteRuleSets', applicationGatewayName, 'rewritePathToStaticSite')
          }
          httpListener: {
            id: resourceId('Microsoft.Network/applicationGateways/httpListeners', applicationGatewayName, 'publicHttpListener')
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/applicationGateways/backendAddressPools', applicationGatewayName, 'staticSiteBackendAddressPool')
          }
          backendHttpSettings: {
            id: resourceId('Microsoft.Network/applicationGateways/backendHttpSettingsCollection', applicationGatewayName, 'staticSiteBackendHttpsSettings')
          }
        }
      }
    ]
  }
}

resource storageAccountForStaticFiles 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountForStaticFilesName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    allowBlobPublicAccess: true
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Deny'
      virtualNetworkRules: [
        {
          action: 'Allow'
          id: resourceId('Microsoft.Network/virtualNetworks/subnets', virtualNetwork.name, 'subnet-agw')
        }
      ]
    }
  }
}

resource storageAccountBlobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  name: 'default'
  parent: storageAccountForStaticFiles
  properties: {
    isVersioningEnabled: false
  }
}

resource storageAccountContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2021-06-01' = {
  parent: storageAccountBlobService
  name: 'public'
  properties: {
    publicAccess: 'Blob'
  }
}

output publicIpAddress string = publicIPAddress.properties.ipAddress
