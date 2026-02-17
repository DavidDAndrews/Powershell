#Requires -Version 5.1
<#
.SYNOPSIS
    Validates Veeam backup chains in specified datastores using Veeam Backup Validator.

.DESCRIPTION
    This script enumerates Veeam backup datastores, discovers all backup jobs and their associated
    backup files, then validates each backup chain using the Veeam Backup Validator executable.
    Generates comprehensive HTML reports with validation results.

.PARAMETER DatastorePath
    Path to the Veeam backup datastore to scan. Can be local path or UNC path.

.PARAMETER ValidatorPath
    Path to Veeam.Backup.Validator.exe. Defaults to standard Veeam installation path.

.PARAMETER ReportPath
    Directory where HTML/XML validation reports will be saved.

.PARAMETER IncludeAllVMs
    If specified, validates all VMs in each backup. Otherwise validates backup integrity only.

.EXAMPLE
    .\Validate-VeeamBackupChains.ps1 -DatastorePath "D:\VeeamBackups" -ReportPath "C:\Reports"

.NOTES
    Author: PowerShell Validator Script
    Version: 1.0
    Requires: Veeam Backup & Replication with Validator component installed
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$DatastorePath,
    
    [Parameter(Mandatory=$false)]
    [string]$ValidatorPath = "C:\Program Files\Veeam\Backup and Replication\Backup\Veeam.Backup.Validator.exe",
    
    [Parameter(Mandatory=$false)]
    [string]$ReportPath = "$env:USERPROFILE\Downloads\VeeamValidation",
    
    [switch]$IncludeAllVMs,
    
    [switch]$Silent
)

# Global variables
$script:ValidationResults = @()
$script:LogFile = Join-Path $ReportPath "VeeamValidation_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$script:SummaryReport = Join-Path $ReportPath "ValidationSummary_$(Get-Date -Format 'yyyyMMdd_HHmmss').html"

#region Helper Functions

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Warning', 'Error', 'Success')]
        [string]$Level = 'Info'
    )
    
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logEntry = "$timestamp [$Level] $Message"
    
    # Console output with colors
    if (-not $Silent) {
        switch ($Level) {
            'Error'   { Write-Host $logEntry -ForegroundColor Red }
            'Warning' { Write-Host $logEntry -ForegroundColor Yellow }
            'Success' { Write-Host $logEntry -ForegroundColor Green }
            default   { Write-Host $logEntry -ForegroundColor White }
        }
    }
    
    # File output
    if ($script:LogFile) {
        Add-Content -Path $script:LogFile -Value $logEntry -ErrorAction SilentlyContinue
    }
}

function Test-ValidatorExecutable {
    if (-not (Test-Path $ValidatorPath)) {
        Write-Log "Veeam Backup Validator not found at: $ValidatorPath" -Level Error
        Write-Log "Please ensure Veeam Backup & Replication is installed with the Validator component" -Level Error
        return $false
    }
    
    try {
        $versionOutput = & $ValidatorPath /? 2>&1 | Select-Object -First 2
        Write-Log "Found Veeam Backup Validator: $($versionOutput -join ' ')" -Level Success
        return $true
    }
    catch {
        Write-Log "Failed to execute Veeam Backup Validator: $_" -Level Error
        return $false
    }
}

function Initialize-Environment {
    # Create report directory if it doesn't exist
    if (-not (Test-Path $ReportPath)) {
        New-Item -Path $ReportPath -ItemType Directory -Force | Out-Null
        Write-Log "Created report directory: $ReportPath" -Level Info
    }
    
    # Initialize log file
    if (-not (Test-Path (Split-Path $script:LogFile -Parent))) {
        New-Item -Path (Split-Path $script:LogFile -Parent) -ItemType Directory -Force | Out-Null
    }
    
    Write-Log "=== Veeam Backup Chain Validation Started ===" -Level Info
    Write-Log "Datastore: $DatastorePath" -Level Info
    Write-Log "Report Path: $ReportPath" -Level Info
}

#endregion

#region Backup Discovery Functions

function Find-VeeamBackupJobs {
    param(
        [string]$Path
    )
    
    Write-Log "Scanning for Veeam backup jobs in: $Path" -Level Info
    
    $backupJobs = @{}
    
    # Find all VBM files (backup metadata)
    $vbmFiles = Get-ChildItem -Path $Path -Recurse -Filter "*.vbm" -ErrorAction SilentlyContinue
    
    foreach ($vbm in $vbmFiles) {
        $jobName = [System.IO.Path]::GetFileNameWithoutExtension($vbm.Name)
        $jobPath = $vbm.DirectoryName
        
        Write-Log "Found backup job: $jobName" -Level Info
        
        # Find associated backup files
        $vbkFiles = Get-ChildItem -Path $jobPath -Filter "*.vbk" -ErrorAction SilentlyContinue
        $vibFiles = Get-ChildItem -Path $jobPath -Filter "*.vib" -ErrorAction SilentlyContinue
        
        $backupJobs[$jobName] = @{
            Name = $jobName
            Path = $jobPath
            VBMFile = $vbm.FullName
            FullBackups = $vbkFiles
            IncrementalBackups = $vibFiles
            TotalFiles = $vbkFiles.Count + $vibFiles.Count
            TotalSize = ($vbkFiles | Measure-Object -Property Length -Sum).Sum + 
                       ($vibFiles | Measure-Object -Property Length -Sum).Sum
        }
        
        Write-Log "  - Full backups: $($vbkFiles.Count)" -Level Info
        Write-Log "  - Incremental backups: $($vibFiles.Count)" -Level Info
    }
    
    # Also find orphaned backup files (without VBM)
    $allVbkFiles = Get-ChildItem -Path $Path -Recurse -Filter "*.vbk" -ErrorAction SilentlyContinue
    
    foreach ($vbk in $allVbkFiles) {
        $jobPath = $vbk.DirectoryName
        $vbmInSameDir = Get-ChildItem -Path $jobPath -Filter "*.vbm" -ErrorAction SilentlyContinue
        
        if (-not $vbmInSameDir) {
            # Extract job name from file name pattern
            $jobName = if ($vbk.Name -match '^(.+?)(?:D\d{4}-\d{2}-\d{2}T|\d{4}-\d{2}-\d{2}T|\.vbk)') {
                $matches[1]
            } else {
                [System.IO.Path]::GetFileNameWithoutExtension($vbk.Name)
            }
            
            if (-not $backupJobs.ContainsKey("$jobName-Orphaned")) {
                Write-Log "Found orphaned backup files for job: $jobName" -Level Warning
                
                $backupJobs["$jobName-Orphaned"] = @{
                    Name = "$jobName-Orphaned"
                    Path = $jobPath
                    VBMFile = $null
                    FullBackups = Get-ChildItem -Path $jobPath -Filter "$jobName*.vbk" -ErrorAction SilentlyContinue
                    IncrementalBackups = Get-ChildItem -Path $jobPath -Filter "$jobName*.vib" -ErrorAction SilentlyContinue
                    IsOrphaned = $true
                }
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
        
        # Determine chain type
        if ($Job.VBMFile) {
            $chainInfo.ChainType = "Standard"
        } elseif ($Job.IsOrphaned) {
            $chainInfo.ChainType = "Orphaned"
        } else {
            $chainInfo.ChainType = "Standalone"
        }
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
    }
    
    Write-Log "Starting validation for job: $($Job.Name)" -Level Info
    
    # Generate report filename
    $reportFileName = "$($Job.Name)_$(Get-Date -Format 'yyyyMMdd_HHmmss').$ReportFormat"
    $reportFullPath = Join-Path $ReportPath $reportFileName
    
    try {
        # Validate using VBM file if available
        if ($Job.VBMFile -and (Test-Path $Job.VBMFile)) {
            Write-Log "Validating using VBM file: $($Job.VBMFile)" -Level Info
            
            $arguments = @(
                "/file:`"$($Job.VBMFile)`""
                "/report:`"$reportFullPath`""
                "/format:$ReportFormat"
            )
            
            if (-not $IncludeAllVMs) {
                $arguments += "/silence"
            }
            
            $process = Start-Process -FilePath $ValidatorPath -ArgumentList $arguments -NoNewWindow -Wait -PassThru
            
            if ($process.ExitCode -eq 0) {
                $validationResult.ValidationStatus = "Success"
                Write-Log "Validation completed successfully for: $($Job.Name)" -Level Success
            } else {
                $validationResult.ValidationStatus = "Failed"
                $validationResult.Errors += "Validator exit code: $($process.ExitCode)"
                Write-Log "Validation failed for: $($Job.Name) (Exit code: $($process.ExitCode))" -Level Error
            }
            
            $validationResult.ReportPath = $reportFullPath
        }
        # Validate individual backup files if no VBM
        else {
            Write-Log "No VBM file found, validating individual backup files" -Level Warning
            
            foreach ($backup in $Job.FullBackups) {
                Write-Log "  Validating: $($backup.Name)" -Level Info
                
                $fileReportPath = Join-Path $ReportPath "$([System.IO.Path]::GetFileNameWithoutExtension($backup.Name))_$(Get-Date -Format 'yyyyMMdd_HHmmss').$ReportFormat"
                
                $arguments = @(
                    "/file:`"$($backup.FullName)`""
                    "/report:`"$fileReportPath`""
                    "/format:$ReportFormat"
                    "/silence"
                )
                
                $process = Start-Process -FilePath $ValidatorPath -ArgumentList $arguments -NoNewWindow -Wait -PassThru
                
                $fileResult = @{
                    FileName = $backup.Name
                    Status = if ($process.ExitCode -eq 0) { "Valid" } else { "Invalid" }
                    ExitCode = $process.ExitCode
                    ReportPath = $fileReportPath
                }
                
                $validationResult.Files += $fileResult
                
                if ($process.ExitCode -ne 0) {
                    Write-Log "  Validation failed for file: $($backup.Name)" -Level Error
                    $validationResult.Errors += "File $($backup.Name) validation failed"
                } else {
                    Write-Log "  Validation successful for file: $($backup.Name)" -Level Success
                }
            }
            
            # Set overall status based on file validations
            $failedCount = ($validationResult.Files | Where-Object { $_.Status -eq "Invalid" }).Count
            if ($failedCount -eq 0 -and $validationResult.Files.Count -gt 0) {
                $validationResult.ValidationStatus = "Success"
            } elseif ($failedCount -lt $validationResult.Files.Count) {
                $validationResult.ValidationStatus = "PartialSuccess"
            } else {
                $validationResult.ValidationStatus = "Failed"
            }
        }
    }
    catch {
        $validationResult.ValidationStatus = "Error"
        $validationResult.Errors += $_.Exception.Message
        Write-Log "Exception during validation: $_" -Level Error
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
        Write-Log "[$jobCount/$totalJobs] Processing job: $jobName" -Level Info
        
        $job = $BackupJobs[$jobName]
        $chainInfo = Get-BackupChainInfo -Job $job
        
        # Perform validation
        $validationResult = Invoke-VeeamValidator -Job $job -ReportFormat "html"
        
        # Combine results
        $combinedResult = @{
            JobName = $jobName
            ChainInfo = $chainInfo
            ValidationResult = $validationResult
            Timestamp = Get-Date
        }
        
        $allResults += $combinedResult
        $script:ValidationResults += $combinedResult
        
        # Add delay between validations to avoid overload
        if ($jobCount -lt $totalJobs) {
            Start-Sleep -Seconds 2
        }
    }
    
    return $allResults
}

#endregion

#region Reporting Functions

function Format-FileSize {
    param([int64]$Size)
    
    if ($Size -gt 1TB) {
        return "{0:N2} TB" -f ($Size / 1TB)
    } elseif ($Size -gt 1GB) {
        return "{0:N2} GB" -f ($Size / 1GB)
    } elseif ($Size -gt 1MB) {
        return "{0:N2} MB" -f ($Size / 1MB)
    } elseif ($Size -gt 1KB) {
        return "{0:N2} KB" -f ($Size / 1KB)
    } else {
        return "$Size Bytes"
    }
}

function New-ValidationSummaryReport {
    param(
        [array]$Results
    )
    
    Write-Log "Generating HTML summary report" -Level Info
    
    $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>Veeam Backup Chain Validation Report</title>
    <meta charset="utf-8">
    <style>
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            margin: 20px;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
        }
        .container {
            max-width: 1400px;
            margin: 0 auto;
            background: white;
            border-radius: 10px;
            padding: 30px;
            box-shadow: 0 10px 40px rgba(0,0,0,0.1);
        }
        h1 {
            color: #333;
            border-bottom: 3px solid #667eea;
            padding-bottom: 10px;
        }
        h2 {
            color: #555;
            margin-top: 30px;
        }
        .summary-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 20px;
            margin: 20px 0;
        }
        .summary-card {
            background: #f8f9fa;
            padding: 20px;
            border-radius: 8px;
            text-align: center;
            border-left: 4px solid #667eea;
        }
        .summary-card h3 {
            margin: 0 0 10px 0;
            color: #666;
            font-size: 14px;
            text-transform: uppercase;
        }
        .summary-card .value {
            font-size: 32px;
            font-weight: bold;
            color: #333;
        }
        .summary-card.success { border-left-color: #28a745; }
        .summary-card.warning { border-left-color: #ffc107; }
        .summary-card.error { border-left-color: #dc3545; }
        table {
            width: 100%;
            border-collapse: collapse;
            margin: 20px 0;
        }
        th {
            background: #667eea;
            color: white;
            padding: 12px;
            text-align: left;
            font-weight: 600;
        }
        td {
            padding: 10px 12px;
            border-bottom: 1px solid #dee2e6;
        }
        tr:hover {
            background: #f8f9fa;
        }
        .status-badge {
            display: inline-block;
            padding: 4px 12px;
            border-radius: 20px;
            font-size: 12px;
            font-weight: bold;
            text-transform: uppercase;
        }
        .status-success { background: #d4edda; color: #155724; }
        .status-partial { background: #fff3cd; color: #856404; }
        .status-failed { background: #f8d7da; color: #721c24; }
        .status-error { background: #f8d7da; color: #721c24; }
        .status-notrun { background: #e9ecef; color: #495057; }
        .chain-type {
            display: inline-block;
            padding: 3px 8px;
            border-radius: 4px;
            font-size: 11px;
            font-weight: bold;
        }
        .chain-standard { background: #cfe2ff; color: #084298; }
        .chain-orphaned { background: #fff3cd; color: #664d03; }
        .chain-standalone { background: #e9ecef; color: #495057; }
        .details-section {
            margin-top: 40px;
            padding: 20px;
            background: #f8f9fa;
            border-radius: 8px;
        }
        .file-list {
            max-height: 300px;
            overflow-y: auto;
            border: 1px solid #dee2e6;
            border-radius: 4px;
            padding: 10px;
            background: white;
            margin-top: 10px;
        }
        .file-item {
            padding: 5px 0;
            border-bottom: 1px solid #f0f0f0;
            font-family: monospace;
            font-size: 12px;
        }
        .timestamp {
            color: #6c757d;
            font-size: 14px;
            margin-top: 30px;
            text-align: center;
        }
        .chart-container {
            margin: 30px 0;
            height: 300px;
        }
    </style>
    <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
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
                <div class="value">$(($Results | Where-Object { $_.ValidationResult.ValidationStatus -eq 'Success' }).Count)</div>
            </div>
            <div class="summary-card warning">
                <h3>Partial Success</h3>
                <div class="value">$(($Results | Where-Object { $_.ValidationResult.ValidationStatus -eq 'PartialSuccess' }).Count)</div>
            </div>
            <div class="summary-card error">
                <h3>Failed</h3>
                <div class="value">$(($Results | Where-Object { $_.ValidationResult.ValidationStatus -in @('Failed', 'Error') }).Count)</div>
            </div>
        </div>

        <h2>📊 Validation Results Summary</h2>
        <table>
            <thead>
                <tr>
                    <th>Job Name</th>
                    <th>Chain Type</th>
                    <th>Files</th>
                    <th>Total Size</th>
                    <th>Oldest Backup</th>
                    <th>Newest Backup</th>
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
        
        $chainClass = switch ($result.ChainInfo.ChainType) {
            'Standard' { 'chain-standard' }
            'Orphaned' { 'chain-orphaned' }
            default { 'chain-standalone' }
        }
        
        $reportLink = if ($result.ValidationResult.ReportPath -and (Test-Path $result.ValidationResult.ReportPath)) {
            "<a href='file:///$($result.ValidationResult.ReportPath -replace '\\', '/')'>View Report</a>"
        } else {
            "N/A"
        }
        
        $html += @"
                <tr>
                    <td><strong>$($result.JobName)</strong></td>
                    <td><span class="chain-type $chainClass">$($result.ChainInfo.ChainType)</span></td>
                    <td>$($result.ChainInfo.ChainLength)</td>
                    <td>$(Format-FileSize $result.ChainInfo.TotalSize)</td>
                    <td>$(if ($result.ChainInfo.OldestBackup) { $result.ChainInfo.OldestBackup.ToString('yyyy-MM-dd') } else { 'N/A' })</td>
                    <td>$(if ($result.ChainInfo.NewestBackup) { $result.ChainInfo.NewestBackup.ToString('yyyy-MM-dd') } else { 'N/A' })</td>
                    <td><span class="status-badge $statusClass">$($result.ValidationResult.ValidationStatus)</span></td>
                    <td>$([Math]::Round($result.ValidationResult.Duration, 1))s</td>
                    <td>$reportLink</td>
                </tr>
"@
    }

    $html += @"
            </tbody>
        </table>

        <h2>📈 Statistics</h2>
        <canvas id="validationChart"></canvas>

        <div class="details-section">
            <h2>📁 Datastore Information</h2>
            <p><strong>Datastore Path:</strong> $DatastorePath</p>
            <p><strong>Total Backup Jobs:</strong> $($Results.Count)</p>
            <p><strong>Total Backup Files:</strong> $(($Results | ForEach-Object { $_.ChainInfo.ChainLength } | Measure-Object -Sum).Sum)</p>
            <p><strong>Total Storage Used:</strong> $(Format-FileSize ($Results | ForEach-Object { $_.ChainInfo.TotalSize } | Measure-Object -Sum).Sum)</p>
        </div>

        <script>
            const ctx = document.getElementById('validationChart').getContext('2d');
            const statusCounts = {
                'Success': $(($Results | Where-Object { $_.ValidationResult.ValidationStatus -eq 'Success' }).Count),
                'Partial Success': $(($Results | Where-Object { $_.ValidationResult.ValidationStatus -eq 'PartialSuccess' }).Count),
                'Failed': $(($Results | Where-Object { $_.ValidationResult.ValidationStatus -eq 'Failed' }).Count),
                'Error': $(($Results | Where-Object { $_.ValidationResult.ValidationStatus -eq 'Error' }).Count),
                'Not Run': $(($Results | Where-Object { $_.ValidationResult.ValidationStatus -eq 'NotRun' }).Count)
            };

            new Chart(ctx, {
                type: 'doughnut',
                data: {
                    labels: Object.keys(statusCounts),
                    datasets: [{
                        data: Object.values(statusCounts),
                        backgroundColor: [
                            '#28a745',
                            '#ffc107',
                            '#dc3545',
                            '#6c757d',
                            '#e9ecef'
                        ]
                    }]
                },
                options: {
                    responsive: true,
                    maintainAspectRatio: false,
                    plugins: {
                        legend: {
                            position: 'right'
                        },
                        title: {
                            display: true,
                            text: 'Validation Status Distribution'
                        }
                    }
                }
            });
        </script>
    </div>
</body>
</html>
"@

    $html | Out-File -FilePath $script:SummaryReport -Encoding UTF8
    Write-Log "HTML report saved to: $script:SummaryReport" -Level Success
}

#endregion

#region Main Execution

function Show-InteractiveMenu {
    Clear-Host
    Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║         Veeam Backup Chain Validator - Main Menu            ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "1. Validate Local Datastore" -ForegroundColor White
    Write-Host "2. Validate Network Datastore (UNC Path)" -ForegroundColor White
    Write-Host "3. Validate Multiple Datastores" -ForegroundColor White
    Write-Host "4. View Last Report" -ForegroundColor White
    Write-Host "5. Settings" -ForegroundColor White
    Write-Host "Q. Quit" -ForegroundColor White
    Write-Host ""
    Write-Host "Select an option: " -NoNewline -ForegroundColor Yellow
}

function Start-ValidationWorkflow {
    # Initialize environment
    Initialize-Environment
    
    # Verify Veeam Validator is available
    if (-not (Test-ValidatorExecutable)) {
        Write-Log "Cannot proceed without Veeam Backup Validator" -Level Error
        return
    }
    
    # If no datastore path provided, show interactive menu
    if (-not $DatastorePath) {
        Show-InteractiveMenu
        $choice = Read-Host
        
        switch ($choice) {
            '1' {
                $DatastorePath = Read-Host "Enter local datastore path"
            }
            '2' {
                $DatastorePath = Read-Host "Enter UNC path (\\server\share)"
                $useCredentials = Read-Host "Use credentials? (Y/N)"
                if ($useCredentials -eq 'Y') {
                    $cred = Get-Credential -Message "Enter credentials for $DatastorePath"
                    # Map network drive temporarily
                    $null = New-PSDrive -Name "VeeamTemp" -PSProvider FileSystem -Root $DatastorePath -Credential $cred -ErrorAction Stop
                    $DatastorePath = "VeeamTemp:\"
                }
            }
            '3' {
                Write-Host "Enter datastore paths (one per line, empty line to finish):" -ForegroundColor Yellow
                $paths = @()
                while ($true) {
                    $path = Read-Host
                    if ([string]::IsNullOrWhiteSpace($path)) { break }
                    $paths += $path
                }
                
                foreach ($path in $paths) {
                    Write-Host "`nProcessing datastore: $path" -ForegroundColor Cyan
                    $script:DatastorePath = $path
                    Start-ValidationWorkflow
                }
                return
            }
            '4' {
                if (Test-Path $script:SummaryReport) {
                    Start-Process $script:SummaryReport
                } else {
                    Write-Host "No report found" -ForegroundColor Yellow
                }
                return
            }
            'Q' {
                Write-Host "Exiting..." -ForegroundColor Yellow
                return
            }
            default {
                Write-Host "Invalid selection" -ForegroundColor Red
                return
            }
        }
    }
    
    # Validate datastore path exists
    if (-not (Test-Path $DatastorePath)) {
        Write-Log "Datastore path not found: $DatastorePath" -Level Error
        return
    }
    
    # Discover backup jobs
    Write-Log "=" * 60 -Level Info
    Write-Log "Starting backup discovery..." -Level Info
    $backupJobs = Find-VeeamBackupJobs -Path $DatastorePath
    
    if ($backupJobs.Count -eq 0) {
        Write-Log "No Veeam backup jobs found in: $DatastorePath" -Level Warning
        return
    }
    
    # Validate all backup jobs
    Write-Log "=" * 60 -Level Info
    Write-Log "Starting validation of $($backupJobs.Count) backup jobs..." -Level Info
    $validationResults = Test-AllBackupJobs -BackupJobs $backupJobs
    
    # Generate summary report
    New-ValidationSummaryReport -Results $validationResults
    
    # Display summary
    Write-Log "=" * 60 -Level Info
    Write-Log "Validation Summary:" -Level Info
    Write-Log "  Total Jobs: $($validationResults.Count)" -Level Info
    Write-Log "  Successful: $(($validationResults | Where-Object { $_.ValidationResult.ValidationStatus -eq 'Success' }).Count)" -Level Success
    Write-Log "  Partial Success: $(($validationResults | Where-Object { $_.ValidationResult.ValidationStatus -eq 'PartialSuccess' }).Count)" -Level Warning
    Write-Log "  Failed: $(($validationResults | Where-Object { $_.ValidationResult.ValidationStatus -in @('Failed', 'Error') }).Count)" -Level Error
    Write-Log "=" * 60 -Level Info
    
    # Open report if not in silent mode
    if (-not $Silent) {
        Write-Host "`nWould you like to open the summary report? (Y/N): " -NoNewline -ForegroundColor Yellow
        $openReport = Read-Host
        if ($openReport -eq 'Y') {
            Start-Process $script:SummaryReport
        }
    }
    
    Write-Log "Validation complete. Reports saved to: $ReportPath" -Level Success
}

# Main entry point
Start-ValidationWorkflow

#endregion