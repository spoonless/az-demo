metadata description = 'Creates a hosting for a static site'

@description('name of the site')
param site string = 'earth'

@description('location of the data')
param location string = resourceGroup().location

var uniqueStorageName = 'st${site}${uniqueString(resourceGroup().id)}'

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: uniqueStorageName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
}

resource storageAccountBlob 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  name: 'default'
  parent: storageAccount
}

resource publicIPAddress 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: 'ip-${site}-${uniqueString(resourceGroup().id)}-001' 
  location: location
  sku:{
      name:'Basic'
      tier:'Regional'
  }
  properties: {
    publicIPAddressVersion: 'IPv4'
  }
}

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: 'vnet-${site}-${uniqueString(resourceGroup().id)}-001'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.0.0.0/16'
      ]
    }
    subnets: [
      {
        name: 'subnet-001'
        properties: {
          addressPrefix: '10.0.0.0/24'
        }
      }
    ]
  }
}

var applicationGatewayName = 'agw-${site}-${uniqueString(resourceGroup().id)}'

resource applicationGateway 'Microsoft.Network/applicationGateways@2024-05-01' = {
  name: applicationGatewayName
  location: location
  properties:{
    sku: {
      capacity: 1
      name: 'Basic'
      tier: 'Basic'
    }

    enableHttp2: true

    frontendIPConfigurations: [
      {
        name: 'agwFrontendIP'
        properties: {
          publicIPAddress: {
            id: publicIPAddress.id
          }
        }
      }
    ]
    
    gatewayIPConfigurations: [
      {
        name: 'agwIPConfiguration'
        properties: {
          subnet: {
            id: resourceId('Microsoft.Network/virtualNetworks/subnets', virtualNetwork.name, 'subnet-001')
          }
        }
      }
    ]

    sslCertificates: [
      {
        name: 'agwSslCertificateHttps'
        properties:{
          data: 'todo'
          password: 'todo'
        }
      }
    ]

    frontendPorts: [
      {
        name: 'agwFrontendPort'
        properties: {
          port: 80
        }
      }
      {
        name: 'agwFrontendSecuredPort'
        properties: {
          port: 443
        }
      }
    ]

    backendHttpSettingsCollection: [
      {
        name: 'backendHttpSettings'
        properties: {
          protocol: 'Https'
          port: 443
          probeEnabled: false
          cookieBasedAffinity: 'Disabled'
        }
      }
    ]

    httpListeners: [
      {
        name: 'agwHttpListener'
        properties: {
          protocol: 'Http'
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendIPConfigurations', applicationGatewayName, 'agwFrontendIP')
          }
          frontendPort: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendPorts', applicationGatewayName, 'agwFrontendPort')
          }
        }
      }
      {
        name: 'agwHttpsListener'
        properties: {
          protocol: 'Https'
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendIPConfigurations', applicationGatewayName, 'agwFrontendIP')
          }
          frontendPort: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendPorts', applicationGatewayName, 'agwFrontendSecuredPort')
          }
          sslCertificate: {
            id: resourceId('Microsoft.Network/applicationGateways/sslCertificates', applicationGatewayName, 'agwSslCertificateHttps')
          }
        }
      }
    ]

    backendAddressPools: [
      {
        name: 'agwBackendAddressPoolStorage'
        properties:{
          backendAddresses:[
            {
              fqdn: '${storageAccount.name}.blob.${environment().suffixes.storage}'
            }
          ]
        }
      }
    ]

    redirectConfigurations:[
      {
        name:'redirectConfigurationHttpToHttps'
        properties:{
          redirectType:'Temporary'
          targetListener:{
            id: resourceId('Microsoft.Network/applicationGateways/httpListeners', applicationGatewayName, 'agwHttpsListener')
          }
          includePath: true
          includeQueryString: true
        }
      }
    ]

    requestRoutingRules: [
      {
        name:'httpToHttpsRule'
        properties:{
          ruleType: 'Basic'
          httpListener: {
            id: resourceId('Microsoft.Network/applicationGateways/httpListeners', applicationGatewayName, 'agwHttpListener')
          }
          redirectConfiguration:{
            id: resourceId('Microsoft.Network/applicationGateways/redirectConfigurations', applicationGatewayName, 'redirectConfigurationHttpToHttps')
          }
        }
      }
      {
        name: 'securedStorageRule'
        properties: {
          ruleType:'Basic'
          backendAddressPool: {
            id: resourceId('Microsoft.Network/applicationGateways/backendAddressPools', applicationGatewayName, 'agwBackendAddressPoolStorage')
          }
          httpListener: {
            id: resourceId('Microsoft.Network/applicationGateways/httpListeners', applicationGatewayName, 'agwHttpsListener')
          }
          backendHttpSettings: {
            id: resourceId('Microsoft.Network/applicationGateways/backendHttpSettingsCollection', applicationGatewayName, 'backendHttpSettings')
          }
        }
      }
    ]
  }
}
