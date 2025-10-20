using System.Diagnostics;
using System.Linq;

namespace UiTestsPlayground.Helpers;

internal static class CodetracerLauncher
{
    public static readonly string RepoRoot =
        Environment.GetEnvironmentVariable("CODETRACER_REPO_ROOT_PATH") ??
        Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", ".."));

    public static string CtPath { get; } =
        Environment.GetEnvironmentVariable("CODETRACER_E2E_CT_PATH") ??
        Path.Combine(
            Environment.GetEnvironmentVariable("NIX_CODETRACER_EXE_DIR") ??
            Path.Combine(RepoRoot, "src", "build-debug"),
            "bin", "ct");

    public static string CtInstallDir { get; } = Path.GetDirectoryName(CtPath)!;

    private static readonly string ProgramsDir = Path.Combine(RepoRoot, "test-programs");

    private static readonly string DefaultTraceDirectory =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            ".local", "share", "codetracer");

    public static bool IsCtAvailable => File.Exists(CtPath);

    public static string GetTracePath(string? overridePath)
    {
        if (!string.IsNullOrWhiteSpace(overridePath))
        {
            return overridePath;
        }

        if (!Directory.Exists(DefaultTraceDirectory))
        {
            throw new DirectoryNotFoundException($"Default trace directory not found: {DefaultTraceDirectory}. Set CODETRACER_TRACE_PATH to a valid trace.");
        }

        var traces = Directory.GetDirectories(DefaultTraceDirectory, "trace-*", SearchOption.TopDirectoryOnly)
            .Select(path => (Path: path, Number: ParseTraceNumber(Path.GetFileName(path))))
            .Where(item => item.Number.HasValue)
            .Select(item => (item.Path, Number: item.Number!.Value))
            .OrderByDescending(item => item.Number)
            .ToList();

        if (traces.Count == 0)
        {
            throw new InvalidOperationException($"No trace directories found under {DefaultTraceDirectory}. Record a trace or set CODETRACER_TRACE_PATH.");
        }

        return traces.First().Path;
    }

    private static int? ParseTraceNumber(string? directoryName)
    {
        if (string.IsNullOrEmpty(directoryName))
        {
            return null;
        }

        var suffix = directoryName.Replace("trace-", string.Empty, StringComparison.OrdinalIgnoreCase);
        return int.TryParse(suffix, out var value) ? value : null;
    }

    public static int RecordProgram(string relativePath)
    {
        var psi = new ProcessStartInfo(CtPath, $"record {Path.Combine(ProgramsDir, relativePath)}")
        {
            WorkingDirectory = CtInstallDir,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false
        };

        using var proc = Process.Start(psi)!;
        proc.WaitForExit();
        var lines = proc.StandardOutput.ReadToEnd().Trim().Split('\n', StringSplitOptions.RemoveEmptyEntries);
        var lastLine = lines.Last();
        return int.Parse(lastLine.Split(':')[1].Trim());
    }
}
