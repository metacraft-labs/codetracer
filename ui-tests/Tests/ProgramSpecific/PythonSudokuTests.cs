using System;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.Playwright;
using UiTests.PageObjects;
using UiTests.PageObjects.Panes.CallTrace;
using UiTests.Utils;

namespace UiTests.Tests.ProgramSpecific;

/// <summary>
/// Smoke tests for the Python Sudoku Solver test program (<c>py_sudoku_solver</c>).
///
/// Python programs are recorded as DB traces (not RR), so the call trace shows the
/// full execution tree and the event log/terminal are populated immediately. However,
/// the Program State pane may be empty at function entry points for DB traces, and
/// flow values only appear in the visible editor viewport.
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
    /// Navigate the call trace to the <c>solve_sudoku</c> function and confirm
    /// the editor shows the expected source file.
    ///
    /// The call trace for the simplified board shows <c>solve_sudoku</c> as a
    /// direct child of <c>_solve_and_print</c>, making it visible without deep
    /// tree expansion.
    /// </summary>
    public static async Task CallTraceNavigationToIsValidMove(IPage page)
        => await LanguageSmokeTestHelpers.AssertCallTraceNavigationAsync(
            page, "solve_sudoku", "main.py");

    /// <summary>
    /// Verify the <c>board</c> variable is visible as a call trace argument
    /// on the <c>solve_sudoku</c> entry.
    ///
    /// For Python DB traces the Program State pane is typically empty at function
    /// entry points, and flow values only appear when the editor viewport shows the
    /// relevant lines. The most reliable way to verify variable visibility is to
    /// check that the call trace entry for <c>solve_sudoku</c> renders a
    /// <c>board</c> argument, confirming the backend captured the variable value.
    /// </summary>
    public static async Task VariableInspectionInSolveSudoku(IPage page)
    {
        var layout = new LayoutPage(page);
        await layout.WaitForBaseComponentsLoadedAsync();

        var callTrace = (await layout.CallTraceTabsAsync()).First();
        await callTrace.TabButton().ClickAsync();
        callTrace.InvalidateEntries();

        // Locate solve_sudoku in the call trace (may need expanding _solve_and_print first).
        CallTraceEntry? targetEntry = null;
        await RetryHelpers.RetryAsync(async () =>
        {
            callTrace.InvalidateEntries();
            targetEntry = await callTrace.FindEntryAsync("solve_sudoku", forceReload: true);
            if (targetEntry is not null)
            {
                return true;
            }

            // Expand all visible entries to reveal solve_sudoku if it's nested.
            var allEntries = await callTrace.EntriesAsync(true);
            foreach (var entry in allEntries)
            {
                try { await entry.ExpandChildrenAsync(); }
                catch (TimeoutException) { /* some entries may not support expansion */ }
            }

            return false;
        }, maxAttempts: 60, delayMs: 1000);

        if (targetEntry is null)
        {
            throw new Exception(
                "Call trace entry 'solve_sudoku' was not found when trying to inspect the 'board' argument.");
        }

        // Verify the solve_sudoku entry has a 'board' argument rendered.
        await RetryHelpers.RetryAsync(async () =>
        {
            var args = await targetEntry.ArgumentsAsync();
            foreach (var arg in args)
            {
                var name = await arg.NameAsync();
                if (string.Equals(name, "board", StringComparison.OrdinalIgnoreCase))
                {
                    return true;
                }
            }

            return false;
        }, maxAttempts: 30, delayMs: 1000);
    }

    /// <summary>
    /// Verify the terminal output contains a digit from the solved board.
    /// The sudoku solver prints the solved grid which always contains the digit "1".
    /// </summary>
    public static async Task TerminalOutputShowsSolvedBoard(IPage page)
        => await LanguageSmokeTestHelpers.AssertTerminalOutputContainsAsync(page, "1");
}
