// Last Epoch rendering bridge ABI. Pack=8, x64, cdecl exports.
#pragma once
#include <cstdint>
#include <d3d11.h>

#pragma pack(push, 8)
struct Frame {
    int abi, cameraId, frameIndex, mode;
    ID3D11Resource *color, *depth, *motion, *output;
    int renderWidth, renderHeight, outputWidth, outputHeight;
    float jitterX, jitterY, motionScaleX, motionScaleY;
    int historyEpoch, verify, reversedDepth;
    float cameraNear, cameraFar, cameraFov, deltaMilliseconds;
    int quality, preset;
};

struct NativeDiagnostics {
    int abi, size, status, backendFlags;
    unsigned lastNgxResult;
    int frameGenerationState;
    unsigned frameGenerationResult, frameGenerationFlags;
    unsigned presentedSinceSample, maxGeneratedPerRendered;
    std::uint64_t evaluations, queuedFrames, rejectedFrames;
};
struct HudlessDiagnostics {
    int abi, size, providerVersion, lastResult;
    std::uint64_t capturedTokens, acceptedSubmissions, rejectedSubmissions;
};
// Optional local-provider presentation-counter ABI. DXGI PresentCount is a
// sequence counter, not physical panel scanouts. Compare deltas within one epoch.
struct PresentationDiagnostics {
    std::uint32_t size, version;
    std::uint64_t epoch, clientPresents, nativePresentCalls, displayedFrames;
    std::uint64_t sampleQpc, qpcFrequency;
    std::uint32_t flags, nativeRaw, displayRaw, presentRefresh, syncRefresh;
    std::int32_t nativeQueryHResult, displayQueryHResult;
    std::uint32_t requestedMultiplier;
    std::uint64_t lastDisplayQpc;
};
#pragma pack(pop)
static_assert(sizeof(Frame) == 120, "Frame must match managed ABI 3, Pack=8");
static_assert(sizeof(NativeDiagnostics) == 64, "Diagnostics must match managed ABI 1, Pack=8");
static_assert(sizeof(HudlessDiagnostics) == 40, "HUDless diagnostics ABI 1, Pack=8");
static_assert(sizeof(PresentationDiagnostics) == 96, "Presentation diagnostics ABI 1, Pack=8");

// Native status: 0 waiting; 1 input contract accepted; 2 SR evaluate succeeded;
// 3 feature created only; negative values identify failure (see ABI.md).
// Backend flags: 1 attached, 2 initialized, 4 feature created.
// FG state: 0 not observed; 1 runtime module loaded; 2 query succeeded;
// -1 query unavailable or failed. None alone proves generated frames are visible.
