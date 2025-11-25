using System;

namespace UiTests.Stability;

/// <summary>
/// Marker base type for stability intents.
/// </summary>
public abstract record StabilityIntent
{
    public DateTimeOffset CreatedAt { get; init; } = DateTimeOffset.UtcNow;
}

public sealed record StartStabilitySession(
    string ProgramId,
    TimeSpan MaxRuntime,
    int? IterationLimit,
    int Seed) : StabilityIntent;

public sealed record RequestEventLogSnapshot() : StabilityIntent;

public sealed record EventLogSnapshotReceived(
    int RowCount,
    int? ActiveIndex) : StabilityIntent;

public sealed record JumpToEventIndex(int TargetIndex) : StabilityIntent;

public sealed record JumpCompleted(int TargetIndex) : StabilityIntent;

public sealed record IterationCompleted(int CompletedIterations) : StabilityIntent;

public sealed record StopRequested(string Reason) : StabilityIntent;

// Debugger controls
public sealed record ContinueToEndIntent() : StabilityIntent;
public sealed record RunToEntryIntent() : StabilityIntent;
public sealed record StepNextIntent() : StabilityIntent;
public sealed record StepIntoIntent() : StabilityIntent;
public sealed record StepOutIntent() : StabilityIntent;
public sealed record ReverseContinueIntent() : StabilityIntent;
public sealed record ReverseStepNextIntent() : StabilityIntent;
public sealed record ReverseStepIntoIntent() : StabilityIntent;
public sealed record ReverseStepOutIntent() : StabilityIntent;

// Panes and filesystem
public sealed record TogglePaneIntent(string PaneName) : StabilityIntent;
public sealed record OpenAllFilesIntent() : StabilityIntent;
public sealed record CloseAllEditorsIntent() : StabilityIntent;
