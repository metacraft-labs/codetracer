using System.Collections.Generic;
using System.Linq;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using Microsoft.Playwright;
using UtTestsExperimentalConsoleAppication.PageObjects.Panes.EventLog;
using UtTestsExperimentalConsoleAppication.PageObjects.Panes.VariableState;
using UtTestsExperimentalConsoleAppication.PageObjects.Panes.CallTrace;

namespace UtTestsExperimentalConsoleAppication.PageObjects;

/// <summary>
/// Main layout page that contains all tabs and menu elements.
/// </summary>
public class LayoutPage : BasePage
{
    private List<EventLogPane> _eventLogTabs = new();
    private List<VariableStatePane> _programStateTabs = new();
    private List<EditorTab> _editorTabs = new();

    public LayoutPage(IPage page) : base(page) { }

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

    public async Task<IReadOnlyList<EditorTab>> EditorTabsAsync(bool forceReload = false)
    {
        if (forceReload || _editorTabs.Count == 0)
        {
            var roots = await Page.Locator("div[id^='editorComponent-']").AllAsync();
            var tabs = new List<EditorTab>();
            foreach (var r in roots)
            {
                var idAttr = await r.GetAttributeAsync("id") ?? string.Empty;
                var tab = new EditorTab(Page, Page.Locator($"#{idAttr}"), "");
                var m = Regex.Match(idAttr, @"(\d+)");
                if (m.Success) tab.IdNumber = int.Parse(m.Groups[1].Value);
                tab.FilePath = await tab.Root.GetAttributeAsync("data-label") ?? string.Empty;
                var segments = tab.FilePath.Split('/', System.StringSplitOptions.RemoveEmptyEntries);
                tab.FileName = segments.LastOrDefault() ?? string.Empty;
                tab.TabButtonText = string.Join('/', segments.TakeLast(2));
                tabs.Add(tab);
            }
            _editorTabs = tabs;
        }
        return _editorTabs;
    }

    public ILocator MenuRootButton() => Page.Locator("#menu-root-name");
    public ILocator MenuSearchTextBox() => Page.Locator("#menu-search-text");

    #region Nested types
    public class TextRow
    {
        public TextRow(IPage page, ILocator root)
        {
            Page = page;
            Root = root;
        }
        public IPage Page { get; }
        public ILocator Root { get; }
    }

    public class EditorTab : TabObject
    {
        public EditorTab(IPage page, ILocator root, string tabButtonText) : base(page, root, tabButtonText) { }

        public string FilePath { get; set; } = string.Empty;
        public string FileName { get; set; } = string.Empty;
        public string TabButtonText { get; set; } = string.Empty;
        public int IdNumber { get; set; } = -1;

        public ILocator EditorLinesRoot() => Root.Locator(".view-lines");
        public ILocator GutterRoot() => Root.Locator(".margin-view-overlays");

        public async Task<int> HighlightedLineNumberAsync()
        {
            if (await Root.Locator(".on").CountAsync() > 0)
            {
                var classes = await Root.Locator(".on").First.GetAttributeAsync("class");
                var m = Regex.Match(classes ?? string.Empty, @"on-(\d+)");
                if (m.Success) return int.Parse(m.Groups[1].Value);
            }
            return -1;
        }

        public async Task<IReadOnlyList<TextRow>> VisibleTextRowsAsync()
        {
            var locators = await Root.Locator(".view-line").AllAsync();
            return locators.Select(l => new TextRow(Page, l)).ToList();
        }
    }

    public class TracePointEditor
    {
        public TracePointEditor(EditorTab parentEditorTab, int lineNumber)
        {
            ParentEditorTab = parentEditorTab;
            LineNumber = lineNumber;
        }

        public EditorTab ParentEditorTab { get; }
        public int LineNumber { get; }

        public ILocator Root => ParentEditorTab.Root.Locator($"xpath=//*[@id='edit-trace-{ParentEditorTab.IdNumber}-{LineNumber}']/ancestor::*[@class='trace']");

        public ILocator EditTextBox => Root.Locator("textarea");

        public async Task<IReadOnlyList<EventRow>> EventElementsAsync(bool forceReload = false)
        {
            var locators = await Root.Locator(".trace-view tbody tr").AllAsync();
            return locators.Select(l => new EventRow(l, EventElementType.TracePointEditor)).ToList();
        }
    }
    #endregion
}
