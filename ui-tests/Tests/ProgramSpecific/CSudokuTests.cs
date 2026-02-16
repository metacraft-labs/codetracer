using System.Threading.Tasks;
using Microsoft.Playwright;

namespace UiTests.Tests.ProgramSpecific;

/// <summary>
/// Smoke tests for the C Sudoku Solver test program (<c>c_sudoku_solver</c>).
///
/// This is an RR-based trace (compiled C recorded with <c>rr</c>), which may be
/// slower than DB-based traces. Each test is a thin wrapper that delegates to the
/// shared <see cref="LanguageSmokeTestHelpers"/> so the assertions remain
/// language-agnostic while the parameters are specific to the C program under test.
/// </summary>
public static class CSudokuTests
{
    /// <summary>
    /// Verify the editor opens a tab for the main C source file.
    /// </summary>
    public static async Task EditorLoadsMainC(IPage page)
        => await LanguageSmokeTestHelpers.AssertEditorLoadsFileAsync(page, "main.c");

    /// <summary>
    /// Verify the event log contains at least one recorded event.
    /// </summary>
    public static async Task EventLogPopulated(IPage page)
        => await LanguageSmokeTestHelpers.AssertEventLogPopulatedAsync(page);

    /// <summary>
    /// Navigate the call trace to the <c>solve</c> function and confirm
    /// the editor shows the expected source file.
    /// </summary>
    public static async Task CallTraceNavigationToSolve(IPage page)
        => await LanguageSmokeTestHelpers.AssertCallTraceNavigationAsync(page, "solve", "main.c");

    /// <summary>
    /// Navigate to the <c>solve</c> function and verify the <c>board</c>
    /// variable is visible in the Program State pane.
    /// </summary>
    public static async Task VariableInspectionBoard(IPage page)
        => await LanguageSmokeTestHelpers.AssertVariableVisibleAsync(page, "solve", "board");

    /// <summary>
    /// Verify the terminal output contains a digit from the solved board.
    /// The sudoku solver prints the solved grid which always contains the digit "1".
    /// </summary>
    public static async Task TerminalOutputShowsSolvedBoard(IPage page)
        => await LanguageSmokeTestHelpers.AssertTerminalOutputContainsAsync(page, "1");
}
