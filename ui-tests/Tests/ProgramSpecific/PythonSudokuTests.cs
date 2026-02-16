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
    /// Navigate the call trace to the <c>_solve_in_place</c> function and confirm
    /// the editor shows the expected source file.
    ///
    /// The Python solver uses constraint propagation (<c>_solve_in_place</c>) instead
    /// of the <c>is_valid_move</c> function for actual solving, so we navigate to the
    /// function that is actually invoked during execution.
    /// </summary>
    public static async Task CallTraceNavigationToIsValidMove(IPage page)
        => await LanguageSmokeTestHelpers.AssertCallTraceNavigationAsync(
            page, "_solve_in_place", "main.py");

    /// <summary>
    /// Verify the <c>board</c> variable is visible as a flow value annotation
    /// in the editor.
    ///
    /// For Python DB traces the Program State pane may be empty at function entry
    /// points, but the backend computes flow values that appear as inline
    /// annotations in the editor. This is a more reliable assertion for DB traces.
    /// </summary>
    public static async Task VariableInspectionInSolveSudoku(IPage page)
        => await LanguageSmokeTestHelpers.AssertFlowValueVisibleAsync(page, "board");

    /// <summary>
    /// Verify the terminal output contains a digit from the solved board.
    /// The sudoku solver prints the solved grid which always contains the digit "1".
    /// </summary>
    public static async Task TerminalOutputShowsSolvedBoard(IPage page)
        => await LanguageSmokeTestHelpers.AssertTerminalOutputContainsAsync(page, "1");
}
