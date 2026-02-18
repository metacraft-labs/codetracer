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
    ///
    /// For RR-based traces the editor panel is added dynamically when the backend
    /// sends a <c>CtCompleteMove</c> event, so we wait for base components first,
    /// then poll for the editor with a generous timeout.
    /// </summary>
    public static async Task AssertEditorLoadsFileAsync(IPage page, string expectedFileName)
    {
        var layout = new LayoutPage(page);
        await layout.WaitForBaseComponentsLoadedAsync();

        // Wait for the editor component to appear (may take time for RR traces
        // where the backend must start an rr replay session first).
        await RetryHelpers.RetryAsync(async () =>
        {
            var editors = await layout.EditorTabsAsync(forceReload: true);
            return editors.Any(e =>
                e.TabButtonText.Contains(expectedFileName, StringComparison.OrdinalIgnoreCase));
        }, maxAttempts: 60, delayMs: 1000);
    }

    /// <summary>
    /// Verify the event log has at least one event entry.
    /// Opens the event log tab, waits for rows to appear, and asserts count > 0.
    /// </summary>
    public static async Task AssertEventLogPopulatedAsync(IPage page)
    {
        var layout = new LayoutPage(page);
        await layout.WaitForBaseComponentsLoadedAsync();

        var eventLog = (await layout.EventLogTabsAsync()).First();
        await eventLog.TabButton().ClickAsync();

        await RetryHelpers.RetryAsync(async () =>
        {
            var events = await eventLog.EventElementsAsync(forceReload: true);
            return events.Count > 0;
        }, maxAttempts: 60, delayMs: 1000);
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
        await layout.WaitForBaseComponentsLoadedAsync();

        var callTrace = (await layout.CallTraceTabsAsync()).First();
        await callTrace.TabButton().ClickAsync();
        callTrace.InvalidateEntries();

        // Locate the target entry, expanding parent entries if needed.
        // For RR traces the call trace populates after the backend starts replaying,
        // so we use a generous timeout.
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
            // entries and search again on the next retry. Entries scrolled out of the
            // virtualized viewport may throw Playwright timeouts — skip those.
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
                $"Call trace entry '{functionName}' was not found after expanding all visible entries.");
        }

        await targetEntry.ActivateAsync();

        // After navigation the editor should show a tab containing the expected file name.
        await RetryHelpers.RetryAsync(async () =>
        {
            var editors = await layout.EditorTabsAsync(forceReload: true);
            return editors.Any(e =>
                e.TabButtonText.Contains(expectedFile, StringComparison.OrdinalIgnoreCase));
        }, maxAttempts: 30, delayMs: 1000);
    }

    /// <summary>
    /// Navigate to a function via the call trace and verify that a named variable
    /// is visible in the Program State pane.
    ///
    /// This helper first activates the target call trace entry, then opens the
    /// state pane and waits for the expected variable to appear.
    ///
    /// When <paramref name="stepForwardFirst"/> is <c>true</c>, the helper clicks
    /// the step-in button once after activating the call trace entry and waits for
    /// the backend to return to ready state. This is needed for languages like Rust
    /// where local variables are not visible at the very start of a function (before
    /// the first <c>let</c> binding has executed).
    /// </summary>
    public static async Task AssertVariableVisibleAsync(
        IPage page, string functionName, string variableName, bool stepForwardFirst = false)
    {
        var layout = new LayoutPage(page);
        await layout.WaitForBaseComponentsLoadedAsync();

        var callTrace = (await layout.CallTraceTabsAsync()).First();
        await callTrace.TabButton().ClickAsync();
        callTrace.InvalidateEntries();

        // Locate and activate the call trace entry for the given function.
        // For RR traces the call trace populates after the backend starts replaying,
        // so we use a generous timeout.
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
                try { await entry.ExpandChildrenAsync(); }
                catch (PlaywrightException) { /* entry not in viewport */ }
                catch (TimeoutException) { /* expansion did not complete */ }
            }

            return false;
        }, maxAttempts: 60, delayMs: 1000);

        if (targetEntry is null)
        {
            throw new Exception(
                $"Call trace entry '{functionName}' was not found when trying to inspect variable '{variableName}'.");
        }

        await targetEntry.ActivateAsync();

        // For languages like Rust, step over once so that the first variable
        // bindings are executed and become visible in the state pane.
        // We use step-over (#next-debug) rather than step-in to avoid diving
        // into runtime internals (e.g. Rust's alloc::exchange_malloc).
        if (stepForwardFirst)
        {
            var stepOverBtn = page.Locator("#next-debug");
            await stepOverBtn.ClickAsync();

            // Wait for the backend to finish processing the step.
            await RetryHelpers.RetryAsync(async () =>
            {
                var status = page.Locator("#stable-status");
                var className = await status.GetAttributeAsync("class") ?? "";
                return className.Contains("ready-status");
            }, maxAttempts: 60, delayMs: 1000);
        }

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
        }, maxAttempts: 60, delayMs: 1000);
    }

    /// <summary>
    /// Verify that a named variable is visible, checking both flow value annotations
    /// in the editor and the Program State pane.
    ///
    /// This unified helper handles differences across languages:
    /// <list type="bullet">
    ///   <item>Languages with flow support (C, Rust, C++, Nim): flow value annotations
    ///   appear as <c>&lt;span&gt;</c> elements with IDs matching
    ///   <c>flow-parallel-value-box-{editor}-{line}-{varName}</c>.</item>
    ///   <item>Languages without flow support (Go, etc.): the helper falls back to the
    ///   Program State pane, stepping forward up to <paramref name="maxSteps"/> times
    ///   to advance past variable initialization.</item>
    /// </list>
    ///
    /// The helper first waits for the editor, then polls for flow values. If none appear
    /// within a short timeout, it opens the state pane and interleaves step-over clicks
    /// with variable name checks.
    /// </summary>
    public static async Task AssertFlowValueVisibleAsync(
        IPage page, string variableName, int maxSteps = 5)
    {
        var layout = new LayoutPage(page);
        await layout.WaitForBaseComponentsLoadedAsync();

        // Wait for the editor to appear (RR traces may take time to start).
        await RetryHelpers.RetryAsync(async () =>
        {
            var editors = await layout.EditorTabsAsync(forceReload: true);
            return editors.Count > 0;
        }, maxAttempts: 60, delayMs: 1000);

        // Check for the variable via flow value annotations OR the Program State pane.
        //
        // Flow value IDs use the pattern: flow-parallel-value-box-{editor}-{line}-{varName}.
        // Languages with flow support (C, Rust, C++, Nim) will have these annotations
        // computed by the backend.  For RR traces the flow computation involves LLDB
        // replay which can take over 30 seconds (especially for Rust).
        //
        // Languages without flow support (Go, etc.) won't have annotations at all, but
        // they do show variables in the Program State pane after stepping past variable
        // initialization.
        //
        // We check both sources in a single retry loop so that:
        //  - Languages with flow don't waste time on the state pane fallback
        //  - Languages without flow start stepping early instead of waiting 30+s
        var flowSelector = $"span[id*=\"-{variableName}\"][class*=\"flow-parallel-value-box\"]";

        var statePane = (await layout.ProgramStateTabsAsync()).First();
        bool statePaneOpened = false;
        int stepsPerformed = 0;

        await RetryHelpers.RetryAsync(async () =>
        {
            // Check flow annotations first (cheap DOM query).
            var flowElements = await page.Locator(flowSelector).AllAsync();
            if (flowElements.Count > 0)
            {
                return true;
            }

            // Flow not ready yet — also check the state pane (opens it once).
            if (!statePaneOpened)
            {
                await statePane.TabButton().ClickAsync();
                statePaneOpened = true;
            }

            var variables = await statePane.ProgramStateVariablesAsync(forceReload: true);
            foreach (var variable in variables)
            {
                var name = await variable.NameAsync();
                if (string.Equals(name, variableName, StringComparison.OrdinalIgnoreCase))
                {
                    return true;
                }
            }

            // Step over once to advance past variable initialization, then re-check
            // on the next retry. Limit the number of steps to avoid running past the
            // function body.
            if (stepsPerformed < maxSteps)
            {
                var stepOverBtn = page.Locator("#next-debug");
                await stepOverBtn.ClickAsync();
                stepsPerformed++;

                // Wait for the backend to finish processing the step.
                await RetryHelpers.RetryAsync(async () =>
                {
                    var status = page.Locator("#stable-status");
                    var className = await status.GetAttributeAsync("class") ?? "";
                    return className.Contains("ready-status");
                }, maxAttempts: 30, delayMs: 1000);
            }

            return false;
        }, maxAttempts: 60, delayMs: 1000);
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
        await layout.WaitForBaseComponentsLoadedAsync();

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
        }, maxAttempts: 60, delayMs: 1000);
    }

    /// <summary>
    /// Verify the event log contains at least one row whose text cell includes
    /// <paramref name="expectedText"/>.
    ///
    /// This is useful for RR-based traces where the terminal pane does not show
    /// output (the <c>ct/load-terminal</c> handler reads from the DB event store
    /// which is empty for RR traces).  The event log, however, records stdout/stderr
    /// events during the RR recording and can be used to verify that the program
    /// produced the expected output.
    /// </summary>
    public static async Task AssertEventLogContainsTextAsync(IPage page, string expectedText)
    {
        var layout = new LayoutPage(page);
        await layout.WaitForBaseComponentsLoadedAsync();

        var eventLog = (await layout.EventLogTabsAsync()).First();
        await eventLog.TabButton().ClickAsync();

        await RetryHelpers.RetryAsync(async () =>
        {
            var events = await eventLog.EventElementsAsync(forceReload: true);
            foreach (var ev in events)
            {
                var text = await ev.ConsoleOutputAsync();
                if (text.Contains(expectedText, StringComparison.OrdinalIgnoreCase))
                {
                    return true;
                }
            }

            return false;
        }, maxAttempts: 60, delayMs: 1000);
    }

    /// <summary>
    /// Navigate the execution forward by clicking "continue", then verify
    /// the terminal output pane contains the expected text.
    ///
    /// This is needed for RR-based traces where the initial position is the
    /// program entry point and no terminal output has been produced yet.
    /// Clicking "continue" advances the debugger to the next breakpoint or
    /// end of program, populating the terminal with accumulated output.
    /// </summary>
    public static async Task AssertTerminalOutputAfterContinueAsync(IPage page, string expectedText)
    {
        var layout = new LayoutPage(page);
        await layout.WaitForBaseComponentsLoadedAsync();

        // Click the "continue" debug button to advance execution.
        var continueBtn = page.Locator("#continue-debug");
        await continueBtn.ClickAsync();

        // Wait for the backend to finish processing (status returns to "ready").
        await RetryHelpers.RetryAsync(async () =>
        {
            var status = page.Locator("#stable-status");
            var className = await status.GetAttributeAsync("class") ?? "";
            return className.Contains("ready-status");
        }, maxAttempts: 120, delayMs: 1000);

        // Now check the terminal output.
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
        }, maxAttempts: 60, delayMs: 1000);
    }
}
