# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A PowerShell reimplementation of the Royal Apps Toolbox "Dynamic Folder" sample for **Pleasant Password Server**, adding modern authentication (SAML SSO via WebView2). It produces Royal TS import files (`.rdfx` / `.rdfe`) whose embedded scripts render the Pleasant folder tree in Royal TS and retrieve passwords on demand. Runtime target is **Windows PowerShell 5.1** — Royal TS runs the embedded scripts under the .NET-Framework Desktop edition, not PowerShell 7.

## Build

The `dist/` files are **generated** — never edit them by hand. Edit `src/` then rebuild:

```bash
powershell -ExecutionPolicy Bypass -File build.ps1
```

`build.ps1` concatenates the source into two full scripts, runs a strict ASCII transliteration + PowerShell parser syntax-check, and emits:
- `dist/Pleasant Password (PowerShell SSO).rdfx` — current XML format, the primary import
- `dist/Pleasant Password (PowerShell SSO).rdfe` — legacy JSON format for older Royal TS
- `dist/DynamicFolder.full.ps1` / `dist/DynamicCredential.full.ps1` — the concatenated scripts, handy for debugging in an editor (replace the `$...$` tokens by hand to run standalone)

There is no test suite; verification is the parser check in `build.ps1` plus live debugging inside Royal TS.

## How the source assembles

Royal TS embeds two scripts per Dynamic Folder — a **Folder Script** (renders the tree) and a **Dynamic Credential Script** (fetches one password). `build.ps1` builds each by concatenating:

```
Header.<Kind>.ps1  +  Common.ps1  +  WebClientMode.ps1  +  Body.<Kind>.ps1
```

- **`Header.*.ps1`** — sets `$Config` from Royal TS replacement tokens (`$CustomProperty.X$`, `$EffectiveUsername$`, `$EffectivePassword$`, `$DynamicCredential.EffectiveID$`). These tokens are substituted by Royal TS *before* execution.
- **`Common.ps1`** — shared core: config validation, HTTP wrappers, DPAPI token/cookie cache, WebView2 SDK bootstrap, and all three auth flows. Holds `$script:BuildTag` (see below).
- **`WebClientMode.ps1`** — the cookie-mode implementation against the internal WebClient API.
- **`Body.*.ps1`** — the entry point: calls `Initialize-Config` / `Initialize-Http`, branches on `$Config.AuthMode`, and emits rJSON (folder) or a `{ Password }` JSON (credential).

### `$script:BuildTag` in Common.ps1

Bump this string (currently `v13`) on **every** change to the embedded script. Royal TS does **not** refresh the embedded script when you re-import an `.rdfx` over an existing Dynamic Folder — the old script keeps running. The build tag is logged on the first debug-log line so you can confirm which version Royal TS actually executed. If a change "did nothing", suspect a stale script first.

## Authentication modes (Custom Property "Auth Mode")

The core complexity of this repo is that Pleasant's REST API officially supports only the OAuth2 **Resource Owner Password Grant** — no authorization-code / SAML flow. On a server with enforced Entra SAML SSO and password-grant disabled, there is no client-side way to obtain a REST bearer token. Hence three modes:

- **`WebClient`** — SAML login via WebView2, then reuse the **session cookie** against the internal WebClient endpoints (`/WebClient/Main/GetTree`, `POST /WebClient/CredentialListGrid/Select` with `__RequestVerificationToken`, `/WebClient/Main/CopyPasswordPopup`). Works on SSO-enforced servers but is slow (one GetTree+Grid roundtrip per folder). This is the practical fallback for our server.
- **`SSO`** — OAuth2 Authorization Code + PKCE, reverse-engineered from the KeePass HUB client (`client_id={2279DD22-...}` with braces, `redirect_uri=kp4pps://callback`, `/oauth2/authorize` → intercept the `kp4pps://` callback in WebView2 → exchange code at `/OAuth2/Token`). Yields a real REST bearer for the fast `/api/v5/rest/folders/` single-call tree. **Known unresolved issue:** the token exchange returns HTTP 400 "code_verifier required (PKCE)" — see below.
- **`Password`** — classic password grant + `X-Pleasant-OTP` MFA header (the Python original's flow). Disabled on our server.

The `Body` files select the branch: `webclient` → `Get-WebClientStoreObjects` / `Get-WebClientPassword`; otherwise `Invoke-PleasantApi` against REST v5.

### Open problem: PKCE token exchange (SSO mode)

`Get-TokenViaAuthCodePkce` completes the SAML login and obtains an auth code (`pkce_ok=True`), but `/OAuth2/Token` returns 400 "Proof Key for Code Exchange (PKCE) code_verifier required" even when `code_verifier` is provably in the request. A consumed code then yields `invalid_grant`, so the correct encoding must be sent on the **first** attempt. The `Common.ps1` code logs `Callback query:` and `Token POST body:` to aid diagnosis. The definitive next step is capturing the real KeePass client's `POST /OAuth2/Token` (Fiddler with HTTPS decrypt) to see the exact parameter placement.

## Critical constraints

- **No confidential data in the repo, ever.** No real hostnames, tenant IDs, GUIDs, or credentials in source, docs, or commits. `docs/SERVER-FINDINGS.md` is deliberately anonymized. This is a hard requirement.
- **Debug logs must be in English** (per project owner). Log via `Write-DebugLog`; output goes to `%LOCALAPPDATA%\RoyalTS-PleasantPPS\debug.log` only when Custom Property "Debug Log" = Yes.
- **ASCII-only embedded scripts.** Royal TS passes scripts to PS 5.1 without a BOM, so it assumes ANSI and umlauts/typographic chars break the syntax. `build.ps1`'s `ConvertTo-Ascii` transliterates and hard-fails if any non-ASCII survives. Keep `src/*.ps1` saved as UTF-8 **with BOM**.
- **PS 5.1 quirks to respect:** error bodies come from `$_.ErrorDetails.Message` (not the response stream); hashtable form-POST bodies silently drop fields, so form posts use a raw `HttpWebRequest` with `Expect100Continue=$false`; `Invoke-Http` is a non-throwing wrapper that returns `{ Ok; Status; Content; Headers }`.

## WebView2

SSO/WebClient modes need the managed WebView2 **SDK wrapper** DLLs (net462). The Evergreen **Runtime** is already present on any machine with Edge/Teams. The scripts auto-download the SDK from nuget.org to `%LOCALAPPDATA%\RoyalTS-PleasantPPS\lib` on first SSO run; `tools/Install-WebView2Sdk.ps1` covers offline setup, and `PLEASANT_WEBVIEW2_DIR` can override the path.

## Runtime state locations

- `%LOCALAPPDATA%\RoyalTS-PleasantPPS\` — app dir
  - `debug.log` — debug output
  - `lib\` — auto-downloaded WebView2 SDK
  - DPAPI-encrypted token/cookie cache (current Windows user scope)
  - persistent WebView2 profile (enables silent SSO on token expiry)

## Repo layout

```
src/        source scripts (edit here)
build.ps1   generator (run after any src change)
dist/       generated artifacts (do not edit)
tools/      Install-WebView2Sdk.ps1, discover-webclient-api.js (WebClient endpoint discovery)
docs/       SERVER-FINDINGS.md (anonymized server analysis), TROUBLESHOOTING.md
```

Remote: https://github.com/thammi96/royal-pleasant
