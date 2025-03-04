metadata description = 'An app with a static web part and an API'

@description('resource group which acts as the central DNS zone')
param centralResourceGroupName string = 'rg-site-dev-001'

@description('name of the parent DNS zone')
param centralDnsZoneName string = 'az.gayerie.dev'

@description('location of the data')
param location string = resourceGroup().location

@description('name of the app')
param appName string = 'demo'

param staticSiteRepositoryUrl string
param staticSiteRepositoryBranch string = 'main'
param staticSiteBuildLocation string = './'

var uniqueId = uniqueString(resourceGroup().id)

resource staticSite 'Microsoft.Web/staticSites@2024-04-01' = {
  name: 'swa-${appName}-${uniqueId}'
  location: location
  sku: {
    name: 'Standard'
    tier: 'Standard'
  }
  properties: {
    repositoryUrl: staticSiteRepositoryUrl
    branch: staticSiteRepositoryBranch
    allowConfigFileUpdates: true
    provider: 'GitHub'
    enterpriseGradeCdnStatus: 'Disabled'
    publicNetworkAccess: 'Enabled'
    buildProperties: {
       appLocation: staticSiteBuildLocation
    }
  }
}

resource staticSiteCustomDomain 'Microsoft.Web/staticSites/customDomains@2024-04-01' = {
  parent: staticSite
  name: '${appName}.${centralDnsZoneName}'
}

resource staticSiteUserProvidedFunctionApp 'Microsoft.Web/staticSites/userProvidedFunctionApps@2024-04-01' = {
  parent: staticSite
  name: 'swa-func-${appName}-${uniqueId}'
  properties: {
    functionAppRegion: location
    functionAppResourceId: 'TODO'
  }
}

resource appsettings 'Microsoft.Web/staticSites/config@2024-04-01' = {
  name: 'appsettings'
  parent: staticSite
  properties: {
    AADB2C_PROVIDER_CLIENT_ID: 'TODO'
    AADB2C_PROVIDER_CLIENT_SECRET: 'TODO'
  }
}

module updateCentralDns 'central_dns_cname.bicep' = {
  name: 'updateCentralDns'
  scope: resourceGroup(centralResourceGroupName)
  params: {
    centralDnsZoneName: centralDnsZoneName
    name: appName
    value: staticSite.properties.defaultHostname
  }
}

output staticSiteGitHubDeploymentToken string = staticSite.properties.repositoryToken
