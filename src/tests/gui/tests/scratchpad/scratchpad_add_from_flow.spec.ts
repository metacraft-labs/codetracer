/**
 * Regression test for #612 — adding an Omniscience inline value to the
 * Scratchpad must add it exactly once.
 *
 * The reported symptom was that clicking the `+` button on an inline flow
 * value appended the same value four times.  The cause was not the button:
 * `InternalAddToScratchpad` was delivered once per `ScratchpadComponent` that
 * had ever been registered, because the event bus had no unsubscribe path and
 * panels are destroyed and re-created routinely (closing a tab, a layout reset
 * on re-record, closing a session).  See
 * `src/frontend/tests/scratchpad_add_dispatch_test.nim` for the headless
 * counterpart of this test — per the headless-first policy that test is the
 * primary one, and this spec confirms the same invariant end to end.
 *
 * Both add gestures are covered because they funnel into the same sink:
 * Ctrl+click on the value, and the `+` button inside the hover popup.
 *
 * Assertions use `toBe`, deliberately.  `ScratchpadPane.waitForEntryCount`
 * asserts `>= count`, which is satisfied by the buggy behaviour — a test
 * written with it would have passed while the bug was present.
 */

import { test, expect } from "../../lib/fixtures";
import { retry } from "../../lib/retry-helpers";
import { LayoutPage } from "../../page-objects/layout-page";
import type { EditorPane } from "../../page-objects/panes/editor/editor-pane";
import type { FlowValue } from "../../page-objects/panes/editor/flow-value";
import type { ScratchpadPane } from "../../page-objects/panes/scratchpad/scratchpad-pane";

/**
 * Navigate to a source editor that renders inline flow values.
 *
 * Mirrors the navigation the Noir suite uses: pick the first event-log row so
 * the debugger lands inside traced code, then open the editor tab it brings
 * up.  We do not require a specific file — any editor showing a
 * scratchpad-capable flow value is enough for this test.
 */
async function openEditorWithFlowValues(layout: LayoutPage): Promise<EditorPane> {
  const eventLog = (await layout.eventLogTabs())[0];
  await eventLog.clickTab();
  const firstRow = await eventLog.rowByIndex(1, true);
  await firstRow.click();

  let editor: EditorPane | null = null;
  await retry(
    async () => {
      const editors = await layout.editorTabs(true);
      for (const candidate of editors) {
        await candidate.clickTab();
        const values = await candidate.flowValues();
        for (const value of values) {
          if (await value.supportsScratchpad()) {
            editor = candidate;
            return true;
          }
        }
      }
      return false;
    },
    { maxAttempts: 30, delayMs: 500 },
  );

  if (!editor) {
    throw new Error("No editor with scratchpad-capable flow values was found.");
  }
  return editor;
}

async function requireFlowValue(editor: EditorPane): Promise<FlowValue> {
  let target: FlowValue | null = null;
  await retry(
    async () => {
      const values = await editor.flowValues();
      for (const value of values) {
        if (await value.supportsScratchpad()) {
          target = value;
          return true;
        }
      }
      return false;
    },
    { maxAttempts: 30, delayMs: 300 },
  );
  if (!target) {
    throw new Error("No scratchpad-capable flow value is rendered.");
  }
  return target;
}

/**
 * Force the flow overlay to be torn down and rebuilt several times.
 *
 * The original report blamed accumulated DOM listeners on the `+` button, and
 * although that turned out not to be the mechanism, a fix must still hold
 * after the overlay has been re-rendered — so the test steps first.
 */
async function stepAround(layout: LayoutPage, times: number): Promise<void> {
  for (let i = 0; i < times; i += 1) {
    await layout.nextButton().dispatchEvent("click");
    await layout.page.waitForTimeout(300);
  }
}

async function emptyScratchpad(layout: LayoutPage): Promise<ScratchpadPane> {
  const scratchpad = (await layout.scratchpadTabs(true))[0];
  await scratchpad.clickTab();
  for (const entry of await scratchpad.entries(true)) {
    await entry.close();
  }
  await retry(async () => (await scratchpad.entryCount()) === 0);
  return scratchpad;
}

test.describe("Scratchpad add from flow", () => {
  test.setTimeout(120_000);
  test.use({ sourcePath: "noir_space_ship/", launchMode: "trace" });

  test("ctrl+click on a flow value adds exactly one entry", async ({
    ctPage,
  }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForAllComponentsLoaded();
    await layout.waitForTraceLoaded();

    const editor = await openEditorWithFlowValues(layout);
    await stepAround(layout, 3);

    const scratchpad = await emptyScratchpad(layout);

    await editor.clickTab();
    const value = await requireFlowValue(editor);
    await value.addToScratchpad();

    await retry(async () => (await scratchpad.entryCount()) > 0);
    // Deliberately `toBe`: the bug produced 4 entries, which every `>=`
    // assertion in the existing helpers would have accepted.
    expect(await scratchpad.entryCount()).toBe(1);
  });

  test("the + button in the value popup adds exactly one entry", async ({
    ctPage,
  }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForAllComponentsLoaded();
    await layout.waitForTraceLoaded();

    const editor = await openEditorWithFlowValues(layout);
    await stepAround(layout, 3);

    const scratchpad = await emptyScratchpad(layout);

    await editor.clickTab();
    const value = await requireFlowValue(editor);

    // Hovering the inline value opens the tippy popup that hosts the `+`
    // button (`ui/value.nim` -> `add-to-scratchpad-button`); the popup DOM is
    // rebuilt on every `mouseover`, so the button must be re-located here.
    await value.root.scrollIntoViewIfNeeded();
    await value.root.hover();

    const addButton = ctPage.locator(".add-to-scratchpad-button").first();
    await addButton.waitFor({ state: "visible", timeout: 10_000 });
    await addButton.click();

    await retry(async () => (await scratchpad.entryCount()) > 0);
    expect(await scratchpad.entryCount()).toBe(1);
  });

  test("re-opening the Scratchpad panel does not multiply entries", async ({
    ctPage,
  }) => {
    // The multiplier came from panel generations, not from clicks: every
    // `ScratchpadComponent` that had been registered stayed subscribed.
    // Closing the panel and letting the middleware re-open it (it does so
    // automatically when a value is added and no panel is present) builds
    // exactly those generations.
    const layout = new LayoutPage(ctPage);
    await layout.waitForAllComponentsLoaded();
    await layout.waitForTraceLoaded();

    const editor = await openEditorWithFlowValues(layout);

    for (let generation = 0; generation < 3; generation += 1) {
      const pane = (await layout.scratchpadTabs(true))[0];
      await pane.clickTab();
      const closeTab = pane
        .tabButton()
        .locator("xpath=ancestor::li[contains(@class,'lm_tab')]")
        .locator(".lm_close_tab");
      if ((await closeTab.count()) > 0) {
        await closeTab.first().click();
        await ctPage.waitForTimeout(300);
      }

      // Re-open by adding a value: `middleware.addToScratchpadHandler` opens
      // the panel when none is present.
      await editor.clickTab();
      const value = await requireFlowValue(editor);
      await value.addToScratchpad();
      await ctPage.waitForTimeout(500);
    }

    const scratchpad = await emptyScratchpad(layout);

    await editor.clickTab();
    const value = await requireFlowValue(editor);
    await value.addToScratchpad();

    await retry(async () => (await scratchpad.entryCount()) > 0);
    expect(await scratchpad.entryCount()).toBe(1);
  });
});
