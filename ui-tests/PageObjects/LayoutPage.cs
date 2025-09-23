using System.Collections.Generic;
using System.Linq;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using Microsoft.Playwright;
using UiTests.PageObjects.Panes.EventLog;
using UiTests.PageObjects.Panes.VariableState;
using UiTests.PageObjects.Panes.CallTrace;
using UiTests.PageObjects.Panes.Editor;
using UiTests.PageObjects.Panes.Filesystem;
using UiTests.PageObjects.Panes.Terminal;
using UiTests.PageObjects.Panes.Scratchpad;
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
    private List<CallTracePane> _callTraceTabs = new();
    private List<FilesystemPane> _filesystemTabs = new();
    private List<TerminalOutputPane> _terminalTabs = new();
    private List<ScratchpadPane> _scratchpadTabs = new();

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

    public Task WaitForTerminalLoadedAsync() =>
        RetryHelpers.RetryAsync(async () =>
            await Page.Locator("div[id^='terminalComponent-']").CountAsync() > 0);

    public Task WaitForScratchpadLoadedAsync() =>
        RetryHelpers.RetryAsync(async () =>
            await Page.Locator("div[id^='scratchpadComponent-']").CountAsync() > 0);

    public Task WaitForEditorLoadedAsync() =>
        RetryHelpers.RetryAsync(async () =>
            await Page.Locator("div[id^='editorComponent-']").CountAsync() > 0);

    public async Task WaitForAllComponentsLoadedAsync()
    {
        // TODO: improve wait
        await Task.Delay(5000);
        var waits = new[]
        {
            // WaitForFilesystemLoadedAsync(),
            // WaitForStateLoadedAsync(),
            // WaitForCallTraceLoadedAsync(),
            // WaitForEventLogLoadedAsync(),
            WaitForEditorLoadedAsync()
        };
        await Task.WhenAll(waits);
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

    public async Task<IReadOnlyList<CallTracePane>> CallTraceTabsAsync(bool forceReload = false)
    {
        if (forceReload || _callTraceTabs.Count == 0)
        {
            var roots = await Page.Locator("div[id^='calltraceComponent-']").AllAsync();
            _callTraceTabs = roots.Select(r => new CallTracePane(Page, r, "PROGRAM CALL TRACE")).ToList();
        }

        return _callTraceTabs;
    }

    public async Task<IReadOnlyList<FilesystemPane>> FilesystemTabsAsync(bool forceReload = false)
    {
        if (forceReload || _filesystemTabs.Count == 0)
        {
            var roots = await Page.Locator("div[id^='filesystemComponent-']").AllAsync();
            _filesystemTabs = roots.Select(r => new FilesystemPane(Page, r, "FILE EXPLORER")).ToList();
        }

        return _filesystemTabs;
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

    public async Task<IReadOnlyList<TerminalOutputPane>> TerminalTabsAsync(bool forceReload = false)
    {
        if (forceReload || _terminalTabs.Count == 0)
        {
            var roots = await Page.Locator("div[id^='terminalComponent-']").AllAsync();
            _terminalTabs = roots.Select(r => new TerminalOutputPane(Page, r, "TERMINAL OUTPUT")).ToList();
        }

        return _terminalTabs;
    }

    public async Task<IReadOnlyList<ScratchpadPane>> ScratchpadTabsAsync(bool forceReload = false)
    {
        if (forceReload || _scratchpadTabs.Count == 0)
        {
            var roots = await Page.Locator("div[id^='scratchpadComponent-']").AllAsync();
            _scratchpadTabs = roots.Select(r => new ScratchpadPane(Page, r, "SCRATCHPAD")).ToList();
        }

        return _scratchpadTabs;
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
