using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text.Json;
using Mono.Cecil;

namespace LastEpoch.LoaderDiagnostics;

internal static class CoreModuleRepair
{
    // These empty compiler delegate-cache helpers were observed in Last Epoch's
    // Unity 6000.4.8 interop output. The serialized module fails .NET 6 loading
    // with Duplicate type '<>O'; Cecil's unchanged read/write normalizes it.
    // No helper, method, field or other game definition is removed by this repair.
    private static readonly HashSet<string> KnownHelpers = new(StringComparer.Ordinal)
    {
        "UnityEngine.Awaitable/<>O",
        "UnityEngine.Playables.ScriptPlayableBinding/<>O",
        "UnityEngine.Rendering.ShaderKeywordSet/<>O",
        "UnityEngine.U2D.SpriteAtlasManager/<>O",
        "UnityEngine.CrashReport/<>O",
        "UnityEngine.Experimental.Playables.TexturePlayableBinding/<>O"
    };

    internal static bool IsNormalized(string bepinexRoot)
    {
        var inputPath = Path.Combine(Path.GetFullPath(bepinexRoot), "interop", "UnityEngine.CoreModule.dll");
        var recordPath = Path.Combine(Path.GetFullPath(bepinexRoot), "LastEpochGraphics", "interop-backups", "CoreModule-normalization.json");
        RejectReparsePoints(inputPath);
        RejectReparsePoints(recordPath);
        if (!File.Exists(inputPath) || !File.Exists(recordPath)) return false;
        using var record = JsonDocument.Parse(File.ReadAllBytes(recordPath));
        return record.RootElement.GetProperty("normalizedSha256").GetString() == Hash(File.ReadAllBytes(inputPath));
    }

    internal static void RepairGeneratedModule(string bepinexRoot, Action<string> log)
    {
        var root = Path.GetFullPath(bepinexRoot);
        var inputPath = Path.Combine(root, "interop", "UnityEngine.CoreModule.dll");
        var backupDirectory = Path.Combine(root, "LastEpochGraphics", "interop-backups");
        var recordPath = Path.Combine(backupDirectory, "CoreModule-normalization.json");
        RejectReparsePoints(inputPath);
        RejectReparsePoints(backupDirectory);
        RejectReparsePoints(recordPath);
        if (!File.Exists(inputPath)) { log("No generated CoreModule is available to normalize."); return; }
        var original = File.ReadAllBytes(inputPath);
        var originalHash = Hash(original);
        if (File.Exists(recordPath))
        {
            using var record = JsonDocument.Parse(File.ReadAllBytes(recordPath));
            if (record.RootElement.GetProperty("normalizedSha256").GetString() == originalHash)
            {
                log($"Generated CoreModule already normalized ({originalHash}).");
                return;
            }
        }
        var normalized = NormalizeGeneratedModule(original);
        var normalizedHash = Hash(normalized);
        Directory.CreateDirectory(backupDirectory);
        var backupPath = Path.Combine(backupDirectory, "UnityEngine.CoreModule." + originalHash + ".original.dll");
        RejectReparsePoints(backupPath);
        if (!File.Exists(backupPath))
        {
            using var backup = new FileStream(backupPath, FileMode.CreateNew, FileAccess.Write, FileShare.Read);
            backup.Write(original);
            backup.Flush(true);
        }
        if (Hash(File.ReadAllBytes(backupPath)) != originalHash) throw new IOException("Generated-wrapper backup hash mismatch.");
        var temporaryPath = inputPath + ".le-normalize-" + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            using (var temporary = new FileStream(temporaryPath, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                temporary.Write(normalized);
                temporary.Flush(true);
            }
            if (Hash(File.ReadAllBytes(inputPath)) != originalHash) throw new IOException("Generated CoreModule changed during normalization.");
            File.Move(temporaryPath, inputPath, true);
            if (Hash(File.ReadAllBytes(inputPath)) != normalizedHash) throw new IOException("Normalized wrapper hash mismatch.");
            var record = JsonSerializer.Serialize(new
            {
                schemaVersion = 1,
                assembly = "UnityEngine.CoreModule",
                originalSha256 = originalHash,
                normalizedSha256 = normalizedHash,
                originalBackup = Path.GetFileName(backupPath),
                normalizedAtUtc = DateTime.UtcNow.ToString("o"),
                operation = "Mono.Cecil unchanged semantic read/write; no definitions removed"
            }, new JsonSerializerOptions { WriteIndented = true });
            var recordTemp = recordPath + "." + Guid.NewGuid().ToString("N") + ".tmp";
            File.WriteAllText(recordTemp, record);
            File.Move(recordTemp, recordPath, true);
            log($"Normalized generated CoreModule metadata; all definitions preserved. Original SHA256={originalHash}; new SHA256={normalizedHash}; backup={backupPath}");
        }
        finally { if (File.Exists(temporaryPath)) File.Delete(temporaryPath); }
    }

    internal static byte[] NormalizeGeneratedModule(byte[] original)
    {
        using var input = new MemoryStream(original, false);
        using var assembly = AssemblyDefinition.ReadAssembly(input, new ReaderParameters { InMemory = true, ReadSymbols = false });
        if (assembly.Name.Name != "UnityEngine.CoreModule" || assembly.Name.Version != new Version(0, 0, 0, 0) ||
            !assembly.MainModule.AssemblyReferences.Any(reference => reference.Name == "Il2CppInterop.Runtime"))
            throw new InvalidDataException("Refusing to normalize anything except a generated Il2CppInterop CoreModule wrapper.");
        var types = assembly.MainModule.GetTypes().ToArray();
        var helpers = types.Where(type => type.Name == "<>O").ToArray();
        if (helpers.Length != KnownHelpers.Count || helpers.Any(type => !KnownHelpers.Contains(type.FullName) ||
            !type.IsNested || !type.IsAbstract || !type.IsSealed || type.HasFields || type.HasMethods ||
            type.HasProperties || type.HasEvents || type.HasInterfaces || type.HasGenericParameters || type.HasNestedTypes))
            throw new InvalidDataException("CoreModule helper layout differs from the validated Unity 6000.4 case; leaving it unchanged.");
        var before = DescribeSymbols(assembly);
        using var output = new MemoryStream();
        assembly.Write(output);
        var normalized = output.ToArray();
        using var verifyStream = new MemoryStream(normalized, false);
        using var verification = AssemblyDefinition.ReadAssembly(verifyStream);
        if (!before.SequenceEqual(DescribeSymbols(verification)))
            throw new InvalidDataException("Cecil normalization changed semantic definitions; refusing replacement.");
        return normalized;
    }

    private static string[] DescribeSymbols(AssemblyDefinition assembly) => assembly.MainModule.GetTypes()
        .SelectMany(type => new[] { $"T:{type.FullName}:{(int)type.Attributes}:{type.BaseType?.FullName}" }
            .Concat(type.Fields.Select(field => $"F:{field.FullName}:{(int)field.Attributes}"))
            .Concat(type.Methods.Select(method => $"M:{method.FullName}:{(int)method.Attributes}"))
            .Concat(type.Properties.Select(property => $"P:{property.FullName}"))
            .Concat(type.Events.Select(@event => $"E:{@event.FullName}")))
        .OrderBy(symbol => symbol, StringComparer.Ordinal).ToArray();

    private static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();

    private static void RejectReparsePoints(string path)
    {
        for (var current = Path.GetFullPath(path); !string.IsNullOrEmpty(current); current = Path.GetDirectoryName(current))
            if ((File.Exists(current) || Directory.Exists(current)) && (File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
                throw new IOException("Refusing generated-wrapper repair through a junction or symbolic link: " + current);
    }
}
