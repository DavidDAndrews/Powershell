# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is a Windows maintenance and cleanup PowerShell script repository. The main file is `PS-FixW11.ps1`, which performs comprehensive system maintenance including:

- DISM (Deployment Image Servicing and Management) system file integrity checks
- Windows Update installation
- Disk cleanup and optimization
- System log cleanup and archiving
- User profile cleanup
- System restart and repair

## Key Script Architecture

### Core Components

1. **Configuration Section (Lines 49-138)**: 
   - Configurable variables for ISO paths, WIM values, cleanup thresholds
   - Network paths for Windows ISO files
   - Maintenance configurations and retention periods

2. **OS Detection (Lines 217-305)**:
   - Automatic detection of Windows versions (10, 11, Server 2016/2019/2022)
   - Sets appropriate ISO file and WIM index based on detected OS
   - Supports both desktop and server editions

3. **System Health Check (Lines 550-588)**:
   - DISM health scan and repair operations
   - Mounts Windows ISO for system file restoration
   - System File Checker (SFC) execution
   - Volume repair operations

4. **Cleanup Operations (Lines 600-896)**:
   - Comprehensive file cleanup across multiple system locations
   - Event log archiving and clearing
   - Windows Update cache cleanup
   - User profile cleanup based on age thresholds

### Key Functions

- `Write-BoxedText`: Creates formatted console output boxes
- `Write-WarningBox`, `Write-ErrorBox`, `Write-SuccessBox`: Status message helpers
- `Use-MissionImpossible`, `Use-Mario`: Audio notification functions
- `Start-CleanMGR`: Disk cleanup utility wrapper

## Script Configuration

### Key Variables to Modify

- `$ISO_SOURCE_PATH`: Network path to Windows ISO files
- `$ISO_FILES`: Hash table mapping Windows versions to ISO filenames
- `$WIM_VALUES`: WIM index values for different installation types
- `$CLEANUP_PATHS`: Directory paths for cleanup operations
- `$DEFAULT_DAYS_TO_DELETE`: File retention period
- `$PROFILE_AGE_LIMIT`: User profile cleanup threshold

### Parameters

- `-DaysToDelete`: Days before temp files are deleted (default: 1)
- `-ProfileAge`: Days before unused profiles are deleted (default: 30)
- `-SkipWindowsUpdate`: Skip Windows Update installation
- `-NoRestart`: Skip system restart
- `-ISOSourcePath`: Custom ISO source path

## Execution Requirements

- **Administrator privileges required**: Script self-elevates if not running as admin
- **Windows ISO access**: Requires access to Windows ISO files (network or local)
- **PowerShell execution policy**: Must allow script execution
- **Network connectivity**: For Windows Updates and ISO downloads

## Common Operations

### Running the Script
```powershell
# Basic execution
.\PS-FixW11.ps1

# With custom parameters
.\PS-FixW11.ps1 -DaysToDelete 7 -ProfileAge 60 -SkipWindowsUpdate

# Test run without restart
.\PS-FixW11.ps1 -NoRestart -WhatIf
```

### Customization
- Modify ISO_FILES hash table for different Windows versions
- Update CLEANUP_PATHS for additional cleanup locations
- Adjust retention periods in configuration section

## Important Notes

- Script creates logs in `C:\SVC\Clean-[date].log`
- Backs up event logs before clearing them
- Creates system restore point before major changes
- Requires reboot after completion for optimal results
- Handles both desktop and server Windows editions
- Supports Windows 10, 11, Server 2016, 2019, and 2022