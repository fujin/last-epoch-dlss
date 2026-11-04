# Pure decisions plus an isolated read-only scan fixture. Never queries or targets the installed game.
[CmdletBinding()]
param()
. (Join-Path $PSScriptRoot 'Preflight.Core.ps1')
$checks = 0
function Check([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "CHECK FAILED: $Message" }
    $script:checks++
}
function Find-Check($Results, [string]$Id) { @($Results | Where-Object Id -eq $Id)[0] }
$hashA = 'a' * 64
$hashB = 'b' * 64
Check ((Test-LePreflightFileFact Stage fixture $false '' $hashA 'Prepare payload.').Status -eq 'Fail') 'Missing required file must block.'
Check ((Test-LePreflightFileFact Stage fixture $true $hashA $hashA '').Status -eq 'Pass') 'Matching pin should pass.'
Check ((Test-LePreflightFileFact Stage fixture $true $hashB $hashA '').Status -eq 'Fail') 'Changed pin must block.'
Check ((Test-LePreflightFileFact Stage fixture $true $hashA 'bad hash' '').Status -eq 'Fail') 'Malformed pin must block.'
Check ((Test-LePreflightFileFact Source fixture $true '' '' '').Status -eq 'Pass') 'Presence-only source requirement should pass without claiming authentication.'
$files = @{
    'Last Epoch.exe'=$true
    'GameAssembly.dll'=$true
    'UnityPlayer.dll'=$true
    'Last Epoch_Data\il2cpp_data\Metadata\global-metadata.dat'=$true
}
$gameChecks = @(Test-LePreflightGameFacts $files '6000.4.8f1 (test hash)' '6000.4.8f1' @() '')
Check ((Find-Check $gameChecks unity-version).Status -eq 'Pass') 'Known Unity product version should be recognized.'
Check ((Find-Check $gameChecks game-build).Status -eq 'Warning') 'Unity version must not certify game build.'
Check ((Find-Check $gameChecks game-stopped).Status -eq 'Pass') 'Empty injected process list should mean stopped.'
$runningChecks = @(Test-LePreflightGameFacts $files '6000.4.8f1' '6000.4.8f1' @('Last Epoch') '')
Check ((Find-Check $runningChecks game-stopped).Status -eq 'Fail') 'Running game must block deployment.'
$unknownChecks = @(Test-LePreflightGameFacts $files '6000.5.1f1' '6000.4.8f1' @() 'Access denied')
Check ((Find-Check $unknownChecks game-stopped).Status -eq 'Fail') 'Failed process inspection cannot mean stopped.'
Check ((Find-Check $unknownChecks unity-version).Status -eq 'Warning') 'Unknown engine should be labeled unverified.'
$files['GameAssembly.dll']=$false
Check ((Find-Check @(Test-LePreflightGameFacts $files '' '6000.4.8f1' @() '') 'game:GameAssembly.dll').Status -eq 'Fail') 'Wrong game root should block.'
Check ((Test-LePreflightTargetFact 'version.dll' $hashA File $hashA $false @()).Status -eq 'Fail') 'Unmanaged proxy must block even if bytes happen to match.'
Check ((Test-LePreflightTargetFact 'addon.dll' $hashA File $hashA $false @()).Status -eq 'Pass') 'Identical nonproxy can be backed up by installer.'
Check ((Test-LePreflightTargetFact 'addon.dll' $hashA File $hashB $false @()).Status -eq 'Fail') 'Unmanaged changed file must block.'
Check ((Test-LePreflightTargetFact 'addon.dll' $hashA File $hashB $true @($hashB)).Status -eq 'Pass') 'Recognized owned prior version should allow an update.'
Check ((Test-LePreflightTargetFact 'addon.dll' $hashA File $hashB $true @($hashA)).Status -eq 'Fail') 'External edit of journal-owned file must block.'
Check ((Test-LePreflightTargetFact 'addon.dll' $hashA Directory '' $false @()).Status -eq 'Fail') 'Directory collision must block.'
Check ((Test-LePreflightTargetFact 'GameAssembly.dll' $hashA Missing '' $false @()).Status -eq 'Fail') 'Protected game file must never be staged.'
Check ((Test-LePreflightTargetFact 'Last Epoch_Data\globalgamemanagers' $hashA Missing '' $false @()).Status -eq 'Fail') 'Protected game data must block.'
Check ((Test-LePreflightTargetFact 'Last Epoch_Data\Plugins\x86_64\addon.dll' $hashA Missing '' $false @()).Status -eq 'Pass') 'Existing installer allowed plugin location should remain allowed.'
$separated = Complete-LePreflightReport @((New-LePreflightCheck Source sdk Fail 'SDK missing'),(New-LePreflightCheck Stage pin Pass 'Present'),(New-LePreflightCheck Game coverage Warning 'Unverified')) All 'fixture' 'fixture'
Check ($separated.SourceStatus -eq 'Blocked' -and $separated.StageStatus -eq 'NoDetectedBlockers') 'Missing SDK must not block an otherwise prepared stage.'
Check ($separated.RuntimeCompatibility -eq 'UnverifiedByPreflight') 'No blockers must never claim runtime compatibility.'
$runningAll = Complete-LePreflightReport @((New-LePreflightCheck Game game-stopped Fail 'Running')) All 'fixture' 'fixture'
Check ($runningAll.SourceStatus -eq 'NoDetectedBlockers' -and $runningAll.StageStatus -eq 'Blocked') 'Running game must block Stage, not Source preparation.'
$unreadableSource = Complete-LePreflightReport @((New-LePreflightCheck Game game-stopped Fail 'Process inspection failed')) Source 'fixture' 'fixture'
Check ($unreadableSource.BlockerCount -eq 0 -and (Find-Check $unreadableSource.Checks game-stopped).Status -eq 'Warning') 'Unknown process state must be advisory for Source-only preparation.'
$sourceOnly = Complete-LePreflightReport @((New-LePreflightCheck Source sdk Pass 'Present')) Source 'fixture' 'fixture'
Check ($sourceOnly.StageStatus -eq 'NotScanned') 'Source-only scan must not certify stage.'

$fixture = Join-Path ([IO.Path]::GetTempPath()) ('le-preflight-test-' + [Guid]::NewGuid().ToString('N'))
$game = Join-Path $fixture 'game'
$project = Join-Path $fixture 'project'
$stage = Join-Path $project 'stage'
$diagnostics = Join-Path $project 'diagnostics'
function Snapshot-Files([string]$Root) {
    @((Get-ChildItem -LiteralPath $Root -Recurse -File | Sort-Object FullName | ForEach-Object { $_.FullName + '|' + (Get-FileSha256 $_.FullName) }) |
        Out-String)
}
try {
    New-Item -ItemType Directory -Path $game, (Join-Path $project 'packaging') -Force | Out-Null
    foreach ($name in @('backend-plan.json','build-prerequisites.json','source-candidates.json')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot ("..\packaging\" + $name)) -Destination (Join-Path $project ("packaging\" + $name))
    }
    Set-Content -LiteralPath (Join-Path $game 'Last Epoch.exe') -Value 'fixture data; never executed'
    Set-Content -LiteralPath (Join-Path $game 'GameAssembly.dll') -Value 'fixture data; never loaded'
    $before = Snapshot-Files $fixture
    $report = Invoke-LePreflightScan -GameDirectory $game -ProjectDirectory $project -StageDirectory $stage -DiagnosticsDirectory $diagnostics -Scope All -ProcessNames @() -ProcessError ''
    $after = Snapshot-Files $fixture
    Check (($before | Out-String) -eq ($after | Out-String)) 'Read-only scan changed fixture file bytes or created files.'
    Check (-not (Test-Path -LiteralPath $stage) -and -not (Test-Path -LiteralPath $diagnostics)) 'Scan created stage/journal directories.'
    Check ($report.SourceStatus -eq 'Blocked' -and $report.StageStatus -eq 'Blocked') 'Fresh incomplete fixture should list both source and stage blockers.'
    Check ((Find-Check $report.Checks game-stopped).Status -eq 'Pass') 'Fixture must use injected processes, independent of actual game state.'
    Check ((Find-Check $report.Checks 'BepInEx\plugins\LastEpochGraphics\LastEpochGraphics.dll').Status -eq 'Fail') 'Stage should require the selected managed artifact.'
    Check ((Find-Check $report.Checks repair-runtime).Status -eq 'Fail') 'Missing external repair runtime should block the current launcher workflow.'
    $sourceReport = Invoke-LePreflightScan -GameDirectory $game -ProjectDirectory $project -StageDirectory $stage -DiagnosticsDirectory $diagnostics -Scope Source -ProcessNames @('Last Epoch') -ProcessError ''
    Check ($sourceReport.StageStatus -eq 'NotScanned') 'Source scan should not inspect a selected stage.'
    Check ((Find-Check $sourceReport.Checks game-stopped).Status -eq 'Warning') 'Source-only running state must be advisory without stopping a real process.'
    # Required pins cannot silently turn into presence-only checks, including optional NR.
    $planPath = Join-Path $project 'packaging\backend-plan.json'
    $originalPlan = Get-Content -LiteralPath $planPath -Raw
    New-Item -ItemType Directory -Path (Join-Path $stage 'OptiScaler') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $stage 'OptiScaler\nvngx.dll_dlssnr.dll') -Value 'fixture forwarder; never loaded'
    foreach ($badPin in @('', 'not-a-sha256')) {
        $plan = $originalPlan | ConvertFrom-Json
        ($plan.Dependencies | Where-Object Archive -eq file | Select-Object -First 1).SHA256 = $badPin
        $plan | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $planPath
        $pinReport = Invoke-LePreflightScan -GameDirectory $game -ProjectDirectory $project -StageDirectory $stage -DiagnosticsDirectory $diagnostics -Scope Stage -ProcessNames @() -ProcessError ''
        Check ((Find-Check $pinReport.Checks packaging-manifests).Detail -match 'dependency SHA256') 'Empty/malformed direct-file dependency pin must be rejected before receipt/presence checks.'
        $plan = $originalPlan | ConvertFrom-Json
        $plan.OptionalNeuralRendering.Archive.Files[0].SHA256 = $badPin
        $plan | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $planPath
        $pinReport = Invoke-LePreflightScan -GameDirectory $game -ProjectDirectory $project -StageDirectory $stage -DiagnosticsDirectory $diagnostics -Scope Stage -ProcessNames @() -ProcessError ''
        Check ((Find-Check $pinReport.Checks optional-nr).Status -eq 'Fail' -and (Find-Check $pinReport.Checks optional-nr).Detail -match 'optional NR SHA256') 'Empty/malformed selected NR pin must be a structured blocker.'
    }
    # Exercise path rejection in the actual optional-NR observer without creating a junction.
    $plan = $originalPlan | ConvertFrom-Json
    $plan.OptionalNeuralRendering.Forwarder.Target = '..\outside.dll'
    $plan | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $planPath
    $pathReport = Invoke-LePreflightScan -GameDirectory $game -ProjectDirectory $project -StageDirectory $stage -DiagnosticsDirectory $diagnostics -Scope Stage -ProcessNames @() -ProcessError ''
    Check ((Find-Check $pathReport.Checks optional-nr).Status -eq 'Fail' -and (Find-Check $pathReport.Checks optional-nr).Detail -match 'Invalid relative deployment path') 'NR observation path failure must remain in the report.'
    Set-Content -LiteralPath $planPath -Value $originalPlan
    Set-Content -LiteralPath (Join-Path $game 'UnityPlayer.dll') -Value 'fixture version metadata; never loaded'
    $originalUnityObserver = (Get-Item -LiteralPath Function:\Get-LePreflightUnityProductVersion).ScriptBlock
    $originalRuntimeObserver = (Get-Item -LiteralPath Function:\Get-LePreflightRuntime8Directories).ScriptBlock
    try {
        # Replace only read observers in this fixture process; no public guard or filesystem ACL changes.
        Set-Item -LiteralPath Function:\Get-LePreflightUnityProductVersion -Value { throw 'Fixture denied metadata read.' }
        Set-Item -LiteralPath Function:\Get-LePreflightRuntime8Directories -Value { throw 'Fixture blocked runtime path.' }
        $observationReport = Invoke-LePreflightScan -GameDirectory $game -ProjectDirectory $project -StageDirectory $stage -DiagnosticsDirectory $diagnostics -Scope Stage -ProcessNames @() -ProcessError ''
        Check ((Find-Check $observationReport.Checks unity-metadata).Status -eq 'Fail') 'Unreadable Unity version metadata must be a structured blocker.'
        Check ((Find-Check $observationReport.Checks repair-runtime).Detail -eq 'Fixture blocked runtime path.') 'Runtime path/enumeration failure must be a structured blocker.'
        $jsonReport = $observationReport | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        Check ($jsonReport.ReadOnly -and (Find-Check $jsonReport.Checks unity-metadata).Status -eq 'Fail' -and (Find-Check $jsonReport.Checks repair-runtime).Status -eq 'Fail') 'Observation failures must preserve a complete serializable report.'
    } finally {
        Set-Item -LiteralPath Function:\Get-LePreflightUnityProductVersion -Value $originalUnityObserver
        Set-Item -LiteralPath Function:\Get-LePreflightRuntime8Directories -Value $originalRuntimeObserver
    }
    $badJson = Join-Path $project 'packaging\backend-plan.json'
    Set-Content -LiteralPath $badJson -Value '{'
    $badReport = Invoke-LePreflightScan -GameDirectory $game -ProjectDirectory $project -StageDirectory $stage -DiagnosticsDirectory $diagnostics -Scope Stage -ProcessNames @() -ProcessError ''
    Check ((Find-Check $badReport.Checks packaging-manifests).Status -eq 'Fail') 'Malformed packaging metadata should produce a blocking report.'
    Write-Output "Passed $checks preflight checks; no installed game, binaries or network were used."
} finally {
    $safeFixture = Get-FullDirectoryPath $fixture
    $safeTemp = Get-FullDirectoryPath ([IO.Path]::GetTempPath())
    if (-not $safeFixture.StartsWith($safeTemp + '\le-preflight-test-', [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid preflight fixture cleanup root.' }
    if (Test-Path -LiteralPath $safeFixture) {
        Assert-NoReparsePoint $safeFixture
        foreach ($child in @(Get-ChildItem -LiteralPath $safeFixture -Recurse -Force | Sort-Object { $_.FullName.Length } -Descending)) {
            if (-not $child.FullName.StartsWith($safeFixture + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid cleanup child.' }
            Remove-Item -LiteralPath $child.FullName
        }
        Remove-Item -LiteralPath $safeFixture
    }
}
