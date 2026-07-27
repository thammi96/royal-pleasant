# ============================================================================
#  build.ps1 – erzeugt aus den Quelldateien in src\ die importierbaren
#  Royal-TS-Dateien dist\*.rdfx (aktuelles XML-Format) und dist\*.rdfe
#  (Legacy-JSON) sowie die beiden vollständigen Skripte (praktisch zum
#  Debuggen im Script-Editor).
# ============================================================================
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if (-not $root) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }

function Read-Src([string]$Name) {
    Get-Content -Path (Join-Path $root "src\$Name") -Raw -Encoding UTF8
}

$common    = Read-Src 'Common.ps1'
$webclient = Read-Src 'WebClientMode.ps1'
$core = $common + "`r`n" + $webclient

$folderScript = (Read-Src 'Header.DynamicFolder.ps1') + "`r`n" + $core + "`r`n" + (Read-Src 'Body.DynamicFolder.ps1')
$dyncredScript = (Read-Src 'Header.DynamicCredential.ps1') + "`r`n" + $core + "`r`n" + (Read-Src 'Body.DynamicCredential.ps1')

# Royal TS uebergibt Skripte je nach Version ohne BOM an Windows PowerShell 5.1,
# das dann ANSI annimmt -> Umlaute/typografische Zeichen wuerden zerschossen.
# Deshalb: eingebettete Skripte strikt auf ASCII transliterieren.
function ConvertTo-Ascii([string]$Text) {
    $map = @(
        @('ä', 'ae'), @('ö', 'oe'), @('ü', 'ue'), @('Ä', 'Ae'), @('Ö', 'Oe'), @('Ü', 'Ue'), @('ß', 'ss'),
        @([string][char]0x201E, '"'), @([string][char]0x201C, '"'), @([string][char]0x201D, '"'),
        @([string][char]0x201A, "'"), @([string][char]0x2018, "'"), @([string][char]0x2019, "'"),
        @([string][char]0x2013, '-'), @([string][char]0x2014, '-'), @([string][char]0x2026, '...'),
        @([string][char]0x2192, '->')
    )
    foreach ($pair in $map) { $Text = $Text.Replace([string]$pair[0], [string]$pair[1]) }
    $nonAscii = [regex]::Matches($Text, '[^\x00-\x7F]') | ForEach-Object { $_.Value } | Sort-Object -Unique
    if ($nonAscii) {
        throw ('Nicht-ASCII-Zeichen nach Transliteration uebrig: ' + (($nonAscii | ForEach-Object { '{0} (U+{1:X4})' -f $_, [int][char]$_ }) -join ', '))
    }
    return $Text
}
$folderScript  = ConvertTo-Ascii $folderScript
$dyncredScript = ConvertTo-Ascii $dyncredScript

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
                [ordered]@{ Name = 'SSO Login URL';     Type = 'URL';   Value = '' }
                [ordered]@{ Name = 'Auth Mode';         Type = 'Text';  Value = 'SSO' }
                [ordered]@{ Name = 'Token Variant';     Type = 'Text';  Value = '1' }
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

# --- rdfx (aktuelles XML-Format, Struktur wie Toolbox-Samples) --------------
$meta = $rdfe.Objects[0]
$xml  = New-Object System.Xml.XmlDocument
$root = $xml.AppendChild($xml.CreateElement('DynamicFolderExport'))
[void]$root.AppendChild($xml.CreateElement('Name')).AppendChild($xml.CreateTextNode('Dynamic Folder Export'))
$objects = $root.AppendChild($xml.CreateElement('Objects'))
$obj = $objects.AppendChild($xml.CreateElement('DynamicFolderExportObject'))

function Add-XmlText([System.Xml.XmlElement]$Parent, [string]$Name, [string]$Text) {
    $el = $Parent.AppendChild($xml.CreateElement($Name))
    if ($Text) { [void]$el.AppendChild($xml.CreateTextNode($Text)) }
    return $el
}
function Add-XmlCData([System.Xml.XmlElement]$Parent, [string]$Name, [string]$Text) {
    $el = $Parent.AppendChild($xml.CreateElement($Name))
    [void]$el.AppendChild($xml.CreateCDataSection($Text))
    return $el
}

[void](Add-XmlText $obj 'Type' 'DynamicFolder')
[void](Add-XmlText $obj 'Name' $meta.Name)
[void](Add-XmlText $obj 'Description' $meta.Description)
[void](Add-XmlCData $obj 'Notes' $meta.Notes)
$propsEl = $obj.AppendChild($xml.CreateElement('CustomProperties'))
foreach ($p in $meta.CustomProperties) {
    $pEl = $propsEl.AppendChild($xml.CreateElement('CustomProperty'))
    [void](Add-XmlText $pEl 'Name' $p.Name)
    [void](Add-XmlText $pEl 'Type' $p.Type)
    [void](Add-XmlText $pEl 'Value' $p.Value)
}
[void](Add-XmlText $obj 'ScriptInterpreter' 'powershell')
[void](Add-XmlCData $obj 'Script' $folderScript)
[void](Add-XmlText $obj 'DynamicCredentialScriptInterpreter' 'powershell')
[void](Add-XmlCData $obj 'DynamicCredentialScript' $dyncredScript)
[void](Add-XmlText $obj 'DynamicFolderScriptTokenMode' 'ReplaceInline')
[void](Add-XmlText $obj 'DynamicFolderScriptEnvironmentPrefix' 'DynFolder_')
$tok1 = $obj.AppendChild($xml.CreateElement('DynamicFolderScriptTokens'))
[void]$tok1.AppendChild($xml.CreateElement('Token'))
[void](Add-XmlText $obj 'DynamicCredentialScriptTokenMode' 'ReplaceInline')
[void](Add-XmlText $obj 'DynamicCredentialScriptEnvironmentPrefix' 'DynCredential_')
$tok2 = $obj.AppendChild($xml.CreateElement('DynamicCredentialScriptTokens'))
[void]$tok2.AppendChild($xml.CreateElement('Token'))

$rdfxPath = Join-Path $distDir 'Pleasant Password (PowerShell SSO).rdfx'
$settings = New-Object System.Xml.XmlWriterSettings
$settings.Indent = $true
$settings.OmitXmlDeclaration = $true
$settings.Encoding = New-Object System.Text.UTF8Encoding($true)
$writer = [System.Xml.XmlWriter]::Create($rdfxPath, $settings)
$xml.Save($writer)
$writer.Close()

[System.IO.File]::WriteAllText((Join-Path $distDir 'DynamicFolder.full.ps1'), $folderScript, (New-Object System.Text.UTF8Encoding($true)))
[System.IO.File]::WriteAllText((Join-Path $distDir 'DynamicCredential.full.ps1'), $dyncredScript, (New-Object System.Text.UTF8Encoding($true)))

Write-Host "OK: $rdfxPath"
Write-Host "OK: $rdfePath (Legacy)"
Write-Host 'OK: dist\DynamicFolder.full.ps1, dist\DynamicCredential.full.ps1'
