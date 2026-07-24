# ============================================================================
#  build.ps1 – erzeugt aus den Quelldateien in src\ die importierbare
#  Royal-TS-Datei dist\Pleasant Password (PowerShell SSO).rdfe sowie die
#  beiden vollständigen Skripte (praktisch zum Debuggen im Script-Editor).
# ============================================================================
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if (-not $root) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }

function Read-Src([string]$Name) {
    Get-Content -Path (Join-Path $root "src\$Name") -Raw -Encoding UTF8
}

$common = Read-Src 'Common.ps1'

$folderScript = (Read-Src 'Header.DynamicFolder.ps1') + "`r`n" + $common + "`r`n" + (Read-Src 'Body.DynamicFolder.ps1')
$dyncredScript = (Read-Src 'Header.DynamicCredential.ps1') + "`r`n" + $common + "`r`n" + (Read-Src 'Body.DynamicCredential.ps1')

# Syntax-Check beider generierter Skripte
foreach ($pair in @(@('DynamicFolder', $folderScript), @('DynamicCredential', $dyncredScript))) {
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($pair[1], [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) {
        $errors | ForEach-Object { Write-Host ("{0}: Zeile {1}: {2}" -f $pair[0], $_.Extent.StartLineNumber, $_.Message) -ForegroundColor Red }
        throw "Syntaxfehler im generierten Skript '$($pair[0])'."
    }
}

$notesHtml = @'
<h2><strong>Pleasant Password Server (PowerShell, SSO)</strong></h2>
<p><strong>Version</strong>: 1.0.0<br />
<strong>Autor</strong>: Marco Thamm / Medialine (Vibecoding) &ndash; basierend auf dem Python-Sample von Royal Apps<br />
<strong>Repo</strong>: https://github.com/thammi96/royal-pleasant</p>
<p>Dynamic Folder f&uuml;r Pleasant Password Server auf PowerShell-Basis mit zwei Auth-Modi:</p>
<ul>
<li><strong>SSO</strong>: SAML-Anmeldung &uuml;ber ein WebView2-Browserfenster (WebClient), Token-&Uuml;bernahme in die REST-API. MFA/Conditional Access &uuml;bernimmt der IdP.</li>
<li><strong>Password</strong>: klassischer OAuth2 Password Grant inkl. OTP/MFA-Header (wie das Python-Original).</li>
</ul>
<p>Tokens werden DPAPI-verschl&uuml;sselt gecacht (%LOCALAPPDATA%\RoyalTS-PleasantPPS), damit Reload und Passwortabruf ohne erneute Anmeldung funktionieren.</p>
<p><strong>Voraussetzungen SSO-Modus</strong>: WebView2 Evergreen Runtime + einmalig tools\Install-WebView2Sdk.ps1 aus dem Repo ausf&uuml;hren. Details und Troubleshooting: siehe README im Repo.</p>
'@ -replace "`r`n", "`n"

$rdfe = [ordered]@{
    Name    = 'Dynamic Folder Export'
    Objects = @(
        [ordered]@{
            Type             = 'DynamicFolder'
            Name             = 'Pleasant Password Server (PowerShell, SSO)'
            Description      = 'Dynamic Folder fuer Pleasant Password Server (PowerShell) mit SAML-SSO via WebView2, OAuth2-Password-Grant inkl. MFA, DPAPI-Token-Cache und API v5.'
            Notes            = $notesHtml
            CustomProperties = @(
                [ordered]@{ Name = 'Server URL';        Type = 'URL';   Value = 'TODO' }
                [ordered]@{ Name = 'Auth Mode';         Type = 'Text';  Value = 'SSO' }
                [ordered]@{ Name = 'Omit Domain';       Type = 'YesNo'; Value = 'False' }
                [ordered]@{ Name = 'Ignore SSL Errors'; Type = 'YesNo'; Value = 'False' }
                [ordered]@{ Name = 'Use Token Cache';   Type = 'YesNo'; Value = 'True' }
                [ordered]@{ Name = 'Debug Log';         Type = 'YesNo'; Value = 'False' }
            )
            Script                             = $folderScript
            ScriptInterpreter                  = 'powershell'
            DynamicCredentialScript            = $dyncredScript
            DynamicCredentialScriptInterpreter = 'powershell'
        }
    )
}

$distDir = Join-Path $root 'dist'
New-Item -ItemType Directory -Path $distDir -Force | Out-Null

$rdfePath = Join-Path $distDir 'Pleasant Password (PowerShell SSO).rdfe'
$json = $rdfe | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText($rdfePath, $json, (New-Object System.Text.UTF8Encoding($false)))

[System.IO.File]::WriteAllText((Join-Path $distDir 'DynamicFolder.full.ps1'), $folderScript, (New-Object System.Text.UTF8Encoding($true)))
[System.IO.File]::WriteAllText((Join-Path $distDir 'DynamicCredential.full.ps1'), $dyncredScript, (New-Object System.Text.UTF8Encoding($true)))

Write-Host "OK: $rdfePath"
Write-Host 'OK: dist\DynamicFolder.full.ps1, dist\DynamicCredential.full.ps1'
