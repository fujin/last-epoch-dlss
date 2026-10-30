// Frame wire layout adapted from Pseudogiant-xr/Big-Beautiful-Walk (Apache-2.0).
using System;
using System.Runtime.InteropServices;

namespace LastEpochGraphics;

[StructLayout(LayoutKind.Sequential, Pack = 8)]
internal struct Frame
{
    public int Abi, CameraId, FrameIndex, Mode;
    public IntPtr Color, Depth, Motion, Output;
    public int RenderWidth, RenderHeight, OutputWidth, OutputHeight;
    public float JitterX, JitterY, MotionScaleX, MotionScaleY;
    public int HistoryEpoch, Verify, ReversedDepth;
    public float CameraNear, CameraFar, CameraFov, DeltaMilliseconds;
    public int Quality, Preset;
}

[StructLayout(LayoutKind.Sequential, Pack = 8)]
internal struct NativeDiagnostics
{
    public int Abi, Size, Status, BackendFlags;
    public uint LastNgxResult;
    public int FrameGenerationState;
    public uint FrameGenerationResult, FrameGenerationFlags;
    public uint PresentedSinceSample, MaxGeneratedPerRendered;
    public ulong Evaluations, QueuedFrames, RejectedFrames;
}

[StructLayout(LayoutKind.Sequential, Pack = 8)]
internal struct HudlessDiagnostics
{
    public int Abi, Size, ProviderVersion, LastResult;
    public ulong CapturedTokens, AcceptedSubmissions, RejectedSubmissions;
}

[StructLayout(LayoutKind.Sequential, Pack = 8)]
internal struct PresentationDiagnostics
{
    public uint Size, Version;
    public ulong Epoch, ClientPresents, NativePresentCalls, DisplayedFrames, SampleQpc, QpcFrequency;
    public uint Flags, NativeRaw, DisplayRaw, PresentRefresh, SyncRefresh;
    public int NativeQueryHResult, DisplayQueryHResult;
    public uint RequestedMultiplier;
    public ulong LastDisplayQpc;
}

internal static class Native
{
    internal const string Dll = "LastEpochNative";
    [DllImport(Dll, EntryPoint="LE_Initialize", CharSet=CharSet.Unicode, CallingConvention=CallingConvention.Cdecl)]
    internal static extern void Initialize(string data, string runtime);
    [DllImport(Dll, EntryPoint="LE_FrameSize", CallingConvention=CallingConvention.Cdecl)]
    internal static extern int FrameSize();
    [DllImport(Dll, EntryPoint="LE_GetRenderEvent", CallingConvention=CallingConvention.Cdecl)]
    internal static extern IntPtr GetRenderEvent();
    [DllImport(Dll, EntryPoint="LE_Queue", CallingConvention=CallingConvention.Cdecl)]
    internal static extern IntPtr Queue(ref Frame frame);
    [DllImport(Dll, EntryPoint="LE_CancelQueuedFrame", CallingConvention=CallingConvention.Cdecl)]
    internal static extern void CancelQueuedFrame(IntPtr frame);
    [DllImport(Dll, EntryPoint="LE_Status", CallingConvention=CallingConvention.Cdecl)]
    internal static extern int Status();
    [DllImport(Dll, EntryPoint="LE_RequestRetry", CallingConvention=CallingConvention.Cdecl)]
    internal static extern void RequestRetry();
    [DllImport(Dll, EntryPoint="LE_Evaluations", CallingConvention=CallingConvention.Cdecl)]
    internal static extern ulong Evaluations();
    [DllImport(Dll, EntryPoint="LE_GetDiagnostics", CallingConvention=CallingConvention.Cdecl)]
    internal static extern int GetDiagnostics(out NativeDiagnostics diagnostics, int size);
    [DllImport(Dll, EntryPoint="LE_HudlessProviderVersion", CallingConvention=CallingConvention.Cdecl)]
    internal static extern uint HudlessProviderVersion();
    [DllImport(Dll, EntryPoint="LE_QueueHudless", CallingConvention=CallingConvention.Cdecl)]
    internal static extern IntPtr QueueHudless(int cameraId, int frameIndex, IntPtr color);
    [DllImport(Dll, EntryPoint="LE_GetHudlessDiagnostics", CallingConvention=CallingConvention.Cdecl)]
    internal static extern int GetHudlessDiagnostics(out HudlessDiagnostics diagnostics, int size);
    [DllImport(Dll, EntryPoint="LE_GetPresentationDiagnostics", CallingConvention=CallingConvention.Cdecl)]
    internal static extern int GetPresentationDiagnostics(out PresentationDiagnostics diagnostics, int size);
}
