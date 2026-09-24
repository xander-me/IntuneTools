# Get-AutopilotHardwareHash

Silent collection of the Windows Autopilot hardware hash and direct import into Intune with a group tag (default `GR_PC_DK`). Built to run as SYSTEM from ManageEngine Endpoint Central; no module downloads, plain Microsoft Graph REST.

- Script: [Get-AutopilotHardwareHash.ps1](Get-AutopilotHardwareHash.ps1) (`Get-Help .\Get-AutopilotHardwareHash.ps1 -Full`)
- Danish how-to guide (app registration, ManageEngine setup, exit codes, troubleshooting): [VEJLEDNING.md](VEJLEDNING.md)
- Tests: [tests/](tests/Get-AutopilotHardwareHash.Tests.ps1) (Pester 5, mocked Graph and WMI)

Graph application permission: `DeviceManagementServiceConfig.ReadWrite.All`. Credentials are passed at run time and must never be committed. A local import CSV is always written as a fallback (`-SkipUpload` for CSV only).

Validation: 14/14 Pester tests on Linux (PowerShell 7.6, Pester 5.7.1). **Windows, WMI, ManageEngine and live Graph import: NOT RUN.**
