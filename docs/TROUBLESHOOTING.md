# Troubleshooting

Erster Schritt bei jedem Problem: Custom Property **Debug Log = Yes** setzen und
`%LOCALAPPDATA%\RoyalTS-PleasantPPS\debug.log` beobachten.

## SSO-Modus

### „WebView2-SDK-Assemblies nicht gefunden/ladbar und Auto-Download fehlgeschlagen"
Normalfall: Beim ersten SSO-Lauf lädt das Skript die benötigten net462-DLLs
automatisch von nuget.org nach `%LOCALAPPDATA%\RoyalTS-PleasantPPS\lib`.
Schlägt das fehl (Proxy, kein Internet, nuget.org gesperrt):

- einmalig `tools\Install-WebView2Sdk.ps1` von einem Rechner mit Internet
  ausführen bzw. den `lib`-Ordner dorthin kopieren, oder
- einen eigenen Pfad über die Umgebungsvariable `PLEASANT_WEBVIEW2_DIR`
  setzen (Ordner muss `Microsoft.Web.WebView2.Core.dll`,
  `Microsoft.Web.WebView2.WinForms.dll` und `WebView2Loader.dll` enthalten).

Hintergrund: Die WebView2 Evergreen **Runtime** (Browser-Engine) ist über
Edge/Teams/Office praktisch überall vorhanden — es geht hier nur um die
managed **SDK-Wrapper**. Royal TS führt PowerShell-Skripte mit Windows
PowerShell 5.1 (.NET Framework) aus; die WebView2-DLLs, die Royal TS selbst
mitbringt, sind je nach Version .NET-(Core)-Builds und lassen sich dort nicht
laden — deshalb der separate SDK-Download.

### „WebView2-Initialisierung fehlgeschlagen"
WebView2 **Evergreen Runtime** fehlt (nicht zu verwechseln mit dem SDK):
https://developer.microsoft.com/microsoft-edge/webview2/ → Evergreen Bootstrapper.
Auf Windows 10/11 mit aktuellem Edge normalerweise vorhanden.

### Anmeldefenster erscheint, schließt sich aber nach Login nicht
Das Skript hat kein verwertbares Token aus der WebClient-Sitzung abfangen können.

1. Prüfen, ob unter `<Server URL>/WebClient` wirklich der Pleasant WebClient
   erreichbar ist und der Login dort durchläuft.
2. `Debug Log = Yes`: erscheinen Meldungen zu verworfenen Kandidaten?
3. Die Capture-Logik steckt komplett in `Get-TokenViaSso` (src/Common.ps1):
   - Weg 1: `WebResourceRequested` → `Authorization`-Header aller WebClient-Requests
   - Weg 2: Scan von session-/localStorage nach `access_token`/JWT-Mustern
   Falls eine neue Pleasant-Version das Token anders transportiert (z. B. nur
   Cookie-Session), muss hier nachgezogen werden. Debug-Ansatz: WebClient im
   normalen Browser öffnen, F12 → Network → prüfen, wie die API-Calls
   (`/api/v5/...`) authentifiziert werden.

### Fenster geht bei jedem Reload wieder auf
- `Use Token Cache = Yes` gesetzt?
- Token-Lebensdauer im Pleasant-Server sehr kurz konfiguriert? (Admin →
  Server-Einstellungen → Token-Lifetime). Nach Ablauf ist dank persistentem
  WebView2-Profil aber i. d. R. nur ein Silent-SSO-Durchlauf nötig.
- Cache-Datei löschbar unter `%LOCALAPPDATA%\RoyalTS-PleasantPPS\token-*.dat`
  (bei Bedarf einfach alles in dem Ordner außer `lib` löschen = „Logout").

## Password-Modus

### HTTP 400 beim Token-Abruf
Häufigste Ursache laut Pleasant-Doku: redundanter Domänenname im Benutzernamen
→ **Omit Domain = Yes** versuchen. Bei SSO-only-Konten schlägt der Password
Grant grundsätzlich fehl, außer im Pleasant-Server ist für das Konto
*„Allow Exception For Direct Sign-In"* aktiv → sonst **Auth Mode = SSO** verwenden.

### MFA-Dialog kommt nicht / Token-Fehler trotz korrektem OTP
Der Server signalisiert MFA über die Header `X-Pleasant-OTP: required` und
`X-Pleasant-OTP-Provider`. Mit `Debug Log = Yes` wird der Provider geloggt.
Back-Channel-Provider (SMS/E-Mail) brauchen ggf. zwei Anläufe (erst beim ersten
Request wird der Versand ausgelöst).

### Passwort mit Sonderzeichen
Royal TS ersetzt `$EffectivePassword$` textuell im Skript. Ein **einfaches
Anführungszeichen (`'`)** im Passwort bricht dadurch die Skript-Syntax.
Workaround: Passwort des API-Kontos ohne `'` wählen oder SSO-Modus nutzen.

## Allgemein

### Zertifikatsfehler (self-signed in Testumgebung)
`Ignore SSL Errors = Yes` — nur für Test! In Produktion sauberes Zertifikat.

### „Custom Property … ist nicht gesetzt"
Replacement-Tokens werden nur ersetzt, wenn die Custom Properties am Dynamic
Folder existieren und exakt so heißen wie im Import (Server URL, Auth Mode,
Omit Domain, Ignore SSL Errors, Use Token Cache, Debug Log).

### Skript im Editor testen (außerhalb von Royal TS)
`dist\DynamicFolder.full.ps1` in VS Code öffnen, im `$Config`-Block oben die
`$...$`-Tokens durch echte Werte ersetzen und ausführen. Ausgabe ist das
rJSON, das Royal TS erwartet. Analog `dist\DynamicCredential.full.ps1` mit
fester Credential-ID (GUID des Eintrags).
