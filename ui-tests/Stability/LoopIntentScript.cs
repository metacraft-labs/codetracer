using System;
using System.Collections.Generic;

namespace UiTests.Stability;

/// <summary>
/// Simple script that cycles through a fixed sequence of intents until max runtime elapses.
/// </summary>
public sealed class LoopIntentScript : IStabilityScript
{
    private readonly IReadOnlyList<StabilityIntent> _sequence;
    private readonly TimeSpan _maxRuntime;
    private int _index;

    public LoopIntentScript(IReadOnlyList<StabilityIntent> sequence, TimeSpan maxRuntime)
    {
        _sequence = sequence ?? throw new ArgumentNullException(nameof(sequence));
        if (_sequence.Count == 0) throw new ArgumentException("Sequence must contain at least one intent.", nameof(sequence));
        _maxRuntime = maxRuntime;
        _index = 0;
    }

    public StabilityIntent? NextIntent(StabilityModel state, DateTimeOffset now)
    {
        if (IsComplete(state, now))
        {
            return null;
        }

        var intent = _sequence[_index % _sequence.Count];
        _index++;
        return intent;
    }

    public bool IsComplete(StabilityModel state, DateTimeOffset now)
    {
        return now >= state.StartedAt + _maxRuntime || now >= state.Deadline;
    }
}
