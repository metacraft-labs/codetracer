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

const EDIT_MARKS_SRC = path.join(
  REPO_ROOT,
  "src/frontend/viewmodel/views/edit_toolbar_marks.nim",
);

/**
 * The two class strings `editButtonClass` hands out, read from the view.
 *
 * Deliberately parsed rather than transcribed — see the header. Build and Run
 * are icon buttons and the other two are text buttons, and which rules each
 * one picks up follows entirely from that string, so a spec carrying its own
 * copy would keep asserting against the old spelling after the view moved on.
 */
function buttonClassesFromView(): { icon: string; text: string } {
  const src = fs.readFileSync(EDIT_VIEW_SRC, "utf8");
  const body = src.slice(src.indexOf("func editButtonClass*"));
  const found = [...body.matchAll(/"((?:ct-button-[a-z-]+\s+)+edit-toolbar-button)"/g)]
    .map((m) => m[1]);
  const icon = found.find((c) => c.includes("ct-button-image-"));
  const text = found.find((c) => c.includes("ct-button-text-"));
  if (!icon || !text) {
    throw new Error(
      `Could not read both button classes from editButtonClass in ` +
        `${path.basename(EDIT_VIEW_SRC)}; found ${JSON.stringify(found)}.`,
    );
  }
  return { icon, text };
}

/** The mark's class, read from the marks module. */
function markClassFromSource(): string {
  const src = fs.readFileSync(EDIT_MARKS_SRC, "utf8");
  const m = src.match(/EditMarkClass\*\s*=\s*"([^"]+)"/);
  if (!m) throw new Error("EditMarkClass not found in edit_toolbar_marks.nim");
  return m[1];
}

/** Which button ids carry a mark, read from the `EditToolbarMarks` table. */
function markedIdsFromSource(): string[] {
  const src = fs.readFileSync(EDIT_MARKS_SRC, "utf8");
  const table = src.slice(src.indexOf("const EditToolbarMarks*"));
  return [...table.matchAll(/buttonId:\s*"([^"]+)"/g)].map((m) => m[1]);
}

/** `EditMarkCount`, the literal the marks module states independently. */
function markCountFromSource(): number {
  const src = fs.readFileSync(EDIT_MARKS_SRC, "utf8");
  const m = src.match(/EditMarkCount\*\s*=\s*(\d+)/);
  if (!m) throw new Error("EditMarkCount not found in edit_toolbar_marks.nim");
  return Number(m[1]);
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
  const { icon: iconClass, text: textClass } = buttonClassesFromView();
  const markClass = markClassFromSource();
  const marked = new Set(markedIdsFromSource());
  const panelClass = panelClassFromView();
  const ids = [EDIT_TOOLBAR_IDS.build, EDIT_TOOLBAR_IDS.run];

  // `#menu` and `#isonim-debug-controls` are reproduced because the rules under
  // test are scoped to them; mounting the panel bare would measure a cascade
  // the product never applies.
  //
  // A marked button gets an empty `<svg>` carrying the real mark class rather
  // than the real path data. What is under test here is the CSS box the mark
  // is given — its size comes from the stylesheet, not from its `d` — and the
  // artwork's own invariants are asserted separately, from the source, in
  // `the marks are drawn in the restored family's manner`.
  const buttons = ids
    .map((id, i) => {
      const isIcon = marked.has(id);
      const cls = isIcon ? iconClass : textClass;
      const inner = isIcon
        ? `<svg class="${markClass}" viewBox="0 0 16 16"><path d="M0 0h16v16H0Z" fill="currentColor"/></svg>`
        : ["Build", "Run"][i];
      return `<button id="${id}" class="${cls}">${inner}</button>`;
    })
    .join("");
  await page.setContent(
    `<div id="menu" class="menu">` +
      `<div id="isonim-debug-controls">` +
      `<div class="${panelClass}" data-topbar-surface="edit-commands" data-button-count="2">` +
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

  return await page.evaluate(
    ([selectors, mc]: [string[], string]) => {
      const els = selectors.map((s) => document.getElementById(s)!);
      const rects = els.map((e) => e.getBoundingClientRect());
      return {
        count: els.filter(Boolean).length,
        heights: rects.map((r) => Math.round(r.height)),
        widths: rects.map((r) => r.width),
        gaps: rects
          .slice(1)
          .map((r, i) => Math.round(r.left - rects[i].right)),
        backgroundImages: els.map((e) => getComputedStyle(e).backgroundImage),
        // The frame, and the colour the marks inherit through `currentColor`.
        borderWidths: els.map((e) => getComputedStyle(e).borderWidth),
        borders: els.map((e) => getComputedStyle(e).border),
        colors: els.map((e) => getComputedStyle(e).color),
        markFills: els.map((e) => {
          const p0 = e.querySelector("." + mc + " path");
          return p0 ? getComputedStyle(p0).fill : null;
        }),
        backgroundRepeats: els.map((e) => getComputedStyle(e).backgroundRepeat),
        paddings: els.map((e) => getComputedStyle(e).padding),
        radii: els.map((e) => getComputedStyle(e).borderRadius),
        // The mark's PAINTED box, per button — null where there is no mark.
        marks: els.map((e) => {
          const m = e.querySelector("." + mc);
          if (!m) return null;
          const r = m.getBoundingClientRect();
          return { w: Math.round(r.width), h: Math.round(r.height) };
        }),
      };
    },
    [ids, markClass] as [string[], string],
  );
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
    expect(m.count).toBe(2);
    for (let i = 0; i < 2; i++) {
      expect(
        m.backgroundImages[i],
        `${["build", "run"][i]} must not paint a background image`,
      ).toBe("none");
    }
  });

  test(`edit toolbar: buttons are spaced and share the bar's control height (${theme.name})`, async ({
    page,
  }) => {
    const m = await measureToolbar(page, resolveThemeCss(theme.css));

    // Pixel gaps, not "are they adjacent". Zero here is the welded segmented
    // control the report was describing.
    expect(m.gaps).toEqual([EXPECTED_GAP_PX]);

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
    const marked = new Set(markedIdsFromSource());
    const ids = [EDIT_TOOLBAR_IDS.build, EDIT_TOOLBAR_IDS.run];

    // The root cause, asserted directly rather than through its symptom: if no
    // `[class*="ct-button-…"]` size rule matches the class the view emits, the
    // buttons keep the user agent's `1px 6px`. Any value other than that means
    // a rule matched; asserting the exact value pins WHICH one.
    //
    // The two kinds take different rules and so different values — a text
    // button is padded to fit its label, an icon button is sized square and
    // centres its glyph — which is why this is per-id rather than one value
    // for the row.
    ids.forEach((id, i) => {
      expect(
        m.paddings[i],
        `${id}: user-agent fallback padding means no size rule matched`,
      ).not.toBe("1px 6px");
      expect(m.paddings[i]).toBe(marked.has(id) ? "0px" : "6.66667px 10px");
    });

    // One radius for the row. The text variant inherits 0.5em and the icon
    // variant 0.375em, both `!important` and both resolved against the user
    // agent's 13.33px, so without an override the row would round its two
    // kinds of button differently by 1.7px.
    for (const r of m.radii) expect(r).toBe("6px");
  });

  test(`edit toolbar: icon buttons are square, marked, and take the image rules (${theme.name})`, async ({
    page,
  }) => {
    const m = await measureToolbar(page, resolveThemeCss(theme.css));
    const marked = new Set(markedIdsFromSource());
    const ids = [EDIT_TOOLBAR_IDS.build, EDIT_TOOLBAR_IDS.run];

    // Exactly the buttons the marks table names are icon buttons, and it names
    // as many as `EditMarkCount` says. A literal, so dropping a mark is a
    // failure rather than a smaller number compared against itself.
    expect(markedIdsFromSource().length).toBe(markCountFromSource());
    expect(markedIdsFromSource().sort()).toEqual(
      [EDIT_TOOLBAR_IDS.build, EDIT_TOOLBAR_IDS.run].sort(),
    );

    ids.forEach((id, i) => {
      if (!marked.has(id)) {
        expect(m.marks[i], `${id} is a text button and must carry no mark`).toBeNull();
        return;
      }
      // A PAINTED box, not `present: true`. A mark that failed to attach, or
      // one collapsed to zero by a missing size rule, leaves a button that
      // still renders and still clicks — which is exactly how a bare toolbar
      // passed three earlier probes.
      expect(m.marks[i], `${id} must carry a mark`).not.toBeNull();
      expect(m.marks[i]!.w, `${id} mark width`).toBe(16);
      expect(m.marks[i]!.h, `${id} mark height`).toBe(16);

      // Square at the bar's control height. `[class*="ct-button-image-md-"]`
      // would make these 23.33px and its `max-height` would clamp the row's
      // `height: 100%`, putting the icons 2.67px below the text buttons.
      expect(m.widths[i], `${id} width`).toBe(BAR_CONTROL_HEIGHT_PX);
      expect(m.heights[i], `${id} height`).toBe(BAR_CONTROL_HEIGHT_PX);

      // Proof that the icon variant really does pick up the image rules: the
      // user agent's initial `background-repeat` is `repeat`, and only
      // `[class*="ct-button-image-"]` sets `no-repeat`. This is the same
      // property whose ABSENCE tiled an asset across "Run Tests" — asserted
      // here from the other side.
      expect(
        m.backgroundRepeats[i],
        `${id}: the image-button rules did not match this class`,
      ).toBe("no-repeat");
    });
  });
}

/**
 * The artwork's own invariants, read from the source it is drawn in.
 *
 * These are not geometry, so they are not measured in a browser — they are the
 * properties that make the marks members of the family they are meant to
 * emulate, and each one corresponds to a defect this toolbar has already had.
 */
test("the marks are drawn in the restored family's manner", () => {
  const src = fs.readFileSync(EDIT_MARKS_SRC, "utf8");

  // Just `svgMarkup`'s body, and then only the strings it BUILDS. Slicing to
  // end-of-file swept in the prose that explains which properties are being
  // avoided and why, so the check reported its own documentation as the
  // violation.
  const from = src.indexOf("func svgMarkup*");
  const rest = src.slice(from + 1);
  const next = rest.search(/\n(?:func|proc|when|const|type)\b/);
  const emitterSrc = next === -1 ? rest : rest.slice(0, next);
  const emitter = [...emitterSrc.matchAll(/"((?:[^"\\]|\\.)*)"/g)]
    .map((m) => m[1])
    .join(" ");

  // No colour literal reaches the output. Baking `#DDDDDD` into the asset
  // files is why the debugger strip rendered twelve blank buttons on the white
  // theme; restoring the DRAWINGS is not a reason to restore that.
  //
  // Scanned over the file's STRING LITERALS rather than its text: the header
  // discusses `#DDDDDD` by name, and a check that cannot tell a colour being
  // emitted from a colour being explained is a check that forces the next
  // person to stop writing the explanation.
  const literals = [...src.matchAll(/"((?:[^"\\]|\\.)*)"/g)].map((m) => m[1]);
  const hex = literals.filter((s) => /#[0-9a-fA-F]{3,8}\b/.test(s));
  expect(hex, `colour literals found: ${JSON.stringify(hex)}`).toEqual([]);
  expect(emitter).toContain("currentColor");

  // Butt caps and mitre joins — SVG's initial values, which the original
  // assets got by not saying anything. The codicon set that replaced them is
  // round/round, and `debug_control_marks.svgMarkup` hard-codes those, so
  // emitting either property here would put these marks in the wrong family.
  expect(
    emitter,
    "a linecap would put these marks in the codicon family, not the restored one",
  ).not.toContain("stroke-linecap");
  expect(emitter).not.toContain("stroke-linejoin");
  expect(emitter).toContain("stroke-miterlimit");

  // Drawn on the same 16-unit grid as the marks they sit beside.
  const table = src.slice(src.indexOf("const EditToolbarMarks*"));
  const boxes = [...table.matchAll(/viewBox:\s*"([^"]+)"/g)].map((m) => m[1]);
  expect(boxes.length).toBe(markCountFromSource());
  for (const b of boxes) expect(b).toBe("0 0 16 16");

  // Stroke widths are the originals' 1, not the codicons' 1.6.
  const widths = [...src.matchAll(/drawn\([^)]*?,\s*"([\d.]+)"\)/g)].map((m) => m[1]);
  for (const w of widths) expect(w).toBe("1");
});

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
  const buttonClass = buttonClassesFromView().text;
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

/**
 * THE TWO SURFACES DRAW THEIR ICON BUTTONS THE SAME WAY.
 *
 * Two more reports, both about the same pair of buttons:
 *
 *   * *"The debugging control icons designed by our designer don't have
 *     rectangular frames. The icons you created for the build and run tests
 *     operations should not have either."*
 *   * *"The foreground color of the vector shapes is also slightly different
 *     I think."*
 *
 * WHERE THE FRAME CAME FROM, AND WHY NO AMOUNT OF READING THE MARKS FOUND IT.
 * `edit_toolbar_marks.nim` emits two paths per mark and no rectangle. The
 * frame was the BUTTON's border: both surfaces carry
 * `ct-button-image-md-secondary`, `[class*="-button-"][class*="-secondary"]`
 * gives that a `border: 0.03125em solid colors-ui-border-primary`, and the
 * debugger strip cancels it per button with `ct-button-no-border` — twelve
 * times, in `isonim_debug_controls_view`. This bar never adopted that half of
 * the convention, so it computed `border: 1px solid rgb(86, 86, 86)` against
 * the strip's `0px none`.
 *
 * WHY THE COLOUR IS ASSERTED AS A PARITY AND NOT AS A VALUE.
 * The marks paint `currentColor` in both channels, so their colour is
 * whatever the button's `color` resolves to. Writing the expected rgb here
 * would pin a design token into a test file and go stale the first time the
 * palette moves. Comparing the two SURFACES answers the actual question —
 * "are these the same colour as the designer's?" — and stays true across any
 * repalette. The reported difference was never a baked colour: there is no
 * hex literal in the marks module, which the mutation arm above already
 * guards, and both surfaces computed the identical rgb before this change.
 *
 * BOTH BARS ARE MOUNTED IN ONE PAGE, under the `#isonim-debug-controls` host
 * they really share, because a value read from two separate page loads is two
 * measurements that were never compared.
 */
test.describe("edit toolbar and debugger strip agree", () => {
  const DEBUG_BUTTON_CLASS = "ct-button-image-md-secondary ct-button-no-border";

  async function mountBoth(page: any, themeCss: string) {
    const { icon } = buttonClassesFromView();
    const markClass = markClassFromSource();
    const mark = `<svg class="${markClass}" viewBox="0 0 16 16">` +
      `<path d="M2 2L14 14" fill="none" stroke="currentColor" stroke-width="1"/></svg>`;

    await page.setContent(
      `<div id="menu" class="menu"><div id="isonim-debug-controls">` +
        `<div class="ct-header isonim-debug-controls" ` +
        `data-topbar-surface="debugger-controls">` +
        `<button id="dbg" class="${DEBUG_BUTTON_CLASS}">${mark}</button>` +
        `</div>` +
        `<div class="ct-header edit-mode-toolbar" ` +
        `data-topbar-surface="edit-commands" data-button-count="2">` +
        `<div class="separate-bar"></div>` +
        `<button id="edit" class="${icon}">${mark}</button>` +
        `</div></div></div>`,
      { waitUntil: "domcontentloaded" },
    );
    await page.addStyleTag({ path: themeCss });
    await page.evaluate(
      () => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))),
    );

    return page.evaluate(() => {
      const read = (id: string) => {
        const el = document.getElementById(id)!;
        const cs = getComputedStyle(el);
        const path0 = el.querySelector("svg path")!;
        return {
          borderWidth: cs.borderWidth,
          borderStyle: cs.borderStyle,
          color: cs.color,
          stroke: getComputedStyle(path0).stroke,
        };
      };
      return { dbg: read("dbg"), edit: read("edit") };
    });
  }

  for (const theme of THEMES) {
    test(`icon buttons carry no frame (${theme.name})`, async ({ page }) => {
      const m = await mountBoth(page, resolveThemeCss(theme.css));

      // The designer's bar, stated first so a change there is a failure here
      // rather than a silently moved goalpost.
      expect(
        m.dbg.borderWidth,
        "the debugger strip is the reference and must draw no frame",
      ).toBe("0px");

      // The report, as the number that showed it. `1px` is what shipped.
      expect(
        m.edit.borderWidth,
        `the edit toolbar's icon button draws a ${m.edit.borderWidth} ` +
          `${m.edit.borderStyle} frame; the debugger strip's draws none`,
      ).toBe(m.dbg.borderWidth);
      expect(m.edit.borderStyle).toBe(m.dbg.borderStyle);
    });

    test(`marks inherit the same foreground on both surfaces (${theme.name})`, async ({
      page,
    }) => {
      const m = await mountBoth(page, resolveThemeCss(theme.css));

      // `currentColor` is only as good as the `color` it resolves against, so
      // both are asserted: the button's colour, and that the mark actually
      // took it rather than falling back to the initial `black`.
      expect(
        m.edit.color,
        `the edit toolbar's buttons are ${m.edit.color}, the debugger ` +
          `strip's are ${m.dbg.color}`,
      ).toBe(m.dbg.color);
      expect(m.edit.stroke, "the mark did not inherit the button's colour")
        .toBe(m.edit.color);
      expect(m.dbg.stroke).toBe(m.dbg.color);
    });
  }

  test("verify the frame check can fail", async ({ page }) => {
    // The class the view emitted before this change: the `-secondary` border
    // with nothing cancelling it. Reproduced rather than described, so the
    // assertion above is watched failing against the markup that shipped.
    const themeCss = resolveThemeCss(THEMES[0].css);
    await page.setContent(
      `<div id="menu" class="menu"><div id="isonim-debug-controls">` +
        `<div class="ct-header edit-mode-toolbar">` +
        `<button id="shipped" class="ct-button-image-md-secondary edit-toolbar-button">` +
        `<svg viewBox="0 0 16 16"><path d="M2 2L14 14"/></svg></button>` +
        `</div></div></div>`,
      { waitUntil: "domcontentloaded" },
    );
    await page.addStyleTag({ path: themeCss });
    await page.evaluate(
      () => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))),
    );

    const shipped = await page.evaluate(() => {
      const cs = getComputedStyle(document.getElementById("shipped")!);
      return { borderWidth: cs.borderWidth, borderStyle: cs.borderStyle };
    });

    // The frame the report was pointing at, in numbers.
    expect(shipped.borderWidth, "the shipped class must draw a frame, or the " +
      "check above proves nothing").toBe("1px");
    expect(shipped.borderStyle).toBe("solid");
  });
});
