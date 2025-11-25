using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using UiTests.Configuration;
using UiTests.Execution;

namespace UiTests.Tests.Stability;

internal static class StabilityTestUtilities
{
    public static (int DurationMinutes, int MaxRuntimeMinutes, StabilityProgramSettings? Program) ResolveRuntime(TestExecutionContext context, StabilityRuntimeSettings runtimeSettings, StabilitySettings stabilitySettings)
    {
        var programId = context.Scenario.TraceProgram ?? context.Settings.Electron.TraceProgram;
        var programOverrides = stabilitySettings.Programs.FirstOrDefault(p =>
            string.Equals(p.Id, programId, StringComparison.OrdinalIgnoreCase) ||
            string.Equals(p.ProgramPath, programId, StringComparison.OrdinalIgnoreCase));

        var duration = ResolveDurationMinutes(context, runtimeSettings, programOverrides);
        var maxRuntime = runtimeSettings.OverrideMaxRuntimeMinutes
            ?? runtimeSettings.DefaultMaxRuntimeMinutes;

        if (context.Scenario.StabilityOvernight || runtimeSettings.Overnight)
        {
            duration = runtimeSettings.OvernightDurationMinutes;
            maxRuntime = runtimeSettings.OvernightDurationMinutes;
        }

        return (duration, maxRuntime, programOverrides);
    }

    public static int ResolveDurationMinutes(
        TestExecutionContext context,
        StabilityRuntimeSettings runtimeSettings,
        StabilityProgramSettings? programOverrides)
    {
        if (context.Scenario.StabilityOvernight || runtimeSettings.Overnight)
        {
            return runtimeSettings.OvernightDurationMinutes;
        }

        if (context.Scenario.StabilityDurationMinutes.HasValue)
        {
            return context.Scenario.StabilityDurationMinutes.Value;
        }

        if (runtimeSettings.OverrideDurationMinutes.HasValue)
        {
            return runtimeSettings.OverrideDurationMinutes.Value;
        }

        if (programOverrides?.DurationMinutes is not null)
        {
            return programOverrides.DurationMinutes.Value;
        }

        return runtimeSettings.DefaultDurationMinutes;
    }

    public static string CreateRunDirectory(StabilitySettings settings, string scenarioId, string runId, params string[] additionalSegments)
    {
        var segments = new List<string> { settings.Artifacts.Root, "logs", "stability", scenarioId, runId };
        if (additionalSegments is { Length: > 0 })
        {
            segments.AddRange(additionalSegments);
        }

        var path = Path.Combine(segments.ToArray());
        Directory.CreateDirectory(path);
        return path;
    }
}
