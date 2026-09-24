BeforeAll {
    if (-not $env:ProgramData) { $env:ProgramData = $TestDrive }  # Windows-only default in the script's param block
    . (Join-Path $PSScriptRoot '..' 'Get-AutopilotHardwareHash.ps1')
    # Windows-only commands are absent on Linux; define stubs so they can be mocked.
    if (-not (Get-Command Get-CimInstance -ErrorAction SilentlyContinue)) { function global:Get-CimInstance { } }
    $script:Hash = [Convert]::ToBase64String([byte[]](1..200))
}

Describe 'ConvertTo-Base64Url' {
    It 'encodes without padding and with URL-safe characters' {
        ConvertTo-Base64Url ([byte[]](0xfb, 0xff, 0xfe)) | Should -Be '-__-'
        ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes('a')) | Should -Be 'YQ'
    }
}

Describe 'New-AutopilotCsvContent' {
    It 'writes the exact Intune import header and one row with the group tag' {
        $csv = New-AutopilotCsvContent -SerialNumber 'ABC123' -HardwareHash $script:Hash -GroupTag 'GR_PC_DK'
        $lines = $csv -split "`r`n"
        $lines[0] | Should -BeExactly 'Device Serial Number,Windows Product ID,Hardware Hash,Group Tag'
        $lines[1] | Should -BeExactly "ABC123,,$($script:Hash),GR_PC_DK"
    }
    It 'rejects values that would break the CSV' {
        { New-AutopilotCsvContent -SerialNumber 'A,B' -HardwareHash $script:Hash -GroupTag 'X' } | Should -Throw
        { New-AutopilotCsvContent -SerialNumber 'AB' -HardwareHash $script:Hash -GroupTag "X`n" } | Should -Throw
    }
}

Describe 'New-ClientAssertion' {
    It 'produces an RS256 JWT with x5t that verifies with the certificate public key' {
        $rsa = [Security.Cryptography.RSA]::Create(2048)
        $req = [Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=test', $rsa,
            [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $cert = $req.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-5), [DateTimeOffset]::UtcNow.AddDays(1))
        $jwt = New-ClientAssertion -Certificate $cert -TenantId 'tenant' -ClientId 'client'
        $parts = $jwt.Split('.')
        $parts.Count | Should -Be 3
        $pad = { param($s) $s = $s.Replace('-', '+').Replace('_', '/'); $s + ('=' * ((4 - $s.Length % 4) % 4)) }
        $header = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String((& $pad $parts[0]))) | ConvertFrom-Json
        $payload = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String((& $pad $parts[1]))) | ConvertFrom-Json
        $header.alg | Should -Be 'RS256'
        $header.x5t | Should -Be (ConvertTo-Base64Url $cert.GetCertHash())
        $payload.aud | Should -Be 'https://login.microsoftonline.com/tenant/oauth2/v2.0/token'
        $payload.iss | Should -Be 'client'
        $valid = $cert.PublicKey.GetRSAPublicKey().VerifyData([Text.Encoding]::UTF8.GetBytes("$($parts[0]).$($parts[1])"),
            [Convert]::FromBase64String((& $pad $parts[2])), [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $valid | Should -BeTrue
    }
}

Describe 'Invoke-Main' {
    BeforeEach {
        $OutputFolder = Join-Path $TestDrive ([guid]::NewGuid())
        $GroupTag = 'GR_PC_DK'; $WaitMinutes = 1; $UpdateGroupTag = $false; $SkipUpload = $false
        $TenantId = 'tenant'; $ClientId = 'client'; $ClientSecret = 'not-a-real-secret'; $CertificateThumbprint = $null
        $script:Mode = 'Secret'
        Mock Test-IsElevated { $true }
        Mock Get-DeviceHardwareInfo { [pscustomobject]@{ SerialNumber = 'SN-1'; HardwareHash = $script:Hash } }
        Mock Get-GraphToken { 'token' }
        Mock Start-Sleep { }
        Mock Invoke-Graph { throw "Unmocked Graph call: $Method $Path" }  # never reach the real Graph
    }

    It 'returns 1 when not elevated' {
        Mock Test-IsElevated { $false }
        Invoke-Main | Select-Object -Last 1 | Should -Be 1
    }
    It 'returns 7 when credentials are missing' {
        $ClientSecret = $null
        Invoke-Main | Select-Object -Last 1 | Should -Be 7
    }
    It 'returns 2 when the hash cannot be read' {
        Mock Get-DeviceHardwareInfo { throw 'no hash' }
        Invoke-Main | Select-Object -Last 1 | Should -Be 2
    }
    It 'writes an ASCII CSV and returns 10 with -SkipUpload, without calling Graph' {
        $SkipUpload = $true; $script:Mode = 'Local'
        Mock Invoke-Graph { throw 'should not be called' }
        Invoke-Main | Select-Object -Last 1 | Should -Be 10
        $bytes = [IO.File]::ReadAllBytes((Join-Path $OutputFolder 'SN-1.csv'))
        ($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
        [Text.Encoding]::ASCII.GetString($bytes) | Should -Match 'SN-1,,.+,GR_PC_DK'
        Should -Invoke Get-GraphToken -Times 0
    }
    It 'returns 3 when authentication fails' {
        Mock Get-GraphToken { throw 'AADSTS7000215' }
        Invoke-Main | Select-Object -Last 1 | Should -Be 3
    }
    It 'returns 0 and does not import when the device is already registered' {
        Mock Invoke-Graph { [pscustomobject]@{ value = @([pscustomobject]@{ id = 'd1'; serialNumber = 'SN-1'; groupTag = 'OLD' }) } }
        Invoke-Main | Select-Object -Last 1 | Should -Be 0
        Should -Invoke Invoke-Graph -Times 1 -Exactly
    }
    It 'updates the group tag of a registered device with -UpdateGroupTag' {
        $UpdateGroupTag = $true
        Mock Invoke-Graph { [pscustomobject]@{ value = @([pscustomobject]@{ id = 'd1'; serialNumber = 'SN-1'; groupTag = 'OLD' }) } } -ParameterFilter { $Path -like 'deviceManagement/windowsAutopilotDeviceIdentities?*' }
        Mock Invoke-Graph { $null } -ParameterFilter { $Method -eq 'Post' }
        Invoke-Main | Select-Object -Last 1 | Should -Be 0
        Should -Invoke Invoke-Graph -ParameterFilter { $Method -eq 'Post' -and $Path -like '*/d1/updateDeviceProperties' -and $Body.groupTag -eq 'GR_PC_DK' } -Times 1 -Exactly
    }
    It 'imports with the group tag and returns 0 when the import completes' {
        Mock Invoke-Graph { [pscustomobject]@{ value = @() } } -ParameterFilter { $Path -like 'deviceManagement/windowsAutopilotDeviceIdentities?*' }
        Mock Invoke-Graph { [pscustomobject]@{ id = 'imp1' } } -ParameterFilter { $Method -eq 'Post' }
        Mock Invoke-Graph { [pscustomobject]@{ state = [pscustomobject]@{ deviceImportStatus = 'complete' } } } -ParameterFilter { $Path -eq 'deviceManagement/importedWindowsAutopilotDeviceIdentities/imp1' -and $Method -ne 'Delete' }
        Mock Invoke-Graph { $null } -ParameterFilter { $Method -eq 'Delete' }
        Invoke-Main | Select-Object -Last 1 | Should -Be 0
        Should -Invoke Invoke-Graph -ParameterFilter { $Method -eq 'Post' -and $Body.groupTag -eq 'GR_PC_DK' -and $Body.serialNumber -eq 'SN-1' -and $Body.hardwareIdentifier -eq $script:Hash } -Times 1 -Exactly
    }
    It 'returns 5 when the import reports an error' {
        Mock Invoke-Graph { [pscustomobject]@{ value = @() } } -ParameterFilter { $Path -like 'deviceManagement/windowsAutopilotDeviceIdentities?*' }
        Mock Invoke-Graph { [pscustomobject]@{ id = 'imp1' } } -ParameterFilter { $Method -eq 'Post' }
        Mock Invoke-Graph { [pscustomobject]@{ state = [pscustomobject]@{ deviceImportStatus = 'error'; deviceErrorCode = 806; deviceErrorName = 'ZtdDeviceAlreadyAssigned' } } } -ParameterFilter { $Path -eq 'deviceManagement/importedWindowsAutopilotDeviceIdentities/imp1' }
        Invoke-Main | Select-Object -Last 1 | Should -Be 5
    }
    It 'returns 4 when the Graph lookup fails' {
        Mock Invoke-Graph { throw 'Forbidden' }
        Invoke-Main | Select-Object -Last 1 | Should -Be 4
    }
}
