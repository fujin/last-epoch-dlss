// Adapted from Big Beautiful Walk; Copyright 2026 Big Beautiful Walk contributors.
// Licensed under Apache-2.0. Last Epoch adaptation: see NOTICE and LICENSE.
#include <windows.h>
#include <d3d11_1.h>
#include <wrl/client.h>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <memory>
#include <limits>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>
#include "Upscaler.h"
#include "Native.h"

// Shared core of both native DLLs. The upscaler backend (NVIDIA NGX SDK or the OptiScaler bridge)
// is chosen at link time; this file contains no vendor SDK code.
using Microsoft::WRL::ComPtr;
namespace backend = le::backend;

namespace {
std::atomic<int> status{0};
std::atomic<bool> retryRequested{false};
std::atomic<bool> fatalError{false};
std::atomic<unsigned long long> evaluationCount{0}, queuedCount{0}, rejectedCount{0};
std::atomic<unsigned long long> hudlessCaptured{0}, hudlessAccepted{0}, hudlessRejected{0};
std::atomic<int> hudlessResult{0};
std::mutex presentationMutex;
PresentationDiagnostics presentationSnapshot{sizeof(PresentationDiagnostics), 1};
int presentationResult = 0;
bool presentationQueryFailed = false;
bool verifyReadbacks = false;
bool dumpHudlessImages = false;
unsigned hudlessImageCount = 0;
int hudlessImageEpoch = -1;
int hudlessImageAttemptEpoch = -1, hudlessImageAttemptFrame = -1;
int hudlessViewEpoch = -1, hudlessViewFrame = -1, hudlessReadbackFrame = -1;
std::wstring hudlessRequestPath;
unsigned long long hudlessRequest = 0, hudlessRequestServed = 0, hudlessRequestAttempted = 0, hudlessViewRequest = 0;
int hudlessRequestPollFrame = -1;
std::mutex logMutex;
std::wstring dataDirectory, runtimeDirectory;
}

void le::Log(const char* format, ...) {
    std::lock_guard<std::mutex> guard(logMutex);
    FILE* file = nullptr;
    _wfopen_s(&file, (dataDirectory + L"\\native.log").c_str(), L"ab");
    if (!file) return;
    SYSTEMTIME time{};
    GetLocalTime(&time);
    fprintf(file, "%02u:%02u:%02u.%03u [LE] ", time.wHour, time.wMinute, time.wSecond, time.wMilliseconds);
    va_list args;
    va_start(args, format);
    vfprintf(file, format, args);
    va_end(args);
    fputc('\n', file);
    fclose(file);
}

namespace {
using le::Log;

int SafePresentationQuery(PresentationDiagnostics* output) {
    __try { return backend::QueryPresentation(*output); }
    __except (EXCEPTION_EXECUTE_HANDLER) { return -10; }
}
void ReportPresentation() {
    if (presentationQueryFailed) return;
    PresentationDiagnostics next{sizeof(PresentationDiagnostics), 1};
    int result = SafePresentationQuery(&next);
    if (result == 1 && (next.size != sizeof(next) || next.version != 1)) result = -11;
    if (result == -10 || result == -11) {
        presentationQueryFailed = true;
        Log("Optional presentation telemetry disabled result=%d; reconstruction remains enabled.", result);
    }
    std::lock_guard<std::mutex> guard(presentationMutex);
    presentationResult = result;
    presentationSnapshot = next;
}

// A C++ catch does not catch bad COM pointers under /EHsc. These small functions
// keep SEH outside scopes containing C++ destructors and fail closed on stale RTs.
bool SafeAddRef(ID3D11Resource* resource) {
    __try { resource->AddRef(); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
void SafeRelease(ID3D11Resource* resource) {
    if (!resource) return;
    __try { resource->Release(); }
    __except (EXCEPTION_EXECUTE_HANDLER) {}
}
bool DescribeGuarded(ID3D11Resource* resource, D3D11_TEXTURE2D_DESC* desc) {
    ID3D11Texture2D* texture = nullptr;
    __try {
        if (!resource || FAILED(resource->QueryInterface(__uuidof(ID3D11Texture2D), reinterpret_cast<void**>(&texture)))) return false;
        texture->GetDesc(desc);
        texture->Release();
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

bool Describe(ID3D11Resource* resource, D3D11_TEXTURE2D_DESC& desc) {
    if (!DescribeGuarded(resource, &desc)) return false;
    return desc.Width && desc.Height && desc.Width <= 16384 && desc.Height <= 16384 &&
        desc.ArraySize == 1 && desc.SampleDesc.Count == 1;
}

// Unity may replay a camera command buffer. Its event data must therefore be an
// opaque consume-once token, not a freed Frame address that could be reused.
struct HudlessPacket { int cameraId, frameIndex; ID3D11Resource* color; };
struct PendingFrames {
    std::mutex mutex;
    std::unordered_map<std::uintptr_t, std::unique_ptr<Frame>> frames;
    std::unordered_map<std::uintptr_t, std::unique_ptr<HudlessPacket>> hudless;
    std::uintptr_t next = 1;
};
PendingFrames& Pending() { static auto* pending = new PendingFrames(); return *pending; }
std::unique_ptr<Frame> TakeFrame(void* token) {
    auto& pending = Pending();
    std::lock_guard<std::mutex> guard(pending.mutex);
    auto it = pending.frames.find(reinterpret_cast<std::uintptr_t>(token));
    if (it == pending.frames.end()) return {};
    auto frame = std::move(it->second);
    pending.frames.erase(it);
    return frame;
}
std::unique_ptr<HudlessPacket> TakeHudless(void* token) {
    auto& pending = Pending();
    std::lock_guard<std::mutex> guard(pending.mutex);
    auto it = pending.hudless.find(reinterpret_cast<std::uintptr_t>(token));
    if (it == pending.hudless.end()) return {};
    auto frame = std::move(it->second);
    pending.hudless.erase(it);
    return frame;
}

bool DepthFormat(DXGI_FORMAT format) {
    switch (format) {
    case DXGI_FORMAT_R32_FLOAT: case DXGI_FORMAT_R32_TYPELESS: case DXGI_FORMAT_D32_FLOAT:
    case DXGI_FORMAT_R16_UNORM: case DXGI_FORMAT_R16_TYPELESS: case DXGI_FORMAT_D16_UNORM:
    case DXGI_FORMAT_D24_UNORM_S8_UINT: case DXGI_FORMAT_R24G8_TYPELESS: case DXGI_FORMAT_R24_UNORM_X8_TYPELESS:
    case DXGI_FORMAT_D32_FLOAT_S8X24_UINT: case DXGI_FORMAT_R32G8X24_TYPELESS: case DXGI_FORMAT_R32_FLOAT_X8X24_TYPELESS:
        return true;
    default: return false;
    }
}

struct State {
    ComPtr<ID3D11Device> device;
    ComPtr<ID3D11DeviceContext> context;
    ComPtr<ID3D11DeviceContext1> context1;
    ComPtr<ID3DDeviceContextState> pluginState;
    ComPtr<ID3DDeviceContextState> savedState;
    int width = 0, height = 0, outWidth = 0, outHeight = 0, cameraId = 0, epoch = -1, lastFrame = -1;
    unsigned flags = 0;
    int quality = -1, preset = -1;
    unsigned long long evaluations = 0;
    unsigned long long hudlessToken = 0;
    int hudlessCameraId = 0, hudlessFrame = -1;
    bool initialized = false, verified = false;
    int lastInputProbe = -1;
};

// The engine owns the process lifetime. Explicit GPU-idle teardown is used for feature recreation.
// Avoid calling graphics/NGX APIs from a DLL destructor after Unity has destroyed its device.
State& Engine() { static State* state = new State(); return *state; }

bool WaitGpu(State& state) {
    D3D11_QUERY_DESC desc{D3D11_QUERY_EVENT, 0};
    ComPtr<ID3D11Query> query;
    if (FAILED(state.device->CreateQuery(&desc, &query))) return false;
    state.context->End(query.Get());
    state.context->Flush();
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
    for (;;) {
        BOOL complete = FALSE;
        const HRESULT result = state.context->GetData(query.Get(), &complete, sizeof(complete), 0);
        if (FAILED(result)) return false;
        if (result == S_OK && complete) return true;
        if (std::chrono::steady_clock::now() >= deadline) return false;
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
}

struct RestoreContext {
    State& state;
    explicit RestoreContext(State& value) : state(value) {
        state.context1->SwapDeviceContextState(state.pluginState.Get(), &state.savedState);
    }
    ~RestoreContext() {
        state.context1->SwapDeviceContextState(state.savedState.Get(), nullptr);
        state.savedState.Reset();
    }
};

bool BindDevice(State& state, ID3D11Resource* color) {
    ComPtr<ID3D11Device> device;
    color->GetDevice(&device);
    if (!device) return false;
    if (state.device) return device.Get() == state.device.Get();
    // Commit nothing until every interface and the saved context state exist, so a retry
    // after a partial failure rebinds instead of evaluating without context restoration.
    ComPtr<ID3D11DeviceContext> context;
    device->GetImmediateContext(&context);
    ComPtr<ID3D11Device1> device1;
    ComPtr<ID3D11DeviceContext1> context1;
    if (!context || FAILED(device.As(&device1)) || FAILED(context.As(&context1))) return false;
    D3D_FEATURE_LEVEL level = device->GetFeatureLevel(), selected{};
    ComPtr<ID3DDeviceContextState> pluginState;
    HRESULT result = device1->CreateDeviceContextState(0, &level, 1, D3D11_SDK_VERSION,
        __uuidof(ID3D11Device), &selected, &pluginState);
    if (FAILED(result) || !pluginState) { Log("Context-state creation failed: 0x%08x", unsigned(result)); return false; }
    state.device = device;
    state.context = context;
    state.context1 = context1;
    state.pluginState = pluginState;
    return true;
}

bool InitializeBackend(State& state) {
    if (state.initialized) return true;
    // The backend initializes once per device; a retry only repeats the steps that failed before.
    state.initialized = backend::Initialize(state.device.Get(), dataDirectory, runtimeDirectory);
    return state.initialized;
}

bool EnsureFeature(State& state, const Frame& frame, const D3D11_TEXTURE2D_DESC& color,
                   const D3D11_TEXTURE2D_DESC& motion) {
    unsigned flags = le::FlagAutoExposure;
    if (frame.reversedDepth) flags |= le::FlagDepthInverted;
    if (motion.Width <= unsigned(frame.renderWidth) && motion.Height <= unsigned(frame.renderHeight))
        flags |= le::FlagMVLowRes;
    if (color.Format == DXGI_FORMAT_R16G16B16A16_FLOAT || color.Format == DXGI_FORMAT_R16G16B16A16_TYPELESS ||
        color.Format == DXGI_FORMAT_R11G11B10_FLOAT || color.Format == DXGI_FORMAT_R32G32B32A32_FLOAT ||
        color.Format == DXGI_FORMAT_R32G32B32A32_TYPELESS) flags |= le::FlagIsHDR;
    if (backend::HasFeature() && state.width == frame.renderWidth && state.height == frame.renderHeight &&
        state.outWidth == frame.outputWidth && state.outHeight == frame.outputHeight && state.flags == flags &&
        state.quality == frame.quality && state.preset == frame.preset) return true;
    if (backend::HasFeature()) {
        if (!WaitGpu(state)) { Log("Feature resize abandoned: GPU completion not confirmed."); return false; }
        backend::Release();
    }
    const le::CreateInputs create{unsigned(frame.renderWidth), unsigned(frame.renderHeight),
        unsigned(frame.outputWidth), unsigned(frame.outputHeight), frame.quality, frame.preset, flags};
    if (!backend::Create(state.context.Get(), create)) return false;
    state.width = frame.renderWidth; state.height = frame.renderHeight;
    state.outWidth = frame.outputWidth; state.outHeight = frame.outputHeight; state.flags = flags;
    state.quality = frame.quality; state.preset = frame.preset;
    state.lastFrame = -1; state.verified = false;
    return true;
}

ComPtr<ID3D11Texture2D> Capture(State& state, ID3D11Resource* resource) {
    D3D11_TEXTURE2D_DESC desc{};
    if (!Describe(resource, desc)) return {};
    desc.BindFlags = 0; desc.MiscFlags = 0; desc.Usage = D3D11_USAGE_STAGING; desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    ComPtr<ID3D11Texture2D> texture;
    if (SUCCEEDED(state.device->CreateTexture2D(&desc, nullptr, &texture)))
        state.context->CopyResource(texture.Get(), resource);
    return texture;
}

float HalfFloat(unsigned short bits) {
    const unsigned sign = unsigned(bits & 0x8000) << 16;
    unsigned exponent = (bits >> 10) & 31, mantissa = bits & 1023, value;
    if (!exponent) {
        if (!mantissa) value = sign;
        else {
            int shift = 0;
            while (!(mantissa & 1024)) { mantissa <<= 1; ++shift; }
            value = sign | (unsigned(113 - shift) << 23) | ((mantissa & 1023) << 13);
        }
    } else if (exponent == 31) value = sign | 0x7f800000 | (mantissa << 13);
    else value = sign | ((exponent + 112) << 23) | (mantissa << 13);
    float output;
    memcpy(&output, &value, sizeof(output));
    return output;
}

void InspectSamples(State& state, ID3D11Resource* resource, const char* label) {
    D3D11_TEXTURE2D_DESC desc{};
    if (!Describe(resource, desc)) return;
    unsigned bytesPerPixel = 0, channels = 1;
    bool half = false, normalized8 = false, normalized16 = false, packedDepth = false;
    switch (desc.Format) {
    case DXGI_FORMAT_R16_FLOAT: bytesPerPixel = 2; half = true; break;
    case DXGI_FORMAT_R16_UNORM: case DXGI_FORMAT_D16_UNORM:
    case DXGI_FORMAT_R16_TYPELESS: bytesPerPixel = 2; normalized16 = true; break;
    case DXGI_FORMAT_R16G16_FLOAT: case DXGI_FORMAT_R16G16_TYPELESS:
        bytesPerPixel = 4; channels = 2; half = true; break;
    case DXGI_FORMAT_R32_FLOAT: case DXGI_FORMAT_R32_TYPELESS:
    case DXGI_FORMAT_D32_FLOAT: bytesPerPixel = 4; break;
    case DXGI_FORMAT_R32G32_FLOAT: case DXGI_FORMAT_R32G32_TYPELESS:
        bytesPerPixel = 8; channels = 2; break;
    case DXGI_FORMAT_R16G16B16A16_FLOAT: case DXGI_FORMAT_R16G16B16A16_TYPELESS:
        bytesPerPixel = 8; channels = 3; half = true; break;
    case DXGI_FORMAT_R32G32B32A32_FLOAT: case DXGI_FORMAT_R32G32B32A32_TYPELESS:
        bytesPerPixel = 16; channels = 3; break;
    case DXGI_FORMAT_R8G8B8A8_UNORM: case DXGI_FORMAT_R8G8B8A8_UNORM_SRGB: case DXGI_FORMAT_R8G8B8A8_TYPELESS:
    case DXGI_FORMAT_B8G8R8A8_UNORM: case DXGI_FORMAT_B8G8R8A8_UNORM_SRGB: case DXGI_FORMAT_B8G8R8A8_TYPELESS:
        bytesPerPixel = 4; channels = 3; normalized8 = true; break;
    case DXGI_FORMAT_D32_FLOAT_S8X24_UINT: case DXGI_FORMAT_R32G8X24_TYPELESS:
    case DXGI_FORMAT_R32_FLOAT_X8X24_TYPELESS: bytesPerPixel = 8; break;
    case DXGI_FORMAT_D24_UNORM_S8_UINT: case DXGI_FORMAT_R24G8_TYPELESS:
    case DXGI_FORMAT_R24_UNORM_X8_TYPELESS: bytesPerPixel = 4; packedDepth = true; break;
    default: Log("%s sample inspection unavailable for format=%u", label, unsigned(desc.Format)); return;
    }
    auto capture = Capture(state, resource);
    if (!capture) return;
    D3D11_MAPPED_SUBRESOURCE mapped{};
    const HRESULT result = state.context->Map(capture.Get(), 0, D3D11_MAP_READ, 0, &mapped);
    if (FAILED(result)) { Log("%s readback failed HRESULT=0x%08x", label, unsigned(result)); return; }
    double total = 0;
    float minimum = std::numeric_limits<float>::infinity(), maximum = -minimum;
    size_t finite = 0, invalid = 0, nonzero = 0;
    unsigned long long hash = 14695981039346656037ull;
    const unsigned stepX = (desc.Width / 64u) ? desc.Width / 64u : 1u;
    const unsigned stepY = (desc.Height / 64u) ? desc.Height / 64u : 1u;
    for (unsigned y = 0; y < desc.Height; y += stepY) {
        auto* row = static_cast<const unsigned char*>(mapped.pData) + size_t(y) * mapped.RowPitch;
        for (unsigned x = 0; x < desc.Width; x += stepX) {
            const auto* pixel = row + size_t(x) * bytesPerPixel;
            for (unsigned byte = 0; byte < bytesPerPixel; ++byte) { hash ^= pixel[byte]; hash *= 1099511628211ull; }
            for (unsigned channel = 0; channel < channels; ++channel) {
                float value = 0;
                if (half) { unsigned short bits; memcpy(&bits, pixel + channel * 2, 2); value = HalfFloat(bits); }
                else if (normalized8) value = float(pixel[channel]) / 255.0f;
                else if (normalized16) { unsigned short bits; memcpy(&bits, pixel, 2); value = float(bits) / 65535.0f; }
                else if (packedDepth) { unsigned bits; memcpy(&bits, pixel, 4); value = float(bits & 0xffffffu) / 16777215.0f; }
                else memcpy(&value, pixel + channel * 4, 4);
                if (!std::isfinite(value)) { ++invalid; continue; }
                minimum = (std::min)(minimum, value); maximum = (std::max)(maximum, value);
                total += std::abs(value); ++finite;
                if (std::abs(value) > 0.000001f) ++nonzero;
            }
        }
    }
    state.context->Unmap(capture.Get(), 0);
    Log("%s sampled evidence size=%ux%u format=%u finite=%zu invalid=%zu nonzero=%zu min=%.8g max=%.8g meanAbs=%.8g hash=%016llx",
        label, desc.Width, desc.Height, unsigned(desc.Format), finite, invalid, nonzero,
        finite ? minimum : 0, finite ? maximum : 0, finite ? total / double(finite) : 0, hash);
}

bool HudlessEvidenceDue(const State& state, int frameIndex) {
    if (!dumpHudlessImages || hudlessImageCount >= 4) return false;
    if (!hudlessRequestPath.empty()) {
        if (hudlessRequestPollFrame < 0 || frameIndex - hudlessRequestPollFrame >= 60) {
            hudlessRequestPollFrame = frameIndex;
            WIN32_FILE_ATTRIBUTE_DATA attributes{};
            if (GetFileAttributesExW(hudlessRequestPath.c_str(), GetFileExInfoStandard, &attributes) &&
                !(attributes.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY))
                hudlessRequest = (static_cast<unsigned long long>(attributes.ftLastWriteTime.dwHighDateTime) << 32) | attributes.ftLastWriteTime.dwLowDateTime;
        }
        return hudlessRequest && hudlessRequest != hudlessRequestServed &&
            (hudlessRequest != hudlessRequestAttempted || frameIndex - hudlessImageAttemptFrame >= 300);
    }
    return hudlessImageEpoch != state.epoch &&
        (hudlessImageAttemptEpoch != state.epoch || frameIndex - hudlessImageAttemptFrame >= 300);
}
void DumpHudlessEvidence(State& state, ID3D11Texture2D* texture, int frameIndex) {
    if (!HudlessEvidenceDue(state, frameIndex)) return;
    hudlessImageAttemptEpoch = state.epoch; hudlessImageAttemptFrame = frameIndex;
    hudlessRequestAttempted = hudlessRequest;
    D3D11_TEXTURE2D_DESC desc{};
    texture->GetDesc(&desc);
    const bool rgba = desc.Format == DXGI_FORMAT_R8G8B8A8_TYPELESS || desc.Format == DXGI_FORMAT_R8G8B8A8_UNORM || desc.Format == DXGI_FORMAT_R8G8B8A8_UNORM_SRGB;
    const bool bgra = desc.Format == DXGI_FORMAT_B8G8R8A8_TYPELESS || desc.Format == DXGI_FORMAT_B8G8R8A8_UNORM || desc.Format == DXGI_FORMAT_B8G8R8A8_UNORM_SRGB;
    if (!rgba && !bgra) return;
    auto staging = Capture(state, texture);
    if (!staging) return;
    std::vector<unsigned char> row(size_t(desc.Width) * 4);
    D3D11_MAPPED_SUBRESOURCE mapped{};
    if (FAILED(state.context->Map(staging.Get(), 0, D3D11_MAP_READ, 0, &mapped))) return;
    struct UnmapOnExit {
        ID3D11DeviceContext* context;
        ID3D11Resource* resource;
        ~UnmapOnExit() { context->Unmap(resource, 0); }
    } unmap{state.context.Get(), staging.Get()};
    bool visible = false;
    for (unsigned y = 0; y < desc.Height && !visible; y += (std::max)(1u, desc.Height / 32))
        for (unsigned x = 0; x < desc.Width; x += (std::max)(1u, desc.Width / 32)) {
            const auto* pixel = static_cast<const unsigned char*>(mapped.pData) + size_t(y) * mapped.RowPitch + x * 4;
            if (pixel[0] > 16 || pixel[1] > 16 || pixel[2] > 16) { visible = true; break; }
        }
    if (!visible) return;
    const auto path = dataDirectory + L"\\hudless-" + std::to_wstring(GetCurrentProcessId()) +
        L"-epoch" + std::to_wstring(state.epoch) + L"-frame" + std::to_wstring(frameIndex) + L".bmp";
    FILE* file = nullptr;
    _wfopen_s(&file, path.c_str(), L"wb");
    std::unique_ptr<FILE, decltype(&fclose)> closeFile(file, &fclose);
    bool written = false;
    if (file) {
        BITMAPFILEHEADER header{};
        BITMAPINFOHEADER info{};
        header.bfType = 0x4d42;
        header.bfOffBits = sizeof(header) + sizeof(info);
        header.bfSize = header.bfOffBits + desc.Width * desc.Height * 4;
        info.biSize = sizeof(info); info.biWidth = LONG(desc.Width); info.biHeight = -LONG(desc.Height);
        info.biPlanes = 1; info.biBitCount = 32; info.biCompression = BI_RGB;
        info.biSizeImage = desc.Width * desc.Height * 4;
        written = fwrite(&header, sizeof(header), 1, file) == 1 && fwrite(&info, sizeof(info), 1, file) == 1;
        for (unsigned y = 0; written && y < desc.Height; ++y) {
            const auto* source = static_cast<const unsigned char*>(mapped.pData) + size_t(y) * mapped.RowPitch;
            for (unsigned x = 0; x < desc.Width; ++x) {
                row[x * 4] = source[x * 4 + (rgba ? 2 : 0)];
                row[x * 4 + 1] = source[x * 4 + 1];
                row[x * 4 + 2] = source[x * 4 + (rgba ? 0 : 2)];
                row[x * 4 + 3] = 255;
            }
            written = fwrite(row.data(), row.size(), 1, file) == 1;
        }
        if (fclose(closeFile.release()) != 0) written = false;
    }
    if (written) {
        ++hudlessImageCount; hudlessImageEpoch = state.epoch;
        hudlessRequestServed = hudlessRequest;
        Log("HUDless raw storage evidence saved: %ls; %ux%u format=%u, top-row-first, no gamma or orientation correction; image %u/4",
            path.c_str(), desc.Width, desc.Height, unsigned(desc.Format), hudlessImageCount);
    } else {
        dumpHudlessImages = false;
        Log("Optional HUDless image evidence could not be written; further image dumps disabled.");
    }
}

void Verify(State& state, ID3D11Texture2D* before, ID3D11Texture2D* after) {
    D3D11_MAPPED_SUBRESOURCE a{}, b{};
    if (FAILED(state.context->Map(before, 0, D3D11_MAP_READ, 0, &a))) return;
    if (FAILED(state.context->Map(after, 0, D3D11_MAP_READ, 0, &b))) { state.context->Unmap(before, 0); return; }
    double absolute = 0; size_t count = 0, changed = 0;
    for (int y = 0; y < state.outHeight; y += 8) {
        const auto* rowA = reinterpret_cast<const unsigned short*>(static_cast<const char*>(a.pData) + size_t(y) * a.RowPitch);
        const auto* rowB = reinterpret_cast<const unsigned short*>(static_cast<const char*>(b.pData) + size_t(y) * b.RowPitch);
        for (int x = 0; x < state.outWidth; x += 8) for (int channel = 0; channel < 3; ++channel) {
            const float delta = std::abs(HalfFloat(rowA[x * 4 + channel]) - HalfFloat(rowB[x * 4 + channel]));
            if (!std::isfinite(delta)) continue;
            absolute += delta; ++count; if (delta > 0.0001f) ++changed;
        }
    }
    state.context->Unmap(before, 0); state.context->Unmap(after, 0);
    Log("A/B pixel evidence: %s versus bilinear, samples=%zu changed=%zu mean_absolute_linear_RGB_difference=%.8f",
        backend::Name(), count, changed, count ? absolute / double(count) : 0);
    state.verified = true;
}

void Evaluate(Frame& frame) {
    verifyReadbacks = frame.verify != 0;
    auto& state = Engine();
    state.hudlessToken = 0;
    D3D11_TEXTURE2D_DESC color{}, depth{}, motion{}, output{};
    if (!Describe(frame.color, color) || !Describe(frame.depth, depth) || !Describe(frame.motion, motion) || !Describe(frame.output, output)) {
        Log("Rejected missing or unsupported texture contract."); status = -1; return;
    }
    if (!DepthFormat(depth.Format) ||
        (motion.Format != DXGI_FORMAT_R16G16_FLOAT && motion.Format != DXGI_FORMAT_R16G16_TYPELESS &&
         motion.Format != DXGI_FORMAT_R32G32_FLOAT && motion.Format != DXGI_FORMAT_R32G32_TYPELESS)) {
        Log("Rejected depth/motion formats: depth=%u motion=%u", unsigned(depth.Format), unsigned(motion.Format));
        status = -1; return;
    }
    if (frame.frameIndex % 300 == 0 || status == 0) {
        Log("Unity texture contract frame=%d mode=%d color=%ux%u fmt=%u depth=%ux%u fmt=%u motion=%ux%u fmt=%u output=%ux%u fmt=%u jitter=(%.5f,%.5f) MVscale=(%.1f,%.1f)",
            frame.frameIndex, frame.mode, color.Width, color.Height, unsigned(color.Format), depth.Width, depth.Height,
            unsigned(depth.Format), motion.Width, motion.Height, unsigned(motion.Format), output.Width, output.Height,
            unsigned(output.Format), frame.jitterX, frame.jitterY,
            frame.motionScaleX, frame.motionScaleY);
    }
    if (status < 0 && frame.mode != 0) return;
    if (color.Width != unsigned(frame.renderWidth) || color.Height != unsigned(frame.renderHeight) ||
        output.Width != unsigned(frame.outputWidth) || output.Height != unsigned(frame.outputHeight) ||
        (output.Format != DXGI_FORMAT_R16G16B16A16_FLOAT && output.Format != DXGI_FORMAT_R16G16B16A16_TYPELESS)) {
        Log("Rejected colour/output contract: colour=%ux%u expected=%dx%d output=%ux%u fmt=%u array=%u samples=%u expected=%dx%d.",
            color.Width, color.Height, frame.renderWidth, frame.renderHeight, output.Width, output.Height,
            unsigned(output.Format), output.ArraySize, output.SampleDesc.Count, frame.outputWidth, frame.outputHeight);
        status = -1; return;
    }
    if (!BindDevice(state, frame.color)) { Log("D3D11 device/context binding failed."); status = -6; return; }
    for (auto* resource : {frame.depth, frame.motion, frame.output}) {
        ComPtr<ID3D11Device> resourceDevice;
        resource->GetDevice(&resourceDevice);
        if (resourceDevice.Get() != state.device.Get()) { Log("Texture belongs to a different D3D11 device; rejected."); status = -6; return; }
    }
    if ((motion.Width != unsigned(frame.renderWidth) || motion.Height != unsigned(frame.renderHeight)) &&
        (motion.Width != unsigned(frame.outputWidth) || motion.Height != unsigned(frame.outputHeight))) {
        Log("Motion extent is neither render size nor output size; rejected."); status = -1; return;
    }
    if ((depth.Width != unsigned(frame.renderWidth) || depth.Height != unsigned(frame.renderHeight)) &&
        (depth.Width != unsigned(frame.outputWidth) || depth.Height != unsigned(frame.outputHeight))) {
        Log("Depth extent is neither render size nor output size; rejected."); status = -1; return;
    }
    RestoreContext restore(state);
    const bool samplePixels = frame.verify && (state.lastInputProbe < 0 || frame.frameIndex - state.lastInputProbe >= 300);
    if (samplePixels) {
        InspectSamples(state, frame.depth, "depth");
        InspectSamples(state, frame.motion, "motion");
        InspectSamples(state, frame.color, "scene RGB input");
        state.lastInputProbe = frame.frameIndex;
    }
    if (frame.mode == 0) { if (samplePixels) InspectSamples(state, frame.output, "spatial fallback RGB"); status = 1; return; }
    if (!InitializeBackend(state)) { status = -3; return; }
    if (!EnsureFeature(state, frame, color, motion)) { status = -4; return; }
    if (frame.mode == 2) { state.lastFrame = -1; status = 3; return; }
    const bool verify = frame.verify && !state.verified && state.evaluations >= 30;
    auto before = verify ? Capture(state, frame.output) : ComPtr<ID3D11Texture2D>{};
    le::EvaluateInputs evaluate{};
    evaluate.color = frame.color; evaluate.output = frame.output;
    evaluate.depth = frame.depth; evaluate.motion = frame.motion;
    evaluate.jitterX = frame.jitterX; evaluate.jitterY = frame.jitterY;
    evaluate.motionScaleX = frame.motionScaleX; evaluate.motionScaleY = frame.motionScaleY;
    evaluate.renderWidth = unsigned(frame.renderWidth); evaluate.renderHeight = unsigned(frame.renderHeight);
    evaluate.reset = state.lastFrame < 0 || state.cameraId != frame.cameraId || state.epoch != frame.historyEpoch || frame.frameIndex > state.lastFrame + 1;
    evaluate.cameraNear = frame.reversedDepth ? frame.cameraFar : frame.cameraNear;
    evaluate.cameraFar = frame.reversedDepth ? frame.cameraNear : frame.cameraFar;
    evaluate.cameraFov = frame.cameraFov;
    evaluate.deltaMilliseconds = frame.deltaMilliseconds;
    unsigned result = 0;
    if (!backend::Evaluate(state.context.Get(), evaluate, result)) {
        Log("%s EvaluateFeature failed result=0x%08x", backend::Name(), result); status = -5; return;
    }
    // Capture on this render thread immediately after the matching SR call.
    state.hudlessToken = backend::HudlessFrameToken();
    state.hudlessCameraId = frame.cameraId;
    state.hudlessFrame = frame.frameIndex;
    if (state.hudlessToken) ++hudlessCaptured;
    if (samplePixels) InspectSamples(state, frame.output, "reconstructed RGB output");
    ++state.evaluations;
    evaluationCount.store(state.evaluations);
    state.lastFrame = frame.frameIndex; state.cameraId = frame.cameraId; state.epoch = frame.historyEpoch;
    if (state.evaluations == 1 || state.evaluations % 300 == 0) {
        Log("%s EvaluateFeature succeeded result=0x%08x evaluations=%llu reset=%d", backend::Name(), result,
            state.evaluations, evaluate.reset);
        Log("Camera inputs near=%.4f far=%.1f verticalFovRadians=%.5f", frame.cameraNear, frame.cameraFar, frame.cameraFov);
        backend::ReportFrameGeneration(state.evaluations);
        ReportPresentation();
    }
    if (before) { auto after = Capture(state, frame.output); if (after) Verify(state, before.Get(), after.Get()); }
    status = 2;
}

bool EvaluateGuarded(Frame* frame) {
    __try { Evaluate(*frame); return true; }
    __except (GetExceptionCode() == EXCEPTION_ACCESS_VIOLATION || GetExceptionCode() == EXCEPTION_IN_PAGE_ERROR
        ? EXCEPTION_EXECUTE_HANDLER : EXCEPTION_CONTINUE_SEARCH) { return false; }
}

void EvaluateHudless(const HudlessPacket& packet) {
    auto& state = Engine();
    int result = 0;
    if (backend::HudlessVersion() == 1) {
        if (!state.hudlessToken || state.hudlessCameraId != packet.cameraId || state.hudlessFrame != packet.frameIndex) result = -100;
        else {
            D3D11_TEXTURE2D_DESC desc{};
            if (!Describe(packet.color, desc) || desc.Width != unsigned(state.outWidth) || desc.Height != unsigned(state.outHeight) ||
                (desc.Format != DXGI_FORMAT_R8G8B8A8_TYPELESS && desc.Format != DXGI_FORMAT_R8G8B8A8_UNORM &&
                 desc.Format != DXGI_FORMAT_R8G8B8A8_UNORM_SRGB && desc.Format != DXGI_FORMAT_B8G8R8A8_TYPELESS &&
                 desc.Format != DXGI_FORMAT_B8G8R8A8_UNORM && desc.Format != DXGI_FORMAT_B8G8R8A8_UNORM_SRGB)) result = -101;
            else {
                ComPtr<ID3D11Device> device;
                packet.color->GetDevice(&device);
                if (device.Get() != state.device.Get()) result = -8;
                else {
                    ComPtr<ID3D11Texture2D> texture;
                    if (FAILED(packet.color->QueryInterface(IID_PPV_ARGS(&texture)))) result = -4;
                    else {
                        const bool inspect = verifyReadbacks && (hudlessReadbackFrame < 0 || packet.frameIndex - hudlessReadbackFrame >= 300);
                        if (inspect) hudlessReadbackFrame = packet.frameIndex;
                        if (inspect || (HudlessEvidenceDue(state, packet.frameIndex) &&
                            (hudlessViewEpoch != state.epoch || packet.frameIndex - hudlessViewFrame >= 300 || hudlessViewRequest != hudlessRequest))) {
                            hudlessViewEpoch = state.epoch; hudlessViewFrame = packet.frameIndex;
                            hudlessViewRequest = hudlessRequest;
                            ComPtr<ID3D11RenderTargetView> view;
                            state.context->OMGetRenderTargets(1, &view, nullptr);
                            if (view) {
                                D3D11_RENDER_TARGET_VIEW_DESC viewDesc{}; view->GetDesc(&viewDesc);
                                ComPtr<ID3D11Resource> bound; view->GetResource(&bound);
                                ComPtr<IUnknown> boundId, captureId;
                                bound->QueryInterface(IID_PPV_ARGS(&boundId)); texture->QueryInterface(IID_PPV_ARGS(&captureId));
                                Log("HUDless capture RTV camera=%d frame=%d format=%u boundMatchesCapture=%d; SDR Linear-project encoding expects SRGB view 29/91",
                                    packet.cameraId, packet.frameIndex, unsigned(viewDesc.Format), boundId.Get() == captureId.Get());
                            }
                        }
                        RestoreContext restore(state);
                        if (inspect)
                            InspectSamples(state, texture.Get(), "encoded HUDless RGB");
                        const auto token = state.hudlessToken;
                        state.hudlessToken = 0;
                        result = backend::SubmitHudless(state.context.Get(), texture.Get(), token);
                        if (result == 1) {
                            try { DumpHudlessEvidence(state, texture.Get(), packet.frameIndex); }
                            catch (...) { dumpHudlessImages = false; Log("Optional HUDless image evidence failed; further dumps disabled."); }
                        }
                    }
                }
            }
        }
    }
    hudlessResult = result;
    if (result == 1) {
        const auto count = ++hudlessAccepted;
        if (count == 1 || count % 300 == 0) Log("Late HUDless accepted camera=%d frame=%d submissions=%llu", packet.cameraId, packet.frameIndex, count);
    } else if (result < 0) {
        const auto count = ++hudlessRejected;
        if (count <= 3 || count % 300 == 0) Log("Late HUDless rejected result=%d camera=%d frame=%d rejected=%llu", result, packet.cameraId, packet.frameIndex, count);
    }
}
bool EvaluateHudlessGuarded(HudlessPacket* packet) {
    __try { EvaluateHudless(*packet); return true; }
    __except (GetExceptionCode() == EXCEPTION_ACCESS_VIOLATION || GetExceptionCode() == EXCEPTION_IN_PAGE_ERROR
        ? EXCEPTION_EXECUTE_HANDLER : EXCEPTION_CONTINUE_SEARCH) { return false; }
}
void InspectFinalColor(const HudlessPacket& packet) {
    auto& state = Engine();
    if (!BindDevice(state, packet.color)) return;
    ComPtr<ID3D11RenderTargetView> boundView;
    ComPtr<ID3D11Resource> boundColor;
    ComPtr<IUnknown> sourceIdentity, boundIdentity;
    packet.color->QueryInterface(IID_PPV_ARGS(&sourceIdentity));
    state.context->OMGetRenderTargets(1, &boundView, nullptr);
    if (boundView) {
        D3D11_RENDER_TARGET_VIEW_DESC viewDesc{};
        boundView->GetDesc(&viewDesc);
        boundView->GetResource(&boundColor);
        if (boundColor) boundColor->QueryInterface(IID_PPV_ARGS(&boundIdentity));
        Log("Color-probe bound RTV format=%u (SDR SRGB expected 29 or 91 in a Linear project)", unsigned(viewDesc.Format));
    }
    Log("Color-probe resource identity camera=%d frame=%d sourceIUnknown=%p boundIUnknown=%p sourceInterface=%p boundInterface=%p",
        packet.cameraId, packet.frameIndex, static_cast<void*>(sourceIdentity.Get()), static_cast<void*>(boundIdentity.Get()),
        static_cast<void*>(packet.color), static_cast<void*>(boundColor.Get()));
    RestoreContext restore(state);
    Log("Postprocess color probe camera=%d frame=%d", packet.cameraId, packet.frameIndex);
    InspectSamples(state, packet.color, "postprocess RGB final");
    if (boundColor) InspectSamples(state, boundColor.Get(), "currently bound color RGB");
}
bool InspectFinalColorGuarded(HudlessPacket* packet) {
    __try { InspectFinalColor(*packet); return true; }
    __except (GetExceptionCode() == EXCEPTION_ACCESS_VIOLATION || GetExceptionCode() == EXCEPTION_IN_PAGE_ERROR
        ? EXCEPTION_EXECUTE_HANDLER : EXCEPTION_CONTINUE_SEARCH) { return false; }
}

void RecoverContextAfterFault() {
    // SEH under /EHsc may skip C++ stack cleanup. Restore any saved host context
    // explicitly before disabling further work for the lifetime of this process.
    State& state = Engine();
    __try {
        if (state.context1 && state.savedState) {
            state.context1->SwapDeviceContextState(state.savedState.Get(), nullptr);
            state.savedState.Reset();
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) {}
}

void __stdcall RenderEvent(int eventId, void* pointer) {
    if ((eventId == 2 || eventId == 3) && pointer) {
        auto packet = TakeHudless(pointer);
        if (!packet) return;
        if (!fatalError) {
            try {
                if (!(eventId == 2 ? EvaluateHudlessGuarded(packet.get()) : InspectFinalColorGuarded(packet.get()))) {
                    RecoverContextAfterFault(); fatalError = true; status = -7; hudlessResult = -10;
                    Log("Late HUDless native memory exception; restart required.");
                }
            } catch (...) { RecoverContextAfterFault(); fatalError = true; status = -7; hudlessResult = -10; }
        }
        SafeRelease(packet->color);
        return;
    }
    if (eventId != 1 || !pointer) return;
    auto frame = TakeFrame(pointer);
    if (!frame) return; // Replayed or cancelled event: never dereference its token.
    if (!fatalError) {
        if (retryRequested.exchange(false)) status = 0;
        try {
            if (!EvaluateGuarded(frame.get())) {
                RecoverContextAfterFault(); fatalError = true;
                Log("Invalid resource/backend memory access; bridge disabled. Restart required."); status = -7;
            }
        }
        catch (...) { RecoverContextAfterFault(); fatalError = true; Log("Unhandled native %s exception; integration disabled.", backend::Name()); status = -7; }
    }
    for (auto* resource : {frame->color, frame->depth, frame->motion, frame->output}) SafeRelease(resource);
}
}

extern "C" __declspec(dllexport) void LE_Initialize(const wchar_t* data, const wchar_t* runtime) {
    if (!data || !runtime || !*data || !*runtime) { status = -2; return; }
    dataDirectory = data; runtimeDirectory = runtime;
    wchar_t evidenceOption[8]{};
    dumpHudlessImages = GetEnvironmentVariableW(L"LE_DLSS_DUMP_HUDLESS", evidenceOption, 8) == 1 && evidenceOption[0] == L'1';
    DWORD requestLength = GetEnvironmentVariableW(L"LE_DLSS_HUDLESS_DUMP_REQUEST", nullptr, 0);
    if (requestLength > 1 && requestLength < 32768) {
        hudlessRequestPath.resize(requestLength);
        GetEnvironmentVariableW(L"LE_DLSS_HUDLESS_DUMP_REQUEST", hudlessRequestPath.data(), requestLength);
        hudlessRequestPath.resize(wcslen(hudlessRequestPath.c_str()));
    }
    if (dumpHudlessImages) {
        if (hudlessRequestPath.empty()) Log("Optional raw HUDless BMP evidence enabled: at most 4 nonblack images, one per history epoch.");
        else Log("Optional raw HUDless BMP evidence waits for marker creation/modification: %ls; max4 images, marker polled every60 camera frames.", hudlessRequestPath.c_str());
    }
    Log("Last Epoch rendering bridge 0.1.0 loaded; backend=%s; frame ABI=%zu", backend::Name(), sizeof(Frame));
    if (!backend::Attach(runtimeDirectory)) status = -2;
}
extern "C" __declspec(dllexport) int LE_FrameSize() { return sizeof(Frame); }
extern "C" __declspec(dllexport) int LE_Status() { return retryRequested.load() ? 0 : status.load(); }
// Re-entry happens on the render thread; callers never mutate backend/device state.
extern "C" __declspec(dllexport) void LE_RequestRetry() { if (!fatalError) retryRequested = true; }
extern "C" __declspec(dllexport) void* LE_GetRenderEvent() { return reinterpret_cast<void*>(&RenderEvent); }
extern "C" __declspec(dllexport) unsigned long long LE_Evaluations() { return evaluationCount.load(); }
extern "C" __declspec(dllexport) int LE_GetDiagnostics(NativeDiagnostics* output, int size) {
    if (!output || size != sizeof(NativeDiagnostics)) return 0;
    const auto backendStatus = backend::Status();
    *output = {1, sizeof(NativeDiagnostics), LE_Status(), int(backendStatus.flags), backendStatus.lastNgxResult,
        backendStatus.frameGenerationState, backendStatus.frameGenerationResult, backendStatus.frameGenerationFlags,
        backendStatus.presentedSinceSample, backendStatus.maxGeneratedPerRendered,
        evaluationCount.load(), queuedCount.load(), rejectedCount.load()};
    return 1;
}
extern "C" __declspec(dllexport) void LE_CancelQueuedFrame(Frame* queued) {
    auto frame = TakeFrame(queued);
    if (!frame) { auto late = TakeHudless(queued); if (late) SafeRelease(late->color); return; }
    for (auto* resource : {frame->color, frame->depth, frame->motion, frame->output}) SafeRelease(resource);
}
extern "C" __declspec(dllexport) Frame* LE_Queue(const Frame* input) {
    if (!input || input->abi != 3 || input->quality < 0 || input->quality > 5 || input->preset < 0 || input->preset > 13 ||
        input->mode < 0 || input->mode > 3 || input->renderWidth <= 0 || input->renderHeight <= 0 ||
        input->outputWidth < input->renderWidth || input->outputHeight < input->renderHeight ||
        input->outputWidth > 16384 || input->outputHeight > 16384 ||
        !std::isfinite(input->jitterX) || !std::isfinite(input->jitterY) ||
        !std::isfinite(input->motionScaleX) || !std::isfinite(input->motionScaleY) ||
        !std::isfinite(input->cameraNear) || !std::isfinite(input->cameraFar) ||
        input->cameraNear <= 0 || input->cameraFar <= input->cameraNear ||
        !std::isfinite(input->cameraFov) || input->cameraFov <= 0 || input->cameraFov >= 3.141593f ||
        !std::isfinite(input->deltaMilliseconds) || input->deltaMilliseconds <= 0 ||
        input->color == input->output || input->depth == input->output || input->motion == input->output ||
        !input->color || !input->depth || !input->motion || !input->output) { ++rejectedCount; return nullptr; }
    auto frame = std::make_unique<Frame>(*input);
    ID3D11Resource* resources[] = {frame->color, frame->depth, frame->motion, frame->output};
    for (int index = 0; index < 4; ++index) if (!SafeAddRef(resources[index])) {
        for (int retained = 0; retained < index; ++retained) SafeRelease(resources[retained]);
        ++rejectedCount; status = -1;
        Log("Rejected stale/unreadable texture pointer in queue (resource index=%d).", index);
        return nullptr;
    }
    auto& pending = Pending();
    try {
        std::lock_guard<std::mutex> guard(pending.mutex);
        if (pending.frames.size() + pending.hudless.size() >= 256 || pending.next == 0) {
            for (auto* resource : resources) SafeRelease(resource);
            ++rejectedCount; status = -1;
            Log("Event queue limit reached; a camera command buffer may not be executing.");
            return nullptr;
        }
        const auto token = pending.next++;
        pending.frames.emplace(token, std::move(frame));
        ++queuedCount;
        return reinterpret_cast<Frame*>(token);
    } catch (...) {
        for (auto* resource : resources) SafeRelease(resource);
        ++rejectedCount; status = -1;
        return nullptr;
    }
}
extern "C" __declspec(dllexport) unsigned LE_HudlessProviderVersion() { return backend::HudlessVersion(); }
extern "C" __declspec(dllexport) int LE_GetPresentationDiagnostics(PresentationDiagnostics* output, int size) {
    if (!output || size != sizeof(PresentationDiagnostics)) return -1;
    std::lock_guard<std::mutex> guard(presentationMutex);
    *output = presentationSnapshot;
    return presentationResult;
}
extern "C" __declspec(dllexport) int LE_GetHudlessDiagnostics(HudlessDiagnostics* output, int size) {
    if (!output || size != sizeof(HudlessDiagnostics)) return 0;
    *output = {1, sizeof(HudlessDiagnostics), int(backend::HudlessVersion()), hudlessResult.load(),
        hudlessCaptured.load(), hudlessAccepted.load(), hudlessRejected.load()};
    return 1;
}
extern "C" __declspec(dllexport) void* LE_QueueHudless(int cameraId, int frameIndex, ID3D11Resource* color) {
    if (!color || frameIndex < 0 || !SafeAddRef(color)) return nullptr;
    try {
        auto packet = std::make_unique<HudlessPacket>(HudlessPacket{cameraId, frameIndex, color});
        auto& pending = Pending();
        std::lock_guard<std::mutex> guard(pending.mutex);
        if (pending.frames.size() + pending.hudless.size() < 256 && pending.next != 0) {
            const auto token = pending.next++;
            pending.hudless.emplace(token, std::move(packet));
            return reinterpret_cast<void*>(token);
        }
    } catch (...) {}
    SafeRelease(color);
    return nullptr;
}
