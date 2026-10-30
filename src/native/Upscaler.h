// Adapted from Big Beautiful Walk; Copyright 2026 Big Beautiful Walk contributors.
// Licensed under Apache-2.0. Last Epoch adaptation: see NOTICE and LICENSE.
#pragma once
#include <d3d11.h>
#include <string>
struct PresentationDiagnostics;

// Vendor-neutral contract between the shared core (Native.cpp) and the one backend linked into
// each DLL. Exactly one backend translation unit defines le::backend; nothing here includes
// vendor SDK headers.
namespace le {

void Log(const char* format, ...);

// Feature-creation flag bits, numerically identical to the NGX DLSS create flags.
enum CreateFlags : unsigned {
    FlagIsHDR = 1u << 0,
    FlagMVLowRes = 1u << 1,
    FlagDepthInverted = 1u << 3,
    FlagAutoExposure = 1u << 6,
};

struct CreateInputs {
    unsigned renderWidth, renderHeight, outputWidth, outputHeight;
    int quality, preset;
    unsigned flags;
};

struct EvaluateInputs {
    ID3D11Resource *color, *output, *depth, *motion;
    float jitterX, jitterY, motionScaleX, motionScaleY;
    unsigned renderWidth, renderHeight;
    int reset;
    // Near/far are already ordered for the depth convention (swapped for reversed depth).
    float cameraNear, cameraFar, cameraFov, deltaMilliseconds;
};

struct BackendStatus {
    unsigned flags = 0, lastNgxResult = 0;
    int frameGenerationState = 0;
    unsigned frameGenerationResult = 0, frameGenerationFlags = 0;
    unsigned presentedSinceSample = 0, maxGeneratedPerRendered = 0;
};

namespace backend {
// Short name used in log lines ("DLSS" or "OptiScaler").
const char* Name();
// Called from LE_Initialize; returns false when the backend cannot run in this process.
bool Attach(const std::wstring& runtimeDirectory);
// One-time runtime initialisation on the render thread. Retries must not re-run completed steps.
bool Initialize(ID3D11Device* device, const std::wstring& dataDirectory, const std::wstring& runtimeDirectory);
bool HasFeature();
bool Create(ID3D11DeviceContext* context, const CreateInputs& inputs);
bool Evaluate(ID3D11DeviceContext* context, const EvaluateInputs& inputs, unsigned& result);
// Caller guarantees the GPU is idle.
void Release();
void ReportFrameGeneration(unsigned long long evaluations);
// Optional local-provider ABI. The version getter returns cached state; the
// other calls run only on the immediate rendering thread.
unsigned HudlessVersion();
unsigned long long HudlessFrameToken();
int SubmitHudless(ID3D11DeviceContext* context, ID3D11Texture2D* color, unsigned long long token);
int QueryPresentation(PresentationDiagnostics& output);
BackendStatus Status();
}
}
