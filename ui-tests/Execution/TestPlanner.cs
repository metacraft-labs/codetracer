using System.Linq;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using UiTests.Configuration;

namespace UiTests.Execution;

internal interface ITestPlanner
{
    IReadOnlyList<TestPlanEntry> BuildPlan();
}

internal sealed class TestPlanner : ITestPlanner
{
    private readonly AppSettings _settings;
    private readonly ITestRegistry _registry;
    private readonly ILogger<TestPlanner> _logger;

    public TestPlanner(IOptions<AppSettings> settings, ITestRegistry registry, ILogger<TestPlanner> logger)
    {
        _settings = settings.Value;
        _registry = registry;
        _logger = logger;
    }

    public IReadOnlyList<TestPlanEntry> BuildPlan()
    {
        var scenarios = _settings.Scenarios.Where(s => s.Enabled).ToList();
        if (scenarios.Count == 0)
        {
            _logger.LogWarning("No enabled scenarios found. Nothing to execute.");
            return Array.Empty<TestPlanEntry>();
        }

        var runner = _settings.Runner;
        var includeSet = runner.IncludeTests.ToHashSet(StringComparer.OrdinalIgnoreCase);
        var excludeSet = runner.ExcludeTests.ToHashSet(StringComparer.OrdinalIgnoreCase);
        var scenarioTestSet = scenarios.Select(s => s.Test).ToHashSet(StringComparer.OrdinalIgnoreCase);

        foreach (var descriptor in _registry.All.OrderBy(d => d.Id, StringComparer.OrdinalIgnoreCase))
        {
            if (scenarioTestSet.Contains(descriptor.Id))
            {
                continue;
            }

            if (excludeSet.Contains(descriptor.Id))
            {
                continue;
            }

            if (includeSet.Count > 0 && !includeSet.Contains(descriptor.Id))
            {
                continue;
            }

            scenarios.Add(new ScenarioSettings
            {
                Id = $"auto-{descriptor.Id}",
                Description = $"Auto-generated scenario for {descriptor.Id}",
                Mode = runner.DefaultMode,
                Test = descriptor.Id,
                Enabled = true
            });

            scenarioTestSet.Add(descriptor.Id);
        }

        var modes = ResolveExecutionModes(runner);

        var plan = new List<TestPlanEntry>();
        foreach (var scenario in scenarios)
        {
            if (!_registry.TryResolve(scenario.Test, out var descriptor))
            {
                _logger.LogWarning("Skipping scenario {ScenarioId}: test '{Test}' not registered.", scenario.Id, scenario.Test);
                continue;
            }

            if (ShouldSkip(scenario, descriptor, includeSet, excludeSet))
            {
                _logger.LogInformation("Skipping scenario {ScenarioId} ({Test}) due to include/exclude filters.", scenario.Id, descriptor.Id);
                continue;
            }

            foreach (var mode in modes)
            {
                plan.Add(new TestPlanEntry(descriptor, scenario, mode));
            }
        }

        return plan;
    }

    private static bool ShouldSkip(ScenarioSettings scenario, UiTestDescriptor descriptor, HashSet<string> includeSet, HashSet<string> excludeSet)
    {
        if (excludeSet.Contains(scenario.Id) || excludeSet.Contains(descriptor.Id))
        {
            return true;
        }

        if (includeSet.Count == 0)
        {
            return false;
        }

        return !includeSet.Contains(scenario.Id) && !includeSet.Contains(descriptor.Id);
    }

    private static IReadOnlyList<TestMode> ResolveExecutionModes(RunnerSettings runner)
    {
        if (runner.ExecutionModes is { Count: > 0 })
        {
            return runner.ExecutionModes;
        }

        return new[] { TestMode.Electron, TestMode.Web };
    }
}
