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
        DebugLogger.Reset();
        DebugLogger.Log("Starting CalculateDamageCalltraceNavigation");

        var layout = new LayoutPage(page);
        DebugLogger.Log("Waiting for all components to load");
        await layout.WaitForAllComponentsLoadedAsync();
        DebugLogger.Log("All components loaded");

        var callTrace = (await layout.CallTraceTabsAsync()).First();
        DebugLogger.Log("Call trace tab acquired; focusing call trace");
        await callTrace.TabButton().ClickAsync();
        callTrace.InvalidateEntries();

        var eventLog = (await layout.EventLogTabsAsync()).First();
        DebugLogger.Log("Opening event log tab");
        await eventLog.TabButton().ClickAsync();
        var firstRow = await eventLog.RowByIndexAsync(1, forceReload: true);
        DebugLogger.Log("Clicking first event log row");
        await firstRow.ClickAsync();

        var statusReportEntry = await callTrace.FindEntryAsync("status_report", forceReload: true)
            ?? throw new Exception("Unable to locate status_report entry in call trace.");
        DebugLogger.Log("Activating status_report entry");
        await statusReportEntry.ActivateAsync();
        DebugLogger.Log("Expanding status_report children");
        await statusReportEntry.ExpandChildrenAsync();
        callTrace.InvalidateEntries();

        var calculateDamageEntry = await callTrace.FindEntryAsync("calculate_damage", forceReload: true)
            ?? throw new Exception("Unable to locate calculate_damage entry in call trace.");
        DebugLogger.Log("Activating calculate_damage entry");
        await calculateDamageEntry.ActivateAsync();

        var shieldEditor = (await layout.EditorTabsAsync(true))
            .FirstOrDefault(e => e.TabButtonText.Contains("shield.nr", StringComparison.OrdinalIgnoreCase))
            ?? throw new Exception("shield.nr editor tab was not available.");
        DebugLogger.Log("Focusing shield.nr editor tab");
        await shieldEditor.TabButton().ClickAsync();

        await RetryHelpers.RetryAsync(async () =>
        {
            var activeLine = await shieldEditor.ActiveLineNumberAsync();
            return activeLine == 22;
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

            return snapshot.TryGetValue("initial_shield", out var initialValue) && initialValue.Contains("10000", StringComparison.Ordinal)
                && snapshot.TryGetValue("mass", out var massValue) && massValue.Contains("100", StringComparison.Ordinal)
                && snapshot.TryGetValue("remaining_shield", out var remainingValue) && remainingValue.Contains("10000", StringComparison.Ordinal);
        }, maxAttempts: 30, delayMs: 200);

        await layout.NextButton().ClickAsync();
        await layout.ReverseNextButton().ClickAsync();
    }

    public static async Task LoopIterationSliderTracksRemainingShield(IPage page)
    {
        var traceStep = 0;
        void Trace(string message)
        {
            traceStep++;
            DebugLogger.Log($"LoopIterationTrace[{traceStep}]: {message}");
        }

        var layout = new LayoutPage(page);
        Trace("Created LayoutPage");
        await layout.WaitForAllComponentsLoadedAsync();
        Trace("Waited for all components");

        var callTrace = (await layout.CallTraceTabsAsync()).First();
        await callTrace.TabButton().ClickAsync();
        Trace("Focused call trace tab");
        callTrace.InvalidateEntries();
        Trace("Invalidated call trace entries");

        Trace("RequireCallTraceEntryAsync configured");
        var iterateEntry = await RequireCallTraceEntryAsync(callTrace, "iterate_asteroids", Trace);
        Trace("Acquire iterate_asteroids entry");
        await iterateEntry.ActivateAsync();
        Trace("Activated iterate_asteroids");

        var editor = await RequireShieldEditorAsync(layout, Trace);
        Trace("Editor tab confirmed");

        var sliderContainer = editor.Root.Locator(".flow-loop-slider").First;
        Trace("Acquired slider container locator");
        await sliderContainer.WaitForAsync(new() { State = WaitForSelectorState.Visible });
        Trace("Slider container visible");

        var statePane = (await layout.ProgramStateTabsAsync()).First();
        Trace("Retrieved state pane");
        await statePane.TabButton().ClickAsync();
        Trace("Focused state pane");

        var iterationValueBoxLocator = editor.FlowValueElementById("flow-parallel-value-box-0-6-regeneration");
        if (await iterationValueBoxLocator.CountAsync() == 0)
        {
            Trace("Loop iteration value box id not found; falling back to name lookup");
            iterationValueBoxLocator = editor.FlowValueElementByName("regeneration");
        }

        var iterationValueBox = iterationValueBoxLocator.First;
        await iterationValueBox.WaitForAsync(new() { State = WaitForSelectorState.Visible, Timeout = 5000 });
        Trace("Loop iteration value box located");

        var iterationTextarea = editor.Root.Locator(".flow-loop-textarea").First;
        await iterationTextarea.WaitForAsync(new() { State = WaitForSelectorState.Visible, Timeout = 5000 });
        Trace("Loop textarea located");
        const int loopLineNumber = 5;

        async Task SetLoopIterationAsync(int iteration)
        {
            Trace($"SetLoopIterationAsync invoked for iteration {iteration}");
            await iterationValueBox.ClickAsync();
            await iterationValueBox.DblClickAsync();
            Trace("Loop iteration value box focused");

            await iterationTextarea.FillAsync(string.Empty);
            Trace("Cleared textarea");
            await iterationTextarea.TypeAsync(iteration.ToString(CultureInfo.InvariantCulture), new() { Delay = 20 });
            Trace("Typed iteration value");
            await iterationTextarea.PressAsync("Enter");
            Trace("Pressed Enter on textarea");

            await RetryHelpers.RetryAsync(async () =>
            {
                var currentIteration = await iterationValueBox.GetAttributeAsync("iteration");
                Trace($"Current iteration attribute value: '{currentIteration}'");
                return string.Equals(currentIteration, iteration.ToString(CultureInfo.InvariantCulture), StringComparison.Ordinal);
            }, maxAttempts: 15, delayMs: 200);

            try
            {
                await RetryHelpers.RetryAsync(async () =>
                {
                    var activeLine = await editor.ActiveLineNumberAsync();
                    Trace($"Active line after dragging loop slider: {activeLine}");
                    return activeLine == 5;
                }, maxAttempts: 30, delayMs: 200);
            }
            catch (TimeoutException ex)
            {
                throw new TimeoutException("CodeTracer was expected to highlight line 5 after jumping to the requested iteration.", ex);
            }
        }
        Trace("SetLoopIterationAsync configured");

        async Task<int?> TryReadStateVariableAsync(string name)
        {
            Trace($"TryReadStateVariableAsync invoked for {name}");
            var variables = await statePane.ProgramStateVariablesAsync(forceReload: true);
            Trace($"Retrieved {variables.Count} state variables");
            foreach (var variable in variables)
            {
                var variableName = await variable.NameAsync();
                Trace($"Inspecting variable '{variableName}'");
                if (!string.Equals(variableName, name, StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }

                var rawValue = await variable.ValueAsync() ?? string.Empty;
                Trace($"Raw value for '{name}' is '{rawValue}'");
                var cleaned = rawValue.Split(' ', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault()?.TrimEnd('%') ?? rawValue;
                if (int.TryParse(cleaned, NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsed))
                {
                    Trace($"Parsed '{name}' as {parsed}");
                    return parsed;
                }
                Trace($"Failed to parse '{name}' from '{rawValue}'");
                throw new Exception($"Unable to parse integer value from '{rawValue}' for variable '{name}'.");
            }

            return null;
        }

        async Task<int> ReadIntVariableAsync(string name)
        {
            var value = await TryReadStateVariableAsync(name);
            if (value.HasValue)
            {
                return value.Value;
            }

            Trace($"Variable '{name}' not found");
            throw new Exception($"Variable '{name}' was not found in the state pane.");
        }
        Trace("ReadIntVariableAsync configured");

        async Task<int> ReadLoopFlowValueAsync(string name)
        {
            Trace($"ReadLoopFlowValueAsync invoked for {name}");
            var line = editor.LineByNumber(loopLineNumber);
            var flowValues = await line.FlowValuesAsync();
            foreach (var flowValue in flowValues)
            {
                var valueName = await flowValue.NameAsync();
                Trace($"Inspecting flow value '{valueName}'");
                if (!string.Equals(valueName, name, StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }

                var text = await flowValue.ValueTextAsync();
                Trace($"Flow value '{name}' raw text '{text}'");
                var cleaned = text.Split(' ', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault()?.TrimEnd('%') ?? text;
                if (int.TryParse(cleaned, NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsed))
                {
                    Trace($"Parsed flow value '{name}' as {parsed}");
                    return parsed;
                }

                throw new Exception($"Unable to parse integer value from flow loop expression '{text}' for '{name}'.");
            }

            throw new Exception($"Flow loop value '{name}' was not found.");
        }

        async Task<int> ReadDamageValueAsync()
        {
            var fromState = await TryReadStateVariableAsync("damage");
            if (fromState.HasValue)
            {
                Trace("Read 'damage' from state pane");
                return fromState.Value;
            }

            Trace("'damage' not available in state pane; reading from flow loop value");
            return await ReadLoopFlowValueAsync("damage");
        }

        var expectations = new List<(int Iteration, int Remaining, int Damage)>
        {
            (Iteration: 0, Remaining: 10000, Damage: 100),
            (Iteration: 1, Remaining: 9000, Damage: 2000),
            (Iteration: 2, Remaining: 8000, Damage: 2000),
            (Iteration: 3, Remaining: 7000, Damage: 2000),
            (Iteration: 4, Remaining: 5000, Damage: 3000),
            (Iteration: 5, Remaining: 3500, Damage: 2500),
            (Iteration: 6, Remaining: 1250, Damage: 3250),
            (Iteration: 7, Remaining: 1018, Damage: 1232)
        };
        Trace("Expectations prepared");

        foreach (var step in expectations)
        {
            Trace($"Beginning iteration {step.Iteration}");
            await SetLoopIterationAsync(step.Iteration);
            Trace($"Iteration {step.Iteration} applied");
            await RetryHelpers.RetryAsync(async () =>
            {
                var remaining = await ReadIntVariableAsync("remaining_shield");
                var damage = await ReadDamageValueAsync();
                Trace($"Iteration {step.Iteration} observed remaining={remaining}, damage={damage}");
                return remaining == step.Remaining && damage == step.Damage;
            }, maxAttempts: 30, delayMs: 200);
            Trace($"Iteration {step.Iteration} expectations met");
            await page.WaitForTimeoutAsync(1000);
            Trace($"Iteration {step.Iteration} post-delay complete");
        }
        Trace("LoopIterationSliderTracksRemainingShield completed");
    }

    public static async Task SimpleLoopIterationJump(IPage page)
    {
        var layout = new LayoutPage(page);
        await layout.WaitForAllComponentsLoadedAsync();

        var callTrace = (await layout.CallTraceTabsAsync()).First();
        await callTrace.TabButton().ClickAsync();
        callTrace.InvalidateEntries();

        var iterateEntry = await RequireCallTraceEntryAsync(callTrace, "iterate_asteroids");
        await iterateEntry.ActivateAsync();

        var shieldEditor = await RequireShieldEditorAsync(layout);

        var iterationValueBoxLocator = shieldEditor.FlowValueElementById("flow-parallel-value-box-0-6-regeneration");
        if (await iterationValueBoxLocator.CountAsync() == 0)
        {
            DebugLogger.Log("SimpleLoopIterationJump: primary regeneration value box id not found; falling back to name lookup.");
            iterationValueBoxLocator = shieldEditor.FlowValueElementByName("regeneration");
        }

        var iterationValueBox = iterationValueBoxLocator.First;
        await iterationValueBox.WaitForAsync(new() { State = WaitForSelectorState.Visible, Timeout = 5000 });
        // await iterationValueBox.ClickAsync();
        // await iterationValueBox.DblClickAsync();
        var iterationEditor = shieldEditor.Root.Locator(".flow-loop-textarea").First;
        await iterationEditor.WaitForAsync(new() { State = WaitForSelectorState.Visible, Timeout = 5000 });

        const string iterationTarget = "4";
        await iterationEditor.PressAsync("Backspace");
        await iterationEditor.TypeAsync(iterationTarget, new() { Delay = 20 });
        await iterationEditor.PressAsync("Enter");

        try
        {
            await RetryHelpers.RetryAsync(async () =>
            {
                var activeLine = await shieldEditor.ActiveLineNumberAsync();
                return activeLine == 5;
            }, maxAttempts: 30, delayMs: 200);
        }
        catch (TimeoutException ex)
        {
            throw new TimeoutException("CodeTracer was expected to jump to line 5 after jimping to a new loop iterration.", ex);
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

        await Task.Delay(1000);
        await RetryHelpers.RetryAsync(firstRow.IsHighlightedAsync);
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
            if (!await tab.IsVisibleAsync())
            {
                continue;
            }

            await tab.TabButton().ClickAsync();

            var events = (await tab.EventElementsAsync(true)).ToList();
            if (events.Count == 0)
            {
                throw new FailedTestException("Event log did not render any events.");
            }

            for (var i = 0; i < events.Count; i++)
            {
                var row = events[i];
                await row.ClickAsync();

                var capturedIndex = i;
                await RetryHelpers.RetryAsync(async () =>
                {
                    var highlighted = await events[capturedIndex].IsHighlightedAsync();
                    if (!highlighted)
                    {
                        var classes = await events[capturedIndex]._root.GetAttributeAsync("class") ?? string.Empty;
                        DebugLogger.Log($"JumpToAllEvents: row {capturedIndex} classes '{classes}' not highlighted yet.");
                    }
                    return highlighted;
                }, maxAttempts: 15, delayMs: 200);
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

        // TODO: replace gotoLine-based navigation with breakpoint + continue workflow
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

        // TODO: replace gotoLine-based navigation with breakpoint + continue workflow
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

    private static async Task<CallTraceEntry> RequireCallTraceEntryAsync(
        CallTracePane callTrace,
        string functionName,
        Action<string>? trace = null)
    {
        if (callTrace is null)
        {
            throw new ArgumentNullException(nameof(callTrace));
        }

        if (string.IsNullOrWhiteSpace(functionName))
        {
            throw new ArgumentException("Function name must be provided.", nameof(functionName));
        }

        CallTraceEntry? located = null;
        await RetryHelpers.RetryAsync(async () =>
        {
            trace?.Invoke($"RequireCallTraceEntryAsync: refreshing entries for {functionName}");
            callTrace.InvalidateEntries();
            located = await callTrace.FindEntryAsync(functionName, forceReload: true);
            if (located is not null)
            {
                trace?.Invoke($"RequireCallTraceEntryAsync: located '{functionName}'");
                return true;
            }

            var allEntries = await callTrace.EntriesAsync(true);
            foreach (var entry in allEntries)
            {
                var name = await entry.FunctionNameAsync();
                trace?.Invoke($"RequireCallTraceEntryAsync: expanding entry '{name}'");
                await entry.ExpandChildrenAsync();
            }

            return false;
        }, maxAttempts: 20, delayMs: 200);

        return located ?? throw new Exception($"Call trace entry '{functionName}' was not found.");
    }

    private static async Task<EditorPane> RequireShieldEditorAsync(LayoutPage layout, Action<string>? trace = null)
    {
        if (layout is null)
        {
            throw new ArgumentNullException(nameof(layout));
        }

        EditorPane? editor = null;
        await RetryHelpers.RetryAsync(async () =>
        {
            trace?.Invoke("RequireShieldEditorAsync: refreshing editor tabs");
            var editors = await layout.EditorTabsAsync(true);
            editor = editors.FirstOrDefault(e => e.TabButtonText.Contains("shield.nr", StringComparison.OrdinalIgnoreCase));
            if (editor is null)
            {
                trace?.Invoke("RequireShieldEditorAsync: shield.nr editor not found yet");
                return false;
            }

            await editor.TabButton().ClickAsync();
            trace?.Invoke("RequireShieldEditorAsync: focused shield.nr editor tab");
            return true;
        }, maxAttempts: 20, delayMs: 200);

        if (editor is null)
        {
            trace?.Invoke("RequireShieldEditorAsync: failed to locate shield.nr editor tab");
            throw new Exception("shield.nr editor tab was not available after selecting iterate_asteroids.");
        }

        return editor;
    }

}
