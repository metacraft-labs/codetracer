using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.Playwright;

namespace UiTests.PageObjects.Panes.CallTrace;

/// <summary>
/// Represents a single argument rendered within a call trace record.
/// </summary>
public class CallTraceArgument
{
    private readonly ILocator _root;

    public CallTraceArgument(ILocator root)
    {
        _root = root;
    }

    public ILocator Root => _root;

    public ILocator NameLocator => _root.Locator(".call-arg-name");
    public ILocator ValueLocator => _root.Locator(".call-arg-text");

    public async Task<string?> NameAsync()
    {
        var text = await NameLocator.First.TextContentAsync();
        return text?.TrimEnd('=');
    }

    public async Task<string?> ValueAsync()
    {
        var text = await ValueLocator.First.TextContentAsync();
        return text?.Trim();
    }

    public Task ClickAsync() => _root.ClickAsync();

    public Task CtrlClickAsync() => _root.ClickAsync(new() { Modifiers = new[] { KeyboardModifier.Control } });

    public Task RightClickAsync() => _root.ClickAsync(new() { Button = MouseButton.Right });

    /// <summary>
    /// Returns tooltips that are direct siblings of the argument container.
    /// </summary>
    public async Task<IReadOnlyList<CallTraceValueTooltip>> TooltipsAsync()
    {
        var tooltips = await _root.Locator("xpath=following-sibling::div[contains(@class,'call-tooltip')]").AllAsync();
        return tooltips.Select(locator => new CallTraceValueTooltip(locator)).ToList();
    }
}
