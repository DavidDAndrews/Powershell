# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

The Validator directory contains PowerShell scripts for validating Veeam backup chains using the official Veeam Backup Validator executable. The main script discovers backup jobs in datastores and validates their integrity.

## Core Components

### Validate-VeeamBackupChains.ps1
Main validation script that:
- Discovers Veeam backup jobs by scanning for VBM, VBK, and VIB files
- Validates backup chains using `Veeam.Backup.Validator.exe`
- Generates HTML reports with validation results and statistics
- Supports both local and network (UNC) datastores
- Handles orphaned backup files without VBM metadata

## Commands

### Running the Validator
```powershell
# Basic validation of a local datastore
.\Validate-VeeamBackupChains.ps1 -DatastorePath "D:\VeeamBackups"

# Validate with custom report path
.\Validate-VeeamBackupChains.ps1 -DatastorePath "D:\VeeamBackups" -ReportPath "C:\Reports"

# Interactive mode (shows menu)
.\Validate-VeeamBackupChains.ps1

# Silent mode validation
.\Validate-VeeamBackupChains.ps1 -DatastorePath "\\server\backups" -Silent
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
- HTML reports with summary grid and per-job status table
- Summary statistics and per-job validation details
- Color-coded status indicators (Success, PartialSuccess, Failed, Error)
- Links to individual Veeam Validator HTML reports
- CSV export flattens nested hashtables into `[PSCustomObject]` for readable columns
- JSON export uses `-Depth 10` to avoid truncating nested chain data

### Backup Discovery Logic
1. Scans recursively for VBM files (backup metadata)
2. Associates VBK (full) and VIB (incremental) files with jobs
3. Identifies orphaned backup files without metadata
4. Extracts job names from file naming patterns

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

## Output Structure
Reports are saved to `%USERPROFILE%\Downloads\VeeamValidation\` by default:
- `ValidationSummary_[timestamp].html` - Main summary report
- `[JobName]_[timestamp].html` - Individual job validation reports
- `VeeamValidation_[timestamp].log` - Detailed execution log