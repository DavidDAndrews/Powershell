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
- Comprehensive try-catch blocks with detailed logging
- Graceful handling of missing files and orphaned backups
- Validation continues even if individual jobs fail

### Reporting Structure
- HTML reports with Chart.js visualizations
- Summary statistics and per-job validation details
- Color-coded status indicators (Success, PartialSuccess, Failed, Error)
- Links to individual validation reports

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