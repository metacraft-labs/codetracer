using System.Collections.Generic;
using System.Linq;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using Microsoft.Playwright;
using UiTests.PageObjects.Panes.EventLog;
using UiTests.PageObjects.Panes.VariableState;
using UiTests.PageObjects.Panes.CallTrace;
using UiTests.PageObjects.Panes.Editor;
using UiTests.Utils;

namespace UiTests.PageObjects;

/// <summary>
/// Main layout page that contains all tabs and menu elements.
/// </summary>
public class LayoutPage : BasePage
{
    private List<EventLogPane> _eventLogTabs = new();
    private List<VariableStatePane> _programStateTabs = new();
    private List<EditorPane> _editorTabs = new();

    public LayoutPage(IPage page) : base(page) { }

    public Task WaitForFilesystemLoadedAsync() =>
        RetryHelpers.RetryAsync(async () =>
            await Page.Locator("div[id^='filesystemComponent-']").CountAsync() > 0);

    public Task WaitForStateLoadedAsync() =>
        RetryHelpers.RetryAsync(async () =>
            await Page.Locator("div[id^='stateComponent-']").CountAsync() > 0);

    public Task WaitForCallTraceLoadedAsync() =>
        RetryHelpers.RetryAsync(async () =>
            await Page.Locator("div[id^='calltraceComponent-']").CountAsync() > 0);

    public Task WaitForEventLogLoadedAsync() =>
        RetryHelpers.RetryAsync(async () =>
            await Page.Locator("div[id^='eventLogComponent-']").CountAsync() > 0);

    public Task WaitForEditorLoadedAsync() =>
        RetryHelpers.RetryAsync(async () =>
            await Page.Locator("div[id^='editorComponent-']").CountAsync() > 0);

    public Task WaitForAllComponentsLoadedAsync()
    {
        var waits = new[]
        {
            // WaitForFilesystemLoadedAsync(),
            // WaitForStateLoadedAsync(),
            // WaitForCallTraceLoadedAsync(),
            // WaitForEventLogLoadedAsync(),
            WaitForEditorLoadedAsync()
        };
        return Task.WhenAll(waits);
    }

    #region Debug Buttons
    public ILocator RunToEntryButton() => Page.Locator("#run-to-entry-debug");
    public ILocator ContinueButton() => Page.Locator("#continue-debug");
    public ILocator ReverseContinueButton() => Page.Locator("#reverse-continue-debug");
    public ILocator StepOutButton() => Page.Locator("#step-out-debug");
    public ILocator ReverseStepOutButton() => Page.Locator("#reverse-step-out-debug");
    public ILocator StepInButton() => Page.Locator("#step-in-debug");
    public ILocator ReverseStepInButton() => Page.Locator("#reverse-step-in-debug");
    public ILocator NextButton() => Page.Locator("#next-debug");
    public ILocator ReverseNextButton() => Page.Locator("#reverse-next-debug");
    #endregion

    public async Task<IReadOnlyList<EventLogPane>> EventLogTabsAsync(bool forceReload = false)
    {
        if (forceReload || _eventLogTabs.Count == 0)
        {
            var roots = await Page.Locator("div[id^='eventLogComponent-']").AllAsync();
            _eventLogTabs = roots.Select(r => new EventLogPane(Page, r, "EVENT LOG")).ToList();
        }
        return _eventLogTabs;
    }

    public async Task<IReadOnlyList<VariableStatePane>> ProgramStateTabsAsync(bool forceReload = false)
    {
        if (forceReload || _programStateTabs.Count == 0)
        {
            var roots = await Page.Locator("div[id^='stateComponent-']").AllAsync();
            _programStateTabs = roots.Select(r => new VariableStatePane(Page, r, "STATE")).ToList();
        }
        return _programStateTabs;
    }

    public async Task<IReadOnlyList<EditorPane>> EditorTabsAsync(bool forceReload = false)
    {
        if (forceReload || _editorTabs.Count == 0)
        {
            var roots = await Page.Locator("div[id^='editorComponent-']").AllAsync();
            var tabs = new List<EditorPane>();
            foreach (var r in roots)
            {
                var idAttr = await r.GetAttributeAsync("id") ?? string.Empty;
                var filePath = await r.GetAttributeAsync("data-label") ?? string.Empty;
                var segments = filePath.Split('/', System.StringSplitOptions.RemoveEmptyEntries);
                var fileName = segments.LastOrDefault() ?? string.Empty;
                var tabButtonText = string.Join('/', segments.TakeLast(2));
                var idMatch = Regex.Match(idAttr, @"(\d+)");
                var idNumber = idMatch.Success ? int.Parse(idMatch.Groups[1].Value) : -1;
                var paneRoot = Page.Locator($"#{idAttr}");
                var pane = new EditorPane(Page, paneRoot, tabButtonText, idNumber, filePath, fileName);
                tabs.Add(pane);
            }
            _editorTabs = tabs;
        }
        return _editorTabs;
    }

    public ILocator MenuRootButton() => Page.Locator("#menu-root-name");
    public ILocator MenuSearchTextBox() => Page.Locator("#menu-search-text");

}
