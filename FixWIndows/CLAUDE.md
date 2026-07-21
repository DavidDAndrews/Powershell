# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

Windows maintenance and cleanup utility for Windows PowerShell 5.1 (the version that ships with Windows — no PowerShell 7 features are used). Files:

- `FixWindows.ps1` — the main script. Self-elevates via UAC and runs maintenance in ordered, individually fault-tolerant phases.
- `FixWindows.config.json` — optional runtime configuration (ISO share path, ISO filename map, retention periods, cleanup paths). Lets the script be updated per-environment without editing code.
- `Enable-PowerShellExecution.bat` — helper to set the execution policy on new machines.

## Script Architecture (FixWindows.ps1)

The script is organized into `#region` blocks:

1. **Self-elevation** — relaunches elevated via UAC, forwarding all bound parameters.
2. **Default configuration** (`$Defaults`) — every tunable value, overridable by the JSON config, which is in turn overridable by explicit command-line parameters (`Merge-Configuration`).
3. **Output helpers** — `Write-BoxedText` (centered console boxes), `Write-Log` (timestamped), `Write-Warning/Error/SuccessBox`, sound helpers (`Use-MissionImpossible`, `Use-Mario`, all silent in `-Unattended` mode).
4. **Platform detection** — `Get-PlatformInfo` detects Windows 10/11 (x64/ARM64) and Server 2012 R2–2025 (Core vs Desktop Experience) and maps to a platform key used to pick the ISO. `Resolve-WimIndex` inspects the ISO's `install.wim`/`install.esd` with `Get-WindowsImage` and picks the image index matching the running edition (fallback: index 2 for server Desktop Experience, else 1).
5. **Network share / ISO sync** — `Sync-LocalIso` pings the share host, authenticates (credentials cached DPAPI-encrypted at `%USERPROFILE%\FixWindows-Credentials.xml`), and copies the ISO to `C:\SVC` only when the source's size/timestamp differs from the local copy.
6. **Maintenance phases** — `Invoke-HealthCheck` (DISM scan/check/restore from local ISO + SFC), `Invoke-VolumeRepair` (all fixed NTFS/ReFS volumes), `Backup-AndClearEventLogs`, `Invoke-FileCleanup` (table-driven from `CleanupPaths`), `Invoke-ProfileCleanup` (CIM-based), `Invoke-WindowsUpdatePhase` (PSWindowsUpdate with Windows Update COM fallback), `Invoke-CleanMgr` (enables all VolumeCaches handlers except `DownloadsFolder`).
7. **Main** — `Invoke-Phase` wraps each phase in try/catch, records status/duration, prints a summary table; restart at the end unless `-NoRestart`.

## Parameters

- `-DaysToDelete <int>` — age threshold for temp-file cleanup (default 1)
- `-ProfileAge <int>` — age threshold for stale profile removal (default 30)
- `-SkipHealthCheck` — skip DISM/SFC/volume repair (and ISO download)
- `-SkipWindowsUpdate` — skip the update phase
- `-NoRestart` — do not reboot at the end
- `-Unattended` — no prompts, countdowns, or sounds (for scheduled tasks)
- `-ISOSourcePath <path>` — override the ISO share path
- `-ConfigPath <path>` — alternate JSON config location
- `-WhatIf` — supported; destructive operations are skipped/logged

## Configuration precedence

Command-line parameters > `FixWindows.config.json` > built-in `$Defaults`. The JSON `IsoFiles` map merges per key, so a partial map only overrides the entries it names. `DeleteShadowCopies` defaults to `false` because deleting shadow copies destroys System Restore points (including the one the script creates).

## Exit codes

- `0` — success
- `1` — fatal error (unsupported OS, no ISO mapping, etc.)
- `2` — completed, but one or more phases failed

## Development notes

- Target Windows PowerShell 5.1: no ternary, `??`, `&&`/`||` chains, or `ForEach-Object -Parallel`.
- Prefer `Get-CimInstance` over the removed-in-PS7 `Get-WmiObject`.
- Lint with `Invoke-ScriptAnalyzer -Path .\FixWindows.ps1`; parse-check with `[System.Management.Automation.Language.Parser]::ParseFile`. Remaining accepted warnings: `Write-Host` (intentional console UX) and empty catch blocks used as reachability probes.
- Logs: transcript at `C:\SVC\Clean-<date>.log`; event log archives under `C:\Logs\<Month-day>\`.
