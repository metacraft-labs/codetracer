using System.Threading.Tasks;
using Microsoft.Playwright;

namespace UiTests.Tests.ProgramSpecific;

/// <summary>
/// Smoke tests for the Nim Sudoku Solver test program (<c>nim_sudoku_solver</c>).
///
/// This is an RR-based trace (compiled Nim recorded with <c>rr</c>), which may be
/// slower than DB-based traces. Each test is a thin wrapper that delegates to the
/// shared <see cref="LanguageSmokeTestHelpers"/> so the assertions remain
/// language-agnostic while the parameters are specific to the Nim program under test.
///
/// For RR traces the initial position is the program entry point.
/// The call trace only shows the current call stack at this position, so tests
/// verify the entry-point function rather than deeper call targets. The terminal
/// output test navigates forward to a position where output has been produced.
/// </summary>
public static class NimSudokuTests
{
    /// <summary>
    /// Verify the editor opens a tab for the main Nim source file.
    /// </summary>
    public static async Task EditorLoadsMainNim(IPage page)
        => await LanguageSmokeTestHelpers.AssertEditorLoadsFileAsync(page, "main.nim");

    /// <summary>
    /// Verify the event log contains at least one recorded event.
    /// </summary>
    public static async Task EventLogPopulated(IPage page)
        => await LanguageSmokeTestHelpers.AssertEventLogPopulatedAsync(page);

    /// <summary>
    /// Verify the call trace shows the entry-point function and that activating it
    /// keeps the editor on the expected source file.
    ///
    /// For RR traces at the initial position, the call trace shows the current
    /// call stack, not the full execution tree.  Nim compiles the
    /// <c>isMainModule</c> block into the module initialization function.
    /// </summary>
    public static async Task CallTraceNavigationToSolveSudoku(IPage page)
        => await LanguageSmokeTestHelpers.AssertCallTraceNavigationAsync(page, "main", "main.nim");

    /// <summary>
    /// Verify that the <c>testBoards</c> variable is visible as a flow value
    /// annotation in the editor.
    ///
    /// RR traces may not show variables in the Program State pane at the entry
    /// point, so flow value annotations in the editor are more reliable.
    /// </summary>
    public static async Task VariableInspectionBoard(IPage page)
        => await LanguageSmokeTestHelpers.AssertFlowValueVisibleAsync(page, "testBoards");

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
