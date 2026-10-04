# GPO-Audit

Read-only Group Policy audit for an Active Directory domain. `Invoke-GPOAudit.ps1` documents which GPOs exist, where they are linked, which apply to (or are denied for) a given computer and user, and flags problems (security filtering, WMI filters, SYSVOL/AD version mismatches, stale GPOs, event-log errors) as Critical / High / Medium / Low / Informational findings.

The only changes it makes are installing missing RSAT prerequisites (with confirmation or `-InstallPrerequisites`), running `gpupdate /force` when `-ForceGPUpdate` is given, and writing report files. It supports `-WhatIf`.

## Files

- `Invoke-GPOAudit.ps1` - the audit script. Full documentation is in its comment-based help: `Get-Help .\Invoke-GPOAudit.ps1 -Full`.
- `ClaudePrompt.txt` - a prompt for turning a zipped audit output folder into a self-contained HTML remediation report (`GPO-Remediation-Plan_<Domain>_<yyyyMMdd>.html`).
- `GPOAudit.zip` - sample output from two audit runs.
- `GPO-Remediation-Plan_*.html` - a sample remediation report produced from that output with `ClaudePrompt.txt`.

## Requirements

- Windows 10/11 or Windows Server 2019/2022/2025, domain joined
- Run elevated (local administrator); the script stops without elevation
- RSAT GroupPolicy and ActiveDirectory modules (installable with `-InstallPrerequisites`)
- Windows PowerShell 5.1 preferred. Under PowerShell 7 it tries the Windows PowerShell compatibility import; `-RelaunchInWindowsPowerShell` relaunches in 5.1 if that fails.

## Usage

```powershell
# Local computer, domain-wide inventory and event logs, install prerequisites unattended
.\Invoke-GPOAudit.ps1 -InstallPrerequisites -IncludeDomainInventory -IncludeEventLogs

# Remote computer and user
.\Invoke-GPOAudit.ps1 -ComputerName PC123 -UserName 'DOMAIN\User1' -IncludeDomainInventory -IncludeEventLogs -OutputPath C:\Audits\PC123

# Domain inventory only, without touching a target computer
.\Invoke-GPOAudit.ps1 -IncludeDomainInventory -SkipRemoteRSOP
```

Other parameters: `-Domain`, `-DomainController`, `-Credential`, `-IncludeSecurityAudit`, `-OpenReport`, `-StaleGpoDays` (default 365), `-RecentGpoDays` (default 7), `-EventLogDays` (default 14), `-ForceGPUpdate`.

## Output

By default `<SystemDrive>\GPOAudit\<COMPUTERNAME>_yyyyMMdd_HHmmss\`, containing the master `GPOAudit-Report.html` plus `Computer`, `User`, `DomainGPOs`, `Links`, `Permissions`, `WMI-Filters`, `RSOP`, `EventLogs`, `RawData`, `Summary` and `Logs` folders (CSV/JSON exports, per-GPO HTML/XML reports, EVTX exports and the execution log).
