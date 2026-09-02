#!/usr/bin/env python3
"""Re-apply registry hardening on LAB-NUC and report host status."""
import json
from winrdp_mcp.context import Context

HOST = "LAB-NUC"
REGPATH = r"HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"


def main() -> None:
    ctx = Context()

    # Step 1: (re)provision-free direct registry hardening.
    # Bootstrap forces LocalAccountTokenFilterPolicy=1; remediation requires 0.
    apply_script = (
        f"Set-ItemProperty -Path '{REGPATH}' -Name LocalAccountTokenFilterPolicy "
        f"-Value 0 -Type DWord -Force | Out-Null;"
        f"(Get-ItemProperty -Path '{REGPATH}' -Name LocalAccountTokenFilterPolicy)"
        ".LocalAccountTokenFilterPolicy"
    )
    res = ctx.exec_ps(apply_script, host=HOST)
    value = res.stdout.strip()

    # Step 2: status summary.
    status_script = (
        "if(Test-Path 'HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System'){"
        "$p = Get-ItemProperty -Path 'HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System' -Name LocalAccountTokenFilterPolicy -ErrorAction SilentlyContinue;"
        "$uac = Get-ItemProperty -Path 'HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System' -Name EnableLUA -ErrorAction SilentlyContinue;"
        "$svc = Get-Service WinRM -ErrorAction SilentlyContinue;"
        "[pscustomobject]@{"
        "  LocalAccountTokenFilterPolicy = $p.LocalAccountTokenFilterPolicy;"
        "  EnableLUA = $uac.EnableLUA;"
        "  WinRM_Status = $svc.Status;"
        "  WinRM_StartType = $svc.StartType;"
        "  HostName = $env:COMPUTERNAME;"
        "  User = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name"
        "} | ConvertTo-Json -Compress}"
    )
    raw = ctx.exec_ps(status_script, host=HOST)
    status = json.loads(raw.stdout.strip())

    print("LocalAccountTokenFilterPolicy (set & read back):", value)
    print("Host status:", json.dumps(status, indent=2))
    print("rc:", res.rc, "| status_rc:", raw.rc)


if __name__ == "__main__":
    main()
