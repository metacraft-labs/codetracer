using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using UiTests.Configuration;
using UiTests.Infrastructure;

namespace UiTests.Application;

internal sealed class UiTestApplication
{
    private readonly ILogger<UiTestApplication> _logger;
    private readonly IUiTestExecutionPipeline _pipeline;
    private readonly IHostApplicationLifetime _lifetime;
    private readonly IProcessLifecycleManager _processLifecycle;
    private readonly IStabilityArtifactManager _stabilityArtifacts;
    private readonly AppSettings _settings;

    public UiTestApplication(
        ILogger<UiTestApplication> logger,
        IUiTestExecutionPipeline pipeline,
        IHostApplicationLifetime lifetime,
        IProcessLifecycleManager processLifecycle,
        IStabilityArtifactManager stabilityArtifacts,
        IOptions<AppSettings> settings)
    {
        _logger = logger;
        _pipeline = pipeline;
        _lifetime = lifetime;
        _processLifecycle = processLifecycle;
        _stabilityArtifacts = stabilityArtifacts;
        _settings = settings.Value;
    }

    public async Task<int> RunAsync()
    {
        try
        {
            using var scope = _logger.BeginScope("ui-tests");
            _stabilityArtifacts.PrepareArtifacts(_settings.Stability);
            var emitLifecycleTelemetry = _settings.Runner.VerboseConsole;
            if (emitLifecycleTelemetry)
            {
                _processLifecycle.ReportProcessCounts("pre-run");
            }

            var cancellationToken = _lifetime.ApplicationStopping;
            var exitCode = await _pipeline.ExecuteAsync(cancellationToken);

            if (emitLifecycleTelemetry || exitCode != 0)
            {
                _processLifecycle.ReportProcessCounts("post-run");
            }

            _processLifecycle.KillProcesses("post-run cleanup");

            if (emitLifecycleTelemetry || exitCode != 0)
            {
                _processLifecycle.ReportProcessCounts("final snapshot");
            }

            return exitCode;
        }
        catch (OperationCanceledException ex)
        {
            _logger.LogWarning(ex, "UI tests were cancelled.");
            return 130; // conventional signal exit code
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "UI tests failed with an unhandled exception.");
            return 1;
        }
    }
}
