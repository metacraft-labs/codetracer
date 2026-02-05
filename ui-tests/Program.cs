using System.Collections.Generic;
using System.Collections.Immutable;
using System.Linq;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using UiTests.Application;
using UiTests.Configuration;
using UiTests.Execution;
using UiTests.Infrastructure;

namespace UiTests;

internal static class Program
{
    private const string ConfigPathKey = "Runner:Config";

    private static readonly ImmutableDictionary<string, string> SwitchMappings =
        new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            ["--config"] = ConfigPathKey,
            ["-c"] = ConfigPathKey,
            ["--max-parallel"] = "Runner:MaxParallelInstances",
            ["--max-parallelism"] = "Runner:MaxParallelInstances",
            ["--stop-on-fail"] = "Runner:StopOnFirstFailure",
            ["--include"] = "Runner:IncludeTests",
            ["--exclude"] = "Runner:ExcludeTests",
            ["--mode"] = "Runner:ExecutionModes:0",
            ["--default-mode"] = "Runner:DefaultMode",
            ["--verbose-console"] = "Runner:VerboseConsole",
            ["--retries"] = "Runner:MaxRetries"
        }.ToImmutableDictionary(StringComparer.OrdinalIgnoreCase);

    public static async Task<int> Main(string[] args)
    {
        var listMonitors = args.Any(IsListMonitorsOption);
        var sanitizedArgs = args.Where(arg => !IsListMonitorsOption(arg)).ToArray();
        var includeOverrides = ResolveMultiOption(sanitizedArgs, "--include");
        var excludeOverrides = ResolveMultiOption(sanitizedArgs, "--exclude");
        var modeOverrides = ResolveModeOptions(sanitizedArgs);
        var selection = new SuiteProfileSelection(
            ResolveNamedOption(args, "--suite"),
            ResolveNamedOption(args, "--profile"),
            includeOverrides,
            excludeOverrides,
            modeOverrides);

        using var host = CreateHostBuilder(sanitizedArgs, selection).Build();

        if (listMonitors)
        {
            PrintMonitors(host.Services.GetRequiredService<IMonitorLayoutService>());
            return 0;
        }

        var app = host.Services.GetRequiredService<UiTestApplication>();
        return await app.RunAsync();
    }

    private static IHostBuilder CreateHostBuilder(string[] args, SuiteProfileSelection selection)
    {
        return Host.CreateDefaultBuilder(args)
            .UseConsoleLifetime()
            .ConfigureAppConfiguration((context, config) =>
            {
                config.Sources.Clear();

                var env = context.HostingEnvironment;
                config.AddJsonFile("appsettings.json", optional: false, reloadOnChange: false);
                config.AddJsonFile($"appsettings.{env.EnvironmentName}.json", optional: true, reloadOnChange: false);

                var configPath = ResolveConfigPath(args);
                if (!string.IsNullOrWhiteSpace(configPath))
                {
                    var absolutePath = Path.IsPathRooted(configPath)
                        ? configPath
                        : Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, configPath));

                    if (!File.Exists(absolutePath))
                    {
                        throw new FileNotFoundException($"Configuration override file not found: '{absolutePath}'.", absolutePath);
                    }

                    config.AddJsonFile(absolutePath, optional: false, reloadOnChange: false);
                }

                config.AddEnvironmentVariables(prefix: "UITESTS_");
                config.AddCommandLine(args, SwitchMappings);
            })
            .ConfigureServices((context, services) =>
            {
                var configuration = context.Configuration;

                services.AddOptions();
                services.AddSingleton(selection);
                services.AddOptions<AppSettings>()
                    .Bind(configuration)
                    .ValidateDataAnnotations()
                    .ValidateOnStart();

                services.AddSingleton<IParallelismProvider, EnvironmentParallelismProvider>();
                services.AddSingleton<IPostConfigureOptions<AppSettings>, AppSettingsPostConfigure>();
                services.AddSingleton<ICodetracerLauncher, CodetracerLauncher>();
                services.AddSingleton<IPortAllocator, PortAllocator>();
                services.AddSingleton<ICtHostLauncher, CtHostLauncher>();
                services.AddSingleton<IMonitorLayoutService, MonitorLayoutService>();
                services.AddSingleton<ITestRegistry, TestRegistry>();
                services.AddSingleton<ITestPlanner, TestPlanner>();
                services.AddSingleton<IUiTestExecutionPipeline, TestExecutionPipeline>();
                services.AddSingleton<ITestSessionExecutor, ElectronTestSessionExecutor>();
                services.AddSingleton<ITestSessionExecutor, WebTestSessionExecutor>();
                services.AddSingleton<IProcessLifecycleManager, ProcessLifecycleManager>();

                services.AddLogging(builder =>
                {
                    builder.AddSimpleConsole(o =>
                    {
                        o.SingleLine = true;
                        o.TimestampFormat = "HH:mm:ss ";
                    });
                    builder.SetMinimumLevel(LogLevel.Information);
                });

                services.AddSingleton<UiTestApplication>();
            });
    }

    private static string? ResolveConfigPath(IEnumerable<string> args)
    {
        using var enumerator = args.GetEnumerator();
        while (enumerator.MoveNext())
        {
            var current = enumerator.Current;
            if (current is null)
            {
                continue;
            }

            if (current.StartsWith("--config=", StringComparison.OrdinalIgnoreCase))
            {
                return current["--config=".Length..];
            }

            if (string.Equals(current, "--config", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(current, "-c", StringComparison.OrdinalIgnoreCase))
            {
                if (enumerator.MoveNext())
                {
                    return enumerator.Current;
                }

                throw new InvalidOperationException("Missing value for --config argument.");
            }
        }

        return null;
    }

    private static string? ResolveNamedOption(IEnumerable<string> args, string optionName)
    {
        using var enumerator = args.GetEnumerator();
        while (enumerator.MoveNext())
        {
            var current = enumerator.Current;
            if (current is null)
            {
                continue;
            }

            if (current.StartsWith($"{optionName}=", StringComparison.OrdinalIgnoreCase))
            {
                return current[(optionName.Length + 1)..];
            }

            if (string.Equals(current, optionName, StringComparison.OrdinalIgnoreCase))
            {
                if (enumerator.MoveNext())
                {
                    return enumerator.Current;
                }

                throw new InvalidOperationException($"Missing value for {optionName} argument.");
            }
        }

        return null;
    }

    private static IReadOnlyList<string> ResolveMultiOption(IEnumerable<string> args, string optionName)
    {
        var results = new List<string>();
        using var enumerator = args.GetEnumerator();
        while (enumerator.MoveNext())
        {
            var current = enumerator.Current;
            if (current is null)
            {
                continue;
            }

            if (current.StartsWith($"{optionName}=", StringComparison.OrdinalIgnoreCase))
            {
                var value = current[(optionName.Length + 1)..].Trim();
                if (!string.IsNullOrWhiteSpace(value))
                {
                    results.Add(value);
                }
                continue;
            }

            if (string.Equals(current, optionName, StringComparison.OrdinalIgnoreCase))
            {
                if (enumerator.MoveNext())
                {
                    var value = (enumerator.Current ?? string.Empty).Trim();
                    if (!string.IsNullOrWhiteSpace(value))
                    {
                        results.Add(value);
                    }
                    continue;
                }

                throw new InvalidOperationException($"Missing value for {optionName} argument.");
            }
        }

        return results;
    }

    private static IReadOnlyList<TestMode> ResolveModeOptions(IEnumerable<string> args)
    {
        var rawValues = ResolveMultiOption(args, "--mode");
        if (rawValues.Count == 0)
        {
            return Array.Empty<TestMode>();
        }

        var modes = new List<TestMode>(rawValues.Count);
        foreach (var value in rawValues)
        {
            if (!Enum.TryParse<TestMode>(value, ignoreCase: true, out var parsed))
            {
                throw new InvalidOperationException($"Unrecognized mode '{value}'. Expected Electron or Web.");
            }
            modes.Add(parsed);
        }

        return modes;
    }

    private static bool IsListMonitorsOption(string arg)
    {
        if (arg is null)
        {
            return false;
        }

        if (string.Equals(arg, "--list-monitors", StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }

        return arg.StartsWith("--list-monitors=", StringComparison.OrdinalIgnoreCase);
    }

    private static void PrintMonitors(IMonitorLayoutService monitorLayoutService)
    {
        var monitors = monitorLayoutService.DetectMonitors();
        if (monitors.Count == 0)
        {
            Console.WriteLine("No monitors detected.");
            return;
        }

        Console.WriteLine("Detected monitors:");
        for (int i = 0; i < monitors.Count; i++)
        {
            var monitor = monitors[i];
            var primarySuffix = monitor.IsPrimary ? " [primary]" : string.Empty;
            var edid = string.IsNullOrWhiteSpace(monitor.Edid) ? "n/a" : monitor.Edid;
            Console.WriteLine($"  {i + 1}: {monitor.Name} {monitor.Width}x{monitor.Height} at {monitor.X},{monitor.Y}{primarySuffix} - EDID: {edid}");
        }
    }
}
