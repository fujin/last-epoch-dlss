COMPLETE CORRESPONDING OPTISCALER SOURCE
=======================================

Each variant directory contains a complete patch against the same pinned base,
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

MENU-FENCE CANDIDATE

menu-fence/late-hudless.patch is a separate COMPLETE patch against the original
archive. It includes the presentation-stats changes plus the overlay allocator,
fence and ImGui upload-lifetime fixes. Candidate DLL identity is 571C93E3...;
build, export checks and independent review passed, but runtime validation is
pending and it has not been deployed. menu-fence-only.patch is only the focused
review delta against the B913 source, not a replacement for the complete patch.

The complete menu-fence patch intentionally excludes the unrelated optional
Present-probe experiment in the development working tree. Build-Candidate.ps1
and SourceOverride.targets document how the original mixed working tree build
excluded that experiment; they assume their original vendor build-directory
layout. A fresh archive plus the complete patch uses the ordinary Build-Local.ps1
recipe below and needs no source override.

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
bytes; the candidate manifest provides hashes for all 14 changed files.

The patch itself supplies Build-Local.ps1. It selects VS2022 v143, embedded
compiler symbols and bounded parallelism, generates the build-date headers, and
disables upstream batch packaging events. Use the variant manifest for the
required exports, ABI and validation evidence. Build-date/toolchain differences
can change the resulting DLL hash. Review and validate a rebuilt DLL before
updating approval pins or staging it; the existing helper intentionally rejects
unrecognized binaries. A successful build is not a runtime compatibility test.

Recorded build warnings include C4744 (atomic shared_ptr alignment in unchanged
upstream code) and LNK4098 (mixed CRT defaults in upstream libraries). These are
recorded in the manifests; they were not silently suppressed or proven harmless.

The byte-preserved SOURCE-NOTICE files retain their original vendor-relative
paths. In this repository, locate the base ZIP under downloads and the variant
patch under packaging/patches. Preserve the full corresponding source and all
original third-party notices if distributing a modified GPL backend.
