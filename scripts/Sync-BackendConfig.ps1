[CmdletBinding()]
param(
    [string]$GameDirectory = 'G:\SteamLibrary\steamapps\common\Last Epoch',
    [string]$DiagnosticsDirectory = (Join-Path $PSScriptRoot '..\diagnostics')
)
. (Join-Path $PSScriptRoot 'Deployment.ps1')
Assert-GameStopped
$gamePath = Get-FullDirectoryPath $GameDirectory
$diagnostics = Get-FullDirectoryPath $DiagnosticsDirectory
$manifestPath = Join-Path $diagnostics 'deployment-manifest.json'
$manifest = Read-DeploymentManifest $manifestPath $gamePath
if (-not $manifest) { return }
$entry = @($manifest.files | Where-Object { $_.state -eq 'active' -and $_.relativePath -eq 'OptiScaler.ini' })
if ($entry.Count -ne 1) { return }
$installed = Get-SafeChildPath $gamePath 'OptiScaler.ini'
if (-not (Test-Path -LiteralPath $installed -PathType Leaf)) { return }
if ((Get-Item -LiteralPath $installed).Length -gt 262144) {
    throw 'Installed OptiScaler configuration exceeds the expected INI size; leaving it unchanged.'
}
$hash = Get-FileSha256 $installed
$contents = [IO.File]::ReadAllText($installed)
if ($contents -notmatch '(?m)^\[Upscalers\]\s*$' -or $contents -notmatch '(?m)^\[FrameGen\]\s*$') {
    throw 'Installed OptiScaler configuration is not a recognized INI; leaving it unchanged.'
}
# OptiScaler saves spacing and discovered auto values during feature creation,
# and its overlay saves user choices here. Preserve that exact configuration
# before a deliberately requested profile edit; never adopt arbitrary DLL edits.
if ($hash -notin @($entry[0].installedHashes)) {
    $backup = Get-SafeChildPath $diagnostics ("runtime-config\OptiScaler-$hash.ini")
    New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($backup)) -Force | Out-Null
    if (-not (Test-Path -LiteralPath $backup)) { Copy-Item -LiteralPath $installed -Destination $backup }
    if ((Get-FileSha256 $backup) -ne $hash -or (Get-FileSha256 $installed) -ne $hash) { throw 'Runtime config changed during backup.' }
    $entry[0].installedHashes = @($entry[0].installedHashes) + $hash
    $entry[0].installedSha256 = $hash
    Save-DeploymentManifest $manifest $manifestPath
}
$staged = Get-SafeChildPath (Get-FullDirectoryPath (Join-Path $PSScriptRoot '..\stage')) 'OptiScaler.ini'
Copy-Item -LiteralPath $installed -Destination $staged -Force
if ((Get-FileSha256 $staged) -ne $hash) { throw 'Runtime config staging checksum failed.' }
