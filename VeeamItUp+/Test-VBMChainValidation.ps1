# Test script for VBM chain validation

# Function to parse VBM metadata and validate backup chains
function Parse-VBMMetadata {
    param(
        [string]$VBMFilePath,
        [string]$BackupDirectory
    )
    
    $result = @{
        Storages = @()
        ChainValidation = @{
            IsValid = $true
            BrokenChains = @()
            MissingFiles = @()
            OrphanedIncrementals = @()
            Issues = @()
        }
    }
    
    if (-not (Test-Path $VBMFilePath)) {
        Write-Host "⚠️ VBM file not found: $VBMFilePath" -ForegroundColor Yellow
        return $result
    }
    
    try {
        Write-Host "📄 Parsing VBM metadata: $VBMFilePath" -ForegroundColor Cyan
        
        # Load VBM XML content
        $vbmContent = Get-Content $VBMFilePath -Raw
        
        # Extract all Storage elements
        $storagePattern = '<Storage[^>]+/>'
        $storageMatches = [regex]::Matches($vbmContent, $storagePattern)
        
        Write-Host "  Found $($storageMatches.Count) storage entries in VBM" -ForegroundColor Gray
        
        $storageById = @{}
        
        foreach ($match in $storageMatches) {
            $storageXml = $match.Value
            
            # Extract attributes
            $storage = @{
                Id = if ($storageXml -match 'Id="([^"]+)"') { $matches[1] } else { "" }
                FilePath = if ($storageXml -match 'FilePath="([^"]+)"') { $matches[1] } else { "" }
                LinkId = if ($storageXml -match 'LinkId="([^"]+)"') { $matches[1] } else { "" }
                CreationTime = if ($storageXml -match 'CreationTime="([^"]+)"') { $matches[1] } else { "" }
                Stats = if ($storageXml -match 'Stats="([^"]+)"') { $matches[1] } else { "" }
                State = if ($storageXml -match 'State="([^"]+)"') { $matches[1] } else { "1" }
                IsCorrupted = if ($storageXml -match 'IsCorrupted="([^"]+)"') { $matches[1] } else { "False" }
                Type = ""
                FileExists = $false
                ActualSize = 0
                ExpectedSize = 0
                ChainStatus = "Valid"
                ChainIssues = @()
            }
            
            # Determine backup type from file extension
            if ($storage.FilePath -match '\.vbk$') {
                $storage.Type = "Full"
            } elseif ($storage.FilePath -match '\.vib$') {
                $storage.Type = "Incremental"
            } else {
                $storage.Type = "Unknown"
            }
            
            # Parse stats to get file size
            if ($storage.Stats) {
                $statsXml = $storage.Stats -replace '&lt;', '<' -replace '&gt;', '>' -replace '&quot;', '"' -replace '&amp;', '&'
                if ($statsXml -match '<BackupSize>(\d+)</BackupSize>') {
                    $storage.ExpectedSize = [int64]$matches[1]
                }
            }
            
            # Check if file exists on disk
            # The VBM contains paths like D:\Backup\DC01\filename.vbk
            # We need to check in the actual backup directory, not the original path
            $fileName = Split-Path -Leaf $storage.FilePath
            $fullPath = Join-Path $BackupDirectory $fileName
            
            # Also try the original path if it's absolute
            $originalPath = $storage.FilePath
            
            if (Test-Path $fullPath) {
                $storage.FileExists = $true
                $fileInfo = Get-Item $fullPath
                $storage.ActualSize = $fileInfo.Length
                Write-Host "      ✅ File found: $fileName" -ForegroundColor Green
            } elseif ([System.IO.Path]::IsPathRooted($originalPath) -and (Test-Path $originalPath)) {
                # Try the original absolute path
                $storage.FileExists = $true
                $fileInfo = Get-Item $originalPath
                $storage.ActualSize = $fileInfo.Length
                Write-Host "      ✅ File found at original path: $originalPath" -ForegroundColor Green
                
            }
            
            # Check size mismatch if file was found
            if ($storage.FileExists -and $storage.ExpectedSize -gt 0) {
                $sizeDiff = [Math]::Abs($storage.ActualSize - $storage.ExpectedSize)
                if ($sizeDiff -gt 1048576) {
                    $storage.ChainIssues += "SIZE_MISMATCH"
                }
            } else {
                $storage.FileExists = $false
                $storage.ChainStatus = "Critical"
                $storage.ChainIssues += "FILE_MISSING"
                $result.ChainValidation.MissingFiles += @{
                    Id = $storage.Id
                    FilePath = $storage.FilePath
                }
                Write-Host "      ⚠️ File not found: $fileName (checked: $fullPath)" -ForegroundColor Yellow
            }
            
            # Check corruption flag
            if ($storage.IsCorrupted -eq "True") {
                $storage.ChainStatus = "Critical"
                $storage.ChainIssues += "CORRUPTED"
            }
            
            $storageById[$storage.Id] = $storage
            $result.Storages += $storage
        }
        
        # Validate backup chains
        Write-Host "  Validating backup chains..." -ForegroundColor Cyan
        
        $hasFullBackup = $false
        
        foreach ($storage in $result.Storages) {
            if ($storage.Type -eq "Full") {
                $hasFullBackup = $true
                
                # Full backups should not have LinkId
                if ($storage.LinkId) {
                    $storage.ChainStatus = "Warning"
                    $storage.ChainIssues += "FULL_WITH_LINKID"
                }
            } elseif ($storage.Type -eq "Incremental") {
                # Incremental must have LinkId
                if (-not $storage.LinkId) {
                    $storage.ChainStatus = "Critical"
                    $storage.ChainIssues += "ORPHANED_NO_LINK"
                    $result.ChainValidation.OrphanedIncrementals += @{
                        Id = $storage.Id
                        FilePath = $storage.FilePath
                    }
                } else {
                    # Check if parent exists
                    if (-not $storageById.ContainsKey($storage.LinkId)) {
                        $storage.ChainStatus = "Critical"
                        $storage.ChainIssues += "BROKEN_CHAIN_PARENT_MISSING"
                        $result.ChainValidation.BrokenChains += @{
                            Id = $storage.Id
                            FilePath = $storage.FilePath
                            MissingParentId = $storage.LinkId
                        }
                    } else {
                        # Check if parent is healthy
                        $parent = $storageById[$storage.LinkId]
                        if ($parent.ChainStatus -eq "Critical") {
                            $storage.ChainStatus = "Critical"
                            $storage.ChainIssues += "PARENT_UNHEALTHY"
                        }
                    }
                }
            }
        }
        
        # Check for no full backup
        if (-not $hasFullBackup -and $result.Storages.Count -gt 0) {
            $result.ChainValidation.IsValid = $false
            $result.ChainValidation.Issues += "NO_FULL_BACKUP"
            Write-Host "  ❌ CRITICAL: No full backup found in chain!" -ForegroundColor Red
        }
        
        # Determine overall chain health
        $criticalCount = ($result.Storages | Where-Object { $_.ChainStatus -eq "Critical" }).Count
        if ($criticalCount -gt 0) {
            $result.ChainValidation.IsValid = $false
            $result.ChainValidation.Issues += "$criticalCount backups with critical issues"
            Write-Host "  ❌ Chain validation FAILED: $criticalCount critical issues found" -ForegroundColor Red
        } else {
            Write-Host "  ✅ Chain validation PASSED" -ForegroundColor Green
        }
        
    } catch {
        Write-Host "❌ Error parsing VBM file: $_" -ForegroundColor Red
        $result.ChainValidation.IsValid = $false
        $result.ChainValidation.Issues += "Parse error: $_"
    }
    
    return $result
}

# Test the function
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  VBM Chain Validation Test" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$vbmResult = Parse-VBMMetadata -VBMFilePath './DC01.vbm' -BackupDirectory './'

Write-Host ""
Write-Host "VBM Parsing Results:" -ForegroundColor Yellow
Write-Host "-------------------"
Write-Host "Total Storages: $($vbmResult.Storages.Count)"
Write-Host "Chain Valid: $($vbmResult.ChainValidation.IsValid)"
Write-Host "Missing Files: $($vbmResult.ChainValidation.MissingFiles.Count)"
Write-Host "Broken Chains: $($vbmResult.ChainValidation.BrokenChains.Count)"
Write-Host "Orphaned Incrementals: $($vbmResult.ChainValidation.OrphanedIncrementals.Count)"

if ($vbmResult.ChainValidation.Issues.Count -gt 0) {
    Write-Host ""
    Write-Host "Chain Issues:" -ForegroundColor Red
    foreach ($issue in $vbmResult.ChainValidation.Issues) {
        Write-Host "  - $issue"
    }
}

Write-Host ""
Write-Host "Storage Details:" -ForegroundColor Yellow
Write-Host "---------------"
$storageNum = 1
foreach ($storage in $vbmResult.Storages) {
    $fileName = Split-Path -Leaf $storage.FilePath
    
    $statusColor = switch ($storage.ChainStatus) {
        "Critical" { "Red" }
        "Warning" { "Yellow" }
        default { "Green" }
    }
    
    Write-Host ""
    Write-Host "[$storageNum] File: $fileName" -ForegroundColor White
    Write-Host "    Type: $($storage.Type)"
    Write-Host "    Status: $($storage.ChainStatus)" -ForegroundColor $statusColor
    
    if ($storage.LinkId) {
        Write-Host "    LinkId: $($storage.LinkId.Substring(0, [Math]::Min(8, $storage.LinkId.Length)))..."
    }
    
    if ($storage.ChainIssues.Count -gt 0) {
        Write-Host "    Issues: $($storage.ChainIssues -join ', ')" -ForegroundColor Red
    }
    
    $storageNum++
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Test Complete" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan