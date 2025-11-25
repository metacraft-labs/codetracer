using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net.Http;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using Microsoft.Playwright;
using UiTests.Configuration;
using UiTests.Helpers;
using UiTests.Infrastructure;
using UiTests.Utils;

namespace UiTests.Execution;

internal sealed class ElectronTestSessionExecutor : ITestSessionExecutor
{
    private readonly ICodetracerLauncher _launcher;
    private readonly IMonitorLayoutService _monitorLayoutService;
    private readonly AppSettings _settings;
    private readonly IProcessLifecycleManager _processLifecycle;
    private readonly ILogger<ElectronTestSessionExecutor> _logger;

    public ElectronTestSessionExecutor(
        ICodetracerLauncher launcher,
        IMonitorLayoutService monitorLayoutService,
        IOptions<AppSettings> settings,
        ILogger<ElectronTestSessionExecutor> logger,
        IProcessLifecycleManager processLifecycle)
    {
        _launcher = launcher;
        _monitorLayoutService = monitorLayoutService;
        _settings = settings.Value;
        _logger = logger;
        _processLifecycle = processLifecycle;
    }

    public TestMode Mode => TestMode.Electron;

    public async Task ExecuteAsync(TestPlanEntry entry, CancellationToken cancellationToken)
    {
        if (!_launcher.IsCtAvailable)
        {
            throw new InvalidOperationException($"ct executable not found at {_launcher.CtPath}. Build CodeTracer or set CODETRACER_E2E_CT_PATH.");
        }

        var programToRecord = entry.Scenario.TraceProgram ?? _settings.Electron.TraceProgram;
        var recording = await _launcher.RecordProgramAsync(programToRecord, cancellationToken);
        var port = await GetFreeTcpPortAsync();
        var verboseConsole = ShouldEmitVerboseConsole(entry);
        _logger.Log(verboseConsole ? LogLevel.Information : LogLevel.Debug, "[{Scenario}] Launching Electron trace {TraceId} on port {Port}.", entry.Scenario.Id, recording.TraceId, port);

        await using var session = await LaunchElectronAsync(recording.TraceId, port, cancellationToken);
        var monitors = _monitorLayoutService.DetectMonitors();
        var selectedMonitor = MonitorSelectionHelper.SelectPreferredMonitor(
            monitors,
            _settings.Electron.PreferredDisplayEdid,
            _settings.Electron.PreferredDisplayIndex,
            _logger,
            entry.Scenario.Id,
            verboseConsole);

        var page = await GetAppPageAsync(session.Browser, "CodeTracer", cancellationToken);
        page.SetDefaultTimeout(20_000);
        await page.WaitForLoadStateAsync(LoadState.NetworkIdle);

        if (await WindowPositioningHelper.MoveElectronWindowAsync(session, page, selectedMonitor) is false)
        {
            _logger.LogDebug("[{Scenario}] Electron window positioning script did not adjust bounds.", entry.Scenario.Id);
        }

        if (entry.Scenario.DelaySeconds > 0)
        {
            await Task.Delay(TimeSpan.FromSeconds(entry.Scenario.DelaySeconds), cancellationToken);
        }

        var isStability = entry.Test.Id.StartsWith("Stability.", StringComparison.OrdinalIgnoreCase);
        var screenshotMode = _settings.Stability.Artifacts.ScreenshotMode;
        var mediaRunId = DateTime.UtcNow.ToString("yyyyMMdd_HHmmssfff");
        var context = new TestExecutionContext(entry.Scenario, entry.Mode, page, cancellationToken, _settings);
        var enableDebugLog = entry.Scenario.VerboseLogging || _settings.Runner.VerboseConsole;
        using var loggingScope = enableDebugLog ? DebugLogger.PushScope(true) : null;
        try
        {
            await entry.Test.Handler(context);
            if (isStability && screenshotMode == StabilityRecordingMode.On)
            {
                await CaptureScreenshotAsync(page, entry, mediaRunId, "success");
            }
        }
        catch
        {
            if (isStability && screenshotMode != StabilityRecordingMode.Off)
            {
                await CaptureScreenshotAsync(page, entry, mediaRunId, "failure");
            }
            throw;
        }
    }

    private async Task<CodeTracerSession> LaunchElectronAsync(int traceId, int port, CancellationToken cancellationToken)
    {
        var info = new ProcessStartInfo(_launcher.CtPath)
        {
            WorkingDirectory = _launcher.CtInstallDirectory,
            UseShellExecute = false
        };
        info.ArgumentList.Add($"--remote-debugging-port={port}");
        info.EnvironmentVariables.Remove("ELECTRON_RUN_AS_NODE");
        info.EnvironmentVariables.Remove("ELECTRON_NO_ATTACH_CONSOLE");
        info.EnvironmentVariables.Add("CODETRACER_CALLER_PID", "1");
        info.EnvironmentVariables.Add("CODETRACER_TRACE_ID", traceId.ToString());
        info.EnvironmentVariables.Add("CODETRACER_IN_UI_TEST", "1");
        info.EnvironmentVariables.Add("CODETRACER_TEST", "1");
        info.EnvironmentVariables.Add("CODETRACER_WRAP_ELECTRON", "1");
        info.EnvironmentVariables.Add("CODETRACER_START_INDEX", "1");

        var process = Process.Start(info) ?? throw new InvalidOperationException("Failed to start CodeTracer Electron process.");
        var label = $"electron:{traceId}";
        _processLifecycle.RegisterProcess(process, label);
        try
        {
            await WaitForCdpAsync(port, TimeSpan.FromSeconds(_settings.Electron.CdpStartupTimeoutSeconds), cancellationToken);

            var playwright = await Playwright.CreateAsync();
            var browser = await playwright.Chromium.ConnectOverCDPAsync($"http://localhost:{port}", new() { Timeout = _settings.Electron.CdpStartupTimeoutSeconds * 1000 });

            return new CodeTracerSession(process, browser, playwright, _processLifecycle, label);
        }
        catch
        {
            _processLifecycle.UnregisterProcess(process.Id);
            try
            {
                if (!process.HasExited)
                {
                    process.Kill(entireProcessTree: true);
                    process.WaitForExit(5000);
                }
            }
            catch
            {
                // ignore cleanup failures
            }
            finally
            {
                process.Dispose();
            }

            throw;
        }
    }

    private async Task CaptureScreenshotAsync(IPage page, TestPlanEntry entry, string runId, string label)
    {
        var root = Path.GetFullPath(Path.Combine(_settings.Stability.Artifacts.Root, "media", entry.Scenario.Id, runId, "screenshots"));
        Directory.CreateDirectory(root);
        var name = $"{DateTime.UtcNow:yyyyMMdd_HHmmssfff}_{Sanitize(label)}.png";
        var path = Path.Combine(root, name);
        await page.ScreenshotAsync(new() { Path = path, FullPage = true });
    }

    private static string Sanitize(string value)
    {
        var invalid = Path.GetInvalidFileNameChars();
        return new string(value.Select(ch => invalid.Contains(ch) ? '_' : ch).ToArray());
    }

    private static async Task WaitForCdpAsync(int port, TimeSpan timeout, CancellationToken cancellationToken)
    {
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        cts.CancelAfter(timeout);

        using var client = new HttpClient();
        while (!cts.IsCancellationRequested)
        {
            try
            {
                using var response = await client.GetAsync($"http://localhost:{port}/json/version", cts.Token);
                if (response.IsSuccessStatusCode)
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

        throw new TimeoutException("CDP endpoint did not become ready within the allotted time.");
    }

    private static Task<int> GetFreeTcpPortAsync()
    {
        var listener = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, 0);
        listener.Start();
        int port = ((System.Net.IPEndPoint)listener.LocalEndpoint).Port;
        listener.Stop();
        return Task.FromResult(port);
    }

    private static async Task<IPage> GetAppPageAsync(IBrowser browser, string? titleContains, CancellationToken cancellationToken)
    {
        for (int i = 0; i < 100; i++)
        {
            var pages = browser.Contexts.SelectMany(c => c.Pages).ToList();
            var appPage = await FindAppPageAsync(pages, titleContains);
            if (appPage is not null)
            {
                return appPage;
            }

            await Task.Delay(100, cancellationToken);
        }

        throw new TimeoutException($"Could not find app page that contains {titleContains} in the title after connecting Playwright.");
    }

    private static async Task<IPage?> FindAppPageAsync(IEnumerable<IPage> pages, string? titleContains)
    {
        foreach (var page in pages)
        {
            var url = page.Url;
            if (url.StartsWith("devtools://", StringComparison.OrdinalIgnoreCase) ||
                url.StartsWith("chrome-devtools://", StringComparison.OrdinalIgnoreCase) ||
                url.StartsWith("chrome://", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            if (string.IsNullOrEmpty(titleContains))
            {
                return page;
            }

            var title = await page.TitleAsync();
            if (title?.Contains(titleContains, StringComparison.OrdinalIgnoreCase) == true)
            {
                return page;
            }
        }

        return null;
    }

    private bool ShouldEmitVerboseConsole(TestPlanEntry entry)
        => _settings.Runner.VerboseConsole || entry.Scenario.VerboseLogging;
}
