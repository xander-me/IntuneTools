# IntuneTools

**Status: PowerShell utility collection. Validation and prerequisites vary by script; this is not a packaged application.**

Work on these utilities in this repository. Select a script by purpose rather than running the whole repository.

| Script | Purpose | Environment and dependencies |
| --- | --- | --- |
| [OSSupportedOverveiw.ps1](IntuneGraph/OS/OSSupportedOverveiw/OSSupportedOverveiw.ps1) | Interactive multi-platform Intune OS lifecycle report | PowerShell console, authorized Graph device-inventory access and endoflife.date API access; validate the host and lifecycle mapping |
| [MacOS_iOS_SupportedOverview.ps1](MacOS_iOS_SupportedOvervie/MacOS_iOS_SupportedOverview.ps1) | Apple device lifecycle report | Script documents Windows PowerShell 5.1 / PowerShell 7+, app-only Graph credentials and DeviceManagementManagedDevices.Read.All |
| [UpdateOSwithLog.ps1](UpdateOSwithLog/UpdateOSwithLog.ps1) | Windows Update installation with logging | Windows 10/11, elevated Windows PowerShell and Windows Update COM services; may request or schedule reboot |

Read each script's help and credential configuration before use. Lifecycle scripts require tenant/app configuration; supply credentials securely in your execution setup and keep them out of Git. Lifecycle conclusions depend on external source data and are not a device-security assessment.

## Validation and next work

The 2026-09-21 review parsed the scripts without executing Graph or Windows Update operations. No automated test suite or representative tenant/Windows acceptance evidence is committed.

Next: verify the UpdateOS installation result and Intune detection marker on an authorized test PC. The current script writes the marker before installation and chooses its final exit code from reboot mode; correct and test failure reporting before treating that marker as update-completion evidence.

For lifecycle changes, test synthetic inventory and release responses before validating a limited authorized tenant sample. Preserve unknown states rather than inferring support from missing data.

## Attribution

[UpdateOSwithLog attribution](UpdateOSwithLog/README.md) credits Michael Niehaus for the original update script; this copy adds logging. Preserve existing script authorship and notices.

## Current work and handoff

Read [STATUS.md](STATUS.md) for current work, evidence, blockers and the next action. This README remains the project entry point; the handoff is a dated record and must be checked against live Git/issue state.
