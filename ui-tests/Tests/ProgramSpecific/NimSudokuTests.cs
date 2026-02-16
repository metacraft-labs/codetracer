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
    /// Navigate the call trace to the <c>solveSudoku</c> function and confirm
    /// the editor shows the expected source file.
    /// </summary>
    public static async Task CallTraceNavigationToSolveSudoku(IPage page)
        => await LanguageSmokeTestHelpers.AssertCallTraceNavigationAsync(page, "solveSudoku", "main.nim");

    /// <summary>
    /// Navigate to the <c>solveSudoku</c> function and verify the <c>board</c>
    /// variable is visible in the Program State pane.
    /// </summary>
    public static async Task VariableInspectionBoard(IPage page)
        => await LanguageSmokeTestHelpers.AssertVariableVisibleAsync(page, "solveSudoku", "board");

    /// <summary>
    /// Verify the terminal output contains a digit from the solved board.
    /// The sudoku solver prints the solved grid which always contains the digit "1".
    /// </summary>
    public static async Task TerminalOutputShowsSolvedBoard(IPage page)
        => await LanguageSmokeTestHelpers.AssertTerminalOutputContainsAsync(page, "1");
}
