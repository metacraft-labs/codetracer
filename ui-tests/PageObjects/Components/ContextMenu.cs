using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.Playwright;

namespace UiTests.PageObjects.Components;

/// <summary>
/// Utility wrapper for interacting with the global CodeTracer context menu.
/// </summary>
public class ContextMenu
{
    private const string DefaultContainerSelector = "#context-menu-container";
    private const string DefaultItemSelector = ".context-menu-item";
    private const string DefaultHintSelector = ".context-menu-hint";

    private readonly IPage _page;
    private readonly string _containerSelector;
    private readonly string _itemSelector;
    private readonly string _hintSelector;

    public ContextMenu(
        IPage page,
        string? containerSelector = null,
        string? itemSelector = null,
        string? hintSelector = null)
    {
        _page = page;
        _containerSelector = containerSelector ?? DefaultContainerSelector;
        _itemSelector = itemSelector ?? DefaultItemSelector;
        _hintSelector = hintSelector ?? DefaultHintSelector;
    }

    /// <summary>
    /// Locator referencing the outer context-menu container.
    /// </summary>
    public ILocator Container => _page.Locator(_containerSelector);

    /// <summary>
    /// Waits until the menu container becomes visible.
    /// </summary>
    public Task WaitForVisibleAsync()
        => Container.WaitForAsync(new() { State = WaitForSelectorState.Visible });

    /// <summary>
    /// Waits until the menu container is hidden.
    /// </summary>
    public Task WaitForHiddenAsync()
        => Container.WaitForAsync(new() { State = WaitForSelectorState.Hidden });

    /// <summary>
    /// Retrieves the menu entries currently displayed.
    /// </summary>
    /// <remarks>
    /// Context menu items may contain a hint element (e.g., keyboard shortcut) nested
    /// inside the item. Since InnerTextAsync() returns the combined text of all child
    /// elements, we need to subtract the hint text from the full text to get just the
    /// action name.
    /// </remarks>
    public async Task<IReadOnlyList<ContextMenuEntry>> GetEntriesAsync()
    {
        var items = await Container.Locator(_itemSelector).AllAsync();
        var entries = new List<ContextMenuEntry>(items.Count);

        foreach (var item in items)
        {
            var fullText = await item.InnerTextAsync() ?? string.Empty;
            if (string.IsNullOrWhiteSpace(fullText))
            {
                continue;
            }
            var hintLocator = item.Locator(_hintSelector);
            var hint = await hintLocator.CountAsync() > 0
                ? await hintLocator.First.InnerTextAsync() ?? string.Empty
                : string.Empty;

            // Remove the hint from the full text to get just the action name.
            // The hint text is typically appended after the action text.
            var actionText = fullText.Trim();
            if (!string.IsNullOrEmpty(hint))
            {
                var hintIndex = actionText.IndexOf(hint.Trim(), StringComparison.Ordinal);
                if (hintIndex >= 0)
                {
                    actionText = actionText.Substring(0, hintIndex).Trim();
                }
            }

            entries.Add(new ContextMenuEntry(actionText, hint.Trim()));
        }

        return entries;
    }

    /// <summary>
    /// Selects an entry whose text matches <paramref name="entryText"/>.
    /// Throws when the entry cannot be found.
    /// </summary>
    /// <remarks>
    /// Note: We cannot use Exact = true because context menu items may contain
    /// hint text (e.g., keyboard shortcuts) as a nested element. The InnerText
    /// of the menu item includes both the action text and the hint text, making
    /// exact matches fail for entries like "Add value to scratchpad" when the
    /// full text is "Add value to scratchpad CTRL+<click on value>".
    /// </remarks>
    public async Task SelectAsync(string entryText)
    {
        if (string.IsNullOrWhiteSpace(entryText))
        {
            throw new ArgumentException("Entry text must be provided.", nameof(entryText));
        }

        // Use filter to find items that start with the entry text to avoid
        // matching hint text which comes after the main action text.
        var items = Container.Locator(_itemSelector);
        var count = await items.CountAsync();

        for (int i = 0; i < count; i++)
        {
            var item = items.Nth(i);
            var text = await item.InnerTextAsync();
            // The menu item text format is: "ActionText" or "ActionText HintText"
            // We check if the text starts with our entry text (ignoring the hint).
            if (text != null && text.Trim().StartsWith(entryText, StringComparison.OrdinalIgnoreCase))
            {
                await item.ClickAsync();
                await WaitForHiddenAsync();
                return;
            }
        }

        throw new InvalidOperationException(
            $"Context menu entry '{entryText}' was not found. Available items: {count}");
    }

    /// <summary>
    /// Attempts to close the context menu by simulating an escape key press.
    /// </summary>
    public async Task DismissAsync()
    {
        if (await Container.IsVisibleAsync())
        {
            await _page.Keyboard.PressAsync("Escape");
            await WaitForHiddenAsync();
        }
    }

    /// <summary>
    /// Represents a single context-menu entry (text + optional hint).
    /// </summary>
    public readonly record struct ContextMenuEntry(string Text, string Hint)
    {
        public bool Matches(string expectedText) =>
            string.Equals(Text, expectedText, StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>
    /// Helper to assert that the current menu matches the expected set of entries.
    /// </summary>
    public async Task EnsureEntriesAsync(IEnumerable<string> expectedEntries)
    {
        if (expectedEntries is null)
        {
            throw new ArgumentNullException(nameof(expectedEntries));
        }

        var expectedList = expectedEntries.ToList();
        var actual = await GetEntriesAsync();

        if (actual.Count != expectedList.Count)
        {
            throw new InvalidOperationException(
                $"Context menu mismatch: expected {expectedList.Count} entries but saw {actual.Count}. " +
                $"Actual entries: {string.Join(", ", actual.Select(e => e.Text))}");
        }

        for (var i = 0; i < expectedList.Count; i++)
        {
            var expected = expectedList[i];
            var actualEntry = actual[i];
            if (!actualEntry.Matches(expected))
            {
                throw new InvalidOperationException(
                    $"Context menu mismatch at index {i}: expected '{expected}' but found '{actualEntry.Text}'.");
            }
        }
    }
}
