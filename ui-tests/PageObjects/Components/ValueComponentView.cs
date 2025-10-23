using System;
using System.Threading.Tasks;
using Microsoft.Playwright;

namespace UiTests.PageObjects.Components;

/// <summary>
/// Lightweight wrapper around the reusable value component markup used across panes,
/// including scratchpad entries, tooltips, and inline state values.
/// </summary>
public class ValueComponentView
{
    private readonly ILocator _root;

    public ValueComponentView(ILocator root)
    {
        _root = root ?? throw new ArgumentNullException(nameof(root));
    }

    /// <summary>
    /// Root locator representing the <c>.value-expanded</c> element.
    /// </summary>
    public ILocator Root => _root;

    private ILocator NameContainer() => _root.Locator(".value-name-container");
    private ILocator ExpandButton() => NameContainer().Locator(".value-expand-button");
    private ILocator AddToScratchpadButton() => NameContainer().Locator(".add-to-scratchpad-button");
    private ILocator HistoryToggle() => NameContainer().Locator(".toggle-value-history");
    private ILocator ValueTypeNode() => NameContainer().Locator(".value-type");
    private ILocator ValueTextNode() => _root.Locator(".value-expanded-text").First;

    /// <summary>
    /// Extracts the label rendered before the value (e.g. <c>remaining_shield:</c>).
    /// </summary>
    public async Task<string> NameAsync()
    {
        var nameText = await NameContainer().Locator(".value-name").InnerTextAsync();
        var name = (nameText ?? string.Empty).Trim();
        return name.TrimEnd(':').Trim();
    }

    /// <summary>
    /// Returns the textual representation of the value body.
    /// </summary>
    public async Task<string> ValueTextAsync()
    {
        var valueText = await ValueTextNode().InnerTextAsync();
        return (valueText ?? string.Empty).Trim();
    }

    /// <summary>
    /// Returns the type annotation if the component exposes one.
    /// </summary>
    public async Task<string?> ValueTypeAsync()
    {
        if (await ValueTypeNode().CountAsync() == 0)
        {
            return null;
        }

        var text = await ValueTypeNode().First.InnerTextAsync();
        return text?.Trim();
    }

    /// <summary>
    /// Indicates whether the value supports nested expansion.
    /// </summary>
    public async Task<bool> IsExpandableAsync()
        => await ExpandButton().Locator(".caret-expand, .caret-collapse").CountAsync() > 0;

    /// <summary>
    /// Attempts to expand the value component (no-op if it is not expandable).
    /// </summary>
    public async Task ExpandAsync()
    {
        if (await IsExpandableAsync())
        {
            await ExpandButton().ClickAsync();
        }
    }

    /// <summary>
    /// Determines whether the inline "Add to scratchpad" button is available.
    /// </summary>
    public async Task<bool> HasAddToScratchpadButtonAsync()
        => await AddToScratchpadButton().CountAsync() > 0;

    /// <summary>
    /// Clicks the inline "Add to scratchpad" button (throws if it is absent).
    /// </summary>
    public async Task ClickAddToScratchpadAsync()
    {
        if (!await HasAddToScratchpadButtonAsync())
        {
            throw new InvalidOperationException("This value component does not expose an inline Add to scratchpad button.");
        }

        await AddToScratchpadButton().ClickAsync();
    }

    /// <summary>
    /// Indicates whether the value component offers a history toggle entry.
    /// </summary>
    public async Task<bool> HasHistoryToggleAsync()
        => await HistoryToggle().CountAsync() > 0;

    /// <summary>
    /// Invokes the history toggle (throws when unavailable).
    /// </summary>
    public async Task ToggleHistoryAsync()
    {
        if (!await HasHistoryToggleAsync())
        {
            throw new InvalidOperationException("No history toggle is available for this value component.");
        }

        await HistoryToggle().ClickAsync();
    }
}
