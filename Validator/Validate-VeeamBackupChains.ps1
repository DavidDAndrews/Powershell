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

.EXAMPLE
    .\Validate-VeeamBackupChains.ps1 -DatastorePath "D:\VeeamBackups" -ReportPath "C:\Reports"

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

    [switch]$SkipElevationCheck
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
        $knownJobPaths += $jobPath
        
        # Extract Job Name from Directory or VBM Filename
        $jobName = [System.IO.Path]::GetFileNameWithoutExtension($vbm.Name)
        
        # Find associated files in the same directory
        $vbkFiles = @(Get-ChildItem -Path $jobPath -File -Filter "*.vbk" -ErrorAction SilentlyContinue)
        $vibFiles = @(Get-ChildItem -Path $jobPath -File -Filter "*.vib" -ErrorAction SilentlyContinue)

        # Accumulate size with foreach: Measure-Object returns $null (not a MeasureInfo) for
        # empty collections under PS 5.1 Set-StrictMode, so .Sum would throw
        $jobTotalBytes = [long]0
        foreach ($f in $vbkFiles) { $jobTotalBytes += $f.Length }
        foreach ($f in $vibFiles) { $jobTotalBytes += $f.Length }

        $backupJobs[$jobName] = @{
            Name               = $jobName
            Path               = $jobPath
            VBMFile            = $vbm.FullName
            FullBackups        = $vbkFiles
            IncrementalBackups = $vibFiles
            TotalFiles         = $vbkFiles.Count + $vibFiles.Count
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
        $sortedFiles = $allFiles | Sort-Object CreationTime
        
        $chainInfo.ChainLength = $allFiles.Count
        $chainInfo.OldestBackup = $sortedFiles[0].CreationTime
        $chainInfo.NewestBackup = $sortedFiles[-1].CreationTime
        $chainInfo.TotalSize = ($allFiles | Measure-Object -Property Length -Sum).Sum
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
    }
    
    Write-Log "Starting validation for job: $($Job.Name)" -Level Info
    
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
            
            if ($process.ExitCode -eq 0) {
                $validationResult.ValidationStatus = "Success"
                Write-Log "Validation completed successfully for: $($Job.Name)" -Level Success
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
            
            $failedCount = ($validationResult.Files | Where-Object { $_.Status -eq "Invalid" }).Count
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

    $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>Veeam Backup Chain Validation Report</title>
    <meta charset="utf-8">
    <style>
        body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; margin: 20px; background: #f4f6f9; }
        .container { max-width: 1400px; margin: 0 auto; background: white; border-radius: 8px; padding: 30px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
        h1 { color: #333; border-bottom: 3px solid #667eea; padding-bottom: 10px; }
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
        .timestamp { color: #6c757d; font-size: 14px; margin-top: 30px; text-align: center; }
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
            <div class="summary-card warning">
                <h3>Partial Success</h3>
                <div class="value">$(@($Results | Where-Object { $_.ValidationResult.ValidationStatus -eq 'PartialSuccess' }).Count)</div>
            </div>
            <div class="summary-card error">
                <h3>Failed</h3>
                <div class="value">$(@($Results | Where-Object { $_.ValidationResult.ValidationStatus -in @('Failed', 'Error') }).Count)</div>
            </div>
        </div>

        <h2>📊 Validation Results</h2>
        <table>
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
        
        $html += @"
                <tr>
                    <td><strong>$(& $htmlSafe $result.JobName)</strong></td>
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
    </div>
</body>
</html>
"@

    try {
        $html | Out-File -FilePath $Script:SummaryReport -Encoding UTF8 -ErrorAction Stop
        Write-Log "HTML report saved to: $Script:SummaryReport" -Level Success
    } catch {
        Write-Log "Failed to save HTML summary report: $($_.Exception.Message)" -Level Error
    }

    # Export CSV — flatten nested hashtables so column values are meaningful, not type names
    if ($Script:Config.ExportCsv) {
        $csvPath = Join-Path $Script:Config.ReportPath "ValidationResults_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
        try {
            $flatResults = $Script:ValidationResults | ForEach-Object {
                [PSCustomObject]@{
                    JobName          = $_.JobName
                    Timestamp        = $_.Timestamp
                    ChainType        = $_.ChainInfo.ChainType
                    ChainLength      = $_.ChainInfo.ChainLength
                    TotalSizeBytes   = $_.ChainInfo.TotalSize
                    OldestBackup     = $_.ChainInfo.OldestBackup
                    NewestBackup     = $_.ChainInfo.NewestBackup
                    ValidationStatus = $_.ValidationResult.ValidationStatus
                    DurationSeconds  = $_.ValidationResult.Duration
                    Errors           = ($_.ValidationResult.Errors -join '; ')
                    ReportPath       = $_.ValidationResult.ReportPath
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
        $validationResults = Test-AllBackupJobs -BackupJobs $backupJobs

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
