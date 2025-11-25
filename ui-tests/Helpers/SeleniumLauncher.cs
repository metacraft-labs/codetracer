using System.Diagnostics;
using System.IO;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;
using OpenQA.Selenium;
using OpenQA.Selenium.Chrome;
using System.Threading;
using UiTests.Configuration;
using UiTests.Infrastructure;

public static class SeleniumLauncher
{
    public static IWebDriver Launch(string programRelativePath)
    {
        var launcher = new CodetracerLauncher(
            Options.Create(new AppSettings()),
            NullLogger<CodetracerLauncher>.Instance);

        if (!launcher.IsCtAvailable)
            throw new FileNotFoundException($"ct executable not found at {launcher.CtPath}");

        var recording = launcher.RecordProgramAsync(programRelativePath, CancellationToken.None).GetAwaiter().GetResult();
        // CodetracerLauncher.StartCore(traceId, 1);

        var psi = new ProcessStartInfo(launcher.CtPath, "--remote-debugging-port=9222")
        {
            WorkingDirectory = launcher.CtInstallDirectory,
            UseShellExecute = false
        };
        psi.Environment["CODETRACER_CALLER_PID"] = "1";
        psi.Environment["CODETRACER_TRACE_ID"] = recording.TraceId.ToString();
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
