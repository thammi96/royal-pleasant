# ============================================================================
#  Install-WebView2Sdk.ps1
#  Lädt das Microsoft.Web.WebView2-NuGet-Paket herunter und legt die für den
#  SSO-Modus benötigten Assemblies (net462 + nativer WebView2Loader) unter
#  %LOCALAPPDATA%\RoyalTS-PleasantPPS\lib ab.
#
#  Einmalig pro Benutzer/Rechner ausführen:
#     powershell -ExecutionPolicy Bypass -File .\tools\Install-WebView2Sdk.ps1
#
#  Voraussetzung zur Laufzeit ist außerdem die WebView2 Evergreen Runtime
#  (auf Windows 10/11 üblicherweise bereits vorhanden).
# ============================================================================
[CmdletBinding()]
param(
    # Bewährte stabile SDK-Version; bei Bedarf per Parameter überschreiben.
    [string]$Version = '1.0.2592.51',
    [string]$TargetDir = (Join-Path $env:LOCALAPPDATA 'RoyalTS-PleasantPPS\lib')
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$tempDir = Join-Path $env:TEMP ('webview2-sdk-' + [Guid]::NewGuid().ToString('N'))
$zipPath = Join-Path $env:TEMP ('webview2-sdk-' + $Version + '.zip')

Write-Host "Lade Microsoft.Web.WebView2 $Version von nuget.org ..."
Invoke-WebRequest -Uri "https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2/$Version" -OutFile $zipPath -UseBasicParsing

Write-Host 'Entpacke Paket ...'
Expand-Archive -Path $zipPath -DestinationPath $tempDir -Force

# .NET-Framework-Build ermitteln (Royal TS führt PowerShell-Skripte mit
# Windows PowerShell 5.1 aus, daher net4xx statt netcoreapp).
$netDir = Get-ChildItem -Path (Join-Path $tempDir 'lib') -Directory |
    Where-Object { $_.Name -like 'net4*' } |
    Sort-Object Name -Descending |
    Select-Object -First 1
if (-not $netDir) { throw "Kein net4x-Ordner im Paket gefunden (lib\net4*)." }

New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
Copy-Item -Path (Join-Path $netDir.FullName 'Microsoft.Web.WebView2.Core.dll')     -Destination $TargetDir -Force
Copy-Item -Path (Join-Path $netDir.FullName 'Microsoft.Web.WebView2.WinForms.dll') -Destination $TargetDir -Force

# Nativer Loader: x64 direkt neben die Managed-DLLs, x86 in Unterordner.
$loader64 = Join-Path $tempDir 'runtimes\win-x64\native\WebView2Loader.dll'
$loader86 = Join-Path $tempDir 'runtimes\win-x86\native\WebView2Loader.dll'
if (Test-Path $loader64) { Copy-Item $loader64 -Destination $TargetDir -Force }
if (Test-Path $loader86) {
    $x86Dir = Join-Path $TargetDir 'x86'
    New-Item -ItemType Directory -Path $x86Dir -Force | Out-Null
    Copy-Item $loader86 -Destination $x86Dir -Force
}

Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host "Fertig. WebView2-SDK liegt jetzt unter: $TargetDir"
Write-Host 'Der SSO-Modus des Dynamic Folders findet die DLLs dort automatisch.'
