#Requires -Version 5.1
<#
.SYNOPSIS
    Validates Veeam backup chains in specified datastores using Veeam Backup Validator.

.DESCRIPTION
    This script enumerates Veeam backup datastores, discovers all backup jobs and their associated
    backup files, then validates each backup chain using the Veeam Backup Validator executable.
    Generates comprehensive HTML, CSV, and JSON reports with validation results.

.PARAMETER DatastorePath
    Path to the Veeam backup datastore to scan. Can be local path or UNC path.

.PARAMETER ValidatorPath
    Path to Veeam.Backup.Validator.exe. Defaults to standard Veeam installation path.

.PARAMETER ReportPath
    Directory where HTML/XML validation reports will be saved.

.PARAMETER Credential
    PSCredential object for accessing UNC paths.

.PARAMETER IncludeAllVMs
    If specified, validates all VMs in each backup. Otherwise validates backup integrity only.

.PARAMETER ExportCsv
    If specified, exports results to CSV.

.PARAMETER ExportJson
    If specified, exports results to JSON.

.PARAMETER SendTeamsNotification
    If specified, sends a summary to a Microsoft Teams Webhook.

.PARAMETER TeamsWebhookUrl
    The URL of the Microsoft Teams Incoming Webhook.

.PARAMETER SkipElevationCheck
    If specified, suppresses the automatic UAC re-launch when the session is not elevated.
    Useful for scheduled tasks that already run as SYSTEM, CI pipelines, or test harnesses.

.PARAMETER NoOpenReport
    If specified, the generated HTML summary report is NOT automatically opened in the
    default browser. The default behaviour is to open it in a maximised browser window;
    pass this switch for unattended/scheduled runs.

.EXAMPLE
    .\Validate.PS1 -DatastorePath "D:\VeeamBackups" -ReportPath "C:\Reports"

.NOTES
    Author: PowerShell Validator Script (Refactored)
    Version: 2.1
    Requires: Veeam Backup & Replication with Validator component installed
    Elevation: The script automatically re-launches itself with administrator privileges
               via UAC if the current session is not elevated. Pass -SkipElevationCheck
               to suppress this behaviour.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$DatastorePath,
    
    [Parameter(Mandatory=$false)]
    [string]$ValidatorPath = "C:\Program Files\Veeam\Backup and Replication\Backup\Veeam.Backup.Validator.exe",
    
    [Parameter(Mandatory=$false)]
    [string]$ReportPath = "$env:USERPROFILE\Downloads\VeeamValidation",
    
    [Parameter(Mandatory=$false)]
    [System.Management.Automation.PSCredential]$Credential,
    
    [Parameter(Mandatory=$false)]
    [switch]$IncludeAllVMs,
    
    [switch]$Silent,
    
    [switch]$ExportCsv,
    
    [switch]$ExportJson,
    
    [switch]$SendTeamsNotification,

    [string]$TeamsWebhookUrl,

    [switch]$SkipElevationCheck,

    [switch]$NoOpenReport
)

# Strict Mode for better error checking
Set-StrictMode -Version Latest
Set-PSDebug -Trace 0

# Global Configuration Object
$Script:Config = @{
    ValidatorPath = $ValidatorPath
    ReportPath = $ReportPath
    DatastorePath = $DatastorePath
    IncludeAllVMs = $IncludeAllVMs
    Silent = $Silent
    Credential = $Credential
    ExportCsv = $ExportCsv
    ExportJson = $ExportJson
    SendTeamsNotification = $SendTeamsNotification
    TeamsWebhookUrl = $TeamsWebhookUrl
    NoOpenReport = $NoOpenReport
}

$Script:ValidationResults = @()
$Script:LogFile    = $null  # Set by Initialize-Environment after report directory is confirmed to exist
$Script:SummaryReport = $null  # Set by Initialize-Environment after report directory is confirmed to exist

#region Self-Elevation

# If the session is not running as Administrator, re-launch with elevated privileges via UAC.
# The same PowerShell host that invoked this script is used so pwsh / powershell compatibility
# is preserved automatically.
#
# Limitations:
#   - PSCredential (-Credential) cannot be serialised across a process boundary and will be
#     omitted; the elevated session will prompt for credentials again if required.
#   - Pass -SkipElevationCheck to suppress this behaviour (scheduled tasks, CI, test harnesses).
if (-not $SkipElevationCheck) {
    $currentPrincipal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {

        Write-Host 'Session is not elevated — relaunching as Administrator...' -ForegroundColor Yellow

        # Rebuild the caller's arguments so the elevated instance receives identical inputs.
        $argParts = [System.Collections.Generic.List[string]]::new()
        $argParts.AddRange([string[]]@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`""))

        foreach ($key in $PSBoundParameters.Keys) {
            $val = $PSBoundParameters[$key]
            if ($val -is [System.Management.Automation.PSCredential]) {
                Write-Warning "-Credential cannot be forwarded to the elevated session and will be omitted."
            }
            elseif ($val -is [switch]) {
                if ($val.IsPresent) { $argParts.Add("-$key") }
            }
            else {
                $argParts.Add("-$key")
                $argParts.Add("`"$val`"")
            }
        }

        # Use the exact executable that is running this script (handles both pwsh.exe and powershell.exe)
        $psExe   = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $elevated = Start-Process -FilePath $psExe -ArgumentList ($argParts -join ' ') `
                                  -Verb RunAs -Wait -PassThru
        exit $elevated.ExitCode
    }
}

#endregion

#region Helper Functions

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Warning', 'Error', 'Success')]
        [string]$Level = 'Info'
    )
    
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logEntry = "$timestamp [$Level] $Message"
    
    if (-not $Script:Config.Silent) {
        switch ($Level) {
            'Error'   { Write-Host $logEntry -ForegroundColor Red }
            'Warning' { Write-Host $logEntry -ForegroundColor Yellow }
            'Success' { Write-Host $logEntry -ForegroundColor Green }
            default   { Write-Host $logEntry -ForegroundColor White }
        }
    }
    
    if ($Script:LogFile) {
        Add-Content -Path $Script:LogFile -Value $logEntry -ErrorAction SilentlyContinue
    }
}

function Test-ValidatorExecutable {
    # 1. Check provided path
    if (Test-Path $Script:Config.ValidatorPath) { return $true }

    # 2. Check Registry for installation path
    $regPath = "HKLM:\SOFTWARE\Veeam\Veeam Backup and Replication"
    try {
        $installDir = (Get-ItemProperty -Path $regPath -ErrorAction Stop).InstallDir
        $fallbackPath = Join-Path $installDir "Veeam.Backup.Validator.exe"
        if (Test-Path $fallbackPath) {
            Write-Log "Found Veeam Validator via Registry: $fallbackPath" -Level Success
            $Script:Config.ValidatorPath = $fallbackPath
            return $true
        }
    } catch {
        Write-Log "Could not locate Veeam Registry key." -Level Warning
    }

    Write-Log "Veeam Backup Validator not found at: $($Script:Config.ValidatorPath)" -Level Error
    return $false
}

function Initialize-Environment {
    $dirCreated = $false
    try {
        if (-not (Test-Path $Script:Config.ReportPath)) {
            New-Item -Path $Script:Config.ReportPath -ItemType Directory -Force -ErrorAction Stop | Out-Null
            $dirCreated = $true
        }
    } catch {
        throw "Failed to create report directory '$($Script:Config.ReportPath)': $($_.Exception.Message)"
    }

    # Set log/report file paths only after the directory is guaranteed to exist
    $Script:LogFile = Join-Path $Script:Config.ReportPath "VeeamValidation_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
    $Script:SummaryReport = Join-Path $Script:Config.ReportPath "ValidationSummary_$(Get-Date -Format 'yyyyMMdd_HHmmss').html"

    if ($dirCreated) { Write-Log "Created report directory: $($Script:Config.ReportPath)" -Level Info }
    Write-Log "=== Veeam Backup Chain Validation Started ===" -Level Info
}

#endregion

#region Backup Discovery Functions

function Find-VeeamBackupJobs {
    param(
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path $Path -PathType Container)) {
        Write-Log "Invalid or inaccessible path for backup discovery: '$Path'" -Level Error
        return @{}
    }

    Write-Log "Scanning for Veeam backup jobs in: $Path" -Level Info
    
    $backupJobs = @{}
    $knownJobPaths = @()
    
    # 1. Scan for VBM files (Metadata) - Single Pass with -File
    # @() ensures an empty array rather than $null when no files match — required for .Count under Set-StrictMode
    $vbmFiles = @(Get-ChildItem -Path $Path -Recurse -File -Filter "*.vbm" -ErrorAction SilentlyContinue)
    
    foreach ($vbm in $vbmFiles) {
        $jobPath = $vbm.DirectoryName

        # Extract Job Name from Directory or VBM Filename
        $jobName = [System.IO.Path]::GetFileNameWithoutExtension($vbm.Name)

        # Find associated backup files in the same directory.
        # VRB (reverse incrementals) are treated as incrementals for chain/size purposes.
        $vbkFiles = @(Get-ChildItem -Path $jobPath -File -Filter "*.vbk" -ErrorAction SilentlyContinue)
        $vibFiles = @(Get-ChildItem -Path $jobPath -File -Filter "*.vib" -ErrorAction SilentlyContinue)
        $vrbFiles = @(Get-ChildItem -Path $jobPath -File -Filter "*.vrb" -ErrorAction SilentlyContinue)

        # Skip folders that contain a VBM but no actual backup payload — nothing to report on,
        # no restore points to display. Also skip them from the known-paths list so the orphan
        # scan can still pick up any VBK that may appear later.
        if (($vbkFiles.Count + $vibFiles.Count + $vrbFiles.Count) -eq 0) {
            Write-Log "Skipping folder with VBM but no backup files: $jobPath" -Level Info
            continue
        }

        $knownJobPaths += $jobPath

        # Combined incrementals list: VIB + VRB
        $incrementals = @()
        $incrementals += $vibFiles
        $incrementals += $vrbFiles

        # Accumulate size with foreach: Measure-Object returns $null (not a MeasureInfo) for
        # empty collections under PS 5.1 Set-StrictMode, so .Sum would throw
        $jobTotalBytes = [long]0
        foreach ($f in $vbkFiles)     { $jobTotalBytes += $f.Length }
        foreach ($f in $incrementals) { $jobTotalBytes += $f.Length }

        $backupJobs[$jobName] = @{
            Name               = $jobName
            Path               = $jobPath
            VBMFile            = $vbm.FullName
            FullBackups        = $vbkFiles
            IncrementalBackups = $incrementals
            TotalFiles         = $vbkFiles.Count + $incrementals.Count
            TotalSize          = $jobTotalBytes
        }
    }
    
    # 2. Scan for Orphaned Files (VBK/VIB without VBM)
    # We scan for VBK files to establish the job identity, then check for VIBs
    $allVbkFiles = @(Get-ChildItem -Path $Path -Recurse -File -Filter "*.vbk" -ErrorAction SilentlyContinue)
    
    foreach ($vbk in $allVbkFiles) {
        $jobPath = $vbk.DirectoryName
        
        # If this path was already processed as a valid job, skip
        if ($knownJobPaths -contains $jobPath) { continue }
        
        # Extract Job Name (Heuristic: Directory Name or Filename prefix)
        $jobName = if ($vbk.Name -match '^(.+?)(?:D\d{4}-\d{2}-\d{2}T|\d{4}-\d{2}-\d{2}T|\.vbk)') {
            $matches[1]
        } else {
            [System.IO.Path]::GetFileNameWithoutExtension($vbk.Name)
        }
        
        # Avoid duplicates in orphan list
        if (-not $backupJobs.ContainsKey("$jobName-Orphaned")) {
            Write-Log "Found orphaned backup files for job: $jobName" -Level Warning
            
            $vibFiles = @(Get-ChildItem -Path $jobPath -File -Filter "$jobName*.vib" -ErrorAction SilentlyContinue)
            
            $backupJobs["$jobName-Orphaned"] = @{
                Name = "$jobName-Orphaned"
                Path = $jobPath
                VBMFile = $null
                FullBackups = @($vbk) # The current file
                IncrementalBackups = $vibFiles
                IsOrphaned = $true
            }
        }
    }
    
    Write-Log "Total backup jobs found: $($backupJobs.Count)" -Level Info
    return $backupJobs
}

function Get-BackupChainInfo {
    param(
        [hashtable]$Job
    )
    
    $chainInfo = @{
        JobName = $Job.Name
        ChainType = "Unknown"
        ChainLength = 0
        OldestBackup = $null
        NewestBackup = $null
        TotalSize = 0
        Files = @()
    }
    
    $allFiles = @()
    if ($Job.FullBackups) { $allFiles += $Job.FullBackups }
    if ($Job.IncrementalBackups) { $allFiles += $Job.IncrementalBackups }
    
    if ($allFiles.Count -gt 0) {
        $sortedFiles = @($allFiles | Sort-Object CreationTime)
        
        $chainInfo.ChainLength = $allFiles.Count
        $chainInfo.OldestBackup = $sortedFiles[0].CreationTime
        $chainInfo.NewestBackup = $sortedFiles[-1].CreationTime
        # foreach accumulator: Measure-Object returns $null (not a MeasureInfo) for empty input under PS5.1 StrictMode
        $chainTotalBytes = [long]0
        foreach ($f in $allFiles) { $chainTotalBytes += $f.Length }
        $chainInfo.TotalSize = $chainTotalBytes
        $chainInfo.Files = $sortedFiles | ForEach-Object {
            @{
                Name = $_.Name
                Path = $_.FullName
                Size = $_.Length
                Created = $_.CreationTime
                Type = if ($_.Extension -eq '.vbk') { 'Full' } else { 'Incremental' }
            }
        }
        
        if ($Job.VBMFile) { $chainInfo.ChainType = "Standard" }
        elseif ($Job.IsOrphaned) { $chainInfo.ChainType = "Orphaned" }
        else { $chainInfo.ChainType = "Standalone" }
    }
    
    return $chainInfo
}

#endregion

#region Validation Functions

function Get-VbmFileManifest {
    <#
    .SYNOPSIS
        Returns the set of .vbk/.vib filenames referenced by a Veeam VBM metadata file.

    .DESCRIPTION
        VBM files are XML but the precise schema varies across Veeam versions (v9–v12).
        Rather than binding to a specific element path, we read the raw content and
        extract every token that ends in .vbk or .vib. This gives a reliable, version-
        independent list of files the metadata believes should exist on disk.
    #>
    param([string]$VbmPath)

    $names = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if (-not $VbmPath -or -not (Test-Path $VbmPath)) { return $names }

    try {
        $content = Get-Content -Path $VbmPath -Raw -ErrorAction Stop
    } catch {
        Write-Log "Could not read VBM file '$VbmPath': $($_.Exception.Message)" -Level Warning
        return $names
    }

    # Get-Content -Raw returns $null for an empty file; [regex]::Matches throws on null input
    if ([string]::IsNullOrEmpty($content)) { return $names }

    # Use a strict allow-list of filename characters so we don't greedily capture surrounding
    # XML markup (e.g. 'IsFilePath="True"><Elements>filename.vbk'). Veeam file names consist
    # of letters, digits, dots, hyphens, underscores, and the 'T' date/time separator — all
    # covered by [A-Za-z0-9._-]. The earlier broader class inadvertently allowed '&', '=', ';',
    # which pulled in HTML-entity-encoded junk when the VBM is a serialised/escaped blob.
    $regexMatches = [regex]::Matches($content, '[A-Za-z0-9._\-]+\.(?:vbk|vib|vrb)', 'IgnoreCase')
    foreach ($m in $regexMatches) { [void]$names.Add($m.Value) }
    return $names
}

function Get-VeeamFilenameTimestamp {
    <#
    .SYNOPSIS
        Extracts the embedded restore-point timestamp from a Veeam file name.

    .DESCRIPTION
        Veeam names include an ISO-like timestamp, e.g.
        'DC01.vm-20D2026-04-04T220403_7A19.vbk' → 2026-04-04 22:04:03.
        Returns [datetime] on success, $null otherwise.
    #>
    param([string]$FileName)
    if ([string]::IsNullOrEmpty($FileName)) { return $null }
    if ($FileName -match '(\d{4}-\d{2}-\d{2})T(\d{2})(\d{2})(\d{2})') {
        try {
            return [datetime]::ParseExact(
                "$($matches[1])T$($matches[2]):$($matches[3]):$($matches[4])",
                'yyyy-MM-ddTHH:mm:ss',
                [System.Globalization.CultureInfo]::InvariantCulture)
        } catch { return $null }
    }
    return $null
}

function Test-BackupChainIntegrity {
    <#
    .SYNOPSIS
        Cross-checks the VBM manifest against the files actually present in the job directory.

    .DESCRIPTION
        Catches chain damage that the Veeam validator may silently skip:
          - Files the VBM expects but are missing on disk (broken chain)
          - Files on disk that the VBM does not reference (renamed/stray/orphaned)

        Returns a hashtable with Status (Valid | ChainBroken | NoVbm), a Messages list,
        and the MissingFromDisk / ExtraOnDisk filename arrays.
    #>
    param([hashtable]$Job)

    $result = @{
        Status          = 'Unknown'
        Messages        = @()
        MissingFromDisk = @()
        ExtraOnDisk     = @()
    }

    if (-not $Job.VBMFile -or -not (Test-Path $Job.VBMFile)) {
        $result.Status = 'NoVbm'
        return $result
    }

    $expected = Get-VbmFileManifest -VbmPath $Job.VBMFile

    $actualNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($f in @($Job.FullBackups))        { if ($f)      { [void]$actualNames.Add($f.Name) } }
    foreach ($f in @($Job.IncrementalBackups)) { if ($f)      { [void]$actualNames.Add($f.Name) } }

    foreach ($name in $expected)    { if (-not $actualNames.Contains($name)) { $result.MissingFromDisk += $name } }
    foreach ($name in $actualNames) { if (-not $expected.Contains($name))    { $result.ExtraOnDisk     += $name } }

    if ($result.MissingFromDisk.Count -eq 0 -and $result.ExtraOnDisk.Count -eq 0) {
        $result.Status = 'Valid'
    } else {
        $result.Status = 'ChainBroken'
        if ($result.MissingFromDisk.Count -gt 0) {
            $result.Messages += "Referenced by VBM but missing on disk: $($result.MissingFromDisk -join ', ')"
        }
        if ($result.ExtraOnDisk.Count -gt 0) {
            $result.Messages += "Present on disk but not referenced by VBM (possibly renamed/orphaned): $($result.ExtraOnDisk -join ', ')"
        }
    }
    return $result
}

function Invoke-VeeamValidator {
    param(
        [hashtable]$Job,
        [string]$ReportFormat = "html"
    )
    
    $validationResult = @{
        JobName = $Job.Name
        ValidationStatus = "NotRun"
        StartTime = Get-Date
        EndTime = $null
        Duration = $null
        Files = @()
        Errors = @()
        ReportPath = $null
        Stdout = @()
        Stderr = @()
        ChainIntegrity = $null
    }
    
    Write-Log "Starting validation for job: $($Job.Name)" -Level Info

    # Chain integrity cross-check — runs before the Veeam validator and can fail the job
    # independently, because the validator may silently skip files listed in the VBM that
    # are not present on disk (and never sees files on disk that are not in the VBM).
    $integrity = Test-BackupChainIntegrity -Job $Job
    $validationResult.ChainIntegrity = $integrity
    if ($integrity.Status -eq 'ChainBroken') {
        foreach ($msg in $integrity.Messages) {
            Write-Log "Chain integrity issue for '$($Job.Name)': $msg" -Level Error
            $validationResult.Errors += $msg
        }
    }
    
    $reportFileName = "$($Job.Name)_$(Get-Date -Format 'yyyyMMdd_HHmmss').$ReportFormat"
    $reportFullPath = Join-Path $Script:Config.ReportPath $reportFileName
    
    # Declare before try so the finally block can always reference them, even if try throws early
    $tempStdout = $null
    $tempStderr = $null

    try {
        $tempStdout = [System.IO.Path]::GetTempFileName()
        $tempStderr = [System.IO.Path]::GetTempFileName()

        if ($Job.VBMFile -and (Test-Path $Job.VBMFile)) {
            $arguments = @(
                "/file:`"$($Job.VBMFile)`""
                "/report:`"$reportFullPath`""
                "/format:$ReportFormat"
            )
            if (-not $Script:Config.IncludeAllVMs) { $arguments += "/silence" }
            
            # Execute with redirection
            $process = Start-Process -FilePath $Script:Config.ValidatorPath -ArgumentList $arguments -NoNewWindow -Wait -PassThru `
                       -RedirectStandardOutput $tempStdout -RedirectStandardError $tempStderr
            
            $validationResult.Stdout = Get-Content $tempStdout -ErrorAction SilentlyContinue
            $validationResult.Stderr = Get-Content $tempStderr -ErrorAction SilentlyContinue
            
            if ($process.ExitCode -eq 0 -and $integrity.Status -ne 'ChainBroken') {
                $validationResult.ValidationStatus = "Success"
                Write-Log "Validation completed successfully for: $($Job.Name)" -Level Success
            } elseif ($integrity.Status -eq 'ChainBroken' -and $process.ExitCode -eq 0) {
                # Veeam validator passed but our chain integrity check detected
                # missing or renamed files — this would be silently reported as Success
                # without the cross-check.
                $validationResult.ValidationStatus = "Failed"
                $validationResult.Errors += "Veeam validator exit 0 but chain integrity check failed"
                Write-Log "Validation failed for '$($Job.Name)' (chain integrity mismatch, validator passed)" -Level Error
            } else {
                $validationResult.ValidationStatus = "Failed"
                $validationResult.Errors += "Validator exit code: $($process.ExitCode)"
                if ($validationResult.Stderr) { $validationResult.Errors += "Stderr: $($validationResult.Stderr -join ' ')" }
                Write-Log "Validation failed for: $($Job.Name)" -Level Error
            }
            $validationResult.ReportPath = $reportFullPath
        }
        else {
            # Validate individual files
            Write-Log "No VBM file found, validating individual backup files" -Level Warning
            
            foreach ($backup in $Job.FullBackups) {
                $fileReportPath = Join-Path $Script:Config.ReportPath "$([System.IO.Path]::GetFileNameWithoutExtension($backup.Name))_$(Get-Date -Format 'yyyyMMdd_HHmmss').$ReportFormat"
                
                $arguments = @(
                    "/file:`"$($backup.FullName)`""
                    "/report:`"$fileReportPath`""
                    "/format:$ReportFormat"
                    "/silence"
                )
                
                $process = Start-Process -FilePath $Script:Config.ValidatorPath -ArgumentList $arguments -NoNewWindow -Wait -PassThru `
                           -RedirectStandardOutput $tempStdout -RedirectStandardError $tempStderr
                
                $fileResult = @{
                    FileName = $backup.Name
                    Status = if ($process.ExitCode -eq 0) { "Valid" } else { "Invalid" }
                    ExitCode = $process.ExitCode
                    ReportPath = $fileReportPath
                }
                
                $validationResult.Files += $fileResult
                
                if ($process.ExitCode -ne 0) {
                    $validationResult.Errors += "File $($backup.Name) validation failed"
                }
            }
            
            $failedCount = @($validationResult.Files | Where-Object { $_.Status -eq "Invalid" }).Count
            if ($failedCount -eq 0 -and $validationResult.Files.Count -gt 0) {
                $validationResult.ValidationStatus = "Success"
            } elseif ($failedCount -lt $validationResult.Files.Count) {
                $validationResult.ValidationStatus = "PartialSuccess"
            } else {
                $validationResult.ValidationStatus = "Failed"
            }
            # Point top-level ReportPath to the directory containing the per-file reports
            $validationResult.ReportPath = $Script:Config.ReportPath
        }
    }
    catch {
        $validationResult.ValidationStatus = "Error"
        $validationResult.Errors += $_.Exception.Message
        Write-Log "Exception during validation of '$($Job.Name)': $($_.Exception.Message)" -Level Error
    }
    finally {
        # Guarded against $null in case temp file assignment was never reached
        if ($tempStdout) { Remove-Item $tempStdout -ErrorAction SilentlyContinue }
        if ($tempStderr) { Remove-Item $tempStderr -ErrorAction SilentlyContinue }
    }
    
    $validationResult.EndTime = Get-Date
    $validationResult.Duration = ($validationResult.EndTime - $validationResult.StartTime).TotalSeconds
    
    return $validationResult
}

function Test-AllBackupJobs {
    param(
        [hashtable]$BackupJobs
    )
    
    $allResults = @()
    $jobCount = 0
    $totalJobs = $BackupJobs.Count
    
    foreach ($jobName in $BackupJobs.Keys) {
        $jobCount++
        Write-Progress -Activity "Validating Backups" -Status "Processing: $jobName" -PercentComplete (($jobCount / $totalJobs) * 100)
        
        Write-Log "[$jobCount/$totalJobs] Processing job: $jobName" -Level Info
        
        $job = $BackupJobs[$jobName]
        $chainInfo = Get-BackupChainInfo -Job $job
        $validationResult = Invoke-VeeamValidator -Job $job -ReportFormat "html"
        
        $combinedResult = @{
            JobName = $jobName
            ChainInfo = $chainInfo
            ValidationResult = $validationResult
            Timestamp = Get-Date
        }
        
        $allResults += $combinedResult
        $Script:ValidationResults += $combinedResult
    }
    
    Write-Progress -Activity "Validating Backups" -Completed
    return $allResults
}

#endregion

#region Reporting Functions

function Open-HtmlReport {
    <#
    .SYNOPSIS
        Opens an HTML file in the user's default browser, maximised when possible.

    .DESCRIPTION
        Resolves the default browser executable from the HKCU\Software\Microsoft\Windows\
        Shell\Associations\UrlAssociations\https\UserChoice registry entry, then launches
        it directly. Direct-launching (instead of shell association) lets us pass the
        -WindowStyle Maximized parameter to Start-Process, and for Chromium-based browsers
        (Chrome / Edge / Brave / Opera / Vivaldi) we additionally pass --start-maximized
        which reliably opens a maximised window even when the browser was not running.

        Falls back to Start-Process on the HTML path if the default-browser resolution fails.
    #>
    param([Parameter(Mandatory)] [string]$Path)

    if (-not (Test-Path $Path)) { return }

    $browserExe = $null
    try {
        $assoc = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice' -ErrorAction Stop
        $progId = $assoc.ProgId
        if ($progId) {
            $cmdRaw = (Get-ItemProperty -Path "Registry::HKEY_CLASSES_ROOT\$progId\shell\open\command" -ErrorAction Stop).'(default)'
            # Extract the executable path — typically quoted, e.g.  "C:\Program Files\...\chrome.exe" --single-argument %1
            if ($cmdRaw -match '^"([^"]+)"') { $browserExe = $matches[1] }
            elseif ($cmdRaw -match '^(\S+)') { $browserExe = $matches[1] }
        }
    } catch {
        # Silent — fall through to the Start-Process fallback below
    }

    try {
        if ($browserExe -and (Test-Path $browserExe)) {
            $isChromium = $browserExe -match 'chrome\.exe|msedge\.exe|brave\.exe|opera\.exe|vivaldi\.exe|chromium\.exe'
            $browserArgs = if ($isChromium) { @('--start-maximized', "`"$Path`"") } else { @("`"$Path`"") }
            Start-Process -FilePath $browserExe -ArgumentList $browserArgs -WindowStyle Maximized | Out-Null
            Write-Log "Opened report in default browser (maximised): $Path" -Level Info
        } else {
            # No resolvable browser exe — fall back to the shell association
            Start-Process -FilePath $Path -WindowStyle Maximized | Out-Null
            Write-Log "Opened report via shell association: $Path" -Level Info
        }
    } catch {
        Write-Log "Could not open HTML report '$Path': $($_.Exception.Message)" -Level Warning
    }
}

function Format-FileSize {
    param([Nullable[int64]]$Size)
    if (-not $Size -or $Size -le 0) { return 'N/A' }
    if ($Size -gt 1TB)     { return "{0:N2} TB" -f ($Size / 1TB) }
    elseif ($Size -gt 1GB) { return "{0:N2} GB" -f ($Size / 1GB) }
    elseif ($Size -gt 1MB) { return "{0:N2} MB" -f ($Size / 1MB) }
    elseif ($Size -gt 1KB) { return "{0:N2} KB" -f ($Size / 1KB) }
    else                   { return "$Size Bytes" }
}

function New-ValidationSummaryReport {
    param(
        [array]$Results
    )
    
    Write-Log "Generating HTML summary report" -Level Info
    
    $htmlSafe = {
        param($val)
        if ($null -eq $val) { return '' }
        [string]$val -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;'
    }

    # Display names: strip Veeam's trailing "_<hex>" GUID fragment so reports show "DC01"
    # instead of "DC01_242B8". Conservative pattern: 4+ hex chars at the end after an underscore.
    $getDisplayName = {
        param($raw)
        if ([string]::IsNullOrWhiteSpace($raw)) { return '' }
        if ($raw -match '^(.+?)_[0-9A-Fa-f]{4,}$') { return $matches[1] }
        return $raw
    }

    $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>Veeam Backup Chain Validation Report</title>
    <meta charset="utf-8">
    <style>
        html, body { height: 100%; }
        body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; margin: 0; padding: 10px 0; background: #f4f6f9; }
        /* Container occupies 95% of the viewport width when maximised, with minimal inner padding */
        .container { width: 95vw; max-width: 95vw; margin: 0 auto; background: white; border-radius: 8px; padding: 14px 18px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); box-sizing: border-box; }
        h1 { color: #333; border-bottom: 3px solid #667eea; padding-bottom: 8px; margin: 4px 0 10px 0; font-size: 22px; }
        h2 { margin: 16px 0 8px 0; font-size: 18px; }
        /* Alternate table rows: white + light blue for readability */
        tbody tr:nth-child(even) td { background: #eaf3ff; }
        tbody tr:nth-child(odd)  td { background: #ffffff; }
        tbody tr:hover td           { background: #d9e8fb; }
        .summary-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 20px; margin: 20px 0; }
        .summary-card { background: #f8f9fa; padding: 20px; border-radius: 8px; text-align: center; border-left: 4px solid #667eea; }
        .summary-card.success { border-left-color: #28a745; }
        .summary-card.warning { border-left-color: #ffc107; }
        .summary-card.error { border-left-color: #dc3545; }
        table { width: 100%; border-collapse: collapse; margin: 20px 0; }
        th { background: #667eea; color: white; padding: 12px; text-align: left; }
        td { padding: 10px 12px; border-bottom: 1px solid #dee2e6; }
        .status-badge { display: inline-block; padding: 4px 12px; border-radius: 20px; font-size: 12px; font-weight: bold; }
        .status-success { background: #d4edda; color: #155724; }
        .status-partial { background: #fff3cd; color: #856404; }
        .status-failed { background: #f8d7da; color: #721c24; }
        .status-error { background: #f8d7da; color: #721c24; }
        .integrity-issue {
            background: #fff5f5;
            padding: 10px 14px;
            margin-top: 8px;
            border-left: 3px solid #dc3545;
            border-radius: 0 4px 4px 0;
            font-size: 12px;
        }
        .integrity-issue .integrity-title {
            color: #721c24;
            font-weight: 600;
            margin-bottom: 6px;
            font-size: 13px;
        }
        .integrity-issue .integrity-group { margin: 4px 0 6px 0; }
        .integrity-issue .integrity-label { color: #333; font-weight: 500; }
        .integrity-issue ul {
            margin: 4px 0 4px 0;
            padding-left: 22px;
            font-family: Consolas, 'Courier New', monospace;
            font-size: 11px;
            color: #333;
        }
        .integrity-issue li { margin: 1px 0; }

        /* Orphaned-file panel — softer/informational tone, no error framing */
        .orphaned-files {
            background: #fff8e1;
            padding: 10px 14px;
            margin-top: 8px;
            border-left: 3px solid #f0ad4e;
            border-radius: 0 4px 4px 0;
            font-size: 12px;
        }
        .orphaned-files .orphaned-title {
            color: #8a6d3b;
            font-weight: 600;
            margin-bottom: 6px;
            font-size: 13px;
        }
        .orphaned-files .orphaned-subtext {
            color: #555;
            margin-bottom: 4px;
            font-size: 11px;
        }
        .orphaned-files ul {
            margin: 4px 0 4px 0;
            padding-left: 22px;
            font-family: Consolas, 'Courier New', monospace;
            font-size: 11px;
            color: #333;
        }
        .orphaned-files li { margin: 1px 0; }
        .timestamp { color: #6c757d; font-size: 14px; margin-top: 30px; text-align: center; }

        /* Backup chain visualization */
        .chain-section { margin: 30px 0 10px 0; }
        /* Each job gets a distinct light-purple panel to visually separate jobs from each other */
        .job-chain {
            margin-bottom: 20px;
            background: #f2eefb;
            border: 1px solid #dbd1f0;
            border-radius: 10px;
            padding: 12px 14px;
            box-shadow: 0 1px 3px rgba(120, 90, 180, 0.08);
        }
        .job-chain h3 { color: #4a2e8a; margin: 4px 0 10px 0; font-size: 16px; }
        /* One chain-container per VBK segment — each VBK starts a new row */
        .chain-container {
            display: flex;
            flex-wrap: nowrap;
            align-items: stretch;
            gap: 10px;
            padding: 14px;
            background: #fafbfc;
            border: 1px solid #e1e4e8;
            border-radius: 8px;
            overflow-x: auto;
            margin-bottom: 10px;
        }
        .chain-card {
            min-width: 170px;
            max-width: 210px;
            padding: 12px;
            border-radius: 6px;
            /* Layered subtle shadow for a lifted, soft-card look */
            box-shadow: 0 2px 6px rgba(0,0,0,0.12), 0 1px 2px rgba(0,0,0,0.06);
            transition: box-shadow 0.2s ease, transform 0.2s ease;
            border: 2px solid transparent;
            flex-shrink: 0;
            display: flex;
            flex-direction: column;
            gap: 4px;
            /* Legible sans-serif stack for on-card text */
            font-family: 'Segoe UI', 'Trebuchet MS', Verdana, Arial, sans-serif;
        }
        .chain-card:hover {
            box-shadow: 0 6px 16px rgba(0,0,0,0.18), 0 2px 4px rgba(0,0,0,0.08);
            transform: translateY(-2px);
        }
        .chain-card.full        { background: #d4edda; border-color: #28a745; }  /* green */
        .chain-card.incremental { background: #d1ecf1; border-color: #17a2b8; }  /* blue */
        .chain-card.broken      { background: #f8d7da; border-color: #dc3545; }  /* red */
        .chain-card .card-type {
            font-weight: 700;
            font-size: 11px;
            text-transform: uppercase;
            letter-spacing: 0.5px;
            color: #1a1a1a;
        }
        .chain-card.broken .card-type { color: #721c24; }
        .chain-card .card-name {
            font-size: 15px;
            font-weight: 600;
            color: #111;
        }
        .chain-card .card-date {
            font-size: 12px;
            color: #333;
        }
        .chain-card .card-size {
            font-size: 11px;
            color: #555;
        }
        .chain-card .card-filename {
            font-family: Consolas, 'Courier New', monospace;
            font-size: 10px;
            color: #6c757d;
            word-break: break-all;
            margin-top: 4px;
            border-top: 1px dashed rgba(0,0,0,0.1);
            padding-top: 4px;
        }
        .chain-arrow {
            color: #28a745;
            font-size: 28px;
            font-weight: bold;
            align-self: center;
            user-select: none;
            flex-shrink: 0;
        }
        .chain-legend { display: flex; gap: 16px; margin: 10px 0 0 0; font-size: 12px; color: #555; flex-wrap: wrap; }
        .chain-legend .swatch { display: inline-block; width: 14px; height: 14px; border-radius: 3px; margin-right: 6px; vertical-align: middle; border: 1px solid rgba(0,0,0,0.15); }
        .chain-legend .swatch.full        { background: #d4edda; border-color: #28a745; }
        .chain-legend .swatch.incremental { background: #d1ecf1; border-color: #17a2b8; }
        .chain-legend .swatch.broken      { background: #f8d7da; border-color: #dc3545; }
        .no-chain { color: #6c757d; font-style: italic; padding: 8px; }
        .unreferenced-heading {
            margin: 14px 0 6px 0;
            font-size: 13px;
            font-weight: 600;
            color: #721c24;
        }

        /* Sort bar (Validation Results + Backup Chain Visualization) */
        .sort-bar {
            display: flex; align-items: center; gap: 8px;
            margin: 6px 0 10px 0;
            font-size: 12px;
            flex-wrap: wrap;
        }
        .sort-bar .sort-label { color: #555; font-weight: 600; margin-right: 4px; }
        .sort-bar button {
            padding: 5px 12px;
            border: 1px solid #ccd5e0;
            background: #fff;
            border-radius: 4px;
            font-size: 12px;
            cursor: pointer;
            color: #333;
        }
        .sort-bar button:hover { background: #eef4fc; border-color: #667eea; color: #333; }
        .sort-bar button.active { background: #667eea; color: #fff; border-color: #4a52c9; }

        /* Per-card selection checkbox on actionable (deletable) red cards */
        .chain-card .card-select {
            margin-top: 6px;
            padding-top: 4px;
            border-top: 1px dashed rgba(0,0,0,0.2);
            font-size: 11px;
            color: #555;
            cursor: pointer;
            user-select: none;
            display: flex;
            align-items: center;
            gap: 4px;
        }
        .chain-card .card-select input { margin: 0; }

        /* Action bar at the end of the chain section */
        .action-bar {
            display: flex; justify-content: center; gap: 16px;
            margin: 18px 0 8px 0;
        }
        .action-bar button {
            padding: 10px 22px; border: none; border-radius: 6px;
            font-size: 14px; font-weight: 700; cursor: pointer;
            box-shadow: 0 2px 5px rgba(0,0,0,0.12);
            transition: background 0.15s ease, transform 0.15s ease;
        }
        .action-bar .btn-delete  { background: #dc3545; color: #fff; }
        .action-bar .btn-delete:hover  { background: #a71d2a; transform: translateY(-1px); }
        .action-bar .btn-archive { background: #6c757d; color: #fff; }
        .action-bar .btn-archive:hover { background: #495057; transform: translateY(-1px); }

        /* Modal overlay + dialogs */
        .modal-overlay {
            position: fixed; inset: 0;
            background: rgba(0,0,0,0.65);
            display: flex; align-items: center; justify-content: center;
            z-index: 1000;
        }
        .modal-overlay.hidden { display: none; }
        .modal-box {
            background: #fff; color: #222;
            max-width: 680px; width: 92%; max-height: 86vh; overflow-y: auto;
            padding: 22px 28px; border-radius: 10px;
            box-shadow: 0 10px 50px rgba(0,0,0,0.4);
        }
        .modal-box.red-dialog {
            background: #7f0a0a; color: #fff;
            border: 3px solid #ff2020;
        }
        .modal-box h2 { margin: 0 0 10px 0; font-size: 22px; text-align: center; }
        .modal-box.red-dialog code {
            background: rgba(0,0,0,0.4); padding: 2px 6px; border-radius: 3px; color: #ffd700;
            font-family: Consolas, 'Courier New', monospace;
        }
        /* Blinking yellow warning text */
        @keyframes blink-yellow {
            0%, 49%   { color: #ffd700; text-shadow: 0 0 10px rgba(255,215,0,0.6); }
            50%, 100% { color: #ffffff; text-shadow: none; }
        }
        .blink-yellow { animation: blink-yellow 0.8s steps(1, start) infinite; font-weight: 800; }

        .modal-file-list {
            max-height: 220px; overflow-y: auto;
            font-family: Consolas, 'Courier New', monospace; font-size: 12px;
            background: rgba(0,0,0,0.3); color: #fff;
            border-radius: 4px; padding: 8px 14px;
            margin: 8px 0; list-style-position: inside;
        }
        .modal-box .confirm-input {
            width: 100%; padding: 9px 10px; font-size: 16px;
            font-family: Consolas, monospace; font-weight: 700;
            border: 2px solid #ff2020; border-radius: 4px;
            background: #fff; color: #7f0a0a;
            text-align: center; letter-spacing: 3px; text-transform: uppercase;
            box-sizing: border-box;
        }
        .modal-buttons { display: flex; justify-content: center; gap: 10px; margin-top: 14px; flex-wrap: wrap; }
        .modal-buttons button {
            padding: 8px 20px; border: none; border-radius: 4px;
            font-weight: 700; cursor: pointer; font-size: 13px;
        }
        .btn-confirm-delete { background: #ff2020; color: #fff; }
        .btn-cancel         { background: #6c757d; color: #fff; }
        .btn-copy           { background: #17a2b8; color: #fff; }
        .script-output {
            margin-top: 16px; padding-top: 14px;
            border-top: 1px solid rgba(255,255,255,0.25);
        }
        .script-output pre {
            background: #1e1e1e; color: #d4d4d4;
            padding: 12px; border-radius: 4px;
            font-size: 11px; font-family: Consolas, 'Courier New', monospace;
            white-space: pre-wrap; word-break: break-all;
            max-height: 200px; overflow-y: auto;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>🔍 Veeam Backup Chain Validation Report</h1>
        <p class="timestamp">Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</p>
        
        <div class="summary-grid">
            <div class="summary-card">
                <h3>Total Jobs</h3>
                <div class="value">$($Results.Count)</div>
            </div>
            <div class="summary-card success">
                <h3>Successful</h3>
                <div class="value">$(@($Results | Where-Object { $_.ValidationResult.ValidationStatus -eq 'Success' }).Count)</div>
            </div>
            <div class="summary-card error">
                <h3>Failed</h3>
                <div class="value">$(@($Results | Where-Object { $_.ValidationResult.ValidationStatus -ne 'Success' }).Count)</div>
            </div>
        </div>

        <h2>📊 Validation Results</h2>
        <div class="sort-bar">
            <span class="sort-label">Sort by:</span>
            <button onclick="sortJobs('machine', 'asc')"  title="Machine name A → Z">Machine ▲</button>
            <button onclick="sortJobs('machine', 'desc')" title="Machine name Z → A">Machine ▼</button>
            <button onclick="sortJobs('lastrun', 'asc')"  title="Oldest last-run first">Last Run ▲</button>
            <button onclick="sortJobs('lastrun', 'desc')" title="Most recent last-run first">Last Run ▼</button>
        </div>
        <table id="results-table">
            <thead>
                <tr>
                    <th>Job Name</th>
                    <th>Chain Type</th>
                    <th>Files</th>
                    <th>Total Size</th>
                    <th>Validation Status</th>
                    <th>Duration</th>
                    <th>Report</th>
                </tr>
            </thead>
            <tbody>
"@

    foreach ($result in $Results) {
        $statusClass = switch ($result.ValidationResult.ValidationStatus) {
            'Success' { 'status-success' }
            'PartialSuccess' { 'status-partial' }
            'Failed' { 'status-failed' }
            'Error' { 'status-error' }
            default { 'status-notrun' }
        }
        
        $reportLink = if ($result.ValidationResult.ReportPath -and (Test-Path $result.ValidationResult.ReportPath)) {
            "<a href='file:///$($result.ValidationResult.ReportPath -replace '\\', '/')' target='_blank'>View</a>"
        } else {
            "N/A"
        }

        # Chain integrity details — rendered as up to two distinct panels:
        #   1. Red panel: genuine chain integrity issues (files referenced by VBM but missing on disk)
        #   2. Amber panel: possible orphaned files (on disk but not referenced by VBM).
        # These are presented separately because an extra file on disk is not itself a chain
        # integrity failure — it may be a rename, a manual copy, or a leftover from maintenance.
        $integrityHtml = ''
        $integrity = $result.ValidationResult.ChainIntegrity
        if ($integrity) {
            if ($integrity.MissingFromDisk.Count -gt 0) {
                $integrityHtml += '<div class="integrity-issue">'
                $integrityHtml += '<div class="integrity-title">⚠ Chain integrity issues detected</div>'
                $integrityHtml += '<div class="integrity-group"><span class="integrity-label">Missing from disk (referenced by VBM):</span><ul>'
                foreach ($m in $integrity.MissingFromDisk) {
                    $integrityHtml += "<li>$(& $htmlSafe $m)</li>"
                }
                $integrityHtml += '</ul></div></div>'
            }
            if ($integrity.ExtraOnDisk.Count -gt 0) {
                $integrityHtml += '<div class="orphaned-files">'
                $integrityHtml += '<div class="orphaned-title">Possible Orphaned Files</div>'
                $integrityHtml += '<div class="orphaned-subtext">File(s) present on disk that are not referenced by the VBM — may be renamed, copied, or leftover.</div>'
                $integrityHtml += '<ul>'
                foreach ($e in $integrity.ExtraOnDisk) {
                    $integrityHtml += "<li>$(& $htmlSafe $e)</li>"
                }
                $integrityHtml += '</ul></div>'
            }
        }

        # Compact display name + stable sort keys on the <tr> for the sort controls
        $displayJobName = & $getDisplayName $result.JobName
        $displayJobSafe = & $htmlSafe $displayJobName
        $lastRunIso     = if ($result.ChainInfo.NewestBackup) { $result.ChainInfo.NewestBackup.ToString('o') } else { '' }

        $html += @"
                <tr data-machine="$(& $htmlSafe $displayJobName.ToLower())" data-lastrun="$lastRunIso">
                    <td><strong>$displayJobSafe</strong>$integrityHtml</td>
                    <td>$(& $htmlSafe $result.ChainInfo.ChainType)</td>
                    <td>$($result.ChainInfo.ChainLength)</td>
                    <td>$(Format-FileSize $result.ChainInfo.TotalSize)</td>
                    <td><span class="status-badge $statusClass">$(& $htmlSafe $result.ValidationResult.ValidationStatus)</span></td>
                    <td>$([Math]::Round($result.ValidationResult.Duration, 1))s</td>
                    <td>$reportLink</td>
                </tr>
"@
    }

    $html += @"
            </tbody>
        </table>
"@

    # ── Backup Chain Visualization ──
    # Each job renders as a horizontal ribbon of cards:
    #   Green  → full backup (.vbk)
    #   Yellow → incremental backup (.vib)
    #   Red    → unreferenced on disk OR referenced by VBM but missing OR VBK that failed validation
    # Arrows between cards point to the next link in the chain in chronological order.
    $html += @'
        <h2>🔗 Backup Chain Visualization</h2>
        <div class="chain-legend">
            <span><span class="swatch full"></span>Full (VBK)</span>
            <span><span class="swatch incremental"></span>Incremental (VIB)</span>
            <span><span class="swatch broken"></span>Broken / Unreferenced / Missing</span>
        </div>
        <div class="chain-section">
'@

    # Local helper: extract the short machine name from a Veeam file name.
    # Veeam naming format is typically '{Machine}.vm-{date}T{time}_{hex}.vbk|.vib',
    # so the short name is the first dot-separated token. Falls back to the raw name.
    $getShortName = {
        param($rawName)
        if ([string]::IsNullOrEmpty($rawName)) { return '' }
        $first = ($rawName -split '\.', 2)[0]
        if ([string]::IsNullOrWhiteSpace($first)) { return $rawName }
        return $first
    }

    # Local helper: format a card's date line as 'yyyy-MM-dd HH:mm DAYOFWEEK'
    $formatCardDate = {
        param($created)
        if (-not $created) { return '' }
        '{0} {1}' -f $created.ToString('yyyy-MM-dd HH:mm'), $created.DayOfWeek.ToString().ToUpper()
    }

    # Local helper: emit a single chain card as HTML.
    # If $selectable is $true and $filePath is provided, a selection checkbox is embedded so
    # the user can pick the card for a bulk DELETE or ARCHIVE action from the action bar.
    $emitCard = {
        param($cls, $label, $displayName, $dateLine, $sizeLine, $fileNameRaw, $selectable, $filePath)
        $checkbox = ''
        if ($selectable -and $filePath) {
            # Escape the path for safe embedding in an HTML data- attribute
            $encodedPath = [string]$filePath -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;'
            $checkbox = "<label class=`"card-select`"><input type=`"checkbox`" class=`"file-select`" data-path=`"$encodedPath`" /> Select</label>"
        }
        @"
<div class="chain-card $cls">
    <div class="card-type">$label</div>
    <div class="card-name">$displayName</div>
    <div class="card-date">$dateLine</div>
    <div class="card-size">$sizeLine</div>
    <div class="card-filename">$fileNameRaw</div>
    $checkbox
</div>
"@
    }

    foreach ($result in $Results) {
        $displayJobName = & $getDisplayName $result.JobName
        $jobNameSafe    = & $htmlSafe $displayJobName
        $jobMachineKey  = & $htmlSafe $displayJobName.ToLower()
        $jobLastRunIso  = if ($result.ChainInfo.NewestBackup) { $result.ChainInfo.NewestBackup.ToString('o') } else { '' }

        $integrity       = $result.ValidationResult.ChainIntegrity
        $extraOnDisk     = if ($integrity) { @($integrity.ExtraOnDisk) }     else { @() }
        $missingFromDisk = if ($integrity) { @($integrity.MissingFromDisk) } else { @() }

        # Per-file Invalid set (only populated by the file-by-file validation branch).
        # We never infer "corrupt" solely from an overall Failed status — that could be
        # caused by a chain-integrity mismatch rather than actual file corruption.
        $invalidByFile = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        if ($result.ValidationResult.Files) {
            foreach ($pf in $result.ValidationResult.Files) {
                if ($pf.Status -eq 'Invalid') { [void]$invalidByFile.Add($pf.FileName) }
            }
        }

        $html += "            <div class=`"job-chain`" data-machine=`"$jobMachineKey`" data-lastrun=`"$jobLastRunIso`"><h3>$jobNameSafe</h3>"

        $files = @($result.ChainInfo.Files)

        # Build the main timeline from files the VBM actually references:
        #   - Referenced actual files (kept in chronological order)
        #   - MISSING entries inferred from the VBM (chronological via filename timestamp)
        # Unreferenced files (on disk but NOT in the VBM — e.g. renamed with _MOD)
        # are held aside and rendered in their own separate final row below the chain,
        # since they aren't part of any valid restore point sequence.
        $timeline          = [System.Collections.Generic.List[hashtable]]::new()
        $unreferencedItems = [System.Collections.Generic.List[hashtable]]::new()

        foreach ($f in $files) {
            if ($extraOnDisk -contains $f.Name) {
                $unreferencedItems.Add(@{
                    Name    = $f.Name
                    Type    = $f.Type
                    Created = $f.Created
                    Size    = $f.Size
                    Path    = $f.Path
                })
            } else {
                $timeline.Add(@{
                    Kind    = 'Actual'
                    Name    = $f.Name
                    Type    = $f.Type
                    Created = $f.Created
                    Size    = $f.Size
                    Path    = $f.Path
                })
            }
        }
        foreach ($m in $missingFromDisk) {
            $ts   = Get-VeeamFilenameTimestamp -FileName $m
            $type = if ($m -match '\.vbk$') { 'Full' } else { 'Incremental' }
            $timeline.Add(@{
                Kind    = 'Missing'
                Name    = $m
                Type    = $type
                Created = $ts
                Size    = 0
            })
        }

        if ($timeline.Count -eq 0) {
            $html += '<div class="chain-container"><div class="no-chain">No backup files found in this chain.</div></div>'
        } else {
            # Sort chronologically; entries without a timestamp sort to the end
            $sortedTimeline = @($timeline | Sort-Object @{
                Expression = { if ($_.Created) { $_.Created } else { [datetime]::MaxValue } }
            })

            # Split into sub-chains: a Full (VBK) starts a new row, even if that VBK is missing
            $chains = [System.Collections.Generic.List[object]]::new()
            $current = [System.Collections.Generic.List[object]]::new()
            foreach ($item in $sortedTimeline) {
                if ($item.Type -eq 'Full' -and $current.Count -gt 0) {
                    $chains.Add($current)
                    $current = [System.Collections.Generic.List[object]]::new()
                }
                $current.Add($item)
            }
            if ($current.Count -gt 0) { $chains.Add($current) }

            foreach ($chain in $chains) {
                $html += '<div class="chain-container">'
                $brokenDownstream = $false   # Once a VIB in this sub-chain is bad, all subsequent VIBs are unreliable
                $first = $true

                foreach ($item in $chain) {
                    if (-not $first) { $html += '<div class="chain-arrow">→</div>' }

                    $isFull    = $item.Type -eq 'Full'
                    $isMissing = $item.Kind -eq 'Missing'
                    $isInvalid = (-not $isMissing) -and ($invalidByFile.Contains($item.Name))

                    # Choose card class and label per state machine, propagating broken state
                    if ($isMissing) {
                        $cls   = 'broken'
                        $label = if ($isFull) { '⚠ RP VBK MISSING' } else { '⚠ RP VIB MISSING' }
                        $brokenDownstream = $true
                    }
                    elseif ($isInvalid) {
                        $cls   = 'broken'
                        $label = if ($isFull) { '⚠ CORRUPT VBK' } else { '⚠ CORRUPT VIB' }
                        $brokenDownstream = $true
                    }
                    elseif ($brokenDownstream -and -not $isFull) {
                        # Cascade: VIB is otherwise fine but its base/parent is bad — restore point unusable
                        $cls   = 'broken'
                        $label = '⚠ VIB NOT VALID - BROKEN CHAIN'
                    }
                    elseif ($isFull) {
                        $cls   = 'full'
                        $label = 'FULL (VBK)'
                        # A fresh VBK resets the propagation — already true because a new sub-chain
                        # means a new chain-container, but keep explicit for clarity.
                        $brokenDownstream = $false
                    }
                    else {
                        $cls   = 'incremental'
                        $label = 'INCR (VIB)'
                    }

                    $displayName = & $htmlSafe (& $getShortName $item.Name)
                    $fileNameRaw = & $htmlSafe $item.Name
                    $dateLine    = if ($item.Created) {
                        & $htmlSafe (& $formatCardDate $item.Created)
                    } elseif ($isMissing) {
                        'referenced by VBM'
                    } else {
                        ''
                    }
                    $sizeLine = if ($isMissing) { 'not on disk' } else { Format-FileSize $item.Size }

                    # Only CORRUPT cards are selectable in the main chain — MISSING files
                    # aren't on disk and BROKEN CHAIN downstream files are restorable once
                    # the real break is fixed, so we don't encourage deleting them.
                    $selectable = $isInvalid -and ($item.ContainsKey('Path')) -and $item.Path
                    $selPath    = if ($selectable) { $item.Path } else { $null }

                    $html += & $emitCard $cls $label $displayName $dateLine $sizeLine $fileNameRaw $selectable $selPath
                    $first = $false
                }

                $html += '</div>'
            }

            # ── Separate final row for UNREFERENCED files (on disk but not in VBM) ──
            # These are presented chronologically on their own line so the main chain remains
            # a clean sequence of referenced restore points. Typical cause: a file was renamed
            # after the VBM was written (e.g. '..._2562.vib' → '..._2562_MOD.vib').
            if ($unreferencedItems.Count -gt 0) {
                $sortedUnref = @($unreferencedItems | Sort-Object @{
                    Expression = { if ($_.Created) { $_.Created } else { [datetime]::MaxValue } }
                })

                $html += '<div class="unreferenced-heading">Possible Orphaned Files</div>'
                $html += '<div class="chain-container">'
                $firstUnref = $true
                foreach ($u in $sortedUnref) {
                    if (-not $firstUnref) { $html += '<div class="chain-arrow">→</div>' }
                    $label        = if ($u.Type -eq 'Full') { '⚠ UNREFERENCED VBK' } else { '⚠ UNREFERENCED VIB' }
                    $displayName  = & $htmlSafe (& $getShortName $u.Name)
                    $fileNameRaw  = & $htmlSafe $u.Name
                    $dateLine     = if ($u.Created) { & $htmlSafe (& $formatCardDate $u.Created) } else { '' }
                    $sizeLine     = Format-FileSize $u.Size
                    # Unreferenced files are always selectable (they exist on disk, don't belong
                    # to any valid restore point, and are the prime candidates for cleanup).
                    $html += & $emitCard 'broken' $label $displayName $dateLine $sizeLine $fileNameRaw $true $u.Path
                    $firstUnref = $false
                }
                $html += '</div>'
            }
        }

        $html += '</div>'
    }

    $html += @'
        </div>
        <div class="action-bar">
            <button class="btn-delete"  onclick="onDeleteClick()">🗑 DELETE Selected</button>
            <button class="btn-archive" onclick="onArchiveClick()">📦 ARCHIVE Selected</button>
        </div>
    </div>

    <!-- DELETE dialog (red, blinking yellow warning) -->
    <div id="delete-modal" class="modal-overlay hidden">
      <div class="modal-box red-dialog">
        <h2 class="blink-yellow">⚠ WARNING: YOU ARE ABOUT TO DESTROY A BACKUP! ⚠</h2>
        <p>The following file(s) will be <strong>permanently deleted from disk</strong>:</p>
        <ul id="delete-file-list" class="modal-file-list"></ul>
        <p>Run this command in an <strong>elevated</strong> PowerShell terminal to perform the deletion:</p>
        <pre id="delete-ps-command"></pre>
        <div class="modal-buttons">
          <button class="btn-copy"   onclick="copyText('delete-ps-command')">📋 Copy Command</button>
          <button class="btn-cancel" onclick="closeModal('delete-modal')">Close</button>
        </div>
      </div>
    </div>

    <!-- ARCHIVE dialog -->
    <div id="archive-modal" class="modal-overlay hidden">
      <div class="modal-box">
        <h2>📦 Archive Files to ORPHANED Folder</h2>
        <p>The command below will <strong>MOVE</strong> the selected file(s) to an <code>ORPHANED</code> folder at the root of each source drive (created if it doesn’t exist).</p>
        <p>Run it in an <strong>elevated</strong> PowerShell terminal:</p>
        <pre id="archive-ps-command"></pre>
        <div class="modal-buttons">
          <button class="btn-copy"   onclick="copyText('archive-ps-command')">📋 Copy Command</button>
          <button class="btn-cancel" onclick="closeModal('archive-modal')">Close</button>
        </div>
      </div>
    </div>

    <script>
    // Use double-quoted JS strings throughout. PowerShell's single-quoted here-string
    // (@' ... '@) is fully literal, so single quotes inside pass through untouched.
    function byId(id) { return document.getElementById(id); }
    function getSelected() { return Array.from(document.querySelectorAll(".file-select:checked")); }
    function openModal(id)  { byId(id).classList.remove("hidden"); }
    function closeModal(id) { byId(id).classList.add("hidden"); }

    // PowerShell single-quoted literal: wrap in single quotes, doubling any embedded single quote.
    function psQuote(p) {
        var s = String(p).split("'").join("''");
        return "'" + s + "'";
    }

    function buildDeleteCmd(paths) {
        var arr = paths.map(psQuote).join(",");
        return "@(" + arr + ") | ForEach-Object { Write-Host \"Deleting $_\" -ForegroundColor Red; Remove-Item -Path $_ -Force -Verbose }";
    }

    function buildArchiveCmd(paths) {
        // Group by drive letter so each drive gets its own ORPHANED folder at its root
        var byDrive = {};
        paths.forEach(function (p) {
            var m = p.match(/^([A-Za-z]):/);
            if (!m) { return; }
            var d = m[1].toUpperCase();
            (byDrive[d] = byDrive[d] || []).push(p);
        });
        var parts = Object.keys(byDrive).sort().map(function (d) {
            var destPath = d + ":\\ORPHANED";
            var arr      = byDrive[d].map(psQuote).join(",");
            return (
                "$dest = " + psQuote(destPath) + "; " +
                "if (-not (Test-Path $dest)) { New-Item -Path $dest -ItemType Directory -Force | Out-Null }; " +
                "@(" + arr + ") | ForEach-Object { Write-Host \"Archiving $_ -> $dest\" -ForegroundColor Cyan; Move-Item -Path $_ -Destination $dest -Force -Verbose }"
            );
        });
        return parts.join("\n");
    }

    function onDeleteClick() {
        var sel = getSelected();
        if (!sel.length) { alert("Please select one or more files using the checkboxes."); return; }
        var list = byId("delete-file-list");
        list.innerHTML = "";
        var paths = [];
        sel.forEach(function (cb) {
            var li = document.createElement("li");
            li.textContent = cb.dataset.path;
            list.appendChild(li);
            paths.push(cb.dataset.path);
        });
        byId("delete-ps-command").textContent = buildDeleteCmd(paths);
        openModal("delete-modal");
    }

    function onArchiveClick() {
        var sel = getSelected();
        if (!sel.length) { alert("Please select one or more files using the checkboxes."); return; }
        var paths = sel.map(function (cb) { return cb.dataset.path; });
        byId("archive-ps-command").textContent = buildArchiveCmd(paths);
        openModal("archive-modal");
    }

    function copyText(elId) {
        var txt = byId(elId).textContent;
        if (navigator.clipboard && navigator.clipboard.writeText) {
            navigator.clipboard.writeText(txt).then(function () {
                alert("Command copied to clipboard. Paste it into an elevated PowerShell terminal to execute.");
            }, function () { fallbackCopy(txt); });
        } else { fallbackCopy(txt); }
    }
    function fallbackCopy(txt) {
        var ta = document.createElement("textarea");
        ta.value = txt; document.body.appendChild(ta); ta.select();
        try { document.execCommand("copy"); alert("Command copied to clipboard."); }
        catch (e) { alert("Could not copy. Copy manually:\n\n" + txt); }
        document.body.removeChild(ta);
    }

    // Sort both the Validation Results table and the Backup Chain Visualization section
    // in sync. Keys:  machine = case-insensitive display name ;  lastrun = ISO-8601 timestamp
    // of the most recent backup (empty string sorts before any value).
    function sortJobs(key, dir) {
        var factor = dir === "asc" ? 1 : -1;

        function cmp(a, b) {
            var av = a.getAttribute("data-" + key) || "";
            var bv = b.getAttribute("data-" + key) || "";
            if (av === bv) { return 0; }
            return (av < bv ? -1 : 1) * factor;
        }

        var tbody = document.querySelector("#results-table tbody");
        if (tbody) {
            var rows = Array.prototype.slice.call(tbody.querySelectorAll("tr"));
            rows.sort(cmp);
            rows.forEach(function (r) { tbody.appendChild(r); });
        }

        var chainSection = document.querySelector(".chain-section");
        if (chainSection) {
            var jobs = Array.prototype.slice.call(chainSection.querySelectorAll(".job-chain"));
            jobs.sort(cmp);
            jobs.forEach(function (j) { chainSection.appendChild(j); });
        }

        // Visual active-button indicator across all sort-bar rows
        var activeId = key + "-" + dir;
        document.querySelectorAll(".sort-bar button").forEach(function (b) {
            b.classList.toggle("active", b.dataset.sortId === activeId);
        });
    }

    // Tag each sort button with a data-sort-id so we can highlight the active one
    document.addEventListener("DOMContentLoaded", function () {
        document.querySelectorAll(".sort-bar button").forEach(function (b) {
            var m = b.getAttribute("onclick");
            if (m) {
                var match = m.match(/sortJobs\(['"]([^'"]+)['"],\s*['"]([^'"]+)['"]\)/);
                if (match) { b.dataset.sortId = match[1] + "-" + match[2]; }
            }
        });
    });
    </script>
</body>
</html>
'@

    $htmlSaved = $false
    try {
        $html | Out-File -FilePath $Script:SummaryReport -Encoding UTF8 -ErrorAction Stop
        Write-Log "HTML report saved to: $Script:SummaryReport" -Level Success
        $htmlSaved = $true
    } catch {
        Write-Log "Failed to save HTML summary report: $($_.Exception.Message)" -Level Error
    }

    # Auto-open the report in the default browser (maximised) unless suppressed.
    # Silent mode and -NoOpenReport both skip this, so unattended runs don't spawn UI.
    if ($htmlSaved -and -not $Script:Config.Silent -and -not $Script:Config.NoOpenReport) {
        Open-HtmlReport -Path $Script:SummaryReport
    }

    # Export CSV — flatten nested hashtables so column values are meaningful, not type names
    if ($Script:Config.ExportCsv) {
        $csvPath = Join-Path $Script:Config.ReportPath "ValidationResults_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
        try {
            $flatResults = $Script:ValidationResults | ForEach-Object {
                $integ = $_.ValidationResult.ChainIntegrity
                [PSCustomObject]@{
                    JobName              = $_.JobName
                    Timestamp            = $_.Timestamp
                    ChainType            = $_.ChainInfo.ChainType
                    ChainLength          = $_.ChainInfo.ChainLength
                    TotalSizeBytes       = $_.ChainInfo.TotalSize
                    OldestBackup         = $_.ChainInfo.OldestBackup
                    NewestBackup         = $_.ChainInfo.NewestBackup
                    ValidationStatus     = $_.ValidationResult.ValidationStatus
                    ChainIntegrityStatus = if ($integ) { $integ.Status } else { '' }
                    MissingFromDisk      = if ($integ) { ($integ.MissingFromDisk -join '; ') } else { '' }
                    ExtraOnDisk          = if ($integ) { ($integ.ExtraOnDisk     -join '; ') } else { '' }
                    DurationSeconds      = $_.ValidationResult.Duration
                    Errors               = ($_.ValidationResult.Errors -join '; ')
                    ReportPath           = $_.ValidationResult.ReportPath
                }
            }
            $flatResults | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
            Write-Log "CSV report saved to: $csvPath" -Level Success
        } catch {
            Write-Log "Failed to save CSV report: $($_.Exception.Message)" -Level Error
        }
    }

    # Export JSON
    if ($Script:Config.ExportJson) {
        $jsonPath = Join-Path $Script:Config.ReportPath "ValidationResults_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
        try {
            $Script:ValidationResults | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonPath -Encoding UTF8 -ErrorAction Stop
            Write-Log "JSON report saved to: $jsonPath" -Level Success
        } catch {
            Write-Log "Failed to save JSON report: $($_.Exception.Message)" -Level Error
        }
    }
}

function Send-TeamsNotification {
    param(
        [array]$Results,
        [string]$WebhookUrl
    )

    if (-not $WebhookUrl) {
        Write-Log "Teams Webhook URL not provided. Skipping notification." -Level Warning
        return
    }

    if ($WebhookUrl -notmatch '^https?://') {
        Write-Log "Teams Webhook URL is invalid (must start with http:// or https://): $WebhookUrl" -Level Warning
        return
    }

    $successCount = @($Results | Where-Object { $_.ValidationResult.ValidationStatus -eq 'Success' }).Count
    $failedCount  = @($Results | Where-Object { $_.ValidationResult.ValidationStatus -in @('Failed', 'Error') }).Count
    
    $color = if ($failedCount -gt 0) { "FF0000" } else { "008000" }
    
    $body = @{
        text = "Veeam Validation Summary"
        themeColor = $color
        sections = @(
            @{
                activityTitle = "Validation Results"
                activitySubtitle = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
                activityText = "Total Jobs: $($Results.Count)`nSuccess: $successCount`nFailed: $failedCount"
                activityImage = "https://img.icons8.com/color/48/000000/backup.png"
            }
        )
    } | ConvertTo-Json -Depth 3

    try {
        Invoke-RestMethod -Uri $WebhookUrl -Method Post -Body $body -ContentType 'application/json' -ErrorAction Stop
        Write-Log "Teams notification sent." -Level Success
    } catch {
        Write-Log "Failed to send Teams notification: $($_.Exception.Message)" -Level Error
    }
}

#endregion

#region Main Execution

function Start-ValidationWorkflow {
    $mappedDrive = $null

    try {
        # 1. Initialize
        Initialize-Environment

        # 2. Check Validator
        if (-not (Test-ValidatorExecutable)) {
            Write-Log "Cannot proceed without Veeam Backup Validator" -Level Error
            return 1
        }

        # 3. Handle UNC Paths & Credentials
        if ($Script:Config.DatastorePath -match '^\\\\') {
            try {
                $driveLetter = "VeeamNet"
                $driveParams = @{
                    Name        = $driveLetter
                    PSProvider  = 'FileSystem'
                    Root        = $Script:Config.DatastorePath
                    ErrorAction = 'Stop'
                }
                # Only supply -Credential when one was provided; passing $null causes errors on some systems
                if ($Script:Config.Credential) { $driveParams.Credential = $Script:Config.Credential }
                $null = New-PSDrive @driveParams
                $Script:Config.DatastorePath = "${driveLetter}:\"
                $mappedDrive = $driveLetter
                Write-Log "Mapped UNC path to: $Script:Config.DatastorePath" -Level Info
            }
            catch {
                Write-Log "Failed to map network drive: $($_.Exception.Message)" -Level Error
                return 1
            }
        }
        elseif (-not $Script:Config.DatastorePath) {
            $Script:Config.DatastorePath = Read-Host "Enter Datastore Path"
        }

        # 4. Validate Path Exists
        if (-not (Test-Path $Script:Config.DatastorePath)) {
            Write-Log "Datastore path not found: $($Script:Config.DatastorePath)" -Level Error
            return 1
        }

        # 5. Discovery
        Write-Log "Starting backup discovery..." -Level Info
        $backupJobs = Find-VeeamBackupJobs -Path $Script:Config.DatastorePath

        if ($backupJobs.Count -eq 0) {
            Write-Log "No Veeam backup jobs found in: $($Script:Config.DatastorePath)" -Level Warning
            return 2
        }

        # 6. Validation
        Write-Log "Starting validation of $($backupJobs.Count) backup jobs..." -Level Info
        # @() forces an array even when Test-AllBackupJobs returns a single result.
        # Without this, PowerShell unwraps a 1-element array into the hashtable itself,
        # and $validationResults.Count would return the number of hashtable keys (4)
        # instead of the number of jobs.
        $validationResults = @(Test-AllBackupJobs -BackupJobs $backupJobs)

        # 7. Reporting
        New-ValidationSummaryReport -Results $validationResults

        # 8. Notification
        if ($Script:Config.SendTeamsNotification) {
            Send-TeamsNotification -Results $validationResults -WebhookUrl $Script:Config.TeamsWebhookUrl
        }

        # Exit code: 0 = all passed, 3 = one or more validation failures
        $failedCount = @($validationResults | Where-Object { $_.ValidationResult.ValidationStatus -in @('Failed', 'Error') }).Count
        $exitCode = if ($failedCount -gt 0) { 3 } else { 0 }
        Write-Log "Validation complete. $($validationResults.Count) jobs processed, $failedCount failed." -Level Success
        return $exitCode
    }
    catch {
        Write-Log "Unhandled error in validation workflow: $($_.Exception.Message)" -Level Error
        return 1
    }
    finally {
        # 9. Cleanup — always runs, even on early return or unhandled exception
        if ($mappedDrive) {
            Remove-PSDrive -Name $mappedDrive -Force -ErrorAction SilentlyContinue
            Write-Log "Removed temporary network drive." -Level Info
        }
    }
}

# Entry Point — exit code conventions:
#   0 = success, all backups valid
#   1 = script/configuration error
#   2 = no backup jobs found
#   3 = one or more backup validation failures
exit (Start-ValidationWorkflow)
