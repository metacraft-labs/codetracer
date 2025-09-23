using System.Threading.Tasks;
using Microsoft.Playwright;
using UiTests.PageObjects.Components;

namespace UiTests.PageObjects.Panes.Scratchpad;

/// <summary>
/// Represents a single entry inside the scratchpad pane.
/// </summary>
public class ScratchpadValueView
{
    private readonly ILocator _root;
    private readonly ValueComponentView _valueComponent;

    public ScratchpadValueView(ILocator root)
    {
        _root = root;
        _valueComponent = new ValueComponentView(root.Locator(":scope .value-expanded").First);
    }

    public ILocator Root => _root;

    public ILocator CloseButtonLocator => _root.Locator(".scratchpad-value-close");

    public ValueComponentView ValueComponent => _valueComponent;

    public Task CloseAsync() => CloseButtonLocator.ClickAsync();

    public Task ExpandAsync() => _valueComponent.ExpandAsync();

    public Task CollapseAsync() => _valueComponent.CollapseAsync();
}
