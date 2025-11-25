using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using Microsoft.Playwright;
using UiTests.Configuration;
using UiTests.Helpers;
using UiTests.Infrastructure;
using UiTests.Utils;

namespace UiTests.Execution;

internal sealed class WebTestSessionExecutor : ITestSessionExecutor
{
    private readonly ICodetracerLauncher _launcher;
    private readonly ICtHostLauncher _hostLauncher;
    private readonly IPortAllocator _portAllocator;
    private readonly IMonitorLayoutService _monitorLayoutService;
    private readonly AppSettings _settings;
    private readonly ILogger<WebTestSessionExecutor> _logger;
    private readonly IProcessLifecycleManager _processLifecycle;

    public WebTestSessionExecutor(
        ICodetracerLauncher launcher,
        ICtHostLauncher hostLauncher,
        IPortAllocator portAllocator,
        IMonitorLayoutService monitorLayoutService,
        IOptions<AppSettings> settings,
        ILogger<WebTestSessionExecutor> logger,
        IProcessLifecycleManager processLifecycle)
    {
        _launcher = launcher;
        _hostLauncher = hostLauncher;
        _portAllocator = portAllocator;
        _monitorLayoutService = monitorLayoutService;
        _settings = settings.Value;
        _logger = logger;
        _processLifecycle = processLifecycle;
    }

    public TestMode Mode => TestMode.Web;

    public async Task ExecuteAsync(TestPlanEntry entry, CancellationToken cancellationToken)
    {
        var traceOverride = Environment.GetEnvironmentVariable("CODETRACER_TRACE_PATH");
        string tracePath;
        if (!string.IsNullOrWhiteSpace(traceOverride))
        {
            tracePath = _launcher.ResolveTracePath(traceOverride);
        }
        else
        {
            var programToRecord = entry.Scenario.TraceProgram ?? _settings.Electron.TraceProgram;
            var recording = await _launcher.RecordProgramAsync(programToRecord, cancellationToken);
            tracePath = recording.TracePath;
        }

        if (!Directory.Exists(tracePath))
        {
            throw new DirectoryNotFoundException($"Trace directory not found: {tracePath}. Set CODETRACER_TRACE_PATH to a valid trace.");
        }

        int httpPort = _portAllocator.GetFreeTcpPort();
        int socketPort = _portAllocator.GetFreeTcpPort();
        int backendPort = socketPort;
        int frontendPort = socketPort;

        var label = $"{entry.Scenario.Id}-{entry.Mode}";
        var verboseConsole = ShouldEmitVerboseConsole(entry);
        var hostProcess = _hostLauncher.StartHostProcess(httpPort, backendPort, frontendPort, tracePath, label, verboseConsole);
        _processLifecycle.RegisterProcess(hostProcess, $"ct-host:{label}");
        var isStability = entry.Test.Id.StartsWith("Stability.", StringComparison.OrdinalIgnoreCase);
        var videoMode = _settings.Stability.Artifacts.VideoMode;
        var screenshotMode = _settings.Stability.Artifacts.ScreenshotMode;
        var mediaRunId = DateTime.UtcNow.ToString("yyyyMMdd_HHmmssfff");
        string? mediaRoot = isStability && videoMode != StabilityRecordingMode.Off
            ? Path.GetFullPath(Path.Combine(_settings.Stability.Artifacts.Root, "media", entry.Scenario.Id, mediaRunId))
            : null;

        await using var session = await CreateWebSessionAsync(hostProcess, httpPort, entry, label, verboseConsole, cancellationToken, mediaRoot, videoMode);
        var failed = false;
        try
        {
            if (entry.Scenario.DelaySeconds > 0)
            {
                await Task.Delay(TimeSpan.FromSeconds(entry.Scenario.DelaySeconds), cancellationToken);
            }

            var context = new TestExecutionContext(entry.Scenario, entry.Mode, session.Page, cancellationToken, _settings);
            var enableDebugLog = entry.Scenario.VerboseLogging || _settings.Runner.VerboseConsole;
            using var loggingScope = enableDebugLog ? DebugLogger.PushScope(true) : null;
            try
            {
                await entry.Test.Handler(context);
                if (isStability && screenshotMode == StabilityRecordingMode.On)
                {
                    await CaptureScreenshotAsync(session.Page, entry, mediaRunId, "success");
                }
            }
            catch
            {
                failed = true;
                if (isStability && screenshotMode != StabilityRecordingMode.Off)
                {
                    await CaptureScreenshotAsync(session.Page, entry, mediaRunId, "failure");
                }
                throw;
            }
        }
        finally
        {
            _processLifecycle.UnregisterProcess(hostProcess.Id);
            if (isStability && videoMode == StabilityRecordingMode.FailOnly && mediaRoot is not null && !failed)
            {
                TryDeleteMedia(mediaRoot);
            }
        }
    }

    private async Task<WebTestSession> CreateWebSessionAsync(Process hostProcess, int port, TestPlanEntry entry, string label, bool verboseConsole, CancellationToken cancellationToken, string? mediaRoot, StabilityRecordingMode videoMode)
    {
        await _hostLauncher.WaitForServerAsync(port, TimeSpan.FromSeconds(_settings.Web.HostStartupTimeoutSeconds), entry.Scenario.Id, cancellationToken);

        var playwright = await Playwright.CreateAsync();

        var monitors = _monitorLayoutService.DetectMonitors();
        var selectedMonitor = MonitorSelectionHelper.SelectPreferredMonitor(
            monitors,
            _settings.Web.BrowserWindow.PreferredDisplayEdid,
            _settings.Web.BrowserWindow.PreferredDisplayIndex,
            _logger,
            entry.Scenario.Id,
            verboseConsole);

        var positionOverride = Environment.GetEnvironmentVariable("PLAYGROUND_WINDOW_POSITION");
        var sizeOverride = Environment.GetEnvironmentVariable("PLAYGROUND_WINDOW_SIZE");
        var launchArgs = _monitorLayoutService.BuildBrowserLaunchArgs(positionOverride, sizeOverride, selectedMonitor);

        var browser = await playwright.Chromium.LaunchAsync(new BrowserTypeLaunchOptions
        {
            Headless = _settings.Web.BrowserWindow.Headless,
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

        if (mediaRoot is not null && videoMode != StabilityRecordingMode.Off)
        {
            Directory.CreateDirectory(mediaRoot);
            contextOptions.RecordVideoDir = mediaRoot;
        }

        var context = await browser.NewContextAsync(contextOptions);
        var page = await context.NewPageAsync();
        page.SetDefaultTimeout(20_000);

        await page.GotoAsync($"http://localhost:{port}", new PageGotoOptions { WaitUntil = WaitUntilState.NetworkIdle });
        await page.EvaluateAsync("() => { document.body.style.zoom = '100%'; }");
        await page.EvaluateAsync("() => { document.documentElement.style.zoom = '100%'; }");
        await page.Keyboard.PressAsync("Control+0");

        var resized = await WindowPositioningHelper.MoveWindowAsync(page, selectedMonitor);

        if (!resized)
        {
            _logger.LogDebug("[{Scenario}] Window resize script could not adjust browser bounds.", entry.Scenario.Id);
        }

        return new WebTestSession(hostProcess, playwright, browser, context, page, _processLifecycle, $"ct-host:{label}");
    }

    private bool ShouldEmitVerboseConsole(TestPlanEntry entry)
        => _settings.Runner.VerboseConsole || entry.Scenario.VerboseLogging;

    private async Task CaptureScreenshotAsync(IPage page, TestPlanEntry entry, string runId, string label)
    {
        var root = Path.GetFullPath(Path.Combine(_settings.Stability.Artifacts.Root, "media", entry.Scenario.Id, runId, "screenshots"));
        Directory.CreateDirectory(root);
        var name = $"{DateTime.UtcNow:yyyyMMdd_HHmmssfff}_{Sanitize(label)}.png";
        var path = Path.Combine(root, name);
        await page.ScreenshotAsync(new() { Path = path, FullPage = true });
    }

    private static void TryDeleteMedia(string mediaRoot)
    {
        try
        {
            if (Directory.Exists(mediaRoot))
            {
                Directory.Delete(mediaRoot, recursive: true);
            }
        }
        catch
        {
            // best effort
        }
    }

    private static string Sanitize(string value)
    {
        var invalid = Path.GetInvalidFileNameChars();
        return new string(value.Select(ch => invalid.Contains(ch) ? '_' : ch).ToArray());
    }
}
