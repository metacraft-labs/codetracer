using System.Diagnostics;

namespace UiTestsPlayground.Helpers;

/// <summary>
/// Provides helpers for inspecting and terminating stray CodeTracer processes between test runs.
/// </summary>
internal static class ProcessUtilities
{
    private static readonly string[] ProcessNames =
        { "ct", "electron", "backend-manager", "virtualization-layers", "node" };

    /// <summary>
    /// Logs the number of running processes that could interfere with UI test runs.
    /// </summary>
    public static void ReportProcessCounts()
    {
        foreach (var name in ProcessNames)
        {
            var count = Process.GetProcessesByName(name).Length;
            Console.WriteLine($"Process '{name}': {count} instance(s).");
        }
    }

    /// <summary>
    /// Forcefully terminates lingering CodeTracer related processes to guarantee a clean slate
    /// before or after executing UI scenarios.
    /// </summary>
    /// <param name="reason">Context string used to annotate the console output.</param>
    public static void KillProcesses(string reason)
    {
        foreach (var name in ProcessNames)
        {
            foreach (var process in Process.GetProcessesByName(name))
            {
                try
                {
                    Console.WriteLine($"[{reason}] Killing process {name} (PID {process.Id}).");
                    process.Kill(entireProcessTree: true);
                    process.WaitForExit(5000);
                }
                catch
                {
                    // Ignore failures while best-effort killing processes.
                }
                finally
                {
                    process.Dispose();
                }
            }
        }
    }
}
