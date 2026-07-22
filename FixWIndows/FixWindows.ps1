<#
.SYNOPSIS
    Comprehensive Windows system maintenance and cleanup script.

.DESCRIPTION
    Performs system maintenance in ordered phases:
      1. Platform detection (Windows 10/11 x64/ARM64, Server 2012 R2 - 2025, Core/Desktop)
      2. ISO sync from network share (downloads/refreshes only when the source copy differs)
      3. DISM ScanHealth / CheckHealth / RestoreHealth sourced from the local ISO,
         with the WIM/ESD index resolved dynamically against the running edition
      4. SFC scan and volume repair on all fixed drives
      5. Event log archive + clear
      6. Table-driven file cleanup (temp folders, caches, logs, dumps, vendor folders)
      7. Stale user profile removal
      8. Windows Update (PSWindowsUpdate module with COM fallback)
      9. CleanMgr sweep, job summary, optional restart

    All defaults can be overridden by FixWindows.config.json placed next to the
    script (see the sample file). Explicit command-line parameters always win
    over the config file, which wins over built-in defaults.

    Requires Windows PowerShell 5.1 (ships with Windows) - no external modules
    are required; PSWindowsUpdate is installed opportunistically and the script
    falls back to the built-in Windows Update COM API when unavailable.

.PARAMETER DaysToDelete
    Files older than this many days are removed from age-filtered cleanup paths. Default 1.

.PARAMETER ProfileAge
    User profiles not used for this many days are removed. Default 30.

.PARAMETER SkipHealthCheck
    Skip the DISM/SFC/volume-repair phase (and therefore the ISO download).

.PARAMETER SkipWindowsUpdate
    Skip the Windows Update phase.

.PARAMETER NoRestart
    Do not restart the computer when finished.

.PARAMETER Unattended
    Fully non-interactive: no countdown, no sounds, no credential prompts
    (fails instead of prompting). Intended for scheduled-task use.

.PARAMETER ISOSourcePath
    UNC or local folder containing the Windows ISO files,
    e.g. "\\192.168.111.10\nas-data\ISO\WINDOWS". Overrides the config file.

.PARAMETER ConfigPath
    Path to a JSON config file. Defaults to FixWindows.config.json beside the script.

.EXAMPLE
    .\FixWindows.ps1
.EXAMPLE
    .\FixWindows.ps1 -DaysToDelete 7 -ProfileAge 60 -SkipWindowsUpdate
.EXAMPLE
    .\FixWindows.ps1 -Unattended -NoRestart -ISOSourcePath 'D:\ISO'
.EXAMPLE
    .\FixWindows.ps1 -WhatIf     # show what would be done without changing anything

.NOTES
    Author: David Andrews  (C) 2022-2026 All Rights Reserved
    Requires: Windows PowerShell 5.1, Administrator (self-elevates via UAC)
    Log: C:\SVC\Clean-<date>.log
#>
#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium',
    HelpUri = 'https://github.com/DavidDAndrews/FixWindows')]
param(
    [ValidateRange(0, 3650)]
    [int]$DaysToDelete = 1,

    [ValidateRange(1, 3650)]
    [int]$ProfileAge = 30,

    [switch]$SkipHealthCheck,

    [switch]$SkipWindowsUpdate,

    [switch]$NoRestart,

    [switch]$Unattended,

    [string]$ISOSourcePath,

    [string]$ConfigPath
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

#region ============================ SELF-ELEVATION =============================

$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Not elevated - relaunching as Administrator (UAC prompt)...' -ForegroundColor Yellow
    # Rebuild the exact argument list so parameters survive the relaunch
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath))
    foreach ($entry in $PSBoundParameters.GetEnumerator()) {
        if ($entry.Value -is [System.Management.Automation.SwitchParameter]) {
            if ($entry.Value.IsPresent) { $argList += ('-{0}' -f $entry.Key) }
        }
        else {
            $argList += ('-{0}' -f $entry.Key)
            $argList += ('"{0}"' -f $entry.Value)
        }
    }
    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList ($argList -join ' ') -Verb RunAs
    }
    catch {
        Write-Host "Elevation was declined or failed: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
    exit 0
}

#endregion

#region ======================= DEFAULT CONFIGURATION ==========================
# Everything in $Defaults can be overridden by FixWindows.config.json.
# Explicit command-line parameters override both.

$Defaults = @{
    IsoSourcePath      = '\\192.168.111.10\nas-data\ISO\WINDOWS'
    WorkFolder         = 'C:\SVC'
    EventLogBackupRoot = 'C:\Logs'
    DaysToDelete       = 1
    ProfileAge         = 30
    IisLogAgeDays      = 60
    # Deleting shadow copies also deletes System Restore points, so this is
    # opt-in. Set to true in the config file to restore the old behavior.
    DeleteShadowCopies = $false
    CreateRestorePoint = $true
    # ISO file per platform key (keys produced by Get-PlatformInfo)
    IsoFiles           = @{
        WIN11       = 'W11PRO-24H2.ISO'
        WIN11_ARM64 = 'W11Pro-ARM64.iso'
        WIN10       = 'W10PRO-1809.ISO'
        SVR2025     = 'W2025.ISO'
        SVR2022     = 'W2022.ISO'
        SVR2019     = 'W2019-1809.ISO'
        SVR2016     = 'W2016-1607.ISO'
        SVR2012R2   = 'W2012R2-1207.ISO'
    }
    # Folders whose entire contents are removed subject to the age filter.
    # AgeDays 0 = delete regardless of age; -1 = use DaysToDelete.
    CleanupPaths       = @(
        @{ Path = 'C:\Windows\Temp\*';                                                          AgeDays = -1; Name = 'Windows temp folder' }
        @{ Path = 'C:\Users\*\AppData\Local\Temp\*';                                            AgeDays = -1; Name = 'User temp folders' }
        @{ Path = 'C:\Users\*\AppData\Local\Microsoft\Windows\Temporary Internet Files\*';      AgeDays = -1; Name = 'Temporary internet files' }
        @{ Path = 'C:\Windows\Logs\CBS\*.log';                                                  AgeDays = 0;  Name = 'CBS log files' }
        @{ Path = 'C:\ProgramData\Microsoft\Windows\WER\*';                                     AgeDays = 0;  Name = 'Windows Error Reporting (system)' }
        @{ Path = 'C:\Users\*\AppData\Local\Microsoft\Windows\WER\*';                           AgeDays = 0;  Name = 'Windows Error Reporting (users)' }
        @{ Path = 'C:\Users\*\AppData\Local\Microsoft\Windows\INetCache\*';                     AgeDays = 0;  Name = 'INet cache' }
        @{ Path = 'C:\Users\*\AppData\Local\Microsoft\Windows\INetCookies\*';                   AgeDays = 0;  Name = 'INet cookies' }
        @{ Path = 'C:\Users\*\AppData\Local\Microsoft\Windows\IECompatCache\*';                 AgeDays = 0;  Name = 'IE compat cache' }
        @{ Path = 'C:\Users\*\AppData\Local\Microsoft\Windows\IECompatUaCache\*';               AgeDays = 0;  Name = 'IE compat UA cache' }
        @{ Path = 'C:\Users\*\AppData\Local\Microsoft\Windows\IEDownloadHistory\*';             AgeDays = 0;  Name = 'IE download history' }
        @{ Path = 'C:\Users\*\AppData\Local\Microsoft\Terminal Server Client\Cache\*';          AgeDays = 0;  Name = 'Terminal Server client cache' }
        @{ Path = 'C:\Windows\minidump\*';                                                      AgeDays = 0;  Name = 'Minidump files' }
        @{ Path = 'C:\Windows\Prefetch\*';                                                      AgeDays = 0;  Name = 'Prefetch' }
    )
    # Folders removed outright if present
    FoldersToRemove    = @('C:\Config.Msi', 'C:\Intel', 'C:\Dell', 'C:\PerfLogs')
    # Individual files removed outright if present
    FilesToRemove      = @('C:\Windows\memory.dmp')
}

#endregion

#region ========================= OUTPUT HELPERS ===============================

function Get-ConsoleWidth {
    try {
        $w = $Host.UI.RawUI.WindowSize.Width
        if ($w -ge 40) { return $w }
    }
    catch { }
    return 100
}

function Write-BoxedText {
    param(
        [string]$Title,
        [string[]]$Messages = @(),
        [string]$ForegroundColor = 'White'
    )
    $lines = @($Messages | Where-Object { $null -ne $_ })
    $maxLength = $Title.Length
    foreach ($line in $lines) {
        if ($line.Length -gt $maxLength) { $maxLength = $line.Length }
    }
    $consoleWidth = Get-ConsoleWidth
    if ($maxLength -gt ($consoleWidth - 6)) { $maxLength = $consoleWidth - 6 }

    $h = [string][char]0x2500
    $horizontalLine = $h * ($maxLength + 2)
    $leftPadding = ' ' * [Math]::Max(0, [Math]::Floor(($consoleWidth - ($maxLength + 4)) / 2))
    $v = [char]0x2502

    Write-Host ($leftPadding + [char]0x250C + $horizontalLine + [char]0x2510) -ForegroundColor $ForegroundColor
    if ($Title) {
        $t = if ($Title.Length -gt $maxLength) { $Title.Substring(0, $maxLength) } else { $Title }
        Write-Host ($leftPadding + $v + ' ' + $t.PadRight($maxLength) + ' ' + $v) -ForegroundColor $ForegroundColor
        if ($lines.Count -gt 0) {
            Write-Host ($leftPadding + [char]0x251C + $horizontalLine + [char]0x2524) -ForegroundColor $ForegroundColor
        }
    }
    foreach ($line in $lines) {
        if ($line.Length -gt $maxLength) { $line = $line.Substring(0, $maxLength) }
        Write-Host ($leftPadding + $v + ' ' + $line.PadRight($maxLength) + ' ' + $v) -ForegroundColor $ForegroundColor
    }
    Write-Host ($leftPadding + [char]0x2514 + $horizontalLine + [char]0x2518) -ForegroundColor $ForegroundColor
}

function Write-WarningBox { param([string]$Message) Write-BoxedText -Title '! WARNING' -Messages @($Message) -ForegroundColor Yellow }
function Write-ErrorBox   { param([string]$Message) Write-BoxedText -Title 'X ERROR'   -Messages @($Message) -ForegroundColor Red }
function Write-SuccessBox { param([string]$Message) Write-BoxedText -Title '+ SUCCESS' -Messages @($Message) -ForegroundColor Green }

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('Info', 'Warning', 'Error', 'Success')][string]$Level = 'Info'
    )
    $color = switch ($Level) {
        'Warning' { 'Yellow' }
        'Error'   { 'Red' }
        'Success' { 'Green' }
        default   { 'Gray' }
    }
    Write-Host ('[{0:HH:mm:ss}] {1}' -f (Get-Date), $Message) -ForegroundColor $color
}

function Invoke-Beep {
    # All sounds are suppressed in unattended mode and tolerate hosts with no console
    param([int]$Frequency = 800, [int]$Duration = 200)
    if ($script:Unattended) { return }
    try { [Console]::Beep($Frequency, $Duration) } catch { }
}

function Use-MissionImpossible {
    if ($script:Unattended) { return }
    foreach ($note in @(784, 784, 932, 1047, 784, 784)) {
        Invoke-Beep -Frequency $note -Duration 150
        Start-Sleep -Milliseconds 200
    }
}

function Use-Mario {
    if ($script:Unattended) { return }
    foreach ($note in @(659, 659, 659, 523, 659, 784)) {
        Invoke-Beep -Frequency $note -Duration 100
        Start-Sleep -Milliseconds 150
    }
    Invoke-Beep -Frequency 395 -Duration 250
}

#endregion

#region ====================== CONFIG FILE HANDLING ============================

function Merge-Configuration {
    <# Overlays FixWindows.config.json (if present) onto $Defaults, then applies
       any explicitly supplied command-line parameters on top. #>
    param([hashtable]$BaseConfig, [string]$Path)

    $config = @{}
    foreach ($key in $BaseConfig.Keys) { $config[$key] = $BaseConfig[$key] }

    if ($Path -and (Test-Path -LiteralPath $Path)) {
        Write-Log "Loading configuration overrides from $Path"
        try {
            $json = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
            foreach ($prop in $json.PSObject.Properties) {
                switch ($prop.Name) {
                    'IsoFiles' {
                        # Merge per-key so a partial map only overrides what it names
                        foreach ($isoProp in $prop.Value.PSObject.Properties) {
                            $config.IsoFiles[$isoProp.Name] = [string]$isoProp.Value
                        }
                    }
                    'CleanupPaths' {
                        $paths = @()
                        foreach ($item in $prop.Value) {
                            $age = -1
                            if ($item.PSObject.Properties.Name -contains 'AgeDays') { $age = [int]$item.AgeDays }
                            $name = if ($item.PSObject.Properties.Name -contains 'Name') { [string]$item.Name } else { [string]$item.Path }
                            $paths += @{ Path = [string]$item.Path; AgeDays = $age; Name = $name }
                        }
                        $config.CleanupPaths = $paths
                    }
                    default { $config[$prop.Name] = $prop.Value }
                }
            }
        }
        catch {
            Write-Log "Config file could not be parsed, using defaults: $($_.Exception.Message)" -Level Warning
        }
    }
    return $config
}

#endregion

#region ====================== PLATFORM DETECTION ==============================

function Get-PlatformInfo {
    <# Detects the running OS and returns everything downstream phases need:
       platform key (for the ISO map), edition name (for WIM index matching),
       architecture, and whether this is Server Core. #>
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $build = [int]$os.BuildNumber
    $caption = [string]$os.Caption
    $isServer = ($os.ProductType -ne 1)   # 1=Workstation, 2=DC, 3=Server
    $isCore = -not (Test-Path -LiteralPath (Join-Path $env:windir 'explorer.exe'))

    $isArm64 = ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64' -or
                "$($os.OSArchitecture)" -match 'ARM')

    $key = $null
    $displayName = $caption
    if (-not $isServer) {
        if ($build -ge 22000) {
            if ($isArm64) { $key = 'WIN11_ARM64'; $displayName = 'Windows 11 ARM64' }
            else          { $key = 'WIN11';       $displayName = 'Windows 11' }
        }
        elseif ($build -ge 10240) { $key = 'WIN10'; $displayName = 'Windows 10' }
    }
    else {
        # Ordered so '2012 R2' is not shadowed by a plain '2012' match
        $serverMap = [ordered]@{
            '2012 R2' = 'SVR2012R2'
            '2025'    = 'SVR2025'
            '2022'    = 'SVR2022'
            '2019'    = 'SVR2019'
            '2016'    = 'SVR2016'
        }
        foreach ($pattern in $serverMap.Keys) {
            if ($caption -match [regex]::Escape($pattern)) {
                $key = $serverMap[$pattern]
                $displayName = "Windows Server $pattern"
                break
            }
        }
    }

    # Edition name as it appears inside the WIM, e.g. "Windows 11 Pro" or
    # "Windows Server 2022 Standard"
    $editionName = $caption -replace '^Microsoft\s+', ''

    [pscustomobject]@{
        Caption          = $caption
        DisplayName      = $displayName
        Build            = $build
        IsServer         = $isServer
        IsCore           = $isCore
        IsArm64          = $isArm64
        Key              = $key
        EditionName      = $editionName
        # Original script convention: index 2 for server Desktop Experience,
        # otherwise 1. Used only if dynamic index resolution fails.
        FallbackWimIndex = if ($isServer -and -not $isCore) { 2 } else { 1 }
    }
}

function Resolve-WimIndex {
    <# Given a mounted install.wim/install.esd, find the image index whose
       edition matches the running OS instead of trusting a hardcoded number. #>
    param(
        [Parameter(Mandatory)][string]$ImagePath,
        [Parameter(Mandatory)]$Platform
    )
    try {
        $images = @(Get-WindowsImage -ImagePath $ImagePath -ErrorAction Stop)
    }
    catch {
        Write-Log "Could not enumerate images in $ImagePath ($($_.Exception.Message)); using fallback index $($Platform.FallbackWimIndex)" -Level Warning
        return $Platform.FallbackWimIndex
    }

    if ($images.Count -eq 1) { return [int]$images[0].ImageIndex }

    # 1) Exact edition match, e.g. "Windows 11 Pro"
    $match = $images | Where-Object { $_.ImageName -eq $Platform.EditionName } | Select-Object -First 1
    if ($match) {
        Write-Log "Matched edition '$($match.ImageName)' at index $($match.ImageIndex)"
        return [int]$match.ImageIndex
    }

    # 2) Server: match base edition (Standard/Datacenter) + Core vs Desktop Experience
    if ($Platform.IsServer) {
        $baseEdition = $null
        foreach ($ed in @('Datacenter', 'Standard', 'Essentials')) {
            if ($Platform.EditionName -match $ed) { $baseEdition = $ed; break }
        }
        if ($baseEdition) {
            $candidates = $images | Where-Object { $_.ImageName -match $baseEdition }
            if ($Platform.IsCore) {
                $match = $candidates | Where-Object { $_.ImageName -notmatch 'Desktop Experience' } | Select-Object -First 1
            }
            else {
                $match = $candidates | Where-Object { $_.ImageName -match 'Desktop Experience' } | Select-Object -First 1
            }
            if ($match) {
                Write-Log "Matched server edition '$($match.ImageName)' at index $($match.ImageIndex)"
                return [int]$match.ImageIndex
            }
        }
    }

    # 3) Loose contains-match either direction
    $match = $images | Where-Object {
        $Platform.EditionName -like "*$($_.ImageName)*" -or $_.ImageName -like "*$($Platform.EditionName)*"
    } | Select-Object -First 1
    if ($match) {
        Write-Log "Loosely matched edition '$($match.ImageName)' at index $($match.ImageIndex)"
        return [int]$match.ImageIndex
    }

    Write-Log "No edition in the ISO matched '$($Platform.EditionName)'; using fallback index $($Platform.FallbackWimIndex)" -Level Warning
    return $Platform.FallbackWimIndex
}

#endregion

#region ==================== NETWORK SHARE / ISO SYNC ==========================

function Test-ShareAccess {
    param([string]$NetworkPath, [pscredential]$Credential)
    try {
        if ($Credential) {
            $null = New-PSDrive -Name 'FIXWTEST' -PSProvider FileSystem -Root $NetworkPath -Credential $Credential -ErrorAction Stop
            Remove-PSDrive -Name 'FIXWTEST' -Force -ErrorAction SilentlyContinue
        }
        else {
            $null = Get-ChildItem -LiteralPath $NetworkPath -ErrorAction Stop | Select-Object -First 1
        }
        return $true
    }
    catch { return $false }
}

function Get-ShareCredential {
    <# Returns $null when the share is reachable anonymously / with current
       identity, a PSCredential when one is needed, or throws when access
       cannot be established. Credentials are cached DPAPI-encrypted per user. #>
    param([string]$NetworkPath, [string]$CredentialPath)

    if (Test-ShareAccess -NetworkPath $NetworkPath) {
        Write-Log 'Network share accessible with current credentials'
        return $null
    }

    if (Test-Path -LiteralPath $CredentialPath) {
        Write-Log 'Trying stored network credentials...'
        try {
            $stored = Import-Clixml -LiteralPath $CredentialPath
            if (Test-ShareAccess -NetworkPath $NetworkPath -Credential $stored) {
                Write-Log 'Stored credentials accepted' -Level Success
                return $stored
            }
        }
        catch { }
        Write-Log 'Stored credentials rejected, removing them' -Level Warning
        Remove-Item -LiteralPath $CredentialPath -Force -ErrorAction SilentlyContinue
    }

    if ($script:Unattended) {
        throw "Share $NetworkPath requires credentials and none are stored (unattended mode - not prompting)."
    }

    $cred = Get-Credential -Message "Enter credentials for $NetworkPath"
    if (-not $cred) { throw "No credentials provided for $NetworkPath." }
    if (-not (Test-ShareAccess -NetworkPath $NetworkPath -Credential $cred)) {
        throw "Provided credentials were rejected by $NetworkPath."
    }
    $cred | Export-Clixml -LiteralPath $CredentialPath
    Write-Log "Credentials verified and cached (DPAPI-encrypted) at $CredentialPath" -Level Success
    return $cred
}

function Sync-LocalIso {
    <# Ensures an up-to-date copy of the ISO exists locally. Re-copies only
       when the source file's size or timestamp differs, so re-runs are fast
       and a refreshed ISO on the NAS is picked up automatically. #>
    param(
        [Parameter(Mandatory)][string]$SourceFolder,
        [Parameter(Mandatory)][string]$IsoFileName,
        [Parameter(Mandatory)][string]$DestinationFolder,
        [Parameter(Mandatory)][string]$CredentialPath
    )
    $localIso = Join-Path $DestinationFolder $IsoFileName
    $sourceIso = Join-Path $SourceFolder $IsoFileName
    $localExists = Test-Path -LiteralPath $localIso

    # Quick reachability probe so an offline NAS doesn't hang the run
    $sourceReachable = $true
    if ($SourceFolder -match '^\\\\([^\\]+)') {
        $shareHost = $Matches[1]
        $sourceReachable = Test-Connection -ComputerName $shareHost -Count 1 -Quiet -ErrorAction SilentlyContinue
        if (-not $sourceReachable) { Write-Log "ISO source host $shareHost is not responding to ping" -Level Warning }
    }

    if (-not $sourceReachable) {
        if ($localExists) {
            Write-Log 'Using existing local ISO (source unreachable)' -Level Warning
            return $localIso
        }
        throw "ISO source $SourceFolder is unreachable and no local copy exists at $localIso."
    }

    $credential = $null
    if ($SourceFolder -like '\\*') {
        try {
            $shareRoot = ($SourceFolder -split '\\')[0..3] -join '\'   # \\host\share
            $credential = Get-ShareCredential -NetworkPath $shareRoot -CredentialPath $CredentialPath
        }
        catch {
            if ($localExists) {
                Write-Log "Could not authenticate to share ($($_.Exception.Message)); using existing local ISO" -Level Warning
                return $localIso
            }
            throw
        }
    }

    $driveMapped = $false
    try {
        if ($credential) {
            $null = New-PSDrive -Name 'FIXWISO' -PSProvider FileSystem -Root $SourceFolder -Credential $credential -ErrorAction Stop
            $driveMapped = $true
            $sourceIso = 'FIXWISO:\' + $IsoFileName
        }

        if (-not (Test-Path -LiteralPath $sourceIso)) {
            if ($localExists) {
                Write-Log "ISO $IsoFileName not found on source; using existing local copy" -Level Warning
                return $localIso
            }
            throw "ISO $IsoFileName was not found at $SourceFolder."
        }

        $sourceItem = Get-Item -LiteralPath $sourceIso
        $needCopy = $true
        if ($localExists) {
            $localItem = Get-Item -LiteralPath $localIso
            if ($localItem.Length -eq $sourceItem.Length -and $localItem.LastWriteTimeUtc -ge $sourceItem.LastWriteTimeUtc) {
                $needCopy = $false
            }
        }

        if ($needCopy) {
            $sizeGB = '{0:N2}' -f ($sourceItem.Length / 1GB)
            Write-BoxedText -Title 'ISO DOWNLOAD' -Messages @(
                "Copying $IsoFileName ($sizeGB GB) from",
                $SourceFolder,
                "to $DestinationFolder ..."
            ) -ForegroundColor DarkYellow
            Copy-Item -LiteralPath $sourceIso -Destination $localIso -Force
            Write-Log "ISO copied to $localIso" -Level Success
        }
        else {
            Write-Log "Local ISO $localIso is current (size and timestamp match the source)" -Level Success
        }
        return $localIso
    }
    finally {
        if ($driveMapped) { Remove-PSDrive -Name 'FIXWISO' -Force -ErrorAction SilentlyContinue }
    }
}

#endregion

#region ========================= MAINTENANCE PHASES ===========================

function Invoke-HealthCheck {
    param(
        [Parameter(Mandatory)][string]$IsoPath,
        [Parameter(Mandatory)]$Platform
    )
    Write-BoxedText -Title 'WINDOWS HEALTH CHECK' -Messages @(
        'DISM + SFC repairs sourced from the local ISO.',
        'This will take quite a while - please be patient.'
    ) -ForegroundColor White

    if ($WhatIfPreference) {
        Write-Log 'WhatIf: would run DISM ScanHealth/CheckHealth/RestoreHealth and SFC /scannow'
        return
    }

    Write-Log 'DISM: ScanHealth'
    & dism.exe /Online /Cleanup-Image /ScanHealth
    Write-Log 'DISM: CheckHealth'
    & dism.exe /Online /Cleanup-Image /CheckHealth

    Write-Log "Mounting $IsoPath"
    $mounted = $false
    try {
        $null = Mount-DiskImage -ImagePath $IsoPath -PassThru
        $mounted = $true
        $driveLetter = (Get-DiskImage -ImagePath $IsoPath | Get-Volume).DriveLetter
        if (-not $driveLetter) { throw 'ISO mounted but no drive letter was assigned.' }
        $mountRoot = "${driveLetter}:"
        Write-Log "ISO mounted as $mountRoot" -Level Success

        # Modern media may ship install.esd instead of install.wim
        $installImage = $null
        $sourceType = $null
        foreach ($candidate in @(@{File = 'install.wim'; Type = 'WIM' }, @{File = 'install.esd'; Type = 'ESD' })) {
            $p = Join-Path "$mountRoot\sources" $candidate.File
            if (Test-Path -LiteralPath $p) { $installImage = $p; $sourceType = $candidate.Type; break }
        }
        if (-not $installImage) { throw "Neither install.wim nor install.esd found under $mountRoot\sources." }

        $index = Resolve-WimIndex -ImagePath $installImage -Platform $Platform
        Write-Log "DISM: RestoreHealth from ${sourceType}:${installImage}:$index"
        & dism.exe /Online /Cleanup-Image /RestoreHealth /Source:"${sourceType}:${installImage}:$index" /LimitAccess
        if ($LASTEXITCODE -ne 0) { Write-Log "DISM RestoreHealth exit code: $LASTEXITCODE" -Level Warning }
    }
    finally {
        if ($mounted) {
            Write-Log 'Dismounting ISO'
            Dismount-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue | Out-Null
        }
    }

    Write-Log 'Running System File Checker (sfc /scannow)'
    & "$env:windir\System32\sfc.exe" /scannow
}

function Invoke-VolumeRepair {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()
    $volumes = @(Get-Volume | Where-Object {
            $_.DriveLetter -and $_.DriveType -eq 'Fixed' -and "$($_.FileSystemType)" -match 'NTFS|ReFS'
        })
    if ($volumes.Count -eq 0) { Write-Log 'No fixed volumes found to repair' -Level Warning; return }

    $letters = ($volumes | ForEach-Object { $_.DriveLetter }) -join ''
    Write-BoxedText -Title 'VOLUME REPAIR' -Messages @("Repairing volume(s): $letters") -ForegroundColor White

    foreach ($volume in $volumes) {
        if (-not $PSCmdlet.ShouldProcess("Volume $($volume.DriveLetter):", 'Repair-Volume -OfflineScanAndFix')) { continue }
        try {
            Write-Log "Repair-Volume $($volume.DriveLetter): (offline scan and fix - system volume repairs run at next boot)"
            Repair-Volume -DriveLetter $volume.DriveLetter -OfflineScanAndFix -ErrorAction Stop
        }
        catch {
            Write-Log "Repair-Volume $($volume.DriveLetter): failed: $($_.Exception.Message)" -Level Warning
        }
    }
}

function Backup-AndClearEventLogs {
    param([Parameter(Mandatory)][string]$BackupRoot)
    $backupFolder = Join-Path $BackupRoot (Get-Date -Format 'MMMM-dd')
    $logNames = @(Get-WinEvent -ListLog * -ErrorAction SilentlyContinue |
        Where-Object { $_.RecordCount -gt 0 } | ForEach-Object { $_.LogName })
    Write-Log "Archiving $($logNames.Count) event logs to $backupFolder"

    if ($WhatIfPreference) { Write-Log 'WhatIf: would export and clear all event logs'; return }

    if (-not (Test-Path -LiteralPath $backupFolder)) {
        New-Item -Path $backupFolder -ItemType Directory -Force | Out-Null
    }
    $failed = 0
    foreach ($log in $logNames) {
        $exportPath = Join-Path $backupFolder (($log -replace '[/\\]', '_') + '.evtx')
        & wevtutil.exe epl "$log" "$exportPath" /ow:true 2>$null
        if ($LASTEXITCODE -eq 0) {
            & wevtutil.exe cl "$log" 2>$null
            if ($LASTEXITCODE -ne 0) { $failed++ }
        }
        else { $failed++ }
    }
    if ($failed -gt 0) { Write-Log "$failed log(s) could not be exported/cleared (typically in-use debug channels)" -Level Warning }
    Write-Log "Event logs archived to $backupFolder" -Level Success
}

function Remove-OldItems {
    <# Deletes the contents matched by a (wildcard) path, optionally keeping
       anything newer than the age threshold. #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$AgeDays = 0,
        [string]$Name = ''
    )
    if (-not $Name) { $Name = $Path }
    if (-not (Test-Path -Path $Path -ErrorAction SilentlyContinue)) {
        Write-Log "SKIP  $Name (path not present)"
        return
    }
    Write-Log "CLEAN $Name"
    $items = @(Get-ChildItem -Path $Path -Recurse -Force -ErrorAction SilentlyContinue)
    if ($AgeDays -gt 0) {
        $cutoff = (Get-Date).AddDays(-$AgeDays)
        $items = @($items | Where-Object { $_.CreationTime -lt $cutoff -and $_.LastWriteTime -lt $cutoff })
    }
    # Delete leaf-first so directories are empty by the time they are removed
    $items |
        Sort-Object { $_.FullName.Length } -Descending |
        Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
}

function Invoke-FileCleanup {
    param([Parameter(Mandatory)][hashtable]$Config)

    # -- Windows Update cache (service must be stopped while its folder is purged)
    Write-Log 'Stopping Windows Update services (wuauserv, bits)'
    if (-not $WhatIfPreference) {
        Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
        Stop-Service -Name bits -Force -ErrorAction SilentlyContinue
    }
    try {
        Remove-OldItems -Path "$env:windir\SoftwareDistribution\*" -AgeDays 0 -Name 'Windows Update cache (SoftwareDistribution)'
    }
    finally {
        if (-not $WhatIfPreference) {
            Start-Service -Name bits -ErrorAction SilentlyContinue
            Start-Service -Name wuauserv -ErrorAction SilentlyContinue
        }
    }

    # -- Table-driven path cleanup
    foreach ($entry in $Config.CleanupPaths) {
        $age = [int]$entry.AgeDays
        if ($age -lt 0) { $age = [int]$Config.DaysToDelete }
        Remove-OldItems -Path $entry.Path -AgeDays $age -Name $entry.Name
    }

    # -- IIS logs (only when IIS is present)
    if (Test-Path -LiteralPath 'C:\inetpub\logs\LogFiles') {
        Remove-OldItems -Path 'C:\inetpub\logs\LogFiles\*' -AgeDays ([int]$Config.IisLogAgeDays) -Name "IIS logs older than $($Config.IisLogAgeDays) days"
    }

    # -- Vendor/stray folders removed outright
    foreach ($folder in $Config.FoldersToRemove) {
        if (Test-Path -LiteralPath $folder) {
            Write-Log "CLEAN Removing folder $folder"
            Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue
        }
        else { Write-Log "SKIP  $folder (not present)" }
    }
    foreach ($file in $Config.FilesToRemove) {
        if (Test-Path -LiteralPath $file) {
            Write-Log "CLEAN Removing file $file"
            Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
        }
    }

    # -- Recycle bin (Clear-RecycleBin handles all fixed drives)
    Write-Log 'CLEAN Emptying recycle bin'
    if (-not $WhatIfPreference) {
        try { Clear-RecycleBin -Force -ErrorAction Stop }
        catch { Write-Log "Clear-RecycleBin: $($_.Exception.Message)" -Level Warning }
    }

    # -- Shadow copies (opt-in: also destroys System Restore points)
    if ($Config.DeleteShadowCopies) {
        Write-Log 'CLEAN Deleting all shadow copies (vssadmin) - this removes restore points' -Level Warning
        if (-not $WhatIfPreference) { & vssadmin.exe Delete Shadows /All /Quiet | Out-Null }
    }
    else {
        Write-Log 'SKIP  Shadow copy deletion (DeleteShadowCopies is false in config)'
    }
}

function Invoke-ProfileCleanup {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory)][int]$AgeDays)
    Write-Log "Looking for user profiles unused for more than $AgeDays days..."
    $cutoff = (Get-Date).AddDays(-$AgeDays)
    $stale = @(Get-CimInstance -ClassName Win32_UserProfile -ErrorAction Stop | Where-Object {
            (-not $_.Special) -and
            (-not $_.Loaded) -and
            ($_.SID -notmatch '-500$') -and
            ($_.LastUseTime) -and
            ($_.LastUseTime -lt $cutoff)
        })
    if ($stale.Count -eq 0) { Write-Log 'No stale profiles found' -Level Success; return }

    foreach ($profileEntry in $stale) {
        if (-not $PSCmdlet.ShouldProcess($profileEntry.LocalPath, 'Remove user profile')) { continue }
        Write-Log "Removing profile: $($profileEntry.LocalPath) (last used $($profileEntry.LastUseTime))" -Level Warning
        try {
            $profileEntry | Remove-CimInstance -ErrorAction Stop
            Write-Log "Removed $($profileEntry.LocalPath)" -Level Success
        }
        catch {
            Write-Log "Failed to remove $($profileEntry.LocalPath): $($_.Exception.Message)" -Level Warning
        }
    }
}

function Invoke-WindowsUpdatePhase {
    if ($WhatIfPreference) { Write-Log 'WhatIf: would search for and install Windows Updates'; return }

    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    # Preferred path: PSWindowsUpdate module (richer output, handles reboot flags)
    $psWindowsUpdateReady = $false
    try {
        if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
            Write-Log 'Installing PSWindowsUpdate module from PSGallery...'
            if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
                Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Confirm:$false | Out-Null
            }
            Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
            Install-Module -Name PSWindowsUpdate -Force -Confirm:$false -Scope AllUsers -ErrorAction Stop
        }
        Import-Module PSWindowsUpdate -Force -ErrorAction Stop
        $psWindowsUpdateReady = $true
    }
    catch {
        Write-Log "PSWindowsUpdate unavailable ($($_.Exception.Message)); falling back to Windows Update COM API" -Level Warning
    }

    if ($psWindowsUpdateReady) {
        try {
            Get-WindowsUpdate -ErrorAction Stop | Out-Host
            # -IgnoreReboot: this script controls the reboot itself at the end
            Install-WindowsUpdate -AcceptAll -IgnoreReboot -Confirm:$false -ErrorAction Stop | Out-Host
            return
        }
        catch {
            Write-Log "PSWindowsUpdate failed ($($_.Exception.Message)); falling back to COM API" -Level Warning
        }
    }

    # Fallback: built-in Windows Update Agent COM API (works on every supported OS)
    $session = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()
    Write-Log 'Searching for available updates (COM)...'
    $result = $searcher.Search("IsInstalled=0 and IsHidden=0 and Type='Software'")
    if ($result.Updates.Count -eq 0) { Write-Log 'No updates available' -Level Success; return }

    Write-Log "Found $($result.Updates.Count) update(s):"
    $toInstall = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($update in $result.Updates) {
        Write-Host "  - $($update.Title)" -ForegroundColor Cyan
        if (-not $update.EulaAccepted) { $update.AcceptEula() | Out-Null }
        $null = $toInstall.Add($update)
    }

    Write-Log 'Downloading updates...'
    $downloader = $session.CreateUpdateDownloader()
    $downloader.Updates = $toInstall
    $null = $downloader.Download()

    Write-Log 'Installing updates...'
    $installer = $session.CreateUpdateInstaller()
    $installer.Updates = $toInstall
    $installResult = $installer.Install()
    if ($installResult.ResultCode -eq 2) {
        Write-Log 'Updates installed successfully' -Level Success
        if ($installResult.RebootRequired) { Write-Log 'A reboot is required to complete installation' -Level Warning }
    }
    else {
        Write-Log "Update installation finished with result code $($installResult.ResultCode)" -Level Warning
    }
}

function Invoke-CleanMgr {
    $cleanMgrExe = Join-Path $env:windir 'System32\cleanmgr.exe'
    if (-not (Test-Path -LiteralPath $cleanMgrExe)) {
        Write-Log 'cleanmgr.exe not present (Server Core / feature removed) - skipping' -Level Warning
        return
    }
    if ($WhatIfPreference) { Write-Log 'WhatIf: would configure and run CleanMgr /sagerun:1'; return }

    # Enable every available cleanup handler for sageset profile 1, EXCEPT the
    # Downloads folder handler - that one deletes the user's Downloads content.
    $volumeCachesKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'
    $handlers = @(Get-ChildItem -Path $volumeCachesKey -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -ne 'DownloadsFolder' })
    foreach ($handler in $handlers) {
        Set-ItemProperty -Path $handler.PSPath -Name 'StateFlags0001' -Value 2 -Type DWord -ErrorAction SilentlyContinue
    }
    Write-Log "CleanMgr configured with $($handlers.Count) cleanup handlers (Downloads folder excluded)"

    Write-Log 'Running CleanMgr (this can take a while)...'
    $process = Start-Process -FilePath $cleanMgrExe -ArgumentList '/sagerun:1' -Wait -PassThru
    Write-Log "CleanMgr finished with exit code $($process.ExitCode)" -Level Success
}

function New-MaintenanceRestorePoint {
    try {
        # Checkpoint-Computer exists on client SKUs only
        if (-not (Get-Command Checkpoint-Computer -ErrorAction SilentlyContinue)) {
            Write-Log 'System Restore not available on this SKU (server) - skipping restore point'
            return
        }
        if ($WhatIfPreference) { Write-Log 'WhatIf: would create a system restore point'; return }
        # Lift the default 24h restore-point throttle for this run
        $srKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
        Set-ItemProperty -Path $srKey -Name 'SystemRestorePointCreationFrequency' -Value 0 -Type DWord -ErrorAction SilentlyContinue
        Checkpoint-Computer -Description 'Before FixWindows maintenance' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Write-Log 'System restore point created' -Level Success
    }
    catch {
        Write-Log "Could not create restore point: $($_.Exception.Message)" -Level Warning
    }
}

function Get-DiskUsageReport {
    Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' |
        Select-Object @{Name = 'Drive'; Expression = { $_.DeviceID } },
        @{Name = 'Size (GB)'; Expression = { '{0:N1}' -f ($_.Size / 1GB) } },
        @{Name = 'Free (GB)'; Expression = { '{0:N1}' -f ($_.FreeSpace / 1GB) } },
        @{Name = 'Free %'; Expression = { '{0:P1}' -f ($_.FreeSpace / $_.Size) } } |
        Format-Table -AutoSize | Out-String
}

#endregion

#region ============================ MAIN =====================================

$script:Unattended = [bool]$Unattended
$StartTime = Get-Date
$PhaseResults = New-Object System.Collections.ArrayList

function Invoke-Phase {
    <# Runs one maintenance phase; a failure is logged and recorded but never
       kills the rest of the run. #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Action,
        [switch]$Skip
    )
    if ($Skip) {
        Write-Log "Phase skipped: $Name" -Level Warning
        $null = $PhaseResults.Add([pscustomobject]@{ Phase = $Name; Status = 'Skipped'; Duration = '-' })
        return
    }
    Write-Host ''
    Write-BoxedText -Title ("PHASE: " + $Name.ToUpper()) -ForegroundColor DarkGreen
    $phaseStart = Get-Date
    try {
        & $Action
        $status = 'OK'
    }
    catch {
        Write-ErrorBox "$Name failed: $($_.Exception.Message)"
        $status = 'FAILED'
    }
    $elapsed = (Get-Date) - $phaseStart
    $null = $PhaseResults.Add([pscustomobject]@{
            Phase    = $Name
            Status   = $status
            Duration = ('{0:mm\:ss}' -f $elapsed)
        })
}

# ---- Configuration -----------------------------------------------------------
if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 'FixWindows.config.json' }
$Config = Merge-Configuration -BaseConfig $Defaults -Path $ConfigPath

# Explicit command-line parameters beat the config file
if ($PSBoundParameters.ContainsKey('DaysToDelete')) { $Config.DaysToDelete = $DaysToDelete }
if ($PSBoundParameters.ContainsKey('ProfileAge')) { $Config.ProfileAge = $ProfileAge }
if ($PSBoundParameters.ContainsKey('ISOSourcePath')) { $Config.IsoSourcePath = $ISOSourcePath }

$WorkFolder = [string]$Config.WorkFolder
$LogFile = Join-Path $WorkFolder ('Clean-{0}.log' -f (Get-Date -Format 'MM-d-yy'))
$CredentialPath = Join-Path $env:USERPROFILE 'FixWindows-Credentials.xml'

# Work folder must exist BEFORE the transcript starts
if (-not (Test-Path -LiteralPath $WorkFolder)) {
    New-Item -Path $WorkFolder -ItemType Directory -Force | Out-Null
}
try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch { }
Start-Transcript -Path $LogFile -Append | Out-Null

$exitCode = 0
try {
    Clear-Host

    # ---- Platform detection ---------------------------------------------------
    $Platform = Get-PlatformInfo
    if (-not $Platform.Key) {
        Write-ErrorBox "Unsupported OS: $($Platform.Caption) (build $($Platform.Build))"
        throw "Unable to map this operating system to a known platform key."
    }
    $IsoFileName = [string]$Config.IsoFiles[$Platform.Key]
    if (-not $IsoFileName) {
        throw "No ISO configured for platform key '$($Platform.Key)' - add it to FixWindows.config.json."
    }

    Write-BoxedText -Title 'SYSTEM MAINTENANCE' -Messages @(
        'WINDOWS PowerShell Maintenance and Cleanup Routines',
        '(C) 2022-2026 David Andrews'
    ) -ForegroundColor White

    $archLabel = if ($Platform.IsArm64) { 'ARM64' } else { 'x64' }
    Write-BoxedText -Title 'SYSTEM DETECTION' -Messages @(
        "Detected:     $($Platform.DisplayName) (build $($Platform.Build))",
        "Edition:      $($Platform.EditionName)",
        "Architecture: $archLabel$(if ($Platform.IsCore) { '  (Server Core)' })",
        "Host:         $env:COMPUTERNAME",
        "ISO file:     $IsoFileName",
        "ISO source:   $($Config.IsoSourcePath)",
        "Log file:     $LogFile"
    ) -ForegroundColor Green

    Use-MissionImpossible

    # ---- Abort window (interactive runs only) ---------------------------------
    if (-not $script:Unattended) {
        Write-Host ''
        Write-Host '  Press CTRL-C within 15 seconds to abort...' -BackgroundColor Red -ForegroundColor Yellow
        for ($i = 15; $i -ge 1; $i--) {
            Write-Progress -Activity 'Starting maintenance' -Status "Time remaining: $i seconds (CTRL-C to abort)" -PercentComplete ((15 - $i) / 15 * 100)
            Start-Sleep -Seconds 1
        }
        Write-Progress -Activity 'Starting maintenance' -Completed
    }

    # ---- Phases ----------------------------------------------------------------
    if ($Config.CreateRestorePoint) {
        Invoke-Phase -Name 'Restore point' -Action { New-MaintenanceRestorePoint }
    }

    $BeforeUsage = Get-DiskUsageReport

    Invoke-Phase -Name 'System health check (DISM + SFC)' -Skip:$SkipHealthCheck -Action {
        $localIso = Sync-LocalIso -SourceFolder $Config.IsoSourcePath -IsoFileName $IsoFileName `
            -DestinationFolder $WorkFolder -CredentialPath $CredentialPath
        Invoke-HealthCheck -IsoPath $localIso -Platform $Platform
    }

    Invoke-Phase -Name 'Volume repair' -Skip:$SkipHealthCheck -Action { Invoke-VolumeRepair }

    Invoke-Phase -Name 'Event log archive and clear' -Action {
        Backup-AndClearEventLogs -BackupRoot ([string]$Config.EventLogBackupRoot)
    }

    Invoke-Phase -Name 'File cleanup' -Action { Invoke-FileCleanup -Config $Config }

    Invoke-Phase -Name "User profile cleanup (>$($Config.ProfileAge) days)" -Action {
        Invoke-ProfileCleanup -AgeDays ([int]$Config.ProfileAge)
    }

    Invoke-Phase -Name 'Windows Update' -Skip:$SkipWindowsUpdate -Action { Invoke-WindowsUpdatePhase }

    Invoke-Phase -Name 'Disk Cleanup (CleanMgr)' -Action { Invoke-CleanMgr }

    # ---- Summary ---------------------------------------------------------------
    $AfterUsage = Get-DiskUsageReport
    $EndTime = Get-Date
    $totalElapsed = $EndTime - $StartTime

    Write-Host ''
    Write-BoxedText -Title 'JOB SUMMARY' -Messages @("Machine: $env:COMPUTERNAME") -ForegroundColor White
    $PhaseResults | Format-Table -AutoSize | Out-String | Write-Host

    Write-BoxedText -Title 'DISK USAGE BEFORE' -ForegroundColor DarkYellow
    Write-Host $BeforeUsage -ForegroundColor DarkYellow
    Write-BoxedText -Title 'DISK USAGE AFTER' -ForegroundColor White
    Write-Host $AfterUsage -ForegroundColor Green

    Write-Log ('Total execution time: {0} minutes {1} seconds' -f [int]$totalElapsed.TotalMinutes, $totalElapsed.Seconds) -Level Success

    if (@($PhaseResults | Where-Object { $_.Status -eq 'FAILED' }).Count -gt 0) {
        $exitCode = 2
        Write-WarningBox 'One or more phases failed - review the log above.'
    }
    else {
        Write-SuccessBox 'ALL MAINTENANCE PHASES COMPLETED SUCCESSFULLY!'
        Use-Mario
    }
}
catch {
    Write-ErrorBox "Fatal error: $($_.Exception.Message)"
    Write-Log $_.ScriptStackTrace -Level Error
    $exitCode = 1
}
finally {
    try { Stop-Transcript | Out-Null } catch { }
}

# ---- Restart -------------------------------------------------------------------
if ($exitCode -ne 1 -and -not $NoRestart -and -not $WhatIfPreference) {
    Write-BoxedText -Title 'SYSTEM REBOOT' -Messages @(
        'REBOOTING SYSTEM NOW!',
        'Boot-time volume repair will run during startup.',
        'The first boot may take a while - DO NOT RESET!'
    ) -ForegroundColor Red
    if (-not $script:Unattended) {
        for ($i = 1; $i -le 5; $i++) { Invoke-Beep -Frequency 1000 -Duration 400; Start-Sleep -Seconds 1 }
    }
    Restart-Computer -Force
}
elseif ($NoRestart) {
    Write-Log 'Restart suppressed (-NoRestart). Reboot manually to complete boot-time volume repair.' -Level Warning
}

exit $exitCode

#endregion
