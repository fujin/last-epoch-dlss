[CmdletBinding()]
param([ValidateRange(1,16)][int]$ParallelProcesses = 4)
$ErrorActionPreference = 'Stop'
$forkRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd('\') + '\'
$archive = Join-Path $forkRoot '..\..\downloads\optiscaler-source-1.2.1.zip'
if ((Get-FileHash -LiteralPath $archive).Hash -ne '1EAAD2223E679A935426E922F86A0341232AE96641579FEC4A5B34004A1CD507') {
    throw 'The pinned original OptiScaler source archive does not match.'
}
$baselineManifest = Get-Content -LiteralPath (Join-Path $forkRoot 'local-build-menu-fence\variant-manifest.json') -Raw | ConvertFrom-Json
if ($baselineManifest.DllSha256 -ne '571C93E38E0A81ACC0C5B0BB43C4DB1801B1484CD2E4F84826B2AAF33DAA9BE6') {
    throw 'The selected571C baseline manifest does not match.'
}
foreach ($sourceFile in $baselineManifest.SourceFiles) {
    if ((Get-FileHash -LiteralPath (Join-Path $forkRoot $sourceFile.Path)).Hash -ne $sourceFile.Sha256) {
        throw "Selected571C source changed: $($sourceFile.Path)"
    }
}
$manifestPath = Join-Path $PSScriptRoot 'variant-manifest.json'
if (Test-Path -LiteralPath $manifestPath) {
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ((Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'source\dx11_with_dx12_sc.cpp')).Hash -ne $manifest.BuildSourceOverride.Sha256) {
        throw 'The diagnostic translation unit does not match its manifest.'
    }
}
$vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
$msbuild = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -find MSBuild\**\Bin\MSBuild.exe | Select-Object -First 1
if (-not $msbuild) { throw 'VS2022 C++ v143 Build Tools are required.' }
$arguments = @(
    (Join-Path $forkRoot 'OptiScaler\OptiScaler.vcxproj'), '/t:Build', '/p:Configuration=Release',
    '/p:Platform=x64', '/p:PlatformToolset=v143', '/p:PreferredToolArchitecture=x64',
    "/p:LEBuildProcesses=$ParallelProcesses", "/p:SolutionDir=$forkRoot", "/p:OutDir=$PSScriptRoot\",
    "/p:IntDir=$PSScriptRoot\obj\", '/p:PreBuildEventUseInBuild=false', '/p:PostBuildEventUseInBuild=false',
    "/p:ForceImportAfterCppTargets=$PSScriptRoot\SourceOverride.targets", "/m:$ParallelProcesses",
    '/v:minimal', '/nologo', "/flp:logfile=$PSScriptRoot\build.log;verbosity=normal"
)
& $msbuild @arguments
if ($LASTEXITCODE -ne 0) { throw "Candidate build failed: $LASTEXITCODE" }
Write-Host 'Isolated raw application capture candidate built; stage and installed backend were not changed.'
