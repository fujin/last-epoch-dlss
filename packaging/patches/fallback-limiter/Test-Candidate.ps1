[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$archive=Join-Path $repoRoot 'downloads/optiscaler-source-1.2.1.zip'
$baselinePatch=Join-Path $PSScriptRoot '../menu-fence/late-hudless.patch'
$baselineManifest=Get-Content -LiteralPath (Join-Path $PSScriptRoot '../menu-fence/variant-manifest.json') -Raw | ConvertFrom-Json
$candidatePatch=Join-Path $PSScriptRoot 'fallback-limiter-only.patch'
$candidateManifest=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'candidate-manifest.json') -Raw | ConvertFrom-Json
if((Get-FileHash -LiteralPath $archive).Hash -ne '1EAAD2223E679A935426E922F86A0341232AE96641579FEC4A5B34004A1CD507'){throw 'Pinned base source archive mismatch.'}
if((Get-FileHash -LiteralPath $baselinePatch).Hash -ne '53E3ED17C77CB12BF7710BEE540A8EF40F47DBA99EAEBD33325D29C78A196958'){throw 'Pinned571C source patch mismatch.'}
if((Get-FileHash -LiteralPath $candidatePatch).Hash -ne $candidateManifest.PatchSha256){throw 'Candidate patch/manifest mismatch.'}
$runRoot=Join-Path $repoRoot ('build/fallback-limiter-tests-'+[Guid]::NewGuid().ToString('N'))
$sourceRoot=Join-Path $runRoot 'source'
[IO.Directory]::CreateDirectory($sourceRoot) | Out-Null
$paths=@('OptiScaler/misc/FrameLimit.cpp','OptiScaler/misc/FrameLimit.h','OptiScaler/hooks/FG_Hooks.cpp','OptiScaler/wrapped/wrapped_swapchain.cpp','OptiScaler/hooks/Vulkan_Hooks.cpp')
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip=[IO.Compression.ZipFile]::OpenRead($archive)
try{
  foreach($path in $paths){
    $entry=$zip.GetEntry('OptiScaler-DLSS5-1.2.1/'+$path)
    if($null -eq $entry){throw "Missing pinned source entry: $path"}
    $destination=Join-Path $sourceRoot $path
    [IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
    [IO.Compression.ZipFileExtensions]::ExtractToFile($entry,$destination,$false)
  }
}finally{$zip.Dispose()}
$oldCeiling=[Environment]::GetEnvironmentVariable('GIT_CEILING_DIRECTORIES','Process')
Push-Location $sourceRoot
try{
  $env:GIT_CEILING_DIRECTORIES=$runRoot
  & git -c core.autocrlf=false apply --check --include=OptiScaler/hooks/FG_Hooks.cpp -- $baselinePatch
  if($LASTEXITCODE -ne 0){throw '571C source reconstruction check failed.'}
  & git -c core.autocrlf=false apply --include=OptiScaler/hooks/FG_Hooks.cpp -- $baselinePatch
  if($LASTEXITCODE -ne 0){throw '571C source reconstruction failed.'}
  $expected=($baselineManifest.SourceFiles | Where-Object Path -eq 'OptiScaler/hooks/FG_Hooks.cpp').Sha256
  if((Get-FileHash -LiteralPath 'OptiScaler/hooks/FG_Hooks.cpp').Hash -ne $expected){throw 'Reconstructed571C hook differs from its provenance.'}
  & git -c core.autocrlf=false apply --check -- $candidatePatch
  if($LASTEXITCODE -ne 0){throw 'Candidate patch check failed.'}
  & git -c core.autocrlf=false apply -- $candidatePatch
  if($LASTEXITCODE -ne 0){throw 'Candidate patch reconstruction failed.'}
}finally{
  Pop-Location
  [Environment]::SetEnvironmentVariable('GIT_CEILING_DIRECTORIES',$oldCeiling,'Process')
}
# Compile the production helper extracted from the candidate patch, never a test-side copy.
$vswhere='C:/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe'
$msbuild=& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -find 'MSBuild\**\Bin\MSBuild.exe' | Select-Object -First 1
if(-not $msbuild){throw 'VS2022 C++ v143 Build Tools are required.'}
$bin=Join-Path $runRoot 'bin'
$obj=Join-Path $runRoot 'obj'
& $msbuild (Join-Path $PSScriptRoot 'FrameLimitPolicyTests.vcxproj') /t:Build /p:Configuration=Release /p:Platform=x64 /p:PlatformToolset=v143 /p:PreferredToolArchitecture=x64 "/p:FrameLimitReconstruction=$sourceRoot" "/p:OutDir=$bin\" "/p:IntDir=$obj\" /m:1 /nr:false /v:minimal /nologo
if($LASTEXITCODE -ne 0){throw "Standalone test build failed: $LASTEXITCODE"}
& (Join-Path $bin 'FrameLimitPolicyTests.exe')
if($LASTEXITCODE -ne 0){throw "Production-policy tests failed: $LASTEXITCODE"}
[ordered]@{CandidatePatchSha256=(Get-FileHash -LiteralPath $candidatePatch).Hash;ProductionHelperSha256=(Get-FileHash -LiteralPath (Join-Path $sourceRoot 'OptiScaler/misc/FrameLimitPolicy.h')).Hash;Result='PASS';Scope='Pure production interval/multiplier arithmetic only; no game, runtime DLL, GPU, timer, Reflex or end-to-end latency test.'} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $runRoot 'test-results.json')
Write-Host "Isolated results: $runRoot"