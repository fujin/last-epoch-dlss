// Adapted from Big Beautiful Walk; Copyright 2026 Big Beautiful Walk contributors.
// Licensed under Apache-2.0. Last Epoch adaptation: see NOTICE and LICENSE.
#include <windows.h>
#include <atomic>
#include "NgxProtocol.h"
#include "Upscaler.h"
#include "Native.h"
#ifdef LE_STREAMLINE_TELEMETRY
#include <sl_dlss_g.h>
#endif

// Calls only the loaded OptiScaler's NGX-compatible exports. OptiScaler owns
// upscaler selection, D3D11/D3D12 interop, FG, NR, and presentation hooks.
namespace {
using le::Log;
struct Exports {
    ngx::InitWithProjectIdFunction init = nullptr;
    ngx::GetCapabilityParametersFunction getCapabilityParameters = nullptr;
    ngx::CreateFeatureFunction createFeature = nullptr;
    ngx::EvaluateFeatureFunction evaluateFeature = nullptr;
    ngx::ReleaseFeatureFunction releaseFeature = nullptr;
};
bool attached = false, ngxReady = false;
Exports opti;
ngx::Parameter* parameters = nullptr;
ngx::Handle* feature = nullptr;
std::atomic<unsigned> flags{0}, lastResult{0}, fgResult{0}, fgFlags{0}, fgPresented{0}, fgMax{0};
std::atomic<int> fgState{0};
using HudlessVersionFunction = unsigned (__cdecl*)();
using HudlessTokenFunction = unsigned long long (__cdecl*)();
using HudlessSubmitFunction = int (__cdecl*)(ID3D11DeviceContext*, ID3D11Texture2D*, unsigned long long);
HudlessVersionFunction hudlessVersionFunction = nullptr;
HudlessTokenFunction hudlessTokenFunction = nullptr;
HudlessSubmitFunction hudlessSubmitFunction = nullptr;
std::atomic<unsigned> hudlessVersion{0};
bool hudlessQueried = false;
using PresentationFunction = int (__cdecl*)(PresentationDiagnostics*, unsigned);
PresentationFunction presentationFunction = nullptr;

template <typename Function>
bool Resolve(HMODULE module, const char* name, Function& function) {
    function = reinterpret_cast<Function>(GetProcAddress(module, name));
    return function != nullptr;
}
bool FindExports(HMODULE module, Exports& found) {
    return module &&
        Resolve(module, "NVSDK_NGX_D3D11_Init_with_ProjectID", found.init) &&
        Resolve(module, "NVSDK_NGX_D3D11_GetCapabilityParameters", found.getCapabilityParameters) &&
        Resolve(module, "NVSDK_NGX_D3D11_CreateFeature", found.createFeature) &&
        Resolve(module, "NVSDK_NGX_D3D11_EvaluateFeature", found.evaluateFeature) &&
        Resolve(module, "NVSDK_NGX_D3D11_ReleaseFeature", found.releaseFeature);
}
}

namespace le::backend {
const char* Name() { return "OptiScaler (selected backend unconfirmed)"; }

bool Attach(const std::wstring& runtimeDirectory) {
    if (attached) return true;
    // Never load it late: its factory and swapchain hooks must run at startup.
    std::wstring root = runtimeDirectory;
    for (auto& c : root) if (c == L'/') c = L'\\';
    while (!root.empty() && root.back() == L'\\') root.pop_back();
    for (const wchar_t* name : {L"version.dll", L"winmm.dll", L"dxgi.dll", L"OptiScaler.dll"}) {
        const std::wstring candidate = root + L"\\" + name;
        HMODULE module = GetModuleHandleW(candidate.c_str());
        if (!module) continue;
        Exports found;
        if (!FindExports(module, found)) continue;
        opti = found;
        attached = true;
        flags.fetch_or(1u);
        Resolve(module, "OptiScaler_GetHudlessD3D11Version", hudlessVersionFunction);
        Resolve(module, "OptiScaler_GetHudlessFrameTokenD3D11", hudlessTokenFunction);
        Resolve(module, "OptiScaler_SubmitHudlessD3D11", hudlessSubmitFunction);
        Resolve(module, "OptiScaler_GetPresentationStatsV1", presentationFunction);
        wchar_t loaded[32768]{};
        GetModuleFileNameW(module, loaded, 32768);
        Log("Loaded NGX-compatible bridge found: %ls. Export availability does not prove DLSS/FG/NR activation.", loaded);
        return true;
    }
    Log("No supported NGX-compatible OptiScaler module already loaded from %ls; bridge disabled.", root.c_str());
    return false;
}

bool Initialize(ID3D11Device* device, const std::wstring& dataDirectory, const std::wstring& runtimeDirectory) {
    if (!Attach(runtimeDirectory) || !device) return false;
    if (!hudlessQueried) {
        hudlessQueried = true;
        const unsigned version = hudlessVersionFunction && hudlessTokenFunction && hudlessSubmitFunction
            ? hudlessVersionFunction() : 0;
        hudlessVersion = version == 1 ? 1u : 0u;
        Log("Optional late HUDless provider ABI=%u supported=%d; this does not enable frame generation.", version, version == 1);
    }
    if (!ngxReady) {
        const auto result = opti.init("f5c13389-ff44-4c21-b44e-6ad38cd9efc9", ngx::EngineTypeUnity,
            "6000.4.8f1", dataDirectory.c_str(), device, nullptr, ngx::SdkVersion);
        lastResult = result;
        Log("OptiScaler NGX D3D11 initialization result=0x%08x", result);
        if (ngx::Failed(result) || result == 0) return false;
        ngxReady = true;
        flags.fetch_or(2u);
    }
    if (!parameters) {
        const auto result = opti.getCapabilityParameters(&parameters);
        lastResult = result;
        if (ngx::Failed(result) || result == 0 || !parameters) {
            parameters = nullptr;
            Log("OptiScaler capability parameters unavailable result=0x%08x", result);
            return false;
        }
    }
    int available = 0;
    const auto result = parameters->Get("SuperSampling.Available", &available);
    // Missing capability information is distinct from confirmation. Creation is
    // allowed as the authoritative probe, as OptiScaler may omit this key.
    if (ngx::Failed(result) || result == 0) {
        Log("SuperSampling.Available not reported; attempting feature creation as capability probe.");
        return true;
    }
    Log("OptiScaler SuperSampling.Available=%d", available);
    return available != 0;
}

bool HasFeature() { return feature != nullptr; }

bool Create(ID3D11DeviceContext* context, const CreateInputs& inputs) {
    if (!parameters || !context) return false;
    parameters->Set("Width", inputs.renderWidth);
    parameters->Set("Height", inputs.renderHeight);
    parameters->Set("OutWidth", inputs.outputWidth);
    parameters->Set("OutHeight", inputs.outputHeight);
    parameters->Set("PerfQualityValue", inputs.quality);
    parameters->Set("DLSS.Feature.Create.Flags", int(inputs.flags));
    parameters->Set("DLSS.Enable.Output.Subrects", 0);
    // Preset selection is owned by the configured OptiScaler backend. Do not
    // claim a requested hint is the effective NVIDIA model.
    const auto result = opti.createFeature(context, ngx::FeatureSuperSampling, parameters, &feature);
    lastResult = result;
    Log("OptiScaler CreateFeature result=0x%08x render=%ux%u output=%ux%u flags=0x%x quality=%d",
        result, inputs.renderWidth, inputs.renderHeight, inputs.outputWidth, inputs.outputHeight, inputs.flags, inputs.quality);
    const bool success = !ngx::Failed(result) && result != 0 && feature;
    if (success) flags.fetch_or(4u);
    else if (feature) { opti.releaseFeature(feature); feature = nullptr; }
    return success;
}

bool Evaluate(ID3D11DeviceContext* context, const EvaluateInputs& inputs, unsigned& result) {
    if (!parameters || !feature || !context) { result = 0; return false; }
    parameters->Set("Color", inputs.color);
    parameters->Set("Output", inputs.output);
    parameters->Set("Depth", inputs.depth);
    parameters->Set("MotionVectors", inputs.motion);
    parameters->Set("Jitter.Offset.X", inputs.jitterX);
    parameters->Set("Jitter.Offset.Y", inputs.jitterY);
    parameters->Set("Sharpness", 0.0f);
    parameters->Set("MV.Scale.X", inputs.motionScaleX == 0.0f ? 1.0f : inputs.motionScaleX);
    parameters->Set("MV.Scale.Y", inputs.motionScaleY == 0.0f ? 1.0f : inputs.motionScaleY);
    parameters->Set("Reset", inputs.reset);
    parameters->Set("DLSS.Render.Subrect.Dimensions.Width", inputs.renderWidth);
    parameters->Set("DLSS.Render.Subrect.Dimensions.Height", inputs.renderHeight);
    parameters->Set("DLSS.Pre.Exposure", 1.0f);
    parameters->Set("DLSS.Exposure.Scale", 1.0f);
    parameters->Set("FrameTimeDeltaInMsec", inputs.deltaMilliseconds);
    parameters->Set("FSR.cameraNear", inputs.cameraNear);
    parameters->Set("FSR.cameraFar", inputs.cameraFar);
    parameters->Set("FSR.cameraFovAngleVertical", inputs.cameraFov);
    parameters->Set("FSR.viewSpaceToMetersFactor", 1.0f);
    parameters->Set("FSR.frameTimeDelta", inputs.deltaMilliseconds);
    result = opti.evaluateFeature(context, feature, parameters, nullptr);
    lastResult = result;
    return !ngx::Failed(result) && result != 0;
}

void Release() {
    if (feature) opti.releaseFeature(feature);
    feature = nullptr;
    flags.fetch_and(~4u);
}

void ReportFrameGeneration(unsigned long long evaluations) {
    HMODULE module = GetModuleHandleW(L"sl.dlss_g.dll");
    if (!module) { fgState = 0; return; }
    fgState = 1;
#ifdef LE_STREAMLINE_TELEMETRY
    using PluginFunction = void* (__cdecl*)(const char*);
    auto getFunction = reinterpret_cast<PluginFunction>(GetProcAddress(module, "slGetPluginFunction"));
    if (!getFunction) { fgState = -1; return; }
    auto getState = reinterpret_cast<PFun_slDLSSGGetState*>(getFunction("slDLSSGGetState"));
    if (!getState) { fgState = -1; return; }
    sl::DLSSGState state{};
    const sl::ViewportHandle viewport{0};
    const auto result = getState(viewport, state, nullptr);
    fgResult = unsigned(result);
    if (result != sl::Result::eOk) { fgState = -1; return; }
    fgState = 2;
    fgFlags = unsigned(state.status);
    fgPresented = state.numFramesActuallyPresented;
    fgMax = state.numFramesToGenerateMax;
    Log("FG telemetry query succeeded flags=0x%x presentedSinceSample=%u SR_evaluations=%llu maxGeneratedPerRendered=%u. Counts do not prove a specific active multiplier.",
        unsigned(state.status), state.numFramesActuallyPresented, evaluations, state.numFramesToGenerateMax);
#else
    Log("FG runtime module loaded; no query compiled, activation unverified (SR evaluations=%llu).", evaluations);
#endif
}

BackendStatus Status() {
    return {flags.load(), lastResult.load(), fgState.load(), fgResult.load(), fgFlags.load(), fgPresented.load(), fgMax.load()};
}
unsigned HudlessVersion() { return hudlessVersion.load(); }
unsigned long long HudlessFrameToken() { return hudlessVersion == 1 ? hudlessTokenFunction() : 0; }
int SubmitHudless(ID3D11DeviceContext* context, ID3D11Texture2D* color, unsigned long long token) {
    return hudlessVersion == 1 ? hudlessSubmitFunction(context, color, token) : 0;
}
int QueryPresentation(PresentationDiagnostics& output) {
    return presentationFunction ? presentationFunction(&output, sizeof(output)) : 0;
}
}
