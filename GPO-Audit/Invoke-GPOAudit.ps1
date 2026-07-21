#Requires -Version 5.1
#==============================================================================
#  Invoke-GPOAudit.ps1  -  Production Group Policy Object Audit Script
#  Version  : 1.0.0
#  Safe     : READ-ONLY except RSAT installation and local report files
#  Platform : Windows 10, 11, Server 2019, 2022, 2025
#==============================================================================

<#
.SYNOPSIS
    Audits and documents every Group Policy Object that affects a target
    Windows computer and, optionally, a specified user. Generates HTML,
    CSV, JSON, and XML reports.

.DESCRIPTION
    Produces a complete picture of the Group Policy environment including:
      - Full RSOP for the specified computer and user via gpresult and
        Get-GPResultantSetOfPolicy
      - Domain-wide GPO inventory with version, status, and content analysis
      - GPO link map: site, domain, and every OU
      - Security filtering and delegation ACL analysis
      - WMI filter inventory and consistency check
      - SYSVOL <-> Active Directory consistency check
      - Group Policy Operational event log analysis
      - Categorised findings: Critical / High / Medium / Low / Informational
      - Master HTML report (embedded CSS, no external dependencies), individual
        per-GPO HTML and XML reports, CSV and JSON exports, plain-text log,
        executive summary, and remediation recommendations

    READ-ONLY except for RSAT component installation (requires confirmation
    or -InstallPrerequisites) and creating local report files.

.PARAMETER ComputerName
    Name of the computer to audit. Defaults to the local machine.

.PARAMETER UserName
    Optional user to include in RSOP analysis. Accepts DOMAIN\User or UPN.

.PARAMETER OutputPath
    Root folder for report files.
    Defaults to C:\GPOAudit\<ComputerName>_yyyyMMdd_HHmmss.

.PARAMETER Domain
    AD domain FQDN. Defaults to $env:USERDNSDOMAIN.

.PARAMETER DomainController
    Specific DC to target. Defaults to the PDC Emulator or logon DC.

.PARAMETER Credential
    PSCredential for privileged or remote operations. Never written to disk.

.PARAMETER InstallPrerequisites
    Install missing RSAT components without an interactive prompt.

.PARAMETER IncludeDomainInventory
    Enumerate every GPO, link, WMI filter, and (with -IncludeSecurityAudit)
    every permission set in the domain.

.PARAMETER IncludeEventLogs
    Collect the Group Policy Operational event log from the target computer.

.PARAMETER IncludeSecurityAudit
    Deep ACL and delegation analysis for every GPO.
    Requires -IncludeDomainInventory.

.PARAMETER SkipRemoteRSOP
    Skip RSOP collection on the remote computer.

.PARAMETER OpenReport
    Open the master HTML report in the default browser when done.

.PARAMETER StaleGPODays
    Days without modification before a GPO is flagged as stale. Default: 365.

.EXAMPLE
    .\Invoke-GPOAudit.ps1 -InstallPrerequisites -IncludeDomainInventory -IncludeEventLogs

.EXAMPLE
    .\Invoke-GPOAudit.ps1 `
        -ComputerName PC123 `
        -UserName 'DOMAIN\User1' `
        -IncludeDomainInventory `
        -IncludeEventLogs `
        -OutputPath C:\Audits\PC123

.EXAMPLE
    .\Invoke-GPOAudit.ps1 -IncludeDomainInventory -SkipRemoteRSOP

.EXAMPLE
    $Credential = Get-Credential
    .\Invoke-GPOAudit.ps1 -ComputerName PC123 -Credential $Credential -IncludeDomainInventory

.NOTES
    PERMISSIONS REQUIRED
    Local Administrator (script host)  : Always required (auto-elevates via UAC).
    Standard Domain User               : Own-account gpresult, read GPO metadata.
    Delegated GPO Reader               : Full inventory, ACL audit.
    Domain Admin                       : All features, SYSVOL, full ACLs.
    Local Admin on target              : Remote RSOP, remote event logs.
    SYSVOL (Authenticated Users read)  : cpassword scan, GPT.INI comparison.

    If not already elevated, the script re-launches itself with RunAs and
    the same parameters (except -Credential, which cannot be forwarded).

    PowerShell 5.1 is preferred. The GroupPolicy module is a Windows
    PowerShell binary module. In PS 7 the script attempts the
    -UseWindowsPowerShell compatibility shim and warns if that fails.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param (
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ComputerName = $env:COMPUTERNAME,

    [Parameter()]
    [string]$UserName,

    [Parameter()]
    [string]$OutputPath,

    [Parameter()]
    [string]$Domain = $(if ($env:USERDNSDOMAIN) { $env:USERDNSDOMAIN } else { '' }),

    [Parameter()]
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
    [ValidateRange(1, 9999)]
    [int]$StaleGPODays = 365
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

#region ── Script-scope state ──────────────────────────────────────────────────

$script:StartTime         = Get-Date
$script:Findings          = [System.Collections.Generic.List[pscustomobject]]::new()
$script:LogLines          = [System.Collections.Generic.List[string]]::new()
$script:GPModuleLoaded    = $false
$script:ADModuleLoaded    = $false
$script:IsRemote          = ($ComputerName -ne $env:COMPUTERNAME)
$script:RootOutput        = ''
$script:ReportPath        = ''
$script:DC                = ''
$script:SectionSeq        = 0
$script:BoundParameters  = @{} + $PSBoundParameters

#endregion

#region ── LOGGING AND HELPERS ─────────────────────────────────────────────────

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR','SUCCESS','SECTION')]
        [string]$Level = 'INFO'
    )
    process {
        $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $line = "[$ts][$Level] $Message"
        $script:LogLines.Add($line)
        switch ($Level) {
            'SECTION' { Write-Host "`n=== $Message ===" -ForegroundColor Cyan }
            'SUCCESS' { Write-Host "  [OK] $Message"   -ForegroundColor Green }
            'WARN'    { Write-Warning $Message }
            'ERROR'   { Write-Error   $Message -ErrorAction Continue }
            default   { Write-Verbose $line }
        }
    }
}

function Add-Finding {
    [CmdletBinding()]
    param(
        [ValidateSet('Critical','High','Medium','Low','Informational')]
        [string]$Severity,
        [string]$Category,
        [string]$Title,
        [string]$Detail         = '',
        [string]$Recommendation = '',
        [string]$AffectedObject = ''
    )
    $script:Findings.Add([pscustomobject]@{
        Severity        = $Severity
        Category        = $Category
        Title           = $Title
        Detail          = $Detail
        Recommendation  = $Recommendation
        AffectedObject  = $AffectedObject
    })
    $lv = if ($Severity -in 'Critical','High') { 'WARN' } else { 'INFO' }
    Write-Log "Finding [$Severity][$Category] $Title" -Level $lv
}

function Get-SafeFileName {
    param([Parameter(Mandatory)][string]$Name)
    $invalid = [System.IO.Path]::GetInvalidFileNameChars()
    $safe    = $Name
    foreach ($c in $invalid) { $safe = $safe.Replace([string]$c, '_') }
    $safe = $safe -replace '\s+', '_'
    if ($safe.Length -gt 180) { $safe = $safe.Substring(0, 180) }
    return $safe
}

function ConvertTo-HtmlEncoded {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $Text -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;' -replace "'", '&#39;'
}

function New-HtmlTable {
    param([object[]]$Data, [string[]]$Properties)
    if ((Get-SafeCount $Data) -eq 0) { return '<p class="no-data">No data available.</p>' }
    if (-not $Properties -or $Properties.Count -eq 0) {
        $Properties = @($Data[0].PSObject.Properties | ForEach-Object { $_.Name })
    }
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append('<table><thead><tr>')
    foreach ($p in $Properties) { [void]$sb.Append("<th>$(ConvertTo-HtmlEncoded $p)</th>") }
    [void]$sb.Append('</tr></thead><tbody>')
    foreach ($row in $Data) {
        [void]$sb.Append('<tr>')
        foreach ($p in $Properties) {
            $val = Get-ObjectProperty -InputObject $row -Name $p -Default ''
            if ($null -eq $val) { $val = '' }
            [void]$sb.Append("<td>$(ConvertTo-HtmlEncoded ($val.ToString()))</td>")
        }
        [void]$sb.Append('</tr>')
    }
    [void]$sb.Append('</tbody></table>')
    return $sb.ToString()
}

function New-HtmlSection {
    param([string]$Title, [string]$Content, [switch]$Collapsed)
    $script:SectionSeq++
    $id     = "sec$($script:SectionSeq)"
    $toggle = if ($Collapsed) { '[+]' } else { '[-]' }
    $style  = if ($Collapsed) { ' style="display:none"' } else { '' }
    return @"
<div class="section">
  <div class="section-hdr" onclick="toggleSec('$id')">
    <span class="sec-title">$(ConvertTo-HtmlEncoded $Title)</span>
    <span id="toggle_$id" class="toggle-btn">$toggle</span>
  </div>
  <div class="section-body" id="body_$id"$style>
    $Content
  </div>
</div>
"@
}

#endregion

#region ── OS / ENVIRONMENT DETECTION ─────────────────────────────────────────

function Get-OSInfo {
    $os = $null
    try   { $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop }
    catch { try { $os = Get-WmiObject -Class Win32_OperatingSystem -ErrorAction Stop } catch {} }
    $caption = if ($os) { $os.Caption } else { [System.Environment]::OSVersion.VersionString }
    $build   = if ($os) { $os.BuildNumber } else { [System.Environment]::OSVersion.Version.Build.ToString() }
    [pscustomobject]@{
        Caption  = $caption
        Build    = $build
        IsClient = ($caption -match 'Windows 10|Windows 11')
        IsServer = ($caption -match 'Windows Server')
    }
}

function Test-IsAdmin {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object System.Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ObjectProperty {
    <#
    .SYNOPSIS
        StrictMode-safe property read. Returns $Default when missing or input is null.
    #>
    param(
        [AllowNull()]$InputObject,
        [Parameter(Mandatory)][string]$Name,
        $Default = $null
    )
    if ($null -eq $InputObject) { return $Default }
    $prop = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $Default }
    return $prop.Value
}

function Get-SafeCount {
    param([AllowNull()]$InputObject)
    return @($InputObject).Count
}

function Test-IsDeserializedTypeName {
    # WinPS compatibility shim often replaces complex objects with their type name string.
    param([AllowNull()]$Value, [string]$TypeName)
    return ($Value -is [string] -and $Value -eq $TypeName)
}

function Get-GpoAdVersions {
    <#
    .SYNOPSIS
        User/Computer GPO versions from the GPO object, or GPT.INI when the PS7 shim omits them.
    #>
    param(
        [Parameter(Mandatory)]$Gpo,
        [string]$DomainName
    )
    $userVer = Get-ObjectProperty -InputObject $Gpo -Name 'UserVersion'
    $compVer = Get-ObjectProperty -InputObject $Gpo -Name 'ComputerVersion'
    if ($null -ne $userVer -and $null -ne $compVer) {
        return @{ User = ([int]$userVer -band 0xFFFF); Computer = ([int]$compVer -band 0xFFFF) }
    }

    try {
        $id = [string](Get-ObjectProperty -InputObject $Gpo -Name 'Id' -Default '')
        $id = $id.Trim('{}')
        if (-not $id -or -not $DomainName) { return @{ User = 0; Computer = 0 } }
        $gptPath = "\\$DomainName\SYSVOL\$DomainName\Policies\{$id}\GPT.INI"
        if (-not (Test-Path -LiteralPath $gptPath)) { return @{ User = 0; Computer = 0 } }
        $vLine = Get-Content -LiteralPath $gptPath -ErrorAction Stop |
            Where-Object { $_ -match '^\s*Version\s*=' } |
            Select-Object -First 1
        if (-not $vLine) { return @{ User = 0; Computer = 0 } }
        $sysVer = [int](($vLine -replace '.*=\s*', '').Trim())
        return @{ User = ($sysVer -shr 16); Computer = ($sysVer -band 0xFFFF) }
    }
    catch {
        return @{ User = 0; Computer = 0 }
    }
}

function Invoke-WindowsPowerShellJson {
    <#
    .SYNOPSIS
        Runs a script in Windows PowerShell 5.1 and returns objects from JSON.
        Used when the PS7 WinPS compatibility shim drops complex GroupPolicy types.
    #>
    param(
        [Parameter(Mandatory)][string]$Script,
        [int]$Depth = 6
    )
    $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $exe)) {
        throw 'Windows PowerShell 5.1 not found (powershell.exe).'
    }

    $wrapped = @"
`$ErrorActionPreference = 'Stop'
Import-Module GroupPolicy -ErrorAction Stop
try { Import-Module ActiveDirectory -ErrorAction SilentlyContinue } catch {}
`$__result = . { $Script }
if (`$null -eq `$__result) { return }
`$__result | ConvertTo-Json -Depth $Depth -Compress
"@
    $tmpIn  = [System.IO.Path]::ChangeExtension([System.IO.Path]::GetTempFileName(), '.ps1')
    $tmpOut = [System.IO.Path]::GetTempFileName()
    $tmpErr = "$tmpOut.err"
    try {
        Set-Content -LiteralPath $tmpIn -Value $wrapped -Encoding UTF8
        $p = Start-Process -FilePath $exe `
            -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $tmpIn) `
            -Wait -PassThru -WindowStyle Hidden `
            -RedirectStandardOutput $tmpOut -RedirectStandardError $tmpErr
        $json = Get-Content -LiteralPath $tmpOut -Raw -ErrorAction SilentlyContinue
        if ($p.ExitCode -ne 0 -and [string]::IsNullOrWhiteSpace($json)) {
            $errText = Get-Content -LiteralPath $tmpErr -Raw -ErrorAction SilentlyContinue
            throw "Windows PowerShell call failed (exit $($p.ExitCode)): $errText"
        }
        if ([string]::IsNullOrWhiteSpace($json)) { return @() }
        $parsed = $json | ConvertFrom-Json
        return @($parsed)
    }
    finally {
        Remove-Item -LiteralPath $tmpIn, $tmpOut, $tmpErr -Force -ErrorAction SilentlyContinue
    }
}

function Request-AdministratorElevation {
    <#
    .SYNOPSIS
        Re-launches this script elevated via UAC, preserving bound parameters.
    #>
    [CmdletBinding()]
    param()

    if ($script:BoundParameters.ContainsKey('Credential') -and
        $script:BoundParameters['Credential'] -and
        $script:BoundParameters['Credential'] -ne [System.Management.Automation.PSCredential]::Empty) {
        Write-Error 'Cannot auto-elevate while -Credential is specified (credentials cannot be forwarded safely). Start an elevated PowerShell session and re-run with -Credential.'
        exit 1
    }

    $hostExe = Join-Path -Path $PSHOME -ChildPath $(
        if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
    )
    if (-not (Test-Path -LiteralPath $hostExe)) {
        $hostExe = (Get-Process -Id $PID).Path
    }

    $scriptPath = $PSCommandPath
    if (-not $scriptPath) { $scriptPath = $MyInvocation.MyCommand.Path }
    if (-not $scriptPath -or -not (Test-Path -LiteralPath $scriptPath)) {
        Write-Error 'Unable to resolve script path for elevation.'
        exit 1
    }

    $argParts = [System.Collections.Generic.List[string]]::new()
    [void]$argParts.Add('-NoProfile')
    [void]$argParts.Add('-ExecutionPolicy Bypass')
    [void]$argParts.Add('-File')
    [void]$argParts.Add(('"{0}"' -f $scriptPath))

    foreach ($key in $script:BoundParameters.Keys) {
        if ($key -eq 'Credential') { continue }

        $value = $script:BoundParameters[$key]
        if ($value -is [System.Management.Automation.SwitchParameter]) {
            if ($value.IsPresent) { [void]$argParts.Add("-$key") }
            continue
        }
        if ($value -is [bool]) {
            if ($value) { [void]$argParts.Add("-$key") }
            continue
        }

        [void]$argParts.Add("-$key")
        [void]$argParts.Add(('"{0}"' -f ([string]$value).Replace('"', '\"')))
    }

    $argumentList = $argParts -join ' '
    Write-Host 'Administrator privileges required. Prompting for elevation (UAC)...' -ForegroundColor Yellow

    try {
        $proc = Start-Process -FilePath $hostExe -ArgumentList $argumentList -Verb RunAs -Wait -PassThru
        if ($null -eq $proc) {
            Write-Error 'Elevation failed or was cancelled.'
            exit 1
        }
        exit $proc.ExitCode
    }
    catch {
        Write-Error "Elevation failed or was cancelled: $_"
        exit 1
    }
}

function Test-IsDomainJoined {
    try { return [bool](Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).PartOfDomain }
    catch { return $false }
}

function Get-EnvironmentInfo {
    Write-Log 'Collecting environment information' -Level SECTION
    $osInfo = Get-OSInfo
    $psVer  = $PSVersionTable.PSVersion.ToString()
    $psEd   = if ($PSVersionTable.PSEdition) { $PSVersionTable.PSEdition } else { 'Desktop' }

    $dc = $DomainController
    if (-not $dc) {
        try { $dc = ([System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()).PdcRoleOwner.Name }
        catch { $dc = if ($env:LOGONSERVER) { $env:LOGONSERVER.TrimStart('\') } else { 'Unknown' } }
    }
    $script:DC = $dc

    if ([string]::IsNullOrEmpty($Domain)) {
        try { $script:Domain = ([System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()).Name }
        catch {}
    }

    $site = 'Unknown'
    try { $site = [System.DirectoryServices.ActiveDirectory.ActiveDirectorySite]::GetComputerSite().Name } catch {}
    $fqdn = try { [System.Net.Dns]::GetHostEntry('').HostName } catch { "$($env:COMPUTERNAME).$Domain" }

    $info = [pscustomobject]@{
        ComputerName     = $env:COMPUTERNAME
        FQDN             = $fqdn
        Domain           = $Domain
        DomainController = $dc
        ADSite           = $site
        CurrentUser      = "$env:USERDOMAIN\$env:USERNAME"
        OSCaption        = $osInfo.Caption
        OSBuild          = $osInfo.Build
        OSIsClient       = $osInfo.IsClient
        OSIsServer       = $osInfo.IsServer
        PSVersion        = $psVer
        PSEdition        = $psEd
        IsAdmin          = Test-IsAdmin
        IsDomainJoined   = Test-IsDomainJoined
        AuditTarget      = $ComputerName
        AuditUser        = if ($UserName) { $UserName } else { '(not specified)' }
    }
    Write-Log "  Computer : $($info.ComputerName)"
    Write-Log "  Domain   : $($info.Domain)"
    Write-Log "  DC       : $($info.DomainController)"
    Write-Log "  OS       : $($info.OSCaption) [$($info.OSBuild)]"
    Write-Log "  PS       : $psVer [$psEd]"
    return $info
}

#endregion

#region ── POWERSHELL MODULE LOADING ──────────────────────────────────────────

function Import-RequiredModules {
    Write-Log 'Loading required PowerShell modules' -Level SECTION
    $psEd = $PSVersionTable.PSEdition

    # GroupPolicy
    if (Get-Module -Name GroupPolicy -ErrorAction SilentlyContinue) {
        $script:GPModuleLoaded = $true
        Write-Log '  GroupPolicy: already loaded.' -Level SUCCESS
    } elseif ($psEd -eq 'Core') {
        Write-Log '  PS 7 detected. Loading GroupPolicy via -UseWindowsPowerShell...' -Level WARN
        try {
            Import-Module GroupPolicy -UseWindowsPowerShell -ErrorAction Stop -WarningAction SilentlyContinue
            $script:GPModuleLoaded = $true
            Write-Log '  GroupPolicy: loaded via compatibility shim.' -Level SUCCESS
        } catch {
            Write-Log '  GroupPolicy FAILED to load in PS7. Re-run in powershell.exe (5.1).' -Level WARN
            Add-Finding -Severity High -Category Prerequisites `
                -Title  'GroupPolicy module not available in PowerShell 7' `
                -Detail "Error: $_" `
                -Recommendation 'Run this script in Windows PowerShell 5.1: powershell.exe -File .\Invoke-GPOAudit.ps1'
        }
    } else {
        try {
            Import-Module GroupPolicy -ErrorAction Stop
            $script:GPModuleLoaded = $true
            Write-Log '  GroupPolicy: loaded.' -Level SUCCESS
        } catch {
            Write-Log "  GroupPolicy module not available: $_" -Level WARN
            Add-Finding -Severity High -Category Prerequisites `
                -Title  'GroupPolicy module could not be loaded' `
                -Detail "Error: $_" `
                -Recommendation 'Install RSAT Group Policy Management Tools.'
        }
    }

    # ActiveDirectory
    if (Get-Module -Name ActiveDirectory -ErrorAction SilentlyContinue) {
        $script:ADModuleLoaded = $true
        Write-Log '  ActiveDirectory: already loaded.' -Level SUCCESS
    } elseif ($psEd -eq 'Core') {
        try {
            Import-Module ActiveDirectory -UseWindowsPowerShell -ErrorAction Stop -WarningAction SilentlyContinue
            $script:ADModuleLoaded = $true
            Write-Log '  ActiveDirectory: loaded via compatibility shim.' -Level SUCCESS
        } catch {
            Write-Log "  ActiveDirectory not available in PS7 compat mode: $_" -Level WARN
        }
    } else {
        try {
            Import-Module ActiveDirectory -ErrorAction Stop
            $script:ADModuleLoaded = $true
            Write-Log '  ActiveDirectory: loaded.' -Level SUCCESS
        } catch {
            Write-Log "  ActiveDirectory module not available: $_" -Level WARN
        }
    }
}

#endregion

#region ── RSAT PREREQUISITE CHECK AND INSTALLATION ───────────────────────────

function Test-RSATAvailable {
    param([pscustomobject]$OSInfo)
    $gpOk = $false; $adOk = $false
    if ($OSInfo.IsClient) {
        try {
            $gpOk = (Get-WindowsCapability -Online -Name 'Rsat.GroupPolicy.Management.Tools~~~~0.0.1.0' -ErrorAction Stop).State -eq 'Installed'
            $adOk = (Get-WindowsCapability -Online -Name 'Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0' -ErrorAction Stop).State -eq 'Installed'
        } catch {}
    } elseif ($OSInfo.IsServer) {
        try {
            $gpOk = (Get-WindowsFeature -Name GPMC               -ErrorAction Stop).Installed
            $adOk = (Get-WindowsFeature -Name RSAT-AD-PowerShell -ErrorAction Stop).Installed
        } catch {}
    }
    [pscustomobject]@{ GroupPolicyRSAT = $gpOk; ActiveDirectoryRSAT = $adOk }
}

function Install-RSATComponents {
    [CmdletBinding(SupportsShouldProcess)]
    param([pscustomobject]$OSInfo)
    Write-Log 'Installing missing RSAT components' -Level SECTION
    $rebootNeeded = $false

    if ($OSInfo.IsClient) {
        foreach ($cap in @('Rsat.GroupPolicy.Management.Tools~~~~0.0.1.0','Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0')) {
            try { $state = (Get-WindowsCapability -Online -Name $cap -ErrorAction Stop).State } catch { continue }
            if ($state -eq 'Installed') { Write-Log "  Already installed: $cap" -Level SUCCESS; continue }
            if ($PSCmdlet.ShouldProcess($cap, 'Add-WindowsCapability')) {
                try {
                    $r = Add-WindowsCapability -Online -Name $cap -ErrorAction Stop
                    if ($r.RestartNeeded) { $rebootNeeded = $true }
                    Write-Log "  Installed: $cap" -Level SUCCESS
                } catch { Write-Log "  FAILED '$cap': $_" -Level ERROR }
            }
        }
    } elseif ($OSInfo.IsServer) {
        foreach ($feat in @('GPMC','RSAT-AD-PowerShell')) {
            try { $installed = (Get-WindowsFeature -Name $feat -ErrorAction Stop).Installed } catch { continue }
            if ($installed) { Write-Log "  Already installed: $feat" -Level SUCCESS; continue }
            if ($PSCmdlet.ShouldProcess($feat, 'Install-WindowsFeature')) {
                try {
                    $r = Install-WindowsFeature -Name $feat -ErrorAction Stop
                    if ($r.RestartNeeded -ne 'No') { $rebootNeeded = $true }
                    Write-Log "  Installed: $feat" -Level SUCCESS
                } catch { Write-Log "  FAILED '$feat': $_" -Level ERROR }
            }
        }
    } else {
        Write-Log '  OS not recognised. Cannot install RSAT automatically.' -Level WARN
    }

    if ($rebootNeeded) {
        Write-Log '  RESTART REQUIRED to activate newly installed RSAT components.' -Level WARN
        Add-Finding -Severity Medium -Category Prerequisites `
            -Title  'Restart required after RSAT installation' `
            -Detail 'One or more RSAT components need a reboot.' `
            -Recommendation 'Restart and re-run the audit.'
    }
}

#endregion

#region ── CONNECTIVITY TESTING ───────────────────────────────────────────────

function Test-TCPPort {
    param([string]$HostName, [int]$Port, [int]$TimeoutMs = 2000)
    $tcp = New-Object System.Net.Sockets.TcpClient
    try {
        $ar = $tcp.BeginConnect($HostName, $Port, $null, $null)
        $ok = $ar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if ($ok -and $tcp.Connected) { $tcp.EndConnect($ar); return $true }
        return $false
    } catch { return $false }
    finally  { $tcp.Close() }
}

function Test-DomainConnectivity {
    param([string]$DC, [string]$DomainName)
    Write-Log 'Testing domain connectivity' -Level SECTION
    $r = [ordered]@{}

    $r['DNS_Domain']     = try { $null = [System.Net.Dns]::GetHostAddresses($DomainName); 'OK' } catch { "FAILED: $_" }
    $r['DC_Ping']        = try { if (Test-Connection $DC -Count 1 -Quiet -EA Stop) {'OK'} else {'FAILED: no ICMP'} } catch {"FAILED: $_"}
    $r['LDAP_389']       = if (Test-TCPPort $DC 389)  { 'OK' } else { 'FAILED: TCP 389 unreachable' }
    $r['GC_3268']        = if (Test-TCPPort $DC 3268) { 'OK' } else { 'FAILED: TCP 3268 unreachable' }
    $r['SMB_445']        = if (Test-TCPPort $DC 445)  { 'OK' } else { 'FAILED: TCP 445 unreachable' }
    $r['SYSVOL_Share']   = try { if (Test-Path "\\$DomainName\SYSVOL"   -EA Stop) {'OK'} else {'NOT ACCESSIBLE'} } catch {"FAILED: $_"}
    $r['NETLOGON_Share'] = try { if (Test-Path "\\$DomainName\NETLOGON" -EA Stop) {'OK'} else {'NOT ACCESSIBLE'} } catch {"FAILED: $_"}

    foreach ($k in $r.Keys) {
        $lv = if ($r[$k] -eq 'OK') { 'SUCCESS' } else { 'WARN' }
        Write-Log "  $k : $($r[$k])" -Level $lv
    }
    foreach ($k in $r.Keys) {
        if ($r[$k] -ne 'OK') {
            $sev = if ($k -in 'DNS_Domain','LDAP_389','DC_Ping') { 'High' } else { 'Medium' }
            Add-Finding -Severity $sev -Category Connectivity `
                -Title  "Connectivity failure: $k" -Detail $r[$k] `
                -Recommendation "Verify network path to DC '$DC' and that the $k service is reachable."
        }
    }
    return [pscustomobject]$r
}

function Test-RemoteTarget {
    param([string]$Target)
    if ($Target -eq $env:COMPUTERNAME) { return $true }
    $winRM = $false; $cim = $false
    try { Test-WSMan -ComputerName $Target -EA Stop | Out-Null; $winRM = $true } catch {}
    try { Get-CimInstance Win32_ComputerSystem -ComputerName $Target -OperationTimeoutSec 8 -EA Stop | Out-Null; $cim = $true } catch {}
    Write-Log "  Remote '$Target' — WinRM: $winRM  CIM/RPC: $cim"
    if (-not $winRM -and -not $cim) {
        Add-Finding -Severity High -Category Remote `
            -Title  "Remote target '$Target' is unreachable" `
            -Detail 'Neither WinRM nor CIM/RPC could be established.' `
            -Recommendation 'Verify the machine is online, WinRM is enabled, and firewall allows PS Remoting and RPC.' `
            -AffectedObject $Target
        return $false
    }
    return $true
}

#endregion

#region ── OUTPUT DIRECTORY ───────────────────────────────────────────────────

function New-OutputDirectory {
    param([pscustomobject]$EnvInfo)
    if ([string]::IsNullOrEmpty($OutputPath)) {
        $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
        $script:RootOutput = "C:\GPOAudit\$($EnvInfo.AuditTarget)_$ts"
    } else {
        $script:RootOutput = $OutputPath
    }
    $subdirs = @('Summary','Computer','User','DomainGPOs','DomainGPOs\HTML','DomainGPOs\XML',
                 'Links','Permissions','WMI-Filters','RSOP','EventLogs','RawData','Logs')
    try {
        New-Item -ItemType Directory -Path $script:RootOutput -Force | Out-Null
        foreach ($s in $subdirs) {
            New-Item -ItemType Directory -Path (Join-Path $script:RootOutput $s) -Force | Out-Null
        }
        Write-Log "Output directory: $script:RootOutput" -Level SUCCESS
    } catch {
        Write-Error "Could not create output directory '$($script:RootOutput)': $_"
        throw
    }
    $script:ReportPath = Join-Path $script:RootOutput 'Summary\GPOAudit_Report.html'
    try {
        Start-Transcript -Path (Join-Path $script:RootOutput 'Logs\Transcript.log') -Force | Out-Null
    } catch {}
}

#endregion

#region ── COMPUTER AD INFORMATION ────────────────────────────────────────────

function Get-ComputerADInfo {
    param([string]$Target, [string]$DomainName)
    Write-Log "Collecting AD information for '$Target'" -Level SECTION

    $info = [ordered]@{
        ComputerName    = $Target; Domain = $DomainName
        OU              = 'Unknown'; DN = 'Unknown'
        OperatingSystem = 'Unknown'; OSVersion = 'Unknown'
        LastLogon       = $null; PasswordLastSet = $null; Groups = ''; Error = ''
    }

    if ($script:ADModuleLoaded) {
        try {
            $props  = @('DistinguishedName','OperatingSystem','OperatingSystemVersion','LastLogonDate','PasswordLastSet','MemberOf')
            $adComp = Get-ADComputer -Identity $Target -Properties $props -ErrorAction Stop
            $info['DN']               = $adComp.DistinguishedName
            $info['OU']               = $adComp.DistinguishedName -replace '^CN=[^,]+,', ''
            $info['OperatingSystem']  = $adComp.OperatingSystem
            $info['OSVersion']        = $adComp.OperatingSystemVersion
            $info['LastLogon']        = $adComp.LastLogonDate
            $info['PasswordLastSet']  = $adComp.PasswordLastSet
            $info['Groups']           = ($adComp.MemberOf -join '; ')
            Write-Log "  OU: $($info['OU'])" -Level SUCCESS
        } catch {
            Write-Log "  AD lookup failed: $_" -Level WARN; $info['Error'] = $_.ToString()
        }
    } else {
        try {
            $s = [adsisearcher]"(&(objectClass=computer)(cn=$Target))"
            $r = $s.FindOne()
            if ($r) {
                $info['DN'] = $r.Properties['distinguishedname'][0]
                $info['OU'] = $info['DN'] -replace '^CN=[^,]+,', ''
                $info['OperatingSystem'] = if ($r.Properties['operatingsystem'].Count) { $r.Properties['operatingsystem'][0] } else { 'Unknown' }
            }
        } catch { Write-Log "  ADSI fallback failed: $_" -Level WARN }
    }

    if ($Target -eq $env:COMPUTERNAME) {
        try {
            $os = Get-CimInstance Win32_OperatingSystem -EA SilentlyContinue
            $cs = Get-CimInstance Win32_ComputerSystem  -EA SilentlyContinue
            if ($os) { $info['LastBootTime'] = $os.LastBootUpTime }
            if ($cs) { $info['LoggedOnUser'] = $cs.UserName }
            $adapters = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' -EA SilentlyContinue
            $info['NetworkAdapters'] = $adapters | ForEach-Object {
                "$($_.Description) IP=$($_.IPAddress -join ',') DNS=$($_.DNSServerSearchOrder -join ',')"
            }
        } catch {}
    }
    return [pscustomobject]$info
}

#endregion

#region ── RSOP / GPRESULT COLLECTION ─────────────────────────────────────────

function Invoke-GPResultCollection {
    param([string]$Target, [string]$UserParam, [string]$OutDir)
    Write-Log "Running gpresult for '$Target'" -Level SECTION

    $isLocal = ($Target -eq $env:COMPUTERNAME)
    $base    = if ($isLocal) { @() } else { @('/S', $Target) }
    if ($UserParam) { $base += @('/USER', $UserParam) }

    # /R
    try { & gpresult.exe @($base + '/R') 2>&1 | Out-File (Join-Path $OutDir 'gpresult_R.txt') -Encoding UTF8 -Force
          Write-Log '  gpresult /R saved.' -Level SUCCESS }
    catch { Write-Log "  gpresult /R failed: $_" -Level WARN }

    # /Z
    try { & gpresult.exe @($base + '/Z') 2>&1 | Out-File (Join-Path $OutDir 'gpresult_Z.txt') -Encoding UTF8 -Force
          Write-Log '  gpresult /Z saved.' -Level SUCCESS }
    catch { Write-Log "  gpresult /Z failed: $_" -Level WARN }

    # /H
    $hPath = Join-Path $OutDir 'gpresult_H.html'
    if (Test-Path $hPath -EA SilentlyContinue) { Remove-Item $hPath -Force -EA SilentlyContinue }
    try { & gpresult.exe @($base + @('/H', $hPath, '/F')) 2>&1 | Out-Null
          Write-Log '  gpresult /H saved.' -Level SUCCESS }
    catch { Write-Log "  gpresult /H failed: $_" -Level WARN }

    # /X
    $xPath = Join-Path $OutDir 'gpresult_X.xml'
    if (Test-Path $xPath -EA SilentlyContinue) { Remove-Item $xPath -Force -EA SilentlyContinue }
    try { & gpresult.exe @($base + @('/X', $xPath, '/F')) 2>&1 | Out-Null
          Write-Log '  gpresult /X saved.' -Level SUCCESS }
    catch { Write-Log "  gpresult /X failed: $_" -Level WARN }

    $rsop = [pscustomobject]@{
        ComputerApplied = [System.Collections.Generic.List[pscustomobject]]::new()
        ComputerDenied  = [System.Collections.Generic.List[pscustomobject]]::new()
        UserApplied     = [System.Collections.Generic.List[pscustomobject]]::new()
        UserDenied      = [System.Collections.Generic.List[pscustomobject]]::new()
    }

    if (Test-Path $xPath -EA SilentlyContinue) {
        try {
            [xml]$xDoc = Get-Content $xPath -Raw -Encoding Unicode -EA Stop
            $ns = New-Object System.Xml.XmlNamespaceManager($xDoc.NameTable)
            $ns.AddNamespace('r', 'http://www.microsoft.com/GroupPolicy/Rsop')

            $compNodes = $xDoc.SelectNodes('//r:Logging/r:Computer/r:GPO', $ns)
            $userNodes = $xDoc.SelectNodes('//r:Logging/r:User/r:GPO',     $ns)
            if (-not $compNodes -or $compNodes.Count -eq 0) {
                $compNodes = $xDoc.SelectNodes('//Computer/GPO')
                $userNodes = $xDoc.SelectNodes('//User/GPO')
            }

            function ParseGPONodes($nodes, $scope) {
                if (-not $nodes) { return }
                foreach ($n in $nodes) {
                    $applied = ($n.IsValid -eq 'true') -or ($n.Applied -eq 'true') -or
                               ($n.AppliedOrder -and [int]$n.AppliedOrder -gt 0)
                    $e = [pscustomobject]@{
                        Name   = $n.Name
                        Id     = $n.Id
                        Order  = if ($n.AppliedOrder) { $n.AppliedOrder } else { '' }
                        Reason = if ($n.DeniedReason) { $n.DeniedReason } else { '' }
                    }
                    if ($applied) {
                        if ($scope -eq 'Computer') { $rsop.ComputerApplied.Add($e) } else { $rsop.UserApplied.Add($e) }
                    } else {
                        if ($scope -eq 'Computer') { $rsop.ComputerDenied.Add($e) } else { $rsop.UserDenied.Add($e) }
                    }
                }
            }
            ParseGPONodes $compNodes 'Computer'
            ParseGPONodes $userNodes 'User'
            Write-Log "  RSOP: CompApplied=$($rsop.ComputerApplied.Count) CompDenied=$($rsop.ComputerDenied.Count) UserApplied=$($rsop.UserApplied.Count) UserDenied=$($rsop.UserDenied.Count)" -Level SUCCESS
        } catch { Write-Log "  RSOP XML parse failed: $_" -Level WARN }
    }

    # Get-GPResultantSetOfPolicy
    if ($script:GPModuleLoaded) {
        $gprsopPath = Join-Path $OutDir 'RSOP_GPModule.xml'
        try {
            $gprArgs = @{ ReportType='Xml'; Path=$gprsopPath; ErrorAction='Stop' }
            $gprArgs['Computer'] = if ($isLocal) { $env:COMPUTERNAME } else { $Target }
            Get-GPResultantSetOfPolicy @gprArgs | Out-Null
            Write-Log '  Get-GPResultantSetOfPolicy XML saved.' -Level SUCCESS
        } catch { Write-Log "  Get-GPResultantSetOfPolicy failed: $_" -Level WARN }
    }

    foreach ($d in $rsop.ComputerDenied) {
        Add-Finding -Severity Low -Category RSOP `
            -Title  "Computer GPO denied: '$($d.Name)'" `
            -Detail "Denial reason: $($d.Reason)" `
            -Recommendation 'Verify security group membership, WMI filter result, and link status.' `
            -AffectedObject $d.Name
    }
    return $rsop
}

#endregion

#region ── EVENT LOG COLLECTION ───────────────────────────────────────────────

function Get-GPEventLog {
    param([string]$Target, [string]$OutDir)
    Write-Log "Collecting GP Operational events from '$Target'" -Level SECTION

    $logName = 'Microsoft-Windows-GroupPolicy/Operational'
    $isLocal = ($Target -eq $env:COMPUTERNAME)

    try {
        $params = @{ LogName=$logName; MaxEvents=2000; ErrorAction='Stop' }
        if (-not $isLocal) { $params['ComputerName'] = $Target }
        $events = Get-WinEvent @params
        Write-Log "  Collected $($events.Count) event(s)." -Level SUCCESS

        $events | Select-Object TimeCreated, Id, LevelDisplayName,
                    @{N='Source';E={$_.ProviderName}}, Message |
            Export-Csv (Join-Path $OutDir 'GP_Operational_Events.csv') -NoTypeInformation -Force
        Write-Log '  Events exported to CSV.' -Level SUCCESS

        if ($isLocal) {
            try {
                & wevtutil.exe epl $logName (Join-Path $OutDir 'GP_Operational.evtx') 2>&1 | Out-Null
                Write-Log '  EVTX export saved.' -Level SUCCESS
            } catch {}
        }

        $errWarn  = @($events | Where-Object { $_.Level -in 2,3 })
        $slowLink = @($events | Where-Object { $_.Message -match 'slow.?link' })
        $sysvolF  = @($events | Where-Object { $_.Message -match 'SYSVOL|NETLOGON' -and $_.Level -in 2,3 })
        $dcDisc   = @($events | Where-Object { $_.Message -match 'domain controller' -and $_.Level -in 2,3 })

        if ($errWarn.Count -gt 0)  { Add-Finding -Severity High   -Category EventLogs -Title "GP processing errors on '$Target' ($($errWarn.Count))"  -Detail 'Errors in GP/Operational log.' -Recommendation 'Review the GP Operational log.' -AffectedObject $Target }
        if ($slowLink.Count -gt 0) { Add-Finding -Severity Medium -Category EventLogs -Title "Slow link detected on '$Target'"                         -Detail "$($slowLink.Count) slow-link event(s)." -Recommendation 'Review slow-link bandwidth thresholds.' -AffectedObject $Target }
        if ($sysvolF.Count -gt 0)  { Add-Finding -Severity High   -Category EventLogs -Title "SYSVOL/NETLOGON errors on '$Target'"                    -Detail "$($sysvolF.Count) event(s)." -Recommendation 'Check SYSVOL replication: repadmin /replsummary.' -AffectedObject $Target }
        if ($dcDisc.Count -gt 0)   { Add-Finding -Severity High   -Category EventLogs -Title "DC discovery errors on '$Target'"                       -Detail "$($dcDisc.Count) event(s)." -Recommendation 'Check DNS and site coverage.' -AffectedObject $Target }

        return $events
    } catch {
        Write-Log "  Event log collection failed: $_" -Level WARN
        Add-Finding -Severity Medium -Category EventLogs -Title "Could not collect event log from '$Target'" `
            -Detail $_.ToString() -Recommendation 'Verify WinRM and firewall allow remote event log access.' -AffectedObject $Target
        return @()
    }
}

#endregion

#region ── DOMAIN GPO INVENTORY ───────────────────────────────────────────────

function Get-DomainGPOInventory {
    param([string]$DomainName, [string]$DomainGPODir, [string]$RawDataDir)
    Write-Log 'Enumerating domain GPO inventory' -Level SECTION

    if (-not $script:GPModuleLoaded) { Write-Log '  GP module unavailable. Skipped.' -Level WARN; return @() }

    $allGPOs = try { @(Get-GPO -All -Domain $DomainName -EA Stop) } catch { Write-Log "  Get-GPO -All failed: $_" -Level ERROR; return @() }
    Write-Log "  Found $(Get-SafeCount $allGPOs) GPO(s)." -Level INFO

    $inventory = [System.Collections.Generic.List[pscustomobject]]::new()
    $total = Get-SafeCount $allGPOs; $idx = 0

    foreach ($gpo in $allGPOs) {
        $idx++
        $displayName = [string](Get-ObjectProperty -InputObject $gpo -Name 'DisplayName' -Default 'Unknown')
        $gpoId       = [string](Get-ObjectProperty -InputObject $gpo -Name 'Id' -Default '')
        Write-Progress -Activity 'GPO Inventory' -Status "$displayName ($idx/$total)" `
            -PercentComplete $(if ($total -gt 0) { [int](($idx / $total) * 100) } else { 0 })

        try {
            $gpoStatusRaw    = Get-ObjectProperty -InputObject $gpo -Name 'GpoStatus' -Default 'AllSettingsEnabled'
            $gpoStatus       = $gpoStatusRaw.ToString()
            $userEnabled     = $gpoStatus -notin @('UserSettingsDisabled','AllSettingsDisabled')
            $computerEnabled = $gpoStatus -notin @('ComputerSettingsDisabled','AllSettingsDisabled')

            $wmiObj    = Get-ObjectProperty -InputObject $gpo -Name 'WmiFilter'
            $wmiFilter = ''
            if ($null -ne $wmiObj -and -not [string]::IsNullOrWhiteSpace([string]$wmiObj) -and
                -not (Test-IsDeserializedTypeName -Value $wmiObj -TypeName 'Microsoft.GroupPolicy.WmiFilter')) {
                $wmiName = Get-ObjectProperty -InputObject $wmiObj -Name 'Name'
                $wmiFilter = if ($null -ne $wmiName) { [string]$wmiName } else { [string]$wmiObj }
            }

            $versions = Get-GpoAdVersions -Gpo $gpo -DomainName $DomainName
            $safeName = Get-SafeFileName $displayName
            $xmlFile  = Join-Path $DomainGPODir "XML\$safeName.xml"
            $htmlFile = Join-Path $DomainGPODir "HTML\$safeName.html"

            $flags = @{ Scripts=$false; Prefs=$false; SchTasks=$false; DriveMaps=$false
                        RegPrefs=$false; Printers=$false; SoftInst=$false; CPassword=$false; Empty=$false }
            $linkCount = 0; $links = @()

            try {
                if ($gpoId) {
                    Get-GPOReport -Guid $gpoId -ReportType Xml  -Domain $DomainName -Path $xmlFile  -EA Stop
                    Get-GPOReport -Guid $gpoId -ReportType Html -Domain $DomainName -Path $htmlFile -EA Stop
                }
                [xml]$rXml = Get-Content $xmlFile -Raw -EA SilentlyContinue
                if ($rXml) {
                    $x = $rXml.OuterXml
                    $flags.Scripts    = $x -match '<Script\b|<Scripts\b'
                    $flags.Prefs      = $x -match '<Preferences\b|Preferences xmlns'
                    $flags.SchTasks   = $x -match 'ScheduledTasks'
                    $flags.DriveMaps  = $x -match 'DriveMapSettings|DriveMap'
                    $flags.RegPrefs   = $x -match 'RegistrySettings|:Registry'
                    $flags.Printers   = $x -match 'PrinterSettings|Printers'
                    $flags.SoftInst   = $x -match 'SoftwareInstallation|ClassStore'
                    $flags.CPassword  = $x -match 'cpassword'
                    $compExt = Get-ObjectProperty -InputObject $rXml.GPO.Computer -Name 'ExtensionData'
                    $userExt = Get-ObjectProperty -InputObject $rXml.GPO.User -Name 'ExtensionData'
                    $flags.Empty = ($null -eq $compExt -and $null -eq $userExt)
                    $lNodes = Get-ObjectProperty -InputObject $rXml.GPO -Name 'LinksTo'
                    if ($lNodes) {
                        $links = @($lNodes) | ForEach-Object {
                            $somPath = [string](Get-ObjectProperty -InputObject $_ -Name 'SOMPath' -Default '')
                            $somType = if ($somPath -eq $DomainName) { 'Domain' }
                                       elseif ($somPath -match '[\\/]') { 'OU' }
                                       else { 'Site' }
                            [pscustomobject]@{
                                SOMPath     = $somPath
                                SOMName     = [string](Get-ObjectProperty -InputObject $_ -Name 'SOMName' -Default '')
                                SOMType     = $somType
                                LinkEnabled = ([string](Get-ObjectProperty -InputObject $_ -Name 'Enabled' -Default 'true') -ne 'false')
                                Enforced    = ([string](Get-ObjectProperty -InputObject $_ -Name 'NoOverride' -Default 'false') -eq 'true')
                            }
                        }
                        $linkCount = Get-SafeCount $links
                    }
                }
            } catch { Write-Log "  Report failed for '$displayName': $_" -Level WARN }

            $owner = Get-ObjectProperty -InputObject $gpo -Name 'Owner' -Default ''
            $desc  = Get-ObjectProperty -InputObject $gpo -Name 'Description' -Default ''
            $created  = Get-ObjectProperty -InputObject $gpo -Name 'CreationTime'
            $modified = Get-ObjectProperty -InputObject $gpo -Name 'ModificationTime'
            $domainNm = Get-ObjectProperty -InputObject $gpo -Name 'DomainName' -Default $DomainName

            $entry = [pscustomobject]@{
                Name = $displayName; Id = $gpoId.Trim('{}'); Domain = [string]$domainNm
                Owner = [string]$owner; Description = [string]$desc
                Created = $created; Modified = $modified
                GpoStatus = $gpoStatus
                UserSettingsEnabled = $userEnabled; ComputerSettingsEnabled = $computerEnabled
                UserVersion = $versions.User; ComputerVersion = $versions.Computer
                WmiFilter = $wmiFilter; LinkCount = $linkCount; Links = $links
                HasScripts = $flags.Scripts; HasPreferences = $flags.Prefs; HasScheduledTasks = $flags.SchTasks
                HasDriveMaps = $flags.DriveMaps; HasRegistryPrefs = $flags.RegPrefs
                HasPrinters = $flags.Printers; HasSoftwareInstall = $flags.SoftInst
                HasCPassword = $flags.CPassword; IsEmpty = $flags.Empty
                XmlReportPath = $xmlFile; HtmlReportPath = $htmlFile
            }
            $inventory.Add($entry)

            if ($flags.CPassword) {
                Add-Finding -Severity Critical -Category Security `
                    -Title  "cpassword in GPO: '$displayName'" `
                    -Detail "GPO contains a Group Policy Preferences cpassword entry (MS14-025)." `
                    -Recommendation 'Remove cpassword immediately. Deploy LAPS. Apply MS14-025 patch.' `
                    -AffectedObject $displayName
            }
        }
        catch {
            Write-Log "  Failed to inventory GPO '$displayName': $_" -Level WARN
        }
    }
    Write-Progress -Activity 'GPO Inventory' -Completed

    $inventory | Select-Object Name,Id,Domain,Owner,Description,Created,Modified,GpoStatus,
        UserSettingsEnabled,ComputerSettingsEnabled,UserVersion,ComputerVersion,WmiFilter,
        LinkCount,HasScripts,HasPreferences,HasScheduledTasks,HasDriveMaps,HasRegistryPrefs,
        HasPrinters,HasSoftwareInstall,HasCPassword,IsEmpty |
        Export-Csv (Join-Path $RawDataDir 'GPO_Inventory.csv') -NoTypeInformation -Force
    $inventory | Select-Object Name,Id,Domain,Owner,GpoStatus,LinkCount,WmiFilter,HasCPassword,IsEmpty,Created,Modified |
        ConvertTo-Json -Depth 3 | Out-File (Join-Path $RawDataDir 'GPO_Inventory.json') -Encoding UTF8 -Force

    Write-Log "  Inventory complete: $($inventory.Count) GPOs." -Level SUCCESS
    return , @($inventory.ToArray())
}

#endregion

#region ── GPO LINK INVENTORY ─────────────────────────────────────────────────

function ConvertFrom-GPLinkAttribute {
    param(
        [string]$GPLink,
        [string]$TargetDN,
        [string]$TargetType,
        [bool]$BlockInheritance = $false
    )
    if ([string]::IsNullOrWhiteSpace($GPLink)) { return @() }

    $results = [System.Collections.Generic.List[pscustomobject]]::new()
    $rx = [regex]'\[LDAP://(?<path>[^\]]+);(?<opt>\d+)\]'
    $order = 0
    foreach ($m in $rx.Matches($GPLink)) {
        $order++
        $path = $m.Groups['path'].Value
        $opt  = [int]$m.Groups['opt'].Value
        $guid = if ($path -match '\{([0-9A-Fa-f-]{36})\}') { $Matches[1] } else { '' }
        # Bit0 = link disabled, Bit1 = enforced (No Override)
        $results.Add([pscustomobject]@{
            GPOName           = ''
            GPOId             = $guid
            Target            = $TargetDN
            TargetType        = $TargetType
            LinkOrder         = $order
            LinkEnabled       = (($opt -band 1) -eq 0)
            Enforced          = (($opt -band 2) -ne 0)
            BlockInheritance  = $BlockInheritance
        })
    }
    return , @($results.ToArray())
}

function Get-GPOLinkInventory {
    param([string]$DomainName, [string]$RawDataDir)
    Write-Log 'Enumerating GPO links' -Level SECTION

    $allLinks = [System.Collections.Generic.List[pscustomobject]]::new()
    $gpoNameById = @{}

    # Prefer LDAP gpLink — Get-GPInheritance GpoLink objects break under the PS7 WinPS shim.
    try {
        $domDN = if ($script:ADModuleLoaded) {
            (Get-ADDomain -Identity $DomainName -EA Stop).DistinguishedName
        } else {
            "DC=$($DomainName.Replace('.', ',DC='))"
        }

        # Cache GPO display names
        if ($script:GPModuleLoaded) {
            try {
                foreach ($g in @(Get-GPO -All -Domain $DomainName -EA Stop)) {
                    $id = [string](Get-ObjectProperty -InputObject $g -Name 'Id' -Default '')
                    $nm = [string](Get-ObjectProperty -InputObject $g -Name 'DisplayName' -Default '')
                    if ($id) { $gpoNameById[$id.Trim('{}').ToLower()] = $nm }
                }
            } catch {}
        }

        function Add-LinksFromDirectoryEntry {
            param([string]$Dn, [string]$CType)
            try {
                $entry = [adsi]"LDAP://$Dn"
                $gpLink = ''
                if ($entry.Properties.Contains('gplink')) {
                    $gpLink = [string]$entry.Properties['gplink'][0]
                }
                $blocked = $false
                if ($entry.Properties.Contains('gpoptions')) {
                    $blocked = (([int]$entry.Properties['gpoptions'][0]) -band 1) -ne 0
                }
                foreach ($lk in @(ConvertFrom-GPLinkAttribute -GPLink $gpLink -TargetDN $Dn -TargetType $CType -BlockInheritance $blocked)) {
                    $key = $lk.GPOId.ToLower()
                    if ($gpoNameById.ContainsKey($key)) { $lk.GPOName = $gpoNameById[$key] }
                    $allLinks.Add($lk)
                }
            } catch {
                Write-Log "  Link read failed for '$Dn': $_" -Level WARN
            }
        }

        Add-LinksFromDirectoryEntry -Dn $domDN -CType 'Domain'
        Write-Log '  Domain-level links collected.' -Level SUCCESS

        try {
            $cfgNC  = ([adsi]'LDAP://RootDSE').configurationNamingContext
            $forest = [System.DirectoryServices.ActiveDirectory.Forest]::GetCurrentForest()
            foreach ($site in $forest.Sites) {
                Add-LinksFromDirectoryEntry -Dn "CN=$($site.Name),CN=Sites,$cfgNC" -CType 'Site'
            }
            Write-Log '  Site-level links collected.' -Level SUCCESS
        } catch { Write-Log "  Site links failed: $_" -Level WARN }

        if ($script:ADModuleLoaded) {
            try {
                $ous = @(Get-ADOrganizationalUnit -Filter * -Properties DistinguishedName -EA Stop)
                $ouT = $ous.Count; $ouI = 0
                foreach ($ou in $ous) {
                    $ouI++
                    Write-Progress -Activity 'OU Link Inventory' -Status "$($ou.Name) ($ouI/$ouT)" `
                        -PercentComplete $(if ($ouT -gt 0) { [int](($ouI / $ouT) * 100) } else { 0 })
                    Add-LinksFromDirectoryEntry -Dn $ou.DistinguishedName -CType 'OU'
                }
                Write-Progress -Activity 'OU Link Inventory' -Completed
                Write-Log "  OU-level links collected ($ouT OUs)." -Level SUCCESS
            } catch { Write-Log "  OU links failed: $_" -Level WARN }
        }
    }
    catch {
        Write-Log "  LDAP link enumeration failed: $_. Falling back to Get-GPInheritance via Windows PowerShell." -Level WARN
        try {
            $native = Invoke-WindowsPowerShellJson -Script @"
`$links = [System.Collections.Generic.List[object]]::new()
function Add-NativeLinks(`$inherit, `$ctype) {
    if (-not `$inherit) { return }
    `$blocked = [bool]`$inherit.GpoInheritanceBlocked
    foreach (`$lk in @(`$inherit.GpoLinks)) {
        `$links.Add([pscustomobject]@{
            GPOName = `$lk.DisplayName
            GPOId = `$lk.GpoId.ToString().Trim('{}')
            Target = `$inherit.Path
            TargetType = `$ctype
            LinkOrder = `$lk.Order
            LinkEnabled = [bool]`$lk.Enabled
            Enforced = [bool]`$lk.Enforced
            BlockInheritance = `$blocked
        })
    }
}
`$dom = Get-ADDomain -Identity '$DomainName'
Add-NativeLinks (Get-GPInheritance -Target `$dom.DistinguishedName -Domain '$DomainName') 'Domain'
Get-ADOrganizationalUnit -Filter * | ForEach-Object {
    try { Add-NativeLinks (Get-GPInheritance -Target `$_.DistinguishedName -Domain '$DomainName') 'OU' } catch {}
}
`$links
"@
            foreach ($lk in @($native)) { $allLinks.Add([pscustomobject]$lk) }
        } catch {
            Write-Log "  Native link fallback also failed: $_" -Level WARN
        }
    }

    $disabled = @($allLinks | Where-Object { -not $_.LinkEnabled })
    $enforced = @($allLinks | Where-Object { $_.Enforced })
    $blocked  = @($allLinks | Where-Object { $_.BlockInheritance } | Select-Object -ExpandProperty Target -Unique)

    if ((Get-SafeCount $disabled) -gt 0) {
        Add-Finding -Severity Low -Category Links -Title "$(Get-SafeCount $disabled) disabled GPO link(s)" `
            -Detail "Disabled: $(($disabled.GPOName | Where-Object { $_ } | Select-Object -Unique) -join '; ')" `
            -Recommendation 'Remove disabled links no longer needed.'
    }
    if ((Get-SafeCount $enforced) -gt 0) {
        Add-Finding -Severity Medium -Category Links -Title "$(Get-SafeCount $enforced) enforced (No Override) link(s)" `
            -Detail 'Enforced links override Block Inheritance.' `
            -Recommendation 'Confirm each enforced link is intentional.'
    }
    if ((Get-SafeCount $blocked) -gt 0) {
        Add-Finding -Severity Medium -Category Links -Title "$(Get-SafeCount $blocked) OU(s) with Block Inheritance" `
            -Detail ($blocked -join '; ') `
            -Recommendation 'Use Block Inheritance sparingly; document business justification.'
    }

    $allLinks | Select-Object GPOName,GPOId,Target,TargetType,LinkOrder,LinkEnabled,Enforced,BlockInheritance |
        Export-Csv (Join-Path $RawDataDir 'GPO_Links.csv') -NoTypeInformation -Force
    $allLinks | Select-Object GPOName,GPOId,Target,TargetType,LinkOrder,LinkEnabled,Enforced,BlockInheritance |
        ConvertTo-Json -Depth 3 | Out-File (Join-Path $RawDataDir 'GPO_Links.json') -Encoding UTF8 -Force

    Write-Log "  Total link records: $($allLinks.Count)." -Level INFO
    return , @($allLinks.ToArray())
}

#endregion

#region ── SECURITY FILTERING / DELEGATION AUDIT ──────────────────────────────

function Get-GPOPermissionsAudit {
    param([pscustomobject[]]$GPOInventory, [string]$RawDataDir)
    Write-Log 'Auditing GPO security filtering and delegation' -Level SECTION
    if (-not $script:GPModuleLoaded) { Write-Log '  GP module unavailable. Skipped.' -Level WARN; return @() }

    $allPerms = [System.Collections.Generic.List[pscustomobject]]::new()
    $useNative = $PSVersionTable.PSEdition -eq 'Core'

    if ($useNative) {
        Write-Log '  PS 7 detected — collecting permissions via Windows PowerShell (Trustee objects break under the compatibility shim).'
        try {
            $native = Invoke-WindowsPowerShellJson -Depth 4 -Script @'
$out = foreach ($g in Get-GPO -All) {
    foreach ($p in Get-GPPermission -Guid $g.Id -All) {
        [pscustomobject]@{
            GPOName     = $g.DisplayName
            GPOId       = $g.Id.ToString().Trim('{}')
            Trustee     = $p.Trustee.Name
            TrusteeSid  = $p.Trustee.Sid.ToString()
            TrusteeType = $p.Trustee.SidType.ToString()
            Permission  = $p.Permission.ToString()
            Denied      = [bool]$p.Denied
        }
    }
}
$out
'@
            foreach ($row in @($native)) {
                $allPerms.Add([pscustomobject]@{
                    GPOName     = [string]$row.GPOName
                    GPOId       = [string]$row.GPOId
                    Trustee     = [string]$row.Trustee
                    TrusteeSid  = [string]$row.TrusteeSid
                    TrusteeType = [string]$row.TrusteeType
                    Permission  = [string]$row.Permission
                    Denied      = [bool]$row.Denied
                })
            }
        }
        catch {
            Write-Log "  Native permissions collection failed: $_" -Level WARN
            $useNative = $false
        }
    }

    if (-not $useNative) {
        $total = Get-SafeCount $GPOInventory; $idx = 0
        foreach ($gpo in $GPOInventory) {
            $idx++
            Write-Progress -Activity 'GPO Permissions' -Status "$($gpo.Name) ($idx/$total)" `
                -PercentComplete $(if ($total -gt 0) { [int](($idx / $total) * 100) } else { 0 })
            try {
                $perms = @(Get-GPPermission -Guid $gpo.Id -All -EA Stop)
                foreach ($p in $perms) {
                    $trusteeObj = Get-ObjectProperty -InputObject $p -Name 'Trustee'
                    if (Test-IsDeserializedTypeName -Value $trusteeObj -TypeName 'Microsoft.GroupPolicy.GPTrustee') {
                        Write-Log "  Trustee deserialization failed for '$($gpo.Name)' — re-run under Windows PowerShell 5.1 for full ACL detail." -Level WARN
                        break
                    }
                    $trustee  = [string](Get-ObjectProperty -InputObject $trusteeObj -Name 'Name' -Default '')
                    $sidObj   = Get-ObjectProperty -InputObject $trusteeObj -Name 'Sid'
                    $sidStr   = if ($null -ne $sidObj) { $sidObj.ToString() } else { '' }
                    $sidType  = [string](Get-ObjectProperty -InputObject $trusteeObj -Name 'SidType' -Default '')
                    $permStr  = [string](Get-ObjectProperty -InputObject $p -Name 'Permission' -Default '')
                    $denied   = [bool](Get-ObjectProperty -InputObject $p -Name 'Denied' -Default $false)
                    $allPerms.Add([pscustomobject]@{
                        GPOName = $gpo.Name; GPOId = $gpo.Id
                        Trustee = $trustee; TrusteeSid = $sidStr
                        TrusteeType = $sidType.ToString(); Permission = $permStr.ToString(); Denied = $denied
                    })
                }
            } catch { Write-Log "  Permissions failed for '$($gpo.Name)': $_" -Level WARN }
        }
        Write-Progress -Activity 'GPO Permissions' -Completed
    }

    # Findings from collected ACE rows
    $byGpo = $allPerms | Group-Object GPOId
    foreach ($grp in @($byGpo)) {
        $rows = @($grp.Group)
        $gpoName = $rows[0].GPOName
        $gpoMeta = @($GPOInventory | Where-Object { $_.Id -eq $grp.Name } | Select-Object -First 1)
        $status  = if ($gpoMeta) { $gpoMeta.GpoStatus } else { '' }

        $applyPerms = @($rows | Where-Object { $_.Permission -eq 'GpoApply' -and -not $_.Denied })
        if ((Get-SafeCount $applyPerms) -eq 0 -and $status -ne 'AllSettingsDisabled') {
            Add-Finding -Severity High -Category Security `
                -Title  "No 'Apply Group Policy' permission on '$gpoName'" `
                -Detail 'No principal has Apply Group Policy. This GPO will never apply to any object.' `
                -Recommendation 'Add Apply Group Policy to Authenticated Users or a targeted security group.' `
                -AffectedObject $gpoName
        }

        foreach ($p in $rows) {
            $trustee = $p.Trustee; $permStr = $p.Permission; $sidType = $p.TrusteeType
            if ($sidType -eq 'Unknown' -or $trustee -match '^S-1-') {
                Add-Finding -Severity Medium -Category Security -Title "Unresolved SID on '$gpoName'" `
                    -Detail "SID: $($p.TrusteeSid) | Permission: $permStr" `
                    -Recommendation 'Remove the orphaned SID from the GPO ACL.' -AffectedObject $gpoName
            }
            if ($trustee -match '^Everyone$|^Anonymous') {
                Add-Finding -Severity High -Category Security -Title "Overly broad permission on '$gpoName'" `
                    -Detail "'$trustee' has '$permStr'." `
                    -Recommendation "Remove 'Everyone' or 'Anonymous' from this GPO's ACL." -AffectedObject $gpoName
            }
            if ($permStr -in 'GpoEdit','GpoEditDeleteModifySecurity') {
                if ($trustee -notmatch 'Domain Admins|Enterprise Admins|Group Policy Creator Owners|SYSTEM|Administrators') {
                    Add-Finding -Severity High -Category Security -Title "Non-standard editor on '$gpoName'" `
                        -Detail "'$trustee' has '$permStr'." `
                        -Recommendation "Confirm '$trustee' requires edit rights." -AffectedObject $gpoName
                }
            }
            if ($permStr -eq 'GpoApply') {
                $hasRead = @($rows | Where-Object { $_.Trustee -eq $trustee -and $_.Permission -eq 'GpoRead' })
                if ((Get-SafeCount $hasRead) -eq 0) {
                    Add-Finding -Severity Medium -Category Security -Title "Apply without Read on '$gpoName'" `
                        -Detail "'$trustee' has Apply but not Read." `
                        -Recommendation "Add Read permission for '$trustee' on this GPO." -AffectedObject $gpoName
                }
            }
        }
    }

    $allPerms | Export-Csv (Join-Path $RawDataDir 'GPO_Permissions.csv') -NoTypeInformation -Force
    $allPerms | ConvertTo-Json -Depth 3 | Out-File (Join-Path $RawDataDir 'GPO_Permissions.json') -Encoding UTF8 -Force
    Write-Log "  Permissions audit complete: $($allPerms.Count) ACE record(s)." -Level SUCCESS
    return , @($allPerms.ToArray())
}

#endregion

#region ── WMI FILTER AUDIT ───────────────────────────────────────────────────

function Get-WMIFilterAudit {
    param([pscustomobject[]]$GPOInventory, [string]$DomainName, [string]$RawDataDir)
    Write-Log 'Auditing WMI filters' -Level SECTION
    $wmiFilters = [System.Collections.Generic.List[pscustomobject]]::new()

    try {
        $domDN = if ($script:ADModuleLoaded) { (Get-ADDomain -Identity $DomainName -EA Stop).DistinguishedName }
                 else { "DC=$($DomainName.Replace('.', ',DC='))" }
        $s = [adsisearcher]'(objectClass=msWMI-SomFilter)'
        $s.SearchRoot = [adsi]"LDAP://CN=SOM,CN=WMIPolicy,CN=System,$domDN"
        $s.PageSize   = 1000
        $results      = $s.FindAll()
        foreach ($r in $results) {
            $p     = $r.Properties
            $parm2 = if ($p['mswmi-parm2'].Count) { $p['mswmi-parm2'][0].ToString() } else { '' }
            $parts = $parm2 -split ';'
            $ns    = if ($parts.Count -ge 2) { $parts[1] } else { 'root\CIMv2' }
            $query = if ($parts.Count -ge 4) { $parts[3..($parts.Count-1)] -join ';' } else { $parm2 }

            $nameStr = if ($p['mswmi-name'].Count)         { $p['mswmi-name'][0].ToString() }         else { 'Unknown' }
            $isW32P  = $query -match 'Win32_Product'
            $isBroad = $query -match 'Win32_Product|SELECT \* FROM Win32_'

            $f = [pscustomobject]@{
                Name    = $nameStr
                Description  = if ($p['mswmi-parm1'].Count)        { $p['mswmi-parm1'][0].ToString() }        else { '' }
                Author       = if ($p['mswmi-author'].Count)        { $p['mswmi-author'][0].ToString() }       else { '' }
                Created      = if ($p['mswmi-creationdate'].Count)  { $p['mswmi-creationdate'][0].ToString() } else { '' }
                Modified     = if ($p['mswmi-changedate'].Count)    { $p['mswmi-changedate'][0].ToString() }   else { '' }
                Namespace    = $ns; Query = $query
                IsWin32Product = $isW32P; BroadOrExpensive = $isBroad
                UsedByGPOs   = [System.Collections.Generic.List[string]]::new()
            }
            $wmiFilters.Add($f)
            if ($isW32P)  { Add-Finding -Severity High   -Category WMIFilters -Title "WMI filter uses Win32_Product: '$nameStr'" -Detail "Query: $query" -Recommendation 'Replace Win32_Product with Win32_InstalledWin32Program or registry-based detection.' -AffectedObject $nameStr }
            elseif ($isBroad) { Add-Finding -Severity Medium -Category WMIFilters -Title "Expensive WMI filter: '$nameStr'" -Detail "Query: $query" -Recommendation 'Narrow query scope to avoid slowing Group Policy processing.' -AffectedObject $nameStr }
        }
        $results.Dispose()
        Write-Log "  Found $($wmiFilters.Count) WMI filter(s)." -Level INFO
    } catch { Write-Log "  WMI filter enumeration failed: $_" -Level WARN }

    foreach ($gpo in $GPOInventory) {
        $wmiRef = Get-ObjectProperty -InputObject $gpo -Name 'WmiFilter' -Default ''
        if (-not [string]::IsNullOrEmpty([string]$wmiRef)) {
            $m = @($wmiFilters | Where-Object { $_.Name -eq $wmiRef } | Select-Object -First 1)
            $gpoName = Get-ObjectProperty -InputObject $gpo -Name 'Name' -Default 'Unknown'
            if (-not $m) {
                Add-Finding -Severity High -Category WMIFilters -Title "Broken WMI filter ref on '$gpoName'" `
                    -Detail "GPO references WMI filter '$wmiRef' which does not exist." `
                    -Recommendation 'Fix or remove the broken WMI filter reference. GPO will not apply until corrected.' -AffectedObject $gpoName
            } else { $m.UsedByGPOs.Add([string]$gpoName) }
        }
    }
    $wmiFilters | Where-Object { $_.UsedByGPOs.Count -eq 0 } | ForEach-Object {
        Add-Finding -Severity Low -Category WMIFilters -Title "Unused WMI filter: '$($_.Name)'" `
            -Detail 'Not assigned to any GPO.' -Recommendation 'Remove unused WMI filters.' -AffectedObject $_.Name
    }
    $wmiFilters | Select-Object Name,Description,Author,Created,Modified,Namespace,Query,IsWin32Product,BroadOrExpensive |
        Export-Csv (Join-Path $RawDataDir 'WMI_Filters.csv') -NoTypeInformation -Force
    return $wmiFilters
}

#endregion

#region ── SYSVOL CONSISTENCY CHECK ───────────────────────────────────────────

function Test-SYSVOLConsistency {
    param([string]$DomainName, [pscustomobject[]]$GPOInventory, [string]$RawDataDir)
    Write-Log 'Checking SYSVOL / AD consistency' -Level SECTION

    $base = "\\$DomainName\SYSVOL\$DomainName\Policies"
    $ok   = try { Test-Path $base -EA Stop } catch { $false }

    if (-not $ok) {
        Write-Log "  SYSVOL not accessible: $base" -Level WARN
        Add-Finding -Severity High -Category SYSVOL -Title 'SYSVOL not accessible' `
            -Detail "Path: $base" -Recommendation 'Verify SYSVOL replication: repadmin /replsummary and dcdiag /test:sysvolcheck'
        return $null
    }
    Write-Log "  SYSVOL accessible." -Level SUCCESS

    $sysvolGuids = try {
        Get-ChildItem $base -Directory -EA Stop |
            Where-Object { $_.Name -match '^\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}$' } |
            ForEach-Object { $_.Name.Trim('{}').ToLower() }
    } catch { @() }

    $adGuids      = @($GPOInventory | ForEach-Object { $_.Id.ToLower() })
    $onlySysvol   = @($sysvolGuids | Where-Object { $_ -notin $adGuids })
    $onlyAD       = @($adGuids     | Where-Object { $_ -notin $sysvolGuids })

    Write-Log "  AD GPOs: $($adGuids.Count)  SYSVOL GPOs: $($sysvolGuids.Count)  Only SYSVOL: $($onlySysvol.Count)  Only AD: $($onlyAD.Count)"

    if ($onlySysvol.Count -gt 0) { Add-Finding -Severity High -Category SYSVOL -Title "$($onlySysvol.Count) orphaned SYSVOL folder(s) with no AD object" -Detail ($onlySysvol -join ', ') -Recommendation 'Investigate; may be remnants of deleted GPOs. Verify before removing.' }
    if ($onlyAD.Count -gt 0)     { Add-Finding -Severity High -Category SYSVOL -Title "$($onlyAD.Count) AD GPO(s) missing SYSVOL folder"                 -Detail ($onlyAD -join ', ')     -Recommendation 'Check SYSVOL replication. Broken GPOs must be recreated or deleted.' }

    $mismatches = [System.Collections.Generic.List[pscustomobject]]::new()
    foreach ($gpo in $GPOInventory) {
        $gptPath = Join-Path $base "{$($gpo.Id)}\GPT.INI"
        if (-not (Test-Path $gptPath -EA SilentlyContinue)) { continue }
        try {
            $vLine = Get-Content $gptPath -EA Stop | Where-Object { $_ -match '^\s*Version\s*=' } | Select-Object -First 1
            if ($vLine) {
                $sysVer = [int]($vLine -replace '.*=\s*', '').Trim()
                $adVer  = ($gpo.UserVersion -shl 16) -bor $gpo.ComputerVersion
                if ($sysVer -ne $adVer) {
                    $mismatches.Add([pscustomobject]@{ GPOName=$gpo.Name; ADVersion=$adVer; SYSVOLVersion=$sysVer })
                    Add-Finding -Severity High -Category SYSVOL -Title "GPT.INI version mismatch: '$($gpo.Name)'" `
                        -Detail "AD: $adVer | SYSVOL: $sysVer — replication problem." `
                        -Recommendation 'Run repadmin /replsummary. Consider gpfixup for widespread issues.' -AffectedObject $gpo.Name
                }
            }
        } catch {}
    }

    Write-Log '  Scanning SYSVOL for cpassword...'
    try {
        $cpFiles = @(Get-ChildItem $base -Recurse -Filter '*.xml' -EA SilentlyContinue |
            Select-String -Pattern 'cpassword' -List -EA SilentlyContinue |
            Select-Object -ExpandProperty Filename -Unique)
        if ($cpFiles.Count -gt 0) {
            Add-Finding -Severity Critical -Category SYSVOL -Title 'cpassword entries found in SYSVOL' `
                -Detail "Files: $($cpFiles -join ', ')" `
                -Recommendation 'Remove all cpassword entries immediately. Apply MS14-025. Use LAPS for local admin passwords.'
        } else { Write-Log '  No cpassword entries in SYSVOL.' -Level SUCCESS }
    } catch { Write-Log "  SYSVOL cpassword scan failed: $_" -Level WARN }

    $result = [pscustomobject]@{
        SYSVOLAccessible  = $true
        ADGPOCount        = $adGuids.Count
        SYSVOLGPOCount    = $sysvolGuids.Count
        OnlyInSYSVOL      = $onlySysvol
        OnlyInAD          = $onlyAD
        VersionMismatches = $mismatches
    }
    [pscustomobject]@{
        ADGPOCount=($adGuids.Count); SYSVOLGPOCount=($sysvolGuids.Count)
        OnlyInSYSVOL=($onlySysvol -join '; '); OnlyInAD=($onlyAD -join '; ')
        VersionMismatches=$mismatches.Count
    } | Export-Csv (Join-Path $RawDataDir 'SYSVOL_Consistency.csv') -NoTypeInformation -Force
    return $result
}

#endregion

#region ── FINDINGS ANALYSIS ──────────────────────────────────────────────────

function Invoke-FindingsAnalysis {
    param([pscustomobject[]]$GPOInventory, [pscustomobject[]]$AllLinks)
    Write-Log 'Running findings analysis' -Level SECTION

    $linkedIds = @($AllLinks | Select-Object -ExpandProperty GPOId -Unique)
    $now       = Get-Date

    foreach ($gpo in $GPOInventory) {
        if ($gpo.Id -notin $linkedIds) {
            Add-Finding -Severity Medium -Category Hygiene -Title "Unlinked GPO: '$($gpo.Name)'" `
                -Detail 'Not linked to any site, domain, or OU. Has no effect.' `
                -Recommendation 'Link if still needed, or delete.' -AffectedObject $gpo.Name
        }
        if ($gpo.IsEmpty) {
            Add-Finding -Severity Low -Category Hygiene -Title "Empty GPO: '$($gpo.Name)'" `
                -Detail 'No computer or user settings.' `
                -Recommendation 'Delete empty GPOs to reduce processing overhead.' -AffectedObject $gpo.Name
        }
        if ($gpo.GpoStatus -eq 'AllSettingsDisabled') {
            Add-Finding -Severity Low -Category Hygiene -Title "Fully disabled GPO: '$($gpo.Name)'" `
                -Detail 'Both halves disabled. Applies nothing.' `
                -Recommendation 'Delete if no longer needed.' -AffectedObject $gpo.Name
        }
        if ($gpo.GpoStatus -in 'UserSettingsDisabled','ComputerSettingsDisabled') {
            Add-Finding -Severity Informational -Category Hygiene -Title "Partially disabled GPO: '$($gpo.Name)'" `
                -Detail "Status: $($gpo.GpoStatus)." `
                -Recommendation 'Confirm this is intentional.' -AffectedObject $gpo.Name
        }
        if ([string]::IsNullOrWhiteSpace($gpo.Description)) {
            Add-Finding -Severity Informational -Category Hygiene -Title "GPO has no description: '$($gpo.Name)'" `
                -Detail 'No description documenting purpose, owner, or review date.' `
                -Recommendation "Add a description to GPO '$($gpo.Name)'." -AffectedObject $gpo.Name
        }
        $age = ($now - $gpo.Modified).Days
        if ($age -ge $StaleGPODays) {
            Add-Finding -Severity Low -Category Hygiene -Title "Stale GPO - $age days old - '$($gpo.Name)'" `
                -Detail "Last modified: $($gpo.Modified)." `
                -Recommendation 'Review; if no longer required, unlink and delete.' -AffectedObject $gpo.Name
        }
        if ($age -le 7) {
            Add-Finding -Severity Informational -Category RecentChanges -Title "Recently modified - $age days: '$($gpo.Name)'" `
                -Detail "Modified: $($gpo.Modified)." `
                -Recommendation 'Verify the change was authorised and documented.' -AffectedObject $gpo.Name
        }
    }
    Write-Log "  Findings analysis complete. Total: $($script:Findings.Count)." -Level SUCCESS
}

#endregion

#region ── HTML REPORT GENERATION ─────────────────────────────────────────────

function New-HTMLReport {
    param(
        [pscustomobject]$EnvInfo,   [pscustomobject]$Connectivity,
        [pscustomobject]$ComputerInfo, [pscustomobject]$RSOPData,
        [pscustomobject[]]$GPOInventory, [pscustomobject[]]$AllLinks,
        [pscustomobject[]]$AllPerms,     [pscustomobject[]]$WMIFilters,
        [pscustomobject]$SysvolResult,   [string]$ReportFile
    )
    Write-Log 'Generating master HTML report' -Level SECTION
    $script:SectionSeq = 0

    $css = @'
*{box-sizing:border-box;margin:0;padding:0}body{font-family:"Segoe UI",Arial,sans-serif;background:#edf2f7;color:#2d3748;font-size:14px}a{color:#3182ce;text-decoration:none}a:hover{text-decoration:underline}.hdr{background:linear-gradient(135deg,#1a365d,#2c5282);color:#fff;padding:20px 32px}.hdr h1{font-size:20px;font-weight:700}.hdr .meta{font-size:12px;margin-top:5px;opacity:.85}.nav{background:#2a4a7f;padding:0 32px;display:flex;flex-wrap:wrap}.nav a{color:#bee3f8;padding:9px 14px;display:inline-block;font-size:12px;border-bottom:3px solid transparent;white-space:nowrap}.nav a:hover{color:#fff;border-bottom-color:#63b3ed;text-decoration:none}.wrap{max-width:1440px;margin:20px auto;padding:0 20px 60px}.section{background:#fff;border-radius:6px;margin-bottom:18px;box-shadow:0 1px 3px rgba(0,0,0,.1);overflow:hidden}.section-hdr{background:#ebf8ff;border-bottom:1px solid #bee3f8;padding:12px 18px;cursor:pointer;display:flex;justify-content:space-between;align-items:center;user-select:none}.sec-title{font-size:14px;font-weight:600;color:#2b6cb0}.toggle-btn{font-size:12px;color:#4a90d9;font-weight:700;min-width:24px;text-align:right}.section-body{padding:18px}table{width:100%;border-collapse:collapse;font-size:12px}thead th{background:#2c5282;color:#fff;padding:8px 10px;text-align:left;font-weight:600;white-space:nowrap}tbody tr:nth-child(even){background:#f7fafc}tbody tr:hover{background:#ebf8ff}td{padding:6px 10px;border-bottom:1px solid #e2e8f0;vertical-align:top;word-break:break-word;max-width:420px}.badge{display:inline-block;padding:2px 9px;border-radius:10px;font-size:11px;font-weight:700;white-space:nowrap}.bc{background:#fff5f5;color:#c53030;border:1px solid #fc8181}.bh{background:#fffaf0;color:#c05621;border:1px solid #f6ad55}.bm{background:#fffff0;color:#975a16;border:1px solid #f6e05e}.bl{background:#f0fff4;color:#276749;border:1px solid #68d391}.bi{background:#f0f4f8;color:#4a5568;border:1px solid #cbd5e0}.stat-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(130px,1fr));gap:12px;margin-bottom:16px}.stat-card{background:#f7fafc;border:1px solid #e2e8f0;border-radius:6px;padding:12px;text-align:center}.stat-card .num{font-size:26px;font-weight:700;color:#2b6cb0}.stat-card .lbl{font-size:11px;color:#718096;margin-top:3px}.sok{color:#276749;font-weight:600}.sfail{color:#c53030;font-weight:600}.no-data{color:#a0aec0;font-style:italic;padding:8px 0}.sumbox{border:1px solid #e2e8f0;border-radius:5px;padding:10px 14px;background:#f7fafc}
'@

    $js = 'function toggleSec(id){var b=document.getElementById("body_"+id),t=document.getElementById("toggle_"+id);if(b.style.display==="none"){b.style.display="";t.textContent="[-]";}else{b.style.display="none";t.textContent="[+]";}}'

    $crit=$($script:Findings|Where-Object Severity -eq 'Critical').Count
    $high=$($script:Findings|Where-Object Severity -eq 'High').Count
    $med =$($script:Findings|Where-Object Severity -eq 'Medium').Count
    $low =$($script:Findings|Where-Object Severity -eq 'Low').Count
    $info=$($script:Findings|Where-Object Severity -eq 'Informational').Count
    $gCnt = if ($GPOInventory) { $GPOInventory.Count } else { 'N/A' }
    $lCnt = if ($AllLinks)     { $AllLinks.Count }     else { 'N/A' }

    $summaryHtml = @"
<div class="stat-grid">
  <div class="stat-card"><div class="num">$gCnt</div><div class="lbl">Total GPOs</div></div>
  <div class="stat-card"><div class="num">$lCnt</div><div class="lbl">Total Links</div></div>
  <div class="stat-card"><div class="num" style="color:#c53030">$crit</div><div class="lbl">Critical</div></div>
  <div class="stat-card"><div class="num" style="color:#c05621">$high</div><div class="lbl">High</div></div>
  <div class="stat-card"><div class="num" style="color:#975a16">$med</div><div class="lbl">Medium</div></div>
  <div class="stat-card"><div class="num" style="color:#276749">$low</div><div class="lbl">Low</div></div>
  <div class="stat-card"><div class="num" style="color:#4a5568">$info</div><div class="lbl">Info</div></div>
</div>
<div class="sumbox">
  <b>Target:</b> $(ConvertTo-HtmlEncoded $EnvInfo.AuditTarget) &nbsp;|&nbsp;
  <b>Domain:</b> $(ConvertTo-HtmlEncoded $EnvInfo.Domain) &nbsp;|&nbsp;
  <b>DC:</b> $(ConvertTo-HtmlEncoded $EnvInfo.DomainController) &nbsp;|&nbsp;
  <b>Operator:</b> $(ConvertTo-HtmlEncoded $EnvInfo.CurrentUser) &nbsp;|&nbsp;
  <b>Date:</b> $($script:StartTime.ToString('yyyy-MM-dd HH:mm:ss'))
</div>
"@

    $envRows = @(
        [pscustomobject]@{Property='Computer';         Value=$EnvInfo.ComputerName}
        [pscustomobject]@{Property='FQDN';             Value=$EnvInfo.FQDN}
        [pscustomobject]@{Property='Domain';           Value=$EnvInfo.Domain}
        [pscustomobject]@{Property='Domain Controller';Value=$EnvInfo.DomainController}
        [pscustomobject]@{Property='AD Site';          Value=$EnvInfo.ADSite}
        [pscustomobject]@{Property='OS';               Value=$EnvInfo.OSCaption}
        [pscustomobject]@{Property='OS Build';         Value=$EnvInfo.OSBuild}
        [pscustomobject]@{Property='PowerShell';       Value="$($EnvInfo.PSVersion) [$($EnvInfo.PSEdition)]"}
        [pscustomobject]@{Property='Running As';       Value=$EnvInfo.CurrentUser}
        [pscustomobject]@{Property='Admin';            Value=$EnvInfo.IsAdmin}
        [pscustomobject]@{Property='Domain Joined';    Value=$EnvInfo.IsDomainJoined}
        [pscustomobject]@{Property='GP Module';        Value=$script:GPModuleLoaded}
        [pscustomobject]@{Property='AD Module';        Value=$script:ADModuleLoaded}
    )
    $envHtml = New-HtmlTable -Data $envRows -Properties @('Property','Value')

    $connHtml = if ($Connectivity) {
        $sb2 = [System.Text.StringBuilder]::new()
        [void]$sb2.Append('<table><thead><tr><th>Check</th><th>Result</th></tr></thead><tbody>')
        foreach ($kv in $Connectivity.PSObject.Properties) {
            $cls = if ($kv.Value -eq 'OK') { 'sok' } else { 'sfail' }
            [void]$sb2.Append("<tr><td>$(ConvertTo-HtmlEncoded $kv.Name)</td><td class='$cls'>$(ConvertTo-HtmlEncoded $kv.Value)</td></tr>")
        }
        [void]$sb2.Append('</tbody></table>')
        $sb2.ToString()
    } else { '<p class="no-data">Connectivity check not run.</p>' }

    $compAppliedHtml = if ($RSOPData -and $RSOPData.ComputerApplied.Count -gt 0) { New-HtmlTable $RSOPData.ComputerApplied @('Order','Name','Id') } else { '<p class="no-data">No computer-scope applied GPOs recorded.</p>' }
    $compDeniedHtml  = if ($RSOPData -and $RSOPData.ComputerDenied.Count  -gt 0) { New-HtmlTable $RSOPData.ComputerDenied  @('Name','Reason','Id') } else { '<p class="no-data">No computer-scope denied GPOs recorded.</p>' }
    $userAppliedHtml = if ($RSOPData -and $RSOPData.UserApplied.Count     -gt 0) { New-HtmlTable $RSOPData.UserApplied     @('Order','Name','Id') } else { '<p class="no-data">No user-scope applied GPOs recorded.</p>' }
    $userDeniedHtml  = if ($RSOPData -and $RSOPData.UserDenied.Count      -gt 0) { New-HtmlTable $RSOPData.UserDenied      @('Name','Reason','Id') } else { '<p class="no-data">No user-scope denied GPOs recorded.</p>' }

    $gpoInvHtml = if ($GPOInventory -and $GPOInventory.Count -gt 0) {
        New-HtmlTable $GPOInventory @('Name','GpoStatus','LinkCount','UserVersion','ComputerVersion','WmiFilter','HasCPassword','IsEmpty','Modified','Owner')
    } else { '<p class="no-data">Domain inventory not collected. Use -IncludeDomainInventory.</p>' }

    $linksHtml = if ($AllLinks -and $AllLinks.Count -gt 0) {
        $disp = if ($AllLinks.Count -gt 500) { $AllLinks[0..499] } else { $AllLinks }
        (New-HtmlTable $disp @('GPOName','Target','TargetType','LinkOrder','LinkEnabled','Enforced','BlockInheritance')) +
            $(if ($AllLinks.Count -gt 500) { "<p style='color:#718096;font-size:12px'>Showing 500 of $($AllLinks.Count)</p>" } else { '' })
    } else { '<p class="no-data">Link inventory not collected.</p>' }

    $permsHtml = if ($AllPerms -and $AllPerms.Count -gt 0) {
        $disp = if ($AllPerms.Count -gt 1000) { $AllPerms[0..999] } else { $AllPerms }
        (New-HtmlTable $disp @('GPOName','Trustee','TrusteeType','Permission','Denied')) +
            $(if ($AllPerms.Count -gt 1000) { "<p style='color:#718096;font-size:12px'>Showing 1000 of $($AllPerms.Count)</p>" } else { '' })
    } else { '<p class="no-data">Permissions audit not collected. Use -IncludeSecurityAudit.</p>' }

    $wmiHtml = if ($WMIFilters -and $WMIFilters.Count -gt 0) {
        New-HtmlTable $WMIFilters @('Name','Namespace','Query','IsWin32Product','BroadOrExpensive','Author','Modified')
    } else { '<p class="no-data">No WMI filters found.</p>' }

    $sysvolHtml = if ($SysvolResult) { @"
<table><thead><tr><th>Item</th><th>Value</th></tr></thead><tbody>
<tr><td>SYSVOL Accessible</td><td class="sok">Yes</td></tr>
<tr><td>AD GPO Count</td><td>$($SysvolResult.ADGPOCount)</td></tr>
<tr><td>SYSVOL GPO Count</td><td>$($SysvolResult.SYSVOLGPOCount)</td></tr>
<tr><td>Only in SYSVOL (orphaned)</td><td>$($SysvolResult.OnlyInSYSVOL.Count)</td></tr>
<tr><td>Only in AD (missing SYSVOL)</td><td>$($SysvolResult.OnlyInAD.Count)</td></tr>
<tr><td>GPT.INI Version Mismatches</td><td>$($SysvolResult.VersionMismatches.Count)</td></tr>
</tbody></table>
"@ } else { '<p class="no-data">SYSVOL check not performed or SYSVOL not accessible.</p>' }

    # Findings table with raw badge HTML
    $sevOrder = @{Critical=1;High=2;Medium=3;Low=4;Informational=5}
    $sorted   = $script:Findings | Sort-Object { $sevOrder[$_.Severity] }
    $fSb = [System.Text.StringBuilder]::new()
    if ($sorted.Count -gt 0) {
        [void]$fSb.Append('<table><thead><tr><th>Sev</th><th>Cat</th><th>Title</th><th>Object</th><th>Detail</th><th>Action</th></tr></thead><tbody>')
        foreach ($f in $sorted) {
            $bc = switch ($f.Severity) { 'Critical'{'bc'} 'High'{'bh'} 'Medium'{'bm'} 'Low'{'bl'} default{'bi'} }
            [void]$fSb.Append("<tr><td><span class='badge $bc'>$(ConvertTo-HtmlEncoded $f.Severity)</span></td>")
            [void]$fSb.Append("<td>$(ConvertTo-HtmlEncoded $f.Category)</td>")
            [void]$fSb.Append("<td>$(ConvertTo-HtmlEncoded $f.Title)</td>")
            [void]$fSb.Append("<td>$(ConvertTo-HtmlEncoded $f.AffectedObject)</td>")
            [void]$fSb.Append("<td>$(ConvertTo-HtmlEncoded $f.Detail)</td>")
            [void]$fSb.Append("<td>$(ConvertTo-HtmlEncoded $f.Recommendation)</td></tr>")
        }
        [void]$fSb.Append('</tbody></table>')
    } else { [void]$fSb.Append('<p class="no-data">No findings generated.</p>') }
    $findingsHtml = $fSb.ToString()

    $critHigh  = @($sorted | Where-Object { $_.Severity -in 'Critical','High' })
    $remLines  = $critHigh | ForEach-Object { "<li><strong>[$(ConvertTo-HtmlEncoded $_.Severity)] $(ConvertTo-HtmlEncoded $_.Title)</strong><br>$(ConvertTo-HtmlEncoded $_.Recommendation)</li>" }
    $remHtml   = if ($remLines.Count -gt 0) { "<ol style='padding-left:20px;line-height:1.9'>$($remLines -join '')</ol>" }
                 else { '<p class="no-data">No critical or high findings to remediate.</p>' }

    $gpoReportHtml = if ($GPOInventory -and $GPOInventory.Count -gt 0) {
        $lSb = [System.Text.StringBuilder]::new()
        [void]$lSb.Append('<table><thead><tr><th>GPO Name</th><th>Status</th><th>Links</th><th>HTML</th><th>XML</th></tr></thead><tbody>')
        foreach ($g in $GPOInventory) {
            $sf = Get-SafeFileName $g.Name
            $hExists = Test-Path $g.HtmlReportPath -EA SilentlyContinue
            $xExists = Test-Path $g.XmlReportPath  -EA SilentlyContinue
            $hLnk = if ($hExists) { "<a href='..\DomainGPOs\HTML\$sf.html' target='_blank'>HTML</a>" } else { 'N/A' }
            $xLnk = if ($xExists) { "<a href='..\DomainGPOs\XML\$sf.xml'  target='_blank'>XML</a>"  } else { 'N/A' }
            [void]$lSb.Append("<tr><td>$(ConvertTo-HtmlEncoded $g.Name)</td><td>$(ConvertTo-HtmlEncoded $g.GpoStatus)</td><td>$($g.LinkCount)</td><td>$hLnk</td><td>$xLnk</td></tr>")
        }
        [void]$lSb.Append('</tbody></table>')
        $lSb.ToString()
    } else { '<p class="no-data">No individual GPO reports generated.</p>' }

    $secs  = @()
    $secs += New-HtmlSection 'Executive Summary'         $summaryHtml
    $secs += New-HtmlSection 'Environment'               $envHtml
    $secs += New-HtmlSection 'Connectivity'              $connHtml
    $secs += New-HtmlSection 'Computer Applied GPOs'     $compAppliedHtml
    $secs += New-HtmlSection 'Computer Denied GPOs'      $compDeniedHtml
    $secs += New-HtmlSection 'User Applied GPOs'         $userAppliedHtml   -Collapsed
    $secs += New-HtmlSection 'User Denied GPOs'          $userDeniedHtml    -Collapsed
    $secs += New-HtmlSection 'Domain GPO Inventory'      $gpoInvHtml        -Collapsed
    $secs += New-HtmlSection 'GPO Link Map'              $linksHtml         -Collapsed
    $secs += New-HtmlSection 'Permissions / Delegation'  $permsHtml         -Collapsed
    $secs += New-HtmlSection 'WMI Filters'               $wmiHtml           -Collapsed
    $secs += New-HtmlSection 'SYSVOL Consistency'        $sysvolHtml
    $secs += New-HtmlSection 'All Findings'              $findingsHtml
    $secs += New-HtmlSection 'Remediation Priorities'    $remHtml
    $secs += New-HtmlSection 'Individual GPO Reports'    $gpoReportHtml     -Collapsed

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>GPO Audit - $(ConvertTo-HtmlEncoded $EnvInfo.AuditTarget)</title>
<style>$css</style></head>
<body>
<div class="hdr">
  <h1>Group Policy Object Audit Report</h1>
  <div class="meta">Target: <strong>$(ConvertTo-HtmlEncoded $EnvInfo.AuditTarget)</strong> &nbsp;|&nbsp; Domain: <strong>$(ConvertTo-HtmlEncoded $EnvInfo.Domain)</strong> &nbsp;|&nbsp; DC: <strong>$(ConvertTo-HtmlEncoded $EnvInfo.DomainController)</strong> &nbsp;|&nbsp; Generated: <strong>$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</strong></div>
</div>
<div class="nav">
  <a href="javascript:void(0)">Summary</a><a href="javascript:void(0)">Environment</a>
  <a href="javascript:void(0)">Connectivity</a><a href="javascript:void(0)">Applied GPOs</a>
  <a href="javascript:void(0)">All Findings</a><a href="javascript:void(0)">SYSVOL</a>
  <a href="javascript:void(0)">Remediation</a>
</div>
<div class="wrap">
$($secs -join "`n")
</div>
<script>$js</script>
</body></html>
"@

    try {
        $html | Out-File -FilePath $ReportFile -Encoding UTF8 -Force
        Write-Log "Master HTML report: $ReportFile" -Level SUCCESS
    } catch { Write-Log "Failed to save HTML report: $_" -Level ERROR }
}

#endregion

#region ── EXPORT HELPERS ─────────────────────────────────────────────────────

function Export-FindingsData {
    param([string]$RootOutput)
    $script:Findings | Export-Csv (Join-Path $RootOutput 'RawData\Findings.csv') -NoTypeInformation -Force
    $script:Findings | ConvertTo-Json -Depth 4 | Out-File (Join-Path $RootOutput 'RawData\Findings.json') -Encoding UTF8 -Force

    $sevOrder = @{Critical=1;High=2;Medium=3;Low=4;Informational=5}
    $sorted   = $script:Findings | Sort-Object { $sevOrder[$_.Severity] }
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('GPO AUDIT FINDINGS REPORT')
    [void]$sb.AppendLine("Generated : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    [void]$sb.AppendLine('=' * 78)
    foreach ($sev in @('Critical','High','Medium','Low','Informational')) {
        $g = @($sorted | Where-Object Severity -eq $sev)
        if ($g.Count -eq 0) { continue }
        [void]$sb.AppendLine("`n[$sev] — $($g.Count) finding(s)")
        [void]$sb.AppendLine('-' * 60)
        foreach ($f in $g) {
            [void]$sb.AppendLine("  Object : $($f.AffectedObject)")
            [void]$sb.AppendLine("  Title  : $($f.Title)")
            [void]$sb.AppendLine("  Detail : $($f.Detail)")
            [void]$sb.AppendLine("  Action : $($f.Recommendation)")
            [void]$sb.AppendLine()
        }
    }
    $sb.ToString() | Out-File (Join-Path $RootOutput 'Summary\Findings_Summary.txt') -Encoding UTF8 -Force
    Write-Log 'Findings exported: CSV, JSON, TXT.' -Level SUCCESS
}

function Export-ExecutionLog {
    param([string]$LogDir)
    $script:LogLines | Out-File (Join-Path $LogDir 'Audit_Execution.log') -Encoding UTF8 -Force
}

#endregion

#region ── MAIN EXECUTION ─────────────────────────────────────────────────────

function Main {
    Write-Host ''
    Write-Host '  GPO-Audit v1.0.0  -  Starting' -ForegroundColor Cyan
    Write-Host '  ─────────────────────────────────────────────────────────────' -ForegroundColor Cyan

    # 1. Admin check / auto-elevate
    if (-not (Test-IsAdmin)) {
        Request-AdministratorElevation
        return
    }
    Write-Log 'Administrator privileges confirmed.' -Level SUCCESS

    # 2. Environment
    $envInfo = Get-EnvironmentInfo
    $osInfo  = Get-OSInfo

    if (-not $envInfo.IsDomainJoined) {
        Write-Log 'Machine is NOT domain-joined. Domain features unavailable.' -Level WARN
        Add-Finding -Severity High -Category Prerequisites -Title 'Machine is not domain-joined' `
            -Detail 'GPO inventory, RSOP, and SYSVOL checks require domain membership.' `
            -Recommendation 'Run from a domain-joined machine.'
    }

    # 3. Output directory
    New-OutputDirectory -EnvInfo $envInfo

    # 4. RSAT check / install
    Write-Log 'Checking RSAT prerequisites' -Level SECTION
    $rsatStatus = Test-RSATAvailable -OSInfo $osInfo
    Write-Log "  GroupPolicy RSAT     : $(if ($rsatStatus.GroupPolicyRSAT) {'Installed'} else {'MISSING'})"
    Write-Log "  ActiveDirectory RSAT : $(if ($rsatStatus.ActiveDirectoryRSAT) {'Installed'} else {'MISSING'})"

    if (-not $rsatStatus.GroupPolicyRSAT -or -not $rsatStatus.ActiveDirectoryRSAT) {
        if ($InstallPrerequisites) {
            Install-RSATComponents -OSInfo $osInfo
        } elseif ($PSCmdlet.ShouldProcess('Missing RSAT components', 'Install')) {
            Install-RSATComponents -OSInfo $osInfo
        } else {
            Write-Log 'RSAT installation skipped.' -Level WARN
            Add-Finding -Severity Medium -Category Prerequisites `
                -Title  'RSAT components missing' `
                -Detail "GroupPolicyRSAT=$($rsatStatus.GroupPolicyRSAT) | ActiveDirectoryRSAT=$($rsatStatus.ActiveDirectoryRSAT)" `
                -Recommendation 'Run with -InstallPrerequisites to install automatically.'
        }
    }

    # 5. Modules
    Import-RequiredModules

    # 6. Connectivity
    $connectivity = Test-DomainConnectivity -DC $script:DC -DomainName $Domain

    # 7. Computer info
    $computerInfo = Get-ComputerADInfo -Target $ComputerName -DomainName $Domain
    $computerInfo | ConvertTo-Json -Depth 3 |
        Out-File (Join-Path $script:RootOutput 'Computer\ComputerInfo.json') -Encoding UTF8 -Force

    # 8. RSOP
    $rsopData = $null
    if (-not $SkipRemoteRSOP) {
        $proceed = $true
        if ($script:IsRemote) { $proceed = Test-RemoteTarget -Target $ComputerName }
        if ($proceed) {
            $rsopData = Invoke-GPResultCollection -Target $ComputerName -UserParam $UserName `
                -OutDir (Join-Path $script:RootOutput 'RSOP')
        }
    } else { Write-Log 'RSOP collection skipped (-SkipRemoteRSOP).' }

    # 9. Event logs
    $events = @()
    if ($IncludeEventLogs) {
        $events = Get-GPEventLog -Target $ComputerName -OutDir (Join-Path $script:RootOutput 'EventLogs')
    }

    # 10. Domain inventory
    $gpoInventory = @(); $allLinks = @(); $allPerms = @(); $wmiFilters = @(); $sysvolResult = $null

    if ($IncludeDomainInventory) {
        $gpoInventory = Get-DomainGPOInventory -DomainName $Domain `
            -DomainGPODir (Join-Path $script:RootOutput 'DomainGPOs') `
            -RawDataDir   (Join-Path $script:RootOutput 'RawData')

        $allLinks = Get-GPOLinkInventory -DomainName $Domain `
            -RawDataDir (Join-Path $script:RootOutput 'RawData')

        if ($IncludeSecurityAudit -and $gpoInventory.Count -gt 0) {
            $allPerms = Get-GPOPermissionsAudit -GPOInventory $gpoInventory `
                -RawDataDir (Join-Path $script:RootOutput 'RawData')
        }

        $wmiFilters = Get-WMIFilterAudit -GPOInventory $gpoInventory -DomainName $Domain `
            -RawDataDir (Join-Path $script:RootOutput 'RawData')

        $sysvolResult = Test-SYSVOLConsistency -DomainName $Domain -GPOInventory $gpoInventory `
            -RawDataDir (Join-Path $script:RootOutput 'RawData')
    }

    # 11. Findings analysis
    if ($gpoInventory.Count -gt 0) {
        Invoke-FindingsAnalysis -GPOInventory $gpoInventory -AllLinks $allLinks
    }

    # 12. HTML report
    New-HTMLReport `
        -EnvInfo $envInfo -Connectivity $connectivity -ComputerInfo $computerInfo `
        -RSOPData $rsopData -GPOInventory $gpoInventory -AllLinks $allLinks `
        -AllPerms $allPerms -WMIFilters $wmiFilters -SysvolResult $sysvolResult `
        -ReportFile $script:ReportPath

    # 13. Exports
    Export-FindingsData -RootOutput $script:RootOutput
    Export-ExecutionLog -LogDir     (Join-Path $script:RootOutput 'Logs')

    # 14. Transcript
    try { Stop-Transcript -EA SilentlyContinue } catch {}

    # 15. Summary
    $elapsed = (Get-Date) - $script:StartTime
    $cF = @($script:Findings | Where-Object Severity -eq 'Critical').Count
    $hF = @($script:Findings | Where-Object Severity -eq 'High').Count
    $mF = @($script:Findings | Where-Object Severity -eq 'Medium').Count
    $lF = @($script:Findings | Where-Object Severity -eq 'Low').Count
    Write-Host ''
    Write-Host '  GPO-Audit Complete' -ForegroundColor Cyan
    Write-Host '  ─────────────────────────────────────────────────────────────' -ForegroundColor Cyan
    Write-Host "  Duration  : $($elapsed.ToString('mm\:ss'))"
    Write-Host "  Findings  : Critical=$cF  High=$hF  Medium=$mF  Low=$lF"
    Write-Host "  Output    : $script:RootOutput"
    Write-Host "  Report    : $script:ReportPath"
    Write-Host ''

    if ($OpenReport -and (Test-Path $script:ReportPath -EA SilentlyContinue)) {
        Start-Process $script:ReportPath
    }
}

Main

#endregion




