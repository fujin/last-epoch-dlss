[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$GameDirectory = 'G:\SteamLibrary\steamapps\common\Last Epoch',
    [string]$SourceDirectory = (Join-Path $PSScriptRoot '..\loader'),
    [string]$DiagnosticsDirectory = (Join-Path $PSScriptRoot '..\diagnostics')
)
. (Join-Path $PSScriptRoot 'Deployment.ps1')
foreach ($required in @('winhttp.dll', 'doorstop_config.ini', 'BepInEx\core\BepInEx.Unity.IL2CPP.dll')) {
    if (-not (Test-Path -LiteralPath (Join-Path $SourceDirectory $required) -PathType Leaf)) {
        throw "Incomplete official BepInEx IL2CPP loader: missing $required"
    }
}
Install-ManagedPayload -SourceDirectory $SourceDirectory -GameDirectory $GameDirectory -DiagnosticsDirectory $DiagnosticsDirectory -Component 'BepInEx IL2CPP loader' -WhatIf:$WhatIfPreference
