<#
.SYNOPSIS
    Intune OS Lifecycle Report (interactive, console only).

.DESCRIPTION
    This script generates a detailed lifecycle report for Intune-managed devices across multiple platforms (iOS, iPadOS, macOS, Android, Windows, and others).
    It retrieves device data from Microsoft Graph and OS lifecycle information from endoflife.date API.
    The report is displayed in the console with dynamically sized columns and Danish date formatting.

.PARAMETER TenantId
    The Azure AD tenant ID used for authentication to Microsoft Graph.

.PARAMETER ClientId
    The Azure AD application client ID used for authentication.

.PARAMETER ClientSecret
    The Azure AD application client secret used for authentication.

.FUNCTIONS
    Write-Info
        Outputs informational messages to the console in DarkCyan.

    Get-Releases
        Retrieves OS release lifecycle data from endoflife.date API.

    Build-GenericEolInfo
        Processes generic OS lifecycle data (iOS, iPadOS, macOS, Android).

    Build-WindowsEolInfo
        Processes Windows OS lifecycle data, mapping by build number.

    Get-MaxLen
        Calculates the maximum string length in an array for dynamic column sizing.

    Fit-Col
        Formats a string to fit a specified column width, truncating and padding as needed.

.INPUTS
    Interactive prompts for platform selection and EOL filtering.

.OUTPUTS
    Console output:
        - Summary of device lifecycle status (Supported, EndOfLife, Unknown)
        - Detailed table of device lifecycle information with dynamic columns

.NOTES
    - Dates are formatted in Danish (dd-MM-yyyy).
    - Console width is expanded for better readability.
    - Requires Microsoft Graph API permissions and valid credentials.
    - Uses endoflife.date public API for OS lifecycle data.

.LIMITATIONS
    - Only supports console output (no export).
    - May not work in hosts that do not support console resizing (e.g., ISE, VSCode terminals).
    - Device and OS data accuracy depends on Intune and endoflife.date sources.

.EXAMPLE
    # Run the script and follow interactive prompts to generate an OS lifecycle report for Intune devices.


.AUTHOR
    Original script author: Alexander Christensen
    Documented: GitHub Copilot

#>
<#
    Intune OS Lifecycle Report (interactive, console only)
    - Platforms: iOS, iPadOS, macOS, Android, Windows (client), others (Unknown)
    - Uses Microsoft Graph + endoflife.date v1
    - Windows:
        * Known GA builds mapped by build number
        * Builds higher than highest known GA build = Preview/Beta
    - Output in console with dynamic column widths
    - Dates shown in Danish format (dd-MM-yyyy)
#>
# Improve console formatting and ensure dynamic columns use the script's maximum caps
# - Set Danish date/culture for consistent date formatting
# - Expand console/window width to avoid wrapping
# - Provide "row length" hints so the later dynamic-width math picks the script's max caps
[System.Threading.Thread]::CurrentThread.CurrentCulture = 'da-DK'
[System.Threading.Thread]::CurrentThread.CurrentUICulture = 'da-DK'

try {
    $raw = $Host.UI.RawUI
    $newWidth = 200
    $raw.BufferSize = New-Object Management.Automation.Host.Size($newWidth, $raw.BufferSize.Height)
    $raw.WindowSize = New-Object Management.Automation.Host.Size([Math]::Min($newWidth, $raw.MaxPhysicalWindowSize.Width), $raw.WindowSize.Height)
} catch {
    # ignore hosts that don't support resizing (ISE/VSCode integrated terminals, etc.)
}

# Provide large "row" length hints so the later width calculation will use the script's configured caps
# (The later code sums header-length + these "_Row" values, then clamps to per-column caps.)
$MaxLen_OS_Row     = 200
$MaxLen_Model_Row  = 200
$MaxLen_Device_Row = 200
$MaxLen_User_Row   = 200
$MaxLen_Ver_Row    = 200
$MaxLen_Status_Row = 200
$MaxLen_Phase_Row  = 200
$MaxLen_Days_Row   = 200
$MaxLen_EOL_Row    = 200
$MaxLen_Min_Row    = 200
$MaxLen_New_Row    = 200
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

Write-Host "Which platforms do you want to include?" -ForegroundColor Cyan
Write-Host "  1) All platforms"
Write-Host "  2) Apple only (iOS, iPadOS, macOS)"
Write-Host "  3) Windows only"
Write-Host "  4) Android only (incl. Android Enterprise)"
$osChoice = Read-Host "Choose (1-4)"

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

switch ($osChoice) {
    "2" {
        $FilteredDevices = $Devices | Where-Object {
            $_.operatingSystem -in @("iOS","iPadOS","macOS")
        }
    }
    "3" {
        $FilteredDevices = $Devices | Where-Object {
            $_.operatingSystem -like "Windows*"
        }
    }
    "4" {
        $FilteredDevices = $Devices | Where-Object {
            $_.operatingSystem -like "Android*"
        }
    }
    default {
        $FilteredDevices = $Devices
    }
}

Write-Info "Found $($FilteredDevices.Count) devices matching platform filter."

# =========================
# 3. Get endoflife.date data
# =========================
Write-Info "Retrieving OS lifecycle data from endoflife.date..."

function Get-Releases {
    param([string]$url)
    (Invoke-RestMethod -Method Get -Uri $url).result.releases
}

$IosReleases      = Get-Releases "https://endoflife.date/api/v1/products/ios/"
$IpadosReleases   = Get-Releases "https://endoflife.date/api/v1/products/ipados/"
$MacOsReleases    = Get-Releases "https://endoflife.date/api/v1/products/macos/"
$AndroidReleases  = Get-Releases "https://endoflife.date/api/v1/products/android/"
$WindowsReleases  = Get-Releases "https://endoflife.date/api/v1/products/windows/"

# ---------- Generic (numeric-cycle) OS: iOS, iPadOS, macOS, Android ----------
function Build-GenericEolInfo {
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

        $isSup = (-not $r.isEol) -and $r.isMaintained
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

$IosEol     = Build-GenericEolInfo $IosReleases
$IpadosEol  = Build-GenericEolInfo $IpadosReleases
$MacOsEol   = Build-GenericEolInfo $MacOsReleases
$AndroidEol = Build-GenericEolInfo $AndroidReleases

# ---------- Windows: map by build number (e.g. 10.0.26100) ----------
function Build-WindowsEolInfo {
    param([array]$Releases)

    $dict       = [System.Collections.Generic.Dictionary[string,object]]::new()
    $maintained = @()
    $supported  = @()

    foreach ($r in $Releases) {
        $build = $null
        if ($r.latest -and $r.latest.name) {
            $build = [string]$r.latest.name   # e.g. "10.0.26100"
        }
        if (-not $build) { continue }

        $label = [string]$r.label            # e.g. "10 22H2", "11 23H2 (E)"

        $eol = $null
        if ($r.eolFrom) { try { $eol = [datetime]::Parse($r.eolFrom) } catch {} }

        $releaseDate = $null
        if ($r.releaseDate) { try { $releaseDate = [datetime]::Parse($r.releaseDate) } catch {} }

        $isSup = (-not $r.isEol) -and $r.isMaintained   # ignore ESU

        $entry = [PSCustomObject]@{
            Build       = $build
            Label       = $label
            EolDate     = $eol
            ReleaseDate = $releaseDate
            Supported   = $isSup
        }

        $dict[$build] = $entry

        if ($releaseDate -and $r.isMaintained) { $maintained += $entry }
        if ($releaseDate -and $isSup)         { $supported  += $entry }
    }

    $lowest = if ($supported.Count) {
        ($supported | Sort-Object ReleaseDate | Select-Object -First 1).Label
    } else { "-" }

    $newest = if ($maintained.Count) {
        ($maintained | Sort-Object ReleaseDate | Select-Object -Last 1).Label
    } else { "-" }

    # Highest known GA build (for Preview/Beta detection)
    $highestBuildVersion = $null
    if ($dict.Count -gt 0) {
        $highestBuildVersion = $dict.Keys |
            ForEach-Object { [version]$_ } |
            Sort-Object |
            Select-Object -Last 1
    }

    return [PSCustomObject]@{
        MapByBuild      = $dict
        LowestSupported = $lowest
        NewestAvailable = $newest
        HighestBuild    = if ($highestBuildVersion) { $highestBuildVersion.ToString() } else { $null }
    }
}

$WindowsEol = Build-WindowsEolInfo $WindowsReleases

# =========================
# 4. Build report (all platforms)
# =========================
Write-Info "Calculating lifecycle status per device..."

$Report = foreach ($d in $FilteredDevices) {

    $os  = $d.operatingSystem
    $ver = $d.osVersion
    if (-not $ver) { $ver = "-" }

    # Determine OS family
    $family = if     ($os -eq "iOS")             { "iOS" }
              elseif ($os -eq "iPadOS")          { "iPadOS" }
              elseif ($os -eq "macOS")           { "macOS" }
              elseif ($os -like "Android*")      { "Android" }
              elseif ($os -like "Windows*")      { "Windows" }
              else                               { "Other" }

    $status       = "Unknown"
    $phase        = "Unknown"
    $eol          = $null
    $daysToEol    = $null
    $lowestSup    = "-"
    $newestAvail  = "-"
    $major        = ""

    if ($family -in @("iOS","iPadOS","macOS","Android")) {
        # ---------- Apple / Android ----------
        switch ($family) {
            "iOS"     { $info = $IosEol }
            "iPadOS"  { $info = $IpadosEol }
            "macOS"   { $info = $MacOsEol }
            "Android" { $info = $AndroidEol }
        }

        $map = $info.Map
        $lowestSup   = $info.LowestSupported
        $newestAvail = $info.NewestAvailable

        $firstToken = ($ver -split '\s+')[0]
        $major      = ($firstToken -split '\.')[0]  # e.g. "18" from "18.0.1"

        if ($major -and $map.ContainsKey($major)) {
            $entry = $map[$major]
            $eol   = $entry.EolDate

            if ($entry.Supported) {
                $status = "Supported"
                if ($eol) {
                    $daysToEol = ($eol - $Today).Days
                    if     ($daysToEol -le 180 -and $daysToEol -gt 0) { $phase = "NearingEOL" }
                    elseif ($daysToEol -gt 180)                       { $phase = "Supported"  }
                    else { $phase = "EOL"; $status = "EndOfLife" }
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
    }
    elseif ($family -eq "Windows") {
        # ---------- Windows: map by build number ----------
        $buildKey = $null
        if ($ver -match '^(\d+\.\d+\.\d+)') {
            $buildKey = $matches[1]   # e.g. "10.0.26100" or "10.0.27902"
        }

        $lowestSup   = $WindowsEol.LowestSupported
        $newestAvail = $WindowsEol.NewestAvailable

        if ($buildKey -and $WindowsEol.MapByBuild.ContainsKey($buildKey)) {
            # Known GA build – use lifecycle from endoflife.date
            $entry = $WindowsEol.MapByBuild[$buildKey]
            $eol   = $entry.EolDate
            $major = $entry.Label   # "10 22H2", "11 23H2 (E)"

            if ($entry.Supported) {
                $status = "Supported"
                if ($eol) {
                    $daysToEol = ($eol - $Today).Days
                    if     ($daysToEol -le 180 -and $daysToEol -gt 0) { $phase = "NearingEOL" }
                    elseif ($daysToEol -gt 180)                       { $phase = "Supported"  }
                    else { $phase = "EOL"; $status = "EndOfLife" }
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
        elseif ($buildKey -and $WindowsEol.HighestBuild) {
            # Unknown build – compare to highest known GA build
            $currentBuild = [version]$buildKey
            $highestBuild = [version]$WindowsEol.HighestBuild

            if ($currentBuild -gt $highestBuild) {
                # Higher than anything in endoflife.date = likely Insider / vNext
                $status = "Unknown"
                $phase  = "Preview/Beta"
                $major  = ""
            }
            else {
                # Older or odd build not in dataset
                $status = "Unknown"
                $phase  = "Unmapped"
                $major  = ""
            }
        }
        else {
            # Could not parse build at all
            $status = "Unknown"
            $phase  = "Unmapped"
            $major  = ""
        }
    }
    else {
        # ---------- Other OS (Linux, ChromeOS, etc.) ----------
        $status       = "Unknown"
        $phase        = "Unknown"
        $lowestSup    = "-"
        $newestAvail  = "-"
        $major        = ""
    }

    [PSCustomObject]@{
        OS                     = $os
        Model                  = $d.model
        DeviceName             = $d.deviceName
        User                   = $d.userDisplayName
        CurrentVersion         = $ver          # Detected version
        MajorVer               = $major        # For Windows: release label (if mapped)
        Status                 = $status
        SupportPhase           = $phase
        EolDate                = $eol
        DaysToEol              = $daysToEol
        LowestSupportedVersion = $lowestSup    # "Min" column
        NewestVersionAvailable = $newestAvail  # "New" column (newest non-beta GA)
    }
}

if ($OnlyEol) {
    $Report = $Report | Where-Object Status -eq "EndOfLife"
}

# =========================
# 5. Summary
# =========================
Write-Host ""
if ($OnlyEol) {
    Write-Host "OS lifecycle – summary (EOL devices only)" -ForegroundColor Cyan
} else {
    Write-Host "OS lifecycle – summary (all included platforms)" -ForegroundColor Cyan
}

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
# 6. Dynamic-column console table (DK date)
# =========================

function Get-MaxLen {
    param([string[]]$values)
    if (-not $values -or $values.Count -eq 0) { return 1 }
    return ($values | ForEach-Object { if ($_){ $_.Length } else { 1 } } |
        Measure-Object -Maximum).Maximum
}

# Prepare a sorted list first (same sort as before)
$ReportSorted = $Report | Sort-Object @{
        Expression = {
            switch ($_.Status) {
                "EndOfLife" { 0 }
                "Unknown"   { 1 }
                default     { 2 }
            }
        }
    }, OS, MajorVer, DeviceName

# Create display rows (strings) so we can calculate widths
$DisplayRows = foreach ($r in $ReportSorted) {
    $os   = if ($r.OS)   { $r.OS }   else { "-" }
    $mod  = if ($r.Model){ $r.Model }else { "-" }
    $dev  = if ($r.DeviceName){ $r.DeviceName } else { "-" }
    $usr  = if ($r.User){ ($r.User -split '\s-\s' | Select-Object -First 1) } else { "-" }
    $ver  = if ($r.CurrentVersion){ ($r.CurrentVersion -replace '\s+',' ') } else { "-" }
    $stat = if ($r.Status){ $r.Status } else { "-" }
    $ph   = if ($r.SupportPhase){ $r.SupportPhase } else { "-" }
    $days = if ($r.DaysToEol -ne $null){ $r.DaysToEol.ToString() } else { "-" }
    $eolS = if ($r.EolDate){ $r.EolDate.ToString("dd-MM-yyyy") } else { "-" }
    $minV = if ($r.LowestSupportedVersion){ $r.LowestSupportedVersion } else { "-" }
    $newV = if ($r.NewestVersionAvailable){ $r.NewestVersionAvailable } else { "-" }

    [PSCustomObject]@{
        OS     = $os
        Model  = $mod
        Device = $dev
        User   = $usr
        Ver    = $ver
        Status = $stat
        Phase  = $ph
        Days   = $days
        Eol    = $eolS
        Min    = $minV
        New    = $newV
        StatusRaw = $r.Status   # for coloring later
    }
}

# Compute dynamic widths (with max caps)
$MaxLen_OS    = Get-MaxLen -values @('OS')
$MaxLen_Model = Get-MaxLen -values @('Model')
$MaxLen_Device= Get-MaxLen -values @('Device')
$MaxLen_User  = Get-MaxLen -values @('User')
$MaxLen_Ver   = Get-MaxLen -values @('Version')
$MaxLen_Status= Get-MaxLen -values @('Status')
$MaxLen_Phase = Get-MaxLen -values @('Phase')
$MaxLen_Days  = Get-MaxLen -values @('Days')
$MaxLen_EOL   = Get-MaxLen -values @('EOL')
$MaxLen_Min   = Get-MaxLen -values @('Min')
$MaxLen_New   = Get-MaxLen -values @('New')

function Fit-Col {
    param(
        [string]$text,
        [int]$width,
        [string]$placeholder = "-"
    )
    if (-not $text) { $text = $placeholder }
    if ($text.Length -gt $width) {
        return $text.Substring(0, $width - 1) + "…"
    } else {
        return $text.PadRight($width)
    }
}
$MaxLen_Min_Row    = Get-MaxLen -values $DisplayRows.Min
$MaxLen_New_Row    = Get-MaxLen -values $DisplayRows.New

$W_OS    = [Math]::Min( [Math]::Max( $MaxLen_OS    + $MaxLen_OS_Row,     4 ), 15 )
$W_MODEL = [Math]::Min( [Math]::Max( $MaxLen_Model + $MaxLen_Model_Row,  6 ), 25 )
$W_DEV   = [Math]::Min( [Math]::Max( $MaxLen_Device+ $MaxLen_Device_Row, 6 ), 28 )
$W_USER  = [Math]::Min( [Math]::Max( $MaxLen_User  + $MaxLen_User_Row,   6 ), 28 )
$W_VER   = [Math]::Min( [Math]::Max( $MaxLen_Ver   + $MaxLen_Ver_Row,    7 ), 28 )
$W_STAT  = [Math]::Min( [Math]::Max( $MaxLen_Status+ $MaxLen_Status_Row, 6 ), 14 )
$W_PHASE = [Math]::Min( [Math]::Max( $MaxLen_Phase + $MaxLen_Phase_Row,  6 ), 18 )
$W_DAYS  = [Math]::Min( [Math]::Max( $MaxLen_Days  + $MaxLen_Days_Row,   4 ), 8 )
$W_EOL   = [Math]::Min( [Math]::Max( $MaxLen_EOL   + $MaxLen_EOL_Row,    6 ), 12 )
$W_MIN   = [Math]::Min( [Math]::Max( $MaxLen_Min   + $MaxLen_Min_Row,    4 ), 18 )
$W_NEW   = [Math]::Min( [Math]::Max( $MaxLen_New   + $MaxLen_New_Row,    4 ), 18 )

function Fit-Col {
    param([string]$text, [int]$width)
    if (-not $text) { $text = "-" }
    if ($text.Length -gt $width) {
        return $text.Substring(0, $width - 1) + "…"
    } else {
        return $text.PadRight($width)
    }
}

Write-Host "Intune devices – OS lifecycle details" -ForegroundColor Cyan

$header =
    (Fit-Col "OS"      $W_OS)    + " " +
    (Fit-Col "Model"   $W_MODEL) + " " +
    (Fit-Col "Device"  $W_DEV)   + " " +
    (Fit-Col "User"    $W_USER)  + " " +
    (Fit-Col "Version" $W_VER)   + " " +
    (Fit-Col "Status"  $W_STAT)  + " " +
    (Fit-Col "Phase"   $W_PHASE) + " " +
    (Fit-Col "Days"    $W_DAYS)  + " " +
    (Fit-Col "EOL"     $W_EOL)   + " " +
    (Fit-Col "Min"     $W_MIN)   + " " +
    (Fit-Col "New"     $W_NEW)

Write-Host $header -ForegroundColor White
Write-Host ("".PadRight($header.Length,"-")) -ForegroundColor DarkGray

foreach ($row in $DisplayRows) {
    $line =
        (Fit-Col $row.OS     $W_OS)    + " " +
        (Fit-Col $row.Model  $W_MODEL) + " " +
        (Fit-Col $row.Device $W_DEV)   + " " +
        (Fit-Col $row.User   $W_USER)  + " " +
        (Fit-Col $row.Ver    $W_VER)   + " " +
        (Fit-Col $row.Status $W_STAT)  + " " +
        (Fit-Col $row.Phase  $W_PHASE) + " " +
        (Fit-Col $row.Days   $W_DAYS)  + " " +
        (Fit-Col $row.Eol    $W_EOL)   + " " +
        (Fit-Col $row.Min    $W_MIN)   + " " +
        (Fit-Col $row.New    $W_NEW)

    $color = switch ($row.StatusRaw) {
        "Supported" { "Green" }
        "EndOfLife" { "Red" }
        default     { "Yellow" }
    }

    Write-Host $line -ForegroundColor $color
}

Write-Host ""
Write-Host ("Total devices evaluated: {0}" -f $Report.Count) -ForegroundColor Cyan
