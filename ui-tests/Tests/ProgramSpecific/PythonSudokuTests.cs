using System.Threading.Tasks;
using Microsoft.Playwright;

namespace UiTests.Tests.ProgramSpecific;

/// <summary>
/// Smoke tests for the Python Sudoku Solver test program (<c>py_sudoku_solver</c>).
///
/// Each test is a thin wrapper that delegates to the shared
/// <see cref="LanguageSmokeTestHelpers"/> so the assertions remain language-agnostic
/// while the parameters are specific to the Python program under test.
/// </summary>
public static class PythonSudokuTests
{
    /// <summary>
    /// Verify the editor opens a tab for the main Python source file.
    /// </summary>
    public static async Task EditorLoadsMainPy(IPage page)
        => await LanguageSmokeTestHelpers.AssertEditorLoadsFileAsync(page, "main.py");

    /// <summary>
    /// Verify the event log contains at least one recorded event.
    /// </summary>
    public static async Task EventLogPopulated(IPage page)
        => await LanguageSmokeTestHelpers.AssertEventLogPopulatedAsync(page);

    /// <summary>
    /// Navigate the call trace to the <c>is_valid_move</c> function and confirm
    /// the editor shows the expected source file.
    /// </summary>
    public static async Task CallTraceNavigationToIsValidMove(IPage page)
        => await LanguageSmokeTestHelpers.AssertCallTraceNavigationAsync(
            page, "is_valid_move", "main.py");

    /// <summary>
    /// Navigate to the <c>solve_sudoku</c> function and verify the <c>board</c>
    /// variable is visible in the Program State pane.
    /// </summary>
    public static async Task VariableInspectionInSolveSudoku(IPage page)
        => await LanguageSmokeTestHelpers.AssertVariableVisibleAsync(
            page, "solve_sudoku", "board");

    /// <summary>
    /// Verify the terminal output contains a digit from the solved board.
    /// The sudoku solver prints the solved grid which always contains the digit "1".
    /// </summary>
    public static async Task TerminalOutputShowsSolvedBoard(IPage page)
        => await LanguageSmokeTestHelpers.AssertTerminalOutputContainsAsync(page, "1");
}
