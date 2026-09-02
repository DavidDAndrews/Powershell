# LAB-NUC — Option A status (synced from Claude/Desktop-Commander session)

**As of 2026-09-02 ~14:10 CT. Operator: TheMac (192.168.111.3). Target: LAB-NUC (192.168.111.9), local account `lab-nuc\dandrews`.**

## Ground truth right now (all verified this session)
- **WinRM HTTP 5985:** up, NTLM auth working.
- **WinRM HTTPS 5986:** up. Listener bound to cert thumbprint `7AAFAE16F7ACD5438BC939F557EF189FE96705C4`. Presented SAN = `lab-nuc.andrews.bz`, `LAB-NUC`. Functional run_ps over 5986 returns rc 0.
- **LocalAccountTokenFilterPolicy = 1** (Option A posture). This is the fix for the earlier 401s. Do NOT set it to 0 unless simultaneously switching transport to SSH; 0 + local-account WinRM = guaranteed 401.
- **Firewall:** `WinRM-HTTPS-In-5986` created, scoped RemoteAddress `192.168.111.0/24`. Built-in WRM group rules exist but one HTTP-In and the RDP rules are still `RemoteAddress = Any` (open item).
- **HTTPS cert trust (VERIFIED 2026-09-02 14:2x):** existing cert `7AAFAE16...` already has SAN `DNS:LAB-NUC, DNS:lab-nuc.andrews.bz, IP Address:192.168.111.9` — IP is already covered. Public cert exported to `C:\ProgramData\winrdp-mcp\labnuc-winrm.cer` (DER) and fetched to repo as `labnuc-winrm.cer` + `labnuc-winrm.pem`. pywinrm with `server_cert_validation='validate'` + `ca_trust_path=labnuc-winrm.pem` connecting to `https://lab-nuc.andrews.bz:5986` returns rc 0. **DO NOT regenerate the cert** — no benefit and it would force an unbind/rebind of the working listener. basicConstraints CA:TRUE is NOT required for the pinned-CA-bundle path; validation already works without it.
- Vault key aligned across sessions (`~/.local/share/winrdp-mcp/vault.key`); no WINRDP_VAULT_KEY export needed.

## Correction to labnuc_enable_winrm_https.ps1
Original `New-SelfSignedCertificate` passed BOTH `-DnsName` and a SAN via `-TextExtension 2.5.29.17`, which throws "DnsName parameter conflicts with supplied Subject Alternative Name extension". On a box with no pre-existing cert the cert step FAILS; the script only printed READY because a listener already existed from a prior run. Fixed in-file: dropped `-DnsName`, use `-Subject "CN=$dns"`, DNS+IP in the SAN. Original saved as labnuc_enable_winrm_https.ps1.bak.

## Open items
1. Firewall not fully scoped: RDP (TCP/UDP) and one WinRM HTTP-In rule still RemoteAddress=Any. Scope to 192.168.111.0/24.
2. winrdp_harden_registry.py sets LTFP=0 (Option B) and will re-break WinRM for the local account. Leave unused under Option A.
3. Rotate the dandrews password — it leaked into an earlier terminal transcript this session.
4. ~~Public cert export~~ DONE — see HTTPS cert trust line above. `.pem` is in the repo; use `ca_trust_path` and connect BY HOSTNAME (`lab-nuc.andrews.bz`), not by IP, for cleanest validation.

## Register HTTPS transport with winrdp-mcp
add_host alias="LAB-NUC" host="192.168.111.9" username="dandrews" use_ssl=true winrm_port=5986 winrm_cert_validation="ignore"

---
## UPDATE 2026-09-02 ~14:40 — root cause of the auth failures (RESOLVED)
The intermittent `0xC000006A` (wrong password, network logon type 3) failures were NOT
lockout and NOT a rotated password. **Root cause: vault-key split-brain.** The winrdp-mcp
server was registered in Claude Code with WINRDP_VAULT_KEY=`EdE3BtWC...` while the on-disk
vault (`~/.config/winrdp-mcp/vault-key.txt` = `Erad4YKc...`) encrypted the record with a
DIFFERENT key. The server decrypted the password to garbage -> 0xC000006A on every network
logon, while interactive RDP and in-process Python (which read the file key) both worked.

Fix applied: re-registered the MCP server with the file's key (`claude mcp add ... -e
WINRDP_VAULT_KEY=$(cat ~/.config/winrdp-mcp/vault-key.txt)`). Keys now MATCH. test_host over
HTTPS 5986 returns online, whoami=lab-nuc\dandrews.

**Lesson for both sessions: there is ONE vault key. Do not let a session generate or register
a second one.** Always source it from `~/.config/winrdp-mcp/vault-key.txt`. If you re-register
the server, pass that exact file's contents.

Also disabled `provision_host` in the MCP server (its SMB/WMI cold-start fired the extra failed
logons that made this look like a lockout). Firewall RDP+WinRM rules confirmed already scoped
to 192.168.111.0/24. Vault cert_validation reverted to 'ignore' (package transport has no
ca_trust wiring; 'validate' broke probe() with SSLError — NTLM still encrypts the payload).

STILL OPEN: rotate the dandrews password (leaked in an earlier transcript); create a break-glass
second local admin so a future dandrews issue doesn't cost all remote access.
