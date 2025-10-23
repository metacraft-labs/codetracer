using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.Playwright;
using UiTests.PageObjects;
using UiTests.PageObjects.Panes.CallTrace;
using UiTests.PageObjects.Panes.Editor;
using UiTests.PageObjects.Panes.EventLog;
using UiTests.PageObjects.Panes.Scratchpad;
using UiTests.PageObjects.Panes.VariableState;
using UiTests.Utils;
using UiTests.Tests;

public static class NoirSpaceShipTests
{
    /// <summary>
    /// Ensure the Noir Space Ship example opens an editor tab titled "src/main.nr".
    /// </summary>
    public static async Task EditorLoadedMainNrFile(IPage page)
    {    
        var layout = new LayoutPage(page);

        await layout.WaitForAllComponentsLoadedAsync();
        
        var editors = await layout.EditorTabsAsync();
        
        if (!editors.Any(e => e.TabButtonText == "src/main.nr"))
        {
            throw new Exception("Expected editor tab 'src/main.nr' not found.");
        }
    }

    public static async Task CalculateDamageCalltraceNavigation(IPage page)
    {
        var layout = new LayoutPage(page);
        await layout.WaitForAllComponentsLoadedAsync();

        var callTrace = (await layout.CallTraceTabsAsync()).First();
        await callTrace.TabButton().ClickAsync();
        callTrace.InvalidateEntries();

        var statusReportEntry = await callTrace.FindEntryAsync("status_report", forceReload: true)
            ?? throw new Exception("Unable to locate status_report entry in call trace.");
        await statusReportEntry.ActivateAsync();

        var calculateDamageEntry = await callTrace.FindEntryAsync("calculate_damage", forceReload: true)
            ?? throw new Exception("Unable to locate calculate_damage entry in call trace.");
        await calculateDamageEntry.ActivateAsync();

        var shieldEditor = (await layout.EditorTabsAsync(true))
            .FirstOrDefault(e => e.TabButtonText.Contains("shield.nr", StringComparison.OrdinalIgnoreCase))
            ?? throw new Exception("shield.nr editor tab was not available.");
        await shieldEditor.TabButton().ClickAsync();

        await RetryHelpers.RetryAsync(async () =>
        {
            var lineNumber = await shieldEditor.ActiveLineNumberAsync();
            return lineNumber == 22;
        }, maxAttempts: 30, delayMs: 200);

        var statePane = (await layout.ProgramStateTabsAsync()).First();
        await statePane.TabButton().ClickAsync();

        await RetryHelpers.RetryAsync(async () =>
        {
            var variables = await statePane.ProgramStateVariablesAsync(true);
            var snapshot = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (var variable in variables)
            {
                var name = await variable.NameAsync();
                if (string.IsNullOrWhiteSpace(name))
                {
                    continue;
                }

                var value = await variable.ValueAsync() ?? string.Empty;
                snapshot[name] = value.Trim();
            }

            return snapshot.TryGetValue("mass", out var massValue) && massValue.Contains("100", StringComparison.Ordinal)
                && snapshot.TryGetValue("damage", out var damageValue) && damageValue.Contains("100", StringComparison.Ordinal)
                && snapshot.TryGetValue("remaining_shield", out var remainingValue) && remainingValue.Contains("10000", StringComparison.Ordinal);
        }, maxAttempts: 30, delayMs: 200);

        await layout.NextButton().ClickAsync();
        await layout.ReverseNextButton().ClickAsync();
    }

    public static async Task LoopIterationSliderTracksRemainingShield(IPage page)
    {
        var layout = new LayoutPage(page);
        await layout.WaitForAllComponentsLoadedAsync();

        var editor = (await layout.EditorTabsAsync()).First(e => e.TabButtonText.Contains("shield.nr", StringComparison.OrdinalIgnoreCase));
        await editor.TabButton().ClickAsync();

        var sliderLocator = editor.Root.Locator(".flow-loop-slider").First;
        await sliderLocator.WaitForAsync(new() { State = WaitForSelectorState.Visible });

        var sliderId = await sliderLocator.GetAttributeAsync("id")
            ?? throw new Exception("Flow slider element is missing an id attribute.");

        var statePane = (await layout.ProgramStateTabsAsync()).First();
        await statePane.TabButton().ClickAsync();

        async Task SetSliderAsync(int iteration)
        {
            await page.EvaluateAsync(
                @"({ id, value }) => {
                    const slider = document.getElementById(id);
                    if (!slider || !slider.noUiSlider) {
                        throw new Error('Flow slider is not available.');
                    }
                    slider.noUiSlider.set(value);
                }",
                new { id = sliderId, value = iteration });
            await Task.Delay(150);
        }

        async Task<int> ReadIntVariableAsync(string name)
        {
            var variables = await statePane.ProgramStateVariablesAsync(forceReload: true);
            foreach (var variable in variables)
            {
                var variableName = await variable.NameAsync();
                if (!string.Equals(variableName, name, StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }

                var rawValue = await variable.ValueAsync() ?? string.Empty;
                var cleaned = rawValue.Split(' ', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault()?.TrimEnd('%') ?? rawValue;
                if (int.TryParse(cleaned, NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsed))
                {
                    return parsed;
                }
                throw new Exception($"Unable to parse integer value from '{rawValue}' for variable '{name}'.");
            }

            throw new Exception($"Variable '{name}' was not found in the state pane.");
        }

        var expectations = new[]
        {
            (Iteration: 0, Remaining: 10000, Damage: 100),
            (Iteration: 1, Remaining: 9000, Damage: 2000),
            (Iteration: 2, Remaining: 8000, Damage: 2000),
            (Iteration: 3, Remaining: 7000, Damage: 2000)
        };

        foreach (var step in expectations)
        {
            await SetSliderAsync(step.Iteration);
            await RetryHelpers.RetryAsync(async () =>
            {
                var remaining = await ReadIntVariableAsync("remaining_shield");
                var damage = await ReadIntVariableAsync("damage");
                return remaining == step.Remaining && damage == step.Damage;
            }, maxAttempts: 30, delayMs: 200);
        }
    }

    public static async Task EventLogJumpHighlightsActiveRow(IPage page)
    {
        var layout = new LayoutPage(page);
        await layout.WaitForAllComponentsLoadedAsync();

        var eventLog = (await layout.EventLogTabsAsync()).First();
        await eventLog.TabButton().ClickAsync();

        var rows = (await eventLog.EventElementsAsync(true)).ToList();
        if (rows.Count < 2)
        {
            throw new Exception("Event log did not render enough rows for the navigation test.");
        }

        var firstRow = rows[0];
        var firstIndex = await firstRow.IndexAsync();

        await firstRow._root.ClickAsync();
        await RetryHelpers.RetryAsync(firstRow.IsHighlightedAsync);

        await layout.NextButton().ClickAsync();
        await RetryHelpers.RetryAsync(async () =>
        {
            var refreshed = (await eventLog.EventElementsAsync(true)).ToList();
            foreach (var row in refreshed)
            {
                if (!await row.IsHighlightedAsync())
                {
                    continue;
                }

                var activeIndex = await row.IndexAsync();
                return activeIndex != firstIndex;
            }
            return false;
        });
    }

    public static async Task TraceLogRecordsDamageRegeneration(IPage page)
    {
        var layout = new LayoutPage(page);
        await layout.WaitForAllComponentsLoadedAsync();

        var shieldEditor = (await layout.EditorTabsAsync()).First(e => e.TabButtonText.Contains("shield.nr", StringComparison.OrdinalIgnoreCase));
        await shieldEditor.TabButton().ClickAsync();

        const int traceLine = 14;
        await shieldEditor.OpenTrace(traceLine);
        var tracePanel = new TraceLogPanel(shieldEditor, traceLine);
        await tracePanel.Root.WaitForAsync(new() { State = WaitForSelectorState.Visible });

        var expression = "log(damage, remaining_shield, regeneration)";
        await tracePanel.EditTextBox().FillAsync(expression);

        var eventLog = (await layout.EventLogTabsAsync()).First();
        await eventLog.TabButton().ClickAsync();

        var baselineEventCount = (await eventLog.EventElementsAsync(true)).Count;

        await shieldEditor.RunTracepointsJsAsync();

        await RetryHelpers.RetryAsync(async () =>
        {
            var rows = await tracePanel.TraceRowsAsync();
            return rows.Count > 0;
        });

        var traceRows = await tracePanel.TraceRowsAsync();
        var iterationCount = traceRows.Count;

        await RetryHelpers.RetryAsync(async () =>
        {
            var currentCount = (await eventLog.EventElementsAsync(true)).Count;
            return currentCount >= baselineEventCount + iterationCount;
        });

        await shieldEditor.RunTracepointsJsAsync();

        await RetryHelpers.RetryAsync(async () =>
        {
            var currentRows = await tracePanel.TraceRowsAsync();
            return currentRows.Count == iterationCount;
        });

        await RetryHelpers.RetryAsync(async () =>
        {
            var currentCount = (await eventLog.EventElementsAsync(true)).Count;
            return currentCount == baselineEventCount + iterationCount;
        });
    }

    public static async Task RemainingShieldHistoryChronology(IPage page)
    {
        var layout = new LayoutPage(page);
        await layout.WaitForAllComponentsLoadedAsync();

        var statePane = (await layout.ProgramStateTabsAsync()).First();
        await statePane.TabButton().ClickAsync();

        var variables = await statePane.ProgramStateVariablesAsync(true);
        VariableStateRecord? remainingShieldVariable = null;
        foreach (var variable in variables)
        {
            var name = await variable.NameAsync();
            if (string.Equals(name, "remaining_shield", StringComparison.OrdinalIgnoreCase))
            {
                remainingShieldVariable = variable;
                break;
            }
        }

        if (remainingShieldVariable is null)
        {
            throw new Exception("remaining_shield variable was not found in the state pane.");
        }

        var historyEntries = await remainingShieldVariable.HistoryEntriesAsync();
        if (historyEntries.Count == 0)
        {
            throw new Exception("History entries for remaining_shield were not rendered.");
        }

        var values = new List<int>();
        foreach (var entry in historyEntries)
        {
            var valueText = await entry.ValueTextAsync();
            if (int.TryParse(valueText, NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsed))
            {
                values.Add(parsed);
            }
        }

        if (!values.SequenceEqual(values.OrderBy(v => v).Reverse()))
        {
            throw new Exception("remaining_shield history is not strictly decreasing as expected.");
        }

        await layout.NextButton().ClickAsync();
        await layout.NextButton().ClickAsync();
        await layout.NextButton().ClickAsync();

        var scratchpad = (await layout.ScratchpadTabsAsync()).First();
        await scratchpad.TabButton().ClickAsync();

        var initialCount = await scratchpad.EntryCountAsync();
        await historyEntries[0].AddToScratchpadAsync();
        await scratchpad.WaitForEntryCountAsync(initialCount + 1);

        var entries = await scratchpad.EntryMapAsync(forceReload: true);
        if (!entries.ContainsKey("remaining_shield"))
        {
            throw new Exception("Missing remaining_shield entry in scratchpad after adding from history.");
        }

        var nextRemainingShield = await remainingShieldVariable.ValueAsync();
        var scratchpadValue = await entries["remaining_shield"].ValueTextAsync();

        if (string.Equals(nextRemainingShield?.Trim(), scratchpadValue.Trim(), StringComparison.OrdinalIgnoreCase))
        {
            throw new Exception("History snapshot matches current state; expected historical value to differ.");
        }
    }

    public static async Task ScratchpadCompareIterations(IPage page)
    {
        var layout = new LayoutPage(page);
        await layout.WaitForAllComponentsLoadedAsync();

        var editor = (await layout.EditorTabsAsync()).First(e => e.TabButtonText.Contains("shield.nr", StringComparison.OrdinalIgnoreCase));
        await editor.TabButton().ClickAsync();

        const int traceLine = 14;
        await editor.OpenTrace(traceLine);
        var tracePanel = new TraceLogPanel(editor, traceLine);
        await tracePanel.Root.WaitForAsync(new() { State = WaitForSelectorState.Visible });

        var expression = "log(damage, remaining_shield)";
        await tracePanel.EditTextBox().FillAsync(expression);
        await editor.RunTracepointsJsAsync();

        var scratchpad = (await layout.ScratchpadTabsAsync()).First();
        await scratchpad.TabButton().ClickAsync();

        var entries = await scratchpad.EntryMapAsync(forceReload: true);
        if (!entries.TryGetValue("damage", out var damageEntry) || !entries.TryGetValue("remaining_shield", out var remainingEntry))
        {
            throw new Exception("Damage and remaining_shield entries were not found in the scratchpad after running tracepoints.");
        }

        var damageValue = await damageEntry.ValueTextAsync();
        var remainingValue = await remainingEntry.ValueTextAsync();

        if (!damageValue.Contains(","))
        {
            throw new Exception("Expected multiple iterations captured for damage but found a single value.");
        }

        if (!remainingValue.Contains(","))
        {
            throw new Exception("Expected multiple iterations captured for remaining_shield but found a single value.");
        }
    }

    public static async Task StepControlsRecoverFromReverse(IPage page)
    {
        var layout = new LayoutPage(page);
        await layout.WaitForAllComponentsLoadedAsync();

        var editor = (await layout.EditorTabsAsync()).First(e => e.TabButtonText.Contains("shield.nr", StringComparison.OrdinalIgnoreCase));
        await editor.TabButton().ClickAsync();

        // Collect baseline operation status
        var operationStatus = page.Locator("#operation-status");
        var initialStatus = await operationStatus.InnerTextAsync() ?? string.Empty;

        await layout.ReverseContinueButton().ClickAsync();

        await RetryHelpers.RetryAsync(async () =>
        {
            var text = await operationStatus.InnerTextAsync();
            return text != null && text.Contains("busy", StringComparison.OrdinalIgnoreCase);
        });

        await layout.ContinueButton().ClickAsync();

        await RetryHelpers.RetryAsync(async () =>
        {
            var text = await operationStatus.InnerTextAsync();
            return text != null && text.Contains("ready", StringComparison.OrdinalIgnoreCase);
        });
    }

    public static async Task TraceLogDisableButtonShouldFlipState(IPage page)
    {
        var layout = new LayoutPage(page);
        await layout.WaitForAllComponentsLoadedAsync();

        var editor = (await layout.EditorTabsAsync()).First(e => e.TabButtonText.Contains("shield.nr", StringComparison.OrdinalIgnoreCase));
        await editor.TabButton().ClickAsync();

        const int traceLine = 14;
        await editor.OpenTrace(traceLine);
        var tracePanel = new TraceLogPanel(editor, traceLine);
        await tracePanel.Root.WaitForAsync(new() { State = WaitForSelectorState.Visible });

        var toggleButton = tracePanel.ToggleButton();
        var disabledOverlay = tracePanel.DisabledOverlay();

        await toggleButton.ClickAsync();
        await disabledOverlay.WaitForAsync(new() { State = WaitForSelectorState.Visible });
        var buttonText = await toggleButton.InnerTextAsync() ?? string.Empty;
        if (!buttonText.Contains("Enable", StringComparison.OrdinalIgnoreCase))
        {
            throw new Exception("Trace disable button did not switch to 'Enable' after disabling.");
        }

        await toggleButton.ClickAsync();
        await disabledOverlay.WaitForAsync(new() { State = WaitForSelectorState.Hidden });
        buttonText = await toggleButton.InnerTextAsync() ?? string.Empty;
        if (!buttonText.Contains("Disable", StringComparison.OrdinalIgnoreCase))
        {
            throw new Exception("Trace disable button did not switch back to 'Disable' after re-enabling.");
        }

        await editor.RunTracepointsJsAsync();
        await RetryHelpers.RetryAsync(async () =>
        {
            var rows = await tracePanel.TraceRowsAsync();
            return rows.Count > 0;
        });
    }

    public static async Task ExhaustiveScratchpadAdditions(IPage page)
    {
        var layout = new LayoutPage(page);
        await layout.WaitForAllComponentsLoadedAsync();

        var scratchpad = (await layout.ScratchpadTabsAsync()).First();
        await scratchpad.TabButton().ClickAsync();
        var expectedCount = await scratchpad.EntryCountAsync();

        // Call trace argument addition
        var callTrace = (await layout.CallTraceTabsAsync()).First();
        await callTrace.WaitForReadyAsync();
        callTrace.InvalidateEntries();

        CallTraceArgument? targetArgument = null;
        var entries = await callTrace.EntriesAsync(true);
        foreach (var entry in entries)
        {
            var arguments = await entry.ArgumentsAsync();
            if (arguments.Count > 0)
            {
                targetArgument = arguments.First();
                break;
            }
        }
        if (targetArgument is null)
        {
            throw new Exception("Unable to locate a call trace argument for scratchpad test.");
        }

        await targetArgument.AddToScratchpadAsync();
        expectedCount += 1;
        await scratchpad.WaitForEntryCountAsync(expectedCount);
        scratchpad.InvalidateCache();

        // Flow value addition
        var editor = (await layout.EditorTabsAsync()).First();
        FlowValue? flowValue = null;
        await RetryHelpers.RetryAsync(async () =>
        {
            var values = await editor.FlowValuesAsync();
            if (values.Count == 0)
            {
                return false;
            }
            flowValue = values.First();
            return true;
        }, maxAttempts: 20, delayMs: 200);

        if (flowValue is null)
        {
            throw new Exception("No flow value was found for scratchpad test.");
        }

        await flowValue.SelectContextMenuOptionAsync("Add value to scratchpad");
        expectedCount += 1;
        await scratchpad.WaitForEntryCountAsync(expectedCount);
        scratchpad.InvalidateCache();

        // Prepare trace log data by running tracepoints
        await CreateSimpleTracePoint(page);

        layout = new LayoutPage(page);
        await layout.WaitForAllComponentsLoadedAsync();
        scratchpad = (await layout.ScratchpadTabsAsync(true)).First();
        await scratchpad.TabButton().ClickAsync();
        expectedCount = await scratchpad.EntryCountAsync();

        editor = (await layout.EditorTabsAsync(true)).First(e => e.TabButtonText.Contains("src/main.nr", StringComparison.Ordinal));
        const int firstTraceLine = 13;
        await editor.OpenTrace(firstTraceLine);
        var tracePanel = new TraceLogPanel(editor, firstTraceLine);
        await tracePanel.Root.WaitForAsync(new() { State = WaitForSelectorState.Visible });
        var traceRows = await tracePanel.TraceRowsAsync();
        if (traceRows.Count == 0)
        {
            throw new Exception("Trace log did not produce any rows for scratchpad test.");
        }

        var traceMenuOptions = await traceRows[0].ContextMenuEntriesAsync();
        var addTraceOption = traceMenuOptions.FirstOrDefault(opt => opt.Contains("Add", StringComparison.OrdinalIgnoreCase));
        if (string.IsNullOrEmpty(addTraceOption))
        {
            throw new Exception("Trace log context menu does not expose an Add to scratchpad option.");
        }
        await traceRows[0].SelectMenuOptionAsync(addTraceOption);
        expectedCount += 1;
        await scratchpad.WaitForEntryCountAsync(expectedCount);
        scratchpad.InvalidateCache();

        // Value history addition
        var statePane = (await layout.ProgramStateTabsAsync(true)).First();
        await statePane.TabButton().ClickAsync();
        var variables = await statePane.ProgramStateVariablesAsync(true);
        var variableWithHistory = variables.FirstOrDefault();
        if (variableWithHistory is null)
        {
            throw new Exception("Program state pane did not expose any variables.");
        }

        var historyEntries = await variableWithHistory.HistoryEntriesAsync();
        if (historyEntries.Count == 0)
        {
            throw new Exception("No value history entries were available for scratchpad test.");
        }

        await historyEntries[0].AddToScratchpadAsync();
        expectedCount += 1;
        await scratchpad.WaitForEntryCountAsync(expectedCount);

        var finalCount = await scratchpad.EntryCountAsync();
        if (finalCount < expectedCount)
        {
            throw new Exception("Scratchpad did not register all additions as expected.");
        }
    }

    public static async Task FilesystemContextMenuOptions(IPage page)
    {
        var layout = new LayoutPage(page);
        await layout.WaitForAllComponentsLoadedAsync();

        var filesystem = (await layout.FilesystemTabsAsync()).First();
        await filesystem.TabButton().ClickAsync();

        var node = await filesystem.NodeByPathAsync(
            "source folders",
            "codetracer",
            "test-programs",
            "noir_space_ship",
            "src");

        var options = await node.ContextMenuOptionsAsync();
        var missing = filesystem.ExpectedContextMenuEntries
            .Where(expected => !options.Any(actual => actual.Equals(expected, StringComparison.OrdinalIgnoreCase)))
            .ToList();

        if (missing.Count > 0)
        {
            throw new Exception($"Filesystem context menu missing entries: {string.Join(", ", missing)}. Actual: {string.Join(", ", options)}");
        }
    }

    public static async Task CallTraceContextMenuOptions(IPage page)
    {
        var layout = new LayoutPage(page);
        await layout.WaitForAllComponentsLoadedAsync();

        var callTrace = (await layout.CallTraceTabsAsync()).First();
        await callTrace.TabButton().ClickAsync();
        callTrace.InvalidateEntries();
        var entries = await callTrace.EntriesAsync(true);

        var callEntry = entries.FirstOrDefault();
        if (callEntry is null)
        {
            throw new Exception("No call trace entries were rendered.");
        }

        var expectedCallOptions = (await callEntry.ExpectedContextMenuAsync()).OrderBy(x => x, StringComparer.OrdinalIgnoreCase).ToList();
        var actualCallOptions = (await callEntry.ContextMenuEntriesAsync()).OrderBy(x => x, StringComparer.OrdinalIgnoreCase).ToList();
        if (!expectedCallOptions.SequenceEqual(actualCallOptions, StringComparer.OrdinalIgnoreCase))
        {
            throw new Exception($"Call trace context menu mismatch. Expected: {string.Join(", ", expectedCallOptions)}; Actual: {string.Join(", ", actualCallOptions)}");
        }

        var argument = (await callEntry.ArgumentsAsync()).FirstOrDefault();
        if (argument is null)
        {
            throw new Exception("Call trace entry does not expose any arguments.");
        }

        var argumentOptions = (await argument.ContextMenuEntriesAsync()).OrderBy(x => x, StringComparer.OrdinalIgnoreCase).ToList();
        var expectedArgumentOptions = argument.ExpectedContextMenuEntries.OrderBy(x => x, StringComparer.OrdinalIgnoreCase).ToList();
        if (!expectedArgumentOptions.SequenceEqual(argumentOptions, StringComparer.OrdinalIgnoreCase))
        {
            throw new Exception($"Call trace argument context menu mismatch. Expected: {string.Join(", ", expectedArgumentOptions)}; Actual: {string.Join(", ", argumentOptions)}");
        }
    }

    public static async Task FlowContextMenuOptions(IPage page)
    {
        var layout = new LayoutPage(page);
        await layout.WaitForAllComponentsLoadedAsync();

        var editor = (await layout.EditorTabsAsync()).First();
        var flowValues = await editor.FlowValuesAsync();
        if (flowValues.Count == 0)
        {
            throw new Exception("Editor did not render any flow values to inspect.");
        }

        var flowValue = flowValues.First();
        var actual = (await flowValue.ContextMenuEntriesAsync()).OrderBy(x => x, StringComparer.OrdinalIgnoreCase).ToList();
        var expected = flowValue.ExpectedContextMenuEntries.OrderBy(x => x, StringComparer.OrdinalIgnoreCase).ToList();

        if (!expected.SequenceEqual(actual, StringComparer.OrdinalIgnoreCase))
        {
            throw new Exception($"Flow context menu mismatch. Expected: {string.Join(", ", expected)}; Actual: {string.Join(", ", actual)}");
        }
    }

    public static async Task TraceLogContextMenuOptions(IPage page)
    {
        await CreateSimpleTracePoint(page);

        var layout = new LayoutPage(page);
        await layout.WaitForAllComponentsLoadedAsync();

        var editor = (await layout.EditorTabsAsync(true)).First(e => e.TabButtonText.Contains("src/main.nr", StringComparison.Ordinal));
        const int traceLine = 13;
        await editor.OpenTrace(traceLine);
        var tracePanel = new TraceLogPanel(editor, traceLine);
        await tracePanel.Root.WaitForAsync(new() { State = WaitForSelectorState.Visible });
        var rows = await tracePanel.TraceRowsAsync();
        if (rows.Count == 0)
        {
            throw new Exception("Trace log panel did not render any rows for inspection.");
        }

        var options = await rows[0].ContextMenuEntriesAsync();
        if (!options.Any(option => option.Contains("scratchpad", StringComparison.OrdinalIgnoreCase)))
        {
            throw new Exception($"Trace log row context menu does not expose an Add to scratchpad entry. Actual entries: {string.Join(", ", options)}");
        }
    }

    public static async Task ValueHistoryContextMenuOptions(IPage page)
    {
        var layout = new LayoutPage(page);
        await layout.WaitForAllComponentsLoadedAsync();

        var statePane = (await layout.ProgramStateTabsAsync()).First();
        await statePane.TabButton().ClickAsync();

        var variables = await statePane.ProgramStateVariablesAsync(true);
        foreach (var variable in variables)
        {
            var history = await variable.HistoryEntriesAsync();
            if (history.Count == 0)
            {
                continue;
            }

            var options = await history[0].ContextMenuEntriesAsync();
            if (!options.Any(option => option.Contains("scratchpad", StringComparison.OrdinalIgnoreCase)))
            {
                throw new Exception($"Value history context menu missing Add to scratchpad. Actual entries: {string.Join(", ", options)}");
            }

            return;
        }

        throw new Exception("No variable exposed history entries to validate context menu options.");
    }
    public static async Task JumpToAllEvents(IPage page)
    {
        var layout = new LayoutPage(page);
        await layout.WaitForAllComponentsLoadedAsync();

        var eventLogs = await layout.EventLogTabsAsync();
        foreach (var tab in eventLogs)
        {
            if (!await tab.IsVisibleAsync()) { continue; }

            var events = (await tab.EventElementsAsync()).ToList();
            if (!await EventsInExpectedState(events, -1))
            {
                throw new FailedTestException("Events were expected to be greyed out initially.");
            }

            for (int i = 0; i < events.Count; i++)
            {
                await events[i]._root.ClickAsync();
                await RetryHelpers.RetryAsync(async () =>
                    (await events[i]._root.GetAttributeAsync("class"))?.Contains("active") == true);

                if (!await EventsInExpectedState(events, i))
                {
                    throw new FailedTestException($"Event state mismatch after jumping to index {i}.");
                }
            }
        }
    }

    /// <summary>
    /// Creates two tracepoints, executes them, and validates the event and trace logs.
    /// </summary>
    public static async Task CreateSimpleTracePoint(IPage page)
    {
        const int firstLine = 13;
        const int secondLine = 37;
        const string firstMessage = "This is a simple trace point";
        const string secondMessage = "This is another simple trace point";

        var layout = new LayoutPage(page);
        await layout.WaitForAllComponentsLoadedAsync();

        await Task.Delay(1000);

        var editors = await layout.EditorTabsAsync();
        EditorPane? editor = null;
        await RetryHelpers.RetryAsync(async () =>
        {
            var loadedEditors = await layout.EditorTabsAsync();
            editor = loadedEditors.FirstOrDefault(e => e.TabButtonText == "src/main.nr");
            return editor is not null;
        });

        if (editor is null)
        {
            throw new TimeoutException("Expected editor tab 'src/main.nr' not found.");
        }

        // editor is now safe to use
        await editor.TabButton().ClickAsync();

        await Task.Delay(1000);

        var eventLog = (await layout.EventLogTabsAsync()).First();
        await eventLog.TabButton().ClickAsync();

        // await editor.JumpToLineJsAsync(firstLine);
        await editor.OpenTrace(firstLine);
        await Task.Delay(1000);
        
        var firstTracePanel = new TraceLogPanel(editor, firstLine);
        await firstTracePanel.Root.WaitForAsync(new() { State = WaitForSelectorState.Visible });

        var firstExpression = $"log(\"{firstMessage}\")";
        await firstTracePanel.EditTextBox().FillAsync(firstExpression);

        await editor.RunTracepointsJsAsync();

        await RetryHelpers.RetryAsync(async () =>
        {
            var events = await eventLog.EventElementsAsync(true);
            if (events.Count == 0)
            {
                return false;
            }

            var text = await events[0].ConsoleOutputAsync();
            return text.Contains(firstMessage, StringComparison.Ordinal);
        });

        await RetryHelpers.RetryAsync(async () =>
        {
            var rows = await firstTracePanel.EventRowsAsync();
            if (rows.Count == 0)
            {
                return false;
            }

            var text = await rows[0].ConsoleOutputAsync();
            return text.Contains(firstMessage, StringComparison.Ordinal);
        });

        await editor.JumpToLineJsAsync(secondLine);
        await editor.OpenTrace(secondLine);
        var secondTracePanel = new TraceLogPanel(editor, secondLine);
        await secondTracePanel.Root.WaitForAsync(new() { State = WaitForSelectorState.Visible });

        var secondExpression = $"log(\"{secondMessage}\")";
        await secondTracePanel.EditTextBox().FillAsync(secondExpression);

        await editor.RunTracepointsJsAsync();

        await RetryHelpers.RetryAsync(async () =>
        {
            var events = await eventLog.EventElementsAsync(true);
            if (events.Count == 0)
            {
                return false;
            }

            var firstText = await events[0].ConsoleOutputAsync();
            if (!firstText.Contains(firstMessage, StringComparison.Ordinal))
            {
                return false;
            }

            var lastText = await events[^1].ConsoleOutputAsync();
            return lastText.Contains(secondMessage, StringComparison.Ordinal);
        });

        await RetryHelpers.RetryAsync(async () =>
        {
            var firstRows = await firstTracePanel.EventRowsAsync();
            if (firstRows.Count == 0)
            {
                return false;
            }

            var firstTraceText = await firstRows[0].ConsoleOutputAsync();
            if (!firstTraceText.Contains(firstMessage, StringComparison.Ordinal))
            {
                return false;
            }

            var secondRows = await secondTracePanel.EventRowsAsync();
            if (secondRows.Count == 0)
            {
                return false;
            }

            foreach (var row in secondRows)
            {
                var text = await row.ConsoleOutputAsync();
                if (text.Contains(secondMessage, StringComparison.Ordinal))
                {
                    return true;
                }
            }

            return false;
        });
    }

    private static async Task<bool> EventsInExpectedState(IReadOnlyList<EventRow> events, int currentIndex)
    {
        for (int i = 0; i < events.Count; i++)
        {
            var classes = await events[i]._root.GetAttributeAsync("class") ?? string.Empty;
            var opacityStr = await events[i]._root.EvaluateAsync<string>("el => window.getComputedStyle(el).opacity");
            var opacity = double.Parse(opacityStr, CultureInfo.InvariantCulture);

            if (currentIndex < 0)
            {
                if (!classes.Contains("future") || opacity >= 1) return false;
            }
            else if (i < currentIndex)
            {
                if (!classes.Contains("past") || opacity < 1) return false;
            }
            else if (i == currentIndex)
            {
                if (!classes.Contains("active") || opacity < 1) return false;
            }
            else
            {
                if (!classes.Contains("future") || opacity >= 1) return false;
            }
        }

        return true;
    }
}
