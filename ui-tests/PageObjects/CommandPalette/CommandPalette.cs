using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.Playwright;
using UiTests.Utils;

namespace UiTests.PageObjects.CommandPalette;

/// <summary>
/// Playwright abstraction over the command palette component.
/// </summary>
public class CommandPalette
{
    private readonly IPage _page;

    public CommandPalette(IPage page) => _page = page;

    private ILocator Root => _page.Locator("#command-view");
    private ILocator QueryInput => _page.Locator("#command-query-text");
    private ILocator ResultsContainer => _page.Locator("#command-results");
    private ILocator ResultItems => ResultsContainer.Locator(".command-result");
    private ILocator MatchingResultItems => ResultsContainer.Locator(".command-result:not(.empty)");

    /// <summary>
    /// Opens the command palette via the keyboard shortcut.
    /// </summary>
    public async Task OpenAsync()
    {
        await _page.Keyboard.PressAsync("Control+KeyP");
        await Root.WaitForAsync(new() { State = WaitForSelectorState.Visible });
    }

    /// <summary>
    /// Closes the command palette.
    /// </summary>
    public async Task CloseAsync()
    {
        await _page.Keyboard.PressAsync("Escape");
        await Root.WaitForAsync(new() { State = WaitForSelectorState.Hidden });
    }

    /// <summary>
    /// Returns whether the palette is currently visible.
    /// </summary>
    public Task<bool> IsVisibleAsync() => Root.IsVisibleAsync();

    /// <summary>
    /// Retrieves all rendered result strings.
    /// </summary>
    public async Task<IReadOnlyList<string>> ResultTextsAsync()
    {
        var items = await ResultItems.AllAsync();
        var results = new List<string>(items.Count);
        foreach (var item in items)
        {
            var text = await item.InnerTextAsync() ?? string.Empty;
            results.Add(text.Trim());
        }
        return results;
    }

    /// <summary>
    /// Waits until the palette renders at least <paramref name="count"/> results.
    /// This includes both matching results and the "no matching result" message.
    /// </summary>
    public Task WaitForResultsAsync(int count = 1)
        => RetryHelpers.RetryAsync(async () => await ResultItems.CountAsync() >= count);

    /// <summary>
    /// Waits until the palette renders at least <paramref name="count"/> matching command results.
    /// This excludes the "no matching result" message.
    /// </summary>
    public Task WaitForMatchingResultsAsync(int count = 1)
        => RetryHelpers.RetryAsync(async () => await MatchingResultItems.CountAsync() >= count);

    /// <summary>
    /// Selects the command with the provided label.
    /// </summary>
    public async Task ExecuteCommandAsync(string commandText)
    {
        await EnsureVisibleAsync();
        await QueryInput.FillAsync($":{commandText}");
        await WaitForMatchingResultsAsync();
        await QueryInput.PressAsync("Enter");
        await Root.WaitForAsync(new() { State = WaitForSelectorState.Hidden });
    }

    /// <summary>
    /// Executes a symbol search using the <c>:sym</c> command.
    /// </summary>
    public async Task ExecuteSymbolSearchAsync(string symbolQuery, int resultIndex = 0)
    {
        await EnsureVisibleAsync();
        await QueryInput.FillAsync($":sym {symbolQuery}");
        await WaitForResultsAsync();
        var target = ResultItems.Nth(resultIndex);
        await target.ClickAsync();
        await Root.WaitForAsync(new() { State = WaitForSelectorState.Hidden });
    }

    private async Task EnsureVisibleAsync()
    {
        if (!await IsVisibleAsync())
        {
            await OpenAsync();
        }
    }
}
