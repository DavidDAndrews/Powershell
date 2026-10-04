# FixWindows

Windows maintenance and cleanup for Windows 10/11 (x64/ARM64) and Windows Server 2012 R2 to 2025, written for Windows PowerShell 5.1.

## Files

- `FixWindows.ps1` - the script. Self-elevates through UAC, then runs: platform detection, ISO sync from a network share, DISM ScanHealth/CheckHealth/RestoreHealth sourced from the local ISO, SFC and volume repair, event-log archive and clear, file cleanup, stale-profile removal, Windows Update (PSWindowsUpdate with a COM fallback), CleanMgr, and a restart.
- `FixWindows.config.json` - optional settings beside the script: ISO share path, ISO file per platform, work folder, event-log backup root, retention days, shadow-copy and restore-point options.
- `Enable-PowerShellExecution.bat` - helper that checks for `C:\SVC` and sets the PowerShell execution policy on a new machine.

## Usage

```powershell
.\FixWindows.ps1
.\FixWindows.ps1 -DaysToDelete 7 -ProfileAge 60 -SkipWindowsUpdate
.\FixWindows.ps1 -Unattended -NoRestart -ISOSourcePath 'D:\ISO'
.\FixWindows.ps1 -WhatIf
```

Parameters: `-DaysToDelete` (default 1), `-ProfileAge` (default 30), `-SkipHealthCheck`, `-SkipWindowsUpdate`, `-NoRestart`, `-Unattended`, `-ISOSourcePath`, `-ConfigPath`, plus `-WhatIf`. Command-line parameters override the JSON config, which overrides the built-in defaults. Full help: `Get-Help .\FixWindows.ps1 -Full`.

## Output and exit codes

- Transcript: `C:\SVC\Clean-<date>.log`; event-log archives under `C:\Logs\<Month-day>\`
- Share credentials, if prompted, are cached DPAPI-encrypted at `%USERPROFILE%\FixWindows-Credentials.xml`
- Exit codes: `0` success, `1` fatal error, `2` completed with one or more failed phases
