/**
 * Port of ui-tests/Tests/ProgramSpecific/NoirSpaceShipTests.cs
 *
 * Only the renderer-responsiveness check (#784, a main-thread long-task
 * measurement over repeated jumps) is still written here: it reads the
 * browser's Long Tasks API, which no user can observe. Every other Noir
 * Space Ship behaviour is a scenario now
 * (src/tests/scenarios/noir-space-ship/).
 */

import { test, expect } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

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
});
