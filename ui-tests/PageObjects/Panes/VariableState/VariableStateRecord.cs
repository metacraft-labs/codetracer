using System.Threading.Tasks;
using Microsoft.Playwright;

namespace UtTestsExperimentalConsoleAppication.PageObjects.Panes.VariableState;

/// <summary>
/// Represents a single variable entry in the Program State pane.
/// </summary>
public class VariableStateRecord
{
    private readonly ILocator _root;

    public VariableStateRecord(ILocator root)
    {
        _root = root;
    }

    public Task<string?> NameAsync()
        => _root.Locator(".value-name").TextContentAsync();

    public Task<string?> ValueTypeAsync()
        => _root.Locator(".value-type").TextContentAsync();

    public Task<string?> ValueAsync()
        => _root.Locator(".value-expanded-text").GetAttributeAsync("textContent");
}
