using System.Diagnostics;
using Microsoft.Playwright;
using UiTests.Helpers;

public static class PlaywrightLauncher
{
    private static async Task<int> GetFreeTcpPortAsync()
    {
        var l = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, 0);
        l.Start();
        int port = ((System.Net.IPEndPoint)l.LocalEndpoint).Port;
        l.Stop();
        return port;
    }

    private static async Task WaitForCdpAsync(int port, TimeSpan timeout)
    {
        using var cts = new CancellationTokenSource(timeout);
        using var client = new System.Net.Http.HttpClient();
        while (!cts.Token.IsCancellationRequested)
        {
            try
            {
                var resp = await client.GetAsync($"http://localhost:{port}/json/version", cts.Token);
                if (resp.IsSuccessStatusCode) return;
            }
            catch { /* keep polling */ }
            await Task.Delay(150, cts.Token);
        }
        throw new TimeoutException("CDP endpoint did not become ready.");
    }
    public static string CtPath => CodetracerLauncher.CtPath;
    public static bool IsCtAvailable => CodetracerLauncher.IsCtAvailable;

    public static async Task<IBrowser> LaunchAsync(string programRelativePath)
    {
        if (!IsCtAvailable)
            throw new FileNotFoundException($"ct executable not found at {CtPath}");

        int traceId = CodetracerLauncher.RecordProgram(programRelativePath);
        int port = await GetFreeTcpPortAsync();

        var info = new ProcessStartInfo(CtPath)
        {
            WorkingDirectory = CodetracerLauncher.CtInstallDir,
            // RedirectStandardOutput = true,
            // RedirectStandardError = true,
            UseShellExecute = false,
            // ArgumentList = { "--remote-debugging-port=9222" },
        };
        info.ArgumentList.Add($"--remote-debugging-port={port}");
        info.EnvironmentVariables.Add("CODETRACER_CALLER_PID", "1");
        info.EnvironmentVariables.Add("CODETRACER_TRACE_ID", traceId.ToString());
        info.EnvironmentVariables.Add("CODETRACER_IN_UI_TEST", "1");
        info.EnvironmentVariables.Add("CODETRACER_TEST", "1");
        info.EnvironmentVariables.Add("CODETRACER_WRAP_ELECTRON", "1");
        info.EnvironmentVariables.Add("CODETRACER_START_INDEX", "1");
        // info.EnvironmentVariables.Add("CODETRACER_DEV_TOOLS", "");

        var process = Process.Start(info)!;

        await WaitForCdpAsync(port, TimeSpan.FromSeconds(20));

        Console.WriteLine($"process started {process.Id}");

        var pw = await Playwright.CreateAsync();

        Console.WriteLine($"Playwright will try to connect to {process.Id}");

        var browser = await pw.Chromium.ConnectOverCDPAsync($"http://localhost:{port}", options: new()
        {
            Timeout = 20000
        });

        return browser;
        // var firstWindow = await app.FirstWindowAsync();
        // return (await firstWindow.TitleAsync()) == "DevTools"
        //     ? (await app.WindowsAsync())[1]
        //     : firstWindow;
    }
    
    public static async Task<IPage> GetAppPageAsync(IBrowser browser, string? titleContains = null)
    {
        // Wait for at least one non-DevTools page to appear
        for (int i = 0; i < 100; i++)
        {
            var pages = browser.Contexts.SelectMany(c => c.Pages).ToList();
            var appPage = pages.FirstOrDefault(p =>
                !p.Url.StartsWith("devtools://", StringComparison.OrdinalIgnoreCase) &&
                !p.Url.StartsWith("chrome-devtools://", StringComparison.OrdinalIgnoreCase) &&
                !p.Url.StartsWith("chrome://", StringComparison.OrdinalIgnoreCase) &&
                (string.IsNullOrEmpty(titleContains) || (p.TitleAsync().GetAwaiter().GetResult()?.Contains(titleContains) == true)));

            if (appPage is not null) return appPage;
            await Task.Delay(100);
        }
        if (titleContains != null)
        {
            throw new TimeoutException($"Could not find app page that contains {titleContains} in the title after connecting playwright.");
        }
        else
        { 
            throw new TimeoutException("Could not find app page (non-DevTools) after connecting playwright.");
        }
    }
}