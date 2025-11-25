using System;
using System.Collections.Generic;
using System.IO;
using System.Threading.Tasks;
using UiTests.Execution;
using UiTests.PageObjects;
using UiTests.Stability;

namespace UiTests.Tests.Stability;

public static class StabilityAdditionalTests
{
    public static async Task DebuggerContinueRunToEntry(TestExecutionContext context)
        => await RunLoopAsync(
            context,
            new StabilityIntent[]
            {
                new ContinueToEndIntent(),
                new RunToEntryIntent()
            },
            testName: "DebuggerContinueRunToEntry");

    public static async Task SteppingForwardReverse(TestExecutionContext context)
        => await RunLoopAsync(
            context,
            new StabilityIntent[]
            {
                new StepIntoIntent(),
                new ReverseStepIntoIntent()
            },
            testName: "SteppingForwardReverse");

    public static async Task PaneToggleCycle(TestExecutionContext context)
        => await RunLoopAsync(
            context,
            new StabilityIntent[]
            {
                new TogglePaneIntent("Event Log"),
                new TogglePaneIntent("Scratchpad"),
                new TogglePaneIntent("Filesystem"),
                new TogglePaneIntent("State"),
                new TogglePaneIntent("Call Trace"),
                new TogglePaneIntent("Terminal Output")
            },
            testName: "PaneToggleCycle");

    public static async Task FilesystemOpenCloseSweep(TestExecutionContext context)
        => await RunLoopAsync(
            context,
            new StabilityIntent[]
            {
                new OpenAllFilesIntent(),
                new CloseAllEditorsIntent(),
                new OpenAllFilesIntent()
            },
            testName: "FilesystemOpenCloseSweep");

    private static async Task RunLoopAsync(TestExecutionContext context, IReadOnlyList<StabilityIntent> sequence, string testName)
    {
        var stabilitySettings = context.Settings.Stability;
        var runtimeSettings = stabilitySettings.Runtime;
        var (durationMinutes, maxRuntimeMinutes, programOverrides) = StabilityTestUtilities.ResolveRuntime(context, runtimeSettings, stabilitySettings);

        var runId = $"{DateTime.UtcNow:yyyyMMdd_HHmmssfff}";
        var runDirectory = StabilityTestUtilities.CreateRunDirectory(stabilitySettings, context.Scenario.Id, runId, testName);

        var seed = stabilitySettings.DefaultSeed;
        var startTime = DateTimeOffset.UtcNow;
        var model = StabilityModel.Create(
            programOverrides?.ProgramPath ?? programOverrides?.Id ?? context.Scenario.TraceProgram ?? context.Settings.Electron.TraceProgram,
            startTime,
            TimeSpan.FromMinutes(durationMinutes),
            targetIterations: null,
            seed);

        var script = new LoopIntentScript(sequence, TimeSpan.FromMinutes(maxRuntimeMinutes));
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
