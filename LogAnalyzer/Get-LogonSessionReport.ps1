#Requires -Version 7.0
<#
.SYNOPSIS
    Windows Logon Session Report - Queries Security event logs from remote machines,
    correlates logon/logoff/reconnect/lock events into per-user sessions, and generates
    a professional HTML5 report.

.DESCRIPTION
    Production-quality PowerShell 7+ utility that:
    - Queries Windows Security event logs (Event IDs: 4624, 4634, 4647, 4778, 4779, 4800, 4801)
    - Correlates events into per-user logon sessions using LogonId as the primary key
    - Generates a self-contained HTML5 report with sorting, searching, and expandable details
    - Supports secure credential storage via DPAPI-encrypted registry entries

    Prerequisites:
    - PowerShell 7.0 or later
    - Administrative access on target machines (local admin sufficient; domain admin not required)
    - WinRM / PS Remoting enabled on targets (Enable-PSRemoting on each target)
    - Windows Audit Policy must log logon/logoff events on targets:
        auditpol /set /subcategory:"Logon" /success:enable /failure:enable
        auditpol /set /subcategory:"Logoff" /success:enable
        auditpol /set /subcategory:"Other Logon/Logoff Events" /success:enable
    - Firewall: TCP 5985 (HTTP) or 5986 (HTTPS) for WinRM

.PARAMETER ComputerName
    One or more target computer names or IP addresses.

.PARAMETER ComputerListPath
    Path to a text file containing one computer name per line (blank lines and # comments ignored).

.PARAMETER StartTime
    Start of the query window. Default: 7 days ago (midnight UTC).

.PARAMETER EndTime
    End of the query window. Default: now (UTC).

.PARAMETER Credential
    A PSCredential object for authenticating to remote machines.

.PARAMETER UseStoredCredential
    Load credentials previously saved with -SaveCredential.

.PARAMETER SaveCredential
    Prompt for credentials and store them encrypted in the registry, then exit.

.PARAMETER ClearCredential
    Remove stored credentials from the registry, then exit.

.PARAMETER OutputPath
    Directory for report output. Default: current directory.

.PARAMETER ReportName
    Base name for the report file. Default: LogonReport_yyyyMMdd_HHmmss.

.PARAMETER TimeoutSeconds
    Timeout for each remote query in seconds. Default: 120.

.PARAMETER IncludeFailuresInReport
    Include machines that failed to query in the HTML report.

.PARAMETER TestMode
    Run against localhost for validation without requiring remote access.

.PARAMETER ExportJson
    Also export session data as a JSON file alongside the HTML report.

.PARAMETER ExportCsv
    Also export a flattened CSV of sessions alongside the HTML report.

.EXAMPLE
    # Save credentials for later use
    .\Get-LogonSessionReport.ps1 -SaveCredential

.EXAMPLE
    # Query a single host using stored credentials
    .\Get-LogonSessionReport.ps1 -ComputerName "WS01" -UseStoredCredential

.EXAMPLE
    # Query multiple hosts with explicit credentials, last 3 days
    .\Get-LogonSessionReport.ps1 -ComputerName "WS01","WS02","DC01" -Credential (Get-Credential) -StartTime (Get-Date).AddDays(-3)

.EXAMPLE
    # Query hosts from a file and export all formats
    .\Get-LogonSessionReport.ps1 -ComputerListPath ".\targets.txt" -UseStoredCredential -ExportJson -ExportCsv

.EXAMPLE
    # Test mode against localhost
    .\Get-LogonSessionReport.ps1 -TestMode -Verbose
#>

[CmdletBinding(DefaultParameterSetName = 'Query')]
param(
    [Parameter(ParameterSetName = 'Query', Position = 0)]
    [Parameter(ParameterSetName = 'TestMode')]
    [string[]]$ComputerName,

    [Parameter(ParameterSetName = 'Query')]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$ComputerListPath,

    [Parameter(ParameterSetName = 'Query')]
    [Parameter(ParameterSetName = 'TestMode')]
    [datetime]$StartTime = (Get-Date).AddDays(-7).Date.ToUniversalTime(),

    [Parameter(ParameterSetName = 'Query')]
    [Parameter(ParameterSetName = 'TestMode')]
    [datetime]$EndTime = (Get-Date).ToUniversalTime(),

    [Parameter(ParameterSetName = 'Query')]
    [System.Management.Automation.PSCredential]$Credential,

    [Parameter(ParameterSetName = 'Query')]
    [switch]$UseStoredCredential,

    [Parameter(ParameterSetName = 'SaveCred')]
    [switch]$SaveCredential,

    [Parameter(ParameterSetName = 'ClearCred')]
    [switch]$ClearCredential,

    [Parameter(ParameterSetName = 'Query')]
    [Parameter(ParameterSetName = 'TestMode')]
    [string]$OutputPath = (Get-Location).Path,

    [Parameter(ParameterSetName = 'Query')]
    [Parameter(ParameterSetName = 'TestMode')]
    [string]$ReportName = "LogonReport_$(Get-Date -Format 'yyyyMMdd_HHmmss')",

    [Parameter(ParameterSetName = 'Query')]
    [Parameter(ParameterSetName = 'TestMode')]
    [ValidateRange(10, 600)]
    [int]$TimeoutSeconds = 120,

    [Parameter(ParameterSetName = 'Query')]
    [Parameter(ParameterSetName = 'TestMode')]
    [switch]$IncludeFailuresInReport,

    [Parameter(ParameterSetName = 'TestMode')]
    [switch]$TestMode,

    [Parameter(ParameterSetName = 'Query')]
    [Parameter(ParameterSetName = 'TestMode')]
    [switch]$ExportJson,

    [Parameter(ParameterSetName = 'Query')]
    [Parameter(ParameterSetName = 'TestMode')]
    [switch]$ExportCsv
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ─────────────────────────────────────────────────────────────────────────────
# CONSTANTS
# ─────────────────────────────────────────────────────────────────────────────

$script:RegistryPath = 'HKCU:\Software\LogonAuditTool'
$script:RegistryValueName = 'Credential'

# Logon Type mapping: numeric code → human-readable label
# Reference: https://learn.microsoft.com/en-us/windows/security/threat-protection/auditing/event-4624
$script:LogonTypeMap = @{
    0  = 'System'
    2  = 'Interactive'
    3  = 'Network'
    4  = 'Batch'
    5  = 'Service'
    7  = 'Unlock'
    8  = 'NetworkCleartext'
    9  = 'NewCredentials'
    10 = 'RemoteInteractive'
    11 = 'CachedInteractive'
    12 = 'CachedRemoteInteractive'
    13 = 'CachedUnlock'
}

# Event IDs we care about
$script:EventIds = @(4624, 4634, 4647, 4778, 4779, 4800, 4801)

# ─────────────────────────────────────────────────────────────────────────────
# CREDENTIAL MANAGEMENT
# ─────────────────────────────────────────────────────────────────────────────
# Credentials are stored using Export-Clixml which serializes PSCredential with
# the password encrypted via Windows DPAPI (Data Protection API). DPAPI encrypts
# under the CurrentUser scope: only the same Windows user account on the same
# machine can decrypt the blob. The encrypted XML is stored as a Base64 string
# in the registry at HKCU:\Software\LogonAuditTool\Credential.
# ─────────────────────────────────────────────────────────────────────────────

function Save-StoredCredential {
    <#
    .SYNOPSIS
        Prompts for credentials and stores them encrypted in the registry via DPAPI.
    #>
    [CmdletBinding()]
    param()

    $cred = Get-Credential -Message "Enter credentials for remote logon audit queries"
    if (-not $cred) {
        Write-Warning "No credential provided. Aborting save."
        return
    }

    # Ensure registry path exists
    if (-not (Test-Path $script:RegistryPath)) {
        New-Item -Path $script:RegistryPath -Force | Out-Null
    }

    # Serialize to DPAPI-encrypted XML, then Base64-encode for registry storage
    $tempFile = [System.IO.Path]::GetTempFileName()
    try {
        $cred | Export-Clixml -Path $tempFile -Force
        $xmlBytes = [System.IO.File]::ReadAllBytes($tempFile)
        $b64 = [Convert]::ToBase64String($xmlBytes)
        Set-ItemProperty -Path $script:RegistryPath -Name $script:RegistryValueName -Value $b64 -Type String
        Write-Host "Credential saved successfully (DPAPI-encrypted, CurrentUser scope)." -ForegroundColor Green
    }
    finally {
        # Securely remove temp file
        if (Test-Path $tempFile) { Remove-Item $tempFile -Force }
    }
}

function Get-StoredCredential {
    <#
    .SYNOPSIS
        Retrieves DPAPI-encrypted credentials from the registry.
    .OUTPUTS
        PSCredential or $null if not found.
    #>
    [CmdletBinding()]
    [OutputType([System.Management.Automation.PSCredential])]
    param()

    if (-not (Test-Path $script:RegistryPath)) {
        Write-Warning "No stored credential found at $($script:RegistryPath)."
        return $null
    }

    $b64 = (Get-ItemProperty -Path $script:RegistryPath -Name $script:RegistryValueName -ErrorAction SilentlyContinue).$($script:RegistryValueName)
    if (-not $b64) {
        Write-Warning "No stored credential value found."
        return $null
    }

    $tempFile = [System.IO.Path]::GetTempFileName()
    try {
        $xmlBytes = [Convert]::FromBase64String($b64)
        [System.IO.File]::WriteAllBytes($tempFile, $xmlBytes)
        $cred = Import-Clixml -Path $tempFile
        Write-Verbose "Credential loaded for user: $($cred.UserName)"
        return $cred
    }
    catch {
        Write-Warning "Failed to decrypt stored credential (wrong user context?): $_"
        return $null
    }
    finally {
        if (Test-Path $tempFile) { Remove-Item $tempFile -Force }
    }
}

function Clear-StoredCredential {
    <#
    .SYNOPSIS
        Removes stored credentials from the registry.
    #>
    [CmdletBinding()]
    param()

    if (Test-Path $script:RegistryPath) {
        Remove-ItemProperty -Path $script:RegistryPath -Name $script:RegistryValueName -ErrorAction SilentlyContinue
        Write-Host "Stored credential cleared." -ForegroundColor Yellow
    }
    else {
        Write-Host "No stored credential to clear." -ForegroundColor Gray
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# EVENT RETRIEVAL
# ─────────────────────────────────────────────────────────────────────────────

function Get-RemoteSecurityEvents {
    <#
    .SYNOPSIS
        Queries Security event log on a remote machine for logon-related events.
    .DESCRIPTION
        Uses Invoke-Command (PS Remoting) to run Get-WinEvent on the target with
        FilterHashtable for performance. Returns parsed event objects or an error result.
    .OUTPUTS
        [PSCustomObject] with ComputerName, QueryStatus, Error, Events[]
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Computer,

        [Parameter(Mandatory)]
        [datetime]$StartTime,

        [Parameter(Mandatory)]
        [datetime]$EndTime,

        [System.Management.Automation.PSCredential]$Credential,

        [int]$TimeoutSeconds = 120,

        [switch]$IsLocalhost
    )

    $result = [PSCustomObject]@{
        ComputerName = $Computer
        QueryStatus  = 'Failed'
        Error        = $null
        Events       = @()
        EventCount   = 0
        QueryTime    = $null
    }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    # The scriptblock that runs on the remote (or local) machine.
    # IMPORTANT: Must be compatible with Windows PowerShell 5.1 since WinRM
    # remoting uses the system PowerShell, not PowerShell 7. Avoid:
    #   - ?? (null-coalescing)       - ??= (null-coalescing assignment)
    #   - ?. (null-conditional)      - ternary (condition ? a : b)
    $queryBlock = {
        param($EventIds, $Start, $End)

        $filter = @{
            LogName   = 'Security'
            Id        = $EventIds
            StartTime = $Start
            EndTime   = $End
        }

        $events = Get-WinEvent -FilterHashtable $filter -ErrorAction SilentlyContinue

        foreach ($evt in $events) {
            # Parse XML for structured data instead of fragile message parsing
            [xml]$xml = $evt.ToXml()
            $sys = $xml.Event.System
            $data = @{}

            # EventData fields to hashtable.
            # Use .InnerText instead of .'#text' because self-closing/empty
            # XML elements have no #text child node, which throws in strict mode.
            if ($xml.Event.EventData -and $xml.Event.EventData.Data) {
                foreach ($d in $xml.Event.EventData.Data) {
                    if ($d.Name) {
                        $val = $d.InnerText
                        if ($val -ne '') { $data[$d.Name] = $val }
                    }
                }
            }

            # Resolve LogonId: prefer TargetLogonId, fall back to SubjectLogonId, then LogonId
            $resolvedLogonId = $data['TargetLogonId']
            if (-not $resolvedLogonId) { $resolvedLogonId = $data['SubjectLogonId'] }
            if (-not $resolvedLogonId) { $resolvedLogonId = $data['LogonId'] }

            # Resolve LogonType to integer or null
            $logonTypeVal = $null
            if ($data['LogonType']) { $logonTypeVal = [int]$data['LogonType'] }

            [PSCustomObject]@{
                EventId            = [int]$sys.EventID
                TimeCreated        = [datetime]$evt.TimeCreated.ToUniversalTime()
                Computer           = $sys.Computer
                # Fields from EventData (will be null if not present for that event type)
                TargetUserName     = $data['TargetUserName']
                TargetDomainName   = $data['TargetDomainName']
                TargetUserSid      = $data['TargetUserSid']
                SubjectUserName    = $data['SubjectUserName']
                SubjectDomainName  = $data['SubjectDomainName']
                LogonType          = $logonTypeVal
                TargetLogonId      = $data['TargetLogonId']
                SubjectLogonId     = $data['SubjectLogonId']
                LogonId            = $resolvedLogonId
                WorkstationName    = $data['WorkstationName']
                IpAddress          = $data['IpAddress']
                IpPort             = $data['IpPort']
                ProcessName        = $data['ProcessName']
                AuthPackage        = $data['AuthenticationPackageName']
                # RDP session fields (4778/4779)
                AccountName        = $data['AccountName']
                AccountDomain      = $data['AccountDomain']
                SessionName        = $data['SessionName']
                ClientName         = $data['ClientName']
                ClientAddress      = $data['ClientAddress']
            }
        }
    }

    try {
        Write-Verbose "Querying $Computer for events $($script:EventIds -join ',') from $StartTime to $EndTime ..."

        $invokeParams = @{
            ScriptBlock  = $queryBlock
            ArgumentList = @(,$script:EventIds), $StartTime, $EndTime
            ErrorAction  = 'Stop'
        }

        if ($IsLocalhost) {
            # Run locally -- no remoting needed
            Write-Verbose "Running in local mode against $Computer"
            $rawEvents = & $queryBlock $script:EventIds $StartTime $EndTime
        }
        else {
            $invokeParams['ComputerName'] = $Computer
            if ($Credential) { $invokeParams['Credential'] = $Credential }

            # Create a job for timeout control
            $job = Invoke-Command @invokeParams -AsJob
            $completed = $job | Wait-Job -Timeout $TimeoutSeconds
            if (-not $completed) {
                $job | Stop-Job
                $job | Remove-Job -Force
                throw "Query timed out after $TimeoutSeconds seconds."
            }
            $rawEvents = $job | Receive-Job
            $job | Remove-Job -Force
        }

        $stopwatch.Stop()

        if ($rawEvents) {
            $result.Events = @($rawEvents)
            $result.EventCount = $result.Events.Count
        }
        $result.QueryStatus = 'Success'
        $result.QueryTime = $stopwatch.Elapsed
        Write-Verbose "$Computer : $($result.EventCount) events retrieved in $($stopwatch.Elapsed.TotalSeconds.ToString('F1'))s"
    }
    catch {
        $stopwatch.Stop()
        $result.Error = $_.Exception.Message
        $result.QueryTime = $stopwatch.Elapsed
        Write-Warning "Failed to query $Computer : $($_.Exception.Message)"
    }

    return $result
}

# ─────────────────────────────────────────────────────────────────────────────
# SESSION CORRELATION
# ─────────────────────────────────────────────────────────────────────────────

function Convert-EventsToSessions {
    <#
    .SYNOPSIS
        Correlates raw security events into user session objects.

    .DESCRIPTION
        Correlation strategy (documented for auditability):

        PRIMARY CORRELATION (High confidence):
          - Match 4624 (logon) → 4634/4647 (logoff) by LogonId.
            LogonId is a per-boot unique hex identifier assigned by LSASS.
            Each logon gets a unique LogonId; logoff events reference the same value.

        SECONDARY CORRELATION (Medium confidence):
          - For 4778/4779 (RDP reconnect/disconnect): these events include a
            LogonId field in newer Windows versions. When present, match directly.
            When absent, correlate by: same user + same workstation + event falls
            within the session time window. Prefer RemoteInteractive (type 10) sessions.

        TERTIARY CORRELATION (Low confidence):
          - For 4800/4801 (lock/unlock): match by SubjectLogonId when available.
            Otherwise, match by same user + nearest active session by time.

        ACTIVE TIME CALCULATION:
          - ActiveTime = SessionDuration - sum(locked intervals)
          - A locked interval = time between a 4800 and the next matching 4801.
          - If a 4800 has no matching 4801, the interval extends to session end.
          - If a 4801 has no preceding 4800, it is noted but not subtracted.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory)]
        [string]$ComputerName,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Events
    )

    if ($Events.Count -eq 0) { return @() }

    # ── Filter out noise accounts ──
    $noiseAccounts = @('SYSTEM', 'LOCAL SERVICE', 'NETWORK SERVICE', 'DWM-1', 'DWM-2',
                       'DWM-3', 'UMFD-0', 'UMFD-1', 'UMFD-2', 'UMFD-3', 'ANONYMOUS LOGON', '$')

    function Test-IsNoiseAccount {
        param([string]$UserName)
        if ([string]::IsNullOrWhiteSpace($UserName)) { return $true }
        if ($UserName.EndsWith('$')) { return $true }
        return ($UserName.ToUpper() -in $noiseAccounts)
    }

    # ── Bucket events by type ──
    $logonEvents     = @($Events | Where-Object { $_.EventId -eq 4624 -and -not (Test-IsNoiseAccount $_.TargetUserName) })
    $logoffEvents    = @($Events | Where-Object { $_.EventId -in @(4634, 4647) })
    $rdpReconnects   = @($Events | Where-Object { $_.EventId -eq 4778 })
    $rdpDisconnects  = @($Events | Where-Object { $_.EventId -eq 4779 })
    $lockEvents      = @($Events | Where-Object { $_.EventId -eq 4800 })
    $unlockEvents    = @($Events | Where-Object { $_.EventId -eq 4801 })

    Write-Verbose "Correlation input: $($logonEvents.Count) logons, $($logoffEvents.Count) logoffs, $($rdpReconnects.Count) RDP reconnects, $($rdpDisconnects.Count) RDP disconnects, $($lockEvents.Count) locks, $($unlockEvents.Count) unlocks"

    # Build lookup: LogonId → logoff event (first logoff per LogonId)
    $logoffByLogonId = @{}
    foreach ($evt in ($logoffEvents | Sort-Object TimeCreated)) {
        $lid = $evt.LogonId
        if ($lid -and -not $logoffByLogonId.ContainsKey($lid)) {
            $logoffByLogonId[$lid] = $evt
        }
    }

    $sessions = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($logon in ($logonEvents | Sort-Object TimeCreated)) {
        $lid = $logon.TargetLogonId ?? $logon.LogonId
        $userName = if ($logon.TargetDomainName -and $logon.TargetDomainName -ne '-') {
            "$($logon.TargetDomainName)\$($logon.TargetUserName)"
        } else { $logon.TargetUserName }

        $logonTypeNum = $logon.LogonType
        $logonTypeName = if ($null -ne $logonTypeNum -and $script:LogonTypeMap.ContainsKey($logonTypeNum)) {
            $script:LogonTypeMap[$logonTypeNum]
        } elseif ($null -ne $logonTypeNum) {
            "Unknown($logonTypeNum)"
        } else { 'Unknown' }

        # ── Find matching logoff (PRIMARY: by LogonId) ──
        $logoff = $null
        $logoffConfidence = 'None'
        if ($lid -and $logoffByLogonId.ContainsKey($lid)) {
            $logoff = $logoffByLogonId[$lid]
            $logoffConfidence = 'High'
        }

        $logoffTime = if ($logoff) { $logoff.TimeCreated } else { $null }
        $logoffType = if ($logoff) {
            switch ($logoff.EventId) { 4634 { 'SessionEnded' } 4647 { 'UserInitiated' } default { 'Unknown' } }
        } else { $null }

        $duration = if ($logoffTime) { $logoffTime - $logon.TimeCreated } else { $null }
        $durationStr = if ($duration) {
            '{0}d {1:D2}h {2:D2}m {3:D2}s' -f $duration.Days, $duration.Hours, $duration.Minutes, $duration.Seconds
        } else { 'Open (no logoff)' }

        # ── Build timeline ──
        $timeline = [System.Collections.Generic.List[PSCustomObject]]::new()

        # Logon event
        $timeline.Add([PSCustomObject]@{
            Time       = $logon.TimeCreated
            EventId    = 4624
            Type       = 'Logon'
            Detail     = "LogonType=$logonTypeName ($logonTypeNum)"
            Confidence = 'High'
        })

        # ── Correlate RDP disconnect/reconnect events ──
        $sessionEnd = if ($logoffTime) { $logoffTime } else { $EndTime }

        foreach ($rdpEvt in $rdpDisconnects) {
            $matched = $false
            $conf = 'Low'

            # Primary: LogonId match
            if ($lid -and ($rdpEvt.LogonId -eq $lid -or $rdpEvt.SubjectLogonId -eq $lid)) {
                $matched = $true; $conf = 'High'
            }
            # Secondary: same user + time window + prefer RDP sessions
            elseif (-not $matched) {
                $rdpUser = if ($rdpEvt.AccountDomain) { "$($rdpEvt.AccountDomain)\$($rdpEvt.AccountName)" }
                           else { $rdpEvt.AccountName ?? $rdpEvt.SubjectUserName }
                if ($rdpUser -eq $userName -and
                    $rdpEvt.TimeCreated -ge $logon.TimeCreated -and
                    $rdpEvt.TimeCreated -le $sessionEnd -and
                    $logonTypeNum -eq 10) {
                    $matched = $true; $conf = 'Medium'
                }
            }

            if ($matched) {
                $timeline.Add([PSCustomObject]@{
                    Time       = $rdpEvt.TimeCreated
                    EventId    = 4779
                    Type       = 'RDP Disconnect'
                    Detail     = "Client=$($rdpEvt.ClientName) Addr=$($rdpEvt.ClientAddress) Session=$($rdpEvt.SessionName)"
                    Confidence = $conf
                })
            }
        }

        foreach ($rdpEvt in $rdpReconnects) {
            $matched = $false
            $conf = 'Low'

            if ($lid -and ($rdpEvt.LogonId -eq $lid -or $rdpEvt.SubjectLogonId -eq $lid)) {
                $matched = $true; $conf = 'High'
            }
            elseif (-not $matched) {
                $rdpUser = if ($rdpEvt.AccountDomain) { "$($rdpEvt.AccountDomain)\$($rdpEvt.AccountName)" }
                           else { $rdpEvt.AccountName ?? $rdpEvt.SubjectUserName }
                if ($rdpUser -eq $userName -and
                    $rdpEvt.TimeCreated -ge $logon.TimeCreated -and
                    $rdpEvt.TimeCreated -le $sessionEnd -and
                    $logonTypeNum -eq 10) {
                    $matched = $true; $conf = 'Medium'
                }
            }

            if ($matched) {
                $timeline.Add([PSCustomObject]@{
                    Time       = $rdpEvt.TimeCreated
                    EventId    = 4778
                    Type       = 'RDP Reconnect'
                    Detail     = "Client=$($rdpEvt.ClientName) Addr=$($rdpEvt.ClientAddress) Session=$($rdpEvt.SessionName)"
                    Confidence = $conf
                })
            }
        }

        # ── Correlate lock/unlock events ──
        $matchedLocks = [System.Collections.Generic.List[PSCustomObject]]::new()
        $matchedUnlocks = [System.Collections.Generic.List[PSCustomObject]]::new()

        foreach ($lockEvt in $lockEvents) {
            $matched = $false
            $conf = 'Low'

            if ($lid -and $lockEvt.SubjectLogonId -eq $lid) {
                $matched = $true; $conf = 'High'
            }
            elseif (-not $matched) {
                $lockUser = if ($lockEvt.SubjectDomainName -and $lockEvt.SubjectDomainName -ne '-') {
                    "$($lockEvt.SubjectDomainName)\$($lockEvt.SubjectUserName)"
                } else { $lockEvt.SubjectUserName }
                if ($lockUser -eq $userName -and
                    $lockEvt.TimeCreated -ge $logon.TimeCreated -and
                    $lockEvt.TimeCreated -le $sessionEnd) {
                    $matched = $true; $conf = 'Medium'
                }
            }

            if ($matched) {
                $matchedLocks.Add($lockEvt)
                $timeline.Add([PSCustomObject]@{
                    Time       = $lockEvt.TimeCreated
                    EventId    = 4800
                    Type       = 'Locked'
                    Detail     = ''
                    Confidence = $conf
                })
            }
        }

        foreach ($unlockEvt in $unlockEvents) {
            $matched = $false
            $conf = 'Low'

            if ($lid -and $unlockEvt.SubjectLogonId -eq $lid) {
                $matched = $true; $conf = 'High'
            }
            elseif (-not $matched) {
                $unlockUser = if ($unlockEvt.SubjectDomainName -and $unlockEvt.SubjectDomainName -ne '-') {
                    "$($unlockEvt.SubjectDomainName)\$($unlockEvt.SubjectUserName)"
                } else { $unlockEvt.SubjectUserName }
                if ($unlockUser -eq $userName -and
                    $unlockEvt.TimeCreated -ge $logon.TimeCreated -and
                    $unlockEvt.TimeCreated -le $sessionEnd) {
                    $matched = $true; $conf = 'Medium'
                }
            }

            if ($matched) {
                $matchedUnlocks.Add($unlockEvt)
                $timeline.Add([PSCustomObject]@{
                    Time       = $unlockEvt.TimeCreated
                    EventId    = 4801
                    Type       = 'Unlocked'
                    Detail     = ''
                    Confidence = $conf
                })
            }
        }

        # Logoff event
        if ($logoff) {
            $timeline.Add([PSCustomObject]@{
                Time       = $logoff.TimeCreated
                EventId    = $logoff.EventId
                Type       = "Logoff ($logoffType)"
                Detail     = ''
                Confidence = $logoffConfidence
            })
        }

        # Sort timeline
        $sortedTimeline = $timeline | Sort-Object Time

        # ── Calculate active time ──
        # Active = total session duration minus time spent locked
        $lockedSeconds = 0.0
        $sortedLocks = $matchedLocks | Sort-Object TimeCreated
        $sortedUnlocks = $matchedUnlocks | Sort-Object TimeCreated
        $unlockQueue = [System.Collections.Generic.Queue[PSCustomObject]]::new()
        foreach ($u in $sortedUnlocks) { $unlockQueue.Enqueue($u) }

        foreach ($lk in $sortedLocks) {
            # Find the next unlock after this lock
            $matchingUnlock = $null
            while ($unlockQueue.Count -gt 0) {
                $candidate = $unlockQueue.Peek()
                if ($candidate.TimeCreated -ge $lk.TimeCreated) {
                    $matchingUnlock = $unlockQueue.Dequeue()
                    break
                }
                $unlockQueue.Dequeue() | Out-Null
            }
            $lockEnd = if ($matchingUnlock) { $matchingUnlock.TimeCreated } else { $sessionEnd }
            $lockedSeconds += ($lockEnd - $lk.TimeCreated).TotalSeconds
        }

        $activeTime = $null
        $activeTimeStr = $null
        if ($duration) {
            $activeSec = [Math]::Max(0, $duration.TotalSeconds - $lockedSeconds)
            $activeTime = [TimeSpan]::FromSeconds($activeSec)
            $activeTimeStr = '{0}d {1:D2}h {2:D2}m {3:D2}s' -f $activeTime.Days, $activeTime.Hours, $activeTime.Minutes, $activeTime.Seconds
        }

        # ── Notes ──
        $notes = [System.Collections.Generic.List[string]]::new()
        if (-not $logoff) { $notes.Add('No logoff event found') }
        if ($matchedLocks.Count -gt 0) { $notes.Add("$($matchedLocks.Count) lock event(s)") }
        $rdpDiscCount = @($sortedTimeline | Where-Object EventId -eq 4779).Count
        if ($rdpDiscCount -gt 0) {
            $notes.Add("RDP disconnected $rdpDiscCount time(s)")
        }

        $session = [PSCustomObject]@{
            PSTypeName        = 'LogonSession'
            ComputerName      = $ComputerName
            User              = $userName
            LogonId           = $lid
            LogonTime         = $logon.TimeCreated
            LogoffTime        = $logoffTime
            SessionDuration   = $duration
            DurationDisplay   = $durationStr
            ActiveTime        = $activeTime
            ActiveTimeDisplay = $activeTimeStr ?? 'N/A'
            LogonType         = $logonTypeName
            LogonTypeId       = $logonTypeNum
            SourceIP          = $logon.IpAddress
            SourceWorkstation = $logon.WorkstationName
            AuthPackage       = $logon.AuthPackage
            ProcessName       = $logon.ProcessName
            LogoffType        = $logoffType
            LogoffConfidence  = $logoffConfidence
            Events            = $sortedTimeline
            LockedSeconds     = $lockedSeconds
            Notes             = ($notes -join '; ')
        }

        $sessions.Add($session)
    }

    Write-Verbose "Correlated $($sessions.Count) sessions for $ComputerName"
    return $sessions.ToArray()
}

# ─────────────────────────────────────────────────────────────────────────────
# HTML REPORT GENERATOR
# ─────────────────────────────────────────────────────────────────────────────

function New-LogonReportHtml {
    <#
    .SYNOPSIS
        Generates a self-contained HTML5 report from WorkstationResult objects.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [object[]]$Results,

        [Parameter(Mandatory)]
        [datetime]$StartTime,

        [Parameter(Mandatory)]
        [datetime]$EndTime,

        [switch]$IncludeFailures
    )

    $totalMachines = @($Results).Count
    $successCount = @($Results | Where-Object QueryStatus -eq 'Success').Count
    $failCount = $totalMachines - $successCount
    $totalSessions = @($Results | ForEach-Object { @($_.Sessions).Count } | Measure-Object -Sum).Sum
    $generatedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss') + ' UTC'

    # ── Helper: HTML-encode ──
    function HEnc([string]$s) { [System.Net.WebUtility]::HtmlEncode($s ?? '') }

    # ── Build machine sections ──
    $machineSectionsHtml = [System.Text.StringBuilder]::new()

    foreach ($r in $Results) {
        if ($r.QueryStatus -ne 'Success' -and -not $IncludeFailures) { continue }

        [void]$machineSectionsHtml.Append(@"
        <div class="machine-section">
            <h2 class="machine-header" onclick="toggleSection(this)">
                <span class="chevron">&#9654;</span>
                $(HEnc $r.ComputerName)
                <span class="badge $(if ($r.QueryStatus -eq 'Success') {'badge-ok'} else {'badge-err'})">$($r.QueryStatus)</span>
                <span class="badge badge-info">$(@($r.Sessions).Count) sessions</span>
                $(if ($r.QueryTime) {"<span class='badge badge-info'>Query: $($r.QueryTime.TotalSeconds.ToString('F1'))s</span>"})
            </h2>
            <div class="machine-body" style="display:none;">
"@)

        if ($r.QueryStatus -ne 'Success') {
            [void]$machineSectionsHtml.Append("<div class='error-box'>Error: $(HEnc $r.Error)</div>")
        }

        if (@($r.Sessions).Count -gt 0) {
            [void]$machineSectionsHtml.Append(@"
                <div class="table-controls">
                    <input type="text" class="search-box" placeholder="Filter sessions..." onkeyup="filterTable(this)">
                </div>
                <table class="session-table sortable">
                    <thead>
                        <tr>
                            <th data-sort="string" onclick="sortTable(this)">User &#x25B4;&#x25BE;</th>
                            <th data-sort="date" onclick="sortTable(this)">Logon Time &#x25B4;&#x25BE;</th>
                            <th data-sort="date" onclick="sortTable(this)">Logoff Time &#x25B4;&#x25BE;</th>
                            <th data-sort="number" onclick="sortTable(this)">Duration &#x25B4;&#x25BE;</th>
                            <th data-sort="number" onclick="sortTable(this)">Active Time &#x25B4;&#x25BE;</th>
                            <th data-sort="string" onclick="sortTable(this)">Type &#x25B4;&#x25BE;</th>
                            <th data-sort="string" onclick="sortTable(this)">Source IP &#x25B4;&#x25BE;</th>
                            <th data-sort="string" onclick="sortTable(this)">Workstation &#x25B4;&#x25BE;</th>
                            <th>Notes</th>
                            <th>Details</th>
                        </tr>
                    </thead>
                    <tbody>
"@)

            $rowIdx = 0
            foreach ($s in ($r.Sessions | Sort-Object LogonTime -Descending)) {
                $rowClass = if ($rowIdx % 2 -eq 0) { 'row-even' } else { 'row-odd' }
                $logonTimeStr = if ($s.LogonTime) { $s.LogonTime.ToString('yyyy-MM-dd HH:mm:ss') } else { '-' }
                $logoffTimeStr = if ($s.LogoffTime) { $s.LogoffTime.ToString('yyyy-MM-dd HH:mm:ss') } else { '-' }
                $durationSec = if ($s.SessionDuration) { [int]$s.SessionDuration.TotalSeconds } else { 0 }
                $activeSec = if ($s.ActiveTime) { [int]$s.ActiveTime.TotalSeconds } else { 0 }
                $detailId = "detail-$($r.ComputerName)-$rowIdx" -replace '[^a-zA-Z0-9_-]', '_'

                [void]$machineSectionsHtml.Append(@"
                        <tr class="$rowClass">
                            <td>$(HEnc $s.User)</td>
                            <td data-value="$logonTimeStr">$logonTimeStr</td>
                            <td data-value="$logoffTimeStr">$logoffTimeStr</td>
                            <td data-value="$durationSec">$(HEnc $s.DurationDisplay)</td>
                            <td data-value="$activeSec">$(HEnc $s.ActiveTimeDisplay)</td>
                            <td>$(HEnc $s.LogonType)</td>
                            <td>$(HEnc ($s.SourceIP ?? '-'))</td>
                            <td>$(HEnc ($s.SourceWorkstation ?? '-'))</td>
                            <td class="notes-cell">$(HEnc ($s.Notes ?? ''))</td>
                            <td><button class="btn-detail" onclick="toggleDetail('$detailId')">Timeline</button></td>
                        </tr>
                        <tr id="$detailId" class="detail-row" style="display:none;">
                            <td colspan="10">
                                <div class="timeline-box">
                                    <div class="timeline-meta">
                                        LogonId: <code>$(HEnc ($s.LogonId ?? 'N/A'))</code> |
                                        Auth: <code>$(HEnc ($s.AuthPackage ?? 'N/A'))</code> |
                                        Process: <code>$(HEnc ($s.ProcessName ?? 'N/A'))</code> |
                                        Locked: $([Math]::Round($s.LockedSeconds / 60, 1)) min
                                    </div>
                                    <table class="timeline-table">
                                        <thead><tr><th>Time (UTC)</th><th>Event</th><th>Detail</th><th>Confidence</th></tr></thead>
                                        <tbody>
"@)

                foreach ($te in $s.Events) {
                    $confClass = switch ($te.Confidence) { 'High' { 'conf-high' } 'Medium' { 'conf-med' } default { 'conf-low' } }
                    [void]$machineSectionsHtml.Append(@"
                                            <tr>
                                                <td>$($te.Time.ToString('yyyy-MM-dd HH:mm:ss'))</td>
                                                <td><span class="evt-badge evt-$($te.EventId)">$($te.EventId)</span> $(HEnc $te.Type)</td>
                                                <td>$(HEnc $te.Detail)</td>
                                                <td><span class="$confClass">$(HEnc $te.Confidence)</span></td>
                                            </tr>
"@)
                }

                [void]$machineSectionsHtml.Append(@"
                                        </tbody>
                                    </table>
                                </div>
                            </td>
                        </tr>
"@)
                $rowIdx++
            }

            [void]$machineSectionsHtml.Append("</tbody></table>")
        }
        else {
            [void]$machineSectionsHtml.Append("<p class='no-data'>No sessions found for this machine in the query window.</p>")
        }

        [void]$machineSectionsHtml.Append("</div></div>")
    }

    # ── Assemble full HTML ──
    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Windows Logon Session Report</title>
<style>
    :root {
        --bg: #0f172a; --surface: #1e293b; --surface2: #334155;
        --border: #475569; --text: #e2e8f0; --text-muted: #94a3b8;
        --accent: #38bdf8; --accent-hover: #7dd3fc; --green: #4ade80;
        --red: #f87171; --yellow: #fbbf24; --purple: #c084fc;
    }
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
        font-family: 'Segoe UI', system-ui, -apple-system, sans-serif;
        background: var(--bg); color: var(--text); line-height: 1.6;
        padding: 2rem; max-width: 1600px; margin: 0 auto;
    }
    h1 { font-size: 1.75rem; font-weight: 700; margin-bottom: 0.5rem; color: var(--accent); }
    .report-meta { color: var(--text-muted); font-size: 0.85rem; margin-bottom: 2rem; }
    .summary-grid {
        display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
        gap: 1rem; margin-bottom: 2rem;
    }
    .summary-card {
        background: var(--surface); border: 1px solid var(--border); border-radius: 8px;
        padding: 1.25rem; text-align: center;
    }
    .summary-card .value { font-size: 2rem; font-weight: 700; color: var(--accent); }
    .summary-card .label { font-size: 0.8rem; color: var(--text-muted); text-transform: uppercase; letter-spacing: 0.05em; }
    .machine-section {
        background: var(--surface); border: 1px solid var(--border); border-radius: 8px;
        margin-bottom: 1rem; overflow: hidden;
    }
    .machine-header {
        padding: 1rem 1.25rem; cursor: pointer; font-size: 1.1rem; font-weight: 600;
        display: flex; align-items: center; gap: 0.75rem; user-select: none;
        transition: background 0.15s;
    }
    .machine-header:hover { background: var(--surface2); }
    .chevron { transition: transform 0.2s; font-size: 0.75rem; }
    .machine-header.open .chevron { transform: rotate(90deg); }
    .machine-body { padding: 0 1.25rem 1.25rem; }
    .badge {
        font-size: 0.7rem; padding: 0.2rem 0.6rem; border-radius: 9999px;
        font-weight: 600; text-transform: uppercase; letter-spacing: 0.03em;
    }
    .badge-ok { background: rgba(74,222,128,0.15); color: var(--green); }
    .badge-err { background: rgba(248,113,113,0.15); color: var(--red); }
    .badge-info { background: rgba(56,189,248,0.12); color: var(--accent); }
    .error-box {
        background: rgba(248,113,113,0.1); border: 1px solid var(--red);
        border-radius: 6px; padding: 0.75rem 1rem; margin-bottom: 1rem;
        color: var(--red); font-size: 0.85rem;
    }
    .table-controls { margin-bottom: 0.75rem; }
    .search-box {
        background: var(--bg); color: var(--text); border: 1px solid var(--border);
        border-radius: 6px; padding: 0.5rem 0.75rem; font-size: 0.85rem; width: 300px;
    }
    .search-box:focus { outline: none; border-color: var(--accent); }
    .session-table {
        width: 100%; border-collapse: collapse; font-size: 0.82rem;
    }
    .session-table th {
        background: var(--bg); padding: 0.6rem 0.75rem; text-align: left;
        font-weight: 600; border-bottom: 2px solid var(--border); cursor: pointer;
        white-space: nowrap; position: sticky; top: 0; user-select: none;
    }
    .session-table th:hover { color: var(--accent); }
    .session-table td {
        padding: 0.5rem 0.75rem; border-bottom: 1px solid rgba(71,85,105,0.4);
        white-space: nowrap;
    }
    .row-even { background: transparent; }
    .row-odd { background: rgba(255,255,255,0.02); }
    .session-table tr:hover { background: rgba(56,189,248,0.06); }
    .notes-cell { max-width: 250px; white-space: normal; font-size: 0.78rem; color: var(--text-muted); }
    .btn-detail {
        background: transparent; color: var(--accent); border: 1px solid var(--accent);
        border-radius: 4px; padding: 0.2rem 0.6rem; cursor: pointer; font-size: 0.75rem;
        transition: all 0.15s;
    }
    .btn-detail:hover { background: var(--accent); color: var(--bg); }
    .detail-row td { padding: 0 !important; }
    .timeline-box {
        background: var(--bg); padding: 1rem; border-top: 1px solid var(--border);
    }
    .timeline-meta {
        font-size: 0.78rem; color: var(--text-muted); margin-bottom: 0.75rem;
    }
    .timeline-meta code {
        background: var(--surface2); padding: 0.1rem 0.4rem; border-radius: 3px;
        font-size: 0.76rem;
    }
    .timeline-table {
        width: 100%; border-collapse: collapse; font-size: 0.78rem;
    }
    .timeline-table th {
        background: var(--surface2); padding: 0.4rem 0.6rem; text-align: left;
        font-weight: 600;
    }
    .timeline-table td { padding: 0.35rem 0.6rem; border-bottom: 1px solid rgba(71,85,105,0.3); }
    .evt-badge {
        display: inline-block; padding: 0.1rem 0.4rem; border-radius: 3px;
        font-size: 0.7rem; font-weight: 700; margin-right: 0.3rem;
    }
    .evt-4624 { background: rgba(74,222,128,0.2); color: var(--green); }
    .evt-4634, .evt-4647 { background: rgba(248,113,113,0.2); color: var(--red); }
    .evt-4778 { background: rgba(56,189,248,0.2); color: var(--accent); }
    .evt-4779 { background: rgba(251,191,36,0.2); color: var(--yellow); }
    .evt-4800 { background: rgba(192,132,252,0.2); color: var(--purple); }
    .evt-4801 { background: rgba(192,132,252,0.15); color: var(--purple); }
    .conf-high { color: var(--green); font-weight: 600; }
    .conf-med { color: var(--yellow); }
    .conf-low { color: var(--red); font-style: italic; }
    .no-data { color: var(--text-muted); font-style: italic; padding: 1rem 0; }
    footer {
        margin-top: 3rem; padding-top: 1rem; border-top: 1px solid var(--border);
        color: var(--text-muted); font-size: 0.75rem; text-align: center;
    }
    @media (max-width: 1024px) {
        body { padding: 1rem; }
        .session-table { font-size: 0.75rem; }
        .session-table td, .session-table th { padding: 0.4rem; }
    }
</style>
</head>
<body>

<h1>Windows Logon Session Report</h1>
<div class="report-meta">
    Generated: $generatedAt |
    Query window: $($StartTime.ToString('yyyy-MM-dd HH:mm')) &ndash; $($EndTime.ToString('yyyy-MM-dd HH:mm')) UTC
</div>

<div class="summary-grid">
    <div class="summary-card"><div class="value">$totalMachines</div><div class="label">Machines Queried</div></div>
    <div class="summary-card"><div class="value" style="color:var(--green);">$successCount</div><div class="label">Successful</div></div>
    <div class="summary-card"><div class="value" style="color:var(--red);">$failCount</div><div class="label">Failed</div></div>
    <div class="summary-card"><div class="value">$totalSessions</div><div class="label">Total Sessions</div></div>
</div>

$($machineSectionsHtml.ToString())

<footer>
    Windows Logon Session Report &bull; Generated by Get-LogonSessionReport.ps1 &bull; All times in UTC
</footer>

<script>
function toggleSection(el) {
    el.classList.toggle('open');
    const body = el.nextElementSibling;
    body.style.display = body.style.display === 'none' ? 'block' : 'none';
}

function toggleDetail(id) {
    const row = document.getElementById(id);
    if (row) row.style.display = row.style.display === 'none' ? 'table-row' : 'none';
}

function filterTable(input) {
    const filter = input.value.toLowerCase();
    const table = input.closest('.machine-body').querySelector('.session-table');
    if (!table) return;
    const rows = table.querySelectorAll('tbody > tr:not(.detail-row)');
    rows.forEach(row => {
        const text = row.textContent.toLowerCase();
        const show = text.includes(filter);
        row.style.display = show ? '' : 'none';
        // Also hide the detail row if filtering hides the parent
        const next = row.nextElementSibling;
        if (next && next.classList.contains('detail-row') && !show) {
            next.style.display = 'none';
        }
    });
}

function sortTable(th) {
    const table = th.closest('table');
    const tbody = table.querySelector('tbody');
    const colIdx = Array.from(th.parentNode.children).indexOf(th);
    const sortType = th.dataset.sort || 'string';
    const dir = th.dataset.dir === 'asc' ? 'desc' : 'asc';
    th.dataset.dir = dir;

    // Collect data rows (skip detail rows)
    const pairs = [];
    const rows = Array.from(tbody.children);
    for (let i = 0; i < rows.length; i++) {
        if (!rows[i].classList.contains('detail-row')) {
            pairs.push({ data: rows[i], detail: rows[i + 1]?.classList.contains('detail-row') ? rows[i + 1] : null });
            if (rows[i + 1]?.classList.contains('detail-row')) i++;
        }
    }

    pairs.sort((a, b) => {
        const cellA = a.data.children[colIdx];
        const cellB = b.data.children[colIdx];
        let valA = cellA.dataset.value || cellA.textContent.trim();
        let valB = cellB.dataset.value || cellB.textContent.trim();
        let cmp = 0;
        if (sortType === 'number') { cmp = (parseFloat(valA) || 0) - (parseFloat(valB) || 0); }
        else if (sortType === 'date') { cmp = (new Date(valA) || 0) - (new Date(valB) || 0); }
        else { cmp = valA.localeCompare(valB); }
        return dir === 'asc' ? cmp : -cmp;
    });

    pairs.forEach(p => {
        tbody.appendChild(p.data);
        if (p.detail) tbody.appendChild(p.detail);
    });
}

// Auto-expand first machine section if only one
document.addEventListener('DOMContentLoaded', () => {
    const headers = document.querySelectorAll('.machine-header');
    if (headers.length === 1) headers[0].click();
});
</script>

</body>
</html>
"@

    return $html
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN ORCHESTRATOR
# ─────────────────────────────────────────────────────────────────────────────

# Handle credential-only operations first
if ($SaveCredential) {
    Save-StoredCredential
    return
}

if ($ClearCredential) {
    Clear-StoredCredential
    return
}

# ── Resolve credential ──
$effectiveCred = $null
if ($UseStoredCredential) {
    $effectiveCred = Get-StoredCredential
    if (-not $effectiveCred) {
        Write-Error "No stored credential available. Use -SaveCredential first."
        return
    }
}
elseif ($Credential) {
    $effectiveCred = $Credential
}

# ── Resolve target computers ──
$targets = [System.Collections.Generic.List[string]]::new()

if ($TestMode) {
    $targets.Add($env:COMPUTERNAME ?? 'localhost')
    Write-Verbose "Test mode: targeting local machine ($($targets[0]))"
}
else {
    if ($ComputerName) {
        foreach ($c in $ComputerName) {
            # Handle CSV-style input ("WS01,WS02,WS03")
            foreach ($name in ($c -split ',')) {
                $trimmed = $name.Trim()
                if ($trimmed) { $targets.Add($trimmed) }
            }
        }
    }

    if ($ComputerListPath) {
        $lines = Get-Content $ComputerListPath | ForEach-Object { $_.Trim() } |
                 Where-Object { $_ -and -not $_.StartsWith('#') }
        foreach ($line in $lines) { $targets.Add($line) }
    }
}

if ($targets.Count -eq 0) {
    Write-Error "No target computers specified. Use -ComputerName, -ComputerListPath, or -TestMode."
    return
}

$uniqueTargets = @($targets | Select-Object -Unique)
Write-Verbose "Targets resolved: $($uniqueTargets -join ', ')"

# ── Ensure output directory exists ──
if (-not (Test-Path $OutputPath)) {
    New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
}

# ── Normalize times to UTC ──
# All event comparisons and display use UTC to avoid time-skew issues
# between machines in different time zones.
if ($StartTime.Kind -ne [System.DateTimeKind]::Utc) {
    $StartTime = $StartTime.ToUniversalTime()
}
if ($EndTime.Kind -ne [System.DateTimeKind]::Utc) {
    $EndTime = $EndTime.ToUniversalTime()
}
Write-Verbose "Query window (UTC): $($StartTime.ToString('yyyy-MM-dd HH:mm:ss')) to $($EndTime.ToString('yyyy-MM-dd HH:mm:ss'))"

# ── Query each machine ──
$allResults = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($target in $uniqueTargets) {
    Write-Verbose "Processing: $target"

    $queryParams = @{
        Computer       = $target
        StartTime      = $StartTime
        EndTime        = $EndTime
        TimeoutSeconds = $TimeoutSeconds
    }

    if ($TestMode -or $target -eq $env:COMPUTERNAME -or $target -eq 'localhost') {
        $queryParams['IsLocalhost'] = $true
    }
    elseif ($effectiveCred) {
        $queryParams['Credential'] = $effectiveCred
    }

    $queryResult = Get-RemoteSecurityEvents @queryParams

    # Correlate events into sessions
    if ($queryResult.QueryStatus -eq 'Success' -and $queryResult.Events.Count -gt 0) {
        $sessions = Convert-EventsToSessions -ComputerName $target -Events $queryResult.Events
    }
    else {
        $sessions = @()
    }

    $workstationResult = [PSCustomObject]@{
        PSTypeName   = 'WorkstationResult'
        ComputerName = $target
        QueryStatus  = $queryResult.QueryStatus
        Error        = $queryResult.Error
        EventCount   = $queryResult.EventCount
        QueryTime    = $queryResult.QueryTime
        Sessions     = $sessions
    }

    $allResults.Add($workstationResult)
}

# ── Generate outputs ──
$basePath = Join-Path $OutputPath $ReportName

# HTML Report
Write-Verbose "Generating HTML report..."
$html = New-LogonReportHtml -Results $allResults -StartTime $StartTime -EndTime $EndTime -IncludeFailures:$IncludeFailuresInReport
$htmlPath = "$basePath.html"
$html | Out-File -FilePath $htmlPath -Encoding utf8 -Force
Write-Host "HTML report saved: $htmlPath" -ForegroundColor Green

# Optional JSON export
if ($ExportJson) {
    $jsonPath = "$basePath.json"
    $allResults | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonPath -Encoding utf8 -Force
    Write-Host "JSON export saved: $jsonPath" -ForegroundColor Green
}

# Optional CSV export (flattened sessions)
if ($ExportCsv) {
    $csvPath = "$basePath.csv"
    $csvData = foreach ($r in $allResults) {
        foreach ($s in $r.Sessions) {
            [PSCustomObject]@{
                ComputerName      = $s.ComputerName
                User              = $s.User
                LogonId           = $s.LogonId
                LogonTime         = $s.LogonTime
                LogoffTime        = $s.LogoffTime
                DurationDisplay   = $s.DurationDisplay
                ActiveTimeDisplay = $s.ActiveTimeDisplay
                LogonType         = $s.LogonType
                SourceIP          = $s.SourceIP
                SourceWorkstation = $s.SourceWorkstation
                AuthPackage       = $s.AuthPackage
                LogoffType        = $s.LogoffType
                LogoffConfidence  = $s.LogoffConfidence
                LockedMinutes     = [Math]::Round($s.LockedSeconds / 60, 1)
                Notes             = $s.Notes
            }
        }
    }
    $csvData | Export-Csv -Path $csvPath -NoTypeInformation -Encoding utf8
    Write-Host "CSV export saved: $csvPath" -ForegroundColor Green
}

# ── Summary to console ──
Write-Host ""
Write-Host "══════════════════════════════════════════════" -ForegroundColor DarkCyan
Write-Host " Logon Session Report Summary" -ForegroundColor Cyan
Write-Host "══════════════════════════════════════════════" -ForegroundColor DarkCyan
Write-Host " Machines queried : $($uniqueTargets.Count)" -ForegroundColor White
Write-Host " Successful       : $(@($allResults | Where-Object QueryStatus -eq 'Success').Count)" -ForegroundColor Green
Write-Host " Failed           : $(@($allResults | Where-Object QueryStatus -ne 'Success').Count)" -ForegroundColor $(if (@($allResults | Where-Object QueryStatus -ne 'Success').Count -gt 0) {'Red'} else {'White'})
Write-Host " Total sessions   : $(@($allResults | ForEach-Object { @($_.Sessions).Count } | Measure-Object -Sum).Sum)" -ForegroundColor White
Write-Host " Query window     : $($StartTime.ToString('yyyy-MM-dd HH:mm')) to $($EndTime.ToString('yyyy-MM-dd HH:mm')) UTC" -ForegroundColor White
Write-Host "══════════════════════════════════════════════" -ForegroundColor DarkCyan

foreach ($r in $allResults) {
    $icon = if ($r.QueryStatus -eq 'Success') { '[OK]' } else { '[FAIL]' }
    $color = if ($r.QueryStatus -eq 'Success') { 'Green' } else { 'Red' }
    $detail = if ($r.QueryStatus -eq 'Success') { "$(@($r.Sessions).Count) sessions ($($r.EventCount) events)" } else { $r.Error }
    Write-Host "  $icon $($r.ComputerName): $detail" -ForegroundColor $color
}

Write-Host ""

# ── Return structured results for pipeline use ──
return $allResults
