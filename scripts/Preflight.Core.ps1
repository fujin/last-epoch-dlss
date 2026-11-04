# Read-only preflight helpers. Data-only decisions are deliberately separate from observation.
# This file never launches, downloads, installs, repairs, or writes a file.
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Deployment.ps1')
. (Join-Path $PSScriptRoot 'LocalBackend.ps1')

function New-LePreflightCheck {
    param([string]$Scope, [string]$Id, [ValidateSet('Pass','Warning','Fail')][string]$Status, [string]$Detail)
    [pscustomobject]@{ Scope=$Scope; Id=$Id; Status=$Status; Detail=$Detail }
}

function Test-LePreflightFileFact {
    param([string]$Scope, [string]$Id, [bool]$Exists, [string]$ActualHash, [string]$ExpectedHash, [string]$Action)
    if (-not $Exists) { return (New-LePreflightCheck $Scope $Id Fail ("Missing file. " + $Action)) }
    if ($ExpectedHash -and $ExpectedHash -notmatch '^[a-fA-F0-9]{64}$') {
        return (New-LePreflightCheck $Scope $Id Fail 'Invalid expected SHA256 in local manifest; review the manifest.')
    }
    if ($ExpectedHash -and $ActualHash -ne $ExpectedHash) {
        return (New-LePreflightCheck $Scope $Id Fail 'SHA256 differs from the recorded candidate. Do not change trust pins to suppress this; obtain or review the intended artifact.')
    }
    New-LePreflightCheck $Scope $Id Pass $(if ($ExpectedHash) { 'SHA256 matches the recorded candidate.' } else { 'File present; presence alone does not authenticate its bytes.' })
}

function Test-LePreflightGameFacts {
    param([hashtable]$Files, [string]$EngineVersion, [string]$ExpectedEngine, [string[]]$ProcessNames, [string]$ProcessError)
    foreach ($name in @('Last Epoch.exe','GameAssembly.dll','UnityPlayer.dll','Last Epoch_Data\il2cpp_data\Metadata\global-metadata.dat')) {
        New-LePreflightCheck Game "game:$name" $(if ($Files[$name]) { 'Pass' } else { 'Fail' }) $(if ($Files[$name]) { 'Required IL2CPP game file present.' } else { 'Missing required file. Supply the actual Last Epoch game directory, not the mod directory.' })
    }
    if ($ProcessError) { New-LePreflightCheck Game game-stopped Fail "Could not inspect processes: $ProcessError" }
    elseif (@($ProcessNames | Where-Object { $_ -eq 'Last Epoch' }).Count -gt 0) {
        New-LePreflightCheck Game game-stopped Fail 'Last Epoch is running. Close it before any installation or restore; preflight itself has not changed anything.'
    } else { New-LePreflightCheck Game game-stopped Pass 'No Last Epoch process observed in this snapshot. Installers recheck immediately before their work.' }
    if ($EngineVersion -eq $ExpectedEngine -or $EngineVersion.StartsWith($ExpectedEngine + ' ', [StringComparison]::Ordinal)) {
        New-LePreflightCheck Game unity-version Pass "Unity product version matches the tested engine: $EngineVersion"
    } else { New-LePreflightCheck Game unity-version Warning "Unity product version '$EngineVersion' is not the tested '$ExpectedEngine'; treat this installation as unverified." }
    New-LePreflightCheck Game game-build Warning 'The Unity executable version is not the game version. Last Epoch 1.5.3 / Steam build 26087601 was tested; this command does not certify that game build or generated interop freshness.'
    New-LePreflightCheck Game runtime-coverage Warning 'Offline Windows x64/D3D11, native DLAA, RTX 5080 and primary-display 8-bit SDR game output were tested. GPU/driver/API/HDR/online compatibility and rendering cannot be proven by this offline scan.'
}

function Test-LePreflightTargetFact {
    param([string]$RelativePath, [string]$SourceHash, [ValidateSet('Missing','File','Directory')][string]$TargetKind, [string]$TargetHash, [bool]$Managed, [string[]]$InstalledHashes)
    if ($RelativePath -match '^(Last Epoch\.exe|GameAssembly\.dll|UnityPlayer\.dll)$' -or
        ($RelativePath -match '^Last Epoch_Data[\\/]' -and $RelativePath -notmatch '^Last Epoch_Data[\\/]Plugins[\\/]x86_64[\\/]')) {
        return (New-LePreflightCheck Stage "target:$RelativePath" Fail 'Payload contains a protected game file.')
    }
    if ($TargetKind -eq 'Directory') { return (New-LePreflightCheck Stage "target:$RelativePath" Fail 'Payload target is an existing directory.') }
    if ($TargetKind -eq 'Missing') { return (New-LePreflightCheck Stage "target:$RelativePath" Pass 'Target absent; no file collision observed.') }
    if (-not $Managed -and $RelativePath -in @('winhttp.dll','version.dll','winmm.dll','dxgi.dll','d3d11.dll','d3d12.dll','doorstop_config.ini')) {
        return (New-LePreflightCheck Stage "target:$RelativePath" Fail 'Unmanaged loader/proxy conflict. Reconcile it before using the existing installers.')
    }
    if ($Managed -and $TargetHash -notin @($InstalledHashes)) {
        return (New-LePreflightCheck Stage "target:$RelativePath" Fail 'Journal-owned target was changed externally; installer will refuse it.')
    }
    if (-not $Managed -and $SourceHash -ne $TargetHash) {
        return (New-LePreflightCheck Stage "target:$RelativePath" Fail 'Unmanaged target differs from the staged file; installer will refuse it.')
    }
    New-LePreflightCheck Stage "target:$RelativePath" Pass $(if ($Managed) { 'Target matches a journal-owned hash.' } else { 'Existing target has identical bytes; installer will preserve its original.' })
}

function Complete-LePreflightReport {
    param([object[]]$Checks, [string]$Scope, [string]$GameDirectory, [string]$ProjectDirectory)
    if ($Scope -eq 'Source') {
        $Checks = @($Checks | ForEach-Object {
            if ($_.Id -eq 'game-stopped' -and $_.Status -eq 'Fail') {
                New-LePreflightCheck Game $_.Id Warning ($_.Detail + ' Source preparation may proceed; this still blocks installation.')
            } else { $_ }
        })
    }
    $installChecks = @($Checks | Where-Object { $_.Scope -in @('Game','Stage') })
    # Build preparation is read-only with respect to the game; only installation requires it stopped.
    $sourceChecks = @($Checks | Where-Object { $_.Scope -in @('Game','Source') -and $_.Id -ne 'game-stopped' })
    [pscustomobject]@{
        SchemaVersion=1
        Scope=$Scope
        GameDirectory=$GameDirectory
        ProjectDirectory=$ProjectDirectory
        ReadOnly=$true
        SourceStatus=$(if ($Scope -eq 'Stage') { 'NotScanned' } elseif (@($sourceChecks | Where-Object Status -eq Fail).Count) { 'Blocked' } else { 'NoDetectedBlockers' })
        StageStatus=$(if ($Scope -eq 'Source') { 'NotScanned' } elseif (@($installChecks | Where-Object Status -eq Fail).Count) { 'Blocked' } else { 'NoDetectedBlockers' })
        RuntimeCompatibility='UnverifiedByPreflight'
        BlockerCount=@($Checks | Where-Object Status -eq Fail).Count
        WarningCount=@($Checks | Where-Object Status -eq Warning).Count
        Checks=@($Checks)
    }
}

# Small read-only observers let fixtures inject deterministic access failures without ACL changes.
function Get-LePreflightUnityProductVersion([string]$Path) {
    [Diagnostics.FileVersionInfo]::GetVersionInfo($Path).ProductVersion
}
function Get-LePreflightRuntime8Directories([string]$ProjectDirectory) {
    $runtimeBase = Get-SafeChildPath $ProjectDirectory 'tools\dotnet\shared\Microsoft.NETCore.App'
    if (Test-Path -LiteralPath $runtimeBase -PathType Container) {
        Get-ChildItem -LiteralPath $runtimeBase -Directory | Where-Object {
            $_.Name -match '^8\.\d+\.\d+$' -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -and
            (Test-Path -LiteralPath (Join-Path $_.FullName 'coreclr.dll') -PathType Leaf)
        }
    }
}
function Invoke-LePreflightScan {
    # Internal injection seam: tests provide process facts; the public command always obtains them itself.
    param([string]$GameDirectory, [string]$ProjectDirectory, [string]$StageDirectory, [string]$DiagnosticsDirectory,
          [ValidateSet('Source','Stage','All')][string]$Scope, [string[]]$ProcessNames, [string]$ProcessError)
    $checks = [Collections.Generic.List[object]]::new()
    function Add-Check([string]$Group, [string]$Id, [string]$Status, [string]$Detail) {
        $checks.Add((New-LePreflightCheck $Group $Id $Status $Detail))
    }
    function Check-File([string]$Group, [string]$Root, [string]$Relative, [string]$Expected, [string]$Action) {
        try {
            $path = Get-SafeChildPath $Root $Relative
            $exists = Test-Path -LiteralPath $path -PathType Leaf
            $actual = if ($exists -and $Expected) { Get-FileSha256 $path } else { '' }
            $checks.Add((Test-LePreflightFileFact $Group $Relative $exists $actual $Expected $Action))
        } catch { Add-Check $Group $Relative Fail $_.Exception.Message }
    }
    function Read-Json([string]$Root, [string]$Relative) {
        $path = Get-SafeChildPath $Root $Relative
        Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    }
    function Read-PayloadFiles([string]$Root) {
        $pending = [Collections.Generic.Stack[string]]::new()
        $pending.Push($Root)
        while ($pending.Count) {
            $directory = $pending.Pop()
            Assert-NoReparsePoint $directory
            foreach ($item in Get-ChildItem -LiteralPath $directory -Force) {
                if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Payload contains a reparse point: $($item.FullName)" }
                if ($item.PSIsContainer) { $pending.Push($item.FullName) } else { $item }
            }
        }
    }
    $game = Get-FullDirectoryPath $GameDirectory
    $project = Get-FullDirectoryPath $ProjectDirectory
    $stage = Get-FullDirectoryPath $StageDirectory
    $diagnostics = Get-FullDirectoryPath $DiagnosticsDirectory
    $roots = @($game,$project)
    if ($Scope -ne 'Source') { $roots += @($stage,$diagnostics) }
    foreach ($root in $roots) {
        try { Assert-NoReparsePoint $root } catch {
            Add-Check Game path-safety Fail $_.Exception.Message
            return (Complete-LePreflightReport $checks.ToArray() $Scope $game $project)
        }
    }
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or -not [Environment]::Is64BitProcess) {
        Add-Check Game platform Fail 'Use 64-bit PowerShell on Windows.'
    } else { Add-Check Game platform Pass 'Running in 64-bit Windows PowerShell/PowerShell.' }
    try {
        $plan = Read-Json $project 'packaging\backend-plan.json'
        $prerequisites = Read-Json $project 'packaging\build-prerequisites.json'
        $candidates = Read-Json $project 'packaging\source-candidates.json'
        if ($plan.SchemaVersion -ne 1 -or $prerequisites.SchemaVersion -ne 1 -or $candidates.SchemaVersion -ne 1) { throw 'Unsupported packaging manifest schema.' }
        foreach ($pin in @($candidates.ManagedCandidate.SHA256,$candidates.NativeCandidate.SHA256)) {
            if ($pin -notmatch '^[a-fA-F0-9]{64}$') { throw 'Missing or malformed required candidate SHA256.' }
        }
        foreach ($dependency in $plan.Dependencies) {
            if ($dependency.SHA256 -notmatch '^[a-fA-F0-9]{64}$') { throw "Missing or malformed dependency SHA256: $($dependency.Id)" }
        }
    } catch {
        Add-Check Game packaging-manifests Fail $_.Exception.Message
        return (Complete-LePreflightReport $checks.ToArray() $Scope $game $project)
    }
    $files = @{}
    foreach ($relative in @('Last Epoch.exe','GameAssembly.dll','UnityPlayer.dll','Last Epoch_Data\il2cpp_data\Metadata\global-metadata.dat')) {
        try { $files[$relative] = Test-Path -LiteralPath (Get-SafeChildPath $game $relative) -PathType Leaf }
        catch { $files[$relative]=$false; Add-Check Game "path:$relative" Fail $_.Exception.Message }
    }
    $engine = ''
    if ($files['UnityPlayer.dll']) {
        try { $engine = Get-LePreflightUnityProductVersion (Get-SafeChildPath $game 'UnityPlayer.dll') }
        catch { Add-Check Game unity-metadata Fail $_.Exception.Message }
    }
    foreach ($item in Test-LePreflightGameFacts $files ([string]$engine) '6000.4.8f1' $ProcessNames $ProcessError) { $checks.Add($item) }

    if ($Scope -ne 'Stage') {
        Check-File Source $project 'tools\dotnet\dotnet.exe' '' 'Extract the pinned .NET SDK from build-prerequisites.json.'
        Check-File Source $project ("tools\dotnet\sdk\" + $prerequisites.DotnetSdk.Version + '\dotnet.dll') '' 'The scripts use the project-local pinned SDK, not an arbitrary global dotnet.'
        Check-File Source $project 'vendor\Streamline\include\sl_dlss_g.h' '' 'Extract the pinned Streamline headers at the path in build-prerequisites.json.'
        foreach ($name in @('BepInEx.Core.dll','BepInEx.Preloader.Core.dll','Mono.Cecil.dll')) {
            Check-File Source $project ("loader\BepInEx\core\$name") '' 'Extract the pinned BepInEx archive locally.'
        }
        foreach ($relative in @('BepInEx\core\BepInEx.Core.dll','BepInEx\interop\Unity.Postprocessing.Runtime.dll','BepInEx\interop\UnityEngine.CoreModule.dll')) {
            Check-File Source $game $relative '' 'Managed builds need locally generated references from this owned game build. Preflight does not generate or repair them.'
        }
        foreach ($name in @('cmake','ctest','git')) {
            $command = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            Add-Check Source "tool:$name" $(if ($command) { 'Pass' } else { 'Fail' }) $(if ($command) { "Found $($command.Source); no executable was run or version certified." } else { "Install $name for source builds." })
        }
        Add-Check Source native-toolchain Warning 'Visual Studio 2022 C++ x64/v143 and Windows SDK 10.0.26100 are required by the current recipe. Their installation, compiler version and successful configure/build are not certified by this presence scan.'
        Add-Check Source source-provenance Warning 'Source may include newer, unvalidated candidates. Successful compilation does not approve new binary hashes; maintainers must review and promote artifacts before packaging.'
    }
    if ($Scope -ne 'Source') {
        $definition = Get-LocalBackendDefinition
        foreach ($root in @($stage,$diagnostics,(Join-Path $project 'loader'))) {
            if ($root -eq $game -or $root.StartsWith($game + '\', [StringComparison]::OrdinalIgnoreCase)) {
                Add-Check Stage payload-location Fail 'Stage, loader source and journal must remain outside the game directory.'
            }
        }
        Check-File Stage $stage 'version.dll' $definition.DllSha256 'Obtain/build and promote the selected local backend; the upstream DLL lacks the selected late-HUDless variant.'
        try { Assert-RecognizedLocalBackend (Get-SafeChildPath $stage 'version.dll'); Add-Check Stage backend-exports Pass 'Recognized backend PE exports present; DLL was not loaded.' }
        catch { Add-Check Stage backend-exports Fail $_.Exception.Message }
        foreach ($doc in $definition.Documents) { Check-File Stage $stage ("docs\local-backend\" + $doc.Name) $doc.SHA256 'Run the reviewed local-backend staging step; preserve its corresponding source and notices.' }
        Check-File Stage $stage 'BepInEx\plugins\LastEpochGraphics\LastEpochGraphics.dll' $candidates.ManagedCandidate.SHA256 'Recorded managed candidate is absent. A different build needs explicit review/promotion.'
        Check-File Stage $stage 'BepInEx\plugins\LastEpochGraphics\LastEpochNative.dll' $candidates.NativeCandidate.SHA256 'Recorded native candidate is absent. A different build needs explicit review/promotion.'
        foreach ($relative in @('OptiScaler.ini','BepInEx\config\local.lastepoch.graphics.cfg','BepInEx\patchers\LoaderDiagnostics\LastEpoch.LoaderDiagnostics.dll')) {
            Check-File Stage $stage $relative '' 'Build and stage the loader fix and choose an explicit DLAA profile before installation.'
        }
        foreach ($relative in @('winhttp.dll','doorstop_config.ini','BepInEx\core\BepInEx.Unity.IL2CPP.dll','dotnet\coreclr.dll','dotnet\System.Private.CoreLib.dll')) {
            Check-File Stage (Join-Path $project 'loader') $relative '' 'A separate complete pinned BepInEx loader payload is required by Install-Loader.ps1.'
        }
        foreach ($relative in @('tools\dotnet\dotnet.exe','tools\interop-repair\LastEpoch.InteropRepair.dll','tools\interop-repair\LastEpoch.InteropRepair.runtimeconfig.json','tools\interop-repair\LastEpoch.InteropRepair.deps.json','tools\interop-repair\Mono.Cecil.dll')) {
            Check-File Stage $project $relative '' 'The current offline launcher calls the external .NET 8 interop-repair tool; prepare its runtime and files without launching the game.'
        }
        try {
            $runtime8 = @(Get-LePreflightRuntime8Directories $project)
            Add-Check Stage repair-runtime $(if ($runtime8.Count) { 'Pass' } else { 'Fail' }) $(if ($runtime8.Count) { 'Project-local .NET 8 runtime files present; no managed host was executed.' } else { 'Missing project-local .NET 8 runtime for the repair tool.' })
        } catch { Add-Check Stage repair-runtime Fail $_.Exception.Message }
        try {
            $receipt = Read-Json $stage 'docs\backend-downloads.json'
            if ($receipt.SchemaVersion -ne 1) { throw 'Unsupported backend receipt schema.' }
            foreach ($dependency in $plan.Dependencies) {
                $record = @($receipt.Dependencies | Where-Object Id -eq $dependency.Id)
                if ($record.Count -ne 1 -or $record[0].SHA256 -ne $dependency.SHA256) { throw "Receipt dependency pin differs: $($dependency.Id)" }
                foreach ($file in $dependency.Files) {
                    if ($file.Target -eq 'version.dll') { continue } # replaced by the independently pinned local backend
                    $recordedFile = @($receipt.Files | Where-Object Target -eq $file.Target)
                    if ($recordedFile.Count -ne 1) { throw "Missing/duplicate receipt member: $($file.Target)" }
                    if ($recordedFile[0].SHA256 -notmatch '^[a-fA-F0-9]{64}$') { throw "Missing or malformed receipt member SHA256: $($file.Target)" }
                    $expected = if ($dependency.Archive -eq 'file') { $dependency.SHA256 } else { $recordedFile[0].SHA256 }
                    Check-File Stage $stage $file.Target $expected 'Fetch and stage the pinned backend dependencies.'
                }
            }
            Add-Check Stage archive-member-provenance Warning 'ZIP-member hashes were compared to the local download receipt, not recomputed from the pinned archives. This detects drift, not a forged receipt. Public release needs an independently reviewed complete per-file manifest.'
        } catch { Add-Check Stage backend-receipt Fail $_.Exception.Message }
        try {
            $nrFiles = @($plan.OptionalNeuralRendering.Archive.Files) + @($plan.OptionalNeuralRendering.Forwarder)
            $nrPresent = Test-Path -LiteralPath (Get-SafeChildPath $stage $plan.OptionalNeuralRendering.Forwarder.Target) -PathType Leaf
            if ($nrPresent -or (Test-Path -LiteralPath (Get-SafeChildPath $stage $plan.OptionalNeuralRendering.Archive.Files[0].Target) -PathType Leaf)) {
                # Validate every selected pin before any member can become a presence-only check.
                foreach ($file in $nrFiles) {
                    if ($file.SHA256 -notmatch '^[a-fA-F0-9]{64}$') { throw "Missing or malformed optional NR SHA256: $($file.Target)" }
                }
                foreach ($file in $nrFiles) { Check-File Stage $stage $file.Target $file.SHA256 'Complete or remove the optional NR payload; enabling NR still requires separate runtime validation.' }
            } else { Add-Check Stage optional-nr Warning 'Optional NR payload is absent. Keep NR disabled; its presence is not required for the initial DLAA/FG scope.' }
        } catch { Add-Check Stage optional-nr Fail $_.Exception.Message }

        try {
            $manifest = Read-DeploymentManifest (Get-SafeChildPath $diagnostics 'deployment-manifest.json') $game
            $managed = @{}
            if ($manifest) {
                foreach ($entry in @($manifest.files | Where-Object state -eq active)) {
                    $null = Get-SafeChildPath $game $entry.relativePath
                    if ($managed.ContainsKey($entry.relativePath)) { throw "Duplicate active journal entry: $($entry.relativePath)" }
                    $managed[$entry.relativePath] = $entry
                }
            }
            foreach ($conflict in @('winhttp.dll','version.dll','winmm.dll','dxgi.dll','d3d11.dll','d3d12.dll','doorstop_config.ini')) {
                if ((Test-Path -LiteralPath (Get-SafeChildPath $game $conflict)) -and -not $managed.ContainsKey($conflict)) {
                    Add-Check Stage "conflict:$conflict" Fail 'Unmanaged loader/proxy exists; existing installer would refuse it.'
                }
            }
            if ((Test-Path -LiteralPath (Get-SafeChildPath $game 'MelonLoader')) -or
                ((Test-Path -LiteralPath (Get-SafeChildPath $game 'BepInEx')) -and (-not $manifest -or @($manifest.files).Count -eq 0))) {
                Add-Check Stage unmanaged-loader Fail 'Unmanaged loader directory found; reconcile it rather than stacking installers.'
            }
            foreach ($payloadRoot in @((Join-Path $project 'loader'),$stage)) {
                $payloadFiles = @(Read-PayloadFiles $payloadRoot)
                if (-not $payloadFiles.Count) { throw "Payload missing or empty: $payloadRoot" }
                foreach ($file in $payloadFiles) {
                    $relative = $file.FullName.Substring($payloadRoot.Length + 1)
                    $target = Get-SafeChildPath $game $relative
                    $kind = if (Test-Path -LiteralPath $target -PathType Leaf) { 'File' } elseif (Test-Path -LiteralPath $target) { 'Directory' } else { 'Missing' }
                    $targetHash = if ($kind -eq 'File') { Get-FileSha256 $target } else { '' }
                    $sourceHash = if ($kind -eq 'File') { Get-FileSha256 $file.FullName } else { '' }
                    $entry = $managed[$relative]
                    $ownedHashes = if ($entry) { @($entry.installedHashes) } else { @() }
                    $result = Test-LePreflightTargetFact $relative $sourceHash $kind $targetHash ($null -ne $entry) $ownedHashes
                    if ($result.Status -eq 'Fail') { $checks.Add($result) }
                }
            }
            Add-Check Stage journal-scan Pass 'Journal ownership and payload target collisions inspected; no writes or backup verification performed. Individual failures above remain blocking.'
        } catch { Add-Check Stage journal-scan Fail $_.Exception.Message }
        Add-Check Stage release-manifest Warning 'This is a developer-stage inventory, not a release allowlist. Extra files, complete loader authenticity, configuration semantics, signatures and license/distribution approval require the future release-package validator.'
    }
    Complete-LePreflightReport $checks.ToArray() $Scope $game $project
}
