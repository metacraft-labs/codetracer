/**
 * FU-E — Rapid DAP step serialization (regression).
 *
 * Pre-fix: rapid F10 presses (or held-down repeats) sent several
 * `next` DAP requests on the wire before the previous `stopped` /
 * `CtCompleteMove` notification was processed.  This raced the UI's
 * `currentStep`/location state and, on the wire, occasionally caused
 * one of the overlapping `next` requests to be silently dropped.
 *
 * The keyboard reaches `ui/debug_toolbar.nim::dapStep` through the real
 * window key router and toolbar ViewModel. Its stableBusy guard drops steps
 * until middleware processes CtCompleteMove.
 *
 * Dispatch each burst in one renderer task: separate awaited Playwright
 * keyboard presses allow a fast backend to complete between presses, so two
 * accepted requests do not imply overlap. No backend is mocked or delayed;
 * only key delivery is synchronous, keeping completion IPC outside the burst.
 */

import { test, expect } from "../../lib/fixtures";
import type { Page } from "@playwright/test";

async function focusEditor(ctPage: Page) {
  // Focus the input, not the centre of the potentially clipped view-lines
  // canvas: neighbouring panes can cover that point in the default layout.
  await ctPage.evaluate(() => {
    const d = (window as any).data;
    d.ui.editors[d.services.editor.active].monacoEditor.focus();
  });
  await expect.poll(() => ctPage.evaluate(() => {
    const d = (window as any).data;
    return d.ui.editors[d.services.editor.active].monacoEditor.hasTextFocus();
  })).toBe(true);
}

async function pressF10Burst(ctPage: Page, count: number, repeat = false) {
  return ctPage.evaluate(({ count, repeat }) => {
    const target = document.activeElement;
    if (!target?.closest(".monaco-editor")) {
      throw new Error("F10 burst requires focus in the Monaco editor");
    }
    const busy: boolean[] = [];
    for (let i = 0; i < count; i += 1) {
      target.dispatchEvent(new KeyboardEvent("keydown", {
        key: "F10", code: "F10", keyCode: 121, which: 121,
        bubbles: true, cancelable: true, repeat: repeat && i > 0,
      }));
      busy.push((window as unknown as {
        data: { status: { stableBusy: boolean } };
      }).data.status.stableBusy);
      if (!repeat || i === count - 1) {
        target.dispatchEvent(new KeyboardEvent("keyup", {
          key: "F10", code: "F10", keyCode: 121, which: 121,
          bubbles: true, cancelable: true,
        }));
      }
    }
    return busy;
  }, { count, repeat });
}

async function waitStableBusyFalse(ctPage: Page) {
  await expect
    .poll(
      () =>
        ctPage.evaluate(
          () =>
            (window as unknown as { data?: { status?: { stableBusy?: boolean } } })
              .data?.status?.stableBusy === false,
        ),
      { timeout: 60_000 },
    )
    .toBe(true);
}

async function resetRequestLog(ctPage: Page) {
  await ctPage.evaluate(() => {
    const t = (window as unknown as { __CODETRACER_TEST__?: { vmBackendRequests?: unknown[] } })
      .__CODETRACER_TEST__ ?? {};
    t.vmBackendRequests = [];
    (window as unknown as { __CODETRACER_TEST__: typeof t }).__CODETRACER_TEST__ = t;
  });
}

async function countStepRequests(ctPage: Page): Promise<number> {
  return ctPage.evaluate(() => {
    type R = { command?: string; source?: string };
    const log =
      ((window as unknown as { __CODETRACER_TEST__?: { vmBackendRequests?: R[] } })
        .__CODETRACER_TEST__?.vmBackendRequests ?? []) as R[];
    // Count the accepted desktop step once, after dapStep's guard, rather
    // than mixing in the store's independent request-observer records.
    return log.filter((r) => r.source === "dapStep" && r.command === "next").length;
  });
}

test.describe("FU-E — Rapid DAP step serialization", () => {
  test.describe.configure({ mode: "serial" });
  test.setTimeout(120_000);
  test.use({
    sourcePath: "py_console_logs/main.py",
    launchMode: "trace",
  });

  test("five in-flight F10 presses emit exactly one DAP step request", async ({ ctPage }) => {
    await expect(ctPage.locator(".monaco-editor").first()).toBeVisible({ timeout: 60_000 });
    await focusEditor(ctPage);
    // Initial ``runToEntry`` seeds `data.status.stableBusy = true`; wait
    // until the first `CtCompleteMove` flips it.
    await waitStableBusyFalse(ctPage);
    await resetRequestLog(ctPage);

    expect(await pressF10Burst(ctPage, 5)).toEqual([true, true, true, true, true]);
    expect(await countStepRequests(ctPage)).toBe(1);
    await waitStableBusyFalse(ctPage);
    // Dropped presses must not have queued work to send on completion.
    expect(await countStepRequests(ctPage)).toBe(1);
  });

  test("F10 is accepted again after the previous step completes", async ({ ctPage }) => {
    await expect(ctPage.locator(".monaco-editor").first()).toBeVisible({ timeout: 60_000 });
    await focusEditor(ctPage);
    await waitStableBusyFalse(ctPage);
    await resetRequestLog(ctPage);

    expect(await pressF10Burst(ctPage, 5, true)).toEqual([true, true, true, true, true]);
    expect(await countStepRequests(ctPage)).toBe(1);
    await waitStableBusyFalse(ctPage); // CtCompleteMove released the guard.
    expect(await countStepRequests(ctPage)).toBe(1);
    expect(await pressF10Burst(ctPage, 1)).toEqual([true]);
    expect(await countStepRequests(ctPage)).toBe(2);
    await waitStableBusyFalse(ctPage);
    expect(await countStepRequests(ctPage)).toBe(2);
  });
});
