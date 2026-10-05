# PowerShell

A collection of Windows administration scripts, mostly for Windows maintenance, Active Directory and Veeam Backup & Replication. Each folder is self-contained; see its README (or the script's comment-based help, `Get-Help .\<script>.ps1 -Full`) for details.

| Folder | What it contains | PowerShell |
|---|---|---|
| [`FixWIndows/`](FixWIndows/) | `FixWindows.ps1`: Windows maintenance and cleanup (DISM/SFC from a local ISO, volume repair, event-log archive, temp/profile cleanup, Windows Update, CleanMgr), with an optional JSON config and a batch helper to set the execution policy | 5.1 |
| [`GPO-Audit/`](GPO-Audit/) | `Invoke-GPOAudit.ps1`: read-only Group Policy audit with an HTML report and CSV/JSON exports, plus a prompt for turning the output into a remediation plan | 5.1 (7 via compatibility layer) |
| [`LogAnalyzer/`](LogAnalyzer/) | `Get-LogonSessionReport.ps1`: logon/logoff/RDP/lock events from remote Security logs, correlated into sessions, as an HTML report | 7.0+ |
| [`Validator/`](Validator/) | `Validate.PS1`: validates Veeam backup chains with `Veeam.Backup.Validator.exe` plus a VBM/disk cross-check; `Test-ErrorHandling.ps1` tests it | 5.1+ |
| [`Veeam/`](Veeam/) | Veeam Enterprise Reporter: a single-page HTML/JavaScript dashboard for the Veeam REST API, with an optional Node.js CORS proxy | n/a |
| [`VeeamItUp+/`](VeeamItUp+/) | `VeeamItUpPlus.ps1`: menu-driven Veeam repository analysis across saved servers (maps shares, scans backup files, HTML reports, optional OpenAI analysis and email); `Test-VBMChainValidation.ps1` tests the VBM chain parser | 5.1+ |
| [`WinUtils/`](WinUtils/) | `DemoteDC.PS1` (demote a domain controller and remove AD DS/DNS roles) and `Promote-RODC-DNS.PS1` (promote a server to a read-only DC with DNS, with pre-checks and `-CheckOnly`) | 5.1 |

Most scripts must run elevated on Windows; several self-elevate through UAC. Scripts that change systems (`FixWindows.ps1`, `DemoteDC.PS1`, `Promote-RODC-DNS.PS1`) can reboot the machine when they finish.
