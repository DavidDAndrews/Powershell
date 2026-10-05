# Veeam Enterprise Reporter

A single-page web dashboard (plain HTML, CSS and JavaScript, no build step) for monitoring Veeam Backup & Replication jobs through the Veeam REST API. It shows job status, job details and recent session history.

## Files

| File | Purpose |
|---|---|
| `index.html` | The whole app: markup plus inline JavaScript that calls the Veeam REST API from the browser |
| `styles.css` | Styling for `index.html` |
| `proxy-server.js` | Optional Node.js CORS proxy (no dependencies) that forwards requests to one Veeam server |
| `vbr_rest_123_v12_rev1.txt` | Veeam B&R REST API OpenAPI specification (YAML, `version: 1.2-rev1`) used as a reference |

## Features

- **Connect form**: server address, port (default 9419), username and password; signs in with the OAuth2 password grant (`/api/oauth2/token`)
- **Summary cards**: Successful, Warning, Failed and Running job counts
- **Jobs table**: search by name, filter by type (Backup, Backup Copy, Replica) and status, **Export CSV** (`veeam-jobs-report.csv`)
- **Job details**: click **Details** for status, type, last/next run, repository, retention and the job's recent sessions (`/api/v1/sessions?jobIdFilter=...`, up to 100)
- **Remember credentials**: optional; stored in the browser's `localStorage` encrypted with AES-GCM, but the key is derived from a constant in `index.html`, so treat this as obfuscation rather than protection. **Clear Saved** removes them.

The app sends `x-api-version: 1.0-rev2` (`1.0-rev1` for `/api/v1/backups/` and `/api/v1/backupObjects/` paths).

## Usage

1. Open `index.html` in a browser (or serve the folder with any static web server).
2. Enter the Veeam server details and click **Connect**.

The page always connects over HTTPS directly from the browser, so the Veeam server's certificate must be trusted by the browser, and the browser may block the requests because of CORS.

### CORS proxy

`proxy-server.js` listens on `http://localhost:3000` and forwards every request to the Veeam server set in its `VEEAM_SERVER` / `VEEAM_PORT` constants (edit them first), adding permissive CORS headers and accepting self-signed certificates:

```bash
node proxy-server.js
```

Note: the proxy speaks plain HTTP, while `index.html` always uses `https://`. Using the proxy as-is therefore needs the page's protocol changed (see `protocol: 'https'` in `handleConnection`).

## Requirements

- A modern browser (uses `fetch` and the Web Crypto API)
- Veeam Backup & Replication with the REST API enabled (port 9419 by default)
- Node.js, only for the optional proxy
