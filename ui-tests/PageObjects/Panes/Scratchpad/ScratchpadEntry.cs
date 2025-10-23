using System;
using System.Threading.Tasks;
using Microsoft.Playwright;
using UiTests.PageObjects.Components;

namespace UiTests.PageObjects.Panes.Scratchpad;

/// <summary>
/// Represents a single scratchpad record rendered inside the scratchpad pane.
/// </summary>
public class ScratchpadEntry
{
    private readonly ILocator _root;
    private readonly ValueComponentView _valueView;

    public ScratchpadEntry(ILocator root)
    {
        _root = root ?? throw new ArgumentNullException(nameof(root));
        _valueView = new ValueComponentView(_root.Locator(".value-expanded").First);
    }

    /// <summary>
    /// Underlying locator for the scratchpad entry container.
    /// </summary>
    public ILocator Root => _root;

    /// <summary>
    /// Returns the inline value component view backing this entry.
    /// </summary>
    public ValueComponentView ValueComponent => _valueView;

    /// <summary>
    /// Locator for the entry's close button.
    /// </summary>
    public ILocator CloseButton => _root.Locator(".scratchpad-value-close");

    /// <summary>
    /// Closes (removes) the entry from the scratchpad.
    /// </summary>
    public Task CloseAsync() => CloseButton.ClickAsync();

    /// <summary>
    /// Human-readable label associated with the entry (expression name).
    /// </summary>
    public async Task<string> ExpressionAsync()
    {
        var name = await _valueView.NameAsync();
        return name.TrimEnd(':').Trim();
    }

    /// <summary>
    /// Returns the rendered value text.
    /// </summary>
    public Task<string> ValueTextAsync() => _valueView.ValueTextAsync();

    /// <summary>
    /// Returns the optional type annotation (if present).
    /// </summary>
    public Task<string?> ValueTypeAsync() => _valueView.ValueTypeAsync();

    /// <summary>
    /// Exposes the underlying value component for further inspection.
    /// </summary>
    public ValueComponentView ValueComponentView => _valueView;
}
