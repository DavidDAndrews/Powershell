#Requires -RunAsAdministrator
#Requires -Modules ActiveDirectory

<#
.SYNOPSIS
    Domain Controller Demotion Script with Role Cleanup
.DESCRIPTION
    Handles DC demotion and cleanup of AD DS/DNS roles for both active and already-demoted DCs
#>

[CmdletBinding()]
param(
    [string]$DCName = $env:COMPUTERNAME,
    [string]$LogPath = "C:\Logs\DC-Demotion",
    [switch]$ForceRemoval,
    [switch]$SkipPreChecks
)

#region Initialize Variables
$script:StartTime = Get-Date
$script:LogEntries = @()
$script:PreCheckResults = @()
$script:FSMORolesFound = @()
$script:DemotionSuccess = $false
$script:DNSServerInstalled = $false
$script:DNSRemoved = $false
$script:IsRODC = $false
$script:DnsModuleAvailable = (Get-Module -ListAvailable -Name 'DnsServer') -ne $null

# Ensure log directory exists
if (-not (Test-Path $LogPath)) {
    New-Item -Path $LogPath -ItemType Directory -Force | Out-Null
}
$script:LogFile = Join-Path $LogPath "DCDemotion_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
#endregion

#region Core Functions
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("Info", "Warning", "Error", "Success")]
        [string]$Level = "Info"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"

    # Console output with colors
    switch ($Level) {
        "Info"    { Write-Host $logMessage -ForegroundColor Cyan }
        "Warning" { Write-Host $logMessage -ForegroundColor Yellow }
        "Error"   { Write-Host $logMessage -ForegroundColor Red }
        "Success" { Write-Host $logMessage -ForegroundColor Green }
    }

    # Write to log file
    Add-Content -Path $script:LogFile -Value $logMessage

    # Add to array for HTML report
    $script:LogEntries += [PSCustomObject]@{
        Timestamp = $timestamp
        Level = $Level
        Message = $Message
    }
}

function Test-DCStatus {
    param([string]$DCName)

    Write-Log "Checking domain controller status..." -Level Info

    # Check if AD DS role is installed
    try {
        $adFeature = Get-WindowsFeature -Name AD-Domain-Services -ErrorAction Stop
        if ($adFeature.InstallState -ne "Installed") {
            return [PSCustomObject]@{
                IsValid = $false
                IsDemoted = $false
                HasADDS = $false
                Message = "AD DS role not installed"
            }
        }
    } catch {
        Write-Log "Failed to check AD DS feature: $_" -Level Error
        return [PSCustomObject]@{
            IsValid = $false
            IsDemoted = $false
            HasADDS = $false
            Message = "Cannot check AD DS feature"
        }
    }

    # Check if domain joined
    $computerSystem = Get-WmiObject -Class Win32_ComputerSystem
    if ($computerSystem.PartOfDomain -eq $false) {
        return [PSCustomObject]@{
            IsValid = $false
            IsDemoted = $true
            HasADDS = $true
            Message = "Server not domain-joined but AD DS installed - likely already demoted"
        }
    }

    # Try to verify as active DC
    try {
        $dcCheck = Get-ADDomainController -Identity $DCName -ErrorAction Stop
        $script:IsRODC = $dcCheck.IsReadOnly
        return [PSCustomObject]@{
            IsValid = $true
            IsDemoted = $false
            HasADDS = $true
            Message = "Active domain controller$(if ($script:IsRODC) { ' (RODC)' } else { '' })"
        }
    } catch {
        if ($_.Exception.Message -like "*No mapping between account names and security IDs*" -or
            $_.Exception.Message -like "*Cannot find directory server*") {
            return [PSCustomObject]@{
                IsValid = $false
                IsDemoted = $true
                HasADDS = $true
                Message = "Server appears to be demoted but roles still installed"
            }
        } else {
            return [PSCustomObject]@{
                IsValid = $false
                IsDemoted = $false
                HasADDS = $true
                Message = "Cannot verify DC status: $_"
            }
        }
    }
}

function Remove-ServerRoles {
    Write-Log "`n=== Starting Role Removal ===" -Level Info

    $rolesRemoved = $false

    # Check current role status
    $adFeature = Get-WindowsFeature -Name AD-Domain-Services -ErrorAction SilentlyContinue
    $dnsFeature = Get-WindowsFeature -Name DNS -ErrorAction SilentlyContinue

    # Remove AD DS if installed
    if ($adFeature.InstallState -eq "Installed") {
        Write-Log "Removing AD DS role..." -Level Info
        try {
            $result = Remove-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools -Restart:$false -ErrorAction Stop
            if ($result.Success) {
                Write-Log "AD DS role removal initiated successfully" -Level Success
                $rolesRemoved = $true
            }
        } catch {
            Write-Log "PowerShell removal failed, trying DISM: $_" -Level Warning
            $dismResult = Start-Process -FilePath "dism.exe" `
                -ArgumentList "/online", "/disable-feature", "/featurename:DirectoryServices-DomainController", "/quiet", "/norestart" `
                -Wait -PassThru -NoNewWindow
            if ($dismResult.ExitCode -eq 0 -or $dismResult.ExitCode -eq 3010) {
                Write-Log "AD DS removal scheduled via DISM" -Level Success
                $rolesRemoved = $true
            }
        }
    }

    # Remove DNS if installed and user agrees
    if ($dnsFeature.InstallState -eq "Installed") {
        $response = Read-Host "`nRemove DNS Server role? (Y/N)"
        if ($response -eq 'Y') {
            Write-Log "Removing DNS Server role..." -Level Info
            try {
                $result = Remove-WindowsFeature -Name DNS -IncludeManagementTools -Restart:$false -ErrorAction Stop
                if ($result.Success) {
                    Write-Log "DNS Server role removal initiated successfully" -Level Success
                    $rolesRemoved = $true
                }
            } catch {
                Write-Log "PowerShell removal failed, trying DISM: $_" -Level Warning
                $dismResult = Start-Process -FilePath "dism.exe" `
                    -ArgumentList "/online", "/disable-feature", "/featurename:DNS-Server-Core-Role", "/quiet", "/norestart" `
                    -Wait -PassThru -NoNewWindow
                if ($dismResult.ExitCode -eq 0 -or $dismResult.ExitCode -eq 3010) {
                    Write-Log "DNS removal scheduled via DISM" -Level Success
                    $rolesRemoved = $true
                }
            }
        }
    }

    return $rolesRemoved
}

function Invoke-Reboot {
    $response = Read-Host "`nReboot now? (Y/N)"
    if ($response -eq 'Y') {
        Write-Log "Initiating reboot..." -Level Info
        try {
            Restart-Computer -Force -ErrorAction Stop
        } catch {
            Write-Log "Standard reboot failed, using shutdown.exe" -Level Warning
            Start-Process -FilePath "shutdown.exe" -ArgumentList "/r", "/t", "10", "/f" -NoNewWindow
            Write-Log "System will restart in 10 seconds..." -Level Info
        }
    } else {
        Write-Log "Please reboot manually to complete the process" -Level Warning
    }
}

function Generate-HTMLReport {
    param(
        [string]$ReportPath,
        [string]$DCName,
        [bool]$Success
    )

    Write-Log "Generating HTML report..." -Level Info

    # Simple HTML template
    $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>DC Demotion Report - $DCName</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; }
        h1 { color: #333; }
        .success { color: green; }
        .error { color: red; }
        .warning { color: orange; }
        .info { color: blue; }
        .log-entry { margin: 5px 0; padding: 5px; background: #f5f5f5; }
    </style>
</head>
<body>
    <h1>Domain Controller Demotion Report</h1>
    <h2>Server: $DCName</h2>
    <h3>Status: $(if ($Success) { '<span class="success">SUCCESS</span>' } else { '<span class="error">FAILED</span>' })</h3>
    <h3>Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</h3>
    <hr>
    <h3>Log Entries:</h3>
    <div class="log-container">
"@

    foreach ($entry in $script:LogEntries) {
        $class = $entry.Level.ToLower()
        $html += "<div class='log-entry $class'>[$($entry.Timestamp)] [$($entry.Level)] $($entry.Message)</div>`n"
    }

    $html += @"
    </div>
</body>
</html>
"@

    $html | Out-File -FilePath $ReportPath -Encoding UTF8
    Write-Log "Report saved to: $ReportPath" -Level Success
}
#endregion

#region Main Execution
Write-Log "=== Starting Domain Controller Demotion Process ===" -Level Info
Write-Log "Target DC: $DCName" -Level Info
Write-Log "Force Removal: $ForceRemoval" -Level Info

# Check DC Status
$dcStatus = Test-DCStatus -DCName $DCName

if ($dcStatus.IsDemoted -and $dcStatus.HasADDS) {
    # Server is already demoted but has roles
    Write-Log "Server appears to be already demoted but still has AD DS/DNS roles installed" -Level Warning

    $response = Read-Host "`nWould you like to remove the remaining roles? (Y/N)"
    if ($response -eq 'Y') {
        $rolesRemoved = Remove-ServerRoles
        if ($rolesRemoved) {
            Write-Log "Role removal completed. A reboot is required." -Level Success
            $script:DemotionSuccess = $true
            Invoke-Reboot
        }
    }
} elseif ($dcStatus.IsValid) {
    # Active DC - proceed with demotion
    if (-not $SkipPreChecks) {
        Write-Log "Running pre-demotion checks..." -Level Info
        # Add your pre-demotion checks here
    }

    Write-Log "Starting demotion process..." -Level Info

    # Get local admin password
    Write-Log "Please set the local Administrator password:" -Level Info
    $localAdminPwd = Read-Host -AsSecureString "Enter new local Administrator password"
    $confirmPwd = Read-Host -AsSecureString "Confirm password"

    # Verify passwords match
    $pwd1 = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($localAdminPwd))
    $pwd2 = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($confirmPwd))

    if ($pwd1 -ne $pwd2) {
        Write-Log "Passwords do not match!" -Level Error
        exit 1
    }

    try {
        # Perform demotion
        if ($ForceRemoval) {
            Uninstall-ADDSDomainController `
                -LocalAdministratorPassword $localAdminPwd `
                -Force:$true `
                -ForceRemoval:$true `
                -NoRebootOnCompletion:$true `
                -ErrorAction Stop
        } else {
            $cred = Get-Credential -Message "Enter Domain Admin credentials"
            Uninstall-ADDSDomainController `
                -Credential $cred `
                -LocalAdministratorPassword $localAdminPwd `
                -Force:$true `
                -NoRebootOnCompletion:$true `
                -ErrorAction Stop
        }

        Write-Log "Demotion completed successfully" -Level Success

        # Remove roles after demotion
        Start-Sleep -Seconds 10
        $rolesRemoved = Remove-ServerRoles

        if ($rolesRemoved) {
            $script:DemotionSuccess = $true
            Invoke-Reboot
        }

    } catch {
        Write-Log "Demotion failed: $_" -Level Error
        $script:DemotionSuccess = $false
    }
} else {
    # Not a valid DC
    Write-Log $dcStatus.Message -Level Error
    Write-Log "Cannot proceed with demotion" -Level Error
}

# Generate report
$reportPath = Join-Path "C:\Logs" "DC_Demotion_Report_$(Get-Date -Format 'yyyyMMdd_HHmmss').html"
if (-not (Test-Path "C:\Logs")) {
    New-Item -Path "C:\Logs" -ItemType Directory -Force | Out-Null
}

Generate-HTMLReport -ReportPath $reportPath -DCName $DCName -Success $script:DemotionSuccess
Start-Process $reportPath

Write-Log "=== Process Complete ===" -Level Info
#endregion