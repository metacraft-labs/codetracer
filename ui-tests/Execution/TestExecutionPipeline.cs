using System.Collections.Concurrent;
using System.Linq;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using UiTests.Application;
using UiTests.Configuration;

namespace UiTests.Execution;

internal sealed class TestExecutionPipeline : IUiTestExecutionPipeline
{
    private readonly ITestPlanner _planner;
    private readonly IReadOnlyDictionary<TestMode, ITestSessionExecutor> _executors;
    private readonly ILogger<TestExecutionPipeline> _logger;
    private readonly AppSettings _settings;

    public TestExecutionPipeline(
        ITestPlanner planner,
        IEnumerable<ITestSessionExecutor> executors,
        IOptions<AppSettings> settings,
        ILogger<TestExecutionPipeline> logger)
    {
        _planner = planner;
        _executors = executors.ToDictionary(executor => executor.Mode);
        _settings = settings.Value;
        _logger = logger;
    }

    public async Task<int> ExecuteAsync(CancellationToken cancellationToken)
    {
        var plan = _planner.BuildPlan();
        if (plan.Count == 0)
        {
            _logger.LogWarning("No test plan produced. Exiting.");
            return 0;
        }

        if (_settings.Runner.ExecutionModes.Count == 0)
        {
            throw new InvalidOperationException("Runner.ExecutionModes must contain at least one mode.");
        }

        foreach (var mode in _settings.Runner.ExecutionModes)
        {
            if (!_executors.ContainsKey(mode))
            {
                throw new InvalidOperationException($"No executor registered for test mode '{mode}'.");
            }
        }

        var maxParallel = _settings.Runner.MaxParallelInstances ?? 1;
        _logger.LogInformation("Executing {ScenarioCount} scenario(s) across {ModeCount} mode(s) with max parallelism {Parallelism}.", plan.Count, _settings.Runner.ExecutionModes.Count, maxParallel);

        using var throttler = new SemaphoreSlim(maxParallel);
        using var linkedCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        var failures = new ConcurrentQueue<TestFailure>();
        var tasks = plan.Select(entry => ExecuteEntryAsync(entry, throttler, linkedCts, failures));

        await Task.WhenAll(tasks);

        if (failures.IsEmpty)
        {
            _logger.LogInformation("All UI tests completed successfully.");
            return 0;
        }

        foreach (var failure in failures)
        {
            _logger.LogError(failure.Exception, "Test {TestId} in scenario {ScenarioId} ({Mode}) failed.", failure.Entry.Test.Id, failure.Entry.Scenario.Id, failure.Entry.Mode);
        }

        return failures.Count;
    }

    private async Task ExecuteEntryAsync(TestPlanEntry entry, SemaphoreSlim throttler, CancellationTokenSource linkedCts, ConcurrentQueue<TestFailure> failures)
    {
        try
        {
            await throttler.WaitAsync(linkedCts.Token);
        }
        catch (OperationCanceledException)
        {
            return;
        }

        try
        {
            if (linkedCts.IsCancellationRequested)
            {
                return;
            }

            _logger.LogInformation("Starting test {TestId} / scenario {ScenarioId} ({Mode}).", entry.Test.Id, entry.Scenario.Id, entry.Mode);
            await _executors[entry.Mode].ExecuteAsync(entry, linkedCts.Token);
            _logger.LogInformation("Completed test {TestId} / scenario {ScenarioId} ({Mode}).", entry.Test.Id, entry.Scenario.Id, entry.Mode);
        }
        catch (OperationCanceledException ex) when (linkedCts.IsCancellationRequested)
        {
            failures.Enqueue(new TestFailure(entry, ex));
        }
        catch (Exception ex)
        {
            failures.Enqueue(new TestFailure(entry, ex));
            if (_settings.Runner.StopOnFirstFailure)
            {
                linkedCts.Cancel();
            }
        }
        finally
        {
            throttler.Release();
        }
    }
}
