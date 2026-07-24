# ============================================================================
#  Auth-Modus "WebClient" (Cookie-Modus)
#  Für Pleasant-Server mit erzwungenem SAML-SSO, bei denen der OAuth2-
#  Password-Grant deaktiviert ist und die REST-API damit nicht erreichbar ist
#  (siehe docs/SERVER-FINDINGS.md).
#
#  Idee: Anmeldung per WebView2 (SAML/Entra im Browser), danach die
#  Session-Cookies aus WebView2 in eine PowerShell-WebSession übernehmen und
#  die INTERNE WebClient-API mit Cookie + Anti-Forgery-Token ansprechen:
#    - Ordnerbaum : GET  /WebClient/Main/CredentialList        (HTML, geparst)
#    - Einträge   : POST /WebClient/CredentialListGrid/Select  (?CredentialGroupId=<id>)
#    - Passwort   : GET  /WebClient/Main/CopyPasswordPopup      (?credentialId=<id>)
#
#  Wichtig (aus Discovery bestätigt): IsEncrypted=false, EncryptedCredentialKey=null
#  -> die Passwörter kommen server-entschlüsselt zurück (kein E2E), Cookie-
#  Replay genügt. Bei IsEncrypted=true müsste der echte WebClient entschlüsseln
#  (nicht unterstützt) -> dann Fehlermeldung.
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
        Write-DebugLog ('{0} Cookies DPAPI-gecacht.' -f $arr.Count)
    } catch {
        Write-DebugLog ('Cookie-Cache schreiben fehlgeschlagen: {0}' -f $_.Exception.Message)
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
            Write-DebugLog 'Cookie-Cache gültig.'
            return $session
        }
        Write-DebugLog 'Gecachte Cookies nicht mehr gültig.'
    } catch {
        Write-DebugLog ('Cookie-Cache unlesbar: {0}' -f $_.Exception.Message)
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

# Session gültig? (angemeldete /WebClient/Main-Seite statt Redirect auf SignIn)
function Test-WebClientSession {
    param($Session)
    try {
        $r = Invoke-WebRequest -Uri ($Config.ServerUrl + '/WebClient/Main') -WebSession $Session -UseBasicParsing -MaximumRedirection 0 -TimeoutSec 30 -ErrorAction Stop
        return ($r.StatusCode -eq 200 -and $r.Content -notmatch 'SingleSignOn|Account/SignIn')
    } catch {
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
    Write-DebugLog 'Kein __RequestVerificationToken in /WebClient/Main gefunden.'
    return $null
}

# --- SSO-Login per WebView2, danach Cookies übernehmen ----------------------
function Get-WebClientSession {
    $cached = Get-CachedCookieSession
    if ($cached) { Write-DebugLog 'Verwende gecachte Cookie-Session.'; return $cached }

    $session = Invoke-WebClientSsoLogin   # in Common.ps1 (WebView2), liefert WebSession
    Write-DebugLog 'Pruefe Session gegen /WebClient/Main ...'
    if (-not (Test-WebClientSession $session)) {
        throw 'WebClient-Anmeldung fehlgeschlagen: Session nach SSO nicht gültig (Cookies uebernommen, aber /WebClient/Main antwortet nicht angemeldet).'
    }
    Write-DebugLog 'Session gueltig.'
    # Cookies für den Cache einsammeln
    $cookieList = New-Object System.Collections.Generic.List[object]
    foreach ($c in $session.Cookies.GetCookies([Uri]$Config.ServerUrl)) { $cookieList.Add($c) }
    Save-CookieSession $cookieList
    return $session
}

# ============================================================================
#  Datenzugriff über die interne WebClient-API
# ============================================================================

# Einträge (Credentials) eines Ordners holen
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
        Write-DebugLog ('  Ordner {0}: {1} Eintraege.' -f $FolderId, $entries.Count)
        return $entries
    }
    return @()
}

# Passwort eines Eintrags (Klartext, da server-entschlüsselt)
function Get-WebClientPassword {
    param($Session, [string]$CredentialId)
    $uri = $Config.ServerUrl + '/WebClient/Main/CopyPasswordPopup?credentialId=' + $CredentialId
    $r = Invoke-WebRequest -Uri $uri -WebSession $Session -UseBasicParsing -TimeoutSec 60 -Headers @{ 'X-Requested-With' = 'XMLHttpRequest' }
    $obj = $r.Content | ConvertFrom-Json
    if (-not $obj.success) {
        throw ('Passwortabruf fehlgeschlagen: {0}' -f $obj.details)
    }
    if ($obj.decryptionData -and $obj.decryptionData.IsEncrypted) {
        throw 'Eintrag ist client-seitig verschlüsselt (IsEncrypted=true) - Cookie-Modus kann das nicht entschlüsseln.'
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
    Write-DebugLog ('GetTree id="{0}" -> {1} Kinder.' -f $Id, $arr.Count)
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

# Kompletten Store (Top-Level-Objekte) über den Cookie-Modus aufbauen.
# Der Wurzelordner ("Root") wird nicht als Ordner angelegt, nur sein Inhalt.
function Get-WebClientStoreObjects {
    $session = Get-WebClientSession
    $anti = Get-AntiForgeryToken $session
    Write-DebugLog ('Anti-Forgery-Token {0}' -f $(if ($anti) { 'gefunden' } else { 'NICHT gefunden' }))

    $topNodes = @(Get-WebClientChildren -Session $session -Id '')
    Write-DebugLog ('Wurzel: {0} Top-Level-Knoten.' -f $topNodes.Count)

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
