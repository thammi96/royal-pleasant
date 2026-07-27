# ============================================================================
#  Royal TS Dynamic Folder Script - Pleasant Password Server (PowerShell)
#  Die $...$-Platzhalter werden von Royal TS vor der Ausfuehrung ersetzt
#  (Replacement Tokens). Hinweis: Passwoerter mit einfachem Anfuehrungszeichen
#  (') brechen die Ersetzung - siehe Doku.
# ============================================================================
$Config = @{
    ScriptKind       = 'Folder'
    ServerUrl        = '$CustomProperty.ServerURL$'
    SsoLoginUrl      = '$CustomProperty.SSOLoginURL$'
    AuthMode         = '$CustomProperty.AuthMode$'
    TokenVariant     = '$CustomProperty.TokenVariant$'
    OmitDomain       = '$CustomProperty.OmitDomain$'
    IgnoreSsl        = '$CustomProperty.IgnoreSSLErrors$'
    UseCache         = '$CustomProperty.UseTokenCache$'
    DebugLog         = '$CustomProperty.DebugLog$'
    Username         = '$EffectiveUsername$'
    UsernameNoDomain = '$EffectiveUsernameWithoutDomain$'
    Password         = '$EffectivePassword$'
}

# ============================================================================
#  Pleasant Password Server - Royal TS Dynamic Folder (PowerShell)
#  Gemeinsamer Kern: HTTP, Token-Cache (DPAPI), Password-Grant (+OTP/MFA),
#  SSO-Anmeldung ueber WebView2 (SAML im Browser, Token-Capture).
#
#  Diese Datei wird von build.ps1 in beide Skripte eingebettet
#  (Dynamic Folder Script und Dynamic Credential Script).
# ============================================================================

$ErrorActionPreference = 'Stop'

# Bump this whenever the embedded script changes, so the debug log shows
# unambiguously which version Royal TS is actually running.
$script:BuildTag = 'v18'

$script:IsPsCore = ($PSVersionTable.PSEdition -eq 'Core')
$script:AppDir   = Join-Path $env:LOCALAPPDATA 'RoyalTS-PleasantPPS'
if (-not (Test-Path $script:AppDir)) {
    New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null
}

# ---------------------------------------------------------------------------
# Logging (nur wenn Custom Property "Debug Log" = Yes)
# Jede Ausfuehrung schreibt eine EIGENE Datei unter ...\logs\ mit Zeitstempel
# im Namen - so laesst sich der Log eines einzelnen Versuchs sauber
# herauskopieren, ohne ihn aus einer wachsenden Sammeldatei zu fischen.
# ---------------------------------------------------------------------------
$script:LogDir  = Join-Path $script:AppDir 'logs'
$script:LogFile = $null

function Get-LogFilePath {
    if ($script:LogFile) { return $script:LogFile }
    try {
        if (-not (Test-Path $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null }
        $kind = if ($Config -and $Config.ScriptKind) { $Config.ScriptKind } else { 'Unknown' }
        $script:LogFile = Join-Path $script:LogDir ('{0:yyyy-MM-dd_HH-mm-ss}_{1}_pid{2}.log' -f (Get-Date), $kind, $PID)
        # Aeltere Logs aufraeumen (die neuesten 40 behalten)
        try {
            Get-ChildItem -Path $script:LogDir -Filter '*.log' -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -Skip 40 |
                Remove-Item -Force -ErrorAction SilentlyContinue
        } catch { }
    } catch {
        $script:LogFile = Join-Path $script:AppDir 'debug.log'
    }
    return $script:LogFile
}

function Write-DebugLog {
    param([string]$Message)
    if ($Config.DebugLog -ne 'Yes') { return }
    $line = '{0:yyyy-MM-dd HH:mm:ss.fff} [{1}] {2}' -f (Get-Date), $Config.ScriptKind, $Message
    try { Add-Content -Path (Get-LogFilePath) -Value $line -Encoding UTF8 } catch { }
}

# Haengt bei aktivem Debug-Log den Pfad der aktuellen Logdatei an eine
# Fehlermeldung an, damit im Royal-TS-Fehlerdialog direkt steht, welche
# Datei zu diesem Fehlversuch gehoert.
function Add-LogHint {
    param([string]$Message)
    if ($Config.DebugLog -ne 'Yes') { return $Message }
    return ($Message + [Environment]::NewLine + '--- Log: ' + (Get-LogFilePath))
}

# ---------------------------------------------------------------------------
# Konfiguration pruefen/normalisieren
# ---------------------------------------------------------------------------
function Initialize-Config {
    if (-not $Config.ServerUrl -or $Config.ServerUrl -eq 'TODO') {
        throw 'Custom Property "Server URL" ist nicht gesetzt (Dynamic Folder -> Eigenschaften -> Custom Properties).'
    }
    $Config.ServerUrl = $Config.ServerUrl.TrimEnd('/')
    if ($Config.AuthMode -notmatch '^(?i)(sso|password|webclient)$') {
        throw ('Custom Property "Auth Mode" muss "WebClient", "SSO" oder "Password" sein (aktuell: "{0}").' -f $Config.AuthMode)
    }
    Write-DebugLog ('Start - Build={0} Server={1} AuthMode={2} TokenVariant={3}' -f $script:BuildTag, $Config.ServerUrl, $Config.AuthMode, $Config.TokenVariant)
    Write-DebugLog ('Env   - PS={0}/{1} OS={2} Host={3} User={4} Apartment={5}' -f `
        $PSVersionTable.PSVersion, $PSVersionTable.PSEdition, [Environment]::OSVersion.Version,
        $env:COMPUTERNAME, $env:USERNAME, [System.Threading.Thread]::CurrentThread.GetApartmentState())
}

# ---------------------------------------------------------------------------
# HTTP-Grundlagen (TLS 1.2, optional Zertifikatspruefung deaktivieren)
# ---------------------------------------------------------------------------
function Initialize-Http {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch { }
    if ($Config.IgnoreSsl -eq 'Yes' -and -not $script:IsPsCore) {
        [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
    }
}

# Duenner Wrapper um Invoke-WebRequest: wirft bei HTTP-Fehlern NICHT, sondern
# liefert Status/Header/Content zurueck (wird u. a. fuer die OTP-Header benoetigt).
function Invoke-Http {
    param(
        [string]$Method,
        [string]$Uri,
        $Body = $null,
        [hashtable]$Headers = $null,
        [string]$ContentType = $null
    )
    $splat = @{ Method = $Method; Uri = $Uri; UseBasicParsing = $true; TimeoutSec = 90 }
    if ($null -ne $Body)  { $splat.Body = $Body }
    if ($Headers)         { $splat.Headers = $Headers }
    if ($ContentType)     { $splat.ContentType = $ContentType }
    if ($script:IsPsCore -and $Config.IgnoreSsl -eq 'Yes') { $splat.SkipCertificateCheck = $true }

    try {
        $resp = Invoke-WebRequest @splat
        $h = @{}
        foreach ($k in $resp.Headers.Keys) { $h[$k] = [string]($resp.Headers[$k] -join ',') }
        return @{ Ok = $true; Status = [int]$resp.StatusCode; Content = [string]$resp.Content; Headers = $h }
    } catch {
        $ex = $_.Exception
        $status = 0; $h = @{}; $content = ''
        if ($ex.Response) {
            if ($script:IsPsCore) {
                # PowerShell 7: HttpResponseMessage
                $status = [int]$ex.Response.StatusCode
                foreach ($kv in $ex.Response.Headers) { $h[$kv.Key] = [string]($kv.Value -join ',') }
                if ($_.ErrorDetails) { $content = [string]$_.ErrorDetails.Message }
            } else {
                # Windows PowerShell 5.1: HttpWebResponse
                $status = [int]$ex.Response.StatusCode
                foreach ($k in $ex.Response.Headers.AllKeys) { $h[$k] = [string]$ex.Response.Headers[$k] }
                # In PS 5.1 the response body is usually already captured here:
                if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
                    $content = [string]$_.ErrorDetails.Message
                }
                if (-not $content) {
                    try {
                        $stream = $ex.Response.GetResponseStream()
                        if ($stream.CanSeek) { $stream.Position = 0 }
                        $sr = New-Object System.IO.StreamReader($stream)
                        $content = $sr.ReadToEnd()
                        $sr.Close()
                    } catch { }
                }
            }
        }
        if ($status -eq 0) {
            throw ('Verbindung zu "{0}" fehlgeschlagen: {1}' -f $Uri, $ex.Message)
        }
        return @{ Ok = $false; Status = $status; Content = $content; Headers = $h }
    }
}

# Raw form POST via HttpWebRequest - writes the exact body bytes (like curl),
# bypassing Invoke-WebRequest quirks and disabling Expect: 100-continue. Used
# for the OAuth token exchange where the body must arrive verbatim.
function Invoke-FormPost {
    param(
        [string]$Uri,
        [string]$Body,
        [string]$ContentType = 'application/x-www-form-urlencoded',
        [hashtable]$ExtraHeaders = $null,
        $CookieContainer = $null,
        # Der echte KeePass-Client (System.Net.WebClient) sendet
        # "Expect: 100-continue" und "Connection: Keep-Alive" und setzt KEINEN
        # Accept-Header. Diese Schalter erlauben die exakte Nachbildung.
        [bool]$ExpectContinue = $false,
        [bool]$KeepAlive = $false,
        [bool]$SendAccept = $true
    )
    $req = [System.Net.HttpWebRequest]::Create($Uri)
    $req.Method = 'POST'
    if ($ContentType) { $req.ContentType = $ContentType }
    if ($SendAccept) { $req.Accept = 'application/json' }
    $req.ServicePoint.Expect100Continue = $ExpectContinue
    $req.KeepAlive = $KeepAlive
    if ($CookieContainer) { $req.CookieContainer = $CookieContainer }
    if ($ExtraHeaders) {
        foreach ($k in $ExtraHeaders.Keys) {
            if ($k -ieq 'Authorization') { $req.Headers['Authorization'] = [string]$ExtraHeaders[$k] }
            else { $req.Headers.Add($k, [string]$ExtraHeaders[$k]) }
        }
    }
    if ($Config.IgnoreSsl -eq 'Yes') {
        $req.ServerCertificateValidationCallback = { $true }
    }
    $bytes = [System.Text.Encoding]::ASCII.GetBytes($Body)
    $req.ContentLength = $bytes.Length

    # Den kompletten ausgehenden Request protokollieren (Request-Line, Header,
    # Body-Bytes). Auth-Code und code_verifier sind Einmalwerte und nach dem
    # Tausch wertlos -> unbedenklich und fuer die Fehlersuche entscheidend.
    Write-DebugLog ('HTTP >>> POST {0}' -f $Uri)
    Write-DebugLog ('HTTP >>> Content-Type: {0}; Content-Length: {1}' -f $req.ContentType, $bytes.Length)
    foreach ($hk in $req.Headers.AllKeys) { Write-DebugLog ('HTTP >>> {0}: {1}' -f $hk, $req.Headers[$hk]) }
    Write-DebugLog ('HTTP >>> body[{0}]: {1}' -f $Body.Length, $Body)

    $result = $null
    try {
        if ($bytes.Length -gt 0) {
            $rs = $req.GetRequestStream(); $rs.Write($bytes, 0, $bytes.Length); $rs.Close()
        }
        $resp = $req.GetResponse()
        $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
        $content = $sr.ReadToEnd(); $sr.Close()
        $result = @{ Ok = $true; Status = [int]$resp.StatusCode; Content = $content; Response = $resp }
    } catch [System.Net.WebException] {
        $er = $_.Exception.Response
        if (-not $er) {
            Write-DebugLog ('HTTP <<< network failure: {0}' -f $_.Exception.Message)
            throw ('Connection to "{0}" failed: {1}' -f $Uri, $_.Exception.Message)
        }
        $sr = New-Object System.IO.StreamReader($er.GetResponseStream())
        $content = $sr.ReadToEnd(); $sr.Close()
        $result = @{ Ok = $false; Status = [int]$er.StatusCode; Content = $content; Response = $er }
    }

    Write-DebugLog ('HTTP <<< HTTP {0}' -f $result.Status)
    try {
        foreach ($hk in $result.Response.Headers.AllKeys) {
            Write-DebugLog ('HTTP <<< {0}: {1}' -f $hk, $result.Response.Headers[$hk])
        }
    } catch { }
    Write-DebugLog ('HTTP <<< body: {0}' -f $result.Content)
    return $result
}

function Get-HeaderValue {
    param([hashtable]$Headers, [string]$Name)
    foreach ($k in $Headers.Keys) {
        if ($k -ieq $Name) { return [string]$Headers[$k] }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Token-Cache: DPAPI-verschluesselt (nur aktueller Windows-Benutzer) unter
# %LOCALAPPDATA%\RoyalTS-PleasantPPS\token-<hash>.dat
# Verhindert, dass bei jedem Reload / jedem Passwort-Abruf neu angemeldet
# werden muss - wichtig, weil das Dynamic-Credential-Skript pro Abruf
# separat ausgefuehrt wird.
# ---------------------------------------------------------------------------
function Get-TokenCachePath {
    $keySource = '{0}|{1}|{2}|{3}' -f $Config.ServerUrl.ToLowerInvariant(), $Config.AuthMode.ToLowerInvariant(), $Config.Username, $env:USERNAME
    $sha  = [System.Security.Cryptography.SHA256]::Create()
    $hash = ($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($keySource)) | ForEach-Object { $_.ToString('x2') }) -join ''
    return (Join-Path $script:AppDir ('token-' + $hash.Substring(0, 32) + '.dat'))
}

function Get-CachedToken {
    if ($Config.UseCache -ne 'Yes') { return $null }
    $path = Get-TokenCachePath
    if (-not (Test-Path $path)) { return $null }
    try {
        Add-Type -AssemblyName System.Security
        $enc = [System.IO.File]::ReadAllBytes($path)
        $raw = [System.Security.Cryptography.ProtectedData]::Unprotect($enc, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        $obj = [System.Text.Encoding]::UTF8.GetString($raw) | ConvertFrom-Json
        $now = [System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        if ($now -lt ([long]$obj.expires_at - 60)) {
            Write-DebugLog ('Token cache hit, valid until {0:u}' -f [System.DateTimeOffset]::FromUnixTimeSeconds([long]$obj.expires_at).LocalDateTime)
            return [string]$obj.access_token
        }
        Write-DebugLog 'Cached token expired.'
    } catch {
        Write-DebugLog ('Token cache unreadable: {0}' -f $_.Exception.Message)
    }
    return $null
}

function Save-CachedToken {
    param([string]$Token, [long]$ExpiresAt)
    if ($Config.UseCache -ne 'Yes') { return }
    try {
        Add-Type -AssemblyName System.Security
        $json = @{ access_token = $Token; expires_at = $ExpiresAt } | ConvertTo-Json -Compress
        $enc = [System.Security.Cryptography.ProtectedData]::Protect(
            [System.Text.Encoding]::UTF8.GetBytes($json), $null,
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        [System.IO.File]::WriteAllBytes((Get-TokenCachePath), $enc)
        Write-DebugLog ('Token cached, valid until {0:u}' -f [System.DateTimeOffset]::FromUnixTimeSeconds($ExpiresAt).LocalDateTime)
    } catch {
        Write-DebugLog ('Writing token cache failed: {0}' -f $_.Exception.Message)
    }
}

function Clear-CachedToken {
    Remove-Item -Path (Get-TokenCachePath) -Force -ErrorAction SilentlyContinue
}

# Ablaufzeitpunkt (exp-Claim) aus einem JWT lesen; $null wenn kein JWT.
function Get-JwtExpiry {
    param([string]$Token)
    try {
        $parts = $Token.Split('.')
        if ($parts.Count -lt 2) { return $null }
        $payload = $parts[1].Replace('-', '+').Replace('_', '/')
        switch ($payload.Length % 4) {
            2 { $payload += '==' }
            3 { $payload += '=' }
        }
        $json = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($payload)) | ConvertFrom-Json
        if ($json.exp) { return [long]$json.exp }
    } catch { }
    return $null
}

# Prueft, ob ein Token von der API akzeptiert wird (alles ausser 401/403 gilt
# als authentifiziert - so bleibt der Check unabhaengig vom konkreten Endpunkt).
function Test-AccessToken {
    param([string]$Token)
    if (-not $Token) { return $false }
    try {
        $r = Invoke-Http -Method 'GET' -Uri ($Config.ServerUrl + '/api/v5/rest/folders/root') -Headers @{
            Accept        = 'application/json'
            Authorization = 'Bearer ' + $Token
        }
        return ($r.Status -ne 401 -and $r.Status -ne 403)
    } catch {
        return $false
    }
}

# ---------------------------------------------------------------------------
# Einfacher Eingabedialog (fuer OTP im Password-Modus)
# ---------------------------------------------------------------------------
function Show-InputDialog {
    param([string]$Message, [string]$Title = 'Pleasant Password Server')
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $form = New-Object System.Windows.Forms.Form
    $form.Text            = $Title
    $form.Size            = New-Object System.Drawing.Size(420, 170)
    $form.StartPosition   = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.TopMost         = $true
    $form.MaximizeBox     = $false
    $form.MinimizeBox     = $false

    $label = New-Object System.Windows.Forms.Label
    $label.Text     = $Message
    $label.AutoSize = $false
    $label.Location = New-Object System.Drawing.Point(12, 12)
    $label.Size     = New-Object System.Drawing.Size(380, 40)
    $form.Controls.Add($label)

    $textBox = New-Object System.Windows.Forms.TextBox
    $textBox.Location = New-Object System.Drawing.Point(12, 58)
    $textBox.Size     = New-Object System.Drawing.Size(380, 24)
    $form.Controls.Add($textBox)

    $okButton = New-Object System.Windows.Forms.Button
    $okButton.Text         = 'OK'
    $okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $okButton.Location     = New-Object System.Drawing.Point(236, 92)
    $form.Controls.Add($okButton)

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text         = 'Abbrechen'
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $cancelButton.Location     = New-Object System.Drawing.Point(317, 92)
    $form.Controls.Add($cancelButton)

    $form.AcceptButton = $okButton
    $form.CancelButton = $cancelButton
    $form.Add_Shown({ $textBox.Select() })

    if ($form.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return $textBox.Text
    }
    return $null
}

# ---------------------------------------------------------------------------
# Auth-Modus "Password": klassischer OAuth2 Resource Owner Password Grant
# inkl. MFA ueber die X-Pleasant-OTP-Header (wie im Python-Original).
# Doku: https://pleasantpasswords.com/info/pleasant-password-server/
#       m-programmatic-access/restful-api/oauth-two-factor-support
# ---------------------------------------------------------------------------
function Get-TokenViaPasswordGrant {
    $user = if ($Config.OmitDomain -eq 'Yes') { $Config.UsernameNoDomain } else { $Config.Username }
    if (-not $user -or -not $Config.Password) {
        throw 'Auth Mode "Password": Dem Dynamic Folder muessen Zugangsdaten zugewiesen sein (Eigenschaften -> Zugangsdaten).'
    }

    $tokenUri = $Config.ServerUrl + '/OAuth2/Token'
    $body     = @{ grant_type = 'password'; username = $user; password = $Config.Password }

    $r = Invoke-Http -Method 'POST' -Uri $tokenUri -Body $body -ContentType 'application/x-www-form-urlencoded'

    if (-not $r.Ok -and (Get-HeaderValue $r.Headers 'X-Pleasant-OTP') -eq 'required') {
        $provider = Get-HeaderValue $r.Headers 'X-Pleasant-OTP-Provider'
        Write-DebugLog ('MFA required, provider: {0}' -f $provider)
        $otp = Show-InputDialog ('Einmalpasswort (OTP) fuer MFA eingeben' + $(if ($provider) { " - Provider: $provider" } else { '' }) + ':')
        if (-not $otp) { throw 'MFA abgebrochen: kein OTP eingegeben.' }
        $otpHeaders = @{ 'X-Pleasant-OTP-Provider' = $provider; 'X-Pleasant-OTP' = $otp }
        $r = Invoke-Http -Method 'POST' -Uri $tokenUri -Body $body -ContentType 'application/x-www-form-urlencoded' -Headers $otpHeaders
    }

    if (-not $r.Ok) {
        if ($r.Status -eq 400) {
            throw ('Anmeldung fehlgeschlagen (HTTP 400). Haeufige Ursache: redundanter Domaenenname im Benutzernamen -> Custom Property "Omit Domain" auf Yes setzen. Bei SSO-only-Konten muss im Pleasant-Server "Allow Exception For Direct Sign-In" aktiv sein oder Auth Mode "SSO" verwendet werden. Details: {0}' -f $r.Content)
        }
        throw ('Token-Endpoint meldet HTTP {0}: {1}' -f $r.Status, $r.Content)
    }

    $tok = $r.Content | ConvertFrom-Json
    if (-not $tok.access_token) { throw 'Token-Endpoint hat kein access_token geliefert.' }

    $now = [System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $expiresAt = $null
    if ($tok.PSObject.Properties['expires_in'] -and $tok.expires_in) { $expiresAt = $now + [long]$tok.expires_in }
    if (-not $expiresAt) { $expiresAt = Get-JwtExpiry $tok.access_token }
    if (-not $expiresAt) { $expiresAt = $now + 1200 }  # konservativer Default: 20 Minuten

    return @{ Token = [string]$tok.access_token; ExpiresAt = [long]$expiresAt }
}

# ---------------------------------------------------------------------------
# WebView2-SDK-Bootstrap: Royal TS fuehrt PowerShell-Skripte mit Windows
# PowerShell 5.1 (.NET Framework) aus. Die WebView2 Evergreen *Runtime* ist
# auf Win 10/11 vorhanden, aber die managed SDK-Wrapper (net462) fehlen ->
# beim ersten SSO-Lauf automatisch von nuget.org nachladen.
# ---------------------------------------------------------------------------
function Install-WebView2SdkAuto {
    $libDir  = Join-Path $script:AppDir 'lib'
    $version = '1.0.2592.51'
    Write-DebugLog ('WebView2 SDK not found - downloading version {0} from nuget.org ...' -f $version)
    $zip = Join-Path $env:TEMP ('webview2-sdk-' + $version + '.zip')
    $tmp = Join-Path $env:TEMP ('webview2-sdk-' + [Guid]::NewGuid().ToString('N'))
    try {
        Invoke-WebRequest -Uri ('https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2/' + $version) -OutFile $zip -UseBasicParsing -TimeoutSec 120
        Expand-Archive -Path $zip -DestinationPath $tmp -Force
        $netDir = Get-ChildItem -Path (Join-Path $tmp 'lib') -Directory |
            Where-Object { $_.Name -like 'net4*' } |
            Sort-Object Name -Descending |
            Select-Object -First 1
        if (-not $netDir) { throw 'Kein net4x-Build im WebView2-NuGet-Paket gefunden.' }
        New-Item -ItemType Directory -Path $libDir -Force | Out-Null
        Copy-Item -Path (Join-Path $netDir.FullName 'Microsoft.Web.WebView2.Core.dll')     -Destination $libDir -Force
        Copy-Item -Path (Join-Path $netDir.FullName 'Microsoft.Web.WebView2.WinForms.dll') -Destination $libDir -Force
        $l64 = Join-Path $tmp 'runtimes\win-x64\native\WebView2Loader.dll'
        if (Test-Path $l64) { Copy-Item $l64 -Destination $libDir -Force }
        $l86 = Join-Path $tmp 'runtimes\win-x86\native\WebView2Loader.dll'
        if (Test-Path $l86) {
            $x86Dir = Join-Path $libDir 'x86'
            New-Item -ItemType Directory -Path $x86Dir -Force | Out-Null
            Copy-Item $l86 -Destination $x86Dir -Force
        }
        Write-DebugLog ('WebView2 SDK installed to {0}' -f $libDir)
        return $libDir
    } finally {
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# Auth-Modus "SSO": Die Pleasant-API kennt offiziell nur den Password-Grant.
# Fuer SAML-SSO-Konten oeffnen wir daher ein WebView2-Fenster mit dem Pleasant
# WebClient. Die SAML-Anmeldung (inkl. MFA/Conditional Access) uebernimmt der
# IdP im Browser. Sobald der WebClient angemeldet ist, ruft er die REST-API
# mit einem Bearer-Token auf - dieses Token fangen wir ab:
#   1. primaer ueber die Authorization-Header der WebClient-Requests
#      (WebResourceRequested-Event),
#   2. sekundaer ueber einen Scan von session-/localStorage nach
#      access_token-/JWT-Mustern.
# Jeder Kandidat wird gegen die API verifiziert, bevor er verwendet wird.
# Das WebView2-Profil ist persistent -> Folge-Anmeldungen laufen i. d. R.
# ohne erneute Passworteingabe (Silent SSO), danach greift der Token-Cache.
# ---------------------------------------------------------------------------
# WebView2-SDK-Assemblies suchen, laden und den nativen Loader auffindbar
# machen. Von SSO-Bearer- UND WebClient-Cookie-Modus genutzt.
function Initialize-WebView2Sdk {
    if ($script:WebView2Ready) { return }

    $searchDirs = New-Object System.Collections.Generic.List[string]
    if ($env:PLEASANT_WEBVIEW2_DIR) { $searchDirs.Add($env:PLEASANT_WEBVIEW2_DIR) }
    $searchDirs.Add((Join-Path $script:AppDir 'lib'))
    try {
        $procDir = Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
        if ($procDir -match 'Royal') { $searchDirs.Add($procDir) }
    } catch { }
    foreach ($pf in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if (-not $pf) { continue }
        foreach ($v in 8, 7, 6, 5) { $searchDirs.Add((Join-Path $pf ('Royal TS V{0}' -f $v))) }
    }

    $winFormsDll = $null
    $coreDll     = $null
    foreach ($d in $searchDirs) {
        if (-not $d -or -not (Test-Path $d)) { continue }
        $wf = Get-ChildItem -Path $d -Filter 'Microsoft.Web.WebView2.WinForms.dll' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($wf) {
            $co = Join-Path (Split-Path -Parent $wf.FullName) 'Microsoft.Web.WebView2.Core.dll'
            if (Test-Path $co) {
                try {
                    Add-Type -Path $co -ErrorAction Stop
                    Add-Type -Path $wf.FullName -ErrorAction Stop
                    $winFormsDll = $wf.FullName
                    $coreDll     = $co
                    break
                } catch {
                    Write-DebugLog ('WebView2 assembly from "{0}" not loadable ({1}) - trying next.' -f $d, $_.Exception.Message)
                }
            }
        }
    }
    if (-not $winFormsDll) {
        # Automatischer Bootstrap von nuget.org, danach erneuter Ladeversuch
        try {
            $autoLib = Install-WebView2SdkAuto
            $co = Join-Path $autoLib 'Microsoft.Web.WebView2.Core.dll'
            $wf = Join-Path $autoLib 'Microsoft.Web.WebView2.WinForms.dll'
            if ((Test-Path $co) -and (Test-Path $wf)) {
                Add-Type -Path $co -ErrorAction Stop
                Add-Type -Path $wf -ErrorAction Stop
                $coreDll     = $co
                $winFormsDll = $wf
            }
        } catch {
            Write-DebugLog ('WebView2 SDK auto-download failed: {0}' -f $_.Exception.Message)
        }
    }
    if (-not $winFormsDll) {
        throw ('WebView2-SDK-Assemblies nicht gefunden/ladbar und Auto-Download von nuget.org fehlgeschlagen (Proxy/kein Internet?). Manuell "tools\Install-WebView2Sdk.ps1" aus dem Repo ausfuehren (installiert nach {0}\lib) oder Pfad ueber die Umgebungsvariable PLEASANT_WEBVIEW2_DIR vorgeben.' -f $script:AppDir)
    }
    Write-DebugLog ('WebView2 SDK loaded from: {0}' -f (Split-Path -Parent $winFormsDll))

    # Nativer WebView2Loader muss auffindbar sein (liegt neben den SDK-DLLs
    # bzw. in x86-Unterordner) -> Verzeichnis in PATH aufnehmen.
    $libDir = Split-Path -Parent $coreDll
    $loaderDir = if ([Environment]::Is64BitProcess) { $libDir } else { Join-Path $libDir 'x86' }
    if (Test-Path $loaderDir) { $env:PATH = $loaderDir + ';' + $env:PATH }

    $script:WebView2Ready = $true
}

function Get-TokenViaSso {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
        throw 'SSO-Modus benoetigt einen STA-Thread (WebView2/WinForms). Bitte im Royal-TS-Kontext ausfuehren oder Auth Mode "Password" verwenden.'
    }

    Initialize-WebView2Sdk

    # --- Zustand + UI ------------------------------------------------------
    $script:SsoState = @{
        Token      = $null
        ExpiresAt  = 0
        Candidates = New-Object System.Collections.Queue
        Seen       = @{}
        Pending    = $null
        Error      = $null
    }

    $script:SsoProbeJs = @'
(function(){
  var out = [];
  try { for (var i = 0; i < sessionStorage.length; i++) { out.push(sessionStorage.getItem(sessionStorage.key(i))); } } catch (e) { }
  try { for (var i = 0; i < localStorage.length;  i++) { out.push(localStorage.getItem(localStorage.key(i)));  } } catch (e) { }
  return out.join('\n');
})()
'@

    # --- Start-URL bestimmen: Custom Property > /WebClient > Server-Root ----
    $ssoUrl = $null
    if ($Config.ContainsKey('SsoLoginUrl') -and $Config.SsoLoginUrl -and $Config.SsoLoginUrl -ne 'TODO') {
        $ssoUrl = $Config.SsoLoginUrl
        Write-DebugLog ('SSO-Login-URL aus Custom Property: {0}' -f $ssoUrl)
    } else {
        # Pleasant 9: WebClient liegt unter /WebClient/Main; aeltere Staende
        # unter /WebClient. Bei 404 auf Server-Root ausweichen.
        foreach ($cand in @('/WebClient/Main', '/WebClient', '/')) {
            $ssoUrl = $Config.ServerUrl + $cand
            try {
                $probe = Invoke-Http -Method 'GET' -Uri $ssoUrl
                if ($probe.Status -ne 404) {
                    Write-DebugLog ('SSO-Login-Seite: {0} (HTTP {1})' -f $ssoUrl, $probe.Status)
                    break
                }
            } catch {
                Write-DebugLog ('Probe {0} fehlgeschlagen ({1})' -f $ssoUrl, $_.Exception.Message)
                break
            }
        }
    }

    $script:SsoForm = New-Object System.Windows.Forms.Form
    $script:SsoForm.Text          = 'Pleasant Password Server - SSO-Anmeldung (Fenster schliesst sich automatisch)'
    $script:SsoForm.Size          = New-Object System.Drawing.Size(1050, 800)
    $script:SsoForm.StartPosition = 'CenterScreen'

    $script:SsoWebView = New-Object Microsoft.Web.WebView2.WinForms.WebView2
    $script:SsoWebView.Dock = [System.Windows.Forms.DockStyle]::Fill
    $props = New-Object Microsoft.Web.WebView2.WinForms.CoreWebView2CreationProperties
    $props.UserDataFolder = Join-Path $script:AppDir 'WebView2'   # persistentes Profil -> Silent SSO bei Folgeanmeldungen
    $script:SsoWebView.CreationProperties = $props
    $script:SsoForm.Controls.Add($script:SsoWebView)

    # Token-Kandidat aufnehmen (dedupliziert)
    function script:Add-SsoCandidate {
        param([string]$Candidate)
        if (-not $Candidate) { return }
        $Candidate = $Candidate -replace '^\s*Bearer\s+', ''
        $Candidate = $Candidate.Trim('"')
        if ($Candidate.Length -lt 20) { return }
        if (-not $script:SsoState.Seen.ContainsKey($Candidate)) {
            $script:SsoState.Seen[$Candidate] = $true
            $script:SsoState.Candidates.Enqueue($Candidate)
        }
    }

    $script:SsoWebView.add_CoreWebView2InitializationCompleted({
        param($sender, $e)
        if (-not $e.IsSuccess) {
            $msg = 'unbekannt'
            if ($e.InitializationException) { $msg = $e.InitializationException.Message }
            $script:SsoState.Error = 'WebView2-Initialisierung fehlgeschlagen (WebView2 Evergreen Runtime installiert?): ' + $msg
            $script:SsoForm.Close()
            return
        }
        $core = $script:SsoWebView.CoreWebView2
        $core.AddWebResourceRequestedFilter('*', [Microsoft.Web.WebView2.Core.CoreWebView2WebResourceContext]::All)
        $core.add_WebResourceRequested({
            param($s2, $e2)
            try {
                if ($e2.Request.Headers.Contains('Authorization')) {
                    Add-SsoCandidate ($e2.Request.Headers.GetHeader('Authorization'))
                }
            } catch { }
        })
    })

    $script:SsoTimer = New-Object System.Windows.Forms.Timer
    $script:SsoTimer.Interval = 800
    $script:SsoTimer.add_Tick({
        $st = $script:SsoState
        try {
            # 1) abgefangene Authorization-Header verifizieren
            while ($st.Candidates.Count -gt 0) {
                $cand = [string]$st.Candidates.Dequeue()
                if (Test-AccessToken $cand) {
                    $st.Token = $cand
                    $exp = Get-JwtExpiry $cand
                    $st.ExpiresAt = if ($exp) { $exp } else { [System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 1200 }
                    $script:SsoForm.Close()
                    return
                }
            }
            # 2) Fallback: Web Storage des WebClients nach Token-Mustern scannen
            if ($st.Pending -and $st.Pending.IsCompleted) {
                try {
                    $raw = [string]($st.Pending.Result | ConvertFrom-Json)
                    foreach ($m in ([regex]'"access_token"\s*:\s*"([^"]+)"').Matches($raw)) { Add-SsoCandidate $m.Groups[1].Value }
                    foreach ($m in ([regex]'ey[A-Za-z0-9_\-]{15,}\.ey[A-Za-z0-9_\-]{15,}\.[A-Za-z0-9_\-]{10,}').Matches($raw)) { Add-SsoCandidate $m.Value }
                } catch { }
                $st.Pending = $null
            }
            if (-not $st.Pending -and $script:SsoWebView.CoreWebView2) {
                $st.Pending = $script:SsoWebView.CoreWebView2.ExecuteScriptAsync($script:SsoProbeJs)
            }
        } catch { }
    })

    $script:SsoStartUrl = $ssoUrl
    $script:SsoForm.add_Shown({
        $script:SsoTimer.Start()
        try {
            $script:SsoWebView.Source = [Uri]$script:SsoStartUrl
        } catch {
            $script:SsoState.Error = 'WebView2 konnte nicht gestartet werden: ' + $_.Exception.Message
            $script:SsoForm.Close()
        }
    })

    try {
        [void]$script:SsoForm.ShowDialog()
    } finally {
        $script:SsoTimer.Stop()
        $script:SsoTimer.Dispose()
        try { $script:SsoWebView.Dispose() } catch { }
        $script:SsoForm.Dispose()
    }

    if ($script:SsoState.Error) { throw $script:SsoState.Error }
    if (-not $script:SsoState.Token) {
        throw 'SSO-Anmeldung abgebrochen oder es konnte kein API-Token aus der WebClient-Sitzung uebernommen werden (Details ggf. mit "Debug Log" = Yes nachvollziehen).'
    }
    Write-DebugLog 'SSO-Token erfolgreich uebernommen.'
    return @{ Token = $script:SsoState.Token; ExpiresAt = [long]$script:SsoState.ExpiresAt }
}

# ---------------------------------------------------------------------------
# WebView2-SSO-Login fuer den Cookie-Modus (Auth Mode = WebClient):
# oeffnet den WebClient, laesst den Benutzer per SAML anmelden und uebernimmt
# nach erfolgreicher Anmeldung die Session-Cookies in eine PowerShell-
# WebSession. Nutzt dieselbe WebView2-Infrastruktur wie Get-TokenViaSso.
# ---------------------------------------------------------------------------
function Invoke-WebClientSsoLogin {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
        throw 'WebClient-Modus benoetigt einen STA-Thread (WebView2/WinForms). Im Royal-TS-Kontext ausfuehren.'
    }

    Initialize-WebView2Sdk   # laedt/bootstrappt die WebView2-Assemblies

    $script:WcState = @{ Cookies = $null; Error = $null; Busy = $false; Ticks = 0 }
    $script:WcServerHost = ([Uri]$Config.ServerUrl).Host

    $loginUrl = $Config.ServerUrl + '/WebClient/Main'
    if ($Config.ContainsKey('SsoLoginUrl') -and $Config.SsoLoginUrl -and $Config.SsoLoginUrl -ne 'TODO') {
        $loginUrl = $Config.SsoLoginUrl
    }
    Write-DebugLog ('WebClient login starting, URL={0}, host={1}' -f $loginUrl, $script:WcServerHost)

    $script:WcForm = New-Object System.Windows.Forms.Form
    $script:WcForm.Text          = 'Pleasant Password Server - Anmeldung (Fenster schliesst sich automatisch)'
    $script:WcForm.Size          = New-Object System.Drawing.Size(1050, 800)
    $script:WcForm.StartPosition = 'CenterScreen'

    $script:WcWebView = New-Object Microsoft.Web.WebView2.WinForms.WebView2
    $script:WcWebView.Dock = [System.Windows.Forms.DockStyle]::Fill
    $props = New-Object Microsoft.Web.WebView2.WinForms.CoreWebView2CreationProperties
    $props.UserDataFolder = Join-Path $script:AppDir 'WebView2'
    $script:WcWebView.CreationProperties = $props
    $script:WcForm.Controls.Add($script:WcWebView)

    $script:WcWebView.add_CoreWebView2InitializationCompleted({
        param($sender, $e)
        if (-not $e.IsSuccess) {
            $msg = if ($e.InitializationException) { $e.InitializationException.Message } else { 'unbekannt' }
            $script:WcState.Error = 'WebView2-Initialisierung fehlgeschlagen (Evergreen Runtime installiert?): ' + $msg
            Write-DebugLog $script:WcState.Error
            $script:WcForm.Close()
        } else {
            Write-DebugLog 'WebView2 initialized.'
        }
    })

    # Zur Nachvollziehbarkeit jede Navigation loggen
    $script:WcWebView.add_NavigationStarting({
        param($sender, $e)
        try { Write-DebugLog ('Navigation -> {0}' -f $e.Uri) } catch { }
    })

    # Timer prueft auf UI-Thread den Anmeldezustand und liest die Cookies
    # SYNCHRON aus (message-pump via DoEvents), das ist in PowerShell 5.1
    # zuverlaessiger als eine TPL-Continuation auf einem Fremd-Thread.
    $script:WcTimer = New-Object System.Windows.Forms.Timer
    $script:WcTimer.Interval = 700
    $script:WcTimer.add_Tick({
        if ($script:WcState.Busy) { return }
        $script:WcState.Busy = $true
        try {
            $script:WcState.Ticks++
            $core = $script:WcWebView.CoreWebView2
            if (-not $core) { return }
            $src = [string]$core.Source
            if (-not $src) { return }

            $onOurHost  = $src -match [regex]::Escape($script:WcServerHost)
            $onAuthPage = $src -match '(?i)SignIn|SingleSignOn|/SAML|/Account/|login\.microsoftonline|\.windows\.net|oauth2|/adfs'

            # alle 5 Ticks (~3,5 s) den aktuellen Zustand loggen, damit man im
            # Log sieht, wo die Anmeldung gerade steht
            if (($script:WcState.Ticks % 5) -eq 1) {
                Write-DebugLog ('Waiting for login... current URL={0} (ourHost={1}, authPage={2})' -f $src, $onOurHost, $onAuthPage)
            }

            if ($onOurHost -and -not $onAuthPage) {
                Write-DebugLog ('Login detected at URL={0} - reading cookies...' -f $src)
                $task = $core.CookieManager.GetCookiesAsync($Config.ServerUrl)
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                while (-not $task.IsCompleted -and $sw.ElapsedMilliseconds -lt 5000) {
                    [System.Windows.Forms.Application]::DoEvents()
                    Start-Sleep -Milliseconds 25
                }
                if (-not $task.IsCompleted) {
                    Write-DebugLog 'CookieManager timeout (5s) - retrying on next tick.'
                    return
                }
                $cookies = $task.Result
                $names = @()
                $list = New-Object System.Collections.Generic.List[object]
                foreach ($c in $cookies) {
                    $list.Add([pscustomobject]@{ Name = $c.Name; Value = $c.Value; Domain = $c.Domain; Path = $c.Path })
                    $names += $c.Name
                }
                Write-DebugLog ('CookieManager returned {0} cookies: {1}' -f $list.Count, ($names -join ', '))
                if ($list.Count -gt 0) {
                    $script:WcState.Cookies = $list
                    $script:WcTimer.Stop()
                    $script:WcForm.Close()
                }
            }
        } catch {
            Write-DebugLog ('Error in login timer: {0}' -f $_.Exception.Message)
        } finally {
            $script:WcState.Busy = $false
        }
    })

    $script:WcStartUrl = $loginUrl
    $script:WcForm.add_Shown({
        $script:WcTimer.Start()
        try { $script:WcWebView.Source = [Uri]$script:WcStartUrl }
        catch {
            $script:WcState.Error = 'WebView2 konnte nicht gestartet werden: ' + $_.Exception.Message
            Write-DebugLog $script:WcState.Error
            $script:WcForm.Close()
        }
    })

    try { [void]$script:WcForm.ShowDialog() }
    finally {
        try { $script:WcTimer.Stop(); $script:WcTimer.Dispose() } catch { }
        try { $script:WcWebView.Dispose() } catch { }
        $script:WcForm.Dispose()
    }

    if ($script:WcState.Error) { throw $script:WcState.Error }
    if (-not $script:WcState.Cookies -or $script:WcState.Cookies.Count -eq 0) {
        throw 'Anmeldung abgebrochen oder keine Session-Cookies uebernommen (mit Debug Log = Yes zeigt das Log die letzte URL).'
    }

    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $srvHost = ([Uri]$Config.ServerUrl).Host
    foreach ($c in $script:WcState.Cookies) {
        try {
            $ck = New-Object System.Net.Cookie($c.Name, $c.Value, $(if ($c.Path) { $c.Path } else { '/' }), $(if ($c.Domain) { $c.Domain.TrimStart('.') } else { $srvHost }))
            $session.Cookies.Add($ck)
        } catch { }
    }
    Write-DebugLog ('WebClient login ok, {0} cookies captured.' -f $script:WcState.Cookies.Count)
    return $session
}

# ---------------------------------------------------------------------------
# SSO via OAuth2 Authorization Code + PKCE (the flow the KeePass HUB desktop
# client uses). Yields a real REST-API Bearer token even when the password
# grant is disabled and SAML SSO is enforced.
#   1. WebView2 opens /oauth2/authorize (SAML login happens at the IdP)
#   2. server redirects to  kp4pps://callback?code=...&state=...
#   3. we intercept that redirect, then exchange the code at /OAuth2/Token
# Public client_id + redirect_uri are the KeePass client's (PKCE-protected,
# no secret involved).
# ---------------------------------------------------------------------------
$script:KpClientId      = '{2279DD22-9B86-4CB0-AAC5-17028159160B}'
$script:KpRedirectUri   = 'kp4pps://callback'
$script:KpClientVersion = '9.2.0.0'

function New-PkcePair {
    $bytes = New-Object 'System.Byte[]' 32
    ([System.Security.Cryptography.RandomNumberGenerator]::Create()).GetBytes($bytes)
    $verifier = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    $hash = ([System.Security.Cryptography.SHA256]::Create()).ComputeHash([System.Text.Encoding]::ASCII.GetBytes($verifier))
    $challenge = [Convert]::ToBase64String($hash).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    return @{ Verifier = $verifier; Challenge = $challenge }
}

function New-RandomHex {
    param([int]$Bytes = 16)
    $b = New-Object 'System.Byte[]' $Bytes
    ([System.Security.Cryptography.RandomNumberGenerator]::Create()).GetBytes($b)
    return (($b | ForEach-Object { $_.ToString('x2') }) -join '')
}

# Der echte Client bildet device_id und X-Pleasant-MAC-Addresses aus
# NetworkInterface.GetAllNetworkInterfaces(): device_id = erste physische
# MAC ohne Trennzeichen, MAC-Addresses = alle, mit Komma verbunden.
function Get-MacAddressList {
    $macs = New-Object System.Collections.ArrayList
    try {
        # Kein OperationalStatus-Filter: der echte Client nimmt alle Adapter
        # ausser Loopback/Tunnel. Mit Filter kaemen andere device_id und eine
        # andere MAC-Liste heraus als beim Original (nachgemessen).
        foreach ($nic in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            if ($nic.NetworkInterfaceType -eq 'Loopback' -or $nic.NetworkInterfaceType -eq 'Tunnel') { continue }
            $addr = $nic.GetPhysicalAddress().ToString()
            if ($addr -and $addr.Length -ge 12 -and -not $macs.Contains($addr)) { [void]$macs.Add($addr) }
        }
    } catch { }
    return $macs
}

function Get-DeviceId {
    # @() ist zwingend: PowerShell rollt eine einelementige Liste zu einem
    # String aus, und $string[0] waere dann das erste ZEICHEN (device_id=0).
    $macs = @(Get-MacAddressList)
    if ($macs.Count -gt 0) { return [string]$macs[0] }
    return ((New-RandomHex 6).ToUpperInvariant())
}

# Die drei Header, die der KeePass-Client an JEDEN Request haengt - auch an
# /oauth2/authorize (via WebResourceRequested) und an /OAuth2/Token. Ohne sie
# ordnet der Server die PKCE-Sitzung offenbar nicht zu.
function Get-PleasantClientHeaders {
    $h = @{
        'X-Pleasant-Client-Identifier'     = $script:KpClientId
        'X-Pleasant-Client-Version-Number' = $script:KpClientVersion
        'X-Pleasant-MAC-Addresses'         = (@(Get-MacAddressList) -join ',')
    }
    $user = if ($Config.Username) { $Config.Username } else { $env:USERNAME }
    if ($user -and $user.Trim()) { $h['X-Pleasant-Client-User'] = $user }
    return $h
}

# Token-Variante 9: den Tausch von Pleasants EIGENER Client-Bibliothek
# erledigen lassen (falls "KeePass for Pleasant Password Server" installiert
# ist). Das ist vor allem ein Beweismittel: schlaegt auch das fehl, liegt das
# Problem serverseitig und nicht an unserem Request.
function Get-TokenViaPleasantClientDll {
    param([string]$Code, [string]$Verifier)

    $dir = $null
    foreach ($base in @(${env:ProgramFiles(x86)}, $env:ProgramFiles)) {
        if (-not $base) { continue }
        $p = Join-Path $base 'Pleasant Solutions\KeePass for Pleasant Password Server'
        if (Test-Path (Join-Path $p 'PassMan.Client.dll')) { $dir = $p; break }
    }
    if (-not $dir) {
        throw 'Token variant 9 requires "KeePass for Pleasant Password Server" to be installed (PassMan.Client.dll not found).'
    }
    Write-DebugLog ('Using Pleasant client library from: {0}' -f $dir)

    # Abhaengigkeiten VORAB laden. Ein AssemblyResolve-Handler ist hier
    # unbrauchbar: das Delegat-Scriptblock laeuft in einem Kontext, in dem die
    # $script:-Variablen nicht aufloesen - die Aufloesung scheitert dann still
    # und der spaetere Aufruf stirbt ohne Logeintrag.
    foreach ($dep in @(
        'System.Runtime.CompilerServices.Unsafe.dll', 'System.Buffers.dll',
        'System.Memory.dll', 'System.Numerics.Vectors.dll', 'System.ValueTuple.dll',
        'System.Threading.Tasks.Extensions.dll', 'Microsoft.Bcl.AsyncInterfaces.dll',
        'System.Text.Encodings.Web.dll', 'System.Text.Json.dll',
        'Newtonsoft.Json.dll', 'NLog.dll'
    )) {
        $dp = Join-Path $dir $dep
        if (Test-Path $dp) {
            try { [void][Reflection.Assembly]::LoadFrom($dp) }
            catch { Write-DebugLog ('Dependency {0} could not be loaded: {1}' -f $dep, $_.Exception.Message) }
        }
    }

    # Ersetzt die Binding-Redirects aus KeePass.exe.config, die hier fehlen:
    # liefert die bereits geladene Assembly gleichen einfachen Namens zurueck,
    # egal welche Version angefordert wird (System.Text.Json verlangt z.B.
    # Unsafe 4.0.4.1). Bewusst OHNE externe Variablen, sonst loest der
    # Scriptblock im Delegat-Kontext nichts auf.
    [AppDomain]::CurrentDomain.add_AssemblyResolve([System.ResolveEventHandler] {
        param($sender, $e)
        $simple = ($e.Name -split ',')[0]
        foreach ($a in [AppDomain]::CurrentDomain.GetAssemblies()) {
            if ($a.GetName().Name -eq $simple) { return $a }
        }
        return $null
    })

    $asm  = [Reflection.Assembly]::LoadFrom((Join-Path $dir 'PassMan.Client.dll'))
    $type = $asm.GetType('PassMan.Client.PassManClient')
    $macs = @(Get-MacAddressList)
    Write-DebugLog ('Client library loaded: {0}' -f $asm.FullName)

    $client = $type.GetConstructors()[0].Invoke(@(
        $script:KpClientId, $macs[0], $env:COMPUTERNAME, $script:KpRedirectUri,
        $null, $null, $null, $null
    ))
    $client.ServerUrl     = $Config.ServerUrl.TrimEnd('/') + '/'
    $client.ClientVersion = $script:KpClientVersion
    $client.MacAddresses  = ($macs -join ',')
    $cookieSet = $false
    if ($script:AcState.CookieHeader) {
        # Rohe Cookie-Paare ohne "Cookie: "-Praefix - die Bibliothek setzt den
        # Headernamen selbst (mit Praefix kaeme "Cookie: Cookie: ..." heraus).
        try { $client.Cookies = $script:AcState.CookieHeader; $cookieSet = $true }
        catch { Write-DebugLog ('Could not set Cookies on the client library: {0}' -f $_.Exception.Message) }
    }
    # TokenEndpoint hat keinen oeffentlichen Getter -> ueber Reflection lesen
    $ep = ''
    try { $ep = [string]$type.GetMethod('get_TokenEndpoint', [Reflection.BindingFlags]'Public,NonPublic,Instance').Invoke($client, @()) } catch { }
    Write-DebugLog ('Client library configured: endpoint={0}, macs={1}, cookiesSet={2}' -f $ep, $macs.Count, $cookieSet)

    Write-DebugLog 'Calling PassManClient.GetAccessToken(authCode, codeVerifier)...'
    $token = $null
    try {
        $token = $type.GetMethod('GetAccessToken', [type[]]@([string], [string])).Invoke($client, @($Code, $Verifier))
    } catch {
        # Die Bibliothek verpackt Fehler mehrfach - die ganze Kette loggen,
        # sonst sieht man den eigentlichen Serverfehler nicht.
        $ex = $_.Exception
        $depth = 0
        while ($ex -and $depth -lt 6) {
            Write-DebugLog ('Client library exception [{0}] {1}: {2}' -f $depth, $ex.GetType().FullName, $ex.Message)
            if ($ex -is [System.Net.WebException] -and $ex.Response) {
                try {
                    $sr = New-Object System.IO.StreamReader($ex.Response.GetResponseStream())
                    Write-DebugLog ('Client library server response: {0}' -f $sr.ReadToEnd())
                    $sr.Close()
                } catch { }
            }
            $ex = $ex.InnerException; $depth++
        }
        throw (Add-LogHint ('Token exchange via the installed Pleasant client library failed: ' + $_.Exception.Message))
    }
    if (-not $token) { throw (Add-LogHint 'Pleasant client library returned no access token.') }

    $expiresAt = 0
    try {
        $te = $type.GetMethod('get_TokenExpiry', [Reflection.BindingFlags]'Public,NonPublic,Instance').Invoke($client, @())
        $expiresAt = [long]$te.ToUnixTimeSeconds()
    } catch { }
    if ($expiresAt -le 0) { $expiresAt = [System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 1200 }
    Write-DebugLog 'Access token acquired via the installed Pleasant client library.'
    return @{ Token = [string]$token; ExpiresAt = $expiresAt }
}

function Get-TokenViaAuthCodePkce {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
        throw 'SSO mode needs an STA thread (WebView2/WinForms). Run inside Royal TS.'
    }
    Initialize-WebView2Sdk

    $pkce       = New-PkcePair
    $state      = New-RandomHex 16
    $deviceId   = Get-DeviceId
    $deviceName = $env:COMPUTERNAME
    $clientUser = if ($Config.Username) { $Config.Username } else { $env:USERNAME }

    # Exakt die Parameterliste und -reihenfolge des KeePass-Clients
    # (PassManClient.GetAuthorizeUrl). Der Client haengt KEIN
    # client_version_number und KEIN client_user an - sein eigenes Muster zur
    # Erkennung der Authorize-URL endet hinter "state" ($-verankert).
    $authorizePath = '/oauth2/authorize?client_id=' + [uri]::EscapeDataString($script:KpClientId) +
        '&response_type=code&redirect_uri=' + [uri]::EscapeDataString($script:KpRedirectUri) +
        '&code_challenge=' + [uri]::EscapeDataString($pkce.Challenge) +
        '&code_challenge_method=S256' +
        '&device_id=' + [uri]::EscapeDataString($deviceId) +
        '&device_name=' + [uri]::EscapeDataString($deviceName) +
        '&state=' + $state

    # Navigate DIRECTLY to /oauth2/authorize (no SAML ReturnUrl wrapper). The
    # wrapper double-encoded the query and may have dropped code_challenge, so
    # the code was issued without a bound challenge -> "code_verifier required"
    # at the token step. Going direct keeps code_challenge intact; if the
    # WebView2 session is already authenticated (persistent profile) it stays
    # silent, otherwise the server redirects to the SAML sign-in first.
    $startUrl = $Config.ServerUrl + $authorizePath
    Write-DebugLog ('Authorize URL: {0}{1}' -f $Config.ServerUrl, ($authorizePath -replace '(code_challenge=)[^&]+', '$1<challenge>'))

    $script:AcState = @{ Code = $null; Error = $null; ExpectedState = $state; CookieJar = $null; CookieHeader = $null; Busy = $false; HeaderLogged = $false }
    $script:AcClientHeaders = Get-PleasantClientHeaders

    # Liest die Cookies der WebView2-Sitzung in einen CookieContainer. Damit
    # laesst sich pruefen, ob der Token-Endpoint die Server-Session braucht
    # (Token-Variante 5) - und im Log sieht man, welche Cookies gesetzt sind.
    $script:AcCaptureCookies = {
        try {
            $core = $script:AcWebView.CoreWebView2
            if (-not $core) { return }
            $task = $core.CookieManager.GetCookiesAsync($Config.ServerUrl)
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            while (-not $task.IsCompleted -and $sw.ElapsedMilliseconds -lt 10000) {
                [System.Windows.Forms.Application]::DoEvents()
                Start-Sleep -Milliseconds 25
            }
            if (-not $task.IsCompleted) {
                Write-DebugLog 'Cookie capture timed out (GetCookiesAsync did not complete).'
                return
            }
            $jar = New-Object System.Net.CookieContainer
            $names = @()
            $pairs = New-Object System.Collections.ArrayList
            foreach ($c in $task.Result) {
                $names += $c.Name
                [void]$pairs.Add($c.Name + '=' + $c.Value)
                try {
                    $dom = ([string]$c.Domain).TrimStart('.')
                    $jar.Add((New-Object System.Net.Cookie($c.Name, $c.Value, '/', $dom)))
                } catch { }
            }
            $script:AcState.CookieJar    = $jar
            $script:AcState.CookieHeader = ($pairs -join '; ')
            Write-DebugLog ('Session cookies at callback ({0}): {1}' -f $names.Count, ($names -join ', '))
        } catch {
            Write-DebugLog ('Cookie capture failed: {0}' -f $_.Exception.Message)
        }
    }

    # Handles the kp4pps://callback redirect (from either event)
    $script:AcHandleCallback = {
        param([string]$Uri)
        try {
            $q = ''
            if ($Uri -match '\?(.*)$') { $q = $Matches[1] }
            # Log the full callback query (one-time code, harmless after use) so
            # we can see every parameter the server sends back, not just code/state.
            Write-DebugLog ('Callback query: ' + $q)
            $code = $null; $st = $null
            foreach ($kv in ($q -split '&')) {
                $p = $kv -split '=', 2
                if ($p[0] -eq 'code')  { $code = [uri]::UnescapeDataString($p[1]) }
                if ($p[0] -eq 'state') { $st   = [uri]::UnescapeDataString($p[1]) }
                if ($p[0] -eq 'error') { $script:AcState.Error = 'Authorize error: ' + [uri]::UnescapeDataString($p[1]) }
            }
            if ($code) {
                if ($st -ne $script:AcState.ExpectedState) {
                    $script:AcState.Error = 'State mismatch (possible CSRF) - aborting.'
                    Write-DebugLog $script:AcState.Error
                } else {
                    $script:AcState.Code = $code
                    Write-DebugLog 'Authorization code received.'
                }
            }
        } catch {
            $script:AcState.Error = 'Failed to parse callback: ' + $_.Exception.Message
        }
    }

    $script:AcForm = New-Object System.Windows.Forms.Form
    $script:AcForm.Text          = 'Pleasant Password Server - Sign in (window closes automatically)'
    $script:AcForm.Size          = New-Object System.Drawing.Size(1050, 800)
    $script:AcForm.StartPosition = 'CenterScreen'

    $script:AcWebView = New-Object Microsoft.Web.WebView2.WinForms.WebView2
    $script:AcWebView.Dock = [System.Windows.Forms.DockStyle]::Fill
    $props = New-Object Microsoft.Web.WebView2.WinForms.CoreWebView2CreationProperties
    $props.UserDataFolder = Join-Path $script:AppDir 'WebView2'
    $script:AcWebView.CreationProperties = $props
    $script:AcForm.Controls.Add($script:AcWebView)

    $script:AcWebView.add_CoreWebView2InitializationCompleted({
        param($sender, $e)
        if (-not $e.IsSuccess) {
            $msg = if ($e.InitializationException) { $e.InitializationException.Message } else { 'unknown' }
            $script:AcState.Error = 'WebView2 initialization failed (Evergreen Runtime installed?): ' + $msg
            Write-DebugLog $script:AcState.Error
            $script:AcForm.Close()
            return
        }
        Write-DebugLog 'WebView2 initialized.'
        # Suppress the OS "open KeePass?" dialog for the custom scheme and grab the code
        try {
            $script:AcWebView.CoreWebView2.add_LaunchingExternalUriScheme({
                param($s2, $e2)
                try {
                    $e2.Cancel = $true
                    if ([string]$e2.Uri -like 'kp4pps:*') { & $script:AcHandleCallback ([string]$e2.Uri) }
                } catch { }
                if ($script:AcState.Code -or $script:AcState.Error) {
                    $script:AcForm.BeginInvoke([Action]{ $script:AcFinishTimer.Start() }) | Out-Null
                }
            })
            Write-DebugLog 'LaunchingExternalUriScheme handler attached.'
        } catch {
            Write-DebugLog ('LaunchingExternalUriScheme not available ({0}); relying on NavigationStarting.' -f $_.Exception.Message)
        }
        # Der KeePass-Client setzt die X-Pleasant-Header auch auf die
        # Browser-Requests (PasswordServerBrowserLoginForm.CoreWebView2_
        # WebResourceRequested) - also auch auf /oauth2/authorize. Ohne sie
        # kennt der Server die Client-Identitaet beim Authorize-Schritt nicht.
        try {
            $core = $script:AcWebView.CoreWebView2
            $core.AddWebResourceRequestedFilter('*', [Microsoft.Web.WebView2.Core.CoreWebView2WebResourceContext]::All)
            $core.add_WebResourceRequested({
                param($s3, $e3)
                try {
                    $u = [string]$e3.Request.Uri
                    if ($u -notlike ($Config.ServerUrl + '*')) { return }
                    foreach ($k in $script:AcClientHeaders.Keys) {
                        $e3.Request.Headers.SetHeader($k, [string]$script:AcClientHeaders[$k])
                    }
                } catch { }
            })
            Write-DebugLog ('X-Pleasant client headers attached to WebView2 requests: {0}' -f (($script:AcClientHeaders.Keys | Sort-Object) -join ', '))
        } catch {
            Write-DebugLog ('Could not attach WebResourceRequested handler: {0}' -f $_.Exception.Message)
        }
    })

    $script:AcWebView.add_NavigationStarting({
        param($sender, $e)
        $u = [string]$e.Uri
        if ($u -like 'kp4pps:*') {
            $e.Cancel = $true
            Write-DebugLog 'Callback navigation intercepted.'
            & $script:AcHandleCallback $u
            # NICHT hier die Cookies lesen und nicht direkt schliessen: in
            # einem WebView2-Event-Handler pumpt DoEvents die Schleife nicht,
            # GetCookiesAsync laeuft dann in den Timeout. Ein Timer-Tick ist
            # ein sauberer Kontext (so macht es auch der WebClient-Modus).
            if ($script:AcState.Code -or $script:AcState.Error) { $script:AcFinishTimer.Start() }
        } else {
            # log without query string (may carry sensitive values)
            $bare = ($u -split '\?', 2)[0]
            Write-DebugLog ('Navigation -> {0}' -f $bare)
        }
    })

    # Laeuft nach dem Callback ausserhalb der WebView2-Events: Cookies lesen,
    # dann Fenster schliessen.
    $script:AcFinishTimer = New-Object System.Windows.Forms.Timer
    $script:AcFinishTimer.Interval = 150
    $script:AcFinishTimer.add_Tick({
        if ($script:AcState.Busy) { return }
        $script:AcState.Busy = $true
        try {
            $script:AcFinishTimer.Stop()
            if ($script:AcState.Code) { & $script:AcCaptureCookies }
            $script:AcForm.Close()
        } catch {
            Write-DebugLog ('Error while finishing sign-in: {0}' -f $_.Exception.Message)
            $script:AcForm.Close()
        } finally { $script:AcState.Busy = $false }
    })

    $script:AcStartUrl = $startUrl
    $script:AcForm.add_Shown({
        try { $script:AcWebView.Source = [Uri]$script:AcStartUrl }
        catch {
            $script:AcState.Error = 'WebView2 could not start: ' + $_.Exception.Message
            $script:AcForm.Close()
        }
    })

    try { [void]$script:AcForm.ShowDialog() }
    finally {
        try { $script:AcWebView.Dispose() } catch { }
        $script:AcForm.Dispose()
    }

    if ($script:AcState.Error) { throw $script:AcState.Error }
    if (-not $script:AcState.Code) {
        throw 'Sign-in cancelled or no authorization code received (enable Debug Log to see the last URL).'
    }

    # Exchange the authorization code for a bearer token (OAuth2 PKCE).
    # The server keeps reporting "code_verifier required" although the raw body
    # provably contains it. Which placement it actually reads is undocumented,
    # so the Custom Property "Token Variant" selects one - that way a variant
    # can be tried per sign-in without rebuilding the script. Variant meanings
    # are listed in docs/TROUBLESHOOTING.md.
    Write-DebugLog 'Exchanging authorization code for access token...'
    $code = $script:AcState.Code
    $ver  = $pkce.Verifier
    $ruri = $script:KpRedirectUri
    $cid  = $script:KpClientId

    # Reihenfolge und Kodierung wie in PassManClient.GetAccessToken: nur
    # redirect_uri wird kodiert, client_id geht mit rohen Klammern raus.
    $pCid   = 'client_id=' + $cid
    $pGrant = 'grant_type=authorization_code'
    $pCode  = 'code=' + $code
    $pRuri  = 'redirect_uri=' + [uri]::EscapeDataString($ruri)
    $pVer   = 'code_verifier=' + $ver
    $bodyFull = "$pCid&$pGrant&$pCode&$pRuri&$pVer"
    $tokenUrl = $Config.ServerUrl + '/OAuth2/Token'

    $recomputed = [Convert]::ToBase64String(([System.Security.Cryptography.SHA256]::Create()).ComputeHash([System.Text.Encoding]::ASCII.GetBytes($ver))).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    Write-DebugLog ('Token request: code(len={0}), code_verifier(len={1}), pkce_ok={2}' -f $code.Length, $ver.Length, ($recomputed -eq $pkce.Challenge))

    # Kopf des echten Clients: X-Pleasant-Header + die Session-Cookies aus dem
    # Browser-Login (PassManWebClient haengt beides an jeden Request).
    $hdrClient = @{}
    foreach ($k in $script:AcClientHeaders.Keys) { $hdrClient[$k] = $script:AcClientHeaders[$k] }
    $hdrFull = @{}
    foreach ($k in $hdrClient.Keys) { $hdrFull[$k] = $hdrClient[$k] }
    if ($script:AcState.CookieHeader) { $hdrFull['Cookie'] = $script:AcState.CookieHeader }

    if ($script:AcState.CookieHeader) {
        Write-DebugLog ('Session cookie header available ({0} chars).' -f $script:AcState.CookieHeader.Length)
    } else {
        Write-DebugLog 'WARNING: no session cookies captured - cookie-dependent variants cannot work.'
    }

    $variant = '1'
    if ($Config.ContainsKey('TokenVariant') -and $Config.TokenVariant -match '^\s*\d+\s*$') {
        $variant = $Config.TokenVariant.Trim()
    }

    # Variante 9 umgeht unseren HTTP-Code komplett.
    if ($variant -eq '9') {
        Write-DebugLog 'Token variant 9: delegating the exchange to the installed Pleasant client library.'
        return (Get-TokenViaPleasantClientDll -Code $code -Verifier $ver)
    }

    # Der echte Client wurde mitgeschnitten (eigene DLL gegen lokalen Listener):
    # POST /oauth2/token, Expect: 100-continue, Connection: Keep-Alive, KEIN
    # Accept-Header, kein Query-String, Body exakt wie oben. Variante 1 bildet
    # genau das nach; 2-8 variieren jeweils EINE Zutat davon.
    $tokenUrlLower = $Config.ServerUrl + '/oauth2/token'
    $postArgs = @{
        Uri            = $tokenUrlLower
        Body           = $bodyFull
        ExtraHeaders   = $hdrFull
        ExpectContinue = $true
        KeepAlive      = $true
        SendAccept     = $false
    }
    switch ($variant) {
        '1' { Write-DebugLog 'Token variant 1: byte-for-byte replication of the captured client request.' }
        '2' {
            Write-DebugLog 'Token variant 2: like 1 but WITHOUT session cookies.'
            $postArgs.ExtraHeaders = $hdrClient
        }
        '3' {
            Write-DebugLog 'Token variant 3: like 1 but path /OAuth2/Token (mixed case).'
            $postArgs.Uri = $tokenUrl
        }
        '4' {
            Write-DebugLog 'Token variant 4: like 1 but WITHOUT Expect: 100-continue.'
            $postArgs.ExpectContinue = $false
            $postArgs.KeepAlive = $false
        }
        '5' {
            Write-DebugLog 'Token variant 5: plain body only, no cookies, no headers, no Expect (pre-v17 baseline).'
            $postArgs.ExtraHeaders = $null
            $postArgs.ExpectContinue = $false
            $postArgs.KeepAlive = $false
            $postArgs.SendAccept = $true
        }
        '6' {
            Write-DebugLog 'Token variant 6: like 1 + code_verifier repeated in the query string.'
            $postArgs.Uri = $tokenUrlLower + '?' + $pVer
        }
        '7' {
            Write-DebugLog 'Token variant 7: like 1 but code_verifier FIRST in the body.'
            $postArgs.Body = "$pVer&$pCid&$pGrant&$pCode&$pRuri"
        }
        '8' {
            Write-DebugLog 'Token variant 8: like 1 but client_id percent-encoded.'
            $postArgs.Body = ('client_id=' + [uri]::EscapeDataString($cid)) + "&$pGrant&$pCode&$pRuri&$pVer"
        }
        default { Write-DebugLog ('Unknown token variant "{0}" - falling back to 1.' -f $variant) }
    }

    $r = Invoke-FormPost @postArgs
    if (-not $r.Ok) {
        Write-DebugLog ('Token endpoint error: HTTP {0}, body: [{1}]' -f $r.Status, $r.Content)
        throw (Add-LogHint ('Token exchange failed (variant {0}): HTTP {1} {2}' -f $variant, $r.Status, $r.Content))
    }
    $tok = $r.Content | ConvertFrom-Json
    if (-not $tok.access_token) { throw 'Token endpoint returned no access_token.' }

    $now = [System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $expiresAt = $null
    if ($tok.PSObject.Properties['expires_in'] -and $tok.expires_in) { $expiresAt = $now + [long]$tok.expires_in }
    if (-not $expiresAt) { $expiresAt = Get-JwtExpiry $tok.access_token }
    if (-not $expiresAt) { $expiresAt = $now + 1200 }

    Write-DebugLog 'Access token acquired via authorization code + PKCE.'
    return @{ Token = [string]$tok.access_token; ExpiresAt = [long]$expiresAt }
}

# ---------------------------------------------------------------------------
# Orchestration: cache -> (SSO auth-code | password) -> fill cache
# ---------------------------------------------------------------------------
function Get-AccessToken {
    $cached = Get-CachedToken
    if ($cached) { return $cached }

    $result = if ($Config.AuthMode -match '^(?i)sso$') { Get-TokenViaAuthCodePkce } else { Get-TokenViaPasswordGrant }
    Save-CachedToken -Token $result.Token -ExpiresAt $result.ExpiresAt
    return $result.Token
}

# GET auf die Pleasant-API inkl. automatischer Re-Authentifizierung,
# falls ein gecachtes Token serverseitig nicht mehr gueltig ist.
function Invoke-PleasantApi {
    param([string]$Path)
    $token = Get-AccessToken
    $uri = $Config.ServerUrl + $Path
    # Der echte Client schickt die X-Pleasant-Header an jeden Request, nicht
    # nur an den Token-Endpoint (PassManClient.GetPassManWebClient).
    $headers = Get-PleasantClientHeaders
    $headers['Accept'] = 'application/json'
    $headers['Authorization'] = 'Bearer ' + $token
    $r = Invoke-Http -Method 'GET' -Uri $uri -Headers $headers
    if ($r.Status -eq 401 -or $r.Status -eq 403) {
        Write-DebugLog ('HTTP {0} - token rejected, re-authenticating.' -f $r.Status)
        Clear-CachedToken
        $token = Get-AccessToken
        $headers['Authorization'] = 'Bearer ' + $token
        $r = Invoke-Http -Method 'GET' -Uri $uri -Headers $headers
    }
    if (-not $r.Ok) {
        throw ('API-Aufruf "{0}" fehlgeschlagen: HTTP {1} {2}' -f $Path, $r.Status, $r.Content)
    }
    return ($r.Content | ConvertFrom-Json)
}

# ============================================================================
#  Auth-Modus "WebClient" (Cookie-Modus)
#  Fuer Pleasant-Server mit erzwungenem SAML-SSO, bei denen der OAuth2-
#  Password-Grant deaktiviert ist und die REST-API damit nicht erreichbar ist
#  (siehe docs/SERVER-FINDINGS.md).
#
#  Idee: Anmeldung per WebView2 (SAML/Entra im Browser), danach die
#  Session-Cookies aus WebView2 in eine PowerShell-WebSession uebernehmen und
#  die INTERNE WebClient-API mit Cookie + Anti-Forgery-Token ansprechen:
#    - Ordnerbaum : GET  /WebClient/Main/CredentialList        (HTML, geparst)
#    - Eintraege   : POST /WebClient/CredentialListGrid/Select  (?CredentialGroupId=<id>)
#    - Passwort   : GET  /WebClient/Main/CopyPasswordPopup      (?credentialId=<id>)
#
#  Wichtig (aus Discovery bestaetigt): IsEncrypted=false, EncryptedCredentialKey=null
#  -> die Passwoerter kommen server-entschluesselt zurueck (kein E2E), Cookie-
#  Replay genuegt. Bei IsEncrypted=true muesste der echte WebClient entschluesseln
#  (nicht unterstuetzt) -> dann Fehlermeldung.
# ============================================================================

# --- Cookie-Cache (DPAPI) ---------------------------------------------------
function Get-CookieCachePath {
    $src = 'cookies|{0}|{1}' -f $Config.ServerUrl.ToLowerInvariant(), $env:USERNAME
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hash = ($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($src)) | ForEach-Object { $_.ToString('x2') }) -join ''
    return (Join-Path $script:AppDir ('cookies-' + $hash.Substring(0, 32) + '.dat'))
}

function Save-CookieSession {
    param([System.Collections.Generic.List[object]]$Cookies)
    if ($Config.UseCache -ne 'Yes') { return }
    try {
        Add-Type -AssemblyName System.Security
        $arr = @()
        foreach ($c in $Cookies) { $arr += @{ Name = $c.Name; Value = $c.Value; Domain = $c.Domain; Path = $c.Path } }
        $json = @{ saved = [System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); cookies = $arr } | ConvertTo-Json -Compress
        $enc = [System.Security.Cryptography.ProtectedData]::Protect([System.Text.Encoding]::UTF8.GetBytes($json), $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        [System.IO.File]::WriteAllBytes((Get-CookieCachePath), $enc)
        Write-DebugLog ('{0} cookies cached (DPAPI).' -f $arr.Count)
    } catch {
        Write-DebugLog ('Writing cookie cache failed: {0}' -f $_.Exception.Message)
    }
}

function Get-CachedCookieSession {
    if ($Config.UseCache -ne 'Yes') { return $null }
    $path = Get-CookieCachePath
    if (-not (Test-Path $path)) { return $null }
    try {
        Add-Type -AssemblyName System.Security
        $enc = [System.IO.File]::ReadAllBytes($path)
        $raw = [System.Security.Cryptography.ProtectedData]::Unprotect($enc, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        $obj = [System.Text.Encoding]::UTF8.GetString($raw) | ConvertFrom-Json
        $session = New-CookieWebSession $obj.cookies
        if (Test-WebClientSession $session) {
            Write-DebugLog 'Cookie cache valid.'
            return $session
        }
        Write-DebugLog 'Cached cookies no longer valid.'
    } catch {
        Write-DebugLog ('Cookie cache unreadable: {0}' -f $_.Exception.Message)
    }
    return $null
}

function Clear-CookieSession {
    Remove-Item -Path (Get-CookieCachePath) -Force -ErrorAction SilentlyContinue
}

function New-CookieWebSession {
    param($Cookies)
    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $srvHost = ([Uri]$Config.ServerUrl).Host
    foreach ($c in $Cookies) {
        try {
            $ck = New-Object System.Net.Cookie($c.Name, $c.Value, $(if ($c.Path) { $c.Path } else { '/' }), $(if ($c.Domain) { $c.Domain.TrimStart('.') } else { $srvHost }))
            $session.Cookies.Add($ck)
        } catch { }
    }
    return $session
}

# Session gueltig? Test ueber den echten API-Endpunkt GetTree:
# angemeldet -> JSON-Array; nicht angemeldet -> Redirect auf die SignIn-HTML.
function Test-WebClientSession {
    param($Session)
    try {
        $r = Invoke-WebRequest -Uri ($Config.ServerUrl + '/WebClient/Main/GetTree?id=') -WebSession $Session -UseBasicParsing -TimeoutSec 30 `
             -Headers @{ 'X-Requested-With' = 'XMLHttpRequest' } -ErrorAction Stop
        $content = [string]$r.Content
        $trimmed = $content.TrimStart()
        $looksJson = ($trimmed.StartsWith('[') -or $trimmed.StartsWith('{'))
        Write-DebugLog ('Session test GetTree: HTTP {0}, length {1}, jsonish={2}' -f [int]$r.StatusCode, $content.Length, $looksJson)
        if (-not $looksJson) {
            $snippet = ($content -replace '\s+', ' ')
            if ($snippet.Length -gt 160) { $snippet = $snippet.Substring(0, 160) }
            Write-DebugLog ('Session test: non-JSON response, start: {0}' -f $snippet)
        }
        return $looksJson
    } catch {
        Write-DebugLog ('Session test error: {0}' -f $_.Exception.Message)
        return $false
    }
}

# --- Anti-Forgery-Token aus /WebClient/Main lesen ---------------------------
function Get-AntiForgeryToken {
    param($Session)
    $r = Invoke-WebRequest -Uri ($Config.ServerUrl + '/WebClient/Main') -WebSession $Session -UseBasicParsing -TimeoutSec 30
    $m = [regex]::Match($r.Content, 'name="__RequestVerificationToken"[^>]*value="([^"]+)"')
    if (-not $m.Success) {
        $m = [regex]::Match($r.Content, 'value="([^"]+)"[^>]*name="__RequestVerificationToken"')
    }
    if ($m.Success) { return $m.Groups[1].Value }
    Write-DebugLog 'No __RequestVerificationToken found in /WebClient/Main.'
    return $null
}

# --- SSO-Login per WebView2, danach Cookies uebernehmen ----------------------
function Get-WebClientSession {
    $cached = Get-CachedCookieSession
    if ($cached) { Write-DebugLog 'Using cached cookie session.'; return $cached }

    $session = Invoke-WebClientSsoLogin   # in Common.ps1 (WebView2), returns WebSession
    Write-DebugLog 'Testing session against GetTree ...'
    if (-not (Test-WebClientSession $session)) {
        throw 'WebClient-Anmeldung fehlgeschlagen: Session nach SSO nicht gueltig (Cookies uebernommen, aber GetTree antwortet nicht mit JSON).'
    }
    Write-DebugLog 'Session valid.'
    # Cookies fuer den Cache einsammeln
    $cookieList = New-Object System.Collections.Generic.List[object]
    foreach ($c in $session.Cookies.GetCookies([Uri]$Config.ServerUrl)) { $cookieList.Add($c) }
    Save-CookieSession $cookieList
    return $session
}

# ============================================================================
#  Datenzugriff ueber die interne WebClient-API
# ============================================================================

# Eintraege (Credentials) eines Ordners holen
function Get-WebClientEntries {
    param($Session, [string]$FolderId, [string]$AntiForgery)
    $uri = $Config.ServerUrl + '/WebClient/CredentialListGrid/Select?CredentialGroupId=' + $FolderId
    $body = @{
        'sort'                     = ''
        'page'                     = '1'
        'pageSize'                 = '1000'
        'group'                    = ''
        'filter'                   = ''
        '__RequestVerificationToken' = $AntiForgery
        'data.take'                = '1000'
        'data.skip'                = '0'
        'data.page'                = '1'
        'data.pageSize'            = '1000'
    }
    $r = Invoke-WebRequest -Uri $uri -Method POST -WebSession $Session -Body $body -UseBasicParsing -TimeoutSec 60 `
         -Headers @{ 'X-Requested-With' = 'XMLHttpRequest' } -ContentType 'application/x-www-form-urlencoded'
    $data = $r.Content | ConvertFrom-Json
    if ($data.PSObject.Properties['Data'] -and $data.Data) {
        $entries = @($data.Data)
        Write-DebugLog ('  Folder {0}: {1} entries.' -f $FolderId, $entries.Count)
        return $entries
    }
    return @()
}

# Passwort eines Eintrags (Klartext, da server-entschluesselt)
function Get-WebClientPassword {
    param($Session, [string]$CredentialId)
    $uri = $Config.ServerUrl + '/WebClient/Main/CopyPasswordPopup?credentialId=' + $CredentialId
    $r = Invoke-WebRequest -Uri $uri -WebSession $Session -UseBasicParsing -TimeoutSec 60 -Headers @{ 'X-Requested-With' = 'XMLHttpRequest' }
    $obj = $r.Content | ConvertFrom-Json
    if (-not $obj.success) {
        throw ('Passwortabruf fehlgeschlagen: {0}' -f $obj.details)
    }
    if ($obj.decryptionData -and $obj.decryptionData.IsEncrypted) {
        throw 'Eintrag ist client-seitig verschluesselt (IsEncrypted=true) - Cookie-Modus kann das nicht entschluesseln.'
    }
    return [string]$obj.response
}

# Unmittelbare Unterordner eines Ordners (Kendo-Treeview-Read)
#   GET /WebClient/Main/GetTree?id=<id>  ->  [{id,name,hasChildren,expanded,spriteCssClass}]
function Get-WebClientChildren {
    param($Session, [string]$Id)
    $uri = $Config.ServerUrl + '/WebClient/Main/GetTree?id=' + [uri]::EscapeDataString($Id)
    $r = Invoke-WebRequest -Uri $uri -WebSession $Session -UseBasicParsing -TimeoutSec 60 -Headers @{ 'X-Requested-With' = 'XMLHttpRequest' }
    $nodes = $r.Content | ConvertFrom-Json
    if ($null -eq $nodes) { return @() }
    $arr = @($nodes)
    Write-DebugLog ('GetTree id="{0}" -> {1} children.' -f $Id, $arr.Count)
    return $arr
}

function ConvertTo-HtmlNotes {
    param($Notes)
    if ($null -eq $Notes) { return '' }
    return ([string]$Notes -replace "`r`n", '<br />' -replace "`r", '<br />' -replace "`n", '<br />')
}

# Einen Grid-Eintrag in ein Royal-TS-DynamicCredential-Objekt wandeln
function ConvertTo-DynCredential {
    param($Entry)
    $custom = @{}
    if ($Entry.PSObject.Properties['CustomFields'] -and $Entry.CustomFields) {
        foreach ($p in $Entry.CustomFields.PSObject.Properties) {
            if ($p.Value) { $custom[$p.Name] = [string]$p.Value }
        }
    }
    return [ordered]@{
        Type             = 'DynamicCredential'
        ID               = [string]$Entry.Id
        Name             = [string]$Entry.Name
        URL              = [string]$Entry.Url
        Username         = [string]$Entry.Username
        Notes            = (ConvertTo-HtmlNotes $Entry.Notes)
        Description      = [string]$Entry.Tags
        CustomProperties = $custom
    }
}

# Rekursiv: Ordner -> { Folder mit Unterordnern + DynamicCredentials }
function Build-WebClientFolder {
    param($Session, [string]$FolderId, [string]$FolderName, [string]$AntiForgery)
    $objects = New-Object System.Collections.ArrayList

    foreach ($child in (Get-WebClientChildren -Session $Session -Id $FolderId)) {
        $sub = Build-WebClientFolder -Session $Session -FolderId $child.id -FolderName $child.name -AntiForgery $AntiForgery
        [void]$objects.Add($sub)
    }
    foreach ($entry in (Get-WebClientEntries -Session $Session -FolderId $FolderId -AntiForgery $AntiForgery)) {
        [void]$objects.Add((ConvertTo-DynCredential $entry))
    }

    return [ordered]@{
        Type    = 'Folder'
        ID      = $FolderId
        Name    = $FolderName
        Objects = $objects
    }
}

# Kompletten Store (Top-Level-Objekte) ueber den Cookie-Modus aufbauen.
# Der Wurzelordner ("Root") wird nicht als Ordner angelegt, nur sein Inhalt.
function Get-WebClientStoreObjects {
    $session = Get-WebClientSession
    $anti = Get-AntiForgeryToken $session
    Write-DebugLog ('Anti-forgery token {0}' -f $(if ($anti) { 'found' } else { 'NOT found' }))

    $topNodes = @(Get-WebClientChildren -Session $session -Id '')
    Write-DebugLog ('Root: {0} top-level nodes.' -f $topNodes.Count)

    $store = New-Object System.Collections.ArrayList
    foreach ($top in $topNodes) {
        if ([string]$top.name -eq 'Root') {
            # Root aufloesen: dessen Unterordner + Eintraege direkt oben einhaengen
            foreach ($child in (Get-WebClientChildren -Session $session -Id $top.id)) {
                [void]$store.Add((Build-WebClientFolder -Session $session -FolderId $child.id -FolderName $child.name -AntiForgery $anti))
            }
            foreach ($entry in (Get-WebClientEntries -Session $session -FolderId $top.id -AntiForgery $anti)) {
                [void]$store.Add((ConvertTo-DynCredential $entry))
            }
        } else {
            [void]$store.Add((Build-WebClientFolder -Session $session -FolderId $top.id -FolderName $top.name -AntiForgery $anti))
        }
    }
    return $store
}

# ============================================================================
#  Hauptteil Dynamic Folder: Ordnerbaum (API v5) laden und in das
#  rJSON-Format von Royal TS umwandeln.
# ============================================================================

function Convert-NotesToHtml {
    param($Notes)
    if ($null -eq $Notes) { return '' }
    return ([string]$Notes -replace "`r`n", '<br />' -replace "`r", '<br />' -replace "`n", '<br />')
}

function Convert-Credential {
    param($Cred)
    $color = ''
    if ($Cred.PSObject.Properties['CustomApplicationFields'] -and $Cred.CustomApplicationFields) {
        if ($Cred.CustomApplicationFields.PSObject.Properties['ForegroundColor']) {
            $color = [string]$Cred.CustomApplicationFields.ForegroundColor
        }
    }
    $tags = @()
    if ($Cred.PSObject.Properties['Tags'] -and $Cred.Tags) {
        $tags = @($Cred.Tags | ForEach-Object { $_.Name })
    }
    return [ordered]@{
        Type             = 'DynamicCredential'
        ID               = [string]$Cred.Id
        Name             = [string]$Cred.Name
        Color            = $color
        URL              = [string]$Cred.Url
        Username         = [string]$Cred.Username
        Notes            = (Convert-NotesToHtml $Cred.Notes)
        Description      = ($tags -join ', ')
        CustomProperties = $Cred.CustomUserFields
    }
}

# Liefert die Objekte (Unterordner + Credentials) einer Ordnerebene.
function Get-FolderObjects {
    param($Group)
    $objects = New-Object System.Collections.ArrayList
    if ($Group.PSObject.Properties['Children'] -and $Group.Children) {
        foreach ($child in @($Group.Children)) {
            if ($child) { [void]$objects.Add((Convert-Folder $child)) }
        }
    }
    if ($Group.PSObject.Properties['Credentials'] -and $Group.Credentials) {
        foreach ($cred in @($Group.Credentials)) {
            if ($cred) { [void]$objects.Add((Convert-Credential $cred)) }
        }
    }
    return , $objects
}

function Convert-Folder {
    param($Group)
    return [ordered]@{
        Type    = 'Folder'
        ID      = [string]$Group.Id
        Name    = [string]$Group.Name
        Notes   = (Convert-NotesToHtml $Group.Notes)
        Objects = (Get-FolderObjects $Group)
    }
}

# --- Hauptablauf ------------------------------------------------------------
Initialize-Config
Initialize-Http

if ($Config.AuthMode -match '^(?i)webclient$') {
    # Cookie-Modus: interne WebClient-API (fuer SSO-Server ohne API-Token)
    $storeObjects = Get-WebClientStoreObjects
} else {
    # REST-API (Bearer): SSO-Bearer-Capture oder Password-Grant
    $tree = Invoke-PleasantApi '/api/v5/rest/folders/'
    $storeObjects = New-Object System.Collections.ArrayList
    foreach ($group in @($tree)) {
        if (-not $group) { continue }
        if ($group.ParentId -eq '00000000-0000-0000-0000-000000000000') {
            # Root-Ordner selbst nicht anlegen, nur dessen Inhalt
            foreach ($obj in (Get-FolderObjects $group)) { [void]$storeObjects.Add($obj) }
        } else {
            [void]$storeObjects.Add((Convert-Folder $group))
        }
    }
}

Write-DebugLog ('Folder tree loaded: {0} objects at top level.' -f @($storeObjects).Count)

@{ Objects = $storeObjects } | ConvertTo-Json -Depth 100 -Compress
