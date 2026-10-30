Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-FullDirectoryPath {
    param([Parameter(Mandatory)][string]$Path)
    return [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
}

function Assert-NoReparsePoint {
    param([Parameter(Mandatory)][string]$Path)
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Refusing a junction or symbolic link in deployment path: $current"
            }
        }
        $parent = [IO.Path]::GetDirectoryName($current)
        if ($parent -eq $current) { break }
        $current = $parent
    }
}

function Get-SafeChildPath {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$RelativePath)
    if ([IO.Path]::IsPathRooted($RelativePath) -or $RelativePath -match '(^|[\\/])\.\.([\\/]|$)|:') {
        throw "Invalid relative deployment path: $RelativePath"
    }
    $rootPath = Get-FullDirectoryPath $Root
    $childPath = [IO.Path]::GetFullPath((Join-Path $rootPath $RelativePath))
    if (-not $childPath.StartsWith($rootPath + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Deployment path escapes its root: $RelativePath"
    }
    Assert-NoReparsePoint $childPath
    return $childPath
}

function Assert-GameStopped {
    if (Get-Process -Name 'Last Epoch' -ErrorAction SilentlyContinue) {
        throw 'Close Last Epoch before installing, restoring, or launching another instance.'
    }
}

function Assert-GameDirectory {
    param([Parameter(Mandatory)][string]$GameDirectory)
    Assert-NoReparsePoint $GameDirectory
    foreach ($name in @('Last Epoch.exe', 'GameAssembly.dll')) {
        if (-not (Test-Path -LiteralPath (Join-Path $GameDirectory $name) -PathType Leaf)) {
            throw "Not a Last Epoch IL2CPP installation: missing $name in $GameDirectory"
        }
    }
}

function Get-FileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Save-DeploymentManifest {
    param([Parameter(Mandatory)]$Manifest, [Parameter(Mandatory)][string]$Path)
    $Manifest.updatedAtUtc = [DateTime]::UtcNow.ToString('o')
    $temporaryPath = $Path + '.tmp'
    Assert-NoReparsePoint $temporaryPath
    $Manifest | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $temporaryPath -Encoding UTF8
    Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
}

function Read-DeploymentManifest {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$GameDirectory)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    Assert-NoReparsePoint $Path
    $manifest = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ($manifest.schemaVersion -ne 1) { throw 'Unsupported deployment manifest version.' }
    if (-not [string]::Equals((Get-FullDirectoryPath $manifest.gameDirectory), $GameDirectory, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'This deployment manifest belongs to another game directory.'
    }
    return $manifest
}

function Install-ManagedPayload {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$SourceDirectory,
        [Parameter(Mandatory)][string]$GameDirectory,
        [Parameter(Mandatory)][string]$DiagnosticsDirectory,
        [Parameter(Mandatory)][string]$Component
    )
    $gamePath = Get-FullDirectoryPath $GameDirectory
    $sourcePath = Get-FullDirectoryPath $SourceDirectory
    $diagnosticsPath = Get-FullDirectoryPath $DiagnosticsDirectory
    Assert-GameStopped
    Assert-GameDirectory $gamePath
    Assert-NoReparsePoint $sourcePath
    Assert-NoReparsePoint $diagnosticsPath
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Container)) { throw "Payload is missing: $sourcePath" }
    if ($sourcePath -eq $gamePath -or $sourcePath.StartsWith($gamePath + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Payload must be staged outside the game installation.'
    }
    if ($diagnosticsPath -eq $gamePath -or $diagnosticsPath.StartsWith($gamePath + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Deployment journal and backups must be outside the game installation.'
    }
    $manifestPath = Join-Path $diagnosticsPath 'deployment-manifest.json'
    $manifest = Read-DeploymentManifest $manifestPath $gamePath
    if (-not $manifest) {
        $manifest = [pscustomobject]@{
            schemaVersion = 1; gameDirectory = $gamePath
            createdAtUtc = [DateTime]::UtcNow.ToString('o'); updatedAtUtc = ''; files = @()
        }
    }
    $managed = @{}
    foreach ($entry in @($manifest.files | Where-Object state -eq 'active')) { $managed[$entry.relativePath] = $entry }
    # Refuse unrelated loader/proxy installations rather than silently stacking hooks.
    foreach ($conflict in @('winhttp.dll', 'version.dll', 'winmm.dll', 'dxgi.dll', 'd3d11.dll', 'd3d12.dll', 'doorstop_config.ini')) {
        $conflictPath = Get-SafeChildPath $gamePath $conflict
        if ((Test-Path -LiteralPath $conflictPath) -and -not $managed.ContainsKey($conflict)) {
            throw "Unmanaged loader/proxy conflict: $conflictPath"
        }
    }
    if ((Test-Path -LiteralPath (Join-Path $gamePath 'MelonLoader')) -or
        ((Test-Path -LiteralPath (Join-Path $gamePath 'BepInEx')) -and @($manifest.files).Count -eq 0)) {
        throw 'An unmanaged mod loader directory already exists. Reconcile that installation first.'
    }
    $items = @(Get-ChildItem -LiteralPath $sourcePath -Recurse -Force)
    if ($items | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }) {
        throw 'Payload contains a junction or symbolic link.'
    }
    $plans = @()
    foreach ($file in @($items | Where-Object { -not $_.PSIsContainer })) {
        $relative = $file.FullName.Substring($sourcePath.Length + 1)
        if ($relative -match '^(Last Epoch\.exe|GameAssembly\.dll|UnityPlayer\.dll)$' -or
            ($relative -match '^Last Epoch_Data[\\/]' -and $relative -notmatch '^Last Epoch_Data[\\/]Plugins[\\/]x86_64[\\/]')) {
            throw "Payload attempts to overwrite a protected game file: $relative"
        }
        $targetPath = Get-SafeChildPath $gamePath $relative
        $sourceHash = Get-FileSha256 $file.FullName
        $entry = $managed[$relative]
        $targetHash = $null
        if (Test-Path -LiteralPath $targetPath) {
            if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf)) { throw "Target is not a file: $targetPath" }
            $targetHash = Get-FileSha256 $targetPath
            if ($entry) {
                if ($targetHash -notin @($entry.installedHashes)) { throw "Managed file was changed externally: $targetPath" }
            } elseif ($targetHash -ne $sourceHash) {
                throw "Unmanaged file conflicts with payload: $targetPath"
            }
        }
        $plans += [pscustomobject]@{ relative = $relative; source = $file.FullName; target = $targetPath; hash = $sourceHash; oldHash = $targetHash; entry = $entry }
    }
    if ($plans.Count -eq 0) { throw 'Payload contains no files.' }
    if (-not $PSCmdlet.ShouldProcess($gamePath, "Install $Component ($($plans.Count) files); journal: $manifestPath")) { return }
    New-Item -ItemType Directory -Path $diagnosticsPath -Force | Out-Null
    Save-DeploymentManifest $manifest $manifestPath
    foreach ($plan in $plans) {
        # Recheck immediately before each write to detect edits since preflight.
        $currentHash = if (Test-Path -LiteralPath $plan.target -PathType Leaf) { Get-FileSha256 $plan.target } else { $null }
        if ($currentHash -ne $plan.oldHash) { throw "File changed after preflight; restore from journal if needed: $($plan.target)" }
        if (-not $plan.entry) {
            $backupRelative = $null
            if ($plan.oldHash) {
                $backupRelative = 'deployment-backups\' + [Guid]::NewGuid().ToString('N') + '.original'
                $backupPath = Get-SafeChildPath $diagnosticsPath $backupRelative
                New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($backupPath)) -Force | Out-Null
                Copy-Item -LiteralPath $plan.target -Destination $backupPath
                if ((Get-FileSha256 $backupPath) -ne $plan.oldHash) { throw 'Backup verification failed.' }
            }
            $plan.entry = [pscustomobject]@{
                relativePath = $plan.relative; component = $Component; state = 'active'
                installedSha256 = $plan.hash; installedHashes = @($plan.hash)
                originalSha256 = $plan.oldHash; originalBackup = $backupRelative; restoredAtUtc = $null
            }
            $manifest.files = @($manifest.files) + @($plan.entry)
        } else {
            $plan.entry.installedSha256 = $plan.hash
            $plan.entry.installedHashes = @(@($plan.entry.installedHashes) + $plan.hash | Select-Object -Unique)
            $plan.entry.component = $Component
        }
        # Journal the desired and prior known hashes before mutation, so an interrupted copy is recoverable.
        Save-DeploymentManifest $manifest $manifestPath
        $null = Get-SafeChildPath $gamePath $plan.relative
        New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($plan.target)) -Force | Out-Null
        $stagedPath = $plan.target + '.le-dlss-' + [Guid]::NewGuid().ToString('N') + '.tmp'
        Assert-NoReparsePoint $stagedPath
        try {
            Copy-Item -LiteralPath $plan.source -Destination $stagedPath
            if ((Get-FileSha256 $stagedPath) -ne $plan.hash) { throw "Staged checksum mismatch: $($plan.target)" }
            Move-Item -LiteralPath $stagedPath -Destination $plan.target -Force
        } finally {
            if (Test-Path -LiteralPath $stagedPath -PathType Leaf) { Remove-Item -LiteralPath $stagedPath }
        }
        if ((Get-FileSha256 $plan.target) -ne $plan.hash) { throw "Installed checksum mismatch: $($plan.target)" }
    }
    Save-DeploymentManifest $manifest $manifestPath
    [pscustomobject]@{ Component = $Component; Files = $plans.Count; GameDirectory = $gamePath; Manifest = $manifestPath }
}
