# IntuneTools — current work and handoff

Updated: 2026-09-23. Owner: Alexander. State: Utility collection. [Scope and project entry point](README.md).

## Objective and authorization

Preserve the project's documented scope and provide a durable resume point. Alexander authorized the cross-project documentation handoff rollout on 2026-09-23: “Lets have it implemented.” This authorizes these documentation/agent-entry changes and publication through a PR; it does not start the next product task or authorize deployment. Reuse existing project decisions and authorization when a project task resumes.

## Completed and evidence

Three PowerShell utilities and per-script prerequisites are documented. The 2026-09-21 review parsed scripts without Graph/Windows Update execution.

## Remaining work and blockers

UpdateOS writes its marker before installation and derives final exit status from reboot mode. Representative Windows/tenant acceptance and a committed automated suite are absent. Tests: NOT RUN in this documentation task. Alexander owns unresolved scope and access to representative environments. The current handoff records documentation inspection of base commit `4d4edc80c349`; it does not re-run historical product tests.

## Next action

Scope a correction and offline test for UpdateOS result/marker semantics, then verify on an authorized test PC before accepting the marker as completion evidence.

## Issues and branches

Checked live on 2026-09-23:

- No open project issues at inspection.
- No pre-existing open PRs at inspection.

The documentation rollout is on `docs/project-handoffs-14`, based on main `4d4edc80c349`. Find its current review in [pull requests](https://github.com/xander-me/IntuneTools/pulls). An open PR is not accepted delivery. Resolve the actual checkout with `git rev-parse --show-toplevel`; verify `git status --short`, branch/commit, fetched remote and live issue/PR state before resuming. The checkout was clean before this task; no pre-existing local work was moved or published. The rollout changes documentation only. Local/unpushed changes at later session boundaries must be recorded here explicitly.

## 2026-09-24: Get-AutopilotHardwareHash

- Added [Autopilot/Get-AutopilotHardwareHash](Autopilot/Get-AutopilotHardwareHash/README.md): silent hash collection and direct Intune import with group tag `GR_PC_DK` for ManageEngine Endpoint Central, requested by Alexander (not part of the Matas store project). Danish guide: [VEJLEDNING.md](Autopilot/Get-AutopilotHardwareHash/VEJLEDNING.md).
- Design: no module downloads (MDM WMI + Graph REST), app-only auth with secret or certificate passed at run time, idempotent (already registered devices are skipped; optional group tag correction), local CSV fallback, explicit exit codes, 64-bit relaunch from 32-bit agents.
- Tests: 14/14 Pester on Linux (PowerShell 7.6, Pester 5.7.1) with mocked WMI/Graph. **NOT RUN:** Windows PowerShell 5.1, real MDM WMI, ManageEngine execution, live Graph import.
- Next action: run on one test PC (`-SkipUpload`, then with upload) as described in section 4 of the guide, then a small ManageEngine test group. Owner: Alexander.

