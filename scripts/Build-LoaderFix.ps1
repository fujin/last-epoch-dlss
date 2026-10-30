[CmdletBinding()]
param(
    [ValidateSet('Release', 'Debug')][string]$Configuration = 'Release',
    [switch]$Restore
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$dotnet = Join-Path $projectRoot 'tools\dotnet\dotnet.exe'
$patcherProject = Join-Path $projectRoot 'src\loader-diagnostics\LoaderDiagnostics.csproj'
$patcherOutput = Join-Path $projectRoot ('src\loader-diagnostics\bin\' + $Configuration + '\net6.0')
$patcherStage = Join-Path $projectRoot 'stage\BepInEx\patchers\LoaderDiagnostics'
$loaderCore = Join-Path $projectRoot 'loader\BepInEx\core'
$repairProject = Join-Path $projectRoot 'src\interop-repair\InteropRepair.csproj'
$repairOutput = Join-Path $projectRoot 'tools\interop-repair'

# This preloader has no generated Unity or game references. It can be built
# before the first game launch and independently of any IL2CPP metadata version.
if (-not (Test-Path -LiteralPath $dotnet -PathType Leaf)) { throw "Portable .NET SDK not found: $dotnet" }
foreach ($reference in @('BepInEx.Core.dll', 'BepInEx.Preloader.Core.dll', 'Mono.Cecil.dll')) {
    if (-not (Test-Path -LiteralPath (Join-Path $loaderCore $reference) -PathType Leaf)) {
        throw "Official extracted loader reference is missing: $reference"
    }
}
if (-not $Restore -and -not (Test-Path -LiteralPath (Join-Path $projectRoot 'src\loader-diagnostics\obj\project.assets.json') -PathType Leaf)) {
    throw 'Loader-fix restore assets are missing. Run this script once with -Restore.'
}
$buildEnvironment = @{
    DOTNET_ROOT = (Split-Path -Parent $dotnet)
    DOTNET_CLI_HOME = (Join-Path $projectRoot 'tools\dotnet-home')
    DOTNET_CLI_TELEMETRY_OPTOUT = '1'
    DOTNET_SKIP_FIRST_TIME_EXPERIENCE = '1'
    DOTNET_GENERATE_ASPNET_CERTIFICATE = 'false'
    DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE = 'true'
    NUGET_PACKAGES = (Join-Path $projectRoot 'tools\nuget')
}
$previousEnvironment = @{}
try {
    foreach ($name in $buildEnvironment.Keys) {
        $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        [Environment]::SetEnvironmentVariable($name, $buildEnvironment[$name], 'Process')
    }
    if ($Restore) {
        & $dotnet restore $patcherProject --disable-parallel
        if ($LASTEXITCODE -ne 0) { throw "Loader-fix restore failed with exit code $LASTEXITCODE." }
    }
    if ($Restore -or -not (Test-Path -LiteralPath (Join-Path $projectRoot 'src\interop-repair\obj\project.assets.json'))) {
        & $dotnet restore $repairProject --disable-parallel -p:NuGetAudit=false
        if ($LASTEXITCODE -ne 0) { throw "Interop repair tool restore failed with exit code $LASTEXITCODE." }
    }
    & $dotnet build $repairProject -c $Configuration --no-restore -o $repairOutput "-p:PathMap=$projectRoot=/_/LastEpochGraphics" -m:1 -nr:false
    if ($LASTEXITCODE -ne 0) { throw "Interop repair tool build failed with exit code $LASTEXITCODE." }
    & $dotnet build $patcherProject -c $Configuration --no-restore -p:OutputType=Library "-p:PathMap=$projectRoot=/_/LastEpochGraphics" -m:1 -nr:false
    if ($LASTEXITCODE -ne 0) { throw "Loader-fix build failed with exit code $LASTEXITCODE." }
    New-Item -ItemType Directory -Path $patcherStage -Force | Out-Null
    foreach ($file in @('LastEpoch.LoaderDiagnostics.dll', 'LastEpoch.LoaderDiagnostics.deps.json', 'LastEpoch.LoaderDiagnostics.pdb')) {
        $built = Join-Path $patcherOutput $file
        if (-not (Test-Path -LiteralPath $built -PathType Leaf)) { throw "Expected loader-fix output missing: $built" }
        Copy-Item -LiteralPath $built -Destination (Join-Path $patcherStage $file) -Force
    }
    $hash = (Get-FileHash -LiteralPath (Join-Path $patcherStage 'LastEpoch.LoaderDiagnostics.dll') -Algorithm SHA256).Hash
    Write-Output "Built and staged loader fix in $patcherStage"
    Write-Output "LastEpoch.LoaderDiagnostics.dll SHA256 $hash"
    Write-Output "Built external interop repair tool in $repairOutput"
} finally {
    foreach ($name in $previousEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name], 'Process')
    }
}
