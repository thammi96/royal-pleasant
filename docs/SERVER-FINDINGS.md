# Auth-Analyse: Pleasant 9.x mit erzwungenem SAML-SSO

Generische Zusammenfassung der Untersuchung an einem Pleasant Password Server
9.3.x (Enterprise Plus) mit erzwungenem Entra-ID/SAML-SSO. Alle Werte sind
anonymisiert – Servernamen, Tenant-IDs, GUIDs bewusst durch Platzhalter ersetzt.

## Ausgangslage

- Entra ID (Azure AD) SAML-SSO ist **erzwungen** (Enforce Partner Sign-in).
- Die Login-Seite bietet nur den SAML-Button, **kein** lokales Passwortfeld.
- Der Direct-Sign-In-Aufruf (`/Account/SignIn?directSignOn=True`) ist
  byte-identisch mit der normalen Seite → Direct-Sign-In-Ausnahme **nicht aktiv**.

## Beobachtetes Verhalten (anonymisiert)

| Prüfung | Ergebnis | Bedeutung |
|---|---|---|
| `POST /OAuth2/Token` grant_type=**password** | `400 "password not supported"` | Password-Grant server­seitig deaktiviert |
| grant_type=**authorization_code** | `500` | nicht implementiert/aktiv |
| grant_type=**client_credentials** | `400 "not supported"` | nicht unterstützt |
| grant_type=**refresh_token** | `500` | nicht implementiert/aktiv |
| grant_type=**saml2-bearer** / **jwt-bearer** | `400 "not supported"` | **kein Token-Exchange aus SAML/JWT** |
| `/.well-known/openid-configuration` | `404` | keine OIDC-Discovery |
| `GET /api/v5\|v6\|v7/rest/folders` | `401` | REST-API aktiv, aber nur mit Bearer |
| `GET /api/v4/...` | `404` | v4 in Pleasant 9 entfernt |
| `GET /WebClient` | `404` | falscher Pfad |
| `GET /WebClient/Main` | `302 → Login` | **WebClient liegt unter `/WebClient/Main`** |
| WebClient nach SSO-Login | funktioniert | eigene interne API, **Cookie-Session** |

## Kernproblem

Die REST-API (`/api/v5+`) akzeptiert **nur** OAuth2-Bearer-Tokens. Bearer-Tokens
gibt es **nur** über den Password-Grant – und der ist bei erzwungenem SSO
deaktiviert. Es existiert **kein** SAML-/JWT-Bearer-Grant und **kein**
Authorization-Code-Flow, mit dem sich der Entra-Token in ein API-Token tauschen
ließe. Mit erzwungenem SSO ohne lokale Anmeldung gibt es damit **keinen
client-seitig erreichbaren API-Zugang**.

Der WebClient funktioniert, benutzt aber seine **eigene interne API** mit
Session-Cookie (nicht die öffentliche REST-API). Deren Endpunkte werden
server-seitig als `action-url`-Attribute in den DOM gerendert und sind mit
Anti-Forgery-Tokens geschützt.

Konsequenz für die Auth-Modi dieses Projekts:

- **Auth Mode = Password**: nicht nutzbar, solange der Password-Grant aus ist.
- **Auth Mode = SSO (Bearer-Capture)**: greift nicht, weil der WebClient kein
  Bearer-Token gegen `/api/v5` verwendet, sondern eine Cookie-Session.

## Lösungswege

### A) Dedizierter API-/Service-Account mit Direct-Sign-In-Ausnahme  ← empfohlen
Admin-Aufgabe auf dem Pleasant-Server:

1. Lokalen Benutzer anlegen, z. B. `svc-royalts` (kein SSO-Konto).
2. **Authentication Policy** mit *Allow Exception For Direct Sign-In* = True
   diesem Konto/einer Rolle zuweisen.
3. **OAuth2 Password-Grant aktivieren** (ggf. nur für diese Policy/Rolle).
4. Dem Konto **Leserechte** auf die benötigten Ordner geben.

Danach läuft die Integration im **Auth Mode = Password** ohne Browser,
„always on", inkl. MFA-Header falls konfiguriert. Sauberster, wartbarer,
herstellerkonformer Weg.

### B) Cookie-Modus gegen die interne WebClient-API  (Fallback, fragil)
Nach SSO-Login im WebView die `action-url`-Endpunkte des WebClients mit der
Session-Cookie replayen (Baum + Passwort anzeigen). Undokumentiert,
DOM-/Anti-Forgery-abhängig, bricht bei Pleasant-Updates. Nur wenn A) nicht
durchsetzbar ist.

### C) SSO Proxy
Der „SSO Proxy"/„Proxy Server" von Pleasant ist eine Endanwender-Funktion zum
Starten/Ausfüllen von Web-Logins **durch** Pleasant – kein Auth-Mechanismus für
die REST-API. Für diese Integration nicht relevant.

## Empfehlung

Weg **A** als Arbeitsauftrag an die Pleasant-Admins formulieren (Service-Account
+ Policy-Ausnahme + Password-Grant aktivieren). Danach ist die Integration mit
dem vorhandenen Password-Mode sofort lauffähig. Weg B nur als Notlösung.
