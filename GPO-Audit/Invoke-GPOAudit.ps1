<#
.SYNOPSIS
    Audits and documents all Group Policy Objects (GPOs) that affect a specified
    Windows computer and, optionally, a specified user.

.DESCRIPTION
    Invoke-GPOAudit.ps1 performs a comprehensive, READ-ONLY audit of Group Policy in an
    Active Directory domain. The only changes it ever makes are:

        1. Installing required RSAT components / Windows features (only with confirmation
           or the -InstallPrerequisites switch, and honoring -WhatIf).
        2. Creating local report files beneath -OutputPath.

    It collects:
        - Which GPOs exist in the domain (with -IncludeDomainInventory)
        - Where every GPO is linked (site / domain / OU), link order, enforced,
          enabled, and Block Inheritance status
        - Which GPOs apply to the specified computer and user
        - Which GPOs were denied and why (security filtering, WMI filtering,
          disabled link, empty, inaccessible)
        - Winning / resultant policy via gpresult (R, Z, H, X) and
          Get-GPResultantSetOfPolicy
        - Security filtering and delegation problems
        - WMI filter inventory and problems
        - SYSVOL vs. Active Directory consistency (orphans, missing folders,
          version mismatches) - comparison only, nothing is touched
        - Group Policy operational event log evidence (with -IncludeEventLogs)
        - Categorized findings (Critical / High / Medium / Low / Informational)
          with remediation recommendations

    Output is a structured folder tree containing a master HTML report (embedded CSS,
    fully portable, no internet access required), CSV and JSON exports of every major
    dataset, per-GPO HTML and XML reports, EVTX/CSV event exports, and a full
    execution log.

    ================================ PERMISSIONS =================================
    Required permissions, by feature:

    WORKS AS A STANDARD DOMAIN USER
        - Reading GPO objects, links, and inheritance (Get-GPO, Get-GPInheritance)
          for all GPOs where "Authenticated Users" retains Read (the default)
        - Reading WMI filters and OU structure via LDAP
        - Reading \\domain\SYSVOL and \\domain\NETLOGON (default ACLs allow Read)
        - gpresult for the CURRENT user on the LOCAL computer (user scope only)

    REQUIRES LOCAL ADMINISTRATOR ON THE TARGET COMPUTER
        - gpresult computer scope (/SCOPE COMPUTER) and RSOP for other users
        - Reading the Microsoft-Windows-GroupPolicy/Operational event log remotely
        - Get-GPResultantSetOfPolicy against the target computer
        - Reading Group Policy state/history from the target's registry
        - Installing RSAT capabilities / Windows features (local machine)
        This script therefore REQUIRES elevation and will stop without it.

    REQUIRES DOMAIN ADMIN (or equivalent delegation)
        - Reading GPOs whose Read permission has been stripped from
          Authenticated Users (locked-down GPOs)
        - Full delegation/permission audit of every GPO (Get-GPPermission needs
          Read on each GPO's security descriptor)
        - Some domain controller diagnostics
        Everything else works with ordinary read access; the script clearly marks
        any item it could not read as UNAVAILABLE instead of failing.

    ============================ POWERSHELL EDITIONS =============================
    Windows PowerShell 5.1 is the PREFERRED host. The GroupPolicy and
    ActiveDirectory RSAT modules are written for .NET Framework; under PowerShell 7
    the GroupPolicy module is not natively supported and must be proxied through
    the Windows PowerShell compatibility layer (Import-Module -UseWindowsPowerShell),
    which serializes objects and can silently lose fidelity (e.g., some report
    generation and permission objects). The script detects PowerShell 7, attempts
    the compatibility import, verifies the cmdlets actually work, and otherwise
    instructs the operator (or relaunches with -RelaunchInWindowsPowerShell) to use
    powershell.exe 5.1.

.PARAMETER ComputerName
    Target computer to audit. Defaults to the local computer. Remote targets are
    audited over WinRM / CIM where possible; every remote method failure is
    non-fatal and clearly reported.

.PARAMETER UserName
    Optional user to include in the audit, as 'DOMAIN\User', 'user@domain', or a
    plain SAM account name. User RSOP data requires that the user has logged on to
    the target computer at least once.

.PARAMETER OutputPath
    Root folder for all reports. Defaults to
    <SystemDrive>\GPOAudit\<COMPUTERNAME>_yyyyMMdd_HHmmss

.PARAMETER Domain
    DNS name of the domain to audit. Defaults to the computer's joined domain.

.PARAMETER DomainController
    Specific domain controller to query. Defaults to an automatically discovered DC.

.PARAMETER Credential
    Alternate credential for Active Directory, CIM, and WinRM operations.
    NOTE: the GroupPolicy module does not accept credentials; GP cmdlets always run
    as the launching user. Credentials are never written to disk.

.PARAMETER InstallPrerequisites
    Install missing RSAT capabilities (client) or Windows features (server)
    without interactive confirmation. Honors -WhatIf.

.PARAMETER IncludeDomainInventory
    Enumerate every GPO in the domain with full metadata, per-GPO HTML/XML
    reports, and the complete link map for all sites, the domain, and all OUs.

.PARAMETER IncludeEventLogs
    Collect Microsoft-Windows-GroupPolicy/Operational events (CSV and, where
    possible, EVTX) and analyze them for errors, slow processing, and filtering.

.PARAMETER IncludeSecurityAudit
    Run the per-GPO security filtering / delegation audit (Get-GPPermission) and
    the WMI filter audit even without -IncludeDomainInventory.

.PARAMETER SkipRemoteRSOP
    Do not attempt RSOP/gpresult collection against a remote target (useful for
    domain-only inventory runs or offline targets).

.PARAMETER OpenReport
    Open the master HTML report when the audit completes.

.PARAMETER StaleGpoDays
    A GPO not modified in this many days is flagged as stale. Default 365.

.PARAMETER RecentGpoDays
    A GPO modified within this many days is flagged as recently changed. Default 7.

.PARAMETER EventLogDays
    How many days of Group Policy operational events to collect. Default 14.

.PARAMETER ForceGPUpdate
    EXPLICIT opt-in to run 'gpupdate /force' on the target before collection.
    Never runs without this switch. Honors -WhatIf.

.PARAMETER RelaunchInWindowsPowerShell
    If running under PowerShell 7 and the GroupPolicy compatibility import fails,
    automatically relaunch this script in Windows PowerShell 5.1
    (credentials cannot be forwarded and will be re-prompted).

.EXAMPLE
    .\Invoke-GPOAudit.ps1 -InstallPrerequisites -IncludeDomainInventory -IncludeEventLogs

    Full local computer audit including the domain-wide GPO inventory and event logs,
    installing any missing RSAT prerequisites unattended.

.EXAMPLE
    .\Invoke-GPOAudit.ps1 -ComputerName PC123 -UserName 'DOMAIN\User1' -IncludeDomainInventory -IncludeEventLogs -OutputPath C:\Audits\PC123

    Remote computer + user audit with domain inventory, written to C:\Audits\PC123.

.EXAMPLE
    .\Invoke-GPOAudit.ps1 -IncludeDomainInventory -SkipRemoteRSOP

    Domain-only inventory: enumerates and documents all GPOs, links, permissions,
    WMI filters, and SYSVOL health without touching any target computer.

.EXAMPLE
    $Credential = Get-Credential
    .\Invoke-GPOAudit.ps1 -ComputerName PC123 -Credential $Credential -IncludeDomainInventory

    Remote audit using alternate credentials for AD/CIM/WinRM operations.

.NOTES
    Author  : GPO Audit Toolkit
    Requires: Windows 10/11 or Windows Server 2019/2022/2025, domain joined,
              local administrator rights, RSAT GroupPolicy + ActiveDirectory tools
              (installable via -InstallPrerequisites).
    Safety  : READ-ONLY against Active Directory, SYSVOL, and all GPOs.
              Never modifies GPOs, permissions, links, or SYSVOL content.
              Never writes credentials to disk.
#>
#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$ComputerName = $env:COMPUTERNAME,

    [Parameter()]
    [ValidatePattern('^[^\\/\[\]:;|=,+*?<>"]+$|^[^\\]+\\[^\\]+$|^\S+@\S+$')]
    [string]$UserName,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath,

    [Parameter()]
    [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9.-]*$')]
    [string]$Domain,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$DomainController,

    [Parameter()]
    [System.Management.Automation.PSCredential]
    [System.Management.Automation.Credential()]
    $Credential = [System.Management.Automation.PSCredential]::Empty,

    [Parameter()]
    [switch]$InstallPrerequisites,

    [Parameter()]
    [switch]$IncludeDomainInventory,

    [Parameter()]
    [switch]$IncludeEventLogs,

    [Parameter()]
    [switch]$IncludeSecurityAudit,

    [Parameter()]
    [switch]$SkipRemoteRSOP,

    [Parameter()]
    [switch]$OpenReport,

    [Parameter()]
    [ValidateRange(1, 3650)]
    [int]$StaleGpoDays = 365,

    [Parameter()]
    [ValidateRange(1, 365)]
    [int]$RecentGpoDays = 7,

    [Parameter()]
    [ValidateRange(1, 365)]
    [int]$EventLogDays = 14,

    [Parameter()]
    [switch]$ForceGPUpdate,

    [Parameter()]
    [switch]$RelaunchInWindowsPowerShell
)

Set-StrictMode -Version 2.0

# =============================================================================
#  Script-scope state
# =============================================================================
$script:ScriptVersion   = '1.0.0'
$script:StartTime       = Get-Date
$script:LogFile         = $null
$script:TranscriptOn    = $false
$script:Findings        = New-Object System.Collections.Generic.List[object]
$script:Unavailable     = New-Object System.Collections.Generic.List[object]
$script:Datasets        = @{}
$script:Paths           = @{}
$script:GPModuleMode    = 'Unknown'      # Native | WinPSCompat | Unavailable
$script:ADModuleMode    = 'Unknown'
$script:HasCredential   = $false
$script:IsLocalTarget   = $true
$script:TargetOnline    = $false
$script:WinRMAvailable  = $false
$script:CimSession      = $null
$script:AdParams        = @{}            # splat for AD cmdlets  (-Server/-Credential)
$script:GpParams        = @{}            # splat for GP cmdlets  (-Domain/-Server)
$script:DomainDN        = $null
$script:ConfigNC        = $null
$script:DomainInfo      = $null
$script:RestartNeeded   = $false
$script:AllGpos         = @()            # cache of Get-GPO -All results
$script:GpoLinkIndex    = @{}            # GUID -> list of link records
$script:MasterReport    = $null

# =============================================================================
#  Core helpers: logging, sanitizing, exporting, findings
# =============================================================================

function Write-AuditLog {
    <#
    .SYNOPSIS
        Central logger: timestamped line to the log file plus the proper stream.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [ValidateSet('Info', 'Success', 'Warn', 'Error', 'Debug', 'Section')]
        [string]$Level = 'Info'
    )
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line  = '[{0}] [{1,-7}] {2}' -f $stamp, $Level.ToUpper(), $Message
    if ($script:LogFile) {
        try { Add-Content -Path $script:LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue } catch { }
    }
    switch ($Level) {
        'Section' { Write-Host "`n=== $Message ===" -ForegroundColor Cyan }
        'Success' { Write-Host "  [OK] $Message" -ForegroundColor Green }
        'Warn'    { Write-Warning $Message }
        'Error'   { Write-Host "  [FAIL] $Message" -ForegroundColor Red }
        'Debug'   { Write-Verbose $Message }
        default   { Write-Verbose $Message; Write-Host "  $Message" -ForegroundColor Gray }
    }
}

function Get-SafeFileName {
    <#
    .SYNOPSIS
        Strips characters that are invalid in file names and caps the length so
        GPO display names can safely become file names.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [int]$MaxLength = 140
    )
    $invalid = [System.IO.Path]::GetInvalidFileNameChars() -join ''
    $pattern = '[{0}]' -f [regex]::Escape($invalid)
    $safe = [regex]::Replace($Name, $pattern, '_')
    $safe = $safe.Trim().TrimEnd('.')
    if ([string]::IsNullOrWhiteSpace($safe)) { $safe = 'Unnamed' }
    if ($safe.Length -gt $MaxLength) { $safe = $safe.Substring(0, $MaxLength) }
    return $safe
}

function Get-PropertySafe {
    <#
    .SYNOPSIS
        StrictMode-safe property reader; returns $null when the property is absent.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][object]$InputObject,
        [Parameter(Mandatory)][string]$Name,
        [object]$Default = $null
    )
    if ($null -eq $InputObject) { return $Default }
    $prop = $InputObject.PSObject.Properties[$Name]
    if ($null -ne $prop) { return $prop.Value }
    return $Default
}

function Export-AuditDataset {
    <#
    .SYNOPSIS
        Registers a dataset and exports it to CSV + JSON for machine analysis.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter()][AllowNull()][object[]]$Data,
        [Parameter(Mandatory)][string]$Folder
    )
    if ($null -eq $Data) { $Data = @() }
    $script:Datasets[$Name] = $Data
    try {
        $csv  = Join-Path $Folder ("{0}.csv"  -f $Name)
        $json = Join-Path $Folder ("{0}.json" -f $Name)
        if ($Data.Count -gt 0) {
            $Data | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
        }
        else {
            Set-Content -Path $csv -Value '# no records collected' -Encoding UTF8
        }
        $Data | ConvertTo-Json -Depth 6 | Set-Content -Path $json -Encoding UTF8
        Write-AuditLog -Level Debug -Message "Exported dataset '$Name' ($($Data.Count) records)"
    }
    catch {
        Write-AuditLog -Level Warn -Message "Failed to export dataset '$Name': $($_.Exception.Message)"
    }
}

function Add-AuditFinding {
    <#
    .SYNOPSIS
        Records a categorized, severity-ranked finding for the reports.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Critical', 'High', 'Medium', 'Low', 'Informational')]
        [string]$Severity,
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Title,
        [Parameter()][string]$Detail = '',
        [Parameter()][string]$Recommendation = '',
        [Parameter()][string]$RelatedObject = ''
    )
    $script:Findings.Add([pscustomobject]@{
            Severity       = $Severity
            Category       = $Category
            Title          = $Title
            Detail         = $Detail
            Recommendation = $Recommendation
            RelatedObject  = $RelatedObject
            Timestamp      = (Get-Date -Format 's')
        })
    $lvl = 'Info'
    if ($Severity -in @('Critical', 'High')) { $lvl = 'Warn' }
    Write-AuditLog -Level $lvl -Message "FINDING [$Severity/$Category] $Title"
}

function Add-UnavailableItem {
    <#
    .SYNOPSIS
        Marks data that could not be collected (permissions / offline target) so
        the reports clearly distinguish "not collected" from "not present".
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Area,
        [Parameter(Mandatory)][string]$Reason
    )
    $script:Unavailable.Add([pscustomobject]@{ Area = $Area; Reason = $Reason })
    Write-AuditLog -Level Warn -Message "UNAVAILABLE: $Area - $Reason"
}

function Invoke-AuditStep {
    <#
    .SYNOPSIS
        Runs one collection phase; guarantees a single failed phase can never
        terminate the whole audit.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Action
    )
    Write-AuditLog -Level Section -Message $Name
    try {
        & $Action
    }
    catch {
        Write-AuditLog -Level Error -Message "Phase '$Name' failed: $($_.Exception.Message)"
        Add-UnavailableItem -Area $Name -Reason $_.Exception.Message
    }
}

# =============================================================================
#  Environment validation and prerequisites
# =============================================================================

function Test-IsAdministrator {
    [CmdletBinding()]
    param()
    try {
        $identity  = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        Write-AuditLog -Level Warn -Message "Administrator check failed: $($_.Exception.Message)"
        return $false
    }
}

function Get-HostOsInfo {
    <#
    .SYNOPSIS
        Returns OS caption, build, and whether this is a client or server SKU.
    #>
    [CmdletBinding()]
    param()
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    [pscustomobject]@{
        Caption     = $os.Caption
        Version     = $os.Version
        BuildNumber = $os.BuildNumber
        ProductType = $os.ProductType          # 1 = workstation, 2 = DC, 3 = server
        IsServer    = ($os.ProductType -ne 1)
        IsDC        = ($os.ProductType -eq 2)
        LastBoot    = $os.LastBootUpTime
        Edition     = (Get-PropertySafe -InputObject $os -Name 'OperatingSystemSKU')
    }
}

function Test-SupportedOperatingSystem {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$OsInfo)
    # Windows 10 = build 10240+, Server 2019 = 17763, 2022 = 20348, 2025 = 26100.
    $build = 0
    [void][int]::TryParse($OsInfo.BuildNumber, [ref]$build)
    if ($OsInfo.IsServer) {
        if ($build -lt 17763) {
            Write-AuditLog -Level Warn -Message "Server build $build predates Windows Server 2019; RSAT feature names may differ."
        }
    }
    elseif ($build -lt 10240) {
        throw "Unsupported operating system: $($OsInfo.Caption) (build $build). Windows 10 or later is required."
    }
    return $true
}

function Invoke-RelaunchInWindowsPowerShell {
    <#
    .SYNOPSIS
        Re-executes this script under powershell.exe 5.1, forwarding all bound
        parameters except -Credential (credentials are never serialized).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$BoundParameters)

    $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $exe)) {
        throw 'Windows PowerShell 5.1 (powershell.exe) was not found; cannot relaunch.'
    }
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath))
    foreach ($kvp in $BoundParameters.GetEnumerator()) {
        if ($kvp.Key -in @('Credential', 'RelaunchInWindowsPowerShell')) { continue }
        $value = $kvp.Value
        if ($value -is [switch] -or $value -is [bool]) {
            if ([bool]$value) { $argList += ('-{0}' -f $kvp.Key) }
        }
        else {
            $argList += ('-{0}' -f $kvp.Key)
            $argList += ('"{0}"' -f $value)
        }
    }
    if ($BoundParameters.ContainsKey('Credential')) {
        Write-Warning 'Credentials cannot be forwarded to the relaunched process; you will be prompted again if needed.'
    }
    Write-Host "`nRelaunching in Windows PowerShell 5.1..." -ForegroundColor Yellow
    Start-Process -FilePath $exe -ArgumentList $argList -Verb RunAs
    exit 0
}

function Import-AuditModule {
    <#
    .SYNOPSIS
        Imports one RSAT module, handling the PowerShell 7 compatibility layer.
        Returns 'Native', 'WinPSCompat', or 'Unavailable'.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$ProbeCommand
    )
    # Already loaded and functional?
    if (Get-Command -Name $ProbeCommand -ErrorAction SilentlyContinue) {
        return $(if ($PSVersionTable.PSEdition -eq 'Core') { 'WinPSCompat' } else { 'Native' })
    }
    if ($PSVersionTable.PSEdition -ne 'Core') {
        try {
            Import-Module -Name $Name -ErrorAction Stop -Verbose:$false
            if (Get-Command -Name $ProbeCommand -ErrorAction SilentlyContinue) { return 'Native' }
        }
        catch {
            Write-AuditLog -Level Warn -Message "Import-Module $Name failed: $($_.Exception.Message)"
        }
        return 'Unavailable'
    }
    # PowerShell 7: try native first (ActiveDirectory works natively on recent RSAT),
    # then the Windows PowerShell compatibility layer.
    try {
        Import-Module -Name $Name -ErrorAction Stop -Verbose:$false -WarningAction SilentlyContinue
        if (Get-Command -Name $ProbeCommand -ErrorAction SilentlyContinue) { return 'Native' }
    }
    catch {
        Write-AuditLog -Level Debug -Message "Native import of $Name under PS7 failed: $($_.Exception.Message)"
    }
    try {
        Write-AuditLog -Level Info -Message "Attempting: Import-Module $Name -UseWindowsPowerShell"
        Import-Module -Name $Name -UseWindowsPowerShell -ErrorAction Stop -Verbose:$false -WarningAction SilentlyContinue
        # Verify the proxied cmdlet genuinely works, not merely exists.
        if (Get-Command -Name $ProbeCommand -ErrorAction SilentlyContinue) {
            Write-AuditLog -Level Warn -Message "$Name loaded through the Windows PowerShell compatibility layer. Objects are serialized; Windows PowerShell 5.1 is recommended for full fidelity."
            return 'WinPSCompat'
        }
    }
    catch {
        Write-AuditLog -Level Warn -Message "Compatibility import of $Name failed: $($_.Exception.Message)"
    }
    return 'Unavailable'
}

function Install-AuditPrerequisites {
    <#
    .SYNOPSIS
        Detects and (with confirmation / -InstallPrerequisites) installs the RSAT
        Group Policy and Active Directory tools. Honors -WhatIf. Read-only apart
        from the installation itself.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][object]$OsInfo,
        [switch]$Unattended
    )

    $installed = @()
    $failed    = @()

    if (-not $OsInfo.IsServer) {
        # ---------------- Windows 10 / 11 client: RSAT capabilities ----------------
        $capabilityNames = @(
            'Rsat.GroupPolicy.Management.Tools~~~~0.0.1.0',
            'Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0'
        )
        if (-not (Get-Command -Name Get-WindowsCapability -ErrorAction SilentlyContinue)) {
            throw "This operating system does not expose Get-WindowsCapability; RSAT Features on Demand are not supported here ($($OsInfo.Caption)). Install RSAT manually."
        }
        foreach ($capName in $capabilityNames) {
            try {
                $cap = Get-WindowsCapability -Online -Name $capName -ErrorAction Stop
            }
            catch {
                Write-AuditLog -Level Error -Message "Capability query failed for ${capName}: $($_.Exception.Message)"
                $failed += $capName
                continue
            }
            if ($null -eq $cap) {
                Write-AuditLog -Level Error -Message "Capability $capName is not available on this OS."
                $failed += $capName
                continue
            }
            if ($cap.State -eq 'Installed') {
                Write-AuditLog -Level Success -Message "Capability already installed: $capName"
                continue
            }
            $proceed = $false
            if ($PSCmdlet.ShouldProcess($capName, 'Add-WindowsCapability -Online')) {
                if ($Unattended) { $proceed = $true }
                else {
                    $proceed = $PSCmdlet.ShouldContinue(
                        "Install Windows capability '$capName'? (requires internet or a configured FoD source)",
                        'RSAT prerequisite missing')
                }
            }
            if (-not $proceed) {
                Write-AuditLog -Level Warn -Message "Skipped installation of $capName (operator declined or -WhatIf)."
                $failed += $capName
                continue
            }
            try {
                Write-AuditLog -Level Info -Message "Installing capability $capName ..."
                $result = Add-WindowsCapability -Online -Name $capName -ErrorAction Stop
                $installed += $capName
                if ($result -and (Get-PropertySafe -InputObject $result -Name 'RestartNeeded')) {
                    $script:RestartNeeded = $true
                }
                Write-AuditLog -Level Success -Message "Installed capability $capName"
            }
            catch {
                Write-AuditLog -Level Error -Message "Failed to install ${capName}: $($_.Exception.Message)"
                $failed += $capName
            }
        }
    }
    else {
        # ---------------- Windows Server: features ----------------
        try {
            Import-Module -Name ServerManager -ErrorAction Stop -Verbose:$false
        }
        catch {
            throw "The ServerManager module is unavailable; cannot manage Windows features on $($OsInfo.Caption)."
        }
        foreach ($featureName in @('GPMC', 'RSAT-AD-PowerShell')) {
            try {
                $feature = Get-WindowsFeature -Name $featureName -ErrorAction Stop
            }
            catch {
                Write-AuditLog -Level Error -Message "Feature query failed for ${featureName}: $($_.Exception.Message)"
                $failed += $featureName
                continue
            }
            if ($null -eq $feature) {
                Write-AuditLog -Level Error -Message "Feature $featureName does not exist on this OS."
                $failed += $featureName
                continue
            }
            if ($feature.Installed) {
                Write-AuditLog -Level Success -Message "Feature already installed: $featureName"
                continue
            }
            $proceed = $false
            if ($PSCmdlet.ShouldProcess($featureName, 'Install-WindowsFeature')) {
                if ($Unattended) { $proceed = $true }
                else {
                    $proceed = $PSCmdlet.ShouldContinue(
                        "Install Windows feature '$featureName'?", 'RSAT prerequisite missing')
                }
            }
            if (-not $proceed) {
                Write-AuditLog -Level Warn -Message "Skipped installation of $featureName (operator declined or -WhatIf)."
                $failed += $featureName
                continue
            }
            try {
                Write-AuditLog -Level Info -Message "Installing feature $featureName ..."
                $result = Install-WindowsFeature -Name $featureName -ErrorAction Stop
                $installed += $featureName
                $restart = Get-PropertySafe -InputObject $result -Name 'RestartNeeded'
                if ("$restart" -match 'Yes|Pending') { $script:RestartNeeded = $true }
                if (-not $result.Success) {
                    Write-AuditLog -Level Error -Message "Install-WindowsFeature reported failure for $featureName (ExitCode: $($result.ExitCode))"
                    $failed += $featureName
                }
                else {
                    Write-AuditLog -Level Success -Message "Installed feature $featureName"
                }
            }
            catch {
                Write-AuditLog -Level Error -Message "Failed to install ${featureName}: $($_.Exception.Message)"
                $failed += $featureName
            }
        }
    }

    if ($script:RestartNeeded) {
        Write-AuditLog -Level Warn -Message 'A RESTART IS REQUIRED to complete prerequisite installation. The audit will continue, but rerun after restarting if modules fail to load.'
    }
    [pscustomobject]@{
        Installed     = $installed
        Failed        = $failed
        RestartNeeded = $script:RestartNeeded
    }
}

function Test-AuditConnectivity {
    <#
    .SYNOPSIS
        Verifies DC discovery, DNS, LDAP, and SMB/SYSVOL reachability.
        Records results as a dataset and raises findings for failures.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DomainName,
        [Parameter()][string]$PreferredDC
    )
    $results = New-Object System.Collections.Generic.List[object]
    $addResult = {
        param($Test, $Target, $Ok, $Detail)
        $results.Add([pscustomobject]@{
                Test = $Test; Target = $Target; Success = [bool]$Ok; Detail = "$Detail"
            })
        if ($Ok) { Write-AuditLog -Level Success -Message "$Test -> $Target" }
        else {
            Write-AuditLog -Level Error -Message "$Test -> $Target : $Detail"
        }
    }

    # --- Domain controller discovery ---
    $dc = $PreferredDC
    if (-not $dc) {
        try {
            $ctx = New-Object System.DirectoryServices.ActiveDirectory.DirectoryContext('Domain', $DomainName)
            $dcObj = [System.DirectoryServices.ActiveDirectory.DomainController]::FindOne($ctx)
            $dc = $dcObj.Name
            & $addResult 'DC discovery' $DomainName $true "Found $dc (site: $($dcObj.SiteName))"
        }
        catch {
            & $addResult 'DC discovery' $DomainName $false $_.Exception.Message
            Add-AuditFinding -Severity High -Category 'Connectivity' -Title 'Domain controller discovery failed' `
                -Detail $_.Exception.Message `
                -Recommendation 'Verify DNS client settings, SRV records (_ldap._tcp.dc._msdcs), and site/subnet mappings.'
            if ($env:LOGONSERVER) { $dc = $env:LOGONSERVER.TrimStart('\') }
        }
    }
    else {
        & $addResult 'DC discovery' $dc $true 'Operator-specified domain controller'
    }

    # --- ICMP / TCP reachability of the DC ---
    if ($dc) {
        $ping = Test-Connection -ComputerName $dc -Count 1 -Quiet -ErrorAction SilentlyContinue
        & $addResult 'DC ping (ICMP)' $dc $ping $(if ($ping) { 'reachable' } else { 'no ICMP reply (may be firewalled - not fatal)' })
    }

    # --- DNS resolution ---
    try {
        $dnsAnswer = Resolve-DnsName -Name $DomainName -Type A -ErrorAction Stop
        $ips = ($dnsAnswer | Where-Object { Get-PropertySafe -InputObject $_ -Name 'IPAddress' } |
            ForEach-Object { $_.IPAddress }) -join ', '
        & $addResult 'DNS resolution' $DomainName $true "Resolved: $ips"
    }
    catch {
        & $addResult 'DNS resolution' $DomainName $false $_.Exception.Message
        Add-AuditFinding -Severity Critical -Category 'Connectivity' -Title "DNS cannot resolve domain '$DomainName'" `
            -Detail $_.Exception.Message `
            -Recommendation 'Group Policy processing depends on DNS. Point the client at domain DNS servers.'
    }

    # --- LDAP: TCP 389 + an actual ADSI bind ---
    $ldapTarget = $(if ($dc) { $dc } else { $DomainName })
    $tcpOk = $false
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $async = $tcp.BeginConnect($ldapTarget, 389, $null, $null)
        if ($async.AsyncWaitHandle.WaitOne(5000) -and $tcp.Connected) { $tcpOk = $true }
        $tcp.Close()
    }
    catch { $tcpOk = $false }
    & $addResult 'LDAP TCP 389' $ldapTarget $tcpOk $(if ($tcpOk) { 'port open' } else { 'connection failed/timeout' })
    try {
        $rootDse = [ADSI]"LDAP://$ldapTarget/RootDSE"
        $defaultNC = $rootDse.Get('defaultNamingContext')
        & $addResult 'LDAP bind (RootDSE)' $ldapTarget $true "defaultNamingContext: $defaultNC"
    }
    catch {
        & $addResult 'LDAP bind (RootDSE)' $ldapTarget $false $_.Exception.Message
        Add-AuditFinding -Severity Critical -Category 'Connectivity' -Title 'LDAP bind to domain failed' `
            -Detail $_.Exception.Message `
            -Recommendation 'Verify network connectivity, firewall rules for TCP 389/636, and machine account health (Test-ComputerSecureChannel).'
    }

    # --- SMB: SYSVOL and NETLOGON ---
    foreach ($share in @('SYSVOL', 'NETLOGON')) {
        $unc = "\\$DomainName\$share"
        $ok = $false
        $detail = ''
        try {
            $ok = Test-Path -LiteralPath $unc -ErrorAction Stop
            $detail = $(if ($ok) { 'accessible' } else { 'not accessible' })
        }
        catch { $detail = $_.Exception.Message }
        & $addResult "SMB $share" $unc $ok $detail
        if (-not $ok) {
            Add-AuditFinding -Severity Critical -Category 'Connectivity' -Title "Cannot access $unc" `
                -Detail $detail `
                -Recommendation 'Clients must read SYSVOL/NETLOGON to apply policy. Check SMB connectivity (TCP 445), DFS namespace health, and SYSVOL replication (DFSR).'
        }
    }

    Export-AuditDataset -Name 'ConnectivityTests' -Data $results.ToArray() -Folder $script:Paths.Summary
    return @{ DomainController = $dc; Results = $results.ToArray() }
}

# =============================================================================
#  Target computer collection: identity, gpresult, RSOP, event logs
# =============================================================================

function Test-LocalTarget {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $short = ($Name -split '\.')[0]
    return ($Name -in @('.', 'localhost') -or
        $short -eq $env:COMPUTERNAME -or
        $Name -eq $env:COMPUTERNAME)
}

function Test-TargetConnectivity {
    <#
    .SYNOPSIS
        For remote targets: tests ping, WinRM, and CIM (WSMan then DCOM) and
        opens a CIM session that later phases reuse.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Target)

    $script:TargetOnline   = $false
    $script:WinRMAvailable = $false
    $script:CimSession     = $null

    if ($script:IsLocalTarget) {
        $script:TargetOnline = $true
        return
    }
    Write-AuditLog -Level Info -Message "Testing connectivity to remote target $Target ..."
    $script:TargetOnline = Test-Connection -ComputerName $Target -Count 2 -Quiet -ErrorAction SilentlyContinue
    if (-not $script:TargetOnline) {
        Write-AuditLog -Level Warn -Message "$Target does not answer ICMP; continuing (ping may be firewalled)."
    }

    # WinRM
    try {
        $wsmanParams = @{ ComputerName = $Target; ErrorAction = 'Stop' }
        if ($script:HasCredential) { $wsmanParams.Credential = $Credential; $wsmanParams.Authentication = 'Default' }
        $null = Test-WSMan @wsmanParams
        $script:WinRMAvailable = $true
        $script:TargetOnline   = $true
        Write-AuditLog -Level Success -Message "WinRM is available on $Target"
    }
    catch {
        Write-AuditLog -Level Warn -Message "WinRM unavailable on ${Target}: $($_.Exception.Message)"
    }

    # CIM: WSMan first, then DCOM fallback
    foreach ($proto in @('Wsman', 'Dcom')) {
        if ($script:CimSession) { break }
        try {
            $opt = New-CimSessionOption -Protocol $proto
            $cimParams = @{ ComputerName = $Target; SessionOption = $opt; ErrorAction = 'Stop'; OperationTimeoutSec = 30 }
            if ($script:HasCredential) { $cimParams.Credential = $Credential }
            $script:CimSession = New-CimSession @cimParams
            $script:TargetOnline = $true
            Write-AuditLog -Level Success -Message "CIM session established to $Target via $proto"
        }
        catch {
            Write-AuditLog -Level Warn -Message "CIM via $proto failed for ${Target}: $($_.Exception.Message)"
        }
    }
    if (-not ($script:WinRMAvailable -or $script:CimSession)) {
        Add-UnavailableItem -Area "Remote collection from $Target" `
            -Reason 'Neither WinRM nor RPC/DCOM CIM connectivity is available. Only domain-side data can be collected. gpresult, event logs, and registry state require the target to be online and reachable.'
    }
}

function Get-TargetComputerInfo {
    <#
    .SYNOPSIS
        Collects identity, OS, network, and Group Policy client state for the
        target computer (local directly; remote via CIM/WinRM/AD).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Target)

    $info = [ordered]@{
        Hostname             = $Target
        FQDN                 = 'UNAVAILABLE'
        Domain               = 'UNAVAILABLE'
        OrganizationalUnitDN = 'UNAVAILABLE'
        ADSite               = 'UNAVAILABLE'
        OperatingSystem      = 'UNAVAILABLE'
        OSBuild              = 'UNAVAILABLE'
        LastBootTime         = 'UNAVAILABLE'
        LoggedOnUser         = 'UNAVAILABLE'
        DomainController     = 'UNAVAILABLE'
        NetworkAdapters      = 'UNAVAILABLE'
        DNSServers           = 'UNAVAILABLE'
        LoopbackMode         = 'Not configured'
        GPProcessingNotes    = ''
        LastGPRefreshMachine = 'UNAVAILABLE'
        SlowLink             = 'See RSOP XML'
        LocalGPOPresent      = 'UNAVAILABLE'
    }

    # ---- CIM data (OS, computer system, NICs) ----
    $cimCommon = @{ ErrorAction = 'Stop' }
    if (-not $script:IsLocalTarget) {
        if ($script:CimSession) { $cimCommon.CimSession = $script:CimSession }
        else { $cimCommon = $null }
    }
    if ($null -ne $cimCommon) {
        try {
            $cs = Get-CimInstance -ClassName Win32_ComputerSystem @cimCommon
            $os = Get-CimInstance -ClassName Win32_OperatingSystem @cimCommon
            $info.Hostname        = $cs.Name
            $info.Domain          = $cs.Domain
            $info.FQDN            = '{0}.{1}' -f $cs.DNSHostName, $cs.Domain
            $info.OperatingSystem = $os.Caption
            $info.OSBuild         = '{0} (build {1})' -f $os.Version, $os.BuildNumber
            $info.LastBootTime    = $os.LastBootUpTime
            $info.LoggedOnUser    = $(if ($cs.UserName) { $cs.UserName } else { '(no interactive user)' })
            $nics = Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter 'IPEnabled = TRUE' @cimCommon
            $info.NetworkAdapters = ($nics | ForEach-Object {
                    '{0} [{1}]' -f $_.Description, (@($_.IPAddress) -join ' ')
                }) -join '; '
            $info.DNSServers = ($nics | ForEach-Object { @($_.DNSServerSearchOrder) } |
                Where-Object { $_ } | Select-Object -Unique) -join ', '
        }
        catch {
            Add-UnavailableItem -Area 'Target CIM inventory' -Reason $_.Exception.Message
        }
    }
    else {
        Add-UnavailableItem -Area 'Target CIM inventory' -Reason 'No CIM connectivity to remote target.'
    }

    # ---- AD object: OU distinguished name ----
    try {
        if (Get-Command Get-ADComputer -ErrorAction SilentlyContinue) {
            $short = ($Target -split '\.')[0]
            $adComp = Get-ADComputer -Identity $short -Properties CanonicalName, DistinguishedName, OperatingSystem @script:AdParams -ErrorAction Stop
            $info.OrganizationalUnitDN = ($adComp.DistinguishedName -replace '^CN=[^,]+,', '')
            if ($info.FQDN -eq 'UNAVAILABLE') { $info.FQDN = $adComp.DNSHostName }
            if ($info.OperatingSystem -eq 'UNAVAILABLE' -and $adComp.OperatingSystem) {
                $info.OperatingSystem = "$($adComp.OperatingSystem) (from AD)"
            }
        }
    }
    catch {
        Add-UnavailableItem -Area 'AD computer object' -Reason $_.Exception.Message
    }

    # ---- Group Policy client state (registry) + AD site + DC ----
    $stateScript = {
        $out = @{}
        try {
            $gpState = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\State\Machine'
            if (Test-Path $gpState) {
                $p = Get-ItemProperty -Path $gpState -ErrorAction SilentlyContinue
                if ($p) {
                    if ($p.PSObject.Properties['Site-Name'])            { $out.Site = $p.'Site-Name' }
                    if ($p.PSObject.Properties['Distinguished-Name'])   { $out.DN   = $p.'Distinguished-Name' }
                }
            }
            $hist = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\History'
            if (Test-Path $hist) {
                $h = Get-ItemProperty -Path $hist -ErrorAction SilentlyContinue
                if ($h -and $h.PSObject.Properties['DCName']) { $out.DC = $h.DCName -replace '^\\\\', '' }
            }
            $loop = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' -Name UserPolicyMode -ErrorAction SilentlyContinue
            if ($loop) {
                $out.Loopback = switch ($loop.UserPolicyMode) { 1 { 'Merge' } 2 { 'Replace' } default { "Unknown ($($loop.UserPolicyMode))" } }
            }
            # Last machine GP refresh: Extension-List key write times approximate it;
            # scheduled-task query is more reliable when available.
            $gt = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\State\Machine\Extension-List' -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($gt) {
                $ep = Get-ItemProperty -Path $gt.PSPath -ErrorAction SilentlyContinue
                foreach ($n in 'EndTimeHi', 'EndTimeLo') {
                    if (-not ($ep -and $ep.PSObject.Properties[$n])) { $ep = $null; break }
                }
                if ($ep) {
                    $ft = ([Int64]$ep.EndTimeHi -shl 32) -bor ([Int64]$ep.EndTimeLo -band 0xFFFFFFFFL)
                    try { $out.LastRefresh = [DateTime]::FromFileTime($ft).ToString('s') } catch { }
                }
            }
            $out.LocalGpo = Test-Path (Join-Path $env:SystemRoot 'System32\GroupPolicy\gpt.ini')
        }
        catch { $out.Error = $_.Exception.Message }
        $out
    }
    $state = $null
    try {
        if ($script:IsLocalTarget) { $state = & $stateScript }
        elseif ($script:WinRMAvailable) {
            $icm = @{ ComputerName = $Target; ScriptBlock = $stateScript; ErrorAction = 'Stop' }
            if ($script:HasCredential) { $icm.Credential = $Credential }
            $state = Invoke-Command @icm
        }
        else {
            Add-UnavailableItem -Area 'Group Policy client registry state' -Reason 'Requires local execution or WinRM on the target.'
        }
    }
    catch {
        Add-UnavailableItem -Area 'Group Policy client registry state' -Reason $_.Exception.Message
    }
    if ($state) {
        if ($state.ContainsKey('Site'))        { $info.ADSite = $state.Site }
        if ($state.ContainsKey('DC'))          { $info.DomainController = $state.DC }
        if ($state.ContainsKey('Loopback'))    { $info.LoopbackMode = $state.Loopback }
        if ($state.ContainsKey('LastRefresh')) { $info.LastGPRefreshMachine = $state.LastRefresh }
        if ($state.ContainsKey('LocalGpo'))    { $info.LocalGPOPresent = $state.LocalGpo }
        if ($state.ContainsKey('DN') -and $info.OrganizationalUnitDN -eq 'UNAVAILABLE') {
            $info.OrganizationalUnitDN = ($state.DN -replace '^CN=[^,]+,', '')
        }
    }
    if ($script:IsLocalTarget -and $info.ADSite -eq 'UNAVAILABLE') {
        try { $info.ADSite = [System.DirectoryServices.ActiveDirectory.ActiveDirectorySite]::GetComputerSite().Name } catch { }
    }
    if ($info.LoopbackMode -notin @('Not configured')) {
        Add-AuditFinding -Severity Informational -Category 'Processing' `
            -Title "Loopback processing is enabled ($($info.LoopbackMode)) on $Target" `
            -Detail 'User settings are drawn (Merge) or replaced (Replace) from GPOs scoped to the COMPUTER object.' `
            -Recommendation 'Verify loopback is intentional; it commonly explains "unexpected" user policy results.' `
            -RelatedObject $Target
    }

    $obj = [pscustomobject]$info
    Export-AuditDataset -Name 'ComputerInfo' -Data @($obj) -Folder $script:Paths.Computer
    return $obj
}

function Invoke-GpResultCollection {
    <#
    .SYNOPSIS
        Runs gpresult /R, /Z, /H, /X for the computer (and user when specified),
        locally or via WinRM for remote targets. Every variant is independent;
        one failure never stops the rest.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter()][string]$User
    )
    $rsopDir = $script:Paths.RSOP

    # Build the gpresult jobs. /H and /X produce files; /R and /Z produce text.
    $jobs = @(
        @{ Label = 'gpresult-R';  Args = @('/R');                    OutFile = $null;  Capture = $true }
        @{ Label = 'gpresult-Z';  Args = @('/Z');                    OutFile = $null;  Capture = $true }
        @{ Label = 'gpresult-H';  Args = @('/H');  Ext = 'html';     OutFile = 'GPResult.html'; Capture = $false }
        @{ Label = 'gpresult-X';  Args = @('/X');  Ext = 'xml';      OutFile = 'GPResult.xml';  Capture = $false }
    )

    $userArgs = @()
    if ($User) { $userArgs = @('/USER', $User) }
    elseif (-not $script:IsLocalTarget) {
        # Remote with no interactive user context: restrict to computer scope so
        # gpresult does not fail looking for a logged-on user profile.
        $userArgs = @('/SCOPE', 'COMPUTER')
    }

    foreach ($job in $jobs) {
        $label = $job.Label
        try {
            if ($script:IsLocalTarget) {
                if ($job.Capture) {
                    $txtPath = Join-Path $rsopDir ("{0}.txt" -f $label)
                    $output = & "$env:SystemRoot\System32\gpresult.exe" @($job.Args + $userArgs) 2>&1
                    $exit = $LASTEXITCODE
                    $output | Out-File -FilePath $txtPath -Encoding UTF8
                    if ($exit -ne 0) { throw "gpresult exited with code $exit. Output: $(($output | Select-Object -First 3) -join ' ')" }
                }
                else {
                    $filePath = Join-Path $rsopDir $job.OutFile
                    $output = & "$env:SystemRoot\System32\gpresult.exe" @($job.Args + @($filePath, '/F') + $userArgs) 2>&1
                    if ($LASTEXITCODE -ne 0) { throw "gpresult exited with code $LASTEXITCODE. Output: $(($output | Select-Object -First 3) -join ' ')" }
                }
                Write-AuditLog -Level Success -Message "$label collected"
            }
            elseif ($script:WinRMAvailable) {
                # Remote: run on the target, write to its TEMP, copy the file back.
                $icm = @{ ComputerName = $Target; ErrorAction = 'Stop' }
                if ($script:HasCredential) { $icm.Credential = $Credential }
                if ($job.Capture) {
                    $txtPath = Join-Path $rsopDir ("{0}.txt" -f $label)
                    $remoteArgs = $job.Args + $userArgs
                    $output = Invoke-Command @icm -ScriptBlock {
                        param($a) & "$env:SystemRoot\System32\gpresult.exe" @a 2>&1 | Out-String
                    } -ArgumentList (, $remoteArgs)
                    $output | Out-File -FilePath $txtPath -Encoding UTF8
                }
                else {
                    $session = New-PSSession @icm
                    try {
                        $remoteFile = Invoke-Command -Session $session -ScriptBlock {
                            param($a, $name)
                            $f = Join-Path $env:TEMP $name
                            & "$env:SystemRoot\System32\gpresult.exe" @($a + @($f, '/F')) 2>&1 | Out-Null
                            if (Test-Path $f) { $f } else { $null }
                        } -ArgumentList (, ($job.Args + $userArgs)), $job.OutFile
                        if ($remoteFile) {
                            Copy-Item -FromSession $session -Path $remoteFile -Destination (Join-Path $rsopDir $job.OutFile) -ErrorAction Stop
                            Invoke-Command -Session $session -ScriptBlock { param($f) Remove-Item $f -ErrorAction SilentlyContinue } -ArgumentList $remoteFile
                        }
                        else { throw 'gpresult did not produce an output file on the remote host.' }
                    }
                    finally { Remove-PSSession -Session $session -ErrorAction SilentlyContinue }
                }
                Write-AuditLog -Level Success -Message "$label collected remotely via WinRM"
            }
            else {
                # Last resort: gpresult /S uses RPC with the CURRENT user's context.
                # /U /P is deliberately NOT used - it would expose a password on the
                # command line and in process listings.
                if ($script:HasCredential) {
                    Write-AuditLog -Level Warn -Message "gpresult /S cannot use -Credential safely; running as current user. Enable WinRM on $Target for credentialed collection."
                }
                if ($job.Capture) {
                    $txtPath = Join-Path $rsopDir ("{0}.txt" -f $label)
                    $output = & "$env:SystemRoot\System32\gpresult.exe" @(@('/S', $Target) + $job.Args + $userArgs) 2>&1
                    if ($LASTEXITCODE -ne 0) { throw "gpresult /S exited with code $LASTEXITCODE" }
                    $output | Out-File -FilePath $txtPath -Encoding UTF8
                }
                else {
                    $filePath = Join-Path $rsopDir $job.OutFile
                    $output = & "$env:SystemRoot\System32\gpresult.exe" @(@('/S', $Target) + $job.Args + @($filePath, '/F') + $userArgs) 2>&1
                    if ($LASTEXITCODE -ne 0) { throw "gpresult /S exited with code $LASTEXITCODE" }
                }
                Write-AuditLog -Level Success -Message "$label collected remotely via RPC (gpresult /S)"
            }
        }
        catch {
            Write-AuditLog -Level Error -Message "$label failed: $($_.Exception.Message)"
            Add-UnavailableItem -Area $label -Reason $_.Exception.Message
        }
    }
}

function Invoke-RsopCollection {
    <#
    .SYNOPSIS
        Get-GPResultantSetOfPolicy XML/HTML reports (module-based RSOP), which can
        differ from gpresult and is worth capturing separately.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter()][string]$User
    )
    if (-not (Get-Command Get-GPResultantSetOfPolicy -ErrorAction SilentlyContinue)) {
        Add-UnavailableItem -Area 'Get-GPResultantSetOfPolicy' -Reason 'Cmdlet not available (GroupPolicy module missing or compatibility-layer limitation).'
        return
    }
    $firstReport = $true
    foreach ($type in @('Xml', 'Html')) {
        $path = Join-Path $script:Paths.RSOP ("RSOP-GPMC.{0}" -f $type.ToLower())
        $params = @{ ReportType = $type; Path = $path; ErrorAction = 'Stop' }
        if (-not $script:IsLocalTarget) { $params.Computer = $Target }
        if ($User) { $params.User = $User }
        # Back-to-back invocations race the teardown of the previous call's
        # temporary RSOP WMI namespace; losing the race surfaces as a raw
        # NullReferenceException from the GPMC interop. Pause between report
        # types and retry on that signature.
        if (-not $firstReport) { Start-Sleep -Seconds 5 }
        $firstReport = $false
        $maxAttempts = 3
        for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
            try {
                $null = Get-GPResultantSetOfPolicy @params
                $note = $(if ($attempt -gt 1) { " (attempt $attempt)" } else { '' })
                Write-AuditLog -Level Success -Message "Get-GPResultantSetOfPolicy ($type) collected$note"
                break
            }
            catch {
                $msg = $_.Exception.Message
                $transient = ($msg -match 'Object reference not set|0x80041001|provider failure')
                if ($transient -and $attempt -lt $maxAttempts) {
                    Write-AuditLog -Level Warn -Message "Get-GPResultantSetOfPolicy ($type) attempt ${attempt}: transient RSOP provider error; retrying in 5s..."
                    Start-Sleep -Seconds 5
                    continue
                }
                # Terminal causes: user never logged on, RSOP WMI namespace access denied, target offline.
                Write-AuditLog -Level Error -Message "Get-GPResultantSetOfPolicy ($type) failed: $msg"
                Add-UnavailableItem -Area "Get-GPResultantSetOfPolicy ($type)" -Reason $msg
                break
            }
        }
    }
}

function Get-GroupPolicyEventLogData {
    <#
    .SYNOPSIS
        Collects Microsoft-Windows-GroupPolicy/Operational events, classifies
        them, exports CSV (+EVTX where practical), and raises findings.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][int]$Days
    )
    $logName = 'Microsoft-Windows-GroupPolicy/Operational'
    $since   = (Get-Date).AddDays(-1 * $Days)
    $events  = $null

    try {
        $filter = @{ LogName = $logName; StartTime = $since }
        $params = @{ FilterHashtable = $filter; ErrorAction = 'Stop'; MaxEvents = 5000 }
        if (-not $script:IsLocalTarget) {
            $params.ComputerName = $Target
            if ($script:HasCredential) { $params.Credential = $Credential }
        }
        $events = Get-WinEvent @params
    }
    catch [Exception] {
        if ($_.Exception.Message -match 'No events were found') {
            Write-AuditLog -Level Info -Message "No Group Policy operational events in the last $Days days."
            $events = @()
        }
        else {
            Add-UnavailableItem -Area 'GroupPolicy operational event log' -Reason $_.Exception.Message
            return
        }
    }

    # Event ID classification for the Microsoft-Windows-GroupPolicy provider:
    #   4000-4299 start of processing      5000-5299 success details
    #   5312 applied GPO list              5313 denied/filtered GPO list
    #   5314 loopback mode                 5320-5321 filtering detail
    #   6000-6299 warnings                 7000-7299 errors during processing
    #   8000-8007 processing completed (property 0 = elapsed seconds)
    #   1058/1030/1096 SYSVOL access       1054/1055 DC/network discovery
    $classify = {
        param($id, $level)
        if ($level -eq 2) { return 'Error' }
        if ($level -eq 3) { return 'Warning' }
        switch ($id) {
            { $_ -in 1054, 1055, 5308, 5326 } { 'DC/Network discovery'; break }
            { $_ -in 1058, 1030, 1096 }       { 'SYSVOL access'; break }
            { $_ -in 5312 }                   { 'Applied GPO list'; break }
            { $_ -in 5313 }                   { 'Denied GPO list (filtering)'; break }
            { $_ -in 5314 }                   { 'Loopback'; break }
            { $_ -in 5320, 5321 }             { 'Security/WMI filtering'; break }
            { $_ -ge 4000 -and $_ -lt 4300 }  { 'Processing start'; break }
            { $_ -ge 5016 -and $_ -le 5017 }  { 'Extension processing (CSE)'; break }
            { $_ -ge 6000 -and $_ -lt 6300 }  { 'Warning'; break }
            { $_ -ge 7000 -and $_ -lt 7300 }  { 'Processing error'; break }
            { $_ -ge 8000 -and $_ -le 8007 }  { 'Processing completed'; break }
            default                           { 'Other' }
        }
    }

    $records = New-Object System.Collections.Generic.List[object]
    $errorCount = 0
    $slowCount  = 0
    foreach ($ev in @($events)) {
        $category = & $classify $ev.Id $ev.Level
        $duration = $null
        if ($ev.Id -ge 8000 -and $ev.Id -le 8007) {
            try {
                if ($ev.Properties.Count -gt 0) { $duration = [double]$ev.Properties[0].Value }
            }
            catch { }
        }
        elseif ($ev.Id -in 5016, 6016, 7016) {
            try {
                if ($ev.Properties.Count -gt 0) { $duration = [math]::Round(([double]$ev.Properties[0].Value) / 1000.0, 1) }
            }
            catch { }
        }
        if ($ev.Level -eq 2) { $errorCount++ }
        if ($null -ne $duration -and $duration -gt 60) { $slowCount++ }
        $records.Add([pscustomobject]@{
                TimeCreated  = $ev.TimeCreated
                Id           = $ev.Id
                Level        = $ev.LevelDisplayName
                Category     = $category
                DurationSec  = $duration
                ActivityId   = "$($ev.ActivityId)"
                Message      = ($ev.Message -replace '\r?\n', ' | ')
            })
    }
    Export-AuditDataset -Name 'GroupPolicyEvents' -Data $records.ToArray() -Folder $script:Paths.EventLogs

    # EVTX export (local: wevtutil; remote: via WinRM + copy)
    try {
        $evtxPath = Join-Path $script:Paths.EventLogs 'GroupPolicy-Operational.evtx'
        if ($script:IsLocalTarget) {
            & "$env:SystemRoot\System32\wevtutil.exe" epl $logName $evtxPath /ow:true 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { Write-AuditLog -Level Success -Message 'EVTX export completed' }
            else { throw "wevtutil exited with code $LASTEXITCODE" }
        }
        elseif ($script:WinRMAvailable) {
            $icm = @{ ComputerName = $Target; ErrorAction = 'Stop' }
            if ($script:HasCredential) { $icm.Credential = $Credential }
            $session = New-PSSession @icm
            try {
                $remoteFile = Invoke-Command -Session $session -ScriptBlock {
                    param($ln)
                    $f = Join-Path $env:TEMP 'GPAudit-GPO-Operational.evtx'
                    Remove-Item $f -ErrorAction SilentlyContinue
                    & "$env:SystemRoot\System32\wevtutil.exe" epl $ln $f 2>&1 | Out-Null
                    if (Test-Path $f) { $f } else { $null }
                } -ArgumentList $logName
                if ($remoteFile) {
                    Copy-Item -FromSession $session -Path $remoteFile -Destination $evtxPath -ErrorAction Stop
                    Invoke-Command -Session $session -ScriptBlock { param($f) Remove-Item $f -ErrorAction SilentlyContinue } -ArgumentList $remoteFile
                    Write-AuditLog -Level Success -Message 'EVTX export copied from remote target'
                }
            }
            finally { Remove-PSSession -Session $session -ErrorAction SilentlyContinue }
        }
        else {
            Add-UnavailableItem -Area 'EVTX export' -Reason 'Requires local execution or WinRM.'
        }
    }
    catch {
        Add-UnavailableItem -Area 'EVTX export' -Reason $_.Exception.Message
    }

    # Findings from event evidence
    if ($errorCount -gt 0) {
        Add-AuditFinding -Severity High -Category 'Processing' `
            -Title "$errorCount Group Policy processing error event(s) in the last $Days days on $Target" `
            -Detail 'See EventLogs\GroupPolicyEvents.csv (Level = Error). Errors 7000-7017 indicate failed processing; 1058/1030 indicate SYSVOL access failures; 1054/1055 indicate DC discovery problems.' `
            -Recommendation 'Investigate the specific event messages; run "gpupdate /force" interactively and re-check, validate DNS/DC reachability and SYSVOL permissions.' `
            -RelatedObject $Target
    }
    if ($slowCount -gt 0) {
        Add-AuditFinding -Severity Medium -Category 'Performance' `
            -Title "$slowCount slow Group Policy processing event(s) (>60s) on $Target" `
            -Detail 'Long processing durations were reported by completion events (8000-8007) or CSE events (5016/7016).' `
            -Recommendation 'Review which client-side extensions are slow (event 5016 per-CSE durations); common causes are unreachable file shares in preferences, WMI filters using Win32_Product, and folder redirection.' `
            -RelatedObject $Target
    }
    if ($records.Count -ge 5000) {
        Write-AuditLog -Level Warn -Message 'Event collection reached the 5000-event cap; older events were not analyzed (the EVTX export contains the full log).'
    }
    Write-AuditLog -Level Info -Message "Collected $($records.Count) events ($errorCount errors, $slowCount slow)."
}

# =============================================================================
#  Domain-side collection: GPO inventory, links, permissions, WMI filters
# =============================================================================

function Get-DomainGpoInventory {
    <#
    .SYNOPSIS
        Enumerates every GPO in the domain with full metadata, content analysis
        from its XML report, and per-GPO HTML + XML report files.
    #>
    [CmdletBinding()]
    param()

    try {
        $script:AllGpos = @(Get-GPO -All @script:GpParams -ErrorAction Stop)
    }
    catch {
        Add-UnavailableItem -Area 'Domain GPO inventory' -Reason $_.Exception.Message
        return @()
    }
    Write-AuditLog -Level Info -Message "Found $($script:AllGpos.Count) GPOs in the domain."

    # GPP extension display names (used to detect preference content).
    $gppNames = @('Drive Maps', 'Files', 'Folders', 'Ini Files', 'Shortcuts', 'Environment',
        'Local Users and Groups', 'Devices', 'Network Options', 'Network Shares',
        'Power Options', 'Regional Options', 'Start Menu', 'Internet Settings',
        'Applications', 'Data Sources', 'Folder Options', 'Registry')

    $inventory = New-Object System.Collections.Generic.List[object]
    $i = 0
    foreach ($gpo in $script:AllGpos) {
        $i++
        Write-Progress -Activity 'Domain GPO inventory' -Status $gpo.DisplayName -PercentComplete ([int](100 * $i / [math]::Max(1, $script:AllGpos.Count)))
        $safeName = Get-SafeFileName -Name ('{0}_{1}' -f $gpo.DisplayName, $gpo.Id.ToString().Substring(0, 8))

        # ---- Per-GPO XML + HTML reports ----
        $reportXmlText = $null
        foreach ($rt in @('Xml', 'Html')) {
            try {
                $ext = $rt.ToLower()
                $reportPath = Join-Path $script:Paths.DomainGPOs ("{0}.{1}" -f $safeName, $ext)
                $report = Get-GPOReport -Guid $gpo.Id -ReportType $rt @script:GpParams -ErrorAction Stop
                Set-Content -Path $reportPath -Value $report -Encoding UTF8
                if ($rt -eq 'Xml') { $reportXmlText = $report }
            }
            catch {
                Add-UnavailableItem -Area "GPO report ($rt): $($gpo.DisplayName)" -Reason $_.Exception.Message
            }
        }

        # ---- Content analysis from the XML report ----
        $extNamesComputer = @()
        $extNamesUser     = @()
        $isEmpty          = $null
        if ($reportXmlText) {
            try {
                $xml = [xml]$reportXmlText
                $extNamesComputer = @($xml.SelectNodes("//*[local-name()='Computer']/*[local-name()='ExtensionData']/*[local-name()='Name']") | ForEach-Object { $_.InnerText })
                $extNamesUser     = @($xml.SelectNodes("//*[local-name()='User']/*[local-name()='ExtensionData']/*[local-name()='Name']") | ForEach-Object { $_.InnerText })
                $isEmpty          = (($extNamesComputer.Count + $extNamesUser.Count) -eq 0)
            }
            catch {
                Write-AuditLog -Level Warn -Message "Could not parse XML report for $($gpo.DisplayName): $($_.Exception.Message)"
            }
        }
        $allExtNames = @($extNamesComputer + $extNamesUser)
        $hasPref = [bool](@($allExtNames | Where-Object { $_ -in $gppNames -and $_ -ne 'Registry' }).Count -gt 0)
        # Preference "Registry" vs Administrative Templates "Registry" share a display
        # name; detect GPP registry via its namespace marker in the raw XML.
        if (-not $hasPref -and $reportXmlText -and $reportXmlText -match 'RegistrySettings\s+clsid=') { $hasPref = $true }

        $wmiFilterName = ''
        $wmiObj = Get-PropertySafe -InputObject $gpo -Name 'WmiFilter'
        if ($wmiObj) { $wmiFilterName = "$(Get-PropertySafe -InputObject $wmiObj -Name 'Name')" }

        $record = [pscustomobject]@{
            DisplayName             = $gpo.DisplayName
            Id                      = $gpo.Id
            DomainName              = $gpo.DomainName
            Owner                   = $gpo.Owner
            Description             = $gpo.Description
            CreationTime            = $gpo.CreationTime
            ModificationTime        = $gpo.ModificationTime
            UserDSVersion           = $gpo.User.DSVersion
            UserSysvolVersion       = $gpo.User.SysvolVersion
            ComputerDSVersion       = $gpo.Computer.DSVersion
            ComputerSysvolVersion   = $gpo.Computer.SysvolVersion
            GpoStatus               = "$($gpo.GpoStatus)"
            UserSettingsEnabled     = $gpo.User.Enabled
            ComputerSettingsEnabled = $gpo.Computer.Enabled
            WmiFilter               = $wmiFilterName
            IsFullyDisabled         = ("$($gpo.GpoStatus)" -eq 'AllSettingsDisabled')
            IsHalfDisabled          = ("$($gpo.GpoStatus)" -in @('UserSettingsDisabled', 'ComputerSettingsDisabled'))
            AppearsEmpty            = $isEmpty
            IsLinked                = $null     # filled in by link inventory
            ContainsPreferences     = $hasPref
            ContainsScripts         = [bool]($allExtNames -contains 'Scripts')
            ContainsScheduledTasks  = [bool]($allExtNames -contains 'Scheduled Tasks')
            ContainsDriveMaps       = [bool]($allExtNames -contains 'Drive Maps')
            ContainsRegistryPrefs   = [bool]($reportXmlText -and $reportXmlText -match 'RegistrySettings\s+clsid=')
            ContainsPrinters        = [bool](($allExtNames -contains 'Printers') -or ($allExtNames -contains 'Deployed Printer Connections'))
            ContainsSoftwareInstall = [bool]($allExtNames -contains 'Software Installation')
            Extensions              = ($allExtNames | Select-Object -Unique) -join '; '
            ReportFile              = "$safeName.html"
            VersionMismatch         = (($gpo.User.DSVersion -ne $gpo.User.SysvolVersion) -or ($gpo.Computer.DSVersion -ne $gpo.Computer.SysvolVersion))
        }
        $inventory.Add($record)
    }
    Write-Progress -Activity 'Domain GPO inventory' -Completed
    Export-AuditDataset -Name 'DomainGPOInventory' -Data $inventory.ToArray() -Folder $script:Paths.DomainGPOs
    return $inventory.ToArray()
}

function ConvertFrom-GPLinkAttribute {
    <#
    .SYNOPSIS
        Parses a raw gPLink attribute string into link records.
        Flag bit 0 = link disabled, bit 1 = enforced.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowEmptyString()][AllowNull()][string]$GPLink,
        [Parameter(Mandatory)][string]$TargetDN,
        [Parameter(Mandatory)][string]$TargetType,
        [Parameter()][string]$CanonicalName = '',
        [Parameter()][bool]$BlockInheritance = $false
    )
    $links = @()
    if ([string]::IsNullOrWhiteSpace($GPLink)) { return $links }
    $rx = [regex]'\[LDAP://[cC][nN]=\{(?<guid>[0-9a-fA-F\-]+)\}[^;]*;(?<flags>\d+)\]'
    $matchList = $rx.Matches($GPLink)
    $order = 0
    foreach ($m in $matchList) {
        # gPLink stores links left-to-right in GPMC display order (link order 1 first).
        $order++
        $flags = [int]$m.Groups['flags'].Value
        $links += [pscustomobject]@{
            GpoGuid          = [guid]$m.Groups['guid'].Value
            TargetDN         = $TargetDN
            TargetType       = $TargetType
            CanonicalName    = $CanonicalName
            LinkOrder        = $order
            Enabled          = (($flags -band 1) -eq 0)
            Enforced         = (($flags -band 2) -ne 0)
            BlockInheritance = $BlockInheritance
        }
    }
    return $links
}

function Get-GpoLinkInventory {
    <#
    .SYNOPSIS
        Enumerates GPO links at site, domain, and OU level (raw gPLink parse),
        plus Get-GPInheritance effective inheritance for the domain and each OU.
    #>
    [CmdletBinding()]
    param()

    $allLinks    = New-Object System.Collections.Generic.List[object]
    $inheritance = New-Object System.Collections.Generic.List[object]

    # GUID -> display name map for link resolution
    $gpoByGuid = @{}
    foreach ($g in $script:AllGpos) { $gpoByGuid[$g.Id.ToString().ToLower()] = $g }

    $resolveName = {
        param($guid)
        $key = $guid.ToString().ToLower()
        if ($gpoByGuid.ContainsKey($key)) { return $gpoByGuid[$key].DisplayName }
        try {
            $g = Get-GPO -Guid $guid @script:GpParams -ErrorAction Stop
            $gpoByGuid[$key] = $g
            return $g.DisplayName
        }
        catch { return "<missing GPO $guid>" }
    }

    # ---- Domain root + all OUs ----
    $containers = @()
    try {
        $domObj = Get-ADObject -Identity $script:DomainDN -Properties gPLink, gPOptions @script:AdParams -ErrorAction Stop
        $containers += [pscustomobject]@{ Obj = $domObj; Type = 'Domain'; Canonical = $script:DomainInfo.DNSRoot }
    }
    catch {
        Add-UnavailableItem -Area 'Domain root gPLink' -Reason $_.Exception.Message
    }
    try {
        $ous = @(Get-ADOrganizationalUnit -Filter * -Properties gPLink, gPOptions, CanonicalName @script:AdParams -ErrorAction Stop)
        Write-AuditLog -Level Info -Message "Enumerated $($ous.Count) organizational units."
        foreach ($ou in $ous) {
            $containers += [pscustomobject]@{ Obj = $ou; Type = 'OU'; Canonical = $ou.CanonicalName }
        }
    }
    catch {
        Add-UnavailableItem -Area 'OU enumeration' -Reason $_.Exception.Message
    }
    # ---- Sites (Configuration NC) ----
    try {
        $sites = @(Get-ADObject -LDAPFilter '(objectClass=site)' -SearchBase "CN=Sites,$($script:ConfigNC)" `
                -Properties gPLink, gPOptions, cn @script:AdParams -ErrorAction Stop)
        foreach ($site in $sites) {
            $containers += [pscustomobject]@{ Obj = $site; Type = 'Site'; Canonical = "Site: $($site.cn)" }
        }
    }
    catch {
        Add-UnavailableItem -Area 'Site link enumeration' -Reason $_.Exception.Message
    }

    foreach ($c in $containers) {
        $gplink = Get-PropertySafe -InputObject $c.Obj -Name 'gPLink'
        $gpopts = Get-PropertySafe -InputObject $c.Obj -Name 'gPOptions' -Default 0
        $blocked = ([int]("0$gpopts") -band 1) -eq 1
        if ($blocked) {
            Add-AuditFinding -Severity Medium -Category 'Inheritance' `
                -Title "Block Inheritance is enabled on $($c.Obj.DistinguishedName)" `
                -Detail 'GPOs linked above this container do not apply unless Enforced.' `
                -Recommendation 'Confirm Block Inheritance is intentional; it complicates troubleshooting and is often better replaced with security filtering.' `
                -RelatedObject $c.Obj.DistinguishedName
        }
        $parsed = ConvertFrom-GPLinkAttribute -GPLink "$gplink" -TargetDN $c.Obj.DistinguishedName `
            -TargetType $c.Type -CanonicalName "$($c.Canonical)" -BlockInheritance $blocked
        foreach ($link in $parsed) {
            $name = & $resolveName $link.GpoGuid
            $rec = [pscustomobject]@{
                GpoName          = $name
                GpoGuid          = $link.GpoGuid
                Target           = $link.TargetDN
                TargetType       = $link.TargetType
                CanonicalName    = $link.CanonicalName
                LinkOrder        = $link.LinkOrder
                Enabled          = $link.Enabled
                Enforced         = $link.Enforced
                BlockInheritance = $link.BlockInheritance
            }
            $allLinks.Add($rec)
            $key = $link.GpoGuid.ToString().ToLower()
            if (-not $script:GpoLinkIndex.ContainsKey($key)) { $script:GpoLinkIndex[$key] = New-Object System.Collections.Generic.List[object] }
            $script:GpoLinkIndex[$key].Add($rec)
            if ($name -like '<missing GPO*') {
                Add-AuditFinding -Severity High -Category 'Links' `
                    -Title "Link to a missing GPO on $($c.Obj.DistinguishedName)" `
                    -Detail "gPLink references GPO {$($link.GpoGuid)} which no longer exists in the domain." `
                    -Recommendation 'Remove the dead link with GPMC (right-click the link, Delete). This is a link cleanup only; no GPO exists to delete.' `
                    -RelatedObject $c.Obj.DistinguishedName
            }
            if (-not $link.Enabled) {
                Add-AuditFinding -Severity Low -Category 'Links' `
                    -Title "Disabled link: '$name' on $($c.Canonical)" `
                    -Detail 'The link exists but is disabled, so the GPO does not apply from this container.' `
                    -Recommendation 'Remove the link if permanently unused, or document why it is kept disabled.' `
                    -RelatedObject $name
            }
            if ($link.Enforced) {
                Add-AuditFinding -Severity Informational -Category 'Links' `
                    -Title "Enforced link: '$name' on $($c.Canonical)" `
                    -Detail 'Enforced links override Block Inheritance and win same-precedence conflicts.' `
                    -Recommendation 'Keep Enforced usage rare and documented.' `
                    -RelatedObject $name
            }
        }
        # ---- Effective inheritance via GPMC (OU + domain only; sites unsupported) ----
        if ($c.Type -in @('Domain', 'OU') -and (Get-Command Get-GPInheritance -ErrorAction SilentlyContinue)) {
            try {
                $inh = Get-GPInheritance -Target $c.Obj.DistinguishedName @script:GpParams -ErrorAction Stop
                foreach ($ilink in @($inh.InheritedGpoLinks)) {
                    $inheritance.Add([pscustomobject]@{
                            Container        = $c.Obj.DistinguishedName
                            ContainerType    = $c.Type
                            GpoName          = $ilink.DisplayName
                            GpoGuid          = $ilink.GpoId
                            EffectiveOrder   = $ilink.Order
                            Enabled          = $ilink.Enabled
                            Enforced         = $ilink.Enforced
                            LinkedDirectly   = ($ilink.Target -eq $c.Obj.DistinguishedName)
                            LinkSource       = $ilink.Target
                            GpoDomainName    = $ilink.GpoDomainName
                            BlockInheritance = $inh.GpoInheritanceBlocked
                        })
                }
            }
            catch {
                Add-UnavailableItem -Area "Get-GPInheritance: $($c.Obj.DistinguishedName)" -Reason $_.Exception.Message
            }
        }
    }

    Export-AuditDataset -Name 'GPOLinks' -Data $allLinks.ToArray() -Folder $script:Paths.Links
    Export-AuditDataset -Name 'GPOInheritance' -Data $inheritance.ToArray() -Folder $script:Paths.Links
    return $allLinks.ToArray()
}

function Get-GpoPermissionAudit {
    <#
    .SYNOPSIS
        Per-GPO security filtering / delegation audit via Get-GPPermission,
        with findings per the audit rules. Read-only.
    #>
    [CmdletBinding()]
    param()

    if (-not (Get-Command Get-GPPermission -ErrorAction SilentlyContinue)) {
        Add-UnavailableItem -Area 'GPO permission audit' -Reason 'Get-GPPermission unavailable.'
        return
    }
    $broadGroups = @('Domain Users', 'Authenticated Users', 'Everyone', 'Users', 'Domain Computers')
    $adminOwners = @('Domain Admins', 'Enterprise Admins', 'Administrators', 'SYSTEM')
    $permRecords = New-Object System.Collections.Generic.List[object]

    $i = 0
    foreach ($gpo in $script:AllGpos) {
        $i++
        Write-Progress -Activity 'GPO permission audit' -Status $gpo.DisplayName -PercentComplete ([int](100 * $i / [math]::Max(1, $script:AllGpos.Count)))
        $perms = $null
        try {
            $perms = @(Get-GPPermission -Guid $gpo.Id -All @script:GpParams -ErrorAction Stop)
        }
        catch {
            Add-UnavailableItem -Area "Permissions: $($gpo.DisplayName)" -Reason $_.Exception.Message
            continue
        }
        $applyTrustees = @()
        $hasAuthUsersRead  = $false
        $hasAuthUsersApply = $false
        $hasDomCompApply   = $false
        foreach ($p in $perms) {
            $trusteeName = "$(Get-PropertySafe -InputObject $p.Trustee -Name 'Name')"
            $trusteeSid  = "$(Get-PropertySafe -InputObject $p.Trustee -Name 'Sid')"
            $trusteeType = "$(Get-PropertySafe -InputObject $p.Trustee -Name 'SidType')"
            $permission  = "$($p.Permission)"
            $unresolved  = ($trusteeType -eq 'Unknown' -or [string]::IsNullOrEmpty($trusteeName))
            $permRecords.Add([pscustomobject]@{
                    GpoName    = $gpo.DisplayName
                    GpoGuid    = $gpo.Id
                    Trustee    = $(if ($unresolved) { $trusteeSid } else { $trusteeName })
                    TrusteeSid = $trusteeSid
                    SidType    = $trusteeType
                    Permission = $permission
                    Inherited  = $p.Inherited
                    Denied     = (Get-PropertySafe -InputObject $p -Name 'Denied' -Default $false)
                    Unresolved = $unresolved
                })
            if ($unresolved) {
                Add-AuditFinding -Severity Medium -Category 'Security' `
                    -Title "Unresolved SID on GPO '$($gpo.DisplayName)'" `
                    -Detail "Trustee $trusteeSid ($permission) cannot be resolved - usually a deleted user/group (orphaned trustee)." `
                    -Recommendation 'Remove the orphaned ACE via GPMC Delegation tab after confirming the principal is really gone.' `
                    -RelatedObject $gpo.DisplayName
            }
            switch -Regex ($permission) {
                'GpoApply' {
                    $applyTrustees += $trusteeName
                    if ($trusteeName -eq 'Authenticated Users') { $hasAuthUsersApply = $true; $hasAuthUsersRead = $true }
                    if ($trusteeName -like '*Domain Computers')  { $hasDomCompApply = $true }
                    if ($trusteeName -in @('Everyone'))          {
                        Add-AuditFinding -Severity High -Category 'Security' `
                            -Title "'Everyone' has Apply Group Policy on '$($gpo.DisplayName)'" `
                            -Detail 'Everyone includes unauthenticated/anonymous contexts in some configurations.' `
                            -Recommendation 'Replace Everyone with Authenticated Users or a scoped security group.' `
                            -RelatedObject $gpo.DisplayName
                    }
                    elseif ($trusteeName -notin $broadGroups -and $trusteeType -in @('Group', 'WellKnownGroup') ) {
                        Add-AuditFinding -Severity Informational -Category 'Security' `
                            -Title "Custom security filtering on '$($gpo.DisplayName)'" `
                            -Detail "Apply Group Policy is granted to custom group '$trusteeName' (security filtering in use)." `
                            -Recommendation 'Confirm group membership matches the intended scope. Remember: since MS16-072, the COMPUTER account must also have Read for user policy to apply.' `
                            -RelatedObject $gpo.DisplayName
                    }
                }
                'GpoRead' {
                    if ($trusteeName -eq 'Authenticated Users') { $hasAuthUsersRead = $true }
                }
                'GpoEditDeleteModifySecurity|GpoEdit' {
                    $sev = $null
                    if ($trusteeName -in @('Everyone', 'Authenticated Users', 'Domain Users', 'Users')) { $sev = 'Critical' }
                    elseif ($trusteeType -eq 'User' -and $trusteeName -notmatch 'Admin') { $sev = 'High' }
                    if ($sev) {
                        Add-AuditFinding -Severity $sev -Category 'Security' `
                            -Title "Broad/non-admin edit rights on '$($gpo.DisplayName)'" `
                            -Detail "'$trusteeName' holds $permission. GPO edit rights are equivalent to code execution on every computer/user the GPO reaches." `
                            -Recommendation 'Restrict edit and modify-security rights to dedicated GPO administration groups.' `
                            -RelatedObject $gpo.DisplayName
                    }
                    elseif ($permission -eq 'GpoEditDeleteModifySecurity' -and $trusteeName -notin $adminOwners) {
                        Add-AuditFinding -Severity Medium -Category 'Security' `
                            -Title "GpoEditDeleteModifySecurity delegated on '$($gpo.DisplayName)'" `
                            -Detail "'$trusteeName' can edit, delete, and change security on this GPO." `
                            -Recommendation 'Verify this delegation is intentional and the group is tightly controlled.' `
                            -RelatedObject $gpo.DisplayName
                    }
                }
                'GpoCustom' {
                    Add-AuditFinding -Severity Low -Category 'Security' `
                        -Title "Custom ACL on '$($gpo.DisplayName)' for '$trusteeName'" `
                        -Detail 'Non-standard permission set (GpoCustom). This can hide Apply-without-Read or Deny ACEs that Get-GPPermission cannot express.' `
                        -Recommendation 'Inspect the raw ACL in GPMC (Delegation > Advanced) for deny entries or missing Read paired with Apply.' `
                        -RelatedObject $gpo.DisplayName
                }
            }
            if ($trusteeName -match 'ANONYMOUS') {
                Add-AuditFinding -Severity High -Category 'Security' `
                    -Title "Anonymous permission entry on '$($gpo.DisplayName)'" `
                    -Detail "Anonymous Logon holds $permission." `
                    -Recommendation 'Remove Anonymous ACEs from GPOs.' -RelatedObject $gpo.DisplayName
            }
        }
        # MS16-072: user policy is read in the computer's context, so if neither
        # Authenticated Users nor Domain Computers retains Read, the GPO can
        # silently fail to apply. Note: this is NOT a flag on Authenticated Users
        # having Read - that is the healthy default.
        if (-not $hasAuthUsersRead -and -not $hasDomCompApply) {
            $domCompRead = @($perms | Where-Object {
                    "$(Get-PropertySafe -InputObject $_.Trustee -Name 'Name')" -like '*Domain Computers' }).Count -gt 0
            if (-not $domCompRead) {
                Add-AuditFinding -Severity High -Category 'Security' `
                    -Title "'$($gpo.DisplayName)' lacks Read for Authenticated Users AND Domain Computers" `
                    -Detail 'After MS16-072, GPOs are retrieved using the computer account. Without Read for either principal, user settings in this GPO will fail to apply (often silently).' `
                    -Recommendation "Add 'Domain Computers: Read' (not Apply) or restore 'Authenticated Users: Read' on the Delegation tab." `
                    -RelatedObject $gpo.DisplayName
            }
        }
        if ($hasAuthUsersApply) {
            Add-AuditFinding -Severity Informational -Category 'Security' `
                -Title "'$($gpo.DisplayName)': Authenticated Users has Read + Apply (default scope)" `
                -Detail 'This is the DEFAULT and is not inherently insecure - it means the GPO applies to every user/computer in linked scopes. Listed for completeness.' `
                -Recommendation 'Use security filtering only when the GPO must be narrower than its links.' `
                -RelatedObject $gpo.DisplayName
        }
        # Owner check
        $ownerOk = $false
        foreach ($a in $adminOwners) { if ("$($gpo.Owner)" -like "*$a*") { $ownerOk = $true; break } }
        if (-not $ownerOk -and -not [string]::IsNullOrEmpty("$($gpo.Owner)")) {
            Add-AuditFinding -Severity Medium -Category 'Security' `
                -Title "Unexpected owner on '$($gpo.DisplayName)': $($gpo.Owner)" `
                -Detail 'GPO owners can modify the GPO regardless of the delegation list.' `
                -Recommendation 'Transfer ownership to Domain Admins unless this is a documented delegation.' `
                -RelatedObject $gpo.DisplayName
        }
    }
    Write-Progress -Activity 'GPO permission audit' -Completed
    Export-AuditDataset -Name 'GPOPermissions' -Data $permRecords.ToArray() -Folder $script:Paths.Permissions
}

function Get-WmiFilterAudit {
    <#
    .SYNOPSIS
        Enumerates all WMI filters via LDAP (msWMI-Som), documents queries, maps
        GPO usage, and flags unused/broken/expensive filters.
    #>
    [CmdletBinding()]
    param()

    $filters = @()
    try {
        $filters = @(Get-ADObject -LDAPFilter '(objectClass=msWMI-Som)' `
                -SearchBase "CN=SOM,CN=WMIPolicy,CN=System,$($script:DomainDN)" `
                -Properties 'msWMI-Name', 'msWMI-Parm1', 'msWMI-Parm2', 'msWMI-Author', 'msWMI-ID', 'whenCreated', 'whenChanged' `
                @script:AdParams -ErrorAction Stop)
    }
    catch {
        Add-UnavailableItem -Area 'WMI filter enumeration' -Reason $_.Exception.Message
        return
    }
    Write-AuditLog -Level Info -Message "Found $($filters.Count) WMI filters."

    # Map WMI filter ID -> GPOs using it (from the groupPolicyContainer attribute,
    # which also exposes references to filters that no longer exist).
    $usage = @{}
    $brokenRefs = @()
    try {
        $gpcs = @(Get-ADObject -LDAPFilter '(objectClass=groupPolicyContainer)' `
                -SearchBase "CN=Policies,CN=System,$($script:DomainDN)" `
                -Properties displayName, gPCWQLFilter @script:AdParams -ErrorAction Stop)
        $filterIds = @{}
        foreach ($f in $filters) { $filterIds[("$($f.'msWMI-ID')").ToLower()] = $true }
        foreach ($gpc in $gpcs) {
            $wql = "$(Get-PropertySafe -InputObject $gpc -Name 'gPCWQLFilter')"
            if ([string]::IsNullOrWhiteSpace($wql)) { continue }
            # Format: [domain;{GUID};0]
            if ($wql -match '\{[0-9a-fA-F\-]+\}') {
                $fid = $Matches[0].ToLower()
                if (-not $usage.ContainsKey($fid)) { $usage[$fid] = @() }
                $usage[$fid] += "$($gpc.displayName)"
                if (-not $filterIds.ContainsKey($fid)) {
                    $brokenRefs += [pscustomobject]@{ Gpo = "$($gpc.displayName)"; FilterId = $fid }
                }
            }
        }
    }
    catch {
        Add-UnavailableItem -Area 'WMI filter usage mapping' -Reason $_.Exception.Message
    }

    $records = New-Object System.Collections.Generic.List[object]
    foreach ($f in $filters) {
        $name = "$($f.'msWMI-Name')"
        $id   = ("$($f.'msWMI-ID')").ToLower()
        # msWMI-Parm2 packs queries as:  <count>;3;<nsLen>;<qryLen>;WQL;<namespace>;<query>;...
        $parm2 = "$($f.'msWMI-Parm2')"
        $queries = @()
        $namespaces = @()
        if ($parm2) {
            $parts = $parm2 -split ';'
            for ($p = 0; $p -lt $parts.Count; $p++) {
                if ($parts[$p] -eq 'WQL' -and ($p + 2) -lt $parts.Count) {
                    $namespaces += $parts[$p + 1]
                    $queries    += $parts[$p + 2]
                }
            }
        }
        $usedBy = @()
        if ($usage.ContainsKey($id)) { $usedBy = @($usage[$id] | Select-Object -Unique) }
        $records.Add([pscustomobject]@{
                Name         = $name
                Description  = "$(Get-PropertySafe -InputObject $f -Name 'msWMI-Parm1')"
                Author       = "$(Get-PropertySafe -InputObject $f -Name 'msWMI-Author')"
                Created      = $f.whenCreated
                Modified     = $f.whenChanged
                FilterId     = $id
                Namespaces   = ($namespaces -join '; ')
                Queries      = ($queries -join ' | ')
                UsedByGpos   = ($usedBy -join '; ')
                UsedByCount  = $usedBy.Count
            })
        if ($usedBy.Count -eq 0) {
            Add-AuditFinding -Severity Low -Category 'WMIFilter' `
                -Title "Unused WMI filter: '$name'" `
                -Detail 'No GPO references this filter.' `
                -Recommendation 'Delete unused WMI filters to reduce clutter (verify with change control first).' `
                -RelatedObject $name
        }
        foreach ($q in $queries) {
            if ($q -match 'Win32_Product') {
                Add-AuditFinding -Severity High -Category 'WMIFilter' `
                    -Title "WMI filter '$name' queries Win32_Product" `
                    -Detail "Query: $q. Win32_Product triggers msiexec reconfiguration/validation of EVERY installed MSI at each policy refresh - a well-known performance and stability hazard." `
                    -Recommendation 'Rewrite using Win32Reg_AddRemovePrograms, CIM_DataFile on a marker file, or registry-based targeting.' `
                    -RelatedObject $name
            }
            elseif ($q -match 'CIM_DataFile|Win32_Directory' -and $q -match "(?i)like\s+'%") {
                Add-AuditFinding -Severity Medium -Category 'WMIFilter' `
                    -Title "Potentially expensive WMI query in filter '$name'" `
                    -Detail "Query: $q. Unanchored LIKE scans over file-system classes are slow at every GP refresh." `
                    -Recommendation 'Anchor the query (drive + path) or use a cheaper class.' `
                    -RelatedObject $name
            }
        }
        foreach ($ns in $namespaces) {
            if ($ns -notmatch '^(?i)root\\') {
                Add-AuditFinding -Severity Medium -Category 'WMIFilter' `
                    -Title "WMI filter '$name' uses suspicious namespace '$ns'" `
                    -Detail 'Namespace does not start with root\; the filter may fail to evaluate (fails CLOSED for the GPO - it will not apply).' `
                    -Recommendation 'Correct the namespace (typically root\CIMv2).' `
                    -RelatedObject $name
            }
        }
    }
    foreach ($br in $brokenRefs) {
        Add-AuditFinding -Severity High -Category 'WMIFilter' `
            -Title "GPO '$($br.Gpo)' references a MISSING WMI filter" `
            -Detail "gPCWQLFilter points at $($br.FilterId), which does not exist. The GPO will NOT apply to anything (missing filters fail closed)." `
            -Recommendation 'Clear the WMI filter reference on the GPO or recreate the filter.' `
            -RelatedObject $br.Gpo
    }
    Export-AuditDataset -Name 'WMIFilters' -Data $records.ToArray() -Folder $script:Paths.WMIFilters
}

# =============================================================================
#  Analysis: applied/denied GPOs, SYSVOL consistency, inventory findings
# =============================================================================

function Get-AppliedGpoAnalysis {
    <#
    .SYNOPSIS
        Parses the gpresult /X XML to produce applied/denied GPO tables (with
        denial reasons), security group membership, site, slow link and loopback
        status for computer and user scopes.
    #>
    [CmdletBinding()]
    param()

    $xmlPath = Join-Path $script:Paths.RSOP 'GPResult.xml'
    if (-not (Test-Path -LiteralPath $xmlPath)) {
        Add-UnavailableItem -Area 'Applied/denied GPO analysis' -Reason 'GPResult.xml was not collected (gpresult /X failed or target offline).'
        return $null
    }
    try {
        $xml = [xml](Get-Content -LiteralPath $xmlPath -Raw)
    }
    catch {
        Add-UnavailableItem -Area 'Applied/denied GPO analysis' -Reason "GPResult.xml could not be parsed: $($_.Exception.Message)"
        return $null
    }

    $summary = [ordered]@{
        ComputerSite     = ''
        ComputerDomain   = ''
        SlowLink         = ''
        LoopbackMode     = 'Not reported'
        ComputerGroups   = @()
        UserGroups       = @()
    }
    $applied = New-Object System.Collections.Generic.List[object]
    $denied  = New-Object System.Collections.Generic.List[object]

    foreach ($scope in @('ComputerResults', 'UserResults')) {
        $scopeLabel = $(if ($scope -eq 'ComputerResults') { 'Computer' } else { 'User' })
        $scopeNodes = $xml.SelectNodes("//*[local-name()='$scope']")
        if ($scopeNodes.Count -eq 0) { continue }
        $sn = $scopeNodes[0]

        $siteNode = $sn.SelectSingleNode("*[local-name()='Site']")
        if ($siteNode -and $scopeLabel -eq 'Computer') { $summary.ComputerSite = $siteNode.InnerText }
        $domNode = $sn.SelectSingleNode("*[local-name()='Domain']")
        if ($domNode -and $scopeLabel -eq 'Computer') { $summary.ComputerDomain = $domNode.InnerText }
        $slowNode = $sn.SelectSingleNode("*[local-name()='SlowLink']")
        if ($slowNode -and $scopeLabel -eq 'Computer') { $summary.SlowLink = $slowNode.InnerText }
        $loopNode = $sn.SelectSingleNode("*[local-name()='LoopbackMode']")
        if ($loopNode) { $summary.LoopbackMode = $loopNode.InnerText }

        $groups = @($sn.SelectNodes("*[local-name()='SecurityGroup']/*[local-name()='Name']") | ForEach-Object { $_.InnerText })
        if ($groups.Count -eq 0) {
            $groups = @($sn.SelectNodes(".//*[local-name()='SecurityGroup']") | ForEach-Object {
                    $n = $_.SelectSingleNode("*[local-name()='Name']"); if ($n) { $n.InnerText } })
        }
        if ($scopeLabel -eq 'Computer') { $summary.ComputerGroups = $groups } else { $summary.UserGroups = $groups }

        foreach ($gpoNode in @($sn.SelectNodes("*[local-name()='GPO']"))) {
            $get = { param($xpath) $n = $gpoNode.SelectSingleNode($xpath); if ($n) { $n.InnerText } else { '' } }
            $name        = & $get "*[local-name()='Name']"
            $guid        = & $get "*[local-name()='Path']/*[local-name()='Identifier']"
            $enabledTxt  = & $get "*[local-name()='Enabled']"
            $validTxt    = & $get "*[local-name()='IsValid']"
            $filterOkTxt = & $get "*[local-name()='FilterAllowed']"
            $accessTxt   = & $get "*[local-name()='AccessDenied']"
            $somPath     = & $get "*[local-name()='Link']/*[local-name()='SOMPath']"
            $somOrder    = & $get "*[local-name()='Link']/*[local-name()='SOMOrder']"
            $appliedOrd  = & $get "*[local-name()='Link']/*[local-name()='AppliedOrder']"
            $linkOrder   = & $get "*[local-name()='Link']/*[local-name()='LinkOrder']"
            $enforcedTxt = & $get "*[local-name()='Link']/*[local-name()='NoOverride']"
            $filterName  = & $get "*[local-name()='FilterName']"

            $isEnabled  = ($enabledTxt -ne 'false')
            $isValid    = ($validTxt -ne 'false')
            $filterOk   = ($filterOkTxt -ne 'false')
            $accessDeny = ($accessTxt -eq 'true')
            $wasApplied = ($isEnabled -and $isValid -and $filterOk -and -not $accessDeny -and $appliedOrd -and $appliedOrd -ne '0')

            $reason = ''
            if (-not $wasApplied) {
                if ($accessDeny)          { $reason = 'Denied by security filtering (no Apply Group Policy permission)' }
                elseif (-not $filterOk)   { $reason = $(if ($filterName) { "Denied by WMI filter '$filterName' (evaluated false)" } else { 'Denied by WMI filter (evaluated false)' }) }
                elseif (-not $isEnabled)  { $reason = 'Link or GPO half disabled for this scope' }
                elseif (-not $isValid)    { $reason = 'GPO inaccessible or corrupt (IsValid=false) - check SYSVOL' }
                else                      { $reason = 'Empty for this scope / not applied (no AppliedOrder)' }
            }

            $rec = [pscustomobject]@{
                Scope        = $scopeLabel
                GpoName      = $name
                GpoGuid      = $guid
                LinkLocation = $somPath
                SOMOrder     = $somOrder
                LinkOrder    = $linkOrder
                AppliedOrder = $appliedOrd
                Enforced     = ($enforcedTxt -eq 'true')
                Applied      = $wasApplied
                DenialReason = $reason
                WmiFilter    = $filterName
            }
            if ($wasApplied) { $applied.Add($rec) } else { $denied.Add($rec) }
        }
    }

    if ("$($summary.LoopbackMode)" -notin @('', 'Not reported')) {
        Add-AuditFinding -Severity Informational -Category 'Processing' `
            -Title "RSOP reports loopback mode: $($summary.LoopbackMode)" `
            -Detail 'User policy scope is affected by GPOs linked to the computer location.' `
            -Recommendation 'Review the applied-user list with loopback in mind.' -RelatedObject 'RSOP'
    }
    if ("$($summary.SlowLink)" -eq 'true') {
        Add-AuditFinding -Severity Medium -Category 'Processing' `
            -Title 'Group Policy detected a SLOW LINK at last processing' `
            -Detail 'On slow links, software installation, folder redirection, and scripts are skipped by default.' `
            -Recommendation 'Check bandwidth to the DC; adjust the slow-link threshold policy if this is a false positive (VPN adapters are a common cause).' `
            -RelatedObject 'RSOP'
    }
    foreach ($d in $denied) {
        if ($d.DenialReason -match 'IsValid=false') {
            Add-AuditFinding -Severity High -Category 'Processing' `
                -Title "GPO '$($d.GpoName)' is inaccessible from the client" `
                -Detail $d.DenialReason `
                -Recommendation 'Verify the SYSVOL folder for this GPO exists and replication is healthy.' `
                -RelatedObject $d.GpoName
        }
    }

    Export-AuditDataset -Name 'AppliedGPOs' -Data $applied.ToArray() -Folder $script:Paths.Summary
    Export-AuditDataset -Name 'DeniedGPOs'  -Data $denied.ToArray()  -Folder $script:Paths.Summary
    $groupRecords = @()
    $groupRecords += @($summary.ComputerGroups | ForEach-Object { [pscustomobject]@{ Scope = 'Computer'; Group = $_ } })
    $groupRecords += @($summary.UserGroups     | ForEach-Object { [pscustomobject]@{ Scope = 'User';     Group = $_ } })
    Export-AuditDataset -Name 'SecurityGroupMembership' -Data $groupRecords -Folder $script:Paths.Summary

    # Per-scope copies in the Computer\ and User\ folders for easy consumption
    Export-AuditDataset -Name 'AppliedGPOs-Computer' -Data @($applied | Where-Object { $_.Scope -eq 'Computer' }) -Folder $script:Paths.Computer
    Export-AuditDataset -Name 'DeniedGPOs-Computer'  -Data @($denied  | Where-Object { $_.Scope -eq 'Computer' }) -Folder $script:Paths.Computer
    Export-AuditDataset -Name 'AppliedGPOs-User'     -Data @($applied | Where-Object { $_.Scope -eq 'User' })     -Folder $script:Paths.User
    Export-AuditDataset -Name 'DeniedGPOs-User'      -Data @($denied  | Where-Object { $_.Scope -eq 'User' })     -Folder $script:Paths.User

    Write-AuditLog -Level Info -Message "Applied: $($applied.Count) GPO scope-entries; Denied/filtered: $($denied.Count)."
    return [pscustomobject]@{
        Applied  = $applied.ToArray()
        Denied   = $denied.ToArray()
        Summary  = [pscustomobject]$summary
    }
}

function Test-SysvolConsistency {
    <#
    .SYNOPSIS
        Read-only comparison of AD GPO objects vs SYSVOL folders, GPT.INI vs AD
        version numbers, cpassword scanning, and script UNC availability.
        NOTHING in SYSVOL is modified.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DomainName)

    $policiesPath = "\\$DomainName\SYSVOL\$DomainName\Policies"
    $results = New-Object System.Collections.Generic.List[object]

    if (-not (Test-Path -LiteralPath $policiesPath)) {
        Add-UnavailableItem -Area 'SYSVOL validation' -Reason "Cannot access $policiesPath"
        return
    }

    # --- AD side: every groupPolicyContainer (works even without -IncludeDomainInventory) ---
    $adGpos = @{}
    try {
        $gpcs = @(Get-ADObject -LDAPFilter '(objectClass=groupPolicyContainer)' `
                -SearchBase "CN=Policies,CN=System,$($script:DomainDN)" `
                -Properties displayName, versionNumber, cn @script:AdParams -ErrorAction Stop)
        foreach ($g in $gpcs) {
            $adGpos[("$($g.cn)").ToLower()] = [pscustomobject]@{
                Name    = "$($g.displayName)"
                Version = [int64](Get-PropertySafe -InputObject $g -Name 'versionNumber' -Default 0)
            }
        }
    }
    catch {
        Add-UnavailableItem -Area 'SYSVOL validation (AD side)' -Reason $_.Exception.Message
        return
    }

    # --- SYSVOL side ---
    $sysvolFolders = @{}
    try {
        foreach ($dir in @(Get-ChildItem -LiteralPath $policiesPath -Directory -ErrorAction Stop)) {
            if ($dir.Name -match '^\{[0-9a-fA-F\-]+\}$') { $sysvolFolders[$dir.Name.ToLower()] = $dir.FullName }
        }
    }
    catch {
        Add-UnavailableItem -Area 'SYSVOL folder enumeration' -Reason $_.Exception.Message
        return
    }
    Write-AuditLog -Level Info -Message "AD GPO objects: $($adGpos.Count); SYSVOL policy folders: $($sysvolFolders.Count)."

    # --- Orphans in each direction ---
    foreach ($guid in $adGpos.Keys) {
        if (-not $sysvolFolders.ContainsKey($guid)) {
            $results.Add([pscustomobject]@{ Guid = $guid; GpoName = $adGpos[$guid].Name; Issue = 'AD object without SYSVOL folder'; Detail = 'Clients cannot read this GPO.' })
            Add-AuditFinding -Severity High -Category 'SYSVOL' `
                -Title "GPO '$($adGpos[$guid].Name)' has NO SYSVOL folder ($guid)" `
                -Detail 'The AD object exists but its SYSVOL content is missing; the GPO cannot apply and clients may log errors.' `
                -Recommendation 'Restore the folder from backup or from a healthy replication partner; if the GPO is dead, delete it via GPMC (do NOT hand-edit SYSVOL).' `
                -RelatedObject $adGpos[$guid].Name
        }
    }
    foreach ($guid in $sysvolFolders.Keys) {
        if (-not $adGpos.ContainsKey($guid)) {
            $results.Add([pscustomobject]@{ Guid = $guid; GpoName = '(orphan)'; Issue = 'SYSVOL folder without AD object'; Detail = $sysvolFolders[$guid] })
            Add-AuditFinding -Severity Medium -Category 'SYSVOL' `
                -Title "Orphaned SYSVOL policy folder $guid" `
                -Detail "Folder $($sysvolFolders[$guid]) has no matching AD GPO object (leftover from an incomplete delete or replication problem)." `
                -Recommendation 'Confirm on all DCs, then remove via a controlled cleanup (e.g., GPMC status tools). This audit does not delete anything.' `
                -RelatedObject $guid
        }
    }

    # --- GPT.INI version vs AD versionNumber (user = high word, computer = low word) ---
    foreach ($guid in $adGpos.Keys) {
        if (-not $sysvolFolders.ContainsKey($guid)) { continue }
        $gptIni = Join-Path $sysvolFolders[$guid] 'GPT.INI'
        if (-not (Test-Path -LiteralPath $gptIni)) {
            Add-AuditFinding -Severity High -Category 'SYSVOL' `
                -Title "GPT.INI missing for '$($adGpos[$guid].Name)'" `
                -Detail "No GPT.INI in $($sysvolFolders[$guid]); clients treat the GPO as unreadable." `
                -Recommendation 'Restore from backup/replication partner.' -RelatedObject $adGpos[$guid].Name
            continue
        }
        try {
            $iniText = Get-Content -LiteralPath $gptIni -Raw -ErrorAction Stop
            if ($iniText -match '(?im)^\s*Version\s*=\s*(\d+)') {
                $sysvolVer = [int64]$Matches[1]
                $adVer = $adGpos[$guid].Version
                if ($sysvolVer -ne $adVer) {
                    $results.Add([pscustomobject]@{ Guid = $guid; GpoName = $adGpos[$guid].Name; Issue = 'Version mismatch'; Detail = "AD=$adVer (user $([int]($adVer -shr 16))/computer $([int]($adVer -band 0xFFFF))) vs SYSVOL=$sysvolVer (user $([int]($sysvolVer -shr 16))/computer $([int]($sysvolVer -band 0xFFFF)))" })
                    Add-AuditFinding -Severity Medium -Category 'SYSVOL' `
                        -Title "Version mismatch AD vs SYSVOL for '$($adGpos[$guid].Name)'" `
                        -Detail "AD versionNumber=$adVer, GPT.INI Version=$sysvolVer. Persistent mismatches indicate SYSVOL replication lag or failure and cause clients to skip re-processing." `
                        -Recommendation 'Check DFSR SYSVOL health (dfsrdiag, event log DFS Replication) and re-save the GPO to bump both versions once replication is fixed.' `
                        -RelatedObject $adGpos[$guid].Name
                }
            }
        }
        catch {
            Add-UnavailableItem -Area "GPT.INI read: $($adGpos[$guid].Name)" -Reason $_.Exception.Message
        }
    }

    # --- cpassword scan (GPP legacy credential exposure, MS14-025) ---
    try {
        $prefXml = @(Get-ChildItem -LiteralPath $policiesPath -Recurse -Filter '*.xml' -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match '\\(Preferences|Machine|User)\\' } |
            Select-Object -First 2000)
        $cpassHits = @()
        foreach ($file in $prefXml) {
            try {
                $hit = Select-String -LiteralPath $file.FullName -Pattern 'cpassword\s*=\s*"[^"]+"' -List -ErrorAction SilentlyContinue
                if ($hit) { $cpassHits += $file.FullName }
            }
            catch { }
        }
        foreach ($hit in $cpassHits) {
            $results.Add([pscustomobject]@{ Guid = ''; GpoName = $hit; Issue = 'cpassword found'; Detail = 'Legacy GPP stored credential' })
            Add-AuditFinding -Severity Critical -Category 'Security' `
                -Title 'Group Policy Preferences cpassword found (MS14-025)' `
                -Detail "File: $hit. The AES key for cpassword is public; any domain user can decrypt this password." `
                -Recommendation 'Remove the preference item, rotate the exposed account password immediately, and redeploy via LAPS or another secret-safe mechanism.' `
                -RelatedObject $hit
        }
        if ($cpassHits.Count -eq 0) { Write-AuditLog -Level Success -Message 'No cpassword values found in scanned preference XML files.' }
    }
    catch {
        Add-UnavailableItem -Area 'cpassword scan' -Reason $_.Exception.Message
    }

    # --- Startup/logon script UNC availability ---
    try {
        $scriptsIni = @(Get-ChildItem -LiteralPath $policiesPath -Recurse -Include 'scripts.ini', 'psscripts.ini' -ErrorAction SilentlyContinue |
            Select-Object -First 500)
        $checked = @{}
        foreach ($ini in $scriptsIni) {
            $text = Get-Content -LiteralPath $ini.FullName -Raw -ErrorAction SilentlyContinue
            if (-not $text) { continue }
            foreach ($m in [regex]::Matches($text, '(?im)^\d+CmdLine\s*=\s*(\\\\\S+)$')) {
                $unc = $m.Groups[1].Value.Trim()
                if ($checked.ContainsKey($unc)) { continue }
                $checked[$unc] = $true
                if (-not (Test-Path -LiteralPath $unc -ErrorAction SilentlyContinue)) {
                    Add-AuditFinding -Severity Medium -Category 'Scripts' `
                        -Title "Startup/logon script UNC path unavailable: $unc" `
                        -Detail "Referenced in $($ini.FullName) but not reachable from this audit host (may still work from clients - verify)." `
                        -Recommendation 'Fix or remove the dead script reference; unreachable scripts slow logons while they time out.' `
                        -RelatedObject $unc
                }
            }
        }
    }
    catch {
        Add-UnavailableItem -Area 'Script UNC validation' -Reason $_.Exception.Message
    }

    Export-AuditDataset -Name 'SysvolConsistency' -Data $results.ToArray() -Folder $script:Paths.RawData
}

function Invoke-GpoFindingsAnalysis {
    <#
    .SYNOPSIS
        Inventory-driven hygiene findings: unlinked/empty/disabled GPOs, missing
        descriptions, duplicates, stale/recent changes, version mismatches.
    #>
    [CmdletBinding()]
    param([Parameter()][object[]]$Inventory = @())

    if ($Inventory.Count -eq 0) { return }
    $now = Get-Date

    # Fill IsLinked from the link index built by Get-GpoLinkInventory
    foreach ($g in $Inventory) {
        $key = $g.Id.ToString().ToLower()
        $g.IsLinked = $script:GpoLinkIndex.ContainsKey($key) -and ($script:GpoLinkIndex[$key].Count -gt 0)
    }

    foreach ($g in $Inventory) {
        $name = $g.DisplayName
        if (-not $g.IsLinked) {
            Add-AuditFinding -Severity Low -Category 'Hygiene' -Title "Unlinked GPO: '$name'" `
                -Detail 'The GPO exists but is not linked to any site, domain, or OU (it applies to nothing).' `
                -Recommendation 'Back up and delete if obsolete, or link it where intended.' -RelatedObject $name
        }
        if ($g.AppearsEmpty -eq $true) {
            Add-AuditFinding -Severity Low -Category 'Hygiene' -Title "Empty GPO: '$name'" `
                -Detail 'No settings were found in either the computer or user half.' `
                -Recommendation 'Delete empty GPOs; they add processing overhead and confusion.' -RelatedObject $name
        }
        if ($g.IsFullyDisabled) {
            Add-AuditFinding -Severity Low -Category 'Hygiene' -Title "Fully disabled GPO: '$name'" `
                -Detail 'GpoStatus = AllSettingsDisabled.' `
                -Recommendation 'Delete or re-enable; document if kept intentionally.' -RelatedObject $name
        }
        elseif ($g.IsHalfDisabled) {
            Add-AuditFinding -Severity Informational -Category 'Hygiene' -Title "Partially disabled GPO: '$name' ($($g.GpoStatus))" `
                -Detail 'One half of the GPO is disabled. This is a legitimate optimization when that half is empty - verify it matches the content.' `
                -Recommendation 'Confirm the disabled half really has no needed settings.' -RelatedObject $name
        }
        if ([string]::IsNullOrWhiteSpace("$($g.Description)")) {
            Add-AuditFinding -Severity Informational -Category 'Hygiene' -Title "No description on GPO: '$name'" `
                -Detail 'Undocumented GPOs slow down troubleshooting and change review.' `
                -Recommendation 'Add owner/purpose/change-ticket to the GPO description.' -RelatedObject $name
        }
        try {
            $age = ($now - [datetime]$g.ModificationTime).TotalDays
            if ($age -gt $StaleGpoDays) {
                Add-AuditFinding -Severity Low -Category 'Hygiene' -Title "Stale GPO: '$name' (unmodified for $([int]$age) days)" `
                    -Detail "Last modified $($g.ModificationTime)." `
                    -Recommendation 'Review whether the GPO is still needed; stale GPOs often contain obsolete settings.' -RelatedObject $name
            }
            elseif ($age -le $RecentGpoDays) {
                Add-AuditFinding -Severity Informational -Category 'Change' -Title "Recently modified GPO: '$name'" `
                    -Detail "Modified $($g.ModificationTime) (within $RecentGpoDays days). Relevant when correlating new problems." `
                    -Recommendation 'Correlate with any recent incident timelines.' -RelatedObject $name
            }
        }
        catch { }
        if ($g.VersionMismatch) {
            Add-AuditFinding -Severity Medium -Category 'SYSVOL' -Title "AD/SYSVOL version mismatch on '$name'" `
                -Detail "User: DS=$($g.UserDSVersion) SYSVOL=$($g.UserSysvolVersion); Computer: DS=$($g.ComputerDSVersion) SYSVOL=$($g.ComputerSysvolVersion)." `
                -Recommendation 'Check SYSVOL (DFSR) replication health; mismatches prevent clients from picking up changes.' -RelatedObject $name
        }
        if ($g.ContainsSoftwareInstall) {
            Add-AuditFinding -Severity Informational -Category 'Content' -Title "GPO '$name' deploys software (MSI)" `
                -Detail 'Software installation only processes at startup/logon (foreground) and never over slow links.' `
                -Recommendation 'Confirm the package source share is reachable from all clients.' -RelatedObject $name
        }
    }

    # Duplicate / similar names (normalized: case, spaces, dashes, underscores)
    $byNorm = @{}
    foreach ($g in $Inventory) {
        $norm = ($g.DisplayName -replace '[\s\-_]', '').ToLower()
        if (-not $byNorm.ContainsKey($norm)) { $byNorm[$norm] = @() }
        $byNorm[$norm] += $g.DisplayName
    }
    foreach ($entry in $byNorm.GetEnumerator()) {
        if ($entry.Value.Count -gt 1) {
            Add-AuditFinding -Severity Low -Category 'Hygiene' `
                -Title "Duplicate/similar GPO names: $($entry.Value -join ' <-> ')" `
                -Detail 'Nearly identical names usually indicate abandoned copies or unclear ownership.' `
                -Recommendation 'Consolidate or rename with a clear naming convention.' `
                -RelatedObject ($entry.Value -join '; ')
        }
    }
}

# =============================================================================
#  Reporting: master HTML (embedded CSS, portable), executive summary, findings
# =============================================================================

function ConvertTo-AuditHtmlTable {
    <#
    .SYNOPSIS
        Renders objects as an HTML table with full encoding. Returns a fragment.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()][object[]]$Data,
        [Parameter()][string[]]$Property,
        [Parameter()][string]$EmptyMessage = 'No records.'
    )
    if ($null -eq $Data -or $Data.Count -eq 0) {
        return "<p class='empty'>$([System.Net.WebUtility]::HtmlEncode($EmptyMessage))</p>"
    }
    if (-not $Property -or $Property.Count -eq 0) {
        $Property = @($Data[0].PSObject.Properties | ForEach-Object { $_.Name })
    }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<div class="tablewrap"><table><thead><tr>')
    foreach ($p in $Property) {
        [void]$sb.AppendFormat('<th>{0}</th>', [System.Net.WebUtility]::HtmlEncode($p))
    }
    [void]$sb.Append('</tr></thead><tbody>')
    foreach ($row in $Data) {
        [void]$sb.Append('<tr>')
        foreach ($p in $Property) {
            $val = Get-PropertySafe -InputObject $row -Name $p
            $text = $(if ($null -eq $val) { '' } else { "$val" })
            $cls = ''
            if ($p -in @('Severity')) { $cls = " class='sev-$($text.ToLower())'" }
            elseif ($text -in @('True', 'False')) { $cls = " class='bool-$($text.ToLower())'" }
            [void]$sb.AppendFormat('<td{0}>{1}</td>', $cls, [System.Net.WebUtility]::HtmlEncode($text))
        }
        [void]$sb.Append('</tr>')
    }
    [void]$sb.Append('</tbody></table></div>')
    return $sb.ToString()
}

function New-MasterHtmlReport {
    [CmdletBinding()]
    param(
        [Parameter()][object]$ComputerInfo,
        [Parameter()][object]$RsopAnalysis,
        [Parameter()][object[]]$Inventory = @(),
        [Parameter()][object]$PrereqResult,
        [Parameter(Mandatory)][hashtable]$Context
    )
    $enc = { param($s) [System.Net.WebUtility]::HtmlEncode("$s") }
    $findings = @($script:Findings | Sort-Object @{ e = {
                switch ($_.Severity) {
                    'Critical' { 0 } 'High' { 1 } 'Medium' { 2 } 'Low' { 3 } default { 4 } } } })
    $sevCounts = @{}
    foreach ($sev in @('Critical', 'High', 'Medium', 'Low', 'Informational')) {
        $sevCounts[$sev] = @($findings | Where-Object { $_.Severity -eq $sev }).Count
    }
    $applied = @(); $denied = @()
    if ($RsopAnalysis) { $applied = @($RsopAnalysis.Applied); $denied = @($RsopAnalysis.Denied) }

    $css = @"
    :root { --crit:#b71c1c; --high:#e65100; --med:#f9a825; --low:#1565c0; --info:#546e7a; --ok:#2e7d32; }
    * { box-sizing: border-box; }
    body { font-family: 'Segoe UI', Tahoma, Arial, sans-serif; margin: 0; background: #f4f6f8; color: #212121; }
    header { background: #1a237e; color: #fff; padding: 24px 32px; }
    header h1 { margin: 0 0 4px 0; font-size: 24px; }
    header .meta { font-size: 13px; opacity: .85; }
    main { padding: 24px 32px; max-width: 1400px; margin: 0 auto; }
    section { background: #fff; border-radius: 8px; padding: 20px 24px; margin-bottom: 24px; box-shadow: 0 1px 3px rgba(0,0,0,.12); }
    h2 { margin-top: 0; font-size: 18px; color: #1a237e; border-bottom: 2px solid #e8eaf6; padding-bottom: 8px; }
    h3 { font-size: 15px; color: #283593; }
    .tiles { display: flex; flex-wrap: wrap; gap: 12px; margin: 8px 0 16px 0; }
    .tile { flex: 1 1 140px; border-radius: 8px; padding: 14px; color: #fff; text-align: center; }
    .tile .num { font-size: 30px; font-weight: 700; display: block; }
    .tile .lbl { font-size: 12px; text-transform: uppercase; letter-spacing: .05em; }
    .t-crit { background: var(--crit); } .t-high { background: var(--high); }
    .t-med { background: var(--med); color:#212121; } .t-low { background: var(--low); } .t-info { background: var(--info); }
    .tablewrap { overflow-x: auto; }
    table { border-collapse: collapse; width: 100%; font-size: 12.5px; margin: 8px 0; }
    th { background: #e8eaf6; text-align: left; padding: 6px 8px; position: sticky; top: 0; }
    td { border-top: 1px solid #eceff1; padding: 5px 8px; vertical-align: top; }
    tr:nth-child(even) td { background: #fafafa; }
    td.sev-critical { color: var(--crit); font-weight: 700; }
    td.sev-high { color: var(--high); font-weight: 700; }
    td.sev-medium { color: #b28704; font-weight: 600; }
    td.sev-low { color: var(--low); }
    td.sev-informational { color: var(--info); }
    td.bool-true { color: var(--ok); } td.bool-false { color: var(--crit); }
    .kv { display: grid; grid-template-columns: 260px 1fr; gap: 4px 16px; font-size: 13px; }
    .kv dt { font-weight: 600; color: #37474f; } .kv dd { margin: 0; word-break: break-word; }
    .empty { color: #90a4ae; font-style: italic; }
    .badge-ok { color: var(--ok); font-weight: 600; } .badge-warn { color: var(--high); font-weight: 600; }
    footer { text-align: center; font-size: 12px; color: #90a4ae; padding: 16px; }
    a { color: #1565c0; }
"@

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">')
    [void]$sb.AppendLine("<title>GPO Audit - $(& $enc $Context.ComputerName)</title><style>$css</style></head><body>")
    [void]$sb.AppendLine("<header><h1>Group Policy Audit Report</h1><div class='meta'>")
    [void]$sb.AppendLine("Generated $(& $enc (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) | Operator: $(& $enc $Context.Operator) | Script v$($script:ScriptVersion)</div></header><main>")

    # ---- Audit context ----
    [void]$sb.AppendLine('<section><h2>Audit Context</h2><dl class="kv">')
    $ctxRows = [ordered]@{
        'Computer audited'   = $Context.ComputerName
        'User audited'       = $(if ($Context.UserName) { $Context.UserName } else { '(none specified)' })
        'Domain'             = $Context.Domain
        'Domain controller'  = $Context.DomainController
        'Audit host'         = $env:COMPUTERNAME
        'PowerShell'         = "$($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition)) - GroupPolicy module mode: $($script:GPModuleMode)"
        'Prerequisites'      = $(if ($PrereqResult) {
                "Installed: $(@($PrereqResult.Installed).Count); Failed/skipped: $(@($PrereqResult.Failed).Count); Restart needed: $($PrereqResult.RestartNeeded)"
            } else { 'All present (no installation attempted)' })
        'Output folder'      = $Context.OutputPath
    }
    foreach ($k in $ctxRows.Keys) {
        [void]$sb.AppendLine("<dt>$(& $enc $k)</dt><dd>$(& $enc $ctxRows[$k])</dd>")
    }
    [void]$sb.AppendLine('</dl></section>')

    # ---- Executive summary ----
    [void]$sb.AppendLine('<section><h2>Executive Summary</h2><div class="tiles">')
    [void]$sb.AppendLine("<div class='tile t-crit'><span class='num'>$($sevCounts['Critical'])</span><span class='lbl'>Critical</span></div>")
    [void]$sb.AppendLine("<div class='tile t-high'><span class='num'>$($sevCounts['High'])</span><span class='lbl'>High</span></div>")
    [void]$sb.AppendLine("<div class='tile t-med'><span class='num'>$($sevCounts['Medium'])</span><span class='lbl'>Medium</span></div>")
    [void]$sb.AppendLine("<div class='tile t-low'><span class='num'>$($sevCounts['Low'])</span><span class='lbl'>Low</span></div>")
    [void]$sb.AppendLine("<div class='tile t-info'><span class='num'>$($sevCounts['Informational'])</span><span class='lbl'>Info</span></div>")
    [void]$sb.AppendLine('</div>')
    $execText = "This audit examined Group Policy for computer '$($Context.ComputerName)'" +
    $(if ($Context.UserName) { " and user '$($Context.UserName)'" } else { '' }) +
    " in domain '$($Context.Domain)'. " +
    "$(@($applied | Where-Object { $_.Scope -eq 'Computer' }).Count) GPO(s) applied to the computer and " +
    "$(@($applied | Where-Object { $_.Scope -eq 'User' }).Count) to the user scope; " +
    "$($denied.Count) scope-entrie(s) were denied or filtered. " +
    $(if ($Inventory.Count -gt 0) { "The domain contains $($Inventory.Count) GPO(s). " } else { 'Domain inventory was not requested. ' }) +
    "The audit produced $($findings.Count) finding(s): $($sevCounts['Critical']) critical and $($sevCounts['High']) high-severity items requiring prompt attention."
    [void]$sb.AppendLine("<p>$(& $enc $execText)</p></section>")

    # ---- Target computer ----
    if ($ComputerInfo) {
        [void]$sb.AppendLine('<section><h2>Target Computer</h2><dl class="kv">')
        foreach ($prop in $ComputerInfo.PSObject.Properties) {
            [void]$sb.AppendLine("<dt>$(& $enc $prop.Name)</dt><dd>$(& $enc $prop.Value)</dd>")
        }
        [void]$sb.AppendLine('</dl></section>')
    }

    # ---- Applied / denied ----
    [void]$sb.AppendLine('<section><h2>Applied GPOs</h2>')
    [void]$sb.AppendLine((ConvertTo-AuditHtmlTable -Data $applied -Property Scope, GpoName, LinkLocation, AppliedOrder, LinkOrder, Enforced, WmiFilter -EmptyMessage 'No applied-GPO data (RSOP collection unavailable).'))
    [void]$sb.AppendLine('<h2>Denied / Filtered GPOs</h2>')
    [void]$sb.AppendLine((ConvertTo-AuditHtmlTable -Data $denied -Property Scope, GpoName, LinkLocation, DenialReason, WmiFilter -EmptyMessage 'No denied GPOs recorded.'))
    if ($RsopAnalysis) {
        [void]$sb.AppendLine('<h3>Processing context</h3><dl class="kv">')
        [void]$sb.AppendLine("<dt>AD site (RSOP)</dt><dd>$(& $enc $RsopAnalysis.Summary.ComputerSite)</dd>")
        [void]$sb.AppendLine("<dt>Slow link detected</dt><dd>$(& $enc $RsopAnalysis.Summary.SlowLink)</dd>")
        [void]$sb.AppendLine("<dt>Loopback mode</dt><dd>$(& $enc $RsopAnalysis.Summary.LoopbackMode)</dd>")
        [void]$sb.AppendLine('</dl>')
    }
    [void]$sb.AppendLine('</section>')

    # ---- Findings ----
    [void]$sb.AppendLine('<section><h2>Findings by Severity</h2>')
    foreach ($sev in @('Critical', 'High', 'Medium', 'Low', 'Informational')) {
        $items = @($findings | Where-Object { $_.Severity -eq $sev })
        if ($items.Count -eq 0) { continue }
        [void]$sb.AppendLine("<h3>$sev ($($items.Count))</h3>")
        [void]$sb.AppendLine((ConvertTo-AuditHtmlTable -Data $items -Property Severity, Category, Title, Detail, Recommendation))
    }
    if ($findings.Count -eq 0) { [void]$sb.AppendLine("<p class='badge-ok'>No findings were raised.</p>") }
    [void]$sb.AppendLine('</section>')

    # ---- Remediation ----
    $remediation = @($findings | Where-Object { $_.Severity -in @('Critical', 'High', 'Medium') -and $_.Recommendation } |
        Select-Object Severity, Category, Title, Recommendation)
    [void]$sb.AppendLine('<section><h2>Recommended Remediation (prioritized)</h2>')
    [void]$sb.AppendLine((ConvertTo-AuditHtmlTable -Data $remediation -EmptyMessage 'No remediation required above Low severity.'))
    [void]$sb.AppendLine('</section>')

    # ---- Domain inventory ----
    if ($Inventory.Count -gt 0) {
        [void]$sb.AppendLine("<section><h2>Domain GPO Inventory ($($Inventory.Count))</h2>")
        $invRows = @($Inventory | ForEach-Object {
                [pscustomobject]@{
                    Name        = $_.DisplayName
                    Guid        = $_.Id
                    Status      = $_.GpoStatus
                    Linked      = $_.IsLinked
                    Empty       = $_.AppearsEmpty
                    WmiFilter   = $_.WmiFilter
                    Modified    = $_.ModificationTime
                    Extensions  = $_.Extensions
                    Report      = $_.ReportFile
                }
            })
        [void]$sb.AppendLine((ConvertTo-AuditHtmlTable -Data $invRows))
        [void]$sb.AppendLine('<h3>Individual GPO reports</h3><ul>')
        foreach ($g in $Inventory) {
            $href = 'DomainGPOs/' + [uri]::EscapeDataString("$($g.ReportFile)")
            [void]$sb.AppendLine("<li><a href='$href'>$(& $enc $g.DisplayName)</a></li>")
        }
        [void]$sb.AppendLine('</ul></section>')

        [void]$sb.AppendLine('<section><h2>GPO Link Map</h2>')
        [void]$sb.AppendLine((ConvertTo-AuditHtmlTable -Data (Get-PropertySafe -InputObject ([pscustomobject]$script:Datasets) -Name 'GPOLinks' -Default @()) -EmptyMessage 'Link inventory not collected.'))
        [void]$sb.AppendLine('</section>')

        [void]$sb.AppendLine('<section><h2>Security Filtering &amp; Delegation</h2>')
        [void]$sb.AppendLine((ConvertTo-AuditHtmlTable -Data (Get-PropertySafe -InputObject ([pscustomobject]$script:Datasets) -Name 'GPOPermissions' -Default @()) -EmptyMessage 'Permission audit not collected (use -IncludeSecurityAudit).'))
        [void]$sb.AppendLine('</section>')

        [void]$sb.AppendLine('<section><h2>WMI Filters</h2>')
        [void]$sb.AppendLine((ConvertTo-AuditHtmlTable -Data (Get-PropertySafe -InputObject ([pscustomobject]$script:Datasets) -Name 'WMIFilters' -Default @()) -EmptyMessage 'WMI filter audit not collected.'))
        [void]$sb.AppendLine('</section>')
    }

    # ---- Unavailable data ----
    [void]$sb.AppendLine('<section><h2>Data That Could Not Be Collected</h2>')
    [void]$sb.AppendLine((ConvertTo-AuditHtmlTable -Data $script:Unavailable.ToArray() -EmptyMessage 'Everything requested was collected successfully.'))
    [void]$sb.AppendLine('</section>')

    [void]$sb.AppendLine("</main><footer>GPO Audit v$($script:ScriptVersion) - read-only audit - all data local to this folder</footer></body></html>")

    $reportPath = Join-Path $Context.OutputPath 'GPOAudit-Report.html'
    Set-Content -Path $reportPath -Value $sb.ToString() -Encoding UTF8
    Write-AuditLog -Level Success -Message "Master HTML report: $reportPath"
    return $reportPath
}

function Write-ExecutiveSummaryFiles {
    <#
    .SYNOPSIS
        Plain-text executive summary + technical findings CSV/JSON exports.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context)

    $findings = $script:Findings.ToArray()
    Export-AuditDataset -Name 'Findings' -Data $findings -Folder $script:Paths.Summary
    Export-AuditDataset -Name 'UnavailableData' -Data $script:Unavailable.ToArray() -Folder $script:Paths.Summary

    $sevLine = foreach ($sev in @('Critical', 'High', 'Medium', 'Low', 'Informational')) {
        '{0}: {1}' -f $sev, @($findings | Where-Object { $_.Severity -eq $sev }).Count
    }
    $top = @($findings | Where-Object { $_.Severity -in @('Critical', 'High') } | Select-Object -First 15 |
        ForEach-Object { ' - [{0}] {1}' -f $_.Severity, $_.Title })
    $lines = @(
        'GROUP POLICY AUDIT - EXECUTIVE SUMMARY'
        '======================================'
        "Date          : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        "Operator      : $($Context.Operator)"
        "Computer      : $($Context.ComputerName)"
        "User          : $(if ($Context.UserName) { $Context.UserName } else { '(none)' })"
        "Domain        : $($Context.Domain)"
        "DC            : $($Context.DomainController)"
        ''
        'FINDINGS'
        ($sevLine -join ' | ')
        ''
        'TOP CRITICAL/HIGH ITEMS'
        $(if ($top.Count -gt 0) { $top } else { ' (none)' })
        ''
        "Full details: GPOAudit-Report.html and Summary\Findings.csv"
        "Items not collectable: $($script:Unavailable.Count) (see Summary\UnavailableData.csv)"
    )
    $sumPath = Join-Path $script:Paths.Summary 'ExecutiveSummary.txt'
    $lines | Out-File -FilePath $sumPath -Encoding UTF8
    Write-AuditLog -Level Success -Message "Executive summary: $sumPath"
}

# =============================================================================
#  MAIN
# =============================================================================
$exitCode = 0
$prereqResult  = $null
$computerInfo  = $null
$rsopAnalysis  = $null
$inventory     = @()

try {
    Write-Host ''
    Write-Host '=============================================================' -ForegroundColor Cyan
    Write-Host "  Group Policy Audit v$script:ScriptVersion  (read-only)" -ForegroundColor Cyan
    Write-Host '=============================================================' -ForegroundColor Cyan

    # ---------------- Output folders + logging ----------------
    if (-not $OutputPath) {
        $OutputPath = Join-Path "$env:SystemDrive\GPOAudit" ('{0}_{1}' -f (($ComputerName -split '\.')[0]).ToUpper(), $script:StartTime.ToString('yyyyMMdd_HHmmss'))
    }
    foreach ($sub in @('Summary', 'Computer', 'User', 'DomainGPOs', 'Links', 'Permissions', 'WMI-Filters', 'RSOP', 'EventLogs', 'RawData', 'Logs')) {
        $p = Join-Path $OutputPath $sub
        if (-not (Test-Path -LiteralPath $p)) { $null = New-Item -Path $p -ItemType Directory -Force -ErrorAction Stop }
    }
    $script:Paths = @{
        Root        = $OutputPath
        Summary     = Join-Path $OutputPath 'Summary'
        Computer    = Join-Path $OutputPath 'Computer'
        User        = Join-Path $OutputPath 'User'
        DomainGPOs  = Join-Path $OutputPath 'DomainGPOs'
        Links       = Join-Path $OutputPath 'Links'
        Permissions = Join-Path $OutputPath 'Permissions'
        WMIFilters  = Join-Path $OutputPath 'WMI-Filters'
        RSOP        = Join-Path $OutputPath 'RSOP'
        EventLogs   = Join-Path $OutputPath 'EventLogs'
        RawData     = Join-Path $OutputPath 'RawData'
        Logs        = Join-Path $OutputPath 'Logs'
    }
    $script:LogFile = Join-Path $script:Paths.Logs 'GPOAudit.log'
    try {
        Start-Transcript -Path (Join-Path $script:Paths.Logs 'Transcript.txt') -ErrorAction Stop | Out-Null
        $script:TranscriptOn = $true
    }
    catch {
        Write-Warning "Start-Transcript failed ($($_.Exception.Message)); continuing with the custom log only."
    }
    Write-AuditLog -Level Info -Message "Output folder: $OutputPath"
    Write-AuditLog -Level Info -Message "Command line: $($MyInvocation.Line)"

    # ---------------- Phase 1: environment validation ----------------
    Write-AuditLog -Level Section -Message 'Phase 1: Environment validation'
    Write-AuditLog -Level Info -Message "PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition)) on $([Environment]::OSVersion.VersionString)"

    if ($env:OS -ne 'Windows_NT') {
        throw 'This script must run on Windows (it drives gpresult.exe, RSAT, and CIM).'
    }
    if (-not (Test-IsAdministrator)) {
        throw 'Administrative privileges are required (computer-scope RSOP, event logs, RSAT installation). Start PowerShell elevated and rerun.'
    }
    Write-AuditLog -Level Success -Message 'Running with administrative privileges.'

    $osInfo = Get-HostOsInfo
    $null = Test-SupportedOperatingSystem -OsInfo $osInfo
    Write-AuditLog -Level Success -Message "Operating system: $($osInfo.Caption) build $($osInfo.BuildNumber) ($(if ($osInfo.IsServer) { 'Server' } else { 'Client' }))"

    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    if (-not $cs.PartOfDomain) {
        throw "This computer ($env:COMPUTERNAME) is not domain joined. A domain-joined audit host is required."
    }
    if (-not $Domain) { $Domain = $cs.Domain }
    Write-AuditLog -Level Success -Message "Domain joined: $($cs.Domain) (auditing domain: $Domain)"

    $script:HasCredential = ($Credential -and $Credential -ne [System.Management.Automation.PSCredential]::Empty)
    $script:IsLocalTarget = Test-LocalTarget -Name $ComputerName

    # ---------------- Phase 2: prerequisites ----------------
    Write-AuditLog -Level Section -Message 'Phase 2: RSAT prerequisites'
    $modulesPresent = (Get-Module -ListAvailable -Name GroupPolicy -ErrorAction SilentlyContinue) -and
                      (Get-Module -ListAvailable -Name ActiveDirectory -ErrorAction SilentlyContinue)
    if ($modulesPresent) {
        Write-AuditLog -Level Success -Message 'GroupPolicy and ActiveDirectory modules are present.'
    }
    else {
        Write-AuditLog -Level Warn -Message 'One or more RSAT modules are missing; checking installable prerequisites.'
        $prereqResult = Install-AuditPrerequisites -OsInfo $osInfo -Unattended:$InstallPrerequisites
    }

    # ---------------- Phase 3: module import (PS 5.1 / 7 handling) ----------------
    Write-AuditLog -Level Section -Message 'Phase 3: Module import'
    $script:GPModuleMode = Import-AuditModule -Name GroupPolicy     -ProbeCommand Get-GPO
    $script:ADModuleMode = Import-AuditModule -Name ActiveDirectory -ProbeCommand Get-ADDomain
    Write-AuditLog -Level Info -Message "GroupPolicy module: $script:GPModuleMode | ActiveDirectory module: $script:ADModuleMode"

    if ($script:GPModuleMode -eq 'Unavailable') {
        if ($PSVersionTable.PSEdition -eq 'Core') {
            Write-AuditLog -Level Error -Message 'The GroupPolicy module could not be loaded under PowerShell 7, even via the Windows PowerShell compatibility layer.'
            if ($RelaunchInWindowsPowerShell) {
                if ($script:TranscriptOn) { try { Stop-Transcript | Out-Null } catch { }; $script:TranscriptOn = $false }
                Invoke-RelaunchInWindowsPowerShell -BoundParameters $PSBoundParameters
            }
            throw 'Run this script in Windows PowerShell 5.1 (powershell.exe), or rerun with -RelaunchInWindowsPowerShell. The GroupPolicy RSAT module is not natively supported on PowerShell 7.'
        }
        throw 'The GroupPolicy module is unavailable. Install RSAT (rerun with -InstallPrerequisites) and try again.'
    }
    if ($script:ADModuleMode -eq 'Unavailable') {
        Write-AuditLog -Level Warn -Message 'ActiveDirectory module unavailable: OU/site/WMI-filter enumeration will be limited. Install Rsat.ActiveDirectory.DS-LDS.Tools / RSAT-AD-PowerShell.'
        Add-UnavailableItem -Area 'ActiveDirectory module' -Reason 'Module not available; LDAP-based collection (OUs, sites, WMI filters, SYSVOL cross-check) is degraded.'
    }

    # ---------------- Phase 4: domain context + connectivity ----------------
    Write-AuditLog -Level Section -Message 'Phase 4: Domain context and connectivity'
    $connectivity = Test-AuditConnectivity -DomainName $Domain -PreferredDC $DomainController
    if (-not $DomainController) { $DomainController = $connectivity.DomainController }

    if ($script:HasCredential) { $script:AdParams.Credential = $Credential }
    if ($DomainController) {
        $script:AdParams.Server = $DomainController
        $script:GpParams.Server = $DomainController
    }
    $script:GpParams.Domain = $Domain

    if ($script:ADModuleMode -ne 'Unavailable') {
        try {
            $script:DomainInfo = Get-ADDomain -Identity $Domain @script:AdParams -ErrorAction Stop
            $script:DomainDN = $script:DomainInfo.DistinguishedName
            $rootDse = Get-ADRootDSE @script:AdParams -ErrorAction Stop
            $script:ConfigNC = $rootDse.configurationNamingContext
            Write-AuditLog -Level Success -Message "Domain DN: $script:DomainDN"
        }
        catch {
            Write-AuditLog -Level Error -Message "AD domain query failed: $($_.Exception.Message)"
            Add-UnavailableItem -Area 'AD domain context' -Reason $_.Exception.Message
        }
    }
    if (-not $script:DomainDN) {
        # LDAP fallback that works without the AD module
        try {
            $rootDse = [ADSI]"LDAP://$Domain/RootDSE"
            $script:DomainDN = "$($rootDse.Get('defaultNamingContext'))"
            $script:ConfigNC = "$($rootDse.Get('configurationNamingContext'))"
            $script:DomainInfo = [pscustomobject]@{ DNSRoot = $Domain; DistinguishedName = $script:DomainDN }
        }
        catch {
            Write-AuditLog -Level Error -Message "LDAP RootDSE fallback failed: $($_.Exception.Message)"
        }
    }

    # ---------------- Phase 5: optional gpupdate (explicit opt-in only) ----------------
    if ($ForceGPUpdate) {
        Write-AuditLog -Level Section -Message 'Phase 5: gpupdate /force (explicitly requested)'
        if ($PSCmdlet.ShouldProcess($ComputerName, 'gpupdate /force')) {
            try {
                if ($script:IsLocalTarget) {
                    & "$env:SystemRoot\System32\gpupdate.exe" /force 2>&1 | ForEach-Object { Write-AuditLog -Level Info -Message "gpupdate: $_" }
                }
                else {
                    Test-TargetConnectivity -Target $ComputerName
                    if ($script:WinRMAvailable) {
                        $icm = @{ ComputerName = $ComputerName; ErrorAction = 'Stop' }
                        if ($script:HasCredential) { $icm.Credential = $Credential }
                        Invoke-Command @icm -ScriptBlock { & "$env:SystemRoot\System32\gpupdate.exe" /force 2>&1 } |
                            ForEach-Object { Write-AuditLog -Level Info -Message "gpupdate[remote]: $_" }
                    }
                    else { Add-UnavailableItem -Area 'gpupdate /force (remote)' -Reason 'WinRM unavailable.' }
                }
            }
            catch { Write-AuditLog -Level Error -Message "gpupdate failed: $($_.Exception.Message)" }
        }
    }

    # ---------------- Phase 6: target computer ----------------
    $script:__ci = $null
    Invoke-AuditStep -Name 'Phase 6: Target connectivity and computer information' -Action {
        Test-TargetConnectivity -Target $ComputerName
        $script:__ci = Get-TargetComputerInfo -Target $ComputerName
    }
    $computerInfo = $script:__ci

    # ---------------- Phase 7: RSOP / gpresult ----------------
    $doRsop = $true
    if ($SkipRemoteRSOP -and -not $script:IsLocalTarget) {
        Write-AuditLog -Level Info -Message 'SkipRemoteRSOP set: skipping gpresult/RSOP against the remote target.'
        Add-UnavailableItem -Area 'RSOP collection' -Reason 'Skipped by -SkipRemoteRSOP.'
        $doRsop = $false
    }
    if ($doRsop) {
        Invoke-AuditStep -Name 'Phase 7a: gpresult collection (/R /Z /H /X)' -Action {
            Invoke-GpResultCollection -Target $ComputerName -User $UserName
        }
        Invoke-AuditStep -Name 'Phase 7b: Get-GPResultantSetOfPolicy' -Action {
            Invoke-RsopCollection -Target $ComputerName -User $UserName
        }
        $script:__rsop = $null
        Invoke-AuditStep -Name 'Phase 7c: Applied/denied GPO analysis' -Action {
            $script:__rsop = Get-AppliedGpoAnalysis
        }
        $rsopAnalysis = $script:__rsop
    }

    # ---------------- Phase 8: event logs ----------------
    if ($IncludeEventLogs) {
        Invoke-AuditStep -Name 'Phase 8: Group Policy operational event log' -Action {
            Get-GroupPolicyEventLogData -Target $ComputerName -Days $EventLogDays
        }
    }

    # ---------------- Phase 9: domain inventory / links / permissions / WMI ----------------
    if ($IncludeDomainInventory -or $IncludeSecurityAudit) {
        $script:__inv = @()
        Invoke-AuditStep -Name 'Phase 9a: Domain GPO inventory' -Action {
            $script:__inv = Get-DomainGpoInventory
        }
        $inventory = @($script:__inv)
    }
    if ($IncludeDomainInventory -and $script:ADModuleMode -ne 'Unavailable') {
        Invoke-AuditStep -Name 'Phase 9b: GPO link inventory (sites/domain/OUs)' -Action {
            $null = Get-GpoLinkInventory
        }
    }
    if ($IncludeSecurityAudit -or $IncludeDomainInventory) {
        Invoke-AuditStep -Name 'Phase 9c: Security filtering and delegation audit' -Action {
            Get-GpoPermissionAudit
        }
        if ($script:ADModuleMode -ne 'Unavailable') {
            Invoke-AuditStep -Name 'Phase 9d: WMI filter audit' -Action {
                Get-WmiFilterAudit
            }
        }
    }

    # ---------------- Phase 10: SYSVOL validation ----------------
    if ($script:ADModuleMode -ne 'Unavailable' -and $script:DomainDN) {
        Invoke-AuditStep -Name 'Phase 10: SYSVOL validation (read-only)' -Action {
            Test-SysvolConsistency -DomainName $Domain
        }
    }

    # ---------------- Phase 11: findings + reports ----------------
    Invoke-AuditStep -Name 'Phase 11: Findings analysis' -Action {
        Invoke-GpoFindingsAnalysis -Inventory $inventory
    }

    Write-AuditLog -Level Section -Message 'Phase 12: Report generation'
    $context = @{
        ComputerName     = $ComputerName
        UserName         = $UserName
        Domain           = $Domain
        DomainController = "$DomainController"
        Operator         = "$env:USERDOMAIN\$env:USERNAME"
        OutputPath       = $OutputPath
    }
    Write-ExecutiveSummaryFiles -Context $context
    $script:MasterReport = New-MasterHtmlReport -ComputerInfo $computerInfo -RsopAnalysis $rsopAnalysis `
        -Inventory $inventory -PrereqResult $prereqResult -Context $context

    # ---------------- Wrap-up ----------------
    $elapsed = (Get-Date) - $script:StartTime
    Write-Host ''
    Write-Host '=============================================================' -ForegroundColor Cyan
    Write-Host ('  Audit complete in {0:mm\:ss}  -  {1} finding(s), {2} item(s) unavailable' -f $elapsed, $script:Findings.Count, $script:Unavailable.Count) -ForegroundColor Cyan
    Write-Host "  Report: $script:MasterReport" -ForegroundColor Cyan
    Write-Host '=============================================================' -ForegroundColor Cyan
    if ($script:RestartNeeded) {
        Write-Warning 'A restart is still required to finish prerequisite installation.'
    }
    if ($OpenReport -and $script:MasterReport -and (Test-Path -LiteralPath $script:MasterReport)) {
        Invoke-Item -Path $script:MasterReport
    }
}
catch {
    $exitCode = 1
    $msg = $_.Exception.Message
    Write-AuditLog -Level Error -Message "FATAL: $msg"
    Write-Error -Message "GPO audit aborted: $msg" -ErrorAction Continue
    if ($_.ScriptStackTrace) { Write-AuditLog -Level Debug -Message $_.ScriptStackTrace }
}
finally {
    if ($script:CimSession) {
        try { Remove-CimSession -CimSession $script:CimSession -ErrorAction SilentlyContinue } catch { }
    }
    if ($script:TranscriptOn) {
        try { Stop-Transcript | Out-Null } catch { }
    }
}
exit $exitCode
