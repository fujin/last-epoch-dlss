[CmdletBinding()]
param(
    [string]$PlanPath = (Join-Path $PSScriptRoot '..\packaging\backend-plan.json'),
    [string]$DownloadsDirectory = (Join-Path $PSScriptRoot '..\downloads'),
    [string]$RuntimeCacheDirectory = (Join-Path $PSScriptRoot '..\vendor\runtime-cache'),
    [string]$StageDirectory = (Join-Path $PSScriptRoot '..\stage')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectDirectory = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$utf8NoBom = New-Object Text.UTF8Encoding($false)

# This script only prepares the local payload. Installation is a separate script.
function Assert-WorkspacePath {
    param([Parameter(Mandatory)][string]$Path)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $prefix = $projectDirectory.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $fullPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Output path must be inside the mod workspace: $fullPath"
    }
    $cursor = $fullPath
    while ($cursor.Length -ge $projectDirectory.Length) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Output path crosses a link or junction: $cursor"
            }
        }
        if ($cursor -eq $projectDirectory) { break }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
    return $fullPath
}

function Resolve-ChildPath {
    param([string]$Root, [string]$RelativePath)
    if ([string]::IsNullOrWhiteSpace($RelativePath) -or
        [IO.Path]::IsPathRooted($RelativePath) -or $RelativePath -match '[:\x00-\x1f]') {
        throw "Invalid relative payload path: $RelativePath"
    }
    $segments = $RelativePath -split '[/\\]'
    if (@($segments | Where-Object { $_ -in @('', '.', '..') -or $_ -match '[. ]$' }).Count -gt 0) {
        throw "Unsafe relative payload path: $RelativePath"
    }
    $fullPath = Assert-WorkspacePath (Join-Path $Root ($segments -join [IO.Path]::DirectorySeparatorChar))
    $rootPrefix = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $fullPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Payload path escapes its destination: $RelativePath"
    }
    return $fullPath
}

function New-ParentDirectory {
    param([string]$Path)
    $parent = Assert-WorkspacePath ([IO.Path]::GetDirectoryName($Path))
    [IO.Directory]::CreateDirectory($parent) | Out-Null
}

function Assert-Sha256 {
    param([string]$Path, [string]$Expected)
    if ($Expected -notmatch '^[0-9a-fA-F]{64}$') { throw "Invalid SHA256 for $Path" }
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    if ($actual -ne $Expected) {
        throw "SHA256 mismatch for $Path. Expected $Expected; received $actual. No unverified file will be staged."
    }
}

function Get-VerifiedDownload {
    param([string]$Url, [string]$Path, [string]$Expected)
    $Path = Assert-WorkspacePath $Path
    $uri = [Uri]$Url
    if (-not $uri.IsAbsoluteUri -or $uri.Scheme -ne 'https') {
        throw "Only HTTPS download URLs are supported: $Url"
    }
    if ($Expected -notmatch '^[0-9a-fA-F]{64}$') { throw "Invalid SHA256 pin for $Url" }
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        Assert-Sha256 $Path $Expected
        Write-Host "Verified cached download: $([IO.Path]::GetFileName($Path))"
        return $Path
    }
    New-ParentDirectory $Path
    $partialPath = Assert-WorkspacePath ($Path + '.partial-' + [Guid]::NewGuid().ToString('N'))
    try {
        Write-Host "Downloading $Url"
        Invoke-WebRequest -Uri $uri.AbsoluteUri -OutFile $partialPath -UseBasicParsing -ErrorAction Stop
        Assert-Sha256 $partialPath $Expected
        Move-Item -LiteralPath $partialPath -Destination $Path
    }
    finally {
        if (Test-Path -LiteralPath $partialPath -PathType Leaf) {
            Remove-Item -LiteralPath $partialPath -Force
        }
    }
    return $Path
}

function Expand-ApprovedMember {
    param([IO.Compression.ZipArchive]$Archive, [string]$Member, [string]$Destination)
    # Exact member matching prevents a similarly named file elsewhere in the ZIP from being used.
    $entries = @($Archive.Entries | Where-Object { $_.FullName -ceq $Member })
    $caseMatches = @($Archive.Entries | Where-Object { $_.FullName -ieq $Member })
    if ($entries.Count -ne 1 -or $caseMatches.Count -ne 1 -or [string]::IsNullOrEmpty($entries[0].Name)) {
        throw "Archive member is missing, ambiguous or not a file: $Member"
    }
    $Destination = Assert-WorkspacePath $Destination
    New-ParentDirectory $Destination
    [IO.Compression.ZipFileExtensions]::ExtractToFile($entries[0], $Destination, $true)
    return $Destination
}

$DownloadsDirectory = Assert-WorkspacePath $DownloadsDirectory
$RuntimeCacheDirectory = Assert-WorkspacePath $RuntimeCacheDirectory
$StageDirectory = Assert-WorkspacePath $StageDirectory
$plan = Get-Content -LiteralPath $PlanPath -Raw | ConvertFrom-Json
if ($plan.SchemaVersion -ne 1) { throw "Unsupported backend plan schema: $($plan.SchemaVersion)" }
$nr = $plan.OptionalNeuralRendering
if ($nr.EnabledByDefault -ne $false) { throw 'Optional NR must remain disabled by default.' }
$optiDependencies = @($plan.Dependencies | Where-Object { $_.Id -eq $nr.Forwarder.DependencyId })
if ($optiDependencies.Count -ne 1 -or $optiDependencies[0].Archive -ne 'zip') {
    throw 'The pinned OptiScaler ZIP dependency is missing or ambiguous.'
}
$optiDependency = $optiDependencies[0]

# This optional preparation requires the already-staged, disabled base configuration.
# It never writes to an INI and cannot enable NR as a side effect.
$iniPath = Resolve-ChildPath $StageDirectory $plan.Backend.ConfigurationFilename
if (-not (Test-Path -LiteralPath $iniPath -PathType Leaf)) {
    throw 'Run Fetch-Backend.ps1 first to prepare the base runtime and disabled INI.'
}
$iniHash = (Get-FileHash -LiteralPath $iniPath -Algorithm SHA256).Hash
$iniContent = Get-Content -LiteralPath $iniPath -Raw
$nrSection = [regex]::Match($iniContent, '(?ims)^\[DlssNr\][ \t]*\r?\n(.*?)(?=^\[|\z)')
if (-not $nrSection.Success -or $nrSection.Groups[1].Value -notmatch '(?im)^[ \t]*Enabled[ \t]*=[ \t]*false[ \t]*\r?$') {
    throw 'The staged configuration must have [DlssNr] Enabled=false before optional model preparation.'
}

$cacheRoot = Resolve-ChildPath $RuntimeCacheDirectory 'nvidia-nr-310.9.16'
$targets = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($mapping in @($nr.Archive.Files) + @($nr.Forwarder)) {
    Resolve-ChildPath $cacheRoot $mapping.Source | Out-Null
    Resolve-ChildPath $StageDirectory $mapping.Target | Out-Null
    if ($mapping.SHA256 -notmatch '^[0-9a-fA-F]{64}$' -or $mapping.Size -le 0) {
        throw "Missing file identity for $($mapping.Source)"
    }
    if (-not $targets.Add(($mapping.Target -replace '\\', '/'))) {
        throw "Duplicate optional NR destination: $($mapping.Target)"
    }
}
$models = @($nr.Archive.Files | Where-Object { $_.Source -ceq 'nvngx_dlssnr.dll' })
if ($models.Count -ne 1) { throw 'The official NR model member is missing or ambiguous.' }
$model = $models[0]

# An existing approved OptiScaler archive is required; this script does not fetch
# or select another fork implicitly.
$optiArchivePath = Resolve-ChildPath $DownloadsDirectory $nr.Forwarder.ArchiveFilename
if (-not (Test-Path -LiteralPath $optiArchivePath -PathType Leaf)) {
    throw 'The pinned OptiScaler archive is missing. Run Fetch-Backend.ps1 first.'
}
Assert-Sha256 $optiArchivePath $optiDependency.SHA256
$nrArchivePath = Resolve-ChildPath $DownloadsDirectory $nr.Archive.DownloadFilename
$nrArchivePath = Get-VerifiedDownload $nr.Archive.Url $nrArchivePath $nr.Archive.SHA256
if ((Get-Item -LiteralPath $nrArchivePath).Length -ne $nr.Archive.Size) {
    throw 'Official NR archive size does not match its pinned identity.'
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Directory]::CreateDirectory($cacheRoot) | Out-Null
$payload = New-Object 'System.Collections.Generic.List[object]'
$nrArchive = [IO.Compression.ZipFile]::OpenRead($nrArchivePath)
try {
    foreach ($mapping in $nr.Archive.Files) {
        $cachedFile = Resolve-ChildPath $cacheRoot $mapping.Source
        Expand-ApprovedMember $nrArchive $mapping.Source $cachedFile | Out-Null
        Assert-Sha256 $cachedFile $mapping.SHA256
        if ((Get-Item -LiteralPath $cachedFile).Length -ne $mapping.Size) {
            throw "Unexpected uncompressed file size: $($mapping.Source)"
        }
        $payload.Add([pscustomobject]@{
            Source = $cachedFile
            Target = $mapping.Target
            SHA256 = $mapping.SHA256
        })
    }
}
finally {
    $nrArchive.Dispose()
}
$optiArchive = [IO.Compression.ZipFile]::OpenRead($optiArchivePath)
try {
    $forwarderPath = Resolve-ChildPath $cacheRoot $nr.Forwarder.Source
    Expand-ApprovedMember $optiArchive $nr.Forwarder.Source $forwarderPath | Out-Null
    Assert-Sha256 $forwarderPath $nr.Forwarder.SHA256
    if ((Get-Item -LiteralPath $forwarderPath).Length -ne $nr.Forwarder.Size) {
        throw 'Unexpected OptiScaler NR forwarder size.'
    }
    $payload.Add([pscustomobject]@{
        Source = $forwarderPath
        Target = $nr.Forwarder.Target
        SHA256 = $nr.Forwarder.SHA256
    })
}
finally {
    $optiArchive.Dispose()
}

$modelPath = Resolve-ChildPath $cacheRoot $model.Source
$signature = Get-AuthenticodeSignature -LiteralPath $modelPath
$expectedSubject = '(^|,\s*)' + [regex]::Escape($nr.Authenticode.RequiredSubject) + '(,|$)'
if ([string]$signature.Status -ne $nr.Authenticode.RequiredStatus -or
    $null -eq $signature.SignerCertificate -or
    $signature.SignerCertificate.Subject -notmatch $expectedSubject) {
    throw "Official NR model signature failed: $($signature.Status). $($signature.StatusMessage)"
}
$modelVersion = (Get-Item -LiteralPath $modelPath).VersionInfo
$numericVersion = '{0}.{1}.{2}.{3}' -f $modelVersion.FileMajorPart, $modelVersion.FileMinorPart,
    $modelVersion.FileBuildPart, $modelVersion.FilePrivatePart
if ($numericVersion -ne $nr.ModelVersion) {
    throw "Unexpected NR runtime version: $numericVersion"
}
$thirdPartyMap = @($nr.Archive.Files | Where-Object { $_.Source -ceq 'ThirdPartyLicenses-dxvk.txt' })
if ($thirdPartyMap.Count -ne 1) { throw 'The official archive license mapping is missing.' }
$thirdPartyText = Get-Content -LiteralPath (Resolve-ChildPath $cacheRoot $thirdPartyMap[0].Source) -Raw
if ($thirdPartyText -notmatch 'NVIDIA RTX SDKs LICENSE' -or $thirdPartyText -notmatch 'DLSS SDK') {
    throw 'The exact archive notice does not contain the expected NVIDIA RTX SDK/DLSS terms.'
}

# Staging begins only after both ZIPs, each member, and NVIDIA's signature pass.
foreach ($entry in $payload) {
    $destination = Resolve-ChildPath $StageDirectory $entry.Target
    New-ParentDirectory $destination
    Copy-Item -LiteralPath $entry.Source -Destination $destination -Force
    Assert-Sha256 $destination $entry.SHA256
}
$notice = @"
Optional DLSS 5 Neural Rendering runtime

NVIDIA model version: $numericVersion
Official source release:
https://github.com/NVIDIAGameWorks/rtx-remix/releases/tag/remix-1.6.1
Downloaded archive:
$($nr.Archive.Url)
Archive SHA256: $($nr.Archive.SHA256)

Exact ZIP member: $($model.Source)
Installed payload path: $($model.Target)
Model size: $($model.Size) bytes
Model SHA256: $($model.SHA256)
Authenticode: $($signature.Status)
Signer: $($signature.SignerCertificate.Subject)

The model DLL is unmodified, native RTX 50-series NVIDIA code. It is not a
community compatibility rebuild. It was read, hashed and signature-checked;
this preparation script did not load or execute it.

The applicable NVIDIA RTX SDK / DLSS / NGX terms are retained in
docs/licenses/RTX-Remix-ThirdPartyLicenses-dxvk.txt, copied byte-for-byte from
this exact official archive. docs/licenses/RTX-Remix-LICENSE.txt is the separate
Remix project license; it does not relicense the proprietary NVIDIA model.

OptiScaler's NR forwarder comes from the hash-pinned OptiScaler 1.2.1 archive.
Forwarder SHA256: $($nr.Forwarder.SHA256)
Its GPL license and corresponding-source information are in
docs/licenses/OptiScaler-LICENSE.txt and docs/OptiScaler-SOURCE.txt.

DLSS 5 Neural Rendering changes lighting/material appearance. Super Resolution
and Multi Frame Generation remain distinct features. Runtime identity and a
valid signature do not establish compatibility with this Last Epoch prototype.
The OptiScaler NR integration is unofficial. Existing color, depth and motion
inputs are the planned integration route; no Last Epoch NR rendering test has
yet been completed.

This optional stage leaves OptiScaler.ini byte-for-byte unchanged and keeps NR
disabled. No files were installed into the game directory.
"@
$noticePath = Resolve-ChildPath $StageDirectory 'docs/NeuralRendering-SOURCE.txt'
New-ParentDirectory $noticePath
[IO.File]::WriteAllText($noticePath, $notice, $utf8NoBom)
$receipt = [ordered]@{
    SchemaVersion = 1
    VerifiedAtUtc = [DateTime]::UtcNow.ToString('o')
    ArchiveUrl = $nr.Archive.Url
    ArchiveSHA256 = $nr.Archive.SHA256
    ModelVersion = $numericVersion
    ModelSHA256 = $model.SHA256
    AuthenticodeStatus = [string]$signature.Status
    SignerSubject = $signature.SignerCertificate.Subject
    SignerThumbprint = $signature.SignerCertificate.Thumbprint
    ForwarderArchiveSHA256 = $optiDependency.SHA256
    Files = @($payload.ToArray() | Select-Object Target, SHA256)
    ConfigurationSHA256 = $iniHash
}
$receiptPath = Resolve-ChildPath $StageDirectory 'docs/neural-rendering-downloads.json'
[IO.File]::WriteAllText($receiptPath, ($receipt | ConvertTo-Json -Depth 6), $utf8NoBom)
Assert-Sha256 $iniPath $iniHash
Write-Host "Staged official NVIDIA NR $numericVersion and its OptiScaler forwarder. Signature: $($signature.Status)."
Write-Host 'OptiScaler.ini unchanged; Neural Rendering remains disabled. No game files changed.'

