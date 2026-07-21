Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'
Import-Module GroupPolicy -UseWindowsPowerShell -WarningAction SilentlyContinue
$g = Get-GPO -All | Select-Object -First 1
$p = @(Get-GPPermission -Guid $g.Id -All -EA Stop)[0]
"Trustee type: $($p.Trustee.GetType().FullName)"
try { "Trustee.Name=$($p.Trustee.Name)" } catch { "Trustee.Name ERR $_" }
try { "Trustee.Sid=$($p.Trustee.Sid)" } catch { "Trustee.Sid ERR $_" }
try { "Permission=$($p.Permission)" } catch { "Permission ERR $_" }
$p.Trustee | Format-List * | Out-String
