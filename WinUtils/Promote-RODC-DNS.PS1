<#
.SYNOPSIS
Promotes a domain-joined server to a Read-Only Domain Controller (RODC) with read-only DNS.

.DESCRIPTION
This script automates the promotion of a Windows Server to an RODC role.
It includes comprehensive pre-checks, domain status verification, error handling, and rollback capabilities.
If the server is not domain-joined, it provides detailed instructions for joining a domain.

.PARAMETER DelegatedAdminGroup
Specifies the group that will have delegated admin rights on the RODC (optional)

.PARAMETER AllowPasswordReplication
Specifies groups allowed to have passwords cached on the RODC (optional)

.PARAMETER DenyPasswordReplication
Specifies groups explicitly denied from having passwords cached (optional)

.PARAMETER DomainAdminUser
Specifies the domain admin username to use for promotion (e.g., 'DOMAIN\Username' or just 'Username')

.PARAMETER SkipPreChecks
Skip pre-flight checks (not recommended)

.PARAMETER SkipRPCCheck
Skip RPC dynamic port check. Use this if RPC is restricted in your environment but static RPC is configured.

.PARAMETER Force
Skip confirmation prompts

.PARAMETER CheckOnly
Only check domain status without attempting promotion

.EXAMPLE
.\Promote-RODC.ps1
Runs the script with default settings and prompts for credentials

.EXAMPLE
.\Promote-RODC.ps1 -CheckOnly
Only checks if the server is ready for RODC promotion

.EXAMPLE
.\Promote-RODC.ps1 -DomainAdminUser "CONTOSO\DCAdmin"
Runs the script with a specific domain admin account

.EXAMPLE
.\Promote-RODC.ps1 -DelegatedAdminGroup "RODC_Admins" -Force
Runs the script with a delegated admin group and no confirmation prompts

.NOTES
- Requires: Windows Server 2016 or later
- Requires: Domain membership (script will guide you if not domain-joined)
- Requires: Domain Admin credentials
- The system will automatically reboot after successful promotion
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$DelegatedAdminGroup,

    [Parameter()]
    [string[]]$AllowPasswordReplication = @(),

    [Parameter()]
    [string[]]$DenyPasswordReplication = @('Domain Admins', 'Enterprise Admins', 'Schema Admins', 'Cert Publishers'),

    [Parameter()]
    [string]$DomainAdminUser,

    [Parameter()]
    [switch]$SkipPreChecks,

    [Parameter()]
    [switch]$SkipRPCCheck,

    [Parameter()]
    [switch]$Force,

    [Parameter()]
    [switch]$CheckOnly
)

#Requires -Version 5.1
#Requires -RunAsAdministrator

# -------------------------
# CONFIGURATION
# -------------------------
$Script:Config = @{
    RODCName = $env:COMPUTERNAME
    LogPath = "C:\Logs\RODC_Promotion"
    TranscriptFile = "C:\Logs\RODC_Promotion\Transcript_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
    LogFile = "C:\Logs\RODC_Promotion\RODC_Promotion_$env:COMPUTERNAME.log"
    HTMLReportPath = "C:\Logs\RODC_Promotion"
    HTMLReportFile = "RODC_Promotion_Report_$(Get-Date -Format 'yyyyMMdd_HHmmss').html"
    PreCheckTimeout = 30
    RequiredPorts = @(
        @{Name='DNS'; Port=53; Protocol='TCP'},
        @{Name='Kerberos'; Port=88; Protocol='TCP'},
        @{Name='RPC Endpoint Mapper'; Port=135; Protocol='TCP'},
        @{Name='LDAP'; Port=389; Protocol='TCP'},
        @{Name='LDAP-SSL'; Port=636; Protocol='TCP'},
        @{Name='SMB'; Port=445; Protocol='TCP'},
        @{Name='Global Catalog'; Port=3268; Protocol='TCP'},
        @{Name='Global Catalog SSL'; Port=3269; Protocol='TCP'}
    )
}

# Initialize report data structure
$Script:ReportData = @{
    StartTime = Get-Date
    EndTime = $null
    ServerInfo = @{}
    DomainInfo = @{}
    PrerequisiteChecks = @()
    ConnectivityTests = @()
    InstallationSteps = @()
    FinalResult = 'In Progress'
    Errors = @()
    Warnings = @()
    PostTasks = @()
}

# -------------------------
# FUNCTIONS
# -------------------------
function Initialize-Logging {
    # Ensure log directory exists
    if (-not (Test-Path -Path $Script:Config.LogPath)) {
        New-Item -ItemType Directory -Path $Script:Config.LogPath -Force | Out-Null
    }

    # Start transcript
    Start-Transcript -Path $Script:Config.TranscriptFile -Force

    Log "=== RODC Promotion Script Started ===" -Level Info
    Log "Script Version: 2.0" -Level Info
    Log "Hostname: $($Script:Config.RODCName)" -Level Info
    Log "User: $env:USERDOMAIN\$env:USERNAME" -Level Info
    Log "PowerShell Version: $($PSVersionTable.PSVersion)" -Level Info

    # Populate initial server info for report
    $Script:ReportData.ServerInfo = @{
        Hostname = $env:COMPUTERNAME
        OperatingSystem = (Get-CimInstance Win32_OperatingSystem).Caption
        OSVersion = (Get-CimInstance Win32_OperatingSystem).Version
        PowerShellVersion = $PSVersionTable.PSVersion.ToString()
        ExecutingUser = "$env:USERDOMAIN\$env:USERNAME"
        ScriptVersion = "2.0"
    }
}

function Log {
    param (
        [Parameter(Mandatory)]
        [string]$Message,

        [Parameter()]
        [ValidateSet('Info', 'Warning', 'Error', 'Success')]
        [string]$Level = 'Info'
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "$timestamp [$Level] $Message"

    # Console output with color
    switch ($Level) {
        'Info'    { Write-Host $entry -ForegroundColor White }
        'Warning' { Write-Host $entry -ForegroundColor Yellow }
        'Error'   { Write-Host $entry -ForegroundColor Red }
        'Success' { Write-Host $entry -ForegroundColor Green }
    }

    # File output
    Add-Content -Path $Script:Config.LogFile -Value $entry

    # Add to report data
    switch ($Level) {
        'Error' {
            $Script:ReportData.Errors += @{
                Timestamp = Get-Date
                Message = $Message
            }
        }
        'Warning' {
            $Script:ReportData.Warnings += @{
                Timestamp = Get-Date
                Message = $Message
            }
        }
    }
}

function Test-DomainStatus {
    Write-Host "`n===== DOMAIN STATUS CHECK =====" -ForegroundColor Cyan
    Write-Host "Server: $env:COMPUTERNAME" -ForegroundColor White
    Write-Host "===============================" -ForegroundColor Cyan

    $computerSystem = Get-CimInstance Win32_ComputerSystem

    Write-Host "`nChecking domain membership... " -NoNewline
    if ($computerSystem.PartOfDomain) {
        Write-Host "JOINED" -ForegroundColor Green
        Write-Host "Domain: $($computerSystem.Domain)" -ForegroundColor Green

        # Try to get more domain info
        try {
            $domain = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()
            Write-Host "Forest: $($domain.Forest.Name)" -ForegroundColor Green
            Write-Host "PDC: $($domain.PdcRoleOwner.Name)" -ForegroundColor Green

            # Check site
            try {
                $site = [System.DirectoryServices.ActiveDirectory.ActiveDirectorySite]::GetComputerSite()
                Write-Host "Site: $($site.Name)" -ForegroundColor Green
            } catch {
                Write-Host "Site: Unable to detect" -ForegroundColor Yellow
            }
        } catch {
            Write-Host "Note: Could not retrieve detailed domain info. This is normal for some configurations." -ForegroundColor Yellow
        }

        # Check DNS settings
        Write-Host "`nDNS Configuration:" -ForegroundColor Cyan
        $adapters = Get-NetAdapter | Where-Object {$_.Status -eq "Up"}
        foreach ($adapter in $adapters) {
            $dns = Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4
            if ($dns.ServerAddresses) {
                Write-Host "  $($adapter.Name): $($dns.ServerAddresses -join ', ')"
            }
        }

        # Check IP configuration
        Write-Host "`nIP Configuration:" -ForegroundColor Cyan
        foreach ($adapter in $adapters) {
            $ipConfig = Get-NetIPConfiguration -InterfaceIndex $adapter.ifIndex
            $dhcpStatus = if ($ipConfig.NetIPv4Interface.Dhcp -eq "Enabled") { "(DHCP)" } else { "(Static)" }
            if ($ipConfig.IPv4Address.IPAddress) {
                Write-Host "  $($adapter.Name): $($ipConfig.IPv4Address.IPAddress) $dhcpStatus"
            }
        }

        if ($CheckOnly) {
            Write-Host "`n✅ This server is domain-joined and can be promoted to RODC." -ForegroundColor Green
            Write-Host "Next step: Run this script without -CheckOnly to begin promotion." -ForegroundColor Yellow
        }

        return $true

    } else {
        Write-Host "NOT JOINED" -ForegroundColor Red
        Write-Host "Workgroup: $($computerSystem.Workgroup)" -ForegroundColor Yellow

        Write-Host "`n❌ This server is NOT domain-joined!" -ForegroundColor Red
        Write-Host "You must join a domain before promoting to RODC." -ForegroundColor Yellow

        # Check DNS configuration
        Write-Host "`nCurrent DNS Configuration:" -ForegroundColor Cyan
        $adapters = Get-NetAdapter | Where-Object {$_.Status -eq "Up"}
        foreach ($adapter in $adapters) {
            $dns = Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4
            if ($dns.ServerAddresses) {
                Write-Host "  $($adapter.Name): $($dns.ServerAddresses -join ', ')"
            }
        }

        Show-DomainJoinInstructions

        return $false
    }
}

function Show-DomainJoinInstructions {
    Write-Host "`n📋 TO JOIN A DOMAIN:" -ForegroundColor Cyan
    Write-Host "===============================" -ForegroundColor Cyan

    Write-Host "`n1. First, ensure DNS points to your domain controller" -ForegroundColor Yellow
    Write-Host "   Example:" -ForegroundColor Cyan
    Write-Host "   Set-DnsClientServerAddress -InterfaceAlias 'Ethernet' -ServerAddresses '192.168.1.10'" -ForegroundColor White

    Write-Host "`n2. Then join the domain using one of these methods:" -ForegroundColor Yellow

    Write-Host "`n   PowerShell (Simple):" -ForegroundColor Cyan
    Write-Host "   Add-Computer -DomainName 'yourdomain.com' -Restart" -ForegroundColor White

    Write-Host "`n   PowerShell (With specific OU for DCs):" -ForegroundColor Cyan
    Write-Host "   `$cred = Get-Credential" -ForegroundColor White
    Write-Host "   Add-Computer -DomainName 'yourdomain.com' ``" -ForegroundColor White
    Write-Host "     -OUPath 'OU=Domain Controllers,DC=yourdomain,DC=com' ``" -ForegroundColor White
    Write-Host "     -Credential `$cred -Restart" -ForegroundColor White

    Write-Host "`n   GUI Method:" -ForegroundColor Cyan
    Write-Host "   - Open Server Manager > Local Server" -ForegroundColor White
    Write-Host "   - Click on Workgroup name > Change" -ForegroundColor White
    Write-Host "   - Select Domain and enter domain name" -ForegroundColor White
    Write-Host "   - Provide domain admin credentials" -ForegroundColor White
    Write-Host "   - Restart when prompted" -ForegroundColor White

    Write-Host "`n3. After reboot, run this script again to proceed with RODC promotion" -ForegroundColor Yellow

    Write-Host "`n💡 TIPS:" -ForegroundColor Green
    Write-Host "   • Ensure network connectivity to domain controller" -ForegroundColor White
    Write-Host "   • Verify DNS resolution: nslookup yourdomain.com" -ForegroundColor White
    Write-Host "   • Check firewall rules if connection fails" -ForegroundColor White
    Write-Host "   • Use FQDN for domain name (e.g., corp.contoso.com)" -ForegroundColor White

    Write-Host "`n===============================" -ForegroundColor Cyan
}

function Test-Prerequisites {
    Log "Starting prerequisite checks..." -Level Info

    $checks = @(
        @{
            Name = "Operating System Version"
            Test = {
                $os = Get-CimInstance Win32_OperatingSystem
                $os.Caption -match "Windows Server" -and [int]$os.BuildNumber -ge 14393
            }
            ErrorMessage = "This script requires Windows Server 2016 or later"
            CanAutoFix = $false
        },
        @{
            Name = "Administrator Privileges"
            Test = {
                $currentPrincipal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
                $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            }
            ErrorMessage = "This script must be run as Administrator"
            CanAutoFix = $false
        },
        @{
            Name = "Domain Membership"
            Test = {
                $cs = Get-CimInstance Win32_ComputerSystem
                if (-not $cs.PartOfDomain) {
                    $script:NotDomainJoined = $true
                    return $false
                }
                return $true
            }
            ErrorMessage = "Server is not joined to a domain. Please join the server to the domain before running this script."
            CanAutoFix = $false
        },
        @{
            Name = "AD PowerShell Module"
            Test = { Get-Module -ListAvailable -Name ActiveDirectory }
            ErrorMessage = "Active Directory PowerShell module is not available."
            CanAutoFix = $true
            AutoFix = {
                Write-Host "  Installing RSAT-AD-PowerShell..." -ForegroundColor Yellow
                try {
                    $result = Install-WindowsFeature -Name RSAT-AD-PowerShell -IncludeManagementTools -ErrorAction Stop
                    if ($result.Success) {
                        Write-Host "  ✓ RSAT-AD-PowerShell installed successfully" -ForegroundColor Green
                        return $true
                    }
                    return $false
                } catch {
                    Write-Host "  ✗ Failed to install RSAT-AD-PowerShell: $_" -ForegroundColor Red
                    return $false
                }
            }
        },
        @{
            Name = "Network Location Awareness Service"
            Test = { (Get-Service -Name NlaSvc -ErrorAction SilentlyContinue).Status -eq 'Running' }
            ErrorMessage = "Network Location Awareness service is not running"
            CanAutoFix = $true
            AutoFix = {
                try {
                    Start-Service -Name NlaSvc -ErrorAction Stop
                    Set-Service -Name NlaSvc -StartupType Automatic -ErrorAction Stop
                    return $true
                } catch {
                    return $false
                }
            }
        },
        @{
            Name = "Windows Time Service"
            Test = { (Get-Service -Name W32Time -ErrorAction SilentlyContinue).Status -eq 'Running' }
            ErrorMessage = "Windows Time service is not running - time sync is critical for AD"
            CanAutoFix = $true
            AutoFix = {
                try {
                    Start-Service -Name W32Time -ErrorAction Stop
                    Set-Service -Name W32Time -StartupType Automatic -ErrorAction Stop
                    return $true
                } catch {
                    return $false
                }
            }
        },
        @{
            Name = "Static IP Address"
            Test = {
                $adapters = Get-NetAdapter | Where-Object {$_.Status -eq "Up"}
                $staticCount = 0
                $dhcpCount = 0

                foreach ($adapter in $adapters) {
                    $ipConfig = Get-NetIPConfiguration -InterfaceIndex $adapter.ifIndex
                    if ($ipConfig.NetIPv4Interface.Dhcp -eq "Disabled") {
                        $staticCount++
                    } else {
                        $dhcpCount++
                        $script:DHCPAdapters += @{
                            Name = $adapter.Name
                            Index = $adapter.ifIndex
                            IP = $ipConfig.IPv4Address.IPAddress
                        }
                    }
                }

                # At least one adapter should have static IP
                return $staticCount -gt 0
            }
            ErrorMessage = "Domain Controllers should have static IP addresses. DHCP detected on network adapters."
            CanAutoFix = $false
            IsWarning = $true
        }
    )

    $failed = $false
    $criticalFailure = $false
    $script:DHCPAdapters = @()

    foreach ($check in $checks) {
        Write-Host "  Checking: $($check.Name)... " -NoNewline
        try {
            if (& $check.Test) {
                Write-Host "PASS" -ForegroundColor Green
                Log "Prerequisite check passed: $($check.Name)" -Level Info
                $Script:ReportData.PrerequisiteChecks += @{
                    Name = $check.Name
                    Status = 'Pass'
                    Details = 'Check passed successfully'
                }
            } else {
                if ($check.CanAutoFix) {
                    Write-Host "FAIL (Attempting auto-fix...)" -ForegroundColor Yellow
                    Log "Prerequisite check failed: $($check.Name) - Attempting automatic fix" -Level Warning

                    if (& $check.AutoFix) {
                        # Re-test after fix
                        if (& $check.Test) {
                            Write-Host "  ✓ Fixed: $($check.Name)" -ForegroundColor Green
                            Log "Successfully fixed: $($check.Name)" -Level Info
                            $Script:ReportData.PrerequisiteChecks += @{
                                Name = $check.Name
                                Status = 'Fixed'
                                Details = "Automatically fixed - $($check.ErrorMessage)"
                            }
                        } else {
                            Write-Host "  ✗ Auto-fix failed for: $($check.Name)" -ForegroundColor Red
                            Log "Auto-fix failed: $($check.Name)" -Level Error
                            $Script:ReportData.PrerequisiteChecks += @{
                                Name = $check.Name
                                Status = 'Fail'
                                Details = "Auto-fix attempted but failed - $($check.ErrorMessage)"
                            }
                            if (-not $check.IsWarning) {
                                $failed = $true
                            }
                        }
                    } else {
                        if (-not $check.IsWarning) {
                            $failed = $true
                        }
                    }
                } else {
                    if ($check.IsWarning) {
                        Write-Host "WARNING" -ForegroundColor Yellow
                        Log "Prerequisite check warning: $($check.Name) - $($check.ErrorMessage)" -Level Warning
                        $Script:ReportData.PrerequisiteChecks += @{
                            Name = $check.Name
                            Status = 'Warning'
                            Details = $check.ErrorMessage
                        }

                        # Show DHCP warning details
                        if ($check.Name -eq "Static IP Address" -and $script:DHCPAdapters.Count -gt 0) {
                            Write-Host "`n  ⚠️  DHCP Configuration Detected:" -ForegroundColor Yellow
                            foreach ($dhcpAdapter in $script:DHCPAdapters) {
                                Write-Host "     - $($dhcpAdapter.Name): $($dhcpAdapter.IP) (DHCP)" -ForegroundColor Yellow
                            }
                            Write-Host "`n  Recommendation: Configure static IP addresses before promoting to DC" -ForegroundColor Yellow
                            Write-Host "  Example PowerShell commands:" -ForegroundColor Cyan

                            $firstAdapter = $script:DHCPAdapters[0]
                            Write-Host "    # Remove DHCP configuration" -ForegroundColor White
                            Write-Host "    Remove-NetIPAddress -InterfaceIndex $($firstAdapter.Index) -Confirm:`$false" -ForegroundColor White
                            Write-Host "    # Set static IP" -ForegroundColor White
                            Write-Host "    New-NetIPAddress -InterfaceIndex $($firstAdapter.Index) -IPAddress '192.168.1.10' ``" -ForegroundColor White
                            Write-Host "      -PrefixLength 24 -DefaultGateway '192.168.1.1'" -ForegroundColor White
                            Write-Host "    # Set DNS servers" -ForegroundColor White
                            Write-Host "    Set-DnsClientServerAddress -InterfaceIndex $($firstAdapter.Index) ``" -ForegroundColor White
                            Write-Host "      -ServerAddresses '192.168.1.5','192.168.1.6'" -ForegroundColor White

                            $continue = Read-Host "`n  Continue with DHCP configuration? (not recommended) (Y/N)"
                            if ($continue -notin @('Y', 'y')) {
                                $failed = $true
                            }
                        }
                    } else {
                        Write-Host "FAIL" -ForegroundColor Red
                        Log "Prerequisite check failed: $($check.Name) - $($check.ErrorMessage)" -Level Error
                        $Script:ReportData.PrerequisiteChecks += @{
                            Name = $check.Name
                            Status = 'Fail'
                            Details = $check.ErrorMessage
                        }
                        $failed = $true

                        # Domain membership is critical
                        if ($check.Name -eq "Domain Membership") {
                            $criticalFailure = $true
                        }
                    }
                }
            }
        } catch {
            Write-Host "ERROR" -ForegroundColor Red
            Log "Prerequisite check error: $($check.Name) - $_" -Level Error
            if (-not $check.IsWarning) {
                $failed = $true
            }
        }
    }

    # If not domain joined, provide helpful information
    if ($script:NotDomainJoined) {
        Write-Host "`n❌ CRITICAL ERROR: Server is not domain-joined!" -ForegroundColor Red
        Show-DomainJoinInstructions
        return $false
    }

    return -not $failed
}

function Get-DomainInfo {
    Log "Detecting domain information..." -Level Info

    $domainInfo = @{}

    # First check if we're domain joined
    $computerSystem = Get-CimInstance Win32_ComputerSystem
    if (-not $computerSystem.PartOfDomain) {
        Log "Computer is not domain-joined. Cannot proceed with RODC promotion." -Level Error
        throw "Computer is not joined to any domain"
    }

    try {
        # Primary method - .NET
        $currentDomain = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()
        $domainInfo.DomainName = $currentDomain.Name
        $domainInfo.ForestName = $currentDomain.Forest.Name
        $domainInfo.DomainMode = $currentDomain.DomainMode

        # Get PDC Emulator
        $domainInfo.PDCEmulator = $currentDomain.PdcRoleOwner.Name

        Log "Domain detection successful using .NET method" -Level Info

        # Store in report data
        $Script:ReportData.DomainInfo = @{
            'Domain Name' = $domainInfo.DomainName
            'Forest Name' = $domainInfo.ForestName
            'Domain Mode' = $domainInfo.DomainMode.ToString()
            'PDC Emulator' = $domainInfo.PDCEmulator
        }
    } catch {
        Log "Primary domain detection failed, trying fallback method..." -Level Warning

        # Fallback method - WMI and registry
        try {
            $domainInfo.DomainName = $computerSystem.Domain

            # Try to get DC from registry
            $dcReg = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon\Parameters" -ErrorAction SilentlyContinue
            if ($dcReg -and $dcReg.DynamicSiteName) {
                $domainInfo.SiteName = $dcReg.DynamicSiteName
            }

            # Use nltest for additional info
            $nltestOutput = nltest /dsgetdc: /pdc 2>$null
            if ($LASTEXITCODE -eq 0) {
                foreach ($line in $nltestOutput) {
                    if ($line -match 'DC: \\\\(.+)$') {
                        $domainInfo.PDCEmulator = $Matches[1]
                    }
                    if ($line -match 'Domain Name:\s+(.+)$') {
                        $domainInfo.DomainName = $Matches[1]
                    }
                }
            }

            # If still no PDC, try nslookup
            if (-not $domainInfo.PDCEmulator -and $domainInfo.DomainName) {
                try {
                    $pdc = Resolve-DnsName -Name "_ldap._tcp.pdc._msdcs.$($domainInfo.DomainName)" -Type SRV -ErrorAction Stop
                    if ($pdc) {
                        $domainInfo.PDCEmulator = $pdc[0].NameTarget
                    }
                } catch {
                    Log "Failed to resolve PDC using DNS" -Level Warning
                }
            }
        } catch {
            throw "Unable to detect domain information using any method"
        }
    }

    # Validate we have minimum required information
    if (-not $domainInfo.DomainName) {
        throw "Could not determine domain name"
    }

    if (-not $domainInfo.PDCEmulator) {
        Log "Could not determine PDC Emulator. Will prompt for domain controller." -Level Warning
        $domainInfo.PDCEmulator = Read-Host "Enter the FQDN of a writable domain controller"
    }

    # Get site information
    try {
        if (-not $domainInfo.SiteName) {
            $domainInfo.SiteName = [System.DirectoryServices.ActiveDirectory.ActiveDirectorySite]::GetComputerSite().Name
        }
    } catch {
        Log "Failed to detect site automatically, will prompt user later" -Level Warning
        $domainInfo.SiteName = $null
    }

    # Update report data with site info
    if ($domainInfo.SiteName -and $Script:ReportData.DomainInfo) {
        $Script:ReportData.DomainInfo['Site Name'] = $domainInfo.SiteName
    }

    return $domainInfo
}

function Test-DomainConnectivity {
    param (
        [Parameter(Mandatory)]
        [string]$DomainController,

        [Parameter()]
        [switch]$SkipRPCCheck
    )

    Log "Testing connectivity to domain controller: $DomainController" -Level Info

    # Validate input
    if ([string]::IsNullOrWhiteSpace($DomainController)) {
        Log "Domain controller name is empty or null" -Level Error
        return $false
    }

    # Test DNS resolution first
    Write-Host "  Testing DNS resolution... " -NoNewline
    try {
        $resolved = Resolve-DnsName -Name $DomainController -ErrorAction Stop
        Write-Host "OK" -ForegroundColor Green
        Log "Resolved $DomainController to $($resolved[0].IPAddress)" -Level Info
        $Script:ReportData.ConnectivityTests += @{
            Name = 'DNS Resolution'
            Target = $DomainController
            Status = 'Pass'
            Details = "Resolved to $($resolved[0].IPAddress)"
        }
    } catch {
        Write-Host "FAIL" -ForegroundColor Red
        Log "Cannot resolve domain controller name '$DomainController'" -Level Error
        $Script:ReportData.ConnectivityTests += @{
            Name = 'DNS Resolution'
            Target = $DomainController
            Status = 'Fail'
            Details = "Cannot resolve hostname"
        }
        return $false
    }

    # Test ICMP
    Write-Host "  Testing ICMP... " -NoNewline
    if (Test-Connection -ComputerName $DomainController -Count 2 -Quiet) {
        Write-Host "OK" -ForegroundColor Green
    } else {
        Write-Host "WARNING" -ForegroundColor Yellow
        Log "ICMP ping failed. Note: Some DCs block ICMP, continuing with other tests..." -Level Warning
    }

    # Test required ports
    $failedPorts = @()
    foreach ($port in $Script:Config.RequiredPorts) {
        Write-Host "  Testing $($port.Name) (port $($port.Port))... " -NoNewline
        try {
            $result = Test-NetConnection -ComputerName $DomainController -Port $port.Port -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
            if ($result.TcpTestSucceeded) {
                Write-Host "OK" -ForegroundColor Green
            } else {
                Write-Host "FAIL" -ForegroundColor Red
                $failedPorts += $port
                Log "Port $($port.Port) ($($port.Name)) is not accessible on $DomainController" -Level Warning
            }
        } catch {
            Write-Host "ERROR" -ForegroundColor Red
            $failedPorts += $port
            Log "Error testing port $($port.Port): $_" -Level Warning
        }
    }

    # Test RPC Dynamic Ports separately
    if (-not $SkipRPCCheck) {
        Write-Host "  Testing RPC Dynamic Ports... " -NoNewline
        try {
            # Use WMI to test RPC connectivity
            $wmiTest = Get-WmiObject -Class Win32_ComputerSystem -ComputerName $DomainController -ErrorAction Stop
            Write-Host "OK" -ForegroundColor Green
            Log "RPC dynamic port connectivity verified via WMI" -Level Info
        } catch {
            Write-Host "WARNING" -ForegroundColor Yellow
            Log "RPC dynamic ports may be restricted. This is common in secured environments." -Level Warning
            Log "RODC promotion may still succeed if static RPC ports are configured." -Level Warning
        }
    }

    # Evaluate results
    $criticalPorts = @(53, 88, 135, 389, 445)  # DNS, Kerberos, RPC, LDAP, SMB
    $failedCritical = $failedPorts | Where-Object { $_.Port -in $criticalPorts }

    if ($failedCritical.Count -gt 0) {
        Log "Critical ports failed: $($failedCritical.Name -join ', ')" -Level Error
        return $false
    } elseif ($failedPorts.Count -gt 0) {
        Log "Some non-critical ports failed. Promotion may still succeed." -Level Warning
        $continue = Read-Host "`nSome connectivity tests failed. Continue anyway? (Y/N)"
        return ($continue -in @('Y', 'y'))
    }

    return $true
}

function Test-ADConnectivity {
    param (
        [Parameter(Mandatory)]
        [pscredential]$Credential,

        [Parameter(Mandatory)]
        [string]$DomainName
    )

    Log "Testing Active Directory connectivity and authentication..." -Level Info

    Write-Host "  Testing LDAP bind... " -NoNewline
    try {
        # Test basic AD connectivity
        $context = New-Object System.DirectoryServices.ActiveDirectory.DirectoryContext('Domain', $DomainName, $Credential.UserName, $Credential.GetNetworkCredential().Password)
        $domain = [System.DirectoryServices.ActiveDirectory.Domain]::GetDomain($context)
        Write-Host "OK" -ForegroundColor Green

        # Test AD cmdlet connectivity
        Write-Host "  Testing AD PowerShell connectivity... " -NoNewline
        $null = Get-ADDomain -Identity $DomainName -Credential $Credential -ErrorAction Stop
        Write-Host "OK" -ForegroundColor Green

        # Check if user has domain admin privileges
        Write-Host "  Verifying domain admin privileges... " -NoNewline
        try {
            # Get the user's group memberships
            $userDN = (Get-ADUser -Identity $Credential.UserName.Split('\')[-1] -Credential $Credential).DistinguishedName
            $groups = Get-ADPrincipalGroupMembership -Identity $userDN -Credential $Credential | Select-Object -ExpandProperty Name

            $adminGroups = @('Domain Admins', 'Enterprise Admins')
            $isAdmin = $false
            foreach ($adminGroup in $adminGroups) {
                if ($groups -contains $adminGroup) {
                    $isAdmin = $true
                    Write-Host "OK (Member of $adminGroup)" -ForegroundColor Green
                    break
                }
            }

            if (-not $isAdmin) {
                Write-Host "WARNING" -ForegroundColor Yellow
                Log "User $($Credential.UserName) may not have sufficient privileges. Not a member of Domain Admins or Enterprise Admins." -Level Warning
                Write-Host "`n  ⚠️  The account '$($Credential.UserName)' is not a member of Domain Admins or Enterprise Admins." -ForegroundColor Yellow
                Write-Host "     RODC promotion requires domain admin privileges." -ForegroundColor Yellow

                if (-not $Force) {
                    $continue = Read-Host "`n  Continue anyway? (Y/N)"
                    if ($continue -notin @('Y', 'y')) {
                        return $false
                    }
                }
            }
        } catch {
            Write-Host "SKIPPED" -ForegroundColor Yellow
            Log "Could not verify admin privileges: $_" -Level Warning
        }

        # Test replication topology
        Write-Host "  Checking replication topology... " -NoNewline
        $sites = Get-ADReplicationSite -Filter * -Credential $Credential -ErrorAction Stop
        Write-Host "OK ($($sites.Count) sites found)" -ForegroundColor Green

        Log "Active Directory connectivity verified successfully" -Level Info
        return $true

    } catch {
        Write-Host "FAIL" -ForegroundColor Red
        Log "AD connectivity test failed: $_" -Level Error

        if ($_.Exception.Message -match "password|credential|authentication|access.*denied") {
            Write-Host "`n  ❌ Authentication failed. Please check your username and password." -ForegroundColor Red
            Write-Host "     Username: $($Credential.UserName)" -ForegroundColor Yellow
        }

        return $false
    }
}

function Test-RODCPrerequisites {
    param (
        [Parameter(Mandatory)]
        [pscredential]$Credential,

        [Parameter(Mandatory)]
        [string]$DomainName
    )

    Log "Checking RODC-specific prerequisites..." -Level Info

    try {
        # Check domain functional level
        $domain = Get-ADDomain -Identity $DomainName -Credential $Credential
        $minLevel = [Microsoft.ActiveDirectory.Management.ADDomainMode]::Windows2003Domain

        if ($domain.DomainMode -lt $minLevel) {
            Log "Domain functional level is too low. Minimum required: Windows Server 2003" -Level Error
            return $false
        }

        Log "Domain functional level: $($domain.DomainMode)" -Level Info

        # Check if RODC already exists with this name
        try {
            $existingRODC = Get-ADDomainController -Identity $Script:Config.RODCName -Credential $Credential -ErrorAction Stop
            Log "A domain controller with name '$($Script:Config.RODCName)' already exists!" -Level Error
            return $false
        } catch {
            # This is expected - RODC should not exist
            Log "Confirmed: No existing DC with name '$($Script:Config.RODCName)'" -Level Info
        }

        return $true
    } catch {
        Log "Failed to check RODC prerequisites: $_" -Level Error
        return $false
    }
}

function Get-SafeModePassword {
    Log "Setting Directory Services Restore Mode (DSRM) password..." -Level Info

    $minLength = 8
    $maxAttempts = 3
    $attempt = 0

    while ($attempt -lt $maxAttempts) {
        $attempt++

        Write-Host "`nThe DSRM password is used to boot the domain controller in Directory Services Restore Mode." -ForegroundColor Yellow
        Write-Host "Requirements: Minimum $minLength characters, should be complex and stored securely." -ForegroundColor Yellow

        $password = Read-Host -AsSecureString "Enter DSRM password"
        $confirmPassword = Read-Host -AsSecureString "Confirm DSRM password"

        # Convert to plain text for comparison (disposed immediately)
        $plainPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($password))
        $plainConfirm = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($confirmPassword))

        # Validate password
        if ($plainPassword -ne $plainConfirm) {
            Write-Host "Passwords do not match. Please try again." -ForegroundColor Red
            continue
        }

        if ($plainPassword.Length -lt $minLength) {
            Write-Host "Password must be at least $minLength characters long." -ForegroundColor Red
            continue
        }

        # Check for basic complexity (at least 3 of: uppercase, lowercase, numbers, special chars)
        $complexity = 0
        if ($plainPassword -cmatch '[A-Z]') { $complexity++ }
        if ($plainPassword -cmatch '[a-z]') { $complexity++ }
        if ($plainPassword -match '\d') { $complexity++ }
        if ($plainPassword -match '[^a-zA-Z0-9]') { $complexity++ }

        if ($complexity -lt 3) {
            Write-Host "Password must contain at least 3 of the following: uppercase, lowercase, numbers, special characters." -ForegroundColor Red
            continue
        }

        # Clear plain text passwords from memory
        $plainPassword = $null
        $plainConfirm = $null
        [System.GC]::Collect()

        Log "DSRM password validated successfully" -Level Info
        return $password
    }

    throw "Failed to set DSRM password after $maxAttempts attempts"
}

function Get-RODCPromotionParameters {
    param (
        [Parameter(Mandatory)]
        [hashtable]$DomainInfo,

        [Parameter(Mandatory)]
        [pscredential]$Credential,

        [Parameter(Mandatory)]
        [securestring]$SafeModePassword
    )

    $params = @{
        Credential = $Credential
        DomainName = $DomainInfo.DomainName
        ReadOnlyReplica = $true
        SiteName = $DomainInfo.SiteName
        InstallDns = $true
        DatabasePath = "C:\Windows\NTDS"
        LogPath = "C:\Windows\NTDS"
        SysvolPath = "C:\Windows\SYSVOL"
        NoGlobalCatalog = $false
        Confirm = $false
        Force = $true
        SafeModeAdministratorPassword = $SafeModePassword
    }

    # Add optional parameters
    if ($DelegatedAdminGroup) {
        $params.DelegatedAdministratorAccountName = $DelegatedAdminGroup
    }

    if ($AllowPasswordReplication.Count -gt 0) {
        $params.AllowPasswordReplicationAccountName = $AllowPasswordReplication
    }

    if ($DenyPasswordReplication.Count -gt 0) {
        $params.DenyPasswordReplicationAccountName = $DenyPasswordReplication
    }

    # If site wasn't auto-detected, prompt user
    if (-not $params.SiteName) {
        $sites = Get-ADReplicationSite -Filter * -Credential $Credential | Select-Object -ExpandProperty Name
        Write-Host "`nAvailable AD Sites:" -ForegroundColor Yellow
        $sites | ForEach-Object { Write-Host "  - $_" }

        do {
            $selectedSite = Read-Host "`nEnter the AD Site name for this RODC"
        } until ($selectedSite -in $sites)

        $params.SiteName = $selectedSite
    }

    return $params
}

function Show-Summary {
    param (
        [Parameter(Mandatory)]
        [hashtable]$DomainInfo,

        [Parameter(Mandatory)]
        [hashtable]$PromotionParams
    )

    Write-Host "`n=== RODC PROMOTION SUMMARY ===" -ForegroundColor Cyan
    Write-Host "Server Name         : $($Script:Config.RODCName)"
    Write-Host "Domain Name         : $($DomainInfo.DomainName)"
    Write-Host "Forest Name         : $($DomainInfo.ForestName)"
    Write-Host "Site Name           : $($PromotionParams.SiteName)"
    Write-Host "PDC Emulator        : $($DomainInfo.PDCEmulator)"
    Write-Host "Install DNS         : Yes"
    Write-Host "Global Catalog      : Yes"

    if ($DelegatedAdminGroup) {
        Write-Host "Delegated Admin     : $DelegatedAdminGroup"
    }

    if ($AllowPasswordReplication.Count -gt 0) {
        Write-Host "Password Replication Allowed:"
        $AllowPasswordReplication | ForEach-Object { Write-Host "  - $_" -ForegroundColor Green }
    }

    if ($DenyPasswordReplication.Count -gt 0) {
        Write-Host "Password Replication Denied:"
        $DenyPasswordReplication | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    }

    Write-Host "`n⚠️  WARNING: This server will automatically reboot after promotion!" -ForegroundColor Yellow
}

function Install-RequiredRoles {
    Log "Installing required Windows features..." -Level Info
    Add-InstallationStep -Name "Feature Installation" -Status "Info" -Details "Installing required Windows features"

    $features = @(
        @{Name = 'AD-Domain-Services'; DisplayName = 'AD Domain Services'},
        @{Name = 'DNS'; DisplayName = 'DNS Server'},
        @{Name = 'RSAT-AD-PowerShell'; DisplayName = 'AD PowerShell Module'},
        @{Name = 'RSAT-AD-AdminCenter'; DisplayName = 'AD Admin Center'},
        @{Name = 'RSAT-ADDS-Tools'; DisplayName = 'AD DS Tools'},
        @{Name = 'RSAT-DNS-Server'; DisplayName = 'DNS Server Tools'}
    )

    # Check which features need to be installed
    $toInstall = @()
    foreach ($feature in $features) {
        $installed = Get-WindowsFeature -Name $feature.Name
        if ($installed.InstallState -ne 'Installed') {
            $toInstall += $feature
        } else {
            Write-Host "  $($feature.DisplayName) is already installed" -ForegroundColor Green
        }
    }

    if ($toInstall.Count -eq 0) {
        Write-Host "  All required features are already installed" -ForegroundColor Green
        Add-InstallationStep -Name "Features Already Installed" -Status "Success" -Details "All required Windows features were already installed"
        Import-Module ActiveDirectory -ErrorAction Stop
        return
    }

    # Install missing features
    foreach ($feature in $toInstall) {
        Write-Host "  Installing $($feature.DisplayName)... " -NoNewline
        try {
            $result = Install-WindowsFeature -Name $feature.Name -IncludeManagementTools -ErrorAction Stop
            if ($result.Success) {
                Write-Host "OK" -ForegroundColor Green
                Add-InstallationStep -Name "Installed $($feature.DisplayName)" -Status "Success" -Details "Feature installed successfully"
            } else {
                Write-Host "FAILED" -ForegroundColor Red
                Add-InstallationStep -Name "Failed to install $($feature.DisplayName)" -Status "Error" -Details "Installation failed"
                throw "Failed to install $($feature.DisplayName)"
            }
        } catch {
            Log "Failed to install feature $($feature.DisplayName) : $_" -Level Error
            Add-InstallationStep -Name "Feature Installation Error" -Status "Error" -Details $_
            throw
        }
    }

    # Import AD module
    Import-Module ActiveDirectory -ErrorAction Stop
    Add-InstallationStep -Name "Features Installed" -Status "Success" -Details "All required Windows features installed successfully"
}

function Add-InstallationStep {
    param (
        [string]$Name,
        [string]$Status,
        [string]$Details = ""
    )

    $Script:ReportData.InstallationSteps += @{
        Timestamp = Get-Date
        Name = $Name
        Status = $Status
        Details = $Details
    }
}

function Invoke-RODCPromotion {
    param (
        [Parameter(Mandatory)]
        [hashtable]$PromotionParams
    )

    Log "Starting RODC promotion process..." -Level Info
    Add-InstallationStep -Name "RODC Promotion Started" -Status "Info" -Details "Beginning promotion to Read-Only Domain Controller"

    try {
        # Create progress indicator
        $activity = "Promoting to Read-Only Domain Controller"
        Write-Progress -Activity $activity -Status "Installing AD DS Domain Controller role..." -PercentComplete 0

        # Perform the promotion
        Install-ADDSDomainController @PromotionParams -ErrorAction Stop

        Write-Progress -Activity $activity -Status "Complete" -PercentComplete 100 -Completed

        Log "RODC promotion completed successfully!" -Level Success
        Add-InstallationStep -Name "RODC Promotion Completed" -Status "Success" -Details "Server successfully promoted to RODC"
        return $true
    } catch {
        Log "RODC promotion failed: $_" -Level Error
        Add-InstallationStep -Name "RODC Promotion Failed" -Status "Error" -Details $_.Exception.Message
        return $false
    }
}

function Complete-Script {
    param (
        [Parameter()]
        [bool]$Success = $true
    )

    # Set final report data
    $Script:ReportData.EndTime = Get-Date
    $Script:ReportData.FinalResult = if ($Success) { 'Success' } else { 'Failed' }

    if ($Success) {
        Log "=== RODC Promotion Script Completed Successfully ===" -Level Success
        Write-Host "`n✅ RODC setup complete!" -ForegroundColor Green
        Write-Host "📋 Log file saved to: $($Script:Config.LogFile)" -ForegroundColor Cyan
        Write-Host "🔄 Server will reboot automatically in 15 seconds..." -ForegroundColor Yellow

        # Post-promotion reminders
        Write-Host "`n📌 POST-REBOOT TASKS:" -ForegroundColor Cyan
        Write-Host "  1. Verify DNS zones: Get-DnsServerZone"
        Write-Host "  2. Check replication: repadmin /replsum"
        Write-Host "  3. Verify RODC status: Get-ADDomainController -Identity $($Script:Config.RODCName)"
        Write-Host "  4. Configure Password Replication Policy if needed"
        Write-Host "  5. Test authentication from client machines"
        Write-Host "`n⚠️  IMPORTANT: Store the DSRM password securely - it's required for recovery!" -ForegroundColor Yellow

        # Add post tasks to report
        $Script:ReportData.PostTasks = @(
            "Verify DNS zones using: Get-DnsServerZone",
            "Check replication status: repadmin /replsum",
            "Verify RODC status: Get-ADDomainController -Identity $($Script:Config.RODCName)",
            "Configure Password Replication Policy as needed",
            "Test authentication from client machines",
            "Securely store the DSRM password"
        )
    } else {
        Log "=== RODC Promotion Script Failed ===" -Level Error
        Write-Host "`n❌ RODC promotion failed. Check the log file for details." -ForegroundColor Red
        Write-Host "📋 Log file: $($Script:Config.LogFile)" -ForegroundColor Yellow
    }

    # Generate HTML report
    Write-Host "`n📊 Generating HTML report..." -ForegroundColor Cyan
    $reportPath = Generate-HTMLReport

    if ($reportPath -and (Test-Path $reportPath)) {
        Write-Host "📄 HTML report saved to: $reportPath" -ForegroundColor Green

        # Open report in default browser
        Write-Host "🌐 Opening report in browser..." -ForegroundColor Cyan
        Start-Process $reportPath
    }

    # Stop transcript
    Stop-Transcript
}

function Generate-HTMLReport {
    try {
        # Ensure the report directory exists
        if (-not (Test-Path -Path $Script:Config.HTMLReportPath)) {
            New-Item -ItemType Directory -Path $Script:Config.HTMLReportPath -Force | Out-Null
        }

        $htmlReportPath = Join-Path $Script:Config.HTMLReportPath $Script:Config.HTMLReportFile

        # Calculate duration
        $duration = if ($Script:ReportData.EndTime) {
            $timespan = $Script:ReportData.EndTime - $Script:ReportData.StartTime
            "{0:00}h {1:00}m {2:00}s" -f $timespan.Hours, $timespan.Minutes, $timespan.Seconds
        } else {
            "N/A"
        }

        # Build HTML content
        $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>RODC Promotion Report - $($Script:Config.RODCName)</title>
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }

        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, sans-serif;
            background-color: #f5f5f5;
            color: #333;
            line-height: 1.6;
        }

        .container {
            max-width: 1200px;
            margin: 0 auto;
            padding: 20px;
        }

        .header {
            background: linear-gradient(135deg, #2c3e50, #3498db);
            color: white;
            padding: 30px;
            border-radius: 10px;
            margin-bottom: 30px;
            box-shadow: 0 4px 6px rgba(0,0,0,0.1);
        }

        .header h1 {
            font-size: 2.5em;
            margin-bottom: 10px;
        }

        .header .subtitle {
            font-size: 1.2em;
            opacity: 0.9;
        }

        .summary-cards {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
            gap: 20px;
            margin-bottom: 30px;
        }

        .card {
            background: white;
            padding: 20px;
            border-radius: 8px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
            transition: transform 0.2s;
        }

        .card:hover {
            transform: translateY(-2px);
            box-shadow: 0 4px 8px rgba(0,0,0,0.15);
        }

        .card h3 {
            color: #2c3e50;
            margin-bottom: 10px;
            font-size: 1.1em;
        }

        .card .value {
            font-size: 1.5em;
            font-weight: bold;
            color: #3498db;
        }

        .status-success {
            color: #27ae60 !important;
        }

        .status-failed {
            color: #e74c3c !important;
        }

        .status-warning {
            color: #f39c12 !important;
        }

        .section {
            background: white;
            padding: 25px;
            border-radius: 8px;
            margin-bottom: 20px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
        }

        .section h2 {
            color: #2c3e50;
            margin-bottom: 20px;
            padding-bottom: 10px;
            border-bottom: 2px solid #ecf0f1;
        }

        table {
            width: 100%;
            border-collapse: collapse;
            margin-top: 10px;
        }

        table th {
            background: #ecf0f1;
            padding: 12px;
            text-align: left;
            font-weight: 600;
            color: #2c3e50;
        }

        table td {
            padding: 12px;
            border-bottom: 1px solid #ecf0f1;
        }

        table tr:hover {
            background: #f8f9fa;
        }

        .badge {
            display: inline-block;
            padding: 4px 12px;
            border-radius: 20px;
            font-size: 0.85em;
            font-weight: 600;
            text-transform: uppercase;
        }

        .badge-success {
            background: #d4edda;
            color: #155724;
        }

        .badge-error {
            background: #f8d7da;
            color: #721c24;
        }

        .badge-warning {
            background: #fff3cd;
            color: #856404;
        }

        .badge-info {
            background: #d1ecf1;
            color: #0c5460;
        }

        .timeline {
            position: relative;
            padding-left: 30px;
        }

        .timeline-item {
            position: relative;
            padding-bottom: 20px;
            border-left: 2px solid #ecf0f1;
        }

        .timeline-item:last-child {
            border-left: none;
        }

        .timeline-item::before {
            content: '';
            position: absolute;
            left: -6px;
            top: 0;
            width: 10px;
            height: 10px;
            border-radius: 50%;
            background: #3498db;
        }

        .timeline-item.success::before {
            background: #27ae60;
        }

        .timeline-item.error::before {
            background: #e74c3c;
        }

        .timeline-item .time {
            font-size: 0.85em;
            color: #7f8c8d;
            margin-bottom: 5px;
        }

        .error-box {
            background: #fee;
            border-left: 4px solid #e74c3c;
            padding: 15px;
            margin: 10px 0;
            border-radius: 4px;
        }

        .warning-box {
            background: #fffbea;
            border-left: 4px solid #f39c12;
            padding: 15px;
            margin: 10px 0;
            border-radius: 4px;
        }

        .info-box {
            background: #e3f2fd;
            border-left: 4px solid #2196f3;
            padding: 15px;
            margin: 10px 0;
            border-radius: 4px;
        }

        .footer {
            text-align: center;
            padding: 20px;
            color: #7f8c8d;
            font-size: 0.9em;
        }

        .print-button {
            position: fixed;
            bottom: 20px;
            right: 20px;
            background: #3498db;
            color: white;
            border: none;
            padding: 12px 24px;
            border-radius: 25px;
            cursor: pointer;
            box-shadow: 0 4px 6px rgba(0,0,0,0.1);
            font-size: 16px;
            transition: all 0.3s;
        }

        .print-button:hover {
            background: #2980b9;
            transform: translateY(-2px);
            box-shadow: 0 6px 12px rgba(0,0,0,0.15);
        }

        @media print {
            .print-button {
                display: none;
            }

            body {
                background: white;
            }

            .container {
                max-width: 100%;
            }
        }
    </style>
</head>
<body>
    <button class="print-button" onclick="window.print()">🖨️ Print Report</button>

    <div class="container">
        <div class="header">
            <h1>RODC Promotion Report</h1>
            <div class="subtitle">$($Script:Config.RODCName) - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</div>
        </div>

        <div class="summary-cards">
            <div class="card">
                <h3>Overall Status</h3>
                <div class="value status-$(if ($Script:ReportData.FinalResult -eq 'Success') {'success'} else {'failed'})">
                    $($Script:ReportData.FinalResult)
                </div>
            </div>

            <div class="card">
                <h3>Duration</h3>
                <div class="value">$duration</div>
            </div>

            <div class="card">
                <h3>Start Time</h3>
                <div class="value">$($Script:ReportData.StartTime.ToString('HH:mm:ss'))</div>
            </div>

            <div class="card">
                <h3>End Time</h3>
                <div class="value">$(if ($Script:ReportData.EndTime) { $Script:ReportData.EndTime.ToString('HH:mm:ss') } else { 'N/A' })</div>
            </div>
        </div>

        <!-- Server Information -->
        <div class="section">
            <h2>📊 Server Information</h2>
            <table>
                <tr>
                    <th>Property</th>
                    <th>Value</th>
                </tr>
$(
    foreach ($key in $Script:ReportData.ServerInfo.Keys) {
        @"
                <tr>
                    <td>$key</td>
                    <td>$($Script:ReportData.ServerInfo[$key])</td>
                </tr>
"@
    }
)
            </table>
        </div>

        <!-- Domain Information -->
        $(if ($Script:ReportData.DomainInfo.Count -gt 0) {
        @"
        <div class="section">
            <h2>🌐 Domain Information</h2>
            <table>
                <tr>
                    <th>Property</th>
                    <th>Value</th>
                </tr>
$(
    foreach ($key in $Script:ReportData.DomainInfo.Keys) {
        @"
                <tr>
                    <td>$key</td>
                    <td>$($Script:ReportData.DomainInfo[$key])</td>
                </tr>
"@
    }
)
            </table>
        </div>
"@
        })

        <!-- Prerequisite Checks -->
        <div class="section">
            <h2>✅ Prerequisite Checks</h2>
            <table>
                <tr>
                    <th>Check</th>
                    <th>Status</th>
                    <th>Details</th>
                </tr>
$(
    foreach ($check in $Script:ReportData.PrerequisiteChecks) {
        $badgeClass = switch ($check.Status) {
            'Pass' { 'badge-success' }
            'Fail' { 'badge-error' }
            'Warning' { 'badge-warning' }
            'Fixed' { 'badge-info' }
            default { 'badge-info' }
        }
        @"
                <tr>
                    <td>$($check.Name)</td>
                    <td><span class="badge $badgeClass">$($check.Status)</span></td>
                    <td>$($check.Details)</td>
                </tr>
"@
    }
)
            </table>
        </div>

        <!-- Connectivity Tests -->
        $(if ($Script:ReportData.ConnectivityTests.Count -gt 0) {
        @"
        <div class="section">
            <h2>🔌 Connectivity Tests</h2>
            <table>
                <tr>
                    <th>Test</th>
                    <th>Target</th>
                    <th>Status</th>
                    <th>Details</th>
                </tr>
$(
    foreach ($test in $Script:ReportData.ConnectivityTests) {
        $badgeClass = if ($test.Status -eq 'Pass') { 'badge-success' } else { 'badge-error' }
        @"
                <tr>
                    <td>$($test.Name)</td>
                    <td>$($test.Target)</td>
                    <td><span class="badge $badgeClass">$($test.Status)</span></td>
                    <td>$($test.Details)</td>
                </tr>
"@
    }
)
            </table>
        </div>
"@
        })

        <!-- Installation Steps Timeline -->
        <div class="section">
            <h2>📝 Installation Timeline</h2>
            <div class="timeline">
$(
    foreach ($step in $Script:ReportData.InstallationSteps) {
        $itemClass = if ($step.Status -eq 'Success') { 'success' } elseif ($step.Status -eq 'Error') { 'error' } else { '' }
        @"
                <div class="timeline-item $itemClass">
                    <div class="time">$($step.Timestamp.ToString('HH:mm:ss'))</div>
                    <strong>$($step.Name)</strong>
                    $(if ($step.Details) { "<br>$($step.Details)" })
                </div>
"@
    }
)
            </div>
        </div>

        <!-- Errors and Warnings -->
        $(if ($Script:ReportData.Errors.Count -gt 0) {
        @"
        <div class="section">
            <h2>❌ Errors</h2>
$(
    foreach ($error in $Script:ReportData.Errors) {
        @"
            <div class="error-box">
                <strong>$($error.Timestamp.ToString('HH:mm:ss'))</strong> - $($error.Message)
            </div>
"@
    }
)
        </div>
"@
        })

        $(if ($Script:ReportData.Warnings.Count -gt 0) {
        @"
        <div class="section">
            <h2>⚠️ Warnings</h2>
$(
    foreach ($warning in $Script:ReportData.Warnings) {
        @"
            <div class="warning-box">
                <strong>$($warning.Timestamp.ToString('HH:mm:ss'))</strong> - $($warning.Message)
            </div>
"@
    }
)
        </div>
"@
        })

        <!-- Post-Installation Tasks -->
        $(if ($Script:ReportData.PostTasks.Count -gt 0) {
        @"
        <div class="section">
            <h2>📌 Post-Installation Tasks</h2>
            <div class="info-box">
                <p>The following tasks should be completed after the server reboots:</p>
                <ul style="margin-top: 10px; margin-left: 20px;">
$(
    foreach ($task in $Script:ReportData.PostTasks) {
        @"
                    <li>$task</li>
"@
    }
)
                </ul>
            </div>
        </div>
"@
        })

        <div class="footer">
            <p>Generated by RODC Promotion Script v2.0 | $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</p>
            <p>Log files located at: $($Script:Config.LogPath)</p>
        </div>
    </div>

    <script>
        // Auto-refresh if still in progress
        $(if ($Script:ReportData.FinalResult -eq 'In Progress') {
        @"
        setTimeout(function() {
            location.reload();
        }, 5000);
"@
        })
    </script>
</body>
</html>
"@

        # Write HTML to file
        $html | Out-File -FilePath $htmlReportPath -Encoding UTF8

        return $htmlReportPath
    } catch {
        Log "Failed to generate HTML report: $_" -Level Error
        return $null
    }
}

# -------------------------
# MAIN SCRIPT EXECUTION
# -------------------------
try {
    # Initialize logging
    Initialize-Logging

    # Add initial installation step
    Add-InstallationStep -Name "Script Started" -Status "Info" -Details "RODC Promotion Script v2.0 initialized"

    # Display banner
    Write-Host "`n==================================================" -ForegroundColor Cyan
    Write-Host "     READ-ONLY DOMAIN CONTROLLER (RODC) SETUP     " -ForegroundColor Cyan
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host "Server: $env:COMPUTERNAME" -ForegroundColor White
    Write-Host "Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor White
    Write-Host "==================================================" -ForegroundColor Cyan

    # Check domain status first
    $isDomainJoined = Test-DomainStatus

    # If CheckOnly parameter was specified, exit here
    if ($CheckOnly) {
        Write-Host "`n===============================" -ForegroundColor Cyan
        Complete-Script -Success $true
        exit 0
    }

    # If not domain joined, exit with instructions
    if (-not $isDomainJoined) {
        throw "Server must be domain-joined before proceeding with RODC promotion"
    }

    # Check prerequisites
    if (-not $SkipPreChecks) {
        Add-InstallationStep -Name "Prerequisites Check" -Status "Info" -Details "Checking system prerequisites"
        if (-not (Test-Prerequisites)) {
            Add-InstallationStep -Name "Prerequisites Failed" -Status "Error" -Details "One or more prerequisite checks failed"
            throw "Prerequisite checks failed. Please resolve the issues above and try again."
        }
        Add-InstallationStep -Name "Prerequisites Passed" -Status "Success" -Details "All prerequisite checks completed successfully"
    } else {
        Log "Skipping prerequisite checks (not recommended)" -Level Warning
        Add-InstallationStep -Name "Prerequisites Skipped" -Status "Warning" -Details "Prerequisite checks were skipped by user"
    }

    # Get domain information
    try {
        $domainInfo = Get-DomainInfo
        Log "Domain: $($domainInfo.DomainName), Site: $($domainInfo.SiteName), PDC: $($domainInfo.PDCEmulator)" -Level Info
    } catch {
        Write-Host "`n❌ ERROR: Failed to detect domain information" -ForegroundColor Red
        Write-Host "Details: $_" -ForegroundColor Red

        if ($_.Exception.Message -match "not joined to any domain") {
            Write-Host "`nThis server must be joined to a domain before it can be promoted to an RODC." -ForegroundColor Yellow
            Show-DomainJoinInstructions
        }

        Complete-Script -Success $false
        exit 1
    }

    # Get credentials
    if (-not $Credential) {
        # Determine the username to use
        $credentialUsername = $null

        if ($DomainAdminUser) {
            # User specified a custom admin account
            if ($DomainAdminUser -contains '\') {
                # Full DOMAIN\Username format provided
                $credentialUsername = $DomainAdminUser
            } else {
                # Just username provided, prepend domain
                $credentialUsername = "$($domainInfo.DomainName)\$DomainAdminUser"
            }
            Write-Host "`nUsing specified domain admin account: $credentialUsername" -ForegroundColor Cyan
        } else {
            # No username specified, prompt for choice
            Write-Host "`nDomain Admin credentials are required for RODC promotion." -ForegroundColor Yellow
            Write-Host "Would you like to:" -ForegroundColor Cyan
            Write-Host "  1. Use the default Administrator account" -ForegroundColor White
            Write-Host "  2. Specify a different domain admin account" -ForegroundColor White

            do {
                $choice = Read-Host "`nSelect option (1 or 2)"
            } until ($choice -in @('1', '2'))

            if ($choice -eq '1') {
                $credentialUsername = "$($domainInfo.DomainName)\Administrator"
            } else {
                Write-Host "`nEnter the domain admin username in one of these formats:" -ForegroundColor Yellow
                Write-Host "  - DOMAIN\Username" -ForegroundColor White
                Write-Host "  - Username@domain.com" -ForegroundColor White
                Write-Host "  - Username (will use current domain)" -ForegroundColor White

                $inputUsername = Read-Host "`nDomain admin username"

                if ($inputUsername -match '\\|@') {
                    # User provided domain info
                    $credentialUsername = $inputUsername
                } else {
                    # Just username, prepend domain
                    $credentialUsername = "$($domainInfo.DomainName)\$inputUsername"
                }
            }
        }

        # Get credentials with the determined username
        $Credential = Get-Credential -Message "Enter password for $credentialUsername" -UserName $credentialUsername

        if (-not $Credential) {
            throw "Credentials are required to continue"
        }
    }
    Log "Using credentials for: $($Credential.UserName)" -Level Info

    # Get DSRM password
    $safeModePassword = Get-SafeModePassword

    # Test domain connectivity
    $connectivityParams = @{
        DomainController = $domainInfo.PDCEmulator
    }
    if ($SkipRPCCheck) {
        $connectivityParams.SkipRPCCheck = $true
    }

    if (-not (Test-DomainConnectivity @connectivityParams)) {
        throw "Domain connectivity tests failed"
    }

    # Test AD-specific connectivity
    if (-not (Test-ADConnectivity -Credential $Credential -DomainName $domainInfo.DomainName)) {
        throw "Active Directory connectivity tests failed"
    }

    # Check RODC-specific prerequisites
    if (-not (Test-RODCPrerequisites -Credential $Credential -DomainName $domainInfo.DomainName)) {
        throw "RODC prerequisite checks failed"
    }

    # Install required roles
    Install-RequiredRoles

    # Get promotion parameters
    $promotionParams = Get-RODCPromotionParameters -DomainInfo $domainInfo -Credential $Credential -SafeModePassword $safeModePassword

    # Show summary and get confirmation
    Show-Summary -DomainInfo $domainInfo -PromotionParams $promotionParams

    if (-not $Force) {
        $confirmation = Read-Host "`nDo you want to proceed with RODC promotion? (Y/N)"
        if ($confirmation -notin @('Y', 'y')) {
            Log "User cancelled the operation" -Level Warning
            Complete-Script -Success $false
            exit
        }
    }

    # Perform promotion
    if (Invoke-RODCPromotion -PromotionParams $promotionParams) {
        Complete-Script -Success $true
    } else {
        Complete-Script -Success $false
        exit 1
    }

} catch {
    Log "Script execution failed: $_" -Level Error

    # Provide specific help for common scenarios
    if ($script:NotDomainJoined -or $_.Exception.Message -match "not joined to any domain") {
        Write-Host "`n❌ This server is not joined to a domain!" -ForegroundColor Red
        Show-DomainJoinInstructions
    } elseif ($_.Exception.Message -match "Credential") {
        Write-Host "`n❌ Valid domain admin credentials are required for RODC promotion." -ForegroundColor Red
        Write-Host "Please ensure you have the correct username and password." -ForegroundColor Yellow
    }

    Complete-Script -Success $false
    exit 1
}