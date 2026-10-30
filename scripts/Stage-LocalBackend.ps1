[CmdletBinding(SupportsShouldProcess)]
param([string]$StageDirectory = (Join-Path $PSScriptRoot '..\stage'))
. (Join-Path $PSScriptRoot 'Deployment.ps1')
. (Join-Path $PSScriptRoot 'LocalBackend.ps1')
$projectRoot = Get-FullDirectoryPath (Join-Path $PSScriptRoot '..')
$stageRoot = Get-FullDirectoryPath $StageDirectory
if (-not $stageRoot.StartsWith($projectRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Local backend staging must remain inside the mod workspace.'
}
Assert-NoReparsePoint $stageRoot
$definition = Get-LocalBackendDefinition
$localRoot = Get-SafeChildPath $projectRoot ('vendor\optiscaler-local\' + $definition.BuildDirectoryName)
$localDll = Get-SafeChildPath $localRoot 'OptiScaler.dll'
Assert-BackendFileHash $localDll $definition.DllSha256
Assert-RecognizedLocalBackend $localDll
$sourceArchive = Get-SafeChildPath $projectRoot 'downloads\optiscaler-source-1.2.1.zip'
Assert-BackendFileHash $sourceArchive $definition.SourceSha256
$official = Get-SafeChildPath $projectRoot 'vendor\runtime-cache\optiscaler_fg-0d5b24887ea2c622754da68efc76ef55ae42b5d3be350a8d43cafbabb6747ec6\DLSS5-Optimised\OptiScaler.dll'
Assert-BackendFileHash $official $definition.OfficialSha256
$fallback = Get-SafeChildPath $projectRoot 'vendor\backend-fallback\OptiScaler-1.2.1-official.dll'
if (Test-Path -LiteralPath $fallback) { Assert-BackendFileHash $fallback $definition.OfficialSha256 }
$targetDll = Get-SafeChildPath $stageRoot 'version.dll'
if (Test-Path -LiteralPath $targetDll) {
    if ((Get-FileSha256 $targetDll) -notin @($definition.DllSha256, $definition.PreviousDllSha256, $definition.LegacyDllSha256, $definition.OfficialSha256)) {
        throw 'The staged version.dll is not a pinned official, selected, or recognized previous local backend.'
    }
}
$copies = @()
foreach ($document in $definition.Documents) {
    $source = Get-SafeChildPath $localRoot $document.Name
    Assert-BackendFileHash $source $document.SHA256
    $copies += [pscustomobject]@{ Source=$source; Target=(Get-SafeChildPath $stageRoot ('docs\local-backend\' + $document.Name)); Hash=$document.SHA256 }
}
$manifest = Get-Content -LiteralPath (Get-SafeChildPath $localRoot 'variant-manifest.json') -Raw | ConvertFrom-Json
$fullPatch = @($definition.Documents | Where-Object Name -eq 'late-hudless.patch')[0]
if ($manifest.ApiVersion -ne 1 -or $manifest.PresentationStatsApiVersion -ne 1 -or $manifest.PresentationStatsBytes -ne 96 -or
    $manifest.Variant -ne $definition.Variant -or $manifest.DllSha256 -ne $definition.DllSha256 -or
    $manifest.BaseSourceArchiveSha256 -ne $definition.SourceSha256 -or $manifest.BaselineDllSha256 -ne $definition.PreviousDllSha256 -or
    $manifest.Patch -ne $fullPatch.Name -or $manifest.PatchSha256 -ne $fullPatch.SHA256) {
    throw 'Local variant manifest does not describe the pinned source and binary.'
}
# All source, binary, documentation, fallback and destination checks precede writes.
if (-not $PSCmdlet.ShouldProcess($stageRoot, 'Stage the verified local ABI1 backend and source notices; preserve official fallback')) { return }
if (-not (Test-Path -LiteralPath $fallback)) {
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($fallback)) | Out-Null
    [IO.File]::Copy($official, $fallback, $false)
    Assert-BackendFileHash $fallback $definition.OfficialSha256
}
$copies += [pscustomobject]@{ Source=$localDll; Target=$targetDll; Hash=$definition.DllSha256 }
foreach ($copy in $copies) {
    Assert-BackendFileHash $copy.Source $copy.Hash
    Assert-NoReparsePoint $copy.Target
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($copy.Target)) | Out-Null
    $temporary = $copy.Target + '.local-backend-' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::Copy($copy.Source, $temporary, $false)
        Assert-BackendFileHash $temporary $copy.Hash
        Move-Item -LiteralPath $temporary -Destination $copy.Target -Force
    } finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary }
    }
}
Assert-RecognizedLocalBackend $targetDll
[pscustomobject]@{
    Stage=$stageRoot; BackendSha256=$definition.DllSha256; OfficialFallback=$fallback
    Installed=$false; ConfigurationChanged=$false
    Restore='Run Fetch-Backend.ps1 to restage the pinned official backend, then Set-Profile.ps1 without -LateHudless.'
}
