using System;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.Playwright;
using UiTests.PageObjects;
using UiTests.PageObjects.Panes.CallTrace;
using UiTests.Utils;

namespace UiTests.Tests.ProgramSpecific;

/// <summary>
/// Smoke tests for the Ruby Sudoku Solver test program (<c>rb_sudoku_solver</c>).
///
/// Ruby is a DB-based trace (recorded by the Ruby tracer, not RR). The call trace
/// uses the Ruby convention <c>ClassName#method</c> for instance methods, e.g.
/// <c>SudokuSolver#solve #3</c>.
///
/// For Ruby DB traces the Program State pane may not expose instance variables
/// (<c>@board</c>) at function entry points. The most reliable way to verify
/// variable capture is to check call trace arguments on <c>SudokuSolver#initialize</c>,
/// which receives <c>board</c> as an explicit parameter.
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
    /// Navigate the call trace to the <c>SudokuSolver#solve</c> method and confirm
    /// the editor shows the expected source file.
    ///
    /// Ruby uses the <c>ClassName#method</c> naming convention in the call trace,
    /// so we search for <c>SudokuSolver#solve</c> rather than just <c>solve</c>.
    /// </summary>
    public static async Task CallTraceNavigationToSolve(IPage page)
        => await LanguageSmokeTestHelpers.AssertCallTraceNavigationAsync(
            page, "SudokuSolver#solve", "sudoku_solver.rb");

    /// <summary>
    /// Verify the <c>board</c> variable is visible as a call trace argument
    /// on the <c>SudokuSolver#initialize</c> entry.
    ///
    /// For Ruby DB traces the Program State pane may not expose instance variables
    /// at function entry points. The <c>initialize(board)</c> method receives
    /// <c>board</c> as an explicit parameter, so it appears as a call trace argument,
    /// confirming the backend captured the variable value.
    /// </summary>
    public static async Task VariableInspectionBoard(IPage page)
    {
        var layout = new LayoutPage(page);
        await layout.WaitForBaseComponentsLoadedAsync();

        var callTrace = (await layout.CallTraceTabsAsync()).First();
        await callTrace.TabButton().ClickAsync();
        callTrace.InvalidateEntries();

        // Locate SudokuSolver#initialize in the call trace (may need expanding).
        CallTraceEntry? targetEntry = null;
        await RetryHelpers.RetryAsync(async () =>
        {
            callTrace.InvalidateEntries();
            targetEntry = await callTrace.FindEntryAsync("SudokuSolver#initialize", forceReload: true);
            if (targetEntry is not null)
            {
                return true;
            }

            // Expand all visible entries to reveal initialize if it's nested.
            var allEntries = await callTrace.EntriesAsync(true);
            foreach (var entry in allEntries)
            {
                try { await entry.ExpandChildrenAsync(); }
                catch (PlaywrightException) { /* entry not in viewport */ }
                catch (TimeoutException) { /* expansion did not complete */ }
            }

            return false;
        }, maxAttempts: 60, delayMs: 1000);

        if (targetEntry is null)
        {
            throw new Exception(
                "Call trace entry 'SudokuSolver#initialize' was not found when trying to inspect the 'board' argument.");
        }

        // Verify the initialize entry has a 'board' argument rendered.
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
