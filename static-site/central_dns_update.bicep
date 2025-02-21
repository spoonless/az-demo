param centralDnsZoneName string
param childDnsZoneName string
param childDnsNameServers string[]


resource publicDnsZone 'Microsoft.Network/dnsZones@2018-05-01' existing = {
  name: centralDnsZoneName
}

resource publicChildDnsZoneRecord 'Microsoft.Network/dnsZones/NS@2018-05-01' = {
  parent: publicDnsZone
  name: childDnsZoneName
  properties: {
    TTL: 3600
    NSRecords: [for nameServer in childDnsNameServers: {
      nsdname: nameServer
    }]
  }
}
