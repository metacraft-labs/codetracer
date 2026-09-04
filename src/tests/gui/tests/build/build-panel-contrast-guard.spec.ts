/**
 * Guard: every text tier in the BUILD output panel must be readable against
 * the panel's own surface, in every theme the product ships.
 *
 * WHAT WAS REPORTED, AND WHAT IT MEASURED.  *"The text in the build output
 * panel is hardly readable due to low contrast issues."*  Measured in Chromium
 * against the compiled theme, on `colors-ui-surface-base-panel` (`#282828`):
 *
 *     tier                                     web       Electron
 *     `.build-output-line` (located, no sev)   1.42:1    1.05:1
 *     `.build-command-label` (idle/running)    1.42:1    1.05:1
 *     `.build-stderr` / `.build-line-error`    4.40:1    4.40:1
 *     `.build-stop-btn.disabled`               1.30:1    1.30:1
 *
 * The first two were never chosen.  `.build-panel` declared a
 * `background-color` and no `color`, `#build` likewise, and no ancestor
 * between them and `body` declares one either — BUILD is a STANDALONE
 * auto-hide pane reparented into `#auto-hide-overlay-content`, so it never
 * enters `.lm_goldenlayout` and never picks up that sheet's colour.  On the
 * web the inherited value is the user-agent `canvastext` → BLACK; in the
 * desktop shell `index.html` loads Bootstrap AFTER the theme and Bootstrap
 * declares `body { color: #212529 }`, which is worse.  This is the THIRD
 * report of this exact shape — the status bar footer (1.22:1) and the debug
 * toolbar marks were the first two — and in all three the colour was
 * inherited or defaulted rather than picked against a measured surface.
 *
 * WHY A SEPARATE SPEC FROM `status-bar/footer-contrast-guard.spec.ts`.  Same
 * machinery, different surface: this one measures `#282828`, that one
 * `#1b1b1b`, and the two share `page-objects/status-footer-contrast.ts` rather
 * than a fourth copy of the sRGB luminance formula.  Like its neighbour it
 * needs no Electron, no `ct`, no recorded trace — it applies the BUILT theme
 * stylesheet to the panel's own markup in a plain browser page.
 *
 * IT RUNS BOTH THEMES, and the answer is more interesting than "both pass".
 * `colors-*` are Stylus compile-time variables and neither
 * `default_white_theme.styl` nor `default_dark_theme.styl` redefines one, so
 * the compiled `.build-panel` block is byte-identical in the light and dark
 * builds — the panel is a dark island in the light theme.  That is asserted
 * directly by `verify_the_light_theme_is_not_a_different_panel`, so the day a
 * Light-mode token set does land, this file goes red rather than quietly
 * measuring the dark theme twice and reporting it as coverage.
 *
 * WHAT MAKES IT A GATE RATHER THAN A THRESHOLD.  A minimum nothing can violate
 * is not a check.  Two arms re-paint the panel with the colours that actually
 * shipped — `verify_the_guard_refuses_the_hexes_that_shipped` puts `#f85149`
 * and the `opacity: 0.3` stop button back, and
 * `verify_the_guard_refuses_the_colour_that_was_never_chosen` reverts the base
 * `color` so the subtree inherits the user-agent default again — and each
 * asserts the guard names the specific tiers it found.
 *
 * WHERE IT STOPS is `contrastFailures`' own limits, documented there: asset-
 * painted colour is invisible to it, it measures against the nearest OPAQUE
 * ancestor background, and a ratio is not a legibility judgement.  The two
 * translucent hover scrims in this panel are the one place that matters here,
 * and they are measured explicitly rather than skipped.
 */

import fs from "node:fs";
import path from "node:path";
import { expect, test, type Page } from "@playwright/test";

import {
  contrastFailures,
  formatContrastTable,
  probeBarContrast,
  type ContrastRegion,
} from "../../page-objects/status-footer-contrast";

/** Repo root, from `src/tests/gui/tests/build`. */
const repoRoot = path.resolve(__dirname, "../../../../..");

/** The Nim view this fixture must keep matching. */
const BUILD_VIEW = path.join(
  repoRoot,
  "src/frontend/viewmodel/views/isonim_build_view.nim",
);

/**
 * Where a built theme can be.  Mirrors `candidateStyleDirs` in
 * `status-bar/footer-visibility-css-guard.spec.ts`; see
 * `codetracer-specs/Architecture/Build-Outputs-And-Path-Resolution.md`.
 */
function candidateStyleDirs(): string[] {
  const dirs: string[] = [];
  if (process.env.CODETRACER_BUILD_DIR) {
    dirs.push(path.join(process.env.CODETRACER_BUILD_DIR, "frontend", "styles"));
  }
  dirs.push(path.join(repoRoot, "src", "build-debug", "frontend", "styles"));
  if (process.env.CODETRACER_E2E_CT_PATH) {
    dirs.push(
      path.join(
        path.dirname(path.dirname(process.env.CODETRACER_E2E_CT_PATH)),
        "frontend",
        "styles",
      ),
    );
  }
  return dirs;
}

/**
 * The themes whose compiled output carries this panel.
 *
 * `default_white_theme_electron.css` is here and the sibling visibility guard
 * omits it, deliberately: that guard's list is the three DARK shells, and the
 * whole question this spec exists to answer is what the panel looks like in
 * the theme nobody checked.  (`default_white_theme.css` is still excluded —
 * its `.styl` imports `defaults` only and carries no component rules at all.)
 */
const THEMES = [
  "default_dark_theme_electron.css",
  "default_dark_theme_extension.css",
  "default_white_theme_electron.css",
] as const;

function resolveTheme(theme: string): string {
  const tried: string[] = [];
  for (const dir of candidateStyleDirs()) {
    const candidate = path.join(dir, theme);
    tried.push(candidate);
    if (fs.existsSync(candidate)) return candidate;
  }
  throw new Error(
    `built theme stylesheet \`${theme}\` not found — run \`just build-once\` ` +
      `after editing any \`.styl\`, or this measures the previous build. ` +
      `Looked in:\n  ${tried.join("\n  ")}`,
  );
}

/**
 * The panel as `renderBuildPanel(r: WebRenderer; vm: BuildVM)` emits it,
 * under the ancestors `viewmodel/platform/web_deployment.nim` writes for
 * `/noir/demo` and `auto_hide.doShowOverlayImpl` reparents it into.
 *
 * The ancestry is part of the fixture and not decoration: the defect WAS the
 * ancestry.  Mounting `.build-panel` straight into `<body>` would still
 * inherit black and still reproduce, but it would stop reproducing the moment
 * someone "fixed" this by colouring `#auto-hide-overlay-content` — and the
 * panel would still be black in the docked and GoldenLayout hosts.
 *
 * Three panels because a build has three header states and each paints
 * differently; `id="build"` is on one of them because the view gives the
 * output container that id and ids must stay unique.
 */
const PANEL_MARKUP = `
<div id="dom-root"><div id="root-container">
  <div id="auto-hide-overlay" class="visible auto-hide-overlay-bottom" style="display:flex; height:520px">
    <div id="auto-hide-overlay-header"><span id="auto-hide-overlay-title">BUILD</span></div>
    <div id="auto-hide-overlay-body" style="display:flex; flex-direction:column; flex:1; min-height:0">
      <div id="auto-hide-overlay-content" style="flex:1; min-height:0; display:flex; flex-direction:column">

        <div class="build-panel isonim-build" id="panel-running" style="height:auto">
          <div class="build-header">
            <div class="build-command-label">running nargo build</div>
            <div class="build-header-controls">
              <div class="build-ctrl-btn build-run-btn" title="Run build (no re-record)">&#9654;</div>
              <div class="build-ctrl-btn build-stop-btn disabled" title="Stop build">&#9632;</div>
              <div class="build-ctrl-btn build-clear-btn" title="Clear build output">&#10005;</div>
              <div class="build-ctrl-btn build-scroll-btn active" title="Toggle auto-scroll">&#8595;</div>
              <div class="build-duration">nargo build</div>
            </div>
          </div>
        </div>

        <div class="build-panel isonim-build" id="panel-succeeded" style="height:auto">
          <div class="build-header build-succeeded">
            <div class="build-command-label">build succeeded</div>
          </div>
        </div>

        <div class="build-panel isonim-build" id="panel-failed">
          <div class="build-header build-failed">
            <div class="build-command-label">build failed (exit code 1)</div>
          </div>
          <div id="build" class="build-output-container">
            <div class="build-stdout">   Compiling hello_noir v0.1.0</div>
            <div class="build-stderr">error: Expected type Field, found u32</div>
            <div class="build-output-line build-clickable">src/main.nr:3:5: note: expanded from here</div>
            <div class="build-output-line build-clickable build-line-error">src/main.nr:7:1: error: expected type</div>
            <div class="build-output-line build-clickable build-line-warning">src/main.nr:9:2: warning: unused import</div>
            <div class="build-output-line build-clickable build-line-info">src/main.nr:11:3: info: inlined</div>
          </div>
        </div>

      </div>
    </div>
  </div>
</div></div>`;

/**
 * Every tier in the panel that CSS paints, and what the reader loses if it is
 * unreadable.
 *
 * Derived from `lineClass` / `headerClass` / `stopButtonClass` /
 * `scrollButtonClass` in `isonim_build_view.nim` — i.e. from what the view can
 * emit, not from what the stylesheet happens to declare.  That distinction is
 * the whole finding: `.build-output-line` with no severity is a class the view
 * emits and NO stylesheet rule coloured, and a list derived from the
 * stylesheet could not contain it.
 *
 * All of these are `kind: "text"` — every one is prose or a text glyph the
 * user reads, so all are held to 4.5:1.  The control glyphs (`▶ ■ ✕ ↓`) are
 * `<div>`s carrying text, not images, so `icon`'s 3:1 relaxation would be the
 * wrong threshold for them.
 */
const BUILD_PANEL_REGIONS: readonly ContrastRegion[] = [
  {
    selector: "#panel-running .build-command-label",
    kind: "text",
    paintedBy: "color",
    why: "the header line that says whether a build is running and what command it ran — one of the two tiers that inherited the user-agent default",
  },
  {
    selector: "#panel-failed .build-header.build-failed .build-command-label",
    kind: "text",
    paintedBy: "color",
    why: "the line that reports the build failed and its exit code",
  },
  {
    selector: "#panel-succeeded .build-header.build-succeeded .build-command-label",
    kind: "text",
    paintedBy: "color",
    why: "the line that reports the build succeeded",
  },
  {
    selector: "#panel-running .build-duration",
    kind: "text",
    paintedBy: "color",
    why: "the command readout beside the controls",
  },
  {
    selector: "#panel-running .build-run-btn",
    kind: "text",
    paintedBy: "color",
    why: "the Run-build control; unreadable means the user cannot find the button that re-runs a build",
  },
  {
    selector: "#panel-running .build-stop-btn.disabled",
    kind: "text",
    paintedBy: "color",
    why: "the Stop control in its disabled state — an `opacity: 0.3` on top of a translucent red drove this to 1.30:1",
  },
  {
    selector: "#panel-running .build-scroll-btn.active",
    kind: "text",
    paintedBy: "color",
    why: "the auto-scroll toggle when it is on; this glyph IS the only indication of that state",
  },
  {
    selector: "#build .build-stdout",
    kind: "text",
    paintedBy: "color",
    why: "plain compiler stdout — the bulk of what the panel is for",
  },
  {
    selector: "#build .build-stderr",
    kind: "text",
    paintedBy: "color",
    why: "compiler stderr, which is where a failing build says why",
  },
  {
    // A located line whose severity parsed as `blsNone`: `lineClass` emits
    // `build-output-line build-clickable` and no severity class.  `:not()`
    // rather than a marker class, because the fixture may only contain
    // attributes the view itself writes.
    selector:
      "#build .build-output-line:not(.build-line-error):not(.build-line-warning):not(.build-line-info)",
    kind: "text",
    paintedBy: "color",
    why: "a clickable compiler line that carries a file:line but no severity keyword — notes, expansion traces, `-->` context lines; this is the tier that measured 1.05:1",
  },
  {
    selector: "#build .build-line-error",
    kind: "text",
    paintedBy: "color",
    why: "an error line the user clicks to jump to the offending source location",
  },
  {
    selector: "#build .build-line-warning",
    kind: "text",
    paintedBy: "color",
    why: "a warning line the user clicks to jump to the offending source location",
  },
  {
    selector: "#build .build-line-info",
    kind: "text",
    paintedBy: "color",
    why: "an informational line the user clicks to jump to a source location",
  },
];

/** Lay the panel out under `theme`, optionally with `extraCss` appended after it. */
async function layOutPanel(
  page: Page,
  theme: string,
  extraCss?: string,
): Promise<void> {
  await page.setContent(
    `<!doctype html><html><body>${PANEL_MARKUP}</body></html>`,
  );
  await page.addStyleTag({ path: resolveTheme(theme) });
  if (extraCss !== undefined) await page.addStyleTag({ content: extraCss });
  await page.evaluate(
    () => new Promise<void>((resolve) => requestAnimationFrame(() => resolve())),
  );
}

/**
 * The panel exactly as it shipped before this guard existed, as CSS.
 *
 * Not a made-up bad colour: these are the declarations lifted from
 * `components/status_bar.styl` at `a314d146b`, which is what makes the
 * negative control worth having.  `!important` only because it is appended to
 * the same cascade and has to beat an ID selector.
 */
const SHIPPED_HEXES_CSS = `
  .build-panel .build-header.build-failed { color: #f85149 !important; }
  .build-panel .build-stop-btn { color: rgba(248, 81, 73, 0.7) !important; }
  .build-panel .build-ctrl-btn.disabled { opacity: 0.3 !important; }
  #build .build-stderr { color: #f85149 !important; }
  #build .build-line-error { color: #f85149 !important; }
`;

/**
 * The other half of what shipped: no `color` anywhere in the subtree, so the
 * uncoloured tiers fall back to the user-agent origin.  `revert` is the
 * shortest exact spelling of "this declaration was never written".
 */
const NEVER_CHOSEN_CSS = `
  .build-panel,
  #build,
  #build .build-output-line,
  .build-panel .build-header { color: revert !important; }
`;

test.describe("build panel contrast (WCAG 1.4.3), /noir/demo BUILD pane", () => {
  for (const theme of THEMES) {
    test(`verify_every_build_panel_tier_clears_AA__${theme.replace(/\W+/g, "_")}`, async ({
      page,
    }) => {
      await layOutPanel(page, theme);
      const probes = await probeBarContrast(page, BUILD_PANEL_REGIONS);

      // Say this first: a table of regions that resolved to nothing would make
      // every ratio below vacuously fine.
      expect(
        probes.filter((p) => !p.found).map((p) => p.selector),
        "every guarded tier must resolve in the panel markup — if one does " +
          "not, PANEL_MARKUP has drifted from isonim_build_view.nim and this " +
          "spec is measuring nothing",
      ).toEqual([]);

      expect(
        contrastFailures(probes, BUILD_PANEL_REGIONS),
        `build panel tiers below 4.5:1 in ${theme}\n\n` +
          formatContrastTable(probes),
      ).toEqual([]);
    });
  }

  test("verify_the_light_theme_is_not_a_different_panel", async ({ page }) => {
    // `colors-*` are Stylus compile-time variables and no theme redefines one,
    // so this panel compiles identically into the light and dark builds. That
    // is a fact worth asserting rather than assuming: it is the reason "we
    // checked both themes" above is honest, and the day it stops being true is
    // the day the light-theme numbers have to be re-derived instead of
    // inherited from the dark run.
    await layOutPanel(page, "default_dark_theme_electron.css");
    const dark = await probeBarContrast(page, BUILD_PANEL_REGIONS);

    await layOutPanel(page, "default_white_theme_electron.css");
    const light = await probeBarContrast(page, BUILD_PANEL_REGIONS);

    const shape = (probes: typeof dark) =>
      probes.map((p) => `${p.selector} ${p.composited} on ${p.background}`);

    expect(
      shape(light),
      "the white theme redefines no `colors-*` token today, so the BUILD " +
        "panel is the same ink on the same `#282828` in both builds. If this " +
        "fails, a Light-mode palette has landed and every ratio in this file " +
        "must be re-measured against it rather than assumed from the dark run.",
    ).toEqual(shape(dark));
  });

  test("verify_the_guard_refuses_the_hexes_that_shipped", async ({ page }) => {
    await layOutPanel(
      page,
      "default_dark_theme_electron.css",
      SHIPPED_HEXES_CSS,
    );
    const probes = await probeBarContrast(page, BUILD_PANEL_REGIONS);
    const failures = contrastFailures(probes, BUILD_PANEL_REGIONS);
    const named = failures.map((f) => f.split(":")[0]);

    // `#f85149` is 4.40:1 on `#282828` — it misses AA by a tenth, which is
    // exactly the kind of near-miss an eyeball approves and a gate must not.
    expect(
      named.sort(),
      "re-painting the panel with the colours that shipped must turn this " +
        `guard red, and name the tiers it found\n\n${failures.join("\n")}`,
    ).toEqual(
      [
        "#build .build-line-error",
        "#build .build-stderr",
        "#panel-failed .build-header.build-failed .build-command-label",
        "#panel-running .build-stop-btn.disabled",
      ].sort(),
    );
  });

  test("verify_the_guard_refuses_the_colour_that_was_never_chosen", async ({
    page,
  }) => {
    await layOutPanel(
      page,
      "default_dark_theme_electron.css",
      NEVER_CHOSEN_CSS,
    );
    const probes = await probeBarContrast(page, BUILD_PANEL_REGIONS);
    const failures = contrastFailures(probes, BUILD_PANEL_REGIONS);
    const named = failures.map((f) => f.split(":")[0]);

    // The two tiers that carried no `color` of their own. Reverting the base
    // declaration puts them back on the user-agent default, which is the
    // defect the user reported.
    expect(
      named,
      "removing the base `color` must turn this guard red on exactly the " +
        "tiers that have no colour of their own — if it does not, those tiers " +
        `are being coloured by something this spec has not accounted for\n\n${failures.join("\n")}`,
    ).toEqual(
      expect.arrayContaining([
        "#panel-running .build-command-label",
        "#build .build-output-line",
      ]),
    );
  });

  test("verify_the_fixture_only_uses_classes_the_view_emits", async ({}) => {
    // The measured table is only worth its ratios if the markup is the app's.
    // Read the view and require every build-* class in the fixture to appear
    // in it — a fixture that drifts measures a panel nobody ships.
    const view = fs.readFileSync(BUILD_VIEW, "utf8");
    const used = new Set(
      [...PANEL_MARKUP.matchAll(/class="([^"]+)"/g)]
        .flatMap((m) => m[1].split(/\s+/))
        .filter((c) => c.startsWith("build-") || c === "isonim-build"),
    );
    const missing = [...used].filter((c) => !view.includes(c));
    expect(
      missing,
      `these classes are in the fixture and not in ${path.relative(repoRoot, BUILD_VIEW)} — ` +
        "the fixture has drifted from the view",
    ).toEqual([]);
  });

  test("verify_the_hover_scrims_still_carry_readable_ink", async ({ page }) => {
    // The two translucent hover backgrounds are the one place in this panel
    // where `contrastFailures`' "nearest opaque ancestor" rule would give a
    // number that is right about the ancestry and wrong about the pixels. So
    // measure them against what they actually composite to, and do it here
    // rather than leaving a sentence saying they were considered.
    await layOutPanel(page, "default_dark_theme_electron.css");
    const measured = await page.evaluate(() => {
      const lin = (c: number) => {
        const s = c / 255;
        return s <= 0.03928 ? s / 12.92 : Math.pow((s + 0.055) / 1.055, 2.4);
      };
      const parse = (v: string) => {
        const p = /rgba?\(([^)]+)\)/
          .exec(v)![1]
          .split(/[,\s/]+/)
          .filter(Boolean)
          .map(Number);
        return { r: p[0], g: p[1], b: p[2], a: p.length > 3 ? p[3] : 1 };
      };
      const lum = (c: { r: number; g: number; b: number }) =>
        0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b);

      // Read the hover declarations out of the cascade rather than hardcoding
      // them, so a restyle of the scrim is measured and not ignored.
      const hoverOf = (selector: string) => {
        for (const sheet of Array.from(document.styleSheets)) {
          let rules: CSSRuleList;
          try {
            rules = sheet.cssRules;
          } catch {
            continue;
          }
          for (const rule of Array.from(rules)) {
            const r = rule as CSSStyleRule;
            if (r.selectorText === selector) {
              return {
                color: r.style.color,
                background: r.style.backgroundColor,
              };
            }
          }
        }
        return null;
      };

      const panelBg = getComputedStyle(
        document.querySelector("#panel-failed")!,
      ).backgroundColor;

      const measureOne = (selector: string) => {
        const hover = hoverOf(selector);
        if (hover === null || hover.background === "") return null;
        const base = parse(panelBg);
        const scrim = parse(hover.background);
        const composite = {
          r: scrim.r * scrim.a + base.r * (1 - scrim.a),
          g: scrim.g * scrim.a + base.g * (1 - scrim.a),
          b: scrim.b * scrim.a + base.b * (1 - scrim.a),
        };
        const ink = parse(hover.color);
        const lf = lum(ink);
        const lb = lum(composite);
        return {
          selector,
          ratio:
            Math.round(
              ((Math.max(lf, lb) + 0.05) / (Math.min(lf, lb) + 0.05)) * 100,
            ) / 100,
        };
      };

      return [
        measureOne(".build-panel .build-ctrl-btn:hover"),
        measureOne(".build-panel .build-stop-btn:hover"),
      ].filter((x) => x !== null);
    });

    expect(
      measured.length,
      "both hover rules must be found in the compiled theme — if they are " +
        "not, this check is measuring nothing",
    ).toBe(2);
    for (const m of measured) {
      expect(
        m!.ratio,
        `${m!.selector}: ${m!.ratio}:1 against the colour its own translucent ` +
          "scrim composites to over the panel",
      ).toBeGreaterThanOrEqual(4.5);
    }
  });
});
