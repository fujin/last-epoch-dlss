using System;
using System.Collections.Generic;
using Il2CppInterop.Runtime;
using Il2CppInterop.Runtime.Injection;
using Il2CppInterop.Runtime.InteropTypes.Arrays;
using UnityEngine.LowLevel;

namespace LastEpochGraphics;

// Unique IL2CPP marker types let us remove only our own nodes from the current
// loop, preserving Last Epoch's custom update system and other modifications.
public sealed class SceneRenderBeginMarker : Il2CppSystem.Object
{
    public SceneRenderBeginMarker(IntPtr pointer) : base(pointer) { }
}
public sealed class SceneRenderEndMarker : Il2CppSystem.Object
{
    public SceneRenderEndMarker(IntPtr pointer) : base(pointer) { }
}

internal static class RenderingScope
{
    private static PlayerLoopSystem.UpdateFunction? begin, end;
    private static bool initialized, editing;
    private const string BeginName = "LastEpochGraphics.SceneRenderBeginMarker";
    private const string EndName = "LastEpochGraphics.SceneRenderEndMarker";

    internal static void Initialize(Action beforeRendering, Action afterRendering)
    {
        ClassInjector.RegisterTypeInIl2Cpp<SceneRenderBeginMarker>();
        ClassInjector.RegisterTypeInIl2Cpp<SceneRenderEndMarker>();
        begin = beforeRendering;
        end = afterRendering;
        initialized = true;
        Reinstall();
    }

    internal static void OnLoopChanged()
    {
        if (initialized && !editing) Reinstall();
    }

    private static bool IsOurs(PlayerLoopSystem system)
    {
        var name = system.type?.FullName;
        return name == BeginName || name == EndName;
    }

    private static void RemoveOwnNodes(PlayerLoopSystem parent)
    {
        var children = parent.subSystemList;
        if (children == null) return;
        var kept = new List<PlayerLoopSystem>();
        foreach (var child in children)
        {
            if (IsOurs(child)) continue;
            RemoveOwnNodes(child);
            kept.Add(child);
        }
        parent.subSystemList = new Il2CppReferenceArray<PlayerLoopSystem>(kept.ToArray());
    }

    private static bool Insert(PlayerLoopSystem parent)
    {
        var children = parent.subSystemList;
        if (children == null) return false;
        if (parent.type?.FullName == "UnityEngine.PlayerLoop.PostLateUpdate")
        {
            var expanded = new List<PlayerLoopSystem>();
            int beginIndex = -1, endIndex = -1;
            foreach (var child in children)
            {
                if (child.type?.Name == "UpdateAllRenderers")
                {
                    beginIndex = expanded.Count;
                    expanded.Add(new PlayerLoopSystem { type = Il2CppType.Of<SceneRenderBeginMarker>(), updateDelegate = begin });
                }
                expanded.Add(child);
                if (child.type?.Name == "FinishFrameRendering")
                {
                    endIndex = expanded.Count;
                    expanded.Add(new PlayerLoopSystem { type = Il2CppType.Of<SceneRenderEndMarker>(), updateDelegate = end });
                }
            }
            if (beginIndex < 0 || endIndex <= beginIndex)
                throw new InvalidOperationException("Expected UpdateAllRenderers→FinishFrameRendering loop interval was not found");
            parent.subSystemList = new Il2CppReferenceArray<PlayerLoopSystem>(expanded.ToArray());
            return true;
        }
        for (int i = 0; i < children.Length; i++)
        {
            var child = children[i];
            if (!Insert(child)) continue;
            // PlayerLoopSystem is an IL2CPP value type exposed through a boxed
            // interop wrapper. Write the modified value back into its parent.
            children[i] = child;
            return true;
        }
        return false;
    }

    private static void Reinstall()
    {
        editing = true;
        try
        {
            var current = PlayerLoop.GetCurrentPlayerLoop();
            RemoveOwnNodes(current);
            if (!Insert(current)) throw new InvalidOperationException("PostLateUpdate loop not found");
            PlayerLoop.SetPlayerLoop(current);
            Plugin.Instance.Log.LogInfo("Render-only target scope installed into CURRENT PlayerLoop: before UpdateAllRenderers, after FinishFrameRendering.");
        }
        finally { editing = false; }
    }

    internal static void Remove()
    {
        if (!initialized) return;
        initialized = false;
        editing = true;
        try
        {
            var current = PlayerLoop.GetCurrentPlayerLoop();
            RemoveOwnNodes(current);
            PlayerLoop.SetPlayerLoop(current);
        }
        finally { editing = false; }
        // Keep the bridge delegates rooted: Unity may finish an already-snapshotted
        // loop once during unload. Plugin's callbacks check Ready before doing work.
    }
}
