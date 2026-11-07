UNSELECTED FALLBACK-LIMITER SOURCE CANDIDATE
===========================================

Tracks https://github.com/fujin/last-epoch-dlss/issues/2. This is a focused review
and test delta against the selected 571C menu-fence source, not a complete patch
against the original upstream archive and not a replacement for 571C.
No backend DLL is included in this repository. The candidate has not been
promoted to the selected runtime.
The optional full-build recipe compiles a local candidate into an ignored tree.

PROBLEM AND CHANGE

FrameLimit::sleep(bool fgActive) multiplied the output-cap interval by two for
all active frame generation. FGHooks::FGPresent could use that fallback with
higher fixed MFG multipliers, so the requested output cap was not represented
correctly. The new sleep argument explicitly means output frames per rendered
frame. An active, unpaused feature supplies GetInterpolatedFrameCount()+1;
inactive/paused/null feature and existing no-FG/Vulkan callers use one.

The pure FrameLimitPolicy helper computes the total interval before rounding to
whole microseconds. It rejects disabled/non-finite/negative caps and clamps the
complete floating interval before integer conversion. Existing wait/timer code,
clock ownership and fallback eligibility conditions remain unchanged.

At 223.900009 output FPS the 5x interval becomes 22331 us instead of the old fixed 2x
interval 8932 us. This corrects cap semantics; it is NOT a claim of lower latency.
A correct output cap can intentionally reduce the real frame rate.

The native NVIDIA Reflex/Sleep path is UNCHANGED and ordinarily bypasses this
fallback. This patch does not establish a cause or fix for the reported NR input
delay. For dynamic MFG, GetInterpolatedFrameCount describes a configured maximum:
we use it as a conservative ceiling, not a measured per-frame displayed count.
It may underfill the output target when fewer frames are generated. End-to-end
input latency, real driver pacing and dynamic behavior remain unvalidated.

OFFLINE TESTS (NO GAME)

Run from the repository root:
  & .\packaging\patches\fallback-limiter\Test-Candidate.ps1

Requirements: existing pinned complete source ZIP in downloads, Git, and VS2022
v143 C++ Build Tools. The script does not download or install prerequisites.
It verifies the original ZIP and 571C full patch hashes, extracts ONLY the five
source files needed to reconstruct this policy/call-site delta, applies 571C's
FG_Hooks change, and verifies that hook against the archived 571C manifest.
It then checks/applies this candidate delta in a new ignored build directory.
This is a partial source reconstruction for policy tests, NOT a full backend
source tree or backend compilation.

The C++ tests compile the ACTUAL FrameLimitPolicy.h reconstructed from the patch;
there is no separate test implementation. Expected literal cases cover 1x..6x,
fractional caps, inactive/paused selection, live multiplier/cap changes, disabled
and invalid caps, count overflow boundaries and total-interval clamping. Tests
use no game, GPU, graphics DLL, Sleep, timing benchmark or latency measurement.
Results and the reconstructed production-header hash remain in the unique
build/fallback-limiter-tests-* directory printed by the script.

FULL BACKEND COMPILE CHECK (NO GAME)

Run from the repository root:
  & .\packaging\patches\fallback-limiter\Build-Candidate.ps1 -ParallelProcesses 2

This separate recipe extracts the COMPLETE pinned archive into a fresh ignored
build/fallback-limiter-full-* tree. It checks the 571C complete patch, applies it
once, verifies all 14 baseline modified-file hashes and the unchanged DX11
interop source, then applies the focused fallback delta. It never uses the mixed
vendor tree. The reconstructed Build-Local.ps1 builds Release x64 with at most
two compiler processes and disables upstream packaging events. dumpbin checks
four extension exports without loading the DLL. Logs, exports and build-results
remain in that unique ignored directory. No binary is uploaded by the script.

The 2026-11-04 full build passed with MSVC 14.44.35207/v143: 0 errors and the two
known upstream warnings C4744 (atomic shared_ptr alignment) and LNK4098 (mixed
CRT libraries). All four extension exports were present. Candidate DLL:
  26,470,912 bytes
  SHA256 D1B725510A86D2F9CEF11E4321F2719FAD5F364C76DAB898065CA066C3ED117B

full-build-validation.json records the ordered input hashes, 19 changed source
file identities, two generated build-identity headers, toolchain, artifact and
static export evidence. Timestamps/toolchain differences can change a rebuild's
DLL hash. The build alone establishes compile/export proof. See the bounded
runtime result below; fallback pacing, input latency, dynamic MFG and broader
compatibility remain unvalidated. The selected 571C backend remains unchanged.

RUNTIME TEST SCOPE AND FUTURE DIAGNOSTIC

2026-11-07: bounded compatibility testing completed at native 5120x1440:
fixed 2x/4x/5x FG with output cap 120 and NR at WorkingScale=0.5, plus 2x NR off.
These measurements used native Reflex and did not exercise the changed fallback
limiter. Stable 571C and the exact original configurations were restored at
09:09:57 UTC. The candidate remains unselected and has not been promoted.
Evidence: ../../../docs/validation/runtime-20261107.txt
The native NVIDIA DLSSG path enables Reflex eLowLatency (DLSSG_Dx12.cpp:300).
Reflex_Hooks.cpp:606 sets reflexLimitsFps from that mode, bypassing the fallback
at FG_Hooks.cpp:1357. The force-disable override is commented out; neither
[fakenvapi] ForceReflex=1 nor UseGamesReflexMarkers=false proves fallback use.
No supported configuration-only forcing path was found. A normal DLSSG run of
D1B725 validates compatibility only, not this changed limiter or lower latency.

Future diagnostic work, not implemented in the production candidate:
- Require both a separate diagnostic build define and a process-only opt-in.
  Preserve Reflex mode, markers and Sleep. In Reflex_Hooks.cpp, force the native
  cap to zero in setFPSLimit and hkNvAPI_D3D_SetSleepMode, check NVAPI results,
  and make update select fallback for the intended NVIDIA/D3D DLSSG test path.
  Clearing reflexLimitsFps alone could leave the old driver cap active.
- Count actual FrameLimit::sleep calls, effective multiplier/cap/interval,
  requested and elapsed wait time, and errors. Log each settings change and a
  summary every 300 calls; prove zero native cap before interpreting results.
- Compare 571C plus this diagnostic with D1B725 plus the identical diagnostic.
  Use ForceDMFG=false, InterpolationCount=1/3/4 (2x/4x/5x), output cap 80, NR off,
  then NR at WorkingScale=0.5. Expected old/new real-FPS ceilings are respectively
  40/40, 40/20, 40/16; output-call ceilings are 80/80, 160/80, 200/80. These are
  predictions subject to GPU headroom and other pacing, not measured results.
  Keep the scene/settings fixed and collect two complete 300-client intervals
  after each transition, matching counter epochs and checking rendering errors.
- Give the diagnostic a distinct artifact/export marker and provenance; reject
  it in release packaging and keep selected pins unchanged. The normal build
  must omit the define, so an environment variable alone cannot enable bypass.

Presentation calls do not measure physical scanouts or input-to-display latency.
This test plan establishes cap semantics; it makes no lower-latency claim.

PROVENANCE AND FUTURE USE

Base: Skynizz/optiscaler-dlss5 revision 6bfc4389c25054ef6747df6e6b1b470e9541c4da,
complete source ZIP SHA256 1EAAD2223E679A935426E922F86A0341232AE96641579FEC4A5B34004A1CD507.
Prerequisite full patch: ../menu-fence/late-hudless.patch, SHA256
53E3ED17C77CB12BF7710BEE540A8EF40F47DBA99EAEBD33325D29C78A196958.
See candidate-manifest.json for the new delta hash and explicit unselected state.

For another full backend build, reconstruct a FRESH complete archive, apply the
571C complete patch once, then this focused delta. Do not stack other complete
variant patches. Preserve 571C's original patches, notices, manifests and selected
hashes unchanged. A later DLL needs its own complete corresponding-source record,
review, build/export checks and runtime validation before any promotion. The
mixed vendor development tree contains unrelated unselected experiments and is
not a reproducible baseline for this candidate.

Source changes and tests in this directory are GPL-3.0 under the included LICENSE;
retain the original backend notices/licenses when reconstructing its full source.
