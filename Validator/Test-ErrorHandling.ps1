#Requires -Version 5.1
<#
.SYNOPSIS
    Tests error-handling scenarios in Validate-VeeamBackupChains.ps1 without a Veeam installation.

.DESCRIPTION
    Each test invokes the script in a child pwsh process, captures stdout/stderr and any
    written log file, then asserts the expected exit code and log message pattern.

    Exit code conventions (from the script under test):
      0 = success (all backups valid)
      1 = script/configuration error
      2 = no backup jobs found
      3 = one or more backup validation failures
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest

$ScriptUnderTest = Join-Path $PSScriptRoot 'Validate-VeeamBackupChains.ps1'
$TempBase        = Join-Path $env:TEMP "VeeamErrTest_$(Get-Date -Format 'yyyyMMddHHmmss')"
# notepad.exe exists on every Windows system; passes the file-existence check in Test-ValidatorExecutable
$FakeValidatorExe = "$env:SystemRoot\System32\notepad.exe"

New-Item $TempBase -ItemType Directory -Force | Out-Null
$EmptyDatastore = Join-Path $TempBase 'EmptyDatastore'
New-Item $EmptyDatastore -ItemType Directory -Force | Out-Null

# ── helpers ────────────────────────────────────────────────────────────────────

$PassCount = 0
$FailCount = 0

function Invoke-ScriptTest {
    param(
        [string]   $Name,
        [hashtable]$Params,          # key=param name, value=string or $true for switches
        [int]      $ExpectedExit,
        [string]   $LogPattern = $null  # regex matched against combined stdout+stderr+log file
    )

    $slug     = $Name -replace '\W', '_'
    $outFile  = Join-Path $TempBase "stdout_$slug.txt"
    $errFile  = Join-Path $TempBase "stderr_$slug.txt"
    $rptPath  = $Params['ReportPath']

    # Build a single quoted argument string so paths with spaces survive Start-Process
    $parts = @("-NoProfile", "-NonInteractive", "-File", "`"$ScriptUnderTest`"")
    foreach ($k in $Params.Keys) {
        $v = $Params[$k]
        if ($v -is [bool] -and $v) { $parts += "-$k" }
        else                       { $parts += "-$k `"$v`"" }
    }
    $argString = $parts -join ' '

    $proc = Start-Process pwsh -ArgumentList $argString -NoNewWindow -Wait -PassThru `
                -RedirectStandardOutput $outFile -RedirectStandardError $errFile

    $exitCode = $proc.ExitCode
    $stdout   = Get-Content $outFile -Raw -ErrorAction SilentlyContinue
    $stderr   = Get-Content $errFile -Raw -ErrorAction SilentlyContinue

    # Read any .log file written into the report directory
    $logText = $null
    if ($rptPath -and (Test-Path $rptPath)) {
        $logFile = Get-ChildItem $rptPath -Filter '*.log' -ErrorAction SilentlyContinue |
                   Select-Object -First 1
        if ($logFile) { $logText = Get-Content $logFile.FullName -Raw -ErrorAction SilentlyContinue }
    }

    $allOutput = (@($stdout, $stderr, $logText) | Where-Object { $_ }) -join "`n"

    $exitOk    = $exitCode -eq $ExpectedExit
    $patternOk = -not $LogPattern -or ($allOutput -match $LogPattern)
    $pass      = $exitOk -and $patternOk

    $color  = if ($pass) { 'Green' } else { 'Red' }
    $status = if ($pass) { 'PASS'  } else { 'FAIL' }

    Write-Host ("  [{0}] {1}" -f $status, $Name) -ForegroundColor $color
    $exitColor = if ($exitOk) { 'DarkGray' } else { 'Red' }
    Write-Host ("        exit: {0}  (expected {1})" -f $exitCode, $ExpectedExit) -ForegroundColor $exitColor

    if ($LogPattern) {
        $pc          = if ($patternOk) { 'DarkGray' } else { 'Red' }
        $matchStatus = if ($patternOk) { 'matched'  } else { 'NOT MATCHED' }
        Write-Host ("        pattern '{0}': {1}" -f $LogPattern, $matchStatus) -ForegroundColor $pc
    }

    if (-not $pass -and $allOutput.Trim()) {
        $snippet = ($allOutput.Trim() -replace '\r?\n', ' | ').Substring(0, [Math]::Min(300, $allOutput.Length))
        Write-Host "        output  : $snippet" -ForegroundColor Yellow
    }

    if ($pass) { $script:PassCount++ } else { $script:FailCount++ }
}

# ── tests ──────────────────────────────────────────────────────────────────────

Write-Host ''
Write-Host '════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host '  Validate-VeeamBackupChains — Error Handling   ' -ForegroundColor Cyan
Write-Host '════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host ''

# T1 ── Validator executable not found → Initialize-Environment succeeds,
#        Test-ValidatorExecutable fails → exit 1
Invoke-ScriptTest -Name 'T1: Validator executable not found' `
    -Params @{
        ValidatorPath  = 'C:\NoSuchFolder\Veeam.Backup.Validator.exe'
        DatastorePath  = $EmptyDatastore
        ReportPath     = (Join-Path $TempBase 'rpt_t1')
    } `
    -ExpectedExit 1 `
    -LogPattern   'Cannot proceed|not found'

# T2 ── DatastorePath does not exist → exit 1
#        Uses notepad.exe as a stand-in to pass the validator check
Invoke-ScriptTest -Name 'T2: Datastore path does not exist' `
    -Params @{
        ValidatorPath  = $FakeValidatorExe
        DatastorePath  = "C:\NoSuchDatastore_$(Get-Random)"
        ReportPath     = (Join-Path $TempBase 'rpt_t2')
    } `
    -ExpectedExit 1 `
    -LogPattern   'Datastore path not found'

# T3 ── Valid but empty datastore → no .vbm/.vbk files → exit 2
Invoke-ScriptTest -Name 'T3: No backup jobs found (empty datastore)' `
    -Params @{
        ValidatorPath  = $FakeValidatorExe
        DatastorePath  = $EmptyDatastore
        ReportPath     = (Join-Path $TempBase 'rpt_t3')
    } `
    -ExpectedExit 2 `
    -LogPattern   'No Veeam backup jobs'

# T4 ── Report directory doesn't exist yet; Initialize-Environment must create it
#        and write the log there (validates deferred $Script:LogFile assignment)
$freshReportDir = Join-Path $TempBase 'rpt_t4_new'
# Deliberately do NOT pre-create this directory
Invoke-ScriptTest -Name 'T4: New report dir auto-created, log file written' `
    -Params @{
        ValidatorPath  = $FakeValidatorExe
        DatastorePath  = $EmptyDatastore
        ReportPath     = $freshReportDir
    } `
    -ExpectedExit 2 `
    -LogPattern   'Veeam Backup Chain Validation Started'

# T5 ── Find-VeeamBackupJobs path guard: pass an empty -DatastorePath
#        The script will call Read-Host in interactive mode, so we pipe a blank
#        line to stdin and rely on the subsequent path-not-found guard → exit 1
Invoke-ScriptTest -Name 'T5: Empty DatastorePath rejected by path guard' `
    -Params @{
        ValidatorPath  = $FakeValidatorExe
        DatastorePath  = ' '    # single space → IsNullOrWhiteSpace guard fires
        ReportPath     = (Join-Path $TempBase 'rpt_t5')
    } `
    -ExpectedExit 1 `
    -LogPattern   'not found|Invalid|inaccessible'

# T7 ── Datastore contains a .vbm file but no .vbk/.vib files
#        Get-ChildItem returns $null (not @()) for empty results; previously caused
#        "The property 'Count' cannot be found" under Set-StrictMode -Version Latest
#        Uses a .cmd stub as the validator so the process exits immediately (notepad hangs).
$datastoreWithVbm = Join-Path $TempBase 'DatastoreWithVbm'
New-Item $datastoreWithVbm -ItemType Directory -Force | Out-Null
New-Item (Join-Path $datastoreWithVbm 'BackupJob.vbm') -ItemType File -Force | Out-Null  # no .vbk or .vib

# where.exe: always present on Windows, exits immediately with code 1 when given
# unrecognised arguments — safe for -NoNewWindow -RedirectStandardOutput, no GUI.
# Expected exit 3: script reaches Validation complete (bug fix confirmed) but
# where.exe returns non-zero, so the job is counted as a validation failure.
# WITHOUT the @() fix, Get-ChildItem returns $null and $null.Count throws under
# StrictMode, the outer catch fires, and the script exits 1 instead.
$whereExe = Join-Path $env:SystemRoot 'System32\where.exe'

Invoke-ScriptTest -Name 'T7: .vbm present but no .vbk/.vib (StrictMode .Count regression)' `
    -Params @{
        ValidatorPath  = $whereExe
        DatastorePath  = $datastoreWithVbm
        ReportPath     = (Join-Path $TempBase 'rpt_t7')
    } `
    -ExpectedExit 3 `
    -LogPattern   'Validation complete'

# T6 ── Verify log is absent / $Script:LogFile=$null before Initialize-Environment,
#        meaning no crash under Set-StrictMode -Version Latest at startup.
#        If the script crashes on startup, it produces a ParseError on stderr → FAIL.
Write-Host ''
Write-Host '  [INFO] T6: StrictMode startup check (no $Script:ReportPath crash)' -ForegroundColor Cyan
$outT6  = Join-Path $TempBase 'stdout_T6.txt'
$errT6  = Join-Path $TempBase 'stderr_T6.txt'
$argsT6 = "-NoProfile -NonInteractive -File `"$ScriptUnderTest`" -ValidatorPath `"C:\Fake.exe`" -DatastorePath `"$EmptyDatastore`" -ReportPath `"$(Join-Path $TempBase 'rpt_t6')`""
$procT6 = Start-Process pwsh -ArgumentList $argsT6 -NoNewWindow -Wait -PassThru `
              -RedirectStandardOutput $outT6 -RedirectStandardError $errT6
$stderrT6 = Get-Content $errT6 -Raw -ErrorAction SilentlyContinue
$strictModeError = $stderrT6 -match 'StrictMode|Variable.*not set|\$Script:ReportPath'
if (-not $strictModeError) {
    Write-Host '        [PASS] No StrictMode/undefined-variable errors on startup' -ForegroundColor Green
    $script:PassCount++
} else {
    Write-Host '        [FAIL] StrictMode error detected on startup' -ForegroundColor Red
    Write-Host "        Stderr: $stderrT6" -ForegroundColor Yellow
    $script:FailCount++
}

# ── summary ────────────────────────────────────────────────────────────────────

$total = $PassCount + $FailCount
Write-Host ''
$summaryColor = if ($FailCount -eq 0) { 'Green' } else { 'Yellow' }
Write-Host ('  Results: {0}/{1} passed' -f $PassCount, $total) -ForegroundColor $summaryColor
Write-Host ''

# Cleanup
Remove-Item $TempBase -Recurse -Force -ErrorAction SilentlyContinue

if ($FailCount -gt 0) { exit 1 } else { exit 0 }
