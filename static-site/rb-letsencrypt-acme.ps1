[OutputType([string])]

param(
    [Parameter()]
    [String] $KeyVault = "kv-envvars-demo-01",

    [Parameter()]
    [String] $ResourceGroup = "rg-demo-france-central",

    [Parameter()]
    [String] $ContactEmail = "david@gayerie.dev",

    [Parameter()]
    [String] $managedIdentityClientId = "9bc01a9c-f0eb-4cd6-8097-aec5a091990f"
)

#region Imports

# Make sure that this modules are present in the runbook environment. Go to
# Modules gallery in the automations account and import the following modules:

Import-Module "Az.KeyVault"
Import-Module "Az.Dns"
Import-Module "ACME-PS"

#endregion

#region Logging

function Log-Message {
    [CmdletBinding()]
    Param
    (
        [Parameter(Mandatory = $true, Position = 0)]
        [String] $LogMessage,

        [Parameter()]
        [String] $Prefix = "general",

        [Parameter()]
        [ValidateSet("INFO", "WARN", "ERROR", "DEBUG")]
        [String] $Level = "INFO"
    )

    $Message = "$(Get-Date) $Level [$Prefix] $LogMessage"

    # Write errors to error stream
    if ($Level -eq "ERROR") {
        Write-Error $Message
        throw $Message
    } else {
        # Write default to output
        Write-Output $Message
    }
}

# endregion

#region Login

$ErrorActionPreference = 'Stop'

# Ensures you do not inherit an AzContext in your runbook
Disable-AzContextAutosave -Scope Process

# Connect to Azure with user-assigned managed identity
$AzureContext = (Connect-AzAccount -Identity -AccountId $managedIdentityClientId).context

# set and store context
$AzureContext = Set-AzContext -SubscriptionName $AzureContext.Subscription -DefaultProfile $AzureContext

#endregion

#region Main program

Log-Message "ACME Renew Runbook for Let's Encrypt"

# Temp dir
$AcmeTempDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "acme"
Log-Message "Using temp dir $AcmeTempDir"
$AcmeService = "LetsEncrypt"

# Find all the A DNS records within a subscription
Log-Message "Finding A DNS records in this subscription"
$Records = Get-AzDnsZone | ForEach-Object {
    Get-AzDnsRecordSet -ZoneName $_.Name -ResourceGroupName $_.ResourceGroupName
} | Where-Object { $_.RecordType -eq "CNAME" }

Log-Message "Found $($Records.length) DNS record(s)"
$Records | Foreach-Object -Process {
    Log-Message "$($_.ZoneName) - $($_.Name)"
}

Log-Message "Preparing ACME account" -Prefix "acme-account"
if (!(Test-Path (Join-Path -Path $AcmeTempDir -ChildPath "Account.xml") -PathType leaf)) {
    New-ACMEState -Path $AcmeTempDir
    Get-ACMEServiceDirectory -State $AcmeTempDir -ServiceName $AcmeService
    New-ACMENonce -State $AcmeTempDir
    New-ACMEAccountKey -State $AcmeTempDir -PassThru
    New-ACMEAccount -State $AcmeTempDir -EmailAddresses $ContactEmail -AcceptTOS
    Log-Message "ACME account created" -Prefix "acme-account"
}
else {
    Log-Message "ACME Account exists" -Prefix "acme-account"
}

# Process all the A DNS records
$Records | ForEach-Object -Process {

    if ($_.Name -eq "@") {
        # Get the full domain name
        $Domain = $($_.ZoneName)
    } else {
        # Get the full domain name
        $Domain = "$($_.Name).$($_.ZoneName)"
    }

    $KeyName = $Domain -replace "\.", "_"

    # Set some local vars for handling and storing the certificate
    $CertificatePassword = ConvertTo-SecureString $_.ZoneName -AsPlainText -Force
    $CertificateExportPath = Join-Path -Path $AcmeTempDir -ChildPath "$($KeyName).pfx"

    Log-Message "Processing subdomain" -Prefix $Domain

    # Try to get the certificate
    $Certificate = Get-AzKeyVaultCertificate -VaultName $KeyVault -Name $KeyName

    # Get information on the certificate if it exists
    # check its expiry and return if it is still fresh enough
    if ($Certificate) {
        $Expires = $Certificate.Expires
        $ExpiresSpan = New-TimeSpan -Start (Get-Date) -End $Expires

        Log-Message "Certificate expiring: $Expires" -Prefix $Domain
        if ($ExpiresSpan.Days -gt 10) {
            Log-Message "Certificate will not expire next week. Skipping this one." -Prefix $Domain
            continue
        }
    }

    # If not returned, start first to create an ACME order
    $DnsIdentifier = New-ACMEIdentifier $Domain
    $Order = New-ACMEOrder -State $AcmeTempDir -Identifiers $DnsIdentifier
    Log-Message "Created order $($Order.ResourceUrl)"

    # When the order is created we can get the authorization and try to fullfil the challenges
    try {
        # Fetch authorization and create a DNS challenge (dns-01)
        $Authorization = Get-ACMEAuthorization -State $AcmeTempDir -Order $Order
        $Challenge = Get-ACMEChallenge -State $AcmeTempDir -Authorization $Authorization -Type "dns-01"

        # Get the record name and content
        $DnsTxtRecordName = $Challenge.Data.TxtRecordName -replace ".$($_.ZoneName)", ""
        $DnsTxtValue = $Challenge.Data.Content

        # Create a challenge TXT record
        Log-Message "Creating DNS record $DnsTxtRecordName"
        New-AzDnsRecordSet -Name $DnsTxtRecordName -RecordType TXT -ZoneName $_.ZoneName -TTL 60 -ResourceGroupName $_.ResourceGroupName -DnsRecords @(New-AzDnsRecordConfig -Value $DnsTxtValue) -Overwrite

        while ($DnsTxtRecordProvisioned -eq $null) {
            Start-Sleep -Seconds 5
            $DnsTxtRecordProvisioned = Get-AzDnsRecordSet -Name $DnsTxtRecordName -RecordType TXT -ZoneName $_.ZoneName -ResourceGroupName $_.ResourceGroupName -ErrorAction Ignore
        }

        # Complete the order, ACME will check for the DNS TXT record
        Log-Message "Completing ACME order" -Prefix $Domain
        $Challenge | Complete-ACMEChallenge -State $AcmeTempDir

        # Wait for the order to update
        Log-Message "Waiting for the order to complete" -Prefix $Domain
        while ($Order.Status -notin ("ready", "invalid")) {
            Start-Sleep -Seconds 5
            $Order | Update-ACMEOrder -State $AcmeTempDir -PassThru
        }

        # If the order seems to be invalid, loop over it and go to the catch block
        if ($Order.Status -eq "invalid") {
            $InvalidMessage = "Your order has been marked as invalid - certificate cannot be issued."
            Log-Message $InvalidMessage -Prefix $Domain -Level "ERROR"
        }

        # Complete the order - this will issue a certificate singing request
        Complete-ACMEOrder -State $AcmeTempDir -Order $Order -GenerateCertificateKey

        # Now we wait until the ACME service provides the certificate url
        Log-Message "Waiting for the Certificate URL"
        while (-not $Order.CertificateUrl) {
            Start-Sleep -Seconds 15
            $Order | Update-ACMEOrder -State $AcmeTempDir -PassThru
        }

        # Create a password for the certificate and export it
        Log-Message "Exporting certificate to $CertificateExportPath" -Prefix $Domain
        Export-ACMECertificate -State $AcmeTempDir `
            -Order $Order `
            -Path $CertificateExportPath `
            -Password $CertificatePassword

        # Importing the certificate
        Log-Message "Importing certificate to $KeyVault" -Prefix $Domain
        Import-AzKeyVaultCertificate -VaultName $KeyVault -Name $KeyName -FilePath $CertificateExportPath -Password $CertificatePassword

        Log-Message "Done" -Prefix $Domain
    }
    catch {
        Log-Message "Processing of $Domain failed" -Level "WARN" -Prefix $Domain
        Log-Message $_ -Level "WARN" -Prefix $Domain
    }
    finally {
        # Cleanup the DNS record
        Remove-AzDnsRecordSet -Name $DnsTxtRecordName -RecordType TXT -ZoneName $_.ZoneName -ResourceGroupName $_.ResourceGroupName
    }
}

#endregion
