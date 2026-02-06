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
    private readonly ITestDiagnosticsService _diagnostics;

    public WebTestSessionExecutor(
        ICodetracerLauncher launcher,
        ICtHostLauncher hostLauncher,
        IPortAllocator portAllocator,
        IMonitorLayoutService monitorLayoutService,
        IOptions<AppSettings> settings,
        ILogger<WebTestSessionExecutor> logger,
        IProcessLifecycleManager processLifecycle,
        ITestDiagnosticsService diagnostics)
    {
        _launcher = launcher;
        _hostLauncher = hostLauncher;
        _portAllocator = portAllocator;
        _monitorLayoutService = monitorLayoutService;
        _settings = settings.Value;
        _logger = logger;
        _processLifecycle = processLifecycle;
        _diagnostics = diagnostics;
    }

    public TestMode Mode => TestMode.Web;

    public async Task ExecuteAsync(TestPlanEntry entry, CancellationToken cancellationToken)
    {
        var traceOverride = Environment.GetEnvironmentVariable("CODETRACER_TRACE_PATH");
        var tracePath = _launcher.ResolveTracePath(traceOverride);
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

        // Create isolated config directory for this test
        using var configScope = new IsolatedConfigScope($"{entry.Test.Id}_{entry.Scenario.Id}");

        var hostProcess = _hostLauncher.StartHostProcess(httpPort, backendPort, frontendPort, tracePath, label, verboseConsole, configScope.ConfigDirectory);
        _processLifecycle.RegisterProcess(hostProcess, $"ct-host:{label}");
        await using var session = await CreateWebSessionAsync(hostProcess, httpPort, entry, label, verboseConsole, cancellationToken);
        try
        {

            if (entry.Scenario.DelaySeconds > 0)
            {
                await Task.Delay(TimeSpan.FromSeconds(entry.Scenario.DelaySeconds), cancellationToken);
            }

            var context = new TestExecutionContext(entry.Scenario, entry.Mode, session.Page, cancellationToken);
            var enableDebugLog = entry.Scenario.VerboseLogging || _settings.Runner.VerboseConsole;
            using var loggingScope = enableDebugLog ? DebugLogger.PushScope(true) : null;

            // Start Playwright trace recording if enabled
            var browserContext = session.Page.Context;
            var traceEnabled = _settings.Runner.PlaywrightTrace;
            string? pwTracePath = null;

            if (traceEnabled)
            {
                pwTracePath = _diagnostics.GetTraceFilePath(entry);
                _logger.LogInformation("[{Scenario}] Starting Playwright trace recording to {TracePath}", entry.Scenario.Id, pwTracePath);
                await browserContext.Tracing.StartAsync(new TracingStartOptions
                {
                    Screenshots = true,
                    Snapshots = true,
                    Sources = true
                });
            }

            try
            {
                await entry.Test.Handler(context);
            }
            catch (Exception ex)
            {
                await _diagnostics.CaptureFailureDiagnosticsAsync(session.Page, entry, ex, attempt: 1);
                throw;
            }
            finally
            {
                if (traceEnabled && pwTracePath != null)
                {
                    try
                    {
                        await browserContext.Tracing.StopAsync(new TracingStopOptions { Path = pwTracePath });
                        _logger.LogInformation("[{Scenario}] Saved Playwright trace to {TracePath}", entry.Scenario.Id, pwTracePath);
                    }
                    catch (Exception ex)
                    {
                        _logger.LogWarning(ex, "[{Scenario}] Failed to save Playwright trace", entry.Scenario.Id);
                    }
                }
            }
        }
        finally
        {
            _processLifecycle.UnregisterProcess(hostProcess.Id);
        }
    }

    private async Task<WebTestSession> CreateWebSessionAsync(Process hostProcess, int port, TestPlanEntry entry, string label, bool verboseConsole, CancellationToken cancellationToken)
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
}
