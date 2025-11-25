using System;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using UiTests.Configuration;
using UiTests.Execution;
using UiTests.PageObjects;
using UiTests.Stability;
using UiTests.Tests.Stability;

namespace UiTests.Tests.Stability;

public static class StabilityEventLogTests
{
    public static async Task EventLogForwardReverse(TestExecutionContext context)
    {
        var stabilitySettings = context.Settings.Stability;
        var runtimeSettings = stabilitySettings.Runtime;
        var (durationMinutes, maxRuntimeMinutes, programOverrides) = StabilityTestUtilities.ResolveRuntime(context, runtimeSettings, stabilitySettings);
        var iterationLimit = context.Scenario.StabilityIterationLimit
            ?? programOverrides?.IterationLimit;

        var runId = $"{DateTime.UtcNow:yyyyMMdd_HHmmssfff}";
        var runDirectory = StabilityTestUtilities.CreateRunDirectory(stabilitySettings, context.Scenario.Id, runId);

        var seed = stabilitySettings.DefaultSeed;
        var startTime = DateTimeOffset.UtcNow;
        var model = StabilityModel.Create(
            programOverrides?.ProgramPath ?? programOverrides?.Id ?? context.Scenario.TraceProgram ?? context.Settings.Electron.TraceProgram,
            startTime,
            TimeSpan.FromMinutes(durationMinutes),
            iterationLimit,
            seed);

        var script = new EventLogStabilityScript(TimeSpan.FromMinutes(maxRuntimeMinutes), iterationLimit);
        var layout = new LayoutPage(context.Page);
        await layout.WaitForAllComponentsLoadedAsync();
        var screenshotRoot = Path.Combine(runDirectory, "screenshots");
        var commandHandler = new PlaywrightStabilityCommandHandler(layout, context.Page, screenshotRoot);
        await using var logWriter = new StabilityLogWriter(runDirectory, context.Scenario.Id, runId);
        logWriter.LogStart(model);
        var store = new StabilityStore(
            model,
            script,
            commandHandler,
            onIntent: (intent, state) => logWriter.LogIntent(intent, state),
            onCommand: (command, state) => logWriter.LogCommand(command, state));

        await store.RunAsync(context.CancellationToken);
        logWriter.LogCompletion(store.State, DateTimeOffset.UtcNow);
    }

}
