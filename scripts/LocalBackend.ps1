# Shared static identity checks. Never load the DLL to inspect its exports.
function Get-LocalBackendDefinition {
    [pscustomobject]@{
        DllSha256 = '571C93E38E0A81ACC0C5B0BB43C4DB1801B1484CD2E4F84826B2AAF33DAA9BE6'
        PreviousDllSha256 = 'B913AA7A90A2C0928524671EA34BAB3A2537345F44EE48CEC96739925F2528B7'
        LegacyDllSha256 = '34AF48543B5EDFEBAE8D45807F6E05139B2C1B055361FC1B4C8B70079AD56210'
        BuildDirectoryName = 'local-build-menu-fence'
        Variant = 'LastEpoch-late-hudless-ABI1-presentation-stats-V1-menu-fence'
        OfficialSha256 = 'AD143C5BD6E5FAB4D1ABD8B048C424E9DDCEABF1A864E0E0695C01A0DC82B4C9'
        SourceSha256 = '1EAAD2223E679A935426E922F86A0341232AE96641579FEC4A5B34004A1CD507'
        Documents = @(
            @{ Name='late-hudless.patch'; SHA256='53E3ED17C77CB12BF7710BEE540A8EF40F47DBA99EAEBD33325D29C78A196958' },
            @{ Name='menu-fence-only.patch'; SHA256='445E3CDF2FF7EE7A2901A930460BC213BD4E344E0EB57C1621AB3E3746208A95' },
            @{ Name='SOURCE-NOTICE.txt'; SHA256='80F4E33A4594DA1FA5469E08A94BFD63385F80FAD4862482EFEE78D47F79B1ED' },
            @{ Name='LICENSE'; SHA256='230184F60BAE2FEAF244F10A8BAC053C8FF33A183BCC365B4D8B876D2B7F4809' },
            @{ Name='variant-manifest.json'; SHA256='B380DC9DD0BBF834063E74904E247A2AE053B61F32408BA4DC98E02DD04C52CE' },
            @{ Name='Build-Candidate.ps1'; SHA256='981E71C63935F0BB14EDAE63AFDBAD0091F6E1552558F3231138749BB3CDD5AF' },
            @{ Name='SourceOverride.targets'; SHA256='3BB3884C081F870ABEF9ADEC490EA9D6995FF76799A560A1BBAF3C96196189F8' }
        )
        Exports = @('OptiScaler_GetHudlessD3D11Version','OptiScaler_GetHudlessFrameTokenD3D11','OptiScaler_SubmitHudlessD3D11','OptiScaler_GetPresentationStatsV1')
    }
}

function Assert-BackendFileHash([string]$Path, [string]$Expected) {
    Assert-NoReparsePoint $Path
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Required backend file is missing: $Path" }
    if ((Get-FileSha256 $Path) -ne $Expected) { throw "Unrecognized backend file or changed build: $Path" }
}

function Assert-RecognizedLocalBackend([string]$Path) {
    $definition = Get-LocalBackendDefinition
    Assert-NoReparsePoint $Path
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Required backend file is missing: $Path" }
    $actualHash = Get-FileSha256 $Path
    if ($actualHash -in @($definition.DllSha256, $definition.PreviousDllSha256)) { $requiredExports = $definition.Exports }
    elseif ($actualHash -eq $definition.LegacyDllSha256) { $requiredExports = $definition.Exports[0..2] }
    else { throw "Unrecognized backend file or changed build: $Path" }
    $bytes = [IO.File]::ReadAllBytes($Path)
    function Read-PeU16([long]$Offset) {
        if ($Offset -lt 0 -or $Offset + 2 -gt $bytes.Length) { throw 'Truncated PE field.' }
        [BitConverter]::ToUInt16($bytes, [int]$Offset)
    }
    function Read-PeU32([long]$Offset) {
        if ($Offset -lt 0 -or $Offset + 4 -gt $bytes.Length) { throw 'Truncated PE field.' }
        [BitConverter]::ToUInt32($bytes, [int]$Offset)
    }
    if ((Read-PeU16 0) -ne 0x5A4D) { throw 'Invalid DOS signature.' }
    $pe = [long](Read-PeU32 0x3C)
    if ((Read-PeU32 $pe) -ne 0x4550 -or (Read-PeU16 ($pe + 4)) -ne 0x8664) { throw 'Expected an x64 PE DLL.' }
    $sections = Read-PeU16 ($pe + 6)
    $optional = $pe + 24
    if ((Read-PeU16 $optional) -ne 0x20B) { throw 'Expected a PE32+ optional header.' }
    $exportRva = [long](Read-PeU32 ($optional + 112))
    $exportSize = [long](Read-PeU32 ($optional + 116))
    $sectionTable = $optional + (Read-PeU16 ($pe + 20))
    function Convert-PeRva([long]$Rva) {
        for ($i = 0; $i -lt $sections; $i++) {
            $section = $sectionTable + 40 * $i
            $address = [long](Read-PeU32 ($section + 12))
            $rawSize = [long](Read-PeU32 ($section + 16))
            if ($Rva -ge $address -and $Rva -lt $address + $rawSize) {
                $offset = [long](Read-PeU32 ($section + 20)) + $Rva - $address
                if ($offset -ge $bytes.Length) { throw 'PE RVA is outside the file.' }
                return $offset
            }
        }
        throw 'PE RVA has no stored section.'
    }
    $directory = Convert-PeRva $exportRva
    $count = Read-PeU32 ($directory + 24)
    if ($count -lt 3 -or $count -gt 10000) { throw 'Invalid PE export count.' }
    $names = Convert-PeRva (Read-PeU32 ($directory + 32))
    $ordinals = Convert-PeRva (Read-PeU32 ($directory + 36))
    $functions = Convert-PeRva (Read-PeU32 ($directory + 28))
    $found = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    for ($i = 0; $i -lt $count; $i++) {
        $nameOffset = Convert-PeRva (Read-PeU32 ($names + 4 * $i))
        $end = $nameOffset
        while ($end -lt $bytes.Length -and $bytes[$end] -ne 0 -and $end - $nameOffset -lt 256) { $end++ }
        if ($end -ge $bytes.Length -or $end - $nameOffset -ge 256) { throw 'Unterminated PE export name.' }
        $name = [Text.Encoding]::ASCII.GetString($bytes, [int]$nameOffset, [int]($end - $nameOffset))
        if ($name -cin $requiredExports) {
            $ordinal = Read-PeU16 ($ordinals + 2 * $i)
            $functionRva = [long](Read-PeU32 ($functions + 4 * $ordinal))
            if ($functionRva -eq 0 -or ($functionRva -ge $exportRva -and $functionRva -lt $exportRva + $exportSize)) {
                throw "Required backend export is missing or forwarded: $name"
            }
            $null = Convert-PeRva $functionRva
            $null = $found.Add($name)
        }
    }
    foreach ($required in $requiredExports) {
        if (-not $found.Contains($required)) { throw "Required backend export is absent: $required" }
    }
}
