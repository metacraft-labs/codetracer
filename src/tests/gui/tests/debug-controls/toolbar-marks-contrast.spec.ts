/**
 * Guard: every mark on the debugger control strip is PAINTED, on the right
 * control, in both themes.
 *
 * WHY THIS EXISTS, AND WHY MARKUP ASSERTIONS DID NOT CATCH IT.
 * The twelve marks on this bar used to be twelve `.svg` files pulled in by
 * `background-image` from `default_dark_theme.styl`. Every one of them baked
 * its colour into the file (`#DDDDDD`, a near-white for a dark background),
 * and `default_white_theme.styl` defined none of the variables that named
 * them. Stylus passes an unknown identifier through as a bare literal rather
 * than failing, so the white theme's built CSS carried
 * `background-image: ct-images-continue` — which no browser can parse and
 * every browser drops. The most-used control strip in the product rendered
 * twelve blank buttons on that theme, and had done for as long as the theme
 * has existed.
 *
 * Nothing noticed, because everything that looked at this bar looked at
 * MARKUP. The buttons were present, had the right ids, were the right size,
 * and clicked correctly; `live-mcr-debug-controls-storybook.spec.ts` drives
 * them and passes on a bar with no glyphs at all. A markup assertion passes
 * happily on an invisible icon — that is precisely how this survived.
 *
 * So this spec refuses to look at markup for the thing it is guarding. It
 * asks the browser what colour each mark is actually painted, asks what
 * colour it is painted ON, and computes the contrast ratio between them. A
 * mark that is absent, transparent, or the same colour as its background
 * fails here and cannot be made to pass by adding an element.
 *
 * WHAT IT MEASURES
 *   1. The strip carries exactly `EXPECTED_MARK_COUNT` marks. The count is a
 *      literal here, not `marks.length` — see `verify_the_count_check_can_
 *      fail`, which runs the same check over a strip with a mark removed.
 *   2. Every mark's `d` is read back and matched to the command its button
 *      sends, so a bar of twelve correct-looking buttons cannot hide a glyph
 *      sitting on the wrong control.
 *   3. Every mark has a non-zero painted box.
 *   4. Every mark's computed fill/stroke against its button's computed
 *      background clears WCAG 1.4.11 (3:1 for a user-interface graphic), in
 *      BOTH themes.
 *   5. The inert treatment is a COLOUR change and not opacity alone — which
 *      is what `button:disabled` silently failed to do while it named a
 *      token (`colors-ui-text-disabled-default`) that was never defined.
 *
 * WHAT IT TRUSTS. The built theme CSS in `src/build-debug/frontend/styles`
 * and the built `storybook/dist/components.js`, which is the REAL Nim view —
 * not a transcription of it. A stale bundle is caught by the mtime guard in
 * `resolveComponentsBundle`; a stale stylesheet is not detectable from here.
 */

import { test, expect } from "@playwright/test";
import * as fs from "fs";
import * as path from "path";

const REPO_ROOT = path.resolve(__dirname, "../../../../..");

/**
 * How many marks the strip has, written down independently of the table that
 * produces them.
 *
 * This is deliberately a literal. Comparing a collection's length against
 * itself passes for every collection, including an empty one, so it can
 * never notice a mark being dropped. It must agree with `ControlMarkCount`
 * in `src/frontend/viewmodel/views/debug_control_marks.nim`, and
 * `verify_the_count_check_can_fail` proves the comparison bites.
 */
const EXPECTED_MARK_COUNT = 12;

/**
 * Each control, and a fragment that must appear in its mark's path data.
 *
 * The fragments are the opening move of each `d`, which is enough to tell
 * the twelve apart and short enough that reformatting the source does not
 * churn this list. They are matched against the mark found on the button
 * that sends the named command, so this table is what makes "the right glyph
 * is on the right control" a measurable claim rather than a hope.
 *
 * THIS TABLE IS ABOUT ROUTING, NOT ABOUT DESIGN. It exists to catch a mark
 * landing on the wrong button, which is invisible from a screenshot of a bar
 * whose glyphs all look plausible. It is not a record of which drawings the
 * product ought to have, and it must be updated — not defended — when the
 * artwork legitimately changes. The eight stepping marks below are the
 * drawings CodeTracer had before `93be377c`, restored in
 * `debug_control_marks.nim`; the alignment with BlockTracer's set that
 * commit made was not wanted here.
 */
const MARK_SIGNATURES: ReadonlyArray<{ action: string; startsWith: string }> = [
  { action: "history-back", startsWith: "M11.5 15L4.5 8L11.5 1" },
  { action: "history-forward", startsWith: "M4.5 1L11.5 8L4.5 15" },
  { action: "reverse-next", startsWith: "M1.5 1.65625H14.5" },
  { action: "next", startsWith: "M1.5 14.3438H14.5" },
  { action: "reverse-step-in", startsWith: "M6.88662 0.342773L2.20669 5.3123" },
  { action: "step-in", startsWith: "M9.61338 14.4643L14.2933 9.49477" },
  { action: "reverse-step-out", startsWith: "M9.96574 14.4643L14.8266 9.49477" },
  { action: "step-out", startsWith: "M7.09078 0.349609L2.2299 5.31913" },
  { action: "reverse-continue", startsWith: "M8 4C9.10457 4 10 3.10457 10 2" },
  { action: "continue", startsWith: "M8 12C9.10457 12 10 12.8954 10 14" },
  { action: "run-to-entry", startsWith: "M16 14L5.33333 14" },
  { action: "reset-operation", startsWith: "M9.38451 0.379639" },
];

/** The two themes a user can actually be looking at. */
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
      `src/frontend/styles/${file.replace(/\.css$/, ".styl")}\n` +
      `NOTE: \`default_white_theme_electron\` is absent from repro.nim's ` +
      `StylusCssEntryPoints, so a macOS \`just build-once\` does not produce it.`,
  );
}

function resolveComponentsBundle(): string {
  const bundle = path.join(REPO_ROOT, "storybook/dist/components.js");
  if (!fs.existsSync(bundle)) {
    throw new Error(
      `storybook/dist/components.js is missing. Run: just build-storybook-components`,
    );
  }
  // The bundle IS the view under test. A stale one would measure the previous
  // toolbar and report green on a change that never reached a browser.
  const view = path.join(
    REPO_ROOT,
    "src/frontend/viewmodel/views/isonim_debug_controls_view.nim",
  );
  const marks = path.join(
    REPO_ROOT,
    "src/frontend/viewmodel/views/debug_control_marks.nim",
  );
  const bundleAge = fs.statSync(bundle).mtimeMs;
  for (const src of [view, marks]) {
    if (fs.existsSync(src) && fs.statSync(src).mtimeMs > bundleAge) {
      throw new Error(
        `storybook/dist/components.js is older than ${path.basename(src)}. ` +
          `Run: just build-storybook-components`,
      );
    }
  }
  return bundle;
}

/**
 * Mount the real toolbar under one theme and return everything measured.
 *
 * The colour work happens in the page because only the browser can resolve
 * `currentColor`, cascade `!important`, and composite a transparent
 * background over its ancestors.
 */
async function measureStrip(page: any, themeCss: string, bundle: string) {
  await page.setContent(
    `<div id="host" class="ct-header"></div>`,
    { waitUntil: "domcontentloaded" },
  );
  await page.addStyleTag({ path: themeCss });
  await page.addScriptTag({ path: bundle });

  return await page.evaluate(() => {
    const host = document.getElementById("host")!;
    // The real Nim view, not a transcription of it.
    (window as any).mountCodeTracerStory(
      host,
      "panel",
      "debug-controls",
      "live-mcr",
    );

    const parseRgb = (s: string): [number, number, number, number] => {
      const m = s.match(/rgba?\(([^)]+)\)/);
      if (!m) return [0, 0, 0, 0];
      const p = m[1].split(",").map((x) => parseFloat(x.trim()));
      return [p[0], p[1], p[2], p.length > 3 ? p[3] : 1];
    };

    const over = (
      fg: [number, number, number, number],
      bg: [number, number, number, number],
    ): [number, number, number, number] => {
      const a = fg[3];
      return [
        fg[0] * a + bg[0] * (1 - a),
        fg[1] * a + bg[1] * (1 - a),
        fg[2] * a + bg[2] * (1 - a),
        1,
      ];
    };

    /** Composite backgrounds up the tree until something is opaque. */
    const effectiveBackground = (
      el: Element,
    ): [number, number, number, number] => {
      const stack: [number, number, number, number][] = [];
      let node: Element | null = el;
      while (node) {
        const c = parseRgb(getComputedStyle(node).backgroundColor);
        if (c[3] > 0) stack.push(c);
        if (c[3] >= 1) break;
        node = node.parentElement;
      }
      // Default to white: an unpainted page is white, and assuming the
      // darker default would flatter a light-coloured mark.
      let acc: [number, number, number, number] = [255, 255, 255, 1];
      for (let i = stack.length - 1; i >= 0; i--) acc = over(stack[i], acc);
      return acc;
    };

    const luminance = (c: [number, number, number, number]) => {
      const f = (v: number) => {
        const s = v / 255;
        return s <= 0.03928 ? s / 12.92 : Math.pow((s + 0.055) / 1.055, 2.4);
      };
      return 0.2126 * f(c[0]) + 0.7152 * f(c[1]) + 0.0722 * f(c[2]);
    };

    const contrast = (
      a: [number, number, number, number],
      b: [number, number, number, number],
    ) => {
      const la = luminance(a);
      const lb = luminance(b);
      return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
    };

    const marks = Array.from(host.querySelectorAll("svg.ct-control-mark"));
    const results = marks.map((svg) => {
      const button = svg.closest("button")!;
      const paths = Array.from(svg.querySelectorAll("path"));
      // The painted colour: whichever channel the shape actually uses.
      const cs = getComputedStyle(paths[0]);
      const fill = parseRgb(cs.fill);
      const stroke = parseRgb(cs.stroke);
      const ink = fill[3] > 0 ? fill : stroke;
      const bg = effectiveBackground(button);
      const box = svg.getBoundingClientRect();
      return {
        action: svg.getAttribute("data-mark"),
        buttonId: button.id,
        ds: paths.map((p) => p.getAttribute("d") || ""),
        // Every channel used by every path, so a shape painted `none` in
        // both cannot hide behind a sibling that is painted.
        inks: paths.map((p) => {
          const s = getComputedStyle(p);
          const f = parseRgb(s.fill);
          return f[3] > 0 ? s.fill : s.stroke;
        }),
        ink: `rgb(${ink[0]}, ${ink[1]}, ${ink[2]})`,
        background: `rgb(${bg[0]}, ${bg[1]}, ${bg[2]})`,
        contrast: Math.round(contrast(ink, bg) * 100) / 100,
        width: box.width,
        height: box.height,
        disabled: button.hasAttribute("disabled"),
      };
    });

    // The inert treatment, measured rather than assumed: force one control
    // disabled and read the colour the cascade actually gives it.
    const probe = host.querySelector("#continue-image") as HTMLElement | null;
    let enabledInk: string | null = null;
    let disabledInk: string | null = null;
    if (probe) {
      probe.removeAttribute("disabled");
      enabledInk = getComputedStyle(probe).color;
      probe.setAttribute("disabled", "true");
      disabledInk = getComputedStyle(probe).color;
      probe.removeAttribute("disabled");
    }

    return { results, enabledInk, disabledInk, buttonCount: host.querySelectorAll("button").length };
  });
}

for (const theme of THEMES) {
  test(`debugger toolbar marks are painted and legible — ${theme.name} theme`, async ({
    page,
  }) => {
    const css = resolveThemeCss(theme.css);
    const bundle = resolveComponentsBundle();
    const { results } = await measureStrip(page, css, bundle);

    // 1. The strip is complete. Against a literal, not against itself.
    expect(
      results.length,
      `the strip should carry ${EXPECTED_MARK_COUNT} marks; a silently ` +
        `dropped control must not read as a pass`,
    ).toBe(EXPECTED_MARK_COUNT);

    // 2. Every command's mark is the mark for that command.
    for (const sig of MARK_SIGNATURES) {
      const found = results.find((r: any) => r.action === sig.action);
      expect(found, `no mark for '${sig.action}'`).toBeTruthy();
      const matches = found!.ds.some((d: string) =>
        d.startsWith(sig.startsWith),
      );
      expect(
        matches,
        `the mark on '${sig.action}' (button #${found!.buttonId}) does not ` +
          `carry its own path — got ${JSON.stringify(found!.ds)}`,
      ).toBe(true);
    }

    // 3 & 4. Painted, and legible against what it is painted on.
    for (const r of results) {
      expect(r.width, `mark '${r.action}' has no width`).toBeGreaterThan(0);
      expect(r.height, `mark '${r.action}' has no height`).toBeGreaterThan(0);
      for (const ink of r.inks) {
        expect(
          ink,
          `a path of mark '${r.action}' is painted in no channel`,
        ).not.toMatch(/rgba?\([^)]*,\s*0\)$/);
        expect(ink, `a path of mark '${r.action}' is unpainted`).not.toBe(
          "none",
        );
      }
      expect(
        r.contrast,
        `mark '${r.action}' is ${r.ink} on ${r.background} — ` +
          `${r.contrast}:1, below the 3:1 WCAG 1.4.11 asks of a UI graphic`,
      ).toBeGreaterThanOrEqual(3);
    }
  });

  test(`the inert treatment is a colour change, not opacity alone — ${theme.name} theme`, async ({
    page,
  }) => {
    const css = resolveThemeCss(theme.css);
    const bundle = resolveComponentsBundle();
    const { enabledInk, disabledInk } = await measureStrip(page, css, bundle);

    expect(enabledInk).toBeTruthy();
    // `button:disabled` named `colors-ui-text-disabled-default`, a token that
    // is defined nowhere. Stylus emitted it as a bare literal, the browser
    // dropped the declaration, and a disabled control kept the enabled
    // colour and was told apart by `opacity` alone. The marks inherit this
    // colour, so this declaration IS their inert treatment.
    expect(
      disabledInk,
      `a disabled control paints ${disabledInk}, the same as an enabled one — ` +
        `the disabled colour rule is being dropped`,
    ).not.toBe(enabledInk);
  });
}

test("verify_the_count_check_can_fail", async ({ page }) => {
  // The trap this arm exists to close: a count compared against the length of
  // the very collection it came from passes for any collection, and a suite
  // in which every case happens to have the same length never notices. So
  // here is a case whose count differs — the identical assertion, over a
  // strip with one mark removed, must fail.
  const css = resolveThemeCss(THEMES[0].css);
  const bundle = resolveComponentsBundle();
  await page.setContent(`<div id="host" class="ct-header"></div>`, {
    waitUntil: "domcontentloaded",
  });
  await page.addStyleTag({ path: css });
  await page.addScriptTag({ path: bundle });

  const counts = await page.evaluate(() => {
    const host = document.getElementById("host")!;
    (window as any).mountCodeTracerStory(
      host,
      "panel",
      "debug-controls",
      "live-mcr",
    );
    const before = host.querySelectorAll("svg.ct-control-mark").length;
    host.querySelector("svg.ct-control-mark")!.remove();
    const after = host.querySelectorAll("svg.ct-control-mark").length;
    return { before, after };
  });

  expect(counts.before).toBe(EXPECTED_MARK_COUNT);
  expect(counts.after).toBe(EXPECTED_MARK_COUNT - 1);
  // The assertion the other tests make, over the short strip: it must reject.
  expect(() =>
    expect(counts.after).toBe(EXPECTED_MARK_COUNT),
  ).toThrow();
});
