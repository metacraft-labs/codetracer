using System;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.Playwright;
using UiTests.PageObjects;
using UiTests.PageObjects.Panes.CallTrace;
using UiTests.PageObjects.Panes.EventLog;
using UiTests.PageObjects.Panes.VariableState;
using UiTests.Utils;

namespace UiTests.Tests.ProgramSpecific;

/// <summary>
/// Language-agnostic smoke test helpers that verify core CodeTracer UI functionality
/// against any traced program. Each helper accepts an <see cref="IPage"/> and
/// language-specific parameters (file name, function name, variable name, etc.).
///
/// These helpers are designed to be thin wrappers around the page-object layer so
/// that language-specific test classes (e.g. PythonSudokuTests, RubySmokeTests) can
/// remain one-liners that delegate all heavy lifting here.
/// </summary>
public static class LanguageSmokeTestHelpers
{
    /// <summary>
    /// Verify the editor loads the expected source file tab.
    /// The assertion uses a case-insensitive substring match on the tab button text
    /// to accommodate path prefixes such as "src/main.py" vs "main.py".
    /// </summary>
    public static async Task AssertEditorLoadsFileAsync(IPage page, string expectedFileName)
    {
        var layout = new LayoutPage(page);
        await layout.WaitForAllComponentsLoadedAsync();

        await RetryHelpers.RetryAsync(async () =>
        {
            var editors = await layout.EditorTabsAsync(forceReload: true);
            return editors.Any(e =>
                e.TabButtonText.Contains(expectedFileName, StringComparison.OrdinalIgnoreCase));
        }, maxAttempts: 20, delayMs: 300);
    }

    /// <summary>
    /// Verify the event log has at least one event entry.
    /// Opens the event log tab, waits for rows to appear, and asserts count > 0.
    /// </summary>
    public static async Task AssertEventLogPopulatedAsync(IPage page)
    {
        var layout = new LayoutPage(page);
        await layout.WaitForAllComponentsLoadedAsync();

        var eventLog = (await layout.EventLogTabsAsync()).First();
        await eventLog.TabButton().ClickAsync();

        await RetryHelpers.RetryAsync(async () =>
        {
            var events = await eventLog.EventElementsAsync(forceReload: true);
            return events.Count > 0;
        }, maxAttempts: 30, delayMs: 300);
    }

    /// <summary>
    /// Navigate call trace to find a function by name, activate it, and verify that
    /// the editor jumps to a tab whose name contains <paramref name="expectedFile"/>.
    ///
    /// The helper searches through the top-level call trace entries, expanding them
    /// if necessary until the target function is found.
    /// </summary>
    public static async Task AssertCallTraceNavigationAsync(
        IPage page, string functionName, string expectedFile)
    {
        var layout = new LayoutPage(page);
        await layout.WaitForAllComponentsLoadedAsync();

        var callTrace = (await layout.CallTraceTabsAsync()).First();
        await callTrace.TabButton().ClickAsync();
        callTrace.InvalidateEntries();

        // Locate the target entry, expanding parent entries if needed.
        CallTraceEntry? targetEntry = null;
        await RetryHelpers.RetryAsync(async () =>
        {
            callTrace.InvalidateEntries();
            targetEntry = await callTrace.FindEntryAsync(functionName, forceReload: true);
            if (targetEntry is not null)
            {
                return true;
            }

            // The function might be nested inside collapsed entries. Expand all visible
            // entries and search again on the next retry.
            var allEntries = await callTrace.EntriesAsync(true);
            foreach (var entry in allEntries)
            {
                await entry.ExpandChildrenAsync();
            }

            return false;
        }, maxAttempts: 25, delayMs: 300);

        if (targetEntry is null)
        {
            throw new Exception(
                $"Call trace entry '{functionName}' was not found after expanding all visible entries.");
        }

        await targetEntry.ActivateAsync();

        // After navigation the editor should show a tab containing the expected file name.
        await RetryHelpers.RetryAsync(async () =>
        {
            var editors = await layout.EditorTabsAsync(forceReload: true);
            return editors.Any(e =>
                e.TabButtonText.Contains(expectedFile, StringComparison.OrdinalIgnoreCase));
        }, maxAttempts: 20, delayMs: 300);
    }

    /// <summary>
    /// Navigate to a function via the call trace and verify that a named variable
    /// is visible in the Program State pane.
    ///
    /// This helper first activates the target call trace entry, then opens the
    /// state pane and waits for the expected variable to appear.
    /// </summary>
    public static async Task AssertVariableVisibleAsync(
        IPage page, string functionName, string variableName)
    {
        var layout = new LayoutPage(page);
        await layout.WaitForAllComponentsLoadedAsync();

        var callTrace = (await layout.CallTraceTabsAsync()).First();
        await callTrace.TabButton().ClickAsync();
        callTrace.InvalidateEntries();

        // Locate and activate the call trace entry for the given function.
        CallTraceEntry? targetEntry = null;
        await RetryHelpers.RetryAsync(async () =>
        {
            callTrace.InvalidateEntries();
            targetEntry = await callTrace.FindEntryAsync(functionName, forceReload: true);
            if (targetEntry is not null)
            {
                return true;
            }

            var allEntries = await callTrace.EntriesAsync(true);
            foreach (var entry in allEntries)
            {
                await entry.ExpandChildrenAsync();
            }

            return false;
        }, maxAttempts: 25, delayMs: 300);

        if (targetEntry is null)
        {
            throw new Exception(
                $"Call trace entry '{functionName}' was not found when trying to inspect variable '{variableName}'.");
        }

        await targetEntry.ActivateAsync();

        // Open the state pane and look for the variable.
        var statePane = (await layout.ProgramStateTabsAsync()).First();
        await statePane.TabButton().ClickAsync();

        await RetryHelpers.RetryAsync(async () =>
        {
            var variables = await statePane.ProgramStateVariablesAsync(forceReload: true);
            foreach (var variable in variables)
            {
                var name = await variable.NameAsync();
                if (string.Equals(name, variableName, StringComparison.OrdinalIgnoreCase))
                {
                    return true;
                }
            }

            return false;
        }, maxAttempts: 30, delayMs: 300);
    }

    /// <summary>
    /// Verify that the terminal output pane contains the expected text.
    ///
    /// The terminal pane is accessed through <see cref="LayoutPage.TerminalTabsAsync"/>
    /// and its rendered lines are checked for a case-insensitive substring match.
    /// </summary>
    public static async Task AssertTerminalOutputContainsAsync(IPage page, string expectedText)
    {
        var layout = new LayoutPage(page);
        await layout.WaitForAllComponentsLoadedAsync();

        var terminalTabs = await layout.TerminalTabsAsync();
        if (terminalTabs.Count == 0)
        {
            throw new Exception("No terminal output pane was found in the layout.");
        }

        var terminal = terminalTabs.First();
        await terminal.TabButton().ClickAsync();

        await RetryHelpers.RetryAsync(async () =>
        {
            var lines = await terminal.LinesAsync(forceReload: true);
            foreach (var line in lines)
            {
                var text = await line.TextAsync();
                if (text.Contains(expectedText, StringComparison.OrdinalIgnoreCase))
                {
                    return true;
                }
            }

            return false;
        }, maxAttempts: 30, delayMs: 300);
    }
}
