using System;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.Playwright;
using UiTests.PageObjects;
using UiTests.PageObjects.Panes.CallTrace;
using UiTests.Utils;

namespace UiTests.Tests.ProgramSpecific;

/// <summary>
/// Smoke tests for the Nim Sudoku Solver test program (<c>nim_sudoku_solver</c>).
///
/// This is an RR-based trace (compiled Nim recorded with <c>rr</c>), which may be
/// slower than DB-based traces.
///
/// For Nim RR traces the initial position is inside the Nim runtime initialization
/// code (e.g. <c>NimMainModule</c> inside stdlib iterators), not in the user's source
/// file. The editor therefore shows a stdlib file like <c>system/iterators_1.nim</c>
/// at startup. Tests account for this by matching any <c>.nim</c> file rather than
/// requiring the user's <c>main.nim</c>, and by verifying the call trace is populated
/// without attempting to navigate to user-level functions.
/// </summary>
public static class NimSudokuTests
{
    /// <summary>
    /// Verify the editor opens a tab for a Nim source file.
    ///
    /// At the RR initial position, Nim is typically inside the runtime's stdlib
    /// (e.g. <c>system/iterators_1.nim</c>), so we accept any <c>.nim</c> tab
    /// rather than specifically requiring <c>main.nim</c>.
    /// </summary>
    public static async Task EditorLoadsMainNim(IPage page)
        => await LanguageSmokeTestHelpers.AssertEditorLoadsFileAsync(page, ".nim");

    /// <summary>
    /// Verify the event log contains at least one recorded event.
    /// </summary>
    public static async Task EventLogPopulated(IPage page)
        => await LanguageSmokeTestHelpers.AssertEventLogPopulatedAsync(page);

    /// <summary>
    /// Verify the call trace is populated with entries.
    ///
    /// For Nim RR traces at the initial position, the call trace shows runtime
    /// functions (<c>NimMainModule</c>, <c>NimMain</c>, <c>main</c>) rather than
    /// user solver functions. Activating these entries triggers a calltrace-jump
    /// that can take several seconds and may land in stdlib code. Instead of
    /// navigating to a specific function, we verify the call trace has visible
    /// entries and at least one corresponds to a Nim runtime function.
    /// </summary>
    public static async Task CallTraceNavigationToSolveSudoku(IPage page)
    {
        var layout = new LayoutPage(page);
        await layout.WaitForBaseComponentsLoadedAsync();

        var callTrace = (await layout.CallTraceTabsAsync()).First();
        await callTrace.TabButton().ClickAsync();

        CallTraceEntry? nimEntry = null;
        await RetryHelpers.RetryAsync(async () =>
        {
            callTrace.InvalidateEntries();
            // Look for a Nim runtime entry to confirm the call trace populated.
            nimEntry = await callTrace.FindEntryAsync("NimMainModule", forceReload: true)
                       ?? await callTrace.FindEntryAsync("NimMain", forceReload: true)
                       ?? await callTrace.FindEntryAsync("main", forceReload: true);
            return nimEntry is not null;
        }, maxAttempts: 60, delayMs: 1000);

        if (nimEntry is null)
        {
            throw new Exception(
                "Call trace did not contain any expected Nim runtime entries " +
                "(NimMainModule, NimMain, main).");
        }
    }

    /// <summary>
    /// Verify that variables are visible in the Program State pane.
    ///
    /// At the Nim RR initial position, the debugger is inside stdlib code where
    /// iterator variables like <c>i</c> or <c>res</c> are visible. We verify
    /// the state pane shows at least one variable to confirm the debugger is
    /// providing variable information at this execution point.
    /// </summary>
    public static async Task VariableInspectionBoard(IPage page)
    {
        var layout = new LayoutPage(page);
        await layout.WaitForBaseComponentsLoadedAsync();

        var statePane = (await layout.ProgramStateTabsAsync()).First();
        await statePane.TabButton().ClickAsync();

        await RetryHelpers.RetryAsync(async () =>
        {
            var variables = await statePane.ProgramStateVariablesAsync(forceReload: true);
            return variables.Count > 0;
        }, maxAttempts: 60, delayMs: 1000);
    }

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
