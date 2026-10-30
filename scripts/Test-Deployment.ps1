# Isolated integration checks: never targets the actual game installation.
[CmdletBinding()]
param()
. (Join-Path $PSScriptRoot 'Deployment.ps1')
$fixture = Join-Path $PSScriptRoot ('.deployment-test-' + [Guid]::NewGuid().ToString('N'))
$game = Join-Path $fixture 'game'
$source = Join-Path $fixture 'payload'
$diagnostics = Join-Path $fixture 'diagnostics'
$checks = 0
function Check([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "CHECK FAILED: $Message" }
    $script:checks++
}
function Must-Throw([scriptblock]$Action, [string]$Message) {
    $thrown = $false
    try { & $Action | Out-Null } catch { $thrown = $true }
    Check $thrown $Message
}
try {
    New-Item -ItemType Directory -Path $game, $source -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $game 'Last Epoch.exe') -Value 'fixture executable; never run'
    Set-Content -LiteralPath (Join-Path $game 'GameAssembly.dll') -Value 'fixture assembly'
    Set-Content -LiteralPath (Join-Path $source 'new-addon.dll') -Value 'version one'
    Set-Content -LiteralPath (Join-Path $source 'shared.txt') -Value 'original'
    Copy-Item -LiteralPath (Join-Path $source 'shared.txt') -Destination (Join-Path $game 'shared.txt')
    Install-ManagedPayload $source $game $diagnostics 'fixture' -WhatIf
    Check (-not (Test-Path -LiteralPath $diagnostics)) 'WhatIf must not create a journal or files.'
    Install-ManagedPayload $source $game $diagnostics 'fixture' | Out-Null
    Check ((Get-Content -LiteralPath (Join-Path $game 'new-addon.dll') -Raw).Trim() -eq 'version one') 'Initial installation failed.'
    $manifestPath = Join-Path $diagnostics 'deployment-manifest.json'
    $journal = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $shared = $journal.files | Where-Object relativePath -eq 'shared.txt'
    Check ($null -ne $shared.originalBackup) 'Identical pre-existing file needs an original backup.'
    Install-ManagedPayload $source $game $diagnostics 'fixture' | Out-Null
    $journal = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    Check (@($journal.files).Count -eq 2) 'Idempotent install duplicated active manifest entries.'
    Set-Content -LiteralPath (Join-Path $source 'new-addon.dll') -Value 'version two'
    Set-Content -LiteralPath (Join-Path $source 'shared.txt') -Value 'updated'
    Install-ManagedPayload $source $game $diagnostics 'fixture' | Out-Null
    Check ((Get-Content -LiteralPath (Join-Path $game 'new-addon.dll') -Raw).Trim() -eq 'version two') 'Managed update failed.'
    Set-Content -LiteralPath (Join-Path $game 'new-addon.dll') -Value 'external edit'
    Must-Throw { Install-ManagedPayload $source $game $diagnostics 'fixture' } 'Installer overwrote an external edit.'
    Must-Throw { & (Join-Path $PSScriptRoot 'Restore.ps1') -GameDirectory $game -DiagnosticsDirectory $diagnostics } 'Restore overwrote an external edit.'
    Check ((Get-Content -LiteralPath (Join-Path $game 'shared.txt') -Raw).Trim() -eq 'updated') 'Failed restore partially modified another file.'
    Copy-Item -LiteralPath (Join-Path $source 'new-addon.dll') -Destination (Join-Path $game 'new-addon.dll') -Force
    Set-Content -LiteralPath (Join-Path $game 'untracked.cfg') -Value 'keep me'
    $interopDirectory = Join-Path $game 'BepInEx\interop'
    $interopBackups = Join-Path $game 'BepInEx\LastEpochGraphics\interop-backups'
    New-Item -ItemType Directory -Path $interopDirectory, $interopBackups -Force | Out-Null
    $interopTarget = Join-Path $interopDirectory 'UnityEngine.CoreModule.dll'
    Set-Content -LiteralPath $interopTarget -Value 'fixture original wrapper'
    $originalHash = Get-FileSha256 $interopTarget
    $originalBackup = 'UnityEngine.CoreModule.' + $originalHash + '.original.dll'
    Copy-Item -LiteralPath $interopTarget -Destination (Join-Path $interopBackups $originalBackup)
    Set-Content -LiteralPath $interopTarget -Value 'fixture normalized wrapper'
    @{ schemaVersion=1; assembly='UnityEngine.CoreModule'; originalSha256=$originalHash; normalizedSha256=(Get-FileSha256 $interopTarget); originalBackup=$originalBackup } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $interopBackups 'CoreModule-normalization.json')
    & (Join-Path $PSScriptRoot 'Restore.ps1') -GameDirectory $game -DiagnosticsDirectory $diagnostics | Out-Null
    Check ((Get-FileSha256 $interopTarget) -eq $originalHash) 'Restore did not restore original generated wrapper.'
    Check (Test-Path -LiteralPath (Join-Path $interopBackups $originalBackup)) 'Generated wrapper backup was not retained.'
    Check (-not (Test-Path -LiteralPath (Join-Path $game 'new-addon.dll'))) 'Restore did not remove an unchanged owned file.'
    Check ((Get-Content -LiteralPath (Join-Path $game 'shared.txt') -Raw).Trim() -eq 'original') 'Restore did not recover original bytes.'
    Check (Test-Path -LiteralPath (Join-Path $game 'untracked.cfg')) 'Restore removed an untracked file.'
    Check (Test-Path -LiteralPath (Join-Path $game 'Last Epoch.exe')) 'Restore touched a game file.'
    Set-Content -LiteralPath (Join-Path $source 'shared.txt') -Value 'original'
    Install-ManagedPayload $source $game $diagnostics 'fixture' | Out-Null
    Check (Test-Path -LiteralPath (Join-Path $game 'new-addon.dll')) 'Reinstall after restore failed.'
    Must-Throw { Get-SafeChildPath $game '..\outside.txt' } 'Path traversal was accepted.'
    Set-Content -LiteralPath (Join-Path $source 'GameAssembly.dll') -Value 'forbidden'
    Must-Throw { Install-ManagedPayload $source $game $diagnostics 'fixture' } 'Protected game file replacement was accepted.'
    Remove-Item -LiteralPath (Join-Path $source 'GameAssembly.dll')
    Must-Throw { Install-ManagedPayload $source $game (Join-Path $game 'diagnostics') 'fixture' } 'Journal inside game installation was accepted.'
    Set-Content -LiteralPath $interopTarget -Value 'regenerated wrapper'
    & (Join-Path $PSScriptRoot 'Restore.ps1') -GameDirectory $game -DiagnosticsDirectory $diagnostics | Out-Null
    Check ((Get-Content -LiteralPath $interopTarget -Raw).Trim() -eq 'regenerated wrapper') 'Restore changed a newer regenerated wrapper.'
    Write-Output "Passed $checks deployment checks. Fixture files were isolated from the installed game."
} finally {
    # Delete only this test's checked children, never recurse over a computed deletion target.
    $safeFixture = Get-FullDirectoryPath $fixture
    $safeScripts = Get-FullDirectoryPath $PSScriptRoot
    if (-not $safeFixture.StartsWith($safeScripts + '\.deployment-test-', [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid test cleanup root.' }
    if (Test-Path -LiteralPath $safeFixture) {
        Assert-NoReparsePoint $safeFixture
        $children = @(Get-ChildItem -LiteralPath $safeFixture -Recurse -Force | Sort-Object { $_.FullName.Length } -Descending)
        foreach ($child in $children) {
            if (-not $child.FullName.StartsWith($safeFixture + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid test cleanup child.' }
            Remove-Item -LiteralPath $child.FullName
        }
        Remove-Item -LiteralPath $safeFixture
    }
}
