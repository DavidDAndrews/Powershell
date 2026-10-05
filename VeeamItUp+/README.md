# VeeamItUp+

Menu-driven PowerShell tool for analyzing Veeam backup repositories on one or more file servers. For each saved server profile it maps the share to a drive letter, scans for Veeam backup files (`.vbk`, `.vib`, `.vrb`) and VBM metadata, checks backup chains, retention and GFS compliance, and writes an interactive HTML report with charts and storage recommendations. Reports can optionally include OpenAI-generated analysis and be emailed over SMTP.

## Files

- `VeeamItUpPlus.ps1` - the tool (Windows PowerShell 5.1 or later). Run it with no parameters: `.\VeeamItUpPlus.ps1`
- `Test-VBMChainValidation.ps1` - stand-alone test of the VBM chain parser; reads `./DC01.vbm` from the current folder
- `DC01.vbm` - sample VBM metadata file (a real Veeam export, about 70 KB) used by that test
- `FileMetadata.html` - saved copy of a third-party article about Veeam metadata, kept as reference

## Menu

`1-N` select a saved server and run the report, `S` manage server profiles, `C` test connectivity, `D` delete server profiles, `L` view the HTML activity log, `M` configure SMTP, `K` manage the OpenAI API key, `Q` quit.

## Storage

- Server profiles, SMTP settings and the OpenAI key are kept under `HKCU:\Software\VeeamItUpPlus`; passwords and the API key are DPAPI-encrypted (current user).
- HTML activity logs (`VeeamItUpPlusLog-*.html`) are written to your Downloads folder; the newest three are kept.
