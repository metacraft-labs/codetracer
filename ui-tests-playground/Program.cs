using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Linq;
using System.Net.Http;
using System.Net.Sockets;
using System.Text.RegularExpressions;
using Microsoft.Playwright;
using UiTestsPlayground.Helpers;

namespace UiTestsPlayground;

internal enum TestMode
{
    Electron,
    Web
}

internal sealed record TestScenario(TestMode Mode, int EventIndex, TimeSpan Delay);

internal readonly record struct MonitorInfo(string Name, int Width, int Height, int X, int Y, bool IsPrimary);

internal static class Program
{
    private static readonly string[] ProcessNames = { "ct", "electron", "backend-manager", "virtualization-layers", "node" };

    public static async Task Main()
    {
        Console.WriteLine("== Pre-run process inspection ==");
        ReportProcessCounts();
        KillProcesses("pre-run cleanup");
        ReportProcessCounts();

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
            ReportProcessCounts();
            KillProcesses("post-run cleanup");
            ReportProcessCounts();
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

            int port = GetFreeTcpPort();
            int backendPort = GetFreeTcpPort();
            int frontendPort = GetFreeTcpPort();
            hostProcess = StartHostProcess(port, backendPort, frontendPort, tracePath, label);
            await WaitForServerAsync(port, TimeSpan.FromSeconds(30), label);

            playwright = await Playwright.CreateAsync();

            var monitors = DetectMonitors();
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

            var launchArgs = BuildBrowserLaunchArgs(positionOverride, sizeOverride, selectedMonitor);

            browser = await playwright.Chromium.LaunchAsync(new BrowserTypeLaunchOptions
            {
                Headless = false,
                Args = launchArgs.ToArray()
            });

            context = await browser.NewContextAsync(new BrowserNewContextOptions
            {
                ViewportSize = null
            });

            var page = await context.NewPageAsync();
            page.SetDefaultTimeout(20000);

            await page.GotoAsync($"http://localhost:{port}", new() { WaitUntil = WaitUntilState.NetworkIdle });

            await page.EvaluateAsync("() => { document.body.style.zoom = '100%'; }");
            await page.EvaluateAsync("() => { document.documentElement.style.zoom = '100%'; }");
            await page.Keyboard.PressAsync("Control+0");

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

    private static int GetFreeTcpPort()
    {
        using var listener = new TcpListener(System.Net.IPAddress.Loopback, 0);
        listener.Start();
        int port = ((System.Net.IPEndPoint)listener.LocalEndpoint).Port;
        listener.Stop();
        return port;
    }

    private static Process StartHostProcess(int port, int backendPort, int frontendPort, string tracePath, string label)
    {
        var psi = new ProcessStartInfo(CodetracerLauncher.CtPath)
        {
            WorkingDirectory = CodetracerLauncher.CtInstallDir,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };

        psi.ArgumentList.Add("host");
        psi.ArgumentList.Add($"--port={port}");
        psi.ArgumentList.Add($"--backend-socket-port={backendPort}");
        psi.ArgumentList.Add($"--frontend-socket={frontendPort}");
        psi.ArgumentList.Add(tracePath);

        var process = Process.Start(psi) ?? throw new InvalidOperationException("Failed to start ct host.");

        _ = Task.Run(async () =>
        {
            try
            {
                string? line;
                while ((line = await process.StandardOutput.ReadLineAsync()) is not null)
                {
                    Console.WriteLine($"[ct host:{label}] {line}");
                }
            }
            catch
            {
                // ignore logging failures
            }
        });

        _ = Task.Run(async () =>
        {
            try
            {
                string? line;
                while ((line = await process.StandardError.ReadLineAsync()) is not null)
                {
                    Console.Error.WriteLine($"[ct host:{label}] {line}");
                }
            }
            catch
            {
                // ignore logging failures
            }
        });

        return process;
    }

    private static async Task WaitForServerAsync(int port, TimeSpan timeout, string label)
    {
        using var client = new HttpClient();
        var deadline = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < deadline)
        {
            try
            {
                using var response = await client.GetAsync($"http://localhost:{port}");
                if (response.IsSuccessStatusCode)
                {
                    return;
                }
            }
            catch
            {
                // keep retrying
            }

            await Task.Delay(250);
        }

        throw new TimeoutException($"[{label}] ct host did not become ready on port {port} within {timeout.TotalSeconds} seconds.");
    }

    private static List<string> BuildBrowserLaunchArgs(string? positionOverride, string? sizeOverride, MonitorInfo? monitor)
    {
        var args = new List<string> { "--start-maximized" };

        int? posX = null, posY = null, width = null, height = null;

        if (!TryParsePair(positionOverride, out posX, out posY) && monitor.HasValue)
        {
            posX = monitor.Value.X;
            posY = monitor.Value.Y;
        }

        if (!TryParsePair(sizeOverride, out width, out height) && monitor.HasValue)
        {
            width = monitor.Value.Width;
            height = monitor.Value.Height;
        }

        if (posX.HasValue && posY.HasValue)
        {
            args.Add($"--window-position={posX.Value},{posY.Value}");
        }

        if (width.HasValue && height.HasValue)
        {
            args.Add($"--window-size={width.Value},{height.Value}");
        }

        return args;
    }

    private static bool TryParsePair(string? value, out int? first, out int? second)
    {
        first = null;
        second = null;
        if (string.IsNullOrWhiteSpace(value))
        {
            return false;
        }

        var parts = value.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length != 2)
        {
            return false;
        }

        if (int.TryParse(parts[0], out var firstValue) && int.TryParse(parts[1], out var secondValue))
        {
            first = firstValue;
            second = secondValue;
            return true;
        }

        return false;
    }

    private static IReadOnlyList<MonitorInfo> DetectMonitors()
    {
        try
        {
            var psi = new ProcessStartInfo("bash")
            {
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false
            };
            psi.ArgumentList.Add("-lc");
            psi.ArgumentList.Add("xrandr --query");

            using var process = Process.Start(psi);
            if (process is null)
            {
                return Array.Empty<MonitorInfo>();
            }

            var output = process.StandardOutput.ReadToEnd();
            process.WaitForExit(2000);

            var monitors = new List<MonitorInfo>();
            foreach (var line in output.Split('\n', StringSplitOptions.RemoveEmptyEntries))
            {
                if (!line.Contains(" connected", StringComparison.Ordinal))
                {
                    continue;
                }

                var parts = line.Split(" connected", 2, StringSplitOptions.TrimEntries);
                if (parts.Length < 2)
                {
                    continue;
                }

                var name = parts[0].Trim();
                var details = parts[1];
                var isPrimary = details.Contains("primary", StringComparison.OrdinalIgnoreCase);

                var match = Regex.Match(details, @"(?<width>\d+)x(?<height>\d+)\+(?<x>-?\d+)\+(?<y>-?\d+)");
                if (!match.Success)
                {
                    continue;
                }

                var width = int.Parse(match.Groups["width"].Value, CultureInfo.InvariantCulture);
                var height = int.Parse(match.Groups["height"].Value, CultureInfo.InvariantCulture);
                var x = int.Parse(match.Groups["x"].Value, CultureInfo.InvariantCulture);
                var y = int.Parse(match.Groups["y"].Value, CultureInfo.InvariantCulture);

                monitors.Add(new MonitorInfo(name, width, height, x, y, isPrimary));
            }

            return monitors;
        }
        catch
        {
            return Array.Empty<MonitorInfo>();
        }
    }

    private static void KillProcesses(string reason)
    {
        foreach (var name in ProcessNames)
        {
            foreach (var process in Process.GetProcessesByName(name))
            {
                try
                {
                    Console.WriteLine($"[{reason}] Killing process {name} (PID {process.Id}).");
                    process.Kill(entireProcessTree: true);
                    process.WaitForExit(5000);
                }
                catch
                {
                    // ignore kill failures
                }
                finally
                {
                    process.Dispose();
                }
            }
        }
    }

    private static void ReportProcessCounts()
    {
        foreach (var name in ProcessNames)
        {
            var count = Process.GetProcessesByName(name).Length;
            Console.WriteLine($"Process '{name}': {count} instance(s).");
        }
    }
}
