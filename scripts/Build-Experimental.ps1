[CmdletBinding()]
param(
    [ValidateSet('SR90', 'Baseline')][string]$Variant = 'SR90',
    [switch]$ManagedOnly,
    [string]$GameDirectory = 'G:\SteamLibrary\steamapps\common\Last Epoch'
)

# This developer recipe never stages, installs or launches the game. Its only
# executable test is the native software D3D11 contract (WARP; no NVIDIA model).
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $PSScriptRoot 'Deployment.ps1')
Assert-NoReparsePoint $repoRoot
$gameRoot = Get-FullDirectoryPath $GameDirectory
Assert-NoReparsePoint $gameRoot
$dotnet = Join-Path $repoRoot 'tools/dotnet/dotnet.exe'
$streamline = Join-Path $repoRoot 'vendor/Streamline'
$nugetCache = Join-Path $repoRoot 'tools/nuget'
$managedSource = Join-Path $repoRoot 'src/managed'
$nativeSource = Join-Path $repoRoot 'src/native'
foreach ($required in @($dotnet, (Join-Path $streamline 'include/sl_dlss_g.h'),
        (Join-Path $gameRoot 'BepInEx/interop/Unity.Postprocessing.Runtime.dll'))) {
    Assert-NoReparsePoint $required
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Existing local build prerequisite is missing: $required. This recipe does not download, generate game interop, or launch the game."
    }
}
$cmake = (Get-Command cmake -CommandType Application -ErrorAction Stop).Source
$ctest = Join-Path (Split-Path -Parent $cmake) 'ctest.exe'
if (-not (Test-Path -LiteralPath $ctest -PathType Leaf)) { throw "CTest not found: $ctest" }
if ($Variant -eq 'SR90' -and -not ([IO.File]::ReadAllText((Join-Path $managedSource 'Plugin.cs')).Contains('LE_EXPERIMENTAL_SR90'))) {
    throw 'This source snapshot does not contain the guarded SR90 experiment. Refusing to label an ordinary build SR90.'
}

$runRoot = Get-SafeChildPath $repoRoot ('build/experimental-' + $Variant.ToLowerInvariant() + '-' + [Guid]::NewGuid().ToString('N'))
if (Test-Path -LiteralPath $runRoot) { throw 'Experimental build destination already exists.' }
$sourceRoot = Join-Path $runRoot 'source'
$managedRoot = Join-Path $sourceRoot 'managed'
$nativeRoot = Join-Path $sourceRoot 'native'
$managedOutput = Join-Path $runRoot 'managed'
$nativeOutput = Join-Path $runRoot 'native'
$logRoot = Join-Path $runRoot 'logs'
$emptyFeed = Join-Path $runRoot 'empty-package-feed'
foreach ($directory in @($managedRoot, $nativeRoot, $managedOutput, $logRoot, $emptyFeed)) {
    [IO.Directory]::CreateDirectory($directory) | Out-Null
}
$selectedCandidates = Get-Content -LiteralPath (Join-Path $repoRoot 'packaging/source-candidates.json') -Raw | ConvertFrom-Json
$started = [DateTime]::UtcNow
$inputs = [Collections.Generic.List[object]]::new()

function Copy-SourceFile([string]$Source, [string]$Destination, [string]$RelativePath) {
    Assert-NoReparsePoint $Source
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { throw "Required source file is missing: $Source" }
    $sha = (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash
    [IO.File]::Copy($Source, $Destination, $false)
    if ((Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash -cne $sha) { throw "Source changed while snapshotting: $RelativePath" }
    $inputs.Add([ordered]@{ Path=$RelativePath; SHA256=$sha })
}
# Only source/project files in the managed source directory; never bin/obj or
# generated interop. A new guarded .cs helper is included and hashed explicitly.
foreach ($item in @(Get-ChildItem -LiteralPath $managedSource -File | Where-Object { $_.Extension -in @('.cs', '.csproj') } | Sort-Object Name)) {
    Copy-SourceFile $item.FullName (Join-Path $managedRoot $item.Name) ('src/managed/' + $item.Name)
}
foreach ($name in @('CMakeLists.txt', 'Native.cpp', 'Native.h', 'Upscaler.h', 'OptiBackend.cpp',
        'NgxProtocol.h', 'NgxSdkBackend.cpp', 'NativeSmoke.cpp', 'LICENSE', 'NOTICE', 'UPSTREAM-NOTICE')) {
    Copy-SourceFile (Join-Path $nativeSource $name) (Join-Path $nativeRoot $name) ('src/native/' + $name)
}
$references = [Collections.Generic.List[object]]::new()
foreach ($folder in @('BepInEx/core', 'BepInEx/interop')) {
    $referenceRoot = Get-SafeChildPath $gameRoot $folder
    foreach ($item in @(Get-ChildItem -LiteralPath $referenceRoot -Filter '*.dll' -File | Sort-Object Name)) {
        Assert-NoReparsePoint $item.FullName
        $references.Add([ordered]@{ Path=$folder + '/' + $item.Name; SHA256=(Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash })
    }
}
$headerInputs = @(Get-ChildItem -LiteralPath (Join-Path $streamline 'include') -File | Sort-Object Name | ForEach-Object {
    Assert-NoReparsePoint $_.FullName
    [ordered]@{ Path='include/' + $_.Name; SHA256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
})
$nugetConfig = Join-Path $runRoot 'NuGet.Config'
# Clear machine/user feeds completely. Already cached framework reference packs
# may be read from tools/nuget; an absent prerequisite fails without a download.
[IO.File]::WriteAllText($nugetConfig, '<configuration><packageSources><clear /></packageSources></configuration>', [Text.UTF8Encoding]::new($false))
$buildEnvironment = @{
    DOTNET_ROOT=(Split-Path -Parent $dotnet)
    DOTNET_CLI_HOME=(Join-Path $runRoot 'dotnet-home')
    DOTNET_CLI_TELEMETRY_OPTOUT='1'
    DOTNET_SKIP_FIRST_TIME_EXPERIENCE='1'
    DOTNET_GENERATE_ASPNET_CERTIFICATE='false'
    DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE='true'
    NUGET_PACKAGES=$nugetCache
}
$previousEnvironment = @{}
$symbols = @()
if ($Variant -eq 'SR90') { $symbols = @('LE_EXPERIMENTAL_SR90') }
$commands = [Collections.Generic.List[object]]::new()
function Invoke-ExperimentalTool([string]$Tool, [string[]]$Arguments, [string]$LogName) {
    $log = Join-Path $logRoot $LogName
    $commands.Add([ordered]@{ Tool=[IO.Path]::GetFileName($Tool); Arguments=$Arguments; Log='logs/' + $LogName })
    & $Tool @Arguments 2>&1 | Tee-Object -FilePath $log | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { throw "$([IO.Path]::GetFileName($Tool)) failed ($LASTEXITCODE); see $log" }
}
$reportPath = Join-Path $runRoot 'build-results.json'
$report = [ordered]@{
    SchemaVersion=1; Variant=$Variant; Status='Building'; StartedUtc=$started.ToString('o')
    ManagedOnly=[bool]$ManagedOnly; NativeSoftwareContract='NOT_RUN'
    SelectedNativeRuntime=[ordered]@{ SHA256=$selectedCandidates.NativeCandidate.SHA256; Replaced=$false; Role='Keep this previously validated native runtime for any later game experiment unless separately promoted.' }
    RecipeSHA256=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
    ToolFiles=@(@{Name='dotnet.exe';SHA256=(Get-FileHash -LiteralPath $dotnet -Algorithm SHA256).Hash}, @{Name='cmake.exe';SHA256=(Get-FileHash -LiteralPath $cmake -Algorithm SHA256).Hash}, @{Name='ctest.exe';SHA256=(Get-FileHash -LiteralPath $ctest -Algorithm SHA256).Hash})
    ManagedSymbols=$symbols; SourceFiles=@($inputs.ToArray()); ReferenceFiles=@($references.ToArray())
    StreamlineHeaders=$headerInputs; Commands=@(); RuntimeValidated=$false; Staged=$false; Installed=$false
    SelectedBackendChanged=$false; GameLaunched=$false
    Scope='Compilation and software D3D11 contracts only. No SR visuals, NVIDIA execution, FG/NR performance or input-latency claim.'
}
try {
    foreach ($name in $buildEnvironment.Keys) {
        $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        [Environment]::SetEnvironmentVariable($name, $buildEnvironment[$name], 'Process')
    }
    Write-Host "Isolated $Variant source snapshot: $runRoot"
    $project = Join-Path $managedRoot 'LastEpochGraphics.csproj'
    Invoke-ExperimentalTool $dotnet @('restore', $project, '--configfile', $nugetConfig, '--source', $emptyFeed,
        '--disable-parallel', '-p:NuGetAudit=false', "-p:GameDir=$gameRoot") 'managed-restore.log'
    $managedArguments = @('build', $project, '-c', 'Release', '--no-restore', '-o', $managedOutput,
        "-p:GameDir=$gameRoot", "-p:PathMap=$runRoot=/_/LastEpochExperimental", '-m:1', '-nr:false')
    if ($symbols.Count -gt 0) { $managedArguments += ('-p:DefineConstants=' + ($symbols -join ';')) }
    Invoke-ExperimentalTool $dotnet $managedArguments 'managed-build.log'
    if (-not $ManagedOnly) {
        Invoke-ExperimentalTool $cmake @('-S', $nativeRoot, '-B', $nativeOutput, '-G', 'Visual Studio 17 2022', '-A', 'x64',
            "-DSTREAMLINE_ROOT=$streamline", '-DLE_BUILD_SMOKE=ON', '-DLE_BUILD_NGX=OFF') 'native-configure.log'
        Invoke-ExperimentalTool $cmake @('--build', $nativeOutput, '--config', 'Release', '--', '/m:1', '/nr:false') 'native-build.log'
        Invoke-ExperimentalTool $ctest @('--test-dir', $nativeOutput, '-C', 'Release', '--output-on-failure', '--no-tests=error', '--timeout', '120') 'native-contract.log'
        $report.NativeSoftwareContract='PASS'
    }
    $artifactItems = @(@{ Path='managed/LastEpochGraphics.dll'; Role='Unselected managed compile candidate; runtime validation required' })
    if (-not $ManagedOnly) { $artifactItems += @{ Path='native/Release/LastEpochNative.dll'; Role='Native software-contract build only; not a replacement for the selected native runtime' } }
    $artifacts = @(foreach ($item in $artifactItems) {
        $artifact = Join-Path $runRoot $item.Path
        if (-not (Test-Path -LiteralPath $artifact -PathType Leaf)) { throw "Expected isolated artifact missing: $artifact" }
        [ordered]@{ Path=$item.Path; Role=$item.Role; Bytes=(Get-Item -LiteralPath $artifact).Length; SHA256=(Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash }
    })
    foreach ($item in $inputs) {
        $relative = $item.Path.Substring(4)
        if ((Get-FileHash -LiteralPath (Join-Path $sourceRoot $relative) -Algorithm SHA256).Hash -cne $item.SHA256) {
            throw "Source snapshot changed during compilation: $($item.Path)"
        }
    }
    foreach ($item in $references) {
        if ((Get-FileHash -LiteralPath (Get-SafeChildPath $gameRoot $item.Path) -Algorithm SHA256).Hash -cne $item.SHA256) {
            throw "Existing game reference changed during compilation: $($item.Path)"
        }
    }
    if (-not $ManagedOnly) { $report.NativeCMakeCacheSHA256=(Get-FileHash -LiteralPath (Join-Path $nativeOutput 'CMakeCache.txt') -Algorithm SHA256).Hash }
    $report.Status='PASS'
    $report.Artifacts=$artifacts
} catch {
    $report.Status='FAIL'
    $report.Failure=$_.Exception.Message
    throw
} finally {
    foreach ($name in $previousEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name], 'Process') }
    $report.Commands=@($commands.ToArray())
    $report.CompletedUtc=[DateTime]::UtcNow.ToString('o')
    $report | ConvertTo-Json -Depth 9 | Set-Content -LiteralPath $reportPath -Encoding UTF8
}
Write-Host "Isolated build passed; native software contract: $($report.NativeSoftwareContract). Review $reportPath before any future deployment."
[pscustomobject]@{ Variant=$Variant; RunDirectory=$runRoot; Manifest=$reportPath; Artifacts=$report.Artifacts; RuntimeValidated=$false; Installed=$false }
