/**
 * New File from a "+" welcome tab while a replay is open (issue #835).
 *
 * Reported flow (Electron desktop): open a trace, click the session tab
 * bar's "+", and on the new tab's welcome screen click "New file". Monaco
 * then reports `Element already has context attribute: editor, code-editor,
 * tab` from its `ScopedContextKeyService`, and the new tab's editor area is
 * blank. The same flow with no replay open works.
 *
 * What the specs require:
 *   - `GUI/Multi-Window-Tab-Management.md` §Tab Behavior: each tab is an
 *     independent session (rule 3: choosing a welcome option turns the "+"
 *     tab into the session it starts; rule 6: tab state is preserved across
 *     switches).
 *   - `GUI/Welcome-And-Sessions/Welcome-Screen.md` §"New file, and what it
 *     creates": one empty editor tab named `#untitled{N}`, in Edit mode.
 *
 * So this spec asserts, in order:
 *   (a) no page error or console message carrying Monaco's "already has
 *       context attribute" error — captured by `page.on("pageerror")` and a
 *       console listener, not eyeballed;
 *   (b) the NEW (active) tab's session container holds a visible Monaco
 *       editor for the `#untitled…` buffer, and typing into it lands in that
 *       editor's model (writable, not read-only);
 *   (c) switching back to the replay tab shows its own Monaco editor still
 *       attached to the document, inside the replay's session container, and
 *       still showing the traced source.
 *
 * No mocks: this drives the real Electron app against a real recorded
 * Python trace (`py_console_logs/main.py`). The defect is in how two
 * sessions' DOM hosts and Monaco instances coexist, which only the real
 * renderer with GoldenLayout and Monaco can show — no headless ViewModel
 * owns Monaco host placement.
 */

import type { Page } from "@playwright/test";
import { test, expect } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";
import { retry } from "../../lib/retry-helpers";

/** Monaco's own wording for a second editor built on an occupied host. */
const CONTEXT_ATTRIBUTE_ERROR = /already has context attribute/i;

interface MonacoEditorProbe {
  /** Index of the `session-container-<n>` that holds the editor, or -1. */
  sessionIndex: number;
  /** Whether the editor's DOM node is still attached to the document. */
  attached: boolean;
  /** Whether the editor's DOM node is laid out (non-zero size). */
  visible: boolean;
  readOnly: boolean;
  /** Model URI / value, so the caller can tell which buffer it is. */
  uri: string;
  value: string;
  /** The `data-label` of the enclosing `editorComponent-*` host, if any. */
  hostLabel: string;
}

/**
 * Describe every live Monaco code editor on the page, tagged with the
 * session container it sits in. A missing `window.monaco` is a FAILURE by
 * name, not an empty list — an empty list would read as "no editor", which
 * is what the bug looks like.
 */
async function probeMonacoEditors(page: Page): Promise<MonacoEditorProbe[]> {
  return page.evaluate(() => {
    const monaco = (window as any).monaco;
    if (!monaco?.editor?.getEditors) {
      throw new Error("window.monaco.editor.getEditors is unavailable: the frontend bundle did not load Monaco");
    }
    return (monaco.editor.getEditors() as any[]).map((ed) => {
      const node = ed.getDomNode?.() as HTMLElement | null;
      const container = node?.closest?.("[id^='session-container-']") as HTMLElement | null;
      const host = node?.closest?.("[id^='editorComponent']") as HTMLElement | null;
      const rect = node?.getBoundingClientRect?.();
      const model = ed.getModel?.();
      const readOnlyOption = monaco.editor.EditorOption?.readOnly;
      return {
        sessionIndex: container ? Number(container.id.replace("session-container-", "")) : -1,
        attached: !!node && document.contains(node),
        visible: !!rect && rect.width > 0 && rect.height > 0,
        readOnly: readOnlyOption !== undefined ? !!ed.getOption(readOnlyOption) : false,
        uri: model ? String(model.uri) : "",
        value: model ? String(model.getValue()) : "",
        hostLabel: host?.getAttribute("data-label") ?? "",
      };
    });
  });
}

/**
 * What the replay tab shows, pane by pane, so the same snapshot taken after
 * switching back can be compared field for field (rule 6: tab state is
 * preserved across switches).
 *
 * Pane contents are read inside `#session-container-0` only, by each pane's
 * GoldenLayout label — the id its host carries — and with `textContent`, not
 * `innerText`, so a pane in a background GoldenLayout tab (display: none) is
 * still compared. Whitespace is collapsed: re-rendering may re-indent.
 * The event log is the one exception: it is a virtualised table whose
 * RENDER WINDOW (how many rows exist in the DOM beyond the visible ones) and
 * scroll extent follow its last viewport measurement, not the tab's state.
 * Measured on this flow: 18 rows rendered and a 10260 px scroll extent before
 * "+", 27 rows and 756 px after — with the same 14 rows on screen, the same
 * scroll position and the same paging footer. So for it the snapshot keeps
 * what the user sees: the rows inside its scroll box, and the footer.
 * Session state that is not a pane (mode, read-only, debugger position) is
 * read from the replay's own `ReplaySession`, not through the forwarding
 * getters, which follow whichever tab is active.
 */
const REPLAY_PANE_LABELS = [
  "filesystemComponent",
  "vCSComponent-0",
  "stateComponent-0",
  "scratchpadComponent-0",
  "calltraceComponent-0",
  "eventLogComponent-0",
  "terminalComponent-0",
  "testResultsComponent-0",
  "constraintsComponent-0",
  "agentActivityComponent-0",
];

async function snapshotReplayTab(page: Page): Promise<Record<string, unknown>> {
  return page.evaluate((labels: string[]) => {
    // Relative commit ages in the VCS pane ("5h" before "View Commit") are
    // wall-clock readings and roll over during a run; they are not tab state.
    const norm = (s: string | null | undefined) =>
      (s ?? "")
        .replace(/\s+/g, " ")
        .replace(/\d+(?:s|m|h|d|w|mo|y)(?= ?View Commit)/g, "<age>")
        .trim();
    const container = document.getElementById("session-container-0");
    if (!container) throw new Error("session-container-0 is missing: the replay tab's container is gone");
    const panes: Record<string, string> = {};
    // The event log's visible rows: those whose box intersects the box of
    // the scrolling element that clips them. A pane in a background
    // GoldenLayout tab has no boxes and yields none, before and after alike.
    const visibleEventRows = (host: Element): string => {
      const rows = (Array.from(host.querySelectorAll("tr")) as HTMLElement[])
        .filter((r) => /stdout|stderr/.test(r.textContent ?? ""));
      let scroller: HTMLElement | null = rows[0]?.parentElement ?? null;
      while (scroller && scroller !== host &&
             !/(auto|scroll|hidden)/.test(getComputedStyle(scroller).overflowY)) {
        scroller = scroller.parentElement;
      }
      const clip = (scroller ?? (host as HTMLElement)).getBoundingClientRect();
      const shown = rows.filter((r) => {
        const b = r.getBoundingClientRect();
        return b.height > 0 && b.bottom > clip.top && b.top < clip.bottom;
      });
      const footer = host.querySelector(".dt-info, [class*='info']");
      return JSON.stringify({
        rows: shown.map((r) => norm(r.textContent)),
        footer: norm(footer?.textContent),
      });
    };
    for (const label of labels) {
      const host = container.querySelector(`[id="${label}"]`);
      panes[label] = !host
        ? "<absent>"
        : label.startsWith("eventLogComponent")
          ? visibleEventRows(host)
          : norm(host.textContent);
    }
    const d = (window as any).data;
    const replay = d?.sessions?.[0];
    const loc = replay?.services?.debugger?.location;
    return {
      panes,
      editors: Array.from(container.querySelectorAll("[id^='editorComponent']"))
        .map((el) => (el as HTMLElement).getAttribute("data-label") ?? "")
        .sort(),
      status: norm(document.getElementById("status-base")?.textContent),
      mode: Number(replay?.ui?.mode),
      readOnly: Boolean(replay?.ui?.readOnly),
      traceLoaded: replay?.trace != null,
      debugger: loc
        ? { path: String(loc.path ?? ""), line: Number(loc.line), rrTicks: Number(loc.rrTicks) }
        : null,
    };
  }, REPLAY_PANE_LABELS);
}

/** Poll until two consecutive snapshots agree, so asynchronous pane mounts
 *  that are still arriving are not mistaken for state. */
async function settledReplaySnapshot(page: Page): Promise<Record<string, unknown>> {
  let previous = JSON.stringify(await snapshotReplayTab(page));
  for (let i = 0; i < 30; i++) {
    await page.waitForTimeout(1000);
    const current = JSON.stringify(await snapshotReplayTab(page));
    if (current === previous) return JSON.parse(current);
    previous = current;
  }
  throw new Error(`the replay tab never settled; last snapshot: ${previous}`);
}

async function activeSessionIndex(page: Page): Promise<number> {
  return page.evaluate(() => (window as any).data?.activeSessionIndex ?? -1);
}

test.describe("New File from a + tab with a replay open (#835)", () => {
  test.setTimeout(240_000);
  test.use({ sourcePath: "py_console_logs/main.py", launchMode: "trace" });

  test("the new tab gets its own writable untitled editor and the replay editor survives", async ({ ctPage }) => {
    // (a) Capture Monaco's context-attribute error from the very start, both
    // as a thrown page error and as a logged console message.
    const contextAttributeErrors: string[] = [];
    const allErrors: string[] = [];
    ctPage.on("pageerror", (error) => {
      const text = `${error.message}\n${error.stack ?? ""}`;
      allErrors.push(`[pageerror] ${text}`);
      if (CONTEXT_ATTRIBUTE_ERROR.test(text)) contextAttributeErrors.push(`[pageerror] ${text}`);
    });
    ctPage.on("console", (msg) => {
      const text = msg.text();
      if (msg.type() === "error") allErrors.push(`[console.error] ${text}`);
      if (CONTEXT_ATTRIBUTE_ERROR.test(text)) contextAttributeErrors.push(`[console.${msg.type()}] ${text}`);
    });

    // 1. The replay: wait for the trace and its editor to be fully up.
    const layout = new LayoutPage(ctPage);
    await layout.waitForTraceLoaded();
    await layout.waitForEditorLoaded();
    expect(await activeSessionIndex(ctPage)).toBe(0);

    let replayEditorsBefore: MonacoEditorProbe[] = [];
    await retry(
      async () => {
        replayEditorsBefore = (await probeMonacoEditors(ctPage)).filter(
          (e) => e.sessionIndex === 0 && e.attached && e.value.length > 0,
        );
        return replayEditorsBefore.length > 0;
      },
      { maxAttempts: 60, delayMs: 500 },
    );
    expect(replayEditorsBefore.length, "the replay tab has a Monaco editor with source").toBeGreaterThan(0);
    const replaySource = replayEditorsBefore[0].value;
    const replayUri = replayEditorsBefore[0].uri;

    // Rule 6 baseline: everything the replay tab shows, before "+".
    await layout.waitForAllComponentsLoaded();
    const replayBefore = await settledReplaySnapshot(ctPage);

    // 2. "+" opens a new tab on the welcome screen.
    await ctPage.locator(".session-tab-add").click();
    await retry(async () => (await activeSessionIndex(ctPage)) === 1, { maxAttempts: 40, delayMs: 250 });
    expect(await activeSessionIndex(ctPage)).toBe(1);
    const newFileOption = ctPage.locator(".start-option.new-file");
    await expect(newFileOption).toBeVisible({ timeout: 15_000 });

    // 3. New File on the new tab's welcome screen.
    await newFileOption.click();
    await expect(ctPage.locator(".welcome-screen")).toBeHidden({ timeout: 15_000 });
    expect(await activeSessionIndex(ctPage)).toBe(1);

    // (b) A visible, writable Monaco editor for the untitled buffer, inside
    // the NEW tab's session container.
    let untitled: MonacoEditorProbe | undefined;
    await retry(
      async () => {
        untitled = (await probeMonacoEditors(ctPage)).find(
          (e) => e.sessionIndex === 1 && e.attached && e.visible && /untitled/i.test(`${e.uri} ${e.hostLabel}`),
        );
        return untitled !== undefined;
      },
      { maxAttempts: 60, delayMs: 500 },
    ).catch(() => undefined);
    const editorsAfterNewFile = await probeMonacoEditors(ctPage);
    expect(
      contextAttributeErrors,
      `Monaco reported a second editor on an occupied host. All errors:\n${allErrors.join("\n")}`,
    ).toEqual([]);
    expect(
      untitled,
      `no visible #untitled Monaco editor in session-container-1; editors: ${JSON.stringify(
        editorsAfterNewFile.map(({ value, ...rest }) => ({ ...rest, valueLength: value.length })),
      )}`,
    ).toBeDefined();
    expect(untitled!.readOnly, "the untitled buffer is writable").toBe(false);
    expect(untitled!.value, "the untitled buffer starts empty").toBe("");

    const typed = "typed_into_untitled_835";
    const untitledEditorNode = ctPage
      .locator("#session-container-1 .monaco-editor")
      .filter({ has: ctPage.locator(".view-lines") })
      .first();
    await untitledEditorNode.click();
    await ctPage.keyboard.type(typed);
    await retry(
      async () =>
        (await probeMonacoEditors(ctPage)).some(
          (e) => e.sessionIndex === 1 && /untitled/i.test(`${e.uri} ${e.hostLabel}`) && e.value.includes(typed),
        ),
      { maxAttempts: 20, delayMs: 250 },
    ).catch(() => undefined);
    const afterTyping = await probeMonacoEditors(ctPage);
    expect(
      afterTyping.some(
        (e) => e.sessionIndex === 1 && /untitled/i.test(`${e.uri} ${e.hostLabel}`) && e.value.includes(typed),
      ),
      "typing lands in the untitled buffer of the new tab",
    ).toBe(true);
    // The keystrokes did not land in the replay's editor either.
    expect(
      afterTyping.filter((e) => e.uri === replayUri).every((e) => !e.value.includes(typed)),
      "typing did not leak into the replay's editor",
    ).toBe(true);

    // (c) Back to the replay tab: its editor is still attached, still in its
    // own session container, and still shows the traced source.
    await ctPage.locator(".session-tab").first().click();
    await retry(async () => (await activeSessionIndex(ctPage)) === 0, { maxAttempts: 40, delayMs: 250 });
    expect(await activeSessionIndex(ctPage)).toBe(0);

    let replayEditorAfter: MonacoEditorProbe | undefined;
    await retry(
      async () => {
        replayEditorAfter = (await probeMonacoEditors(ctPage)).find(
          (e) => e.sessionIndex === 0 && e.attached && e.visible && e.uri === replayUri,
        );
        return replayEditorAfter !== undefined;
      },
      { maxAttempts: 40, delayMs: 250 },
    ).catch(() => undefined);
    expect(replayEditorAfter, "the replay tab's Monaco editor is attached and visible after switching back").toBeDefined();
    expect(replayEditorAfter!.value).toBe(replaySource);
    await expect(ctPage.locator("#session-container-0 .monaco-editor .view-lines").first()).toBeVisible();

    // Rule 6: every replay pane, the status bar, the mode, read-only state and
    // debugger position are as they were before "+". Polled first so a pane
    // still re-rendering after the switch gets its chance to settle back.
    let replayAfter: Record<string, unknown> = {};
    await retry(
      async () => {
        replayAfter = await snapshotReplayTab(ctPage);
        return JSON.stringify(replayAfter) === JSON.stringify(replayBefore);
      },
      { maxAttempts: 20, delayMs: 500 },
    ).catch(() => undefined);
    expect(replayAfter, "the replay tab is unchanged after New File in another tab").toEqual(replayBefore);

    expect(
      contextAttributeErrors,
      `Monaco reported a second editor on an occupied host. All errors:\n${allErrors.join("\n")}`,
    ).toEqual([]);
  });
});
