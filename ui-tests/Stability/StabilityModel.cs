using System;

namespace UiTests.Stability;

public enum NavigationDirection
{
    Forward = 1,
    Reverse = -1
}

/// <summary>
/// In-memory model tracking stability navigation state.
/// </summary>
public sealed record StabilityModel(
    string ProgramId,
    DateTimeOffset StartedAt,
    DateTimeOffset Deadline,
    int Seed,
    int? TargetIterations,
    int? EventLogRowCount,
    int? ActiveIndex,
    NavigationDirection Direction,
    int IterationsCompleted)
{
    public bool IsTimeboundComplete(DateTimeOffset now) => now >= Deadline;

    public bool IsIterationComplete => TargetIterations.HasValue && IterationsCompleted >= TargetIterations.Value;

    public static StabilityModel Create(string programId, DateTimeOffset startedAt, TimeSpan duration, int? targetIterations, int seed)
    {
        return new StabilityModel(
            programId,
            startedAt,
            startedAt + duration,
            seed,
            targetIterations,
            EventLogRowCount: null,
            ActiveIndex: null,
            Direction: NavigationDirection.Forward,
            IterationsCompleted: 0);
    }
}
