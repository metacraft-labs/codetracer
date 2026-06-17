/**
 * FU-E — Rapid DAP step serialization (regression).
 *
 * Pre-fix: rapid F10 presses (or held-down repeats) sent several
 * `next` DAP requests on the wire before the previous `stopped` /
 * `CtCompleteMove` notification was processed.  This raced the UI's
 * `currentStep`/location state and, on the wire, occasionally caused
 * one of the overlapping `next` requests to be silently dropped.
 *
 * Post-fix: ``ui/debug.nim::dapStep`` gates new requests on the
 * `data.status.stableBusy` flag, which the middleware flips back to
 * `false` only on `CtCompleteMove`.  We observe the effect via the
 * existing ``__CODETRACER_TEST__.vmBackendRequests`` log appended by
 * ``recordDapStep`` AFTER the guard.
 */

import { test, expect } from "../../lib/fixtures";

type Req = { command?: string; source?: string };

async function waitStableBusyFalse(ctPage: { evaluate: Function }) {
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

async function resetRequestLog(ctPage: { evaluate: Function }) {
  await ctPage.evaluate(() => {
    const t = (window as unknown as { __CODETRACER_TEST__?: { vmBackendRequests?: unknown[] } })
      .__CODETRACER_TEST__ ?? {};
    t.vmBackendRequests = [];
    (window as unknown as { __CODETRACER_TEST__: typeof t }).__CODETRACER_TEST__ = t;
  });
}

async function countStepRequests(ctPage: { evaluate: Function }): Promise<number> {
  return ctPage.evaluate(() => {
    type R = { command?: string; source?: string };
    const log =
      ((window as unknown as { __CODETRACER_TEST__?: { vmBackendRequests?: R[] } })
        .__CODETRACER_TEST__?.vmBackendRequests ?? []) as R[];
    return log.filter(
      (r) =>
        (r.source === "dapStep" || typeof r.source === "undefined") &&
        typeof r.command === "string" &&
        (r.command.includes("next") ||
          r.command === "DapNext" ||
          r.command === "stepIn" ||
          r.command === "stepOut"),
    ).length;
  });
}

test.describe("FU-E — Rapid DAP step serialization", () => {
  test.describe.configure({ mode: "serial" });
  test.setTimeout(120_000);
  test.use({
    sourcePath: "py_console_logs/main.py",
    launchMode: "trace",
  });

  test("five rapid F10 presses emit at most one DAP step request", async ({ ctPage }) => {
    await expect(ctPage.locator(".monaco-editor").first()).toBeVisible({ timeout: 60_000 });
    await ctPage.locator(".monaco-editor .view-lines").first().click();
    // Initial ``runToEntry`` seeds `data.status.stableBusy = true`; wait
    // until the first `CtCompleteMove` flips it.
    await waitStableBusyFalse(ctPage);
    await resetRequestLog(ctPage);

    for (let i = 0; i < 5; i += 1) {
      await ctPage.keyboard.press("F10");
    }
    // Without serialization, the pre-fix code path would record 5 entries.
    expect(await countStepRequests(ctPage)).toBeLessThanOrEqual(1);
  });

  test("F10 is accepted again after the previous step completes", async ({ ctPage }) => {
    await expect(ctPage.locator(".monaco-editor").first()).toBeVisible({ timeout: 60_000 });
    await ctPage.locator(".monaco-editor .view-lines").first().click();
    await waitStableBusyFalse(ctPage);
    await resetRequestLog(ctPage);

    await ctPage.keyboard.press("F10");
    await waitStableBusyFalse(ctPage); // CtCompleteMove released the guard.
    await ctPage.keyboard.press("F10");

    expect(await countStepRequests(ctPage)).toBeGreaterThanOrEqual(2);
  });
});
