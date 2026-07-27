# ============================================================================
#  Royal TS Dynamic Credential Script – Pleasant Password Server (PowerShell)
#  Wird pro Passwort-Abruf separat ausgeführt; dank DPAPI-Token-Cache ist
#  i. d. R. keine erneute Anmeldung nötig.
# ============================================================================
$Config = @{
    ScriptKind       = 'Credential'
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
    CredentialId     = '$DynamicCredential.EffectiveID$'
}
