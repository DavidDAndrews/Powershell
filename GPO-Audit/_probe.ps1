Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'
Import-Module GroupPolicy -UseWindowsPowerShell -WarningAction SilentlyContinue
$g = Get-GPO -All | Select-Object -First 1
try {
    $p = @(Get-GPPermission -Guid $g.Id -All -EA Stop)
    "perm count=$($p.Count)"
    if ($p.Count -gt 0) { "perm0 props: $(($p[0].PSObject.Properties).Name -join ',')" }
} catch { "perm ERR: $_" }

$dom = $env:USERDNSDOMAIN
$path = "\\$dom\SYSVOL\$dom\Policies\{$($g.Id)}\GPT.INI"
"gpt=$path"
if (Test-Path $path) { Get-Content $path } else { 'GPT missing' }

# LDAP gpLink sample
$root = [adsi]"LDAP://DC=$($dom.Replace('.', ',DC='))"
"gpLink sample: $($root.Properties['gpLink'])"
