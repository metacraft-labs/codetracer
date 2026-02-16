using System.Collections.Concurrent;
using System.Diagnostics;
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
    private readonly IPortAllocator _portAllocator;
    private readonly AppSettings _settings;
    private readonly IProcessLifecycleManager _processLifecycle;
    private readonly ITestDiagnosticsService _diagnostics;
    private readonly ILogger<ElectronTestSessionExecutor> _logger;

    /// <summary>
    /// Caches in-flight or completed recording tasks keyed by trace program path, so that
    /// multiple tests targeting the same program share a single recording.
    /// </summary>
    private readonly ConcurrentDictionary<string, Task<int>> _recordedTraces = new(StringComparer.OrdinalIgnoreCase);

    public ElectronTestSessionExecutor(
        ICodetracerLauncher launcher,
        IMonitorLayoutService monitorLayoutService,
        IPortAllocator portAllocator,
        IOptions<AppSettings> settings,
        ILogger<ElectronTestSessionExecutor> logger,
        IProcessLifecycleManager processLifecycle,
        ITestDiagnosticsService diagnostics)
    {
        _launcher = launcher;
        _monitorLayoutService = monitorLayoutService;
        _portAllocator = portAllocator;
        _settings = settings.Value;
        _logger = logger;
        _processLifecycle = processLifecycle;
        _diagnostics = diagnostics;
    }

    public TestMode Mode => TestMode.Electron;

    public async Task ExecuteAsync(TestPlanEntry entry, CancellationToken cancellationToken)
    {
        if (!_launcher.IsCtAvailable)
        {
            throw new InvalidOperationException($"ct executable not found at {_launcher.CtPath}. Build CodeTracer or set CODETRACER_E2E_CT_PATH.");
        }

        // Resolve the trace program from the most specific source: scenario > test > global default.
        var traceProgram = entry.Scenario.TraceProgram
            ?? entry.Test.TraceProgram
            ?? _settings.Electron.TraceProgram;
        var traceId = await GetOrRecordTraceAsync(traceProgram, cancellationToken);
        var cdpPort = _portAllocator.GetFreeTcpPort();
        var rustLspPort = _portAllocator.GetFreeTcpPort();
        var rubyLspPort = _portAllocator.GetFreeTcpPort();
        // best-effort de-duplication to avoid binding clashes in parallel runs
        while (rustLspPort == cdpPort)
        {
            rustLspPort = _portAllocator.GetFreeTcpPort();
        }
        while (rubyLspPort == cdpPort || rubyLspPort == rustLspPort)
        {
            rubyLspPort = _portAllocator.GetFreeTcpPort();
        }

        var verboseConsole = ShouldEmitVerboseConsole(entry);
        _logger.Log(verboseConsole ? LogLevel.Information : LogLevel.Debug,
            "[{Scenario}] Launching Electron trace {TraceId} (CDP {CdpPort}, LSP {RustLspPort}, Ruby LSP {RubyLspPort}).",
            entry.Scenario.Id, traceId, cdpPort, rustLspPort, rubyLspPort);

        // Create isolated config directory for this test
        using var configScope = new IsolatedConfigScope($"{entry.Test.Id}_{entry.Scenario.Id}");

        await using var session = await LaunchElectronAsync(traceId, cdpPort, rustLspPort, rubyLspPort, configScope.ConfigDirectory, cancellationToken);
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

        var context = new TestExecutionContext(entry.Scenario, entry.Mode, page, cancellationToken);
        var enableDebugLog = entry.Scenario.VerboseLogging || _settings.Runner.VerboseConsole;
        using var loggingScope = enableDebugLog ? DebugLogger.PushScope(true) : null;

        // Start Playwright trace recording if enabled
        var browserContext = page.Context;
        var traceEnabled = _settings.Runner.PlaywrightTrace;
        string? tracePath = null;

        if (traceEnabled)
        {
            tracePath = _diagnostics.GetTraceFilePath(entry);
            _logger.LogInformation("[{Scenario}] Starting Playwright trace recording to {TracePath}", entry.Scenario.Id, tracePath);
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
            await _diagnostics.CaptureFailureDiagnosticsAsync(page, entry, ex, attempt: 1);
            throw;
        }
        finally
        {
            if (traceEnabled && tracePath != null)
            {
                try
                {
                    await browserContext.Tracing.StopAsync(new TracingStopOptions { Path = tracePath });
                    _logger.LogInformation("[{Scenario}] Saved Playwright trace to {TracePath}", entry.Scenario.Id, tracePath);
                }
                catch (Exception ex)
                {
                    _logger.LogWarning(ex, "[{Scenario}] Failed to save Playwright trace", entry.Scenario.Id);
                }
            }
        }
    }

    /// <summary>
    /// Returns a cached trace ID for the given program, recording it at most once even when
    /// multiple tests request the same program concurrently. The <see cref="ConcurrentDictionary{TKey,TValue}.GetOrAdd(TKey, Func{TKey, TValue})"/>
    /// factory guarantees the recording task is created exactly once per unique program path.
    /// </summary>
    private Task<int> GetOrRecordTraceAsync(string traceProgram, CancellationToken cancellationToken)
    {
        return _recordedTraces.GetOrAdd(traceProgram,
            program => _launcher.RecordProgramAsync(program, cancellationToken));
    }

    private async Task<CodeTracerSession> LaunchElectronAsync(int traceId, int cdpPort, int rustLspPort, int rubyLspPort, string isolatedConfigDir, CancellationToken cancellationToken)
    {
        var info = new ProcessStartInfo(_launcher.CtPath)
        {
            WorkingDirectory = _launcher.CtInstallDirectory,
            UseShellExecute = false
        };
        info.ArgumentList.Add($"--remote-debugging-port={cdpPort}");
        info.EnvironmentVariables.Remove("ELECTRON_RUN_AS_NODE");
        info.EnvironmentVariables.Remove("ELECTRON_NO_ATTACH_CONSOLE");
        info.EnvironmentVariables.Add("CODETRACER_CALLER_PID", "1");
        info.EnvironmentVariables.Add("CODETRACER_TRACE_ID", traceId.ToString());
        info.EnvironmentVariables.Add("CODETRACER_IN_UI_TEST", "1");
        info.EnvironmentVariables.Add("CODETRACER_TEST", "1");
        info.EnvironmentVariables["CODETRACER_LSP_PORT"] = rustLspPort.ToString();
        info.EnvironmentVariables["CODETRACER_RUBY_LSP_PORT"] = rubyLspPort.ToString();
        // Isolate config directory to prevent test interference
        info.EnvironmentVariables["XDG_CONFIG_HOME"] = isolatedConfigDir;

        var process = Process.Start(info) ?? throw new InvalidOperationException("Failed to start CodeTracer Electron process.");
        var label = $"electron:{traceId}";
        _processLifecycle.RegisterProcess(process, label);
        try
        {
            await WaitForCdpAsync(cdpPort, TimeSpan.FromSeconds(_settings.Electron.CdpStartupTimeoutSeconds), cancellationToken);

            var playwright = await Playwright.CreateAsync();
            var browser = await playwright.Chromium.ConnectOverCDPAsync($"http://localhost:{cdpPort}", new() { Timeout = _settings.Electron.CdpStartupTimeoutSeconds * 1000 });

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
