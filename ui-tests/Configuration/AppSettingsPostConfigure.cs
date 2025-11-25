using System.Collections.Generic;
using System.Linq;
using Microsoft.Extensions.Options;
using UiTests.Execution;
using UiTests.Infrastructure;

namespace UiTests.Configuration;

internal sealed class AppSettingsPostConfigure : IPostConfigureOptions<AppSettings>
{
    private readonly IParallelismProvider _parallelismProvider;
    private readonly SuiteProfileSelection _selection;

    public AppSettingsPostConfigure(IParallelismProvider parallelismProvider, SuiteProfileSelection selection)
    {
        _parallelismProvider = parallelismProvider;
        _selection = selection;
    }

    public void PostConfigure(string? name, AppSettings options)
    {
        options.Runner ??= new RunnerSettings();
        options.Electron ??= new ElectronSettings();
        options.Web ??= new WebSettings();
        options.Web.Ports ??= new HostPortSettings();
        options.Stability ??= new StabilitySettings();
        options.Stability.Artifacts ??= new StabilityArtifactSettings();
        options.Stability.Runtime ??= new StabilityRuntimeSettings();
        options.Suites = EnsureDictionary(options.Suites);
        options.Profiles = EnsureDictionary(options.Profiles);

        var recommended = Math.Max(1, _parallelismProvider.GetRecommendedParallelism());

        if (!string.IsNullOrWhiteSpace(_selection.Suite))
        {
            if (!options.Suites.TryGetValue(_selection.Suite, out var suite))
            {
                throw new OptionsValidationException(
                    nameof(AppSettings.Suites),
                    typeof(AppSettings),
                    new[] { $"Suite '{_selection.Suite}' is not defined." });
            }

            if (suite.Tests is not { Count: > 0 })
            {
                throw new OptionsValidationException(
                    nameof(AppSettings.Suites),
                    typeof(AppSettings),
                    new[] { $"Suite '{_selection.Suite}' must define at least one test." });
            }

            options.Runner.IncludeTests = suite.Tests.Where(t => !string.IsNullOrWhiteSpace(t)).Select(t => t.Trim()).ToArray();
        }

        if (!string.IsNullOrWhiteSpace(_selection.Profile))
        {
            if (!options.Profiles.TryGetValue(_selection.Profile, out var profile))
            {
                throw new OptionsValidationException(
                    nameof(AppSettings.Profiles),
                    typeof(AppSettings),
                    new[] { $"Profile '{_selection.Profile}' is not defined." });
            }

            if (profile.MaxParallelInstances.HasValue)
            {
                options.Runner.MaxParallelInstances = profile.MaxParallelInstances.Value;
            }

            if (profile.StopOnFirstFailure.HasValue)
            {
                options.Runner.StopOnFirstFailure = profile.StopOnFirstFailure.Value;
            }

            if (profile.ExecutionModes is { Count: > 0 })
            {
                options.Runner.ExecutionModes = profile.ExecutionModes.ToArray();
            }

            if (profile.DefaultMode.HasValue)
            {
                options.Runner.DefaultMode = profile.DefaultMode.Value;
            }
        }

        if (options.Runner.MaxParallelInstances is null || options.Runner.MaxParallelInstances <= 0)
        {
            options.Runner.MaxParallelInstances = recommended;
        }
        else
        {
            options.Runner.MaxParallelInstances = Math.Max(1, options.Runner.MaxParallelInstances.Value);
        }

        if (_selection.IncludeOverrides.Count > 0)
        {
            options.Runner.IncludeTests = _selection.IncludeOverrides
                .Where(v => !string.IsNullOrWhiteSpace(v))
                .Select(v => v.Trim())
                .ToArray();
        }

        if (_selection.ExcludeOverrides.Count > 0)
        {
            options.Runner.ExcludeTests = _selection.ExcludeOverrides
                .Where(v => !string.IsNullOrWhiteSpace(v))
                .Select(v => v.Trim())
                .ToArray();
        }

        if (_selection.ModeOverrides.Count > 0)
        {
            options.Runner.ExecutionModes = _selection.ModeOverrides;
        }

        options.Runner.IncludeTests = Normalize(options.Runner.IncludeTests);
        options.Runner.ExcludeTests = Normalize(options.Runner.ExcludeTests);
        options.Runner.ExecutionModes = NormalizeModes(options.Runner.ExecutionModes, options.Runner.DefaultMode);

        options.Scenarios ??= Array.Empty<ScenarioSettings>();

        if (string.Equals(options.Web.Ports.PortStrategy, "Fixed", StringComparison.OrdinalIgnoreCase) &&
            options.Web.Ports.FixedPort is null)
        {
            throw new OptionsValidationException(
                nameof(WebSettings),
                typeof(WebSettings),
                new[] { "Web:Ports:FixedPort must be specified when PortStrategy is 'Fixed'." });
        }

        var stabilityRuntime = options.Stability.Runtime ?? new StabilityRuntimeSettings();
        if (stabilityRuntime.DefaultMaxRuntimeMinutes < stabilityRuntime.DefaultDurationMinutes)
        {
            stabilityRuntime.DefaultMaxRuntimeMinutes = stabilityRuntime.DefaultDurationMinutes;
        }

        if (stabilityRuntime.Overnight)
        {
            stabilityRuntime.OverrideDurationMinutes ??= stabilityRuntime.OvernightDurationMinutes;
            stabilityRuntime.OverrideMaxRuntimeMinutes ??= stabilityRuntime.OvernightDurationMinutes;
        }
    }

    private static IReadOnlyList<string> Normalize(IReadOnlyList<string>? values)
    {
        if (values is null)
        {
            return Array.Empty<string>();
        }

        return values
            .Where(v => !string.IsNullOrWhiteSpace(v))
            .Select(v => v.Trim())
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();
    }

    private static IReadOnlyList<TestMode> NormalizeModes(IReadOnlyList<TestMode>? modes, TestMode defaultMode)
    {
        var candidate = modes is { Count: > 0 }
            ? modes
            : new[] { defaultMode, defaultMode == TestMode.Electron ? TestMode.Web : TestMode.Electron };

        return candidate
            .Distinct()
            .ToArray();
    }

    private static Dictionary<string, TValue> EnsureDictionary<TValue>(Dictionary<string, TValue>? source)
        where TValue : class
    {
        return source is null
            ? new Dictionary<string, TValue>(StringComparer.OrdinalIgnoreCase)
            : new Dictionary<string, TValue>(source, StringComparer.OrdinalIgnoreCase);
    }
}
