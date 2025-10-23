using System.Linq;
using Microsoft.Extensions.Options;
using UiTests.Execution;
using UiTests.Infrastructure;

namespace UiTests.Configuration;

internal sealed class AppSettingsPostConfigure : IPostConfigureOptions<AppSettings>
{
    private readonly IParallelismProvider _parallelismProvider;

    public AppSettingsPostConfigure(IParallelismProvider parallelismProvider)
    {
        _parallelismProvider = parallelismProvider;
    }

    public void PostConfigure(string? name, AppSettings options)
    {
        options.Runner ??= new RunnerSettings();
        options.Electron ??= new ElectronSettings();
        options.Web ??= new WebSettings();
        options.Web.Ports ??= new HostPortSettings();

        var recommended = Math.Max(1, _parallelismProvider.GetRecommendedParallelism());
        if (options.Runner.MaxParallelInstances is null || options.Runner.MaxParallelInstances <= 0)
        {
            options.Runner.MaxParallelInstances = recommended;
        }
        else
        {
            options.Runner.MaxParallelInstances = Math.Max(1, options.Runner.MaxParallelInstances.Value);
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
}
