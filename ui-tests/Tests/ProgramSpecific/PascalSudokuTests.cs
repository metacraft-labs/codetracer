using System.Threading.Tasks;
using Microsoft.Playwright;

namespace UiTests.Tests.ProgramSpecific;

/// <summary>
/// Smoke tests for the Pascal Sudoku Solver test program (<c>pascal_sudoku_solver</c>).
///
/// This is an RR-based trace (compiled Pascal recorded with <c>rr</c>), which may be
/// slower than DB-based traces. Each test is a thin wrapper that delegates to the
/// shared <see cref="LanguageSmokeTestHelpers"/> so the assertions remain
/// language-agnostic while the parameters are specific to the Pascal program under test.
///
/// For RR traces the initial position is the program entry point (<c>main</c>).
/// The call trace only shows the current call stack at this position, so tests
/// verify the entry-point function rather than deeper call targets. The terminal
/// output test navigates forward to a position where output has been produced.
/// </summary>
public static class PascalSudokuTests
{
    /// <summary>
    /// Verify the editor opens a tab for the Pascal source file.
    /// </summary>
    public static async Task EditorLoadsSudokuPas(IPage page)
        => await LanguageSmokeTestHelpers.AssertEditorLoadsFileAsync(page, "sudoku.pas");

    /// <summary>
    /// Verify the event log contains at least one recorded event.
    /// </summary>
    public static async Task EventLogPopulated(IPage page)
        => await LanguageSmokeTestHelpers.AssertEventLogPopulatedAsync(page);

    /// <summary>
    /// Verify the call trace shows the entry-point function (<c>$main</c>) and
    /// that activating it keeps the editor on the expected source file.
    ///
    /// For RR traces at the initial position, the call trace shows the current
    /// call stack (just <c>$main</c>), not the full execution tree.
    /// Free Pascal prefixes the main program entry with <c>$</c> in the debugger.
    /// </summary>
    public static async Task CallTraceNavigationToSolve(IPage page)
        => await LanguageSmokeTestHelpers.AssertCallTraceNavigationAsync(page, "$main", "sudoku.pas");

    /// <summary>
    /// Verify that the <c>boards</c> variable is visible as a flow value
    /// annotation in the editor.
    ///
    /// RR traces may not show variables in the Program State pane at the entry
    /// point, so flow value annotations in the editor are more reliable.
    /// </summary>
    public static async Task VariableInspectionBoard(IPage page)
        => await LanguageSmokeTestHelpers.AssertFlowValueVisibleAsync(page, "boards");

    /// <summary>
    /// Verify the program produced stdout output containing "Solved".
    ///
    /// For RR traces the terminal pane does not display output (the
    /// <c>load_terminal</c> handler only reads from the DB event store which
    /// is empty for RR). Instead we check the event log for a stdout event
    /// that contains the expected text, which proves the solver ran and
    /// produced output during the recording.
    /// </summary>
    public static async Task TerminalOutputShowsSolvedBoard(IPage page)
        => await LanguageSmokeTestHelpers.AssertEventLogContainsTextAsync(page, "Solved");
}
