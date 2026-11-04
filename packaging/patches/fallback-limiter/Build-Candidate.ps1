[CmdletBinding()]
param([ValidateRange(1,2)][int]$ParallelProcesses = 2)
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$archive = Join-Path $repoRoot 'downloads/optiscaler-source-1.2.1.zip'
$baselinePatch = Join-Path $PSScriptRoot '../menu-fence/late-hudless.patch'
$baselineManifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../menu-fence/variant-manifest.json') -Raw | ConvertFrom-Json
$candidatePatch = Join-Path $PSScriptRoot 'fallback-limiter-only.patch'
$manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'candidate-manifest.json') -Raw | ConvertFrom-Json
function Assert-Hash([string]$Path, [string]$Expected) {
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -cne $Expected) { throw "Source input hash mismatch: $Path" }
}
Assert-Hash $archive '1EAAD2223E679A935426E922F86A0341232AE96641579FEC4A5B34004A1CD507'
Assert-Hash $baselinePatch '53E3ED17C77CB12BF7710BEE540A8EF40F47DBA99EAEBD33325D29C78A196958'
Assert-Hash $candidatePatch $manifest.PatchSha256
$vswhere = 'C:/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe'
$vsRoot = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | Select-Object -First 1
if (-not $vsRoot) { throw 'VS2022 C++ v143 Build Tools are required.' }
$vcVersion = (Get-Content -LiteralPath (Join-Path $vsRoot 'VC/Auxiliary/Build/Microsoft.VCToolsVersion.default.txt') -Raw).Trim()
$dumpbin = Join-Path $vsRoot "VC/Tools/MSVC/$vcVersion/bin/Hostx64/x64/dumpbin.exe"
if (-not (Test-Path -LiteralPath $dumpbin -PathType Leaf)) { throw 'The selected MSVC dumpbin tool is missing.' }
$runRoot = Join-Path $repoRoot ('build/fallback-limiter-full-' + [Guid]::NewGuid().ToString('N'))
$extractRoot = Join-Path $runRoot 'source'
[IO.Directory]::CreateDirectory($extractRoot) | Out-Null
Write-Host "Fresh full reconstruction: $runRoot"
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::ExtractToDirectory($archive, $extractRoot)
$sourceRoot = Join-Path $extractRoot 'OptiScaler-DLSS5-1.2.1'
if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot 'OptiScaler/OptiScaler.vcxproj') -PathType Leaf)) { throw 'Pinned source archive layout differs.' }
$oldCeiling = [Environment]::GetEnvironmentVariable('GIT_CEILING_DIRECTORIES', 'Process')
Push-Location $sourceRoot
try {
    $env:GIT_CEILING_DIRECTORIES = $runRoot
    & git -c core.autocrlf=false apply --check -- $baselinePatch
    if ($LASTEXITCODE -ne 0) { throw 'Complete 571C patch check failed.' }
    & git -c core.autocrlf=false apply -- $baselinePatch
    if ($LASTEXITCODE -ne 0) { throw 'Complete 571C patch application failed.' }
    foreach ($file in $baselineManifest.SourceFiles) { Assert-Hash (Join-Path $sourceRoot $file.Path) $file.Sha256 }
    Assert-Hash (Join-Path $sourceRoot $baselineManifest.BuildSourceOverride.Path) $baselineManifest.BuildSourceOverride.Sha256
    & git -c core.autocrlf=false apply --check -- $candidatePatch
    if ($LASTEXITCODE -ne 0) { throw 'Fallback delta check failed.' }
    & git -c core.autocrlf=false apply -- $candidatePatch
    if ($LASTEXITCODE -ne 0) { throw 'Fallback delta application failed.' }
} finally {
    Pop-Location
    [Environment]::SetEnvironmentVariable('GIT_CEILING_DIRECTORIES', $oldCeiling, 'Process')
}
$sourcePaths = @(@($baselineManifest.SourceFiles.Path) + @($manifest.ProductionFiles) | Sort-Object -Unique)
$sourceFiles = @(foreach ($path in $sourcePaths) {
    [ordered]@{ Path=$path; Sha256=(Get-FileHash -LiteralPath (Join-Path $sourceRoot $path)).Hash }
})
$buildDirectoryName = 'local-build-fallback-limiter'
$buildRoot = Join-Path $sourceRoot $buildDirectoryName
$started = [DateTime]::UtcNow
& (Join-Path $sourceRoot 'Build-Local.ps1') -ParallelProcesses $ParallelProcesses -BuildDirectoryName $buildDirectoryName
foreach ($file in $sourceFiles) { Assert-Hash (Join-Path $sourceRoot $file.Path) $file.Sha256 }
$dll = Join-Path $buildRoot 'OptiScaler.dll'
if (-not (Test-Path -LiteralPath $dll -PathType Leaf)) { throw 'Backend build did not produce OptiScaler.dll.' }
$exports = & $dumpbin /nologo /exports $dll
if ($LASTEXITCODE -ne 0) { throw 'Static export inspection failed.' }
$exportPath = Join-Path $runRoot 'exports.txt'
$exports | Set-Content -LiteralPath $exportPath
$requiredExports = @('OptiScaler_GetHudlessD3D11Version', 'OptiScaler_GetHudlessFrameTokenD3D11', 'OptiScaler_SubmitHudlessD3D11', 'OptiScaler_GetPresentationStatsV1')
foreach ($name in $requiredExports) {
    if (-not ($exports -match ('\b' + [regex]::Escape($name) + '$'))) { throw "Required extension export missing: $name" }
}
$generatedFiles = @(foreach ($name in @('resource_build_date.h', 'resource_build_commit.h')) {
    $path = 'OptiScaler/' + $name
    [ordered]@{ Path=$path; Sha256=(Get-FileHash -LiteralPath (Join-Path $sourceRoot $path)).Hash; Content=[IO.File]::ReadAllText((Join-Path $sourceRoot $path)) }
})
$buildLog = Join-Path $buildRoot 'build.log'
$warningLines = @(Select-String -LiteralPath $buildLog -Pattern '\bwarning [A-Z]+\d+:' | ForEach-Object { $_.Line.Trim() } | Sort-Object -Unique)
$report = [ordered]@{
    Variant=$manifest.Variant
    Result='PASS'
    StartedUtc=$started.ToString('o')
    CompletedUtc=[DateTime]::UtcNow.ToString('o')
    BaseSourceArchiveSha256=(Get-FileHash -LiteralPath $archive).Hash
    OrderedPatches=@(
        [ordered]@{ Path='packaging/patches/menu-fence/late-hudless.patch'; Sha256=(Get-FileHash -LiteralPath $baselinePatch).Hash },
        [ordered]@{ Path='packaging/patches/fallback-limiter/fallback-limiter-only.patch'; Sha256=(Get-FileHash -LiteralPath $candidatePatch).Hash }
    )
    BaselineFilesVerified=$baselineManifest.SourceFiles.Count
    BaselineInteropSourceVerified=$baselineManifest.BuildSourceOverride
    SourceFiles=$sourceFiles
    GeneratedBuildIdentity=$generatedFiles
    Toolchain=[ordered]@{ MSVC=$vcVersion; Platform='x64'; Configuration='Release'; PlatformToolset='v143'; ParallelProcesses=$ParallelProcesses }
    BuildRecipe='Complete pinned archive + ordered patches; reconstructed Build-Local.ps1 -ParallelProcesses 2 -BuildDirectoryName local-build-fallback-limiter; upstream packaging events disabled'
    Dll=[ordered]@{ Name='OptiScaler.dll'; Bytes=(Get-Item -LiteralPath $dll).Length; Sha256=(Get-FileHash -LiteralPath $dll).Hash }
    ExtensionExports=$requiredExports
    ExportInspection='dumpbin only; DLL was not loaded'
    Warnings=$warningLines
    BuildLogSha256=(Get-FileHash -LiteralPath $buildLog).Hash
    ExportLogSha256=(Get-FileHash -LiteralPath $exportPath).Hash
    RuntimeValidated=$false
    Deployed=$false
    Published=$false
    SelectedBackendChanged=$false
}
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $runRoot 'build-results.json')
Write-Host "Full backend compile/link and four static extension export checks passed: $runRoot"
Write-Host "Candidate SHA256: $($report.Dll.Sha256)"
