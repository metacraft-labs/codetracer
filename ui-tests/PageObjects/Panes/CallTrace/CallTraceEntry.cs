using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.Playwright;
using UiTests.PageObjects.Components;
using UiTests.Utils;

namespace UiTests.PageObjects.Panes.CallTrace;

/// <summary>
/// Represents a single call entry rendered within the call trace pane.
/// </summary>
public class CallTraceEntry
{
    private static readonly string[] ExpandChildrenOptions = { "Expand Call Children", "Expand Full Callstack" };
    private static readonly string[] CollapseChildrenOptions = { "Collapse Call Children", "Expand Full Callstack" };

    private readonly CallTracePane _pane;
    private readonly ILocator _root;
    private readonly ContextMenu _contextMenu;

    public CallTraceEntry(CallTracePane pane, ILocator root, ContextMenu contextMenu)
    {
        _pane = pane ?? throw new ArgumentNullException(nameof(pane));
        _root = root ?? throw new ArgumentNullException(nameof(root));
        _contextMenu = contextMenu ?? throw new ArgumentNullException(nameof(contextMenu));
    }

    /// <summary>
    /// Root locator for the entry (<c>.calltrace-call-line</c>).</summary>
    public ILocator Root => _root;

    private ILocator OffsetLocator() => _root.Locator("> span").First;
    private ILocator ChildBoxLocator() => _root.Locator(".call-child-box");
    private ILocator CallTextLocator() => ChildBoxLocator().Locator(".call-text");
    private ILocator ToggleLocator() => ChildBoxLocator().Locator(".toggle-call");
    private ILocator ReturnLocator() => ChildBoxLocator().Locator(".return-text");
    private ILocator ArgumentContainer() => ChildBoxLocator().Locator(".call-args");

    /// <summary>
    /// Extracts the raw call text (e.g. "iterate_asteroids #1").
    /// </summary>
    public async Task<string> CallTextAsync()
    {
        var text = await CallTextLocator().InnerTextAsync();
        return text?.Trim() ?? string.Empty;
    }

    /// <summary>
    /// Function name portion extracted from the call text.
    /// </summary>
    public async Task<string> FunctionNameAsync()
    {
        var callText = await CallTextAsync();
        var hashIndex = callText.IndexOf('#');
        return hashIndex >= 0 ? callText[..hashIndex].Trim() : callText;
    }

    /// <summary>
    /// Call identifier (the suffix after '#', if present).
    /// </summary>
    public async Task<string> CallIdentifierAsync()
    {
        var callText = await CallTextAsync();
        var hashIndex = callText.IndexOf('#');
        return hashIndex >= 0 ? callText[(hashIndex + 1)..].Trim() : string.Empty;
    }

    /// <summary>
    /// Depth inferred from the leading spacer element.
    /// </summary>
    public async Task<int> DepthAsync()
    {
        var style = await OffsetLocator().GetAttributeAsync("style") ?? string.Empty;
        var minWidthPrefix = "min-width:";
        var index = style.IndexOf(minWidthPrefix, StringComparison.OrdinalIgnoreCase);
        if (index < 0)
        {
            return 0;
        }

        var start = index + minWidthPrefix.Length;
        var end = style.IndexOf('p', start);
        if (end < 0)
        {
            end = style.Length;
        }

        var valueString = style[start..end].Trim().TrimEnd('x');
        if (!double.TryParse(valueString, NumberStyles.Any, CultureInfo.InvariantCulture, out var pixels))
        {
            return 0;
        }

        return (int)Math.Round(pixels / 8.0, MidpointRounding.AwayFromZero);
    }

    private async Task<bool> HasClassAsync(string className)
    {
        var classAttr = await _root.GetAttributeAsync("class") ?? string.Empty;
        return classAttr.Split(' ', StringSplitOptions.RemoveEmptyEntries)
            .Contains(className, StringComparer.OrdinalIgnoreCase);
    }

    /// <summary>
    /// Indicates whether this entry is the currently selected call.
    /// </summary>
    public Task<bool> IsSelectedAsync() => HasClassAsync("event-selected");

    /// <summary>
    /// Determines whether the entry exposes a toggle button.
    /// </summary>
    public async Task<bool> HasToggleAsync()
    {
        return await ToggleLocator().Locator(".collapse-call-img, .dot-call-img").CountAsync() > 0;
    }

    /// <summary>
    /// Checks if child calls are currently expanded.
    /// </summary>
    public async Task<bool> HasExpandedChildrenAsync()
    {
        return await ToggleLocator().Locator(".collapse-call-img").CountAsync() > 0;
    }

    /// <summary>
    /// Returns the call context-menu options expected for the current state.
    /// </summary>
    public async Task<IReadOnlyList<string>> ExpectedContextMenuAsync()
    {
        return await HasExpandedChildrenAsync() ? CollapseChildrenOptions : ExpandChildrenOptions;
    }

    /// <summary>
    /// Opens the call context menu and retrieves the visible entries.
    /// </summary>
    public async Task<IReadOnlyList<string>> ContextMenuEntriesAsync()
    {
        await ChildBoxLocator().ClickAsync(new() { Button = MouseButton.Right });
        await _contextMenu.WaitForVisibleAsync();
        var entries = await _contextMenu.GetEntriesAsync();
        await _contextMenu.DismissAsync();
        return entries.Select(e => e.Text).ToList();
    }

    /// <summary>
    /// Expands child calls when possible.
    /// </summary>
    public async Task ExpandChildrenAsync()
    {
        if (!await HasToggleAsync())
        {
            return;
        }

        if (!await HasExpandedChildrenAsync())
        {
            await ToggleLocator().ClickAsync();
            await RetryHelpers.RetryAsync(HasExpandedChildrenAsync);
        }
    }

    /// <summary>
    /// Collapses the children when expanded.
    /// </summary>
    public async Task CollapseChildrenAsync()
    {
        if (!await HasToggleAsync())
        {
            return;
        }

        if (await HasExpandedChildrenAsync())
        {
            await ToggleLocator().ClickAsync();
            await RetryHelpers.RetryAsync(async () => !await HasExpandedChildrenAsync());
        }
    }

    /// <summary>
    /// Clicks the call entry to trigger jump navigation.
    /// Tries multiple hit targets (call text, child container, root) to accommodate
    /// renderer differences between Electron and Web.
    /// </summary>
    public async Task ActivateAsync()
    {
        var functionName = await FunctionNameAsync();
        DebugLogger.Log($"CallTraceEntry[{functionName}]: Begin ActivateAsync");

        var targets = new (string Label, ILocator Locator)[]
        {
            ("call-text", CallTextLocator()),
            ("child-box", ChildBoxLocator()),
            ("root", _root)
        };

        var clickAttempts = new (string Label, LocatorClickOptions Options)[]
        {
            ("single-click", new LocatorClickOptions { ClickCount = 1 }),
            ("double-click", new LocatorClickOptions { ClickCount = 2, Delay = 50 }),
            ("forced-click", new LocatorClickOptions { ClickCount = 1, Force = true })
        };

        foreach (var (targetLabel, target) in targets)
        {
            try
            {
                DebugLogger.Log($"CallTraceEntry[{functionName}]: scrolling into view {targetLabel}");
                await target.ScrollIntoViewIfNeededAsync();
            }
            catch (PlaywrightException ex)
            {
                DebugLogger.Log($"CallTraceEntry[{functionName}]: scroll failed for {targetLabel}: {ex.Message}");
            }

            foreach (var (clickLabel, options) in clickAttempts)
            {
                try
                {
                    DebugLogger.Log($"CallTraceEntry[{functionName}]: clicking {targetLabel} with {clickLabel}");
                    await target.ClickAsync(options);
                    try
                    {
                        await RetryHelpers.RetryAsync(async () => await IsSelectedAsync(), maxAttempts: 5, delayMs: 50);
                        DebugLogger.Log($"CallTraceEntry[{functionName}]: activation succeeded via {targetLabel}/{clickLabel}");
                        return;
                    }
                    catch (TimeoutException)
                    {
                        DebugLogger.Log($"CallTraceEntry[{functionName}]: selection timeout after {targetLabel}/{clickLabel}");
                    }
                }
                catch (PlaywrightException ex)
                {
                    DebugLogger.Log($"CallTraceEntry[{functionName}]: PlaywrightException on {targetLabel}/{clickLabel}: {ex.Message}");
                }
            }
        }

        DebugLogger.Log($"CallTraceEntry[{functionName}]: failed to activate via all targets");
        throw new InvalidOperationException("Failed to activate call trace entry via any known target.");
    }

    /// <summary>
    /// Retrieves all argument descriptors rendered for the call.
    /// </summary>
    public async Task<IReadOnlyList<CallTraceArgument>> ArgumentsAsync()
    {
        var args = await ArgumentContainer().Locator(".call-arg").AllAsync();
        return args.Select(locator => new CallTraceArgument(_pane, locator, _contextMenu)).ToList();
    }

    /// <summary>
    /// Retrieves the return value text if available, otherwise null.
    /// </summary>
    public async Task<string?> ReturnValueAsync()
    {
        if (await ReturnLocator().CountAsync() == 0)
        {
            return null;
        }

        var text = await ReturnLocator().First.InnerTextAsync();
        return text?.Trim();
    }
}
