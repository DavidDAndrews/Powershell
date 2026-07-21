# GPO-Audit

A production-quality PowerShell audit tool for Group Policy Objects in Active Directory.
Audits every GPO affecting a target computer and optional user. Generates HTML, CSV, JSON,
and XML reports with categorised security findings.

## Required Permissions

| Feature | Minimum Role |
|---|---|
| Run the script | **Local Administrator** on the machine running the script |
| `gpresult` for own account | Standard domain user |
| Remote RSOP / remote event logs | Local admin on the **target** computer |
| Read GPO metadata, `Get-GPO -All` | Standard domain user (Authenticated Users read) |
| Full ACL audit, `Get-GPPermission` | Delegated GPO Read or Domain Admin |
| SYSVOL access, GPT.INI comparison | Authenticated Users (default) |
| cpassword SYSVOL scan | Domain user with SYSVOL read |
| RSAT installation | Local admin + Windows Update / internet |

> **PowerShell 5.1 is strongly preferred.** The `GroupPolicy` module is a Windows PowerShell
> binary module. In PS 7 the script tries `Import-Module GroupPolicy -UseWindowsPowerShell`
> but this shim can fail on complex cmdlets. Run in `powershell.exe` for full compatibility.

## Structure

```
GPO-Audit/
├── Invoke-GPOAudit.ps1    # Full audit entry point (production script)
├── GPO-Audit.psd1         # Module manifest
├── GPO-Audit.psm1         # Root module (auto-loads Public/Private)
├── Public/
│   └── Get-GPOInventory.ps1   # Exported: retrieves GPO inventory with link data
├── Private/
│   └── Resolve-GPOLinks.ps1   # Internal: parses GPO XML report for link details
└── README.md
```

## Usage — Invoke-GPOAudit.ps1

All examples require an elevated PowerShell 5.1 (`powershell.exe`) session.

### Local computer audit (installs RSAT if missing)

```powershell
.\Invoke-GPOAudit.ps1 -InstallPrerequisites -IncludeDomainInventory -IncludeEventLogs
```

### Remote computer audit with user RSOP

```powershell
.\Invoke-GPOAudit.ps1 `
    -ComputerName PC123 `
    -UserName 'DOMAIN\User1' `
    -IncludeDomainInventory `
    -IncludeEventLogs `
    -OutputPath C:\Audits\PC123
```

### Domain-only inventory (no remote RSOP)

```powershell
.\Invoke-GPOAudit.ps1 `
    -IncludeDomainInventory `
    -SkipRemoteRSOP
```

### Full audit with alternate credentials

```powershell
$Credential = Get-Credential
.\Invoke-GPOAudit.ps1 `
    -ComputerName PC123 `
    -Credential $Credential `
    -IncludeDomainInventory
```

### Full security audit

```powershell
.\Invoke-GPOAudit.ps1 `
    -IncludeDomainInventory `
    -IncludeSecurityAudit `
    -IncludeEventLogs `
    -OpenReport
```

## Output

Reports are written to `C:\GPOAudit\<ComputerName>_yyyyMMdd_HHmmss\` (or `-OutputPath`):

```
Summary\GPOAudit_Report.html     # Master HTML report (embedded CSS, portable)
Summary\Findings_Summary.txt     # Plain-text findings by severity
RSOP\gpresult_R.txt / Z / H / X  # All gpresult output formats
RSOP\RSOP_GPModule.xml           # Get-GPResultantSetOfPolicy output
EventLogs\GP_Operational_Events.csv
DomainGPOs\HTML\<name>.html      # Per-GPO HTML report
DomainGPOs\XML\<name>.xml        # Per-GPO XML report
RawData\GPO_Inventory.csv / .json
RawData\GPO_Links.csv / .json
RawData\GPO_Permissions.csv      # (with -IncludeSecurityAudit)
RawData\WMI_Filters.csv
RawData\SYSVOL_Consistency.csv
RawData\Findings.csv / .json
Logs\Transcript.log
Logs\Audit_Execution.log
```

## Findings Severity

| Level | Examples |
|---|---|
| Critical | cpassword in SYSVOL or GPO, MS14-025 |
| High | No Apply GP permission, broken WMI filter, SYSVOL mismatch, unresolved SIDs |
| Medium | Unlinked GPOs, enforced links, Block Inheritance, connectivity failures |
| Low | Empty GPOs, disabled GPOs, stale GPOs, disabled links |
| Informational | No description, recently modified, partially disabled |

## Module Usage (Get-GPOInventory)

```powershell
Import-Module .\GPO-Audit.psd1

# Basic inventory
Get-GPOInventory

# Include link details (slower — one XML report per GPO)
Get-GPOInventory -IncludeLinks | Where-Object LinkCount -eq 0

# Export to CSV
Get-GPOInventory -IncludeLinks | Export-Csv -Path .\GPOInventory.csv -NoTypeInformation
```

## Development

Add public functions as individual `.ps1` files in `Public\` — the module exports them automatically.  
Add internal helpers to `Private\`.

## Version History

| Version | Date       | Notes |
|---------|------------|-------|
| 1.0.0   | 2026-07-21 | Production audit script |
| 0.1.0   | 2026-07-21 | Initial scaffold |
