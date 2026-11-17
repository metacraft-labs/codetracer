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
 * <file path>` on the right, BUILD | PROBLEMS | FIND IN FILES labels ... as
 * auto-hide pane triggers".
 *
 * This spec exists because that contract was silently broken and the
 * breakage was invisible except as a suite-wide timeout in an unrelated
 * place.  A single stylesheet rule,
 *
 *     #status #status-base > *:not(#auto-hide-bottom-strip)
 *       display: none !important
 *
 * made the footer tabs-only.  It removed the location readout
 * (`.location-path`), its copy affordance (`#copy-path-image`), the
 * language/encoding readout (`#file-info-status`), and — because the
 * `!important` outranked `.collapsed-icon-zone.has-icons` — §10.3's icon
 * zone, which could then never appear at all.  Every Electron spec started
 * with `readyOnEntryTest`, which then waited for `.location-path` to be
 * visible, so the whole suite went red on a footer nobody was looking at.
 *
 * THE LOCATION READOUT IS NOW HIDDEN ON PURPOSE.  The status-bar design hides
 * `.location-path` and `#copy-path-image` (`status_bar.styl`, "HIDDEN FOR
 * NOW"; `docs/UI-Design-Decisions.md` D-05, 2026-10-15), and on 2026-11-11 the
 * decision was to keep them hidden: §3.1 records it.  So this spec no longer
 * requires them, and the current location is checked where the user now
 * reads it, on the editor's execution line.  `readyOnEntryTest` waits for
 * that line too, which means a footer regression no longer turns the whole
 * suite red: this spec and `footer-visibility-css-guard.spec.ts` are the only
 * things that notice one.  The third test below pins that independence.
 *
 * A third attempt reached the same footer without going red at all.
 * `00fd68b7f "fix: status bar styling"` wrote `position: absolute; left:
 * -9999px` on `#file-info-status` and `.status-right`, and Playwright reports
 * an off-screen `.location-path` as "visible, enabled and stable" — so
 * `readyOnEntryTest` passed, this spec passed, and the footer was gone for
 * two weeks.  That is why the shared predicate in `status-footer-contract.ts`
 * now measures placement as well as box, and why the negative control below
 * runs the whole `CAUGHT_HIDE_SPELLINGS` list through the *predicate* rather
 * than through the readiness wait: the readiness wait cannot see this family
 * and never will.
 *
 * No mocks: this drives the real Electron app against a real recorded trace.
 */
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import * as childProcess from "node:child_process";

import {
  test,
  expect,
  readyOnEntryTest,
  READY_ON_ENTRY_SELECTOR,
} from "../../lib/fixtures";
import {
  BOTTOM_STRIP_IN_FOOTER_SELECTOR,
  RETIRED_BOTTOM_TABS_SELECTOR,
  bottomStripTabs,
} from "../../page-objects/auto-hide-strip";
import { parseStatusLocation } from "../../page-objects/status_bar";
import {
  CAUGHT_HIDE_SPELLINGS,
  TABS_ONLY_RULE_CSS,
  footerVisibilityFailures,
  probeFooterRegions,
} from "../../page-objects/status-footer-contract";

const repoRoot = path.resolve(__dirname, "../../../../..");

/**
 * The rule that broke the footer — twice, `b27da3947` and `51a3e820e` — kept
 * verbatim in `status-footer-contract.ts` so the historical case stays
 * covered by name.  The negative controls below run the whole
 * `CAUGHT_HIDE_SPELLINGS` list, because a control that only recognises the
 * spelling that shipped is a control the next spelling walks past — which is
 * not a hypothetical: `00fd68b7f` was the next spelling, and it is now entry
 * seven of that list.
 */
const TABS_ONLY_RULE = TABS_ONLY_RULE_CSS;

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
  test("footer_hosts_tab_strip_and_keeps_language_certificate_and_icon_zone", async ({
    ctPage,
  }) => {
    test.setTimeout(180_000);
    await readyOnEntryTest(ctPage);

    // -- The current location, where the design now shows it --------------
    // The execution-line arrow is on a line of `program.js`, in a visible
    // editor.  `readyOnEntryTest` waited for a visible arrow; this pins
    // that it is the recorded program's, not some other editor's.
    // Monaco's `data-uri` is an `inmemory://model/N` id, not the file, so the
    // file is taken from the location the status bar still renders (hidden):
    // the arrow must be on the line of that location, in `program.js`.
    const arrowLine = await ctPage
      .locator(READY_ON_ENTRY_SELECTOR)
      .filter({ visible: true })
      .first()
      .getAttribute("data-line");
    const reported = parseStatusLocation(
      (await ctPage.locator("#status-base .location-path").textContent()) ?? "",
    );
    expect(reported, "the status bar holds the entry location").not.toBeNull();
    expect(reported!.path).toMatch(/program\.js$/);
    expect(arrowLine, "the arrow is on the reported entry line").toBe(
      String(reported!.line),
    );

    // -- §3.1: the bar's own readouts are live ---------------------------
    await expect(ctPage.locator("#status-base #file-info-status")).toBeVisible();
    await expect(
      ctPage.locator("#status-base #file-info-status .file-info-status-language"),
    ).not.toBeEmpty();
    // The right-hand group's readout while the path is hidden by design.
    // It appears once the certificate indicator has read the tree, which
    // need not have happened by the time the entry location arrives.
    await expect(
      ctPage.locator("#status-base .status-right .test-certificate-status"),
    ).toBeVisible();
    // `#stable-status` is rendered only while the replay is busy (since
    // 74caaa788b), so an idle bar may not have it; when it is there it says
    // what it is.
    const stable = ctPage.locator("#status-base #file-info-status #stable-status");
    if ((await stable.count()) > 0) {
      await expect(stable).toContainText("stable:");
    }

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
    // They needed ~1035px of the 1050px minimum while the location path was
    // shown, so this also guards the margin: adding another always-present
    // readout or bottom tab pushes the last readout off-screen.  Polled
    // rather than asserted once so the flex row has time to settle after the
    // resize; the value polled is the overflow itself, so a real overflow
    // reports how much, and the message lists the offending elements.
    //
    // WHAT COUNTS AS OVERFLOW: content the user can see that ends past the
    // bar's right edge.  Not `scrollWidth`, which also counts transparent
    // boxes.  Measured at this width (2026-11-11): the "Path copied to
    // clipboard" tooltip of the copy button, `#location-status
    // .custom-tooltip`, is laid out at `opacity: 0` and ends 159px past the
    // edge.  It belongs to the copy button the design hides (D-05), so it can
    // never be shown, and `scrollWidth` would fail this test on it.
    const overflow = async () =>
      ctPage.evaluate(() => {
        const base = document.querySelector("#status-base") as HTMLElement | null;
        if (!base) {
          return {
            overflow: Number.MAX_SAFE_INTEGER,
            scrollOverflow: Number.MAX_SAFE_INTEGER,
            pastRightEdge: [] as string[],
          };
        }
        const right = base.getBoundingClientRect().left + base.clientWidth;
        const seen = (node: Element): boolean => {
          for (
            let el: Element | null = node;
            el !== null && el !== base.parentElement;
            el = el.parentElement
          ) {
            const style = getComputedStyle(el);
            if (
              style.visibility !== "visible" ||
              Number.parseFloat(style.opacity) === 0
            ) {
              return false;
            }
          }
          const r = node.getBoundingClientRect();
          return r.width > 0 && r.height > 0;
        };
        const describe = (node: Element) => {
          const r = node.getBoundingClientRect();
          const id = node.id ? `#${node.id}` : "";
          const cls = node.classList.length
            ? `.${Array.from(node.classList).join(".")}`
            : "";
          return (
            `${node.tagName.toLowerCase()}${id}${cls} x=${Math.round(r.x)} ` +
            `w=${Math.round(r.width)} visible=${seen(node)}`
          );
        };
        const past = Array.from(base.querySelectorAll("*")).filter(
          (node) => node.getBoundingClientRect().right > right + 1,
        );
        const visibleRights = past
          .filter(seen)
          .map((node) => node.getBoundingClientRect().right - right);
        return {
          overflow: Math.round(Math.max(0, ...visibleRights)),
          scrollOverflow: base.scrollWidth - base.clientWidth,
          pastRightEdge: past.map(describe),
        };
      });
    let measured = await overflow();
    await expect
      .poll(
        async () => {
          measured = await overflow();
          return measured.overflow;
        },
        { timeout: 10_000, intervals: [250, 500, 1000] },
      )
      .toBeLessThanOrEqual(0)
      .catch((failure: Error) => {
        throw new Error(
          `${failure.message}\nelements past the bar's right edge at ` +
            `${WINDOW_MIN_WIDTH}px (scrollWidth overflow ` +
            `${measured.scrollOverflow}): ` +
            JSON.stringify(measured.pastRightEdge, null, 1),
        );
      });

    // The control for that narrower measure: a visible readout made wide
    // enough to spill must still count, or the measure above ignores too much.
    await ctPage.evaluate(() => {
      const spill = document.createElement("span");
      spill.id = "footer-overflow-control";
      spill.className = "status-inline";
      spill.textContent = "x".repeat(400);
      document.querySelector("#status-base .status-right")?.appendChild(spill);
    });
    await expect
      .poll(async () => (await overflow()).overflow, { timeout: 5_000 })
      .toBeGreaterThan(0);
    await ctPage.evaluate(() =>
      document.getElementById("footer-overflow-control")?.remove(),
    );

    // The bar's last readout, now the test certificate (the location path is
    // hidden by design), must end inside the bar and stay on one row.
    const lastReadout = ctPage.locator(
      "#status-base .status-right .test-certificate-status",
    );
    await expect(lastReadout).toBeVisible();
    const squeezed = await ctPage.evaluate(() => {
      const base = document.querySelector("#status-base") as HTMLElement;
      const readout = document.querySelector(
        "#status-base .status-right .test-certificate-status",
      );
      if (!readout) return null;
      const r = readout.getBoundingClientRect();
      return { barWidth: base.clientWidth, right: r.right, height: r.height };
    });
    expect(squeezed, "the certificate readout must have a box").not.toBeNull();
    // `+ 1` absorbs sub-pixel rounding between the viewport size Playwright
    // sets and the width the fixed-position bar reports.
    expect(squeezed!.right).toBeLessThanOrEqual(squeezed!.barWidth + 1);
    // The bar is 2em tall and `overflow: visible`, so a readout that wraps
    // does not clip — it spills over the content above.
    expect(squeezed!.height).toBeLessThanOrEqual(32);
  });

  test("entry_readiness_reads_the_editor_not_the_footer", async ({
    ctPage,
  }) => {
    test.setTimeout(180_000);
    // Readiness used to be read from the footer, which is how two footer
    // regressions surfaced as suite-wide timeouts.  It is now read from the
    // editor's execution line.  Pin both halves of that in the real app:
    //
    //   1. The tabs-only rule that shipped twice takes the footer's readouts
    //      away (the footer predicate says so), and readiness still passes,
    //      because nothing about the session's entry location changed.  A
    //      footer regression must therefore be caught by THIS file and the
    //      CSS guard, not by the rest of the suite.
    //   2. Hiding the editor makes readiness fail, and say why: the
    //      execution line is drawn but has no box.  That is the visibility
    //      half of the wait, watched failing on the live renderer rather than
    //      only on the synthetic page of `ready-on-entry-contract.spec.ts`.
    await readyOnEntryTest(ctPage);

    const tabsOnly = await ctPage.addStyleTag({ content: TABS_ONLY_RULE });
    await expect(ctPage.locator("#status-base #file-info-status")).toBeHidden();
    await expect(
      ctPage.locator("#status-base #auto-hide-bottom-strip"),
    ).toBeVisible();
    expect(
      footerVisibilityFailures(await probeFooterRegions(ctPage)),
      "the tabs-only rule must still fail the footer contract",
    ).not.toEqual([]);
    await readyOnEntryTest(ctPage);
    await tabsOnly.evaluate((el) => (el as Element).remove());

    await ctPage.addStyleTag({
      content: ".monaco-editor { display: none !important; }",
    });
    let refusal = "";
    try {
      await readyOnEntryTest(ctPage);
    } catch (failure) {
      refusal = (failure as Error).message;
    }
    expect(refusal, "a hidden editor must not count as ready").toMatch(
      /Timeout \d+ms exceeded/,
    );
    expect(refusal).toContain("IS drawn but has no box");
    expect(refusal).toContain("monaco-editor");
  });

  test("every_spelling_of_the_blanket_hide_is_caught_in_the_running_app", async ({
    ctPage,
  }) => {
    test.setTimeout(180_000);
    // The negative control that generalises.  It applies every entry of
    // `CAUGHT_HIDE_SPELLINGS` — eight of which have never been written in
    // this repo — and requires the shared visibility check to reject each of
    // them in the real renderer.
    //
    // It asserts through `footerVisibilityFailures` rather than through a
    // Playwright visibility wait, because that predicate is
    // box-and-`visibility` only: an `opacity: 0` footer would sail past it
    // while being just as invisible to the user, and an OFF-SCREEN footer
    // sails past it too — Playwright reported a `.location-path` at
    // x = -9999 as "visible, enabled and stable", which is how `00fd68b7f`
    // shipped for two weeks.  Those two gaps are why the predicate folds in
    // effective opacity AND placement.
    await readyOnEntryTest(ctPage);
    // The certificate readout is a guarded region and arrives once the
    // indicator has read the tree; wait for it so the loop below measures
    // the injected rules and not the launch.
    await expect(
      ctPage.locator("#status-base .status-right .test-certificate-status"),
    ).toBeVisible();

    const survived: string[] = [];
    for (const spelling of CAUGHT_HIDE_SPELLINGS) {
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
