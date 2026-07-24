# ============================================================================
#  Pleasant Password Server – Royal TS Dynamic Folder (PowerShell)
#  Gemeinsamer Kern: HTTP, Token-Cache (DPAPI), Password-Grant (+OTP/MFA),
#  SSO-Anmeldung über WebView2 (SAML im Browser, Token-Capture).
#
#  Diese Datei wird von build.ps1 in beide Skripte eingebettet
#  (Dynamic Folder Script und Dynamic Credential Script).
# ============================================================================

$ErrorActionPreference = 'Stop'

$script:IsPsCore = ($PSVersionTable.PSEdition -eq 'Core')
$script:AppDir   = Join-Path $env:LOCALAPPDATA 'RoyalTS-PleasantPPS'
if (-not (Test-Path $script:AppDir)) {
    New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null
}

# ---------------------------------------------------------------------------
# Logging (nur wenn Custom Property "Debug Log" = Yes)
# ---------------------------------------------------------------------------
function Write-DebugLog {
    param([string]$Message)
    if ($Config.DebugLog -ne 'Yes') { return }
    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Config.ScriptKind, $Message
    try { Add-Content -Path (Join-Path $script:AppDir 'debug.log') -Value $line -Encoding UTF8 } catch { }
}

# ---------------------------------------------------------------------------
# Konfiguration prüfen/normalisieren
# ---------------------------------------------------------------------------
function Initialize-Config {
    if (-not $Config.ServerUrl -or $Config.ServerUrl -eq 'TODO') {
        throw 'Custom Property "Server URL" ist nicht gesetzt (Dynamic Folder -> Eigenschaften -> Custom Properties).'
    }
    $Config.ServerUrl = $Config.ServerUrl.TrimEnd('/')
    if ($Config.AuthMode -notmatch '^(?i)(sso|password)$') {
        throw ('Custom Property "Auth Mode" muss "SSO" oder "Password" sein (aktuell: "{0}").' -f $Config.AuthMode)
    }
    Write-DebugLog ('Start – Server={0} AuthMode={1} PS={2}/{3}' -f $Config.ServerUrl, $Config.AuthMode, $PSVersionTable.PSVersion, $PSVersionTable.PSEdition)
}

# ---------------------------------------------------------------------------
# HTTP-Grundlagen (TLS 1.2, optional Zertifikatsprüfung deaktivieren)
# ---------------------------------------------------------------------------
function Initialize-Http {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch { }
    if ($Config.IgnoreSsl -eq 'Yes' -and -not $script:IsPsCore) {
        [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
    }
}

# Dünner Wrapper um Invoke-WebRequest: wirft bei HTTP-Fehlern NICHT, sondern
# liefert Status/Header/Content zurück (wird u. a. für die OTP-Header benötigt).
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
                try {
                    $sr = New-Object System.IO.StreamReader($ex.Response.GetResponseStream())
                    $content = $sr.ReadToEnd()
                    $sr.Close()
                } catch { }
            }
        }
        if ($status -eq 0) {
            throw ('Verbindung zu "{0}" fehlgeschlagen: {1}' -f $Uri, $ex.Message)
        }
        return @{ Ok = $false; Status = $status; Content = $content; Headers = $h }
    }
}

function Get-HeaderValue {
    param([hashtable]$Headers, [string]$Name)
    foreach ($k in $Headers.Keys) {
        if ($k -ieq $Name) { return [string]$Headers[$k] }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Token-Cache: DPAPI-verschlüsselt (nur aktueller Windows-Benutzer) unter
# %LOCALAPPDATA%\RoyalTS-PleasantPPS\token-<hash>.dat
# Verhindert, dass bei jedem Reload / jedem Passwort-Abruf neu angemeldet
# werden muss – wichtig, weil das Dynamic-Credential-Skript pro Abruf
# separat ausgeführt wird.
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
            Write-DebugLog ('Token-Cache-Treffer, gültig bis {0:u}' -f [System.DateTimeOffset]::FromUnixTimeSeconds([long]$obj.expires_at).LocalDateTime)
            return [string]$obj.access_token
        }
        Write-DebugLog 'Token im Cache ist abgelaufen.'
    } catch {
        Write-DebugLog ('Token-Cache unlesbar: {0}' -f $_.Exception.Message)
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
        Write-DebugLog ('Token im Cache gespeichert, gültig bis {0:u}' -f [System.DateTimeOffset]::FromUnixTimeSeconds($ExpiresAt).LocalDateTime)
    } catch {
        Write-DebugLog ('Token-Cache schreiben fehlgeschlagen: {0}' -f $_.Exception.Message)
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

# Prüft, ob ein Token von der API akzeptiert wird (alles außer 401/403 gilt
# als authentifiziert – so bleibt der Check unabhängig vom konkreten Endpunkt).
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
# Einfacher Eingabedialog (für OTP im Password-Modus)
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
# inkl. MFA über die X-Pleasant-OTP-Header (wie im Python-Original).
# Doku: https://pleasantpasswords.com/info/pleasant-password-server/
#       m-programmatic-access/restful-api/oauth-two-factor-support
# ---------------------------------------------------------------------------
function Get-TokenViaPasswordGrant {
    $user = if ($Config.OmitDomain -eq 'Yes') { $Config.UsernameNoDomain } else { $Config.Username }
    if (-not $user -or -not $Config.Password) {
        throw 'Auth Mode "Password": Dem Dynamic Folder müssen Zugangsdaten zugewiesen sein (Eigenschaften -> Zugangsdaten).'
    }

    $tokenUri = $Config.ServerUrl + '/OAuth2/Token'
    $body     = @{ grant_type = 'password'; username = $user; password = $Config.Password }

    $r = Invoke-Http -Method 'POST' -Uri $tokenUri -Body $body -ContentType 'application/x-www-form-urlencoded'

    if (-not $r.Ok -and (Get-HeaderValue $r.Headers 'X-Pleasant-OTP') -eq 'required') {
        $provider = Get-HeaderValue $r.Headers 'X-Pleasant-OTP-Provider'
        Write-DebugLog ('MFA erforderlich, Provider: {0}' -f $provider)
        $otp = Show-InputDialog ('Einmalpasswort (OTP) für MFA eingeben' + $(if ($provider) { " - Provider: $provider" } else { '' }) + ':')
        if (-not $otp) { throw 'MFA abgebrochen: kein OTP eingegeben.' }
        $otpHeaders = @{ 'X-Pleasant-OTP-Provider' = $provider; 'X-Pleasant-OTP' = $otp }
        $r = Invoke-Http -Method 'POST' -Uri $tokenUri -Body $body -ContentType 'application/x-www-form-urlencoded' -Headers $otpHeaders
    }

    if (-not $r.Ok) {
        if ($r.Status -eq 400) {
            throw ('Anmeldung fehlgeschlagen (HTTP 400). Häufige Ursache: redundanter Domänenname im Benutzernamen -> Custom Property "Omit Domain" auf Yes setzen. Bei SSO-only-Konten muss im Pleasant-Server "Allow Exception For Direct Sign-In" aktiv sein oder Auth Mode "SSO" verwendet werden. Details: {0}' -f $r.Content)
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
# WebView2-SDK-Bootstrap: Royal TS führt PowerShell-Skripte mit Windows
# PowerShell 5.1 (.NET Framework) aus. Die WebView2 Evergreen *Runtime* ist
# auf Win 10/11 vorhanden, aber die managed SDK-Wrapper (net462) fehlen ->
# beim ersten SSO-Lauf automatisch von nuget.org nachladen.
# ---------------------------------------------------------------------------
function Install-WebView2SdkAuto {
    $libDir  = Join-Path $script:AppDir 'lib'
    $version = '1.0.2592.51'
    Write-DebugLog ('WebView2-SDK nicht gefunden - lade Version {0} von nuget.org ...' -f $version)
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
        Write-DebugLog ('WebView2-SDK installiert nach {0}' -f $libDir)
        return $libDir
    } finally {
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# Auth-Modus "SSO": Die Pleasant-API kennt offiziell nur den Password-Grant.
# Für SAML-SSO-Konten öffnen wir daher ein WebView2-Fenster mit dem Pleasant
# WebClient. Die SAML-Anmeldung (inkl. MFA/Conditional Access) übernimmt der
# IdP im Browser. Sobald der WebClient angemeldet ist, ruft er die REST-API
# mit einem Bearer-Token auf – dieses Token fangen wir ab:
#   1. primär über die Authorization-Header der WebClient-Requests
#      (WebResourceRequested-Event),
#   2. sekundär über einen Scan von session-/localStorage nach
#      access_token-/JWT-Mustern.
# Jeder Kandidat wird gegen die API verifiziert, bevor er verwendet wird.
# Das WebView2-Profil ist persistent -> Folge-Anmeldungen laufen i. d. R.
# ohne erneute Passworteingabe (Silent SSO), danach greift der Token-Cache.
# ---------------------------------------------------------------------------
function Get-TokenViaSso {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
        throw 'SSO-Modus benötigt einen STA-Thread (WebView2/WinForms). Bitte im Royal-TS-Kontext ausführen oder Auth Mode "Password" verwenden.'
    }

    # --- WebView2-SDK-Assemblies suchen ------------------------------------
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
                    Write-DebugLog ('WebView2-Assembly aus "{0}" nicht ladbar ({1}) – nächster Kandidat.' -f $d, $_.Exception.Message)
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
            Write-DebugLog ('Auto-Download des WebView2-SDK fehlgeschlagen: {0}' -f $_.Exception.Message)
        }
    }
    if (-not $winFormsDll) {
        throw ('WebView2-SDK-Assemblies nicht gefunden/ladbar und Auto-Download von nuget.org fehlgeschlagen (Proxy/kein Internet?). Manuell "tools\Install-WebView2Sdk.ps1" aus dem Repo ausführen (installiert nach {0}\lib) oder Pfad über die Umgebungsvariable PLEASANT_WEBVIEW2_DIR vorgeben. Alternativ Auth Mode "Password" verwenden.' -f $script:AppDir)
    }
    Write-DebugLog ('WebView2-SDK geladen aus: {0}' -f (Split-Path -Parent $winFormsDll))

    # Nativer WebView2Loader muss auffindbar sein (liegt neben den SDK-DLLs
    # bzw. in x86-Unterordner) -> Verzeichnis in PATH aufnehmen.
    $libDir = Split-Path -Parent $coreDll
    $loaderDir = if ([Environment]::Is64BitProcess) { $libDir } else { Join-Path $libDir 'x86' }
    if (Test-Path $loaderDir) { $env:PATH = $loaderDir + ';' + $env:PATH }

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

    $script:SsoForm = New-Object System.Windows.Forms.Form
    $script:SsoForm.Text          = 'Pleasant Password Server - SSO-Anmeldung (Fenster schließt sich automatisch)'
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

    $script:SsoForm.add_Shown({
        $script:SsoTimer.Start()
        try {
            $script:SsoWebView.Source = [Uri]($Config.ServerUrl + '/WebClient')
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
        throw 'SSO-Anmeldung abgebrochen oder es konnte kein API-Token aus der WebClient-Sitzung übernommen werden (Details ggf. mit "Debug Log" = Yes nachvollziehen).'
    }
    Write-DebugLog 'SSO-Token erfolgreich übernommen.'
    return @{ Token = $script:SsoState.Token; ExpiresAt = [long]$script:SsoState.ExpiresAt }
}

# ---------------------------------------------------------------------------
# Orchestrierung: Cache -> (SSO | Password) -> Cache füllen
# ---------------------------------------------------------------------------
function Get-AccessToken {
    $cached = Get-CachedToken
    if ($cached) { return $cached }

    $result = if ($Config.AuthMode -match '^(?i)sso$') { Get-TokenViaSso } else { Get-TokenViaPasswordGrant }
    Save-CachedToken -Token $result.Token -ExpiresAt $result.ExpiresAt
    return $result.Token
}

# GET auf die Pleasant-API inkl. automatischer Re-Authentifizierung,
# falls ein gecachtes Token serverseitig nicht mehr gültig ist.
function Invoke-PleasantApi {
    param([string]$Path)
    $token = Get-AccessToken
    $uri = $Config.ServerUrl + $Path
    $r = Invoke-Http -Method 'GET' -Uri $uri -Headers @{ Accept = 'application/json'; Authorization = 'Bearer ' + $token }
    if ($r.Status -eq 401 -or $r.Status -eq 403) {
        Write-DebugLog ('HTTP {0} – Token verworfen, neue Anmeldung.' -f $r.Status)
        Clear-CachedToken
        $token = Get-AccessToken
        $r = Invoke-Http -Method 'GET' -Uri $uri -Headers @{ Accept = 'application/json'; Authorization = 'Bearer ' + $token }
    }
    if (-not $r.Ok) {
        throw ('API-Aufruf "{0}" fehlgeschlagen: HTTP {1} {2}' -f $Path, $r.Status, $r.Content)
    }
    return ($r.Content | ConvertFrom-Json)
}
