[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$GameDirectory = 'G:\SteamLibrary\steamapps\common\Last Epoch',
    [ValidateSet('D3D11', 'D3D12')][string]$Renderer = 'D3D11',
    [switch]$TestWindow,
    [ValidateRange(640, 7680)][int]$Width = 1600,
    [ValidateRange(480, 4320)][int]$Height = 900,
    [string]$DiagnosticsDirectory = (Join-Path $PSScriptRoot '..\diagnostics')
)
. (Join-Path $PSScriptRoot 'Deployment.ps1')
$gamePath = Get-FullDirectoryPath $GameDirectory
$diagnosticsPath = Get-FullDirectoryPath $DiagnosticsDirectory
Assert-GameStopped
Assert-GameDirectory $gamePath
Assert-NoReparsePoint $diagnosticsPath
$stamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff')
$logPath = Join-Path $diagnosticsPath "Player-$Renderer-$stamp.log"
# Official EHG full-offline option: https://support.lastepoch.com/hc/en-us/articles/46363253291803-How-do-I-use-Offline-mode
$launchArguments = @('--offline', ('-force-' + $Renderer.ToLowerInvariant()), '-logFile', ('"' + $logPath + '"'))
if ($TestWindow) { $launchArguments += @('-screen-fullscreen', '0', '-screen-width', "$Width", '-screen-height', "$Height") }
$exePath = Join-Path $gamePath 'Last Epoch.exe'
if (-not $PSCmdlet.ShouldProcess($exePath, ('Launch full offline: ' + ($launchArguments -join ' ')))) { return }
& (Join-Path $PSScriptRoot 'Repair-Interop.ps1') -GameDirectory $gamePath
New-Item -ItemType Directory -Path $diagnosticsPath -Force | Out-Null
$process = Start-Process -FilePath $exePath -ArgumentList $launchArguments -WorkingDirectory $gamePath -PassThru
[pscustomobject]@{ ProcessId = $process.Id; Renderer = $Renderer; Offline = $true; LogPath = $logPath; Arguments = $launchArguments }
