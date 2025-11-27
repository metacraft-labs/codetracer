using System.Collections.Concurrent;
using System.Globalization;
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
        AppSettingsAccessor.Initialize(_settings);
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
        var targetParallelism = Math.Max(1, Math.Min(maxParallel, plan.Count));
        _logger.LogInformation(
            "Executing {ScenarioCount} scenario(s) across {ModeCount} mode(s) with max parallelism {Parallelism} (ramped).",
            plan.Count,
            _settings.Runner.ExecutionModes.Count,
            targetParallelism);

        using var linkedCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        using var throttler = new SemaphoreSlim(1, targetParallelism);
        var rampTask = RampUpParallelismAsync(throttler, targetParallelism, linkedCts.Token);
        var failures = new ConcurrentQueue<TestFailure>();
        var results = new ConcurrentBag<TestRunResult>();
        var tasks = plan.Select(entry => ExecuteEntryAsync(entry, throttler, linkedCts, failures, results)).ToList();
        await Task.WhenAll(tasks);
        linkedCts.Cancel();
        await rampTask;

        var materializedResults = results.ToList();

        if (failures.IsEmpty)
        {
            EmitSummary(plan, materializedResults);
            return 0;
        }

        foreach (var failure in failures)
        {
            _logger.LogError(
                failure.Exception,
                "Test {TestId} in scenario {ScenarioId} ({Mode}) failed.",
                failure.Entry.Test.Id,
                failure.Entry.Scenario.Id,
                failure.Entry.Mode);
        }

        EmitSummary(plan, materializedResults);
        return failures.Count;
    }

    private async Task ExecuteEntryAsync(
        TestPlanEntry entry,
        SemaphoreSlim throttler,
        CancellationTokenSource linkedCts,
        ConcurrentQueue<TestFailure> failures,
        ConcurrentBag<TestRunResult> results)
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

            if (ShouldEmitConsole(entry))
            {
                _logger.LogInformation("Starting test {TestId} / scenario {ScenarioId} ({Mode}).", entry.Test.Id, entry.Scenario.Id, entry.Mode);
            }

            await _executors[entry.Mode].ExecuteAsync(entry, linkedCts.Token);

            if (ShouldEmitConsole(entry))
            {
                _logger.LogInformation("Completed test {TestId} / scenario {ScenarioId} ({Mode}).", entry.Test.Id, entry.Scenario.Id, entry.Mode);
            }

            results.Add(new TestRunResult(entry, TestOutcome.Passed));
        }
        catch (OperationCanceledException ex) when (linkedCts.IsCancellationRequested)
        {
            failures.Enqueue(new TestFailure(entry, ex));
            results.Add(new TestRunResult(entry, TestOutcome.Failed));
        }
        catch (Exception ex)
        {
            failures.Enqueue(new TestFailure(entry, ex));
            results.Add(new TestRunResult(entry, TestOutcome.Failed));
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

    private bool ShouldEmitConsole(TestPlanEntry entry)
        => _settings.Runner.VerboseConsole || entry.Scenario.VerboseLogging;

    private void EmitSummary(IReadOnlyCollection<TestPlanEntry> plan, IReadOnlyCollection<TestRunResult> results)
    {
        var executed = results.Count;
        var skipped = Math.Max(0, plan.Count - executed);
        var webRuns = results.Count(r => r.Entry.Mode == TestMode.Web);
        var electronRuns = results.Count(r => r.Entry.Mode == TestMode.Electron);

        var overallPass = results.Count(r => r.Outcome == TestOutcome.Passed);
        var overallFail = results.Count(r => r.Outcome == TestOutcome.Failed);
        var webPass = results.Count(r => r.Outcome == TestOutcome.Passed && r.Entry.Mode == TestMode.Web);
        var webFail = results.Count(r => r.Outcome == TestOutcome.Failed && r.Entry.Mode == TestMode.Web);
        var electronPass = results.Count(r => r.Outcome == TestOutcome.Passed && r.Entry.Mode == TestMode.Electron);
        var electronFail = results.Count(r => r.Outcome == TestOutcome.Failed && r.Entry.Mode == TestMode.Electron);

        _logger.LogInformation(
            "Executed {Executed} test(s) | Web {WebCount} | Electron {ElectronCount}",
            executed,
            webRuns,
            electronRuns);
        _logger.LogInformation("Overall => pass {Pass} | fail {Fail}", ColorizePassCount(overallPass), ColorizeFailCount(overallFail));
        _logger.LogInformation("Electron => pass {Pass} | fail {Fail}", ColorizePassCount(electronPass), ColorizeFailCount(electronFail));
        _logger.LogInformation("Web => pass {Pass} | fail {Fail}", ColorizePassCount(webPass), ColorizeFailCount(webFail));

        if (skipped > 0)
        {
            _logger.LogInformation("Skipped {SkipCount} test(s) due to filters or early cancellation.", ColorizeSkipCount(skipped));
        }
    }

    private static string ColorizePassCount(int value) => Colorize(value, PassColor);
    private static string ColorizeFailCount(int value) => Colorize(value, FailColor);
    private static string ColorizeSkipCount(int value) => Colorize(value, SkipColor);

    private static string Colorize(int value, string color)
    {
        var formatted = value.ToString(CultureInfo.InvariantCulture);
        return value == 0 ? formatted : $"{color}{formatted}{AnsiReset}";
    }

    private const string PassColor = "\u001b[32m";
    private const string FailColor = "\u001b[31m";
    private const string SkipColor = "\u001b[33m";
    private const string AnsiReset = "\u001b[0m";

    private sealed record TestRunResult(TestPlanEntry Entry, TestOutcome Outcome);

    private enum TestOutcome
    {
        Passed,
        Failed
    }

    private static Task RampUpParallelismAsync(SemaphoreSlim throttler, int targetParallelism, CancellationToken cancellationToken)
    {
        if (targetParallelism <= 1)
        {
            return Task.CompletedTask;
        }

        return Task.Run(async () =>
        {
            for (var current = 1; current < targetParallelism; current++)
            {
                try
                {
                    await Task.Delay(TimeSpan.FromSeconds(1), cancellationToken);
                }
                catch (OperationCanceledException)
                {
                    break;
                }

                if (cancellationToken.IsCancellationRequested)
                {
                    break;
                }

                try
                {
                    throttler.Release();
                }
                catch (SemaphoreFullException)
                {
                    break;
                }
            }
        }, CancellationToken.None);
    }
}
