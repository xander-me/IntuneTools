<#
.SYNOPSIS
    Collects the Windows Autopilot hardware hash silently and imports it into Intune with a group tag.

.DESCRIPTION
    Designed to run unattended as SYSTEM from ManageEngine Endpoint Central (Custom Script) or any
    other management agent. No modules are downloaded; the hash is read from the MDM WMI bridge and
    uploaded with plain Microsoft Graph REST calls.

    1. Reads serial number and hardware hash (MDM_DevDetail_Ext01).
    2. Always writes an Intune import CSV locally as a fallback.
    3. Unless -SkipUpload is given: gets an app-only Graph token (client secret or certificate),
       skips devices that are already registered (optionally correcting the group tag), imports the
       device and waits for the import result.

    No credentials are stored in this script. Pass them as parameters at run time.
    Required Graph application permission: DeviceManagementServiceConfig.ReadWrite.All.

.PARAMETER TenantId
    Entra tenant ID (GUID) or primary domain.
.PARAMETER ClientId
    Application (client) ID of the app registration.
.PARAMETER ClientSecret
    Client secret. Use a short-lived secret and delete it after the rollout.
.PARAMETER CertificateThumbprint
    Thumbprint of a certificate with private key in Cert:\LocalMachine\My, used instead of a secret.
.PARAMETER GroupTag
    Autopilot group tag. Default: GR_PC_DK.
.PARAMETER SkipUpload
    Only collect and write the local CSV.
.PARAMETER UpdateGroupTag
    If the device is already registered with another group tag, change it to -GroupTag.
.PARAMETER WaitMinutes
    Maximum minutes to wait for the import result. Default: 10.
.PARAMETER OutputFolder
    Folder for log and CSV. Default: C:\ProgramData\AutopilotHash.

.EXAMPLE
    powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\Get-AutopilotHardwareHash.ps1 -TenantId contoso.onmicrosoft.com -ClientId <app-id> -ClientSecret <secret>

.NOTES
    Exit codes: 0 imported or already registered, 10 local CSV only (-SkipUpload),
    1 not elevated / unsupported, 2 hash collection failed, 3 authentication failed,
    4 Graph request failed, 5 import failed, 6 import timed out, 7 invalid parameters.
    Windows PowerShell 5.1, Windows 10 1703+ / Windows 11.
#>
[CmdletBinding(DefaultParameterSetName = 'Secret')]
param(
    [Parameter(ParameterSetName = 'Secret')][Parameter(ParameterSetName = 'Certificate')][string]$TenantId,
    [Parameter(ParameterSetName = 'Secret')][Parameter(ParameterSetName = 'Certificate')][string]$ClientId,
    [Parameter(ParameterSetName = 'Secret')][string]$ClientSecret,
    [Parameter(ParameterSetName = 'Certificate', Mandatory)][string]$CertificateThumbprint,
    [Parameter(ParameterSetName = 'Local', Mandatory)][switch]$SkipUpload,
    [ValidatePattern('^[A-Za-z0-9_\-\.]{1,100}$')][string]$GroupTag = 'GR_PC_DK',
    [switch]$UpdateGroupTag,
    [ValidateRange(1, 60)][int]$WaitMinutes = 10,
    [string]$OutputFolder = (Join-Path $env:ProgramData 'AutopilotHash')
)

$ErrorActionPreference = 'Stop'
$script:GraphBase = 'https://graph.microsoft.com/v1.0'
$script:LogFile = $null
$script:Mode = $PSCmdlet.ParameterSetName

function Write-Log {
    param([string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO')
    $line = '{0:u} [{1}] {2}' -f (Get-Date).ToUniversalTime(), $Level, $Message
    if ($script:LogFile) { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 }
    [Console]::Out.WriteLine($line)  # not the pipeline: keeps function return values clean
}

function ConvertTo-Base64Url {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function New-AutopilotCsvContent {
    # Intune import format. Header names must match exactly; Intune rejects Unicode (UTF-16) files.
    param([Parameter(Mandatory)][string]$SerialNumber, [Parameter(Mandatory)][string]$HardwareHash, [string]$GroupTag, [string]$ProductId = '')
    foreach ($value in @($SerialNumber, $GroupTag, $ProductId)) {
        if ($value -match '[",\r\n]') { throw "Value contains characters not allowed in the import CSV: $value" }
    }
    "Device Serial Number,Windows Product ID,Hardware Hash,Group Tag`r`n$SerialNumber,$ProductId,$HardwareHash,$GroupTag`r`n"
}

function New-ClientAssertion {
    # JWT for certificate-based client credentials (RS256, x5t = base64url of the SHA-1 thumbprint).
    param([Parameter(Mandatory)][System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
          [Parameter(Mandatory)][string]$TenantId, [Parameter(Mandatory)][string]$ClientId)
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $header = @{ alg = 'RS256'; typ = 'JWT'; x5t = (ConvertTo-Base64Url $Certificate.GetCertHash()) } | ConvertTo-Json -Compress
    $payload = @{
        aud = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
        iss = $ClientId; sub = $ClientId; jti = [guid]::NewGuid().ToString()
        nbf = $now - 60; exp = $now + 600
    } | ConvertTo-Json -Compress
    $unsigned = (ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes($header))) + '.' + (ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes($payload)))
    $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($Certificate)
    if (-not $rsa) { throw 'The certificate has no usable RSA private key.' }
    $signature = $rsa.SignData([Text.Encoding]::UTF8.GetBytes($unsigned),
        [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    "$unsigned.$(ConvertTo-Base64Url $signature)"
}

function Test-IsElevated {
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-DeviceHardwareInfo {
    $serial = (Get-CimInstance -ClassName Win32_BIOS).SerialNumber
    if ([string]::IsNullOrWhiteSpace($serial)) { throw 'The BIOS returned no serial number.' }
    $devDetail = Get-CimInstance -Namespace 'root/cimv2/mdm/dmmap' -ClassName 'MDM_DevDetail_Ext01' `
        -Filter "InstanceID='Ext' AND ParentID='./DevDetail'"
    if (-not $devDetail -or [string]::IsNullOrWhiteSpace($devDetail.DeviceHardwareData)) {
        throw 'The MDM bridge returned no hardware hash (DeviceHardwareData).'
    }
    [pscustomobject]@{ SerialNumber = $serial.Trim(); HardwareHash = $devDetail.DeviceHardwareData }
}

function Get-GraphToken {
    param([string]$TenantId, [string]$ClientId, [string]$ClientSecret, [string]$CertificateThumbprint)
    $body = @{ client_id = $ClientId; scope = 'https://graph.microsoft.com/.default'; grant_type = 'client_credentials' }
    if ($CertificateThumbprint) {
        $cert = Get-Item -LiteralPath ("Cert:\LocalMachine\My\" + $CertificateThumbprint.Replace(' ', ''))
        $body.client_assertion_type = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'
        $body.client_assertion = New-ClientAssertion -Certificate $cert -TenantId $TenantId -ClientId $ClientId
    } else {
        $body.client_secret = $ClientSecret
    }
    (Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
        -Body $body -ContentType 'application/x-www-form-urlencoded').access_token
}

function Invoke-Graph {
    param([string]$Method = 'Get', [Parameter(Mandatory)][string]$Path, $Body, [Parameter(Mandatory)][string]$Token)
    $params = @{ Method = $Method; Uri = "$script:GraphBase/$Path"; Headers = @{ Authorization = "Bearer $Token" }; UseBasicParsing = $true }
    if ($null -ne $Body) { $params.Body = ($Body | ConvertTo-Json -Depth 5); $params.ContentType = 'application/json' }
    for ($attempt = 1; ; $attempt++) {
        try { return Invoke-RestMethod @params }
        catch {
            $status = 0
            if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
            if (($status -eq 429 -or $status -ge 500) -and $attempt -lt 5) {
                Write-Log "Graph $Method $Path returned $status; retry $attempt of 4." 'WARN'
                Start-Sleep -Seconds ([math]::Min(60, 5 * [math]::Pow(2, $attempt - 1)))
                continue
            }
            throw
        }
    }
}

function Invoke-Main {
    New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $OutputFolder 'Logs') -Force | Out-Null
    $script:LogFile = Join-Path $OutputFolder 'Logs\AutopilotHash.log'
    Write-Log "Start. Computer=$env:COMPUTERNAME GroupTag=$GroupTag Mode=$script:Mode"

    if (-not (Test-IsElevated)) {
        Write-Log 'Must run as SYSTEM or elevated administrator.' 'ERROR'; return 1
    }
    if (-not $SkipUpload -and (-not $TenantId -or -not $ClientId -or ($script:Mode -eq 'Secret' -and -not $ClientSecret))) {
        Write-Log 'TenantId, ClientId and ClientSecret or CertificateThumbprint are required unless -SkipUpload is used.' 'ERROR'; return 7
    }

    try { $device = Get-DeviceHardwareInfo }
    catch { Write-Log "Hash collection failed: $($_.Exception.Message)" 'ERROR'; return 2 }
    Write-Log "Serial=$($device.SerialNumber) HashLength=$($device.HardwareHash.Length)"

    $csvPath = Join-Path $OutputFolder ("{0}.csv" -f ($device.SerialNumber -replace '[^A-Za-z0-9_\-]', '_'))
    [IO.File]::WriteAllText($csvPath, (New-AutopilotCsvContent -SerialNumber $device.SerialNumber -HardwareHash $device.HardwareHash -GroupTag $GroupTag), [Text.Encoding]::ASCII)
    Write-Log "Local import CSV written: $csvPath"
    if ($SkipUpload) { Write-Log 'SkipUpload: done.'; return 10 }

    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    try { $token = Get-GraphToken -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret -CertificateThumbprint $CertificateThumbprint }
    catch { Write-Log "Authentication failed: $($_.Exception.Message)" 'ERROR'; return 3 }

    try {
        $serialFilter = [uri]::EscapeDataString("contains(serialNumber,'$($device.SerialNumber.Replace("'", "''"))')")
        $existing = @((Invoke-Graph -Path "deviceManagement/windowsAutopilotDeviceIdentities?`$filter=$serialFilter" -Token $token).value |
            Where-Object { $_.serialNumber -eq $device.SerialNumber })
        if ($existing.Count -gt 0) {
            $current = $existing[0]
            Write-Log "Already registered in Autopilot (id $($current.id), group tag '$($current.groupTag)')."
            if ($UpdateGroupTag -and $current.groupTag -ne $GroupTag) {
                Invoke-Graph -Method Post -Path "deviceManagement/windowsAutopilotDeviceIdentities/$($current.id)/updateDeviceProperties" `
                    -Body @{ groupTag = $GroupTag } -Token $token | Out-Null
                Write-Log "Group tag changed to '$GroupTag'."
            }
            return 0
        }

        $import = Invoke-Graph -Method Post -Path 'deviceManagement/importedWindowsAutopilotDeviceIdentities' -Token $token -Body @{
            '@odata.type'      = '#microsoft.graph.importedWindowsAutopilotDeviceIdentity'
            groupTag           = $GroupTag
            serialNumber       = $device.SerialNumber
            productKey         = ''
            hardwareIdentifier = $device.HardwareHash
            state              = @{
                '@odata.type'        = 'microsoft.graph.importedWindowsAutopilotDeviceIdentityState'
                deviceImportStatus   = 'pending'; deviceRegistrationId = ''; deviceErrorCode = 0; deviceErrorName = ''
            }
        }
        Write-Log "Import submitted (id $($import.id))."
    }
    catch { Write-Log "Graph request failed: $($_.Exception.Message)" 'ERROR'; return 4 }

    $deadline = (Get-Date).AddMinutes($WaitMinutes)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 30
        try { $state = (Invoke-Graph -Path "deviceManagement/importedWindowsAutopilotDeviceIdentities/$($import.id)" -Token $token).state }
        catch { Write-Log "Status check failed: $($_.Exception.Message)" 'WARN'; continue }
        switch ($state.deviceImportStatus) {
            'complete' {
                Write-Log 'Import complete. Intune syncs the device to Autopilot shortly.'
                try { Invoke-Graph -Method Delete -Path "deviceManagement/importedWindowsAutopilotDeviceIdentities/$($import.id)" -Token $token | Out-Null } catch { }
                return 0
            }
            'error' {
                Write-Log "Import failed: $($state.deviceErrorCode) $($state.deviceErrorName)" 'ERROR'
                return 5
            }
            default { Write-Log "Import status: $($state.deviceImportStatus)" }
        }
    }
    Write-Log "Import not finished after $WaitMinutes minutes; check Intune > Windows Autopilot devices." 'WARN'
    return 6
}

# Run only when executed, not when dot-sourced by tests.
if ($MyInvocation.InvocationName -ne '.') {
    # A 32-bit agent (WOW64) cannot reach the 64-bit MDM WMI bridge reliably; relaunch in 64-bit PowerShell.
    if ($env:PROCESSOR_ARCHITEW6432 -eq 'AMD64' -and -not [Environment]::Is64BitProcess) {
        $argsList = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
        foreach ($p in $PSBoundParameters.GetEnumerator()) {
            if ($p.Value -is [switch]) { if ($p.Value) { $argsList += "-$($p.Key)" } } else { $argsList += "-$($p.Key)"; $argsList += "$($p.Value)" }
        }
        & "$env:WINDIR\Sysnative\WindowsPowerShell\v1.0\powershell.exe" @argsList
        exit $LASTEXITCODE
    }
    exit ([int](Invoke-Main | Select-Object -Last 1))
}
