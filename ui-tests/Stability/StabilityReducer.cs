using System;
using System.Collections.Generic;

namespace UiTests.Stability;

public static class StabilityReducer
{
    public static (StabilityModel Next, IReadOnlyList<StabilityCommand> Commands) Reduce(StabilityModel state, StabilityIntent intent)
    {
        switch (intent)
        {
            case StartStabilitySession:
                return (state, new StabilityCommand[] { new ReadEventLogSnapshotCommand() });

            case RequestEventLogSnapshot:
                return (state, new StabilityCommand[] { new ReadEventLogSnapshotCommand() });

            case EventLogSnapshotReceived snapshot:
                if (snapshot.RowCount <= 0)
                {
                    throw new InvalidOperationException("Event log did not contain any rows.");
                }

                var activeIndex = snapshot.ActiveIndex ?? 0;
                if (activeIndex < 0)
                {
                    activeIndex = 0;
                }

                if (activeIndex > snapshot.RowCount)
                {
                    activeIndex = snapshot.RowCount;
                }

                return (
                    state with
                    {
                        EventLogRowCount = snapshot.RowCount,
                        ActiveIndex = activeIndex
                    },
                    Array.Empty<StabilityCommand>());

            case JumpToEventIndex jump:
                if (!state.EventLogRowCount.HasValue)
                {
                    throw new InvalidOperationException("Cannot request a jump before event log snapshot is available.");
                }

                if (jump.TargetIndex <= 0 || jump.TargetIndex > state.EventLogRowCount.Value)
                {
                    throw new InvalidOperationException($"Jump target {jump.TargetIndex} is outside the event log range [1,{state.EventLogRowCount.Value}].");
                }

                return (
                    state,
                    new StabilityCommand[]
                    {
                        new JumpToEventIndexCommand(jump.TargetIndex),
                        new AssertEventHighlightCommand(jump.TargetIndex),
                        new LogMessageCommand($"Jumped to event index {jump.TargetIndex}")
                    });

            case JumpCompleted completed:
                var nextDirection = state.Direction;
                var iterationsCompleted = state.IterationsCompleted;

                if (state.EventLogRowCount.HasValue && state.EventLogRowCount.Value > 1)
                {
                    if (state.Direction == NavigationDirection.Forward && completed.TargetIndex >= state.EventLogRowCount.Value)
                    {
                        nextDirection = NavigationDirection.Reverse;
                    }
                    else if (state.Direction == NavigationDirection.Reverse && completed.TargetIndex <= 1)
                    {
                        nextDirection = NavigationDirection.Forward;
                        iterationsCompleted += 1;
                    }
                }

                return (
                    state with
                    {
                        ActiveIndex = completed.TargetIndex,
                        Direction = nextDirection,
                        IterationsCompleted = iterationsCompleted
                    },
                    Array.Empty<StabilityCommand>());

            case IterationCompleted iterationCompleted:
                return (
                    state with { IterationsCompleted = iterationCompleted.CompletedIterations },
                    Array.Empty<StabilityCommand>());

            case StopRequested:
                return (state, Array.Empty<StabilityCommand>());

            case ContinueToEndIntent:
                return (state, new StabilityCommand[] { new ClickDebuggerControlCommand(DebuggerControl.Continue) });

            case RunToEntryIntent:
                return (state, new StabilityCommand[] { new ClickDebuggerControlCommand(DebuggerControl.RunToEntry) });

            case StepNextIntent:
                return (state, new StabilityCommand[] { new ClickDebuggerControlCommand(DebuggerControl.StepNext) });

            case StepIntoIntent:
                return (state, new StabilityCommand[] { new ClickDebuggerControlCommand(DebuggerControl.StepInto) });

            case StepOutIntent:
                return (state, new StabilityCommand[] { new ClickDebuggerControlCommand(DebuggerControl.StepOut) });

            case ReverseContinueIntent:
                return (state, new StabilityCommand[] { new ClickDebuggerControlCommand(DebuggerControl.ReverseContinue) });

            case ReverseStepNextIntent:
                return (state, new StabilityCommand[] { new ClickDebuggerControlCommand(DebuggerControl.ReverseStepNext) });

            case ReverseStepIntoIntent:
                return (state, new StabilityCommand[] { new ClickDebuggerControlCommand(DebuggerControl.ReverseStepInto) });

            case ReverseStepOutIntent:
                return (state, new StabilityCommand[] { new ClickDebuggerControlCommand(DebuggerControl.ReverseStepOut) });

            case TogglePaneIntent pane:
                return (state, new StabilityCommand[] { new TogglePaneCommand(pane.PaneName) });

            case OpenAllFilesIntent:
                return (state, new StabilityCommand[] { new OpenAllFilesystemFilesCommand() });

            case CloseAllEditorsIntent:
                return (state, new StabilityCommand[] { new CloseAllEditorsCommand() });
        }

        throw new InvalidOperationException($"Unhandled intent type {intent.GetType().Name}");
    }
}
