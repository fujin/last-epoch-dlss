[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PlayerLogPath,
    [string]$BackendLogPath,
    [switch]$RequireClean
)

$ErrorActionPreference = 'Stop'
$log = Get-Item -LiteralPath $PlayerLogPath -ErrorAction Stop
if ($log.PSIsContainer) { throw 'PlayerLogPath must identify a log file.' }

# Read the whole Unity log: adapter telemetry at its tail can hide thousands of
# earlier native rendering errors, even while NGX evaluations report success.
$patterns = @(
    'Dimensions of color surface .* do not match dimensions of depth surface',
    'RenderTexture\.Create failed',
    'Failed to create RenderTexture',
    'RenderTextureDesc width or height is less than or equal to 0',
    'RenderTexture is not created'
)
$hits = @(Select-String -LiteralPath $log.FullName -Pattern $patterns)
$devicePattern = "DXGI_ERROR_DEVICE_(?:HUNG|REMOVED|RESET)|We've lost the Device|GPU device instance has been suspended"
$playerDeviceHits = @(Select-String -LiteralPath $log.FullName -Pattern $devicePattern)
$backendLog = $null
$backendHits = @()
if ($BackendLogPath) {
    $backendLog = Get-Item -LiteralPath $BackendLogPath -ErrorAction Stop
    if ($backendLog.PSIsContainer) { throw 'BackendLogPath must identify a log file.' }
    $backendHits = @(Select-String -LiteralPath $backendLog.FullName -Pattern $devicePattern)
}
$mismatches = @($hits | Where-Object { $_.Line -match $patterns[0] })
$groups = @($hits | Group-Object -Property Line | Sort-Object Count -Descending |
    ForEach-Object { [pscustomobject]@{ Count = $_.Count; Message = $_.Name } })
$result = [pscustomobject]@{
    PlayerLogPath = $log.FullName
    BackendLogPath = if ($backendLog) { $backendLog.FullName } else { $null }
    Passed = ($hits.Count + $playerDeviceHits.Count + $backendHits.Count) -eq 0
    RenderTargetErrors = $hits.Count
    ColorDepthMismatches = $mismatches.Count
    PlayerDeviceErrors = $playerDeviceHits.Count
    BackendDeviceErrors = $backendHits.Count
    FirstErrorLine = if ($hits.Count) { $hits[0].LineNumber } else { $null }
    FirstDeviceErrorLine = if ($playerDeviceHits.Count) { $playerDeviceHits[0].LineNumber } else { $null }
    FirstBackendDeviceErrorLine = if ($backendHits.Count) { $backendHits[0].LineNumber } else { $null }
    Messages = $groups
    # A device-loss cascade can emit thousands of duplicate failures. Keep the
    # result small while retaining full counts and the earliest causal evidence.
    DeviceMessages = @($playerDeviceHits + $backendHits | Select-Object -First 8 |
        ForEach-Object { [pscustomobject]@{ Path = $_.Path; Line = $_.LineNumber; Message = $_.Line } })
}
$result
if ($RequireClean -and -not $result.Passed) {
    throw "Rendering validation failed: $($hits.Count) target errors, $($playerDeviceHits.Count) Unity device errors, $($backendHits.Count) backend device errors."
}
