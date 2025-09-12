using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.Playwright;
using OpenQA.Selenium;
using OpenQA.Selenium.Chrome;

namespace UiTests.Helpers;

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

    public static bool IsCtAvailable => File.Exists(CtPath);

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
        var lines = proc.StandardOutput.ReadToEnd().Trim().Split('\n');
        var last = lines.Last();
        var lastLine = last;
        return int.Parse(last.Split(':')[1].Trim());
    }

    public static void StartCore(int traceId, int runPid)
    {
        var psi = new ProcessStartInfo(CtPath)
        {
            WorkingDirectory = CtInstallDir,
            CreateNoWindow = true,
            UseShellExecute = true,
            ArgumentList = { "start_core", $"{traceId}", $"{runPid}" },
        };
        Process.Start(psi);

        Thread.Sleep(5000);
    }
}

