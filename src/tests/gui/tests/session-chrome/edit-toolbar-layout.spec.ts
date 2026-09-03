/**
 * Guard: the EDIT-mode topbar is laid out by rules that actually match it.
 *
 * WHY THIS EXISTS.
 * `views/isonim_edit_mode_toolbar_view` shipped with no stylesheet of its own.
 * The compiled themes contained zero occurrences of `edit-mode-toolbar`,
 * `edit-toolbar-button` or `ct-button-text`, and the panel rendered on
 * leftovers from rules written for other controls. Three things followed, all
 * of them visible on noirstudio.dev:
 *
 *   1. `#run-tests-image` is the ONE id the two topbar surfaces share
 *      (`EDIT_TOOLBAR_IDS.runTests`, and the contract file says so). On the
 *      debugger strip it is an ICON button and `button.styl` gave that id a
 *      `background-image`. On this surface it is the TEXT button "Run Tests",
 *      and the declarations that tame a background image — `no-repeat`,
 *      `auto 1em`, `center` — live on `[class*="ct-button-image-"]`, which a
 *      text button does not carry. The 21x16 asset fell back to the initial
 *      values and TILED across the button, printing four columns of `</  />`
 *      chevrons on top of the label. The control was unreadable.
 *
 *   2. `.ct-header` sets no `gap`, and the `gap: 0.5em` that spaces the
 *      debugger strip is scoped to `.isonim-debug-controls`, which this panel
 *      does not carry. Four bordered pills rendered edge to edge, each 1px
 *      border touching its neighbour's.
 *
 *   3. The size rules key off `ct-button-md-`, and the class the view emits is
 *      `ct-button-text-md-secondary`, which does not contain that substring.
 *      Nothing matched, so the buttons kept the user agent's `padding: 1px 6px`
 *      and stood 2px shorter than every other control in the bar.
 *
 * WHAT IT REFUSES TO DO.
 * Every one of those defects is invisible to a markup assertion. The buttons
 * were present, had the right ids, were enabled and disabled correctly, and
 * carried the right labels throughout — `data-button-count` read 4 the whole
 * time. So this spec asserts NUMBERS the browser computed: the gap in pixels,
 * the height in pixels, and what `background-image` resolves to on a text
 * button. A panel that regressed any of the three cannot be made to pass here
 * by adding an element or an attribute.
 *
 * WHAT IT TRUSTS, AND WHAT IT REFUSES TO TRANSCRIBE.
 * The built theme CSS, and the class/id strings READ OUT OF THE NIM VIEW at
 * run time rather than copied into this file. The bug was a mismatch between
 * the class the view emits and the selectors the stylesheet offers; a test
 * that hard-codes its own copy of the class cannot see that mismatch, because
 * it would keep asserting against the old string after the view moved on.
 */

import { test, expect } from "@playwright/test";
import * as fs from "fs";
import * as path from "path";
import { EDIT_TOOLBAR_IDS } from "../../page-objects/debug-toolbar-ids";

const REPO_ROOT = path.resolve(__dirname, "../../../../..");

const EDIT_VIEW_SRC = path.join(
  REPO_ROOT,
  "src/frontend/viewmodel/views/isonim_edit_mode_toolbar_view.nim",
);

/**
 * The caption bar's control height, in CSS pixels at the 16px root.
 *
 * Not an arbitrary number and not read back from the element: `#menu` in
 * components/menu_bar.styl fixes the bar at 2.125em/34px and its comment fixes
 * 1.625rem/26px as the size that leaves "4px above and 4px below, both whole
 * pixels". The command prompt and the session tabs are already this tall. A
 * literal here is what makes the assertion able to fail — comparing the
 * toolbar's height against the toolbar's height passes at any value.
 */
const BAR_CONTROL_HEIGHT_PX = 26;

/**
 * `gap: 0.5em` at the bar's 16px context, matching `.isonim-debug-controls`.
 */
const EXPECTED_GAP_PX = 8;

const THEMES = [
  { name: "dark", css: "default_dark_theme_electron.css" },
  { name: "white", css: "default_white_theme_electron.css" },
];

function resolveThemeCss(file: string): string {
  const dirs = [
    process.env.CODETRACER_BUILD_DIR
      ? path.join(process.env.CODETRACER_BUILD_DIR, "frontend/styles")
      : null,
    path.join(REPO_ROOT, "src/build-debug/frontend/styles"),
    path.join(REPO_ROOT, "src/build-debug-repro/frontend/styles"),
  ].filter(Boolean) as string[];
  for (const d of dirs) {
    const p = path.join(d, file);
    if (fs.existsSync(p)) return p;
  }
  throw new Error(
    `Built theme stylesheet ${file} not found in:\n  ${dirs.join("\n  ")}\n` +
      `Run \`just build-once\`, or compile it directly with\n` +
      `  node node_modules/stylus/bin/stylus -o src/build-debug/frontend/styles ` +
      `src/frontend/styles/${file.replace(/\.css$/, ".styl")}`,
  );
}

/**
 * The class string the shipped panel puts on its buttons, read from the view.
 *
 * Deliberately parsed rather than transcribed — see the header. If the view
 * stops emitting a single consistent class this throws instead of quietly
 * measuring markup that no longer exists.
 */
function buttonClassFromView(): string {
  const src = fs.readFileSync(EDIT_VIEW_SRC, "utf8");
  const matches = [...src.matchAll(/class = "([^"]*edit-toolbar-button)"/g)].map(
    (m) => m[1],
  );
  const webVariants = [...new Set(matches.filter((c) => c.includes("ct-button")))];
  if (webVariants.length !== 1) {
    throw new Error(
      `Expected exactly one web button class in ${path.basename(EDIT_VIEW_SRC)}, ` +
        `found ${JSON.stringify(webVariants)}. Update this spec deliberately.`,
    );
  }
  return webVariants[0];
}

/** The panel root's class, likewise read from the view. */
function panelClassFromView(): string {
  const src = fs.readFileSync(EDIT_VIEW_SRC, "utf8");
  const m = src.match(/class = "(ct-header edit-mode-toolbar)"/);
  if (!m) {
    throw new Error(
      `Could not find the web panel root class in ${path.basename(EDIT_VIEW_SRC)}.`,
    );
  }
  return m[1];
}

/**
 * Mount the panel's markup under one theme and measure it.
 *
 * The four ids come from the published page-object contract, so a rename there
 * lands here rather than leaving this spec measuring buttons the product no
 * longer has.
 */
async function measureToolbar(page: any, themeCss: string) {
  const buttonClass = buttonClassFromView();
  const panelClass = panelClassFromView();
  const ids = [
    EDIT_TOOLBAR_IDS.build,
    EDIT_TOOLBAR_IDS.run,
    EDIT_TOOLBAR_IDS.runTests,
    EDIT_TOOLBAR_IDS.recordTests,
  ];

  // `#menu` and `#isonim-debug-controls` are reproduced because the rules under
  // test are scoped to them; mounting the panel bare would measure a cascade
  // the product never applies.
  const buttons = ids
    .map(
      (id, i) =>
        `<button id="${id}" class="${buttonClass}"${i >= 2 ? " disabled" : ""}>` +
        `${["Build", "Run", "Run Tests", "Record Tests"][i]}</button>`,
    )
    .join("");
  await page.setContent(
    `<div id="menu" class="menu">` +
      `<div id="isonim-debug-controls">` +
      `<div class="${panelClass}" data-topbar-surface="edit-commands" data-button-count="4">` +
      `<div class="separate-bar"></div>${buttons}` +
      `</div></div></div>`,
    { waitUntil: "domcontentloaded" },
  );
  await page.addStyleTag({ path: themeCss });

  // Read AFTER layout has settled. A geometry read taken before the stylesheet
  // has been applied returns the unstyled numbers and, for a gap, that is 0 —
  // which is exactly the value this spec calls a failure, so it would fail in
  // the safe direction but for the wrong reason. Two frames is the cheapest
  // guarantee that the style pass ran.
  await page.evaluate(
    () => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))),
  );

  return await page.evaluate((selectors: string[]) => {
    const els = selectors.map((s) => document.getElementById(s)!);
    const rects = els.map((e) => e.getBoundingClientRect());
    return {
      count: els.filter(Boolean).length,
      heights: rects.map((r) => Math.round(r.height)),
      gaps: rects
        .slice(1)
        .map((r, i) => Math.round(r.left - rects[i].right)),
      backgroundImages: els.map((e) => getComputedStyle(e).backgroundImage),
      paddings: els.map((e) => getComputedStyle(e).padding),
      widths: rects.map((r) => r.width),
    };
  }, ids);
}

for (const theme of THEMES) {
  test(`edit toolbar: no background image tiles over a text label (${theme.name})`, async ({
    page,
  }) => {
    const m = await measureToolbar(page, resolveThemeCss(theme.css));

    // The defect, stated as the measurement that showed it: every button on
    // this surface is a TEXT button, so none of them may resolve a
    // background-image at all. `run-tests-image` resolved one and, lacking
    // `no-repeat`, tiled it over the words.
    expect(m.count).toBe(4);
    for (let i = 0; i < 4; i++) {
      expect(
        m.backgroundImages[i],
        `${["build", "run", "run-tests", "record-tests"][i]} must not paint a background image`,
      ).toBe("none");
    }
  });

  test(`edit toolbar: buttons are spaced and share the bar's control height (${theme.name})`, async ({
    page,
  }) => {
    const m = await measureToolbar(page, resolveThemeCss(theme.css));

    // Pixel gaps, not "are they adjacent". Zero here is the welded segmented
    // control the report was describing.
    expect(m.gaps).toEqual([
      EXPECTED_GAP_PX,
      EXPECTED_GAP_PX,
      EXPECTED_GAP_PX,
    ]);

    // One height for every control in the bar. 24 is what the user-agent
    // padding produced when no size rule matched the emitted class.
    for (const h of m.heights) {
      expect(h).toBe(BAR_CONTROL_HEIGHT_PX);
    }
  });

  test(`edit toolbar: the emitted class matches a size rule (${theme.name})`, async ({
    page,
  }) => {
    const m = await measureToolbar(page, resolveThemeCss(theme.css));

    // The root cause, asserted directly rather than through its symptom: if no
    // `[class*="ct-button-…"]` size rule matches the class the view emits, the
    // buttons keep the user agent's `1px 6px`. Any value other than that means
    // a rule matched; asserting the exact horizontal padding pins WHICH one.
    for (const p of m.paddings) {
      expect(p, "user-agent fallback padding means no size rule matched").not.toBe(
        "1px 6px",
      );
      expect(p).toBe("6.66667px 10px");
    }
  });
}

/**
 * Proof that the geometry checks above can fail.
 *
 * `toolbar-marks-contrast.spec.ts` carries the same idea for its count, and
 * for the same reason: an assertion nobody has watched fail is an assertion
 * nobody knows is connected to anything. This mounts the panel with the fixed
 * rules suppressed — the state the bug shipped in — and asserts the OLD
 * numbers, so if the checks above ever stop biting, this one starts failing.
 */
test("verify the layout checks can fail", async ({ page }) => {
  const themeCss = resolveThemeCss(THEMES[0].css);
  const buttonClass = buttonClassFromView();
  const panelClass = panelClassFromView();

  await page.setContent(
    `<div id="menu" class="menu"><div id="isonim-debug-controls">` +
      `<div class="${panelClass}">` +
      `<button id="a" class="${buttonClass}">Build</button>` +
      `<button id="b" class="${buttonClass}">Run</button>` +
      `</div></div></div>`,
    { waitUntil: "domcontentloaded" },
  );
  await page.addStyleTag({ path: themeCss });
  // Re-create the pre-fix cascade: no gap, and the user-agent padding back.
  await page.addStyleTag({
    content:
      `#isonim-debug-controls .edit-mode-toolbar { gap: 0 !important; height: auto !important; align-items: center !important; }` +
      `#isonim-debug-controls .edit-mode-toolbar .${buttonClass.split(" ").join(".")} { height: auto !important; padding: 1px 6px !important; }`,
  });
  await page.evaluate(
    () => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))),
  );

  const broken = await page.evaluate(() => {
    const a = document.getElementById("a")!.getBoundingClientRect();
    const b = document.getElementById("b")!.getBoundingClientRect();
    return {
      gap: Math.round(b.left - a.right),
      height: Math.round(a.height),
      padding: getComputedStyle(document.getElementById("a")!).padding,
    };
  });

  // The numbers the shipped bar actually had. If these ever stop reproducing,
  // the assertions above are measuring something else than they claim.
  expect(broken.gap).toBe(0);
  expect(broken.gap).not.toBe(EXPECTED_GAP_PX);
  expect(broken.height).not.toBe(BAR_CONTROL_HEIGHT_PX);
  expect(broken.padding).toBe("1px 6px");
});
