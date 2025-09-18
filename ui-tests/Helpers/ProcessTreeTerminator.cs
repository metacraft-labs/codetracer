using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Threading.Tasks;

namespace UiTests.Helpers;

/// <summary>
/// Provides cross-platform helpers for terminating CodeTracer process trees
/// that are spawned during UI tests.
/// </summary>
internal static class ProcessTreeTerminator
{
    private static readonly TimeSpan WaitTimeout = TimeSpan.FromSeconds(10);

    /// <summary>
    /// Closes the associated Playwright resources and terminates the
    /// underlying CodeTracer process tree.
    /// </summary>
    public static async Task TerminateAsync(CodeTracerSession session)
    {
        ArgumentNullException.ThrowIfNull(session);

        await CloseBrowserAsync(session);
        TerminateProcessTree(session.RootProcess);
    }

    private static async Task CloseBrowserAsync(CodeTracerSession session)
    {
        try
        {
            await session.Browser.CloseAsync();
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"Failed to close Playwright browser for session {session.RootProcess.Id}: {ex}");
        }

        try
        {
            await session.Browser.DisposeAsync();
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"Failed to dispose Playwright browser for session {session.RootProcess.Id}: {ex}");
        }

        try
        {
            session.Playwright.Dispose();
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"Failed to dispose Playwright runtime for session {session.RootProcess.Id}: {ex}");
        }
    }

    private static void TerminateProcessTree(Process root)
    {
        ArgumentNullException.ThrowIfNull(root);

        if (root.HasExited)
        {
            root.Dispose();
            return;
        }

        if (OperatingSystem.IsWindows())
        {
            TryKillProcess(root, entireProcessTree: true);
        }
        else if (OperatingSystem.IsLinux() || OperatingSystem.IsMacOS())
        {
            KillUnixDescendants(root.Id);
            TryKillProcess(root, entireProcessTree: false);
        }
        else
        {
            TryKillProcess(root, entireProcessTree: true);
        }

        WaitForExit(root);
        root.Dispose();
    }

    private static void KillUnixDescendants(int rootPid)
    {
        Dictionary<int, List<int>> processTree;
        try
        {
            processTree = BuildParentChildMap();
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"Failed to enumerate descendants for PID {rootPid}: {ex}");
            return;
        }

        if (!processTree.TryGetValue(rootPid, out var children))
        {
            return;
        }

        var visited = new HashSet<int>();
        foreach (var child in children)
        {
            KillUnixDescendantRecursive(child, processTree, visited);
        }
    }

    private static void KillUnixDescendantRecursive(int pid, Dictionary<int, List<int>> tree, HashSet<int> visited)
    {
        if (!visited.Add(pid))
        {
            return;
        }

        if (tree.TryGetValue(pid, out var children))
        {
            foreach (var child in children)
            {
                KillUnixDescendantRecursive(child, tree, visited);
            }
        }

        TryKillPid(pid);
    }

    private static Dictionary<int, List<int>> BuildParentChildMap()
    {
        var psi = new ProcessStartInfo("ps")
        {
            ArgumentList = { "-eo", "pid=,ppid=" },
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
        };

        using var process = Process.Start(psi) ?? throw new InvalidOperationException("Failed to start 'ps'.");
        string output = process.StandardOutput.ReadToEnd();
        process.WaitForExit();

        var map = new Dictionary<int, List<int>>();
        foreach (var line in output.Split('\n', StringSplitOptions.RemoveEmptyEntries))
        {
            var parts = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length < 2)
            {
                continue;
            }

            if (!int.TryParse(parts[0], NumberStyles.Integer, CultureInfo.InvariantCulture, out int pid))
            {
                continue;
            }

            if (!int.TryParse(parts[1], NumberStyles.Integer, CultureInfo.InvariantCulture, out int ppid))
            {
                continue;
            }

            if (!map.TryGetValue(ppid, out var children))
            {
                children = new List<int>();
                map[ppid] = children;
            }

            children.Add(pid);
        }

        return map;
    }

    private static void TryKillPid(int pid)
    {
        try
        {
            using var process = Process.GetProcessById(pid);
            if (process.HasExited)
            {
                return;
            }

            process.Kill();
            process.WaitForExit((int)WaitTimeout.TotalMilliseconds);
        }
        catch (ArgumentException)
        {
            // Process already exited.
        }
        catch (InvalidOperationException)
        {
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"Failed to kill child process {pid}: {ex}");
        }
    }

    private static void TryKillProcess(Process process, bool entireProcessTree)
    {
        try
        {
            if (process.HasExited)
            {
                return;
            }

            if (entireProcessTree)
            {
                process.Kill(entireProcessTree: true);
            }
            else
            {
                process.Kill();
            }
        }
        catch (InvalidOperationException)
        {
        }
        catch (PlatformNotSupportedException)
        {
            if (entireProcessTree)
            {
                TryKillProcess(process, entireProcessTree: false);
            }
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"Failed to kill process {process.Id}: {ex}");
        }
    }

    private static void WaitForExit(Process process)
    {
        try
        {
            if (process.WaitForExit((int)WaitTimeout.TotalMilliseconds))
            {
                return;
            }

            process.Refresh();
            if (!process.HasExited)
            {
                TryKillProcess(process, entireProcessTree: false);
                process.WaitForExit((int)WaitTimeout.TotalMilliseconds);
            }
        }
        catch (InvalidOperationException)
        {
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"Failed while waiting for process {process.Id} to exit: {ex}");
        }
    }
}
