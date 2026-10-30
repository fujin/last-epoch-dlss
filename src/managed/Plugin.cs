using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using BepInEx;
using BepInEx.Configuration;
using BepInEx.Unity.IL2CPP;
using HarmonyLib;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.PostProcessing;
using UnityEngine.SceneManagement;

namespace LastEpochGraphics;

[BepInPlugin("local.lastepoch.graphics", "Last Epoch Graphics", "0.1.0")]
public sealed class Plugin : BasePlugin
{
    internal static Plugin Instance = null!;
    internal static ConfigEntry<bool> Enabled = null!, ProbeOnly = null!, VerifyPixels = null!, LateHudless = null!, DedicatedDisplayCamera = null!;
    internal static ConfigEntry<int> Quality = null!;
    internal static ConfigEntry<string> CameraFilter = null!;
    internal static string Status = "Starting", Metrics = "No GPU samples yet";
    internal static bool Ready;
    private static Harmony? patches;
    private static IntPtr renderEvent;
    private static CameraState? active;
    private static int epoch, sampleFrames;
    private static double sampleSeconds;
    private static bool faulted, restorePending, restartPending;
    private static ulong preCullCalls, temporalCalls, queuedFrames, presentedFrames, renderImageCalls;
    private static readonly HashSet<string> reported = new();
    private static bool hasPresentationDiagnostics;
    private static PresentationDiagnostics previousPresentation;
    private static ulong originalTaaHistoryCalls;
    private static bool renderingScopeActive;
    private static int renderingScopeFrame = -1;
    private static readonly bool ExperimentalRenderScope =
#if LE_EXPERIMENTAL_RENDER_SCOPE
        true;
#else
        false;
#endif
    private static readonly bool ExperimentalScaling =
#if LE_EXPERIMENTAL_RENDER_SCOPE || LE_EXPERIMENTAL_SCALING || LE_DIAGNOSTIC_LOW_POSTPROCESS
        true;
#else
        false;
#endif

    public override void Load()
    {
        Instance = this;
        // Bind must not rewrite the staged profile; hotkeys change this process only.
        Config.SaveOnConfigSet = false;
        Enabled = Config.Bind("General", "Enabled", true, "Panel buttons select the adapter mode for this session.");
        ProbeOnly = Config.Bind("Diagnostics", "ProbeOnly", true, "Validate raw scene inputs before post-processing without running reconstruction.");
        VerifyPixels = Config.Bind("Diagnostics", "VerifyPixels", false, "Read back depth/motion samples periodically and compare reconstructed pixels once; may hitch.");
        Quality = Config.Bind("Upscaling", "Quality", 5, "0 Performance, 1 Balanced, 2 Quality, 3 Ultra Performance, 4 Ultra Quality, 5 DLAA. Restart after changing.");
        CameraFilter = Config.Bind("Compatibility", "CameraName", "", "Optional exact scene camera name; empty selects Camera.main. UI cameras are excluded.");
        LateHudless = Config.Bind("Compatibility", "LateHudless", false, "Optional local OptiScaler HUDless API1: requires DisableHudless=false and HUDFix=false. SDR 8-bit output only. Leave off until separately validated.");
        DedicatedDisplayCamera = Config.Bind("Compatibility", "DedicatedDisplayCamera", true, "Present from an empty on-screen camera after the offscreen scene camera. Session checkbox permits comparison with the original camera event.");
        if (Quality.Value < 0 || Quality.Value > 5) Quality.Value = 5;
        Log.LogInfo($"Last Epoch Graphics 0.1.0: Unity={Application.unityVersion}; API={SystemInfo.graphicsDeviceType}; GPU={SystemInfo.graphicsDeviceName}");
        if (!ExperimentalScaling && Quality.Value != 5)
        {
            Status = "This build supports native-resolution DLAA; scaled SR remains experimental.";
            Log.LogWarning(Status + " No graphics hooks were installed. Select Quality=5 or use an explicitly labelled diagnostic build.");
            return;
        }
        if (SystemInfo.graphicsDeviceType != GraphicsDeviceType.Direct3D11)
        {
            Status = "This prototype requires DirectX 11";
            Log.LogWarning(Status);
            return;
        }
        if (GraphicsSettings.currentRenderPipeline != null)
        {
            Status = "Unsupported render pipeline; no hooks installed";
            Log.LogWarning(Status);
            return;
        }
        try
        {
            var pluginDir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location)!;
            var native = NativeLibrary.Load(Path.Combine(pluginDir, "LastEpochNative.dll"));
            hasPresentationDiagnostics = NativeLibrary.TryGetExport(native, "LE_GetPresentationDiagnostics", out _);
            NativeLibrary.SetDllImportResolver(typeof(Plugin).Assembly, (name, _, _) => name == Native.Dll ? native : IntPtr.Zero);
            var logs = Path.Combine(Paths.BepInExRootPath, "LastEpochGraphics");
            Directory.CreateDirectory(logs);
            Native.Initialize(logs, Paths.GameRootPath);
            if (Marshal.SizeOf<Frame>() != Native.FrameSize() || Marshal.SizeOf<NativeDiagnostics>() != 64 || Marshal.SizeOf<HudlessDiagnostics>() != 40 || Marshal.SizeOf<PresentationDiagnostics>() != 96)
                throw new InvalidOperationException("Native interface layout mismatch");
            renderEvent = Native.GetRenderEvent();
            if (renderEvent == IntPtr.Zero) throw new InvalidOperationException("Native render event unavailable");
            Native.RequestRetry(); // Probe mode works without an attached reconstruction backend.
            patches = new Harmony("local.lastepoch.graphics");
            Patch(typeof(PostProcessLayer), "OnPreCull", nameof(PreCull));
            Patch(typeof(PostProcessLayer), "Render", nameof(BeginPostProcessing));
            Patch(typeof(PostProcessLayer), "Render", nameof(EndPostProcessing), true);
            Patch(typeof(TemporalAntialiasing), "Render", nameof(TemporalRender));
            Patch(typeof(TemporalAntialiasing), "CheckHistory", nameof(TraceOriginalTaaHistory));
            Patch(typeof(PostProcessLayer), "OnRenderImage", nameof(RenderImage));
            Patch(typeof(CTAA_PC), "OnPreCull", nameof(CtaaPreCull));
            if (ExperimentalRenderScope)
                Patch(typeof(UnityEngine.LowLevel.PlayerLoop), "SetPlayerLoop", nameof(PlayerLoopChanged), true);
            Ready = true;
            Status = Enabled.Value ? "Waiting for scene camera" : "Original game renderer";
            AddComponent<Controls>();
            if (ExperimentalRenderScope) RenderingScope.Initialize(BeginRenderingScope, EndRenderingScope);
        }
        catch (Exception e)
        {
            Ready = false;
            faulted = true;
            Status = "Adapter initialization failed; see BepInEx log";
            Log.LogError(e);
            try { RenderingScope.Remove(); } catch (Exception cleanup) { Log.LogError(cleanup); }
            patches?.UnpatchSelf();
        }
    }

    private static void Patch(Type type, string name, string handler, bool postfix = false)
    {
        var original = AccessTools.Method(type, name) ?? throw new MissingMethodException(type.FullName, name);
        var hook = new HarmonyMethod(typeof(Plugin), handler);
        patches!.Patch(original, prefix: postfix ? null : hook, postfix: postfix ? hook : null);
        Instance.Log.LogInfo($"Hook installed: {type.Name}.{name} {(postfix ? "postfix" : "prefix")}");
    }

    private static bool Candidate(Camera camera)
    {
        if (camera == null || camera.cameraType != CameraType.Game || camera.stereoEnabled || camera.targetDisplay != 0) return false;
        if (camera.name.IndexOf("UI", StringComparison.OrdinalIgnoreCase) >= 0) return false;
        var rect = camera.rect;
        if (Mathf.Abs(rect.x) > 0.0001f || Mathf.Abs(rect.y) > 0.0001f ||
            Mathf.Abs(rect.width - 1f) > 0.0001f || Mathf.Abs(rect.height - 1f) > 0.0001f) return false;
        return CameraFilter.Value.Length > 0 ? camera.name == CameraFilter.Value : camera == Camera.main;
    }

    // Restore before recording the next camera, never in the middle of a submitted frame.
    private static void ApplyPendingState()
    {
        if (!restartPending && !restorePending) return;
        active?.Dispose();
        active = null;
        epoch++;
        restorePending = false;
        if (restartPending)
        {
            restartPending = false;
            faulted = false;
            Native.RequestRetry();
            Status = Enabled.Value ? "Waiting for scene camera" : "Original game renderer";
        }
    }

    private static void PreCull(PostProcessLayer __instance)
    {
        try
        {
            var camera = __instance.GetComponent<Camera>();
            if (camera == null) return;
            preCullCalls++;
            if (reported.Add(camera.name))
                Instance.Log.LogInfo($"Camera '{camera.name}' main={camera == Camera.main} size={camera.pixelWidth}x{camera.pixelHeight} target={camera.targetTexture?.name ?? "screen"} AA={__instance.antialiasingMode} orthographic={camera.orthographic}");
            if (!ExperimentalRenderScope)
            {
                ApplyPendingState();
                if (!Ready || faulted || !Enabled.Value || !Candidate(camera)) return;
                SelectCamera(camera, __instance);
                active!.Prepare();
                return;
            }
            // Camera targets and allocations are established before Unity enters
            // camera rendering, not after its color/depth surfaces are selected.
            if (!ShouldProcess(camera)) return;
            if (!Candidate(camera)) Fail(new InvalidOperationException("Selected camera contract changed during rendering"));
        }
        catch (Exception e) { Fail(e); }
    }

    private static void SelectCamera(Camera camera, PostProcessLayer layer)
    {
        if (active != null && active.Camera == camera) return;
        active?.Dispose();
        active = new CameraState(camera, layer);
        epoch++;
        Native.RequestRetry();
        Instance.Log.LogInfo($"Selected camera id={camera.GetInstanceID()} layer={layer.GetInstanceID()} name='{camera.name}' clear={camera.clearFlags} HDR={camera.allowHDR} near={camera.nearClipPlane} far={camera.farClipPlane} fov={camera.fieldOfView} quality={Quality.Value} probe={ProbeOnly.Value} renderScope={ExperimentalRenderScope}");
    }

    private static void PlayerLoopChanged()
    {
        try
        {
            if (renderingScopeActive) EndRenderingScope();
            RenderingScope.OnLoopChanged();
        }
        catch (Exception e) { Fail(e); }
    }

    private static void BeginRenderingScope()
    {
        if (!Ready) return;
        try
        {
            if (renderingScopeActive) EndRenderingScope();
            ApplyPendingState();
            if (faulted || !Enabled.Value) return;
            Camera? camera = Camera.main;
            if (CameraFilter.Value.Length > 0)
            {
                camera = null;
                foreach (var candidate in Camera.allCameras)
                    if (candidate.name == CameraFilter.Value) { camera = candidate; break; }
            }
            var layer = camera == null ? null : camera.GetComponent<PostProcessLayer>();
            if (camera == null || layer == null || !layer.enabled || !Candidate(camera))
            {
                active?.Dispose(); active = null;
                return;
            }
            SelectCamera(camera, layer);
            renderingScopeActive = true;
            renderingScopeFrame = Time.frameCount;
            active!.Prepare();
            if (VerifyPixels.Value && Time.frameCount % 300 == 0)
                Instance.Log.LogInfo($"Render scope begin frame={Time.frameCount} cameraPixels={camera.pixelWidth}x{camera.pixelHeight} target={DescribeTexture(camera.targetTexture)}");
        }
        catch (Exception e) { EndRenderingScope(); Fail(e); }
    }

    private static void EndRenderingScope()
    {
        try
        {
            if (renderingScopeActive) active?.EndRenderScope();
        }
        catch (Exception e) { Fail(e); }
        finally { renderingScopeActive = false; renderingScopeFrame = -1; }
    }

    private static bool ShouldProcess(Camera camera) =>
        Ready && !faulted && Enabled.Value && (!ExperimentalRenderScope || renderingScopeActive) && active != null &&
        active.Camera == camera && active.PreparedFrame == Time.frameCount;

    private static bool CtaaPreCull(CTAA_PC __instance)
    {
        var camera = __instance.GetComponent<Camera>();
        if (camera == null || !ShouldProcess(camera)) return true;
        active!.SuppressCtaa(active.TemporalFrame != Time.frameCount);
        return false;
    }

    // PPv2 records its stack from OnPreCull. Redirect the final destination before
    // Render saves it locally; raw scene rendering and opaque effects remain low-res.
    private static void BeginPostProcessing(PostProcessLayer __instance, PostProcessRenderContext context)
    {
        if (!ShouldProcess(context.camera) || active!.Layer != __instance) return;
        try
        {
            var s = active!;
            s.EnsureBuffers(context.width, context.height, context.sourceFormat);
            if (s.SceneTarget == null || s.Probe) return;
            if (context.stereoActive || context.numberOfEyes != 1 || context.command == null)
                throw new InvalidOperationException("Unexpected stereo or missing post-process command buffer");
            s.ContextFrame = Time.frameCount;
            s.ContextWidth = context.width; s.ContextHeight = context.height;
            s.ContextScreenWidth = context.screenWidth; s.ContextScreenHeight = context.screenHeight;
            s.ContextDescriptor = context.m_sourceDescriptor;
            s.ContextDestination = context.destination;
            s.ContextFlip = context.flip;
            context.command.Blit(context.source, s.Presented);
            context.destination = new RenderTargetIdentifier(s.Presented);
            context.flip = false;
            s.RedirectedFrame = Time.frameCount;
        }
        catch (Exception e) { Fail(e); }
    }

    private static void EndPostProcessing(PostProcessLayer __instance, PostProcessRenderContext context)
    {
        var s = active;
        if (s == null || s.Layer != __instance || s.ContextFrame != Time.frameCount) return;
        try
        {
            // The shared legacy context and camera framebuffer remain low-res.
            // Only the independently owned Presented texture leaves this stack
            // at display resolution. Do not leak promoted dimensions/attachments
            // into later camera callbacks or Unity's image-effect plumbing.
            context.width = s.ContextWidth; context.height = s.ContextHeight;
            context.screenWidth = s.ContextScreenWidth; context.screenHeight = s.ContextScreenHeight;
            context.m_sourceDescriptor = s.ContextDescriptor;
            context.source = s.ContextDestination;
            context.destination = s.ContextDestination;
            context.flip = s.ContextFlip;
            var cameraTarget = new RenderTargetIdentifier(BuiltinRenderTextureType.CameraTarget);
            context.command.SetRenderTarget(cameraTarget, cameraTarget);
            s.ContextFrame = -1;
        }
        catch (Exception e) { Fail(e); }
    }

    // Replace only temporal resolve: jitter has been calculated at scene resolution,
    // and bloom, DOF, motion blur, color grading and tonemapping have not run yet.
    private static bool TemporalRender(TemporalAntialiasing __instance, PostProcessRenderContext context)
    {
        if (!ShouldProcess(context.camera)) return true;
        IntPtr queued = IntPtr.Zero;
        bool recorded = false;
        try
        {
            var s = active!;
            temporalCalls++;
            if (s.TemporalFrame == Time.frameCount)
                throw new InvalidOperationException("Selected camera rendered more than once in one frame; disabling temporal reconstruction");
            s.TemporalFrame = Time.frameCount;
            int renderWidth = context.width, renderHeight = context.height;
            s.EnsureBuffers(renderWidth, renderHeight, context.sourceFormat);
            var cmd = context.command ?? throw new InvalidOperationException("TAA command buffer unavailable");
            if (s.SceneTarget != null && s.RedirectedFrame != Time.frameCount)
                throw new InvalidOperationException("Full-resolution post-process destination was not established");

            // Copies and evaluation execute in this same camera command buffer.
            // Native texture pointers belong only to persistent RenderTextures.
            // PPv2's depth debug pass samples _CameraDepthTexture directly.
            // _Params.x=0 selects raw device depth without linearization or gamma.
            // This avoids Blit/RTI aliases selecting a color plane or an unbound texture.
            cmd.SetRenderTarget(new RenderTargetIdentifier(s.Depth));
            var depthSheet = context.propertySheets.Get(context.resources.shaders.debugOverlays);
            depthSheet.properties.SetVector(Shader.PropertyToID("_Params"), Vector4.zero);
            cmd.DrawMesh(RuntimeUtilities.fullscreenTriangle, Matrix4x4.identity, depthSheet.material, 0, 0, depthSheet.properties);
            cmd.Blit(context.source, s.Color);
            cmd.Blit(new RenderTargetIdentifier(BuiltinRenderTextureType.MotionVectors), s.Motion);
            cmd.Blit(context.source, s.Output);
            var jitter = __instance.jitter;
            if (!s.Probe) s.PrepareHistory(__instance);
            Frame frame = new()
            {
                Abi = 3, CameraId = context.camera.GetInstanceID(), FrameIndex = Time.frameCount,
                Mode = s.Probe ? 0 : 3,
                Color = s.ColorPtr, Depth = s.DepthPtr, Motion = s.MotionPtr, Output = s.OutputPtr,
                RenderWidth = renderWidth, RenderHeight = renderHeight,
                OutputWidth = s.Output.width, OutputHeight = s.Output.height,
                JitterX = jitter.x * renderWidth, JitterY = jitter.y * renderHeight,
                MotionScaleX = -renderWidth, MotionScaleY = -renderHeight,
                HistoryEpoch = epoch, Verify = VerifyPixels.Value ? 1 : 0,
                ReversedDepth = SystemInfo.usesReversedZBuffer ? 1 : 0,
                CameraNear = context.camera.nearClipPlane, CameraFar = context.camera.farClipPlane,
                CameraFov = context.camera.fieldOfView * Mathf.Deg2Rad,
                DeltaMilliseconds = Mathf.Clamp(Time.unscaledDeltaTime * 1000, 0.1f, 1000f),
                Quality = s.Probe ? 5 : s.SelectedQuality, Preset = 0
            };
            queued = Native.Queue(ref frame);
            if (queued == IntPtr.Zero) throw new InvalidOperationException("Native input validation rejected the frame");
            s.TrackToken(queued);
#if LE_DIAGNOSTIC_LOW_POSTPROCESS
            if (!s.Probe && s.SceneTarget != null && reported.Add("diagnostic-low-postprocess"))
                Instance.Log.LogWarning("DIAGNOSTIC BUILD: full-resolution native SR is downcopied into the original low-resolution TAA target. PP context/temporary promotion is disabled; this is not validated full-resolution SR presentation.");
#else
            if (!s.Probe && s.SceneTarget != null) PromoteTemporalTarget(context, s);
#endif

            // Treat an attempted interop submission as ownership transfer, including
            // ambiguous exceptions. Native consume-once tokens are replay-safe.
            recorded = true;
            cmd.IssuePluginEventAndData(renderEvent, 1, queued);
            queuedFrames++;
            s.LastQueueFrame = Time.frameCount;
            if (queuedFrames == 1 || queuedFrames % 300 == 0)
            {
                Instance.Log.LogInfo($"Temporal input queue={queuedFrames} mode={frame.Mode} raw={renderWidth}x{renderHeight} output={s.Output.width}x{s.Output.height} jitterPixels={frame.JitterX:F4},{frame.JitterY:F4} MVscale={frame.MotionScaleX},{frame.MotionScaleY} sourceFormat={context.sourceFormat}; copySources={depthSheet.material.shader.name}[raw-depth-pass0]/Builtin.MotionVectors");
                Instance.Log.LogInfo($"Temporal prefix willSkipOriginal={!s.Probe} resetFlag={__instance.m_ResetHistory} pingPong={__instance.m_HistoryPingPong[0]} originalHistoryCalls={originalTaaHistoryCalls} context={context.width}x{context.height} srcType={context.source.m_Type} srcID={context.source.m_NameID} dstType={context.destination.m_Type} dstID={context.destination.m_NameID}");
            }
            if (s.Probe) return true;
            cmd.Blit(s.Output, context.destination);
            s.CommitHistory(__instance);
            if (s.SceneTarget == null) s.RecordNativeHudlessCapture();
            return false;
        }
        catch (Exception e) { Fail(e); return true; }
        finally
        {
            if (queued != IntPtr.Zero && !recorded) Native.CancelQueuedFrame(queued);
        }
    }

    private static void TraceOriginalTaaHistory(TemporalAntialiasing __instance, int id, PostProcessRenderContext context)
    {
        if (active == null || active.Camera != context.camera) return;
        var count = ++originalTaaHistoryCalls;
        if (count <= 8 || count % 300 == 0)
            Instance.Log.LogWarning($"ORIGINAL TAA CheckHistory reached camera={context.camera.GetInstanceID()} frame={Time.frameCount} id={id} count={count} adapterProbe={active.Probe} temporalPrefixFrame={active.TemporalFrame} context={context.width}x{context.height} resetFlag={__instance.m_ResetHistory} sourceType={context.source.m_Type} sourceID={context.source.m_NameID} destinationType={context.destination.m_Type} destinationID={context.destination.m_NameID}");
    }

    private static void PromoteTemporalTarget(PostProcessRenderContext context, CameraState s)
    {
        // PPv2 allocated taaTarget immediately before this hook. Reallocate the same
        // unused property ID so Render's local taaTarget remains valid afterward.
        var destination = context.destination;
        if (destination.m_Type != BuiltinRenderTextureType.PropertyName || destination.m_NameID == 0 ||
            destination.m_NameID == -1 || destination.Equals(context.source))
            throw new InvalidOperationException("TAA destination is not the expected unused named temporary target");
        int w = s.Output.width, h = s.Output.height;
        context.command.ReleaseTemporaryRT(destination.m_NameID);
        context.GetScreenSpaceTemporaryRT(context.command, destination.m_NameID, 0, context.sourceFormat,
            RenderTextureReadWrite.Default, FilterMode.Bilinear, w, h);
        context.width = w;
        context.height = h;
        context.screenWidth = w;
        context.screenHeight = h;
        var descriptor = context.m_sourceDescriptor;
        descriptor.width = w;
        descriptor.height = h;
        descriptor.msaaSamples = 1;
        descriptor.useDynamicScale = false;
        context.m_sourceDescriptor = descriptor;
        // Following effects allocate full-resolution targets. Normalized UVs still
        // sample the original camera's low-resolution depth and motion textures.
    }

    private static bool RenderImage(PostProcessLayer __instance, RenderTexture src, RenderTexture dst)
    {
        renderImageCalls++;
        if (reported.Add("image-layer-" + __instance.GetInstanceID()))
            Instance.Log.LogInfo($"RenderImage entered layer={__instance.GetInstanceID()} src={DescribeTexture(src)} dst={DescribeTexture(dst)} activeLayer={active?.Layer.GetInstanceID()} frame={Time.frameCount} prepared={active?.PreparedFrame}");
        var s = active;
        if (s == null || s.Layer != __instance || s.PreparedFrame != Time.frameCount || src == null) return true;
        bool scaledScene = s.SceneTarget != null;
        bool finalBoundary = scaledScene ? dst == s.SceneTarget : dst == null;
        bool tryHudless = scaledScene && LateHudless.Value && !s.Probe && !faulted && s.LastQueueFrame == Time.frameCount &&
            finalBoundary && Native.HudlessProviderVersion() == 1;
        // Preserve this frame's spatial fallback even if a hook already failed.
        var final = scaledScene && s.RedirectedFrame == Time.frameCount ? s.Presented : src;
        bool savedSrgb = GL.sRGBWrite;
        try
        {
            if (s.LastImageDiagnostic < 0 || Time.frameCount - s.LastImageDiagnostic >= 300)
            {
                Instance.Log.LogInfo($"RenderImage frame={Time.frameCount} src={DescribeTexture(src)} dst={DescribeTexture(dst)} lateHudless={LateHudless.Value} scaled={scaledScene} probe={s.Probe} faulted={faulted} queuedFrame={s.LastQueueFrame} provider={Native.HudlessProviderVersion()} eligible={tryHudless} mainAfterEverythingCapture={s.HudlessCaptureFrame == Time.frameCount}");
                if (s.LastImageDiagnostic < 0 || VerifyPixels.Value)
                    foreach (var component in s.Camera.GetComponents<MonoBehaviour>())
                        Instance.Log.LogInfo($"Camera component: {component.GetIl2CppType().FullName} enabled={component.enabled}");
                s.LastImageDiagnostic = Time.frameCount;
            }
            if (VerifyPixels.Value &&
                (s.LastPresentationProbe < 0 || Time.frameCount - s.LastPresentationProbe >= 300))
                ProbePresentation(s, final);
            if (!scaledScene && !tryHudless) return true;
            if (scaledScene && dst != null)
            {
                GL.sRGBWrite = dst.sRGB;
                Graphics.Blit(final, dst);
            }
            if (!finalBoundary)
            {
                if (!scaledScene) return true;
                // Preserve unknown later image effects. Their final low-res camera
                // target is sampled only after the complete camera chain executes.
                final = s.SceneTarget!;
                if (reported.Add("sr-intermediate-" + s.Camera.GetInstanceID()))
                    Instance.Log.LogWarning("A later image effect remains. Final display preserves the full chain at scene resolution; full-resolution scene reconstruction is not yet presented.");
            }
            if (tryHudless) final = PrepareHudless(s, final, s.FinalCommands) ?? final;
            s.RecordDisplay(final);
            presentedFrames++;
            RenderTexture.active = dst;
            return false;
        }
        catch (Exception e) { Fail(e); return true; }
        finally
        {
            GL.sRGBWrite = savedSrgb;
        }
    }

    private static string DescribeTexture(RenderTexture? texture) => texture == null ? "backbuffer/null" :
        $"'{texture.name}' {texture.width}x{texture.height} {texture.format} sRGB={texture.sRGB}";

    private static void ProbePresentation(CameraState s, RenderTexture source)
    {
        IntPtr token = Native.QueueHudless(s.Camera.GetInstanceID(), Time.frameCount, source.GetNativeTexturePtr());
        if (token == IntPtr.Zero) return;
        s.TrackToken(token);
        var cmd = new CommandBuffer { name = "Last Epoch postprocess color evidence" };
        try
        {
            cmd.IssuePluginEventAndData(renderEvent, 3, token);
            Graphics.ExecuteCommandBuffer(cmd);
            s.LastPresentationProbe = Time.frameCount;
        }
        finally { cmd.Release(); }
    }

    private static RenderTexture? PrepareHudless(CameraState s, RenderTexture source, CommandBuffer? deferred = null)
    {
        IntPtr token = IntPtr.Zero;
        bool recorded = false;
        bool savedSrgb = GL.sRGBWrite;
        CommandBuffer? cmd = null;
        try
        {
            if (HDROutputSettings.main != null && HDROutputSettings.main.active)
            {
                if (reported.Add("late-hudless-hdr")) Instance.Log.LogWarning("Late HUDless skipped: HDR output is outside the 8-bit SDR contract.");
                return null;
            }
            if (source.width != Screen.width || source.height != Screen.height) return null;
            bool encodeSrgb = QualitySettings.activeColorSpace == ColorSpace.Linear;
            s.EnsureHudless(source.width, source.height, encodeSrgb);
            GL.sRGBWrite = encodeSrgb;
            Graphics.Blit(source, s.Hudless);
            // The native callback pairs this packet with the same camera/frame's
            // token obtained immediately after its successful SR evaluation.
            token = Native.QueueHudless(s.Camera.GetInstanceID(), Time.frameCount, s.HudlessPtr);
            if (token == IntPtr.Zero) return null;
            s.TrackToken(token);
            cmd = deferred ?? new CommandBuffer { name = "Last Epoch final scene HUDless submission" };
            recorded = true;
            cmd.IssuePluginEventAndData(renderEvent, 2, token);
            if (deferred == null) Graphics.ExecuteCommandBuffer(cmd);
            if (s.HudlessSubmissions++ % 300 == 0)
                Instance.Log.LogInfo($"Late HUDless queued frame={Time.frameCount} source={source.format} sRGB={source.sRGB} capture={s.Hudless.format} sRGB={s.Hudless.sRGB} size={source.width}x{source.height}; display uses this same encoded capture. Acceptance is reported by native diagnostics.");
            return s.Hudless;
        }
        catch (Exception e)
        {
            if (reported.Add("late-hudless-error")) Instance.Log.LogWarning("Optional late HUDless capture skipped: " + e);
            return null;
        }
        finally
        {
            if (token != IntPtr.Zero && !recorded) Native.CancelQueuedFrame(token);
            if (deferred == null) cmd?.Release();
            GL.sRGBWrite = savedSrgb;
        }
    }

    private static void Fail(Exception e)
    {
        if (!faulted) Instance.Log.LogError(e);
        faulted = true;
        restorePending = true;
        Status = "Adapter stopped; renderer will restore before the next camera frame. See log.";
    }

    internal static void Tick()
    {
        if (!Ready) return;
        try
        {
            if (renderingScopeActive && renderingScopeFrame != Time.frameCount)
            {
                EndRenderingScope();
                Fail(new InvalidOperationException("Render-only target scope did not close in its frame; adapter stopped"));
            }
            if (active != null && (active.Camera == null || active.Layer == null ||
                (active.ColorPtr != IntPtr.Zero && !active.BuffersAlive())))
            {
                restartPending = true;
                Status = "Scene resources changed; rebuilding camera inputs";
            }
            // These are earlier render-thread results; a queued packet or loaded DLL
            // is never reported as successful reconstruction or active frame generation.
            if (!restartPending && !faulted && active != null &&
                active.LastQueueFrame >= 0 && Time.frameCount > active.LastQueueFrame)
            {
                int nativeStatus = Native.Status();
                if (nativeStatus < 0)
                    Fail(new InvalidOperationException($"Native rendering failed with status {nativeStatus}; see native.log"));
                else
                {
                    string sizes = $"{active.InputWidth}×{active.InputHeight} → {active.DisplayWidth}×{active.DisplayHeight}";
                    Status = active.Probe
                        ? nativeStatus == 1 ? $"GPU resource formats valid · {sizes} · pixel-content review required · reconstruction OFF" : "Waiting for render-thread input validation"
                        : nativeStatus == 2 ? $"Upscaler evaluations: {Native.Evaluations()} · {sizes}" : "Waiting for GPU reconstruction; spatial fallback available";
                }
            }
            ApplyPendingState();
            if (faulted && active == null) Status = "Adapter stopped; original renderer restored. See log.";
            sampleFrames++;
            sampleSeconds += Math.Max(0.000001f, Time.unscaledDeltaTime);
            if (sampleFrames >= 300)
            {
                float renderFps = (float)(sampleFrames / sampleSeconds);
                if (Native.GetDiagnostics(out var d, Marshal.SizeOf<NativeDiagnostics>()) == 1)
                {
                    string fg = d.FrameGenerationState == 2
                        ? $"FG query OK, status 0x{d.FrameGenerationFlags:X}, observed presents {d.PresentedSinceSample}"
                        : $"FG unverified (query state {d.FrameGenerationState})";
                    Metrics = $"Unity frames: {renderFps:F1} fps · {fg}";
                    Instance.Log.LogInfo($"GPU sample: Unity fps={renderFps:F2} sampledFrames={sampleFrames} seconds={sampleSeconds:F3}; preCull={preCullCalls} temporalHooks={temporalCalls} queued={queuedFrames} imageCallbacks={renderImageCalls} fullresPresent={presentedFrames}; nativeStatus={d.Status} backendFlags=0x{d.BackendFlags:X} NGX=0x{d.LastNgxResult:X8} evaluations={d.Evaluations} nativeQueued={d.QueuedFrames} rejected={d.RejectedFrames}; FGqueryState={d.FrameGenerationState} FGresult=0x{d.FrameGenerationResult:X8} FGstatus=0x{d.FrameGenerationFlags:X} presentsSinceLastStateQuery={d.PresentedSinceSample} maxGeneratedPerRendered={d.MaxGeneratedPerRendered}. Present count can be reset by OptiScaler queries; it is not an active multiplier.");
                    if (LateHudless.Value && Native.GetHudlessDiagnostics(out var h, Marshal.SizeOf<HudlessDiagnostics>()) == 1)
                        Instance.Log.LogInfo($"Late HUDless sample: providerABI={h.ProviderVersion} lastResult={h.LastResult} capturedFrameTokens={h.CapturedTokens} accepted={h.AcceptedSubmissions} rejected={h.RejectedSubmissions}; acceptance alone does not measure FG multiplier.");
                    SamplePresentation();
                    if (VerifyPixels.Value) TraceCameras();
                }
                sampleFrames = 0;
                sampleSeconds = 0;
            }
        }
        catch (Exception e) { Fail(e); }
    }

    private static void SamplePresentation()
    {
        if (!hasPresentationDiagnostics) return;
        int result = Native.GetPresentationDiagnostics(out var p, Marshal.SizeOf<PresentationDiagnostics>());
        if (result != 1 || p.Version != 1 || p.Size != 96)
        {
            if (reported.Add("presentation-query-" + result))
                Instance.Log.LogInfo($"Independent presentation telemetry unavailable, result={result}; no measured FG multiplier claimed.");
            previousPresentation = default;
            return;
        }
        var old = previousPresentation;
        previousPresentation = p;
        string delta = "baseline/epoch changed; waiting for comparable counters";
        if (old.Version == 1 && old.Epoch == p.Epoch && p.QpcFrequency > 0 &&
            old.QpcFrequency == p.QpcFrequency && p.SampleQpc > old.SampleQpc &&
            p.ClientPresents >= old.ClientPresents && p.NativePresentCalls >= old.NativePresentCalls &&
            p.DisplayedFrames >= old.DisplayedFrames)
        {
            double seconds = (p.SampleQpc - old.SampleQpc) / (double)p.QpcFrequency;
            ulong clients = p.ClientPresents - old.ClientPresents;
            ulong native = p.NativePresentCalls - old.NativePresentCalls;
            ulong display = p.DisplayedFrames - old.DisplayedFrames;
            delta = $"interval={seconds:F3}s clientPresentDelta={clients}";
            if ((p.Flags & old.Flags & 3) == 3)
            {
                delta += $" DXGIpresentCallsDelta={native} rate={native / seconds:F1}/s";
                if (clients > 0)
                {
                    double ratio = native / (double)clients;
                    delta += $" nativeCallsPerClient={ratio:F3}";
                    Metrics += $" · DXGI calls {native / seconds:F1}/s ({ratio:F2}× client presents)";
                }
            }
            if ((p.Flags & old.Flags & 5) == 5)
                delta += $" DXGIreportedPresentCountDelta={display} rate={display / seconds:F1}/s";
        }
        Instance.Log.LogInfo($"Independent presentation counters: epoch={p.Epoch} flags=0x{p.Flags:X} requestedMultiplier={p.RequestedMultiplier} clientTotal={p.ClientPresents} nativeTotal={p.NativePresentCalls} statsTotal={p.DisplayedFrames} nativeHRESULT=0x{p.NativeQueryHResult:X8} statsHRESULT=0x{p.DisplayQueryHResult:X8}; {delta}. DXGI sequence/call counters are not physical panel scanouts.");
    }

    private static void TraceCameras()
    {
        foreach (var camera in Camera.allCameras)
        {
            var layer = camera.GetComponent<PostProcessLayer>();
            Instance.Log.LogInfo($"Camera stack frame={Time.frameCount} name='{camera.name}' id={camera.GetInstanceID()} depth={camera.depth} clear={camera.clearFlags} background={camera.backgroundColor} target={DescribeTexture(camera.targetTexture)} enabled={camera.enabled} active={camera.gameObject.activeInHierarchy} display={camera.targetDisplay} rect={camera.rect} pixels={camera.pixelRect} forceRT={camera.forceIntoRenderTexture} HDR={camera.allowHDR} mask=0x{camera.cullingMask:X8} PP={(layer != null && layer.enabled)}");
            foreach (CameraEvent point in Enum.GetValues(typeof(CameraEvent)))
                foreach (var command in camera.GetCommandBuffers(point))
                    Instance.Log.LogInfo($"Camera command '{camera.name}' {point}: '{command.name}' bytes={command.sizeInBytes}");
        }
    }

    internal static void Toggle()
    {
        Enabled.Value = !Enabled.Value;
        restartPending = true;
    }

    internal static void ToggleProbe()
    {
        ProbeOnly.Value = !ProbeOnly.Value;
        restartPending = true;
    }

    internal static void SetMode(int mode)
    {
        Enabled.Value = mode != 0;
        if (mode != 0) ProbeOnly.Value = mode == 1;
        restartPending = true;
    }

    public override bool Unload()
    {
        Ready = false;
        EndRenderingScope();
        RenderingScope.Remove();
        patches?.UnpatchSelf();
        active?.Dispose();
        active = null;
        // Queued native tokens retain COM resources; the DLL stays loaded.
        return true;
    }

    private sealed class CameraState
    {
        internal readonly Camera Camera;
        internal readonly PostProcessLayer Layer;
        internal readonly bool Probe;
        internal readonly int SelectedQuality;
        private readonly DepthTextureMode oldDepth;
        private readonly PostProcessLayer.Antialiasing oldAA;
        private readonly bool oldFinalBlit, oldTransparentJitter, oldDynamicResolution, oldMsaa;
        private readonly RenderTexture? oldTarget;
        private readonly CTAA_PC? ctaa;
        private bool oldCtaaEnabled;
        internal readonly CommandBuffer FinalCommands;
        private readonly CommandBuffer hudlessCommands;
        private readonly Mesh displayTriangle;
        private readonly MaterialPropertyBlock displayProperties;
        private GameObject? displayObject;
        private Camera? displayCamera, displayOwner;
        private bool targetApplied;
        internal RenderTexture? SceneTarget;
        internal RenderTexture Color = null!, Depth = null!, Motion = null!, Output = null!, Presented = null!;
        internal RenderTexture Hudless = null!;
        internal IntPtr HudlessPtr;
        internal ulong HudlessSubmissions;
        internal int HudlessCaptureFrame = -1;
        internal int LastPresentationProbe = -1, LastImageDiagnostic = -1;
        internal IntPtr ColorPtr, DepthPtr, MotionPtr, OutputPtr;
        internal int PreparedFrame = -1, TemporalFrame = -1, RedirectedFrame = -1, LastQueueFrame = -1;
        internal int ContextFrame = -1, ContextWidth, ContextHeight, ContextScreenWidth, ContextScreenHeight;
        internal RenderTextureDescriptor ContextDescriptor;
        internal RenderTargetIdentifier ContextDestination;
        internal bool ContextFlip;
        private int outputWidth, outputHeight;
        internal int InputWidth, InputHeight;
        internal int DisplayWidth => outputWidth;
        internal int DisplayHeight => outputHeight;
        private RenderTextureFormat colorFormat;
        private readonly Queue<IntPtr> queuedTokens = new();
        private bool hasHistory;
        private CameraHistory previousHistory, pendingHistory;

        [Flags]
        private enum HistoryResetReason { None = 0, FirstFrame = 1, PostProcessRequest = 2, SceneChanged = 4, ProjectionCut = 8, CameraCut = 16, FrameGap = 32 }

        private struct CameraHistory
        {
            internal int Scene, Frame;
            internal float Near, Far, Fov, Aspect, OrthoSize, ShiftX, ShiftY;
            internal bool Orthographic;
            internal Vector3 Position;
            internal Quaternion Rotation;

            internal static CameraHistory Read(Camera camera)
            {
                var transform = camera.transform;
                var projection = camera.nonJitteredProjectionMatrix;
                return new CameraHistory
                {
                    Scene = SceneManager.GetActiveScene().handle, Frame = Time.frameCount,
                    Near = camera.nearClipPlane, Far = camera.farClipPlane, Fov = camera.fieldOfView,
                    Aspect = camera.aspect, Orthographic = camera.orthographic, OrthoSize = camera.orthographicSize,
                    ShiftX = projection.m02, ShiftY = projection.m12,
                    Position = transform.position, Rotation = transform.rotation
                };
            }
        }

        internal void PrepareHistory(TemporalAntialiasing temporal)
        {
            pendingHistory = CameraHistory.Read(Camera);
            var current = pendingHistory;
            var previous = previousHistory;
            var reason = temporal.m_ResetHistory ? HistoryResetReason.PostProcessRequest : HistoryResetReason.None;
            if (!hasHistory) reason |= HistoryResetReason.FirstFrame;
            else
            {
                if (current.Scene != previous.Scene) reason |= HistoryResetReason.SceneChanged;
                if (current.Frame > previous.Frame + 1) reason |= HistoryResetReason.FrameGap;
                // Jitter is excluded. Small continuous zoom/clip changes should not
                // discard history every frame; these thresholds detect actual cuts.
                if (current.Orthographic != previous.Orthographic ||
                    Mathf.Abs(current.Fov - previous.Fov) >= 5f ||
                    RelativeChange(current.Aspect, previous.Aspect, 0.01f) ||
                    RelativeChange(current.Near, previous.Near, 0.01f) ||
                    RelativeChange(current.Far, previous.Far, 0.01f) ||
                    (current.Orthographic && RelativeChange(current.OrthoSize, previous.OrthoSize, 0.1f)) ||
                    Mathf.Abs(current.ShiftX - previous.ShiftX) > 0.05f ||
                    Mathf.Abs(current.ShiftY - previous.ShiftY) > 0.05f)
                    reason |= HistoryResetReason.ProjectionCut;
                if ((current.Position - previous.Position).sqrMagnitude >= 100f ||
                    Quaternion.Angle(current.Rotation, previous.Rotation) >= 30f)
                    reason |= HistoryResetReason.CameraCut;
            }
            if (reason == HistoryResetReason.None) return;
            epoch++;
            Instance.Log.LogInfo($"Temporal history reset queued camera={Camera.GetInstanceID()} frame={current.Frame} epoch={epoch} reason={reason} scene={previous.Scene}->{current.Scene}; no texture reallocation requested.");
        }

        private static bool RelativeChange(float current, float previous, float fraction) =>
            Mathf.Abs(current - previous) > Mathf.Max(0.0001f, Mathf.Abs(previous) * fraction);

        internal void CommitHistory(TemporalAntialiasing temporal)
        {
            // The skipped PPv2 Render normally consumes this flag. Clear it only
            // after our own native event and output copy were successfully recorded.
            previousHistory = pendingHistory;
            hasHistory = true;
            temporal.m_ResetHistory = false;
        }

        internal CameraState(Camera camera, PostProcessLayer layer)
        {
            Camera = camera; Layer = layer;
            Probe = ProbeOnly.Value;
            SelectedQuality = Quality.Value;
            oldDepth = camera.depthTextureMode; oldAA = layer.antialiasingMode;
            oldFinalBlit = layer.finalBlitToCameraTarget; oldTarget = camera.targetTexture;
            oldTransparentJitter = camera.useJitteredProjectionMatrixForTransparentRendering;
            oldDynamicResolution = camera.allowDynamicResolution; oldMsaa = camera.allowMSAA;
            outputWidth = camera.pixelWidth; outputHeight = camera.pixelHeight;
            ctaa = camera.GetComponent<CTAA_PC>();
            oldCtaaEnabled = ctaa != null && ctaa.enabled;
            FinalCommands = new CommandBuffer { name = "Last Epoch final full-resolution display" };
            hudlessCommands = new CommandBuffer { name = "Last Epoch final main-camera HUDless capture" };
            Camera.AddCommandBuffer(CameraEvent.AfterEverything, hudlessCommands);
            displayTriangle = new Mesh { name = "LE final display triangle", hideFlags = HideFlags.HideAndDontSave };
            displayTriangle.vertices = new Vector3[] { new(0, 0, 0), new(0, 2, 0), new(2, 0, 0) };
            displayTriangle.uv = new Vector2[] { new(0, 0), new(0, 2), new(2, 0) };
            displayTriangle.triangles = new int[] { 0, 1, 2 };
            displayProperties = new MaterialPropertyBlock();
            UpdateDisplayOwner();
        }

        internal void Prepare()
        {
            FinalCommands.Clear();
            hudlessCommands.Clear();
            HudlessCaptureFrame = -1;
            UpdateDisplayOwner();
            SuppressCtaa();
            if (oldTarget != null) throw new InvalidOperationException("Scene camera already has an offscreen target; refusing to replace it");
            if (ExperimentalRenderScope && Camera.targetTexture != oldTarget) throw new InvalidOperationException("Scene camera target changed outside our rendering scope; refusing to overwrite it");
            if (!SystemInfo.supportsMotionVectors) throw new InvalidOperationException("Unity motion vectors unavailable");
            if (!Layer.temporalAntialiasing.IsSupported()) throw new InvalidOperationException("PPv2 temporal rendering is unsupported");
            Camera.depthTextureMode |= DepthTextureMode.Depth | DepthTextureMode.MotionVectors;
            Camera.allowDynamicResolution = false;
            Camera.allowMSAA = false;
            Layer.finalBlitToCameraTarget = false;
            Layer.antialiasingMode = PostProcessLayer.Antialiasing.TemporalAntialiasing;
            int w = Screen.width, h = Screen.height;
            if (w <= 0 || h <= 0) return;
            outputWidth = w; outputHeight = h;
            float scale = Probe ? 1f : Scale(SelectedQuality);
            if (scale < 0.999f)
            {
                int rw = Math.Max(64, ((int)(w * scale) + 1) & ~1);
                int rh = Math.Max(64, ((int)(h * scale) + 1) & ~1);
                if (SceneTarget == null || !SceneTarget.IsCreated() || SceneTarget.width != rw || SceneTarget.height != rh)
                {
                    Retire(SceneTarget);
                    SceneTarget = Make(rw, rh, Camera.allowHDR ? RenderTextureFormat.ARGBHalf : RenderTextureFormat.ARGB32, "LE scene", 24);
                    epoch++;
                }
                Camera.targetTexture = SceneTarget;
                targetApplied = true;
            }
            PreparedFrame = Time.frameCount;
        }

        internal void SuppressCtaa(bool resetMatrices = true)
        {
            if (ctaa == null || !ctaa.enabled) return;
            oldCtaaEnabled = true;
            ctaa.enabled = false;
            if (resetMatrices)
            {
                Camera.ResetProjectionMatrix();
                Camera.ResetWorldToCameraMatrix();
                Camera.nonJitteredProjectionMatrix = Camera.projectionMatrix;
            }
            epoch++;
            Instance.Log.LogInfo("CTAA disabled for this adapter session; PPv2 owns temporal jitter. Original enabled state will be restored.");
        }

        internal void EndRenderScope()
        {
            if (Camera != null)
            {
                if (targetApplied) Camera.targetTexture = oldTarget;
                if (VerifyPixels.Value && Time.frameCount % 300 == 0)
                    Instance.Log.LogInfo($"Render scope end frame={Time.frameCount} cameraPixels={Camera.pixelWidth}x{Camera.pixelHeight} target={DescribeTexture(Camera.targetTexture)}; full-size input/UI coordinates restored before next frame.");
            }
            if (displayCamera != null) displayCamera.enabled = false;
            targetApplied = false;
            PreparedFrame = -1;
        }

        internal void RecordNativeHudlessCapture()
        {
            if (!LateHudless.Value || Probe || faulted || Native.HudlessProviderVersion() != 1) return;
            IntPtr token = IntPtr.Zero;
            try
            {
                if (HDROutputSettings.main != null && HDROutputSettings.main.active)
                {
                    if (reported.Add("late-hudless-hdr")) Instance.Log.LogWarning("Late HUDless skipped: HDR output is outside the 8-bit SDR contract.");
                    return;
                }
                if (SceneTarget != null || InputWidth != outputWidth || InputHeight != outputHeight)
                    throw new InvalidOperationException("Native-resolution HUDless capture requires matching camera/display dimensions");
                EnsureHudless(outputWidth, outputHeight, QualitySettings.activeColorSpace == ColorSpace.Linear);
                token = Native.QueueHudless(Camera.GetInstanceID(), Time.frameCount, HudlessPtr);
                if (token == IntPtr.Zero) return;
                TrackToken(token);
                var cameraTarget = new RenderTargetIdentifier(BuiltinRenderTextureType.CameraTarget);
                // Resolve CameraTarget at MAIN camera AfterEverything, after its
                // complete image-effect chain and before later cameras/overlay UI.
                // Preserve Unity's normal OnRenderImage and presentation path.
                hudlessCommands.Blit(cameraTarget, new RenderTargetIdentifier(Hudless));
                hudlessCommands.IssuePluginEventAndData(renderEvent, 2, token);
                hudlessCommands.SetRenderTarget(cameraTarget);
                hudlessCommands.SetViewport(new Rect(0, 0, outputWidth, outputHeight));
                HudlessCaptureFrame = Time.frameCount;
                if (HudlessSubmissions++ % 300 == 0)
                    Instance.Log.LogInfo($"Main-camera AfterEverything HUDless queued camera={Camera.GetInstanceID()} frame={Time.frameCount} depth={Camera.depth} mask=0x{Camera.cullingMask:X8} capture={Hudless.format} sRGB={Hudless.sRGB} size={outputWidth}x{outputHeight}; engine presentation unchanged. Verify captured content and native acceptance before claiming UI separation.");
            }
            catch (Exception e)
            {
                // Optional capture failure must not alter the working DLAA path.
                hudlessCommands.Clear();
                HudlessCaptureFrame = -1;
                if (token != IntPtr.Zero) Native.CancelQueuedFrame(token);
                if (reported.Add("native-hudless-capture-error")) Instance.Log.LogWarning("Main-camera HUDless capture skipped: " + e);
            }
        }

        private void UpdateDisplayOwner()
        {
            if (DedicatedDisplayCamera.Value && displayCamera == null)
            {
                displayObject = new GameObject("Last Epoch Graphics display") { hideFlags = HideFlags.HideAndDontSave };
                UnityEngine.Object.DontDestroyOnLoad(displayObject);
                displayCamera = displayObject.AddComponent<Camera>();
                displayCamera.cullingMask = 0;
                displayCamera.clearFlags = CameraClearFlags.Nothing;
                displayCamera.targetTexture = null;
                displayCamera.targetDisplay = Camera.targetDisplay;
                displayCamera.allowHDR = false;
                displayCamera.allowMSAA = false;
                displayCamera.allowDynamicResolution = false;
                displayCamera.forceIntoRenderTexture = false;
                displayCamera.depthTextureMode = DepthTextureMode.None;
                displayCamera.renderingPath = RenderingPath.Forward;
                displayCamera.rect = new Rect(0, 0, 1, 1);
            }
            if (displayCamera != null)
            {
                displayCamera.depth = Camera.depth + 0.01f;
                displayCamera.enabled = DedicatedDisplayCamera.Value;
            }
            var owner = DedicatedDisplayCamera.Value && displayCamera != null ? displayCamera : Camera;
            if (displayOwner == owner) return;
            if (displayOwner != null) displayOwner.RemoveCommandBuffer(CameraEvent.AfterEverything, FinalCommands);
            displayOwner = owner;
            displayOwner.AddCommandBuffer(CameraEvent.AfterEverything, FinalCommands);
            Instance.Log.LogInfo($"Final display command owner='{displayOwner.name}' depth={displayOwner.depth} dedicated={DedicatedDisplayCamera.Value}; main depth={Camera.depth}");
        }

        internal void RecordDisplay(RenderTexture source)
        {
            // CopyStd uses a normalized blit mesh. A property block explicitly
            // overrides its local MainTex property. Cancel its D3D UV inversion
            // to match PPv2's direct Display target UV transform=(1,1,0,0).
            displayProperties.Clear();
            displayProperties.SetTexture(Shader.PropertyToID("_MainTex"), source);
            displayProperties.SetVector(Shader.PropertyToID("_MainTex_ST"), new Vector4(1, -1, 0, 1));
            FinalCommands.SetRenderTarget(new RenderTargetIdentifier(Display.main.colorBuffer));
            FinalCommands.SetViewport(new Rect(0, 0, outputWidth, outputHeight));
            FinalCommands.DrawMesh(displayTriangle, Matrix4x4.identity, RuntimeUtilities.copyStdMaterial, 0, 0, displayProperties);
            if (VerifyPixels.Value && LastPresentationProbe == Time.frameCount)
            {
                var token = Native.QueueHudless(Camera.GetInstanceID(), Time.frameCount, source.GetNativeTexturePtr());
                if (token != IntPtr.Zero)
                {
                    TrackToken(token);
                    FinalCommands.IssuePluginEventAndData(renderEvent, 3, token);
                }
            }
        }

        internal void EnsureBuffers(int w, int h, RenderTextureFormat sourceFormat)
        {
            if (w <= 0 || h <= 0 || w > outputWidth || h > outputHeight)
                throw new InvalidOperationException($"Unexpected scene/output dimensions: {w}x{h} -> {outputWidth}x{outputHeight}");
            var format = RuntimeUtilities.isFloatingPointFormat(sourceFormat) ? RenderTextureFormat.ARGBHalf : RenderTextureFormat.ARGB32;
            if (BuffersAlive() && Color.width == w && Color.height == h &&
                Output.width == outputWidth && Output.height == outputHeight && colorFormat == format) return;
            Retire(Color); Retire(Depth); Retire(Motion); Retire(Output); Retire(Presented);
            Color = Make(w, h, format, "LE raw scene input");
            Depth = Make(w, h, RenderTextureFormat.RFloat, "LE raw depth input");
            Motion = Make(w, h, RenderTextureFormat.RGHalf, "LE raw motion input");
            Output = Make(outputWidth, outputHeight, RenderTextureFormat.ARGBHalf, "LE temporal output", 0, true);
            Presented = Make(outputWidth, outputHeight, RenderTextureFormat.ARGBHalf, "LE postprocessed output");
            ColorPtr = Color.GetNativeTexturePtr(); DepthPtr = Depth.GetNativeTexturePtr();
            MotionPtr = Motion.GetNativeTexturePtr(); OutputPtr = Output.GetNativeTexturePtr();
            colorFormat = format;
            InputWidth = w; InputHeight = h;
            epoch++;
            Instance.Log.LogInfo($"Persistent raw inputs {w}x{h} ({format}); reconstruction and postprocess output={outputWidth}x{outputHeight}; native texture handles captured");
        }

        internal bool BuffersAlive()
        {
            try
            {
                return Color != null && Depth != null && Motion != null && Output != null && Presented != null &&
                    Color.IsCreated() && Depth.IsCreated() && Motion.IsCreated() && Output.IsCreated() && Presented.IsCreated();
            }
            catch { return false; } // Scene unload can invalidate an IL2CPP wrapper before its next native call.
        }

        internal void TrackToken(IntPtr token)
        {
            // Usually these have already executed. Bound bookkeeping and reclaim
            // events from a camera command buffer Unity discarded during a scene cut.
            while (queuedTokens.Count >= 64) Native.CancelQueuedFrame(queuedTokens.Dequeue());
            queuedTokens.Enqueue(token);
        }

        internal void EnsureHudless(int w, int h, bool encodeSrgb)
        {
            if (Hudless != null && Hudless.IsCreated() && Hudless.width == w && Hudless.height == h && Hudless.sRGB == encodeSrgb) return;
            Retire(Hudless);
            Hudless = new RenderTexture(w, h, 0, RenderTextureFormat.ARGB32,
                encodeSrgb ? RenderTextureReadWrite.sRGB : RenderTextureReadWrite.Linear)
            { name = "LE encoded final scene", hideFlags = HideFlags.HideAndDontSave, useMipMap = false, autoGenerateMips = false, antiAliasing = 1, filterMode = FilterMode.Bilinear };
            if (!Hudless.Create() || Hudless.sRGB != encodeSrgb)
                throw new InvalidOperationException("Could not create the required SDR HUDless capture encoding");
            HudlessPtr = Hudless.GetNativeTexturePtr();
        }

        internal void Restore()
        {
            FinalCommands.Clear();
            hudlessCommands.Clear();
            if (Camera != null) Camera.RemoveCommandBuffer(CameraEvent.AfterEverything, hudlessCommands);
            if (displayOwner != null) displayOwner.RemoveCommandBuffer(CameraEvent.AfterEverything, FinalCommands);
            if (displayCamera != null) displayCamera.enabled = false;
            if (Camera != null)
            {
                if (targetApplied || (SceneTarget != null && Camera.targetTexture == SceneTarget)) Camera.targetTexture = oldTarget;
                Camera.depthTextureMode = oldDepth;
                Camera.allowDynamicResolution = oldDynamicResolution;
                Camera.allowMSAA = oldMsaa;
                Camera.ResetProjectionMatrix();
                Camera.nonJitteredProjectionMatrix = Camera.projectionMatrix;
                Camera.useJitteredProjectionMatrixForTransparentRendering = oldTransparentJitter;
                if (ctaa != null) ctaa.enabled = oldCtaaEnabled;
            }
            if (Layer != null)
            {
                Layer.antialiasingMode = oldAA;
                Layer.finalBlitToCameraTarget = oldFinalBlit;
                Layer.temporalAntialiasing.ResetHistory();
            }
        }

        internal void Dispose()
        {
            Restore();
            // The native registry atomically chooses either cancellation or render
            // consumption. An executing callback keeps its own COM references.
            while (queuedTokens.Count > 0) Native.CancelQueuedFrame(queuedTokens.Dequeue());
            Retire(SceneTarget); Retire(Color); Retire(Depth); Retire(Motion); Retire(Output); Retire(Presented); Retire(Hudless);
            FinalCommands.Release();
            hudlessCommands.Release();
            UnityEngine.Object.Destroy(displayTriangle);
            if (displayObject != null) UnityEngine.Object.Destroy(displayObject);
        }
    }

    private static float Scale(int quality) => quality switch { 0 => 0.5f, 1 => 0.58f, 2 => 2f / 3f, 3 => 1f / 3f, 4 => 0.77f, _ => 1f };
    // Unity defers destruction, and native tokens retain COM references. Never
    // Release() a RenderTexture while camera commands may still refer to it.
    private static void Retire(RenderTexture? texture) { if (texture != null) UnityEngine.Object.Destroy(texture); }
    private static RenderTexture Make(int w, int h, RenderTextureFormat format, string name, int depth = 0, bool random = false)
    {
        if (!SystemInfo.SupportsRenderTextureFormat(format)) throw new InvalidOperationException("Unsupported render texture format: " + format);
        var texture = new RenderTexture(w, h, depth, format, RenderTextureReadWrite.Linear)
        { name = name, hideFlags = HideFlags.HideAndDontSave, enableRandomWrite = random, useMipMap = false, autoGenerateMips = false, antiAliasing = 1, filterMode = FilterMode.Bilinear };
        if (!texture.Create()) { Retire(texture); throw new InvalidOperationException("Could not create " + name); }
        return texture;
    }
}

public sealed class Controls : MonoBehaviour
{
    public Controls(IntPtr ptr) : base(ptr) { }
    private bool visible;
    public void Update()
    {
        if (Input.GetKeyDown(KeyCode.F10)) visible = !visible;
        Plugin.Tick();
    }
    public void OnGUI()
    {
        if (!visible) return;
        GUI.Box(new Rect(20, 20, 850, 172), "Last Epoch Graphics · prototype 0.1");
        GUI.Label(new Rect(32, 46, 824, 28), Plugin.Status);
        GUI.Label(new Rect(32, 74, 824, 26), Plugin.Metrics);
        GUI.Label(new Rect(32, 102, 824, 26), "Session controls · F10 hides/shows this panel");
        if (GUI.Button(new Rect(32, 134, 160, 34), "Original renderer")) Plugin.SetMode(0);
        if (GUI.Button(new Rect(204, 134, 160, 34), "Probe inputs")) Plugin.SetMode(1);
        if (GUI.Button(new Rect(376, 134, 180, 34), "Reconstruction")) Plugin.SetMode(2);
        Plugin.LateHudless.Value = GUI.Toggle(new Rect(572, 140, 278, 26), Plugin.LateHudless.Value, "Late HUDless (session)");
        Plugin.DedicatedDisplayCamera.Value = GUI.Toggle(new Rect(572, 106, 278, 26), Plugin.DedicatedDisplayCamera.Value, "Separate display camera");
    }
}

