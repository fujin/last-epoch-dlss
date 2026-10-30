[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$GameDirectory = 'G:\SteamLibrary\steamapps\common\Last Epoch',
    [string]$DiagnosticsDirectory = (Join-Path $PSScriptRoot '..\diagnostics')
)
. (Join-Path $PSScriptRoot 'Deployment.ps1')
$gamePath = Get-FullDirectoryPath $GameDirectory
$diagnosticsPath = Get-FullDirectoryPath $DiagnosticsDirectory
Assert-GameStopped
Assert-NoReparsePoint $gamePath
Assert-NoReparsePoint $diagnosticsPath
if (-not $WhatIfPreference) {
    & (Join-Path $PSScriptRoot 'Sync-BackendConfig.ps1') -GameDirectory $gamePath -DiagnosticsDirectory $diagnosticsPath
}
$manifestPath = Join-Path $diagnosticsPath 'deployment-manifest.json'
$manifest = Read-DeploymentManifest $manifestPath $gamePath
if (-not $manifest) { throw "No deployment journal found: $manifestPath" }
$pending = @($manifest.files | Where-Object state -eq 'active')
$interopRestore = $null
$interopRecordPath = Get-SafeChildPath $gamePath 'BepInEx\LastEpochGraphics\interop-backups\CoreModule-normalization.json'
if (Test-Path -LiteralPath $interopRecordPath -PathType Leaf) {
    $record = Get-Content -LiteralPath $interopRecordPath -Raw | ConvertFrom-Json
    $interopTarget = Get-SafeChildPath $gamePath 'BepInEx\interop\UnityEngine.CoreModule.dll'
    if ($record.schemaVersion -ne 1 -or $record.assembly -ne 'UnityEngine.CoreModule' -or
        $record.originalSha256 -notmatch '^[0-9a-f]{64}$' -or $record.normalizedSha256 -notmatch '^[0-9a-f]{64}$') {
        throw 'Invalid generated CoreModule repair record.'
    }
    if ((Test-Path -LiteralPath $interopTarget -PathType Leaf) -and (Get-FileSha256 $interopTarget) -eq $record.normalizedSha256) {
        $expectedBackup = 'UnityEngine.CoreModule.' + $record.originalSha256 + '.original.dll'
        if ($record.originalBackup -ne $expectedBackup) { throw 'Invalid CoreModule original backup filename.' }
        $interopBackup = Get-SafeChildPath ([IO.Path]::GetDirectoryName($interopRecordPath)) $expectedBackup
        if (-not (Test-Path -LiteralPath $interopBackup -PathType Leaf) -or (Get-FileSha256 $interopBackup) -ne $record.originalSha256) {
            throw 'Generated CoreModule original backup is missing or changed.'
        }
        $interopRestore = [pscustomobject]@{ target=$interopTarget; backup=$interopBackup; record=$record }
    } else {
        Write-Verbose 'Generated CoreModule differs from the normalized output; preserving it.'
    }
}
$conflicts = @()
foreach ($entry in $pending) {
    $target = Get-SafeChildPath $gamePath $entry.relativePath
    if (Test-Path -LiteralPath $target) {
        if (-not (Test-Path -LiteralPath $target -PathType Leaf) -or (Get-FileSha256 $target) -notin @($entry.installedHashes)) {
            $conflicts += $entry.relativePath
        }
    }
    if ($entry.originalBackup) {
        $backup = Get-SafeChildPath $diagnosticsPath $entry.originalBackup
        if (-not (Test-Path -LiteralPath $backup -PathType Leaf) -or (Get-FileSha256 $backup) -ne $entry.originalSha256) {
            throw "Original backup is missing or changed: $backup"
        }
    }
}
if ($conflicts.Count) {
    throw ('Refusing to alter externally changed files; nothing restored: ' + ($conflicts -join ', '))
}
if (-not $PSCmdlet.ShouldProcess($gamePath, "Restore $($pending.Count) tracked files; preserve untracked files and directories")) { return }
if ($null -ne $interopRestore) {
    if ((Get-FileSha256 $interopRestore.target) -ne $interopRestore.record.normalizedSha256) {
        throw 'Generated CoreModule changed during restore.'
    }
    $temporary = $interopRestore.target + '.le-restore-' + [Guid]::NewGuid().ToString('N') + '.tmp'
    Copy-Item -LiteralPath $interopRestore.backup -Destination $temporary
    Move-Item -LiteralPath $temporary -Destination $interopRestore.target -Force
    if ((Get-FileSha256 $interopRestore.target) -ne $interopRestore.record.originalSha256) { throw 'Generated CoreModule restore verification failed.' }
    Write-Output 'Restored the original generated CoreModule wrapper; hash-named backup retained.'
}
foreach ($entry in $pending) {
    $target = Get-SafeChildPath $gamePath $entry.relativePath
    if (Test-Path -LiteralPath $target -PathType Leaf) {
        if ((Get-FileSha256 $target) -notin @($entry.installedHashes)) { throw "File changed during restore: $target" }
    }
    if ($entry.originalBackup) {
        $backup = Get-SafeChildPath $diagnosticsPath $entry.originalBackup
        New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($target)) -Force | Out-Null
        Copy-Item -LiteralPath $backup -Destination $target -Force
        if ((Get-FileSha256 $target) -ne $entry.originalSha256) { throw "Restore verification failed: $target" }
    } elseif (Test-Path -LiteralPath $target -PathType Leaf) {
        Remove-Item -LiteralPath $target
    }
    $entry.state = 'restored'
    $entry.restoredAtUtc = [DateTime]::UtcNow.ToString('o')
    Save-DeploymentManifest $manifest $manifestPath
}
Write-Output "Restored $($pending.Count) tracked files. Generated caches/configuration and untracked files were preserved. Journal: $manifestPath"
