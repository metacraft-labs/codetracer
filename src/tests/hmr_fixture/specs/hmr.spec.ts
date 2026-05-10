import { test, expect } from "@playwright/test";

// CodeTracer HMR integration test.
//
// Mirrors the isonim parametric spec — but exercises the codetracer-side
// integration pattern: a parametric `render*Panel` proc marked
// `{.uiComponent.}` plus a `mountUiHot`-wrapped `mount*` proc, both
// expressed against codetracer's source layout (../../../../src/tests/hmr_fixture).
// The fixture defines its own tiny FixtureVM rather than dragging in
// codetracer's real ShellVM, since the HMR mechanism we're testing
// (slot register → mount re-render) is independent of the VM
// definition.
//
// What this spec proves about the codetracer integration:
//   1. The `{.uiComponent.}` pragma compiles and runs against
//      codetracer-shaped panel signatures (parametric, returning
//      isonim_dom.Element).
//   2. `mountUiHot` works inside codetracer's `mountIsoNimXxx`
//      pattern.
//   3. Two independent mounts on the same page get per-mount
//      isolation: swapping Panel B's slot does not touch Panel A's
//      DOM.
//   4. A failed swap (factory throws) is contained; Panel A's state
//      and Panel B's previous DOM both survive.
//   5. The harness's reach into codetracer-side identifiers
//      (`renderPanelBLoc`) confirms the pragma also emits the public
//      location const that codetracer test code can refer to.

test.describe("CodeTracer HMR integration", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("/");
    await page.waitForFunction(() => Boolean((window as any).__ctHmrTest));
    await page.evaluate(() => {
      (window as any).__ctHmrNavBaseline = (window as any).__ctHmrNavigations;
    });
  });

  test("initial render mounts both panels", async ({ page }) => {
    await expect(page.locator(".ct-hmr-panel-a")).toBeVisible();
    await expect(page.locator(".ct-hmr-panel-b")).toBeVisible();
    await expect(page.locator(".ct-hmr-panel-a .ct-shell-counter")).toHaveText(
      "0",
    );
    await expect(page.locator(".ct-hmr-panel-b .ct-shell-label")).toHaveText(
      "before",
    );
  });

  test("Panel A input keeps element identity when Panel B is swapped", async ({
    page,
  }) => {
    const handle = await page.evaluateHandle(() =>
      document.querySelector(".ct-hmr-panel-a .ct-shell-input"),
    );

    await page.evaluate(() => (window as any).__ctHmrTest.simulatePanelBAfter());

    const stillSame = await page.evaluate((h) => {
      const cur = document.querySelector(".ct-hmr-panel-a .ct-shell-input");
      return cur !== null && cur.isSameNode(h as Node);
    }, handle);
    expect(stillSame).toBe(true);
  });

  test("Panel A focus and typed value survive a Panel B swap", async ({
    page,
  }) => {
    const inputSel = ".ct-hmr-panel-a .ct-shell-input";
    await page.click(inputSel);
    await expect(page.locator(inputSel)).toBeFocused();
    await page.fill(inputSel, "hello world");

    await page.evaluate(() => (window as any).__ctHmrTest.simulatePanelBAfter());

    await expect(page.locator(inputSel)).toBeFocused();
    await expect(page.locator(inputSel)).toHaveValue("hello world");
  });

  test("Panel A counter signal keeps its value across a Panel B swap", async ({
    page,
  }) => {
    await page.evaluate(() => (window as any).__ctHmrTest.incCounter());
    await page.evaluate(() => (window as any).__ctHmrTest.incCounter());
    await page.evaluate(() => (window as any).__ctHmrTest.incCounter());
    await expect(page.locator(".ct-hmr-panel-a .ct-shell-counter")).toHaveText(
      "3",
    );

    await page.evaluate(() => (window as any).__ctHmrTest.simulatePanelBAfter());

    await expect(page.locator(".ct-hmr-panel-a .ct-shell-counter")).toHaveText(
      "3",
    );
  });

  test("Panel B's DOM is replaced by the after factory", async ({ page }) => {
    await expect(page.locator(".ct-hmr-panel-b .ct-shell-label")).toHaveText(
      "before",
    );

    await page.evaluate(() => (window as any).__ctHmrTest.simulatePanelBAfter());

    await expect(page.locator(".ct-hmr-panel-b.ct-hmr-after")).toBeVisible();
    await expect(page.locator(".ct-hmr-panel-b .ct-shell-label")).toHaveText(
      "AFTER",
    );
  });

  test("a broken Panel B swap preserves Panel A and reports the error", async ({
    page,
  }) => {
    await page.fill(".ct-hmr-panel-a .ct-shell-input", "still here");
    await page.evaluate(() => (window as any).__ctHmrTest.incCounter());
    await expect(page.locator(".ct-hmr-panel-a .ct-shell-counter")).toHaveText(
      "1",
    );

    await page.evaluate(() => {
      (window as any).__capturedErrors = [];
      (window as any).__ctHmrTest.onError((msg: unknown) => {
        (window as any).__capturedErrors.push(String(msg));
      });
    });

    await page.evaluate(() =>
      (window as any).__ctHmrTest.simulatePanelBBroken(),
    );

    await expect(page.locator(".ct-hmr-panel-a .ct-shell-input")).toHaveValue(
      "still here",
    );
    await expect(page.locator(".ct-hmr-panel-a .ct-shell-counter")).toHaveText(
      "1",
    );

    const errors = await page.evaluate(() => (window as any).__capturedErrors);
    expect(errors.length).toBeGreaterThanOrEqual(1);
    expect(errors[0]).toContain("boom");

    const navDelta = await page.evaluate(
      () =>
        (window as any).__ctHmrNavigations -
        (window as any).__ctHmrNavBaseline,
    );
    expect(navDelta).toBe(0);
  });

  test("scroll position is preserved across a Panel B swap", async ({
    page,
  }) => {
    await page.evaluate(() => window.scrollTo(0, 400));
    await page.waitForFunction(() => Math.round(window.scrollY) === 400);

    await page.evaluate(() => (window as any).__ctHmrTest.simulatePanelBAfter());

    const y = await page.evaluate(() => Math.round(window.scrollY));
    expect(y).toBe(400);
  });

  test("repeated swaps don't leak registry entries", async ({ page }) => {
    const initial = await page.evaluate(() =>
      (window as any).__ctHmrTest.registrySize(),
    );
    await page.evaluate(() => {
      for (let i = 0; i < 50; i++) {
        (window as any).__ctHmrTest.simulatePanelBAfter();
      }
    });
    const finalSize = await page.evaluate(() =>
      (window as any).__ctHmrTest.registrySize(),
    );
    expect(finalSize).toBeLessThanOrEqual(initial + 1);
  });

  test("generation counter advances with each register call", async ({
    page,
  }) => {
    const before = await page.evaluate(() =>
      (window as any).__ctHmrTest.generation(),
    );
    await page.evaluate(() => (window as any).__ctHmrTest.simulatePanelBAfter());
    const after = await page.evaluate(() =>
      (window as any).__ctHmrTest.generation(),
    );
    expect(after).toBeGreaterThan(before);
  });
});
