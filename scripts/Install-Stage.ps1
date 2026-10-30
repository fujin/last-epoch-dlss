[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$GameDirectory = 'G:\SteamLibrary\steamapps\common\Last Epoch',
    [string]$SourceDirectory = (Join-Path $PSScriptRoot '..\stage'),
    [string]$DiagnosticsDirectory = (Join-Path $PSScriptRoot '..\diagnostics')
)
. (Join-Path $PSScriptRoot 'Deployment.ps1')
Install-ManagedPayload -SourceDirectory $SourceDirectory -GameDirectory $GameDirectory -DiagnosticsDirectory $DiagnosticsDirectory -Component 'Last Epoch DLSS prototype' -WhatIf:$WhatIfPreference
