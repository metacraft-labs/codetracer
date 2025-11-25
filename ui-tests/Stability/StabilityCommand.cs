namespace UiTests.Stability;

/// <summary>
/// Marker base type for stability commands (side-effect descriptions).
/// </summary>
public abstract record StabilityCommand;

public sealed record ReadEventLogSnapshotCommand : StabilityCommand;

public sealed record JumpToEventIndexCommand(int TargetIndex) : StabilityCommand;

public sealed record AssertEventHighlightCommand(int TargetIndex) : StabilityCommand;

public sealed record LogMessageCommand(string Message) : StabilityCommand;

public enum DebuggerControl
{
    Continue,
    RunToEntry,
    StepNext,
    StepInto,
    StepOut,
    ReverseContinue,
    ReverseStepNext,
    ReverseStepInto,
    ReverseStepOut
}

public sealed record ClickDebuggerControlCommand(DebuggerControl Control) : StabilityCommand;

public sealed record TogglePaneCommand(string PaneName) : StabilityCommand;

public sealed record OpenAllFilesystemFilesCommand : StabilityCommand;

public sealed record CloseAllEditorsCommand : StabilityCommand;

public sealed record CaptureScreenshotCommand(string Label, bool FailOnly = false) : StabilityCommand;
