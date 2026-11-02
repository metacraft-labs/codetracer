/**
 * Regression tests for the alternative-view helper's browser boundary.
 * Only window.data is supplied: starting an RR session would make a fixed-array
 * representation test depend on recording and replay startup. The callbacks
 * still execute through a real browser's page.evaluate, including typed-array
 * coercion on writes, rather than an imitation of Playwright's evaluator.
 */
import { test, expect } from "@playwright/test";
import {
  armAlternativeView,
  readAlternativeViewState,
  ViewInstructions,
  ViewTargetSource,
} from "../../lib/alternative-views";

for (const representation of ["Uint8Array", "Float64Array", "BigInt64Array", "BigUint64Array", "Array", "array-like"] as const) {
  test.describe(`alternative-view flags: ${representation}`, () => {
    test.beforeEach(async ({ page }) => {
      await page.evaluate((kind) => {
        const flags = kind === "Uint8Array" ? new Uint8Array(10)
          : kind === "Float64Array" ? new Float64Array(10)
          : kind === "BigInt64Array" ? new BigInt64Array(10)
          : kind === "BigUint64Array" ? new BigUint64Array(10)
          : kind === "Array"
            ? Array(10).fill(false)
            : Object.assign({}, Array(10).fill(false), { length: 10 });
        (window as any).data = { ui: { openViewOnCompleteMove: flags } };
      }, representation);
    });

    test("recognizes the renderer's flag storage", async ({ page }) => {
      expect((await readAlternativeViewState(page)).hasFlags).toBe(true);
    });

    test("arms both views in place and verifies enabled readback", async ({ page }) => {
      await page.evaluate(() => {
        (window as any).originalFlags = (window as any).data.ui.openViewOnCompleteMove;
      });
      expect(await armAlternativeView(page, ViewTargetSource)).toBe(true);
      expect(await armAlternativeView(page, ViewInstructions)).toBe(true);
      const result = await page.evaluate(() => {
        const flags = (window as any).data.ui.openViewOnCompleteMove;
        return {
          sameStorage: flags === (window as any).originalFlags,
          values: Array.from({ length: flags.length }, (_, i) => flags[i]),
        };
      });
      expect(result.sameStorage).toBe(true);
      const bigint = representation === "BigInt64Array" || representation === "BigUint64Array";
      const numeric = representation === "Uint8Array" || representation === "Float64Array";
      const enabled = bigint ? 1n : numeric ? 1 : true;
      const disabled = bigint ? 0n : numeric ? 0 : false;
      expect(result.values).toEqual([
        disabled, enabled, enabled, ...Array(7).fill(disabled),
      ]);
    });
  });
}

for (const invalid of ["missing-data", "missing-ui", "missing-flags", "short", "long", "string", "data-view"] as const) {
  test(`alternative-view flags reject ${invalid}`, async ({ page }) => {
    await page.evaluate((kind) => {
      const w = window as any;
      if (kind === "missing-data") return;
      w.data = {};
      if (kind === "missing-ui") return;
      w.data.ui = {};
      if (kind === "missing-flags") return;
      w.data.ui.openViewOnCompleteMove = kind === "short"
        ? new Uint8Array(2)
        : kind === "long"
          ? Array(11).fill(false)
          : kind === "string"
            ? "0000000000"
            : new DataView(new ArrayBuffer(10));
    }, invalid);
    expect((await readAlternativeViewState(page)).hasFlags).toBe(false);
    expect(await armAlternativeView(page, ViewTargetSource)).toBe(false);
  });
}
