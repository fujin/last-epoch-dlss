# Read-only developer preflight. Never invokes installers, repair, downloads, or the game.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$GameDirectory,
    [ValidateSet('Source','Stage','All')][string]$Scope = 'All',
    [string]$StageDirectory = (Join-Path $PSScriptRoot '..\stage'),
    [string]$DiagnosticsDirectory = (Join-Path $PSScriptRoot '..\diagnostics'),
    [switch]$AsJson,
    [switch]$FailOnBlocker
)
. (Join-Path $PSScriptRoot 'Preflight.Core.ps1')
$processNames = @()
$processError = ''
try {
    # Query all processes once: "no named process" is not confused with an inspection failure.
    $processNames = @(Get-Process -ErrorAction Stop | Select-Object -ExpandProperty ProcessName)
} catch { $processError = $_.Exception.Message }
$report = Invoke-LePreflightScan -GameDirectory $GameDirectory -ProjectDirectory (Join-Path $PSScriptRoot '..') -StageDirectory $StageDirectory -DiagnosticsDirectory $DiagnosticsDirectory -Scope $Scope -ProcessNames $processNames -ProcessError $processError
if ($AsJson) { $report | ConvertTo-Json -Depth 10 }
else { $report }
if ($FailOnBlocker -and $report.BlockerCount -gt 0) { throw "Preflight found $($report.BlockerCount) blocking observations. No files were changed." }
