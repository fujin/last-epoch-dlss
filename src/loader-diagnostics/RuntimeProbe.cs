using System;
using System.IO;
using System.Reflection;
using System.Runtime.Loader;

namespace LastEpoch.LoaderDiagnostics;

// Optional standalone entry point for inspecting loader failures without starting the game.
public static class RuntimeProbe
{
    public static int Main(string[] args)
    {
        Console.WriteLine($"Runtime: {Environment.Version}");
        if (args.Length is < 1 or > 2) { Console.Error.WriteLine("Supply BepInEx directory and optional CoreModule probe file."); return 2; }
        var root = Path.GetFullPath(args[0]);
        AssemblyLoadContext.Default.Resolving += (context, name) =>
        {
            foreach (var dir in new[] { "interop", "core" })
            {
                var path = Path.Combine(root, dir, name.Name + ".dll");
                if (!File.Exists(path)) continue;
                try { return context.LoadFromAssemblyPath(path); }
                catch (Exception exception) { Console.Error.WriteLine($"RESOLVE {name}: {exception}"); }
            }
            return null;
        };
        if (args.Length == 2 && args[1] == "--normalize-copy")
        {
            // Produces a workspace diagnostic copy only; never modifies the source file.
            var originalPath = Path.Combine(root, "interop", "UnityEngine.CoreModule.dll");
            var normalizedPath = Path.Combine(AppContext.BaseDirectory, "UnityEngine.CoreModule.normalized.dll");
            File.WriteAllBytes(normalizedPath, CoreModuleRepair.NormalizeGeneratedModule(File.ReadAllBytes(originalPath)));
            args[1] = normalizedPath;
            Console.WriteLine($"Normalized test copy: {normalizedPath}");
        }
        try
        {
            foreach (var name in new[] { "Il2Cppmscorlib", "Unity.Scripting", "UnityEngine.CoreModule" })
            {
                var path = name == "UnityEngine.CoreModule" && args.Length == 2 ? Path.GetFullPath(args[1]) : Path.Combine(root, "interop", name + ".dll");
                var assembly = Assembly.LoadFrom(path);
                Console.WriteLine($"Loaded {assembly.FullName}");
            }
            var core = Assembly.Load("UnityEngine.CoreModule");
            Console.WriteLine($"Application: {core.GetType("UnityEngine.Application", true, false)}");
            Console.WriteLine($"Camera: {core.GetType("UnityEngine.Camera", true, false)}");
            return 0;
        }
        catch (Exception exception) { Console.Error.WriteLine(exception); return 1; }
    }
}
