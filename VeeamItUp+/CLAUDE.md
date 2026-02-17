# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

VeeamItUp+ is a PowerShell-based utility for analyzing and reporting on Veeam backup repositories across multiple servers. It maps network drives, scans for Veeam backup files (.vbk, .vib, .vbm), and generates comprehensive HTML reports with storage metrics and recommendations.

## Core Architecture

### Main Components

1. **Network Drive Management** (`New-NetworkDrive`, `Remove-NetworkDrive`)
   - Maps UNC paths to local drive letters
   - Handles credential management via secure registry storage

2. **Server Profile Management** (`Get-SavedServers`, `Save-ServerSettings`, `Get-ServerSettings`)
   - Stores server configurations in registry at `HKCU:\Software\VeeamItUpPlus`
   - Encrypts credentials using Windows DPAPI

3. **Backup Discovery** (`Find-AllBackupLocations`, `Get-VeeamBackupFileInfo`)
   - Recursive scanning for Veeam backup files
   - Parses backup filenames to extract metadata (VM names, backup types, timestamps)

4. **Storage Analysis** (`Measure-StorageMetrics`, `Get-StorageRecommendations`)
   - Calculates retention periods, storage growth rates
   - Provides actionable storage optimization recommendations

5. **HTML Reporting** (`New-HTMLReport`, `Update-HTMLLog`)
   - Generates interactive HTML reports with Chart.js visualizations
   - Real-time activity logging with auto-refresh capability

## Development Commands

### Running the Script
```powershell
# Execute the main script
.\VeeamItUpPlus.ps1

# Note: Script requires PowerShell 5.1 or later
# Runs interactively with menu-driven interface
```

### Testing Connectivity
The script includes built-in connectivity testing via menu option 'C' which:
- Tests network reachability to servers
- Validates UNC path access
- Checks credential validity

### Viewing Logs
- HTML activity logs are automatically created in `%USERPROFILE%\Downloads`
- Access logs via menu option 'L' or directly open the HTML file
- Logs include filtering by severity level (CRITICAL, FAILURE, WARNING, INFORMATIONAL)

## Key Functions Reference

### Core Operations
- `Start-ReportForMappedDrive`: Main workflow orchestrator for backup analysis
- `Find-AllBackupLocations`: Discovers all backup repositories on a drive
- `New-HTMLReport`: Generates the comprehensive analysis report

### Utility Functions
- `Write-Log`: Centralized logging with HTML output
- `Format-StorageSize`: Converts bytes to human-readable format
- `Test-ServerConnectivity`: Validates server accessibility

## Important Patterns

### Error Handling
- All functions use try-catch blocks with detailed logging
- Failures are logged with 'FAILURE' or 'CRITICAL' levels
- Script continues operation on non-critical failures

### Security
- Passwords stored encrypted in registry using `ConvertTo-SecureString`
- Credentials passed as SecureString objects
- Network drives mapped with explicit credentials

### Logging
- All operations logged to HTML file with timestamps
- Log levels: CRITICAL, FAILURE, WARNING, INFORMATIONAL, ALL
- Success operations marked with ✅ emoji automatically

## File Extensions Handled
- `.vbk` - Full backup files
- `.vib` - Incremental backup files  
- `.vbm` - Backup metadata files
- `.vbrbak` - Backup repository metadata

## Registry Structure
```
HKCU:\Software\VeeamItUpPlus\
  └── Servers\
      └── [ServerKeyName]\
          ├── UNCPath
          ├── Username
          ├── Password (encrypted)
          ├── DriveLetter
          └── ServerName
```

## Notes
- Script operates in a continuous menu loop until user quits
- Automatically removes old log files (keeps last 3)
- HTML reports include interactive charts and drill-down capabilities
- All file operations use absolute paths