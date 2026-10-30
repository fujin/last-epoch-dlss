[CmdletBinding()]
param([ValidateRange(1,16)][int]$ParallelProcesses = 4)
$ErrorActionPreference = 'Stop'
$forkRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd('\') + '\'
$archive = Join-Path $forkRoot '..\..\downloads\optiscaler-source-1.2.1.zip'
if ((Get-FileHash -LiteralPath $archive).Hash -ne '1EAAD2223E679A935426E922F86A0341232AE96641579FEC4A5B34004A1CD507') {
    throw 'The pinned original OptiScaler source archive does not match.'
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Directory]::CreateDirectory((Join-Path $PSScriptRoot 'source')) | Out-Null
$zip = [IO.Compression.ZipFile]::OpenRead($archive)
try {
    $entry = $zip.GetEntry('OptiScaler-DLSS5-1.2.1/OptiScaler/with_dx12/dx11_with_dx12_sc.cpp')
    [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, (Join-Path $PSScriptRoot 'source\dx11_with_dx12_sc.cpp'), $true)
} finally { $zip.Dispose() }
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
Write-Host 'Isolated menu-fence candidate built; stage and installed backend were not changed.'
