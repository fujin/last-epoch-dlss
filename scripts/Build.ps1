[CmdletBinding()]
param(
    [string]$GameDirectory = 'G:\SteamLibrary\steamapps\common\Last Epoch',
    [ValidateSet('Release', 'Debug')][string]$Configuration = 'Release',
    [switch]$Restore
)

$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$dotnet = Join-Path $projectRoot 'tools\dotnet\dotnet.exe'
$nativeSource = Join-Path $projectRoot 'src\native'
$nativeBuild = Join-Path $projectRoot 'build\native-telemetry'
$managedProject = Join-Path $projectRoot 'src\managed\LastEpochGraphics.csproj'
$managedBuild = Join-Path $projectRoot ('src\managed\bin\' + $Configuration + '\net6.0')
$streamline = Join-Path $projectRoot 'vendor\Streamline'
$pluginStage = Join-Path $projectRoot 'stage\BepInEx\plugins\LastEpochGraphics'
$noticeStage = Join-Path $projectRoot 'stage\BepInEx\LastEpochGraphics\notices'

if (-not (Test-Path -LiteralPath $dotnet -PathType Leaf)) {
    throw "Portable .NET SDK not found: $dotnet"
}
if (-not (Test-Path -LiteralPath (Join-Path $streamline 'include\sl_dlss_g.h') -PathType Leaf)) {
    throw "Streamline reporting headers not found under $streamline"
}
if (-not (Test-Path -LiteralPath (Join-Path $GameDirectory 'BepInEx\interop\Unity.Postprocessing.Runtime.dll') -PathType Leaf)) {
    throw 'Launch this Last Epoch build with BepInEx first to generate its local interop assemblies.'
}
if (-not $Restore -and -not (Test-Path -LiteralPath (Join-Path $projectRoot 'src\managed\obj\project.assets.json') -PathType Leaf)) {
    throw 'Managed restore assets are missing. Run this script once with -Restore.'
}
$cmake = (Get-Command cmake -CommandType Application -ErrorAction Stop).Source
$ctest = Join-Path (Split-Path -Parent $cmake) 'ctest.exe'
if (-not (Test-Path -LiteralPath $ctest -PathType Leaf)) { throw "CTest not found: $ctest" }

function Invoke-BuildTool {
    param([string]$Tool, [string[]]$Arguments)
    & $Tool @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$([IO.Path]::GetFileName($Tool)) failed with exit code $LASTEXITCODE." }
}

# Keep SDK state, NuGet packages and first-run side effects inside the project.
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
    Invoke-BuildTool $cmake @('-S', $nativeSource, '-B', $nativeBuild, '-G', 'Visual Studio 17 2022', '-A', 'x64', "-DSTREAMLINE_ROOT=$streamline", '-DLE_BUILD_SMOKE=ON', '-DLE_BUILD_NGX=OFF')
    Invoke-BuildTool $cmake @('--build', $nativeBuild, '--config', $Configuration, '--', '/m:1', '/nr:false')
    Invoke-BuildTool $ctest @('--test-dir', $nativeBuild, '-C', $Configuration, '--output-on-failure')
    if ($Restore) {
        Invoke-BuildTool $dotnet @('restore', $managedProject, "-p:GameDir=$GameDirectory", '--disable-parallel')
    }
    Invoke-BuildTool $dotnet @('build', $managedProject, '-c', $Configuration, '--no-restore', "-p:GameDir=$GameDirectory", '-m:1', '-nr:false')
    & (Join-Path $PSScriptRoot 'Build-LoaderFix.ps1') -Configuration $Configuration -Restore:$Restore

    # Stage only after both builds and the native software contract test succeed.
    # This script does not install or launch anything in the game directory.
    $managedDll = Join-Path $managedBuild 'LastEpochGraphics.dll'
    $nativeDll = Join-Path (Join-Path $nativeBuild $Configuration) 'LastEpochNative.dll'
    foreach ($file in @($managedDll, $nativeDll)) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Expected build output missing: $file" }
    }
    New-Item -ItemType Directory -Path $pluginStage, $noticeStage -Force | Out-Null
    Copy-Item -LiteralPath $managedDll, $nativeDll -Destination $pluginStage -Force
    foreach ($notice in @('LICENSE', 'NOTICE', 'UPSTREAM-NOTICE')) {
        Copy-Item -LiteralPath (Join-Path $nativeSource $notice) -Destination (Join-Path $noticeStage ('LastEpochNative-' + $notice + '.txt')) -Force
    }
    Write-Output "Built and staged adapter files in $pluginStage"
    foreach ($file in @('LastEpochGraphics.dll', 'LastEpochNative.dll')) {
        $hash = (Get-FileHash -LiteralPath (Join-Path $pluginStage $file) -Algorithm SHA256).Hash
        Write-Output "$file SHA256 $hash"
    }
} finally {
    foreach ($name in $previousEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name], 'Process')
    }
}
