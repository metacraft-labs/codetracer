/**
 * Guard: the BUILT theme stylesheets must leave every status-bar readout
 * readable — whatever colour the rule that hides it happens to name.
 *
 * *"The colors in the status bar are difficult to read."*  Reported against
 * the live deployment, and measured there before anything was changed: the
 * bar's readouts were painted `rgb(0, 0, 0)` on `rgb(27, 27, 27)` — 1.22:1,
 * where normal text needs 4.5:1 — because `#status-base` declared a
 * background and no `color` and nothing above it declared one either, so the
 * whole bar inherited the user-agent default.  `.build-identity` was worse
 * still at 1.14:1, its `opacity: 0.6` multiplying an already invisible
 * colour.  The full narrative is in `page-objects/status-footer-contrast.ts`.
 *
 * WHY IT COULD ONLY BE REPORTED NOW.  `00fd68b7f` had these readouts at
 * `left: -9999px` from 2026-08-18 until `74879f32c` brought them back.  They
 * had always been painted black-on-near-black; for two weeks they were
 * painted black-on-near-black OFF SCREEN.  The geometry guard beside this one
 * was written for the exiling, and by its own account could never have seen
 * the colour: `SURVIVING_HIDE_SPELLINGS` records "text drawn in the
 * background colour" as a miss whose `why` reads *"requires comparing two
 * computed colours against a contrast threshold, not a box"*.  This file is
 * that comparison, and `verify_it_closes_the_colour_half_of_the_blind_spot`
 * asserts the cross-reference by running those entries rather than by
 * claiming them.
 *
 * WHAT IT REFUSES TO DO.  It never looks for a hex literal, a token name or a
 * declaration.  A guard that rejects `#000000` waves through `#050505`; a
 * guard that requires `colors-ui-text-primary-label-subtle` goes red the day
 * the palette is legitimately retuned and green the day someone applies that
 * token to a surface it does not suit.  It asks the browser what each region
 * is actually painted, what is actually behind it, and whether the ratio
 * clears the threshold for that kind of content.
 * `verify_the_guard_fires_for_colours_it_has_never_seen` proves that against
 * six spellings, five of which have never been written here.
 *
 * WHICH THEMES, AND WHY THESE TWO.  `default_dark_theme_electron.css` is what
 * `index.html` links and what the live deployment serves;
 * `default_white_theme_electron.css` is what `loadTheme` resolves for a
 * `theme: "default_white"` config.  They are the two the NIX package builds
 * (`nix/packages/default.nix`), so both resolve in CI's `result/` tree as
 * well as in a local `src/build-debug` — deliberately unlike the geometry
 * guard's list, two thirds of which only exist after a local `just
 * build-once`.  They are also, measurably, the same stylesheet for this bar:
 * `default_white_theme.styl` redefines not one `colors-*` token, so the
 * footer is `#1b1b1b` in both.  `verify_the_light_theme_is_not_a_different_
 * bar` states that as an assertion rather than leaving it as a surprise.
 *
 * IT TRUSTS THE BUILD, exactly as its sibling does: it reads whatever
 * `src/build-debug` (or the nix output) currently holds and cannot tell a
 * fresh theme from a stale one.  Editing a `.styl` and running this without
 * `just build-once` reports on the previous build.
 */
import * as fs from "node:fs";
import * as path from "node:path";

import { expect, test, type Page } from "@playwright/test";

import {
  BAR_CONTRAST_REGIONS,
  EXEMPT_REGIONS,
  IMAGE_PAINTED_ICONS,
  UNREACHABLE_SELECTORS,
  contrastFailures,
  formatContrastTable,
  probeBarContrast,
} from "../../page-objects/status-footer-contrast";
import { SURVIVING_HIDE_SPELLINGS } from "../../page-objects/status-footer-contract";

/** Repo root, from `src/tests/gui/tests/status-bar`. */
const repoRoot = path.resolve(__dirname, "../../../../..");

/** Frontend views that own every identifier this file reasons about. */
const FRONTEND_SOURCE_DIRS = [
  path.join(repoRoot, "src/frontend"),
  path.join(repoRoot, "src/public"),
];

/**
 * The two themes the nix package builds, so both resolve in CI and locally.
 * See the header for why this list differs from the geometry guard's.
 */
const THEMES = [
  "default_dark_theme_electron.css",
  "default_white_theme_electron.css",
] as const;

/** Resolved the same way `footer-visibility-css-guard.spec.ts` resolves it. */
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

function resolveTheme(theme: string): string {
  const tried: string[] = [];
  for (const dir of candidateStyleDirs()) {
    const candidate = path.join(dir, theme);
    tried.push(candidate);
    if (fs.existsSync(candidate)) return candidate;
  }
  throw new Error(
    `built theme stylesheet \`${theme}\` not found — run \`just build-once\`. ` +
      `Looked in:\n  ${tried.join("\n  ")}`,
  );
}

/**
 * The footer as the app renders it, transcribed from
 * `src/frontend/viewmodel/views/isonim_status_view.nim`.
 *
 * Deliberately a superset of the geometry guard's `FOOTER_MARKUP`: that one
 * only needs the regions whose BOX is contractual, while this one needs every
 * region that puts INK on the bar.  So it additionally carries the encoding
 * readout, the two `.separate-bar` hairlines, the collapsed icon zone in its
 * `has-icons` state (which is where its `#3a5070` chip comes from), an active
 * AND an idle strip tab, `.build-identity` — rendered only by a served build,
 * which is precisely what the report came from — and `.disconnected-status`.
 *
 * `verify_every_measured_region_is_still_rendered` fails if any of it stops
 * being emitted by the frontend, so this cannot decay into a check on markup
 * the app no longer produces.
 */
const FOOTER_MARKUP = `
  <div id="root-container">
    <footer>
      <div id="search-results"></div>
      <div id="status" class="status-shell">
        <div id="active-notifications"></div>
        <div id="status-base">
          <div id="auto-hide-collapsed-icon-zone" class="collapsed-icon-zone has-icons">
            <button class="collapsed-icon" title="BUILD">B</button>
          </div>
          <div id="file-info-status">
            <span class="file-info-status-language status-inline">Noir</span>
            <div class="separate-bar"></div>
            <span class="file-info-status-encoding status-inline">UTF-8</span>
            <div class="separate-bar"></div>
            <span id="operation-status">
              <span id="stable-status" class="ready-status">stable: ready</span>
            </span>
          </div>
          <div id="auto-hide-bottom-strip" class="auto-hide-bottom-strip has-tabs">
            <div class="auto-hide-strip-tab active"><span class="auto-hide-strip-tab-label">BUILD</span></div>
            <div class="auto-hide-strip-tab"><span class="auto-hide-strip-tab-label">PROBLEMS</span></div>
            <div class="auto-hide-strip-tab"><span class="auto-hide-strip-tab-label">FIND IN FILES</span></div>
          </div>
          <span class="test-movement">17</span>
          <span class="status-right">
            <span class="build-identity status-inline" title="deadbeef">cloud 4e9cff5a</span>
            <span class="status-inline disconnected-status" role="status" aria-live="polite">Disconnected</span>
            <span id="location-status">
              <span class="location-path status-inline" data-toggle="tooltip"
                    data-placement="bottom" title="/tmp/program.nr:1#3">/tmp/program.nr:1#3</span>
              <button id="copy-path-image"
                      class="ct-button-image-md-secondary ct-button-no-border"></button>
              <div class="custom-tooltip ">Path copied to clipboard</div>
            </span>
          </span>
        </div>
      </div>
    </footer>
  </div>
`;

async function layOutFooter(
  page: Page,
  theme: string,
  extraCss?: string,
): Promise<void> {
  await page.setContent(
    `<!doctype html><html><body>${FOOTER_MARKUP}</body></html>`,
  );
  await page.addStyleTag({ path: resolveTheme(theme) });
  if (extraCss !== undefined) await page.addStyleTag({ content: extraCss });
}

/** Every word of every double-quoted literal under the frontend sources. */
function identifiersEmittedUnder(dirs: readonly string[]): Set<string> {
  const identifiers = new Set<string>();
  const visit = (dir: string): void => {
    let entries: fs.Dirent[];
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        if (entry.name === "node_modules" || entry.name === "styles") continue;
        visit(full);
        continue;
      }
      if (!/\.(nim|ts|js|html)$/.test(entry.name)) continue;
      const source = fs.readFileSync(full, "utf8");
      for (const literal of source.match(/["'][^"'\n]*["']/g) ?? []) {
        for (const word of literal.slice(1, -1).trim().split(/\s+/)) {
          if (word.length > 0) identifiers.add(word);
        }
      }
    }
  };
  for (const dir of dirs) visit(dir);
  return identifiers;
}

test.describe("status bar contrast (WCAG 1.4.3 / 1.4.11)", () => {
  for (const theme of THEMES) {
    test(`verify_every_status_bar_readout_is_legible__${theme.replace(/\W+/g, "_")}`, async ({
      page,
    }) => {
      await layOutFooter(page, theme);
      const probes = await probeBarContrast(page);

      // A probe that found nothing makes every later assertion vacuous.
      expect(
        probes.filter((p) => !p.found).map((p) => p.selector),
        "every measured region must resolve in the footer markup — if one " +
          "does not, FOOTER_MARKUP has drifted from isonim_status_view.nim",
      ).toEqual([]);

      expect(
        contrastFailures(probes),
        `\`${theme}\` paints part of the status bar too faintly to read.\n\n` +
          "The bar's readouts are ambient text on a dark surface, so they " +
          "need 4.5:1 (WCAG 1.4.3); its controls and meaningful graphics " +
          "need 3:1 (1.4.11).\n\nTake the replacement colour FROM THE DESIGN " +
          "SYSTEM — `src/frontend/styles/generated/mapped.styl` — rather " +
          "than inventing one, and prefer the QUIETEST token that clears " +
          "the threshold: this bar has been made tabs-only three times by " +
          "people who wanted a quieter footer, so a legibility fix that " +
          "overshoots into a loud bar will simply be reverted a fourth " +
          "time.  Do not reach for a token name that nothing declares; an " +
          "unresolved one compiles to a literal and the browser drops it " +
          "silently.\n\nThe bar as measured:\n" +
          formatContrastTable(probes),
      ).toEqual([]);
    });
  }

  test("verify_the_light_theme_is_not_a_different_bar", async ({ page }) => {
    // Stated as an assertion because it is genuinely surprising, and because
    // a future divergence must be a decision rather than a discovery: the
    // light theme's status bar is the DARK one.  `default_white_theme.styl`
    // redefines not a single `colors-*` token, so every design-system colour
    // in this bar resolves identically in both builds.  If that stops being
    // true, this bar needs measuring twice over on two different surfaces,
    // and whoever changes it should find out from here.
    const measured: Record<string, string> = {};
    for (const theme of THEMES) {
      await layOutFooter(page, theme);
      const probes = await probeBarContrast(page);
      measured[theme] = probes
        .map((p) => `${p.selector} ${p.composited} on ${p.background}`)
        .join("\n");
    }
    expect(
      measured[THEMES[1]],
      "the light theme's status bar has diverged from the dark theme's. " +
        "That may well be correct — but it means the palette now has two " +
        "surfaces to satisfy, and the thresholds must be re-derived for the " +
        "second one rather than assumed to carry over.",
    ).toBe(measured[THEMES[0]]);
  });

  test("verify_the_guard_fires_for_colours_it_has_never_seen", async ({
    page,
  }) => {
    // The point of the whole file. Each spelling is applied on top of a
    // known-good theme and the check must go red. Only the first two have
    // ever been written here.
    const spellings: { name: string; css: string }[] = [
      {
        name: "the defect as it shipped — a bar with a background and no colour",
        css: "#status #status-base { color: initial !important; }",
      },
      {
        name: "`.build-identity`'s `opacity: 0.6`, which multiplies whatever it inherits",
        css: "#status-base .build-identity { opacity: 0.06 !important; }",
      },
      {
        name: "a colour one shade off black, which a literal check would miss",
        css: "#status-base .location-path { color: #050505 !important; }",
      },
      {
        name: "text painted in the bar's own background colour",
        css: "#status-base .file-info-status-language { color: #1b1b1b !important; }",
      },
      {
        name: "a translucent white, which reads as bright until it is composited",
        css:
          "#status-base .file-info-status-encoding " +
          "{ color: rgba(255, 255, 255, 0.12) !important; }",
      },
      {
        name: "an opacity on an ANCESTOR rather than on the region itself",
        css: "#status-base .status-right { opacity: 0.08 !important; }",
      },
    ];

    const survived: string[] = [];
    for (const spelling of spellings) {
      await layOutFooter(page, THEMES[0], spelling.css);
      const failures = contrastFailures(await probeBarContrast(page));
      if (failures.length === 0) survived.push(`${spelling.name}: ${spelling.css}`);
    }
    expect(
      survived,
      "these ways of making the status bar unreadable slipped past the " +
        "guard, which means it is checking something other than whether the " +
        "user can read the bar",
    ).toEqual([]);

    // ... and it must still pass with none of them applied, so the line above
    // is not green merely because the check is always red.
    await layOutFooter(page, THEMES[0]);
    expect(
      contrastFailures(await probeBarContrast(page)),
      "the unmodified built theme must satisfy the same check",
    ).toEqual([]);
  });

  test("verify_the_guard_refuses_the_defect_that_shipped", async ({ page }) => {
    // CONTROL DATA, not a synthesised spelling. This is the bar exactly as
    // the live deployment served it when the report was filed: `#status-base`
    // with no `color` of its own, `.build-identity` faded to 0.6, and the
    // strip tabs on the disabled token. A contrast check that has never
    // refused anything is not a check, so watch this one refuse the thing it
    // was written for, region by region, with the ratio in the message.
    const AS_SHIPPED_CSS =
      "#status #status-base { color: initial !important; }\n" +
      "#status #status-base .build-identity { opacity: 0.6 !important; }\n" +
      // The idle token, and the active colour restored after it — the shipped
      // stylesheet carried BOTH, and `.active` won for the open tab. Writing
      // only the first would clobber the active label too and make this
      // control describe a defect that never shipped.
      ".auto-hide-strip-tab { color: #727272 !important; }\n" +
      ".auto-hide-strip-tab.active { color: #c8c8c8 !important; }\n" +
      ".collapsed-icon { color: initial !important; }";

    await layOutFooter(page, THEMES[0], AS_SHIPPED_CSS);
    const failures = contrastFailures(await probeBarContrast(page));

    // Match each failure back to the region it names, rather than slicing at
    // the first `:` — selectors contain colons (`:not(.active)`), and slicing
    // silently truncated one region to a prefix that matches a different one.
    const refused = BAR_CONTRAST_REGIONS.map((r) => r.selector)
      .filter((selector) => failures.some((f) => f.startsWith(`${selector}:`)))
      .sort();
    expect(
      refused,
      "every readout that inherited the user-agent default must be refused. " +
        "`#operation-status`/`#stable-status` and `.disconnected-status` are " +
        "deliberately absent: both name their own colour and both measured " +
        "well above threshold (14.21:1 and 10.21:1), and a control that " +
        "expected all of them would be describing a different defect.",
    ).toEqual(
      [
        "#status-base .file-info-status-language",
        "#status-base .file-info-status-encoding",
        "#status-base .auto-hide-strip-tab:not(.active) .auto-hide-strip-tab-label",
        "#status-base .build-identity",
        "#status-base .location-path",
        "#status-base #auto-hide-collapsed-icon-zone .collapsed-icon",
      ].sort(),
    );

    // The ratios that were actually measured on the live page, so the control
    // pins the DEFECT and not merely "something was red".
    const failureFor = (selector: string): string =>
      failures.find((f) => f.startsWith(`${selector}:`)) ?? "";
    expect(
      failureFor("#status-base .file-info-status-language"),
      "the inherited-black readouts measured 1.22:1 on the live deployment",
    ).toContain("1.22:1, needs 4.5:1");
    expect(
      failureFor("#status-base .build-identity"),
      "`.build-identity` was the worst element in the bar, at 1.14:1",
    ).toContain("1.14:1, needs 4.5:1");
    expect(
      failureFor("#status-base .build-identity"),
      "and the diagnosis must name the opacity, or the reader goes looking " +
        "for a colour that is not the whole story",
    ).toContain("faded to 0.6");
    expect(
      failureFor(
        "#status-base .auto-hide-strip-tab:not(.active) .auto-hide-strip-tab-label",
      ),
      "the idle strip tabs were on the disabled token at 3.06:1",
    ).toContain("3.06:1, needs 4.5:1");

    // The other direction: the fixed theme passes in full. A predicate that
    // rejects everything is no improvement on one that rejects nothing.
    await layOutFooter(page, THEMES[0]);
    expect(
      contrastFailures(await probeBarContrast(page)),
      "and the current, corrected theme must satisfy the guard",
    ).toEqual([]);
  });

  test("verify_it_closes_the_colour_half_of_the_blind_spot", async ({
    page,
  }) => {
    // `status-footer-contract.ts` publishes, as executable data, the ways of
    // hiding the footer its GEOMETRY predicate cannot see. Two of them are
    // colour-only, and their recorded `why` says in as many words that
    // catching them needs a contrast comparison. Those two now carry
    // `caughtBy: "contrast"`, and that claim is checked here rather than
    // believed — the geometry guard's own history is a documented blind spot
    // that stayed accurate right up until someone walked through it, so a
    // cross-reference between two files is worth exactly as much as the
    // assertion that runs it.
    const claimed = SURVIVING_HIDE_SPELLINGS.filter(
      (s) => s.caughtBy === "contrast",
    );
    expect(
      claimed.length,
      "`status-footer-contract.ts` should mark its colour-only spellings as " +
        "caught by this guard; if that annotation is gone, either it was " +
        "dropped or the entries were, and both need a look",
    ).toBeGreaterThan(0);

    const escaped: string[] = [];
    for (const spelling of claimed) {
      await layOutFooter(page, THEMES[0], spelling.css);
      if (contrastFailures(await probeBarContrast(page)).length === 0) {
        escaped.push(`${spelling.name}: ${spelling.css}`);
      }
    }
    expect(
      escaped,
      "these are annotated `caughtBy: \"contrast\"` in " +
        "`page-objects/status-footer-contract.ts`, and this guard does not " +
        "catch them. Either fix the predicate or correct the annotation — " +
        "an inaccurate MISSED list is how the geometry guard came to publish " +
        "a route past itself.",
    ).toEqual([]);
  });

  test("verify_every_measured_region_is_still_rendered", () => {
    // A selector the app stopped emitting is not a failing guard, it is a
    // silent one. Anchor every measured region to the frontend that renders
    // it, so a rename fails HERE rather than leaving a check that can never
    // go red.
    //
    // Read from the Nim/TS SOURCES, never from the compiled `ui.js`: Nim's JS
    // backend emits some string literals as char-code arrays, so grepping the
    // bundle answers a question about the compiler, not about the app.
    const emitted = identifiersEmittedUnder(FRONTEND_SOURCE_DIRS);

    // The identifier each measured selector actually depends on — the last
    // class or id in it, which is the one a rename would move.
    const required = [
      ...BAR_CONTRAST_REGIONS.map((r) => r.selector),
      ...EXEMPT_REGIONS.map((r) => r.selector),
      ...IMAGE_PAINTED_ICONS.map((r) => r.selector),
    ].map((selector) => {
      const last = selector.split(/\s+/).pop() ?? selector;
      return last.replace(/^[.#]/, "").replace(/:not\(.*\)$/, "").split(".")[0];
    });

    const missing = [...new Set(required)].filter((id) => !emitted.has(id));
    expect(
      missing,
      "these identifiers are measured for contrast but no longer emitted by " +
        "the frontend. Either the bar lost a readout — which is the " +
        "regression `footer-visibility-css-guard.spec.ts` exists to catch — " +
        "or it was renamed, in which case update BAR_CONTRAST_REGIONS and " +
        "FOOTER_MARKUP together.",
    ).toEqual([]);
  });

  test("verify_the_unreachable_selectors_are_still_unreachable", () => {
    // The other half of the same idea, and the reason two genuinely awful
    // ratios in `status_bar.styl` are documented rather than fixed.
    // `.whitespace-set` (1.51:1) and `.status-button-clicked` (2.35:1) are
    // the worst numbers in the bar and the most tempting things to "fix";
    // nothing renders either of them, so raising them would spend a design
    // token on a rule the app cannot produce AND leave a healthy-looking
    // number that reads as evidence the control is live.
    //
    // If anyone ever wires one up, this fails and sends them to the comment
    // in `status_bar.styl` — so the exemption cannot outlive its own reason.
    const emitted = identifiersEmittedUnder(FRONTEND_SOURCE_DIRS);
    const nowRendered = UNREACHABLE_SELECTORS.filter((s) =>
      emitted.has(s.identifier),
    ).map((s) => `${s.identifier} (measured ${s.measured})`);
    expect(
      nowRendered,
      "these selectors were left at a failing contrast ratio ON THE GROUND " +
        "THAT NOTHING RENDERS THEM, and something now does. They need real " +
        "colours from the design system before they can ship, and they need " +
        "adding to BAR_CONTRAST_REGIONS. See the comments above each of them " +
        "in `src/frontend/styles/components/status_bar.styl`.",
    ).toEqual([]);
  });

  test("verify_the_image_painted_icons_still_paint_what_we_measured", () => {
    // `#copy-path-image` is painted by a `background-image` SVG, so
    // `getComputedStyle(...).color` describes nothing the user sees — read
    // naively it reports a comfortable 8.31:1 for an element whose visible
    // ink is a stroke this predicate has no access to. Rather than publish a
    // confident wrong number, the asset is pinned: its ink is recorded in
    // `IMAGE_PAINTED_ICONS` and checked here, so a redraw fails loudly and
    // the ratio gets re-derived instead of going quietly stale.
    const wrong: string[] = [];
    for (const icon of IMAGE_PAINTED_ICONS) {
      const assetPath = path.join(repoRoot, icon.asset);
      if (!fs.existsSync(assetPath)) {
        wrong.push(`${icon.selector}: asset ${icon.asset} does not exist`);
        continue;
      }
      const svg = fs.readFileSync(assetPath, "utf8");
      const lower = svg.toLowerCase();
      if (!lower.includes(icon.ink.toLowerCase())) {
        const inks = [...new Set(svg.match(/#[0-9a-fA-F]{3,8}/g) ?? [])];
        wrong.push(
          `${icon.selector}: ${icon.asset} no longer paints in ${icon.ink} ` +
            `(it now uses ${inks.join(", ") || "no hex colour at all"}). ` +
            "Re-measure it against the bar's #1b1b1b and update " +
            "IMAGE_PAINTED_ICONS — 3:1 is the floor for a control.",
        );
      }
    }
    expect(wrong, "image-painted icons must still paint what we measured").toEqual(
      [],
    );
  });
});
