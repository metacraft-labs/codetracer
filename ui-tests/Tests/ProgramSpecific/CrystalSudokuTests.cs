using System.Threading.Tasks;
using Microsoft.Playwright;

namespace UiTests.Tests.ProgramSpecific;

/// <summary>
/// Smoke tests for the Crystal Sudoku Solver test program (<c>crystal_sudoku_solver</c>).
///
/// This is an RR-based trace (compiled Crystal recorded with <c>rr</c>), which may be
/// slower than DB-based traces. Each test is a thin wrapper that delegates to the
/// shared <see cref="LanguageSmokeTestHelpers"/> so the assertions remain
/// language-agnostic while the parameters are specific to the Crystal program under test.
///
/// For RR traces the initial position is the program entry point (<c>main</c>).
/// The call trace only shows the current call stack at this position, so tests
/// verify the entry-point function rather than deeper call targets. The terminal
/// output test navigates forward to a position where output has been produced.
///
/// Crystal's runtime wraps user code in <c>main</c> defined in
/// <c>crystal/main.cr</c>, so the editor opens the runtime source at the
/// initial RR position. The state pane shows runtime variables like <c>argc</c>.
/// </summary>
public static class CrystalSudokuTests
{
    /// <summary>
    /// Verify the editor opens a tab for the Crystal runtime entry point.
    /// Crystal's <c>main</c> lives in <c>crystal/main.cr</c>.
    /// </summary>
    public static async Task EditorLoadsSudokuCr(IPage page)
        => await LanguageSmokeTestHelpers.AssertEditorLoadsFileAsync(page, "main.cr");

    /// <summary>
    /// Verify the event log contains at least one recorded event.
    /// </summary>
    public static async Task EventLogPopulated(IPage page)
        => await LanguageSmokeTestHelpers.AssertEventLogPopulatedAsync(page);

    /// <summary>
    /// Verify the call trace shows the entry-point function (<c>main</c>) and
    /// that activating it opens the Crystal runtime entry source.
    ///
    /// For RR traces at the initial position, the call trace shows the current
    /// call stack (just <c>main</c>), not the full execution tree.
    /// Crystal's <c>main</c> maps to <c>crystal/main.cr</c>.
    /// </summary>
    public static async Task CallTraceNavigationToSolve(IPage page)
        => await LanguageSmokeTestHelpers.AssertCallTraceNavigationAsync(page, "main", "main.cr");

    /// <summary>
    /// Verify that the <c>status</c> runtime variable is visible in the
    /// Program State pane.
    ///
    /// At the Crystal runtime entry point, user variables are not yet
    /// initialized. The state pane shows runtime variables like <c>status</c>.
    /// </summary>
    public static async Task VariableInspectionBoard(IPage page)
        => await LanguageSmokeTestHelpers.AssertFlowValueVisibleAsync(page, "status");

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
