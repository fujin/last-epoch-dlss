[CmdletBinding(SupportsShouldProcess)]
param([string]$GameDirectory = 'G:\SteamLibrary\steamapps\common\Last Epoch')
. (Join-Path $PSScriptRoot 'Deployment.ps1')
$gamePath = Get-FullDirectoryPath $GameDirectory
Assert-GameStopped
Assert-GameDirectory $gamePath
$bepinexRoot = Get-SafeChildPath $gamePath 'BepInEx'
$wrapperPath = Get-SafeChildPath $gamePath 'BepInEx\interop\UnityEngine.CoreModule.dll'
if (-not (Test-Path -LiteralPath $wrapperPath -PathType Leaf)) {
    Write-Output 'Interop has not been generated yet; no wrapper repair needed before this launch.'
    return
}
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$dotnet = Join-Path $projectRoot 'tools\dotnet\dotnet.exe'
$repairTool = Join-Path $projectRoot 'tools\interop-repair\LastEpoch.InteropRepair.dll'
if (-not (Test-Path -LiteralPath $repairTool -PathType Leaf)) { throw 'Run Build-LoaderFix.ps1 before repairing generated interop.' }
if (-not $PSCmdlet.ShouldProcess($wrapperPath, 'Normalize known generated metadata, retaining SHA256-named original backup')) { return }
$previousCliHome = [Environment]::GetEnvironmentVariable('DOTNET_CLI_HOME', 'Process')
try {
    $env:DOTNET_CLI_HOME = Join-Path $projectRoot 'tools\dotnet-home'
    & $dotnet $repairTool --bepinex-root $bepinexRoot
    if ($LASTEXITCODE -ne 0) { throw "Generated interop repair failed with exit code $LASTEXITCODE; game was not launched." }
} finally {
    [Environment]::SetEnvironmentVariable('DOTNET_CLI_HOME', $previousCliHome, 'Process')
}
