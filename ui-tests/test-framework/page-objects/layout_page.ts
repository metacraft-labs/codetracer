import type { Locator, Page } from "@playwright/test";

export class BasePage {
  readonly page: Page;

  constructor(page: Page) {
    this.page = page;
  }
}

/** Representation of a generic tab. */
export class TabObject {
  readonly page: Page;
  readonly root: Locator;
  tabButtonText: string;

  constructor(page: Page, root: Locator, tabButtonText: string) {
    this.page = page;
    this.root = root;
    this.tabButtonText = tabButtonText;
  }

  tabButton(): Locator {
    // search within the group for the button text just like the Nim helper
    return this.page.locator(".lm_title", { hasText: this.tabButtonText }).first();
  }

  async isVisible(): Promise<boolean> {
    const style = await this.root.locator("..").getAttribute("style");
    return !(style?.includes("none"));
  }
}

/** Single program state variable entry. */
export class ProgramStateVariable {
  readonly page: Page;
  readonly root: Locator;

  constructor(page: Page, root: Locator) {
    this.page = page;
    this.root = root;
  }

  async name(): Promise<string> {
    return (await this.root.locator(".value-name").textContent()) ?? "";
  }

  async valueType(): Promise<string> {
    return (await this.root.locator(".value-type").textContent()) ?? "";
  }

  async value(): Promise<string> {
    return (
      (await this.root.locator(".value-expanded-text").getAttribute("textContent")) ??
      ""
    );
  }
}

/** Program state panel tab. */
export class ProgramStateTab extends TabObject {
  private variables: ProgramStateVariable[] = [];

  watchExpressionTextBox(): Locator {
    return this.root.locator("#watch");
  }

  async programStateVariables(forceReload = false): Promise<ProgramStateVariable[]> {
    if (forceReload || this.variables.length === 0) {
      const locators = await this.root.locator(".value-expanded").all();
      this.variables = locators.map((l) => new ProgramStateVariable(this.page, l));
    }
    return this.variables;
  }
}

export enum EventElementType {
  NotSet,
  EventLog,
  TracePointEditor,
}

/** Row in an event log like table. */
export class EventElement {
  readonly page: Page;
  readonly root: Locator;
  readonly elementType: EventElementType;

  constructor(page: Page, root: Locator, elementType: EventElementType) {
    this.page = page;
    this.root = root;
    this.elementType = elementType;
  }

  async tickCount(): Promise<number> {
    const text = await this.root.locator(".rr-ticks-time").textContent();
    return parseInt(text ?? "0", 10);
  }

  async index(): Promise<number> {
    const text = await this.root.locator(".eventLog-index").textContent();
    return parseInt(text ?? "0", 10);
  }

  async consoleOutput(): Promise<string> {
    let selector = ".eventLog-text";
    if (this.elementType === EventElementType.TracePointEditor) {
      selector = "td.trace-values";
      return (
        (await this.root.locator(selector).getAttribute("innerHTML")) ?? ""
      );
    }
    return (await this.root.locator(selector).textContent()) ?? "";
  }
}

/** Event log tab containing event elements. */
export class EventLogTab extends TabObject {
  private events: EventElement[] = [];

  autoScrollButton(): Locator {
    return this.root.locator(".checkmark");
  }

  footerContainer(): Locator {
    return this.root.locator(".data-tables-footer");
  }

  rowsInfoContainer(): Locator {
    return this.footerContainer().locator(".data-tables-footer-info");
  }

  async rows(): Promise<number> {
    const klass = await this.footerContainer().getAttribute("class");
    const m = klass?.match(/(\d*)to/);
    return m ? parseInt(m[1], 10) : 0;
  }

  async toRow(): Promise<number> {
    const text = await this.rowsInfoContainer().textContent();
    const m = text?.match(/(\d*)\sof/);
    return m ? parseInt(m[1], 10) : 0;
  }

  async ofRows(): Promise<number> {
    const text = await this.rowsInfoContainer().textContent();
    const m = text?.match(/of\s(\d*)/);
    return m ? parseInt(m[1], 10) : 0;
  }

  private async eventElementRoots(): Promise<Locator[]> {
    return await this.root.locator(".eventLog-dense-table tbody tr").all();
  }

  async eventElements(forceReload = false): Promise<EventElement[]> {
    if (forceReload || this.events.length === 0) {
      const locators = await this.eventElementRoots();
      this.events = locators.map((l) =>
        new EventElement(this.page, l, EventElementType.EventLog),
      );
    }
    return this.events;
  }
}

/** Visible text row inside an editor. */
export class TextRow {
  readonly page: Page;
  readonly root: Locator;

  constructor(page: Page, root: Locator) {
    this.page = page;
    this.root = root;
  }
}

/** Editor tab hosting a file. */
export class EditorTab extends TabObject {
  filePath = "";
  fileName = "";
  idNumber = -1;

  constructor(page: Page, root: Locator, tabButtonText: string) {
    super(page, root, tabButtonText);
  }

  editorLinesRoot(): Locator {
    return this.root.locator(".view-lines");
  }

  gutterRoot(): Locator {
    return this.root.locator(".margin-view-overlays");
  }

  async highlightedLineNumber(): Promise<number> {
    const count = await this.root.locator(".on").count();
    if (count > 0) {
      const classes = await this.root.locator(".on").first().getAttribute("class");
      const m = classes?.match(/on-(\d*)/);
      if (m) return parseInt(m[1], 10);
    }
    return -1;
  }

  async visibleTextRows(): Promise<TextRow[]> {
    const locators = await this.root.locator(".view-line").all();
    return locators.map((l) => new TextRow(this.page, l));
  }
}

/** Tracepoint editor embedded in an editor tab. */
export class TracePointEditor {
  readonly parentEditorTab: EditorTab;
  readonly lineNumber: number;

  constructor(parentEditorTab: EditorTab, lineNumber: number) {
    this.parentEditorTab = parentEditorTab;
    this.lineNumber = lineNumber;
  }

  root(): Locator {
    return this.parentEditorTab.root.locator(
      `xpath=//*[@id='edit-trace-${this.parentEditorTab.idNumber}-${this.lineNumber}']/ancestor::*[@class='trace']`,
    );
  }

  editTextBox(): Locator {
    return this.root().locator("textarea");
  }

  async eventElements(forceReload = false): Promise<EventElement[]> {
    const locators = await this.root().locator(".trace-view tbody tr").all();
    return locators.map((l) =>
      new EventElement(this.parentEditorTab.page, l, EventElementType.TracePointEditor),
    );
  }
}

/** Main layout page that holds all tabs and menu elements. */
export class LayoutPage extends BasePage {
  private eventLogTabsCache: EventLogTab[] = [];
  private editorTabsCache: EditorTab[] = [];
  private programStateTabsCache: ProgramStateTab[] = [];

  runToEntryButton(): Locator {
    return this.page.locator("#run-to-entry-debug");
  }
  continueButton(): Locator {
    return this.page.locator("#continue-debug");
  }
  reverseContinueButton(): Locator {
    return this.page.locator("#reverse-continue-debug");
  }
  stepOutButton(): Locator {
    return this.page.locator("#step-out-debug");
  }
  reverseStepOutButton(): Locator {
    return this.page.locator("#reverse-step-out-debug");
  }
  stepInButton(): Locator {
    return this.page.locator("#step-in-debug");
  }
  reverseStepInButton(): Locator {
    return this.page.locator("#reverse-step-in-debug");
  }
  nextButton(): Locator {
    return this.page.locator("#next-debug");
  }
  reverseNextButton(): Locator {
    return this.page.locator("#reverse-next-debug");
  }

  async eventLogTabs(forceReload = false): Promise<EventLogTab[]> {
    if (forceReload || this.eventLogTabsCache.length === 0) {
      const roots = await this.page.locator("div[id^='eventLogComponent-']").all();
      this.eventLogTabsCache = roots.map((r) => new EventLogTab(this.page, r, "EVENT LOG"));
    }
    return this.eventLogTabsCache;
  }

  async programStateTabs(forceReload = false): Promise<ProgramStateTab[]> {
    if (forceReload || this.programStateTabsCache.length === 0) {
      const roots = await this.page.locator("div[id^='stateComponent-']").all();
      this.programStateTabsCache = roots.map((r) => new ProgramStateTab(this.page, r, "STATE"));
    }
    return this.programStateTabsCache;
  }

  async editorTabs(forceReload = false): Promise<EditorTab[]> {
    if (forceReload || this.editorTabsCache.length === 0) {
      const roots = await this.page.locator("div[id^='editorComponent-']").all();
      const tabs: EditorTab[] = [];
      for (const r of roots) {
        const idAttr = (await r.getAttribute("id")) ?? "";
        const tab = new EditorTab(this.page, this.page.locator(`#${idAttr}`), "");
        const m = idAttr.match(/(\d)/);
        if (m) tab.idNumber = parseInt(m[1], 10);
        tab.filePath = (await tab.root.getAttribute("data-label")) ?? "";
        const fileNameMatch = tab.filePath.match(/([^/]+)$/);
        tab.fileName = fileNameMatch ? fileNameMatch[1] : "";
        const tabButtonMatch = tab.filePath.match(/[^/]*\/(?!\/)(?:.(?!\/))+$/);
        tab.tabButtonText = tabButtonMatch ? tabButtonMatch[0] : tab.fileName;
        tabs.push(tab);
      }
      this.editorTabsCache = tabs;
    }
    return this.editorTabsCache;
  }
}

