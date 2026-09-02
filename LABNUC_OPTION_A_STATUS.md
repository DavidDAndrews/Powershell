# LAB-NUC — Option A status (synced from Claude/Desktop-Commander session)

**As of 2026-09-02 ~14:10 CT. Operator: TheMac (192.168.111.3). Target: LAB-NUC (192.168.111.9), local account `lab-nuc\dandrews`.**

## Ground truth right now (all verified this session)
- **WinRM HTTP 5985:** up, NTLM auth working.
- **WinRM HTTPS 5986:** up. Listener bound to cert thumbprint `7AAFAE16F7ACD5438BC939F557EF189FE96705C4`. Presented SAN = `lab-nuc.andrews.bz`, `LAB-NUC`. Functional run_ps over 5986 returns rc 0.
- **LocalAccountTokenFilterPolicy = 1** (Option A posture). This is the fix for the earlier 401s. Do NOT set it to 0 unless simultaneously switching transport to SSH; 0 + local-account WinRM = guaranteed 401.
- **Firewall:** `WinRM-HTTPS-In-5986` created, scoped RemoteAddress `192.168.111.0/24`. Built-in WRM group rules exist but one HTTP-In and the RDP rules are still `RemoteAddress = Any` (open item).
- Vault key aligned across sessions (`~/.local/share/winrdp-mcp/vault.key`); no WINRDP_VAULT_KEY export needed.

## Correction to labnuc_enable_winrm_https.ps1
Original `New-SelfSignedCertificate` passed BOTH `-DnsName` and a SAN via `-TextExtension 2.5.29.17`, which throws "DnsName parameter conflicts with supplied Subject Alternative Name extension". On a box with no pre-existing cert the cert step FAILS; the script only printed READY because a listener already existed from a prior run. Fixed in-file: dropped `-DnsName`, use `-Subject "CN=$dns"`, DNS+IP in the SAN. Original saved as labnuc_enable_winrm_https.ps1.bak.

## Open items
1. Firewall not fully scoped: RDP (TCP/UDP) and one WinRM HTTP-In rule still RemoteAddress=Any. Scope to 192.168.111.0/24.
2. winrdp_harden_registry.py sets LTFP=0 (Option B) and will re-break WinRM for the local account. Leave unused under Option A.
3. Rotate the dandrews password — it leaked into an earlier terminal transcript this session.
4. Public cert exported on box at C:\ProgramData\winrdp-mcp\labnuc-winrm.cer; import to Mac trust store to use winrm_cert_validation="validate" on 5986.

## Register HTTPS transport with winrdp-mcp
add_host alias="LAB-NUC" host="192.168.111.9" username="dandrews" use_ssl=true winrm_port=5986 winrm_cert_validation="ignore"
