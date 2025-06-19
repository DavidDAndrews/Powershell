# =====================
# All Function Definitions (move to very top)
# =====================
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('CRITICAL','FAILURE','WARNING','INFORMATIONAL','ALL')][string]$Level = 'INFORMATIONAL'
    )
    # Append green checkmark if message contains 'succeeded' or 'successfully'
    if ($Message -match '(?i)\bsucceeded\b|\bsuccessfully\b') {
        $Message += ' ✅'
    }
    $entry = [PSCustomObject]@{
        Timestamp = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')
        Level = $Level
        Message = $Message
    }
    $script:LogBuffer += $entry
    $script:HtmlLogBuffer += $entry
    
    # Throttled HTML update - only update every 500ms to prevent excessive I/O
    $now = Get-Date
    if (-not $script:LastHtmlUpdate) { 
        $script:LastHtmlUpdate = $now.AddSeconds(-1) 
    }
    
    $timeSinceLastUpdate = ($now - $script:LastHtmlUpdate).TotalMilliseconds
    $shouldUpdate = ($timeSinceLastUpdate -gt 500) -or ($Level -in @('CRITICAL', 'FAILURE'))
    
    if ($script:LogFilePath -and $script:HtmlLogBuffer.Count -gt 0 -and $shouldUpdate) {
        Update-HTMLLog
        $script:LastHtmlUpdate = $now
    }
    
    # No console output for any log level
    # (All logs go to HTML only)
}
function Update-HTMLLog {
    # Quick HTML log update
    if (-not $script:LogFilePath) { return }
    
    try {
        $logEntries = $script:HtmlLogBuffer
        $sessionTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
        $lastUpdate = Get-Date -Format "HH:mm:ss"
        
        # Generate just the log entries HTML
        $logEntriesHtml = ""
        $entryNumber = 1
        foreach ($entry in $logEntries) {
            $levelClass = switch ($entry.Level) {
                'CRITICAL' { 'error' }
                'FAILURE' { 'warning' }
                'WARNING' { 'warning' }
                'INFORMATIONAL' { 'info' }
                default { 'info' }
            }
            $logEntriesHtml += "<div class='log-entry $levelClass'><span class='log-number' style='font-weight:bold;color:#6366F1;margin-right:10px;'>$entryNumber.</span><span class='timestamp'>$($entry.Timestamp)</span><span class='message'>$($entry.Message)</span></div>"
            $entryNumber++
        }
        
        # Create complete HTML with auto-refresh
        $html = @"
<!DOCTYPE html>
<html lang='en'>
<head>
    <meta charset='UTF-8'>
    <meta name='viewport' content='width=device-width, initial-scale=1.0'>
    <title>VeeamItUp+ Activity Log</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); min-height: 100vh; padding: 20px; }
        .container { max-width: 80vw; width: 80vw; margin: 0 auto; background: white; border-radius: 15px; box-shadow: 0 4px 20px rgba(0,0,0,0.1); overflow: hidden; }
        .header { background: linear-gradient(135deg, #2c3e50 0%, #34495e 100%); color: white; padding: 30px; text-align: center; }
        .header h1 { font-size: 2.5em; margin-bottom: 10px; font-weight: 300; }
        .status-bar { background: #F8F9FA; padding: 15px 30px; border-bottom: 1px solid #E9ECEF; display: flex; justify-content: space-between; align-items: center; }
        .log-container { padding: 30px; max-height: 70vh; overflow-y: auto; }
        .log-entry { padding: 12px 20px; margin-bottom: 8px; border-radius: 8px; background: #F9FAFB; border-left: 4px solid #E5E7EB; animation: slideIn 0.3s ease; }
        .log-entry.info { border-left-color: #3B82F6; }
        .log-entry.success { border-left-color: #10B981; }
        .log-entry.warning { border-left-color: #F59E0B; }
        .log-entry.error { border-left-color: #EF4444; }
        .log-entry.menu { border-left-color: #8B5CF6; background: #F3F4F6; }
        .log-entry.input { border-left-color: #06B6D4; background: #ECFEFF; }
        .timestamp { font-family: 'Consolas', monospace; font-size: 0.85em; color: #6B7280; margin-right: 15px; }
        .message { color: #1F2937; }
        .menu-text { font-weight: bold; color: #4C1D95; }
        .input-text { font-weight: bold; color: #0E7490; }
        @keyframes slideIn { from { opacity: 0; transform: translateX(-20px); } to { opacity: 1; transform: translateX(0); } }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🚀 VeeamItUp+ Activity Log</h1>
            <p>Activity monitoring and logging</p>
        </div>
        <div class="status-bar">
            <div style="display: flex; align-items: center; gap: 10px;">
                <button onclick="window.scrollTo(0,0)" style="padding: 8px 18px; font-size: 1em; border-radius: 6px; border: none; background: #10B981; color: white; font-weight: bold; cursor: pointer;">⏮ First</button>
                <button onclick="location.reload()" style="padding: 8px 18px; font-size: 1em; border-radius: 6px; border: none; background: #3B82F6; color: white; font-weight: bold; cursor: pointer;">🔄 Refresh</button>
                <button onclick="window.scrollTo(0,document.body.scrollHeight)" style="padding: 8px 18px; font-size: 1em; border-radius: 6px; border: none; background: #F59E0B; color: white; font-weight: bold; cursor: pointer;">⏭ Last</button>
            </div>
            <div>
                <span>Session: $sessionTime | Last Update: $lastUpdate</span>
            </div>
        </div>
        <div style="padding: 20px 30px 0 30px;">
            <label for="levelFilter"><b>Show entries at or above:</b></label>
            <select id="levelFilter" onchange="filterLog()" style="margin-left: 10px;">
                <option value="ALL">ALL</option>
                <option value="CRITICAL">CRITICAL</option>
                <option value="FAILURE">FAILURE</option>
                <option value="WARNING">WARNING</option>
                <option value="INFORMATIONAL">INFORMATIONAL</option>
            </select>
        </div>
        <div class="log-container" id="logContainer">
$logEntriesHtml
        </div>
    </div>
    <script>
        const levelOrder = { 'ALL': 0, 'INFORMATIONAL': 1, 'WARNING': 2, 'FAILURE': 3, 'CRITICAL': 4 };
        
        function filterLog() {
            const sel = document.getElementById('levelFilter').value;
            const entries = document.querySelectorAll('.log-entry');
            entries.forEach(entry => {
                const classList = entry.className.split(' ');
                let level = 'INFORMATIONAL';
                if (classList.includes('error')) level = 'CRITICAL';
                else if (classList.includes('warning')) level = 'WARNING';
                else if (classList.includes('info')) level = 'INFORMATIONAL';
                if (sel === 'ALL' || levelOrder[level] >= levelOrder[sel]) {
                    entry.style.display = '';
                } else {
                    entry.style.display = 'none';
                }
            });
        }
        
        // Auto-scroll to bottom on load
        window.addEventListener('load', function() {
            const logContainer = document.getElementById('logContainer');
            logContainer.scrollTop = logContainer.scrollHeight;
        });
        
        filterLog();
    </script>
</body>
</html>
"@
        
        $html | Out-File -FilePath $script:LogFilePath -Encoding UTF8 -Force
    } catch {
        # Silently ignore errors during HTML update to avoid recursive logging
    }
}
function Generate-HTMLActivityLog {
    $now = Get-Date
    $fileName = "VeeamItUpPlusLog-" + $now.ToString("yyyy-MMM-dd-ddd-hhmmtt").Replace(":","") + ".html"
    $downloads = Join-Path $env:USERPROFILE "Downloads"
    $logPath = Join-Path $downloads $fileName
    $logEntries = $script:HtmlLogBuffer
    $sessionTime = $now.ToString("yyyy-MM-dd HH:mm:ss.fff")
    $html = @"
<!DOCTYPE html>
<html lang='en'>
<head>
    <meta charset='UTF-8'>
    <meta name='viewport' content='width=device-width, initial-scale=1.0'>
    <title>VeeamItUp+ Activity Log</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); min-height: 100vh; padding: 20px; }
        .container { max-width: 80vw; width: 80vw; margin: 0 auto; background: white; border-radius: 15px; box-shadow: 0 4px 20px rgba(0,0,0,0.1); overflow: hidden; }
        .header { background: linear-gradient(135deg, #2c3e50 0%, #34495e 100%); color: white; padding: 30px; text-align: center; }
        .header h1 { font-size: 2.5em; margin-bottom: 10px; font-weight: 300; }
        .status-bar { background: #F8F9FA; padding: 15px 30px; border-bottom: 1px solid #E9ECEF; display: flex; justify-content: space-between; align-items: center; }
        .log-container { padding: 30px; max-height: 70vh; overflow-y: auto; }
        .log-entry { padding: 12px 20px; margin-bottom: 8px; border-radius: 8px; background: #F9FAFB; border-left: 4px solid #E5E7EB; animation: slideIn 0.3s ease; }
        .log-entry.info { border-left-color: #3B82F6; }
        .log-entry.success { border-left-color: #10B981; }
        .log-entry.warning { border-left-color: #F59E0B; }
        .log-entry.error { border-left-color: #EF4444; }
        .log-entry.menu { border-left-color: #8B5CF6; background: #F3F4F6; }
        .log-entry.input { border-left-color: #06B6D4; background: #ECFEFF; }
        .timestamp { font-family: 'Consolas', monospace; font-size: 0.85em; color: #6B7280; margin-right: 15px; }
        .message { color: #1F2937; }
        .menu-text { font-weight: bold; color: #4C1D95; }
        .input-text { font-weight: bold; color: #0E7490; }
        @keyframes slideIn { from { opacity: 0; transform: translateX(-20px); } to { opacity: 1; transform: translateX(0); } }
        .refresh-toggle { margin-left: 18px; font-size: 1em; display: inline-flex; align-items: center; gap: 6px; }
        .refresh-toggle input[type=checkbox] { accent-color: #3B82F6; width: 18px; height: 18px; }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🚀 VeeamItUp+ Activity Log</h1>
            <p>Activity monitoring and logging</p>
        </div>
        <div class="status-bar">
            <div style="display: flex; align-items: center; gap: 10px;">
                <button id="firstBtn" style="padding: 8px 18px; font-size: 1em; border-radius: 6px; border: none; background: #10B981; color: white; font-weight: bold; cursor: pointer;">⏮ First</button>
                <button id="refreshBtn" style="padding: 8px 18px; font-size: 1em; border-radius: 6px; border: none; background: #3B82F6; color: white; font-weight: bold; cursor: pointer;">🔄 Refresh</button>
                <button id="lastBtn" style="padding: 8px 18px; font-size: 1em; border-radius: 6px; border: none; background: #F59E0B; color: white; font-weight: bold; cursor: pointer;">⏭ Last</button>
            </div>
            <div>
                <span>Session: $sessionTime</span>
            </div>
        </div>
        <div style="padding: 20px 30px 0 30px;">
            <label for="levelFilter"><b>Show entries at or above:</b></label>
            <select id="levelFilter" onchange="filterLog()" style="margin-left: 10px;">
                <option value="ALL">ALL</option>
                <option value="CRITICAL">CRITICAL</option>
                <option value="FAILURE">FAILURE</option>
                <option value="WARNING">WARNING</option>
                <option value="INFORMATIONAL">INFORMATIONAL</option>
            </select>
        </div>
        <div class="log-container" id="logContainer">
"@
    $entryNumber = 1
    foreach ($entry in $logEntries) {
        # Map log level to class
        $levelClass = switch ($entry.Level) {
            'CRITICAL' { 'error' }
            'FAILURE' { 'warning' }
            'WARNING' { 'warning' }
            'INFORMATIONAL' { 'info' }
            default { 'info' }
        }
        $html += "<div class='log-entry $levelClass'><span class='log-number' style='font-weight:bold;color:#6366F1;margin-right:10px;'>$entryNumber.</span><span class='timestamp'>$($entry.Timestamp)</span><span class='message'>$($entry.Message)</span></div>"
        $entryNumber++
    }
    $html += @"
        </div>
    </div>
    <script>
        const levelOrder = { 'ALL': 0, 'INFORMATIONAL': 1, 'WARNING': 2, 'FAILURE': 3, 'CRITICAL': 4 };
        function filterLog() {
            const sel = document.getElementById('levelFilter').value;
            const entries = document.querySelectorAll('.log-entry');
            entries.forEach(entry => {
                const classList = entry.className.split(' ');
                let level = 'INFORMATIONAL';
                if (classList.includes('error')) level = 'CRITICAL';
                else if (classList.includes('warning')) level = 'WARNING';
                else if (classList.includes('info')) level = 'INFORMATIONAL';
                if (sel === 'ALL' || levelOrder[level] >= levelOrder[sel]) {
                    entry.style.display = '';
                } else {
                    entry.style.display = 'none';
                }
            });
        }
        document.getElementById('levelFilter').addEventListener('change', filterLog);
        filterLog();
        // Auto-scroll to bottom only once on load
        window.addEventListener('load', function() {
            const logContainer = document.getElementById('logContainer');
            logContainer.scrollTop = logContainer.scrollHeight;
        });
        // --- Button logic ---
        document.getElementById('refreshBtn').addEventListener('click', function() {
            location.reload();
        });
        document.getElementById('firstBtn').addEventListener('click', function() {
            const logContainer = document.getElementById('logContainer');
            logContainer.scrollTop = 0;
        });
        document.getElementById('lastBtn').addEventListener('click', function() {
            const logContainer = document.getElementById('logContainer');
            logContainer.scrollTop = logContainer.scrollHeight;
        });
    </script>
</body>
</html>
"@
    $html | Out-File -FilePath $logPath -Encoding UTF8 -Force
    Write-Log "HTML activity log generated: $logPath" 'INFORMATIONAL'
}
function Keep-LastNLogs {
    param($N)
    $downloads = Join-Path $env:USERPROFILE "Downloads"
    $pattern = "VeeamItUpPlusLog-*.html"
    $logs = Get-ChildItem -Path $downloads -Filter $pattern | Sort-Object LastWriteTime -Descending
    if ($logs.Count -gt $N) {
        $logs | Select-Object -Skip $N | Remove-Item -Force
    }
}
function Get-AvailableDriveLetters {
    $all = 65..90 | ForEach-Object { [char]$_ }
    $used = (Get-PSDrive -PSProvider FileSystem).Name
    return $all | Where-Object { $_ -notin $used }
}
function New-NetworkDrive {
    param(
        $DriveLetter,
        $UNCPath,
        $Username,
        [System.Security.SecureString]$Password
    )
    
    # First, clean up any existing mapping to this drive letter
    Write-Log "🧹 Cleaning up any existing mapping to $DriveLetter..." 'INFORMATIONAL'
    $cleanupCmd = "net use $DriveLetter /delete /yes"
    $cleanupResult = Invoke-Expression $cleanupCmd 2>&1
    # Don't worry about cleanup errors - drive might not be mapped
    
    # Test UNC path accessibility first
    Write-Log "🔍 Testing UNC path accessibility: $UNCPath" 'INFORMATIONAL'
    try {
        if (-not (Test-Path $UNCPath -ErrorAction SilentlyContinue)) {
            Write-Log "⚠️ UNC path $UNCPath is not accessible from this machine" 'WARNING'
        }
    } catch {
        Write-Log "⚠️ Error testing UNC path: $_" 'WARNING'
    }
    
    # Convert SecureString to plain text for net use
    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
    $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($BSTR)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
    
    # Build command (don't log password for security)
    $cmd = "net use $DriveLetter `"$UNCPath`" /user:`"$Username`" `"$plainPassword`" /persistent:no"
    Write-Log "🔗 Executing drive mapping: net use $DriveLetter `"$UNCPath`" /user:`"$Username`" [PASSWORD HIDDEN] /persistent:no" 'INFORMATIONAL'
    
    # Execute the mapping command
    $result = Invoke-Expression $cmd 2>&1
    
    if ($LASTEXITCODE -eq 0) {
        Write-Log "✅ Drive mapped successfully: $DriveLetter -> $UNCPath" 'INFORMATIONAL'
        
        # Verify the mapping worked by testing the drive
        if (Test-Path $DriveLetter) {
            Write-Log "✅ Drive verification successful: $DriveLetter is accessible" 'INFORMATIONAL'
        return $true
    } else {
            Write-Log "❌ Drive mapping appeared successful but $DriveLetter is not accessible" 'FAILURE'
        return $false
    }
    } else {
        Write-Log "❌ Failed to map drive $DriveLetter to $UNCPath" 'FAILURE'
        Write-Log "❌ Net use error details: $result" 'FAILURE'
        
        # Provide specific error guidance based on common errors
        $errorString = if ($result -ne $null) { $result.ToString() } else { "Unknown error" }
        if ($errorString -match "System error 5") {
            Write-Log "💡 Error 5 = Access Denied. Check username/password or permissions." 'WARNING'
        } elseif ($errorString -match "System error 53") {
            Write-Log "💡 Error 53 = Network path not found. Check UNC path and network connectivity." 'WARNING'
        } elseif ($errorString -match "System error 67") {
            Write-Log "💡 Error 67 = Network name not found. Check server name and network connectivity." 'WARNING'
        } elseif ($errorString -match "System error 86") {
            Write-Log "💡 Error 86 = Invalid password. Check password accuracy." 'WARNING'
        } elseif ($errorString -match "System error 1326") {
            Write-Log "💡 Error 1326 = Logon failure. Check username and password." 'WARNING'
        }
        
        return $false
    }
}
function Remove-NetworkDrive {
    param($DriveLetter)
    $cmd = "net use $DriveLetter /delete /yes"
    Write-Log "Unmapping drive: $cmd" 'INFORMATIONAL'
    $result = Invoke-Expression $cmd 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Log "Drive unmapped: $DriveLetter" 'INFORMATIONAL'
    } else {
        Write-Log "Failed to unmap drive: $result" 'WARNING'
    }
}
function Get-SavedServers {
    if (-not (Test-Path $script:RegRoot)) { return @() }
    $subkeys = Get-ChildItem -Path $script:RegRoot -ErrorAction SilentlyContinue | Where-Object { $_.PSIsContainer }
    $servers = @()
    foreach ($key in $subkeys) {
        $props = Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue
        if ($props.UNCPath -and $props.Username -and $props.Password -and $props.DriveLetter) {
            $servers += [PSCustomObject]@{
                Key = $key.PSChildName
                UNCPath = $props.UNCPath
                Username = $props.Username
                Password = $props.Password
                DriveLetter = $props.DriveLetter
                ServerName = $props.ServerName
            }
        }
    }
    return $servers
}
function Save-ServerSettings {
    param($UNCPath, $Username, $Password, $DriveLetter, $KeyName, $ServerName)
    if (-not (Test-Path $script:RegRoot)) { New-Item -Path $script:RegRoot -Force | Out-Null }
    $key = Join-Path $script:RegRoot $KeyName
    if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
    Set-ItemProperty -Path $key -Name "UNCPath" -Value $UNCPath -Force
    Set-ItemProperty -Path $key -Name "Username" -Value $Username -Force
    Set-ItemProperty -Path $key -Name "Password" -Value (ConvertTo-EncryptedString $Password) -Force
    Set-ItemProperty -Path $key -Name "DriveLetter" -Value $DriveLetter -Force
    Set-ItemProperty -Path $key -Name "ServerName" -Value $ServerName -Force
    Write-Log "Settings saved for $UNCPath ($Username, $DriveLetter) in registry." 'INFORMATIONAL'
}
function Delete-ServerSettings {
    param($KeyName)
    $key = Join-Path $script:RegRoot $KeyName
    if (Test-Path $key) { Remove-Item -Path $key -Recurse -Force }
}
function Delete-AllServerSettings {
    if (Test-Path $script:RegRoot) { Remove-Item -Path $script:RegRoot -Recurse -Force }
}
function Load-ServerSettings {
    param($KeyName)
    $key = Join-Path $script:RegRoot $KeyName
    if (Test-Path $key) {
        $props = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
        if ($props.UNCPath -and $props.Username -and $props.Password -and $props.DriveLetter) {
            try {
                $decrypted = ConvertFrom-EncryptedString $props.Password
            } catch {
                Write-Log "Corrupt or invalid password in registry for $KeyName. Please re-enter credentials." 'FAILURE'
                return $null
            }
            return @{ UNCPath = $props.UNCPath; Username = $props.Username; Password = $decrypted; DriveLetter = $props.DriveLetter }
        }
    }
    return $null
}
function Sanitize-KeyName {
    param($UNCPath, $Username)
    # Use a hash for uniqueness and to avoid invalid chars
    $raw = "$UNCPath|$Username"
    $hash = [System.BitConverter]::ToString((New-Object -TypeName System.Security.Cryptography.SHA1Managed).ComputeHash([System.Text.Encoding]::UTF8.GetBytes($raw))).Replace("-","")
    return $hash
}
function ConvertTo-EncryptedString {
    param([string]$PlainText)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($PlainText)
    $enc = [System.Security.Cryptography.ProtectedData]::Protect($bytes, $null, 'CurrentUser')
    return [Convert]::ToBase64String($enc)
}
function ConvertFrom-EncryptedString {
    param([string]$EncryptedText)
    try {
        $bytes = [Convert]::FromBase64String($EncryptedText)
        $dec = [System.Security.Cryptography.ProtectedData]::Unprotect($bytes, $null, 'CurrentUser')
        if (-not $dec) { throw 'Decryption returned null.' }
        return [System.Text.Encoding]::UTF8.GetString($dec)
    } catch {
        throw "Failed to decrypt password: $_"
    }
}

function Test-ServerConnectivity {
    param(
        [string]$ServerName,
        [string]$UNCPath,
        [int]$TimeoutSeconds = 3
    )
    
    Write-Log "🔍 Testing connectivity to $ServerName (timeout: ${TimeoutSeconds}s)" 'INFORMATIONAL'
    $allPassed = $true
    
    # 1. Quick ping test
    try {
        $pingResult = Test-Connection -ComputerName $ServerName -Count 1 -TimeToLive 10 -Quiet -ErrorAction Stop
        if ($pingResult) {
            Write-Log "📶 Ping to $ServerName succeeded." 'INFORMATIONAL'
        } else {
            Write-Log "⚠️ Ping to $ServerName failed." 'WARNING'
            $allPassed = $false
        }
    } catch {
        Write-Log "⚠️ Ping test to $ServerName failed: $_" 'WARNING'
        $allPassed = $false
    }
    
    # 2. Port 445 test with timeout
    $port445 = $false
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $iar = $tcp.BeginConnect($ServerName, 445, $null, $null)
        $success = $iar.AsyncWaitHandle.WaitOne(($TimeoutSeconds * 1000), $false)
        if ($success -and $tcp.Connected) {
            $tcp.EndConnect($iar)
            $tcp.Close()
            $port445 = $true
            Write-Log "🔌 Port 445 open on $ServerName." 'INFORMATIONAL'
        } else {
            Write-Log "⚠️ Port 445 not accessible on $ServerName (timeout or closed)." 'WARNING'
            $allPassed = $false
        }
        $tcp.Dispose()
    } catch {
        Write-Log "⚠️ Port 445 check failed for $ServerName`: $_" 'WARNING'
        $allPassed = $false
    }
    
    # 3. Skip UNC Path validation as it can be slow and unreliable
    # This will be tested during actual drive mapping
    Write-Log "ℹ️ UNC path validation skipped (will be tested during drive mapping)" 'INFORMATIONAL'
    
    Write-Log "🔍 Connectivity test completed for $ServerName" 'INFORMATIONAL'
    return $allPassed
}
function Show-Banner {
    $esc = [char]27
    $year = (Get-Date).Year
    Write-Host "${esc}[40;92m+------------------------------------------------------------------------------+${esc}[0m"
    Write-Host "${esc}[40;92m|                                                                              |${esc}[0m"
    Write-Host "${esc}[40;92m|                          VeeamItUp+                                          |${esc}[0m"
    Write-Host "${esc}[40;92m|                                                                              |${esc}[0m"
    Write-Host "${esc}[40;92m|   Version 1.0.0   |   Author: David Andrews   |   All Rights Reserved© $year  |${esc}[0m"
    Write-Host "${esc}[40;92m|                                                                              |${esc}[0m"
    Write-Host "${esc}[40;92m+------------------------------------------------------------------------------+${esc}[0m"
}
function Show-ReturnToMenuPrompt {
    param(
        [string]$Message = "Press any key to return to menu...",
        [string]$Color = "Cyan"
    )
    
    Write-Host ""
    Write-Host $Message -ForegroundColor $Color
    Write-Log "⏸️ $Message" 'INFORMATIONAL'
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    Write-Log "🔄 Returning to main menu..." 'INFORMATIONAL'
    Clear-Host
    Show-Banner
    Write-Host ""
}
# ===========================================
# BACKUP ANALYSIS FUNCTIONS FROM OLD APP
# ===========================================

# Function to get Veeam backup filename information and extract metadata
function Get-VeeamBackupFileInfo {
    param([string]$FileName)
    
    $result = @{
        VMName = ""
        BackupType = ""
        BackupDate = $null
        IsFullBackup = $false
        IsIncremental = $false
        BackupSchedule = ""
    }
    
    # Determine backup type by extension
    if ($FileName -match '\.vbk$') {
        $result.IsFullBackup = $true
        $result.BackupType = "Full"
    }
    elseif ($FileName -match '\.vib$') {
        $result.IsIncremental = $true
        $result.BackupType = "Incremental"
    }
    
    # Extract VM name and date
    if ($FileName -match '^(.+?)(\d{4}-\d{2}-\d{2}T\d{6})\.v[bi][kb]$') {
        $vmNamePart = $matches[1]
        $datePart = $matches[2]
        
        # Clean up VM name (remove trailing schedule indicators)
        $result.VMName = $vmNamePart -replace '[DWM]$', ''
        
        # Detect schedule type
        if ($vmNamePart -match 'D$') {
            $result.BackupSchedule = "Daily"
        }
        elseif ($vmNamePart -match 'W$') {
            $result.BackupSchedule = "Weekly"
        }
        elseif ($vmNamePart -match 'M$') {
            $result.BackupSchedule = "Monthly"
        }
        
        # Parse date
        try {
            $result.BackupDate = [DateTime]::ParseExact($datePart, "yyyy-MM-ddTHHmmss", $null)
        }
        catch {
            # Fallback to file creation time
        }
    }
    
    return $result
}

# Function to analyze backup retention and patterns
function Analyze-BackupRetention {
    param([array]$BackupFiles)
    
    $analysis = @{
        TotalBackups = $BackupFiles.Count
        FullBackups = 0
        IncrementalBackups = 0
        OldestBackup = $null
        NewestBackup = $null
        RetentionPoints = 0
        RetentionDays = 0
        BackupFrequency = @{
            Daily = 0
            Weekly = 0
            Monthly = 0
        }
        BackupCalendar = @{}
        EstimatedSchedule = ""
        MissingBackupDates = @()
    }
    
    if ($BackupFiles.Count -eq 0) {
        return $analysis
    }
    
    # Sort by date
    $sortedBackups = $BackupFiles | Sort-Object LastWriteTime
    
    # Count backup types
    $analysis.FullBackups = ($BackupFiles | Where-Object { $_.Name -match '\.vbk$' }).Count
    $analysis.IncrementalBackups = ($BackupFiles | Where-Object { $_.Name -match '\.vib$' }).Count
    
    # Get date range and calculate retention
    if ($sortedBackups -and $sortedBackups.Count -gt 0) {
        $analysis.OldestBackup = $sortedBackups[0].LastWriteTime
        $analysis.NewestBackup = $sortedBackups[-1].LastWriteTime
        $analysis.RetentionDays = ($analysis.NewestBackup - $analysis.OldestBackup).Days
    }
    $analysis.RetentionPoints = $BackupFiles.Count
    
    # Build calendar of backups
    foreach ($backup in $BackupFiles) {
        if ($backup -and $backup.LastWriteTime) {
            $dateKey = $backup.LastWriteTime.ToString("yyyy-MM-dd")
            if (-not $analysis.BackupCalendar.ContainsKey($dateKey)) {
                $analysis.BackupCalendar[$dateKey] = @{
                    FullBackups = @()
                    IncrementalBackups = @()
                }
            }
            
            $parsed = Get-VeeamBackupFileInfo -FileName $backup.Name
            if ($parsed.IsFullBackup) {
                $analysis.BackupCalendar[$dateKey].FullBackups += $backup
            }
            else {
                $analysis.BackupCalendar[$dateKey].IncrementalBackups += $backup
            }
        }
    }
    
    # Analyze backup frequency
    if ($analysis.NewestBackup -and $analysis.OldestBackup) {
        $daysSinceOldest = ($analysis.NewestBackup - $analysis.OldestBackup).Days
        if ($daysSinceOldest -gt 0) {
            $backupsPerDay = $analysis.TotalBackups / $daysSinceOldest
            
            if ($backupsPerDay -ge 0.8) {
                $analysis.EstimatedSchedule = "Daily"
            }
            elseif ($backupsPerDay -ge 0.1) {
                $analysis.EstimatedSchedule = "Weekly"
            }
            else {
                $analysis.EstimatedSchedule = "Monthly"
            }
        }
        
        # Find missing backup dates (gaps in daily backups)
        if ($analysis.EstimatedSchedule -eq "Daily" -and $daysSinceOldest -gt 1) {
            $currentDate = $analysis.OldestBackup.Date
            while ($currentDate -le $analysis.NewestBackup.Date) {
                $dateKey = $currentDate.ToString("yyyy-MM-dd")
                if (-not $analysis.BackupCalendar.ContainsKey($dateKey)) {
                    $analysis.MissingBackupDates += $currentDate
                }
                $currentDate = $currentDate.AddDays(1)
            }
        }
    }
    
    return $analysis
}

# Helper function to calculate standard deviation
function Calculate-StandardDeviation {
    param([array]$Values)
    
    if ($Values.Count -le 1) {
        return 0
    }
    
    $mean = ($Values | Measure-Object -Average).Average
    $sumOfSquaredDifferences = ($Values | ForEach-Object { [math]::Pow($_ - $mean, 2) } | Measure-Object -Sum).Sum
    $variance = $sumOfSquaredDifferences / ($Values.Count - 1)
    $standardDeviation = [math]::Sqrt($variance)
    
    return [math]::Round($standardDeviation, 2)
}

# Function to format storage sizes with appropriate units
function Format-StorageSize {
    param(
        [double]$SizeInGB,
        [int]$DecimalPlaces = 1
    )
    
    if ($SizeInGB -eq 0) {
        return "0 GB"
    }
    
    # Convert GB to bytes for calculation
    $SizeInBytes = $SizeInGB * 1024 * 1024 * 1024
    
    # Define unit thresholds and labels
    $Units = @(
        @{ Threshold = 1024 * 1024 * 1024 * 1024 * 1024 * 1024; Label = "EB"; Divisor = 1024 * 1024 * 1024 * 1024 * 1024 * 1024 }  # Exabytes
        @{ Threshold = 1024 * 1024 * 1024 * 1024 * 1024; Label = "PB"; Divisor = 1024 * 1024 * 1024 * 1024 * 1024 }              # Petabytes
        @{ Threshold = 1024 * 1024 * 1024 * 1024; Label = "TB"; Divisor = 1024 * 1024 * 1024 * 1024 }                            # Terabytes
        @{ Threshold = 1024 * 1024 * 1024; Label = "GB"; Divisor = 1024 * 1024 * 1024 }                                         # Gigabytes
        @{ Threshold = 1024 * 1024; Label = "MB"; Divisor = 1024 * 1024 }                                                       # Megabytes
        @{ Threshold = 1024; Label = "KB"; Divisor = 1024 }                                                                     # Kilobytes
    )
    
    # Find the appropriate unit
    foreach ($Unit in $Units) {
        if ($SizeInBytes -ge $Unit.Threshold) {
            $ConvertedSize = $SizeInBytes / $Unit.Divisor
            return "$([math]::Round($ConvertedSize, $DecimalPlaces)) $($Unit.Label)"
        }
    }
    
    # If smaller than 1KB, show in bytes
    return "$([math]::Round($SizeInBytes, 0)) bytes"
}

# Function to measure storage metrics from backup inventory
function Measure-StorageMetrics {
    param($BackupInventory)
    
    $metrics = @{
        TotalVMs = 0
        TotalRepositories = @{}
        TotalFullBackups = 0
        TotalIncrementalBackups = 0
        TotalReverseIncrementalBackups = 0
        TotalStorageGB = 0
        AverageVMSizeGB = 0
        LargestVMName = ""
        LargestVMSizeGB = 0
        SmallestVMName = ""
        SmallestVMSizeGB = [double]::MaxValue
        RepositoryStats = @{}
        VmSizesGB = @()
    }
    
    foreach ($key in $BackupInventory.Keys) {
        $machine = $BackupInventory[$key]
        $metrics.TotalVMs++
        
        # Track repository
        $repoName = $machine.RepositoryName
        if ($repoName -and -not $metrics.TotalRepositories.ContainsKey($repoName)) {
            $metrics.TotalRepositories[$repoName] = 1
        }
        elseif ($repoName) {
            $metrics.TotalRepositories[$repoName]++
        }
        
        # Count backups
        $metrics.TotalFullBackups += $machine.FullBackups.Count
        $metrics.TotalIncrementalBackups += $machine.IncrementalBackups.Count
        $metrics.TotalReverseIncrementalBackups += $machine.ReverseIncrementalBackups.Count
        
        # Calculate sizes
        $vmSizeGB = $machine.TotalSizeGB
        $metrics.TotalStorageGB += $vmSizeGB
        $metrics.VmSizesGB += $vmSizeGB
        
        # Track largest and smallest
        if ($vmSizeGB -gt $metrics.LargestVMSizeGB) {
            $metrics.LargestVMName = $machine.Name
            $metrics.LargestVMSizeGB = $vmSizeGB
        }
        if ($vmSizeGB -lt $metrics.SmallestVMSizeGB -and $vmSizeGB -gt 0) {
            $metrics.SmallestVMName = $machine.Name
            $metrics.SmallestVMSizeGB = $vmSizeGB
        }
        
        # Repository statistics
        if ($repoName) {
            if (-not $metrics.RepositoryStats.ContainsKey($repoName)) {
                $metrics.RepositoryStats[$repoName] = @{
                    TotalVMs = 0
                    TotalSizeGB = 0
                    TotalFullBackups = 0
                    TotalIncrementalBackups = 0
                    TotalReverseIncrementalBackups = 0
                }
            }
            $repoStats = $metrics.RepositoryStats[$repoName]
            $repoStats.TotalVMs++
            $repoStats.TotalSizeGB += $vmSizeGB
            $repoStats.TotalFullBackups += $machine.FullBackups.Count
            $repoStats.TotalIncrementalBackups += $machine.IncrementalBackups.Count
            $repoStats.TotalReverseIncrementalBackups += $machine.ReverseIncrementalBackups.Count
        }
    }
    
    # Calculate averages and standard deviation
    if ($metrics.TotalVMs -gt 0) {
        $metrics.AverageVMSizeGB = [math]::Round($metrics.TotalStorageGB / $metrics.TotalVMs, 2)
        $metrics.StandardDeviationGB = Calculate-StandardDeviation -Values $metrics.VmSizesGB
    }
    
    # Fix smallest VM if no VMs found
    if ($metrics.SmallestVMSizeGB -eq [double]::MaxValue) {
        $metrics.SmallestVMSizeGB = 0
    }
    
    return $metrics
}

# Function to generate storage recommendations
function Get-StorageRecommendations {
    param($StorageMetrics)
    
    $recommendations = @()
    
    # Check if average VM size is very large
    if ($StorageMetrics.AverageVMSizeGB -gt 500) {
        $recommendations += @{
            Type = "Performance"
            Severity = "Warning"
            Message = "Average VM backup size is very large (>500GB). Consider using incremental backups more frequently."
        }
    }
    
    # Check for imbalanced backup types
    $totalBackups = $StorageMetrics.TotalFullBackups + $StorageMetrics.TotalIncrementalBackups + $StorageMetrics.TotalReverseIncrementalBackups
    if ($totalBackups -gt 0) {
        $fullBackupRatio = $StorageMetrics.TotalFullBackups / $totalBackups
        if ($fullBackupRatio -gt 0.3) {
            $recommendations += @{
                Type = "Storage"
                Severity = "Info"
                Message = "High ratio of full backups ($([math]::Round($fullBackupRatio * 100, 1))%). Consider reducing full backup frequency to save storage."
            }
        }
    }
    
    # Check for very large single VMs
    if ($StorageMetrics.LargestVMSizeGB -gt 1000) {
        $recommendations += @{
            Type = "Storage"
                Severity = "Warning"
                Message = "Very large VM detected: $($StorageMetrics.LargestVMName) ($(Format-StorageSize $StorageMetrics.LargestVMSizeGB)). Consider archiving old backups."
            }
        }
        
        # Check standard deviation for uneven VM sizes
        if ($StorageMetrics.StandardDeviationGB -gt ($StorageMetrics.AverageVMSizeGB * 1.5)) {
            $recommendations += @{
                Type = "Balance"
                Severity = "Info"
                Message = "High variation in VM backup sizes detected. Consider balancing backup storage across repositories."
            }
        }
        
        # Repository-specific recommendations
        foreach ($repoName in $StorageMetrics.RepositoryStats.Keys) {
            $repoStats = $StorageMetrics.RepositoryStats[$repoName]
            
            # Check for repositories with too many VMs
            if ($repoStats.TotalVMs -gt 50) {
                $recommendations += @{
                    Type = "Performance"
                    Severity = "Warning"
                    Message = "Repository '$repoName' contains many VMs ($($repoStats.TotalVMs)). Consider splitting into multiple repositories."
                }
            }
            
            # Check for very large repositories
            if ($repoStats.TotalSizeGB -gt 5000) {
                $recommendations += @{
                    Type = "Storage"
                    Severity = "Warning"
                    Message = "Repository '$repoName' is very large ($(Format-StorageSize $repoStats.TotalSizeGB)). Monitor available space closely."
                }
            }
        }
        
        # Add general best practice recommendations
        if ($recommendations.Count -eq 0) {
            $recommendations += @{
                Type = "BestPractice"
                Severity = "Success"
                Message = "Backup storage appears well-balanced. Continue monitoring growth trends."
            }
        }
        
        return $recommendations
    }

# Generate comprehensive HTML report with all backup information
function New-HTMLReport {
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$BackupInventory,
        
        [Parameter(Mandatory=$true)]
        [hashtable]$StorageMetrics,
        
        [Parameter(Mandatory=$true)]
        [hashtable]$BackupLocations,
        
        [Parameter(Mandatory=$false)]
        [string]$ServerName = $env:COMPUTERNAME.ToUpper(),
        
        [string]$OutputPath = ""
    )
    
    try {
        Write-Log "🎨 Starting HTML report generation for $ServerName" 'INFORMATIONAL'
        
        # Generate output path if not provided
        if ([string]::IsNullOrEmpty($OutputPath)) {
            $timestamp = Get-Date -Format "yyyy-MM-dd-HHmmss"
            $OutputPath = Join-Path $env:USERPROFILE "Downloads\VeeamItUp+_Report_${ServerName}_${timestamp}.html"
        }
        

        
        # Start building HTML
        $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Veeam Backup Repository Analysis - $ServerName</title>
    <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }
        
        html {
            scroll-behavior: smooth;
        }
        
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            padding: 20px;
        }
        
        .container {
            max-width: 80%;
            margin: 0 auto;
            background: white;
            border-radius: 15px;
            box-shadow: 0 4px 20px rgba(0,0,0,0.08);
            overflow: hidden;
        }
        
        .header {
            background: linear-gradient(135deg, #2c3e50 0%, #34495e 100%);
            color: white;
            padding: 30px;
            text-align: center;
            position: relative;
        }
        
        .header-logo {
            position: absolute;
            top: 20px;
            left: 30px;
            max-height: 120px;
            max-width: 300px;
        }
        
        .header h1 {
            font-size: 2.5em;
            margin-bottom: 10px;
            font-weight: 300;
        }
        
        .header p {
            font-size: 1.1em;
            opacity: 0.9;
        }
        
        .content {
            padding: 30px;
        }
        
        .section {
            margin-bottom: 30px;
            background: #f8f9fa;
            border-radius: 12px;
            padding: 25px;
            box-shadow: 0 2px 10px rgba(0,0,0,0.05);
        }
        
        .section-title {
            font-size: 1.8em;
            color: #2c3e50;
            margin-bottom: 20px;
            font-weight: 500;
        }
        
        .repo-summary {
            background: linear-gradient(135deg, #ffffff, #f1f5f9);
            padding: 20px;
            border-radius: 10px;
            margin-bottom: 20px;
            border-left: 4px solid #3498db;
        }
        
        .repo-summary p {
            margin: 5px 0;
            color: #64748b;
            font-weight: 500;
        }
        
        /* Storage Bar Visualization */
        .storage-bar-container {
            margin: 15px 0 10px 0;
            padding: 12px;
            background: linear-gradient(145deg, 
                rgba(255, 255, 255, 0.1) 0%, 
                rgba(255, 255, 255, 0.05) 100%);
            border-radius: 20px;
            border: 1px solid rgba(255, 255, 255, 0.2);
            backdrop-filter: blur(15px);
            box-shadow: 
                0 8px 32px rgba(0, 0, 0, 0.1),
                inset 0 1px 0 rgba(255, 255, 255, 0.2);
        }
        
        .storage-bar-label {
            font-size: 0.95em;
            color: #475569;
            margin-bottom: 12px;
            font-weight: 600;
            text-shadow: 0 1px 2px rgba(0, 0, 0, 0.1);
            display: flex;
            align-items: center;
            gap: 8px;
        }
        
        .storage-bar-label::before {
            content: '';
            width: 4px;
            height: 16px;
            background: linear-gradient(180deg, 
                rgba(59, 130, 246, 0.8) 0%, 
                rgba(37, 99, 235, 1.0) 100%);
            border-radius: 2px;
            box-shadow: 0 2px 4px rgba(59, 130, 246, 0.3);
        }
        
        .storage-bar {
            width: 100%;
            height: 40px;
            background: linear-gradient(180deg, 
                rgba(30, 64, 175, 0.15) 0%, 
                rgba(30, 58, 138, 0.25) 40%,
                rgba(25, 52, 130, 0.35) 100%);
            border-radius: 20px;
            overflow: hidden;
            position: relative;
            backdrop-filter: blur(15px);
            border: 3px solid rgba(255, 255, 255, 0.4);
            box-shadow: 
                inset 0 4px 12px rgba(255, 255, 255, 0.3),
                inset 0 -4px 12px rgba(0, 0, 0, 0.15),
                0 8px 24px rgba(0, 0, 0, 0.2),
                0 16px 48px rgba(0, 0, 0, 0.1);
            transition: all 0.3s ease;
        }
        
        .storage-bar:hover {
            transform: translateY(-2px);
            box-shadow: 
                inset 0 4px 12px rgba(255, 255, 255, 0.4),
                inset 0 -4px 12px rgba(0, 0, 0, 0.15),
                0 12px 32px rgba(0, 0, 0, 0.25),
                0 24px 64px rgba(0, 0, 0, 0.15);
        }
        
        .storage-bar::before {
            content: '';
            position: absolute;
            top: 3px;
            left: 3px;
            right: 3px;
            height: 12px;
            background: linear-gradient(180deg, 
                rgba(255, 255, 255, 0.6) 0%, 
                rgba(255, 255, 255, 0.3) 50%,
                rgba(255, 255, 255, 0.1) 100%);
            border-radius: 16px 16px 8px 8px;
            pointer-events: none;
            opacity: 0.8;
        }
        
        .storage-bar::after {
            content: '';
            position: absolute;
            top: 0;
            left: 0;
            right: 0;
            bottom: 0;
            background: 
                linear-gradient(90deg, 
                    rgba(255, 255, 255, 0.4) 0%, 
                    rgba(255, 255, 255, 0.1) 20%,
                    transparent 30%,
                    transparent 70%,
                    rgba(255, 255, 255, 0.1) 80%,
                    rgba(255, 255, 255, 0.3) 100%),
                radial-gradient(ellipse at top left, 
                    rgba(255, 255, 255, 0.3) 0%, 
                    transparent 50%),
                radial-gradient(ellipse at bottom right, 
                    rgba(0, 0, 0, 0.1) 0%, 
                    transparent 50%);
            border-radius: 20px;
            pointer-events: none;
        }
        
        .storage-segment {
            height: 100%;
            float: left;
            position: relative;
            backdrop-filter: blur(8px);
            transition: all 0.4s cubic-bezier(0.4, 0, 0.2, 1);
            border-right: 1px solid rgba(255, 255, 255, 0.2);
            overflow: hidden;
        }
        
        .storage-segment:last-child {
            border-right: none;
        }
        
        .storage-segment::before {
            content: '';
            position: absolute;
            top: 3px;
            left: 3px;
            right: 3px;
            height: 40%;
            background: linear-gradient(180deg, 
                rgba(255, 255, 255, 0.7) 0%, 
                rgba(255, 255, 255, 0.4) 60%,
                rgba(255, 255, 255, 0.1) 100%);
            border-radius: 16px 16px 8px 8px;
            pointer-events: none;
            opacity: 0.9;
        }
        
        .storage-segment::after {
            content: '';
            position: absolute;
            top: 0;
            left: 0;
            right: 0;
            bottom: 0;
            background: linear-gradient(135deg, 
                rgba(255, 255, 255, 0.25) 0%, 
                transparent 25%,
                transparent 75%,
                rgba(0, 0, 0, 0.15) 100%);
            pointer-events: none;
        }
        
        .storage-segment:hover, .storage-bar:hover .storage-segment {
            filter: brightness(1.15) saturate(1.2);
            transform: scaleY(1.05);
            z-index: 10;
            box-shadow: 
                0 6px 24px rgba(0, 0, 0, 0.25),
                inset 0 2px 12px rgba(255, 255, 255, 0.4),
                inset 0 -2px 8px rgba(0, 0, 0, 0.1);
        }
        
        @keyframes glassReflection {
            0% { 
                opacity: 0.9; 
                transform: translateX(-100%);
            }
            50% { 
                opacity: 1;
                transform: translateX(0%);
            }
            100% { 
                opacity: 0.9;
                transform: translateX(100%);
            }
        }
        
        .storage-bar:hover::before {
            animation: glassReflection 1.5s ease-in-out;
        }
        
        .storage-segment:hover::before {
            animation: glassReflection 1.2s ease-in-out;
        }
        
        .storage-segment.incrementals {
            background: linear-gradient(180deg, 
                rgba(239, 68, 68, 0.3) 0%, 
                rgba(220, 38, 38, 0.4) 30%,
                rgba(200, 25, 25, 0.5) 70%,
                rgba(180, 15, 15, 0.6) 100%);
            border: 1px solid rgba(239, 68, 68, 0.7);
            box-shadow: 
                inset 2px 0 6px rgba(255, 255, 255, 0.4),
                inset -2px 0 6px rgba(0, 0, 0, 0.1),
                inset 0 2px 8px rgba(255, 255, 255, 0.3);
        }
        
        .storage-segment.reverse-incrementals {
            background: linear-gradient(180deg, 
                rgba(251, 146, 60, 0.3) 0%, 
                rgba(249, 115, 22, 0.4) 30%,
                rgba(230, 100, 10, 0.5) 70%,
                rgba(210, 85, 0, 0.6) 100%);
            border: 1px solid rgba(251, 146, 60, 0.7);
            box-shadow: 
                inset 2px 0 6px rgba(255, 255, 255, 0.4),
                inset -2px 0 6px rgba(0, 0, 0, 0.1),
                inset 0 2px 8px rgba(255, 255, 255, 0.3);
        }
        
        .storage-segment.fulls {
            background: linear-gradient(180deg, 
                rgba(34, 197, 94, 0.3) 0%, 
                rgba(22, 163, 74, 0.4) 30%,
                rgba(15, 145, 60, 0.5) 70%,
                rgba(10, 130, 50, 0.6) 100%);
            border: 1px solid rgba(34, 197, 94, 0.7);
            box-shadow: 
                inset 2px 0 6px rgba(255, 255, 255, 0.4),
                inset -2px 0 6px rgba(0, 0, 0, 0.1),
                inset 0 2px 8px rgba(255, 255, 255, 0.3);
        }
        
        .storage-legend {
            display: flex;
            justify-content: center;
            gap: 24px;
            margin-top: 16px;
            padding: 8px 16px;
            background: linear-gradient(145deg, 
                rgba(255, 255, 255, 0.08) 0%, 
                rgba(255, 255, 255, 0.03) 100%);
            border-radius: 12px;
            border: 1px solid rgba(255, 255, 255, 0.1);
            font-size: 0.8em;
            backdrop-filter: blur(5px);
        }
        
        .legend-item {
            display: flex;
            align-items: center;
            gap: 8px;
            padding: 4px 8px;
            border-radius: 8px;
            transition: all 0.3s ease;
        }
        
        .legend-item:hover {
            background: rgba(255, 255, 255, 0.1);
            transform: translateY(-1px);
        }
        
        .legend-color {
            width: 16px;
            height: 16px;
            border-radius: 8px;
            border: 2px solid rgba(255, 255, 255, 0.4);
            box-shadow: 
                inset 0 1px 3px rgba(255, 255, 255, 0.3),
                inset 0 -1px 3px rgba(0, 0, 0, 0.2),
                0 2px 8px rgba(0, 0, 0, 0.15);
        }
        
        .legend-color.incrementals {
            background: linear-gradient(180deg, 
                rgba(239, 68, 68, 0.3) 0%, 
                rgba(220, 38, 38, 0.4) 30%,
                rgba(200, 25, 25, 0.5) 70%,
                rgba(180, 15, 15, 0.6) 100%);
            border: 1px solid rgba(239, 68, 68, 0.7);
            backdrop-filter: blur(3px);
        }
        
        .legend-color.reverse-incrementals {
            background: linear-gradient(180deg, 
                rgba(251, 146, 60, 0.3) 0%, 
                rgba(249, 115, 22, 0.4) 30%,
                rgba(230, 100, 10, 0.5) 70%,
                rgba(210, 85, 0, 0.6) 100%);
            border: 1px solid rgba(251, 146, 60, 0.7);
            backdrop-filter: blur(3px);
        }
        
        .legend-color.fulls {
            background: linear-gradient(180deg, 
                rgba(34, 197, 94, 0.3) 0%, 
                rgba(22, 163, 74, 0.4) 30%,
                rgba(15, 145, 60, 0.5) 70%,
                rgba(10, 130, 50, 0.6) 100%);
            border: 1px solid rgba(34, 197, 94, 0.7);
            backdrop-filter: blur(3px);
        }
        
        .legend-color.available-space {
            background: linear-gradient(180deg, 
                rgba(30, 64, 175, 0.15) 0%, 
                rgba(30, 58, 138, 0.25) 40%,
                rgba(25, 52, 130, 0.35) 100%);
            border: 1px solid rgba(30, 64, 175, 0.4);
            backdrop-filter: blur(3px);
        }
        
        /* Repository Tab System */
        .repo-tabs {
            margin-top: 20px;
            border-radius: 12px;
            overflow: hidden;
            box-shadow: 0 4px 15px rgba(0, 0, 0, 0.08);
            background: white;
        }
        
        .tab-nav {
            display: flex;
            background: linear-gradient(135deg, #f8fafc, #e2e8f0);
            border-bottom: 2px solid #e2e8f0;
        }
        
        .tab-button {
            flex: 1;
            padding: 15px 20px;
            background: none;
            border: none;
            cursor: pointer;
            font-size: 0.95em;
            font-weight: 600;
            color: #64748b;
            transition: all 0.3s ease;
            border-bottom: 3px solid transparent;
            position: relative;
        }
        
        .tab-button:hover {
            background: rgba(59, 130, 246, 0.05);
            color: #3b82f6;
        }
        
        .tab-button.active {
            color: #3b82f6;
            background: white;
            border-bottom-color: #3b82f6;
            box-shadow: 0 -2px 8px rgba(59, 130, 246, 0.1);
        }
        
        .tab-content {
            display: none;
            padding: 25px;
            background: white;
            min-height: 200px;
        }
        
        .tab-content.active {
            display: block;
            animation: fadeIn 0.3s ease-in-out;
        }
        
        @keyframes fadeIn {
            from { opacity: 0; transform: translateY(10px); }
            to { opacity: 1; transform: translateY(0); }
        }
        
        /* Tab Content Styling */
        .tab-overview {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
            gap: 20px;
        }
        
        .overview-card {
            background: linear-gradient(135deg, #f8fafc, #f1f5f9);
            border-radius: 10px;
            padding: 20px;
            border-left: 4px solid #3b82f6;
        }
        
        .overview-card h4 {
            margin: 0 0 10px 0;
            color: #1e40af;
            font-size: 1.1em;
        }
        
        .overview-stat {
            display: flex;
            justify-content: space-between;
            margin: 8px 0;
            font-size: 0.9em;
        }
        
        .overview-stat-label {
            color: #64748b;
        }
        
        .overview-stat-value {
            font-weight: 600;
            color: #1e293b;
        }
        
        .machines-grid {
            display: grid;
            grid-template-columns: repeat(auto-fill, minmax(300px, 1fr));
            gap: 15px;
        }
        
        .machine-summary-card {
            background: linear-gradient(135deg, #ffffff, #f8fafc);
            border: 1px solid #e2e8f0;
            border-radius: 8px;
            padding: 15px;
            transition: all 0.2s ease;
            cursor: pointer;
            position: relative;
        }
        
        .machine-summary-card:hover {
            transform: translateY(-2px);
            box-shadow: 0 4px 12px rgba(0, 0, 0, 0.1);
            border-color: #3b82f6;
            background: linear-gradient(135deg, #f0f9ff, #e0f2fe);
        }
        
        .machine-summary-header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 10px;
        }
        
        .machine-summary-name {
            font-weight: 600;
            color: #1e293b;
            font-size: 0.95em;
        }
        
        .machine-summary-size {
            font-weight: 600;
            color: #3b82f6;
        }
        
        .machine-summary-stats {
            display: flex;
            gap: 15px;
        }
        
        .machine-summary-stat {
            text-align: center;
        }
        
        .machine-summary-stat-value {
            display: block;
            font-size: 1.2em;
            font-weight: 600;
            color: #1e293b;
        }
        
        .machine-summary-stat-label {
            display: block;
            font-size: 0.75em;
            color: #64748b;
            margin-top: 2px;
        }
        
        /* Storage Tab Styles */
        .vm-section {
            background: #f8f9fa;
            border-radius: 10px;
            padding: 20px;
            margin-bottom: 20px;
            border: 1px solid #e2e8f0;
        }
        
        .vm-header {
            font-size: 1.1em;
            font-weight: 600;
            color: #1e293b;
            margin-bottom: 15px;
        }
        
        .retention-info {
            font-size: 0.9em;
            color: #64748b;
            font-weight: normal;
            margin-top: 5px;
        }
        
        .backup-stats {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
            gap: 20px;
            margin-bottom: 20px;
        }
        
        .backup-type {
            background: white;
            border-radius: 8px;
            padding: 20px;
            border: 1px solid #e2e8f0;
        }
        
        .backup-type h4 {
            margin: 0 0 15px 0;
            font-size: 1.1em;
            color: #1e40af;
        }
        
        .stat-row {
            display: flex;
            justify-content: space-between;
            margin: 8px 0;
            padding: 5px 0;
            border-bottom: 1px solid #f1f5f9;
        }
        
        .stat-row:last-child {
            border-bottom: none;
        }
        
        .stat-label {
            color: #64748b;
            font-size: 0.9em;
        }
        
        .stat-value {
            font-weight: 600;
            color: #1e293b;
            font-size: 0.9em;
        }
        
        /* Recommendations */
        .machine-recommendations {
            background: white;
            border-radius: 8px;
            padding: 20px;
            border: 1px solid #e2e8f0;
        }
        
        .recommendations-header {
            margin: 0 0 15px 0;
            font-size: 1.1em;
            color: #1e40af;
        }
        
        .machine-recommendation-item {
            padding: 12px;
            margin-bottom: 10px;
            border-radius: 6px;
            border-left: 4px solid;
        }
        
        .machine-recommendation-item.high {
            background: #fef2f2;
            border-color: #dc2626;
        }
        
        .machine-recommendation-item.medium {
            background: #fffbeb;
            border-color: #d97706;
        }
        
        .machine-recommendation-item.low {
            background: #f0f9ff;
            border-color: #3b82f6;
        }
        
        .recommendation-header-inline {
            display: flex;
            align-items: center;
            gap: 8px;
            margin-bottom: 5px;
        }
        
        .severity-badge-inline {
            padding: 2px 8px;
            border-radius: 12px;
            font-size: 0.75em;
            font-weight: 600;
            text-transform: uppercase;
        }
        
        .severity-badge-inline.high {
            background: #dc2626;
            color: white;
        }
        
        .severity-badge-inline.medium {
            background: #d97706;
            color: white;
        }
        
        .severity-badge-inline.low {
            background: #3b82f6;
            color: white;
        }
        
        .recommendation-message-inline {
            font-size: 0.9em;
            color: #334155;
        }
        
        .footer {
            background: #f8f9fa;
            text-align: center;
            padding: 20px;
            color: #64748b;
            font-size: 0.9em;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <img src="https://houit.com/images/hit-logo.svg" alt="HIT Logo" class="header-logo" />
            <h1>Veeam Backup Repository Analysis - $ServerName</h1>
            <p>Comprehensive backup file analysis and statistics</p>
        </div>
        
        <div class="content">
"@

        # Generate JavaScript for tabs and navigation
        $javascript = @'
function switchTab(repoId, tabName) {
    // Hide all tab contents for this repository
    const tabContents = document.querySelectorAll(`#tabs-${repoId} .tab-content`);
    tabContents.forEach(content => {
        content.classList.remove('active');
    });
    
    // Remove active class from all tab buttons for this repository
    const tabButtons = document.querySelectorAll(`#tabs-${repoId} .tab-button`);
    tabButtons.forEach(button => {
        button.classList.remove('active');
    });
    
    // Show the selected tab content
    const selectedContent = document.getElementById(`tab-${tabName}-${repoId}`);
    if (selectedContent) {
        selectedContent.classList.add('active');
    }
    
    // Add active class to the clicked button
    event.target.classList.add('active');
}

function navigateToMachineStorage(repoId, machineName) {
    // Switch to storage tab
    const storageButton = document.querySelector(`#tabs-${repoId} .tab-button[onclick*="storage"]`);
    if (storageButton) {
        storageButton.click();
    }
    
    // Scroll to the machine section after a short delay
    setTimeout(() => {
        const machineSection = document.getElementById(`machine-${repoId}-${machineName}`);
        if (machineSection) {
            machineSection.scrollIntoView({ behavior: 'smooth', block: 'start' });
            // Highlight the section briefly
            machineSection.style.background = 'rgba(59, 130, 246, 0.1)';
            setTimeout(() => {
                machineSection.style.background = '';
            }, 2000);
        }
    }, 300);
}

// Chart generation functions
const chartData = {};
const chartInstances = {};

function createStorageChart(chartId, machineNames, machineSizes, repoName, machineDetails) {
    const ctx = document.getElementById(chartId);
    if (!ctx) {
        console.error('Chart canvas not found:', chartId);
        return;
    }
    
    // Set up responsive canvas container
    const container = ctx.parentElement;
    if (container) {
        // Ensure the container has proper dimensions
        container.style.position = 'relative';
        container.style.height = '100%';
        container.style.width = '100%';
    }
    
    // Generate colors for each machine
    const colors = [
        'rgba(59, 130, 246, 0.8)',    // Blue
        'rgba(34, 197, 94, 0.8)',     // Green
        'rgba(239, 68, 68, 0.8)',     // Red
        'rgba(251, 146, 60, 0.8)',    // Orange
        'rgba(168, 85, 247, 0.8)',    // Purple
        'rgba(236, 72, 153, 0.8)',    // Pink
        'rgba(14, 165, 233, 0.8)',    // Sky
        'rgba(34, 197, 94, 0.8)',     // Emerald
        'rgba(245, 158, 11, 0.8)',    // Amber
        'rgba(239, 68, 68, 0.8)'      // Rose
    ];
    
    const borderColors = colors.map(color => color.replace('0.8', '1'));
    
    const config = {
        type: 'bar',
        data: {
            labels: machineNames,
            datasets: [{
                label: 'Storage Usage (GB)',
                data: machineSizes,
                backgroundColor: colors.slice(0, machineNames.length),
                borderColor: borderColors.slice(0, machineNames.length),
                borderWidth: 2,
                borderRadius: 6,
                borderSkipped: false
            }]
        },
        options: {
            responsive: true,
            maintainAspectRatio: false,
            interaction: {
                intersect: false,
                mode: 'index'
            },
            plugins: {
                title: {
                    display: false
                },
                legend: {
                    display: false
                },
                tooltip: {
                    backgroundColor: 'rgba(0, 0, 0, 0.9)',
                    titleColor: '#ffffff',
                    bodyColor: '#ffffff',
                    borderColor: 'rgba(255, 255, 255, 0.2)',
                    borderWidth: 1,
                    cornerRadius: 12,
                    padding: {
                        top: 20,
                        bottom: 25,
                        left: 22,
                        right: 22
                    },
                    displayColors: false,
                    titleFont: {
                        size: 14,
                        weight: 'bold'
                    },
                    bodyFont: {
                        size: 12,
                        lineHeight: 1.5
                    },
                    footerFont: {
                        size: 10,
                        weight: 'normal'
                    },
                    caretSize: 8,
                    caretPadding: 12,
                    yAlign: 'top',
                    xAlign: 'center',
                    position: 'nearest',
                    maxWidth: 400,
                    maxHeight: 500,
                    callbacks: {
                        title: function(context) {
                            const index = context[0].dataIndex;
                            const machineName = machineNames[index];
                            return '📁 ' + machineName;
                        },
                        beforeBody: function(context) {
                            return ''; // Add spacing
                        },
                        label: function(context) {
                            const index = context.dataIndex;
                            const machineDetail = machineDetails[index];
                            const value = context.parsed.y;
                            
                            let formattedValue;
                            if (value >= 1024) {
                                formattedValue = (value / 1024).toFixed(2) + ' TB';
                            } else {
                                formattedValue = value.toFixed(2) + ' GB';
                            }
                            
                            const lines = [
                                '💾 Total Storage: ' + formattedValue,
                                '',
                                '📊 Backup Files:',
                                '   🔵 Full Backups: ' + machineDetail.fullCount + ' files',
                                '   🟡 Incrementals: ' + machineDetail.incrementalCount + ' files',
                                '   🔄 Reverse Inc.: ' + machineDetail.reverseCount + ' files',
                                '   📈 Total Points: ' + (machineDetail.fullCount + machineDetail.incrementalCount + machineDetail.reverseCount),
                                ''
                            ];
                            
                            // Add storage breakdown
                            if (machineDetail.fullSizeGB > 0 || machineDetail.incrementalSizeGB > 0 || machineDetail.reverseSizeGB > 0) {
                                lines.push('💽 Storage Breakdown:');
                                if (machineDetail.fullSizeGB > 0) {
                                    const fullFormatted = machineDetail.fullSizeGB >= 1024 ? 
                                        (machineDetail.fullSizeGB / 1024).toFixed(1) + ' TB' : 
                                        machineDetail.fullSizeGB.toFixed(1) + ' GB';
                                    lines.push('   🔵 Full: ' + fullFormatted);
                                }
                                if (machineDetail.incrementalSizeGB > 0) {
                                    const incFormatted = machineDetail.incrementalSizeGB >= 1024 ? 
                                        (machineDetail.incrementalSizeGB / 1024).toFixed(1) + ' TB' : 
                                        machineDetail.incrementalSizeGB.toFixed(1) + ' GB';
                                    lines.push('   🟡 Incremental: ' + incFormatted);
                                }
                                if (machineDetail.reverseSizeGB > 0) {
                                    const revFormatted = machineDetail.reverseSizeGB >= 1024 ? 
                                        (machineDetail.reverseSizeGB / 1024).toFixed(1) + ' TB' : 
                                        machineDetail.reverseSizeGB.toFixed(1) + ' GB';
                                    lines.push('   🔄 Reverse: ' + revFormatted);
                                }
                                lines.push('');
                            }
                            
                            // Add last backup info
                            if (machineDetail.lastBackupDate && machineDetail.lastBackupDate !== 'Never') {
                                lines.push('📅 Last Backup: ' + machineDetail.lastBackupDate);
                                if (machineDetail.backupAge) {
                                    lines.push('⏰ Backup Age: ' + machineDetail.backupAge);
                                }
                                lines.push('');
                            }
                            
                            // Add health status
                            if (machineDetail.healthStatus) {
                                lines.push('🩺 Health: ' + machineDetail.healthStatus);
                                lines.push('');
                            }
                            
                            // Add efficiency metrics
                            if (machineDetail.avgBackupSize) {
                                lines.push('⚡ Performance:');
                                lines.push('   📈 Avg Backup Size: ' + machineDetail.avgBackupSize);
                                if (machineDetail.efficiency) {
                                    lines.push('   🎯 Storage Efficiency: ' + machineDetail.efficiency);
                                }
                            }
                            
                            return lines;
                        },
                        afterLabel: function(context) {
                            return ''; // Add spacing after main content
                        },
                        footer: function(context) {
                            return '💡 Click to view detailed analysis';
                        }
                    },
                    filter: function(tooltipItem) {
                        return true; // Show tooltip for all items
                    },
                    itemSort: function(a, b) {
                        return 0; // Keep original order
                    },
                    mode: 'index',
                    intersect: false,
                    enabled: true,
                    external: function(context) {
                        // Custom tooltip positioning to ensure it fits in viewport
                        const tooltip = context.tooltip;
                        if (!tooltip || tooltip.opacity === 0) {
                            return;
                        }
                        
                        const chart = context.chart;
                        const canvas = chart.canvas;
                        const canvasRect = canvas.getBoundingClientRect();
                        
                        // Enhanced tooltip positioning with larger height allowance
                        if (tooltip && tooltip.caretY !== undefined) {
                            const viewportHeight = window.innerHeight;
                            const viewportWidth = window.innerWidth;
                            const tooltipHeight = 450; // Estimated max tooltip height (reduced for larger charts)
                            const tooltipWidth = 350; // Estimated tooltip width
                            const margin = 30; // Increased safety margin from viewport edges
                            
                            // Vertical positioning
                            const spaceAbove = canvasRect.top + tooltip.caretY;
                            const spaceBelow = viewportHeight - (canvasRect.top + tooltip.caretY);
                            
                            if (spaceBelow < tooltipHeight + margin) {
                                // Not enough space below, position above
                                tooltip.yAlign = 'top';
                            } else {
                                // Enough space below, position below
                                tooltip.yAlign = 'bottom';
                            }
                            
                            // Horizontal positioning
                            const spaceLeft = canvasRect.left + tooltip.caretX;
                            const spaceRight = viewportWidth - (canvasRect.left + tooltip.caretX);
                            
                            if (spaceRight < tooltipWidth + margin && spaceLeft > tooltipWidth + margin) {
                                tooltip.xAlign = 'right';
                            } else if (spaceLeft < tooltipWidth + margin) {
                                tooltip.xAlign = 'left';
                            } else {
                                tooltip.xAlign = 'center';
                            }
                        }
                    }
                }
            },
            layout: {
                padding: {
                    top: 10,
                    bottom: 10,
                    left: 10,
                    right: 10
                }
            },
            scales: {
                y: {
                    beginAtZero: true,
                    grace: '5%',
                    title: {
                        display: true,
                        text: 'Storage (GB)',
                        font: {
                            size: 12,
                            weight: 'bold'
                        }
                    },
                    ticks: {
                        maxTicksLimit: 12,
                        callback: function(value) {
                            if (value >= 1024) {
                                return (value / 1024).toFixed(1) + 'TB';
                            }
                            return value.toFixed(0) + 'GB';
                        }
                    },
                    grid: {
                        color: 'rgba(0, 0, 0, 0.1)'
                    }
                },
                x: {
                    title: {
                        display: true,
                        text: 'Machines',
                        font: {
                            size: 12,
                            weight: 'bold'
                        }
                    },
                    ticks: {
                        maxRotation: 45,
                        minRotation: 0,
                        maxTicksLimit: 20
                    },
                    grid: {
                        display: false
                    }
                }
            },
            onClick: (event, elements) => {
                if (elements.length > 0) {
                    const index = elements[0].index;
                    const machineName = machineNames[index];
                    // Navigate to machine storage section
                    const repoId = chartId.replace('storageChart', 'repoChart');
                    navigateToMachineStorage(repoId, machineName);
                }
            }
        }
    };
    
    // Create chart instance
    const chartInstance = new Chart(ctx, config);
    
    // Store chart instance for potential cleanup
    chartInstances[chartId] = chartInstance;
    
    // Add resize observer to handle container size changes
    if (window.ResizeObserver) {
        const resizeObserver = new ResizeObserver(entries => {
            if (chartInstance && !chartInstance.isDestroyed) {
                chartInstance.resize();
            }
        });
        
        if (container) {
            resizeObserver.observe(container);
        }
    }
    
    // Handle window resize as fallback
    const handleResize = () => {
        if (chartInstance && !chartInstance.isDestroyed) {
            setTimeout(() => {
                chartInstance.resize();
            }, 100);
        }
    };
    
    window.addEventListener('resize', handleResize);
    
    // Store cleanup function
    chartInstance._cleanup = () => {
        window.removeEventListener('resize', handleResize);
        if (window.ResizeObserver && resizeObserver) {
            resizeObserver.disconnect();
        }
    };
}

// Cleanup function for charts
function cleanupCharts() {
    Object.values(chartInstances).forEach(chart => {
        if (chart && chart._cleanup) {
            chart._cleanup();
        }
        if (chart && !chart.isDestroyed) {
            chart.destroy();
        }
    });
    // Clear the instances object
    Object.keys(chartInstances).forEach(key => delete chartInstances[key]);
}

// Initialize charts when page loads
document.addEventListener('DOMContentLoaded', function() {
    // Charts will be initialized after the data is generated
    
    // Add viewport resize handling for better responsive behavior
    let resizeTimeout;
    window.addEventListener('resize', () => {
        clearTimeout(resizeTimeout);
        resizeTimeout = setTimeout(() => {
            Object.values(chartInstances).forEach(chart => {
                if (chart && !chart.isDestroyed) {
                    chart.resize();
                }
            });
        }, 250);
    });
});
'@

        # Add repository sections
        $repoIndex = 1
        foreach ($repository in $BackupLocations.Repositories) {
            $repoId = "repoChart$repoIndex"
            
            # Calculate repository stats
            $totalFullBackups = 0
            $totalIncrementalBackups = 0
            $totalReverseIncrementalBackups = 0
            $averageMachineSize = 0
            $largestMachine = ""
            $largestMachineSize = 0
            
            foreach ($machine in $repository.Machines.Values) {
                $totalFullBackups += $machine.FullBackups.Count
                $totalIncrementalBackups += $machine.IncrementalBackups.Count
                $totalReverseIncrementalBackups += $machine.ReverseIncrementalBackups.Count
                if ($machine.TotalSizeGB -gt $largestMachineSize) {
                    $largestMachineSize = $machine.TotalSizeGB
                    $largestMachine = $machine.Name
                }
            }
            
            if ($repository.Machines.Count -gt 0) {
                $averageMachineSize = [math]::Round($repository.TotalSizeGB / $repository.Machines.Count, 2)
            }
            
            # Calculate storage breakdown for this repository
            $repoIncrementalsGB = 0
            $repoReverseIncrementalsGB = 0
            $repoFullsGB = 0
            
            foreach ($machine in $repository.Machines.Values) {
                $repoIncrementalsGB += ($machine.IncrementalBackups | Measure-Object -Property SizeGB -Sum).Sum
                $repoReverseIncrementalsGB += ($machine.ReverseIncrementalBackups | Measure-Object -Property SizeGB -Sum).Sum
                $repoFullsGB += ($machine.FullBackups | Measure-Object -Property SizeGB -Sum).Sum
            }
            
            # Get drive capacity info 
            $totalCapacityGB = $repository.TotalSizeGB * 10  # Default assumption
            $freeSpaceGB = $totalCapacityGB - $repository.TotalSizeGB  # Default assumption
            
            if ($StorageMetrics.RepositoryInfo) {
                $totalCapacityGB = $StorageMetrics.RepositoryInfo.TotalCapacityTB * 1024
                $freeSpaceGB = $StorageMetrics.RepositoryInfo.FreeSpaceTB * 1024
            }
            
            # Calculate percentages for storage bar (relative to total drive capacity)
            $incrementalPercent = if ($totalCapacityGB -gt 0) { [math]::Round(($repoIncrementalsGB / $totalCapacityGB) * 100, 2) } else { 0 }
            $reverseIncrementalPercent = if ($totalCapacityGB -gt 0) { [math]::Round(($repoReverseIncrementalsGB / $totalCapacityGB) * 100, 2) } else { 0 }
            $fullPercent = if ($totalCapacityGB -gt 0) { [math]::Round(($repoFullsGB / $totalCapacityGB) * 100, 2) } else { 0 }
            
            $html += @"
            <!-- Repository Sections -->
            <div class="section">
                <h2 class="section-title">📦 Repository: $($repository.Name)</h2>
                <div class="repo-summary">
                    <p>📁 Path: $($repository.Path)</p>
                    <p>💻 Machines: $($repository.Machines.Count) | 📊 Total Size: $(Format-StorageSize $repository.TotalSizeGB)</p>
                    
                    <!-- Storage Usage Chart -->
                    <div class="chart-container" style="margin: 20px 0; background: white; border-radius: 10px; padding: 20px; box-shadow: 0 2px 8px rgba(0,0,0,0.1); height: 75vh; max-height: 800px; min-height: 400px; position: relative;">
                        <h3 style="text-align: center; margin-bottom: 20px; color: #1e293b; font-size: 1.1em;">📊 Storage Usage Per Machine (GB)</h3>
                        <div style="position: relative; height: calc(100% - 60px); width: 100%;">
                            <canvas id="storageChart$repoIndex"></canvas>
                        </div>
                    </div>
                    
                    <div class="storage-bar-container">
                        <div class="storage-bar-label">💾 Drive Storage Utilization</div>
                        <div class="storage-bar" title="Available Space: $(Format-StorageSize $freeSpaceGB) ($([math]::Round((($freeSpaceGB / $totalCapacityGB) * 100), 1))% of total drive capacity)">
"@
            
            # Add storage segments only if they have meaningful size
            if ($incrementalPercent -gt 0) {
                $html += @"
                            <div class="storage-segment incrementals" style="width: $incrementalPercent%" title="Incrementals: $(Format-StorageSize $repoIncrementalsGB)"></div>
"@
            }
            
            if ($reverseIncrementalPercent -gt 0) {
                $html += @"
                            <div class="storage-segment reverse-incrementals" style="width: $reverseIncrementalPercent%" title="Reverse Incrementals: $(Format-StorageSize $repoReverseIncrementalsGB)"></div>
"@
            }
            
            if ($fullPercent -gt 0) {
                $html += @"
                            <div class="storage-segment fulls" style="width: $fullPercent%" title="Full Backups: $(Format-StorageSize $repoFullsGB)"></div>
"@
            }
            
            $html += @"
                        </div>
                        <div class="storage-legend">
                            <div class="legend-item">
                                <div class="legend-color incrementals"></div>
                                <span>Incrementals ($(Format-StorageSize $repoIncrementalsGB))</span>
                            </div>
                            <div class="legend-item">
                                <div class="legend-color reverse-incrementals"></div>
                                <span>Reverse Inc. ($(Format-StorageSize $repoReverseIncrementalsGB))</span>
                            </div>
                            <div class="legend-item">
                                <div class="legend-color fulls"></div>
                                <span>Fulls ($(Format-StorageSize $repoFullsGB))</span>
                            </div>
                            <div class="legend-item">
                                <div class="legend-color available-space"></div>
                                <span>Available Space ($(Format-StorageSize $freeSpaceGB))</span>
                            </div>
                        </div>
                    </div>
                </div>
                
                <!-- Repository Tabs -->
                <div class="repo-tabs" id="tabs-$repoId">
                    <div class="tab-nav">
                        <button class="tab-button active" onclick="switchTab('$repoId', 'overview')">📊 Overview</button>
                        <button class="tab-button" onclick="switchTab('$repoId', 'machines')">💻 Machines</button>
                        <button class="tab-button" onclick="switchTab('$repoId', 'storage')">💾 Storage</button>
                        <button class="tab-button" onclick="switchTab('$repoId', 'recommendations')">💡 Recommendations</button>
                    </div>
                    
                    <!-- Overview Tab -->
                    <div id="tab-overview-$repoId" class="tab-content active">
                        <div class="tab-overview">
                            <div class="overview-card">
                                <h4>Repository Summary</h4>
                                <div class="overview-stat">
                                    <span class="overview-stat-label">📁 Path:</span>
                                    <span class="overview-stat-value">$($repository.Path)</span>
                                </div>
                                <div class="overview-stat">
                                    <span class="overview-stat-label">💻 Machines:</span>
                                    <span class="overview-stat-value">$($repository.Machines.Count)</span>
                                </div>
                                <div class="overview-stat">
                                    <span class="overview-stat-label">📊 Total Size:</span>
                                    <span class="overview-stat-value">$(Format-StorageSize $repository.TotalSizeGB)</span>
                                </div>
                            </div>
                            
                            <div class="overview-card">
                                <h4>Backup Distribution</h4>
                                <div class="overview-stat">
                                    <span class="overview-stat-label">🔵 Full Backups:</span>
                                    <span class="overview-stat-value">$totalFullBackups</span>
                                </div>
                                <div class="overview-stat">
                                    <span class="overview-stat-label">🟡 Incremental:</span>
                                    <span class="overview-stat-value">$totalIncrementalBackups</span>
                                </div>
                                <div class="overview-stat">
                                    <span class="overview-stat-label">🔄 Reverse Incremental:</span>
                                    <span class="overview-stat-value">$totalReverseIncrementalBackups</span>
                                </div>
                                <div class="overview-stat">
                                    <span class="overview-stat-label">📈 Total Backup Points:</span>
                                    <span class="overview-stat-value">$($repository.TotalFiles)</span>
                                </div>
                            </div>
                            
                            <div class="overview-card">
                                <h4>Performance Metrics</h4>
                                <div class="overview-stat">
                                    <span class="overview-stat-label">📈 Avg Size:</span>
                                    <span class="overview-stat-value">$(Format-StorageSize $averageMachineSize)</span>
                                </div>
                                <div class="overview-stat">
                                    <span class="overview-stat-label">🎯 Largest:</span>
                                    <span class="overview-stat-value">$largestMachine</span>
                                </div>
                                <div class="overview-stat">
                                    <span class="overview-stat-label">⚡ Efficiency:</span>
                                    <span class="overview-stat-value">$(if ($repository.TotalSizeGB -gt 5000) { "High Volume" } elseif ($repository.TotalSizeGB -gt 1000) { "Medium Volume" } else { "Low Volume" })</span>
                                </div>
                            </div>
                        </div>
                    </div>
                    
                    <!-- Machines Tab -->
                    <div id="tab-machines-$repoId" class="tab-content">
                        <div class="machines-grid">
"@
            
            # Sort machines by size for display
            $sortedMachines = $repository.Machines.GetEnumerator() | Sort-Object { $_.Value.TotalSizeGB } -Descending
            
            foreach ($machine in $sortedMachines) {
                $machineName = $machine.Key
                $machineData = $machine.Value
                
                $html += @"
                            <div class="machine-summary-card" onclick="navigateToMachineStorage('$repoId', '$($machineName.Replace("'", "\'"))')" title="Click to view detailed storage analysis">
                                <div class="machine-summary-header">
                                    <span class="machine-summary-name">📁 $machineName</span>
                                    <span class="machine-summary-size">$(Format-StorageSize $machineData.TotalSizeGB)</span>
                                </div>
                                <div class="machine-summary-stats">
                                    <div class="machine-summary-stat">
                                        <span class="machine-summary-stat-value">$($machineData.FullBackups.Count)</span>
                                        <span class="machine-summary-stat-label">Full Backups</span>
                                    </div>
                                    <div class="machine-summary-stat">
                                        <span class="machine-summary-stat-value">$($machineData.IncrementalBackups.Count)</span>
                                        <span class="machine-summary-stat-label">Incrementals</span>
                                    </div>
                                    <div class="machine-summary-stat">
                                        <span class="machine-summary-stat-value">$($machineData.ReverseIncrementalBackups.Count)</span>
                                        <span class="machine-summary-stat-label">Reverse</span>
                                    </div>
                                </div>
                            </div>
"@
            }
            
            $html += @"
                        </div>
                    </div>
                    
                    <!-- Storage Tab -->
                    <div id="tab-storage-$repoId" class="tab-content">
                        <div class="tab-overview">
                            <div class="overview-card">
                                <h4>Storage Breakdown</h4>
                                <div class="overview-stat">
                                    <span class="overview-stat-label">💾 Used Space:</span>
                                    <span class="overview-stat-value">$(Format-StorageSize $repository.TotalSizeGB)</span>
                                </div>
                                <div class="overview-stat">
                                    <span class="overview-stat-label">📊 Storage Health:</span>
                                    <span class="overview-stat-value">$(if ($repository.TotalSizeGB -gt 5000) { "Large Repository" } elseif ($repository.TotalSizeGB -gt 1000) { "Medium Repository" } else { "Small Repository" })</span>
                                </div>
                            </div>
                        </div>
                        
                        <!-- Detailed Machine Storage Analysis -->
"@
            
            # Add detailed machine storage sections
            foreach ($machine in $sortedMachines) {
                $machineName = $machine.Key
                $machineData = $machine.Value
                
                # Calculate backup point count
                $backupPoints = $machineData.FullBackups.Count + $machineData.IncrementalBackups.Count + $machineData.ReverseIncrementalBackups.Count
                
                # Build detailed storage section for each machine
                $html += @"
                        <div class="vm-section" id="machine-$repoId-$($machineName.Replace("'", "\'"))">
                            <div class="vm-header">
                                📁 $($repository.Name) : $machineName : $($machineData.Path)
                                <div class="retention-info">Currently has $backupPoints backup points in retention</div>
                            </div>
                            <div class="backup-stats">
                                <div class="backup-type incremental">
                                    <h4>🔴 Incrementals</h4>
"@
                
                if ($machineData.IncrementalBackups.Count -gt 0) {
                    $incStats = $machineData.IncrementalBackups | Measure-Object -Property SizeGB -Sum -Average -Maximum -Minimum
                    $lastInc = ($machineData.IncrementalBackups | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
                    
                    $html += @"
                                    <div class="stat-row">
                                        <span class="stat-label">Count:</span>
                                        <span class="stat-value">$($machineData.IncrementalBackups.Count) files</span>
                                    </div>
                                    <div class="stat-row">
                                        <span class="stat-label">Last Run:</span>
                                        <span class="stat-value">$(Get-Date $lastInc.LastWriteTime -Format "ddd yyyy-MM-dd HH:mm:ss")</span>
                                    </div>
                                    <div class="stat-row">
                                        <span class="stat-label">Smallest:</span>
                                        <span class="stat-value">$(Format-StorageSize $incStats.Minimum)</span>
                                    </div>
                                    <div class="stat-row">
                                        <span class="stat-label">Largest:</span>
                                        <span class="stat-value">$(Format-StorageSize $incStats.Maximum)</span>
                                    </div>
                                    <div class="stat-row">
                                        <span class="stat-label">Average:</span>
                                        <span class="stat-value">$(Format-StorageSize $incStats.Average)</span>
                                    </div>
                                    <div class="stat-row">
                                        <span class="stat-label">Total Size:</span>
                                        <span class="stat-value">$(Format-StorageSize $incStats.Sum)</span>
                                    </div>
"@
                } else {
                    $html += @"
                                    <div class="stat-row">
                                        <span class="stat-value">No incremental backups found</span>
                                    </div>
"@
                }
                
                $html += @"
                                </div>
                                <div class="backup-type vrb">
                                    <h4>🔄 Reverse Incrementals</h4>
"@
                
                if ($machineData.ReverseIncrementalBackups.Count -gt 0) {
                    $vrbStats = $machineData.ReverseIncrementalBackups | Measure-Object -Property SizeGB -Sum -Average -Maximum -Minimum
                    $lastVrb = ($machineData.ReverseIncrementalBackups | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
                    $vrbStdDev = if ($machineData.ReverseIncrementalBackups.Count -gt 1) {
                        Calculate-StandardDeviation -Values ($machineData.ReverseIncrementalBackups | Select-Object -ExpandProperty SizeGB)
                    } else { 0 }
                    
                    $html += @"
                                    <div class="stat-row">
                                        <span class="stat-label">Count:</span>
                                        <span class="stat-value">$($machineData.ReverseIncrementalBackups.Count) files</span>
                                    </div>
                                    <div class="stat-row">
                                        <span class="stat-label">Last Run:</span>
                                        <span class="stat-value">$(Get-Date $lastVrb.LastWriteTime -Format "ddd yyyy-MM-dd HH:mm:ss")</span>
                                    </div>
                                    <div class="stat-row">
                                        <span class="stat-label">Smallest:</span>
                                        <span class="stat-value">$(Format-StorageSize $vrbStats.Minimum)</span>
                                    </div>
                                    <div class="stat-row">
                                        <span class="stat-label">Largest:</span>
                                        <span class="stat-value">$(Format-StorageSize $vrbStats.Maximum)</span>
                                    </div>
                                    <div class="stat-row">
                                        <span class="stat-label">Average:</span>
                                        <span class="stat-value">$(Format-StorageSize $vrbStats.Average)</span>
                                    </div>
                                    <div class="stat-row">
                                        <span class="stat-label">Std Dev:</span>
                                        <span class="stat-value">$(Format-StorageSize $vrbStdDev)</span>
                                    </div>
                                    <div class="stat-row">
                                        <span class="stat-label">Total Size:</span>
                                        <span class="stat-value">$(Format-StorageSize $vrbStats.Sum)</span>
                                    </div>
"@
                } else {
                    $html += @"
                                    <div class="stat-row">
                                        <span class="stat-value">No reverse incremental backups found</span>
                                    </div>
"@
                }
                
                $html += @"
                                </div>
                                <div class="backup-type full">
                                    <h4>🟢 Fulls</h4>
"@
                
                if ($machineData.FullBackups.Count -gt 0) {
                    $fullStats = $machineData.FullBackups | Measure-Object -Property SizeGB -Sum -Average -Maximum -Minimum
                    $lastFull = ($machineData.FullBackups | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
                    $stdDev = if ($machineData.FullBackups.Count -gt 1) {
                        Calculate-StandardDeviation -Values ($machineData.FullBackups | Select-Object -ExpandProperty SizeGB)
                    } else { 0 }
                    
                    $html += @"
                                    <div class="stat-row">
                                        <span class="stat-label">Count:</span>
                                        <span class="stat-value">$($machineData.FullBackups.Count) files</span>
                                    </div>
                                    <div class="stat-row">
                                        <span class="stat-label">Last Run:</span>
                                        <span class="stat-value">$(Get-Date $lastFull.LastWriteTime -Format "ddd yyyy-MM-dd HH:mm:ss")</span>
                                    </div>
                                    <div class="stat-row">
                                        <span class="stat-label">Smallest:</span>
                                        <span class="stat-value">$(Format-StorageSize $fullStats.Minimum)</span>
                                    </div>
                                    <div class="stat-row">
                                        <span class="stat-label">Largest:</span>
                                        <span class="stat-value">$(Format-StorageSize $fullStats.Maximum)</span>
                                    </div>
                                    <div class="stat-row">
                                        <span class="stat-label">Average:</span>
                                        <span class="stat-value">$(Format-StorageSize $fullStats.Average)</span>
                                    </div>
                                    <div class="stat-row">
                                        <span class="stat-label">Std Dev:</span>
                                        <span class="stat-value">$(Format-StorageSize $stdDev)</span>
                                    </div>
                                    <div class="stat-row">
                                        <span class="stat-label">Total Size:</span>
                                        <span class="stat-value">$(Format-StorageSize $fullStats.Sum)</span>
                                    </div>
"@
                } else {
                    $html += @"
                                    <div class="stat-row">
                                        <span class="stat-value">No full backups found</span>
                                    </div>
"@
                }
                
                $html += @"
                                </div>
                            </div>
"@
                
                # Add machine-specific recommendations
                $machineRecommendations = @()
                
                # Check backup age
                if ($machineData.LastBackupDate) {
                    $daysSinceBackup = (New-TimeSpan -Start $machineData.LastBackupDate -End (Get-Date)).Days
                    if ($daysSinceBackup -gt 30) {
                        $machineRecommendations += @{
                            Severity = "high"
                            Icon = "🚨"
                            Category = "🩺"
                            CategoryName = "Backup Health"
                            Message = "⚠️ Backup is stale ($daysSinceBackup days old) - immediate attention required"
                        }
                    }
                }
                
                # Check retention
                if ($backupPoints -lt 7) {
                    $machineRecommendations += @{
                        Severity = "medium"
                        Icon = "⚠️"
                        Category = "🛡️"
                        CategoryName = "Risk Management"
                        Message = "⚠️ Low retention ($backupPoints points) - insufficient for disaster recovery. Consider 14-30 points"
                    }
                }
                
                # Check backup ratio
                if ($machineData.FullBackups.Count -gt 0 -and $machineData.IncrementalBackups.Count -eq 0) {
                    $potentialSavings = Format-StorageSize ($machineData.TotalSizeGB * 0.3)
                    $machineRecommendations += @{
                        Severity = "low"
                        Icon = "💡"
                        Category = "💾"
                        CategoryName = "Storage Optimization"
                        Message = "💾 High full backup ratio (100%) - could reduce storage by ~$potentialSavings with more incrementals"
                    }
                }
                
                # Check size anomalies
                if ($repository.Machines.Count -gt 1) {
                    $avgSize = [math]::Round($repository.TotalSizeGB / $repository.Machines.Count, 0)
                    if ($machineData.TotalSizeGB -gt ($avgSize * 2)) {
                        $percentOfRepo = [math]::Round(($machineData.TotalSizeGB / $repository.TotalSizeGB) * 100, 1)
                        $machineRecommendations += @{
                            Severity = "low"
                            Icon = "💡"
                            Category = "🔍"
                            CategoryName = "Storage Analysis"
                            Message = "🟢 Large storage consumer ($(Format-StorageSize $machineData.TotalSizeGB) vs $(Format-StorageSize $avgSize) avg) ($percentOfRepo% of repository) - monitor for optimization opportunities"
                        }
                    }
                }
                
                if ($machineRecommendations.Count -gt 0) {
                    $html += @"
                            <div class="machine-recommendations">
                                <h4 class="recommendations-header">💡 Storage Insights & Recommendations</h4>
                                <div class="recommendations-list">
"@
                    
                    foreach ($rec in $machineRecommendations) {
                        $html += @"
                                    <div class="machine-recommendation-item $($rec.Severity)">
                                        <div class="recommendation-header-inline">
                                            <span class="severity-icon">$($rec.Icon)</span>
                                            <span class="category-icon">$($rec.Category)</span>
                                            <span class="category-name">$($rec.CategoryName)</span>
                                            <span class="severity-badge-inline $($rec.Severity)">$($rec.Severity)</span>
                                        </div>
                                        <div class="recommendation-message-inline">$($rec.Message)</div>
                                    </div>
"@
                    }
                    
                    $html += @"
                                </div>
                            </div>
"@
                }
                
                $html += @"
                        </div>
"@
            }
            
            $html += @"
                    </div>
                    
                    <!-- Recommendations Tab -->
                    <div id="tab-recommendations-$repoId" class="tab-content">
                        <div class="tab-overview">
"@
            
            # Repository-level recommendations
            $repoRecommendations = @()
            

            
            # Check machine count
            if ($repository.Machines.Count -gt 50) {
                $repoRecommendations += @{
                    Type = "Performance"
                    Message = "High machine count ($($repository.Machines.Count)) - consider splitting into multiple repositories for better performance"
                    Severity = "Info"
                }
            }
            
            # Check backup distribution
            $fullRatio = if ($repository.TotalFiles -gt 0) { [math]::Round(($totalFullBackups / $repository.TotalFiles) * 100, 0) } else { 0 }
            if ($fullRatio -gt 70) {
                $repoRecommendations += @{
                    Type = "Storage Optimization"
                    Message = "High full backup ratio ($fullRatio%) - implement incremental backup strategies to reduce storage consumption"
                    Severity = "Info"
                }
            }
            
            if ($repoRecommendations.Count -eq 0) {
                $repoRecommendations += @{
                    Type = "Status"
                    Message = "Repository is operating within recommended parameters"
                    Severity = "Success"
                }
            }
            
            foreach ($rec in $repoRecommendations) {
                $severityClass = switch ($rec.Severity) {
                    "Success" { "low" }
                    "Info" { "low" }
                    "Warning" { "medium" }
                    default { "high" }
                }
                
                $html += @"
                            <div class="machine-recommendation-item $severityClass">
                                <div class="recommendation-header-inline">
                                    <span class="category-name">$($rec.Type)</span>
                                    <span class="severity-badge-inline $severityClass">$($rec.Severity)</span>
                                </div>
                                <div class="recommendation-message-inline">$($rec.Message)</div>
                            </div>
"@
            }
            
            $html += @"
                        </div>
                    </div>
                </div>
            </div>
"@
            
            $repoIndex++
        }
        
        # Generate chart initialization JavaScript
        $chartInitScript = ""
        $repoIndex = 1
        foreach ($repository in $BackupLocations.Repositories) {
            if ($repository.Machines.Count -gt 0) {
                # Prepare chart data for this repository
                $sortedMachines = $repository.Machines.GetEnumerator() | Sort-Object { $_.Value.TotalSizeGB } -Descending
                $machineNames = @()
                $machineSizes = @()
                $machineDetails = @()
                
                foreach ($machine in $sortedMachines) {
                    $machineName = $machine.Key
                    $machineData = $machine.Value
                    
                    # Calculate storage breakdown
                    $fullSizeGB = ($machineData.FullBackups | Measure-Object -Property SizeGB -Sum).Sum
                    $incrementalSizeGB = ($machineData.IncrementalBackups | Measure-Object -Property SizeGB -Sum).Sum
                    $reverseSizeGB = ($machineData.ReverseIncrementalBackups | Measure-Object -Property SizeGB -Sum).Sum
                    
                    # Calculate backup age and health
                    $lastBackupDate = "Never"
                    $backupAge = ""
                    $healthStatus = "Unknown"
                    
                    if ($machineData.LastBackupDate) {
                        $lastBackupDate = Get-Date $machineData.LastBackupDate -Format "MMM dd, yyyy HH:mm"
                        $daysSinceBackup = (New-TimeSpan -Start $machineData.LastBackupDate -End (Get-Date)).Days
                        
                        if ($daysSinceBackup -eq 0) {
                            $backupAge = "Today"
                            $healthStatus = "🟢 Excellent"
                        } elseif ($daysSinceBackup -le 1) {
                            $backupAge = "1 day ago"
                            $healthStatus = "🟢 Excellent"
                        } elseif ($daysSinceBackup -le 7) {
                            $backupAge = "$daysSinceBackup days ago"
                            $healthStatus = "🟡 Good"
                        } elseif ($daysSinceBackup -le 30) {
                            $backupAge = "$daysSinceBackup days ago"
                            $healthStatus = "🟠 Attention Needed"
                        } else {
                            $backupAge = "$daysSinceBackup days ago"
                            $healthStatus = "🔴 Critical"
                        }
                    }
                    
                    # Calculate average backup size
                    $allBackupSizes = @()
                    $allBackupSizes += $machineData.FullBackups | ForEach-Object { $_.SizeGB }
                    $allBackupSizes += $machineData.IncrementalBackups | ForEach-Object { $_.SizeGB }
                    $allBackupSizes += $machineData.ReverseIncrementalBackups | ForEach-Object { $_.SizeGB }
                    
                    $avgBackupSize = "N/A"
                    $efficiency = "N/A"
                    
                    if ($allBackupSizes.Count -gt 0) {
                        $avgSize = ($allBackupSizes | Measure-Object -Average).Average
                        $avgBackupSize = if ($avgSize -ge 1024) { 
                            "$([math]::Round($avgSize / 1024, 1)) TB" 
                        } else { 
                            "$([math]::Round($avgSize, 1)) GB" 
                        }
                        
                        # Calculate efficiency based on incremental vs full ratio
                        $totalFiles = $machineData.FullBackups.Count + $machineData.IncrementalBackups.Count + $machineData.ReverseIncrementalBackups.Count
                        if ($totalFiles -gt 0) {
                            $incrementalRatio = ($machineData.IncrementalBackups.Count + $machineData.ReverseIncrementalBackups.Count) / $totalFiles
                            if ($incrementalRatio -ge 0.8) {
                                $efficiency = "High (Good Inc. Ratio)"
                            } elseif ($incrementalRatio -ge 0.5) {
                                $efficiency = "Medium"
                            } else {
                                $efficiency = "Low (Too Many Fulls)"
                            }
                        }
                    }
                    
                    # Build machine detail object
                    $detailObject = @{
                        fullCount = $machineData.FullBackups.Count
                        incrementalCount = $machineData.IncrementalBackups.Count
                        reverseCount = $machineData.ReverseIncrementalBackups.Count
                        fullSizeGB = [math]::Round($fullSizeGB, 2)
                        incrementalSizeGB = [math]::Round($incrementalSizeGB, 2)
                        reverseSizeGB = [math]::Round($reverseSizeGB, 2)
                        lastBackupDate = $lastBackupDate
                        backupAge = $backupAge
                        healthStatus = $healthStatus
                        avgBackupSize = $avgBackupSize
                        efficiency = $efficiency
                    }
                    
                    # Convert to JSON-safe format for JavaScript
                    $detailJSON = "{"
                    $detailJSON += "fullCount: $($detailObject.fullCount),"
                    $detailJSON += "incrementalCount: $($detailObject.incrementalCount),"
                    $detailJSON += "reverseCount: $($detailObject.reverseCount),"
                    $detailJSON += "fullSizeGB: $($detailObject.fullSizeGB),"
                    $detailJSON += "incrementalSizeGB: $($detailObject.incrementalSizeGB),"
                    $detailJSON += "reverseSizeGB: $($detailObject.reverseSizeGB),"
                    $detailJSON += "lastBackupDate: `"$($detailObject.lastBackupDate.Replace('"', '\"'))`","
                    $detailJSON += "backupAge: `"$($detailObject.backupAge.Replace('"', '\"'))`","
                    $detailJSON += "healthStatus: `"$($detailObject.healthStatus.Replace('"', '\"'))`","
                    $detailJSON += "avgBackupSize: `"$($detailObject.avgBackupSize.Replace('"', '\"'))`","
                    $detailJSON += "efficiency: `"$($detailObject.efficiency.Replace('"', '\"'))`""
                    $detailJSON += "}"
                    
                    $machineNames += """$($machineName.Replace('"', '\"'))"""
                    $machineSizes += $machineData.TotalSizeGB
                    $machineDetails += $detailJSON
                }
                
                $machineNamesJS = "[" + ($machineNames -join ", ") + "]"
                $machineSizesJS = "[" + ($machineSizes -join ", ") + "]"
                $machineDetailsJS = "[" + ($machineDetails -join ", ") + "]"
                $repoNameJS = """$($repository.Name.Replace('"', '\"'))"""
                
                $chartInitScript += @"
        // Initialize chart for repository $repoIndex
        createStorageChart('storageChart$repoIndex', $machineNamesJS, $machineSizesJS, $repoNameJS, $machineDetailsJS);
        
"@
            }
            $repoIndex++
        }
        
        # Add footer
        $html += @"
        </div>
        
        <div class="footer">
            <p>Generated on $(Get-Date -Format "MMMM dd, yyyy 'at' HH:mm:ss")</p>
        </div>
    </div>
    
    <script>
        $javascript
        
        // Initialize all charts when DOM is ready
        document.addEventListener('DOMContentLoaded', function() {
            console.log('Initializing storage charts...');
            $chartInitScript
            console.log('All charts initialized successfully!');
        });
    </script>
</body>
</html>
"@

        # Write HTML to file
        $html | Out-File -FilePath $OutputPath -Encoding UTF8
        
        Write-Log "✅ HTML report generated successfully: $OutputPath" 'INFORMATIONAL'
        return $OutputPath
    }
    catch {
        Write-Log "❌ Error generating HTML report: $_" 'FAILURE'
        return $null
    }
}

# Function to find ALL backup locations on the drive (repositories + ADHOC)
function Find-AllBackupLocations {
    param([string]$RootPath)
    
    Write-Log "🔍 Starting comprehensive Veeam backup discovery on $RootPath" 'INFORMATIONAL'
    
    if (-not (Test-Path $RootPath)) {
        Write-Log "❌ Error: Root path '$RootPath' does not exist or is not accessible" 'FAILURE'
        return @{
            Repositories = @()
            AdhocBackups = @()
            TotalBackupFiles = 0
        }
    }
    
    $result = @{
        Repositories = @()
        AdhocBackups = @()
        TotalBackupFiles = 0
    }
    
    Write-Log "🔍 Scanning entire drive for VIB and VBK files..." 'INFORMATIONAL'
    
    try {
        # First, find ALL VIB and VBK files on the drive
        $allBackupFiles = Get-ChildItem -Path $RootPath -Recurse -Include "*.vbk", "*.vib", "*.vrb" -ErrorAction SilentlyContinue
        $result.TotalBackupFiles = $allBackupFiles.Count
        
        Write-Log "📊 Found $($allBackupFiles.Count) total backup files (.vbk/.vib/.vrb) on the drive" 'INFORMATIONAL'
        
        if ($allBackupFiles.Count -eq 0) {
            Write-Log "⚠️ No Veeam backup files found on the drive" 'WARNING'
            return $result
        }
        
        # Group backup files by their parent directory
        $directoryGroups = $allBackupFiles | Group-Object { $_.Directory.FullName }
        
        Write-Log "📁 Backup files found in $($directoryGroups.Count) different directories" 'INFORMATIONAL'
        
        # First pass: Group all directories by their parent directory to identify potential repositories
        $parentDirectoryGroups = @{}
        
        foreach ($dirGroup in $directoryGroups) {
            $directory = $dirGroup.Name
            $parentPath = Split-Path $directory -Parent
            
            if (-not $parentDirectoryGroups.ContainsKey($parentPath)) {
                $parentDirectoryGroups[$parentPath] = @()
            }
            $parentDirectoryGroups[$parentPath] += $dirGroup
        }
        
        Write-Log "🔍 Analyzing $($parentDirectoryGroups.Count) potential repository locations..." 'INFORMATIONAL'
        
        # Analyze each parent directory to determine repositories vs ADHOC
        foreach ($parentPath in $parentDirectoryGroups.Keys) {
            $machineDirectoriesInParent = $parentDirectoryGroups[$parentPath]
            
            Write-Log "🔍 Checking parent: $parentPath ($($machineDirectoriesInParent.Count) machine directories)" 'INFORMATIONAL'
            
            # Check if this is the root drive (e.g., "V:\")
            $isRootDrive = $parentPath -match '^[A-Za-z]:\\?$'
            
            # If parent contains multiple machine directories with backups AND it's not the root drive, it's a repository
            if ($machineDirectoriesInParent.Count -gt 1 -and -not $isRootDrive) {
                # This is a repository
                $repositoryName = Split-Path $parentPath -Leaf
                if ([string]::IsNullOrEmpty($repositoryName)) {
                    $repositoryName = "Root-Repository"
                }
                
                Write-Log "✅ Repository detected: '$repositoryName' with $($machineDirectoriesInParent.Count) machines" 'INFORMATIONAL'
                
                # Create repository entry
                $newRepo = @{
                    Name = $repositoryName
                    Path = $parentPath
                    Type = "Repository"
                    Machines = @{}
                    TotalFiles = 0
                    TotalSizeGB = 0
                }
                $result.Repositories += $newRepo
                
                # Process each machine in this repository
                foreach ($dirGroup in $machineDirectoriesInParent) {
                    $directory = $dirGroup.Name
                    $filesInDir = $dirGroup.Group
                    $currentDirName = Split-Path $directory -Leaf
                    
                    Write-Log "  📦 Processing repository machine: $currentDirName ($($filesInDir.Count) files)" 'INFORMATIONAL'
                    
                    # Add machine to repository
                    $newRepo.Machines[$currentDirName] = @{
                        Name = $currentDirName
                        Path = $directory
                        FullBackups = @()
                        IncrementalBackups = @()
                        ReverseIncrementalBackups = @()
                        TotalSize = 0
                        LastBackupDate = $null
                    }
                    
                    $machineData = $newRepo.Machines[$currentDirName]
                    
                    # Process files for this machine
                    foreach ($file in $filesInDir) {
                        $backupInfo = @{
                            FileName = $file.Name
                            Size = $file.Length
                            SizeGB = [math]::Round($file.Length / 1GB, 2)
                            CreationTime = $file.CreationTime
                            LastWriteTime = $file.LastWriteTime
                            FullPath = $file.FullName
                        }
                        
                        if ($file.Extension -eq ".vbk") {
                            $machineData.FullBackups += $backupInfo
                            Write-Log "    📦 Repository Full: $($file.Name) ($(Format-StorageSize $backupInfo.SizeGB))" 'INFORMATIONAL'
                        }
                        elseif ($file.Extension -eq ".vib") {
                            $machineData.IncrementalBackups += $backupInfo
                            Write-Log "    📈 Repository Incremental: $($file.Name) ($(Format-StorageSize $backupInfo.SizeGB))" 'INFORMATIONAL'
                        }
                        elseif ($file.Extension -eq ".vrb") {
                            $machineData.ReverseIncrementalBackups += $backupInfo
                            Write-Log "    🔄 Repository Reverse Incremental: $($file.Name) ($(Format-StorageSize $backupInfo.SizeGB))" 'INFORMATIONAL'
                        }
                        else {
                            Write-Log "    ⚠️ Unknown backup file type: $($file.Name) with extension $($file.Extension)" 'WARNING'
                        }
                        
                        $machineData.TotalSize += $file.Length
                        $newRepo.TotalFiles++
                        $newRepo.TotalSizeGB += $backupInfo.SizeGB
                    }
                    
                    # Update machine metrics
                    $machineData.TotalSizeGB = [math]::Round($machineData.TotalSize / 1GB, 2)
                    $allBackups = $machineData.FullBackups + $machineData.IncrementalBackups + $machineData.ReverseIncrementalBackups
                    if ($allBackups.Count -gt 0) {
                        $machineData.LastBackupDate = ($allBackups | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
                    }
                }
            }
            else {
                # Single machine directory OR root drive machines - these are ADHOC backups
                if ($isRootDrive) {
                    Write-Log "🎯 Root drive machines detected - treating as ADHOC: $parentPath ($($machineDirectoriesInParent.Count) directories)" 'INFORMATIONAL'
                } else {
                    Write-Log "🎯 Single machine directory detected - treating as ADHOC: $parentPath" 'INFORMATIONAL'
                }
                
                # Process all machine directories in this parent as ADHOC
                foreach ($dirGroup in $machineDirectoriesInParent) {
                    $directory = $dirGroup.Name
                    $filesInDir = $dirGroup.Group
                    
                    Write-Log "🎯 ADHOC backup location: $directory ($($filesInDir.Count) files)" 'INFORMATIONAL'
                    
                    foreach ($file in $filesInDir) {
                        $backupInfo = @{
                            FileName = $file.Name
                            Size = $file.Length
                            SizeGB = [math]::Round($file.Length / 1GB, 2)
                            CreationTime = $file.CreationTime
                            LastWriteTime = $file.LastWriteTime
                            FullPath = $file.FullName
                            Directory = $directory
                            Type = if ($file.Extension -eq ".vbk") { "Full" } elseif ($file.Extension -eq ".vrb") { "ReverseIncremental" } else { "Incremental" }
                            BackupType = "ADHOC"
                        }
                        
                        $result.AdhocBackups += $backupInfo
                        Write-Log "    🎯 ADHOC $($backupInfo.Type): $($file.Name) ($(Format-StorageSize $backupInfo.SizeGB))" 'INFORMATIONAL'
                    }
                }
            }
        }
        
        # Summary logging
        Write-Log "📊 Discovery Summary:" 'INFORMATIONAL'
        Write-Log "  📦 Repositories found: $($result.Repositories.Count) (excluding root drive)" 'INFORMATIONAL'
        foreach ($repo in $result.Repositories) {
            Write-Log "    🏢 $($repo.Name): $($repo.Machines.Count) machines, $($repo.TotalFiles) files, $(Format-StorageSize $repo.TotalSizeGB)" 'INFORMATIONAL'
        }
        Write-Log "  🎯 ADHOC backups found: $($result.AdhocBackups.Count) files (individual files + root drive machines)" 'INFORMATIONAL'
        
        if ($result.AdhocBackups.Count -gt 0) {
            $adhocSizeGB = ($result.AdhocBackups | Measure-Object -Property SizeGB -Sum).Sum
            Write-Log "    💾 ADHOC total size: $(Format-StorageSize $adhocSizeGB)" 'INFORMATIONAL'
        }
        
        return $result
    }
    catch {
        Write-Log "❌ Error during backup discovery: $_" 'FAILURE'
        return $result
    }
}

function Run-ReportForMappedDrive {
    param(
        $DriveLetter
    )
    
    Write-Log "🚀 Starting comprehensive backup scan on $DriveLetter" 'INFORMATIONAL'
    
    try {
        # Get server name for report
        $serverName = $env:COMPUTERNAME.ToUpper()
        if ($script:SelectedServerName) {
            $serverName = $script:SelectedServerName
        }
        
        # Discover all backup locations
        $backupLocations = Find-AllBackupLocations -RootPath $DriveLetter
        
        if ($backupLocations.TotalBackupFiles -eq 0) {
            Write-Log "❌ No Veeam backup files found on the drive" 'FAILURE'
            return
        }
        
        # Build comprehensive backup inventory
        $backupInventory = @{}
        
        # Process repository backups
        foreach ($repository in $backupLocations.Repositories) {
            Write-Log "📦 Processing repository: $($repository.Name)" 'INFORMATIONAL'
            
            foreach ($machineName in $repository.Machines.Keys) {
                $machineData = $repository.Machines[$machineName]
                
                # Add repository information to machine data
                $machineData.RepositoryName = $repository.Name
                $machineData.RepositoryPath = $repository.Path
                $machineData.BackupType = "Repository"
                
                # Add to main inventory with unique key
                $inventoryKey = "$($repository.Name)::$machineName"
                $backupInventory[$inventoryKey] = $machineData
                
                Write-Log "  ✅ Added repository machine: $inventoryKey ($(Format-StorageSize $machineData.TotalSizeGB))" 'INFORMATIONAL'
            }
        }
        
        # Process ADHOC backups - create "Ad-Hoc Backups" repository only if there are ADHOC backups
        if ($backupLocations.AdhocBackups.Count -gt 0) {
            Write-Log "🎯 Processing ADHOC backups..." 'INFORMATIONAL'
            
            # Create a virtual "Ad-Hoc Backups" repository
            $adhocRepository = @{
                Name = "Ad-Hoc Backups"
                Path = "Various Locations"
                Type = "Repository"
                Machines = @{}
                TotalFiles = 0
                TotalSizeGB = 0
            }
            $backupLocations.Repositories += $adhocRepository
            
            # Group ADHOC backups by extracted machine name or directory
            $adhocGroups = @{}
            
            foreach ($adhocBackup in $backupLocations.AdhocBackups) {
                # Try to extract machine name from filename
                $machineName = $null
                $fileName = $adhocBackup.FileName
                
                # Common Veeam filename patterns
                if ($fileName -match '^(.+?)(\d{4}-\d{2}-\d{2}T\d{6})\.v[bi][kb]$') {
                    $machineName = $matches[1] -replace '[DWM]$', ''  # Remove schedule suffixes
                }
                elseif ($fileName -match '^(.+?)\.v[bi][kb]$') {
                    $machineName = $matches[1]
                }
                else {
                    # Fallback to directory name
                    $machineName = Split-Path $adhocBackup.Directory -Leaf
                }
                
                # Clean machine name
                $machineName = $machineName.Trim()
                if ([string]::IsNullOrEmpty($machineName)) {
                    $machineName = "Unknown-ADHOC"
                }
                
                # Group key includes directory to avoid conflicts - use unique identifier for ADHOC
                $uniqueKey = "$machineName-$(Split-Path $adhocBackup.Directory -Leaf)"
                
                if (-not $adhocGroups.ContainsKey($uniqueKey)) {
                    $adhocGroups[$uniqueKey] = @{
                        Name = $uniqueKey
                        Path = $adhocBackup.Directory
                        FullBackups = @()
                        IncrementalBackups = @()
                        ReverseIncrementalBackups = @()
                        TotalSize = 0
                        LastBackupDate = $null
                    }
                    $adhocRepository.Machines[$uniqueKey] = $adhocGroups[$uniqueKey]
                }
                
                $groupData = $adhocGroups[$uniqueKey]
                
                # Add backup to appropriate collection
                if ($adhocBackup.Type -eq "Full") {
                    $groupData.FullBackups += $adhocBackup
                }
                elseif ($adhocBackup.Type -eq "ReverseIncremental") {
                    $groupData.ReverseIncrementalBackups += $adhocBackup
                }
                else {
                    $groupData.IncrementalBackups += $adhocBackup
                }
                
                $groupData.TotalSize += $adhocBackup.Size
                $adhocRepository.TotalFiles++
                $adhocRepository.TotalSizeGB += $adhocBackup.SizeGB
            }
            
            # Add ADHOC machines to inventory under "Ad-Hoc Backups" repository
            foreach ($uniqueKey in $adhocGroups.Keys) {
                $groupData = $adhocGroups[$uniqueKey]
                $groupData.TotalSizeGB = [math]::Round($groupData.TotalSize / 1GB, 2)
                
                # Find latest backup date
                $allBackups = $groupData.FullBackups + $groupData.IncrementalBackups + $groupData.ReverseIncrementalBackups
                if ($allBackups.Count -gt 0) {
                    $groupData.LastBackupDate = ($allBackups | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
                }
                
                # Add machine data with repository info
                $groupData.RepositoryName = "Ad-Hoc Backups"
                $groupData.RepositoryPath = "Various Locations"
                $groupData.BackupType = "Repository"
                
                # Add to main inventory with repository key format
                $inventoryKey = "Ad-Hoc Backups::$uniqueKey"
                $backupInventory[$inventoryKey] = $groupData
                
                                    Write-Log "  🎯 Added ADHOC machine: $inventoryKey ($(Format-StorageSize $groupData.TotalSizeGB), $($allBackups.Count) files)" 'INFORMATIONAL'
            }
        }
        
        $totalMachines = $backupInventory.Count
        $totalRepositories = $backupLocations.Repositories.Count
        $totalAdhocGroups = ($backupInventory.Keys | Where-Object { $_ -like "Ad-Hoc Backups::*" }).Count
        
        Write-Log "✅ Comprehensive scan completed successfully" 'INFORMATIONAL'
        if ($totalAdhocGroups -gt 0) {
            Write-Log "📊 Total entities: $totalMachines ($($totalRepositories - 1) standard repositories, 1 ADHOC repository with $totalAdhocGroups groups)" 'INFORMATIONAL'
        } else {
            Write-Log "📊 Total entities: $totalMachines ($totalRepositories repositories, no ADHOC backups found)" 'INFORMATIONAL'
        }
        
        # Validate scan results
        if ($totalMachines -eq 0) {
            Write-Log "❌ No machines found during scan" 'FAILURE'
            return
        }
        
        if ($totalRepositories -eq 0) {
            Write-Log "❌ No repositories were created during scan" 'FAILURE'
            return
        }
        
        Write-Log "✅ Scan validation passed: $totalMachines machines in $totalRepositories repositories" 'INFORMATIONAL'
        
        # Measure storage metrics
        Write-Log "📊 Calculating storage metrics..." 'INFORMATIONAL'
        $storageMetrics = Measure-StorageMetrics -BackupInventory $backupInventory
        
        # Get actual disk space information
        $backupDrive = $DriveLetter
        try {
            $driveInfo = Get-WmiObject -Class Win32_LogicalDisk | Where-Object { $_.DeviceID -eq $backupDrive }
            if ($driveInfo) {
                $totalCapacityTB = [math]::Round($driveInfo.Size / 1TB, 2)
                $usedSpaceTB = [math]::Round(($driveInfo.Size - $driveInfo.FreeSpace) / 1TB, 2)
                $freeSpaceTB = [math]::Round($driveInfo.FreeSpace / 1TB, 2)
                $backupDataTB = [math]::Round($storageMetrics.TotalStorageGB / 1024, 2)
                $usagePercent = [math]::Round(($usedSpaceTB / $totalCapacityTB) * 100, 1)
                
                # Add repository info to storage metrics
                $storageMetrics.RepositoryInfo = @{
                    TotalCapacityTB = $totalCapacityTB
                    UsedSpaceTB = $usedSpaceTB
                    FreeSpaceTB = $freeSpaceTB
                    BackupDataTB = $backupDataTB
                    UsagePercent = $usagePercent
                    BackupDrive = $backupDrive
                }
            }
        } catch {
            # Fallback if WMI fails
            Write-Log "⚠️ Could not retrieve disk space information: $_" 'WARNING'
        }
        
        # Generate recommendations
        Write-Log "💡 Generating storage recommendations..." 'INFORMATIONAL'
        $recommendations = Get-StorageRecommendations -StorageMetrics $storageMetrics
        
        # Generate HTML report
        Write-Log "📝 Generating comprehensive HTML report..." 'INFORMATIONAL'
        $reportPath = New-HTMLReport -BackupInventory $backupInventory -StorageMetrics $storageMetrics -BackupLocations $backupLocations -ServerName $serverName
        
        if ($reportPath -and (Test-Path $reportPath)) {
            Write-Log "✅ Report generated successfully for $serverName`: $reportPath" 'INFORMATIONAL'
            
            # Automatically launch the report
            try {
                Start-Process $reportPath
                Write-Log "🚀 HTML report opened in default browser" 'INFORMATIONAL'
            }
            catch {
                Write-Log "⚠️ Failed to open report automatically: $_" 'WARNING'
                Write-Log "Report location: $reportPath" 'INFORMATIONAL'
            }
        }
    }
    catch {
        Write-Log "❌ Error during report generation: $_" 'FAILURE'
    }
    finally {
        # Clean up drive mapping
        Remove-NetworkDrive -DriveLetter $DriveLetter
        Write-Log "🏁 ==== End of Session ====" 'INFORMATIONAL'
    }
}
function Add-NewServerProfile {
    Write-Log "➕ Adding a new server profile." 'INFORMATIONAL'
        Write-Log "❓ Prompting user for UNC path to Veeam repository" 'INFORMATIONAL'
    $UNCPath = Read-Host "Enter UNC path to Veeam repository (e.g. \\server\share)"
        if ([string]::IsNullOrWhiteSpace($UNCPath)) {
            Write-Log "❌ UNC path is empty. Aborting add operation." 'FAILURE'
        return $false
        }
        if (-not $UNCPath.StartsWith("\\")) {
            Write-Log "❌ UNC path does not start with \\. Aborting add operation." 'FAILURE'
        return $false
        }
        Write-Log "📝 User entered UNC path: $UNCPath" 'INFORMATIONAL'
        Write-Log "❓ Prompting user for username" 'INFORMATIONAL'
        $Username = Read-Host "Enter username"
        if ([string]::IsNullOrWhiteSpace($Username)) {
            Write-Log "❌ Username is empty. Aborting add operation." 'FAILURE'
        return $false
        }
        Write-Log "📝 User entered username: $Username" 'INFORMATIONAL'
        Write-Log "❓ Prompting user for password (secure input)" 'INFORMATIONAL'
        $SecurePassword = Read-Host "Enter password" -AsSecureString
        if (-not $SecurePassword -or $SecurePassword.Length -eq 0) {
            Write-Log "❌ Password is empty. Aborting add operation." 'FAILURE'
        return $false
        }
        Write-Log "🔒 User entered password (hidden)." 'INFORMATIONAL'
    
    # Convert SecureString to plain string for registry storage
        $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
        $Password = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($BSTR)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
    
        $available = Get-AvailableDriveLetters
        Write-Log "🔍 Available drive letters: $($available -join ', ')" 'INFORMATIONAL'
    $suggested = if ($available -contains 'V') { 'V' } else { $available | Sort-Object | Select-Object -First 1 }
        do {
        $prompt = "Enter drive letter to use (choose one: $($available -join ', ')) [Suggested: $suggested]"
        Write-Log "❓ Prompting user for drive letter selection" 'INFORMATIONAL'
        $DriveLetterInput = Read-Host $prompt
        if ([string]::IsNullOrWhiteSpace($DriveLetterInput)) { $DriveLetterInput = $suggested }
        $DriveLetterInput = [string]$DriveLetterInput
            $DriveLetterInput = $DriveLetterInput.ToUpper()
            if ($DriveLetterInput.Length -ne 1 -or $DriveLetterInput -notin $available) {
                Write-Log "⚠️ Invalid drive letter entered: $DriveLetterInput" 'WARNING'
                Write-Log "⚠️ Invalid drive letter. Please try again." 'WARNING'
            }
        } while ($DriveLetterInput.Length -ne 1 -or $DriveLetterInput -notin $available)
        $DriveLetter = "$DriveLetterInput`:"
        Write-Log "💾 User selected drive letter: $DriveLetter" 'INFORMATIONAL'
    
        # Parse server name from UNC path
        $ServerName = $null
        if ($UNCPath -match '^\\\\([^\\]+)') { $ServerName = $matches[1] }
        $key = Sanitize-KeyName -UNCPath $UNCPath -Username $Username
        Write-Log "🔑 Generated registry key for new profile: $key" 'INFORMATIONAL'
    
    # Map the drive and run report generation
        Write-Log "🔗 Attempting to map drive $DriveLetter to $UNCPath for $Username..." 'INFORMATIONAL'
    if (New-NetworkDrive -DriveLetter $DriveLetter -UNCPath $UNCPath -Username $Username -Password $SecurePassword) {
            Write-Log "✅ Drive mapping succeeded. Saving new server profile to registry." 'INFORMATIONAL'
            Save-ServerSettings -UNCPath $UNCPath -Username $Username -Password $Password -DriveLetter $DriveLetter -KeyName $key -ServerName $ServerName
        Write-Log "✅ Running backup analysis and report generation." 'INFORMATIONAL'
        Run-ReportForMappedDrive -DriveLetter $DriveLetter
        Update-HTMLLog
        Keep-LastNLogs -N 3
        Write-Log "HTML activity log updated with new server profile and report generation" 'INFORMATIONAL'
        Show-ReturnToMenuPrompt "✅ New server profile added and report completed! Press any key to return to menu..." "Green"
        return $true
        } else {
            Write-Log "❌ Drive mapping failed. Server not saved to registry." 'FAILURE'
        return $false
    }
}
function Test-DriveMapping {
    param(
        $DriveLetter,
        $UNCPath,
        $Username
    )
    
    Write-Log "🔍 Running drive mapping diagnostics..." 'INFORMATIONAL'
    
    # Check if drive letter is already in use
    $existingDrives = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue
    $driveInUse = $existingDrives | Where-Object { $_.Name -eq $DriveLetter.Replace(":","") }
    
    if ($driveInUse) {
        Write-Log "⚠️ Drive $DriveLetter is already mapped to: $($driveInUse.DisplayRoot)" 'WARNING'
    } else {
        Write-Log "✅ Drive $DriveLetter is available" 'INFORMATIONAL'
    }
    
    # Check network connectivity to server
    if ($UNCPath -match '^\\\\([^\\]+)') {
        $serverName = $matches[1]
        Write-Log "🌐 Testing connectivity to server: $serverName" 'INFORMATIONAL'
        
        try {
            $ping = Test-Connection -ComputerName $serverName -Count 1 -Quiet -ErrorAction SilentlyContinue
            if ($ping) {
                Write-Log "✅ Server $serverName is reachable" 'INFORMATIONAL'
            } else {
                Write-Log "❌ Server $serverName is not reachable" 'FAILURE'
            }
        } catch {
            Write-Log "⚠️ Could not test connectivity to $serverName" 'WARNING'
        }
    }
    
    # Show current network mappings
    Write-Log "📋 Current network drive mappings:" 'INFORMATIONAL'
    try {
        $netUseOutput = cmd /c "net use" 2>&1
        if ($netUseOutput) {
            $netUseOutput | ForEach-Object { 
                if ($_ -match "^\s*([A-Z]:)\s+(.+)$") {
                    Write-Log "   $($matches[1]) -> $($matches[2])" 'INFORMATIONAL'
                }
            }
        } else {
            Write-Log "   No network drives currently mapped" 'INFORMATIONAL'
        }
    } catch {
        Write-Log "   Could not retrieve network mappings" 'WARNING'
    }
}

# =====================
# Now do your startup logic
# =====================
Clear-Host
Show-Banner

$now = Get-Date
$script:LogFileName = "VeeamItUpPlusLog-" + $now.ToString("yyyy-MMM-dd-ddd-hhmmtt").Replace(":","") + ".html"
$script:DownloadsPath = Join-Path $env:USERPROFILE "Downloads"
$script:LogFilePath = Join-Path $script:DownloadsPath $script:LogFileName

$script:LogBuffer = @()
$script:HtmlLogBuffer = @()
$script:LogLevelOrder = @{ 'ALL'=0; 'INFORMATIONAL'=1; 'WARNING'=2; 'FAILURE'=3; 'CRITICAL'=4 }
$script:CurrentLogLevel = 'ALL'
$script:ConnectivityResults = @{}

Write-Log "🚀 VeeamItUp+ Console started" 'INFORMATIONAL'
Write-Log "🌐 Initializing HTML activity log..." 'INFORMATIONAL'
Update-HTMLLog  # Use the HTML log function
Keep-LastNLogs -N 3
Write-Log "📱 HTML activity log initialized - use 'L' to view" 'INFORMATIONAL'

# =====================
# Section 0: Multi-Server Registry Management
# =====================
$script:RegRoot = "HKCU:\Software\VeeamItUpPlus"

# =====================
# Section 1: Startup Menu (now in a loop)
# =====================

while ($true) {
    $servers = Get-SavedServers
    Write-Log "🔍 Retrieved saved server profiles from registry. Count: $($servers.Count)" 'INFORMATIONAL'
    if ($servers.Count -gt 0) {
        Write-Log "📋 Displaying saved VeeamItUp+ server profiles to user." 'INFORMATIONAL'
        Write-Host ""
        Write-Log "📋 Saved VeeamItUp+ server profiles:" 'INFORMATIONAL'
        Write-Host "Saved VeeamItUp+ server profiles:" -ForegroundColor Cyan
        Write-Host ""
        
        try {
            $i = 1
            foreach ($s in $servers) {
                try {
                    $serverDisplay = $s.ServerName
                    if (-not $serverDisplay) {
                        # Fallback: parse from UNC if not present
                        if ($s.UNCPath -match '^\\\\([^\\]+)') { $serverDisplay = $matches[1] }
                        else { $serverDisplay = "Unknown Server" }
                    }
                    # Show server info with connectivity status if available
                    $connectivityIcon = ""
                    $connectivityColor = "White"
                    if ($script:ConnectivityResults.ContainsKey($serverDisplay)) {
                        if ($script:ConnectivityResults[$serverDisplay]) {
                            $connectivityIcon = " ⭐" # Pink star for servers that passed connectivity
                            $connectivityColor = "Magenta"
                        } else {
                            $connectivityIcon = " ❌" # Red X for servers that failed connectivity
                            $connectivityColor = "Red"
                        }
                    }
                    
                    Write-Log "$i.$connectivityIcon [Server: $serverDisplay | UNC: $($s.UNCPath)  [$($s.Username)]  Drive: $($s.DriveLetter)]" 'INFORMATIONAL'
                    
                    if ($connectivityIcon) {
                        Write-Host "$i." -NoNewline
                        Write-Host $connectivityIcon -ForegroundColor $connectivityColor -NoNewline
                        Write-Host " [Server: $serverDisplay | UNC: $($s.UNCPath)  [$($s.Username)]  Drive: $($s.DriveLetter)]"
                    } else {
                        Write-Host "$i. [Server: $serverDisplay | UNC: $($s.UNCPath)  [$($s.Username)]  Drive: $($s.DriveLetter)]"
                    }
                    $i++
                } catch {
                    Write-Log "⚠️ Error displaying server profile $i`: $_" 'WARNING'
                    Write-Log "$i. [Error loading server profile - check logs]" 'FAILURE'
                    Write-Host "$i. [Error loading server profile - check logs]" -ForegroundColor Red
                    $i++
                }
            }
        } catch {
            Write-Log "❌ Critical error displaying server profiles: $_" 'CRITICAL'
            Write-Log "❌ Error loading server profiles. Check HTML activity log for details." 'CRITICAL'
        }
        
        Write-Log "📝 Prompting user to select, add, or delete a server profile." 'INFORMATIONAL'
        
        # Debug: Ensure menu always displays
        Write-Log "🎯 Displaying main menu options for $($servers.Count) server(s)" 'INFORMATIONAL'
        
        Write-Log "═══════════════════════════════════════════════════════════════════════════════" 'INFORMATIONAL'
        Write-Log "                                    MENU OPTIONS                                   " 'INFORMATIONAL'
        Write-Log "═══════════════════════════════════════════════════════════════════════════════" 'INFORMATIONAL'
        Write-Log "  1-$($servers.Count): Select a server to map and run report" 'INFORMATIONAL'
        Write-Log "  A: Add new server profile" 'INFORMATIONAL'
        Write-Log "  C: Test server connectivity" 'INFORMATIONAL'
        Write-Log "  D: Delete server profiles" 'INFORMATIONAL'
        Write-Log "  L: View HTML activity log" 'INFORMATIONAL'
        Write-Log "  Q: Quit application" 'INFORMATIONAL'
        Write-Log "═══════════════════════════════════════════════════════════════════════════════" 'INFORMATIONAL'
        
        Write-Host ""
        Write-Host "═══════════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
        Write-Host "                                    MENU OPTIONS                                   " -ForegroundColor Cyan
        Write-Host "═══════════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
        Write-Host "  1-$($servers.Count): Select a server to map and run report" -ForegroundColor White
        Write-Host "  A: Add new server profile" -ForegroundColor Green
        Write-Host "  C: Test server connectivity" -ForegroundColor Magenta
        Write-Host "  D: Delete server profiles" -ForegroundColor Red
        Write-Host "  L: View HTML activity log" -ForegroundColor Cyan
        Write-Host "  Q: Quit application" -ForegroundColor Yellow
        Write-Host "═══════════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
        Write-Host ""
        
        Write-Log "❓ Prompting user to choose a menu option" 'INFORMATIONAL'
        $choice = Read-Host "Please choose an option"
        Write-Log "📝 User selected menu option: $choice" 'INFORMATIONAL'
        if ($choice -match '^[0-9]+$' -and [int]$choice -ge 1 -and [int]$choice -le $servers.Count) {
            $selected = $servers[[int]$choice-1]
            Write-Log "🔑 User selected profile: $($selected.ServerName) [$($selected.UNCPath)] ($($selected.Username))" 'INFORMATIONAL'
            $settings = Load-ServerSettings -KeyName $selected.Key
            if (-not $settings) { Write-Log "❌ Failed to load settings for selected profile. Continuing to menu." 'CRITICAL'; continue }
            $UNCPath = $settings.UNCPath
            $Username = $settings.Username
            $Password = $settings.Password
            $DriveLetter = $settings.DriveLetter
            if ([string]::IsNullOrWhiteSpace($Password)) {
                Write-Log "❌ Password loaded from registry is null or empty. Continuing to menu for security." 'FAILURE'
                continue
            }
            $SecurePassword = ConvertTo-SecureString $Password -AsPlainText -Force
            
            # Store the selected server name for use in the report
            $script:SelectedServerName = $selected.ServerName
            
            Write-Log "🔒 Loaded credentials and drive mapping for selected profile." 'WARNING'
            Write-Log "📋 UNC Path: $UNCPath" 'INFORMATIONAL'
            Write-Log "👤 Username: $Username" 'INFORMATIONAL'
            Write-Log "💾 Drive Letter: $DriveLetter" 'INFORMATIONAL'
            Write-Log "🔒 Password: ********" 'INFORMATIONAL'
            
            # Run diagnostics first
            Test-DriveMapping -DriveLetter $DriveLetter -UNCPath $UNCPath -Username $Username
            
            Write-Log "🔗 Starting drive mapping process..." 'INFORMATIONAL'
            
            # Map the drive and run report
            Write-Log "🔗 Attempting to map drive $DriveLetter to $UNCPath for $Username..." 'INFORMATIONAL'
            if (New-NetworkDrive -DriveLetter $DriveLetter -UNCPath $UNCPath -Username $Username -Password $SecurePassword) {
                Write-Log "✅ Drive mapping succeeded!" 'INFORMATIONAL'
                Write-Log "✅ Drive mapping succeeded. Running report generation." 'INFORMATIONAL'
                Write-Log "📊 Analyzing backup files and generating report..." 'INFORMATIONAL'
                Run-ReportForMappedDrive -DriveLetter $DriveLetter
                Write-Log "✅ Report generation completed!" 'INFORMATIONAL'
                Update-HTMLLog
                Keep-LastNLogs -N 3
                Write-Log "HTML activity log updated with report generation results" 'INFORMATIONAL'
                Show-ReturnToMenuPrompt "✅ Report completed! Press any key to return to menu..." "Green"
                continue
    } else {
                Write-Log "❌ Drive mapping failed!" 'FAILURE'
                Write-Log "❌ Drive mapping failed. Continuing to menu." 'FAILURE'
                Write-Log "💡 Troubleshooting tips:" 'WARNING'
                Write-Log "   • Check if the server is online and accessible" 'WARNING'
                Write-Log "   • Verify username and password are correct" 'WARNING'
                Write-Log "   • Ensure you have permission to access the UNC path" 'WARNING'
                Write-Log "   • Try accessing the UNC path directly in File Explorer first" 'WARNING'
                Write-Log "   • Check if any firewall or VPN is blocking the connection" 'WARNING'
                Write-Log "🔍 Check the HTML activity log for detailed error information." 'INFORMATIONAL'
                Show-ReturnToMenuPrompt "❌ Drive mapping failed. Press any key to return to menu..." "Red"
                continue
            }
        } elseif ($choice -eq 'A') {
            if (Add-NewServerProfile) {
                continue
            } else {
                continue
            }
        } elseif ($choice -eq 'C') {
            Write-Log "🔍 User chose to test server connectivity." 'INFORMATIONAL'
            Write-Log "🔍 Testing connectivity for all saved servers..." 'INFORMATIONAL'
            
            # Clear previous connectivity results
            $script:ConnectivityResults.Clear()
            
            foreach ($s in $servers) {
                $serverDisplay = $s.ServerName
                if (-not $serverDisplay) {
                    if ($s.UNCPath -match '^\\\\([^\\]+)') { $serverDisplay = $matches[1] }
                }
                
                Write-Log "🔍 Testing: $serverDisplay ($($s.UNCPath))" 'INFORMATIONAL'
                $testResult = Test-ServerConnectivity -ServerName $serverDisplay -UNCPath $s.UNCPath -TimeoutSeconds 5
                
                # Store the connectivity result
                $script:ConnectivityResults[$serverDisplay] = $testResult
                
                if ($testResult) {
                    Write-Log "✅ $serverDisplay is accessible" 'INFORMATIONAL'
                } else {
                    Write-Log "❌ $serverDisplay has connectivity issues" 'WARNING'
                }
            }
            
            Write-Log "🔍 Connectivity test completed. Refreshing menu display." 'INFORMATIONAL'
            Clear-Host
            Show-Banner
            Write-Host ""
            continue
        } elseif ($choice -eq 'D') {
            Write-Log "🗑️ User chose to delete a server profile." 'INFORMATIONAL'
            Write-Log "🗑️ Delete ALL or a specific server?" 'INFORMATIONAL'
            Write-Log "❓ Prompting user for delete choice" 'INFORMATIONAL'
            $delChoice = Read-Host "Enter number to delete a server, or ALL to delete all"
            Write-Log "📝 User selected delete option: $delChoice" 'INFORMATIONAL'
            if ($delChoice -eq 'ALL') {
                Write-Log "🗑️ Deleting ALL server profiles from registry." 'WARNING'
                Delete-AllServerSettings
                Show-ReturnToMenuPrompt "🗑️ All server profiles deleted. Press any key to return to menu..." "Yellow"
                continue
            } elseif ($delChoice -match '^[0-9]+$' -and [int]$delChoice -ge 1 -and [int]$delChoice -le $servers.Count) {
                $delKey = $servers[[int]$delChoice-1].Key
                Write-Log "🗑️ Deleting server profile with key: $delKey" 'WARNING'
                Delete-ServerSettings -KeyName $delKey
                Show-ReturnToMenuPrompt "🗑️ Server profile deleted. Press any key to return to menu..." "Yellow"
                continue
            } else {
                Write-Log "❌ Invalid delete choice entered: $delChoice. Continuing to menu." 'FAILURE'
                continue
            }
        } elseif ($choice -eq 'L') {
            Write-Log "📱 User chose to view HTML activity log." 'INFORMATIONAL'
            try {
                Update-HTMLLog  # Refresh the log before opening
                Start-Process $script:LogFilePath
                Write-Log "🚀 HTML activity log opened in default browser" 'INFORMATIONAL'
                Show-ReturnToMenuPrompt "📱 HTML log opened in browser. Press any key to return to menu..." "Cyan"
            }
            catch {
                Write-Log "⚠️ Failed to open HTML log: $_" 'WARNING'
                Show-ReturnToMenuPrompt "❌ Failed to open HTML log. Press any key to return to menu..." "Red"
            }
            continue
        } elseif ($choice -eq 'Q') {
            Write-Log "👋 User chose to quit the application." 'INFORMATIONAL'
            Write-Log "👋 Thank you for using VeeamItUp+!" 'INFORMATIONAL'
            Update-HTMLLog
            break
        } else {
            Write-Log "❌ Invalid menu choice entered: $choice. Continuing to menu." 'FAILURE'
            continue
        }
    } else {
        Write-Log "ℹ️ No saved server profiles found. Prompting user to add a new one." 'INFORMATIONAL'
        Write-Log "⚠️ No saved server profiles found." 'WARNING'
        
        Write-Log "═══════════════════════════════════════════════════════════════════════════════" 'INFORMATIONAL'
        Write-Log "                                    MENU OPTIONS                                   " 'INFORMATIONAL'
        Write-Log "═══════════════════════════════════════════════════════════════════════════════" 'INFORMATIONAL'
        Write-Log "  A: Add new server profile" 'INFORMATIONAL'
        Write-Log "  L: View HTML activity log" 'INFORMATIONAL'
        Write-Log "  Q: Quit application" 'INFORMATIONAL'
        Write-Log "═══════════════════════════════════════════════════════════════════════════════" 'INFORMATIONAL'
        
        Write-Host "No saved server profiles found." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "═══════════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
        Write-Host "                                    MENU OPTIONS                                   " -ForegroundColor Cyan
        Write-Host "═══════════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
        Write-Host "  A: Add new server profile" -ForegroundColor Green
        Write-Host "  L: View HTML activity log" -ForegroundColor Cyan
        Write-Host "  Q: Quit application" -ForegroundColor Yellow
        Write-Host "═══════════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
        Write-Host ""
        
        Write-Log "❓ Prompting user to choose a menu option (no servers scenario)" 'INFORMATIONAL'
        $choice = Read-Host "Please choose an option"
        Write-Log "📝 User selected menu option: $choice" 'INFORMATIONAL'
        if ($choice -eq 'A') {
            if (Add-NewServerProfile) {
                continue
            } else {
                continue
            }
        } elseif ($choice -eq 'L') {
            Write-Log "📱 User chose to view HTML activity log." 'INFORMATIONAL'
            try {
                Update-HTMLLog  # Refresh the log before opening
                Start-Process $script:LogFilePath
                Write-Log "🚀 HTML activity log opened in default browser" 'INFORMATIONAL'
                Show-ReturnToMenuPrompt "📱 HTML log opened in browser. Press any key to return to menu..." "Cyan"
            }
            catch {
                Write-Log "⚠️ Failed to open HTML log: $_" 'WARNING'
                Show-ReturnToMenuPrompt "❌ Failed to open HTML log. Press any key to return to menu..." "Red"
            }
            continue
        } elseif ($choice -eq 'Q') {
            Write-Log "👋 User chose to quit the application." 'INFORMATIONAL'
            Write-Log "👋 Thank you for using VeeamItUp+!" 'INFORMATIONAL'
            Update-HTMLLog
            break
        } else {
            Write-Log "❌ Invalid choice entered: $choice. Continuing to menu." 'FAILURE'
            continue
        }
    }
}

# End of script - all logic is now handled within the menu loop 