using System.Diagnostics;
using OpenQA.Selenium;
using OpenQA.Selenium.Chrome;
using UtTestsExperimentalConsoleAppication.Helpers;

public static class SeleniumLauncher
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