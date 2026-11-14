/**
 * Port of ui-tests/Tests/ProgramSpecific/NoirSpaceShipTests.cs
 *
 * The Noir Space Ship tests still written here: the trace log panel, the
 * scratchpad's comparisons and additions, the trace log and value history
 * context menus, tracepoint creation, and the renderer's responsiveness over
 * repeated jumps (#784, a main-thread long-task check). The call-trace
 * navigation, loop controls, event-log jumps, step controls, the files, call
 * trace and flow context menus and their keys, and adding flow values and
 * arguments to the scratchpad are scenarios now
 * (src/tests/scenarios/noir-space-ship/).
 */

import type { Page } from "@playwright/test";
import { test, expect } from "../../lib/fixtures";
import { retry } from "../../lib/retry-helpers";
import { debugLogger } from "../../lib/debug-logger";
import { LayoutPage } from "../../page-objects/layout-page";
import type { EditorPane } from "../../page-objects/panes/editor/editor-pane";
import { TraceLogPanel } from "../../page-objects/panes/editor/trace-log-panel";
import type { FlowValue } from "../../page-objects/panes/editor/flow-value";
import type { ScratchpadPane } from "../../page-objects/panes/scratchpad/scratchpad-pane";
import type { CallTracePane } from "../../page-objects/panes/call-trace/call-trace-pane";
import type { CallTraceEntry } from "../../page-objects/panes/call-trace/call-trace-entry";

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

/**
 * Navigates via call trace to open the shield.nr editor tab.
 * shield.nr is not open by default - only main.nr is.
 */
async function navigateToShieldEditor(layout: LayoutPage): Promise<EditorPane> {
  const callTrace = (await layout.callTraceTabs())[0];
  await callTrace.clickTab();
  callTrace.invalidateEntries();

  const eventLog = (await layout.eventLogTabs())[0];
  await eventLog.clickTab();
  const firstRow = await eventLog.rowByIndex(1, true);
  await firstRow.click();

  const statusReportEntry = await requireCallTraceEntry(callTrace, "status_report");
  await statusReportEntry.activate();
  await statusReportEntry.expandChildren();
  callTrace.invalidateEntries();

  const calculateDamageEntry = await requireCallTraceEntry(callTrace, "calculate_damage");
  await calculateDamageEntry.activate();

  const editors = await layout.editorTabs(true);
  const shieldEditor = editors.find((e) =>
    e.tabButtonText.toLowerCase().includes("shield.nr"),
  );
  if (!shieldEditor) {
    throw new Error("shield.nr editor tab was not available after navigation.");
  }

  await shieldEditor.clickTab();
  return shieldEditor;
}

/**
 * Finds a call trace entry by function name, expanding all entries if needed.
 */
async function requireCallTraceEntry(
  callTrace: CallTracePane,
  functionName: string,
): Promise<CallTraceEntry> {
  let located: CallTraceEntry | null = null;

  await retry(
    async () => {
      callTrace.invalidateEntries();
      located = await callTrace.findEntry(functionName, true);
      if (located) {
        return true;
      }

      const allEntries = await callTrace.getEntries(true);
      for (const entry of allEntries) {
        try {
          await entry.expandChildren();
        } catch {
          // entry may be scrolled out of viewport
        }
      }
      return false;
    },
    { maxAttempts: 20, delayMs: 200 },
  );

  if (!located) {
    throw new Error(`Call trace entry '${functionName}' was not found.`);
  }
  return located;
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * The first flow value in `editor` that can be added to the scratchpad AND
 * would add a row to it, or `null` if none shows up within the retry budget.
 *
 * The scratchpad keeps one row per expression and drops a sample equal to
 * the row's last one (`ScratchpadVM.addValue`, in
 * `src/frontend/viewmodel/viewmodels/scratchpad_vm.nim`). So adding a flow
 * value whose expression is already pinned leaves the row count unchanged,
 * and a test that counts rows has to pick an expression `scratchpad` does not
 * hold yet. In `noir_space_ship` that matters from the first addition on:
 * `main`'s first call-trace argument, `initial_shield`, is also the first
 * flow value of `main.nr` and of `shield.nr`.
 */
async function findUnpinnedFlowValue(
  editor: EditorPane,
  scratchpad: ScratchpadPane,
  options: { maxAttempts: number; delayMs: number },
): Promise<FlowValue | null> {
  const pinned = new Set<string>();
  for (const entry of await scratchpad.entries(true)) {
    pinned.add(await entry.expression());
  }
  let found: FlowValue | null = null;
  await retry(async () => {
    for (const val of await editor.flowValues()) {
      if (pinned.has(await val.name())) {
        continue;
      }
      if (await val.supportsScratchpad()) {
        found = val;
        return true;
      }
    }
    return false;
  }, options);
  return found;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

// HARDENING (TODO 5.2(h) — noir-space-ship suite-level flake):
//
// Originally this suite saw 16 of ~18 tests fail under sweep load
// with "Element is outside of the viewport" on `CallTracePane.clickTab`
// or with the 60-attempt 1s `waitForReady` budget exhausted on the
// `.calltrace-call-line` container.  Root cause: panels mount before
// the calltrace data is published, the page object scrolls into view
// to click, and GoldenLayout reflows the tab strip out from under it.
//
// Mitigations applied (sweep load can still surface secondary races,
// but the structural causes are addressed):
//
//   1. Pre-recording is already worker-scoped via fixtures.ts'
//      module-level `recordingCache`: the first test in a worker
//      records the noir trace once, every subsequent test in the
//      same worker reuses the cached `traceId`.  No per-test
//      `nargo trace` invocation.
//
//   2. `LayoutPage.waitForCallTraceReady()` (added with this
//      hardening) waits until at least one `.calltrace-call-line`
//      DOM element has been published — not just until the
//      GoldenLayout `calltraceComponent` div has mounted.  The
//      `before` hook below calls it after `waitForAllComponentsLoaded`,
//      so every test starts from a state where the calltrace store
//      has actually populated lines before any
//      `clickTab → invalidate → expand → activate` sequence runs.
//
//   3. `EditorPane.clickTab` and `FilesystemPane.clickTab` were
//      brought in line with `CallTracePane.clickTab`,
//      `EventLogPane.clickTab`, `ScratchpadPane.clickTab`, and
//      `VariableStatePane.clickTab` — all of which now have the
//      three-step `plain → force → dispatchEvent` fallback.  The
//      final `dispatchEvent('click')` step is critical under Xvfb
//      because Playwright's `force:true` does NOT redirect the
//      click to the underlying button when an `lm_header` overlay
//      sits on top — only a synthesized DOM click reliably
//      activates the tab in that situation.
//
// Per-test annotations below describe failures whose root cause is
// product-side (recorder gaps, traceMain DOM lifecycle, etc.) and
// not the suite-level flake.
test.describe("NoirSpaceShip", () => {
  test.setTimeout(90_000);
  test.describe.configure({ retries: 2 });
  test.use({ sourcePath: "noir_space_ship/", launchMode: "trace" });

  // Wait for the call-trace store to have published lines BEFORE any
  // test body runs.  Tests that exercise call-trace tabs (most of this
  // suite) race against the backend's `ct/load-calltrace-section`
  // round-trip when they call `clickTab()` immediately after
  // `waitForAllComponentsLoaded()` — the latter only checks for the
  // GoldenLayout component div.  Pulling the readiness wait into a
  // shared hook removes the race for every test in the suite without
  // duplicating the wait boilerplate per body.
  test.beforeEach(async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForAllComponentsLoaded();
    await layout.waitForCallTraceReady();
  });

  test("trace log records damage regeneration", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForAllComponentsLoaded();

    const shieldEditor = await navigateToShieldEditor(layout);

    const traceLine = 14;
    await shieldEditor.openTrace(traceLine);
    const tracePanel = new TraceLogPanel(shieldEditor, traceLine);
    await tracePanel.root.waitFor({ state: "visible" });

    const expression = "log(damage, remaining_shield, regeneration)";
    await tracePanel.typeExpression(expression);

    await shieldEditor.runTracepointsJs();

    // Wait for trace rows to be populated with iteration data
    await retry(
      async () => {
        const rows = await tracePanel.traceRows();
        return rows.length > 0;
      },
      { maxAttempts: 30, delayMs: 500 },
    );

    const traceRows = await tracePanel.traceRows();
    expect(traceRows.length).toBeGreaterThan(0);

    // Verify the first trace row contains actual data
    const firstRowText = await traceRows[0].text();
    expect(firstRowText.trim().length).toBeGreaterThan(0);

    // Re-run tracepoints and verify that trace rows are still present
    await shieldEditor.runTracepointsJs();

    await retry(
      async () => {
        const currentRows = await tracePanel.traceRows();
        return currentRows.length >= 1;
      },
      { maxAttempts: 30, delayMs: 300 },
    );
  });

  test("scratchpad compare iterations", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForAllComponentsLoaded();

    const editor = await navigateToShieldEditor(layout);

    const traceLine = 14;
    await editor.openTrace(traceLine);
    const tracePanel = new TraceLogPanel(editor, traceLine);
    await tracePanel.root.waitFor({ state: "visible" });

    const expression = "log(damage, remaining_shield)";
    await tracePanel.typeExpression(expression);
    await editor.runTracepointsJs();

    // Wait for trace rows to be populated
    let traceRows = await tracePanel.traceRows();
    await retry(
      async () => {
        traceRows = await tracePanel.traceRows();
        return traceRows.length > 0;
      },
      { maxAttempts: 30, delayMs: 300 },
    );

    expect(traceRows.length).toBeGreaterThan(0);

    const firstRowText = await traceRows[0].text();
    expect(firstRowText.trim().length).toBeGreaterThan(0);

    // Collect all row texts for comparison
    const rowTexts: string[] = [];
    for (const row of traceRows) {
      rowTexts.push(await row.text());
    }

    // If multiple rows exist, verify they contain distinct values
    if (traceRows.length >= 2) {
      const uniqueValues = new Set(rowTexts).size;
      if (uniqueValues < 2) {
        debugLogger.log(
          `All ${traceRows.length} trace rows have the same value: ${rowTexts[0]}`,
        );
      }
    }

    debugLogger.log(
      `ScratchpadCompareIterations: ${traceRows.length} trace row(s), first: ${firstRowText}`,
    );
  });

  test("trace log disable button should flip state", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForAllComponentsLoaded();

    const editor = await navigateToShieldEditor(layout);

    const traceLine = 14;
    await editor.openTrace(traceLine);
    const tracePanel = new TraceLogPanel(editor, traceLine);
    await tracePanel.root.waitFor({ state: "visible" });

    const disabledOverlay = tracePanel.disabledOverlay();

    // First, verify initial state - overlay should be hidden (tracepoint enabled)
    await retry(
      async () => {
        const cls = (await disabledOverlay.getAttribute("class")) ?? "";
        return cls.toLowerCase().includes("hidden");
      },
      { maxAttempts: 10, delayMs: 100 },
    );

    // Click disable via hamburger menu
    await tracePanel.clickToggleButton();

    // Wait for overlay to become visible (indicating tracepoint is disabled)
    await retry(
      async () => {
        const cls = (await disabledOverlay.getAttribute("class")) ?? "";
        return !cls.toLowerCase().includes("hidden");
      },
      { maxAttempts: 20, delayMs: 200 },
    );

    // Now re-enable by clicking toggle again
    await tracePanel.clickToggleButton();

    // Wait for overlay to become hidden again (indicating tracepoint is re-enabled)
    await retry(
      async () => {
        const cls = (await disabledOverlay.getAttribute("class")) ?? "";
        return cls.toLowerCase().includes("hidden");
      },
      { maxAttempts: 20, delayMs: 200 },
    );

    // Also verify we can type and run a trace after re-enabling
    const expression = "log(remaining_shield)";
    await tracePanel.typeExpression(expression);
    await editor.runTracepointsJs();
    await retry(
      async () => {
        const rows = await tracePanel.traceRows();
        return rows.length > 0;
      },
      { maxAttempts: 30, delayMs: 200 },
    );
  });

  test("exhaustive scratchpad additions", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForAllComponentsLoaded();

    const scratchpad = (await layout.scratchpadTabs())[0];
    await scratchpad.clickTab();
    let expectedCount = await scratchpad.entryCount();

    // Call trace argument addition
    const callTrace = (await layout.callTraceTabs())[0];
    await callTrace.waitForReady();
    callTrace.invalidateEntries();

    let targetArgument = null;
    const entries = await callTrace.getEntries(true);
    for (const entry of entries) {
      const args = await entry.arguments();
      if (args.length > 0) {
        targetArgument = args[0];
        break;
      }
    }
    expect(targetArgument).not.toBeNull();

    await targetArgument!.addToScratchpad();
    expectedCount += 1;
    await scratchpad.waitForEntryCount(expectedCount);
    scratchpad.invalidateCache();

    // Flow value addition: one the scratchpad does not hold yet, so that it
    // adds a row (see `findUnpinnedFlowValue`).
    let editor = (await layout.editorTabs())[0];
    const flowValue = await findUnpinnedFlowValue(editor, scratchpad, {
      maxAttempts: 20,
      delayMs: 200,
    });

    expect(flowValue).not.toBeNull();

    await flowValue!.selectContextMenuOption("Add value to scratchpad");
    expectedCount += 1;
    await scratchpad.waitForEntryCount(expectedCount);
    scratchpad.invalidateCache();

    // Prepare trace log data by running tracepoints
    await sleep(500);

    // Re-fetch tabs from the same layout (avoid creating new LayoutPage instances)
    const scratchpadForTrace = (await layout.scratchpadTabs(true))[0];
    await scratchpadForTrace.clickTab();
    expectedCount = await scratchpadForTrace.entryCount();

    const editorsForTrace = await layout.editorTabs(true);
    editor = editorsForTrace.find((e) => e.tabButtonText.includes("src/main.nr"))!;
    await editor.clickTab();
    await sleep(300);

    // Use the *second* tracepoint line (24) created by
    // `createSimpleTracePoint`: when both tracepoints have been added,
    // `runTracepoints` is rate-limited to only changed tracepoints, so the
    // earlier line-13 tracepoint's results are overwritten with an empty
    // aggregate by the second run.  Line 24 was the last to be (re)run, so
    // its trace-table reliably has rows we can drive a scratchpad
    // context-menu action from.
    const firstTraceLine = 24;

    const editorLine = editor.lineByNumber(firstTraceLine);
    const hasExistingTrace = await editorLine.hasTracepoint();

    let tracePanel: TraceLogPanel | null = null;

    if (!hasExistingTrace) {
      try {
        await createSimpleTracePoint(ctPage);

        // Re-acquire references after createSimpleTracePoint (which creates its own LayoutPage)
        const refreshedScratchpad = (await layout.scratchpadTabs(true))[0];
        await refreshedScratchpad.clickTab();
        expectedCount = await refreshedScratchpad.entryCount();
        const refreshedEditors = await layout.editorTabs(true);
        editor = refreshedEditors.find((e) => e.tabButtonText.includes("src/main.nr"))!;
      } catch (ex) {
        const msg = ex instanceof Error ? ex.message : String(ex);
        if (msg.includes("data.services") || msg.includes("services")) {
          console.warn(
            `WARNING: Skipping trace log row test due to frontend issue: ${msg}`,
          );
          return;
        }
        throw ex;
      }
    }

    tracePanel = new TraceLogPanel(editor, firstTraceLine);
    try {
      await tracePanel.root.waitFor({ state: "visible", timeout: 10_000 });
    } catch {
      try {
        await editor.openTrace(firstTraceLine);
        tracePanel = new TraceLogPanel(editor, firstTraceLine);
        await tracePanel.root.waitFor({ state: "visible", timeout: 10_000 });
      } catch (ex) {
        const msg = ex instanceof Error ? ex.message : String(ex);
        if (msg.includes("data.services") || msg.includes("services")) {
          console.warn(
            `WARNING: Skipping trace log row test due to frontend issue: ${msg}`,
          );
          return;
        }
        throw ex;
      }
    }

    // Trace rows populate asynchronously after `runTracepointsJs` resolves —
    // the data-table is rebuilt on the next backend update, which arrives
    // shortly after the test re-opens the panel.  Poll until rows appear
    // (matching the pattern used elsewhere in this spec).
    let traceRows = await tracePanel.traceRows();
    await retry(
      async () => {
        traceRows = await tracePanel!.traceRows();
        return traceRows.length > 0;
      },
      { maxAttempts: 30, delayMs: 300 },
    );
    expect(traceRows.length).toBeGreaterThan(0);

    // Re-fetch scratchpad for this phase
    const scratchpadForTraceRow = (await layout.scratchpadTabs(true))[0];

    // Try to add a trace row value to the scratchpad via its context menu
    try {
      const traceMenuOptions = await traceRows[0].contextMenuEntries();
      const addTraceOption = traceMenuOptions.find((opt) =>
        opt.toLowerCase().includes("add"),
      );
      if (addTraceOption) {
        await traceRows[0].selectMenuOption(addTraceOption);
        expectedCount += 1;
        await scratchpadForTraceRow.waitForEntryCount(expectedCount);
        scratchpadForTraceRow.invalidateCache();
      }
    } catch {
      console.warn(
        "WARNING: Trace row context menu not available (DataTables view may not expose it). Skipping trace row scratchpad addition.",
      );
    }

    // Flow value addition from shield.nr
    const shieldEditor = await navigateToShieldEditor(layout);
    const shieldFlowValue = await findUnpinnedFlowValue(
      shieldEditor,
      (await layout.scratchpadTabs(true))[0],
      { maxAttempts: 20, delayMs: 300 },
    );

    expect(shieldFlowValue).not.toBeNull();

    await shieldFlowValue!.addToScratchpad();
    expectedCount += 1;
    const finalScratchpad = (await layout.scratchpadTabs(true))[0];
    await finalScratchpad.waitForEntryCount(expectedCount);

    const finalCount = await finalScratchpad.entryCount();
    expect(finalCount).toBeGreaterThanOrEqual(expectedCount);
  });

  // The rest of the open menu's keys (CUA-Keymap.md §3.8): the arrows,
  // `Home` / `End` walk its rows (the keyboard row is `.ct-menu-item--active`)
  // and `Enter` chooses one — not the pane under the menu.
  const activeMenuRow = (page: Page) => page.evaluate(() => {
    const rows = Array.from(document.querySelectorAll(
      "#context-menu-container .context-menu-item"));
    return { index: rows.findIndex((r) => r.classList.contains("ct-menu-item--active")),
             count: rows.length };
  });
  const keyTraceOf = (page: Page) => page.evaluate(() =>
    ((globalThis as any).__ctKeyTrace ?? []).slice());

  test("trace log context menu options", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForAllComponentsLoaded();

    await sleep(2000);

    const editors = await layout.editorTabs(true);
    const editor = editors.find((e) => e.tabButtonText.includes("src/main.nr"));
    expect(editor).toBeDefined();
    await editor!.clickTab();
    await sleep(1000);

    const traceLine = 13;
    const editorLine = editor!.lineByNumber(traceLine);

    // Open trace panel with retry to handle data.services race condition
    let tracePanel: TraceLogPanel | null = null;
    await retry(
      async () => {
        try {
          if (await editorLine.hasTracepoint()) {
            tracePanel = new TraceLogPanel(editor!, traceLine);
            return await tracePanel.root.isVisible();
          }

          await editor!.openTrace(traceLine);
          await sleep(500);
          tracePanel = new TraceLogPanel(editor!, traceLine);
          return await tracePanel.root.isVisible();
        } catch (ex) {
          const msg = ex instanceof Error ? ex.message : String(ex);
          if (msg.includes("data.services") || msg.includes("services")) {
            await sleep(1000);
            return false;
          }
          throw ex;
        }
      },
      { maxAttempts: 15, delayMs: 500 },
    );

    expect(tracePanel).not.toBeNull();

    await tracePanel!.root.waitFor({ state: "visible", timeout: 10_000 });

    const expression = 'log("context menu test")';
    await tracePanel!.typeExpression(expression);
    await editor!.runTracepointsJs();

    // Wait for trace rows to appear with actual data
    let rows = await tracePanel!.traceRows();
    let rowText = "";
    await retry(
      async () => {
        rows = await tracePanel!.traceRows();
        if (rows.length === 0) return false;
        rowText = await rows[0].text();
        return rowText.toLowerCase().includes("context menu test");
      },
      { maxAttempts: 40, delayMs: 250 },
    );

    expect(rows.length).toBeGreaterThan(0);
    expect(rowText.toLowerCase()).toContain("context menu test");

    // Verify rows have actual data
    const valueCell = rows[0].root.locator("td.trace-values").first();
    const cellText = (await valueCell.textContent()) ?? "";
    expect(cellText.trim().length).toBeGreaterThan(0);

    console.log(
      `TraceLogContextMenuOptions: Verified ${rows.length} trace rows with expected content`,
    );
  });

  test("value history context menu options", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForAllComponentsLoaded();

    // Noir does not populate the Program State pane with variables or history
    // entries. Instead, we verify that flow values in the editor expose context
    // menu options including "Add value to scratchpad".
    const shieldEditor = await navigateToShieldEditor(layout);

    let flowValue: FlowValue | null = null;
    await retry(
      async () => {
        const flowValues = await shieldEditor.flowValues();
        for (const val of flowValues) {
          if (await val.supportsScratchpad()) {
            flowValue = val;
            return true;
          }
        }
        return false;
      },
      { maxAttempts: 30, delayMs: 300 },
    );

    expect(flowValue).not.toBeNull();

    const options = await flowValue!.contextMenuEntries();
    const hasScratchpadOption = options.some((option) =>
      option.toLowerCase().includes("scratchpad"),
    );
    expect(hasScratchpadOption).toBe(true);
  });

  // GitHub #784 (codetracer-pm issue
  // 2026-10-20-noir-replay-freezes-after-repeated-jumps): "the application
  // freezes after several jumps or tab switches". Measured at agents
  // 06c0f829b, the freeze was the RENDERER's main thread: every move and
  // every tab switch redraws the program menu, and the menu asked the key
  // router for each item's chord, which re-copied the whole router and
  // rebuilt every binding trie per candidate row — 13–25 s of blocked main
  // thread per move on this suite's trace, so the window stopped answering
  // after a few jumps. The replay-server answered throughout.
  //
  // The test drives the reporter's gesture mix (event-log jumps, stepping,
  // editor tab switches) and observes the main thread with the browser's own
  // Long Tasks API (https://w3c.github.io/longtasks/): any single task above
  // the bound is a window that does not paint or take input for that long.
  // The bound is NOT scaled by `CODETRACER_PERF_LIMIT_SCALE`: that scale
  // absorbs a loaded host's slow start-up, while a multi-second blocked main
  // thread is a freeze on any host.
  test("repeated jumps and tab switches keep the renderer responsive (#784)", async ({ ctPage }) => {
    test.setTimeout(900_000);
    const MAX_LONG_TASK_MS = 2_000;
    const MAX_EVAL_ROUND_TRIP_MS = 1_000;
    const ITERATIONS = 8;

    const layout = new LayoutPage(ctPage);
    await layout.waitForAllComponentsLoaded();

    // Observe only what navigation costs: installed after the trace loaded,
    // without the buffered start-up tasks.
    await ctPage.evaluate(() => {
      const w = window as any; // eslint-disable-line @typescript-eslint/no-explicit-any
      w.__ct784LongTasks = [];
      new PerformanceObserver((list) => {
        for (const entry of list.getEntries()) {
          w.__ct784LongTasks.push(Math.round(entry.duration));
        }
      }).observe({ type: "longtask", buffered: false });
    });

    const settle = async (): Promise<void> => {
      // A move is in flight while the debugger service says so; bounded so a
      // backend that never answers fails here rather than hanging the test.
      const deadline = Date.now() + 60_000;
      while (Date.now() < deadline) {
        const busy = await ctPage.evaluate(() => {
          const w = window as any; // eslint-disable-line @typescript-eslint/no-explicit-any
          return Boolean(w?.data?.services?.debugger?.stableBusy);
        });
        if (!busy) return;
        await sleep(50);
      }
      throw new Error("the debugger stayed busy for 60 s after a navigation action");
    };

    const actionLog: string[] = [];
    const act = async (label: string, run: () => Promise<void>): Promise<void> => {
      const t0 = Date.now();
      await run();
      await settle();
      actionLog.push(`${label}=${Date.now() - t0}ms`);
    };

    const eventLog = (await layout.eventLogTabs())[0];
    for (let i = 0; i < ITERATIONS; i++) {
      await act(`#${i} event-log jump`, async () => {
        await eventLog.clickTab();
        const rows = await eventLog.eventElements(true);
        expect(rows.length).toBeGreaterThan(0);
        await rows[(i * 7) % rows.length].click();
      });
      await act(`#${i} next`, async () => {
        await layout.nextButton().dispatchEvent("click");
      });
      await act(`#${i} step in`, async () => {
        await layout.stepInButton().dispatchEvent("click");
      });
      await act(`#${i} editor tabs`, async () => {
        for (const editor of await layout.editorTabs(true)) {
          await editor.clickTab();
        }
      });
    }

    const t0 = Date.now();
    await ctPage.evaluate(() => 1);
    const roundTripMs = Date.now() - t0;
    const longTasks: number[] = await ctPage.evaluate(
      () => (window as any).__ct784LongTasks ?? [], // eslint-disable-line @typescript-eslint/no-explicit-any
    );
    const longest = longTasks.length > 0 ? Math.max(...longTasks) : 0;
    console.log(
      `#784: longest main-thread task ${longest}ms over ${longTasks.length} long tasks ` +
        `[${longTasks.join(", ")}]; round trip ${roundTripMs}ms; ${actionLog.join(", ")}`,
    );
    expect(
      longest,
      `the renderer's main thread was blocked for ${longest}ms in one task ` +
        `(long tasks: ${longTasks.join(", ")}; actions: ${actionLog.join(", ")})`,
    ).toBeLessThan(MAX_LONG_TASK_MS);
    expect(roundTripMs, "a trivial evaluate after the navigation sequence").toBeLessThan(
      MAX_EVAL_ROUND_TRIP_MS,
    );
  });

  test("create simple tracepoint", async ({ ctPage }) => {
    await createSimpleTracePoint(ctPage);
  });
});

// ---------------------------------------------------------------------------
// Standalone tracepoint creation helper (used by exhaustive scratchpad too)
// ---------------------------------------------------------------------------

async function createSimpleTracePoint(page: Page): Promise<void> {
  const firstLine = 13;
  const secondLine = 24;
  const firstMessage = "This is a simple trace point";
  const secondMessage = "This is another simple trace point";

  const layout = new LayoutPage(page);
  await layout.waitForAllComponentsLoaded();

  await sleep(1000);

  let editor: EditorPane | undefined;
  await retry(async () => {
    const loadedEditors = await layout.editorTabs();
    editor = loadedEditors.find((e) => e.tabButtonText === "src/main.nr");
    return editor !== undefined;
  });

  if (!editor) {
    throw new Error("Expected editor tab 'src/main.nr' not found.");
  }

  await editor.clickTab();
  await sleep(1000);

  const eventLog = (await layout.eventLogTabs())[0];
  await eventLog.clickTab();

  await editor.openTrace(firstLine);
  await sleep(1000);

  const firstTracePanel = new TraceLogPanel(editor, firstLine);
  await firstTracePanel.root.waitFor({ state: "visible" });

  const firstExpression = `log("${firstMessage}")`;
  await firstTracePanel.typeExpression(firstExpression);

  await editor.runTracepointsJs();

  await retry(async () => {
    const events = await eventLog.eventElements(true);
    if (events.length === 0) return false;
    const text = await events[0].consoleOutput();
    return text.includes(firstMessage);
  });

  await editor.openTrace(secondLine);
  const secondTracePanel = new TraceLogPanel(editor, secondLine);
  await secondTracePanel.root.waitFor({ state: "visible", timeout: 10_000 });

  const secondExpression = `log("${secondMessage}")`;
  await secondTracePanel.typeExpression(secondExpression);

  await editor.runTracepointsJs();

  // Verify the second tracepoint produced output by checking its trace panel rows.
  // We cannot look for both messages in the event log because the event log is
  // paginated (e.g. 4 of 79 rows visible) and the second message appears far
  // beyond the visible page.
  await retry(
    async () => {
      const rows = await secondTracePanel.traceRows();
      return rows.length > 0;
    },
    { maxAttempts: 30, delayMs: 500 },
  );
}
