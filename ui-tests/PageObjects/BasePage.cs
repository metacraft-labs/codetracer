using System.Threading.Tasks;
using Microsoft.Playwright;

namespace UtTestsExperimentalConsoleAppication.PageObjects;

/// <summary>
/// Base class for all pages in the Playwright test suite.
/// Holds a reference to the underlying <see cref="IPage"/>.
/// </summary>
public abstract class BasePage
{
    protected BasePage(IPage page) => Page = page;

    /// <summary>
    /// Playwright page driving the browser.
    /// </summary>
    protected IPage Page { get; }
}

/// <summary>
/// Representation of a generic tab within CodeTracer.
/// </summary>
public class TabObject
{
    private readonly string _tabButtonText;

    protected readonly IPage Page;

    /// <summary>
    /// Root locator of the tab content.
    /// </summary>
    public ILocator Root { get; }

    public TabObject(IPage page, ILocator root, string tabButtonText)
    {
        Page = page;
        Root = root;
        _tabButtonText = tabButtonText;
    }

    /// <summary>
    /// Locator for the tab button in the tab strip.
    /// </summary>
    public ILocator TabButton()
        => Page.Locator(".lm_title").Filter(new() { HasTextString = _tabButtonText }).First;

    /// <summary>
    /// Determines whether the tab is currently visible.
    /// </summary>
    public async Task<bool> IsVisibleAsync()
    {
        var style = await Root.Locator("..").GetAttributeAsync("style");
        return style is null || !style.Contains("none");
    }
}
