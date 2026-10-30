# Native interface

`LastEpochNative.dll` is an x64 C ABI with cdecl exports. The render callback
returned by `LE_GetRenderEvent` is `void __stdcall(int eventId, void* data)`;
use event ID 1. Managed structures must use sequential layout and `Pack=8`.

The bridge was adapted from Big Beautiful Walk's Apache-2.0 native layer.
The full upstream notice and licence are retained alongside the source.

## Frame (ABI 3, 120 bytes)

Fields in order, matching `Native.h`:

| Offset | Type | Fields |
| --- | --- | --- |
| 0 | four int32 | abi=3, cameraId, frameIndex, mode |
| 16 | four pointers | color, depth, motion, output |
| 48 | four int32 | renderWidth, renderHeight, outputWidth, outputHeight |
| 64 | four float32 | jitterX, jitterY, motionScaleX, motionScaleY |
| 80 | three int32 | historyEpoch, verify, reversedDepth |
| 92 | four float32 | cameraNear, cameraFar, cameraFov, deltaMilliseconds |
| 108 | two int32 | quality, preset |
| 116 | padding | four bytes |

Mode 0 validates and optionally reads back inputs without invoking NGX.
Mode 2 creates a feature without evaluating it. Modes 1 and 3 evaluate.
`quality` is the NGX 0–5 value (5 is DLAA); `preset` is retained for ABI
compatibility but the OptiScaler backend owns its effective preset selection.
Near/far must be positive, conventional physical distances, near < far; the
bridge swaps the optional backend camera inputs when `reversedDepth` is set.
FOV is vertical radians. Frame time is milliseconds. `historyEpoch` changes on
camera cuts or discontinuities. Jitter is in render pixels; motion scale must
be established against the actual game's motion-buffer convention.

All resources must be actual `ID3D11Resource*` from the same device, 2D,
single-sampled and one slice. Output is RGBA16F and must already contain the
fallback image before evaluation. Colour extent equals render extent; depth
and motion may be render or output resolution. Output cannot be smaller than
render extent. Use persistent render textures with lifetime extending through
the render callback; do not pass temporary command-buffer identifiers as COM
pointers.

Unity 6 may return typeless resource formats for explicitly declared floating-point
RenderTextures. RG16/RG32 TYPELESS motion is interpreted as RG16F/RG32F;
R32 TYPELESS depth as R32F; RGBA16 TYPELESS colour/output as RGBA16F. The
managed producer must actually create those float formats (typeless alone cannot
identify whether arbitrary external data is float or integer).

`LE_Queue(ref Frame)` returns an opaque consume-once token; never dereference it.
The bridge owns a copy of the frame with all four resources AddRef'd. Hand the
token to `IssuePluginEventAndData`; its first callback frees the frame and
releases the resources. Replayed or cancelled tokens are ignored. Monotonically
allocated token IDs are never reused, and at most 256 pending frames are allowed.
If submission fails, call `LE_CancelQueuedFrame`. Cancellation is also safe after
recording when retiring a camera or mode: it atomically consumes an unexecuted
token and suppresses its evaluation; the prefilled fallback remains. If the
callback already consumed it, cancellation is a no-op and the callback retains
its resources until it returns. The managed producer tracks at most 64 recent
tokens per camera and cancels them on disposal, including discarded command buffers.
The queue protects COM lifetime, not correctness of image contents. A resource
may remain allocated while Unity overwrites it, so schedule copies and the
plugin callback in the correct camera command sequence.

## Exports

- `void LE_Initialize(wchar_t* dataDirectory, wchar_t* runtimeDirectory)`:
  call once before queuing. Both are absolute existing directories. The runtime
  directory contains an already loaded OptiScaler proxy; no late load occurs.
- `int LE_FrameSize()`: returns 120.
- `int LE_Status()`: status described below.
- `void LE_RequestRetry()`: retry nonfatal failure on the next render callback.
- `void* LE_GetRenderEvent()`: callback address.
- `Frame* LE_Queue(Frame*)`: queue/copy or null on rejected arguments.
- `void LE_CancelQueuedFrame(Frame*)`: consume/cancel a pending opaque token.
- `uint64 LE_Evaluations()`: successful NGX evaluate calls, not presented FPS.
- `int LE_GetDiagnostics(NativeDiagnostics*, int size)`: pass 64; returns 1 on success.

Status: 0 waiting; 1 validated inputs; 2 successful evaluate; 3 feature created
without evaluate. Failures: -1 invalid resources/contract; -2 initialization
paths or bridge attachment; -3 backend initialization; -4 feature creation;
-5 evaluate; -6 device/context; -7 native exception (requires game restart).

## Diagnostics (ABI 1, 64 bytes)

| Offset | Type | Fields |
| --- | --- | --- |
| 0 | four int32 | abi=1, size=64, status, backendFlags |
| 16 | uint32, int32 | lastNgxResult, frameGenerationState |
| 24 | four uint32 | frameGenerationResult, frameGenerationFlags, presentedSinceSample, maxGeneratedPerRendered |
| 40 | three uint64 | evaluations, queuedFrames, rejectedFrames |

Backend flags: bit 0=exports attached, bit 1=NGX initialized, bit 2=feature
created. Frame-generation state: 0=no module observed, 1=module loaded but
activation unknown, 2=state query succeeded, -1=query unavailable/failed.
State querying is optional (`STREAMLINE_ROOT` at build time) and read-only.
These values do not certify a particular active upscaler, NR state, or FG
multiplier. Streamline's presented counter includes ordinary frames; observing
a nonzero counter alone is not proof that interpolation is active.

When `verify` is set, depth/motion sample min/max, nonzero count and hashes are
written at most every 300 frame IDs. After 30 successful evaluations, one
sampled output comparison is made against the prefilled fallback. Readback
can stall rendering; enable it for diagnosis. Nonzero motion or changed output
does not establish temporal correctness. Inspect moving geometry and UI too.

## Optional final-scene and presentation interfaces

`LE_QueueHudless(cameraId, frameIndex, ID3D11Resource*)` retains its texture and
returns an opaque consume-once token. Submit it with render event 2 after final
scene postprocessing and before UI. Event 2 matches the camera/frame against the
provider token obtained immediately after successful reconstruction. Stale,
replayed, mismatched, unsupported-format, and late submissions are rejected.
`LE_CancelQueuedFrame` can cancel this token using the same registry as event 1.
Frame ABI 3 remains 120 bytes.

### Optional local capture evidence

`LE_DLSS_DUMP_HUDLESS=1` enables at most four raw 8-bit BMP captures per process after the provider accepts a HUDless submission. With `LE_DLSS_HUDLESS_DUMP_REQUEST` set to an absolute marker-file path, no image is captured until that file is created or modified. Each new modification requests one image; the bridge polls the marker once per 60 camera frames. The marker is read only and is never deleted or modified by the bridge. Without a marker path, automatic mode captures at most one nonblack image per history epoch. Black frames retry no more frequently than every 300 camera frames.

Images are written beside `native.log`, with process, history epoch and frame in the filename. They preserve RGB storage bytes and top-row-first resource orientation; no gamma conversion or vertical correction is applied. Compare a captured scene with the actual presentation before claiming correct HUD separation. The capture RTV format/identity is logged before the context-state swap. These diagnostics are optional, can stall the GPU, and should be disabled for performance measurements. Frame and diagnostics ABI layouts are unchanged.

The optional provider is local OptiScaler API 1: `OptiScaler_GetHudlessD3D11Version`,
`OptiScaler_GetHudlessFrameTokenD3D11`, and `OptiScaler_SubmitHudlessD3D11`. It requires
`HUDFix=false` and `DisableHudless=false`. Managed `[Compatibility] LateHudless`
defaults false. Inputs must be full-display-size SDR 8-bit RGBA/BGRA with the same
encoded image as the displayed final scene. The capture performs sRGB encoding in
a Linear Unity project; the provider only copies or changes storage layout. HDR
and other source/swapchain formats are rejected. Acceptance does not measure FG.

`LE_HudlessProviderVersion` returns cached render-thread discovery. The 40-byte
Pack=8 `LE_GetHudlessDiagnostics` output contains int32 abi=1, size=40,
providerVersion, lastResult, followed by uint64 capturedTokens,
acceptedSubmissions, rejectedSubmissions. Provider result 1 means accepted;
bridge -100 means no matching token and -101 means invalid texture dimensions or
format. Event 3 uses the same retained packet for diagnostic color sampling only,
without calling the provider. It is safe with FG disabled.

`LE_GetPresentationDiagnostics` returns a cached 96-byte Pack=8 snapshot from the
optional `OptiScaler_GetPresentationStatsV1` export. The provider query runs only
on the rendering thread, first and every 300 successful evaluations. Main-thread
reads copy the snapshot under a mutex. Missing or faulty optional telemetry does
not disable reconstruction. Return 1 means a snapshot is available, 0 unavailable,
negative values indicate a query/contract failure; per-counter flags still apply.

The layout is uint32 size=96/version=1; uint64 epoch, clientPresents,
nativePresentCalls, displayedFrames, sampleQpc, qpcFrequency; uint32 flags,
nativeRaw, displayRaw, presentRefresh, syncRefresh; int32 nativeQueryHResult,
displayQueryHResult; uint32 requestedMultiplier; uint64 lastDisplayQpc.
Flags are 1 verified visible chain, 2 native counter valid, 4 DXGI statistics valid,
8 provider FG active, 16 DLSSG output, 32 DX11 interop, 64 new baseline. Compare
monotonic deltas only within the same epoch and QPC frequency. `displayedFrames`
is the ABI name for accumulated DXGI PresentCount deltas, not physical panel
scanouts or unique images. No Streamline reset-on-read counters are used here.

When verification is enabled, sampled raw RGB and reconstructed RGB statistics
are logged along with depth/motion. Event 3 can sample the postprocess result to
separate reconstruction errors from postprocessing/presentation errors.

## Build and software check

```powershell
cmake -S src/native -B build/native -G "Visual Studio 17 2022" -A x64
cmake --build build/native --config Release
ctest --test-dir build/native -C Release --output-on-failure
```

The smoke test creates a software D3D11 device and tests ABI sizes, invalid
pointer rejection, input sampling, context restoration, queue cancellation,
and missing-backend handling. It does not test NVIDIA rendering or the game.

The optional `LE_BUILD_NGX` SDK backend is retained for future use and is not
part of the default build or the currently selected OptiScaler route.
