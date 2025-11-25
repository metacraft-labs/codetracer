using System;

namespace UiTests.Stability;

public sealed class EventLogStabilityScript : IStabilityScript
{
    private readonly TimeSpan _maxRuntime;
    private readonly int? _iterationLimit;

    public EventLogStabilityScript(TimeSpan maxRuntime, int? iterationLimit = null)
    {
        _maxRuntime = maxRuntime;
        _iterationLimit = iterationLimit;
    }

    public StabilityIntent? NextIntent(StabilityModel state, DateTimeOffset now)
    {
        if (state.EventLogRowCount is null)
        {
            return new RequestEventLogSnapshot();
        }

        if (state.EventLogRowCount.Value <= 0)
        {
            return new StopRequested("Event log is empty.");
        }

        if (IsComplete(state, now))
        {
            return null;
        }

        if (state.EventLogRowCount.Value == 1)
        {
            return new JumpToEventIndex(1);
        }

        var target = state.Direction == NavigationDirection.Forward
            ? Math.Min(state.ActiveIndex.GetValueOrDefault(0) + 1, state.EventLogRowCount.Value)
            : Math.Max(state.ActiveIndex.GetValueOrDefault(state.EventLogRowCount.Value + 1) - 1, 1);

        return new JumpToEventIndex(target);
    }

    public bool IsComplete(StabilityModel state, DateTimeOffset now)
    {
        var timeUp = now >= state.Deadline || now >= state.StartedAt + _maxRuntime;
        var iterationsDone = _iterationLimit.HasValue && state.IterationsCompleted >= _iterationLimit.Value;
        return timeUp || iterationsDone;
    }
}
