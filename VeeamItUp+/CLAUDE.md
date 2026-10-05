# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

VeeamItUp+ is a PowerShell-based utility for analyzing and reporting on Veeam backup repositories across multiple servers. It maps network drives, scans for Veeam backup files (.vbk, .vib, .vrb, .vbm), and generates comprehensive HTML reports with storage metrics and recommendations, optionally with OpenAI-generated analysis and emailed via SMTP.

## Core Architecture

### Main Components

1. **Network Drive Management** (`New-NetworkDrive`, `Remove-NetworkDrive`)
   - Maps UNC paths to local drive letters
   - Handles credential management via secure registry storage

2. **Server Profile Management** (`Get-SavedServers`, `Save-ServerSettings`, `Load-ServerSettings`, `Manage-ServerProfiles`)
   - Stores server configurations in registry at `HKCU:\Software\VeeamItUpPlus`
   - Encrypts passwords using Windows DPAPI (`ConvertTo-EncryptedString` / `ConvertFrom-EncryptedString`)

3. **Backup Discovery** (`Find-AllBackupLocations`, `Get-VeeamBackupFileInfo`, `Parse-VBMMetadata`)
   - Recursive scanning for Veeam backup files and VBM chain metadata
   - Parses backup filenames to extract metadata (VM names, backup types, timestamps)

4. **Storage Analysis** (`Measure-StorageMetrics`, `Analyze-BackupRetention`, `Analyze-GFSCompliance`, `Get-VerboseStorageRecommendations`)
   - Calculates retention periods, storage growth rates
   - Provides actionable storage optimization recommendations

5. **HTML Reporting** (`New-HTMLReport`, `New-HTMLActivityLog`, `Update-HTMLLog`)
   - Generates interactive HTML reports with Chart.js visualizations (loaded from the jsDelivr CDN)
   - Activity log file rewritten as the run progresses (reload the page to see new entries)

6. **OpenAI Analysis** (`Initialize-OpenAIConnection`, `Invoke-OpenAIAnalysis`, `Select-OpenAIModel`)
   - Optional; API key (DPAPI-encrypted) and model stored in the same registry key

7. **Email** (`Send-EmailReport`, `Configure-GlobalSMTPSettings`, `Configure-ServerSMTPSettings`)
   - Per-server or global SMTP settings (`HKCU:\Software\VeeamItUpPlus\GlobalSMTP`)

## Development Commands

### Running the Script
```powershell
# Execute the main script
.\VeeamItUpPlus.ps1

# Note: Script requires PowerShell 5.1 or later
# Runs interactively with menu-driven interface
```

Menu: `1-N` select a saved server and run the report, `S` manage server profiles, `C` test connectivity, `D` delete server profiles, `L` view the HTML activity log, `M` configure SMTP, `K` manage the OpenAI API key, `Q` quit. With no saved servers only `S`, `L`, `M`, `K` and `Q` are offered (add a profile under `S`).

`Test-VBMChainValidation.ps1` is a stand-alone test of the VBM chain-validation logic; it parses `./DC01.vbm` in the current folder (the committed `DC01.vbm` is a real sample VBM file; the referenced `.vbk`/`.vib` files are not in the repo).

### Testing Connectivity
The script includes built-in connectivity testing via menu option 'C' which:
- Tests network reachability to servers
- Validates UNC path access
- Checks credential validity

### Viewing Logs
- HTML activity logs (`VeeamItUpPlusLog-*.html`) are automatically created in `%USERPROFILE%\Downloads`
- Access logs via menu option 'L' or directly open the HTML file
- The log page has First / Refresh / Last buttons and a level filter (ALL, SUCCESS, ERROR); it does not refresh itself

## Key Functions Reference

### Core Operations
- `Run-ReportForMappedDrive`: Main workflow orchestrator for backup analysis
- `Find-AllBackupLocations`: Discovers all backup repositories on a drive
- `New-HTMLReport`: Generates the comprehensive analysis report

### Utility Functions
- `Write-Log`: Centralized logging to the HTML log only (no console output)
- `Format-StorageSize`: Converts bytes to human-readable format
- `Test-ServerConnectivity`: Validates server accessibility

## Important Patterns

### Error Handling
- All functions use try-catch blocks with detailed logging
- Failures are logged with the 'ERROR' level
- Script continues operation on non-critical failures

### Security
- Passwords stored encrypted in registry using DPAPI (`ProtectedData`, CurrentUser scope)
- Credentials passed as SecureString objects
- Network drives mapped with explicit credentials

### Logging
- All operations logged to HTML file with timestamps
- Log levels: `SUCCESS` (default) and `ERROR`
- Messages containing "succeeded" or "successfully" get a ✅ appended automatically

## File Extensions Handled
- `.vbk` - Full backup files
- `.vib` - Incremental backup files  
- `.vrb` - Reverse incremental backup files
- `.vbm` - Backup metadata files

## Registry Structure
```
HKCU:\Software\VeeamItUpPlus\
  ├── OpenAIAPIKey (encrypted), OpenAIModel
  ├── GlobalSMTP\
  └── [ServerKeyName]\
      ├── UNCPath
      ├── Username
      ├── Password (encrypted)
      ├── DriveLetter
      ├── ServerName
      └── EmailAddress, EmailEnabled, SMTPServer, SMTPPort, SMTPUsername, SMTPPassword (encrypted), UseSSL
```

## Notes
- Script operates in a continuous menu loop until user quits
- Automatically removes old log files (keeps last 3)
- HTML reports include interactive charts and drill-down capabilities
- All file operations use absolute paths