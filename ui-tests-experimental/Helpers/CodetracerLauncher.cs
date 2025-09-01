using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.Playwright;
using OpenQA.Selenium;
using OpenQA.Selenium.Chrome;

namespace UtTestsExperimentalConsoleAppication.Helpers;

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

    private static readonly string ProgramsDir = Path.Combine(RepoRoot, "ui-tests", "programs");

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

public static class PlaywrightCodetracerLauncher
{
    public static string CtPath => CodetracerLauncher.CtPath;
    public static bool IsCtAvailable => CodetracerLauncher.IsCtAvailable;

    public static async Task<IBrowser> LaunchAsync(string programRelativePath)
    {
        if (!IsCtAvailable)
            throw new FileNotFoundException($"ct executable not found at {CtPath}");

        int traceId = CodetracerLauncher.RecordProgram(programRelativePath);

        var info = new ProcessStartInfo(CtPath)
        {
            WorkingDirectory = CodetracerLauncher.CtInstallDir,
            // RedirectStandardOutput = true,
            // RedirectStandardError = true,
            UseShellExecute = false,
            ArgumentList = { "--remote-debugging-port=9222" },
        };

        info.EnvironmentVariables.Add("CODETRACER_CALLER_PID", "1");
        info.EnvironmentVariables.Add("CODETRACER_TRACE_ID", traceId.ToString());
        info.EnvironmentVariables.Add("CODETRACER_IN_UI_TEST", "1");
        info.EnvironmentVariables.Add("CODETRACER_TEST", "1");
        info.EnvironmentVariables.Add("CODETRACER_WRAP_ELECTRON", "1");
        info.EnvironmentVariables.Add("CODETRACER_START_INDEX", "1");

        var process = Process.Start(info)!;

        Thread.Sleep(10000);

        Console.WriteLine($"process started {process.Id}");

        var playwright = await Playwright.CreateAsync();
        Console.WriteLine($"will try to connect to {process.Id}");
        var electronWindow = await playwright.Chromium.ConnectOverCDPAsync("http://localhost:9222", options: new() {
            Timeout = 20000
        });

        Thread.Sleep(10000);

        return electronWindow;
        // var firstWindow = await app.FirstWindowAsync();
        // return (await firstWindow.TitleAsync()) == "DevTools"
        //     ? (await app.WindowsAsync())[1]
        //     : firstWindow;
    }
}

public static class SeleniumCodetracerLauncher
{
    public static IWebDriver Launch(string programRelativePath)
    {
        if (!CodetracerLauncher.IsCtAvailable)
            throw new FileNotFoundException($"ct executable not found at {CodetracerLauncher.CtPath}");

        int traceId = CodetracerLauncher.RecordProgram(programRelativePath);
        // CodetracerLauncher.StartCore(traceId, 1);

        var psi = new ProcessStartInfo(CodetracerLauncher.CtPath, "--remote-debugging-port=9222")
        {
            WorkingDirectory = CodetracerLauncher.CtInstallDir,
            UseShellExecute = false
        };
        psi.Environment["CODETRACER_CALLER_PID"] = "1";
        psi.Environment["CODETRACER_TRACE_ID"] = traceId.ToString();
        psi.Environment["CODETRACER_IN_UI_TEST"] = "1";
        psi.Environment["CODETRACER_TEST"] = "1";
        psi.Environment["CODETRACER_WRAP_ELECTRON"] = "1";
        psi.Environment["CODETRACER_START_INDEX"] = "1";
        // Process.Start(psi);

        var options = new ChromeOptions();
        options.DebuggerAddress = "127.0.0.1:9222";

        var driverDir = "/home/franz/code/ChromeDrivers/chromedriver-linux64";

        return new ChromeDriver(driverDir, options);
    }
}

