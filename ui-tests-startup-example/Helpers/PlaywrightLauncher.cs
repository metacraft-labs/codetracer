using System.Diagnostics;
using System.Linq;
using Microsoft.Playwright;

namespace UiTestsPlayground.Helpers;

internal static class PlaywrightLauncher
{
    private static Task<int> GetFreeTcpPortAsync()
    {
        var listener = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, 0);
        listener.Start();
        int port = ((System.Net.IPEndPoint)listener.LocalEndpoint).Port;
        listener.Stop();
        return Task.FromResult(port);
    }

    private static async Task WaitForCdpAsync(int port, TimeSpan timeout)
    {
        using var cts = new CancellationTokenSource(timeout);
        using var client = new System.Net.Http.HttpClient();
        while (!cts.IsCancellationRequested)
        {
            try
            {
                var resp = await client.GetAsync($"http://localhost:{port}/json/version", cts.Token);
                if (resp.IsSuccessStatusCode)
                {
                    return;
                }
            }
            catch
            {
                // keep polling
            }

            await Task.Delay(150, cts.Token);
        }

        throw new TimeoutException("CDP endpoint did not become ready.");
    }

    public static async Task<CodeTracerSession> LaunchAsync(string programRelativePath)
    {
        if (!CodetracerLauncher.IsCtAvailable)
        {
            throw new FileNotFoundException($"ct executable not found at {CodetracerLauncher.CtPath}");
        }

        int traceId = CodetracerLauncher.RecordProgram(programRelativePath);
        int port = await GetFreeTcpPortAsync();

        var info = new ProcessStartInfo(CodetracerLauncher.CtPath)
        {
            WorkingDirectory = CodetracerLauncher.CtInstallDir,
            UseShellExecute = false,
        };
        info.EnvironmentVariables.Remove("ELECTRON_RUN_AS_NODE");
        info.EnvironmentVariables.Remove("ELECTRON_NO_ATTACH_CONSOLE");
        info.ArgumentList.Add($"--remote-debugging-port={port}");
        info.EnvironmentVariables.Add("CODETRACER_CALLER_PID", "1");
        info.EnvironmentVariables.Add("CODETRACER_TRACE_ID", traceId.ToString());
        info.EnvironmentVariables.Add("CODETRACER_IN_UI_TEST", "1");
        info.EnvironmentVariables.Add("CODETRACER_TEST", "1");
        info.EnvironmentVariables.Add("CODETRACER_WRAP_ELECTRON", "1");
        info.EnvironmentVariables.Add("CODETRACER_START_INDEX", "1");

        var process = Process.Start(info)!;

        await WaitForCdpAsync(port, TimeSpan.FromSeconds(20));

        var playwright = await Playwright.CreateAsync();
        var browser = await playwright.Chromium.ConnectOverCDPAsync($"http://localhost:{port}", new() { Timeout = 20000 });

        return new CodeTracerSession(process, browser, playwright);
    }

    public static async Task<IPage> GetAppPageAsync(IBrowser browser, string? titleContains = null)
    {
        for (int i = 0; i < 100; i++)
        {
            var pages = browser.Contexts.SelectMany(c => c.Pages).ToList();
            var appPage = pages.FirstOrDefault(p =>
                !p.Url.StartsWith("devtools://", StringComparison.OrdinalIgnoreCase) &&
                !p.Url.StartsWith("chrome-devtools://", StringComparison.OrdinalIgnoreCase) &&
                !p.Url.StartsWith("chrome://", StringComparison.OrdinalIgnoreCase) &&
                (string.IsNullOrEmpty(titleContains) ||
                 (p.TitleAsync().GetAwaiter().GetResult()?.Contains(titleContains, StringComparison.OrdinalIgnoreCase) == true)));

            if (appPage is not null)
            {
                return appPage;
            }

            await Task.Delay(100);
        }

        if (titleContains != null)
        {
            throw new TimeoutException($"Could not find app page that contains {titleContains} in the title after connecting playwright.");
        }

        throw new TimeoutException("Could not find app page (non-DevTools) after connecting playwright.");
    }
}
