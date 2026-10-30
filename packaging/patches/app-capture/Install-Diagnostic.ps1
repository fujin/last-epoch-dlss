[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidateSet('Capture','Restore')][string]$Mode,
    [string]$GameDirectory = 'G:\SteamLibrary\steamapps\common\Last Epoch',
    [string]$DiagnosticsDirectory = (Join-Path $PSScriptRoot '..\..\..\diagnostics')
)
. (Join-Path $PSScriptRoot '..\..\..\scripts\Deployment.ps1')
$selectedHash = '571C93E38E0A81ACC0C5B0BB43C4DB1801B1484CD2E4F84826B2AAF33DAA9BE6'
$captureHash = 'A9F3C908FC3DDD033EC53142BF7A18B5E209FBA406D178DD809D5C7E5DE635D9'
$gamePath = Get-FullDirectoryPath $GameDirectory
$diagnosticsPath = Get-FullDirectoryPath $DiagnosticsDirectory
Assert-GameStopped
Assert-GameDirectory $gamePath
$manifest = Read-DeploymentManifest (Join-Path $diagnosticsPath 'deployment-manifest.json') $gamePath
if (-not $manifest) { throw 'An existing deployment journal is required.' }
$entry = @($manifest.files | Where-Object { $_.relativePath -eq 'version.dll' -and $_.state -eq 'active' })
if ($entry.Count -ne 1) { throw 'version.dll must already be owned by this deployment journal.' }
$target = Get-SafeChildPath $gamePath 'version.dll'
$currentHash = Get-FileSha256 $target
if ($currentHash -notin @($selectedHash, $captureHash) -or $currentHash -notin @($entry[0].installedHashes)) {
    throw 'Only the unchanged, journal-owned571C or A9F backend can be exchanged by this diagnostic helper.'
}
$payloadName = if ($Mode -eq 'Capture') { 'payload-capture' } else { 'payload-restore' }
$expectedHash = if ($Mode -eq 'Capture') { $captureHash } else { $selectedHash }
$payload = Get-SafeChildPath $PSScriptRoot $payloadName
$items = @(Get-ChildItem -LiteralPath $payload -Force -Recurse)
if ($items.Count -ne 1 -or $items[0].PSIsContainer -or $items[0].Name -ne 'version.dll') {
    throw 'Diagnostic payload must contain exactly one version.dll and no other files/directories.'
}
Assert-NoReparsePoint $items[0].FullName
if ((Get-FileSha256 $items[0].FullName) -ne $expectedHash) { throw 'Diagnostic payload hash mismatch.' }
Install-ManagedPayload -SourceDirectory $payload -GameDirectory $gamePath -DiagnosticsDirectory $diagnosticsPath `
    -Component "Temporary raw application capture: $Mode" -WhatIf:$WhatIfPreference
