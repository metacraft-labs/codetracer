using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.Playwright;

namespace UiTests.PageObjects.Components;

/// <summary>
/// Generic page object for the value component renderer used across panes (state, call trace, scratchpad).
/// The markup originates from <c>value.nim</c> and exposes a consistent structure that we can reuse in tests.
/// </summary>
public class ValueComponentView
{
    private readonly ILocator _root;

    public ValueComponentView(ILocator root) => _root = root;

    /// <summary>
    /// Root locator of the value component.
    /// </summary>
    public ILocator Root => _root;

    /// <summary>
    /// Returns the rendered name label (e.g. <c>initial_shield</c> or <c>[0]</c>).
    /// </summary>
    public Task<string?> NameAsync() => TextContentOrNullAsync(_root.Locator(".value-name"));

    /// <summary>
    /// Returns the type label rendered when the node is expanded.
    /// </summary>
    public Task<string?> TypeAsync() => TextContentOrNullAsync(_root.Locator(".value-type"));

    /// <summary>
    /// Returns the textual representation of the value.
    /// </summary>
    public Task<string?> ValueTextAsync() => TextContentOrNullAsync(_root.Locator(".value-expanded-text"));

    /// <summary>
    /// Locator for the caret button controlling expansion.
    /// </summary>
    public ILocator ExpandButtonLocator => _root.Locator(".value-expand-button");

    /// <summary>
    /// Locator for the optional value history toggle.
    /// </summary>
    public ILocator HistoryToggleLocator => _root.Locator(".toggle-value-history");

    /// <summary>
    /// Determines whether the component exposes an expand/collapse toggle.
    /// The caret icons are rendered as either <c>.caret-collapse</c> or <c>.caret-expand</c>
    /// according to <c>value.nim</c>.
    /// </summary>
    public async Task<bool> HasExpandToggleAsync()
    {
        var caret = ExpandButtonLocator.Locator(".caret-collapse, .caret-expand");
        return await caret.CountAsync() > 0;
    }

    /// <summary>
    /// Returns whether the value is currently expanded. The frontend renders <c>.caret-expand</c>
    /// when the node is open and <c>.caret-collapse</c> otherwise.
    /// </summary>
    public async Task<bool> IsExpandedAsync()
    {
        if (!await HasExpandToggleAsync())
        {
            return false;
        }

        return await ExpandButtonLocator.Locator(".caret-expand").CountAsync() > 0;
    }

    /// <summary>
    /// Expands the value node if it exposes a caret and is currently collapsed.
    /// </summary>
    public async Task ExpandAsync()
    {
        if (!await HasExpandToggleAsync())
        {
            return;
        }

        if (!await IsExpandedAsync())
        {
            await ExpandButtonLocator.ClickAsync();
        }
    }

    /// <summary>
    /// Collapses the value node when possible.
    /// </summary>
    public async Task CollapseAsync()
    {
        if (!await HasExpandToggleAsync())
        {
            return;
        }

        if (await IsExpandedAsync())
        {
            await ExpandButtonLocator.ClickAsync();
        }
    }

    /// <summary>
    /// Returns the text of the tooltip toggle if it exists.
    /// </summary>
    public Task<string?> HistoryTooltipAsync()
        => TextContentOrNullAsync(HistoryToggleLocator.Locator(".custom-tooltip"));

    /// <summary>
    /// Determines whether the history toggle is present.
    /// </summary>
    public async Task<bool> HasHistoryToggleAsync()
        => await HistoryToggleLocator.CountAsync() > 0;

    /// <summary>
    /// Returns child value components rendered under <c>.value-expanded-compound</c>.
    /// </summary>
    public async Task<IReadOnlyList<ValueComponentView>> ChildValuesAsync()
    {
        var compound = _root.Locator(":scope .value-expanded-compound");
        if (await compound.CountAsync() == 0)
        {
            return new List<ValueComponentView>();
        }

        var children = await compound.First.Locator(":scope > .value-expanded").AllAsync();
        return children.Select(child => new ValueComponentView(child)).ToList();
    }

    private static async Task<string?> TextContentOrNullAsync(ILocator locator)
    {
        if (await locator.CountAsync() == 0)
        {
            return null;
        }

        var text = await locator.First.TextContentAsync();
        return text?.Trim();
    }
}
