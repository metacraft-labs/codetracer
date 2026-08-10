/**
 * Status-bar footer contract.
 *
 * The footer is a shared surface: `Auto-Hide-Panes.md` §3.1 puts the bottom
 * auto-hide tab strip in it *alongside* the bar's own content —
 *
 *     |-- Status Bar / Footer
 *     |     |-- Left: auto-hide tab labels for bottom-pinned panels
 *     |     |-- Right: existing status bar content (language, encoding, location)
 *
 * — and §10.3 puts the collapsed-strip icon zone in the same bar.
 * `tools/screen-briefs.md` (Screen 1) states the same expectation for the
 * visual audit: "Footer: Status bar with `Python(db) | UTF-8 | stable: ready |
 * <file path>` on the right, BUILD | PROBLEMS | SEARCH RESULTS labels ... as
 * auto-hide pane triggers".
 *
 * This spec exists because that contract was silently broken once and the
 * breakage was invisible except as a suite-wide timeout in an unrelated
 * place.  A single stylesheet rule,
 *
 *     #status #status-base > *:not(#auto-hide-bottom-strip)
 *       display: none !important
 *
 * made the footer tabs-only.  It removed the only display of the current
 * debug location (`.location-path` — nothing else in the frontend renders
 * `StatusBaseModel.locationText`), its copy affordance
 * (`#copy-path-image`), the language/encoding readout (`#file-info-status`),
 * and — because the `!important` outranked `.collapsed-icon-zone.has-icons`
 * — §10.3's icon zone, which could then never appear at all.  Every Electron
 * spec starts with `readyOnEntryTest`, which waits for `.location-path` to be
 * visible, so the whole suite went red on a footer nobody was looking at.
 *
 * No mocks: this drives the real Electron app against a real recorded trace.
 */
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import * as childProcess from "node:child_process";

import { test, expect, readyOnEntryTest } from "../../lib/fixtures";
import {
  BOTTOM_STRIP_IN_FOOTER_SELECTOR,
  RETIRED_BOTTOM_TABS_SELECTOR,
  bottomStripTabs,
} from "../../page-objects/auto-hide-strip";
import {
  BLANKET_HIDE_SPELLINGS,
  footerVisibilityFailures,
  probeFooterRegions,
} from "../../page-objects/status-footer-contract";

const repoRoot = path.resolve(__dirname, "../../../../..");

/**
 * The rule that broke the footer — twice, `b27da3947` and `51a3e820e` — kept
 * verbatim as the first entry of `BLANKET_HIDE_SPELLINGS` so the historical
 * case stays covered by name.  The negative controls below run the whole
 * list, because a control that only recognises the spelling that shipped is
 * a control the next spelling walks past (milestone M66).
 */
const TABS_ONLY_RULE = BLANKET_HIDE_SPELLINGS[0].css;

/**
 * `minWidth` passed to `BrowserWindow` in `src/frontend/index/window.nim`.
 * The footer's contents must fit at the narrowest window the app allows.
 */
const WINDOW_MIN_WIDTH = 1050;

function findJsRecorder(): string {
  const env = process.env.CODETRACER_JS_RECORDER_PATH;
  if (env && fs.existsSync(env)) return env;
  return path.resolve(
    repoRoot,
    "..",
    "codetracer-js-recorder",
    "packages",
    "cli",
    "dist",
    "index.js",
  );
}

const fixtureDir = path.join(os.tmpdir(), "ct-status-footer-gui-" + process.pid);
const sourcePath = path.join(fixtureDir, "program.js");
const tracePath = path.join(fixtureDir, "trace");
const PROGRAM = "var a = 1; var b = 2; var c = a + b;\nvar d = c * 2;\n";

function prepareFixture(): { traceDir: string } {
  if (fs.existsSync(fixtureDir)) {
    fs.rmSync(fixtureDir, { recursive: true, force: true });
  }
  fs.mkdirSync(fixtureDir, { recursive: true });
  fs.writeFileSync(sourcePath, PROGRAM);

  const recorder = findJsRecorder();
  if (fs.existsSync(recorder)) {
    const recorderOut = path.join(fixtureDir, "rec-out");
    fs.mkdirSync(recorderOut, { recursive: true });
    childProcess.spawnSync("node", [
      recorder,
      "record",
      sourcePath,
      "--out-dir",
      recorderOut,
    ]);
    const entries = fs.readdirSync(recorderOut, { withFileTypes: true });
    const sub = entries.find(
      (e) => e.isDirectory() && e.name.startsWith("trace-"),
    );
    if (sub) fs.renameSync(path.join(recorderOut, sub.name), tracePath);
  }
  return { traceDir: tracePath };
}

const fixture = prepareFixture();

test.use({ sourcePath: fixture.traceDir, launchMode: "trace-folder" });

test.describe("status bar footer contract (Auto-Hide-Panes §3.1 / §10.3)", () => {
  test("footer_hosts_tab_strip_and_keeps_location_language_and_icon_zone", async ({
    ctPage,
  }) => {
    test.setTimeout(180_000);
    await readyOnEntryTest(ctPage);

    // -- §3.1: all three regions of the footer are live ------------------
    const locationPath = ctPage.locator("#status-base .location-path");
    await expect(locationPath).toBeVisible();
    // `path:line#ticks`, filled from `data.services.debugger.location`.
    await expect(locationPath).toHaveText(/program\.js:\d+#\d+$/);
    await expect(ctPage.locator("#status-base #copy-path-image")).toBeVisible();
    await expect(ctPage.locator("#status-base #file-info-status")).toBeVisible();
    await expect(
      ctPage.locator("#status-base #file-info-status .file-info-status-language"),
    ).not.toBeEmpty();
    await expect(
      ctPage.locator("#status-base #file-info-status #stable-status"),
    ).toContainText("stable:");

    // The bottom tab strip shares the bar and carries the standalone panes
    // `layout.nim` registers at boot (see `DEFAULT_BOTTOM_TAB_TITLES` in
    // `page-objects/auto-hide-strip.ts` — there are four, not three).
    const strip = ctPage.locator(BOTTOM_STRIP_IN_FOOTER_SELECTOR);
    await expect(strip).toBeVisible();
    await expect
      .poll(async () => bottomStripTabs(ctPage).count())
      .toBeGreaterThan(0);
    // Tabs are direct children of `#auto-hide-bottom-strip`; the pre-redesign
    // wrapper no longer exists anywhere in the app.  Named through the shared
    // constant so this negative control is the *only* place in the suite that
    // spells the retired class, and the guard in
    // `bottom-strip-selector-guard.spec.ts` can enforce that.
    await expect(
      ctPage.locator(RETIRED_BOTTOM_TABS_SELECTOR),
    ).toHaveCount(0);

    // -- §3.1 ordering: tab strip left of the status readout, no overlap --
    // Read all three boxes inside one `evaluate` rather than with three
    // `boundingBox()` round-trips.  `requestStatusRender` used to rebuild the
    // whole `#status` subtree on every redraw, so separate reads could land
    // either side of a teardown and come back null; it now patches in place
    // and only rebuilds on a structural change, but a rebuild is still
    // possible mid-test and one synchronous read cannot straddle one.
    const layout = await ctPage.evaluate(() => {
      const rect = (selector: string) => {
        const el = document.querySelector(selector);
        if (!el) return null;
        const r = el.getBoundingClientRect();
        return { x: r.x, right: r.right, width: r.width };
      };
      return {
        fileInfo: rect("#status-base #file-info-status"),
        strip: rect("#status-base #auto-hide-bottom-strip"),
        right: rect("#status-base .status-right"),
      };
    });
    expect(layout.fileInfo, "file-info-status must have a box").not.toBeNull();
    expect(layout.strip, "bottom strip must have a box").not.toBeNull();
    expect(layout.right, "status-right must have a box").not.toBeNull();
    expect(layout.fileInfo!.right).toBeLessThanOrEqual(layout.strip!.x + 1);
    expect(layout.strip!.right).toBeLessThanOrEqual(layout.right!.x + 1);

    // -- §10.3: the icon zone is reachable ------------------------------
    // It is `display: none` until a collapsed strip has panels, at which
    // point `auto_hide.styl`'s `.collapsed-icon-zone.has-icons` turns it
    // into a flex row.  The regression made that unreachable, so assert the
    // class actually wins rather than just that the host element exists.
    const iconZone = await ctPage.evaluate(() => {
      const zone = document.querySelector(
        "#auto-hide-collapsed-icon-zone",
      ) as HTMLElement | null;
      if (!zone) return null;
      const idle = getComputedStyle(zone).display;
      zone.classList.add("has-icons");
      const active = getComputedStyle(zone).display;
      zone.classList.remove("has-icons");
      return { idle, active };
    });
    expect(iconZone, "#auto-hide-collapsed-icon-zone must be in the footer").not.toBeNull();
    expect(iconZone!.idle).toBe("none");
    expect(iconZone!.active).toBe("flex");
  });

  test("footer_content_fits_at_the_minimum_window_width", async ({ ctPage }) => {
    test.setTimeout(180_000);
    await readyOnEntryTest(ctPage);

    await ctPage.setViewportSize({ width: WINDOW_MIN_WIDTH, height: 700 });

    // The three regions must not overflow the narrowest permitted window.
    // They currently need ~1035px of the 1050px minimum, so this also guards
    // the thin margin: adding another always-present readout or bottom tab
    // pushes the location path off-screen.  Polled rather than asserted once
    // so the flex row has time to settle after the resize; the value polled
    // is the overflow itself, so a real overflow reports how much.
    await expect
      .poll(
        async () =>
          ctPage.evaluate(() => {
            const base = document.querySelector(
              "#status-base",
            ) as HTMLElement | null;
            if (!base) return Number.MAX_SAFE_INTEGER;
            return base.scrollWidth - base.clientWidth;
          }),
        { timeout: 10_000, intervals: [250, 500, 1000] },
      )
      .toBeLessThanOrEqual(0);

    await expect(ctPage.locator("#status-base .location-path")).toBeVisible();
    const squeezed = await ctPage.evaluate(() => {
      const base = document.querySelector("#status-base") as HTMLElement;
      const path = document.querySelector("#status-base .location-path");
      if (!path) return null;
      const r = path.getBoundingClientRect();
      return { barWidth: base.clientWidth, right: r.right, height: r.height };
    });
    expect(squeezed, "location-path must have a box").not.toBeNull();
    // `+ 1` absorbs sub-pixel rounding between the viewport size Playwright
    // sets and the width the fixed-position bar reports.
    expect(squeezed!.right).toBeLessThanOrEqual(squeezed!.barWidth + 1);
    // The bar is 2em tall and `overflow: visible`, so a readout that wraps
    // does not clip — it spills over the content above.  `.location-path` is
    // `nowrap` + `text-overflow: ellipsis` precisely so a long path shortens
    // instead of growing the row.
    expect(squeezed!.height).toBeLessThanOrEqual(32);
  });

  test("reintroducing_the_tabs_only_rule_breaks_entry_readiness", async ({
    ctPage,
  }) => {
    test.setTimeout(180_000);
    // Negative control. `readyOnEntryTest` is deliberately a *visibility*
    // wait: `.location-path` is attached with the right `title` long before
    // it has a box, so an attachment wait would report readiness for a footer
    // that never renders. Prove the wait still fails loudly if the blanket
    // hide comes back, so a repeat regression cannot pass unnoticed.
    await readyOnEntryTest(ctPage);

    await ctPage.addStyleTag({ content: TABS_ONLY_RULE });

    await expect(ctPage.locator("#status-base .location-path")).toBeHidden();
    await expect(ctPage.locator("#status-base #file-info-status")).toBeHidden();
    await expect(
      ctPage.locator("#status-base #auto-hide-bottom-strip"),
    ).toBeVisible();

    // ... and the readiness wait itself rejects rather than silently passing.
    await expect(readyOnEntryTest(ctPage)).rejects.toThrow(/Timeout|timeout/);
  });

  test("every_spelling_of_the_blanket_hide_is_caught_in_the_running_app", async ({
    ctPage,
  }) => {
    test.setTimeout(180_000);
    // The second negative control, and the one that generalises.  The test
    // above pins the historical rule and the suite-wide symptom it produced;
    // this one applies every entry of `BLANKET_HIDE_SPELLINGS` — five of
    // which have never been written in this repo — and requires the shared
    // visibility check to reject each of them in the real renderer.
    //
    // Note what the two controls measure differently.  `readyOnEntryTest`
    // rejects on `display`/`visibility` hides because Playwright's
    // visibility predicate is box-and-`visibility`; an `opacity: 0` footer
    // would sail past it while being just as invisible to the user.  That
    // gap is why `footerVisibilityFailures` also folds in effective opacity,
    // and why this control asserts through it rather than through the
    // readiness wait.
    await readyOnEntryTest(ctPage);

    const survived: string[] = [];
    for (const spelling of BLANKET_HIDE_SPELLINGS) {
      const injected = await ctPage.addStyleTag({ content: spelling.css });
      const failures = footerVisibilityFailures(
        await probeFooterRegions(ctPage),
      );
      // `addStyleTag` hands back an `ElementHandle<Node>`; the injected node
      // is always the `<style>` element it just appended.
      await injected.evaluate((el) => (el as Element).remove());
      if (failures.length === 0) {
        survived.push(`${spelling.name}: ${spelling.css}`);
      }
    }
    expect(
      survived,
      "these ways of hiding the footer left the contract check green in the " +
        "running app, which means it is recognising a spelling rather than " +
        "an effect",
    ).toEqual([]);

    // With every injected rule removed the footer must be intact again —
    // otherwise the loop above proves nothing.
    expect(
      footerVisibilityFailures(await probeFooterRegions(ctPage)),
      "the footer must be visible again once the injected rules are removed",
    ).toEqual([]);
  });
});
