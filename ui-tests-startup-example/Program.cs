using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Linq;
using Microsoft.Playwright;
using UiTestsPlayground.Helpers;
using MonitorInfo = UiTestsPlayground.Helpers.MonitorUtilities.MonitorInfo;

namespace UiTestsPlayground;

internal enum TestMode
{
    Electron,
    Web
}

internal sealed record TestScenario(TestMode Mode, int EventIndex, TimeSpan Delay);

internal static class Program
{
    public static async Task Main()
    {
        Console.WriteLine("== Pre-run process inspection ==");
        ProcessUtilities.ReportProcessCounts();
        ProcessUtilities.KillProcesses("pre-run cleanup");
        ProcessUtilities.ReportProcessCounts();

        var scenarios = new List<TestScenario>
        {
            new(TestMode.Electron, 3, TimeSpan.FromSeconds(6)),
            new(TestMode.Electron, 6, TimeSpan.FromSeconds(10)),
            new(TestMode.Electron, 9, TimeSpan.FromSeconds(12)),
            new(TestMode.Web, 3, TimeSpan.FromSeconds(6)),
            new(TestMode.Web, 6, TimeSpan.FromSeconds(10)),
            new(TestMode.Web, 9, TimeSpan.FromSeconds(12)),
        };

        Console.WriteLine($"Starting {scenarios.Count} scenarios in parallel...");
        var tasks = scenarios.Select(RunScenarioAsync).ToArray();

        try
        {
            await Task.WhenAll(tasks);
            Console.WriteLine("All scenarios completed successfully.");
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine("One or more scenarios failed: " + ex);
            throw;
        }
        finally
        {
            Console.WriteLine("== Post-run process inspection ==");
            ProcessUtilities.ReportProcessCounts();
            ProcessUtilities.KillProcesses("post-run cleanup");
            ProcessUtilities.ReportProcessCounts();
        }
    }

    private static async Task RunScenarioAsync(TestScenario scenario)
    {
        var label = $"{scenario.Mode}-event{scenario.EventIndex}-delay{scenario.Delay.TotalSeconds:0}";
        Console.WriteLine($"[{label}] Starting scenario.");

        try
        {
            switch (scenario.Mode)
            {
                case TestMode.Electron:
                    await RunElectronScenarioAsync(label, scenario);
                    break;
                case TestMode.Web:
                    await RunWebScenarioAsync(label, scenario);
                    break;
                default:
                    throw new ArgumentOutOfRangeException(nameof(scenario.Mode), scenario.Mode, "Unsupported test mode");
            }

            Console.WriteLine($"[{label}] Scenario finished successfully.");
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"[{label}] Scenario failed: {ex}");
            throw;
        }
    }

    private static async Task RunElectronScenarioAsync(string label, TestScenario scenario)
    {
        CodeTracerSession? session = null;
        try
        {
            session = await PlaywrightLauncher.LaunchAsync("noir_space_ship");
            var page = await PlaywrightLauncher.GetAppPageAsync(session.Browser, titleContains: "CodeTracer");

            await PrepareEventLogAsync(label, page, scenario.EventIndex);
            await ExecuteEventSelectionAsync(label, page, scenario);
        }
        finally
        {
            if (session is not null)
            {
                await session.DisposeAsync();
            }
        }
    }

    private static async Task RunWebScenarioAsync(string label, TestScenario scenario)
    {
        Process? hostProcess = null;
        IPlaywright? playwright = null;
        IBrowser? browser = null;
        IBrowserContext? context = null;

        try
        {
            var traceOverride = Environment.GetEnvironmentVariable("CODETRACER_TRACE_PATH");
            var tracePath = CodetracerLauncher.GetTracePath(traceOverride);
            if (!Directory.Exists(tracePath))
            {
                throw new DirectoryNotFoundException($"[{label}] Trace directory not found: {tracePath}. Set CODETRACER_TRACE_PATH to a valid trace.");
            }

            int port = NetworkUtilities.GetFreeTcpPort();
            int socketPort = NetworkUtilities.GetFreeTcpPort();
            int backendPort = socketPort;
            int frontendPort = socketPort;
            hostProcess = CtHostLauncher.StartHostProcess(port, backendPort, frontendPort, tracePath, label);
            await CtHostLauncher.WaitForServerAsync(port, TimeSpan.FromSeconds(30), label);

            playwright = await Playwright.CreateAsync();

            var monitors = MonitorUtilities.DetectMonitors();
            MonitorInfo? selectedMonitor = null;
            if (monitors.Count > 0)
            {
                selectedMonitor = monitors
                    .OrderByDescending(m => m.IsPrimary)
                    .ThenBy(m => m.Y)
                    .ThenBy(m => m.X)
                    .First();
                Console.WriteLine($"[{label}] Targeting monitor '{selectedMonitor.Value.Name}' ({selectedMonitor.Value.Width}x{selectedMonitor.Value.Height} at {selectedMonitor.Value.X},{selectedMonitor.Value.Y}).");
            }
            else
            {
                Console.WriteLine($"[{label}] Could not detect monitor layout via xrandr; using browser defaults.");
            }

            var positionOverride = Environment.GetEnvironmentVariable("PLAYGROUND_WINDOW_POSITION");
            var sizeOverride = Environment.GetEnvironmentVariable("PLAYGROUND_WINDOW_SIZE");
            var launchArgs = MonitorUtilities.BuildBrowserLaunchArgs(positionOverride, sizeOverride, selectedMonitor);

            browser = await playwright.Chromium.LaunchAsync(new BrowserTypeLaunchOptions
            {
                Headless = false,
                Args = launchArgs.ToArray()
            });

            var contextOptions = new BrowserNewContextOptions();
            if (selectedMonitor.HasValue)
            {
                contextOptions.ViewportSize = new ViewportSize
                {
                    Width = selectedMonitor.Value.Width,
                    Height = selectedMonitor.Value.Height
                };
            }

            context = await browser.NewContextAsync(contextOptions);

            var page = await context.NewPageAsync();
            page.SetDefaultTimeout(20000);

            await page.GotoAsync($"http://localhost:{port}", new() { WaitUntil = WaitUntilState.NetworkIdle });

            await page.EvaluateAsync("() => { document.body.style.zoom = '100%'; }");
            await page.EvaluateAsync("() => { document.documentElement.style.zoom = '100%'; }");
            await page.Keyboard.PressAsync("Control+0");
            await page.EvaluateAsync("() => window.dispatchEvent(new Event('resize'))");

            await PrepareEventLogAsync(label, page, scenario.EventIndex);
            await ExecuteEventSelectionAsync(label, page, scenario);
        }
        finally
        {
            if (context is not null)
            {
                await context.CloseAsync();
                await context.DisposeAsync();
            }

            if (browser is not null)
            {
                await browser.CloseAsync();
                await browser.DisposeAsync();
            }

            playwright?.Dispose();

            if (hostProcess is not null)
            {
                try
                {
                    if (!hostProcess.HasExited)
                    {
                        hostProcess.Kill(entireProcessTree: true);
                        hostProcess.WaitForExit(5000);
                    }
                }
                catch
                {
                    // ignore cleanup failures
                }
                finally
                {
                    hostProcess.Dispose();
                }
            }
        }
    }

    private static async Task PrepareEventLogAsync(string label, IPage page, int eventIndex)
    {
        await page.WaitForLoadStateAsync(LoadState.NetworkIdle);
        await page.WaitForSelectorAsync("#eventLog-0-dense-table-0", new PageWaitForSelectorOptions
        {
            State = WaitForSelectorState.Attached,
            Timeout = 60000
        });

        var rows = page.Locator("#eventLog-0-dense-table-0  tr");
        var deadline = DateTime.UtcNow + TimeSpan.FromSeconds(90);

        while (DateTime.UtcNow < deadline)
        {
            var count = await rows.CountAsync();
            if (count >= eventIndex)
            {
                var targetRow = rows.Nth(eventIndex - 1);
                await targetRow.WaitForAsync(new LocatorWaitForOptions
                {
                    State = WaitForSelectorState.Attached,
                    Timeout = 60000
                });
                await targetRow.ScrollIntoViewIfNeededAsync();
                return;
            }

            await Task.Delay(500);
        }

        throw new TimeoutException($"[{label}] Event log did not contain index {eventIndex} within the expected time.");
    }

    private static async Task ExecuteEventSelectionAsync(string label, IPage page, TestScenario scenario)
    {
        int targetIndex = scenario.EventIndex - 1;
        if (targetIndex < 0)
        {
            throw new ArgumentOutOfRangeException(nameof(scenario.EventIndex), scenario.EventIndex, "Event index must be >= 1");
        }

        var rows = page.Locator("#eventLog-0-dense-table-0  tr");

        await Task.Delay(scenario.Delay);

        var row = rows.Nth(targetIndex);
        await row.ClickAsync();

        await Task.Delay(TimeSpan.FromSeconds(3));

        var classes = await row.GetAttributeAsync("class") ?? string.Empty;
        if (!classes.Contains("active", StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException($"[{label}] Event index {scenario.EventIndex} was not active after selection.");
        }

        Console.WriteLine($"[{label}] Verified event {scenario.EventIndex} is active.");
    }
}
