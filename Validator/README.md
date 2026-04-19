# Validate.PS1 (Veeam Backup Chain Validator)

A PowerShell script that discovers and validates Veeam backup chains in a datastore using the
official `Veeam.Backup.Validator.exe` and produces HTML, CSV, and JSON reports.

## Requirements

- PowerShell 5.1+
- Veeam Backup & Replication with the Validator component installed
- Read access to the backup datastore

## Usage

```powershell
# Basic — validate a local datastore
.\Validate.PS1 -DatastorePath "D:\VeeamBackups"

# Custom report output directory
.\Validate.PS1 -DatastorePath "D:\VeeamBackups" -ReportPath "C:\Reports"

# UNC path with stored credentials
.\Validate.PS1 -DatastorePath "\\server\backups" -Credential (Get-Credential)

# Export CSV and JSON alongside the HTML report
.\Validate.PS1 -DatastorePath "D:\VeeamBackups" -ExportCsv -ExportJson

# Send a Teams summary on completion
.\Validate.PS1 -DatastorePath "D:\VeeamBackups" `
    -SendTeamsNotification -TeamsWebhookUrl "https://outlook.office.com/webhook/..."

# Silent (no console output — log file only)
.\Validate.PS1 -DatastorePath "D:\VeeamBackups" -Silent

# Unattended run — no UAC prompt, no browser pop-up
.\Validate.PS1 -DatastorePath "D:\VeeamBackups" -SkipElevationCheck -NoOpenReport
```

## Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `DatastorePath` | String | _(prompted)_ | Local or UNC path to the backup datastore |
| `ValidatorPath` | String | `C:\Program Files\Veeam\...\Veeam.Backup.Validator.exe` | Override the validator executable path |
| `ReportPath` | String | `%USERPROFILE%\Downloads\VeeamValidation` | Directory for all output files |
| `Credential` | PSCredential | — | Credentials for UNC path access |
| `IncludeAllVMs` | Switch | — | Validate each VM in a backup (slower) |
| `Silent` | Switch | — | Suppress console output; write log file only |
| `ExportCsv` | Switch | — | Also write a flat CSV of results |
| `ExportJson` | Switch | — | Also write a JSON file of results |
| `SendTeamsNotification` | Switch | — | POST a summary to a Teams Incoming Webhook |
| `TeamsWebhookUrl` | String | — | The Teams Incoming Webhook URL |
| `SkipElevationCheck` | Switch | — | Suppress the automatic UAC re-launch when the session is not elevated (scheduled tasks, CI, SYSTEM context) |
| `NoOpenReport` | Switch | — | Do NOT auto-open the HTML report in the default browser (unattended runs) |

## Self-Elevation

When launched in a non-elevated session the script automatically re-launches itself
via UAC, preserving all original parameters. The re-launched elevated process's
exit code is returned to the caller — automation wrappers see the same code they'd
see from a directly-elevated run. Pass `-SkipElevationCheck` to suppress this.

## Chain Integrity Cross-Check

Before (and independent of) the Veeam validator, the script parses each job's VBM
manifest and cross-references it with the files actually on disk. This catches
chain damage that the Veeam validator can silently skip:

- **Missing from disk** (referenced by VBM, not present) — marks the job as Failed.
- **Possible Orphaned Files** (on disk, not referenced by VBM) — reported in a
  separate amber panel and shown in their own row in the chain visualization.

Folders containing a VBM but no `.vbk`/`.vib`/`.vrb` payload are silently skipped
(nothing meaningful to validate).

## Output Files

All files are written to `ReportPath` with a `yyyyMMdd_HHmmss` timestamp:

| File | Description |
|---|---|
| `VeeamValidation_<ts>.log` | Full execution log with timestamps and severity levels |
| `ValidationSummary_<ts>.html` | Colour-coded HTML report with per-job status |
| `<JobName>_<ts>.html` | Individual Veeam Validator HTML report per job |
| `ValidationResults_<ts>.csv` | Flat CSV export (requires `-ExportCsv`) |
| `ValidationResults_<ts>.json` | JSON export with full chain details (requires `-ExportJson`) |

## Exit Codes

The script always terminates with a machine-readable exit code, suitable for use in
scheduled tasks, CI pipelines, and monitoring wrappers.

| Code | Meaning |
|---|---|
| `0` | All backup jobs validated successfully |
| `1` | Script / configuration error (bad path, missing validator, unhandled exception) |
| `2` | No Veeam backup jobs found in the specified datastore |
| `3` | One or more backup jobs failed validation |

```powershell
.\Validate.PS1 -DatastorePath "D:\VeeamBackups"
if ($LASTEXITCODE -eq 3) { Send-Alert "Backup validation failures detected" }
```

## Error Handling

### Validator discovery
The script first checks the provided `-ValidatorPath`, then falls back to the Veeam
registry key (`HKLM:\SOFTWARE\Veeam\Veeam Backup and Replication`).  If neither yields a
valid executable it logs an error and exits with code `1`.

### Report directory initialisation
`Initialize-Environment` creates the report directory before setting `$Script:LogFile`,
so the log path is never referenced before the directory exists (avoiding `Set-StrictMode`
violations).  A `try/catch` around `New-Item` surfaces a descriptive error and propagates
it as a terminating exception if the directory cannot be created.

### Temporary file safety in the validator
Temp file paths (`$tempStdout` / `$tempStderr`) are initialised to `$null` before the
`try` block and assigned with `[System.IO.Path]::GetTempFileName()` inside it.  The
`finally` block guards each `Remove-Item` with an `if ($tempStdout)` check, so no
`StrictMode` error can occur if the `try` block throws before the assignment.

### Network drive mapping
`-Credential` is only passed to `New-PSDrive` when it is non-null; passing `$null`
explicitly can error on some systems.  The mapped drive is removed in the workflow's
`finally` block, which runs on all exit paths including early returns and unhandled
exceptions.

### Top-level workflow protection
`Start-ValidationWorkflow` wraps its entire body in `try/catch/finally`.  Unhandled
exceptions are caught, logged, and result in exit code `1`.  Cleanup (network drive
removal) always runs via `finally`, regardless of how the workflow exits.

### Reporting output
`Out-File`, `Export-Csv`, and `ConvertTo-Json | Out-File` are each wrapped in their own
`try/catch` so a failure writing one output format does not abort the others.  The CSV
export flattens nested hashtables into a `[PSCustomObject]` so column values are
meaningful rather than type names.

### Teams notification
`Send-TeamsNotification` validates that the webhook URL starts with `http://` or `https://`
before attempting the request, and reports a clear warning rather than a confusing
`Invoke-RestMethod` error for malformed URLs.

## Testing

`Test-ErrorHandling.ps1` in the same directory runs 8 automated tests against the main
script using child `pwsh` processes — no Veeam installation required.

```powershell
.\Test-ErrorHandling.ps1
```

Expected output:

```
  [PASS] T1: Validator executable not found
  [PASS] T2: Datastore path does not exist
  [PASS] T3: No backup jobs found (empty datastore)
  [PASS] T4: New report dir auto-created, log file written
  [PASS] T5: Empty DatastorePath rejected by path guard
  [PASS] T7: .vbm with no backup payload is skipped (exit 2)
  [PASS] T8: Broken chain detected via VBM/disk cross-check
  [PASS] T6: StrictMode startup check

  Results: 8/8 passed
```

The tests cover:

- Correct exit codes for each failure mode
- Log message pattern matching
- Deferred `$Script:LogFile` initialisation (T4)
- Absence of `Set-StrictMode` startup crashes (T6)
- Folders with a VBM but no backup payload are skipped (T7)
- Chain integrity cross-check detects missing + orphaned files (T8)
