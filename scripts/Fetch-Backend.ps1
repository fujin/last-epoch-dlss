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
if (@($plan.Dependencies).Count -eq 0) { throw 'Backend plan has no dependencies.' }

Add-Type -AssemblyName System.IO.Compression.FileSystem
$payload = New-Object 'System.Collections.Generic.List[object]'
$targets = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$dependencyIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$receipts = New-Object 'System.Collections.Generic.List[object]'
$licensePath = $null
$licenseOrigin = $null

# Validate every requested path and format before downloading or changing the stage.
foreach ($dependency in $plan.Dependencies) {
    if ($dependency.Id -notmatch '^[a-zA-Z0-9_-]+$' -or -not $dependencyIds.Add($dependency.Id)) {
        throw "Invalid or duplicate dependency ID: $($dependency.Id)"
    }
    if ($dependency.Archive -notin @('zip', 'file')) {
        throw "Unsupported archive format '$($dependency.Archive)' for $($dependency.Id)"
    }
    if ($dependency.SHA256 -notmatch '^[0-9a-fA-F]{64}$' -or @($dependency.Files).Count -eq 0) {
        throw "Missing hash or file mappings for $($dependency.Id)"
    }
    if ($dependency.Archive -eq 'file' -and @($dependency.Files).Count -ne 1) {
        throw "A direct-file dependency must contain exactly one mapping: $($dependency.Id)"
    }
    foreach ($mapping in $dependency.Files) {
        Resolve-ChildPath $RuntimeCacheDirectory $mapping.Source | Out-Null
        Resolve-ChildPath $StageDirectory $mapping.Target | Out-Null
        if (-not $targets.Add(($mapping.Target -replace '\\', '/'))) {
            throw "Duplicate staged destination: $($mapping.Target)"
        }
    }
}

foreach ($dependency in $plan.Dependencies) {
    $downloadPath = Resolve-ChildPath $DownloadsDirectory ($dependency.Id + '.' + $dependency.Archive)
    $downloadPath = Get-VerifiedDownload $dependency.Url $downloadPath $dependency.SHA256
    $cacheRoot = Resolve-ChildPath $RuntimeCacheDirectory ($dependency.Id + '-' + $dependency.SHA256.ToLowerInvariant())
    [IO.Directory]::CreateDirectory($cacheRoot) | Out-Null
    $archive = $null
    try {
        if ($dependency.Archive -eq 'zip') {
            $archive = [IO.Compression.ZipFile]::OpenRead($downloadPath)
        }
        foreach ($mapping in $dependency.Files) {
            $cachedFile = Resolve-ChildPath $cacheRoot $mapping.Source
            if ($dependency.Archive -eq 'zip') {
                Expand-ApprovedMember $archive $mapping.Source $cachedFile | Out-Null
            }
            else {
                New-ParentDirectory $cachedFile
                Copy-Item -LiteralPath $downloadPath -Destination $cachedFile -Force
            }
            $payload.Add([pscustomobject]@{
                Source = $cachedFile
                Target = $mapping.Target
                SHA256 = (Get-FileHash -LiteralPath $cachedFile -Algorithm SHA256).Hash
            })
        }

        if ($dependency.Id -eq 'optiscaler_fg' -and $null -ne $archive) {
            foreach ($candidate in @(
                'DLSS5-Optimised/LICENSE', 'DLSS5-Optimised/LICENSE.txt',
                'DLSS5-Optimised/COPYING', 'DLSS5-Optimised/COPYING.txt',
                'LICENSE', 'LICENSE.txt', 'COPYING', 'COPYING.txt'
            )) {
                if (@($archive.Entries | Where-Object { $_.FullName -ceq $candidate }).Count -gt 0) {
                    $licensePath = Resolve-ChildPath $cacheRoot 'package-license.txt'
                    Expand-ApprovedMember $archive $candidate $licensePath | Out-Null
                    $licenseOrigin = "$($dependency.Url) :: $candidate"
                    break
                }
            }
        }
    }
    finally {
        if ($null -ne $archive) { $archive.Dispose() }
    }
    $receipts.Add([pscustomobject]@{
        Id = $dependency.Id
        Url = $dependency.Url
        SHA256 = $dependency.SHA256.ToUpperInvariant()
    })
}

if ($null -eq $licensePath) {
    # Pin the fallback text to the same source revision as the approved runtime.
    if ($plan.Backend.Commit -ne '6bfc4389c25054ef6747df6e6b1b470e9541c4da') {
        throw 'OptiScaler archive has no license; add a reviewed license pin for the new source revision.'
    }
    $licenseOrigin = 'https://raw.githubusercontent.com/Skynizz/optiscaler-dlss5/6bfc4389c25054ef6747df6e6b1b470e9541c4da/LICENSE'
    $licensePath = Resolve-ChildPath $DownloadsDirectory 'optiscaler-LICENSE.txt'
    $licensePath = Get-VerifiedDownload $licenseOrigin $licensePath '3972DC9744F6499F0F9B2DBF76696F2AE7AD8AF9B23DDE66D6AF86C9DFB36986'
}
$licenseText = Get-Content -LiteralPath $licensePath -Raw
if ($licenseText -notmatch 'GNU GENERAL PUBLIC LICENSE' -or $licenseText -notmatch 'Version 3, 29 June 2007') {
    throw 'The OptiScaler license file is not the expected GPL version 3 text.'
}

$iniLines = New-Object 'System.Collections.Generic.List[string]'
foreach ($section in $plan.InitialConfiguration.PSObject.Properties) {
    if ($section.Name -notmatch '^[A-Za-z0-9_]+$') { throw "Invalid INI section: $($section.Name)" }
    $iniLines.Add("[$($section.Name)]")
    $hasMenuShortcut = $false
    foreach ($setting in $section.Value.PSObject.Properties) {
        if ($setting.Name -notmatch '^[A-Za-z0-9_]+$') { throw "Invalid INI setting: $($setting.Name)" }
        $value = [string]$setting.Value
        if ($section.Name -eq 'Menu' -and $setting.Name -eq 'ShortcutKey') {
            $value = '0x2D'
            $hasMenuShortcut = $true
        }
        if ($value -match '[\r\n\x00]') { throw "Multiline INI value: $($setting.Name)" }
        $iniLines.Add("$($setting.Name)=$value")
    }
    if ($section.Name -eq 'Menu' -and -not $hasMenuShortcut) { $iniLines.Add('ShortcutKey=0x2D') }
    $iniLines.Add('')
}
if ($null -eq $plan.InitialConfiguration.PSObject.Properties['Menu']) {
    $iniLines.Add('[Menu]')
    $iniLines.Add('ShortcutKey=0x2D')
    $iniLines.Add('')
}

# All downloads, members, license and configuration are validated before staging.
foreach ($entry in $payload) {
    $destination = Resolve-ChildPath $StageDirectory $entry.Target
    New-ParentDirectory $destination
    Copy-Item -LiteralPath $entry.Source -Destination $destination -Force
    Assert-Sha256 $destination $entry.SHA256
}
$configPath = Resolve-ChildPath $StageDirectory $plan.Backend.ConfigurationFilename
New-ParentDirectory $configPath
[IO.File]::WriteAllLines($configPath, $iniLines, $utf8NoBom)
$stagedLicense = Resolve-ChildPath $StageDirectory 'docs/licenses/OptiScaler-LICENSE.txt'
New-ParentDirectory $stagedLicense
Copy-Item -LiteralPath $licensePath -Destination $stagedLicense -Force

$notice = @"
OptiScaler source availability and runtime provenance

Runtime: $($plan.Backend.Repository), version $($plan.Backend.Version)
Exact source revision: $($plan.Backend.Commit)
License: GPL-3.0, included in docs/licenses/OptiScaler-LICENSE.txt.
Original license source: $licenseOrigin

Corresponding source archive (including submodules):
$($plan.Backend.SourceArchiveUrl)
Source archive SHA256:
$($plan.Backend.SourceArchiveSHA256)

This stage contains the unmodified published OptiScaler DLL, renamed version.dll.
The source archive is not downloaded by this script. Preserve its availability and
fulfil the GPL source-distribution requirements if redistributing this payload.
NVIDIA DLLs retain their separate licenses in OptiScaler/streamline/licenses.

This script downloaded and verified runtime files only. It did not install files
into Last Epoch or execute downloaded binaries. Frame generation compatibility
still requires in-game validation. The OptiScaler menu uses Insert (0x2D).
"@
$noticePath = Resolve-ChildPath $StageDirectory 'docs/OptiScaler-SOURCE.txt'
[IO.File]::WriteAllText($noticePath, $notice, $utf8NoBom)
$receiptPath = Resolve-ChildPath $StageDirectory 'docs/backend-downloads.json'
$receipt = [ordered]@{
    SchemaVersion = 1
    Dependencies = @($receipts.ToArray())
    OptiScalerLicense = [ordered]@{
        Source = $licenseOrigin
        SHA256 = (Get-FileHash -LiteralPath $licensePath -Algorithm SHA256).Hash
    }
    Files = @($payload.ToArray() | Select-Object Target, SHA256)
}
[IO.File]::WriteAllText($receiptPath, ($receipt | ConvertTo-Json -Depth 6), $utf8NoBom)
Write-Host "Verified $($receipts.Count) backend dependencies and staged $($payload.Count) approved files in $StageDirectory"
Write-Host 'OptiScaler menu: Insert. No game files changed.'

