#!/usr/bin/env node
/**
 * The DeepReview design-review capture driver (UD-0).
 *
 * This file is the SINGLE SOURCE OF TRUTH for the harness's view / size /
 * theme matrix. The shell wrapper
 * (`tools/visual-review/capture-deepreview-views.sh`), the review-prompt
 * emitter (`deepreview-review-prompt.sh`) and the contract suite
 * (`deepreview-harness-test.sh`) all learn the matrix by running this file
 * with `--list`, so a view can never exist in one place and not the others.
 *
 * WHY PLAYWRIGHT AND NOT xdotool. The docs capture
 * (`scripts/docs/capture-deep-review-screenshots.sh`) photographs the root X
 * window and crops by hard-coded pixel offsets, which is adequate for two
 * frozen images and useless for a review loop: every named view here is a
 * different UI STATE (a different file selected, a context region expanded)
 * and a different region of the window, and both have to survive the layout
 * moving underneath them. Playwright's Electron driver gives named states via
 * the same selectors the GUI suite already asserts on
 * (`src/tests/gui/tests/deepreview/page-objects/deepreview-page.ts`) and gives
 * clips derived from where an element actually is. The two scripts share the
 * expensive, fragile half — preflight, recording, dataset collection, Xvfb —
 * through `scripts/docs/deep-review-capture-lib.sh`.
 *
 * WHAT A "VIEW" IS. A named (setup, target) pair. `setup` puts the review UI
 * into a state; `target` says which part of the window is worth looking at.
 * Views are captured one app launch each, per theme, so that a mutating view
 * (context expansion) cannot contaminate the view captured after it. Viewport
 * sizes are looped INSIDE a launch, because resizing is not a mutation.
 *
 * VERIFICATION IS PART OF CAPTURE. Every view declares `verify`, a check that
 * the state it claims to have set up is actually on screen, and a failed check
 * aborts with a named error instead of writing a mislabelled PNG. This is the
 * capture-side half of the brief's "What is Expected on the Screenshot"
 * section: the brief stops a reviewer from rating a broken capture, and this
 * stops a broken capture from reaching a reviewer at all.
 *
 * Usage (normally through the shell wrapper):
 *   node capture-deepreview-views.mjs --list
 *   node capture-deepreview-views.mjs --ct <path> --dataset <dir> --out <dir> \
 *        --xdg <dir> --theme dark [--view NAME]... [--size NAME]... \
 *        [--sabotage KIND]
 */

import { _electron } from "playwright";
import fs from "node:fs";
import path from "node:path";
import process from "node:process";

// ---------------------------------------------------------------------------
// The matrix
// ---------------------------------------------------------------------------

/**
 * Viewport sizes, in Electron content-size pixels.
 *
 * `wide` is the size the product is designed at; `laptop` is the most common
 * real machine; `narrow` is the width at which a three-panel IDE layout starts
 * to fight itself, which is where diff-surface regressions show up first.
 */
export const SIZES = {
  wide: { width: 1920, height: 1080 },
  laptop: { width: 1440, height: 900 },
  narrow: { width: 1180, height: 820 },
};

/**
 * Themes, mapped to the value CodeTracer's `.config.yaml` carries in `theme:`.
 *
 * `renderer.nim`'s `loadTheme` resolves that value to
 * `frontend/styles/{value}_theme_electron.css`, so both entries must have a
 * built stylesheet — the shell wrapper's preflight checks exactly that.
 *
 * `light` is in the matrix and is NOT in the default capture set, because
 * CodeTracer does not currently have a light theme to photograph. See
 * `blocked` below and `assertThemePainted`.
 */
export const THEMES = {
  dark: { config: "default_dark", light: false, blocked: "" },
  light: {
    config: "default_white",
    light: true,
    // Established while building this harness, and the reason the theme axis
    // exists but is not exercised by default:
    //
    //   * Before UD-0 there was no `default_white_theme_electron.css` at all,
    //     so `theme: "default_white"` pointed the window's `#theme` link at a
    //     file that did not exist and the app rendered as unstyled HTML. UD-0
    //     added the build rule, so the sheet now exists and loads.
    //   * The palette behind it does not. `default_white_theme.styl` overrides
    //     154 variables, but the Electron surface's dominant backgrounds come
    //     from elsewhere: the built light sheet and the built dark sheet
    //     differ in 292 of 16150 rules (~1.8%), and both carry 127 occurrences
    //     of `#282828` and 3 of `#f5f5f5`. A capture labelled `light` is a
    //     dark window, which is exactly the mislabelling this harness exists
    //     to make impossible.
    //
    // So the axis is wired, the assertion that guards it is live, and the
    // moment a real light palette lands this becomes capturable with no change
    // here beyond clearing this string.
    blocked:
      "CodeTracer has no light palette for the Electron surface yet: the built " +
      "default_white sheet differs from the dark one in ~1.8% of its rules and " +
      "still paints #282828, so a capture labelled 'light' would be a dark window",
  },
};

/** The Noir file of the corpus — the one carrying flow values. */
const NOIR_FILE = "main.nr";
/** The non-Noir file of the corpus. */
const OTHER_FILE = "report.py";

/**
 * The named views.
 *
 * `expects` is the one-line summary that the brief's per-view
 * "What is Expected on the Screenshot" block expands on; the contract suite
 * asserts the brief has a block for every name here, so the two cannot drift.
 */
export const VIEWS = {
  "review-shell": {
    file: NOIR_FILE,
    description:
      "The whole review window on landing: changed-files list, the diff tab, the surrounding panels.",
    expects:
      "a changed-files list naming both corpus files, and a unified diff tab open on the Noir file",
    async setup(ctx) {
      await selectFile(ctx, NOIR_FILE);
    },
    async verify(ctx) {
      await expectAtLeast(ctx, ctx.page.locator(".vcs-file-item"), 2, "changed-file rows");
      await expectAtLeast(ctx, diffTab(ctx), 1, "a diff tab");
    },
    // The whole window: this is the only view where the proportions between
    // panels are what is under review.
    target: null,
  },

  "diff-intraline": {
    file: NOIR_FILE,
    description:
      "A hunk whose changed lines differ only in part of the line — a renamed parameter, not a rewritten line.",
    expects:
      "a removed/added line pair where only one word differs (`factor` becomes `multiplier`)",
    async setup(ctx) {
      await selectFile(ctx, NOIR_FILE);
    },
    async verify(ctx) {
      await expectAtLeast(ctx, intralineLines(ctx), 2, "the intra-line edit pair");
    },
    target: (ctx) => intralineLines(ctx),
  },

  "diff-collapsed-context": {
    file: NOIR_FILE,
    description:
      "The diff as it first renders, with the unchanged region between the two hunks collapsed behind an expansion control.",
    expects: "at least one un-actuated `... Expand N lines above/below` boundary",
    async setup(ctx) {
      await selectFile(ctx, NOIR_FILE);
    },
    async verify(ctx) {
      await expectAtLeast(ctx, expandLines(ctx), 1, "a collapsed-context boundary");
      // A collapsed region that is already expanded is not a collapsed
      // region: assert nothing has been revealed yet.
      const revealed = await diffTab(ctx).locator(".view-overlays .ct-diff-line-revealed")
        .count();
      if (revealed !== 0) {
        throw new Error(
          `view 'diff-collapsed-context': ${revealed} lines are already revealed, so this is not the collapsed state`,
        );
      }
    },
    target: (ctx) => diffTab(ctx),
  },

  "diff-expanded-context": {
    file: NOIR_FILE,
    description:
      "The same region after the reader expands it — the lines the collapsed boundary was hiding.",
    expects:
      "revealed context lines where the `Expand N lines` boundary was, carrying their own line numbers",
    async setup(ctx) {
      await selectFile(ctx, NOIR_FILE);
      await clickEditorLine(ctx, expandLines(ctx).first());
      await ctx.page.waitForTimeout(1500);
    },
    async verify(ctx) {
      await expectAtLeast(
        ctx,
        diffTab(ctx).locator(".view-overlays .ct-diff-line-revealed"),
        1,
        "lines revealed by the expansion",
      );
    },
    target: (ctx) => diffTab(ctx),
  },

  "diff-flow-values": {
    file: NOIR_FILE,
    description:
      "A hunk with the recorded values drawn on it — the property that distinguishes this review surface from GitHub's.",
    expects:
      "inline value chips (a `<name>` chip followed by a value box) on the loop's lines, plus the in-editor invocation stepper",
    async setup(ctx) {
      await selectFile(ctx, NOIR_FILE);
      await diffTab(ctx)
        .locator(".view-lines .review-flow-value")
        .first()
        .waitFor({ state: "visible", timeout: 20000 });
    },
    async verify(ctx) {
      await expectAtLeast(ctx, flowChips(ctx), 2, "inline value chips");
    },
    target: (ctx) => flowChips(ctx),
  },

  "diff-long-line": {
    file: NOIR_FILE,
    description:
      "A changed line far wider than the pane — what the diff does with horizontal overflow.",
    expects:
      "a changed line long enough to run past the right edge of the diff pane (the assert carrying a long message)",
    async setup(ctx) {
      await selectFile(ctx, NOIR_FILE);
    },
    async verify(ctx) {
      await expectAtLeast(ctx, longLines(ctx), 1, "the long line");
    },
    target: (ctx) => longLines(ctx),
  },

  "diff-other-language": {
    file: OTHER_FILE,
    description:
      "A file in a language that is NOT the corpus's recorded one, so highlighting can be shown to be real rather than a Noir-shaped coincidence.",
    expects:
      "the diff tab for `report.py` — Python source, `def`/docstrings/f-strings — not the Noir file",
    async setup(ctx) {
      await selectFile(ctx, OTHER_FILE);
    },
    async verify(ctx) {
      // Both halves matter: the Python file is present AND the Noir file is
      // not what is on screen. Without the second half a stale tab would pass.
      await expectAtLeast(ctx, pythonLines(ctx), 1, "Python source in the diff tab");
      const noir = await noirOnlyLines(ctx).count();
      if (noir !== 0) {
        throw new Error(
          "view 'diff-other-language': the Noir file's lines are on screen, so the wrong tab is active",
        );
      }
    },
    target: (ctx) => diffTab(ctx),
  },
};

// ---------------------------------------------------------------------------
// Locators — expressed with the same selectors the GUI suite asserts on
// ---------------------------------------------------------------------------

// `:visible`, not `.first()`. GoldenLayout keeps every opened tab in the DOM
// and merely hides the inactive ones, so once a second file has been opened
// the first `.unified-diff-container` in document order is a hidden tab
// showing the wrong file — which is exactly the mislabelled capture this
// harness exists to prevent.
const diffTab = (ctx) => ctx.page.locator(".unified-diff-container:visible").first();
const diffLines = (ctx) => diffTab(ctx).locator(".monaco-editor .view-line");

const expandLines = (ctx) =>
  diffLines(ctx).filter({ hasText: /Expand\s+\d+\s+lines\s+(above|below)/ });
const flowChips = (ctx) => diffTab(ctx).locator(".monaco-editor .view-lines .review-flow-value");
const intralineLines = (ctx) => diffLines(ctx).filter({ hasText: /fn\s+scale\(index/ });
// Matched on a single hyphenated token rather than a phrase: Monaco renders
// runs of spaces as U+00A0, so a literal inter-word space in the pattern is a
// coin flip.
const longLines = (ctx) => diffLines(ctx).filter({ hasText: /horizontal-overflow/ });
const pythonLines = (ctx) => diffLines(ctx).filter({ hasText: /def\s+format_row/ });
const noirOnlyLines = (ctx) => diffLines(ctx).filter({ hasText: /let\s+mut\s+total:\s*Field/ });

/**
 * Presses a rendered Monaco line near the START of its text.
 *
 * Not `locator.click()`, which aims at the element's centre. A `.view-line` is
 * as wide as the widest line in the document — the corpus's long assert makes
 * that ~2500px — so the centre lands far to the right of the text, and
 * Playwright first scrolls the editor horizontally to bring that centre into
 * view. The observed result is a press that changes the horizontal scroll and
 * actuates nothing. Pressing 20px into the line hits the control's own text
 * and leaves the scroll alone.
 *
 * `mousedown` is also what the product listens for
 * (`unified_diff.nim`'s `udOnMouseDown`), so the press is issued as an
 * explicit down/up rather than a synthesised click.
 */
async function clickEditorLine(ctx, locator) {
  await locator.waitFor({ state: "visible", timeout: 20000 });
  const box = await locator.boundingBox();
  if (!box) throw new Error(`view '${ctx.viewName}': the line to press is not on screen`);
  const x = Math.min(Math.max(box.x + 20, 4), ctx.size.width - 4);
  const y = box.y + box.height / 2;
  await ctx.page.mouse.move(x, y);
  await ctx.page.mouse.down();
  await ctx.page.mouse.up();
}

/**
 * Scrolls the diff until `locator` matches something, or gives up.
 *
 * Monaco virtualises: only the lines inside the editor's viewport exist in the
 * DOM. A view whose target sits near the bottom of the document is therefore
 * present at `wide` and absent at `narrow` for no reason other than the
 * viewport being 260px shorter — which is exactly what happened to
 * `diff-long-line` the first time the full matrix was regenerated. Without
 * this the harness would have quietly captured six sizes out of seven, or
 * worse, framed the wrong thing.
 *
 * A no-op when the target is already matched, so views whose target is the
 * whole tab pay nothing.
 */
async function scrollDiffTo(ctx, locator) {
  if ((await locator.count()) > 0) return;
  const tab = diffTab(ctx);
  const box = await tab.boundingBox();
  if (!box) return;
  await ctx.page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
  for (let step = 0; step < 40; step += 1) {
    await ctx.page.mouse.wheel(0, 160);
    await ctx.page.waitForTimeout(150);
    if ((await locator.count()) > 0) {
      // One more settle: the line exists but Monaco may still be painting it.
      await ctx.page.waitForTimeout(400);
      return;
    }
  }
}

async function expectAtLeast(ctx, locator, n, what) {
  await locator.first().waitFor({ state: "visible", timeout: 20000 }).catch(() => {});
  const count = await locator.count();
  if (count < n) {
    throw new Error(
      `view '${ctx.viewName}': expected at least ${n} of ${what}, found ${count}. ` +
        "The capture would have been mislabelled, so it was not written.",
    );
  }
}

/**
 * Opens `basename`'s diff tab from the changed-files list.
 *
 * The VCS panel renders only the basename (`vcs-file-name`), which is why the
 * corpus deliberately has no two files with the same one.
 */
async function selectFile(ctx, basename) {
  const row = ctx.page
    .locator(".vcs-file-item")
    .filter({ has: ctx.page.locator(`.vcs-file-name:text-is("${basename}")`) })
    .first();
  await row.waitFor({ state: "visible", timeout: 30000 });
  await row.click();
  await diffTab(ctx).waitFor({ state: "visible", timeout: 30000 });
  // Monaco lays the document out after the tab appears; wait for a rendered
  // line rather than a fixed interval.
  await diffLines(ctx).first().waitFor({ state: "visible", timeout: 30000 });
  await ctx.page.waitForTimeout(1500);
}

// ---------------------------------------------------------------------------
// Sabotage — the methodology's calibration instrument, checklist item 7
// ---------------------------------------------------------------------------

/**
 * Deliberate breakage, used ONCE per campaign to prove the brief is sharp
 * enough that a reviewer reports "an expected element is missing" rather than
 * rating the damage as a styling choice.
 *
 * It lives here, behind an explicit flag, rather than in a throwaway patch,
 * because a calibration that cannot be re-run is a calibration nobody will
 * re-run when the brief changes.
 */
const SABOTAGE = {
  // "remove the value chips" — the methodology's own worked example.
  "hide-value-chips": {
    description: "hides every inline value chip, leaving the diff otherwise intact",
    async apply(ctx) {
      await ctx.page.addStyleTag({
        content: ".review-flow-value { display: none !important; }",
      });
      await ctx.page.waitForTimeout(500);
    },
    // The per-view verification would (correctly) refuse to write this
    // capture, so sabotage suspends it. That is the point: the reviewer, not
    // the harness, is what is being tested.
    skipVerify: true,
  },
  // "point the model at the wrong file" — the other suggestion in the
  // methodology's checklist item 7.
  "wrong-file": {
    description: "opens a different file than the view claims, with the view's name unchanged",
    async apply(ctx) {
      const other = ctx.view.file === NOIR_FILE ? OTHER_FILE : NOIR_FILE;
      await selectFile(ctx, other);
    },
    skipVerify: true,
  },
};

// ---------------------------------------------------------------------------
// Capture
// ---------------------------------------------------------------------------

/** The file name a capture lands under. Kept in one place: tests assert it. */
export function screenshotName(view, size, theme) {
  return `${view}--${size}--${theme}.png`;
}

/**
 * The union bounding box of `locator`'s elements, padded, clamped to the page.
 *
 * A clip computed from where the elements actually are is what lets a view
 * survive the layout moving; the docs capture's fixed `-crop 600x400+270+60`
 * does not.
 */
async function unionClip(page, locator, pad, viewport) {
  const boxes = [];
  const count = await locator.count();
  for (let i = 0; i < count; i += 1) {
    const box = await locator.nth(i).boundingBox();
    if (box && box.width > 0 && box.height > 0) boxes.push(box);
  }
  if (boxes.length === 0) return null;
  let x0 = Infinity;
  let y0 = Infinity;
  let x1 = -Infinity;
  let y1 = -Infinity;
  for (const b of boxes) {
    x0 = Math.min(x0, b.x);
    y0 = Math.min(y0, b.y);
    x1 = Math.max(x1, b.x + b.width);
    y1 = Math.max(y1, b.y + b.height);
  }
  x0 = Math.max(0, x0 - pad);
  y0 = Math.max(0, y0 - pad);
  x1 = Math.min(viewport.width, x1 + pad);
  y1 = Math.min(viewport.height, y1 + pad);
  if (x1 - x0 < 8 || y1 - y0 < 8) return null;
  return { x: Math.round(x0), y: Math.round(y0), width: Math.round(x1 - x0), height: Math.round(y1 - y0) };
}

async function resizeWindow(app, page, size) {
  await app.evaluate(async ({ BrowserWindow }, s) => {
    const win = BrowserWindow.getAllWindows()[0];
    win.setResizable(true);
    win.setContentSize(s.width, s.height);
  }, size);
  // GoldenLayout relays out on the resize event; give it a beat.
  await page.waitForTimeout(1500);
}

/**
 * Asserts the window is actually wearing the theme the caller asked for.
 *
 * `loadTheme` sets `#theme`'s href to `frontend/styles/{theme}_theme_electron.css`,
 * and if that file is missing the window renders as unstyled HTML. A reviewer
 * shown that would report a catastrophic design failure; the harness must
 * report a configuration failure instead.
 */
async function assertTheme(page, themeKey) {
  const wanted = THEMES[themeKey].config;
  const href = await page.evaluate(() => {
    const link = document.getElementById("theme");
    return link ? link.getAttribute("href") : null;
  });
  if (!href || !href.includes(`${wanted}_theme_electron.css`)) {
    throw new Error(
      `theme '${themeKey}' was requested but the window loaded '${href}'. ` +
        "The config was not picked up, or the stylesheet was never built.",
    );
  }
}

/**
 * Asserts the window is actually PAINTED in the theme it is labelled with.
 *
 * The stylesheet check above proves the right file was requested. It does not
 * prove the file makes any difference, and on this codebase it does not: the
 * light sheet loads and the window stays dark. A reviewer handed that capture
 * reports "this is labelled light and is dark" — a finding about the harness,
 * spent from the reviewer's budget, on every single light capture forever.
 *
 * So the label is checked against paint. The measurement is the app shell's
 * own background, sampled from the first candidate that is not transparent,
 * converted to relative luminance.
 */
async function assertThemePainted(page, themeKey) {
  const sample = await page.evaluate(() => {
    const candidates = ["#ROOT", "#root-container", ".session-container", "#main", "body"];
    for (const selector of candidates) {
      const el = document.querySelector(selector);
      if (!el) continue;
      const bg = getComputedStyle(el).backgroundColor;
      const m = /rgba?\(([\d.]+),\s*([\d.]+),\s*([\d.]+)(?:,\s*([\d.]+))?\)/.exec(bg || "");
      if (!m) continue;
      if (m[4] !== undefined && Number(m[4]) === 0) continue;
      return { selector, bg, r: Number(m[1]), g: Number(m[2]), b: Number(m[3]) };
    }
    return null;
  });
  if (!sample) {
    throw new Error(
      `theme '${themeKey}': no app-shell element has an opaque background, so the ` +
        "theme cannot be verified and the capture would be unlabelled in practice",
    );
  }
  // sRGB relative luminance, good enough to separate a light palette from a
  // dark one without pulling in a colour library.
  const lum = (0.2126 * sample.r + 0.7152 * sample.g + 0.0722 * sample.b) / 255;
  const wantLight = THEMES[themeKey].light;
  if (wantLight && lum < 0.5) {
    throw new Error(
      `theme '${themeKey}' is labelled light but '${sample.selector}' paints ` +
        `${sample.bg} (luminance ${lum.toFixed(2)}). ` +
        `${THEMES[themeKey].blocked}. Capture with --theme dark until a light palette exists.`,
    );
  }
  if (!wantLight && lum >= 0.5) {
    throw new Error(
      `theme '${themeKey}' is labelled dark but '${sample.selector}' paints ` +
        `${sample.bg} (luminance ${lum.toFixed(2)})`,
    );
  }
}

async function launch(opts) {
  const env = {};
  for (const [k, v] of Object.entries(process.env)) if (v !== undefined) env[k] = v;
  delete env.CODETRACER_TRACE_ID;
  delete env.CODETRACER_RECORDING_ID;
  delete env.CODETRACER_CALLER_PID;
  delete env.CODETRACER_PREFIX;
  delete env.WAYLAND_DISPLAY;
  delete env.XDG_SESSION_TYPE;
  // Off, for the same reason the GUI suite turns it off: a bundle swapped
  // underneath a running capture is nondeterminism, not a feature.
  env.CT_HMR = "0";
  env.XDG_CONFIG_HOME = opts.xdg;
  env.CODETRACER_NEW_TRACE_POLICY = "window";
  env.CODETRACER_ELECTRON_ARGS = [
    "--no-sandbox",
    "--no-zygote",
    "--disable-gpu",
    "--disable-gpu-compositing",
    "--disable-dev-shm-usage",
    "--in-process-gpu",
    "--ozone-platform-hint=x11",
  ].join(" ");

  const app = await _electron.launch({
    executablePath: opts.ct,
    // A directory with no `.config.yaml` above it, so `findConfig`'s upward
    // walk falls through to XDG_CONFIG_HOME and the requested theme wins.
    cwd: opts.xdg,
    args: ["review", opts.dataset],
    env,
    timeout: 120000,
  });
  let page = await app.firstWindow({ timeout: 120000 });
  if ((await page.title()) === "DevTools") page = app.windows()[1];
  await page.waitForSelector(".vcs-file-item", { timeout: 120000 });
  return { app, page };
}

async function captureView(opts, viewName) {
  const view = VIEWS[viewName];
  const { app, page } = await launch(opts);
  const written = [];
  try {
    await assertTheme(page, opts.theme);
    await assertThemePainted(page, opts.theme);
    for (const sizeName of opts.sizes) {
      const size = SIZES[sizeName];
      await resizeWindow(app, page, size);
      const ctx = { page, app, view, viewName, size };
      await view.setup(ctx);
      if (opts.sabotage) {
        await SABOTAGE[opts.sabotage].apply(ctx);
      }
      // A sabotaged capture cannot be framed on the element the view normally
      // targets — hiding the value chips removes the very thing the clip was
      // computed from. Framing falls back to the whole diff tab, which is also
      // the fairer test: the reviewer is shown the surface in full and has to
      // notice for itself that something expected is absent.
      const targetFn = opts.sabotage && view.target ? diffTab : view.target;
      if (targetFn) await scrollDiffTo(ctx, targetFn(ctx));
      if (!opts.sabotage || !SABOTAGE[opts.sabotage].skipVerify) {
        await view.verify(ctx);
      }
      let clip = null;
      if (targetFn) {
        clip = await unionClip(page, targetFn(ctx), 24, size);
        if (!clip) {
          throw new Error(
            `view '${viewName}': its target region is not on screen at size '${sizeName}'`,
          );
        }
      }
      const out = path.join(opts.out, screenshotName(viewName, sizeName, opts.theme));
      await page.screenshot({ path: out, clip: clip ?? undefined });
      written.push(out);
      console.log(`captured ${out}`);
    }
  } finally {
    await app.close().catch(() => {});
  }
  return written;
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

function printList() {
  for (const [name, v] of Object.entries(VIEWS)) {
    console.log(`view\t${name}\t${v.file}\t${v.description}`);
  }
  for (const [name, s] of Object.entries(SIZES)) {
    console.log(`size\t${name}\t${s.width}x${s.height}`);
  }
  for (const [name, t] of Object.entries(THEMES)) {
    console.log(`theme\t${name}\t${t.config}\t${t.blocked}`);
  }
  for (const [name, s] of Object.entries(SABOTAGE)) {
    console.log(`sabotage\t${name}\t${s.description}`);
  }
}

function fail(message) {
  console.error(`capture-deepreview-views: ${message}`);
  process.exit(2);
}

async function main(argv) {
  const opts = { views: [], sizes: [], theme: "dark", sabotage: "" };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    const next = () => {
      i += 1;
      if (i >= argv.length) fail(`${arg} needs a value`);
      return argv[i];
    };
    switch (arg) {
      case "--list":
        printList();
        return;
      case "--view":
        opts.views.push(next());
        break;
      case "--size":
        opts.sizes.push(next());
        break;
      case "--theme":
        opts.theme = next();
        break;
      case "--ct":
        opts.ct = next();
        break;
      case "--dataset":
        opts.dataset = next();
        break;
      case "--out":
        opts.out = next();
        break;
      case "--xdg":
        opts.xdg = next();
        break;
      case "--sabotage":
        opts.sabotage = next();
        break;
      default:
        fail(`unknown option '${arg}'`);
    }
  }

  for (const [flag, value] of [
    ["--ct", opts.ct],
    ["--dataset", opts.dataset],
    ["--out", opts.out],
    ["--xdg", opts.xdg],
  ]) {
    if (!value) fail(`${flag} is required`);
  }
  if (!THEMES[opts.theme]) fail(`unknown theme '${opts.theme}'; known: ${Object.keys(THEMES).join(", ")}`);
  if (opts.sabotage && !SABOTAGE[opts.sabotage]) {
    fail(`unknown sabotage '${opts.sabotage}'; known: ${Object.keys(SABOTAGE).join(", ")}`);
  }
  if (opts.views.length === 0) opts.views = Object.keys(VIEWS);
  if (opts.sizes.length === 0) opts.sizes = Object.keys(SIZES);
  for (const v of opts.views) if (!VIEWS[v]) fail(`unknown view '${v}'; known: ${Object.keys(VIEWS).join(", ")}`);
  for (const s of opts.sizes) if (!SIZES[s]) fail(`unknown size '${s}'; known: ${Object.keys(SIZES).join(", ")}`);

  fs.mkdirSync(opts.out, { recursive: true });
  for (const viewName of opts.views) {
    await captureView(opts, viewName);
  }
}

main(process.argv.slice(2)).catch((err) => {
  console.error(`capture-deepreview-views: ${err && err.message ? err.message : err}`);
  process.exit(1);
});
