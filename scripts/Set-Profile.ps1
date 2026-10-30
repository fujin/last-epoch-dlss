[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Probe', 'DLAA', 'Quality', 'Balanced', 'Performance')][string]$Profile = 'Probe',
    [ValidateRange(1, 4)][int]$Multiplier = 1,
    [switch]$NeuralRendering,
    [ValidateRange(0.25, 1.0)][double]$NeuralRenderingScale = 1.0,
    [switch]$ExperimentalScaling,
    [switch]$VerifyPixels,
    [switch]$LateHudless,
    [switch]$Install,
    [string]$GameDirectory = 'G:\SteamLibrary\steamapps\common\Last Epoch'
)
. (Join-Path $PSScriptRoot 'Deployment.ps1')
. (Join-Path $PSScriptRoot 'LocalBackend.ps1')
if ($Profile -in @('Quality', 'Balanced', 'Performance') -and -not $ExperimentalScaling) {
    throw 'Reduced-resolution SR is unvalidated and disabled in the normal build. Use DLAA. Diagnostic profiles require -ExperimentalScaling and a separately compiled experimental adapter.'
}
if ($Install -and -not $WhatIfPreference) { & (Join-Path $PSScriptRoot 'Sync-BackendConfig.ps1') -GameDirectory $GameDirectory }
$stage = Get-FullDirectoryPath (Join-Path $PSScriptRoot '..\stage')
$iniPath = Get-SafeChildPath $stage 'OptiScaler.ini'
$pluginPath = Get-SafeChildPath $stage 'BepInEx\config\local.lastepoch.graphics.cfg'
if (-not (Test-Path -LiteralPath $iniPath)) { throw 'Fetch the backend before choosing a profile.' }
if ($NeuralRendering -and -not (Test-Path -LiteralPath (Get-SafeChildPath $stage 'OptiScaler\nvngx_dlssnr.dll'))) {
    throw 'Run Fetch-NeuralRendering.ps1 first.'
}
if ($Profile -eq 'Probe' -and ($Multiplier -gt 1 -or $NeuralRendering)) { throw 'Probe mode cannot enable reconstruction or frame generation.' }
if ($LateHudless) {
    if ($Profile -eq 'Probe' -or $Multiplier -lt 2) { throw 'Late HUDless submission requires an upscaling profile with frame generation enabled.' }
    Assert-RecognizedLocalBackend (Get-SafeChildPath $stage 'version.dll')
}
if ($Install) { Assert-GameStopped }

function Set-IniKey([string]$Text, [string]$Section, [string]$Key, [string]$Value) {
    $lines = [Collections.Generic.List[string]]::new()
    $lines.AddRange([string[]]($Text -split '\r?\n'))
    $start = -1; $end = $lines.Count
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -eq "[$Section]") { $start = $i; continue }
        if ($start -ge 0 -and $lines[$i] -match '^\s*\[') { $end = $i; break }
    }
    if ($start -lt 0) { $lines.Add("[$Section]"); $lines.Add("$Key=$Value") }
    else {
        $found = $false
        for ($i = $start + 1; $i -lt $end; $i++) {
            if ($lines[$i] -match ('^\s*' + [regex]::Escape($Key) + '\s*=')) { $lines[$i] = "$Key=$Value"; $found = $true; break }
        }
        if (-not $found) { $lines.Insert($end, "$Key=$Value") }
    }
    return ($lines -join "`r`n").TrimEnd() + "`r`n"
}

$ini = Get-Content -LiteralPath $iniPath -Raw
$ini = Set-IniKey $ini 'FrameGen' 'Enabled' ($Multiplier -gt 1).ToString().ToLowerInvariant()
$ini = Set-IniKey $ini 'FrameGen' 'DisableHudless' (-not $LateHudless.IsPresent).ToString().ToLowerInvariant()
$ini = Set-IniKey $ini 'OptiFG' 'HUDFix' 'false'
if ($LateHudless) {
    $ini = Set-IniKey $ini 'FrameGen' 'FGInput' 'Upscaler'
    $ini = Set-IniKey $ini 'FrameGen' 'FGOutput' 'DLSSG'
    $ini = Set-IniKey $ini 'FSRFG' 'UseMutexForSwapchain' 'true'
}
$ini = Set-IniKey $ini 'DLSSG' 'InterpolationCount' ([string]([Math]::Max(1, $Multiplier - 1)))
$ini = Set-IniKey $ini 'DLSSG' 'ForceDMFG' 'false'
$ini = Set-IniKey $ini 'DlssNr' 'Enabled' $NeuralRendering.IsPresent.ToString().ToLowerInvariant()
$ini = Set-IniKey $ini 'DlssNr' 'WorkingScale' $NeuralRenderingScale.ToString([Globalization.CultureInfo]::InvariantCulture)
if ($NeuralRendering) { $ini = Set-IniKey $ini 'DlssNr' 'ApplyModel' 'true' }
$quality = switch ($Profile) { 'Performance' {0} 'Balanced' {1} 'Quality' {2} default {5} }
$plugin = if (Test-Path -LiteralPath $pluginPath) { Get-Content -LiteralPath $pluginPath -Raw } else { '' }
$plugin = Set-IniKey $plugin 'General' 'Enabled' 'true'
$plugin = Set-IniKey $plugin 'Diagnostics' 'ProbeOnly' ($Profile -eq 'Probe').ToString().ToLowerInvariant()
$plugin = Set-IniKey $plugin 'Diagnostics' 'VerifyPixels' $VerifyPixels.IsPresent.ToString().ToLowerInvariant()
$plugin = Set-IniKey $plugin 'Upscaling' 'Quality' ([string]$quality)
$plugin = Set-IniKey $plugin 'Compatibility' 'LateHudless' $LateHudless.IsPresent.ToString().ToLowerInvariant()

if (-not $PSCmdlet.ShouldProcess($stage, "Prepare $Profile, requested ${Multiplier}x, neural rendering=$NeuralRendering, late HUDless=$LateHudless")) { return }
[IO.File]::WriteAllText($iniPath, $ini, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($pluginPath, $plugin, [Text.UTF8Encoding]::new($false))
if ($Install) { & (Join-Path $PSScriptRoot 'Install-Stage.ps1') -GameDirectory $GameDirectory }
[pscustomobject]@{ Profile=$Profile; RequestedMultiplier=$Multiplier; NeuralRendering=$NeuralRendering.IsPresent; LateHudless=$LateHudless.IsPresent; Installed=$Install.IsPresent }
