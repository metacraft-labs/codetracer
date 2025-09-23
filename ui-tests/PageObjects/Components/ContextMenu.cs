using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.Playwright;

namespace UiTests.PageObjects.Components;

/// <summary>
/// Page object for the global context menu rendered by the frontend renderer.
/// </summary>
public class ContextMenu
{
    private readonly IPage _page;

    public ContextMenu(IPage page) => _page = page;

    /// <summary>
    /// Locator for the menu container (<c>#context-menu-container</c>).
    /// </summary>
    public ILocator Container => _page.Locator("#context-menu-container");

    /// <summary>
    /// Locator targeting individual context menu items.
    /// </summary>
    public ILocator Items => Container.Locator(".context-menu-item");

    /// <summary>
    /// Waits until the menu container becomes visible.
    /// </summary>
    public Task WaitForVisibleAsync()
        => Container.WaitForAsync(new() { State = WaitForSelectorState.Visible });

    /// <summary>
    /// Determines whether the menu is currently visible.
    /// </summary>
    public Task<bool> IsVisibleAsync() => Container.IsVisibleAsync();

    /// <summary>
    /// Returns the normalized text of all currently visible menu items.
    /// </summary>
    public async Task<IReadOnlyList<string>> ItemTextsAsync()
    {
        var texts = await Items.AllInnerTextsAsync();
        return texts.Select(t => t.Trim()).ToList();
    }

    /// <summary>
    /// Clicks the first menu item whose text contains the provided snippet.
    /// </summary>
    public async Task ClickItemByTextAsync(string text)
    {
        var item = Items.Filter(new() { HasTextString = text });
        await item.First.ClickAsync();
    }

    /// <summary>
    /// Clicks a menu item by index.
    /// </summary>
    public Task ClickItemAsync(int index)
        => Items.Nth(index).ClickAsync();
}
