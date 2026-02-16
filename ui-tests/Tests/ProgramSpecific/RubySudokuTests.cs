using System.Threading.Tasks;
using Microsoft.Playwright;

namespace UiTests.Tests.ProgramSpecific;

/// <summary>
/// Smoke tests for the Ruby Sudoku Solver test program (<c>rb_sudoku_solver</c>).
///
/// Each test is a thin wrapper that delegates to the shared
/// <see cref="LanguageSmokeTestHelpers"/> so the assertions remain language-agnostic
/// while the parameters are specific to the Ruby program under test.
/// </summary>
public static class RubySudokuTests
{
    /// <summary>
    /// Verify the editor opens a tab for the main Ruby source file.
    /// </summary>
    public static async Task EditorLoadsSudokuSolverRb(IPage page)
        => await LanguageSmokeTestHelpers.AssertEditorLoadsFileAsync(page, "sudoku_solver.rb");

    /// <summary>
    /// Verify the event log contains at least one recorded event.
    /// </summary>
    public static async Task EventLogPopulated(IPage page)
        => await LanguageSmokeTestHelpers.AssertEventLogPopulatedAsync(page);

    /// <summary>
    /// Navigate the call trace to the <c>solve</c> method and confirm
    /// the editor shows the expected source file.
    /// </summary>
    public static async Task CallTraceNavigationToSolve(IPage page)
        => await LanguageSmokeTestHelpers.AssertCallTraceNavigationAsync(
            page, "solve", "sudoku_solver.rb");

    /// <summary>
    /// Navigate to the <c>solve</c> method and verify the <c>board</c>
    /// variable is visible in the Program State pane.
    /// The Ruby instance variable <c>@board</c> may be displayed as <c>board</c>
    /// in the variable pane depending on the tracer implementation.
    /// </summary>
    public static async Task VariableInspectionBoard(IPage page)
        => await LanguageSmokeTestHelpers.AssertVariableVisibleAsync(
            page, "solve", "board");

    /// <summary>
    /// Verify the terminal output contains a digit from the solved board.
    /// The sudoku solver prints the solved grid which always contains the digit "1".
    /// </summary>
    public static async Task TerminalOutputShowsSolvedBoard(IPage page)
        => await LanguageSmokeTestHelpers.AssertTerminalOutputContainsAsync(page, "1");
}
