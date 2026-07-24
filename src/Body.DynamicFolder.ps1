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

Write-DebugLog ('Ordnerbaum geladen: {0} Objekte auf oberster Ebene.' -f $storeObjects.Count)

@{ Objects = $storeObjects } | ConvertTo-Json -Depth 100 -Compress
