# ============================================================================
#  Hauptteil Dynamic Credential: Passwort eines einzelnen Eintrags abrufen
#  (API v5: GET /api/v5/rest/entries/<id>/password).
# ============================================================================

Initialize-Config
Initialize-Http

if (-not $Config.CredentialId) {
    throw 'Keine Credential-ID übergeben (Replacement Token DynamicCredential.EffectiveID war leer).'
}

$password = Invoke-PleasantApi ('/api/v5/rest/entries/' + $Config.CredentialId + '/password')

@{ Password = [string]$password } | ConvertTo-Json -Compress
