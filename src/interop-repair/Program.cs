using System;
using System.Diagnostics;
using System.IO;
using LastEpoch.LoaderDiagnostics;

if (args.Length != 2 || args[0] != "--bepinex-root")
{
    Console.Error.WriteLine("Usage: LastEpoch.InteropRepair --bepinex-root <game BepInEx directory>");
    return 2;
}
try
{
    if (Process.GetProcessesByName("Last Epoch").Length != 0)
        throw new InvalidOperationException("Close Last Epoch before normalizing generated interop files.");
    var root = Path.GetFullPath(args[1]);
    if (!string.Equals(Path.GetFileName(root.TrimEnd(Path.DirectorySeparatorChar)), "BepInEx", StringComparison.OrdinalIgnoreCase))
        throw new InvalidOperationException("Expected a BepInEx directory.");
    CoreModuleRepair.RepairGeneratedModule(root, Console.WriteLine);
    return 0;
}
catch (Exception exception)
{
    Console.Error.WriteLine(exception);
    return 1;
}
