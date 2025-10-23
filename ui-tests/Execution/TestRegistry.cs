using System.Collections.Concurrent;
using System.Linq;
using UiTests.Tests;
using UiTests.Tests.ProgramAgnostic;

namespace UiTests.Execution;

internal interface ITestRegistry
{
    bool TryResolve(string identifier, out UiTestDescriptor descriptor);
    IReadOnlyCollection<UiTestDescriptor> All { get; }
}

internal sealed class TestRegistry : ITestRegistry
{
    private readonly ConcurrentDictionary<string, UiTestDescriptor> _tests;

    public TestRegistry()
    {
        _tests = new ConcurrentDictionary<string, UiTestDescriptor>(StringComparer.OrdinalIgnoreCase);

        Register(
            new UiTestDescriptor(
                "NoirSpaceShip.JumpToAllEvents",
                "Noir Space Ship / Jump To All Events",
                async context => await NoirSpaceShipTests.JumpToAllEvents(context.Page)));

        Register(
            new UiTestDescriptor(
                "NoirSpaceShip.EditorLoadedMainNrFile",
                "Noir Space Ship / Editor Loads main.nr",
                async context => await NoirSpaceShipTests.EditorLoadedMainNrFile(context.Page)));

        Register(
            new UiTestDescriptor(
                "NoirSpaceShip.CalculateDamageCalltraceNavigation",
                "Noir Space Ship / Call Trace Navigation To calculate_damage",
                async context => await NoirSpaceShipTests.CalculateDamageCalltraceNavigation(context.Page)));

        Register(
            new UiTestDescriptor(
                "NoirSpaceShip.LoopIterationSliderTracksRemainingShield",
                "Noir Space Ship / Loop Slider Tracks Remaining Shield",
                async context => await NoirSpaceShipTests.LoopIterationSliderTracksRemainingShield(context.Page)));

        Register(
            new UiTestDescriptor(
                "NoirSpaceShip.EventLogJumpHighlightsActiveRow",
                "Noir Space Ship / Event Log Jump Highlights Active Row",
                async context => await NoirSpaceShipTests.EventLogJumpHighlightsActiveRow(context.Page)));

        Register(
            new UiTestDescriptor(
                "NoirSpaceShip.TraceLogRecordsDamageRegeneration",
                "Noir Space Ship / Trace Log Records Damage And Regeneration",
                async context => await NoirSpaceShipTests.TraceLogRecordsDamageRegeneration(context.Page)));

        Register(
            new UiTestDescriptor(
                "NoirSpaceShip.RemainingShieldHistoryChronology",
                "Noir Space Ship / Remaining Shield History Chronology",
                async context => await NoirSpaceShipTests.RemainingShieldHistoryChronology(context.Page)));

        Register(
            new UiTestDescriptor(
                "NoirSpaceShip.ScratchpadCompareIterations",
                "Noir Space Ship / Scratchpad Compare Iterations",
                async context => await NoirSpaceShipTests.ScratchpadCompareIterations(context.Page)));

        Register(
            new UiTestDescriptor(
                "NoirSpaceShip.StepControlsRecoverFromReverse",
                "Noir Space Ship / Step Controls Recover From Reverse",
                async context => await NoirSpaceShipTests.StepControlsRecoverFromReverse(context.Page)));

        Register(
            new UiTestDescriptor(
                "TraceLog.DisableButtonShouldFlipState",
                "Program Agnostic / Trace Log Disable Button Flips State",
                async context => await NoirSpaceShipTests.TraceLogDisableButtonShouldFlipState(context.Page)));

        Register(
            new UiTestDescriptor(
                "CommandPalette.SwitchThemeUpdatesStyles",
                "Program Agnostic / Command Palette Switch Theme",
                async context => await ProgramAgnosticTests.CommandPaletteSwitchThemeUpdatesStyles(context.Page)));

        Register(
            new UiTestDescriptor(
                "CommandPalette.FindSymbolUsesFuzzySearch",
                "Program Agnostic / Command Palette Symbol Search",
                async context => await ProgramAgnosticTests.CommandPaletteFindSymbolUsesFuzzySearch(context.Page)));

        Register(
            new UiTestDescriptor(
                "ViewMenu.OpensEventLogAndScratchpad",
                "Program Agnostic / View Menu Opens Event Log And Scratchpad",
                async context => await ProgramAgnosticTests.ViewMenuOpensEventLogAndScratchpad(context.Page)));

        Register(
            new UiTestDescriptor(
                "DebuggerControls.StepButtonsReflectBusyState",
                "Program Agnostic / Debugger Controls Reflect Busy State",
                async context => await ProgramAgnosticTests.DebuggerControlsStepButtonsReflectBusyState(context.Page)));

        Register(
            new UiTestDescriptor(
                "EventLog.FilterTraceVsRecorded",
                "Program Agnostic / Event Log Filter Trace vs Recorded",
                async context => await ProgramAgnosticTests.EventLogFilterTraceVsRecorded(context.Page)));

        Register(
            new UiTestDescriptor(
                "EditorShortcuts.CtrlF8CtrlF11",
                "Program Agnostic / Editor Shortcuts Ctrl+F8 / Ctrl+F11",
                async context => await ProgramAgnosticTests.EditorShortcutsCtrlF8CtrlF11(context.Page)));

        Register(
            new UiTestDescriptor(
                "NoirSpaceShip.CreateSimpleTracePoint",
                "Noir Space Ship / Create Simple Trace Point",
                async context => await NoirSpaceShipTests.CreateSimpleTracePoint(context.Page)));

        Register(
            new UiTestDescriptor(
                "NoirSpaceShip.ExhaustiveScratchpadAdditions",
                "Noir Space Ship / Exhaustive Scratchpad Additions",
                async context => await NoirSpaceShipTests.ExhaustiveScratchpadAdditions(context.Page)));

        Register(
            new UiTestDescriptor(
                "NoirSpaceShip.FilesystemContextMenuOptions",
                "Noir Space Ship / Filesystem Context Menu Options",
                async context => await NoirSpaceShipTests.FilesystemContextMenuOptions(context.Page)));

        Register(
            new UiTestDescriptor(
                "NoirSpaceShip.CallTraceContextMenuOptions",
                "Noir Space Ship / Call Trace Context Menu Options",
                async context => await NoirSpaceShipTests.CallTraceContextMenuOptions(context.Page)));

        Register(
            new UiTestDescriptor(
                "NoirSpaceShip.FlowContextMenuOptions",
                "Noir Space Ship / Flow Context Menu Options",
                async context => await NoirSpaceShipTests.FlowContextMenuOptions(context.Page)));

        Register(
            new UiTestDescriptor(
                "NoirSpaceShip.TraceLogContextMenuOptions",
                "Noir Space Ship / Trace Log Context Menu Options",
                async context => await NoirSpaceShipTests.TraceLogContextMenuOptions(context.Page)));

        Register(
            new UiTestDescriptor(
                "NoirSpaceShip.ValueHistoryContextMenuOptions",
                "Noir Space Ship / Value History Context Menu Options",
                async context => await NoirSpaceShipTests.ValueHistoryContextMenuOptions(context.Page)));
    }

    public IReadOnlyCollection<UiTestDescriptor> All => _tests.Values.ToList();

    public bool TryResolve(string identifier, out UiTestDescriptor descriptor)
        => _tests.TryGetValue(identifier, out descriptor);

    private void Register(UiTestDescriptor descriptor)
    {
        if (!_tests.TryAdd(descriptor.Id, descriptor))
        {
            throw new InvalidOperationException($"Duplicate test identifier registered: {descriptor.Id}");
        }
    }
}
