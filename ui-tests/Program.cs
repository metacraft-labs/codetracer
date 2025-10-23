using System.Collections.Immutable;
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
            ["--default-mode"] = "Runner:DefaultMode"
        }.ToImmutableDictionary(StringComparer.OrdinalIgnoreCase);

    public static async Task<int> Main(string[] args)
    {
        using var host = CreateHostBuilder(args).Build();
        var app = host.Services.GetRequiredService<UiTestApplication>();
        return await app.RunAsync();
    }

    private static IHostBuilder CreateHostBuilder(string[] args)
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
}
