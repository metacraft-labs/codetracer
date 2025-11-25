using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using UiTests.PageObjects.CommandPalette;
using UiTests.PageObjects;
using UiTests.PageObjects.Panes.EventLog;
using UiTests.PageObjects.Panes.Filesystem;

namespace UiTests.Stability;

public sealed class PlaywrightStabilityCommandHandler : IStabilityCommandHandler
{
    private readonly LayoutPage _layout;
    private readonly Microsoft.Playwright.IPage _page;
    private readonly string? _screenshotRoot;

    public PlaywrightStabilityCommandHandler(LayoutPage layout, Microsoft.Playwright.IPage page, string? screenshotRoot = null)
    {
        _layout = layout;
        _page = page;
        _screenshotRoot = screenshotRoot;
    }

    public async Task<IReadOnlyList<StabilityIntent>> HandleAsync(StabilityCommand command, StabilityModel state, CancellationToken cancellationToken)
    {
        switch (command)
        {
            case ReadEventLogSnapshotCommand:
                return new StabilityIntent[] { await ReadSnapshotAsync(cancellationToken) };

            case JumpToEventIndexCommand jump:
                await PerformJumpAsync(jump.TargetIndex, cancellationToken);
                return new StabilityIntent[] { new JumpCompleted(jump.TargetIndex) };

            case AssertEventHighlightCommand assert:
                await AssertHighlightAsync(assert.TargetIndex, cancellationToken);
                return Array.Empty<StabilityIntent>();

            case LogMessageCommand:
                return Array.Empty<StabilityIntent>();

            case ClickDebuggerControlCommand click:
                await ClickDebuggerControlAsync(click.Control, cancellationToken);
                return Array.Empty<StabilityIntent>();

            case TogglePaneCommand toggle:
                await TogglePaneAsync(toggle.PaneName, cancellationToken);
                return Array.Empty<StabilityIntent>();

            case OpenAllFilesystemFilesCommand:
                await OpenAllFilesystemFilesAsync(cancellationToken);
                return Array.Empty<StabilityIntent>();

            case CloseAllEditorsCommand:
                await CloseAllEditorsAsync(cancellationToken);
                return Array.Empty<StabilityIntent>();

            case CaptureScreenshotCommand capture:
                await CaptureScreenshotAsync(capture.Label, cancellationToken);
                return Array.Empty<StabilityIntent>();
        }

        throw new InvalidOperationException($"Unhandled command {command.GetType().Name}");
    }

    private async Task<StabilityIntent> ReadSnapshotAsync(CancellationToken cancellationToken)
    {
        await _layout.WaitForEventLogLoadedAsync();
        var eventLog = await RequireEventLogAsync(cancellationToken);
        await eventLog.TabButton().ClickAsync(new() { Timeout = 10_000 });
        var rows = (await eventLog.EventElementsAsync(true)).ToList();
        var highlightedIndex = default(int?);
        foreach (var row in rows)
        {
            if (await row.IsHighlightedAsync())
            {
                highlightedIndex = await row.IndexAsync();
                break;
            }
        }

        return new EventLogSnapshotReceived(rows.Count, highlightedIndex);
    }

    private async Task PerformJumpAsync(int targetIndex, CancellationToken cancellationToken)
    {
        await _layout.WaitForEventLogLoadedAsync();
        var eventLog = await RequireEventLogAsync(cancellationToken);
        await eventLog.TabButton().ClickAsync(new() { Timeout = 10_000 });
        var row = await eventLog.RowByIndexAsync(targetIndex, forceReload: true);
        await row.ClickAsync();
    }

    private async Task AssertHighlightAsync(int targetIndex, CancellationToken cancellationToken)
    {
        await _layout.WaitForEventLogLoadedAsync();
        var eventLog = await RequireEventLogAsync(cancellationToken);
        var row = await eventLog.RowByIndexAsync(targetIndex, forceReload: true);
        var highlighted = await row.IsHighlightedAsync();
        if (!highlighted)
        {
            throw new InvalidOperationException($"Expected event log row {targetIndex} to be highlighted after navigation.");
        }
    }

    private async Task<EventLogPane> RequireEventLogAsync(CancellationToken cancellationToken)
    {
        var tabs = await _layout.EventLogTabsAsync(true);
        var visibleTab = tabs.FirstOrDefault();
        if (visibleTab is null)
        {
            throw new InvalidOperationException("Event log tab is not available.");
        }

        return visibleTab;
    }

    private async Task ClickDebuggerControlAsync(DebuggerControl control, CancellationToken cancellationToken)
    {
        await _layout.WaitForAllComponentsLoadedAsync();
        Microsoft.Playwright.ILocator locator = control switch
        {
            DebuggerControl.Continue => _layout.ContinueButton(),
            DebuggerControl.RunToEntry => _layout.RunToEntryButton(),
            DebuggerControl.StepNext => _layout.NextButton(),
            DebuggerControl.StepInto => _layout.StepInButton(),
            DebuggerControl.StepOut => _layout.StepOutButton(),
            DebuggerControl.ReverseContinue => _layout.ReverseContinueButton(),
            DebuggerControl.ReverseStepNext => _layout.ReverseNextButton(),
            DebuggerControl.ReverseStepInto => _layout.ReverseStepInButton(),
            DebuggerControl.ReverseStepOut => _layout.ReverseStepOutButton(),
            _ => throw new InvalidOperationException($"Unsupported debugger control {control}")
        };

        await locator.ClickAsync(new() { Timeout = 10_000 });
    }

    private async Task TogglePaneAsync(string paneName, CancellationToken cancellationToken)
    {
        var palette = new CommandPalette(_page);
        await palette.OpenAsync();
        await palette.ExecuteCommandAsync(paneName);
        await _page.WaitForTimeoutAsync(200);
    }

    private async Task OpenAllFilesystemFilesAsync(CancellationToken cancellationToken)
    {
        await _layout.WaitForFilesystemLoadedAsync();
        var filesystem = (await _layout.FilesystemTabsAsync(true)).First();
        await filesystem.TabButton().ClickAsync(new() { Timeout = 10_000 });

        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var iterations = 0;
        while (iterations < 6)
        {
            iterations++;
            var nodes = await filesystem.VisibleNodesAsync();
            var anyExpanded = false;
            foreach (var node in nodes)
            {
                var name = await node.NameAsync();
                var level = await node.LevelAsync();
                var key = $"{level}:{name}";
                if (!seen.Contains(key))
                {
                    seen.Add(key);
                }

                var isLeaf = await node.IsLeafAsync();
                if (!isLeaf)
                {
                    await node.ExpandAsync();
                    anyExpanded = true;
                }
                else
                {
                    await node.LeftClickAsync();
                    await _page.WaitForTimeoutAsync(50);
                }
            }

            if (!anyExpanded)
            {
                break;
            }
        }
    }

    private async Task CloseAllEditorsAsync(CancellationToken cancellationToken)
    {
        var editors = await _layout.EditorTabsAsync(true);
        if (editors.Count == 0)
        {
            return;
        }

        foreach (var editor in editors)
        {
            try
            {
                await editor.TabButton().ClickAsync();
                await _page.Keyboard.PressAsync("Control+W");
            }
            catch
            {
                // best-effort; continue closing remaining tabs
            }
        }
    }

    private async Task CaptureScreenshotAsync(string label, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(_screenshotRoot))
        {
            return;
        }

        Directory.CreateDirectory(_screenshotRoot);
        var fileName = $"{DateTime.UtcNow:yyyyMMdd_HHmmssfff}_{Sanitize(label)}.png";
        var path = Path.Combine(_screenshotRoot, fileName);
        await _page.ScreenshotAsync(new() { Path = path, FullPage = true });
    }

    private static string Sanitize(string input)
    {
        var invalid = Path.GetInvalidFileNameChars();
        var cleaned = new string(input.Select(ch => invalid.Contains(ch) ? '_' : ch).ToArray());
        return cleaned;
    }
}
