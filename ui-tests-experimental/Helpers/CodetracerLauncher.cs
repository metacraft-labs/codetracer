using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.Playwright;

namespace UiTestsExperimental.Helpers
{
    public static class CodetracerLauncher
    {
        private static readonly string RepoRoot =
            Environment.GetEnvironmentVariable("CODETRACER_REPO_ROOT_PATH") ??
            Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", ".."));

        public static string CtPath { get; } =
            Environment.GetEnvironmentVariable("CODETRACER_E2E_CT_PATH") ??
            Path.Combine(
                Environment.GetEnvironmentVariable("NIX_CODETRACER_EXE_DIR") ??
                Path.Combine(RepoRoot, "src", "build-debug"),
                "bin", "ct");

        private static readonly string CtInstallDir = Path.GetDirectoryName(CtPath)!;
        private static readonly string ProgramsDir = Path.Combine(RepoRoot, "ui-tests", "programs");

        public static bool IsCtAvailable => File.Exists(CtPath);

        public static async Task<IPage> LaunchAsync(string programRelativePath)
        {
            if (!IsCtAvailable)
                throw new FileNotFoundException($"ct executable not found at {CtPath}");

            int traceId = RecordProgram(programRelativePath);
            StartCore(traceId, 1);

            var playwright = await Playwright.CreateAsync();
            var app = await ((dynamic)playwright)._electron.LaunchAsync(new
            {
                executablePath = CtPath,
                cwd = CtInstallDir,
                env = new
                {
                    CODETRACER_CALLER_PID = "1",
                    CODETRACER_TRACE_ID = traceId.ToString(),
                    CODETRACER_IN_UI_TEST = "1",
                    CODETRACER_TEST = "1",
                    CODETRACER_WRAP_ELECTRON = "1",
                    CODETRACER_START_INDEX = "1"
                }
            });

            var firstWindow = await app.FirstWindowAsync();
            return (await firstWindow.TitleAsync()) == "DevTools"
                ? (await app.WindowsAsync())[1]
                : firstWindow;
        }

        private static int RecordProgram(string relativePath)
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
            return int.Parse(last.Split(':')[1].Trim());
        }

        private static void StartCore(int traceId, int runPid)
        {
            var psi = new ProcessStartInfo(CtPath, $"start_core {traceId} {runPid}")
            {
                WorkingDirectory = CtInstallDir
            };
            Process.Start(psi);
        }
    }
}

