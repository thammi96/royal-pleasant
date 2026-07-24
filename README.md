# Royal TS ⇄ Pleasant Password Server – Dynamic Folder (PowerShell, SAML SSO)

PowerShell-Neuimplementierung des [Royal Apps Toolbox-Samples](https://github.com/royalapplications/toolbox/tree/master/Dynamic%20Folder/Pleasant%20Password%20Server) für Pleasant Password Server – mit **moderner Authentifizierung**:

| | Python-Original (Toolbox) | Dieses Projekt |
|---|---|---|
| Sprache | Python 2/3 (+ pip-Module) | PowerShell 5.1 (keine Abhängigkeiten auf Zielsystem) |
| Auth | Nur OAuth2 Password Grant + OTP-Prompt | **SAML SSO via WebView2** und Password Grant + OTP |
| MFA | Tkinter-Eingabefenster | IdP-nativ (SSO) bzw. WinForms-Dialog (Password) |
| Token-Handling | Anmeldung bei **jedem** Abruf | **DPAPI-verschlüsselter Token-Cache**, Silent SSO |
| API | v4 + v5 | v5 (Pleasant 7.x+) |

## Hintergrund / Problemstellung

Die REST-API von Pleasant Password Server kennt offiziell **nur den OAuth2 Resource Owner Password Grant** ([Doku](https://pleasantpasswords.com/info/pleasant-password-server/m-programmatic-access/restful-api)). Einen Authorization-Code-Flow oder eine dokumentierte SAML-Integration für die API gibt es nicht – daran ist z. B. auch [Devolutions RDM gescheitert](https://forum.devolutions.net/topics/40098/pleasant-password-server--saml-sso-authentication). Seit bei uns SAML SSO erzwungen wird, funktioniert die alte Python-Integration deshalb nicht mehr.

**Lösungsansatz dieses Projekts (Auth Mode `SSO`):**

1. Beim ersten Zugriff öffnet das Skript ein WebView2-Fenster mit dem Pleasant **WebClient**.
2. Die Anmeldung läuft ganz normal über den IdP (SAML, MFA, Conditional Access – alles wie im Browser).
3. Der angemeldete WebClient ruft die REST-API mit einem Bearer-Token auf. Genau dieses Token wird abgefangen (primär aus den `Authorization`-Headern der WebClient-Requests, sekundär per Scan von session-/localStorage) und **gegen die API verifiziert**.
4. Das Token wird **DPAPI-verschlüsselt** gecacht (`%LOCALAPPDATA%\RoyalTS-PleasantPPS`). Reload des Ordners und jeder Passwort-Abruf laufen damit ohne erneute Anmeldung.
5. Das WebView2-Profil ist persistent → beim nächsten Token-Ablauf reicht i. d. R. ein **Silent SSO** (Fenster öffnet und schließt sich von selbst).

Für Umgebungen ohne SSO-Zwang (oder Konten mit *„Allow Exception For Direct Sign-In"*) gibt es weiterhin den klassischen Auth Mode `Password` inkl. MFA über die `X-Pleasant-OTP`-Header.

## Installation

### 1. Voraussetzungen

- Royal TS (V6/V7), Windows 10/11
- Pleasant Password Server 7.x+ (API v5)
- Für den SSO-Modus: WebView2 Evergreen **Runtime** — die ist auf praktisch jedem Windows-10/11-PC vorhanden (kommt mit Edge/Teams/Office mit), da muss nichts installiert werden.

Zusätzlich brauchen die Skripte die managed WebView2-**SDK-Wrapper** (net462-DLLs), weil Royal TS PowerShell-Skripte mit Windows PowerShell 5.1 ausführt. Die lädt das Skript **beim ersten SSO-Lauf automatisch** von nuget.org nach `%LOCALAPPDATA%\RoyalTS-PleasantPPS\lib`. Ohne Internetzugang/nuget.org: einmalig manuell

```bash
powershell -ExecutionPolicy Bypass -File tools/Install-WebView2Sdk.ps1
```

ausführen oder den Pfad per Umgebungsvariable `PLEASANT_WEBVIEW2_DIR` vorgeben.

### 2. Dynamic Folder importieren

`dist/Pleasant Password (PowerShell SSO).rdfx` in Royal TS importieren (**Data → Import → Dynamic Folder File (.rdfx)**). Für ältere Royal-TS-Versionen liegt zusätzlich das Legacy-Format `.rdfe` bei.

### 3. Custom Properties konfigurieren

| Property | Werte | Bedeutung |
|---|---|---|
| **Server URL** | z. B. `https://pwd.firma.tld:10001` | Basis-URL des Pleasant-Servers (ohne `/WebClient`) |
| **SSO Login URL** | leer = automatisch | Login-Seite fürs SSO-Fenster. Leer: erst `/WebClient`, bei 404 automatisch Server-Root (leitet z. B. auf `/Account/SignIn` um). Explizit setzen, wenn die Login-Seite woanders liegt. |
| **Auth Mode** | `SSO` \| `Password` | `SSO` = SAML via WebView2, `Password` = OAuth2 Password Grant |
| **Omit Domain** | Yes/No | Nur Password-Modus: Domäne aus dem Benutzernamen entfernen |
| **Ignore SSL Errors** | Yes/No | Zertifikatsprüfung deaktivieren (nur Test!) |
| **Use Token Cache** | Yes/No | DPAPI-Token-Cache verwenden (empfohlen: Yes) |
| **Debug Log** | Yes/No | Protokoll nach `%LOCALAPPDATA%\RoyalTS-PleasantPPS\debug.log` |

Im Modus `Password` müssen dem Dynamic Folder außerdem Zugangsdaten zugewiesen sein; im Modus `SSO` sind keine Zugangsdaten in Royal TS nötig.

### 4. Nutzung

- **Ordner laden:** Rechtsklick auf den Dynamic Folder → *Reload*. Beim ersten Mal (SSO) erscheint das Anmeldefenster; danach Silent SSO/Token-Cache.
- **Passwort-Abruf:** funktioniert wie gewohnt über Dynamic Credentials (Verbindung öffnen, Passwort kopieren, …).

## Sicherheit

- Tokens werden ausschließlich **DPAPI-verschlüsselt** (Scope: aktueller Windows-Benutzer) auf der Platte abgelegt – kein Klartext.
- Passwörter werden nie gespeichert; im SSO-Modus sieht das Skript das Passwort überhaupt nicht (Eingabe nur beim IdP).
- Der Token-Capture verifiziert jeden Kandidaten gegen die API, bevor er verwendet wird.
- `Ignore SSL Errors` nur für Testumgebungen verwenden.

## Repo-Struktur

```
src/                  Quell-Skripte (Header + gemeinsamer Kern + Body)
  Common.ps1          Auth (SSO/Password), Token-Cache, HTTP, API-Wrapper
  Header.*.ps1        Royal-TS-Replacement-Tokens → $Config
  Body.*.ps1          Ordnerbaum → rJSON bzw. Passwort-Abruf
build.ps1             Baut dist/*.rdfx + *.rdfe + Voll-Skripte, inkl. Syntax-Check
dist/                 Fertige Artefakte (rdfx zum Import, rdfe Legacy, Voll-Skripte zum Debuggen)
tools/                Install-WebView2Sdk.ps1 (nur nötig ohne Internet/nuget.org)
docs/                 Troubleshooting & technische Details
```

Änderungen bitte in `src/` machen und `build.ps1` ausführen – nicht direkt in `dist/` editieren.

## Debuggen in Royal TS

1. `Debug Log` auf `Yes` → `%LOCALAPPDATA%\RoyalTS-PleasantPPS\debug.log` beobachten.
2. Die Voll-Skripte `dist/DynamicFolder.full.ps1` / `dist/DynamicCredential.full.ps1` entsprechen 1:1 dem Inhalt der rdfe und lassen sich im Royal-TS-Script-Editor bzw. in VS Code testen (Replacement-Tokens von Hand ersetzen).
3. Details und bekannte Stolperstellen: [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)

## Bekannte Grenzen / Ausblick

- Der SSO-Token-Capture hängt am Verhalten des Pleasant WebClients (Bearer-Token in API-Requests). Bei künftigen Pleasant-Versionen ggf. anpassen – die Capture-Logik ist bewusst zweigleisig (Header + Storage-Scan) und zentral in `Get-TokenViaSso` gekapselt.
- Lesend (Ordner + Passwörter); Schreiben/Anlegen von Einträgen ist nicht Ziel eines Dynamic Folders.
- [Royal Server](https://www.royalapps.com/server/main/features) wäre der nächste Baustein (zentrale Bereitstellung, Secure Gateway); mit ZTNA als „Always on"-Basis ein sinnvoller Folgeschritt – siehe Kickoff-Thema.

## Referenzen

- [Royal Apps Toolbox – Pleasant Password Server (Python-Original)](https://github.com/royalapplications/toolbox/tree/master/Dynamic%20Folder/Pleasant%20Password%20Server)
- [Royal Apps Toolbox Issue #104 – OAuth2/MFA-Anfrage](https://github.com/royalapplications/toolbox/issues/104)
- [Pleasant REST-API](https://pleasantpasswords.com/info/pleasant-password-server/m-programmatic-access/restful-api) · [OAuth Two-Factor Support](https://pleasantpasswords.com/info/pleasant-password-server/m-programmatic-access/restful-api/oauth-two-factor-support)
- Interne Historie: ISSD-232 (ursprüngliche Integration 2020), ISSD-29725 (OAuth2/MFA-Anfrage 2024, damals verworfen)
