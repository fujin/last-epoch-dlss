LAST EPOCH GRAPHICS - LOCAL PROTOTYPE
===================================

Verified at native 1600x900 in offline play: visible DLAA rendering, NVIDIA
2x/3x/4x frame-generation presentation throughput, and actual DLSS 5 Neural
Rendering evaluation/composition. This is still a local prototype, with the
limits below. Updated 31 October 2026, Pacific/Auckland.

CURRENT LIMITS AND USER DISPLAY TARGET

The normal managed build supports native-resolution DLAA. Quality, Balanced and
Performance remain broken:
reduced-resolution postprocessing produced mismatched temporary color/depth sizes
and white presentation. The normal build rejects those modes without installing
graphics hooks. Keep experimental scaling builds and their results isolated.
Set-Profile also rejects those names unless -ExperimentalScaling is supplied for
a separately compiled diagnostic adapter; the normal build still refuses them.

The user's preferred native display mode is 5120x1440 BORDERLESS. Validation of
that mode is IN PROGRESS. A clean restart resolved startup UI clipping, and
returning the game to the foreground worked. An uncapped Ultra + DLAA + 4x FG +
NR WorkingScale=0.5 world run observed about 49.2 rendered fps and 197 DXGI present
calls/second at 98% GPU use, with no Unity color/depth dimension errors. These are
provisional observations, not a completed performance or stability validation.

That native run FAILED stability: the OptiScaler menu opened at 11:09:06, followed
by the first DXGI_ERROR_DEVICE_HUNG at 11:09:15.840. The complete backend log has
753 device-error lines despite the clean Unity target-error check. The hung test
process was closed; normal close timed out before only PID 35412 was terminated.
An overlay fence/resource-lifetime fix and a separate final-camera HUDless capture
fix passed builds/source review. The selected 571C backend then completed a
23-minute 5120x1440 test with normal close and clean complete Unity/backend logs.
Menu tab interaction and repeated NR/FG toggles, including more than six minutes
with FG enabled, caused no hang. Alt-Tab away and return also worked. This is a
bounded test, not broad stability validation. Accepted HUDless captures were
vertically flipped, and the 2101 Blit-based correction did not fix orientation.
A direct raw-buffer comparison confirmed matching static-scene color after
analysis-only Y alignment; no extra sRGB conversion was warranted. The E841
explicit-mesh correction then passed raw orientation/color/UI-omission checks in
Old Road at 5120x1440 with NR off and 4x FG, using the A9F diagnostic backend.
That scene-specific capture proof is separate from broader stability validation.
Candidate identities are recorded in packaging\source-candidates.json.
The old 3840x2160 exclusive setting is not the user's target.

The final installed pair is managed E841/native 257A with normal backend 571C.
Its profile is DLAA + 4x FG + late HUDless, NR off, NR working scale 0.5 retained.
ApplyModel remains enabled, so NR can be enabled from the Insert menu. The game
was left closed after validation.
All diagnostic capture environment flags were cleared for the regular smoke test.
That final test passed and closed normally: menu open/close worked, the full-width
HUD was visible, and complete paired logs had zero checked target/dimension/device
errors. Observed throughput was 55.95-56.13 rendered fps and 224.3-224.5 DXGI calls
per second, exactly four calls per client present. The requested 240 fps target
was not reached. Calls do not establish distinct generated images or panel scans.

A later NR-off comparison (PID 14940) closed normally and passed the complete
paired Unity/backend log check. At native 5120x1440 with DLAA and 4x FG, Ultra
observed about 56.2-56.5 rendered fps / 225 DXGI calls per second. Changing shadows
and volumetric lighting to High observed 56.8-56.9 / 227. This short comparison
did not establish a meaningful performance gain or sustained stability.

Only offline play, using the DLSSProbe character, has been tested. Online play is
unverified. Diagnostic GPU readbacks were enabled during the 1600x900 measured
run. Its ratios and the provisional native-mode observations are not final
performance benchmarks or physical panel FPS.

INSTALLATION AND COMPONENTS

Target: G:\SteamLibrary\steamapps\common\Last Epoch
Game: Last Epoch 1.5.3, Steam build 26087601, Unity 6000.4.8f1 IL2CPP.
Loader: BepInEx 6.0.0-be.791, revision b782da4.
GPU/API: GeForce RTX 5080; game's DirectX 11 built-in render pipeline.
Backend: local modified OptiScaler-DLSS5 1.2.1, base revision
  6bfc4389c25054ef6747df6e6b1b470e9541c4da; selected backend DLL hash 571C93E3...
The local backend adds late HUDless submission and independent presentation
counters; the selected candidate also adds overlay fence/resource-lifetime fixes.
Its exact hash/source patch are in scripts\LocalBackend.ps1 and
packaging\patches\menu-fence\variant-manifest.json. The B913AA7A... variant remains
the historical baseline for the earlier runs described below. The 571C follow-up
passed the bounded menu/control test and final regular-backend smoke test. The
E841 capture's orientation/color/UI omission was separately verified in Old Road.

The adapter requires D3D11. OptiScaler shares resources with D3D12 for NVIDIA
features. Launching the game with D3D12 does not activate this D3D11 adapter.
Dependency URLs/hashes and validation status: packaging\backend-plan.json.
Compatibility summary: docs\dll-compatibility-audit.txt. Local raw logs and module
inventories remain under ignored diagnostics; they are not published.

WHAT HAS BEEN VERIFIED

DLAA reconstructs native-resolution input for temporal antialiasing. Visible
1600x900 output and successful NVIDIA evaluations were verified. DLSS Super
Resolution normally reconstructs from lower-resolution input, but its Quality,
Balanced and Performance modes are not supported by this normal build yet.

NVIDIA FG was checked independently at 2x, 3x and 4x: 300 client presents produced
600, 900 and 1200 underlying DXGI presentation calls respectively. These counts
measure presentation throughput; they are not physical panel scanouts. These
calls also do not independently prove that every presented image was unique. Game
simulation and input responsiveness do not multiply by the FG factor. Requested
menu settings alone are not evidence of generated output.

DLSS 5 Neural Rendering is a separate optional lighting/material appearance pass.
The official signed NVIDIA 310.9.16 model successfully evaluated and composed at
10:37:06 in the saved 1600x900 run; same-scene on/off appearance was checked.
Its logged pass cost was approximately 3 ms in that scene, not a final benchmark
or a prediction for 5120x1440. This uses a community OptiScaler integration.
NR is disabled by default in the initial configuration.

Late HUDless capture passed a direct raw-buffer comparison in the Old Road world
scene with managed E841/native 257A: upright pixels, matching encoded scene color,
and health/mana orbs, ability bar, minimap, quest text and player-health UI omitted.
With NR off and 4x FG, two stone regions and sky measured mean absolute RGB errors
of 0.466, 0.649 and 0.453 on the 0-255 scale at the same image coordinates. Images
were captured about one second apart; moving content can differ. No gamma change
was needed. The summary is in docs\validation\hudless-color-14176.json.
NR enabled at half working width/height also passed: scene MAE 0.54-1.10/255,
with UI still omitted. Its on/off appearance difference in the stone regions was
9.31-10.65/255, larger than same-condition capture noise. See the separate
docs\validation\hudless-color-14176-nr-on.json report.

The diagnostic run closed normally with all checked target/dimension/device
error counts at zero. Late HUDless reached 37,073 accepted submissions; nine
startup rejects stayed constant. Closed-menu scene observations were about
56.14 rendered fps / 224 DXGI calls per second with NR off, and 48.98 / 196 with NR
on at 0.5 working scale. These are provisional scene observations, not final
benchmarks or physical panel FPS.

Earlier captures accepted no images or were inverted; acceptance counters alone
were insufficient evidence. The current result verifies this scene's capture,
not artifact-free generated UI in every menu, transition or combat situation.
The successful 1600x900 DLAA/FG/NR run's complete Unity Player log has zero
render-target errors. Earlier scaling experiments did have such errors.

Evidence:
  diagnostics\dlaa-fg234-nr-success-1600\LogOutput.log
    Exact 2x/3x/4x counter examples at lines 1246, 11535 and 13163.
  diagnostics\dlaa-fg234-nr-success-1600\OptiScaler.log
    Successful NR composition at line 8064 (10:37:06.224453).
  diagnostics\Player-D3D11-20261030-212935-665.log
    Whole-file render-target check passed with zero errors.
  diagnostics\native-5120-menu-device-hung\
    Provisional native-world throughput, then the menu/device-loss failure.
  diagnostics\Player-D3D11-20261030-220301-568.log
    Native run's Unity log; checking this alone would miss the backend hang.
  diagnostics\native-5120-nr-off-effects-high\
    Later short NR-off comparison, normal close, clean paired logs.
  diagnostics\Player-D3D11-20261030-222222-807.log
    Complete Unity log for that comparison.
  diagnostics\native-5120-menu-fence-571c-hudless\
    Clean bounded 571C menu/NR/FG/Alt-Tab test; captured orientation was incorrect.
  diagnostics\Player-D3D11-20261030-223732-014.log
    Complete Unity log for that test.
  diagnostics\native-5120-raw-color-comparison-9808\
    A9F diagnostic / managed 2101 raw-buffer comparison: color matched, Y still flipped.
  diagnostics\Player-D3D11-20261030-230316-786.log
    Complete Unity log; normal close and clean paired checks.
  docs\validation\hudless-color-14176.json
    E841 upright raw-capture comparison and visible UI omission in Old Road.
  diagnostics\native-5120-explicit-capture-14176\
    Both raw pairs and full logs; normal close and clean complete paired checks.
  diagnostics\Player-D3D11-20261030-231317-030.log
    Complete Unity log for the successful corrected-capture run.
  diagnostics\native-5120-final-e841-571c-7236\
    Final normal-backend smoke test; clean menu open/close and normal shutdown.
  diagnostics\Player-D3D11-20261030-232734-696.log
    Complete Unity log for the final test; all checked error counts zero.

RELEASE READINESS AND OFFLINE CHECKS

Public-alpha scope, release gates and issue work that can proceed without
starting Last Epoch are recorded in docs\public-release-plan.txt.
.github\workflows\offline-checks.yml builds the native bridge without proprietary
SDKs, runs its software-D3D11 contract, and checks isolated install/restore
fixtures. Passing these checks does not validate Unity rendering, DLSS, FG, NR
or end-to-end latency. The workflow does not deploy into the game.

SOURCE REPOSITORY

This checkout excludes downloaded runtimes, game files, local diagnostics and
build outputs. See REPOSITORY.txt for prerequisites and packaging\patches\README.txt
for complete corresponding-backend-source reconstruction. Commands below assume
those local prerequisites have been prepared.

COMMANDS FROM THIS WORKSPACE

Run PowerShell here:

  Set-Location 'C:\path\to\last-epoch-dlss'

Close Last Epoch before installing, changing a profile with -Install, repairing
interop, or restoring. The deployment journal and original backups are in
diagnostics\deployment-manifest.json and diagnostics\deployment-backups; keep them.

For already prepared normal-build files, native-resolution DLAA with 2x FG:

  .\scripts\Set-Profile.ps1 -Profile DLAA -Multiplier 2 -Install
  .\scripts\Launch-Offline.ps1 -Renderer D3D11

Choose 5120x1440 Borderless in the game's graphics settings. This launcher command
does not force that mode. The 571C change passed one bounded retest of the earlier
menu/device hang; this is not yet a broadly validated stable preset.
To reproduce the smaller verified test window:

  .\scripts\Launch-Offline.ps1 -Renderer D3D11 -TestWindow -Width 1600 -Height 900

The launcher passes EHG's --offline argument. The observed game can still show
Login / Play Offline; select Play Offline explicitly. Do not infer the selected
session mode from the launch argument alone. The launcher writes a separate Unity
log under diagnostics and does not change persistent Steam launch options.
Official offline reference:
  https://support.lastepoch.com/hc/en-us/articles/46363253291803-How-do-I-use-Offline-mode

SETTINGS AND CONTROLS

Set-Profile.ps1 accepts:
  -Profile Probe|DLAA|Quality|Balanced|Performance   (default Probe)
  -Multiplier 1|2|3|4                            (default 1; 1 disables FG)
  -NeuralRendering                               (default off)
  -NeuralRenderingScale 0.25..1.0                 (default 1.0)
  -ExperimentalScaling                           (diagnostic profiles only)
  -LateHudless                                   (default off)
  -VerifyPixels                                  (default off)
  -Install                                       (otherwise stage only)

Use Probe or DLAA with the normal build. Probe checks scene inputs without
reconstruction and cannot be combined with FG or NR. Lossless Scaling is not
required by this implementation.

To enable the prepared optional NR payload with DLAA and 4x FG:

  .\scripts\Fetch-NeuralRendering.ps1
  .\scripts\Set-Profile.ps1 -Profile DLAA -Multiplier 4 -LateHudless -NeuralRendering -NeuralRenderingScale 0.5 -Install

Fetch-NeuralRendering verifies the official model hash and signature and stages
the model/forwarder; fetching alone does not enable NR. There is no -NR alias.
The tested native-display NR setting is -NeuralRenderingScale 0.5: a 2560x720
model workload for 5120x1440 output. This controls the model's working dimensions.
Late HUDless is an experimental option with one world scene's raw capture
validated. It requires the recognized local backend and FG; broader UI and
stability testing remains necessary:

  .\scripts\Set-Profile.ps1 -Profile DLAA -Multiplier 2 -LateHudless -Install

Each Set-Profile call resets NR, working scale, late HUDless and pixel verification
according to that call's parameters; omitted working scale returns to 1.0. Include
all desired parameters together. LateHudless sets
FrameGen.DisableHudless=false and keeps OptiFG.HUDFix=false; its current API is
limited to SDR 8-bit output. The default leaves DisableHudless=true.
-VerifyPixels causes synchronous GPU readbacks and can introduce hitches; leave
it off for later performance measurements. Restart after persistent changes.

In-game controls:
  Insert  Open the OptiScaler backend menu.
  F10     Show/hide the diagnostic panel; it starts hidden in the normal build.

F8 and F9 are game keys, not mod controls. The diagnostic panel has session-only
Original renderer, Probe inputs and Reconstruction buttons. Original renderer
stops the camera adapter; it does not uninstall the backend proxy. Use the restore
procedure below to remove the tracked installation. Backend menu settings and
adapter settings are separate; use Set-Profile for repeatable configurations.

BUILD / PREPARE THE LOCAL BACKEND

The prepared workspace includes tools\dotnet, loader and vendor dependencies.
Native rebuilding also needs CMake and Visual Studio 2022 C++ tools. Builds use
the game's generated BepInEx interop assemblies; a game update requires renewed
interop generation and rebuilding. Build/test success alone is not visual proof.

With generated interop already available:

  .\scripts\Fetch-Backend.ps1
  .\scripts\Build.ps1 -Restore
  .\scripts\Stage-LocalBackend.ps1
  .\scripts\Install-Loader.ps1
  .\scripts\Set-Profile.ps1 -Profile DLAA -Multiplier 2 -Install

Fetch-Backend prepares the pinned official backend and initial config in stage.
Stage-LocalBackend restores the separately verified local backend and its source
notices to stage; it does not install into the game. The official fallback is kept
under vendor\backend-fallback. Install-Stage installs already staged files without
changing the selected profile. Build diagnostic variants remain separate; do not
replace the normal build with a scaling experiment during ordinary use.

If BepInEx interop does not exist yet, first run Build-LoaderFix.ps1 -Restore,
Install-Loader.ps1 and Launch-Offline.ps1. Allow generation to complete, then close
the game, confirm BepInEx\interop\Unity.Postprocessing.Runtime.dll exists, and run
Repair-Interop.ps1 before the build/setup commands above.

GENERATED COREMODULE COMPATIBILITY FIX

Unity's generated CoreModule wrapper was observed to throw .NET 6
BadImageFormatException: Duplicate type '<>O'. The repair normalizes metadata via
Mono.Cecil, checks the six known empty compiler-helper types and compares semantic
definitions before replacement. It refuses unexpected layouts.

Only BepInEx\interop\UnityEngine.CoreModule.dll is repaired; original game binaries
and assets are not patched. Launch-Offline runs the repair externally while the
game is stopped. It can also be run with .\scripts\Repair-Interop.ps1.
Original wrappers and the normalization record are preserved under:
  <game>\BepInEx\LastEpochGraphics\interop-backups\

LOGS AND REMAINING VALIDATION

  diagnostics\Player-D3D11-<timestamp>.log  Full Unity Player log
  <game>\BepInEx\LogOutput.log            Loader and managed adapter
  <game>\BepInEx\LastEpochGraphics\       Native logs and repair records
  <game>\OptiScaler.log                   Backend log

Check both the complete Player and backend logs, not only their tails. The
expanded checker rejects device loss even when Unity target dimensions are clean.
The saved 1600x900 run passes:

  .\scripts\Test-RenderLog.ps1 -PlayerLogPath '.\diagnostics\Player-D3D11-20261030-212935-665.log' -BackendLogPath '.\diagnostics\dlaa-fg234-nr-success-1600\OptiScaler.log' -RequireClean

The final native-display run also passes:

  .\scripts\Test-RenderLog.ps1 -PlayerLogPath '.\diagnostics\Player-D3D11-20261030-232734-696.log' -BackendLogPath '.\diagnostics\native-5120-final-e841-571c-7236\OptiScaler.log' -RequireClean

The following saved native run is expected to FAIL (-RequireClean throws):

  .\scripts\Test-RenderLog.ps1 -PlayerLogPath '.\diagnostics\Player-D3D11-20261030-220301-568.log' -BackendLogPath '.\diagnostics\native-5120-menu-device-hung\OptiScaler.log' -RequireClean

Pending: broader repeat testing of the menu/device fix and Alt-Tab,
transitions/combat/UI and sustained stability; controlled performance measurements.
Final-camera capture needs broader scene/UI testing; reduced-resolution SR remains
unsupported. Online behavior is unverified. A clean render-target log does not by itself establish
absence of every visual defect.

RESTORE / REMOVE THE TRACKED INSTALLATION

Close Last Epoch, then preview and execute:

  .\scripts\Restore.ps1 -WhatIf
  .\scripts\Restore.ps1

Restore uses the deployment journal, removes unchanged installed files and
restores recorded originals. Externally changed tracked files are refused.
Recognized OptiScaler.ini menu/runtime saves are backed up by SHA256 under
diagnostics\runtime-config before profile installation or restoration; this
exception never adopts changed DLLs. The original generated CoreModule is also
restored when its current hash matches the normalization record. A newer wrapper,
untracked files, generated caches and hash-named wrapper backups are retained.
Restore does not recursively delete BepInEx or the game directory.

Restore, Install-Loader, Install-Stage, Repair-Interop and Set-Profile support
-WhatIf. Supported game-directory overrides use -GameDirectory 'X:\path\to\Last Epoch'.

SOURCE AND LICENSES

Adapter/loader sources: src\managed, src\native, src\loader-diagnostics and
src\interop-repair. Native work adapted from Big Beautiful Walk retains the
LICENSE, NOTICE and UPSTREAM-NOTICE files under src\native.

The selected version.dll is a local modified GPL-3.0 OptiScaler build. Its exact
source patch, manifest, notice and license are under stage\docs\local-backend and
packaging\patches\menu-fence and vendor\optiscaler-local\local-build-menu-fence.
The pinned original source
archive plus that variant's patch reconstructs its matching source; the working
vendor\optiscaler-local tree can also contain separate diagnostic changes.
The notice supplies build instructions. Preserve corresponding-source obligations
when sharing.
NVIDIA runtimes and Streamline retain their separate licenses under
stage\OptiScaler\streamline\licenses and stage\docs\licenses. NR provenance is in
stage\docs\NeuralRendering-SOURCE.txt. BepInEx retains its upstream license.
