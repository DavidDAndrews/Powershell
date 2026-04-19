# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

The Validator directory contains PowerShell scripts for validating Veeam backup chains using the official Veeam Backup Validator executable. The main script discovers backup jobs in datastores and validates their integrity.

## Core Components

### Validate.PS1
Main validation script (renamed from the earlier `Validate-VeeamBackupChains.ps1`) that:
- Discovers Veeam backup jobs by scanning for VBM, VBK, VIB, and VRB files
- Skips folders that contain a VBM but no backup payload
- Validates backup chains using `Veeam.Backup.Validator.exe`
- Performs an independent VBM/disk cross-check to catch damage the validator skips
- Self-elevates via UAC when run non-elevated (unless `-SkipElevationCheck`)
- Generates an interactive HTML report (sort, orphan cleanup, graphical chain view)
- Auto-opens the HTML report in the default browser, maximised, unless suppressed
- Supports both local and network (UNC) datastores
- Handles orphaned backup files without VBM metadata

## Commands

### Running the Validator
```powershell
# Basic validation of a local datastore
.\Validate.PS1 -DatastorePath "D:\VeeamBackups"

# Validate with custom report path
.\Validate.PS1 -DatastorePath "D:\VeeamBackups" -ReportPath "C:\Reports"

# Interactive mode (shows menu)
.\Validate.PS1

# Silent mode validation
.\Validate.PS1 -DatastorePath "\\server\backups" -Silent
```

## Veeam Validator Integration

The script integrates with Veeam's validator executable located at:
`C:\Program Files\Veeam\Backup and Replication\Backup\Veeam.Backup.Validator.exe`

Key validator parameters used:
- `/file:` - Validates VBM metadata or individual backup files
- `/report:` - Generates HTML/XML validation reports
- `/format:` - Specifies report format (html or xml)
- `/silence` - Suppresses console output during validation

## Architecture Patterns

### Error Handling
- `Start-ValidationWorkflow` wraps its entire body in `try/catch/finally`; unhandled exceptions exit with code `1`
- Network drive cleanup always runs via `finally`, including on early returns and exceptions
- `Initialize-Environment` defers `$Script:LogFile` / `$Script:SummaryReport` assignment until after the report directory is confirmed to exist (required for `Set-StrictMode -Version Latest` compliance)
- `New-Item` for the report directory is wrapped in `try/catch` with a descriptive re-throw
- Temp stdout/stderr files in `Invoke-VeeamValidator` are declared `$null` before `try` and guarded in `finally` against never being assigned
- `New-PSDrive` only receives `-Credential` when the value is non-null
- Each report output format (HTML, CSV, JSON) has its own `try/catch` so one failure does not abort others
- `Send-TeamsNotification` validates the URL format before calling `Invoke-RestMethod`
- `Find-VeeamBackupJobs` guards against null/empty/inaccessible paths at entry

### Exit Codes
The script always calls `exit` with a meaningful code:
- `0` — all backups validated successfully
- `1` — script/configuration error (bad path, missing validator, unhandled exception)
- `2` — no backup jobs found in the datastore
- `3` — one or more backup validation failures

### Reporting Structure
- HTML container is 95vw with minimal padding; alternating row colours in the results table
- 3-card summary grid: Total / Successful / Failed  (Failed counts anything non-Success)
- Job names are GUID-stripped for display (e.g. `DC01_242B8` → `DC01`) via a regex that
  matches trailing `_<hex>{4,}`
- Sort controls (Machine ▲/▼, Last Run ▲/▼) reorder the results table and the chain
  visualization in sync; each `<tr>` and `.job-chain` carries `data-machine` and
  `data-lastrun` (ISO-8601) attributes for sorting
- Backup Chain Visualization: each job rendered in a light-purple panel, one chain row
  per VBK segment. Green = full, blue = incremental, red = problem
- Problem labels: `CORRUPT VBK/VIB`, `RP VBK/VIB MISSING`, `VIB NOT VALID - BROKEN CHAIN`,
  `UNREFERENCED VBK/VIB`. Broken state cascades downstream within a sub-chain until the
  next VBK resets it
- Possible Orphaned Files (extras on disk not referenced by VBM) render in a separate,
  chronologically-ordered final row with a softer amber panel in the Validation Results
- Red cards (UNREFERENCED, CORRUPT) carry a `Select` checkbox. An action bar at the bottom
  provides DELETE and ARCHIVE buttons that show a PowerShell command to copy to the
  clipboard (ARCHIVE moves to `<Drive>:\ORPHANED`, created if needed, grouped by drive)
- Auto-opens in default browser (Chromium gets `--start-maximized`); suppressed by
  `-Silent` or `-NoOpenReport`
- CSV export flattens nested hashtables including ChainIntegrityStatus / MissingFromDisk /
  ExtraOnDisk columns for readable spreadsheet output
- JSON export uses `-Depth 10` to avoid truncating nested chain data

### Backup Discovery Logic
1. Scans recursively for VBM files (backup metadata)
2. Associates VBK (full), VIB (incremental), and VRB (reverse incremental) files with jobs
3. Folders with a VBM but no VBK/VIB/VRB payload are skipped entirely
4. Identifies orphaned backup files without metadata
5. Extracts job names from file naming patterns

### Chain Integrity Cross-Check
- `Get-VbmFileManifest` scans the VBM content with a strict regex `[A-Za-z0-9._\-]+\.(?:vbk|vib|vrb)`
  to avoid capturing surrounding XML markup
- `Test-BackupChainIntegrity` compares the VBM manifest against actual files in the job directory
- Produces `MissingFromDisk` (referenced by VBM, gone) and `ExtraOnDisk` (on disk, not referenced)
  lists that drive both the HTML cards and the per-row integrity panels
- Missing entries are placed into the chain visualization in chronological order using
  `Get-VeeamFilenameTimestamp`, which extracts the embedded `yyyy-MM-ddTHHmmss` timestamp
  from Veeam file names

### Self-Elevation
- Immediately after the param block, checks `WindowsPrincipal.IsInRole(Administrator)`
- If not elevated, rebuilds `$PSBoundParameters` as a quoted argument string, re-launches via
  `Start-Process -Verb RunAs -Wait -PassThru`, and exits with the elevated exit code
- Uses `[Diagnostics.Process]::GetCurrentProcess().MainModule.FileName` so pwsh.exe and
  powershell.exe are both handled correctly
- Guarded by `-SkipElevationCheck`; PSCredential is not forwarded across the process boundary

### Interactive Cleanup UX (DELETE / ARCHIVE)
- Each selectable red card emits an embedded checkbox with `data-path="<FullName>"`
- The generated JavaScript lives inside a PowerShell single-quoted here-string (`@'...'@`),
  which is fully literal — the JS must be authored with `"` string delimiters and expect no
  PowerShell escape processing. `psQuote()` produces PS single-quoted literals by doubling
  any internal `'` (a single `split("'").join("''")` in JS)
- DELETE dialog is a red panel with a blinking-yellow warning header, the list of target
  files, a ready-to-run PowerShell command, and 📋 Copy Command / Close buttons
- ARCHIVE groups paths by drive letter and emits one `New-Item` + `Move-Item` block per drive
  targeting `<Drive>:\ORPHANED`
- Browsers cannot modify the filesystem — the commands are clipboard-copyable; the user runs
  them in an elevated PowerShell terminal

## Related Components

The parent directory contains VeeamItUp+ which provides:
- Network drive mapping functionality
- Server profile management with encrypted credentials
- VBM metadata parsing for chain validation
- Extended backup file analysis and reporting

When working with network paths, consider leveraging VeeamItUp+'s credential management patterns from `../VeeamItUp+/VeeamItUpPlus.ps1`.

## File Types Processed
- `.vbm` - Veeam Backup Metadata (contains chain information)
- `.vbk` - Full backup files
- `.vib` - Incremental backup files
- `.vrb` - Reverse incremental backup files (treated as incrementals for chain/size purposes)

## Output Structure
Reports are saved to `%USERPROFILE%\Downloads\VeeamValidation\` by default:
- `ValidationSummary_[timestamp].html` - Main summary report
- `[JobName]_[timestamp].html` - Individual job validation reports
- `VeeamValidation_[timestamp].log` - Detailed execution log