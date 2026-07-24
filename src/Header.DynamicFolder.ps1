# ============================================================================
#  Royal TS Dynamic Folder Script – Pleasant Password Server (PowerShell)
#  Die $...$-Platzhalter werden von Royal TS vor der Ausführung ersetzt
#  (Replacement Tokens). Hinweis: Passwörter mit einfachem Anführungszeichen
#  (') brechen die Ersetzung – siehe Doku.
# ============================================================================
$Config = @{
    ScriptKind       = 'Folder'
    ServerUrl        = '$CustomProperty.ServerURL$'
    SsoLoginUrl      = '$CustomProperty.SSOLoginURL$'
    AuthMode         = '$CustomProperty.AuthMode$'
    OmitDomain       = '$CustomProperty.OmitDomain$'
    IgnoreSsl        = '$CustomProperty.IgnoreSSLErrors$'
    UseCache         = '$CustomProperty.UseTokenCache$'
    DebugLog         = '$CustomProperty.DebugLog$'
    Username         = '$EffectiveUsername$'
    UsernameNoDomain = '$EffectiveUsernameWithoutDomain$'
    Password         = '$EffectivePassword$'
}
