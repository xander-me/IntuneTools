<#
.SYNOPSIS
    Interactive console report that evaluates Apple devices in Microsoft Intune against
    lifecycle data from endoflife.date and prints a colorized, aligned table (Danish date format).

.DESCRIPTION
    This script:
      - Authenticates to Microsoft Graph using the OAuth2 client credentials flow
        (client_id, client_secret, tenant_id).
      - Retrieves managed devices from Microsoft Intune (deviceManagement/managedDevices)
        and selects key properties (id, deviceName, model, operatingSystem, osVersion, userDisplayName, managementAgent).
      - Filters devices to Apple OS families (iOS, iPadOS, macOS) according to an interactive choice.
      - Fetches release/lifecycle data for iOS, iPadOS and macOS from endoflife.date (public API).
      - Parses each device's OS version to extract the major release and maps it to lifecycle data:
          - Determines EOL date, whether the release is supported, days until EOL, and overall status.
      - Produces:
          - A grouped summary by lifecycle status with colorized counts.
          - A detailed, aligned console table with one row per evaluated device.
      - Supports an option to show only devices that are End Of Life (EOL).

    Console output specifics:
      - Color-coded rows: Supported (Green), EndOfLife (Red), Other/Unknown (Yellow).
      - Dates printed in Danish format: dd-MM-yyyy.
      - Table column widths are fixed and long text is trimmed with an ellipsis.

.CONFIGURATION / IMPORTANT VARIABLES
    The script contains top-level variables that must be supplied or secured:
      - TenantId      : Azure AD tenant (GUID)
      - ClientId      : Azure AD app (GUID)
      - ClientSecret  : Client secret for the app (sensitive!)

    Security recommendation: Do NOT hard-code client secrets in source files.
      - Use environment variables, secure files with restricted ACL, or an Azure Key Vault + managed identity.
      - Consider prompting for secrets at runtime or using a certificate-based credential for apps.

.AUTHENTICATION & PERMISSIONS
    - Authentication method: OAuth2 client credentials (app-only).
    - Required Azure AD Application (Application) permission (minimum recommended):
        DeviceManagementManagedDevices.Read.All
      This allows reading managed device inventory via Microsoft Graph.
    - Ensure the app registration has a client secret or certificate and that admin consent was granted.

.INTERACTIVE PROMPTS
    1) Which OS types to include
       - 1 : All Apple (iOS, iPadOS, macOS)
       - 2 : Only iOS
       - 3 : Only iPadOS
       - 4 : Only macOS
    2) Show only devices with EOL OS? (y/n)
       - Affirmative answers accepted: y, yes, j, ja (case-insensitive)

.OUTPUT
    The script builds and emits a collection of PSCustomObject entries. Each object has these properties:
      - OS                     : Operating system family (iOS, iPadOS, macOS)
      - Model                  : Device model string
      - DeviceName             : Device name in Intune
      - User                   : User display name (cleaned for output)
      - CurrentVersion         : Full OS version string reported by device
      - MajorVer               : Extracted major version (e.g. "16", "17")
      - Status                 : "Supported", "EndOfLife", or "Unknown"
      - SupportPhase           : "Supported", "NearingEOL", "EOL", or "Unknown"
      - EolDate                : DateTime for EOL (if available)
      - DaysToEol              : Integer days until EOL (if available)
      - LowestSupportedVersion : Lowest supported major version according to endoflife.date
      - NewestVersionAvailable : Newest major version according to endoflife.date

    Console outputs:
      - Summary grouped by Status with colorized counts.
      - Detailed table (aligned columns) for each device (colorized by Status).
      - Final line: "Total devices evaluated: N"

.ERRORS, LIMITATIONS & NOTES
    - The script assumes endoflife.date API responses include a .result.releases structure.
    - Parsing of osVersion relies on extracting the first token and major part before '.'; nonstandard version strings may yield "Unknown".
    - Time comparisons are done using local system date (Get-Date).Timezone may affect day calculations.
    - If endoflife.date does not include an explicit eolFrom date, EolDate is left null and days are shown as "-".
    - Rate limits: Be mindful of Microsoft Graph throttling and endoflife.date API usage limits; add caching or delays for large inventories.
    - The script is console/interactive oriented (colorized Write-Host); results are printed rather than exported to files by default.
    - The script uses System.Collections.Generic.Dictionary and PSCustomObject; it is compatible with Windows PowerShell 5.1 and PowerShell 7+.

.SECURITY CONSIDERATIONS
    - Do not commit client secrets into source control.
    - Prefer managed identities, certificates, or Azure Key Vault for production automation.
    - Limit app registration permissions to least-privilege required and grant admin consent only where necessary.

.EXAMPLES / USAGE
    - Interactive usage:
        Launch the script in an interactive PowerShell session and follow prompts to select OS families and whether to show only EOL devices.
    - Non-interactive / automation:
        Instead of embedding secrets, pre-seed secure credentials (environment variables, Key Vault) and modify the script to read them.
        To run unattended, predefine the configuration variables and bypass Read-Host prompts (modify the script to accept parameters
        or supply values from a wrapper that sets $osFilter and $OnlyEol prior to execution).

.NOTES
    - Date formatting in the console is intentionally set to Danish format (dd-MM-yyyy).
    - The script is intended for administrators who manage Apple devices via Microsoft Intune and want a quick lifecycle overview.
    - Consider enhancing the script to export CSV/JSON output, integrate with ticketing systems, or send notifications for NearingEOL/EOL devices.

.AUTHOR
    Original script author: Alexander Christensen
    Documented: GitHub Copilot

#>
<#
    Intune Apple OS Lifecycle Report (interactive, console only)
    - iOS / iPadOS / macOS
    - Uses Microsoft Graph + endoflife.date v1
    - Color-coded console output
    - Danish date format (dd-MM-yyyy)
#>

# =========================
# CONFIG
# =========================
$TenantId     = ""
$ClientId     = ""
$ClientSecret = ""


$Today = (Get-Date).Date

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor DarkCyan
}

# =========================
# INTERACTIVE PROMPTS
# =========================

Write-Host "Which OS types do you want to include?" -ForegroundColor Cyan
Write-Host "  1) All Apple (iOS, iPadOS, macOS)"
Write-Host "  2) Only iOS"
Write-Host "  3) Only iPadOS"
Write-Host "  4) Only macOS"
$osChoice = Read-Host "Choose (1-4)"

switch ($osChoice) {
    "2" { $osFilter = @("iOS") }
    "3" { $osFilter = @("iPadOS") }
    "4" { $osFilter = @("macOS") }
    default { $osFilter = @("iOS","iPadOS","macOS") }
}

$OnlyEol = (Read-Host "Show only devices with EOL OS? (y/n)") -match '^(y|yes|j|ja)$'

# =========================
# 1. Get Graph access token
# =========================
Write-Info "Requesting Graph access token..."
$Body = @{
    client_id     = $ClientId
    client_secret = $ClientSecret
    scope         = "https://graph.microsoft.com/.default"
    grant_type    = "client_credentials"
}

$Token = Invoke-RestMethod -Method Post `
    -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
    -Body $Body

$Hdr = @{ Authorization = "Bearer $($Token.access_token)" }

# =========================
# 2. Get Intune devices
# =========================
Write-Info "Retrieving Intune managed devices..."

$Devices = @()
$Url = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$select=id,deviceName,model,operatingSystem,osVersion,userDisplayName,managementAgent"

do {
    $Res = Invoke-RestMethod -Method Get -Uri $Url -Headers $Hdr
    $Devices += $Res.value
    $Url = $Res.'@odata.nextLink'
} while ($Url)

$AppleDevices = $Devices | Where-Object { $_.operatingSystem -in $osFilter }

Write-Info "Found $($AppleDevices.Count) Apple devices in Intune."

# =========================
# 3. Get endoflife.date data
# =========================
Write-Info "Retrieving OS lifecycle data from endoflife.date..."

function Get-Releases { param($url) (Invoke-RestMethod -Method Get -Uri $url).result.releases }

$IosReleases    = Get-Releases "https://endoflife.date/api/v1/products/ios"
$IpadosReleases = Get-Releases "https://endoflife.date/api/v1/products/ipados"
$MacOsReleases  = Get-Releases "https://endoflife.date/api/v1/products/macos"

function Build-EolInfo {
    param([array]$Releases)

    $dict      = [System.Collections.Generic.Dictionary[string,object]]::new()
    $all       = @()
    $supported = @()

    foreach ($r in $Releases) {
        $cycle = [string]$r.name
        if (-not $cycle) { continue }

        [int]$c = 0
        if ([int]::TryParse($cycle, [ref]$c)) {
            $all += $c
        }

        $eol = $null
        if ($r.eolFrom) {
            try { $eol = [datetime]::Parse($r.eolFrom) } catch {}
        }

        $isSup = -not $r.isEol -and $r.isMaintained
        if ($isSup -and $c -gt 0) {
            $supported += $c
        }

        $dict[$cycle] = [PSCustomObject]@{
            Cycle     = $cycle
            EolDate   = $eol
            Supported = $isSup
        }
    }

    $lowest = if ($supported.Count) { ($supported | Sort-Object | Select-Object -First 1).ToString() } else { "-" }
    $newest = if ($all.Count)       { ($all       | Sort-Object | Select-Object -Last 1).ToString() }  else { "-" }

    return [PSCustomObject]@{
        Map             = $dict
        LowestSupported = $lowest
        NewestAvailable = $newest
    }
}

$IosEol    = Build-EolInfo $IosReleases
$IpadosEol = Build-EolInfo $IpadosReleases
$MacOsEol  = Build-EolInfo $MacOsReleases

# =========================
# 4. Build report
# =========================
Write-Info "Calculating lifecycle status per device..."

$Report = foreach ($d in $AppleDevices) {

    $ver = $d.osVersion
    if (-not $ver) { continue }

    # Extract major version (e.g. "26" from "26.0 (25A354)")
    $major = ($ver -split '\s+')[0] -split '\.' | Select-Object -First 1

    switch ($d.operatingSystem) {
        "iOS"    { $info = $IosEol }
        "iPadOS" { $info = $IpadosEol }
        "macOS"  { $info = $MacOsEol }
        default  { $info = $null }
    }
    if (-not $info) { continue }

    $map = $info.Map

    $status    = "Unknown"
    $phase     = "Unknown"
    $eol       = $null
    $daysToEol = $null

    if ($map.ContainsKey($major)) {
        $entry = $map[$major]
        $eol   = $entry.EolDate

        if ($entry.Supported) {
            $status = "Supported"
            if ($eol) {
                $daysToEol = ($eol - $Today).Days
                if ($daysToEol -le 180 -and $daysToEol -gt 0) {
                    $phase = "NearingEOL"
                }
                elseif ($daysToEol -gt 180) {
                    $phase = "Supported"
                }
                else {
                    $phase  = "EOL"
                    $status = "EndOfLife"
                }
            }
            else {
                $phase = "Supported"
            }
        }
        else {
            $status = "EndOfLife"
            $phase  = "EOL"
            if ($eol) { $daysToEol = ($eol - $Today).Days }
        }
    }

    [PSCustomObject]@{
        OS                     = $d.operatingSystem
        Model                  = $d.model
        DeviceName             = $d.deviceName
        User                   = $d.userDisplayName
        CurrentVersion         = $ver
        MajorVer               = $major
        Status                 = $status
        SupportPhase           = $phase
        EolDate                = $eol
        DaysToEol              = $daysToEol
        LowestSupportedVersion = $info.LowestSupported
        NewestVersionAvailable = $info.NewestAvailable
    }
}

if ($OnlyEol) {
    $Report = $Report | Where-Object Status -eq "EndOfLife"
}

# =========================
# 5. Summary
# =========================
Write-Host ""
Write-Host "Apple OS lifecycle – summary" -ForegroundColor Cyan

$summary = $Report | Group-Object Status
foreach ($s in $summary) {
    $color = switch ($s.Name) {
        "Supported" { "Green" }
        "EndOfLife" { "Red" }
        default     { "Yellow" }
    }
    Write-Host ("  {0,-10}: {1,4}" -f $s.Name, $s.Count) -ForegroundColor $color
}
Write-Host ""

# =========================
# 6. Console table (aligned, DK date format)
# =========================

# Column widths
$W_OS     = 7
$W_MODEL  = 14
$W_NAME   = 20
$W_USER   = 20
$W_CUR    = 16
$W_STAT   = 11
$W_PHASE  = 11
$W_DAYS   = 9
$W_EOL    = 12
$W_LOW    = 8
$W_NEW    = 8

function Trim-Col {
    param($t,$w)
    if (-not $t) { $t = "-" }
    if ($t.Length -gt $w) {
        return $t.Substring(0,$w-1) + "…"
    } else {
        return $t.PadRight($w)
    }
}

Write-Host "Apple devices – OS lifecycle details" -ForegroundColor Cyan

$header =
    (Trim-Col "OS"       $W_OS)   + " " +
    (Trim-Col "Model"    $W_MODEL)+ " " +
    (Trim-Col "Device"   $W_NAME)+ " " +
    (Trim-Col "User"     $W_USER)+ " " +
    (Trim-Col "Version"  $W_CUR) + " " +
    (Trim-Col "Status"   $W_STAT)+ " " +
    (Trim-Col "Phase"    $W_PHASE)+ " " +
    (Trim-Col "Days"     $W_DAYS)+ " " +
    (Trim-Col "EOL"      $W_EOL)+ " " +
    (Trim-Col "Min"      $W_LOW)+ " " +
    (Trim-Col "New"      $W_NEW)

Write-Host $header -ForegroundColor White
Write-Host ("".PadRight($header.Length,"-")) -ForegroundColor DarkGray

# Sort: EOL first, then Unknown, then Supported
$ReportSorted = $Report | Sort-Object @{
        Expression = {
            switch ($_.Status) {
                "EndOfLife" { 0 }
                "Unknown"   { 1 }
                default     { 2 }
            }
        }
    }, OS, MajorVer, DeviceName

foreach ($r in $ReportSorted) {

    $userClean = $r.User -split '\s-\s' | Select-Object -First 1
    $verClean  = $r.CurrentVersion -replace '\s+', ' '

    $days = if ($r.DaysToEol -ne $null) { $r.DaysToEol.ToString() } else { "-" }
    $eol  = if ($r.EolDate) { $r.EolDate.ToString("dd-MM-yyyy") } else { "-" }  # DK format

    $line =
        (Trim-Col $r.OS       $W_OS)   + " " +
        (Trim-Col $r.Model    $W_MODEL)+ " " +
        (Trim-Col $r.DeviceName $W_NAME)+ " " +
        (Trim-Col $userClean  $W_USER)+ " " +
        (Trim-Col $verClean   $W_CUR) + " " +
        (Trim-Col $r.Status   $W_STAT)+ " " +
        (Trim-Col $r.SupportPhase $W_PHASE)+ " " +
        (Trim-Col $days       $W_DAYS)+ " " +
        (Trim-Col $eol        $W_EOL)+ " " +
        (Trim-Col $r.LowestSupportedVersion $W_LOW) + " " +
        (Trim-Col $r.NewestVersionAvailable  $W_NEW)

    $color = switch ($r.Status) {
        "Supported" { "Green" }
        "EndOfLife" { "Red" }
        default     { "Yellow" }
    }

    Write-Host $line -ForegroundColor $color
}

Write-Host ""
Write-Host ("Total devices evaluated: {0}" -f $Report.Count) -ForegroundColor Cyan
