using System.Collections.Generic;
using System.Linq;
using Microsoft.Extensions.Logging;
using UiTests.Infrastructure;

namespace UiTests.Execution;

internal static class MonitorSelectionHelper
{
    public static MonitorInfo? SelectPreferredMonitor(
        IReadOnlyList<MonitorInfo> monitors,
        string? preferredEdid,
        int? preferredIndex,
        ILogger logger,
        string scenarioId,
        bool verboseConsole)
    {
        if (monitors.Count == 0)
        {
            if (verboseConsole)
            {
                logger.LogInformation("[{Scenario}] Could not detect monitor layout; using browser defaults.", scenarioId);
            }
            return null;
        }

        MonitorInfo? selected = null;

        if (!string.IsNullOrWhiteSpace(preferredEdid))
        {
            selected = monitors.FirstOrDefault(m =>
                string.Equals(m.Edid, preferredEdid, StringComparison.OrdinalIgnoreCase));

            if (selected is null)
            {
                logger.LogWarning(
                    "[{Scenario}] Preferred EDID '{PreferredEdid}' not found among detected monitors; falling back to index or default ordering.",
                    scenarioId,
                    preferredEdid);
            }
        }

        if (!selected.HasValue && preferredIndex.HasValue && preferredIndex.Value > 0)
        {
            if (preferredIndex.Value <= monitors.Count)
            {
                selected = monitors[preferredIndex.Value - 1];
            }
            else
            {
                logger.LogWarning(
                    "[{Scenario}] Preferred display index {PreferredIndex} is not available (detected {MonitorCount} monitor(s)); falling back to default ordering.",
                    scenarioId,
                    preferredIndex.Value,
                    monitors.Count);
            }
        }

        if (!selected.HasValue)
        {
            selected = monitors
                .OrderByDescending(m => m.IsPrimary)
                .ThenBy(m => m.Y)
                .ThenBy(m => m.X)
                .First();
        }

        if (verboseConsole)
        {
            logger.LogInformation(
                "[{Scenario}] Targeting monitor '{Monitor}' ({Width}x{Height} at {X},{Y}){Edid}.",
                scenarioId,
                selected.Value.Name,
                selected.Value.Width,
                selected.Value.Height,
                selected.Value.X,
                selected.Value.Y,
                string.IsNullOrWhiteSpace(selected.Value.Edid) ? string.Empty : $" [EDID={selected.Value.Edid}]");
        }

        return selected;
    }
}
