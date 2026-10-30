using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Runtime.Loader;
using BepInEx;
using BepInEx.Preloader.Core.Patching;

namespace LastEpoch.LoaderDiagnostics;

// No Unity/Il2Cpp type references: this patcher must load even when the generated
// interop assemblies cannot yet be resolved by the ordinary chainloader.
[PatcherPluginInfo("local.lastepoch.loaderdiagnostics", "LE Loader Diagnostics", "0.1.0")]
public sealed class LoaderDiagnostics : BasePatcher
{
    [ThreadStatic] private static HashSet<string>? resolving;
    private string interopDirectory = "";

    public override void Initialize()
    {
        interopDirectory = Path.Combine(Paths.BepInExRootPath, "interop");
        // Interop modules may already be memory mapped by this stage. The external
        // launcher normalizes them while the game is stopped; here we only verify.
        try
        {
            if (CoreModuleRepair.IsNormalized(Paths.BepInExRootPath)) Log.LogInfo("External CoreModule normalization verified.");
            else Log.LogWarning("CoreModule is not recorded as normalized. Close the game and use Launch-Offline.ps1 once to repair generated metadata.");
        }
        catch (Exception exception) { Log.LogError($"Generated CoreModule normalization verification failed: {exception}"); }
        var ownContext = AssemblyLoadContext.GetLoadContext(typeof(BasePatcher).Assembly) ?? AssemblyLoadContext.Default;
        Log.LogInfo($"CLR {Environment.Version}; interop={interopDirectory}; BepInEx context={ownContext.Name ?? "<unnamed>"}; default={ReferenceEquals(ownContext, AssemblyLoadContext.Default)}");

        // Capture the exception BepInEx.Utility.TryResolveDllAssembly suppresses.
        var corePath = Path.Combine(interopDirectory, "UnityEngine.CoreModule.dll");
        Log.LogInfo($"CoreModule exists={File.Exists(corePath)}");
        try
        {
            Log.LogInfo($"CoreModule on-disk identity: {AssemblyName.GetAssemblyName(corePath).FullName}");
            var assembly = Assembly.LoadFrom(corePath);
            Log.LogInfo($"Direct Assembly.LoadFrom succeeded: {assembly.FullName}; context={AssemblyLoadContext.GetLoadContext(assembly)?.Name}");
        }
        catch (Exception exception)
        {
            Log.LogError($"Direct Assembly.LoadFrom failed: {exception}");
        }

        // Resolve only generated Unity/Il2Cpp wrappers in the requesting load context.
        // Core framework and BepInEx assemblies remain owned by their original resolver.
        ownContext.Resolving += ResolveGeneratedAssembly;
        if (!ReferenceEquals(ownContext, AssemblyLoadContext.Default))
            AssemblyLoadContext.Default.Resolving += ResolveGeneratedAssembly;

        foreach (var name in new[] { "Il2Cppmscorlib", "Unity.Scripting", "UnityEngine.CoreModule" })
        {
            try
            {
                var loaded = ownContext.LoadFromAssemblyPath(Path.Combine(interopDirectory, name + ".dll"));
                Log.LogInfo($"Preloaded {loaded.FullName}; context={AssemblyLoadContext.GetLoadContext(loaded)?.Name}");
            }
            catch (Exception exception)
            {
                Log.LogError($"Context preload {name} failed: {exception}");
            }
        }
        try
        {
            var core = ownContext.LoadFromAssemblyName(new AssemblyName("UnityEngine.CoreModule, Version=0.0.0.0, Culture=neutral, PublicKeyToken=null"));
            var application = core.GetType("UnityEngine.Application", true, false);
            Log.LogInfo($"Unity Application type resolved without invoking it: {application?.FullName}");
        }
        catch (Exception exception)
        {
            Log.LogError($"Unity Application reflection probe failed: {exception}");
        }
    }

    private Assembly? ResolveGeneratedAssembly(AssemblyLoadContext context, AssemblyName requested)
    {
        var name = requested.Name;
        if (name is null || !(name.StartsWith("UnityEngine", StringComparison.Ordinal) ||
                             name.StartsWith("Il2Cpp", StringComparison.Ordinal) || name == "Unity.Scripting"))
            return null;
        if (name.IndexOfAny(new[] { '\\', '/', ':' }) >= 0) return null;
        var path = Path.Combine(interopDirectory, name + ".dll");
        if (!File.Exists(path)) return null;
        resolving ??= new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        if (!resolving.Add(name)) return null;
        try
        {
            var loaded = context.LoadFromAssemblyPath(path);
            Log.LogInfo($"Resolved {requested.FullName} in context {context.Name ?? "<unnamed>"}: {loaded.Location}");
            return loaded;
        }
        catch (Exception exception)
        {
            Log.LogError($"Explicit resolver failed for {requested.FullName}: {exception}");
            return null;
        }
        finally { resolving.Remove(name); }
    }
}
