# Windows Logon Session Report (`Get-LogonSessionReport.ps1`)

A production-quality PowerShell 7+ utility that queries Windows Security event logs from remote machines, correlates logon/logoff/reconnect/lock events into per-user sessions, and generates a professional HTML5 report.

## Features

- Queries Security event log for Event IDs: **4624**, **4634**, **4647**, **4778**, **4779**, **4800**, **4801**
- Correlates events into sessions using LogonId as the primary key
- Calculates session duration and active time (excludes locked intervals)
- Generates a **self-contained HTML5 report** with dark theme, sorting, filtering, and expandable timelines
- Secure credential storage via **DPAPI-encrypted** registry entries (CurrentUser scope)
- Exports to **JSON** and **CSV** alongside HTML
- All times normalized to **UTC** to handle cross-machine time skew

## Prerequisites

| Requirement | Detail |
|---|---|
| **PowerShell** | 7.0 or later |
| **Permissions** | Local admin on target machines (domain admin not required) |
| **WinRM** | PS Remoting enabled on targets (`Enable-PSRemoting` on each) |
| **Firewall** | TCP 5985 (HTTP) or 5986 (HTTPS) for WinRM |
| **Audit Policy** | Logon/logoff auditing must be enabled on targets (see below) |

### Enabling Audit Policy on Targets

```powershell
auditpol /set /subcategory:"Logon" /success:enable /failure:enable
auditpol /set /subcategory:"Logoff" /success:enable
auditpol /set /subcategory:"Other Logon/Logoff Events" /success:enable
```

## Quick Start

### 1. Save Credentials (One-Time Setup)

```powershell
.\Get-LogonSessionReport.ps1 -SaveCredential
```

Prompts for username/password and stores them encrypted in the registry at `HKCU:\Software\LogonAuditTool\Credential` using Windows DPAPI. Only the same user account on the same machine can decrypt.

### 2. Query a Single Host

```powershell
.\Get-LogonSessionReport.ps1 -ComputerName "WS01" -UseStoredCredential
```

### 3. Query Multiple Hosts

```powershell
.\Get-LogonSessionReport.ps1 -ComputerName "WS01","WS02","DC01" -Credential (Get-Credential)
```

### 4. Query from a File

Create `targets.txt`:
```
# Production workstations
WS01
WS02
WS03
```

```powershell
.\Get-LogonSessionReport.ps1 -ComputerListPath .\targets.txt -UseStoredCredential
```

### 5. Custom Time Window

```powershell
# Last 3 days
.\Get-LogonSessionReport.ps1 -ComputerName "WS01" -UseStoredCredential -StartTime (Get-Date).AddDays(-3)

# Specific date range
.\Get-LogonSessionReport.ps1 -ComputerName "WS01" -UseStoredCredential `
    -StartTime "2026-02-10" -EndTime "2026-02-15"
```

### 6. Export All Formats

```powershell
.\Get-LogonSessionReport.ps1 -ComputerName "WS01" -UseStoredCredential `
    -ExportJson -ExportCsv -OutputPath "C:\Reports"
```

### 7. Test Mode (Localhost)

```powershell
.\Get-LogonSessionReport.ps1 -TestMode -Verbose
```

Runs against the local machine without remoting — useful for validation.

### 8. Clear Stored Credentials

```powershell
.\Get-LogonSessionReport.ps1 -ClearCredential
```

### 9. Workgroup / TrustedHosts (When "Access is denied")

If targets are not in the same domain or you see **WinRM client cannot process the request… add to TrustedHosts**:

- Use **`-PromptOnConnectionFailure`** to be prompted for each failed machine. If you choose Y, the script tries to add it to TrustedHosts.
- If you get **"Access is denied"** (no admin rights to change TrustedHosts), the script will then prompt: **"Open an elevated (Administrator) window to add them to TrustedHosts now? (Y/n)"**. Choose **Y** to open an elevated PowerShell that updates TrustedHosts; approve the UAC prompt, then **re-run the report script**.
- Alternatively run the report script **as Administrator** so the first add succeeds, or add hosts manually in an elevated window:
  ```powershell
  Set-Item WSMan:\localhost\Client\TrustedHosts -Value 'DC01,DC02,W2025' -Force
  ```

## Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-ComputerName` | string[] | — | Target computer names (supports CSV: `"A,B,C"`) |
| `-ComputerListPath` | string | — | Path to text file with one computer per line |
| `-StartTime` | datetime | 7 days ago | Start of query window |
| `-EndTime` | datetime | Now | End of query window |
| `-Credential` | PSCredential | — | Explicit credentials |
| `-UseStoredCredential` | switch | — | Load DPAPI-encrypted credentials from registry |
| `-SaveCredential` | switch | — | Prompt and store credentials, then exit |
| `-ClearCredential` | switch | — | Remove stored credentials, then exit |
| `-OutputPath` | string | Current dir | Directory for output files |
| `-ReportName` | string | `LogonReport_<timestamp>` | Base filename for outputs |
| `-TimeoutSeconds` | int | 120 | Per-machine query timeout (10–600) |
| `-IncludeFailuresInReport` | switch | — | Show failed machines in HTML report |
| `-TestMode` | switch | — | Query localhost without remoting |
| `-ExportJson` | switch | — | Also emit `.json` output |
| `-ExportCsv` | switch | — | Also emit `.csv` output |
| `-OpenReport` | switch | `$true` | Open the HTML report in the default browser after generation |
| `-AddToTrustedHostsOnFailure` | switch | — | On WinRM/TrustedHosts failure, add the machine to TrustedHosts and retry (requires admin to modify TrustedHosts) |
| `-PromptOnConnectionFailure` | switch | — | On WinRM/TrustedHosts failure, prompt to add the machine to TrustedHosts and retry; if Access denied, prompt to open elevated window to fix |
| `-Verbose` | switch | — | Detailed progress output |

## Event Coverage

| Event ID | Description | Key Fields Extracted |
|---|---|---|
| **4624** | Successful logon | User, Domain, SID, LogonType, LogonId, IP, Workstation, Auth Package |
| **4634** | Session ended (logoff) | User, LogonId |
| **4647** | User-initiated logoff | User, LogonId |
| **4778** | RDP session reconnect | Account, Session, Client Name/Address |
| **4779** | RDP session disconnect | Account, Session, Client Name/Address |
| **4800** | Workstation locked | User |
| **4801** | Workstation unlocked | User |

## Session Correlation

Sessions are built by matching events using a tiered strategy:

| Priority | Method | Confidence | Used For |
|---|---|---|---|
| **Primary** | LogonId exact match | High | Logon ↔ Logoff, Lock/Unlock when SubjectLogonId present |
| **Secondary** | Same user + same machine + time window | Medium | RDP reconnect/disconnect, Lock/Unlock without LogonId |
| **Tertiary** | Same user + nearest session | Low | Fallback for orphaned events |

Each event in the timeline includes a **Confidence** indicator (High/Medium/Low) so you can audit the correlation quality.

### Active Time Calculation

`ActiveTime = SessionDuration - sum(locked intervals)`

- A locked interval spans from a 4800 (lock) to the next matching 4801 (unlock)
- If no unlock is found, the interval extends to session end
- Displayed in the report alongside total session duration

## Logon Type Reference

| Code | Name | Description |
|---|---|---|
| 0 | System | Used by the system account |
| 2 | Interactive | Local console logon |
| 3 | Network | Network logon (file shares, etc.) |
| 4 | Batch | Scheduled task |
| 5 | Service | Service startup |
| 7 | Unlock | Workstation unlock |
| 8 | NetworkCleartext | Network logon with cleartext creds (IIS basic auth) |
| 9 | NewCredentials | RunAs with `/netonly` |
| 10 | RemoteInteractive | RDP / Terminal Services |
| 11 | CachedInteractive | Logon with cached domain creds |
| 12 | CachedRemoteInteractive | Cached RDP logon |
| 13 | CachedUnlock | Cached unlock |

## HTML Report

The report is a single self-contained HTML5 file with:

- **Executive summary** — machines queried, success/fail counts, total sessions
- **Per-machine sections** — collapsible, with session count and query time badges
- **Session table** — sortable columns, text filter, all key fields
- **Expandable timelines** — per-session event chronology with confidence indicators
- **Dark theme** — modern UI with responsive layout
- No external dependencies (no CDN, no frameworks)

## Output Objects

The script returns `WorkstationResult` objects to the pipeline:

```
WorkstationResult
├── ComputerName   [string]
├── QueryStatus    [string]  Success | Failed
├── Error          [string]  Error message if failed
├── EventCount     [int]
├── QueryTime      [timespan]
└── Sessions[]
    └── LogonSession
        ├── User, LogonId, LogonTime, LogoffTime
        ├── SessionDuration, ActiveTime
        ├── LogonType, SourceIP, SourceWorkstation
        ├── AuthPackage, ProcessName
        ├── LogoffType, LogoffConfidence
        ├── LockedSeconds, Notes
        └── Events[]  (timeline)
```

You can pipe results into further analysis:

```powershell
$results = .\Get-LogonSessionReport.ps1 -ComputerName "WS01" -UseStoredCredential
$results.Sessions | Where-Object LogonType -eq 'RemoteInteractive' | Format-Table User, LogonTime, DurationDisplay
```

## Security Notes

- Credentials are encrypted using Windows DPAPI (CurrentUser scope) — only the same Windows user on the same machine can decrypt
- No plaintext passwords are stored anywhere
- Temp files used during credential serialization are deleted immediately in a `finally` block
- The script does not require domain admin; local admin on targets is sufficient
