#include <windows.h>
#include <wrl/client.h>
#include <cstdio>
#include <vector>
#include "Native.h"

extern "C" __declspec(dllimport) void LE_Initialize(const wchar_t*, const wchar_t*);
extern "C" __declspec(dllimport) int LE_FrameSize();
extern "C" __declspec(dllimport) int LE_Status();
extern "C" __declspec(dllimport) void LE_RequestRetry();
extern "C" __declspec(dllimport) void* LE_GetRenderEvent();
extern "C" __declspec(dllimport) Frame* LE_Queue(const Frame*);
extern "C" __declspec(dllimport) void LE_CancelQueuedFrame(Frame*);
extern "C" __declspec(dllimport) int LE_GetDiagnostics(NativeDiagnostics*, int);
extern "C" __declspec(dllimport) unsigned LE_HudlessProviderVersion();
extern "C" __declspec(dllimport) void* LE_QueueHudless(int, int, ID3D11Resource*);
extern "C" __declspec(dllimport) int LE_GetHudlessDiagnostics(HudlessDiagnostics*, int);
extern "C" __declspec(dllimport) int LE_GetPresentationDiagnostics(PresentationDiagnostics*, int);

using Microsoft::WRL::ComPtr;
int wmain(int argc, wchar_t** argv) {
    if (argc != 2) return 1;
    CreateDirectoryW(argv[1], nullptr);
    if (LE_FrameSize() != 120) return 2;
    LE_Initialize(argv[1], argv[1]); // No bridge present in this test.
    if (LE_Status() != -2) return 3;
    NativeDiagnostics diagnostics{};
    if (LE_GetDiagnostics(&diagnostics, 1) != 0 || !LE_GetDiagnostics(&diagnostics, sizeof(diagnostics))) return 4;
    if (diagnostics.abi != 1 || diagnostics.size != 64 || diagnostics.backendFlags != 0 || diagnostics.evaluations != 0) return 5;
    if (LE_Queue(nullptr)) return 6;

    ComPtr<ID3D11Device> device;
    ComPtr<ID3D11DeviceContext> context;
    D3D_FEATURE_LEVEL level{};
    HRESULT result = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_WARP, nullptr, 0, nullptr, 0,
        D3D11_SDK_VERSION, &device, &level, &context);
    if (FAILED(result)) { printf("WARP creation failed 0x%08x\n", unsigned(result)); return 7; }

    constexpr unsigned width = 64, height = 32;
    std::vector<unsigned short> colors(width * height * 4, 0x3800);
    std::vector<unsigned short> vectors(width * height * 2, 0x2000);
    std::vector<float> depths(width * height);
    for (unsigned i = 0; i < depths.size(); ++i) depths[i] = 0.2f + 0.6f * float(i) / float(depths.size());
    auto makeTexture = [&](DXGI_FORMAT format, const void* pixels, unsigned pitch, ComPtr<ID3D11Texture2D>& texture) {
        D3D11_TEXTURE2D_DESC desc{};
        desc.Width = width; desc.Height = height; desc.MipLevels = 1; desc.ArraySize = 1;
        desc.Format = format; desc.SampleDesc.Count = 1; desc.Usage = D3D11_USAGE_DEFAULT;
        desc.BindFlags = D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_RENDER_TARGET;
        D3D11_SUBRESOURCE_DATA data{pixels, pitch, 0};
        return SUCCEEDED(device->CreateTexture2D(&desc, &data, &texture));
    };
    ComPtr<ID3D11Texture2D> color, depth, motion, output;
    if (!makeTexture(DXGI_FORMAT_R16G16B16A16_FLOAT, colors.data(), width * 8, color) ||
        !makeTexture(DXGI_FORMAT_R32_FLOAT, depths.data(), width * 4, depth) ||
        !makeTexture(DXGI_FORMAT_R16G16_FLOAT, vectors.data(), width * 4, motion) ||
        !makeTexture(DXGI_FORMAT_R16G16B16A16_FLOAT, colors.data(), width * 8, output)) return 8;

    Frame frame{};
    frame.abi = 3; frame.cameraId = 1; frame.frameIndex = 1; frame.mode = 0;
    frame.color = color.Get(); frame.depth = depth.Get(); frame.motion = motion.Get(); frame.output = output.Get();
    frame.renderWidth = frame.outputWidth = width; frame.renderHeight = frame.outputHeight = height;
    frame.motionScaleX = -float(width); frame.motionScaleY = -float(height);
    frame.cameraNear = 0.1f; frame.cameraFar = 1000; frame.cameraFov = 1.0f;
    frame.deltaMilliseconds = 16.6667f; frame.quality = 5; frame.verify = 1;
    const D3D11_VIEWPORT expectedViewport{3.0f, 4.0f, 64.0f, 32.0f, 0.0f, 1.0f};
    context->RSSetViewports(1, &expectedViewport);
    ComPtr<ID3D11RenderTargetView> expectedTarget;
    if (FAILED(device->CreateRenderTargetView(color.Get(), nullptr, &expectedTarget))) return 18;
    ID3D11RenderTargetView* target = expectedTarget.Get();
    context->OMSetRenderTargets(1, &target, nullptr);

    Frame invalid = frame; invalid.abi = 2;
    if (LE_Queue(&invalid)) return 9;
    invalid = frame; invalid.color = reinterpret_cast<ID3D11Resource*>(1);
    if (LE_Queue(&invalid)) return 10;
    LE_RequestRetry();
    Frame* queued = LE_Queue(&frame);
    if (!queued) return 11;
    using RenderEvent = void(__stdcall*)(int, void*);
    auto callback = reinterpret_cast<RenderEvent>(LE_GetRenderEvent());
    callback(1, queued); // A real Unity test must call on its render thread.
    if (LE_Status() != 1) { printf("Probe status=%d\n", LE_Status()); return 12; }
    callback(1, queued); // A replayed camera command buffer must not reuse freed memory.
    LE_CancelQueuedFrame(queued); // Consumed tokens are harmless, too.
    UINT viewportCount = 1;
    D3D11_VIEWPORT actualViewport{};
    context->RSGetViewports(&viewportCount, &actualViewport);
    ComPtr<ID3D11RenderTargetView> actualTarget;
    context->OMGetRenderTargets(1, &actualTarget, nullptr);
    if (viewportCount != 1 || actualViewport.TopLeftX != expectedViewport.TopLeftX ||
        actualViewport.Width != expectedViewport.Width || actualTarget.Get() != expectedTarget.Get()) return 19;
    if (!LE_GetDiagnostics(&diagnostics, sizeof(diagnostics)) || diagnostics.evaluations != 0 || diagnostics.queuedFrames != 1 || diagnostics.rejectedFrames != 3) return 13;
    queued = LE_Queue(&frame);
    if (!queued) return 14;
    LE_CancelQueuedFrame(queued);
    callback(1, queued);
    LE_CancelQueuedFrame(queued);
    // Unity 6 exposes typeless resources even when RenderTexture was declared
    // ARGBHalf/RFloat/RGHalf. Their declared channel types determine interpretation.
    ComPtr<ID3D11Texture2D> typelessColor, typelessDepth, typelessMotion, typelessOutput;
    if (!makeTexture(DXGI_FORMAT_R16G16B16A16_TYPELESS, colors.data(), width * 8, typelessColor) ||
        !makeTexture(DXGI_FORMAT_R32_TYPELESS, depths.data(), width * 4, typelessDepth) ||
        !makeTexture(DXGI_FORMAT_R16G16_TYPELESS, vectors.data(), width * 4, typelessMotion) ||
        !makeTexture(DXGI_FORMAT_R16G16B16A16_TYPELESS, colors.data(), width * 8, typelessOutput)) return 20;
    frame.color = typelessColor.Get(); frame.depth = typelessDepth.Get();
    frame.motion = typelessMotion.Get(); frame.output = typelessOutput.Get();
    frame.frameIndex = 302;
    Frame* consumed = queued;
    queued = LE_Queue(&frame);
    if (!queued || queued == consumed) return 21;
    callback(1, queued);
    if (LE_Status() != 1) return 22;
    frame.mode = 1; frame.frameIndex = 2;
    queued = LE_Queue(&frame);
    if (!queued) return 15;
    callback(1, queued);
    if (LE_Status() != -3) return 16;
    if (!LE_GetDiagnostics(&diagnostics, sizeof(diagnostics)) || diagnostics.evaluations || diagnostics.backendFlags) return 17;
    // A 90% input uses fewer scene pixels while retaining the display-sized output.
    // WARP validates only our resource contract and host-context restoration. It
    // does not evaluate DLSS or establish that Unity presents scaled output correctly.
    constexpr unsigned scaledWidth = 576, scaledHeight = 162;
    constexpr unsigned displayWidth = 640, displayHeight = 180;
    auto makeSizedTexture = [&](DXGI_FORMAT format, unsigned w, unsigned h,
                                bool unorderedAccess, ComPtr<ID3D11Texture2D>& texture) {
        D3D11_TEXTURE2D_DESC desc{};
        desc.Width = w; desc.Height = h; desc.MipLevels = 1; desc.ArraySize = 1;
        desc.Format = format; desc.SampleDesc.Count = 1; desc.Usage = D3D11_USAGE_DEFAULT;
        desc.BindFlags = D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_RENDER_TARGET;
        if (unorderedAccess) desc.BindFlags |= D3D11_BIND_UNORDERED_ACCESS;
        return SUCCEEDED(device->CreateTexture2D(&desc, nullptr, &texture));
    };
    ComPtr<ID3D11Texture2D> scaledColor, scaledDepth, scaledMotion, displayOutput;
    ComPtr<ID3D11Texture2D> displayDepth, displayMotion;
    if (!makeSizedTexture(DXGI_FORMAT_R16G16B16A16_FLOAT, scaledWidth, scaledHeight, false, scaledColor) ||
        !makeSizedTexture(DXGI_FORMAT_R32_FLOAT, scaledWidth, scaledHeight, false, scaledDepth) ||
        !makeSizedTexture(DXGI_FORMAT_R16G16_FLOAT, scaledWidth, scaledHeight, false, scaledMotion) ||
        !makeSizedTexture(DXGI_FORMAT_R16G16B16A16_FLOAT, displayWidth, displayHeight, true, displayOutput) ||
        !makeSizedTexture(DXGI_FORMAT_R32_FLOAT, displayWidth, displayHeight, false, displayDepth) ||
        !makeSizedTexture(DXGI_FORMAT_R16G16_FLOAT, displayWidth, displayHeight, false, displayMotion)) return 27;
    Frame scaled = frame;
    scaled.frameIndex = 600; scaled.mode = 0; scaled.verify = 0; scaled.quality = 2;
    scaled.color = scaledColor.Get(); scaled.depth = scaledDepth.Get();
    scaled.motion = scaledMotion.Get(); scaled.output = displayOutput.Get();
    scaled.renderWidth = scaledWidth; scaled.renderHeight = scaledHeight;
    scaled.outputWidth = displayWidth; scaled.outputHeight = displayHeight;
    scaled.jitterX = 0.25f; scaled.jitterY = -0.375f;
    scaled.motionScaleX = -float(scaledWidth); scaled.motionScaleY = -float(scaledHeight);
    auto probeScaled = [&](const char* label, const Frame& probe, int expectedStatus) {
        LE_RequestRetry();
        Frame* token = LE_Queue(&probe);
        if (!token) { printf("%s: valid queue metadata was rejected\n", label); return false; }
        callback(1, token);
        if (LE_Status() != expectedStatus) {
            printf("%s: expected native status %d, received %d\n", label, expectedStatus, LE_Status());
            return false;
        }
        UINT count = 1;
        D3D11_VIEWPORT viewport{};
        ComPtr<ID3D11RenderTargetView> renderTarget;
        context->RSGetViewports(&count, &viewport);
        context->OMGetRenderTargets(1, &renderTarget, nullptr);
        const bool restored = count == 1 && renderTarget.Get() == expectedTarget.Get() &&
            viewport.TopLeftX == expectedViewport.TopLeftX && viewport.TopLeftY == expectedViewport.TopLeftY &&
            viewport.Width == expectedViewport.Width && viewport.Height == expectedViewport.Height &&
            viewport.MinDepth == expectedViewport.MinDepth && viewport.MaxDepth == expectedViewport.MaxDepth;
        if (!restored) printf("%s: host viewport/render target changed\n", label);
        return restored;
    };
    if (!probeScaled("90% input with render-resolution guides", scaled, 1)) return 28;
    Frame fullGuides = scaled;
    fullGuides.frameIndex++;
    fullGuides.depth = displayDepth.Get(); fullGuides.motion = displayMotion.Get();
    fullGuides.motionScaleX = -float(displayWidth); fullGuides.motionScaleY = -float(displayHeight);
    if (!probeScaled("90% input with display-resolution guides", fullGuides, 1)) return 29;
    Frame wrongExtent = scaled;
    wrongExtent.frameIndex += 2; wrongExtent.color = color.Get();
    if (!probeScaled("Color extent differs from declared render extent", wrongExtent, -1)) return 30;
    wrongExtent = scaled;
    wrongExtent.frameIndex += 3; wrongExtent.output = output.Get();
    if (!probeScaled("Output extent differs from declared display extent", wrongExtent, -1)) return 31;
    wrongExtent = scaled;
    wrongExtent.frameIndex += 4; wrongExtent.depth = depth.Get();
    if (!probeScaled("Depth extent matches neither render nor display extent", wrongExtent, -1)) return 32;
    wrongExtent = scaled;
    wrongExtent.frameIndex += 5; wrongExtent.motion = motion.Get();
    if (!probeScaled("Motion extent matches neither render nor display extent", wrongExtent, -1)) return 33;
    scaled.frameIndex += 6;
    if (!probeScaled("90% contract recovers after rejected extents", scaled, 1)) return 34;
    if (!LE_GetDiagnostics(&diagnostics, sizeof(diagnostics)) || diagnostics.evaluations || diagnostics.backendFlags)
        return 35;
    HudlessDiagnostics lateDiagnostics{};
    PresentationDiagnostics presentation{};
    if (LE_GetPresentationDiagnostics(&presentation, 1) != -1 ||
        LE_GetPresentationDiagnostics(&presentation, sizeof(presentation)) != 0 ||
        presentation.size != sizeof(presentation) || presentation.version != 1 || presentation.flags != 0) return 26;
    if (LE_HudlessProviderVersion() != 0 || !LE_GetHudlessDiagnostics(&lateDiagnostics, sizeof(lateDiagnostics)) ||
        lateDiagnostics.abi != 1 || lateDiagnostics.size != 40 || lateDiagnostics.acceptedSubmissions) return 23;
    auto late = LE_QueueHudless(1, 302, color.Get());
    if (!late) return 24;
    callback(2, late); callback(2, late);
    LE_CancelQueuedFrame(reinterpret_cast<Frame*>(late));
    if (!LE_GetHudlessDiagnostics(&lateDiagnostics, sizeof(lateDiagnostics)) || lateDiagnostics.acceptedSubmissions) return 25;
    printf("PASS: ABI120/64, invalid pointer rejection, WARP typed+typeless sampling/context restore, consume-once replay/cancellation, 90%% scaled-resource contracts and extent rejection, missing backend fails closed. No NVIDIA execution or Unity presentation tested.\n");
    return 0;
}
