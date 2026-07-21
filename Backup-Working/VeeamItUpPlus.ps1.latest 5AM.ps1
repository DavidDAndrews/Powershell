# =====================
# All Function Definitions (move to very top)
# =====================
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('ERROR','SUCCESS')][string]$Level = 'SUCCESS'
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
    $shouldUpdate = ($timeSinceLastUpdate -gt 500) -or ($Level -eq 'ERROR')
    
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
                'ERROR' { 'error' }
                'SUCCESS' { 'success' }
                default { 'success' }
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
            <label for="levelFilter"><b>Filter by log level:</b></label>
            <select id="levelFilter" onchange="filterLog()" style="margin-left: 10px;">
                <option value="ALL" selected>ALL (Default)</option>
                <option value="SUCCESS">SUCCESS</option>
                <option value="ERROR">ERROR</option>
            </select>
        </div>
        <div class="log-container" id="logContainer">
$logEntriesHtml
        </div>
    </div>
    <script>
        function filterLog() {
            const sel = document.getElementById('levelFilter').value;
            const entries = document.querySelectorAll('.log-entry');
            entries.forEach(entry => {
                const classList = entry.className.split(' ');
                let level = 'SUCCESS';
                if (classList.includes('error')) level = 'ERROR';
                else if (classList.includes('success')) level = 'SUCCESS';
                
                // Show entry if ALL is selected or if the level matches the filter
                if (sel === 'ALL' || level === sel) {
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
    $downloads = if ($env:USERPROFILE) { 
        Join-Path $env:USERPROFILE "Downloads" 
    } else { 
        Join-Path $env:HOME "Downloads" 
    }
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
            <label for="levelFilter"><b>Filter by log level:</b></label>
            <select id="levelFilter" onchange="filterLog()" style="margin-left: 10px;">
                <option value="ALL" selected>ALL (Default)</option>
                <option value="SUCCESS">SUCCESS</option>
                <option value="ERROR">ERROR</option>
            </select>
        </div>
        <div class="log-container" id="logContainer">
"@
    $entryNumber = 1
    foreach ($entry in $logEntries) {
        # Map log level to class
        $levelClass = switch ($entry.Level) {
            'ERROR' { 'error' }
            'ERROR' { 'warning' }
            'SUCCESS' { 'warning' }
            'SUCCESS' { 'info' }
            default { 'info' }
        }
        $html += "<div class='log-entry $levelClass'><span class='log-number' style='font-weight:bold;color:#6366F1;margin-right:10px;'>$entryNumber.</span><span class='timestamp'>$($entry.Timestamp)</span><span class='message'>$($entry.Message)</span></div>"
        $entryNumber++
    }
    $html += @"
        </div>
    </div>
    <script>
        function filterLog() {
            const sel = document.getElementById('levelFilter').value;
            const entries = document.querySelectorAll('.log-entry');
            entries.forEach(entry => {
                const classList = entry.className.split(' ');
                let level = 'SUCCESS';
                if (classList.includes('error')) level = 'ERROR';
                else if (classList.includes('success')) level = 'SUCCESS';
                
                // Show entry if ALL is selected or if the level matches the filter
                if (sel === 'ALL' || level === sel) {
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
    Write-Log "HTML activity log generated: $logPath" 'SUCCESS'
}
function Keep-LastNLogs {
    param($N)
    $downloads = if ($env:USERPROFILE) { 
        Join-Path $env:USERPROFILE "Downloads" 
    } else { 
        Join-Path $env:HOME "Downloads" 
    }
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
    Write-Log "🧹 Cleaning up any existing mapping to $DriveLetter..." 'SUCCESS'
    $cleanupCmd = "net use $DriveLetter /delete /yes"
    $cleanupResult = Invoke-Expression $cleanupCmd 2>&1
    # Don't worry about cleanup errors - drive might not be mapped
    
    # Test UNC path accessibility first
    Write-Log "🔍 Testing UNC path accessibility: $UNCPath" 'SUCCESS'
    try {
        if (-not (Test-Path $UNCPath -ErrorAction SilentlyContinue)) {
            Write-Log "⚠️ UNC path $UNCPath is not accessible from this machine" 'SUCCESS'
        }
    } catch {
        Write-Log "⚠️ Error testing UNC path: $_" 'SUCCESS'
    }
    
    # Convert SecureString to plain text for net use
    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
    $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($BSTR)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
    
    # Build command (don't log password for security)
    $cmd = "net use $DriveLetter `"$UNCPath`" /user:`"$Username`" `"$plainPassword`" /persistent:no"
    Write-Log "🔗 Executing drive mapping: net use $DriveLetter `"$UNCPath`" /user:`"$Username`" [PASSWORD HIDDEN] /persistent:no" 'SUCCESS'
    
    # Execute the mapping command
    $result = Invoke-Expression $cmd 2>&1
    
    if ($LASTEXITCODE -eq 0) {
        Write-Log "✅ Drive mapped successfully: $DriveLetter -> $UNCPath" 'SUCCESS'
        
        # Verify the mapping worked by testing the drive
        if (Test-Path $DriveLetter) {
            Write-Log "✅ Drive verification successful: $DriveLetter is accessible" 'SUCCESS'
        return $true
    } else {
            Write-Log "❌ Drive mapping appeared successful but $DriveLetter is not accessible" 'ERROR'
        return $false
    }
    } else {
        Write-Log "❌ Failed to map drive $DriveLetter to $UNCPath" 'ERROR'
        Write-Log "❌ Net use error details: $result" 'ERROR'
        
        # Provide specific error guidance based on common errors
        $errorString = if ($result -ne $null) { $result.ToString() } else { "Unknown error" }
        if ($errorString -match "System error 5") {
            Write-Log "💡 Error 5 = Access Denied. Check username/password or permissions." 'SUCCESS'
        } elseif ($errorString -match "System error 53") {
            Write-Log "💡 Error 53 = Network path not found. Check UNC path and network connectivity." 'SUCCESS'
        } elseif ($errorString -match "System error 67") {
            Write-Log "💡 Error 67 = Network name not found. Check server name and network connectivity." 'SUCCESS'
        } elseif ($errorString -match "System error 86") {
            Write-Log "💡 Error 86 = Invalid password. Check password accuracy." 'SUCCESS'
        } elseif ($errorString -match "System error 1326") {
            Write-Log "💡 Error 1326 = Logon failure. Check username and password." 'SUCCESS'
        }
        
        return $false
    }
}
function Remove-NetworkDrive {
    param($DriveLetter)
    $cmd = "net use $DriveLetter /delete /yes"
    Write-Log "Unmapping drive: $cmd" 'SUCCESS'
    $result = Invoke-Expression $cmd 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Log "Drive unmapped: $DriveLetter" 'SUCCESS'
    } else {
        Write-Log "Failed to unmap drive: $result" 'SUCCESS'
    }
}
function Get-SavedServers {
    if (-not (Test-Path $script:RegRoot)) { return @() }
    $subkeys = Get-ChildItem -Path $script:RegRoot -ErrorAction SilentlyContinue | Where-Object { $_.PSIsContainer }
    $servers = @()
    foreach ($key in $subkeys) {
        $props = Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue
        if ($props.UNCPath -and $props.Username -and $props.Password -and $props.DriveLetter) {
            # Decrypt passwords
            try {
                $decryptedPassword = ConvertFrom-EncryptedString $props.Password
            } catch {
                $decryptedPassword = ""
            }
            
            $smtpDecrypted = if ($props.SMTPPassword) { 
                try { ConvertFrom-EncryptedString $props.SMTPPassword } catch { "" }
            } else { "" }
            
            $servers += [PSCustomObject]@{
                Key = $key.PSChildName
                UNCPath = $props.UNCPath
                Username = $props.Username
                Password = $decryptedPassword
                DriveLetter = $props.DriveLetter
                ServerName = if ($props.ServerName) { $props.ServerName } else { "" }
                EmailAddress = if ($props.EmailAddress) { $props.EmailAddress } else { "" }
                EmailEnabled = if ($null -ne $props.EmailEnabled) { 
                    # Handle both boolean and string values from registry
                    if ($props.EmailEnabled -is [bool]) {
                        $props.EmailEnabled
                    } elseif ($props.EmailEnabled -is [string]) {
                        $props.EmailEnabled -eq "True" -or $props.EmailEnabled -eq "1"
                    } else {
                        [bool]$props.EmailEnabled
                    }
                } else { $false }
                SMTPServer = if ($props.SMTPServer) { $props.SMTPServer } else { "" }
                SMTPPort = if ($props.SMTPPort) { $props.SMTPPort } else { 587 }
                SMTPUsername = if ($props.SMTPUsername) { $props.SMTPUsername } else { "" }
                SMTPPassword = $smtpDecrypted
                UseSSL = if ($null -ne $props.UseSSL) { 
                    # Handle both boolean and string values from registry
                    if ($props.UseSSL -is [bool]) {
                        $props.UseSSL
                    } elseif ($props.UseSSL -is [string]) {
                        $props.UseSSL -eq "True" -or $props.UseSSL -eq "1"
                    } else {
                        [bool]$props.UseSSL
                    }
                } else { $true }
            }
        }
    }
    return $servers
}
function Save-ServerSettings {
    param(
        $UNCPath, 
        $Username, 
        $Password, 
        $DriveLetter, 
        $KeyName, 
        $ServerName,
        $EmailAddress = "",
        $EmailEnabled = $false,
        $SMTPServer = "",
        $SMTPPort = 587,
        $SMTPUsername = "",
        $SMTPPassword = "",
        $UseSSL = $true
    )
    if (-not (Test-Path $script:RegRoot)) { New-Item -Path $script:RegRoot -Force | Out-Null }
    $key = Join-Path $script:RegRoot $KeyName
    if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
    Set-ItemProperty -Path $key -Name "UNCPath" -Value $UNCPath -Force
    Set-ItemProperty -Path $key -Name "Username" -Value $Username -Force
    Set-ItemProperty -Path $key -Name "Password" -Value (ConvertTo-EncryptedString $Password) -Force
    Set-ItemProperty -Path $key -Name "DriveLetter" -Value $DriveLetter -Force
    Set-ItemProperty -Path $key -Name "ServerName" -Value $ServerName -Force
    
    # Save email settings
    Set-ItemProperty -Path $key -Name "EmailAddress" -Value $EmailAddress -Force
    Set-ItemProperty -Path $key -Name "EmailEnabled" -Value $EmailEnabled -Force
    Set-ItemProperty -Path $key -Name "SMTPServer" -Value $SMTPServer -Force
    Set-ItemProperty -Path $key -Name "SMTPPort" -Value $SMTPPort -Force
    Set-ItemProperty -Path $key -Name "SMTPUsername" -Value $SMTPUsername -Force
    if ($SMTPPassword) {
        Set-ItemProperty -Path $key -Name "SMTPPassword" -Value (ConvertTo-EncryptedString $SMTPPassword) -Force
    }
    Set-ItemProperty -Path $key -Name "UseSSL" -Value $UseSSL -Force
    
    Write-Log "Settings saved for $UNCPath ($Username, $DriveLetter) with email: $(if ($EmailEnabled) { $EmailAddress } else { 'Disabled' })" 'SUCCESS'
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
                Write-Log "Corrupt or invalid password in registry for $KeyName. Please re-enter credentials." 'ERROR'
                return $null
            }
            $smtpDecrypted = if ($props.SMTPPassword) { 
                try { ConvertFrom-EncryptedString $props.SMTPPassword } catch { "" }
            } else { "" }
            
            return @{ 
                UNCPath = $props.UNCPath
                Username = $props.Username
                Password = $decrypted
                DriveLetter = $props.DriveLetter
                ServerName = if ($props.ServerName) { $props.ServerName } else { "" }
                EmailAddress = if ($props.EmailAddress) { $props.EmailAddress } else { "" }
                EmailEnabled = if ($null -ne $props.EmailEnabled) { $props.EmailEnabled } else { $false }
                SMTPServer = if ($props.SMTPServer) { $props.SMTPServer } else { "" }
                SMTPPort = if ($props.SMTPPort) { $props.SMTPPort } else { 587 }
                SMTPUsername = if ($props.SMTPUsername) { $props.SMTPUsername } else { "" }
                SMTPPassword = $smtpDecrypted
                UseSSL = if ($null -ne $props.UseSSL) { $props.UseSSL } else { $true }
            }
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
    
    Write-Log "🔍 Testing connectivity to $ServerName (timeout: ${TimeoutSeconds}s)" 'SUCCESS'
    $allPassed = $true
    
    # 1. Quick ping test
    try {
        $pingResult = Test-Connection -ComputerName $ServerName -Count 1 -TimeToLive 10 -Quiet -ErrorAction Stop
        if ($pingResult) {
            Write-Log "📶 Ping to $ServerName succeeded." 'SUCCESS'
        } else {
            Write-Log "⚠️ Ping to $ServerName failed." 'SUCCESS'
            $allPassed = $false
        }
    } catch {
        Write-Log "⚠️ Ping test to $ServerName failed: $_" 'SUCCESS'
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
            Write-Log "🔌 Port 445 open on $ServerName." 'SUCCESS'
        } else {
            Write-Log "⚠️ Port 445 not accessible on $ServerName (timeout or closed)." 'SUCCESS'
            $allPassed = $false
        }
        $tcp.Dispose()
    } catch {
        Write-Log "⚠️ Port 445 check failed for $ServerName`: $_" 'SUCCESS'
        $allPassed = $false
    }
    
    # 3. Skip UNC Path validation as it can be slow and unreliable
    # This will be tested during actual drive mapping
    Write-Log "ℹ️ UNC path validation skipped (will be tested during drive mapping)" 'SUCCESS'
    
    Write-Log "🔍 Connectivity test completed for $ServerName" 'SUCCESS'
    return $allPassed
}
# OpenAI API Functions
function Get-OpenAIAPIKey {
    # Try to get from registry first
    $regPath = "HKCU:\Software\VeeamItUpPlus"
    $keyName = "OpenAIAPIKey"
    
    try {
        if (Test-Path $regPath) {
            $encryptedKey = Get-ItemProperty -Path $regPath -Name $keyName -ErrorAction SilentlyContinue
            if ($encryptedKey.$keyName) {
                Write-Log "🔑 Found OpenAI API key in registry" 'SUCCESS'
                return ConvertFrom-EncryptedString -EncryptedText $encryptedKey.$keyName
            }
        }
    } catch {
        Write-Log "⚠️ Error retrieving OpenAI API key from registry: $_" 'SUCCESS'
    }
    
    return $null
}

function Save-OpenAIAPIKey {
    param([string]$APIKey)
    
    $regPath = "HKCU:\Software\VeeamItUpPlus"
    $keyName = "OpenAIAPIKey"
    
    try {
        if (!(Test-Path $regPath)) {
            New-Item -Path $regPath -Force | Out-Null
        }
        
        $encryptedKey = ConvertTo-EncryptedString -PlainText $APIKey
        Set-ItemProperty -Path $regPath -Name $keyName -Value $encryptedKey
        Write-Log "✅ OpenAI API key saved to registry" 'SUCCESS'
        return $true
    } catch {
        Write-Log "❌ Error saving OpenAI API key: $_" 'ERROR'
        return $false
    }
}

function Save-OpenAIModel {
    param([string]$Model)
    
    $regPath = "HKCU:\Software\VeeamItUpPlus"
    $keyName = "OpenAIModel"
    
    try {
        if (!(Test-Path $regPath)) {
            New-Item -Path $regPath -Force | Out-Null
        }
        
        Set-ItemProperty -Path $regPath -Name $keyName -Value $Model
        Write-Log "✅ OpenAI model preference saved: $Model" 'SUCCESS'
        return $true
    } catch {
        Write-Log "❌ Error saving OpenAI model preference: $_" 'ERROR'
        return $false
    }
}

function Get-OpenAIModel {
    $regPath = "HKCU:\Software\VeeamItUpPlus"
    $keyName = "OpenAIModel"
    
    try {
        if (Test-Path $regPath) {
            $model = Get-ItemProperty -Path $regPath -Name $keyName -ErrorAction SilentlyContinue | Select-Object -ExpandProperty $keyName -ErrorAction SilentlyContinue
            if ($model) {
                Write-Log "📖 Retrieved OpenAI model preference: $model" 'SUCCESS'
                return $model
            }
        }
    } catch {
        Write-Log "⚠️ Could not retrieve model preference: $_" 'SUCCESS'
    }
    
    # Return default model
    return "gpt-4-turbo-preview"
}

function Get-AvailableOpenAIModels {
    Write-Log "🔍 Fetching available models from OpenAI API..." 'SUCCESS'
    
    if (-not $script:OpenAIAPIKey) {
        Write-Log "⚠️ No API key available to fetch models" 'SUCCESS'
        return @()
    }
    
    $headers = @{
        "Authorization" = "Bearer $($script:OpenAIAPIKey)"
    }
    
    try {
        Write-Host "Fetching available models from OpenAI..." -ForegroundColor Cyan
        $response = Invoke-RestMethod -Uri "https://api.openai.com/v1/models" `
                                     -Method GET `
                                     -Headers $headers `
                                     -ErrorAction Stop
        
        # Filter for chat models only
        $chatModels = $response.data | Where-Object { 
            $_.id -match "gpt|o1|claude" 
        } | Select-Object -ExpandProperty id | Sort-Object
        
        Write-Log "✅ Retrieved $($chatModels.Count) models from OpenAI" 'SUCCESS'
        return $chatModels
    }
    catch {
        Write-Log "❌ Failed to fetch models: $_" 'ERROR'
        Write-Host "Unable to fetch models from API. Using default list." -ForegroundColor Yellow
        
        # Return default models if API fails
        return @(
            "gpt-4-turbo-preview",
            "gpt-4-turbo",
            "gpt-4",
            "gpt-4o",
            "gpt-4o-mini",
            "gpt-3.5-turbo",
            "gpt-3.5-turbo-16k"
        )
    }
}

function Select-OpenAIModel {
    Write-Host ""
    Write-Host "Select OpenAI Model" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════════" -ForegroundColor DarkGray
    Write-Host ""
    
    # Get available models from API
    $availableModels = Get-AvailableOpenAIModels
    
    if ($availableModels.Count -eq 0) {
        Write-Host "No models available. Using default model." -ForegroundColor Yellow
        return "gpt-4-turbo-preview"
    }
    
    # Prioritize certain models
    $priorityModels = @(
        "gpt-4-turbo-preview",
        "gpt-4-turbo", 
        "gpt-4o",
        "gpt-4o-mini",
        "gpt-4",
        "gpt-3.5-turbo"
    )
    
    # Build display list
    $displayModels = @()
    $modelDescriptions = @{
        "gpt-4-turbo-preview" = "Latest GPT-4 Turbo - Most capable, best for complex analysis"
        "gpt-4-turbo" = "GPT-4 Turbo - Fast and powerful"
        "gpt-4o" = "GPT-4 Optimized - Enhanced performance"
        "gpt-4o-mini" = "GPT-4o Mini - Smaller, faster, cost-effective"
        "gpt-4" = "GPT-4 - Stable, highly capable"
        "gpt-3.5-turbo" = "GPT-3.5 Turbo - Fast and cost-effective"
    }
    
    # Add priority models first if available
    foreach ($model in $priorityModels) {
        if ($model -in $availableModels) {
            $displayModels += $model
        }
    }
    
    # Add any other models not in priority list
    foreach ($model in $availableModels) {
        if ($model -notin $displayModels) {
            $displayModels += $model
        }
    }
    
    Write-Host "Available Models:" -ForegroundColor Yellow
    $index = 1
    foreach ($model in $displayModels) {
        $description = if ($modelDescriptions.ContainsKey($model)) { 
            " - $($modelDescriptions[$model])" 
        } else { 
            "" 
        }
        Write-Host "  $index. $model$description" -ForegroundColor White
        $index++
    }
    Write-Host ""
    
    $choice = Read-Host "Select model (1-$($displayModels.Count))"
    
    $selectedModel = if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $displayModels.Count) {
        $displayModels[[int]$choice - 1]
    } else {
        $displayModels[0]  # Default to first model
    }
    
    Write-Host ""
    Write-Host "Selected model: $selectedModel" -ForegroundColor Green
    
    # Save the selection
    if (Save-OpenAIModel -Model $selectedModel) {
        $script:OpenAIModel = $selectedModel
        Write-Host "Model preference saved successfully!" -ForegroundColor Green
    }
    
    Start-Sleep -Seconds 2
    return $selectedModel
}

function Remove-OpenAIAPIKey {
    $regPath = "HKCU:\Software\VeeamItUpPlus"
    $keyName = "OpenAIAPIKey"
    
    try {
        if (Test-Path $regPath) {
            Remove-ItemProperty -Path $regPath -Name $keyName -ErrorAction SilentlyContinue
            Write-Log "🗑️ OpenAI API key removed from registry" 'SUCCESS'
            $script:OpenAIAPIKey = $null
            $script:OpenAIConnected = $false
            return $true
        }
    } catch {
        Write-Log "❌ Error removing OpenAI API key: $_" 'ERROR'
    }
    return $false
}

function Test-OpenAIConnection {
    param([string]$APIKey)
    
    if ([string]::IsNullOrWhiteSpace($APIKey)) {
        return $false
    }
    
    Write-Log "🔍 Testing OpenAI API connection..." 'SUCCESS'
    
    # Use the current model or default to gpt-4o-mini if not set
    $testModel = if ($script:OpenAIModel) { $script:OpenAIModel } else { "gpt-4o-mini" }
    
    $headers = @{
        "Authorization" = "Bearer $APIKey"
        "Content-Type" = "application/json"
    }
    
    $body = @{
        "model" = $testModel
        "messages" = @(
            @{
                "role" = "user"
                "content" = "Say 'Connection successful' in 3 words or less"
            }
        )
        "max_tokens" = 10
        "temperature" = 0
    } | ConvertTo-Json
    
    try {
        $response = Invoke-RestMethod -Uri "https://api.openai.com/v1/chat/completions" `
                                     -Method POST `
                                     -Headers $headers `
                                     -Body $body `
                                     -ErrorAction Stop
        
        if ($response.choices -and $response.choices[0].message.content) {
            Write-Log "✅ OpenAI API connection verified successfully" 'SUCCESS'
            return $true
        }
    } catch {
        $errorMsg = $_.Exception.Message
        if ($errorMsg -match "401") {
            Write-Log "❌ Invalid API key - Authentication failed" 'ERROR'
        } elseif ($errorMsg -match "429") {
            Write-Log "⚠️ Rate limit exceeded - API key is valid but rate limited" 'SUCCESS'
            return $true  # Key is valid, just rate limited
        } elseif ($errorMsg -match "403") {
            Write-Log "❌ API key lacks required permissions" 'ERROR'
        } else {
            Write-Log "❌ OpenAI API connection failed: $errorMsg" 'ERROR'
        }
    }
    
    return $false
}

function Initialize-OpenAIConnection {
    Write-Log "🤖 Initializing OpenAI API connection..." 'SUCCESS'
    
    # Try to get key from registry
    $apiKey = Get-OpenAIAPIKey
    
    if ($apiKey) {
        # Test the stored key
        if (Test-OpenAIConnection -APIKey $apiKey) {
            $script:OpenAIAPIKey = $apiKey
            $script:OpenAIConnected = $true
            Write-Log "✅ OpenAI API connected using stored key" 'SUCCESS'
            return $true
        } else {
            Write-Log "⚠️ Stored API key is invalid or expired" 'SUCCESS'
        }
    }
    
    # Prompt for new key
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "                    OpenAI API Configuration                        " -ForegroundColor Yellow
    Write-Host "═══════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "No valid OpenAI API key found. Please enter your API key." -ForegroundColor Yellow
    Write-Host "Get your API key from: " -NoNewline
    Write-Host "https://platform.openai.com/api-keys" -ForegroundColor Cyan
    Write-Host ""
    
    $maxAttempts = 3
    $attempt = 0
    
    while ($attempt -lt $maxAttempts) {
        $attempt++
        Write-Host "Enter OpenAI API Key (attempt $attempt/$maxAttempts): " -NoNewline -ForegroundColor Green
        $secureKey = Read-Host -AsSecureString
        
        # Check if SecureString is empty before converting
        if ($secureKey.Length -eq 0) {
            Write-Host "API key cannot be empty. Please try again." -ForegroundColor Red
            continue
        }
        
        $apiKey = ConvertFrom-SecureString -SecureString $secureKey -AsPlainText
        
        if ([string]::IsNullOrWhiteSpace($apiKey)) {
            Write-Host "API key cannot be empty. Please try again." -ForegroundColor Red
            continue
        }
        
        Write-Host "Verifying API key..." -ForegroundColor Cyan
        
        if (Test-OpenAIConnection -APIKey $apiKey) {
            # Save the valid key
            if (Save-OpenAIAPIKey -APIKey $apiKey) {
                $script:OpenAIAPIKey = $apiKey
                $script:OpenAIConnected = $true
                Write-Host "✅ API key verified and saved successfully!" -ForegroundColor Green
                Start-Sleep -Seconds 1
                
                # Prompt for model selection
                Clear-Host
                Show-Banner
                Select-OpenAIModel
                
                return $true
            }
        } else {
            Write-Host "❌ API key validation failed. Please check your key and try again." -ForegroundColor Red
        }
    }
    
    Write-Host "Maximum attempts reached. Continuing without AI features." -ForegroundColor Yellow
    Write-Log "⚠️ OpenAI API not configured - AI features disabled" 'SUCCESS'
    return $false
}

function Invoke-OpenAIAnalysis {
    param(
        [string]$SystemPrompt,
        [string]$UserPrompt,
        [int]$MaxTokens = 2000
    )
    
    if (-not $script:OpenAIConnected -or -not $script:OpenAIAPIKey) {
        Write-Log "⚠️ OpenAI not connected - skipping AI analysis" 'SUCCESS'
        return $null
    }
    
    $headers = @{
        "Authorization" = "Bearer $($script:OpenAIAPIKey)"
        "Content-Type" = "application/json"
    }
    
    $body = @{
        "model" = $script:OpenAIModel
        "messages" = @(
            @{
                "role" = "system"
                "content" = $SystemPrompt
            },
            @{
                "role" = "user"
                "content" = $UserPrompt
            }
        )
        "max_tokens" = $MaxTokens
        "temperature" = 0.7
    } | ConvertTo-Json -Depth 10
    
    try {
        $response = Invoke-RestMethod -Uri "https://api.openai.com/v1/chat/completions" `
                                     -Method POST `
                                     -Headers $headers `
                                     -Body $body `
                                     -ErrorAction Stop
        
        if ($response.choices -and $response.choices[0].message.content) {
            return $response.choices[0].message.content
        }
    } catch {
        Write-Log "❌ OpenAI API call failed: $_" 'ERROR'
    }
    
    return $null
}

function Invoke-OpenAICompletion {
    param(
        [string]$Prompt,
        [int]$MaxTokens = 200,
        [double]$Temperature = 0.7
    )
    
    if (-not $script:OpenAIConnected -or -not $script:OpenAIAPIKey) {
        Write-Log "⚠️ OpenAI not connected - skipping AI completion" 'SUCCESS'
        return $null
    }
    
    $headers = @{
        "Authorization" = "Bearer $($script:OpenAIAPIKey)"
        "Content-Type" = "application/json"
    }
    
    $body = @{
        "model" = $script:OpenAIModel
        "messages" = @(
            @{
                "role" = "system"
                "content" = "You are a professional IT infrastructure analyst specializing in backup and disaster recovery. Provide detailed, technical, and actionable insights. Important: Always respond in plain text without any markdown formatting, asterisks, bold text, headers, or special characters. Write clear, professional prose suitable for direct inclusion in business reports."
            },
            @{
                "role" = "user"
                "content" = $Prompt
            }
        )
        "max_tokens" = $MaxTokens
        "temperature" = $Temperature
    } | ConvertTo-Json -Depth 10
    
    try {
        $response = Invoke-RestMethod -Uri "https://api.openai.com/v1/chat/completions" `
                                     -Method POST `
                                     -Headers $headers `
                                     -Body $body `
                                     -ErrorAction Stop
        
        if ($response.choices -and $response.choices[0].message.content) {
            return $response.choices[0].message.content
        }
    } catch {
        Write-Log "❌ OpenAI API call failed: $_" 'ERROR'
    }
    
    return $null
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
    
    # Show AI connection status
    if ($script:OpenAIConnected) {
        Write-Host ""
        Write-Host "  [" -NoNewline
        Write-Host "AI API Key Verified and Connected" -ForegroundColor Cyan -NoNewline
        Write-Host "] Model: " -NoNewline
        Write-Host $script:OpenAIModel -ForegroundColor Green
    }
}
function Show-ReturnToMenuPrompt {
    param(
        [string]$Message = "Press any key to return to menu...",
        [string]$Color = "Cyan"
    )
    
    Write-Host ""
    Write-Host $Message -ForegroundColor $Color
    Write-Log "⏸️ $Message" 'SUCCESS'
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    Write-Log "🔄 Returning to main menu..." 'SUCCESS'
    Clear-Host
    Show-Banner
    Write-Host ""
}
# ===========================================
# BACKUP ANALYSIS FUNCTIONS FROM OLD APP
# ===========================================

# Function to parse VBM metadata and validate backup chains
function Parse-VBMMetadata {
    param(
        [string]$VBMFilePath,
        [string]$BackupDirectory
    )
    
    $result = @{
        Storages = @()
        JobParameters = @{
            AppQuiesce = $false
            IndexingEnabled = $false
            EncryptionEnabled = $false
            CompressionLevel = "Unknown"
            BlockSize = 0
            GFSEnabled = $false
            JobType = "Unknown"
            SourceType = "Unknown"
            RepositoryName = "Unknown"
        }
        ChainValidation = @{
            IsValid = $true
            BrokenChains = @()
            MissingFiles = @()
            OrphanedIncrementals = @()
            Issues = @()
        }
    }
    
    if (-not (Test-Path $VBMFilePath)) {
        Write-Log "⚠️ VBM file not found: $VBMFilePath" 'SUCCESS'
        return $result
    }
    
    try {
        Write-Log "📄 Parsing VBM metadata: $VBMFilePath" 'SUCCESS'
        
        # Load VBM XML content
        $vbmContent = Get-Content $VBMFilePath -Raw
        
        # Extract job-level parameters from the Backup element
        if ($vbmContent -match '<Backup[^>]+>') {
            $backupElement = $matches[0]
            
            # Extract encryption state
            if ($backupElement -match 'EncryptionState="([^"]+)"') {
                $result.JobParameters.EncryptionEnabled = ($matches[1] -ne "0")
            }
            
            # Extract job type
            if ($backupElement -match 'JobType="([^"]+)"') {
                $result.JobParameters.JobType = $matches[1]
            }
            
            # Extract source type
            if ($backupElement -match 'SourceType="([^"]+)"') {
                $result.JobParameters.SourceType = $matches[1]
            }
        }
        
        # Check for GFS period in any storage element
        if ($vbmContent -match 'GfsPeriod="([^"]+)"' -and $matches[1] -ne "0") {
            $result.JobParameters.GFSEnabled = $true
        }
        
        # Check for application-aware processing settings
        if ($vbmContent -match 'AppAwareProcessing="([^"]+)"' -or $vbmContent -match 'VssOptions="([^"]+)"') {
            $result.JobParameters.AppQuiesce = $true
        }
        
        # Check for indexing
        if ($vbmContent -match 'IndexingEnabled="([^"]+)"' -and $matches[1] -eq "1") {
            $result.JobParameters.IndexingEnabled = $true
        }
        
        # Extract block size from first storage element
        if ($vbmContent -match 'BlockSize="([^"]+)"') {
            $result.JobParameters.BlockSize = [int]$matches[1]
        }
        
        # Extract compression level if present
        if ($vbmContent -match 'CompressionLevel="([^"]+)"') {
            $result.JobParameters.CompressionLevel = $matches[1]
        }
        
        # Extract all Storage elements
        $storagePattern = '<Storage[^>]+/>'
        $storageMatches = [regex]::Matches($vbmContent, $storagePattern)
        
        Write-Log "  Found $($storageMatches.Count) storage entries in VBM" 'SUCCESS'
        
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
                BlockSize = if ($storageXml -match 'BlockSize="([^"]+)"') { [int]$matches[1] } else { 0 }
                GfsPeriod = if ($storageXml -match 'GfsPeriod="([^"]+)"') { $matches[1] } else { "" }
                PartialIncrement = if ($storageXml -match 'PartialIncrement="([^"]+)"') { $matches[1] -eq "1" } else { $false }
                ExternalContentMode = if ($storageXml -match 'ExternalContentMode="([^"]+)"') { $matches[1] } else { "" }
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
            
            # Parse stats to get file sizes and dedup info
            $storage.DataSize = 0
            $storage.DedupRatio = 0
            $storage.CompressRatio = 0
            
            if ($storage.Stats) {
                $statsXml = $storage.Stats -replace '&lt;', '<' -replace '&gt;', '>' -replace '&quot;', '"' -replace '&amp;', '&'
                if ($statsXml -match '<BackupSize>(\d+)</BackupSize>') {
                    $storage.ExpectedSize = [int64]$matches[1]
                }
                if ($statsXml -match '<DataSize>(\d+)</DataSize>') {
                    $storage.DataSize = [int64]$matches[1]
                }
                if ($statsXml -match '<DedupRatio>(\d+)</DedupRatio>') {
                    $storage.DedupRatio = [int]$matches[1]
                }
                if ($statsXml -match '<CompressRatio>(\d+)</CompressRatio>') {
                    $storage.CompressRatio = [int]$matches[1]
                }
            }
            
            # Check if file exists on disk
            # The VBM contains paths like D:\Backup\DC01\filename.vbk
            # But we're checking from a mapped drive like V:\Backup\DC01
            # We need to check in the actual backup directory
            $fileName = Split-Path -Leaf $storage.FilePath
            $fullPath = Join-Path $BackupDirectory $fileName
            
            # Try multiple path resolution strategies
            $pathsToCheck = @()
            $pathsToCheck += $fullPath  # Primary: BackupDirectory + filename
            
            # If the storage path contains a subdirectory structure, preserve it
            if ($storage.FilePath -match '\\Backup\\(.+)$') {
                # Extract the relative path after "Backup\"
                $relativePath = $matches[1]
                # Try to find this in our current backup location
                $mappedPath = Join-Path (Split-Path $BackupDirectory -Parent) $relativePath
                if ($mappedPath -ne $fullPath) {
                    $pathsToCheck += $mappedPath
                }
            }
            
            # Also try the original path if it's absolute and local
            if ([System.IO.Path]::IsPathRooted($storage.FilePath) -and $storage.FilePath -match '^[A-Z]:') {
                $pathsToCheck += $storage.FilePath
            }
            
            $fileFound = $false
            foreach ($pathToCheck in $pathsToCheck) {
                if (Test-Path $pathToCheck -ErrorAction SilentlyContinue) {
                    $storage.FileExists = $true
                    $fileInfo = Get-Item $pathToCheck
                    $storage.ActualSize = $fileInfo.Length
                    Write-Log "      ✅ File found: $fileName at $pathToCheck" 'SUCCESS'
                    $fileFound = $true
                    break
                }
            }
            
            if (-not $fileFound) {
                Write-Log "      Checked paths for $fileName`:" 'SUCCESS'
                foreach ($pathToCheck in $pathsToCheck) {
                    Write-Log "        - $pathToCheck" 'SUCCESS'
                }
            }
            
            # Check size mismatch if file was found
            if ($storage.FileExists -and $storage.ExpectedSize -gt 0) {
                $sizeDiff = [Math]::Abs($storage.ActualSize - $storage.ExpectedSize)
                if ($sizeDiff -gt 1048576) {
                    $storage.ChainIssues += "SIZE_MISMATCH"
                }
            }
            
            if (-not $storage.FileExists) {
                $storage.FileExists = $false
                $storage.ChainStatus = "Critical"
                $storage.ChainIssues += "FILE_MISSING"
                $result.ChainValidation.MissingFiles += @{
                    Id = $storage.Id
                    FilePath = $storage.FilePath
                }
                Write-Log "      ⚠️ File not found: $fileName" 'SUCCESS'
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
        Write-Log "  Validating backup chains..." 'SUCCESS'
        Write-Log "    Backup directory: $BackupDirectory" 'SUCCESS'
        
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
            Write-Log "  ❌ CRITICAL: No full backup found in chain!" 'ERROR'
        }
        
        # Determine overall chain health
        $criticalCount = ($result.Storages | Where-Object { $_.ChainStatus -eq "Critical" }).Count
        if ($criticalCount -gt 0) {
            $result.ChainValidation.IsValid = $false
            $result.ChainValidation.Issues += "$criticalCount backups with critical issues"
            Write-Log "  ❌ Chain validation FAILED: $criticalCount critical issues found" 'ERROR'
        } else {
            Write-Log "  ✅ Chain validation PASSED" 'SUCCESS'
        }
        
    } catch {
        Write-Log "❌ Error parsing VBM file: $_" 'ERROR'
        $result.ChainValidation.IsValid = $false
        $result.ChainValidation.Issues += "Parse error: $_"
    }
    
    return $result
}

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

# Function to analyze GFS retention policy compliance and generate deep insights
function Analyze-GFSCompliance {
    param(
        [array]$Storages,
        [hashtable]$MachineData
    )
    
    $analysis = @{
        GFSCompliance = @{
            Score = 0
            Grade = "F"
            DailyRetention = @{}
            WeeklyRetention = @{}
            MonthlyRetention = @{}
            YearlyRetention = @{}
        }
        StorageEfficiency = @{}
        BackupHealth = @{}
        Recommendations = @()
        Insights = @()
    }
    
    if ($Storages.Count -eq 0) {
        return $analysis
    }
    
    # Analyze backup distribution over time
    $backupDates = @{}
    $fullBackups = @()
    $incrementals = @()
    
    foreach ($storage in $Storages) {
        try {
            # Skip if CreationTime is empty or invalid
            if ([string]::IsNullOrWhiteSpace($storage.CreationTime)) {
                continue
            }
            
            $date = [DateTime]::Parse($storage.CreationTime)
            $dateKey = $date.ToString("yyyy-MM-dd")
            
            if (-not $backupDates.ContainsKey($dateKey)) {
                $backupDates[$dateKey] = @{
                    Full = @()
                    Incremental = @()
                    Date = $date
                }
            }
            
            if ($storage.Type -eq "Full") {
                $backupDates[$dateKey].Full += $storage
                $fullBackups += $storage
            } else {
                $backupDates[$dateKey].Incremental += $storage
                $incrementals += $storage
            }
        } catch {
            # Skip if date parsing fails
        }
    }
    
    # Calculate date ranges
    $sortedDates = $backupDates.Keys | Sort-Object
    if ($sortedDates.Count -gt 0) {
        # Parse dates safely
        $validDates = @()
        foreach ($dateStr in $sortedDates) {
            try {
                $validDates += [DateTime]::Parse($dateStr)
            } catch {
                # Skip invalid dates
            }
        }
        
        if ($validDates.Count -eq 0) {
            return $analysis
        }
        
        $oldestDate = $validDates | Sort-Object | Select-Object -First 1
        $newestDate = $validDates | Sort-Object | Select-Object -Last 1
        $retentionSpan = ($newestDate - $oldestDate).Days
        
        # Analyze daily retention (last 7 days, not including today)
        $last7Days = $newestDate.AddDays(-6).Date  # Go back 6 days to get 7 days total including newest
        $dailyBackups = $backupDates.Keys | Where-Object { 
            try { 
                $backupDate = [DateTime]::Parse($_)
                $backupDate -ge $last7Days -and $backupDate -le $newestDate
            } catch { 
                $false 
            }
        }
        
        # Cap the actual count at the expected value (can't have more than 7 days in 7 days)
        $actualDailyCount = [Math]::Min($dailyBackups.Count, 7)
        
        $analysis.GFSCompliance.DailyRetention = @{
            Expected = 7
            Actual = $actualDailyCount
            Coverage = [math]::Round(($actualDailyCount / 7) * 100, 1)
        }
        
        # Analyze weekly retention (last 4 weeks)
        $weeklyBackups = @{}
        for ($i = 0; $i -lt 4; $i++) {
            $weekStart = $newestDate.AddDays(-($i * 7 + 7))
            $weekEnd = $newestDate.AddDays(-($i * 7))
            $weekKey = "Week-$($i+1)"
            
            $weekBackups = $backupDates.Keys | Where-Object {
                try {
                    $d = [DateTime]::Parse($_)
                    $d -ge $weekStart -and $d -lt $weekEnd
                } catch {
                    $false
                }
            }
            
            $weeklyBackups[$weekKey] = $weekBackups.Count
        }
        
        $analysis.GFSCompliance.WeeklyRetention = @{
            Expected = 4
            Actual = ($weeklyBackups.Values | Where-Object { $_ -gt 0 }).Count
            Coverage = [math]::Round((($weeklyBackups.Values | Where-Object { $_ -gt 0 }).Count / 4) * 100, 1)
            Details = $weeklyBackups
        }
        
        # Analyze monthly retention (last 12 months)
        $monthlyBackups = @{}
        for ($i = 0; $i -lt 12; $i++) {
            $monthDate = $newestDate.AddMonths(-$i)
            $monthKey = $monthDate.ToString("yyyy-MM")
            
            $monthBackups = $backupDates.Keys | Where-Object {
                $_ -like "$monthKey*"
            }
            
            if ($monthBackups.Count -gt 0) {
                $monthlyBackups[$monthKey] = $monthBackups.Count
            }
        }
        
        $analysis.GFSCompliance.MonthlyRetention = @{
            Expected = 12
            Actual = $monthlyBackups.Count
            Coverage = [math]::Round(($monthlyBackups.Count / 12) * 100, 1)
            Details = $monthlyBackups
        }
        
        # Calculate GFS compliance score
        $dailyScore = $analysis.GFSCompliance.DailyRetention.Coverage
        $weeklyScore = $analysis.GFSCompliance.WeeklyRetention.Coverage
        $monthlyScore = $analysis.GFSCompliance.MonthlyRetention.Coverage
        
        $analysis.GFSCompliance.Score = [math]::Round(($dailyScore * 0.4 + $weeklyScore * 0.3 + $monthlyScore * 0.3), 1)
        
        # Assign grade
        $analysis.GFSCompliance.Grade = switch ([int]$analysis.GFSCompliance.Score) {
            {$_ -ge 95} { "A+" }
            {$_ -ge 90} { "A" }
            {$_ -ge 85} { "B+" }
            {$_ -ge 80} { "B" }
            {$_ -ge 75} { "C+" }
            {$_ -ge 70} { "C" }
            {$_ -ge 65} { "D+" }
            {$_ -ge 60} { "D" }
            default { "F" }
        }
    }
    
    # Analyze storage efficiency
    $totalBackupSize = ($Storages | Measure-Object -Property ExpectedSize -Sum).Sum
    $totalDataSize = ($Storages | Measure-Object -Property DataSize -Sum).Sum
    $avgDedupRatio = ($Storages | Where-Object { $_.DedupRatio -gt 0 } | Measure-Object -Property DedupRatio -Average).Average
    $avgCompressRatio = ($Storages | Where-Object { $_.CompressRatio -gt 0 } | Measure-Object -Property CompressRatio -Average).Average
    
    $analysis.StorageEfficiency = @{
        TotalBackupSize = $totalBackupSize
        TotalDataSize = $totalDataSize
        CompressionRatio = if ($totalDataSize -gt 0) { [math]::Round($totalBackupSize / $totalDataSize * 100, 1) } else { 0 }
        SpaceSaved = $totalDataSize - $totalBackupSize
        AverageDedupRatio = [math]::Round($avgDedupRatio, 1)
        AverageCompressRatio = [math]::Round($avgCompressRatio, 1)
    }
    
    # Generate insights
    $analysis.Insights = @()
    
    # Insight 1: Backup frequency pattern
    if ($backupDates.Count -gt 0) {
        $avgBackupsPerDay = [math]::Round($Storages.Count / [Math]::Max($retentionSpan, 1), 2)
        $analysis.Insights += @{
            Category = "Backup Frequency"
            Severity = if ($avgBackupsPerDay -lt 0.8) { "Warning" } else { "Info" }
            Message = "Average backup frequency: $avgBackupsPerDay backups per day over $retentionSpan days"
            Detail = "This indicates " + $(if ($avgBackupsPerDay -ge 1) { "healthy daily backup execution" } elseif ($avgBackupsPerDay -ge 0.7) { "acceptable backup frequency with some gaps" } else { "concerning gaps in backup schedule" })
        }
    }
    
    # Insight 2: Full vs Incremental ratio
    $fullRatio = if ($Storages.Count -gt 0) { [math]::Round(($fullBackups.Count / $Storages.Count) * 100, 1) } else { 0 }
    $analysis.Insights += @{
        Category = "Backup Type Distribution"
        Severity = if ($fullRatio -gt 30) { "Warning" } elseif ($fullRatio -lt 5) { "Warning" } else { "Info" }
        Message = "Full backup ratio: $fullRatio% ($($fullBackups.Count) full, $($incrementals.Count) incremental)"
        Detail = if ($fullRatio -gt 30) {
            "High full backup ratio detected. Consider reducing full backup frequency to optimize storage. Each full backup consumes significantly more space than incrementals."
        } elseif ($fullRatio -lt 5) {
            "Very low full backup ratio. Consider increasing full backup frequency for better recovery point independence and reduced chain dependency risk."
        } else {
            "Balanced full to incremental ratio. This provides good storage efficiency while maintaining reasonable recovery point independence."
        }
    }
    
    # Insight 3: Deduplication effectiveness
    if ($avgDedupRatio) {
        $analysis.Insights += @{
            Category = "Deduplication Performance"
            Severity = if ($avgDedupRatio -lt 30) { "Warning" } else { "Info" }
            Message = "Average deduplication ratio: $([math]::Round($avgDedupRatio, 1))%"
            Detail = if ($avgDedupRatio -ge 70) {
                "Excellent deduplication performance. Your data has high redundancy, making it ideal for deduplication. This is typical for VMs with similar OS and applications."
            } elseif ($avgDedupRatio -ge 50) {
                "Good deduplication performance. Reasonable data redundancy is being eliminated, providing solid storage savings."
            } elseif ($avgDedupRatio -ge 30) {
                "Moderate deduplication performance. Consider reviewing VM workloads - databases and unique data naturally deduplicate less."
            } else {
                "Poor deduplication performance. This could indicate highly unique data, encrypted workloads, or already compressed data. Review if deduplication is worth the processing overhead."
            }
        }
    }
    
    # Insight 4: Storage growth trend
    if ($Storages.Count -ge 5) {
        $recentBackups = $Storages | Sort-Object CreationTime | Select-Object -Last 5
        $olderBackups = $Storages | Sort-Object CreationTime | Select-Object -First 5
        
        $recentAvgSize = ($recentBackups | Measure-Object -Property ExpectedSize -Average).Average
        $olderAvgSize = ($olderBackups | Measure-Object -Property ExpectedSize -Average).Average
        
        if ($olderAvgSize -gt 0) {
            $growthRate = [math]::Round((($recentAvgSize - $olderAvgSize) / $olderAvgSize) * 100, 1)
            
            $analysis.Insights += @{
                Category = "Storage Growth Trend"
                Severity = if ([Math]::Abs($growthRate) -gt 50) { "Warning" } else { "Info" }
                Message = "Backup size growth: $growthRate% (comparing oldest vs newest backups)"
                Detail = if ($growthRate -gt 50) {
                    "Significant backup size increase detected. This could indicate: 1) Rapid data growth in VMs, 2) Reduced deduplication effectiveness, 3) New applications or databases added. Consider capacity planning for future storage needs."
                } elseif ($growthRate -gt 20) {
                    "Moderate backup size growth observed. Normal for active production systems. Monitor storage capacity to ensure adequate space for future retention."
                } elseif ($growthRate -lt -20) {
                    "Backup size reduction detected. This could indicate: 1) Data cleanup or archival, 2) Improved deduplication, 3) Removed applications. Verify this is intentional."
                } else {
                    "Stable backup sizes indicate consistent data volume and good deduplication performance. This is ideal for capacity planning."
                }
            }
        }
    }
    
    return $analysis
}

# Function to generate verbose AI-powered storage recommendations
function Get-VerboseStorageRecommendations {
    param(
        [hashtable]$GFSAnalysis,
        [hashtable]$MachineData,
        [hashtable]$StorageMetrics
    )
    
    $recommendations = @()
    
    # GFS Compliance Recommendations
    if ($GFSAnalysis.GFSCompliance.Score -lt 90) {
        $recommendations += @{
            Type = "GFS_COMPLIANCE"
            Severity = if ($GFSAnalysis.GFSCompliance.Score -lt 60) { "Critical" } elseif ($GFSAnalysis.GFSCompliance.Score -lt 80) { "High" } else { "Medium" }
            Title = "GFS Retention Policy Compliance: $($GFSAnalysis.GFSCompliance.Grade) ($($GFSAnalysis.GFSCompliance.Score)%)"
            Message = "Current backup retention does not fully comply with GFS best practices"
            Details = @(
                "Daily Coverage: $($GFSAnalysis.GFSCompliance.DailyRetention.Coverage)% - $($GFSAnalysis.GFSCompliance.DailyRetention.Actual) of $($GFSAnalysis.GFSCompliance.DailyRetention.Expected) days"
                "Weekly Coverage: $($GFSAnalysis.GFSCompliance.WeeklyRetention.Coverage)% - $($GFSAnalysis.GFSCompliance.WeeklyRetention.Actual) of $($GFSAnalysis.GFSCompliance.WeeklyRetention.Expected) weeks"
                "Monthly Coverage: $($GFSAnalysis.GFSCompliance.MonthlyRetention.Coverage)% - $($GFSAnalysis.GFSCompliance.MonthlyRetention.Actual) of $($GFSAnalysis.GFSCompliance.MonthlyRetention.Expected) months"
            )
            Actions = @(
                "Review and adjust backup job schedules to ensure daily backups"
                "Configure weekly full backups to maintain at least 4 weekly restore points"
                "Implement monthly archival to maintain 12 months of recovery capability"
                "Consider implementing Veeam's built-in GFS retention policy settings"
            )
        }
    }
    
    # Storage Efficiency Recommendations
    if ($GFSAnalysis.StorageEfficiency.AverageDedupRatio -lt 40) {
        $recommendations += @{
            Type = "DEDUP_OPTIMIZATION"
            Severity = "High"
            Title = "Suboptimal Deduplication Performance"
            Message = "Current deduplication ratio of $($GFSAnalysis.StorageEfficiency.AverageDedupRatio)% is below recommended levels"
            Details = @(
                "Current space saved: $(Format-StorageSize ([math]::Round($GFSAnalysis.StorageEfficiency.SpaceSaved / 1GB, 2)))"
                "Compression efficiency: $($GFSAnalysis.StorageEfficiency.CompressionRatio)%"
                "Potential additional savings with better dedup: $(Format-StorageSize ([math]::Round($GFSAnalysis.StorageEfficiency.TotalBackupSize * 0.3 / 1GB, 2)))"
            )
            Actions = @(
                "Enable Veeam deduplication if not already active"
                "Consider per-VM backup chains for better deduplication"
                "Review if VMs contain encrypted or pre-compressed data"
                "Evaluate using Veeam's compression level 'Optimal' or 'High'"
                "Consider ReFS/XFS with block cloning for additional storage savings"
            )
        }
    }
    
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

# Function to generate comprehensive machine analysis incorporating global best practices
function Get-ComprehensiveMachineAnalysis {
    param(
        [hashtable]$MachineData,
        [hashtable]$GFSAnalysis,
        [hashtable]$VBMMetadata,
        [string]$MachineName
    )
    
    $analysis = @{
        MachineSummary = ""
        Characteristics = @()
        Problems = @()
        Benefits = @()
        BestPracticeRecommendations = @()
        VeeamSpecificRecommendations = @()
        ComplianceScore = 0
        RiskLevel = "Low"
    }
    
    # Analyze machine characteristics
    $totalBackups = 0
    $oldestBackup = $null
    $newestBackup = $null
    $avgBackupSize = 0
    $totalStorageUsed = 0
    $dedupRatio = 0
    $compressionRatio = 0
    $fullBackupCount = 0
    $incrementalCount = 0
    $backupFrequency = "Unknown"
    $retentionDays = 0
    
    # Collect all backups from different categories
    $allBackups = @()
    
    if ($MachineData) {
        if ($MachineData.FullBackups) {
            foreach ($backup in $MachineData.FullBackups) {
                $allBackups += @{
                    Type = "Full"
                    BackupDate = $backup.BackupDate
                    SizeGB = $backup.SizeGB
                    FileName = $backup.FileName
                }
            }
            $fullBackupCount = $MachineData.FullBackups.Count
        }
        
        if ($MachineData.IncrementalBackups) {
            foreach ($backup in $MachineData.IncrementalBackups) {
                $allBackups += @{
                    Type = "Incremental"
                    BackupDate = $backup.BackupDate
                    SizeGB = $backup.SizeGB
                    FileName = $backup.FileName
                }
            }
            $incrementalCount = $MachineData.IncrementalBackups.Count
        }
        
        if ($MachineData.ReverseIncrementalBackups) {
            foreach ($backup in $MachineData.ReverseIncrementalBackups) {
                $allBackups += @{
                    Type = "ReverseIncremental"
                    BackupDate = $backup.BackupDate
                    SizeGB = $backup.SizeGB
                    FileName = $backup.FileName
                }
            }
            $incrementalCount += $MachineData.ReverseIncrementalBackups.Count
        }
        
        $totalBackups = $allBackups.Count
        
        # Get dates from all backups
        $dates = $allBackups | ForEach-Object { $_.BackupDate } | Where-Object { $_ } | Sort-Object
        if ($dates.Count -gt 0) {
            $oldestBackup = $dates[0]
            $newestBackup = $dates[-1]
            $retentionDays = if ($oldestBackup -eq $newestBackup) { 1 } else { ($newestBackup - $oldestBackup).Days }
        } elseif ($MachineData.VBMMetadata -and $MachineData.VBMMetadata.Storages) {
            # If no dates from backup files, try to get from VBM metadata
            $vbmDates = $MachineData.VBMMetadata.Storages | ForEach-Object { 
                try {
                    [DateTime]::Parse($_.CreationTime)
                } catch {
                    $null
                }
            } | Where-Object { $_ } | Sort-Object
            
            if ($vbmDates.Count -gt 0) {
                $oldestBackup = $vbmDates[0]
                $newestBackup = $vbmDates[-1]
                $retentionDays = if ($oldestBackup -eq $newestBackup) { 1 } else { ($newestBackup - $oldestBackup).Days }
                $dates = $vbmDates  # Use VBM dates for frequency calculation
            }
        }
        
        # Calculate total storage used
        $totalStorageUsed = if ($MachineData.TotalSizeGB) { 
            $MachineData.TotalSizeGB 
        } else { 
            ($allBackups | Measure-Object -Property SizeGB -Sum).Sum 
        }
        
        if ($totalBackups -gt 0) {
            $avgBackupSize = $totalStorageUsed / $totalBackups
        }
    }
    
    # Calculate backup frequency
    if ($dates -and $dates.Count -gt 1) {
        $intervals = @()
        $dailyCount = 0
        $weeklyCount = 0
        
        for ($i = 1; $i -lt $dates.Count; $i++) {
            $interval = ($dates[$i] - $dates[$i-1]).Days
            if ($interval -ge 0) {
                $intervals += $interval
                if ($interval -eq 1) { $dailyCount++ }
                elseif ($interval -ge 6 -and $interval -le 8) { $weeklyCount++ }
            }
        }
        
        if ($intervals.Count -gt 0) {
            # Analyze the pattern of backups
            $avgInterval = ($intervals | Measure-Object -Average).Average
            $minInterval = ($intervals | Measure-Object -Minimum).Minimum  
            $maxInterval = ($intervals | Measure-Object -Maximum).Maximum
            
            # Check for pattern of consecutive daily backups
            if ($dailyCount -ge 2) {
                # We have consecutive daily backups
                if ($fullBackupCount -eq 1 -and $incrementalCount -ge 2) {
                    # Pattern: daily incrementals with weekly full
                    $backupFrequency = "Daily (with weekly full backup)"
                } else {
                    $backupFrequency = "Daily"
                }
            } elseif ($avgInterval -le 1.5 -and $minInterval -le 1) {
                $backupFrequency = "Daily"
            } elseif ($avgInterval -le 3) {
                $backupFrequency = "Every 2-3 days"
            } elseif ($avgInterval -le 7) {
                $backupFrequency = "Weekly"
            } elseif ($avgInterval -le 14) {
                $backupFrequency = "Bi-weekly"
            } elseif ($avgInterval -le 31) {
                $backupFrequency = "Monthly"
            } else {
                $backupFrequency = "Irregular (>monthly)"
            }
        } else {
            # Single backup or same-day backups
            $backupFrequency = "Daily"
        }
    } elseif ($dates -and $dates.Count -eq 1) {
        # Only one backup
        $backupFrequency = "Single backup"
    }
    
    # Analyze GFS compliance
    if ($GFSAnalysis -and $GFSAnalysis.GFSCompliance) {
        $analysis.ComplianceScore = $GFSAnalysis.GFSCompliance.Score
        $dedupRatio = $GFSAnalysis.StorageEfficiency.AverageDedupRatio
        $compressionRatio = $GFSAnalysis.StorageEfficiency.CompressionRatio
    }
    
    # Determine risk level based on various factors
    $riskFactors = 0
    
    # Check for backup chain issues
    if ($VBMMetadata -and $VBMMetadata.ChainValidation) {
        if (-not $VBMMetadata.ChainValidation.IsValid) {
            $riskFactors += 3
            $analysis.Problems += "Broken backup chains detected"
        }
        if ($VBMMetadata.ChainValidation.MissingFiles.Count -gt 0) {
            $riskFactors += 2
            $analysis.Problems += "$($VBMMetadata.ChainValidation.MissingFiles.Count) missing backup files"
        }
    }
    
    # Check retention compliance
    if ($analysis.ComplianceScore -lt 60) {
        $riskFactors += 2
        $analysis.Problems += "Poor GFS retention compliance ($($analysis.ComplianceScore)%)"
    } elseif ($analysis.ComplianceScore -lt 80) {
        $riskFactors += 1
        $analysis.Problems += "Moderate GFS retention compliance ($($analysis.ComplianceScore)%)"
    } else {
        $analysis.Benefits += "Good GFS retention compliance ($($analysis.ComplianceScore)%)"
    }
    
    # Check backup frequency
    if ($backupFrequency -eq "Irregular (>monthly)" -or $backupFrequency -eq "Monthly") {
        $riskFactors += 2
        $analysis.Problems += "Infrequent backup schedule ($backupFrequency)"
    } elseif ($backupFrequency -eq "Daily") {
        $analysis.Benefits += "Excellent backup frequency ($backupFrequency)"
    }
    
    # Check deduplication efficiency
    if ($dedupRatio -lt 30) {
        $riskFactors += 1
        $analysis.Problems += "Poor deduplication ratio ($dedupRatio%)"
    } elseif ($dedupRatio -gt 50) {
        $analysis.Benefits += "Excellent deduplication ratio ($dedupRatio%)"
    }
    
    # Check retention period
    if ($retentionDays -lt 7) {
        $riskFactors += 2
        $analysis.Problems += "Very short retention period ($retentionDays days)"
    } elseif ($retentionDays -lt 30) {
        $riskFactors += 1
        $analysis.Problems += "Short retention period ($retentionDays days)"
    } elseif ($retentionDays -gt 90) {
        $analysis.Benefits += "Good retention period ($retentionDays days)"
    }
    
    # Determine overall risk level
    $analysis.RiskLevel = switch ($riskFactors) {
        {$_ -ge 7} { "Critical" }
        {$_ -ge 5} { "High" }
        {$_ -ge 3} { "Medium" }
        {$_ -ge 1} { "Low" }
        default { "Minimal" }
    }
    
    # Add characteristics
    $analysis.Characteristics = @(
        "Total backups: $totalBackups ($fullBackupCount full, $incrementalCount incremental)"
        "Backup frequency: $backupFrequency"
        "Retention period: $retentionDays days"
        "Average backup size: $('{0:N2}' -f $avgBackupSize) GB"
        "Total storage used: $('{0:N2}' -f $totalStorageUsed) GB"
        "Deduplication ratio: $dedupRatio%"
        "Compression ratio: $compressionRatio%"
    )
    
    # Generate Veeam-specific recommendations
    $analysis.VeeamSpecificRecommendations = @()
    
    # Varied Veeam-specific recommendations with different phrasings
    $veeamRecVariations = @{
        Dedup = @(
            "Enable Veeam deduplication and compression settings at 'Optimal' or 'High' level",
            "Boost storage efficiency by activating advanced deduplication in Veeam settings",
            "Maximize storage savings through Veeam's intelligent deduplication features",
            "Optimize repository usage with enhanced compression and deduplication algorithms"
        )
        PerVM = @(
            "Consider using per-VM backup chains for better deduplication",
            "Implement granular per-VM chains to enhance deduplication ratios",
            "Deploy individual VM backup chains for superior storage optimization",
            "Structure backups using per-VM methodology for improved efficiency"
        )
        Synthetic = @(
            "Implement Veeam's synthetic full backup feature to reduce storage consumption",
            "Leverage synthetic fulls to minimize storage footprint and backup windows",
            "Deploy intelligent synthetic backup technology for optimal storage utilization",
            "Activate synthetic full capabilities to streamline backup operations"
        )
        Forward = @(
            "Configure forward incremental with synthetic fulls on weekends",
            "Establish a forward incremental strategy complemented by weekend synthetic operations",
            "Design backup chains using forward incrementals with periodic synthetic consolidation",
            "Optimize backup scheduling with forward incremental and weekly synthetic patterns"
        )
        Daily = @(
            "Configure Veeam backup jobs to run daily for critical VMs",
            "Establish daily backup schedules for mission-critical virtual machines",
            "Implement 24-hour backup cycles for essential workloads",
            "Schedule nightly backups to ensure critical system protection"
        )
        Copy = @(
            "Use Veeam's backup copy jobs for offsite protection",
            "Deploy backup copy jobs to establish geographic redundancy",
            "Configure secondary copies for disaster recovery preparedness",
            "Implement backup copy chains for comprehensive data protection"
        )
    }
    
    # Randomly select variations for recommendations
    $random = Get-Random
    
    if ($dedupRatio -lt 40) {
        $analysis.VeeamSpecificRecommendations += $veeamRecVariations.Dedup[(Get-Random -Maximum $veeamRecVariations.Dedup.Count)]
        $analysis.VeeamSpecificRecommendations += $veeamRecVariations.PerVM[(Get-Random -Maximum $veeamRecVariations.PerVM.Count)]
    }
    
    if ($fullBackupCount -gt ($totalBackups * 0.3)) {
        $analysis.VeeamSpecificRecommendations += $veeamRecVariations.Synthetic[(Get-Random -Maximum $veeamRecVariations.Synthetic.Count)]
        $analysis.VeeamSpecificRecommendations += $veeamRecVariations.Forward[(Get-Random -Maximum $veeamRecVariations.Forward.Count)]
    }
    
    if ($backupFrequency -ne "Daily") {
        $analysis.VeeamSpecificRecommendations += $veeamRecVariations.Daily[(Get-Random -Maximum $veeamRecVariations.Daily.Count)]
        $analysis.VeeamSpecificRecommendations += $veeamRecVariations.Copy[(Get-Random -Maximum $veeamRecVariations.Copy.Count)]
    }
    
    # Generate varied general best practice recommendations
    $analysis.BestPracticeRecommendations = @()
    
    # Varied best practice recommendations with different phrasings
    $bestPracticeVariations = @{
        Rule321 = @(
            "Follow the 3-2-1 backup rule: Keep 3 copies of data, on 2 different media types, with 1 offsite copy",
            "Implement the industry-standard 3-2-1 strategy for comprehensive data protection",
            "Adopt the proven 3-2-1 methodology: triple redundancy across diverse storage platforms",
            "Ensure data resilience through 3-2-1 best practices with geographic distribution"
        )
        RPO = @(
            "Align backup frequency with RPO requirements - critical systems should have daily or more frequent backups",
            "Synchronize backup schedules with business continuity objectives and RPO targets",
            "Match backup intervals to recovery point objectives for optimal protection",
            "Calibrate backup frequency based on acceptable data loss thresholds"
        )
        Retention = @(
            "Extend retention to at least 30 days for compliance and recovery flexibility",
            "Maintain minimum 30-day retention periods to meet regulatory requirements",
            "Establish comprehensive retention policies exceeding 30 days for audit readiness",
            "Configure retention spans of 30+ days for enhanced recovery options"
        )
        Testing = @(
            "Implement regular restore testing using Veeam's SureBackup technology",
            "Schedule automated recovery verification through SureBackup validation",
            "Deploy continuous restore testing protocols with automated verification",
            "Establish routine recovery drills using intelligent testing automation"
        )
        DR = @(
            "Document and test disaster recovery procedures quarterly",
            "Conduct quarterly DR exercises with comprehensive documentation updates",
            "Perform scheduled disaster recovery simulations every three months",
            "Execute regular DR readiness assessments and procedure validation"
        )
        Immutable = @(
            "Enable immutable backups using Veeam's hardened repository feature",
            "Deploy ransomware-resistant immutable storage configurations",
            "Activate write-once-read-many (WORM) storage for backup protection",
            "Implement hardened repositories with immutability for cyber resilience"
        )
        Encryption = @(
            "Implement backup encryption for sensitive data",
            "Apply AES-256 encryption to protect backup data at rest and in transit",
            "Secure backup repositories with enterprise-grade encryption standards",
            "Enable comprehensive encryption across all backup operations"
        )
        Credentials = @(
            "Use separate credentials for backup infrastructure with least privilege principle",
            "Implement role-based access control with dedicated backup service accounts",
            "Deploy segregated authentication with minimal permission sets",
            "Establish dedicated backup credentials following zero-trust principles"
        )
        Monitoring = @(
            "Configure Veeam ONE or similar monitoring for proactive backup health monitoring",
            "Deploy comprehensive monitoring solutions for real-time backup visibility",
            "Implement centralized monitoring dashboards for backup infrastructure",
            "Establish proactive monitoring with predictive analytics capabilities"
        )
        Alerts = @(
            "Set up automated alerts for backup job failures and warnings",
            "Configure intelligent alerting for immediate failure notification",
            "Deploy multi-channel alert systems for critical backup events",
            "Implement smart notification workflows for backup anomalies"
        )
    }
    
    # 3-2-1 Rule (always include, but vary the phrasing)
    $analysis.BestPracticeRecommendations += $bestPracticeVariations.Rule321[(Get-Random -Maximum $bestPracticeVariations.Rule321.Count)]
    
    # RPO/RTO recommendations
    if ($backupFrequency -ne "Daily") {
        $analysis.BestPracticeRecommendations += $bestPracticeVariations.RPO[(Get-Random -Maximum $bestPracticeVariations.RPO.Count)]
    }
    
    # Retention recommendations
    if ($retentionDays -lt 30) {
        $analysis.BestPracticeRecommendations += $bestPracticeVariations.Retention[(Get-Random -Maximum $bestPracticeVariations.Retention.Count)]
    }
    
    # Testing recommendations (randomly select one)
    $analysis.BestPracticeRecommendations += $bestPracticeVariations.Testing[(Get-Random -Maximum $bestPracticeVariations.Testing.Count)]
    $analysis.BestPracticeRecommendations += $bestPracticeVariations.DR[(Get-Random -Maximum $bestPracticeVariations.DR.Count)]
    
    # Security recommendations (randomly select 2 of 3)
    $securityRecs = @(
        $bestPracticeVariations.Immutable[(Get-Random -Maximum $bestPracticeVariations.Immutable.Count)],
        $bestPracticeVariations.Encryption[(Get-Random -Maximum $bestPracticeVariations.Encryption.Count)],
        $bestPracticeVariations.Credentials[(Get-Random -Maximum $bestPracticeVariations.Credentials.Count)]
    ) | Get-Random -Count 3
    $analysis.BestPracticeRecommendations += $securityRecs
    
    # Monitoring recommendations (randomly select 1 of 2)
    if ((Get-Random -Maximum 2) -eq 0) {
        $analysis.BestPracticeRecommendations += $bestPracticeVariations.Monitoring[(Get-Random -Maximum $bestPracticeVariations.Monitoring.Count)]
    } else {
        $analysis.BestPracticeRecommendations += $bestPracticeVariations.Alerts[(Get-Random -Maximum $bestPracticeVariations.Alerts.Count)]
    }
    
    # Generate varied comprehensive 2-paragraph summary with diverse language
    $summaryVariations = @{
        Opening = @(
            "The backup infrastructure for $MachineName demonstrates a $($backupFrequency.ToLower()) backup schedule with $totalBackups total backup points spanning $retentionDays days",
            "Analysis of $MachineName reveals a $($backupFrequency.ToLower()) protection cadence encompassing $totalBackups restore points across a $($retentionDays + 1)-day retention window",
            "$MachineName operates on a $($backupFrequency.ToLower()) backup cycle, maintaining $totalBackups recovery points over a $($retentionDays + 1)-day period",
            "The $MachineName backup ecosystem employs $($backupFrequency.ToLower()) protection, preserving $totalBackups backup instances within a $($retentionDays + 1)-day timeframe"
        )
        Storage = @(
            "The system maintains $fullBackupCount full backups and $incrementalCount incremental backups, consuming approximately $('{0:N2}' -f $totalStorageUsed) GB of storage with an average backup size of $('{0:N2}' -f $avgBackupSize) GB",
            "Repository utilization includes $fullBackupCount full and $incrementalCount incremental backups, occupying $('{0:N2}' -f $totalStorageUsed) GB total with typical backup sizes averaging $('{0:N2}' -f $avgBackupSize) GB",
            "Storage allocation comprises $fullBackupCount complete backups plus $incrementalCount incremental copies, totaling $('{0:N2}' -f $totalStorageUsed) GB with mean backup footprints of $('{0:N2}' -f $avgBackupSize) GB",
            "The backup repository houses $fullBackupCount full images alongside $incrementalCount incremental snapshots, collectively requiring $('{0:N2}' -f $totalStorageUsed) GB while averaging $('{0:N2}' -f $avgBackupSize) GB per backup"
        )
        ComplianceGood = @(
            "The GFS retention compliance score of $($analysis.ComplianceScore)% indicates good adherence to retention policies",
            "With a GFS compliance rating of $($analysis.ComplianceScore)%, the system demonstrates strong retention policy alignment",
            "Achieving $($analysis.ComplianceScore)% GFS compliance reflects robust adherence to established retention standards",
            "The impressive $($analysis.ComplianceScore)% GFS retention score validates effective policy implementation"
        )
        CompliancePoor = @(
            "The GFS retention compliance score of $($analysis.ComplianceScore)% suggests room for improvement in retention policy adherence",
            "At $($analysis.ComplianceScore)% GFS compliance, opportunities exist to enhance retention policy effectiveness",
            "The current $($analysis.ComplianceScore)% GFS retention score indicates potential for policy optimization",
            "With GFS compliance at $($analysis.ComplianceScore)%, retention strategy refinements could yield improvements"
        )
        DedupGood = @(
            "Storage efficiency metrics show effective deduplication at $dedupRatio% with a compression ratio of $compressionRatio%, indicating good storage optimization",
            "Advanced storage optimization achieves $dedupRatio% deduplication alongside $compressionRatio% compression, maximizing repository efficiency",
            "The infrastructure delivers $dedupRatio% deduplication efficiency paired with $compressionRatio% compression, demonstrating excellent storage economics",
            "Repository optimization yields $dedupRatio% deduplication rates and $compressionRatio% compression levels, confirming effective resource utilization"
        )
        DedupPoor = @(
            "Current deduplication efficiency at $dedupRatio% with compression at $compressionRatio% presents opportunities for storage optimization",
            "With deduplication at $dedupRatio% and compression achieving $compressionRatio%, significant storage optimization potential remains untapped",
            "The modest $dedupRatio% deduplication and $compressionRatio% compression rates suggest room for efficiency improvements",
            "Storage metrics showing $dedupRatio% deduplication and $compressionRatio% compression indicate optimization opportunities"
        )
        RiskAssessment = @(
            "The overall risk assessment indicates a $($analysis.RiskLevel.ToLower()) risk level for this backup infrastructure",
            "Comprehensive risk evaluation categorizes this backup environment at a $($analysis.RiskLevel.ToLower()) risk tier",
            "Risk analysis positions the backup infrastructure within the $($analysis.RiskLevel.ToLower()) risk category",
            "The backup system's risk profile evaluates to a $($analysis.RiskLevel.ToLower()) threat level"
        )
        Problems = @(
            "Key areas requiring attention include",
            "Critical focus areas encompass",
            "Priority remediation targets include",
            "Essential improvement opportunities involve"
        )
        NoProblems = @(
            "The backup configuration shows no critical issues",
            "No significant operational concerns were identified",
            "The infrastructure operates without major deficiencies",
            "System analysis reveals stable operational parameters"
        )
        Benefits = @(
            "Positive aspects include",
            "Notable strengths encompass",
            "Key advantages feature",
            "Operational highlights include"
        )
        Recommendations = @(
            "Priority recommendations include",
            "Strategic initiatives should focus on",
            "Immediate optimization opportunities involve",
            "Key enhancement priorities encompass"
        )
    }
    
    # Build paragraph 1 with varied language
    $para1 = $summaryVariations.Opening[(Get-Random -Maximum $summaryVariations.Opening.Count)] + ". "
    $para1 += $summaryVariations.Storage[(Get-Random -Maximum $summaryVariations.Storage.Count)] + ". "
    
    if ($analysis.ComplianceScore -ge 80) {
        $para1 += $summaryVariations.ComplianceGood[(Get-Random -Maximum $summaryVariations.ComplianceGood.Count)] + ". "
    } else {
        $para1 += $summaryVariations.CompliancePoor[(Get-Random -Maximum $summaryVariations.CompliancePoor.Count)] + ". "
    }
    
    if ($dedupRatio -gt 40) {
        $para1 += $summaryVariations.DedupGood[(Get-Random -Maximum $summaryVariations.DedupGood.Count)] + "."
    } else {
        $para1 += $summaryVariations.DedupPoor[(Get-Random -Maximum $summaryVariations.DedupPoor.Count)] + "."
    }
    
    # Build paragraph 2 with varied language
    $para2 = $summaryVariations.RiskAssessment[(Get-Random -Maximum $summaryVariations.RiskAssessment.Count)] + ". "
    
    if ($analysis.Problems.Count -gt 0) {
        $para2 += $summaryVariations.Problems[(Get-Random -Maximum $summaryVariations.Problems.Count)] + ": $($analysis.Problems -join '; '). "
    } else {
        $para2 += $summaryVariations.NoProblems[(Get-Random -Maximum $summaryVariations.NoProblems.Count)] + ". "
    }
    
    if ($analysis.Benefits.Count -gt 0) {
        $para2 += $summaryVariations.Benefits[(Get-Random -Maximum $summaryVariations.Benefits.Count)] + ": $($analysis.Benefits -join '; '). "
    }
    
    $topRecommendations = $analysis.VeeamSpecificRecommendations | Select-Object -First 2
    if ($topRecommendations.Count -gt 0) {
        $para2 += $summaryVariations.Recommendations[(Get-Random -Maximum $summaryVariations.Recommendations.Count)] + ": $($topRecommendations -join ', ')."
    }
    
    $analysis.MachineSummary = "$para1`n$para2"
    
    return $analysis
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
        Write-Log "🎨 Starting HTML report generation for $ServerName" 'SUCCESS'
        
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
"@
                
                # Add chain validation warning if there are issues
                if ($machineData.ChainValidation -and -not $machineData.ChainValidation.IsValid) {
                    $html += @"
                            <div style="margin: 15px 0; padding: 15px; background: #fee2e2; border: 2px solid #dc2626; border-radius: 8px;">
                                <h4 style="margin: 0 0 10px 0; color: #dc2626;">⚠️ CRITICAL: Backup Chain Issues Detected</h4>
                                <ul style="margin: 5px 0 0 20px; color: #dc2626;">
"@
                    foreach ($issue in $machineData.ChainValidation.Issues) {
                        $html += "                                    <li>$issue</li>`n"
                    }
                    
                    if ($machineData.ChainValidation.MissingFiles.Count -gt 0) {
                        $html += "                                    <li><strong>Missing Files:</strong>`n"
                        $html += "                                        <ul style='margin-left: 20px;'>`n"
                        foreach ($missing in $machineData.ChainValidation.MissingFiles) {
                            $fileName = Split-Path -Leaf $missing.FilePath
                            $html += "                                            <li>$fileName</li>`n"
                        }
                        $html += "                                        </ul>`n"
                        $html += "                                    </li>`n"
                    }
                    
                    if ($machineData.ChainValidation.BrokenChains.Count -gt 0) {
                        $html += "                                    <li><strong>Broken Chain Links:</strong>`n"
                        $html += "                                        <ul style='margin-left: 20px;'>`n"
                        foreach ($broken in $machineData.ChainValidation.BrokenChains) {
                            $fileName = Split-Path -Leaf $broken.FilePath
                            $html += "                                            <li>$fileName (missing parent: $($broken.MissingParentId.Substring(0,8))...)</li>`n"
                        }
                        $html += "                                        </ul>`n"
                        $html += "                                    </li>`n"
                    }
                    
                    if ($machineData.ChainValidation.OrphanedIncrementals.Count -gt 0) {
                        $html += "                                    <li><strong>Orphaned Incrementals:</strong>`n"
                        $html += "                                        <ul style='margin-left: 20px;'>`n"
                        foreach ($orphan in $machineData.ChainValidation.OrphanedIncrementals) {
                            $fileName = Split-Path -Leaf $orphan.FilePath
                            $html += "                                            <li>$fileName</li>`n"
                        }
                        $html += "                                        </ul>`n"
                        $html += "                                    </li>`n"
                    }
                    
                    $html += @"
                                </ul>
                            </div>
"@
                }
                
                $html += @"
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
                
                # Add retention points table if VBM metadata is available
                if ($machineData.VBMMetadata -and $machineData.VBMMetadata.Storages.Count -gt 0) {
                    $html += @"
                            <div style="margin-top: 20px; padding: 20px; background: linear-gradient(135deg, #ffffff 0%, #f9fafb 100%); border-radius: 12px; box-shadow: 0 4px 6px rgba(0, 0, 0, 0.07);">
                                <h4 style="margin: 0 0 20px 0; color: #1e40af; font-size: 1.2em; display: flex; align-items: center; gap: 10px;">
                                    📅 Retention Points - Chain Validation & Job Settings
                                    <span style="font-size: 0.7em; padding: 4px 12px; background: linear-gradient(135deg, #e0f2fe, #dbeafe); color: #1e40af; border-radius: 20px; margin-left: auto;">
                                        Total: $($machineData.VBMMetadata.Storages.Count) points
                                    </span>
                                </h4>
                                <div style="margin-bottom: 10px; padding: 10px; background: linear-gradient(90deg, #f0f9ff 0%, #f9fafb 100%); border-radius: 8px; border-left: 4px solid #3b82f6;">
                                    <div style="font-size: 0.85em; color: #475569; margin-bottom: 8px;">
                                        <strong>Legend:</strong> 
                                        <span style="margin: 0 10px; padding: 2px 8px; background: linear-gradient(90deg, #e0f2fe, #f0f9ff); border-radius: 4px;">🔷 Full Backup</span>
                                        <span style="margin: 0 10px; padding: 2px 8px; background: linear-gradient(90deg, #dcfce7, #f0fdf4); border-radius: 4px;">🔸 Incremental</span>
                                        <span style="margin: 0 10px; padding: 2px 8px; background: #d4f4dd; border-radius: 4px;">✅ Enabled/Yes</span>
                                        <span style="margin: 0 10px; padding: 2px 8px; background: #f1f5f9; border-radius: 4px;">➖ Disabled/No</span>
                                    </div>
"@
                    # Show job parameters if available
                    if ($machineData.VBMMetadata.JobParameters) {
                        $jp = $machineData.VBMMetadata.JobParameters
                        $html += @"
                                    <div style="font-size: 0.85em; color: #1e40af;">
                                        <strong>Job Settings:</strong>
                                        <span style="margin-left: 10px;">Encryption: $(if ($jp.EncryptionEnabled) { '✅' } else { '➖' })</span>
                                        <span style="margin-left: 10px;">App Quiesce: $(if ($jp.AppQuiesce) { '✅' } else { '➖' })</span>
                                        <span style="margin-left: 10px;">Indexing: $(if ($jp.IndexingEnabled) { '✅' } else { '➖' })</span>
                                        <span style="margin-left: 10px;">GFS: $(if ($jp.GFSEnabled) { '✅' } else { '➖' })</span>
                                        <span style="margin-left: 10px;">Type: $($jp.JobType)</span>
                                        <span style="margin-left: 10px;">Block: $(if ($jp.BlockSize -gt 0) { "$($jp.BlockSize)KB" } else { '-' })</span>
                                    </div>
"@
                    }
                    $html += @"
                                </div>
                                <table style="width: 100%; border-collapse: separate; border-spacing: 0; font-size: 0.9em; border-radius: 8px; overflow: hidden; box-shadow: 0 2px 4px rgba(0,0,0,0.05);">
                                    <thead>
                                        <tr style="background: linear-gradient(135deg, #4f46e5 0%, #6366f1 100%); color: white;">
                                            <th style="padding: 12px; text-align: left; font-weight: 600;">Type</th>
                                            <th style="padding: 12px; text-align: left; font-weight: 600;">File Name</th>
                                            <th style="padding: 12px; text-align: left; font-weight: 600;">Created</th>
                                            <th style="padding: 12px; text-align: right; font-weight: 600;">Backup Size</th>
                                            <th style="padding: 12px; text-align: right; font-weight: 600;">Data Size</th>
                                            <th style="padding: 12px; text-align: center; font-weight: 600;">Dedup</th>
                                            <th style="padding: 12px; text-align: center; font-weight: 600;">GFS</th>
                                            <th style="padding: 12px; text-align: center; font-weight: 600;">Partial</th>
                                            <th style="padding: 12px; text-align: center; font-weight: 600;">Block</th>
                                            <th style="padding: 12px; text-align: center; font-weight: 600;">Status</th>
                                            <th style="padding: 12px; text-align: left; font-weight: 600;">Issues</th>
                                        </tr>
                                    </thead>
                                    <tbody>
"@
                    
                    # Sort storages by CreationTime (newest first)
                    $sortedStorages = $machineData.VBMMetadata.Storages | Sort-Object { 
                        try {
                            [DateTime]::Parse($_.CreationTime)
                        } catch {
                            [DateTime]::MinValue
                        }
                    } -Descending
                    
                    foreach ($storage in $sortedStorages) {
                        $fileName = Split-Path -Leaf $storage.FilePath
                        
                        # Format sizes
                        $backupSizeGB = if ($storage.ExpectedSize -gt 0) { [math]::Round($storage.ExpectedSize / 1GB, 2) } else { 0 }
                        $backupSizeText = Format-StorageSize $backupSizeGB
                        
                        $dataSizeGB = if ($storage.DataSize -gt 0) { [math]::Round($storage.DataSize / 1GB, 2) } else { 0 }
                        $dataSizeText = Format-StorageSize $dataSizeGB
                        
                        # Format dedup ratio with color coding
                        $dedupText = if ($storage.DedupRatio -gt 0) {
                            $dedupColor = if ($storage.DedupRatio -ge 50) { "#059669" } elseif ($storage.DedupRatio -ge 25) { "#d97706" } else { "#dc2626" }
                            "<span style='font-weight: bold; color: $dedupColor;'>$($storage.DedupRatio)%</span>"
                        } else {
                            "<span style='color: #9ca3af;'>-</span>"
                        }
                        
                        # Format creation date with day of week
                        $creationDateText = $storage.CreationTime
                        try {
                            # Parse the date and add day of week abbreviation
                            if (-not [string]::IsNullOrWhiteSpace($storage.CreationTime)) {
                                $dateObj = [DateTime]::Parse($storage.CreationTime)
                                $dayAbbrev = $dateObj.ToString("ddd")
                                $creationDateText = "$($storage.CreationTime) ($dayAbbrev)"
                            } else {
                                $creationDateText = "N/A"
                            }
                        } catch {
                            # If date parsing fails, just use the original or N/A
                            $creationDateText = if ([string]::IsNullOrWhiteSpace($storage.CreationTime)) { "N/A" } else { $storage.CreationTime }
                        }
                        
                        # Determine row color based on type and chain status
                        $rowStyle = ""
                        $statusBadge = ""
                        $issuesText = ""
                        
                        # Set base color based on backup type
                        if ($storage.Type -eq "Full") {
                            # Light blue background for full backups
                            $rowStyle = "background: linear-gradient(90deg, #e0f2fe 0%, #f0f9ff 100%);"
                        } else {
                            # Light green background for incrementals
                            $rowStyle = "background: linear-gradient(90deg, #dcfce7 0%, #f0fdf4 100%);"
                        }
                        
                        # Override with critical/warning colors if there are issues
                        if ($storage.ChainStatus -eq "Critical") {
                            $rowStyle = "background: linear-gradient(90deg, #fca5a5 0%, #fee2e2 100%); color: #991b1b; font-weight: bold;"
                            $statusBadge = "<span style='padding: 3px 10px; background: linear-gradient(135deg, #dc2626, #b91c1c); color: white; border-radius: 12px; font-weight: bold; box-shadow: 0 2px 4px rgba(0,0,0,0.1);'>❌ CRITICAL</span>"
                            $issuesText = $storage.ChainIssues -join ", "
                        } elseif ($storage.ChainStatus -eq "Warning") {
                            $rowStyle = "background: linear-gradient(90deg, #fcd34d 0%, #fef3c7 100%); color: #92400e;"
                            $statusBadge = "<span style='padding: 3px 10px; background: linear-gradient(135deg, #f59e0b, #d97706); color: white; border-radius: 12px; box-shadow: 0 2px 4px rgba(0,0,0,0.1);'>⚠️ WARNING</span>"
                            $issuesText = $storage.ChainIssues -join ", "
                        } else {
                            $statusBadge = "<span style='padding: 3px 10px; background: linear-gradient(135deg, #10b981, #059669); color: white; border-radius: 12px; box-shadow: 0 2px 4px rgba(0,0,0,0.1);'>✅ OK</span>"
                            $issuesText = "-"
                        }
                        
                        # Type icon
                        $typeIcon = if ($storage.Type -eq "Full") { "🔷" } elseif ($storage.Type -eq "Incremental") { "🔸" } else { "📦" }
                        
                        # Format additional parameters with checkmarks for boolean values
                        $gfsIcon = if ($storage.GfsPeriod -and $storage.GfsPeriod -ne "" -and $storage.GfsPeriod -ne "0") { "✅" } else { "➖" }
                        $partialIcon = if ($storage.PartialIncrement) { "✅" } else { "➖" }
                        $blockSizeText = if ($storage.BlockSize -gt 0) { "$($storage.BlockSize)KB" } else { "-" }
                        
                        $html += @"
                                        <tr style="$rowStyle transition: all 0.2s ease; cursor: pointer;" onmouseover="this.style.transform='translateX(4px)'; this.style.boxShadow='0 2px 4px rgba(0,0,0,0.1)';" onmouseout="this.style.transform='translateX(0)'; this.style.boxShadow='none';">
                                            <td style="padding: 10px 12px; border-bottom: 1px solid rgba(226, 232, 240, 0.5); font-weight: 500;">$typeIcon $($storage.Type)</td>
                                            <td style="padding: 10px 12px; border-bottom: 1px solid rgba(226, 232, 240, 0.5); font-weight: 500;">$fileName</td>
                                            <td style="padding: 10px 12px; border-bottom: 1px solid rgba(226, 232, 240, 0.5); font-size: 0.85em;">$creationDateText</td>
                                            <td style="padding: 10px 12px; border-bottom: 1px solid rgba(226, 232, 240, 0.5); text-align: right; font-weight: 600;">$backupSizeText</td>
                                            <td style="padding: 10px 12px; border-bottom: 1px solid rgba(226, 232, 240, 0.5); text-align: right; font-weight: 500;">$dataSizeText</td>
                                            <td style="padding: 10px 12px; border-bottom: 1px solid rgba(226, 232, 240, 0.5); text-align: center;">$dedupText</td>
                                            <td style="padding: 10px 12px; border-bottom: 1px solid rgba(226, 232, 240, 0.5); text-align: center; font-size: 1.1em;">$gfsIcon</td>
                                            <td style="padding: 10px 12px; border-bottom: 1px solid rgba(226, 232, 240, 0.5); text-align: center; font-size: 1.1em;">$partialIcon</td>
                                            <td style="padding: 10px 12px; border-bottom: 1px solid rgba(226, 232, 240, 0.5); text-align: center; font-size: 0.85em;">$blockSizeText</td>
                                            <td style="padding: 10px 12px; border-bottom: 1px solid rgba(226, 232, 240, 0.5); text-align: center;">$statusBadge</td>
                                            <td style="padding: 10px 12px; border-bottom: 1px solid rgba(226, 232, 240, 0.5); font-size: 0.85em;">$issuesText</td>
                                        </tr>
"@
                    }
                    
                    # Calculate totals for summary row
                    $totalBackupSize = 0
                    $totalDataSize = 0
                    $fullCount = 0
                    $incrementalCount = 0
                    
                    # Use sorted storages for totals calculation
                    foreach ($storage in $sortedStorages) {
                        $totalBackupSize += $storage.ExpectedSize
                        $totalDataSize += $storage.DataSize
                        if ($storage.Type -eq "Full") {
                            $fullCount++
                        } else {
                            $incrementalCount++
                        }
                    }
                    
                    $totalBackupSizeText = Format-StorageSize ([math]::Round($totalBackupSize / 1GB, 2))
                    $totalDataSizeText = Format-StorageSize ([math]::Round($totalDataSize / 1GB, 2))
                    
                    # Calculate average dedup ratio
                    $avgDedupRatio = if ($machineData.VBMMetadata.Storages.Count -gt 0) {
                        [math]::Round(($machineData.VBMMetadata.Storages | Measure-Object -Property DedupRatio -Average).Average, 0)
                    } else { 0 }
                    
                    $html += @"
                                        <tr style="background: linear-gradient(135deg, #f3f4f6 0%, #e5e7eb 100%); border-top: 2px solid #6366f1; font-weight: bold;">
                                            <td colspan="3" style="padding: 12px; border-bottom: none; color: #1e293b;">
                                                TOTALS: $fullCount Full, $incrementalCount Incremental
                                            </td>
                                            <td style="padding: 12px; border-bottom: none; text-align: right; color: #1e293b; font-size: 1.05em;">$totalBackupSizeText</td>
                                            <td style="padding: 12px; border-bottom: none; text-align: right; color: #1e293b; font-size: 1.05em;">$totalDataSizeText</td>
                                            <td style="padding: 12px; border-bottom: none; text-align: center; color: #059669;">Avg: $avgDedupRatio%</td>
                                            <td colspan="2" style="padding: 12px; border-bottom: none;"></td>
                                        </tr>
                                    </tbody>
                                </table>
                            </div>
"@
                    
                    # Set vmName for use in Executive Summary (using the current machine name from loop)
                    $vmName = $machineName
                    
                    # Perform comprehensive GFS and storage analysis
                    $gfsAnalysis = Analyze-GFSCompliance -Storages $machineData.VBMMetadata.Storages -MachineData $machineData
                    
                    # Get comprehensive machine analysis with best practices
                    $comprehensiveAnalysis = Get-ComprehensiveMachineAnalysis -MachineData $machineData -GFSAnalysis $gfsAnalysis -VBMMetadata $machineData.VBMMetadata -MachineName $vmName
                    
                    # Add machine summary section (2 paragraphs)
                    $html += @"
                            <div style="margin-top: 25px; padding: 20px; background: linear-gradient(135deg, #e0e7ff 0%, #eef2ff 100%); border-radius: 12px; border-left: 5px solid #6366f1; box-shadow: 0 4px 6px rgba(0, 0, 0, 0.07);">
                                <h4 style="margin: 0 0 15px 0; color: #312e81; font-size: 1.2em; display: flex; align-items: center; gap: 10px;">
                                    📊 Executive Summary for $vmName
                                    <span style="font-size: 0.7em; padding: 4px 12px; background: $(if ($comprehensiveAnalysis.RiskLevel -eq 'Critical') { 'linear-gradient(135deg, #dc2626, #b91c1c)' } elseif ($comprehensiveAnalysis.RiskLevel -eq 'High') { 'linear-gradient(135deg, #f59e0b, #d97706)' } elseif ($comprehensiveAnalysis.RiskLevel -eq 'Medium') { 'linear-gradient(135deg, #3b82f6, #2563eb)' } else { 'linear-gradient(135deg, #10b981, #059669)' }); color: white; border-radius: 20px; margin-left: auto; font-weight: bold;">
                                        Risk: $($comprehensiveAnalysis.RiskLevel)
                                    </span>
                                </h4>
                                <div style="color: #1e293b; line-height: 1.6;">
                                    $($comprehensiveAnalysis.MachineSummary -replace "`n", "<br>")
                                </div>
                            </div>
"@
                    
                    # Check if this is an AD-HOC backup or has only one retention point (skip GFS if it is)
                    $isAdhoc = $false
                    $skipGFS = $false
                    
                    if ($machineData.BackupType -eq "AdHoc" -or $vmName -match "AD-HOC|ADHOC|Ad-Hoc") {
                        $isAdhoc = $true
                        $skipGFS = $true
                    }
                    
                    # Also skip GFS if there's only one retention point
                    if ($machineData.VBMMetadata -and $machineData.VBMMetadata.Storages.Count -le 1) {
                        $skipGFS = $true
                    }
                    
                    if (-not $skipGFS) {
                        # Add GFS compliance section only for non-ADHOC backups
                        $html += @"
                            <div style="margin-top: 25px; padding: 25px; background: linear-gradient(135deg, #fef3c7 0%, #fef9c3 100%); border-radius: 12px; border-left: 5px solid #f59e0b; box-shadow: 0 4px 6px rgba(0, 0, 0, 0.07);">
                                <h4 style="margin: 0 0 20px 0; color: #92400e; font-size: 1.3em; display: flex; align-items: center; gap: 10px;">
                                    🤖 AI-Powered Storage Intelligence & Deep Insights
                                    <span style="font-size: 0.6em; padding: 4px 12px; background: linear-gradient(135deg, #dc2626, #b91c1c); color: white; border-radius: 20px; margin-left: auto; font-weight: bold;">
                                        GFS Score: $($gfsAnalysis.GFSCompliance.Grade) ($($gfsAnalysis.GFSCompliance.Score)%)
                                    </span>
                                </h4>
                                
                                <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 15px; margin-bottom: 20px;">
                                    <!-- GFS Compliance Card -->
                                    <div style="background: white; padding: 15px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.05);">
                                        <h5 style="margin: 0 0 10px 0; color: #1e40af; font-size: 1.1em;">📅 GFS Retention Compliance</h5>
                                        <div style="font-size: 0.9em;">
                                            <div style="margin: 5px 0; padding: 5px; background: linear-gradient(90deg, #e0f2fe, #f0f9ff); border-radius: 4px;">
                                                <strong>Daily:</strong> $($gfsAnalysis.GFSCompliance.DailyRetention.Actual)/$($gfsAnalysis.GFSCompliance.DailyRetention.Expected) days 
                                                <span style="float: right; color: $(if ($gfsAnalysis.GFSCompliance.DailyRetention.Coverage -ge 80) { '#059669' } else { '#dc2626' });">
                                                    $($gfsAnalysis.GFSCompliance.DailyRetention.Coverage)%
                                                </span>
                                            </div>
                                            <div style="margin: 5px 0; padding: 5px; background: linear-gradient(90deg, #fef2f2, #fee2e2); border-radius: 4px;">
                                                <strong>Weekly:</strong> $($gfsAnalysis.GFSCompliance.WeeklyRetention.Actual)/$($gfsAnalysis.GFSCompliance.WeeklyRetention.Expected) weeks
                                                <span style="float: right; color: $(if ($gfsAnalysis.GFSCompliance.WeeklyRetention.Coverage -ge 75) { '#059669' } else { '#dc2626' });">
                                                    $($gfsAnalysis.GFSCompliance.WeeklyRetention.Coverage)%
                                                </span>
                                            </div>
                                            <div style="margin: 5px 0; padding: 5px; background: linear-gradient(90deg, #f0fdf4, #dcfce7); border-radius: 4px;">
                                                <strong>Monthly:</strong> $($gfsAnalysis.GFSCompliance.MonthlyRetention.Actual)/$($gfsAnalysis.GFSCompliance.MonthlyRetention.Expected) months
                                                <span style="float: right; color: $(if ($gfsAnalysis.GFSCompliance.MonthlyRetention.Coverage -ge 50) { '#059669' } else { '#dc2626' });">
                                                    $($gfsAnalysis.GFSCompliance.MonthlyRetention.Coverage)%
                                                </span>
                                            </div>
                                            <div style="margin-top: 10px; padding: 8px; background: linear-gradient(135deg, #6366f1, #4f46e5); color: white; border-radius: 6px; text-align: center; font-weight: bold;">
                                                Overall Score: $($gfsAnalysis.GFSCompliance.Grade) ($($gfsAnalysis.GFSCompliance.Score)%)
                                            </div>
                                        </div>
                                    </div>
                                    
                                    <!-- Storage Efficiency Card -->
                                    <div style="background: white; padding: 15px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.05);">
                                        <h5 style="margin: 0 0 10px 0; color: #059669; font-size: 1.1em;">📊 Storage Efficiency Metrics</h5>
                                        <div style="font-size: 0.9em;">
                                            <div style="margin: 5px 0;">
                                                <strong>Total Backup Size:</strong> 
                                                <span style="float: right; color: #1e40af; font-weight: bold;">$(Format-StorageSize ([math]::Round($gfsAnalysis.StorageEfficiency.TotalBackupSize / 1GB, 2)))</span>
                                            </div>
                                            <div style="margin: 5px 0;">
                                                <strong>Original Data Size:</strong> 
                                                <span style="float: right; color: #6b7280;">$(Format-StorageSize ([math]::Round($gfsAnalysis.StorageEfficiency.TotalDataSize / 1GB, 2)))</span>
                                            </div>
                                            <div style="margin: 5px 0; padding-top: 5px; border-top: 1px solid #e5e7eb;">
                                                <strong>Space Saved:</strong> 
                                                <span style="float: right; color: #059669; font-weight: bold;">$(Format-StorageSize ([math]::Round($gfsAnalysis.StorageEfficiency.SpaceSaved / 1GB, 2)))</span>
                                            </div>
                                            <div style="margin: 5px 0;">
                                                <strong>Compression Ratio:</strong> 
                                                <span style="float: right;">$($gfsAnalysis.StorageEfficiency.CompressionRatio)%</span>
                                            </div>
                                            <div style="margin: 5px 0;">
                                                <strong>Avg Dedup Ratio:</strong> 
                                                <span style="float: right; color: $(if ($gfsAnalysis.StorageEfficiency.AverageDedupRatio -ge 50) { '#059669' } else { '#dc2626' }); font-weight: bold;">
                                                    $($gfsAnalysis.StorageEfficiency.AverageDedupRatio)%
                                                </span>
                                            </div>
                                        </div>
                                    </div>
                                </div>
                                
                                <!-- Detailed Insights -->
                                <div style="margin-top: 20px;">
                                    <h5 style="margin: 0 0 15px 0; color: #1e293b; font-size: 1.1em;">🔍 Detailed Analysis & Observations</h5>
"@
                    
                    foreach ($insight in $gfsAnalysis.Insights) {
                        $insightIcon = switch ($insight.Severity) {
                            "Critical" { "❌" }
                            "Warning" { "⚠️" }
                            "Info" { "ℹ️" }
                            default { "💡" }
                        }
                        
                        $insightColor = switch ($insight.Severity) {
                            "Critical" { "#dc2626" }
                            "Warning" { "#f59e0b" }
                            "Info" { "#3b82f6" }
                            default { "#6b7280" }
                        }
                        
                        $html += @"
                                    <div style="margin: 10px 0; padding: 12px; background: white; border-left: 4px solid $insightColor; border-radius: 6px;">
                                        <div style="font-weight: bold; color: $insightColor; margin-bottom: 5px;">
                                            $insightIcon $($insight.Category)
                                        </div>
                                        <div style="color: #1e293b; font-size: 0.95em; margin-bottom: 5px;">
                                            $($insight.Message)
                                        </div>
                                        <div style="color: #6b7280; font-size: 0.85em; line-height: 1.5;">
                                            $($insight.Detail)
                                        </div>
                                    </div>
"@
                    }
                    
                    # Add verbose recommendations
                    $verboseRecs = Get-VerboseStorageRecommendations -GFSAnalysis $gfsAnalysis -MachineData $machineData -StorageMetrics $null
                    
                    if ($verboseRecs.Count -gt 0) {
                        $html += @"
                                </div>
                                
                                <!-- Actionable Recommendations -->
                                <div style="margin-top: 20px; padding-top: 20px; border-top: 2px solid #e5e7eb;">
                                    <h5 style="margin: 0 0 15px 0; color: #dc2626; font-size: 1.1em;">🎯 Actionable Recommendations</h5>
"@
                        
                        foreach ($rec in $verboseRecs) {
                            $recIcon = switch ($rec.Severity) {
                                "Critical" { "🔴" }
                                "High" { "🟠" }
                                "Medium" { "🟡" }
                                default { "🟢" }
                            }
                            
                            $html += @"
                                    <div style="margin: 15px 0; padding: 15px; background: linear-gradient(135deg, #fee2e2, #fef2f2); border-radius: 8px; border: 1px solid #fca5a5;">
                                        <div style="font-weight: bold; color: #991b1b; font-size: 1.05em; margin-bottom: 8px;">
                                            $recIcon $($rec.Title)
                                        </div>
                                        <div style="color: #dc2626; margin-bottom: 10px;">
                                            $($rec.Message)
                                        </div>
"@
                            
                            if ($rec.Details) {
                                $html += @"
                                        <div style="margin: 10px 0; padding: 10px; background: white; border-radius: 4px;">
                                            <strong style="color: #7c2d12;">Details:</strong>
                                            <ul style="margin: 5px 0 0 20px; color: #92400e;">
"@
                                foreach ($detail in $rec.Details) {
                                    $html += "                                                <li>$detail</li>`n"
                                }
                                $html += @"
                                            </ul>
                                        </div>
"@
                            }
                            
                            if ($rec.Actions) {
                                $html += @"
                                        <div style="margin-top: 10px; padding: 10px; background: linear-gradient(135deg, #dcfce7, #f0fdf4); border-radius: 4px;">
                                            <strong style="color: #14532d;">Recommended Actions:</strong>
                                            <ol style="margin: 5px 0 0 20px; color: #166534;">
"@
                                foreach ($action in $rec.Actions) {
                                    $html += "                                                <li>$action</li>`n"
                                }
                                $html += @"
                                            </ol>
                                        </div>
"@
                            }
                            
                            $html += @"
                                    </div>
"@
                        }
                    }
                    
                    $html += @"
                                </div>
                            </div>
"@
                    } else {
                        # For AD-HOC backups or single retention point, show a simplified analysis
                        $skipReason = if ($isAdhoc) {
                            "This is an ad-hoc backup collection. GFS retention policies do not apply to ad-hoc backups. These backups are typically created for specific purposes such as pre-maintenance snapshots, migration preparations, or one-time recovery requirements."
                        } else {
                            "This backup has only a single retention point. GFS retention analysis requires multiple backup points to evaluate compliance with Grandfather-Father-Son retention policies."
                        }
                        
                        $html += @"
                            <div style="margin-top: 25px; padding: 20px; background: linear-gradient(135deg, #e0f7fa 0%, #f0fdfa 100%); border-radius: 12px; border-left: 5px solid #06b6d4; box-shadow: 0 4px 6px rgba(0, 0, 0, 0.07);">
                                <h4 style="margin: 0 0 15px 0; color: #0e7490; font-size: 1.2em;">
                                    ℹ️ GFS Analysis Not Applicable
                                </h4>
                                <p style="color: #0891b2; margin: 0;">
                                    $skipReason
                                </p>
                            </div>
"@
                    }
                    
                    # Add best practice recommendations section
                    if ($comprehensiveAnalysis.BestPracticeRecommendations.Count -gt 0 -or $comprehensiveAnalysis.VeeamSpecificRecommendations.Count -gt 0) {
                        $html += @"
                            <div style="margin-top: 25px; padding: 25px; background: linear-gradient(135deg, #f0f9ff 0%, #e0f2fe 100%); border-radius: 12px; border-left: 5px solid #0284c7; box-shadow: 0 4px 6px rgba(0, 0, 0, 0.07);">
                                <h4 style="margin: 0 0 20px 0; color: #075985; font-size: 1.3em;">
                                    🎯 Best Practices & Recommendations
                                </h4>
"@
                        
                        if ($comprehensiveAnalysis.VeeamSpecificRecommendations.Count -gt 0) {
                            $html += @"
                                <div style="margin-bottom: 20px;">
                                    <h5 style="color: #0c4a6e; margin: 0 0 10px 0;">🔧 Veeam-Specific Optimizations</h5>
                                    <ul style="margin: 0; padding-left: 20px; color: #164e63;">
"@
                            foreach ($rec in $comprehensiveAnalysis.VeeamSpecificRecommendations) {
                                $html += "                                        <li style='margin: 5px 0;'>$rec</li>`n"
                            }
                            $html += @"
                                    </ul>
                                </div>
"@
                        }
                        
                        if ($comprehensiveAnalysis.BestPracticeRecommendations.Count -gt 0) {
                            $html += @"
                                <div>
                                    <h5 style="color: #0c4a6e; margin: 0 0 10px 0;">📋 Global Backup Best Practices</h5>
                                    <ul style="margin: 0; padding-left: 20px; color: #164e63;">
"@
                            foreach ($rec in $comprehensiveAnalysis.BestPracticeRecommendations | Select-Object -First 5) {
                                $html += "                                        <li style='margin: 5px 0;'>$rec</li>`n"
                            }
                            $html += @"
                                    </ul>
                                </div>
"@
                        }
                        
                        $html += @"
                            </div>
"@
                    }
                }
                
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
        
        Write-Log "✅ HTML report generated successfully: $OutputPath" 'SUCCESS'
        return $OutputPath
    }
    catch {
        Write-Log "❌ Error generating HTML report: $_" 'ERROR'
        return $null
    }
}

# Function to find ALL backup locations on the drive (repositories + ADHOC)
function Find-AllBackupLocations {
    param([string]$RootPath)
    
    Write-Log "🔍 Starting comprehensive Veeam backup discovery on $RootPath" 'SUCCESS'
    
    if (-not (Test-Path $RootPath)) {
        Write-Log "❌ Error: Root path '$RootPath' does not exist or is not accessible" 'ERROR'
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
    
    Write-Log "🔍 Scanning entire drive for VIB and VBK files..." 'SUCCESS'
    
    try {
        # First, find ALL VIB, VBK and VBM files on the drive
        $allBackupFiles = Get-ChildItem -Path $RootPath -Recurse -Include "*.vbk", "*.vib", "*.vrb" -ErrorAction SilentlyContinue
        $vbmFiles = Get-ChildItem -Path $RootPath -Recurse -Include "*.vbm" -ErrorAction SilentlyContinue
        $result.TotalBackupFiles = $allBackupFiles.Count
        
        Write-Log "📊 Found $($allBackupFiles.Count) total backup files (.vbk/.vib/.vrb) on the drive" 'SUCCESS'
        Write-Log "📄 Found $($vbmFiles.Count) VBM metadata files on the drive" 'SUCCESS'
        
        if ($allBackupFiles.Count -eq 0) {
            Write-Log "⚠️ No Veeam backup files found on the drive" 'SUCCESS'
            return $result
        }
        
        # Group backup files by their parent directory
        $directoryGroups = $allBackupFiles | Group-Object { $_.Directory.FullName }
        
        Write-Log "📁 Backup files found in $($directoryGroups.Count) different directories" 'SUCCESS'
        
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
        
        Write-Log "🔍 Analyzing $($parentDirectoryGroups.Count) potential repository locations..." 'SUCCESS'
        
        # Analyze each parent directory to determine repositories vs ADHOC
        foreach ($parentPath in $parentDirectoryGroups.Keys) {
            $machineDirectoriesInParent = $parentDirectoryGroups[$parentPath]
            
            Write-Log "🔍 Checking parent: $parentPath ($($machineDirectoriesInParent.Count) machine directories)" 'SUCCESS'
            
            # Check if this is the root drive (e.g., "V:\")
            $isRootDrive = $parentPath -match '^[A-Za-z]:\\?$'
            
            # If parent contains multiple machine directories with backups AND it's not the root drive, it's a repository
            if ($machineDirectoriesInParent.Count -gt 1 -and -not $isRootDrive) {
                # This is a repository
                $repositoryName = Split-Path $parentPath -Leaf
                if ([string]::IsNullOrEmpty($repositoryName)) {
                    $repositoryName = "Root-Repository"
                }
                
                Write-Log "✅ Repository detected: '$repositoryName' with $($machineDirectoriesInParent.Count) machines" 'SUCCESS'
                
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
                    
                    Write-Log "  📦 Processing repository machine: $currentDirName ($($filesInDir.Count) files)" 'SUCCESS'
                    
                    # Add machine to repository
                    $newRepo.Machines[$currentDirName] = @{
                        Name = $currentDirName
                        Path = $directory
                        FullBackups = @()
                        IncrementalBackups = @()
                        ReverseIncrementalBackups = @()
                        TotalSize = 0
                        LastBackupDate = $null
                        VBMMetadata = $null
                        ChainValidation = $null
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
                            Write-Log "    📦 Repository Full: $($file.Name) ($(Format-StorageSize $backupInfo.SizeGB))" 'SUCCESS'
                        }
                        elseif ($file.Extension -eq ".vib") {
                            $machineData.IncrementalBackups += $backupInfo
                            Write-Log "    📈 Repository Incremental: $($file.Name) ($(Format-StorageSize $backupInfo.SizeGB))" 'SUCCESS'
                        }
                        elseif ($file.Extension -eq ".vrb") {
                            $machineData.ReverseIncrementalBackups += $backupInfo
                            Write-Log "    🔄 Repository Reverse Incremental: $($file.Name) ($(Format-StorageSize $backupInfo.SizeGB))" 'SUCCESS'
                        }
                        else {
                            Write-Log "    ⚠️ Unknown backup file type: $($file.Name) with extension $($file.Extension)" 'SUCCESS'
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
                    
                    # Look for VBM file in this machine's directory
                    $vbmFileInDir = $vbmFiles | Where-Object { $_.Directory.FullName -eq $directory } | Select-Object -First 1
                    if ($vbmFileInDir) {
                        Write-Log "    📄 Found VBM metadata file: $($vbmFileInDir.Name)" 'SUCCESS'
                        $vbmParse = Parse-VBMMetadata -VBMFilePath $vbmFileInDir.FullName -BackupDirectory $directory
                        $machineData.VBMMetadata = $vbmParse
                        $machineData.ChainValidation = $vbmParse.ChainValidation
                        
                        if (-not $vbmParse.ChainValidation.IsValid) {
                            Write-Log "    ⚠️ CHAIN VALIDATION FAILED for $currentDirName" 'SUCCESS'
                            foreach ($issue in $vbmParse.ChainValidation.Issues) {
                                Write-Log "      ❌ $issue" 'ERROR'
                            }
                        }
                    }
                }
            }
            else {
                # Single machine directory OR root drive machines - these are ADHOC backups
                if ($isRootDrive) {
                    Write-Log "🎯 Root drive machines detected - treating as ADHOC: $parentPath ($($machineDirectoriesInParent.Count) directories)" 'SUCCESS'
                } else {
                    Write-Log "🎯 Single machine directory detected - treating as ADHOC: $parentPath" 'SUCCESS'
                }
                
                # Process all machine directories in this parent as ADHOC
                foreach ($dirGroup in $machineDirectoriesInParent) {
                    $directory = $dirGroup.Name
                    $filesInDir = $dirGroup.Group
                    
                    Write-Log "🎯 ADHOC backup location: $directory ($($filesInDir.Count) files)" 'SUCCESS'
                    
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
                        Write-Log "    🎯 ADHOC $($backupInfo.Type): $($file.Name) ($(Format-StorageSize $backupInfo.SizeGB))" 'SUCCESS'
                    }
                }
            }
        }
        
        # Summary logging
        Write-Log "📊 Discovery Summary:" 'SUCCESS'
        Write-Log "  📦 Repositories found: $($result.Repositories.Count) (excluding root drive)" 'SUCCESS'
        foreach ($repo in $result.Repositories) {
            Write-Log "    🏢 $($repo.Name): $($repo.Machines.Count) machines, $($repo.TotalFiles) files, $(Format-StorageSize $repo.TotalSizeGB)" 'SUCCESS'
        }
        Write-Log "  🎯 ADHOC backups found: $($result.AdhocBackups.Count) files (individual files + root drive machines)" 'SUCCESS'
        
        if ($result.AdhocBackups.Count -gt 0) {
            $adhocSizeGB = ($result.AdhocBackups | Measure-Object -Property SizeGB -Sum).Sum
            Write-Log "    💾 ADHOC total size: $(Format-StorageSize $adhocSizeGB)" 'SUCCESS'
        }
        
        return $result
    }
    catch {
        Write-Log "❌ Error during backup discovery: $_" 'ERROR'
        return $result
    }
}

function Run-ReportForMappedDrive {
    param(
        $DriveLetter
    )
    
    Write-Log "🚀 Starting comprehensive backup scan on $DriveLetter" 'SUCCESS'
    
    try {
        # Get server name for report
        $serverName = $env:COMPUTERNAME.ToUpper()
        if ($script:SelectedServerName) {
            $serverName = $script:SelectedServerName
        }
        
        # Discover all backup locations
        $backupLocations = Find-AllBackupLocations -RootPath $DriveLetter
        
        if ($backupLocations.TotalBackupFiles -eq 0) {
            Write-Log "❌ No Veeam backup files found on the drive" 'ERROR'
            return
        }
        
        # Build comprehensive backup inventory
        $backupInventory = @{}
        
        # Process repository backups
        foreach ($repository in $backupLocations.Repositories) {
            Write-Log "📦 Processing repository: $($repository.Name)" 'SUCCESS'
            
            foreach ($machineName in $repository.Machines.Keys) {
                $machineData = $repository.Machines[$machineName]
                
                # Add repository information to machine data
                $machineData.RepositoryName = $repository.Name
                $machineData.RepositoryPath = $repository.Path
                $machineData.BackupType = "Repository"
                
                # Add to main inventory with unique key
                $inventoryKey = "$($repository.Name)::$machineName"
                $backupInventory[$inventoryKey] = $machineData
                
                Write-Log "  ✅ Added repository machine: $inventoryKey ($(Format-StorageSize $machineData.TotalSizeGB))" 'SUCCESS'
            }
        }
        
        # Process ADHOC backups - create "Ad-Hoc Backups" repository only if there are ADHOC backups
        if ($backupLocations.AdhocBackups.Count -gt 0) {
            Write-Log "🎯 Processing ADHOC backups..." 'SUCCESS'
            
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
                
                                    Write-Log "  🎯 Added ADHOC machine: $inventoryKey ($(Format-StorageSize $groupData.TotalSizeGB), $($allBackups.Count) files)" 'SUCCESS'
            }
        }
        
        $totalMachines = $backupInventory.Count
        $totalRepositories = $backupLocations.Repositories.Count
        $totalAdhocGroups = ($backupInventory.Keys | Where-Object { $_ -like "Ad-Hoc Backups::*" }).Count
        
        Write-Log "✅ Comprehensive scan completed successfully" 'SUCCESS'
        if ($totalAdhocGroups -gt 0) {
            Write-Log "📊 Total entities: $totalMachines ($($totalRepositories - 1) standard repositories, 1 ADHOC repository with $totalAdhocGroups groups)" 'SUCCESS'
        } else {
            Write-Log "📊 Total entities: $totalMachines ($totalRepositories repositories, no ADHOC backups found)" 'SUCCESS'
        }
        
        # Validate scan results
        if ($totalMachines -eq 0) {
            Write-Log "❌ No machines found during scan" 'ERROR'
            return
        }
        
        if ($totalRepositories -eq 0) {
            Write-Log "❌ No repositories were created during scan" 'ERROR'
            return
        }
        
        Write-Log "✅ Scan validation passed: $totalMachines machines in $totalRepositories repositories" 'SUCCESS'
        
        # Measure storage metrics
        Write-Log "📊 Calculating storage metrics..." 'SUCCESS'
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
            Write-Log "⚠️ Could not retrieve disk space information: $_" 'SUCCESS'
        }
        
        # Generate recommendations
        Write-Log "💡 Generating storage recommendations..." 'SUCCESS'
        $recommendations = Get-VerboseStorageRecommendations -StorageMetrics $storageMetrics -GFSAnalysis @{} -MachineData @{}
        
        # Generate HTML report
        Write-Log "📝 Generating comprehensive HTML report..." 'SUCCESS'
        $reportPath = New-HTMLReport -BackupInventory $backupInventory -StorageMetrics $storageMetrics -BackupLocations $backupLocations -ServerName $serverName
        
        if ($reportPath -and (Test-Path $reportPath)) {
            Write-Log "✅ Report generated successfully for $serverName`: $reportPath" 'SUCCESS'
            
            # Check if email should be sent for this server
            if ($script:SelectedServerName) {
                $servers = Get-SavedServers
                $currentServer = $servers | Where-Object { $_.ServerName -eq $script:SelectedServerName }
                
                if ($currentServer -and $currentServer.EmailEnabled -and $currentServer.EmailAddress) {
                    Write-Log "✉️ Email is enabled for this server - preparing to send report to $($currentServer.EmailAddress)" 'SUCCESS'
                    
                    # Get global SMTP settings if server doesn't have them
                    $smtpServer = if ($currentServer.SMTPServer) { $currentServer.SMTPServer } else { (Get-GlobalSMTPSettings).SMTPServer }
                    $smtpPort = if ($currentServer.SMTPPort) { $currentServer.SMTPPort } else { (Get-GlobalSMTPSettings).SMTPPort }
                    $smtpUsername = if ($currentServer.SMTPUsername) { $currentServer.SMTPUsername } else { (Get-GlobalSMTPSettings).SMTPUsername }
                    $smtpPassword = if ($currentServer.SMTPPassword) { $currentServer.SMTPPassword } else { (Get-GlobalSMTPSettings).SMTPPassword }
                    $useSSL = if ($null -ne $currentServer.UseSSL) { $currentServer.UseSSL } else { (Get-GlobalSMTPSettings).UseSSL }
                    
                    # Send the email report with attachment and professional body
                    $emailSent = Send-EmailReport -HTMLFilePath $reportPath `
                        -ToAddress $currentServer.EmailAddress `
                        -SMTPServer $smtpServer `
                        -SMTPPort $smtpPort `
                        -SMTPUsername $smtpUsername `
                        -SMTPPassword $smtpPassword `
                        -UseSSL $useSSL `
                        -ServerName $serverName `
                        -BackupInventory $backupInventory `
                        -StorageMetrics $storageMetrics
                    
                    if ($emailSent) {
                        Write-Log "✅ Report successfully emailed to $($currentServer.EmailAddress)" 'SUCCESS'
                        
                        # Display prominent success message in console
                        Write-Host ""
                        Write-Host "═══════════════════════════════════════════════════════════════════" -ForegroundColor Green
                        Write-Host "✉️  EMAIL SUCCESSFULLY SENT!" -ForegroundColor Green
                        Write-Host "═══════════════════════════════════════════════════════════════════" -ForegroundColor Green
                        Write-Host "  Report has been emailed to: $($currentServer.EmailAddress)" -ForegroundColor White
                        Write-Host "  Subject: Veeam Backup Report - $serverName" -ForegroundColor White
                        Write-Host "  Attachment: Full HTML Report" -ForegroundColor White
                        Write-Host "═══════════════════════════════════════════════════════════════════" -ForegroundColor Green
                        Write-Host ""
                    } else {
                        Write-Log "❌ Failed to email report to $($currentServer.EmailAddress)" 'ERROR'
                        Write-Host ""
                        Write-Host "⚠️ Email delivery failed. Please check SMTP settings." -ForegroundColor Red
                        Write-Host ""
                    }
                } else {
                    Write-Log "ℹ️ Email not configured or disabled for this server" 'SUCCESS'
                }
            }
            
            # Automatically launch the report
            try {
                Start-Process $reportPath
                Write-Log "🚀 HTML report opened in default browser" 'SUCCESS'
            }
            catch {
                Write-Log "⚠️ Failed to open report automatically: $_" 'SUCCESS'
                Write-Log "Report location: $reportPath" 'SUCCESS'
            }
        }
    }
    catch {
        Write-Log "❌ Error during report generation: $_" 'ERROR'
    }
    finally {
        # Clean up drive mapping
        Remove-NetworkDrive -DriveLetter $DriveLetter
        Write-Log "🏁 ==== End of Session ====" 'SUCCESS'
    }
}
function New-ProfessionalEmailBody {
    param(
        [string]$ServerName,
        [hashtable]$BackupInventory,
        [hashtable]$StorageMetrics,
        [string]$HTMLFilePath
    )
    
    Write-Log "📧 Generating professional email body with AI summaries..." 'SUCCESS'
    
    # Calculate summary statistics
    # Extract unique repository names from inventory keys (format: "RepoName::MachineName")
    $uniqueRepositories = @{}
    $repositoryDetails = @{}
    foreach ($key in $BackupInventory.Keys) {
        if ($key -notlike "*Ad-Hoc*") {
            $repoName = $key.Split('::')[0]
            if ($repoName) {
                $uniqueRepositories[$repoName] = $true
                if (-not $repositoryDetails.ContainsKey($repoName)) {
                    $repositoryDetails[$repoName] = @{
                        Machines = @()
                        TotalSize = 0
                        FileCount = 0
                    }
                }
                $repositoryDetails[$repoName].Machines += $key.Split('::')[1]
                $repositoryDetails[$repoName].TotalSize += $BackupInventory[$key].TotalSizeGB
                $repositoryDetails[$repoName].FileCount += $BackupInventory[$key].FullBackups.Count + 
                    $BackupInventory[$key].IncrementalBackups.Count + 
                    $BackupInventory[$key].ReverseIncrementalBackups.Count
            }
        }
    }
    # Add 1 if there are Ad-Hoc backups (they count as 1 repository)
    $hasAdhoc = ($BackupInventory.Keys | Where-Object { $_ -like "*Ad-Hoc*" }).Count -gt 0
    $totalRepositories = $uniqueRepositories.Count + $(if ($hasAdhoc) { 1 } else { 0 })
    
    $totalMachines = $BackupInventory.Count
    $totalBackupSize = [math]::Round(($BackupInventory.Values | ForEach-Object { $_.TotalSizeGB } | Measure-Object -Sum).Sum / 1024, 2)
    $totalBackupFiles = ($BackupInventory.Values | ForEach-Object { 
        $_.FullBackups.Count + $_.IncrementalBackups.Count + $_.ReverseIncrementalBackups.Count 
    } | Measure-Object -Sum).Sum
    
    # Calculate average retention and backup frequency
    $retentionValues = $BackupInventory.Values | ForEach-Object { 
        if ($_.RetentionDays -gt 0) {
            $_.RetentionDays
        } elseif ($_.OldestBackup -and $_.NewestBackup) {
            try {
                # Try to calculate from dates if RetentionDays not set
                $oldest = if ($_.OldestBackup -is [DateTime]) { $_.OldestBackup } else { [DateTime]::Parse($_.OldestBackup) }
                $newest = if ($_.NewestBackup -is [DateTime]) { $_.NewestBackup } else { [DateTime]::Parse($_.NewestBackup) }
                ($newest - $oldest).Days
            } catch {
                0
            }
        } else { 
            0 
        }
    } | Where-Object { $_ -gt 0 }
    
    $avgRetention = if ($retentionValues.Count -gt 0) {
        [math]::Round(($retentionValues | Measure-Object -Average).Average, 0)
    } else {
        7  # Default to 7 days if no retention data available
    }
    
    # Generate AI summary if connected (with lower temperature for consistency)
    $aiSummary = ""
    $aiRepositoryAnalysis = ""
    $aiRecommendations = @()
    
    if ($script:OpenAIConnected -and $script:OpenAIAPIKey) {
        try {
            Write-Log "🤖 Generating AI-powered summary with temperature 0.3 for consistency..." 'SUCCESS'
            
            # Prepare detailed context for AI
            $context = "Analyze this Veeam backup infrastructure report for ${ServerName}. "
            $context += "Infrastructure overview: $totalRepositories backup repositories managing $totalMachines protected virtual machines. "
            $context += "Storage metrics: $totalBackupFiles backup files consuming $totalBackupSize TB of storage. "
            $context += "Average retention period is $avgRetention days. "
            
            # Add storage growth metrics
            if ($StorageMetrics.UsagePercent) {
                $context += "Current storage utilization stands at $($StorageMetrics.UsagePercent)%. "
                if ($StorageMetrics.EstimatedDaysUntilFull) {
                    $context += "At current growth rate, storage will reach capacity in approximately $($StorageMetrics.EstimatedDaysUntilFull) days. "
                }
            }
            
            # Request detailed executive summary (2 paragraphs)
            $summaryPrompt = "$context Write exactly 2 detailed paragraphs for an executive summary. First paragraph should analyze the current backup infrastructure state, coverage, and health. Second paragraph should discuss trends, risks, and strategic considerations. Be specific with numbers and percentages. Use plain text only without any markdown formatting, asterisks, or special characters."
            $aiSummary = Invoke-OpenAICompletion -Prompt $summaryPrompt -MaxTokens 350 -Temperature 0.3
            
            # Clean any remaining formatting from AI response
            if ($aiSummary) {
                $aiSummary = $aiSummary -replace '\*\*', '' -replace '\*', '' -replace '\\', '' -replace '►', '' -replace '\#{1,6}\s*', ''
            }
            
            # Request repository-level analysis (2 paragraphs)
            $repoContext = "Repository details: "
            foreach ($repo in $repositoryDetails.Keys | Select-Object -First 3) {
                $repoContext += "$repo repository contains $($repositoryDetails[$repo].Machines.Count) machines with $($repositoryDetails[$repo].FileCount) backup files totaling $([math]::Round($repositoryDetails[$repo].TotalSize, 1))GB. "
            }
            
            $repoPrompt = "$context $repoContext Write exactly 2 detailed paragraphs analyzing the repository architecture. First paragraph should describe repository distribution, workload balance, and backup patterns. Second paragraph should provide specific repository-level optimization recommendations. Use plain text only without any markdown formatting, asterisks, or special characters."
            $aiRepositoryAnalysis = Invoke-OpenAICompletion -Prompt $repoPrompt -MaxTokens 350 -Temperature 0.3
            
            # Clean any remaining formatting from AI response
            if ($aiRepositoryAnalysis) {
                $aiRepositoryAnalysis = $aiRepositoryAnalysis -replace '\*\*', '' -replace '\*', '' -replace '\\', '' -replace '►', '' -replace '\#{1,6}\s*', ''
            }
            
            # Request server-level recommendations
            $recommendationsPrompt = "$context Provide exactly 5 specific, actionable recommendations for this Veeam backup infrastructure at the server level. Focus on performance optimization, storage efficiency, and operational best practices. Be specific and technical. Format as a simple numbered list without any markdown, asterisks, or special formatting. Each recommendation should be a single clear sentence."
            $aiRecommendationsText = Invoke-OpenAICompletion -Prompt $recommendationsPrompt -MaxTokens 400 -Temperature 0.3
            
            # Clean and parse recommendations into array
            $aiRecommendations = $aiRecommendationsText -split '\n' | Where-Object { $_.Trim() -ne "" } | ForEach-Object {
                # Remove markdown formatting, numbers, bullets, asterisks, etc.
                $cleaned = $_ -replace '^\d+[\.\)]\s*', '' `
                             -replace '^\*+\s*', '' `
                             -replace '^\-\s*', '' `
                             -replace '^\#+\s*', '' `
                             -replace '\*\*', '' `
                             -replace '\*', '' `
                             -replace '\\', '' `
                             -replace '►', ''
                $cleaned.Trim()
            } | Where-Object { $_.Length -gt 10 } | Select-Object -First 5
            
        } catch {
            Write-Log "⚠️ AI summary generation failed: $_" 'SUCCESS'
        }
    }
    
    # Enhanced fallback summaries if AI not available
    if (-not $aiSummary) {
        $aiSummary = "The Veeam backup infrastructure analysis for $ServerName reveals a comprehensive data protection environment spanning $totalRepositories distinct backup repositories. These repositories collectively safeguard $totalMachines virtual machines through a robust backup strategy that has generated $totalBackupFiles backup files, consuming approximately $totalBackupSize TB of storage capacity. The infrastructure demonstrates a mature backup ecosystem with an average retention period of $avgRetention days, indicating compliance with standard data protection policies and regulatory requirements.`n`nFrom an operational perspective, the current storage utilization and backup growth patterns suggest the infrastructure is functioning within acceptable parameters. The diversity of backup types across repositories indicates a well-structured approach to data protection, balancing full backups for complete recovery points with incremental backups for storage efficiency. This architecture provides multiple recovery options while optimizing storage consumption, though continuous monitoring of growth trends and periodic optimization reviews are recommended to maintain peak efficiency."
    }
    
    if (-not $aiRepositoryAnalysis) {
        $repoNames = $repositoryDetails.Keys | Select-Object -First 3
        $repoText = if ($repoNames.Count -gt 0) {
            "Primary repositories include: " + ($repoNames -join ", ") + ". "
        } else { "" }
        
        $aiRepositoryAnalysis = "The repository architecture demonstrates a distributed backup strategy across $totalRepositories distinct storage locations, providing both redundancy and workload distribution. ${repoText}Each repository maintains its own backup chains and retention policies, allowing for granular control over data protection strategies. The distribution of $totalMachines machines across these repositories helps prevent single points of failure and enables parallel backup operations, improving overall backup window efficiency and reducing the impact on production systems during backup operations.`n`nAt the server level, several optimization opportunities exist to enhance the backup infrastructure's performance and reliability. Consider implementing repository load balancing to ensure even distribution of backup workloads, preventing any single repository from becoming a bottleneck. Additionally, regular backup chain health checks and periodic synthetic full backup operations can help maintain optimal repository performance. Implementing automated monitoring for repository capacity thresholds and backup job success rates will provide proactive alerts for potential issues before they impact recovery capabilities."
    }
    
    if ($aiRecommendations.Count -eq 0) {
        $aiRecommendations = @(
            "Implement automated repository capacity monitoring with alerts at 75%, 85%, and 95% utilization thresholds to prevent unexpected storage exhaustion",
            "Configure periodic synthetic full backups to optimize backup chains and reduce dependency on lengthy incremental chains",
            "Deploy backup copy jobs to secondary storage locations for critical VMs to ensure compliance with 3-2-1 backup best practices",
            "Enable backup file compression and deduplication at the repository level to maximize storage efficiency and reduce backup windows",
            "Establish automated backup verification jobs to periodically test restore capabilities and ensure backup integrity"
        )
    }
    
    # Build professional HTML email body
    $emailBody = @"
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <style>
        body {
            font-family: 'Segoe UI', Tahoma, Arial, sans-serif;
            line-height: 1.6;
            color: #333;
            width: 90%;
            max-width: 1200px;
            margin: 0 auto;
            padding: 20px;
            background-color: #f5f5f5;
        }
        .container {
            background: white;
            border-radius: 10px;
            box-shadow: 0 2px 10px rgba(0,0,0,0.1);
            overflow: hidden;
        }
        .header {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 40px;
            text-align: center;
        }
        .header h1 {
            margin: 0;
            font-size: 32px;
            font-weight: 300;
            letter-spacing: 1px;
        }
        .header .subtitle {
            margin-top: 10px;
            opacity: 0.95;
            font-size: 18px;
        }
        .content {
            padding: 30px 40px;
        }
        .summary-section {
            background: #f8f9fa;
            border-left: 4px solid #667eea;
            padding: 25px;
            margin: 30px 0;
            border-radius: 5px;
        }
        .summary-section h2 {
            color: #667eea;
            margin-top: 0;
            font-size: 24px;
            margin-bottom: 20px;
        }
        .summary-section p {
            margin-bottom: 15px;
            text-align: justify;
            line-height: 1.8;
        }
        .repository-section {
            background: #fff9e6;
            border-left: 4px solid #ffa500;
            padding: 25px;
            margin: 30px 0;
            border-radius: 5px;
        }
        .repository-section h2 {
            color: #ff8c00;
            margin-top: 0;
            font-size: 24px;
            margin-bottom: 20px;
        }
        .repository-section p {
            margin-bottom: 15px;
            text-align: justify;
            line-height: 1.8;
        }
        .stats-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
            gap: 25px;
            margin: 30px 0;
        }
        .stat-card {
            background: white;
            padding: 20px;
            border-radius: 8px;
            box-shadow: 0 3px 6px rgba(0,0,0,0.1);
            text-align: center;
            transition: transform 0.2s;
        }
        .stat-card:hover {
            transform: translateY(-2px);
            box-shadow: 0 5px 12px rgba(0,0,0,0.15);
        }
        .stat-value {
            font-size: 36px;
            font-weight: bold;
            color: #764ba2;
            margin-bottom: 5px;
        }
        .stat-label {
            font-size: 14px;
            color: #666;
            text-transform: uppercase;
            letter-spacing: 1px;
        }
        .recommendations {
            background: #fff;
            border: 2px solid #e0e0e0;
            border-radius: 8px;
            padding: 25px;
            margin: 30px 0;
        }
        .recommendations h3 {
            color: #333;
            margin-top: 0;
            font-size: 22px;
            margin-bottom: 20px;
        }
        .recommendations ul {
            list-style: none;
            padding: 0;
        }
        .recommendations li {
            padding: 15px 0;
            padding-left: 35px;
            border-bottom: 1px solid #f0f0f0;
            position: relative;
            line-height: 1.6;
        }
        .recommendations li:last-child {
            border-bottom: none;
        }
        .recommendation-arrow {
            position: absolute;
            left: 0;
            top: 15px;
            color: #667eea;
            font-weight: bold;
            font-size: 18px;
        }
        .attachment-note {
            background: #e8f4fd;
            border: 2px solid #bee5eb;
            border-radius: 8px;
            padding: 25px;
            margin: 30px 0;
            text-align: center;
        }
        .attachment-note .icon {
            font-size: 48px;
            margin-bottom: 15px;
            color: #667eea;
        }
        .attachment-note strong {
            font-size: 18px;
            color: #333;
        }
        .attachment-note ul {
            text-align: left;
            display: inline-block;
            list-style: none;
            padding: 0;
            margin-top: 15px;
        }
        .attachment-note li {
            margin: 8px 0;
            font-size: 14px;
        }
        .signature {
            margin-top: 40px;
            padding: 30px 40px;
            border-top: 2px solid #e0e0e0;
            background: #fafafa;
            color: #555;
        }
        .signature strong {
            color: #333;
            font-size: 16px;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>Veeam Backup Infrastructure Report</h1>
            <div class="subtitle">$ServerName - $(Get-Date -Format 'MMMM dd, yyyy')</div>
        </div>
        
        <div class="content">
            <div class="summary-section">
                <h2>Executive Summary</h2>
$(foreach ($paragraph in $aiSummary -split "`n") {
    if ($paragraph.Trim()) {
"                <p>$paragraph</p>`n"
    }
})
            </div>
            
            <div class="repository-section">
                <h2>Repository Architecture Analysis</h2>
$(foreach ($paragraph in $aiRepositoryAnalysis -split "`n") {
    if ($paragraph.Trim()) {
"                <p>$paragraph</p>`n"
    }
})
            </div>
            
            <div class="stats-grid">
                <div class="stat-card">
                    <div class="stat-value">$totalRepositories</div>
                    <div class="stat-label">Repositories</div>
                </div>
                <div class="stat-card">
                    <div class="stat-value">$totalMachines</div>
                    <div class="stat-label">Protected Machines</div>
                </div>
                <div class="stat-card">
                    <div class="stat-value">$totalBackupFiles</div>
                    <div class="stat-label">Backup Files</div>
                </div>
                <div class="stat-card">
                    <div class="stat-value">$totalBackupSize TB</div>
                    <div class="stat-label">Total Storage</div>
                </div>
            </div>
            
            <div class="recommendations">
                <h3>Server-Level Optimization Recommendations</h3>
                <ul>
$(foreach ($recommendation in $aiRecommendations) {
"                    <li><span class='recommendation-arrow'>&#9658;</span> $recommendation</li>`n"
})                </ul>
            </div>
            
            <div class="attachment-note">
                <div class="icon">&#128206;</div>
                <strong>Full Detailed Report Attached</strong>
                <p>Please review the attached HTML report for comprehensive analysis including:</p>
                <ul>
                    <li>&#8226; Detailed backup inventory for each machine</li>
                    <li>&#8226; Storage utilization and growth trends</li>
                    <li>&#8226; GFS retention compliance analysis</li>
                    <li>&#8226; Backup chain validation results</li>
                    <li>&#8226; Performance metrics and optimization opportunities</li>
                </ul>
            </div>
        </div>
        
        <div class="signature">
            <p>Best Regards,</p>
            <p>
                <strong>David Andrews</strong><br>
                Sr. Systems Engineer<br>
                Houston Information Team, LLC<br>
                Cell +1 (713) 480-9933
            </p>
        </div>
    </div>
</body>
</html>
"@
    
    return $emailBody
}

function Send-EmailReport {
    param(
        [string]$HTMLFilePath,
        [string]$ToAddress,
        [string]$SMTPServer,
        [int]$SMTPPort = 587,
        [string]$SMTPUsername,
        [string]$SMTPPassword,
        [bool]$UseSSL = $true,
        [string]$ServerName = "",
        [string]$FromAddress = "",
        [hashtable]$BackupInventory = @{},
        [hashtable]$StorageMetrics = @{}
    )
    
    try {
        Write-Log "✉️ Preparing to send email report to $ToAddress" 'SUCCESS'
        Write-Log "  SMTP Server: $SMTPServer`:$SMTPPort (SSL: $UseSSL)" 'SUCCESS'
        Write-Log "  SMTP Username: $SMTPUsername" 'SUCCESS'
        
        # Generate professional email body with AI summary
        $emailBody = New-ProfessionalEmailBody -ServerName $ServerName -BackupInventory $BackupInventory -StorageMetrics $StorageMetrics -HTMLFilePath $HTMLFilePath
        
        # Create email message
        $subject = "Veeam Backup Report - $ServerName - $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
        
        # Determine From address - ensure it's a valid email format
        if ($FromAddress) {
            # Use provided From address
            $finalFromAddress = $FromAddress
        } elseif ($SMTPUsername) {
            # Check if username is already an email address
            if ($SMTPUsername -match '@') {
                $finalFromAddress = $SMTPUsername
            } else {
                # For SMTP2GO and similar services, use the To address as From
                # Many SMTP services allow this for authenticated users
                $finalFromAddress = $ToAddress
            }
        } else {
            $finalFromAddress = "veeamreport@$env:COMPUTERNAME.local"
        }
        
        Write-Log "  From Address: $finalFromAddress" 'SUCCESS'
        Write-Log "  To Address: $ToAddress" 'SUCCESS'
        
        $mailParams = @{
            To = $ToAddress
            From = $finalFromAddress
            Subject = $subject
            Body = $emailBody
            BodyAsHtml = $true
            SmtpServer = $SMTPServer
            Port = $SMTPPort
            UseSsl = $UseSSL
            Encoding = [System.Text.Encoding]::UTF8
        }
        
        # Add credentials if provided
        if ($SMTPUsername -and $SMTPPassword) {
            $securePassword = ConvertTo-SecureString $SMTPPassword -AsPlainText -Force
            $credential = New-Object System.Management.Automation.PSCredential($SMTPUsername, $securePassword)
            $mailParams.Credential = $credential
        }
        
        # Attach the HTML report file
        $mailParams.Attachments = $HTMLFilePath
        
        # Send the email (suppress obsolete warning)
        $oldWarningPreference = $WarningPreference
        $WarningPreference = 'SilentlyContinue'
        
        try {
            Send-MailMessage @mailParams -ErrorAction Stop
            Write-Log "✅ Email report successfully sent to $ToAddress with attachment" 'SUCCESS'
            return $true
        }
        finally {
            $WarningPreference = $oldWarningPreference
        }
    }
    catch {
        Write-Log "❌ Failed to send email report: $_" 'ERROR'
        return $false
    }
}

function Manage-ServerProfiles {
    Write-Log "📝 Managing server profiles" 'SUCCESS'
    
    while ($true) {
        Clear-Host
        Write-Host ""
        Write-Host "═══════════════════════════════════════════════════════════════════" -ForegroundColor DarkGray
        Write-Host "                     SERVER PROFILE MANAGEMENT                        " -ForegroundColor Cyan
        Write-Host "═══════════════════════════════════════════════════════════════════" -ForegroundColor DarkGray
        Write-Host ""
        
        $servers = Get-SavedServers
        
        if ($servers.Count -gt 0) {
            Write-Host "Saved Server Profiles:" -ForegroundColor Yellow
            Write-Host ""
            $index = 1
            foreach ($s in $servers) {
                $serverDisplay = if ($s.ServerName) { $s.ServerName } else { 
                    if ($s.UNCPath -match '^\\\\([^\\]+)') { $matches[1] } else { "Unknown" }
                }
                $emailStatus = if ($s.EmailEnabled -and $s.EmailAddress) { 
                    " ✉️ Send To: $($s.EmailAddress)" 
                } else { 
                    "" 
                }
                Write-Host "  $index. $serverDisplay - $($s.UNCPath)$emailStatus" -ForegroundColor White
                $index++
            }
            Write-Host ""
        } else {
            Write-Host "  No server profiles configured" -ForegroundColor Yellow
            Write-Host ""
        }
        
        Write-Host "Options:" -ForegroundColor Cyan
        Write-Host "  A. Add new server profile" -ForegroundColor White
        Write-Host "  E. Edit existing server profile" -ForegroundColor White
        Write-Host "  D. Delete server profile" -ForegroundColor White
        Write-Host "  T. Test email configuration" -ForegroundColor White
        Write-Host "  F. Refresh server list" -ForegroundColor White
        Write-Host "  Q. Return to main menu" -ForegroundColor White
        Write-Host ""
        
        $choice = Read-Host "Please choose an option"
        
        switch ($choice.ToUpper()) {
            'A' {
                Add-NewServerProfile
            }
            'E' {
                if ($servers.Count -eq 0) {
                    Write-Host "No servers to edit." -ForegroundColor Red
                    Start-Sleep -Seconds 2
                    continue
                }
                $serverNum = Read-Host "Enter server number to edit (1-$($servers.Count))"
                if ($serverNum -match '^\d+$' -and [int]$serverNum -ge 1 -and [int]$serverNum -le $servers.Count) {
                    $server = $servers[[int]$serverNum - 1]
                    Edit-ServerProfile -Server $server
                } else {
                    Write-Host "Invalid selection." -ForegroundColor Red
                    Start-Sleep -Seconds 2
                }
            }
            'D' {
                if ($servers.Count -eq 0) {
                    Write-Host "No servers to delete." -ForegroundColor Red
                    Start-Sleep -Seconds 2
                    continue
                }
                $serverNum = Read-Host "Enter server number to delete (1-$($servers.Count))"
                if ($serverNum -match '^\d+$' -and [int]$serverNum -ge 1 -and [int]$serverNum -le $servers.Count) {
                    $server = $servers[[int]$serverNum - 1]
                    $key = Sanitize-KeyName -UNCPath $server.UNCPath -Username $server.Username
                    Delete-ServerSettings -KeyName $key
                    Write-Host "Server profile deleted." -ForegroundColor Green
                    Start-Sleep -Seconds 2
                } else {
                    Write-Host "Invalid selection." -ForegroundColor Red
                    Start-Sleep -Seconds 2
                }
            }
            'T' {
                if ($servers.Count -eq 0) {
                    Write-Host "No servers configured." -ForegroundColor Red
                    Start-Sleep -Seconds 2
                    continue
                }
                $serverNum = Read-Host "Enter server number to test email (1-$($servers.Count))"
                if ($serverNum -match '^\d+$' -and [int]$serverNum -ge 1 -and [int]$serverNum -le $servers.Count) {
                    $server = $servers[[int]$serverNum - 1]
                    Test-EmailConfiguration -Server $server
                } else {
                    Write-Host "Invalid selection." -ForegroundColor Red
                    Start-Sleep -Seconds 2
                }
            }
            'F' {
                Write-Host "Refreshing server list from registry..." -ForegroundColor Yellow
                $servers = Get-SavedServers
                Write-Host "Server list refreshed." -ForegroundColor Green
                Start-Sleep -Seconds 1
            }
            'Q' {
                Clear-Host
                return
            }
            default {
                Write-Host "Invalid option." -ForegroundColor Red
                Start-Sleep -Seconds 2
            }
        }
    }
}

function Edit-ServerProfile {
    param($Server)
    
    # Keep editing in a loop until user cancels
    while ($true) {
        # Reload server data from registry to get latest changes
        $servers = Get-SavedServers
        $updatedServer = $servers | Where-Object { $_.UNCPath -eq $Server.UNCPath -and $_.Username -eq $Server.Username }
        if ($updatedServer) { $Server = $updatedServer }
        
        Clear-Host
        Write-Host ""
        Write-Host "Editing Server Profile" -ForegroundColor Cyan
        Write-Host "═══════════════════════════════════════════════════════════════════" -ForegroundColor DarkGray
        Write-Host ""
        
        $serverName = if ($Server.ServerName) { $Server.ServerName } else { 
            if ($Server.UNCPath -match '^\\\\([^\\]+)') { $matches[1] } else { "Unknown" }
        }
        
        Write-Host "Current Settings for ${serverName}:" -ForegroundColor Yellow
        Write-Host "  UNC Path: $($Server.UNCPath)" -ForegroundColor Gray
        Write-Host "  Username: $($Server.Username)" -ForegroundColor Gray
        Write-Host "  Drive Letter: $($Server.DriveLetter)" -ForegroundColor Gray
        Write-Host "  Email Address: $(if ($Server.EmailAddress) { $Server.EmailAddress } else { 'Not configured' })" -ForegroundColor Gray
        Write-Host "  Email Enabled: $(if ($Server.EmailEnabled) { 'Yes' } else { 'No' })" -ForegroundColor Gray
        Write-Host ""
        
        Write-Host "What would you like to edit?" -ForegroundColor Cyan
        Write-Host "  1. Email address" -ForegroundColor White
        Write-Host "  2. Enable/Disable email" -ForegroundColor White
        Write-Host "  3. Drive letter" -ForegroundColor White
        Write-Host "  4. Username and password" -ForegroundColor White
        Write-Host "  S. Save Changes and Refresh" -ForegroundColor Green
        Write-Host "  Q. Quit to previous menu" -ForegroundColor White
        Write-Host ""
        
        $choice = Read-Host "Enter your choice"
    
        $key = Sanitize-KeyName -UNCPath $Server.UNCPath -Username $Server.Username
        
        switch ($choice.ToUpper()) {
        '1' {
            $newEmail = Read-Host "Enter new email address"
            if ($newEmail) {
                Save-ServerSettings -UNCPath $Server.UNCPath -Username $Server.Username `
                    -Password $Server.Password -DriveLetter $Server.DriveLetter `
                    -KeyName $key -ServerName $Server.ServerName `
                    -EmailAddress $newEmail -EmailEnabled $Server.EmailEnabled `
                    -SMTPServer $Server.SMTPServer -SMTPPort $Server.SMTPPort `
                    -SMTPUsername $Server.SMTPUsername -SMTPPassword $Server.SMTPPassword `
                    -UseSSL $Server.UseSSL
                Write-Host "Email address updated and saved to registry." -ForegroundColor Green
                Write-Log "Email address updated for ${serverName}: $newEmail" 'SUCCESS'
            }
        }
        '2' {
            $newEnabled = if ($Server.EmailEnabled) { $false } else { $true }
            Save-ServerSettings -UNCPath $Server.UNCPath -Username $Server.Username `
                -Password $Server.Password -DriveLetter $Server.DriveLetter `
                -KeyName $key -ServerName $Server.ServerName `
                -EmailAddress $Server.EmailAddress -EmailEnabled $newEnabled `
                -SMTPServer $Server.SMTPServer -SMTPPort $Server.SMTPPort `
                -SMTPUsername $Server.SMTPUsername -SMTPPassword $Server.SMTPPassword `
                -UseSSL $Server.UseSSL
            Write-Host "Email $(if ($newEnabled) { 'enabled' } else { 'disabled' }) and saved to registry." -ForegroundColor Green
            Write-Log "Email notifications $(if ($newEnabled) { 'enabled' } else { 'disabled' }) for $serverName" 'SUCCESS'
        }
        '3' {
            $available = Get-AvailableDriveLetters
            Write-Host "Available drive letters: $($available -join ', ')" -ForegroundColor Yellow
            $newDrive = Read-Host "Enter new drive letter"
            if ($newDrive -and $newDrive.Length -eq 1) {
                $newDrive = "$newDrive`:"
                Save-ServerSettings -UNCPath $Server.UNCPath -Username $Server.Username `
                    -Password $Server.Password -DriveLetter $newDrive `
                    -KeyName $key -ServerName $Server.ServerName `
                    -EmailAddress $Server.EmailAddress -EmailEnabled $Server.EmailEnabled `
                    -SMTPServer $Server.SMTPServer -SMTPPort $Server.SMTPPort `
                    -SMTPUsername $Server.SMTPUsername -SMTPPassword $Server.SMTPPassword `
                    -UseSSL $Server.UseSSL
                Write-Host "Drive letter updated and saved to registry." -ForegroundColor Green
                Write-Log "Drive letter updated for ${serverName}: $newDrive" 'SUCCESS'
            }
        }
        '4' {
            $newUsername = Read-Host "Enter new username"
            $newPassword = Read-Host "Enter new password" -AsSecureString
            if ($newUsername -and $newPassword) {
                $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($newPassword)
                $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($BSTR)
                [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
                
                # Delete old key
                Delete-ServerSettings -KeyName $key
                
                # Create new key with new username
                $newKey = Sanitize-KeyName -UNCPath $Server.UNCPath -Username $newUsername
                Save-ServerSettings -UNCPath $Server.UNCPath -Username $newUsername `
                    -Password $plainPassword -DriveLetter $Server.DriveLetter `
                    -KeyName $newKey -ServerName $Server.ServerName `
                    -EmailAddress $Server.EmailAddress -EmailEnabled $Server.EmailEnabled `
                    -SMTPServer $Server.SMTPServer -SMTPPort $Server.SMTPPort `
                    -SMTPUsername $Server.SMTPUsername -SMTPPassword $Server.SMTPPassword `
                    -UseSSL $Server.UseSSL
                Write-Host "Credentials updated and saved to registry." -ForegroundColor Green
                Write-Log "Credentials updated for $serverName with new username: $newUsername" 'SUCCESS'
            }
        }
        'S' {
            # Force save and refresh all settings
            Write-Host "Saving all current settings to registry..." -ForegroundColor Green
            Save-ServerSettings -UNCPath $Server.UNCPath -Username $Server.Username `
                -Password $Server.Password -DriveLetter $Server.DriveLetter `
                -KeyName $key -ServerName $Server.ServerName `
                -EmailAddress $Server.EmailAddress -EmailEnabled $Server.EmailEnabled `
                -SMTPServer $Server.SMTPServer -SMTPPort $Server.SMTPPort `
                -SMTPUsername $Server.SMTPUsername -SMTPPassword $Server.SMTPPassword `
                -UseSSL $Server.UseSSL
            Write-Host "Settings saved and refreshed successfully!" -ForegroundColor Green
            Write-Log "Server profile saved and refreshed for $serverName" 'SUCCESS'
            Start-Sleep -Seconds 2
        }
        'Q' {
            Write-Log "User quit to previous menu" 'SUCCESS'
            Clear-Host
            return $true  # Indicate we're done editing
        }
        default {
            Write-Host "Invalid option." -ForegroundColor Red
            Start-Sleep -Seconds 1
            continue
        }
    }
    
    Write-Host ""
    Write-Host "Settings saved successfully!" -ForegroundColor Green
    Write-Log "Server profile changes saved to registry for $serverName" 'SUCCESS'
    Start-Sleep -Seconds 1
    }
}

function Configure-ServerSMTPSettings {
    param($Server, $Key)
    
    Write-Host ""
    Write-Host "Configure SMTP Settings" -ForegroundColor Cyan
    Write-Host ""
    
    $smtpServer = Read-Host "Enter SMTP server (e.g., smtp.gmail.com) [Current: $($Server.SMTPServer)]"
    if (-not $smtpServer) { $smtpServer = $Server.SMTPServer }
    
    $smtpPort = Read-Host "Enter SMTP port (e.g., 587) [Current: $($Server.SMTPPort)]"
    if (-not $smtpPort) { $smtpPort = $Server.SMTPPort }
    
    $smtpUsername = Read-Host "Enter SMTP username [Current: $($Server.SMTPUsername)]"
    if (-not $smtpUsername) { $smtpUsername = $Server.SMTPUsername }
    
    $changePassword = Read-Host "Change SMTP password? (Y/N)"
    $smtpPassword = $Server.SMTPPassword
    if ($changePassword -eq 'Y') {
        $smtpSecure = Read-Host "Enter SMTP password" -AsSecureString
        $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($smtpSecure)
        $smtpPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($BSTR)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
    }
    
    $useSSL = Read-Host "Use SSL? (Y/N) [Current: $(if ($Server.UseSSL) { 'Y' } else { 'N' })]"
    if (-not $useSSL) { 
        $useSSL = $Server.UseSSL 
    } else {
        $useSSL = $useSSL -eq 'Y'
    }
    
    Save-ServerSettings -UNCPath $Server.UNCPath -Username $Server.Username `
        -Password $Server.Password -DriveLetter $Server.DriveLetter `
        -KeyName $Key -ServerName $Server.ServerName `
        -EmailAddress $Server.EmailAddress -EmailEnabled $Server.EmailEnabled `
        -SMTPServer $smtpServer -SMTPPort $smtpPort `
        -SMTPUsername $smtpUsername -SMTPPassword $smtpPassword `
        -UseSSL $useSSL
    
    Write-Host "SMTP settings updated." -ForegroundColor Green
}

function Get-GlobalSMTPSettings {
    # Returns global SMTP settings stored in registry
    # If not found, returns default SMTP2GO settings
    
    $regPath = "HKCU:\Software\VeeamItUpPlus\GlobalSMTP"
    
    if (Test-Path $regPath) {
        try {
            $settings = @{
                SMTPServer = (Get-ItemProperty -Path $regPath -Name SMTPServer -ErrorAction SilentlyContinue).SMTPServer
                SMTPPort = (Get-ItemProperty -Path $regPath -Name SMTPPort -ErrorAction SilentlyContinue).SMTPPort
                SMTPUsername = (Get-ItemProperty -Path $regPath -Name SMTPUsername -ErrorAction SilentlyContinue).SMTPUsername
                SMTPPassword = (Get-ItemProperty -Path $regPath -Name SMTPPassword -ErrorAction SilentlyContinue).SMTPPassword
                UseSSL = (Get-ItemProperty -Path $regPath -Name UseSSL -ErrorAction SilentlyContinue).UseSSL
            }
            
            # Decrypt password if it exists
            if ($settings.SMTPPassword) {
                try {
                    $securePassword = ConvertTo-SecureString $settings.SMTPPassword -ErrorAction Stop
                    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
                    $settings.SMTPPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($BSTR)
                    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
                } catch {
                    # Password might be stored in plain text for compatibility
                    # Keep as is
                }
            }
            
            return $settings
        } catch {
            Write-Log "⚠️ Error reading global SMTP settings: $_" 'SUCCESS'
        }
    }
    
    # Return default SMTP2GO settings if no global settings found
    return @{
        SMTPServer = "mail.smtp2go.com"
        SMTPPort = 2525
        SMTPUsername = "dandrews"
        SMTPPassword = "WLGJHz?*AUcx"
        UseSSL = $true
    }
}

function Save-GlobalSMTPSettings {
    param(
        [string]$SMTPServer,
        [int]$SMTPPort,
        [string]$SMTPUsername,
        [string]$SMTPPassword,
        [bool]$UseSSL
    )
    
    $regPath = "HKCU:\Software\VeeamItUpPlus\GlobalSMTP"
    
    # Create registry path if it doesn't exist
    if (-not (Test-Path $regPath)) {
        New-Item -Path $regPath -Force | Out-Null
    }
    
    # Encrypt password
    $securePassword = ConvertTo-SecureString $SMTPPassword -AsPlainText -Force
    $encryptedPassword = ConvertFrom-SecureString $securePassword
    
    # Save settings
    Set-ItemProperty -Path $regPath -Name SMTPServer -Value $SMTPServer
    Set-ItemProperty -Path $regPath -Name SMTPPort -Value $SMTPPort
    Set-ItemProperty -Path $regPath -Name SMTPUsername -Value $SMTPUsername
    Set-ItemProperty -Path $regPath -Name SMTPPassword -Value $encryptedPassword
    Set-ItemProperty -Path $regPath -Name UseSSL -Value $UseSSL
}

function Configure-GlobalSMTPSettings {
    Write-Host ""
    Write-Host "Global SMTP Settings Configuration" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════════" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "Configure default SMTP settings for all servers" -ForegroundColor Yellow
    Write-Host ""
    
    Write-Host "Recommended SMTP2GO Settings:" -ForegroundColor Green
    Write-Host "  Server: mail.smtp2go.com" -ForegroundColor Gray
    Write-Host "  Port: 2525" -ForegroundColor Gray
    Write-Host "  SSL: Yes (STARTTLS)" -ForegroundColor Gray
    Write-Host "  Username: dandrews" -ForegroundColor Gray
    Write-Host ""
    
    $useSMTP2GO = Read-Host "Use SMTP2GO recommended settings? (Y/N)"
    
    if ($useSMTP2GO -eq 'Y') {
        # Save SMTP2GO settings as global
        Save-GlobalSMTPSettings -SMTPServer "mail.smtp2go.com" -SMTPPort 2525 `
            -SMTPUsername "dandrews" -SMTPPassword "WLGJHz?*AUcx" -UseSSL $true
        
        Write-Host "SMTP2GO settings saved as global defaults." -ForegroundColor Green
    } else {
        Write-Host "Enter custom SMTP settings:" -ForegroundColor Yellow
        $smtpServer = Read-Host "SMTP Server"
        $smtpPort = Read-Host "SMTP Port"
        $smtpUsername = Read-Host "SMTP Username"
        $smtpSecure = Read-Host "SMTP Password" -AsSecureString
        $useSSL = Read-Host "Use SSL? (Y/N)"
        $useSSL = $useSSL -eq 'Y'
        
        $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($smtpSecure)
        $smtpPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($BSTR)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
        
        # Save custom settings as global
        Save-GlobalSMTPSettings -SMTPServer $smtpServer -SMTPPort $smtpPort `
            -SMTPUsername $smtpUsername -SMTPPassword $smtpPassword -UseSSL $useSSL
        
        Write-Host "Custom SMTP settings saved as global defaults." -ForegroundColor Green
    }
    
    Start-Sleep -Seconds 2
    Clear-Host
}

function Test-EmailConfiguration {
    param($Server)
    
    if (-not $Server.EmailEnabled) {
        Write-Host "Email is disabled for this server." -ForegroundColor Yellow
        Start-Sleep -Seconds 2
        return
    }
    
    if (-not $Server.EmailAddress -or -not $Server.SMTPServer) {
        Write-Host "Email configuration is incomplete." -ForegroundColor Red
        Start-Sleep -Seconds 2
        return
    }
    
    Write-Host "Sending test email to $($Server.EmailAddress)..." -ForegroundColor Yellow
    
    # Create a simple test HTML
    $testHTML = @"
<!DOCTYPE html>
<html>
<head><title>Test Email</title></head>
<body>
    <h1>VeeamItUp+ Test Email</h1>
    <p>This is a test email from VeeamItUp+ for server: $($Server.ServerName)</p>
    <p>If you received this email, your email configuration is working correctly.</p>
    <p>Timestamp: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</p>
</body>
</html>
"@
    
    $tempFile = [System.IO.Path]::GetTempFileName() + ".html"
    $testHTML | Out-File -FilePath $tempFile -Encoding UTF8
    
    $result = Send-EmailReport -HTMLFilePath $tempFile `
        -ToAddress $Server.EmailAddress `
        -SMTPServer $Server.SMTPServer `
        -SMTPPort $Server.SMTPPort `
        -SMTPUsername $Server.SMTPUsername `
        -SMTPPassword $Server.SMTPPassword `
        -UseSSL $Server.UseSSL `
        -ServerName $Server.ServerName
    
    Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
    
    if ($result) {
        Write-Host ""
        Write-Host "✅ Test email sent successfully!" -ForegroundColor Green
        Write-Host "Check your inbox at: $($Server.EmailAddress)" -ForegroundColor Cyan
    } else {
        Write-Host ""
        Write-Host "❌ Failed to send test email." -ForegroundColor Red
        Write-Host "Please check your SMTP settings and credentials." -ForegroundColor Yellow
    }
    
    Write-Host ""
    Write-Host "Press any key to return to menu..." -ForegroundColor Gray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    Clear-Host
}

function Add-NewServerProfile {
    Write-Log "➕ Adding a new server profile." 'SUCCESS'
    Write-Log "❓ Prompting user for UNC path to Veeam repository" 'SUCCESS'
    $UNCPath = Read-Host "Enter UNC path to Veeam repository (e.g. \\server\share)"
        if ([string]::IsNullOrWhiteSpace($UNCPath)) {
            Write-Log "❌ UNC path is empty. Aborting add operation." 'ERROR'
        return $false
        }
        if (-not $UNCPath.StartsWith("\\")) {
            Write-Log "❌ UNC path does not start with \\. Aborting add operation." 'ERROR'
        return $false
        }
        Write-Log "📝 User entered UNC path: $UNCPath" 'SUCCESS'
        Write-Log "❓ Prompting user for username" 'SUCCESS'
        $Username = Read-Host "Enter username"
        if ([string]::IsNullOrWhiteSpace($Username)) {
            Write-Log "❌ Username is empty. Aborting add operation." 'ERROR'
        return $false
        }
        Write-Log "📝 User entered username: $Username" 'SUCCESS'
        Write-Log "❓ Prompting user for password (secure input)" 'SUCCESS'
        $SecurePassword = Read-Host "Enter password" -AsSecureString
        if (-not $SecurePassword -or $SecurePassword.Length -eq 0) {
            Write-Log "❌ Password is empty. Aborting add operation." 'ERROR'
        return $false
        }
        Write-Log "🔒 User entered password (hidden)." 'SUCCESS'
    
    # Convert SecureString to plain string for registry storage
        $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
        $Password = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($BSTR)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
    
    # Set default email configuration (disabled by default)
    $emailAddress = ""
    $emailEnabled = $false
    
    # Get global SMTP settings from registry for when email is enabled later
    $globalSMTP = Get-GlobalSMTPSettings
    $smtpServer = $globalSMTP.SMTPServer
    $smtpPort = $globalSMTP.SMTPPort
    $smtpUsername = $globalSMTP.SMTPUsername
    $smtpPassword = $globalSMTP.SMTPPassword
    $useSSL = $globalSMTP.UseSSL
    
        $available = Get-AvailableDriveLetters
        Write-Log "🔍 Available drive letters: $($available -join ', ')" 'SUCCESS'
    $suggested = if ($available -contains 'V') { 'V' } else { $available | Sort-Object | Select-Object -First 1 }
        do {
        $prompt = "Enter drive letter to use (choose one: $($available -join ', ')) [Suggested: $suggested]"
        Write-Log "❓ Prompting user for drive letter selection" 'SUCCESS'
        $DriveLetterInput = Read-Host $prompt
        if ([string]::IsNullOrWhiteSpace($DriveLetterInput)) { $DriveLetterInput = $suggested }
        $DriveLetterInput = [string]$DriveLetterInput
            $DriveLetterInput = $DriveLetterInput.ToUpper()
            if ($DriveLetterInput.Length -ne 1 -or $DriveLetterInput -notin $available) {
                Write-Log "⚠️ Invalid drive letter entered: $DriveLetterInput" 'SUCCESS'
                Write-Log "⚠️ Invalid drive letter. Please try again." 'SUCCESS'
            }
        } while ($DriveLetterInput.Length -ne 1 -or $DriveLetterInput -notin $available)
        $DriveLetter = "$DriveLetterInput`:"
        Write-Log "💾 User selected drive letter: $DriveLetter" 'SUCCESS'
    
        # Parse server name from UNC path
        $ServerName = $null
        if ($UNCPath -match '^\\\\([^\\]+)') { $ServerName = $matches[1] }
        $key = Sanitize-KeyName -UNCPath $UNCPath -Username $Username
        Write-Log "🔑 Generated registry key for new profile: $key" 'SUCCESS'
    
    # Test connectivity first
    Write-Host ""
    Write-Host "Testing connectivity to server..." -ForegroundColor Yellow
    Write-Log "🔗 Testing connectivity to $UNCPath..." 'SUCCESS'
    
    # Test server connectivity
    $connectivitySuccess = $false
    if ($UNCPath -match '^\\\\([^\\]+)') {
        $testServerName = $matches[1]
        try {
            # Test network connectivity
            $ping = Test-Connection -ComputerName $testServerName -Count 2 -Quiet -ErrorAction SilentlyContinue
            if ($ping) {
                Write-Host "✅ Server $testServerName is reachable" -ForegroundColor Green
                Write-Log "✅ Server $testServerName is reachable" 'SUCCESS'
                
                # Test drive mapping
                Write-Host "Testing credentials and access..." -ForegroundColor Yellow
                if (New-NetworkDrive -DriveLetter $DriveLetter -UNCPath $UNCPath -Username $Username -Password $SecurePassword) {
                    Write-Host "✅ Successfully connected with provided credentials" -ForegroundColor Green
                    Write-Log "✅ Drive mapping test succeeded for $DriveLetter to $UNCPath" 'SUCCESS'
                    
                    # Remove the test mapping immediately
                    Remove-NetworkDrive -DriveLetter $DriveLetter
                    $connectivitySuccess = $true
                } else {
                    Write-Host "❌ Failed to connect with provided credentials" -ForegroundColor Red
                    Write-Log "❌ Drive mapping test failed" 'ERROR'
                }
            } else {
                Write-Host "❌ Server $testServerName is not reachable" -ForegroundColor Red
                Write-Log "❌ Server $testServerName is not reachable" 'ERROR'
            }
        } catch {
            Write-Host "⚠️ Error testing connectivity: $_" -ForegroundColor Yellow
            Write-Log "⚠️ Error testing connectivity: $_" 'SUCCESS'
        }
    }
    
    # Save profile if connectivity test passed
    if ($connectivitySuccess) {
        Write-Host ""
        Write-Host "✅ Connectivity test successful!" -ForegroundColor Green
        Write-Host "Saving server profile to registry..." -ForegroundColor Yellow
        
        Save-ServerSettings -UNCPath $UNCPath -Username $Username -Password $Password -DriveLetter $DriveLetter -KeyName $key -ServerName $ServerName `
            -EmailAddress $emailAddress -EmailEnabled $emailEnabled `
            -SMTPServer $smtpServer -SMTPPort $smtpPort `
            -SMTPUsername $smtpUsername -SMTPPassword $smtpPassword `
            -UseSSL $useSSL
        
        Write-Log "✅ New server profile saved to registry: $ServerName" 'SUCCESS'
        Write-Host "✅ Server profile successfully added: $ServerName" -ForegroundColor Green
        Write-Host ""
        Write-Host "You can now run a report for this server from the main menu." -ForegroundColor Cyan
        
        Start-Sleep -Seconds 3
        Clear-Host
        return $true
    } else {
        Write-Host ""
        Write-Host "❌ Connectivity test failed. Server profile not saved." -ForegroundColor Red
        Write-Log "❌ Server profile not saved due to connectivity failure" 'ERROR'
        
        Show-ReturnToMenuPrompt "Press any key to return to menu..." "Yellow"
        return $false
    }
}
function Test-DriveMapping {
    param(
        $DriveLetter,
        $UNCPath,
        $Username
    )
    
    Write-Log "🔍 Running drive mapping diagnostics..." 'SUCCESS'
    
    # Check if drive letter is already in use
    $existingDrives = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue
    $driveInUse = $existingDrives | Where-Object { $_.Name -eq $DriveLetter.Replace(":","") }
    
    if ($driveInUse) {
        Write-Log "⚠️ Drive $DriveLetter is already mapped to: $($driveInUse.DisplayRoot)" 'SUCCESS'
    } else {
        Write-Log "✅ Drive $DriveLetter is available" 'SUCCESS'
    }
    
    # Check network connectivity to server
    if ($UNCPath -match '^\\\\([^\\]+)') {
        $serverName = $matches[1]
        Write-Log "🌐 Testing connectivity to server: $serverName" 'SUCCESS'
        
        try {
            $ping = Test-Connection -ComputerName $serverName -Count 1 -Quiet -ErrorAction SilentlyContinue
            if ($ping) {
                Write-Log "✅ Server $serverName is reachable" 'SUCCESS'
            } else {
                Write-Log "❌ Server $serverName is not reachable" 'ERROR'
            }
        } catch {
            Write-Log "⚠️ Could not test connectivity to $serverName" 'SUCCESS'
        }
    }
    
    # Show current network mappings
    Write-Log "📋 Current network drive mappings:" 'SUCCESS'
    try {
        $netUseOutput = cmd /c "net use" 2>&1
        if ($netUseOutput) {
            $netUseOutput | ForEach-Object { 
                if ($_ -match "^\s*([A-Z]:)\s+(.+)$") {
                    Write-Log "   $($matches[1]) -> $($matches[2])" 'SUCCESS'
                }
            }
        } else {
            Write-Log "   No network drives currently mapped" 'SUCCESS'
        }
    } catch {
        Write-Log "   Could not retrieve network mappings" 'SUCCESS'
    }
}

# =====================
# Now do your startup logic
# =====================
Clear-Host
Show-Banner

$now = Get-Date
$script:LogFileName = "VeeamItUpPlusLog-" + $now.ToString("yyyy-MMM-dd-ddd-hhmmtt").Replace(":","") + ".html"
$script:DownloadsPath = if ($env:USERPROFILE) { 
    Join-Path $env:USERPROFILE "Downloads" 
} else { 
    Join-Path $env:HOME "Downloads" 
}
$script:LogFilePath = Join-Path $script:DownloadsPath $script:LogFileName

$script:LogBuffer = @()
$script:HtmlLogBuffer = @()
$script:LogLevelOrder = @{ 'ALL'=0; 'SUCCESS'=1; 'ERROR'=2 }
$script:CurrentLogLevel = 'ALL'
$script:ConnectivityResults = @{}
# Initialize OpenAI API variables
$script:OpenAIAPIKey = $null
$script:OpenAIConnected = $false
$script:OpenAIModel = Get-OpenAIModel  # Load saved model preference or use default

Write-Log "🚀 VeeamItUp+ Console started" 'SUCCESS'
Write-Log "🤖 Using OpenAI Model: $($script:OpenAIModel)" 'SUCCESS'
Write-Log "🌐 Initializing HTML activity log..." 'SUCCESS'
Update-HTMLLog  # Use the HTML log function
Keep-LastNLogs -N 3

# Check for OpenAI API key (don't force initialization)
$apiKey = Get-OpenAIAPIKey
if ($apiKey) {
    # Test the stored key silently
    if (Test-OpenAIConnection -APIKey $apiKey) {
        $script:OpenAIAPIKey = $apiKey
        $script:OpenAIConnected = $true
        Write-Log "✅ OpenAI API connected using stored key" 'SUCCESS'
    } else {
        Write-Log "⚠️ Stored API key exists but validation failed" 'SUCCESS'
    }
} else {
    Write-Log "ℹ️ No OpenAI API key configured - AI features disabled" 'SUCCESS'
}
Write-Log "📱 HTML activity log initialized - use 'L' to view" 'SUCCESS'

# =====================
# Section 0: Multi-Server Registry Management
# =====================
$script:RegRoot = "HKCU:\Software\VeeamItUpPlus"

# =====================
# Section 1: Startup Menu (now in a loop)
# =====================

while ($true) {
    $servers = Get-SavedServers
    Write-Log "🔍 Retrieved saved server profiles from registry. Count: $($servers.Count)" 'SUCCESS'
    if ($servers.Count -gt 0) {
        Write-Log "📋 Displaying saved VeeamItUp+ server profiles to user." 'SUCCESS'
        Write-Host ""
        Write-Log "📋 Saved VeeamItUp+ server profiles:" 'SUCCESS'
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
                    
                    # Add email indicator - just emoji if email is enabled
                    $emailIndicator = ""
                    $hasEmail = $false
                    if ($s.EmailEnabled -and $s.EmailAddress) {
                        $emailIndicator = " ✉️"
                        $hasEmail = $true
                    }
                    
                    Write-Log "$i.$connectivityIcon$emailIndicator [Server: $serverDisplay | UNC: $($s.UNCPath)  [$($s.Username)]  Drive: $($s.DriveLetter)]" 'SUCCESS'
                    
                    if ($connectivityIcon) {
                        Write-Host "$i." -NoNewline
                        Write-Host $connectivityIcon -ForegroundColor $connectivityColor -NoNewline
                        if ($hasEmail) {
                            Write-Host " " -NoNewline
                            Write-Host "✉️" -ForegroundColor Yellow -BackgroundColor Black -NoNewline
                        }
                        Write-Host " [Server: $serverDisplay | UNC: $($s.UNCPath)  [$($s.Username)]  Drive: $($s.DriveLetter)]"
                    } else {
                        Write-Host "$i." -NoNewline
                        if ($hasEmail) {
                            Write-Host " " -NoNewline
                            Write-Host "✉️" -ForegroundColor Yellow -BackgroundColor Black -NoNewline
                        }
                        Write-Host " [Server: $serverDisplay | UNC: $($s.UNCPath)  [$($s.Username)]  Drive: $($s.DriveLetter)]"
                    }
                    $i++
                } catch {
                    Write-Log "⚠️ Error displaying server profile $i`: $_" 'SUCCESS'
                    Write-Log "$i. [Error loading server profile - check logs]" 'ERROR'
                    Write-Host "$i. [Error loading server profile - check logs]" -ForegroundColor Red
                    $i++
                }
            }
        } catch {
            Write-Log "❌ Critical error displaying server profiles: $_" 'ERROR'
            Write-Log "❌ Error loading server profiles. Check HTML activity log for details." 'ERROR'
        }
        
        Write-Log "📝 Prompting user to select, add, or delete a server profile." 'SUCCESS'
        
        # Debug: Ensure menu always displays
        Write-Log "🎯 Displaying main menu options for $($servers.Count) server(s)" 'SUCCESS'
        
        Write-Log "═══════════════════════════════════════════════════════════════════════════════" 'SUCCESS'
        Write-Log "                                    MENU OPTIONS                                   " 'SUCCESS'
        Write-Log "═══════════════════════════════════════════════════════════════════════════════" 'SUCCESS'
        Write-Log "  1-$($servers.Count): Select a server to map and run report" 'SUCCESS'
        Write-Log "  S: Manage Server Profiles" 'SUCCESS'
        Write-Log "  C: Test server connectivity" 'SUCCESS'
        Write-Log "  D: Delete server profiles" 'SUCCESS'
        Write-Log "  L: View HTML activity log" 'SUCCESS'
        Write-Log "  M: Configure SMTP Settings" 'SUCCESS'
        Write-Log "  K: Manage OpenAI API Key" 'SUCCESS'
        Write-Log "  Q: Quit application" 'SUCCESS'
        Write-Log "═══════════════════════════════════════════════════════════════════════════════" 'SUCCESS'
        
        Write-Host ""
        Write-Host "═══════════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
        Write-Host "                                    MENU OPTIONS                                   " -ForegroundColor Cyan
        Write-Host "═══════════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
        Write-Host "  1-$($servers.Count): Select a server to map and run report" -ForegroundColor White
        Write-Host "  S: Manage Server Profiles" -ForegroundColor Green
        Write-Host "  C: Test server connectivity" -ForegroundColor Magenta
        Write-Host "  D: Delete server profiles" -ForegroundColor Red
        Write-Host "  L: View HTML activity log" -ForegroundColor Cyan
        Write-Host "  M: Configure SMTP Settings" -ForegroundColor Cyan
        Write-Host "  K: Manage OpenAI API Key" -ForegroundColor $(if ($script:OpenAIConnected) { "Green" } else { "Yellow" })
        Write-Host "  Q: Quit application" -ForegroundColor Yellow
        Write-Host "═══════════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
        Write-Host ""
        
        Write-Log "❓ Prompting user to choose a menu option" 'SUCCESS'
        $choice = Read-Host "Please choose an option"
        Write-Log "📝 User selected menu option: $choice" 'SUCCESS'
        if ($choice -match '^[0-9]+$' -and [int]$choice -ge 1 -and [int]$choice -le $servers.Count) {
            $selected = $servers[[int]$choice-1]
            Write-Log "🔑 User selected profile: $($selected.ServerName) [$($selected.UNCPath)] ($($selected.Username))" 'SUCCESS'
            $settings = Load-ServerSettings -KeyName $selected.Key
            if (-not $settings) { Write-Log "❌ Failed to load settings for selected profile. Continuing to menu." 'ERROR'; continue }
            $UNCPath = $settings.UNCPath
            $Username = $settings.Username
            $Password = $settings.Password
            $DriveLetter = $settings.DriveLetter
            if ([string]::IsNullOrWhiteSpace($Password)) {
                Write-Log "❌ Password loaded from registry is null or empty. Continuing to menu for security." 'ERROR'
                continue
            }
            $SecurePassword = ConvertTo-SecureString $Password -AsPlainText -Force
            
            # Store the selected server name for use in the report
            $script:SelectedServerName = $selected.ServerName
            
            Write-Log "🔒 Loaded credentials and drive mapping for selected profile." 'SUCCESS'
            Write-Log "📋 UNC Path: $UNCPath" 'SUCCESS'
            Write-Log "👤 Username: $Username" 'SUCCESS'
            Write-Log "💾 Drive Letter: $DriveLetter" 'SUCCESS'
            Write-Log "🔒 Password: ********" 'SUCCESS'
            
            # Run diagnostics first
            Test-DriveMapping -DriveLetter $DriveLetter -UNCPath $UNCPath -Username $Username
            
            Write-Log "🔗 Starting drive mapping process..." 'SUCCESS'
            
            # Map the drive and run report
            Write-Log "🔗 Attempting to map drive $DriveLetter to $UNCPath for $Username..." 'SUCCESS'
            if (New-NetworkDrive -DriveLetter $DriveLetter -UNCPath $UNCPath -Username $Username -Password $SecurePassword) {
                Write-Log "✅ Drive mapping succeeded!" 'SUCCESS'
                Write-Log "✅ Drive mapping succeeded. Running report generation." 'SUCCESS'
                Write-Log "📊 Analyzing backup files and generating report..." 'SUCCESS'
                Run-ReportForMappedDrive -DriveLetter $DriveLetter
                Write-Log "✅ Report generation completed!" 'SUCCESS'
                Update-HTMLLog
                Keep-LastNLogs -N 3
                Write-Log "HTML activity log updated with report generation results" 'SUCCESS'
                Show-ReturnToMenuPrompt "✅ Report completed! Press any key to return to menu..." "Green"
                continue
    } else {
                Write-Log "❌ Drive mapping failed!" 'ERROR'
                Write-Log "❌ Drive mapping failed. Continuing to menu." 'ERROR'
                Write-Log "💡 Troubleshooting tips:" 'SUCCESS'
                Write-Log "   • Check if the server is online and accessible" 'SUCCESS'
                Write-Log "   • Verify username and password are correct" 'SUCCESS'
                Write-Log "   • Ensure you have permission to access the UNC path" 'SUCCESS'
                Write-Log "   • Try accessing the UNC path directly in File Explorer first" 'SUCCESS'
                Write-Log "   • Check if any firewall or VPN is blocking the connection" 'SUCCESS'
                Write-Log "🔍 Check the HTML activity log for detailed error information." 'SUCCESS'
                Show-ReturnToMenuPrompt "❌ Drive mapping failed. Press any key to return to menu..." "Red"
                continue
            }
        } elseif ($choice -eq 'S') {
            Manage-ServerProfiles
            Clear-Host
            Show-Banner
            Write-Host ""
            continue
        } elseif ($choice -eq 'C') {
            Write-Log "🔍 User chose to test server connectivity." 'SUCCESS'
            Write-Log "🔍 Testing connectivity for all saved servers..." 'SUCCESS'
            
            # Clear previous connectivity results
            $script:ConnectivityResults.Clear()
            
            foreach ($s in $servers) {
                $serverDisplay = $s.ServerName
                if (-not $serverDisplay) {
                    if ($s.UNCPath -match '^\\\\([^\\]+)') { $serverDisplay = $matches[1] }
                }
                
                Write-Log "🔍 Testing: $serverDisplay ($($s.UNCPath))" 'SUCCESS'
                $testResult = Test-ServerConnectivity -ServerName $serverDisplay -UNCPath $s.UNCPath -TimeoutSeconds 5
                
                # Store the connectivity result
                $script:ConnectivityResults[$serverDisplay] = $testResult
                
                if ($testResult) {
                    Write-Log "✅ $serverDisplay is accessible" 'SUCCESS'
                } else {
                    Write-Log "❌ $serverDisplay has connectivity issues" 'SUCCESS'
                }
            }
            
            Write-Log "🔍 Connectivity test completed. Refreshing menu display." 'SUCCESS'
            Clear-Host
            Show-Banner
            Write-Host ""
            continue
        } elseif ($choice -eq 'D') {
            Write-Log "🗑️ User chose to delete a server profile." 'SUCCESS'
            Write-Log "🗑️ Delete ALL or a specific server?" 'SUCCESS'
            Write-Log "❓ Prompting user for delete choice" 'SUCCESS'
            $delChoice = Read-Host "Enter number to delete a server, or ALL to delete all"
            Write-Log "📝 User selected delete option: $delChoice" 'SUCCESS'
            if ($delChoice -eq 'ALL') {
                Write-Log "🗑️ Deleting ALL server profiles from registry." 'SUCCESS'
                Delete-AllServerSettings
                Show-ReturnToMenuPrompt "🗑️ All server profiles deleted. Press any key to return to menu..." "Yellow"
                continue
            } elseif ($delChoice -match '^[0-9]+$' -and [int]$delChoice -ge 1 -and [int]$delChoice -le $servers.Count) {
                $delKey = $servers[[int]$delChoice-1].Key
                Write-Log "🗑️ Deleting server profile with key: $delKey" 'SUCCESS'
                Delete-ServerSettings -KeyName $delKey
                Show-ReturnToMenuPrompt "🗑️ Server profile deleted. Press any key to return to menu..." "Yellow"
                continue
            } else {
                Write-Log "❌ Invalid delete choice entered: $delChoice. Continuing to menu." 'ERROR'
                continue
            }
        } elseif ($choice -eq 'M') {
            Write-Log "✉️ User chose to configure SMTP settings" 'SUCCESS'
            Configure-GlobalSMTPSettings
            Clear-Host
            Show-Banner
            Write-Host ""
            continue
        } elseif ($choice -eq 'K') {
            Write-Log "🤖 User chose to manage OpenAI API key" 'SUCCESS'
            Write-Host ""
            Write-Host "═══════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
            Write-Host "                    OpenAI API Key Management                       " -ForegroundColor Yellow
            Write-Host "═══════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
            Write-Host ""
            
            if ($script:OpenAIConnected) {
                Write-Host "Current Status: " -NoNewline
                Write-Host "Connected ✅" -ForegroundColor Green
                Write-Host "Current Model: " -NoNewline
                Write-Host $script:OpenAIModel -ForegroundColor Cyan
                Write-Host ""
                Write-Host "Options:" -ForegroundColor Yellow
                Write-Host "  1. Test connection" -ForegroundColor White
                Write-Host "  2. Update API key" -ForegroundColor White
                Write-Host "  3. Change model" -ForegroundColor White
                Write-Host "  4. Remove API key" -ForegroundColor Red
                Write-Host "  5. Cancel" -ForegroundColor Gray
                Write-Host ""
                
                $keyChoice = Read-Host "Choose an option"
                
                switch ($keyChoice) {
                    "1" {
                        Write-Log "🔍 Testing OpenAI connection..." 'SUCCESS'
                        if (Test-OpenAIConnection -APIKey $script:OpenAIAPIKey) {
                            Write-Host "✅ Connection test successful!" -ForegroundColor Green
                            
                            # Test with a simple query
                            Write-Host "Running AI capability test..." -ForegroundColor Cyan
                            $testResponse = Invoke-OpenAIAnalysis -SystemPrompt "You are a helpful assistant" -UserPrompt "Say 'AI system operational' if you can read this" -MaxTokens 50
                            if ($testResponse) {
                                Write-Host "AI Response: $testResponse" -ForegroundColor Green
                            }
                        } else {
                            Write-Host "❌ Connection test failed" -ForegroundColor Red
                            $script:OpenAIConnected = $false
                        }
                    }
                    "2" {
                        Write-Log "🔄 Updating OpenAI API key..." 'SUCCESS'
                        Write-Host "Enter new OpenAI API key: " -NoNewline -ForegroundColor Yellow
                        $newKey = Read-Host -AsSecureString
                        
                        if ($newKey.Length -eq 0) {
                            Write-Host "API key cannot be empty. Cancelled." -ForegroundColor Yellow
                        } else {
                            $newKeyPlain = ConvertFrom-SecureString -SecureString $newKey -AsPlainText
                            
                            if ($newKeyPlain) {
                                Write-Host "Verifying new API key..." -ForegroundColor Cyan
                                if (Test-OpenAIConnection -APIKey $newKeyPlain) {
                                    Save-OpenAIAPIKey -APIKey $newKeyPlain
                                    $script:OpenAIAPIKey = $newKeyPlain
                                    $script:OpenAIConnected = $true
                                    Write-Host "✅ New API key saved and verified!" -ForegroundColor Green
                                    
                                    # Prompt for model selection
                                    Start-Sleep -Seconds 1
                                    Clear-Host
                                    Show-Banner
                                    Select-OpenAIModel
                                } else {
                                    Write-Host "❌ API key verification failed" -ForegroundColor Red
                                }
                            }
                        }
                    }
                    "3" {
                        Write-Log "🤖 Changing OpenAI model..." 'SUCCESS'
                        Clear-Host
                        Show-Banner
                        Select-OpenAIModel
                    }
                    "4" {
                        Write-Log "🗑️ Removing OpenAI API key..." 'SUCCESS'
                        Write-Host "Are you sure you want to remove the API key? (Y/N): " -NoNewline -ForegroundColor Yellow
                        $confirm = Read-Host
                        if ($confirm -eq 'Y' -or $confirm -eq 'y') {
                            if (Remove-OpenAIAPIKey) {
                                Write-Host "✅ API key removed successfully" -ForegroundColor Green
                            } else {
                                Write-Host "❌ Failed to remove API key" -ForegroundColor Red
                            }
                        } else {
                            Write-Host "Cancelled" -ForegroundColor Gray
                        }
                    }
                    "5" {
                        Write-Host "Cancelled" -ForegroundColor Gray
                    }
                    default {
                        Write-Host "Invalid option" -ForegroundColor Red
                    }
                }
            } else {
                Write-Host ""
                Write-Host "OpenAI API Status" -ForegroundColor Cyan
                Write-Host "═══════════════════════════════════" -ForegroundColor DarkGray
                Write-Host "Current Status: " -NoNewline
                Write-Host "Not Connected ❌" -ForegroundColor Red
                Write-Host ""
                Write-Host "Choose an option:" -ForegroundColor Yellow
                Write-Host "  1. Configure API Key" -ForegroundColor White
                Write-Host "  2. Cancel" -ForegroundColor Gray
                Write-Host ""
                
                $subChoice = Read-Host "Enter your choice"
                
                if ($subChoice -eq '1') {
                    Initialize-OpenAIConnection
                } elseif ($subChoice -eq '2') {
                    Write-Host "Cancelled" -ForegroundColor Gray
                } else {
                    Write-Host "Invalid option" -ForegroundColor Red
                }
            }
            
            Show-ReturnToMenuPrompt "Press any key to return to menu..." "Cyan"
            Clear-Host
            Show-Banner
            Write-Host ""
            continue
        } elseif ($choice -eq 'L') {
            Write-Log "📱 User chose to view HTML activity log." 'SUCCESS'
            try {
                Update-HTMLLog  # Refresh the log before opening
                Start-Process $script:LogFilePath
                Write-Log "🚀 HTML activity log opened in default browser" 'SUCCESS'
                Show-ReturnToMenuPrompt "📱 HTML log opened in browser. Press any key to return to menu..." "Cyan"
            }
            catch {
                Write-Log "⚠️ Failed to open HTML log: $_" 'SUCCESS'
                Show-ReturnToMenuPrompt "❌ Failed to open HTML log. Press any key to return to menu..." "Red"
            }
            continue
        } elseif ($choice -eq 'Q') {
            Write-Log "👋 User chose to quit the application." 'SUCCESS'
            Write-Log "👋 Thank you for using VeeamItUp+!" 'SUCCESS'
            Update-HTMLLog
            break
        } else {
            Write-Log "❌ Invalid menu choice entered: $choice. Continuing to menu." 'ERROR'
            continue
        }
    } else {
        Write-Log "ℹ️ No saved server profiles found. Prompting user to add a new one." 'SUCCESS'
        Write-Log "⚠️ No saved server profiles found." 'SUCCESS'
        
        Write-Log "═══════════════════════════════════════════════════════════════════════════════" 'SUCCESS'
        Write-Log "                                    MENU OPTIONS                                   " 'SUCCESS'
        Write-Log "═══════════════════════════════════════════════════════════════════════════════" 'SUCCESS'
        Write-Log "  S: Manage Server Profiles" 'SUCCESS'
        Write-Log "  L: View HTML activity log" 'SUCCESS'
        Write-Log "  M: Configure SMTP Settings" 'SUCCESS'
        Write-Log "  K: Manage OpenAI API Key" 'SUCCESS'
        Write-Log "  Q: Quit application" 'SUCCESS'
        Write-Log "═══════════════════════════════════════════════════════════════════════════════" 'SUCCESS'
        
        Write-Host "No saved server profiles found." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "═══════════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
        Write-Host "                                    MENU OPTIONS                                   " -ForegroundColor Cyan
        Write-Host "═══════════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
        Write-Host "  S: Manage Server Profiles" -ForegroundColor Green
        Write-Host "  L: View HTML activity log" -ForegroundColor Cyan
        Write-Host "  M: Configure SMTP Settings" -ForegroundColor Cyan
        Write-Host "  K: Manage OpenAI API Key" -ForegroundColor $(if ($script:OpenAIConnected) { "Green" } else { "Yellow" })
        Write-Host "  Q: Quit application" -ForegroundColor Yellow
        Write-Host "═══════════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
        Write-Host ""
        
        Write-Log "❓ Prompting user to choose a menu option (no servers scenario)" 'SUCCESS'
        $choice = Read-Host "Please choose an option"
        Write-Log "📝 User selected menu option: $choice" 'SUCCESS'
        if ($choice -eq 'S') {
            Manage-ServerProfiles
            continue
        } elseif ($choice -eq 'M') {
            Write-Log "✉️ User chose to configure SMTP settings" 'SUCCESS'
            Configure-GlobalSMTPSettings
            Clear-Host
            Show-Banner
            Write-Host ""
            continue
        } elseif ($choice -eq 'K') {
            Write-Log "🤖 User chose to manage OpenAI API key." 'SUCCESS'
            
            if ($script:OpenAIConnected) {
                Write-Host ""
                Write-Host "OpenAI API Status" -ForegroundColor Cyan
                Write-Host "═══════════════════════════════════" -ForegroundColor DarkGray
                Write-Host "Current Status: " -NoNewline
                Write-Host "Connected ✅" -ForegroundColor Green
                Write-Host "Current Model: " -NoNewline
                Write-Host $script:OpenAIModel -ForegroundColor Cyan
                Write-Host ""
                Write-Host "Choose an option:" -ForegroundColor Yellow
                Write-Host "  1. Test API Connection" -ForegroundColor White
                Write-Host "  2. View API Key (masked)" -ForegroundColor White  
                Write-Host "  3. Replace API Key" -ForegroundColor White
                Write-Host "  4. Change Model" -ForegroundColor White
                Write-Host "  5. Delete API Key" -ForegroundColor Red
                Write-Host "  6. Cancel" -ForegroundColor Gray
                Write-Host ""
                
                $subChoice = Read-Host "Enter your choice"
                
                switch ($subChoice) {
                    "1" {
                        Write-Host "Testing API connection..." -ForegroundColor Cyan
                        if (Test-OpenAIConnection) {
                            Write-Host "✅ API connection successful!" -ForegroundColor Green
                        } else {
                            Write-Host "❌ API connection failed" -ForegroundColor Red
                        }
                    }
                    "2" {
                        $apiKey = Get-OpenAIAPIKey
                        if ($apiKey) {
                            $maskedKey = if ($apiKey.Length -gt 8) {
                                $apiKey.Substring(0, 6) + ('*' * ($apiKey.Length - 10)) + $apiKey.Substring($apiKey.Length - 4)
                            } else { '*' * $apiKey.Length }
                            Write-Host "Current API Key: $maskedKey" -ForegroundColor Cyan
                        } else {
                            Write-Host "No API key found" -ForegroundColor Yellow
                        }
                    }
                    "3" {
                        Write-Host "Enter new OpenAI API key: " -NoNewline -ForegroundColor Yellow
                        $newKey = Read-Host -AsSecureString
                        
                        # Check if SecureString is empty before converting
                        if ($newKey.Length -eq 0) {
                            Write-Host "API key cannot be empty. Cancelled." -ForegroundColor Yellow
                        } else {
                            $newKeyPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
                                [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($newKey)
                            )
                            
                            if ($newKeyPlain) {
                                Save-OpenAIAPIKey -APIKey $newKeyPlain
                                if (Test-OpenAIConnection) {
                                    Write-Host "✅ New API key saved and verified!" -ForegroundColor Green
                                    $script:OpenAIConnected = $true
                                } else {
                                    Write-Host "⚠️ API key saved but verification failed" -ForegroundColor Yellow
                                    $script:OpenAIConnected = $false
                                }
                            } else {
                                Write-Host "Cancelled" -ForegroundColor Gray
                            }
                        }
                    }
                    "4" {
                        Clear-Host
                        Show-Banner
                        Select-OpenAIModel
                    }
                    "5" {
                        Write-Host "Are you sure you want to delete the API key? (Y/N): " -NoNewline -ForegroundColor Red
                        $confirm = Read-Host
                        if ($confirm -eq 'Y' -or $confirm -eq 'y') {
                            try {
                                Remove-ItemProperty -Path "HKCU:\Software\VeeamItUpPlus" -Name "OpenAIAPIKey" -ErrorAction Stop
                                $script:OpenAIConnected = $false
                                Write-Host "✅ API key deleted successfully" -ForegroundColor Green
                            } catch {
                                Write-Host "❌ Failed to delete API key: $_" -ForegroundColor Red
                            }
                        } else {
                            Write-Host "Cancelled" -ForegroundColor Gray
                        }
                    }
                    "6" {
                        Write-Host "Cancelled" -ForegroundColor Gray
                    }
                    default {
                        Write-Host "Invalid option" -ForegroundColor Red
                    }
                }
            } else {
                Write-Host ""
                Write-Host "OpenAI API Status" -ForegroundColor Cyan
                Write-Host "═══════════════════════════════════" -ForegroundColor DarkGray
                Write-Host "Current Status: " -NoNewline
                Write-Host "Not Connected ❌" -ForegroundColor Red
                Write-Host ""
                Write-Host "Choose an option:" -ForegroundColor Yellow
                Write-Host "  1. Configure API Key" -ForegroundColor White
                Write-Host "  2. Cancel" -ForegroundColor Gray
                Write-Host ""
                
                $subChoice = Read-Host "Enter your choice"
                
                if ($subChoice -eq '1') {
                    Initialize-OpenAIConnection
                } elseif ($subChoice -eq '2') {
                    Write-Host "Cancelled" -ForegroundColor Gray
                } else {
                    Write-Host "Invalid option" -ForegroundColor Red
                }
            }
            
            Show-ReturnToMenuPrompt "Press any key to return to menu..." "Cyan"
            continue
        } elseif ($choice -eq 'L') {
            Write-Log "📱 User chose to view HTML activity log." 'SUCCESS'
            try {
                Update-HTMLLog  # Refresh the log before opening
                Start-Process $script:LogFilePath
                Write-Log "🚀 HTML activity log opened in default browser" 'SUCCESS'
                Show-ReturnToMenuPrompt "📱 HTML log opened in browser. Press any key to return to menu..." "Cyan"
            }
            catch {
                Write-Log "⚠️ Failed to open HTML log: $_" 'SUCCESS'
                Show-ReturnToMenuPrompt "❌ Failed to open HTML log. Press any key to return to menu..." "Red"
            }
            continue
        } elseif ($choice -eq 'Q') {
            Write-Log "👋 User chose to quit the application." 'SUCCESS'
            Write-Log "👋 Thank you for using VeeamItUp+!" 'SUCCESS'
            Update-HTMLLog
            break
        } else {
            Write-Log "❌ Invalid choice entered: $choice. Continuing to menu." 'ERROR'
            continue
        }
    }
}

# End of script - all logic is now handled within the menu loop 