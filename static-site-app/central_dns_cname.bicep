param centralDnsZoneName string
param name string
param value string


resource publicDnsZone 'Microsoft.Network/dnsZones@2018-05-01' existing = {
  name: centralDnsZoneName
}

resource publicChildCnameZoneRecord 'Microsoft.Network/dnsZones/CNAME@2018-05-01' = {
  parent: publicDnsZone
  name: name
  properties: {
    TTL: 3600
    CNAMERecord: {
      cname: value
    }
  }
}
