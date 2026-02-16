using System.Collections.Concurrent;
using System.Linq;
using UiTests.Tests;
using UiTests.Tests.ProgramAgnostic;
using UiTests.Tests.ProgramSpecific;
using UiTests.Utils;

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
                "NoirSpaceShip.SimpleLoopIterationJump",
                "Noir Space Ship / Simple Loop Iteration Jump",
                async context => await NoirSpaceShipTests.SimpleLoopIterationJump(context.Page)));

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

        // Keyboard-driven command palette shortcuts diverge between Electron and Web runtimes, and the
        // current Playwright keyboard emulation does not trigger the palette reliably. Temporarily omit
        // these program-agnostic cases until we add explicit platform bindings.
        //
        // Register(
        //     new UiTestDescriptor(
        //         "CommandPalette.SwitchThemeUpdatesStyles",
        //         "Program Agnostic / Command Palette Switch Theme",
        //         async context => await ProgramAgnosticTests.CommandPaletteSwitchThemeUpdatesStyles(context.Page)));
        //
        // Register(
        //     new UiTestDescriptor(
        //         "CommandPalette.FindSymbolUsesFuzzySearch",
        //         "Program Agnostic / Command Palette Symbol Search",
        //         async context => await ProgramAgnosticTests.CommandPaletteFindSymbolUsesFuzzySearch(context.Page)));

        Register(
            new UiTestDescriptor(
                "ViewMenu.OpensEventLogAndScratchpad",
                "Program Agnostic / View Menu Opens Event Log And Scratchpad",
                async context => await ProgramAgnosticTests.ViewMenuOpensEventLogAndScratchpad(context.Page)));

        // Keyboard shortcut coverage is disabled until we can send platform-specific chords across
        // Electron and Web sessions without flaking.
        //
        // Register(
        //     new UiTestDescriptor(
        //         "DebuggerControls.StepButtonsReflectBusyState",
        //         "Program Agnostic / Debugger Controls Reflect Busy State",
        //         async context => await ProgramAgnosticTests.DebuggerControlsStepButtonsReflectBusyState(context.Page)));
        //
        // Register(
        //     new UiTestDescriptor(
        //         "EventLog.FilterTraceVsRecorded",
        //         "Program Agnostic / Event Log Filter Trace vs Recorded",
        //         async context => await ProgramAgnosticTests.EventLogFilterTraceVsRecorded(context.Page)));
        //
        // Register(
        //     new UiTestDescriptor(
        //         "EditorShortcuts.CtrlF8CtrlF11",
        //         "Program Agnostic / Editor Shortcuts Ctrl+F8 / Ctrl+F11",
        //         async context => await ProgramAgnosticTests.EditorShortcutsCtrlF8CtrlF11(context.Page)));

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

        // Layout resilience tests - verify app can recover from corrupt layout files
        Register(
            new UiTestDescriptor(
                "Layout.RecoveryFromCorruptedJson",
                "Layout Resilience / Recovery From Corrupted JSON",
                async context => await LayoutResilienceTests.RecoveryFromCorruptedJson(context.Page)));

        Register(
            new UiTestDescriptor(
                "Layout.RecoveryFromInvalidStructure",
                "Layout Resilience / Recovery From Invalid Structure",
                async context => await LayoutResilienceTests.RecoveryFromInvalidStructure(context.Page)));

        Register(
            new UiTestDescriptor(
                "Layout.RecoveryFromMissingType",
                "Layout Resilience / Recovery From Missing Type",
                async context => await LayoutResilienceTests.RecoveryFromMissingType(context.Page)));

        Register(
            new UiTestDescriptor(
                "Layout.NormalOperationWithValidLayout",
                "Layout Resilience / Normal Operation With Valid Layout",
                async context => await LayoutResilienceTests.NormalOperationWithValidLayout(context.Page)));

        // Python Sudoku Solver smoke tests
        Register(
            new UiTestDescriptor(
                "PythonSudoku.EditorLoadsMainPy",
                "Python Sudoku / Editor Loads main.py",
                async context => await PythonSudokuTests.EditorLoadsMainPy(context.Page),
                "py_sudoku_solver"));

        Register(
            new UiTestDescriptor(
                "PythonSudoku.EventLogPopulated",
                "Python Sudoku / Event Log Populated",
                async context => await PythonSudokuTests.EventLogPopulated(context.Page),
                "py_sudoku_solver"));

        Register(
            new UiTestDescriptor(
                "PythonSudoku.CallTraceNavigationToIsValidMove",
                "Python Sudoku / Call Trace Navigation To is_valid_move",
                async context => await PythonSudokuTests.CallTraceNavigationToIsValidMove(context.Page),
                "py_sudoku_solver"));

        Register(
            new UiTestDescriptor(
                "PythonSudoku.VariableInspectionInSolveSudoku",
                "Python Sudoku / Variable Inspection In solve_sudoku",
                async context => await PythonSudokuTests.VariableInspectionInSolveSudoku(context.Page),
                "py_sudoku_solver"));

        Register(
            new UiTestDescriptor(
                "PythonSudoku.TerminalOutputShowsSolvedBoard",
                "Python Sudoku / Terminal Output Shows Solved Board",
                async context => await PythonSudokuTests.TerminalOutputShowsSolvedBoard(context.Page),
                "py_sudoku_solver"));

        // Ruby Sudoku Solver smoke tests
        Register(
            new UiTestDescriptor(
                "RubySudoku.EditorLoadsSudokuSolverRb",
                "Ruby Sudoku / Editor Loads sudoku_solver.rb",
                async context => await RubySudokuTests.EditorLoadsSudokuSolverRb(context.Page),
                "rb_sudoku_solver"));

        Register(
            new UiTestDescriptor(
                "RubySudoku.EventLogPopulated",
                "Ruby Sudoku / Event Log Populated",
                async context => await RubySudokuTests.EventLogPopulated(context.Page),
                "rb_sudoku_solver"));

        Register(
            new UiTestDescriptor(
                "RubySudoku.CallTraceNavigationToSolve",
                "Ruby Sudoku / Call Trace Navigation To solve",
                async context => await RubySudokuTests.CallTraceNavigationToSolve(context.Page),
                "rb_sudoku_solver"));

        Register(
            new UiTestDescriptor(
                "RubySudoku.VariableInspectionBoard",
                "Ruby Sudoku / Variable Inspection board",
                async context => await RubySudokuTests.VariableInspectionBoard(context.Page),
                "rb_sudoku_solver"));

        Register(
            new UiTestDescriptor(
                "RubySudoku.TerminalOutputShowsSolvedBoard",
                "Ruby Sudoku / Terminal Output Shows Solved Board",
                async context => await RubySudokuTests.TerminalOutputShowsSolvedBoard(context.Page),
                "rb_sudoku_solver"));

        // C Sudoku Solver smoke tests
        Register(
            new UiTestDescriptor(
                "CSudoku.EditorLoadsMainC",
                "C Sudoku / Editor Loads main.c",
                async context => await CSudokuTests.EditorLoadsMainC(context.Page),
                "c_sudoku_solver"));

        Register(
            new UiTestDescriptor(
                "CSudoku.EventLogPopulated",
                "C Sudoku / Event Log Populated",
                async context => await CSudokuTests.EventLogPopulated(context.Page),
                "c_sudoku_solver"));

        Register(
            new UiTestDescriptor(
                "CSudoku.CallTraceNavigationToSolve",
                "C Sudoku / Call Trace Navigation To solve",
                async context => await CSudokuTests.CallTraceNavigationToSolve(context.Page),
                "c_sudoku_solver"));

        Register(
            new UiTestDescriptor(
                "CSudoku.VariableInspectionBoard",
                "C Sudoku / Variable Inspection board",
                async context => await CSudokuTests.VariableInspectionBoard(context.Page),
                "c_sudoku_solver"));

        Register(
            new UiTestDescriptor(
                "CSudoku.TerminalOutputShowsSolvedBoard",
                "C Sudoku / Terminal Output Shows Solved Board",
                async context => await CSudokuTests.TerminalOutputShowsSolvedBoard(context.Page),
                "c_sudoku_solver"));

        // Rust Sudoku Solver smoke tests
        Register(
            new UiTestDescriptor(
                "RustSudoku.EditorLoadsMainRs",
                "Rust Sudoku / Editor Loads main.rs",
                async context => await RustSudokuTests.EditorLoadsMainRs(context.Page),
                "rs_sudoku_solver"));

        Register(
            new UiTestDescriptor(
                "RustSudoku.EventLogPopulated",
                "Rust Sudoku / Event Log Populated",
                async context => await RustSudokuTests.EventLogPopulated(context.Page),
                "rs_sudoku_solver"));

        Register(
            new UiTestDescriptor(
                "RustSudoku.CallTraceNavigationToSolve",
                "Rust Sudoku / Call Trace Navigation To solve",
                async context => await RustSudokuTests.CallTraceNavigationToSolve(context.Page),
                "rs_sudoku_solver"));

        Register(
            new UiTestDescriptor(
                "RustSudoku.VariableInspectionBoard",
                "Rust Sudoku / Variable Inspection board",
                async context => await RustSudokuTests.VariableInspectionBoard(context.Page),
                "rs_sudoku_solver"));

        Register(
            new UiTestDescriptor(
                "RustSudoku.TerminalOutputShowsSolvedBoard",
                "Rust Sudoku / Terminal Output Shows Solved Board",
                async context => await RustSudokuTests.TerminalOutputShowsSolvedBoard(context.Page),
                "rs_sudoku_solver"));
    }

    public IReadOnlyCollection<UiTestDescriptor> All => _tests.Values.ToList();

    public bool TryResolve(string identifier, out UiTestDescriptor descriptor)
        => _tests.TryGetValue(identifier, out descriptor);

    private void Register(UiTestDescriptor descriptor)
    {
        var wrapped = WrapWithCompletionLog(descriptor);
        if (!_tests.TryAdd(wrapped.Id, wrapped))
        {
            throw new InvalidOperationException($"Duplicate test identifier registered: {descriptor.Id}");
        }
    }

    private static UiTestDescriptor WrapWithCompletionLog(UiTestDescriptor descriptor)
    {
        async Task Handler(TestExecutionContext context)
        {
            await descriptor.Handler(context);
            DebugLogger.Log($"{descriptor.Id}: completed");
        }

        return descriptor with { Handler = Handler };
    }
}
