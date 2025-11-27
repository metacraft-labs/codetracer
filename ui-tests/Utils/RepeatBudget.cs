using System;
using UiTests.Configuration;

namespace UiTests.Utils;

/// <summary>
/// Tracks a time-bound repetition budget with a minimum iteration guarantee.
/// </summary>
internal sealed class RepeatBudget
{
    private readonly DateTimeOffset _deadline;
    private readonly int _minIterations;

    private RepeatBudget(DateTimeOffset deadline, int minIterations)
    {
        _deadline = deadline;
        _minIterations = minIterations;
    }

    public bool ShouldContinue(int completedIterations)
    {
        if (completedIterations < _minIterations)
        {
            return true;
        }

        return DateTimeOffset.UtcNow < _deadline;
    }

    public static RepeatBudget FromSettings(AppSettings? settings, int defaultMinutes = 1, int minIterations = 10)
    {
        var minutes = settings?.Runner.RepeatDurationMinutes ?? defaultMinutes;
        minutes = Math.Max(1, minutes);
        var deadline = DateTimeOffset.UtcNow.AddMinutes(minutes);
        return new RepeatBudget(deadline, minIterations);
    }
}
