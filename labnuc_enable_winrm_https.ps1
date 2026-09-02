# LAB-NUC Option A bootstrap — run ONCE in an ELEVATED PowerShell over RDP.
# Idempotent. After it prints WINRM_HTTPS_READY, WinRM is manageable over HTTP(5985)
# scoped to the operator subnet, and over HTTPS(5986) with a server cert.
$ErrorActionPreference = 'Continue'
$dns  = 'LAB-NUC.andrews.bz'
$ip   = '192.168.111.9'
$subnet = '192.168.111.0/24'

# 1) Full token for the local admin over the network (THE fix for the 401s).
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
  -Name LocalAccountTokenFilterPolicy -Value 1 -Type DWord -Force | Out-Null

# 2) Make sure WinRM is on, automatic, and the firewall is open on 5985.
try { Get-NetConnectionProfile | Where-Object { $_.NetworkCategory -eq 'Public' } |
      Set-NetConnectionProfile -NetworkCategory Private -ErrorAction SilentlyContinue } catch {}
Enable-PSRemoting -Force -SkipNetworkProfileCheck
Set-Service WinRM -StartupType Automatic
Start-Service WinRM
winrm quickconfig -quiet -force 2>$null

# 3) Self-signed cert for the HTTPS listener. SAN covers both DNS name and the IP
#    we actually connect to, so client-side cert validation can match.
$cert = Get-ChildItem Cert:\LocalMachine\My |
        Where-Object { $_.Subject -like "*$dns*" -or $_.DnsNameList -contains $dns } |
        Select-Object -First 1
if (-not $cert) {
  # NOTE: -DnsName and a SAN via -TextExtension(2.5.29.17) are mutually exclusive;
  # New-SelfSignedCertificate throws "DnsName parameter conflicts with supplied
  # Subject Alternative Name extension". Put BOTH the DNS name and the IP in the
  # SAN TextExtension and drop -DnsName. (Verified on LAB-NUC, Win11 25H2, 2026-09-02.)
  $cert = New-SelfSignedCertificate `
    -Subject "CN=$dns" `
    -CertStoreLocation Cert:\LocalMachine\My `
    -NotAfter (Get-Date).AddYears(3) `
    -TextExtension @("2.5.29.17={text}DNS=$dns&DNS=LAB-NUC&IPAddress=$ip") `
    -KeyExportPolicy Exportable `
    -KeyUsage KeyEncipherment,DigitalSignature `
    -KeyAlgorithm RSA -KeyLength 2048
}
"Cert thumbprint: $($cert.Thumbprint)"

# 4) Bind the cert to the WSMan HTTPS listener (only if not already present).
$listeners = winrm enumerate winrm/config/listener
if ($listeners -notmatch 'Transport = HTTPS') {
  $sel = 'winrm/config/Listener?Address=*+Transport=HTTPS'
  winrm create $sel "@{Hostname='$dns'; CertificateThumbprint='$($cert.Thumbprint)'}"
} else {
  "HTTPS listener already present"
}

# 5) Firewall: allow 5986 (HTTPS) and ensure 5985 (HTTP) both scoped to the operator subnet.
New-NetFirewallRule -DisplayName 'WinRM-HTTPS-In-5986' -Name 'WinRM-HTTPS-In-5986' `
  -Direction Inbound -Protocol TCP -LocalPort 5986 -Action Allow `
  -RemoteAddress $subnet -Profile Any -Enabled True -ErrorAction SilentlyContinue | Out-Null
foreach ($r in (Get-NetFirewallRule -DisplayName 'Windows Remote Management' -ErrorAction SilentlyContinue)) {
  $r | Set-NetFirewallRule -Enabled True -ErrorAction SilentlyContinue
  $r | Get-NetFirewallAddressFilter | Set-NetFirewallAddressFilter -RemoteAddress $subnet -ErrorAction SilentlyContinue
}
$r5985 = Get-NetFirewallRule -DisplayName 'WinRM-HTTP-In-5985' -ErrorAction SilentlyContinue
if ($r5985) {
  $r5985 | Set-NetFirewallRule -Enabled True -ErrorAction SilentlyContinue
  $r5985 | Get-NetFirewallAddressFilter | Set-NetFirewallAddressFilter -RemoteAddress $subnet -ErrorAction SilentlyContinue
}

# 6) Export the PUBLIC cert (.cer) so the client can build its CA trust bundle.
$exportDir = 'C:\ProgramData\winrdp-mcp'
New-Item -ItemType Directory -Path $exportDir -Force | Out-Null
$cerPath = Join-Path $exportDir 'labnuc-winrm.cer'
Export-Certificate -Cert $cert -FilePath $cerPath -Type CERT -Force | Out-Null
"Cert exported: $cerPath"

# 7) Verify.
winrm enumerate winrm/config/listener
Get-Service WinRM | Format-Table -AutoSize Status,StartType
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
  -Name LocalAccountTokenFilterPolicy | Select-Object LocalAccountTokenFilterPolicy | Format-List
Write-Output 'WINRM_HTTPS_READY'
