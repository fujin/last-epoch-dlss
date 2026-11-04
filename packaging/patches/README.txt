COMPLETE CORRESPONDING OPTISCALER SOURCE
=======================================

The presentation-stats, menu-fence and app-capture variant directories each
contain a complete patch against the same pinned base,
the original GPL-3.0 LICENSE, source notice and a hash manifest. No DLL is included.
Do not apply two complete variant patches on top of one another.

Base repository: https://github.com/Skynizz/optiscaler-dlss5
Base revision: 6bfc4389c25054ef6747df6e6b1b470e9541c4da
Complete base archive (includes the required submodules):
https://github.com/Skynizz/optiscaler-dlss5/releases/download/v1.2.1/OptiScaler-DLSS5-1.2.1-source.zip
SHA256: 1EAAD2223E679A935426E922F86A0341232AE96641579FEC4A5B34004A1CD507
Archive root directory: OptiScaler-DLSS5-1.2.1

The ordinary GitHub source archive omits required submodule contents. Use the
explicit complete archive above, or reconstruct that exact pinned submodule set.

PRESENTATION-STATS VARIANT

presentation-stats/late-hudless.patch is the complete source delta for the local
B913AA7A... DLL tested in the recorded sessions. It includes the explicit late
HUDless ABI1, independent presentation counters and safe local build recipe.
Its presence does not make managed final-camera HUDless capture validated.

SELECTED MENU-FENCE CANDIDATE

menu-fence/late-hudless.patch is a separate COMPLETE patch against the original
archive. It includes the presentation-stats changes plus the overlay allocator,
fence and ImGui upload-lifetime fixes. Selected DLL identity is 571C93E3...;
build, export checks and independent review passed. A later bounded 23-minute
native-display runtime test with menu/NR/FG/Alt-Tab interactions and complete
paired logs also passed; broad stability remains unverified. The staging helper
selects this variant; staging itself does not establish runtime success.
menu-fence-only.patch is only the focused
review delta against the B913 source, not a replacement for the complete patch.

The complete menu-fence patch intentionally excludes the unrelated optional
Present-probe experiment in the development working tree. Build-Candidate.ps1
and SourceOverride.targets document how the original mixed working tree build
excluded that experiment; they assume their original vendor build-directory
layout. A fresh archive plus the complete patch uses the ordinary Build-Local.ps1
recipe below and needs no source override.

OPTIONAL RAW APPLICATION-CAPTURE DIAGNOSTIC

app-capture/late-hudless.patch is a separate complete 15-file patch, including the
571C changes plus an opt-in raw D3D11 application-swapchain capture. A9F3C908...
is a temporary diagnostic build, not the selected default backend. Compilation,
exports, full-source reconstruction, independent review and five journal fixture
checks passed; live pixel-comparison validation is recorded separately.

Its SOURCE-NOTICE documents the process environment and explicit request marker,
two-image limit, original build-directory layout and exact reversible diagnostic
installation helper. The helper accepts only pinned, journal-owned binaries;
its local payload folders and DLLs are deliberately excluded from this repository.
The full patch reconstructs clean source using the recipe below. The extra source
translation unit and override recipe preserve the original mixed-tree build.
Capturing can stall the application briefly; this is not a performance build.

EXPERIMENTAL FALLBACK-LIMITER DELTA

fallback-limiter/fallback-limiter-only.patch is an UNSELECTED source candidate,
and is the exception to the complete-variant layout above. Apply it only AFTER
the complete menu-fence patch. It replaces the fallback limiter's fixed 2x
assumption with an explicit configured output multiplier. It does not change
the native Reflex limiter, and does not establish lower end-to-end latency.

fallback-limiter/Test-Candidate.ps1 reconstructs just the upstream files needed
for this delta and compiles tests against its actual production policy header.
It does not build a complete backend DLL, run its timer, install anything or
launch the game. Full-backend build and runtime validation remain pending.
See fallback-limiter/README.txt and candidate-manifest.json before using it.

RECONSTRUCTION RECIPE (POWERSHELL, FROM REPOSITORY ROOT)

Choose a new, empty extraction directory. These steps prepare source and compile
only; they never install into the game. Download paths are ignored by Git.

  New-Item -ItemType Directory -Force downloads | Out-Null
  Invoke-WebRequest -Uri 'https://github.com/Skynizz/optiscaler-dlss5/releases/download/v1.2.1/OptiScaler-DLSS5-1.2.1-source.zip' -OutFile 'downloads/optiscaler-source-1.2.1.zip'
  if ((Get-FileHash 'downloads/optiscaler-source-1.2.1.zip' -Algorithm SHA256).Hash -ne '1EAAD2223E679A935426E922F86A0341232AE96641579FEC4A5B34004A1CD507') { throw 'Source archive hash mismatch' }
  $patch = (Resolve-Path 'packaging/patches/presentation-stats/late-hudless.patch').Path
  Expand-Archive -LiteralPath 'downloads/optiscaler-source-1.2.1.zip' -DestinationPath 'vendor/rebuild-presentation-stats'
  $source = (Resolve-Path 'vendor/rebuild-presentation-stats/OptiScaler-DLSS5-1.2.1').Path
  $oldCeiling = [Environment]::GetEnvironmentVariable('GIT_CEILING_DIRECTORIES', 'Process')
  Push-Location $source
  try {
    $env:GIT_CEILING_DIRECTORIES = Split-Path -Parent $source
    git -c core.autocrlf=false apply --check -- $patch
    if ($LASTEXITCODE -ne 0) { throw 'Patch verification failed' }
    git -c core.autocrlf=false apply -- $patch
    if ($LASTEXITCODE -ne 0) { throw 'Patch application failed' }
    .\Build-Local.ps1 -BuildDirectoryName local-build-presentation -ParallelProcesses 4
  } finally {
    Pop-Location
    [Environment]::SetEnvironmentVariable('GIT_CEILING_DIRECTORIES', $oldCeiling, 'Process')
  }

For the menu candidate, substitute menu-fence/late-hudless.patch, a new extraction
directory such as vendor/rebuild-menu-fence, and output local-build-menu-fence.
Use a clean archive for each variant. The Git ceiling is important: otherwise a
source directory nested inside this checkout can inherit the parent repository
and git apply can skip paths. core.autocrlf=false preserves the patch's source
bytes. The menu-fence manifest provides hashes for its 14 changed files; the
app-capture manifest covers its separate complete set of 15 changed files.

The patch itself supplies Build-Local.ps1. It selects VS2022 v143, embedded
compiler symbols and bounded parallelism, generates the build-date headers, and
disables upstream batch packaging events. Use the variant manifest for the
required exports, ABI and validation evidence. Build-date/toolchain differences
can change the resulting DLL hash. Review and validate a rebuilt DLL before
updating approval pins or staging it; the existing helper intentionally rejects
unrecognized binaries. A successful build is not a runtime compatibility test.

PROMOTING A REVIEWED REBUILD TO STAGING

The reconstruction directory above is isolated. Stage-LocalBackend.ps1 instead
looks under vendor/optiscaler-local/local-build-menu-fence for OptiScaler.dll and
seven exact provenance files: late-hudless.patch, menu-fence-only.patch,
SOURCE-NOTICE.txt, LICENSE, variant-manifest.json, Build-Candidate.ps1 and
SourceOverride.targets. A new build directory does not provide those artifacts
automatically, and changing only the DLL approval hash is insufficient.

After reviewing/testing a rebuild, prepare its corresponding artifact directory
at that expected path, with the DLL plus matching full-source patch, notices,
license, manifest and recipes. If any bytes differ from the existing pinned
variant, record the new DLL/provenance hashes and results in a separate reviewed
variant; update the selected definition and all affected artifact pins in
scripts/LocalBackend.ps1 together. Preserve the original pinned variant as
historical evidence. Do not silently relabel a new build with an old manifest.
Run the staging helper's -WhatIf checks before staging. Staging still does not
install the backend into the game.

Recorded build warnings include C4744 (atomic shared_ptr alignment in unchanged
upstream code) and LNK4098 (mixed CRT defaults in upstream libraries). These are
recorded in the manifests; they were not silently suppressed or proven harmless.

The byte-preserved SOURCE-NOTICE files retain their original vendor-relative
paths. In this repository, locate the base ZIP under downloads and the variant
patch under packaging/patches. Preserve the full corresponding source and all
original third-party notices if distributing a modified GPL backend.
