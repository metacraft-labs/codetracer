/**
 * Guard: the BUILT theme stylesheet must leave every required footer region
 * visible — whatever the rule that hides it looks like.
 *
 * `Auto-Hide-Panes.md` §3.1 keeps the status bar's own content (language,
 * encoding, cursor location) in the footer while the bottom auto-hide tab
 * strip moves in; §10.3 puts the collapsed-strip icon zone in the same bar.
 * Three times now a single stylesheet rule has made the bar tabs-only —
 * `b27da3947 "feat: Redesign of the status bar"`; after that rule was
 * removed, `51a3e820e "fix: UI regressions"` writing it straight back; and
 * `00fd68b7f "fix: status bar styling"` reaching the same result a third way.
 * The first two announced themselves as a suite-wide timeout rather than as a
 * footer complaint, because every Electron spec opens with `readyOnEntryTest`
 * waiting for `.location-path` to be *visible*.  The third announced nothing
 * at all and shipped for two weeks — see below.
 *
 * WHY A SECOND GUARD, GIVEN `status-bar-footer-contract.spec.ts` EXISTS.
 * That spec asserts the same contract and would have failed on `51a3e820e`
 * — confirmed against that commit, 3/3 — but it costs a real Electron launch
 * against a real recorded trace, so it only ever runs where a built app and
 * a recorder sibling are both present.  This one needs neither: it applies
 * the compiled theme CSS to the footer's own markup in a plain browser page
 * and measures what the user would see.  Seconds, no `ct`, no trace, no
 * language recorder.  The two are complements, not duplicates: this one
 * catches the stylesheet, that one catches the app.
 *
 * WHAT IT REFUSES TO DO.  It does not look for a selector, a property name
 * or a rule.  There is no bounded set of ways to hide an element — `:not()`,
 * `:where()`, `:has()`, an enumerated list, `visibility`, `opacity`, a
 * hidden ancestor — and a guard that recognises the spelling of the last
 * regression is exactly the guard the next one walks past.  It asks the
 * browser whether each region has a box the user could look at, and whether
 * that box is where the user is looking.
 * `verify_the_guard_fires_for_spellings_it_has_never_seen` proves that by
 * re-running the check under ten different spellings, eight of which have
 * never been written in this repo.
 *
 * WHY IT ASKS THE SECOND QUESTION.  It used to ask only the first, and said
 * so: its own "where it stops" note named `position: absolute; left: -9999px`
 * as the head of the list of things it could not see.  Eight days later
 * `00fd68b7f` wrote precisely that on `#file-info-status` and `.status-right`
 * and compiled it into all three themes, and it shipped for two weeks with
 * this guard green — because an off-screen element has a full-size box, and
 * Playwright's own visibility predicate calls it "visible, enabled and
 * stable" too.  A documented blind spot is not a smaller guard; it is a
 * published route past it.  `verify_the_guard_refuses_the_regression_that_
 * shipped` is that exact stylesheet rule, watched being refused.
 *
 * WHERE IT STOPS — read this before relying on it.  Asking for a correctly
 * placed box catches every regression that changes LAYOUT or PLACEMENT, and
 * none that changes only PAINTING.  A footer clipped (`clip-path:
 * inset(100%)`), faded by `filter: opacity(0)` rather than `opacity: 0`,
 * drawn in the background colour, or covered by an overlay keeps a full-size
 * box in the right place and passes here.  That boundary is no longer only
 * prose: `SURVIVING_HIDE_SPELLINGS` in `page-objects/status-footer-contract.ts`
 * is the measured MISSED list as data, and
 * `verify_the_blind_spot_is_where_the_guard_says_it_is` runs every entry, so
 * strengthening the predicate without re-deriving the list turns this file
 * red.  The narrative version lives above `footerVisibilityFailures`.
 *
 * IT ALSO TRUSTS THE BUILD.  It reads whatever `src/build-debug` currently
 * holds, and cannot tell a fresh theme from a stale one — editing
 * `status_bar.styl` and running this spec WITHOUT `just build-once` reports
 * green against the previous build.  `just test-gui` takes `build-once` as a
 * prerequisite, which is what CI runs; `just test-gui-prebuilt` does not.
 * A missing build output does fail loudly (see `resolveTheme`); a stale one
 * cannot be detected from here.
 *
 * No mocks and no fixture stylesheet: the CSS under test is the artefact
 * `just build-once` ships to the renderer.  The markup is the footer subtree
 * the app renders, transcribed from
 * `src/frontend/viewmodel/views/isonim_status_view.nim`;
 * `verify_every_guarded_footer_region_is_still_rendered` fails if that view
 * stops emitting any part of it, so the guard cannot quietly decay into a
 * check on markup the app no longer produces (milestone M47).
 */
import * as fs from "node:fs";
import * as path from "node:path";

import { expect, test, type Page } from "@playwright/test";

import {
  CAUGHT_HIDE_SPELLINGS,
  COLLAPSED_ICON_ZONE_ACTIVE_CLASS,
  FOOTER_REQUIRED_REGIONS,
  OFF_SCREEN_RULE_CSS,
  SURVIVING_HIDE_SPELLINGS,
  footerVisibilityFailures,
  probeCollapsedIconZone,
  probeFooterRegions,
} from "../../page-objects/status-footer-contract";

/** Repo root, from `src/tests/gui/tests/status-bar`. */
const repoRoot = path.resolve(__dirname, "../../../../..");

/** Frontend view that owns the footer's DOM. */
const STATUS_VIEW = path.join(
  repoRoot,
  "src/frontend/viewmodel/views/isonim_status_view.nim",
);

/** Views that own the two footer children the status view only hosts. */
const STRIP_VIEW = path.join(
  repoRoot,
  "src/frontend/viewmodel/views/isonim_auto_hide_bottom_strip_view.nim",
);
const ICON_ZONE_VIEW = path.join(
  repoRoot,
  "src/frontend/viewmodel/views/isonim_auto_hide_collapsed_icons_view.nim",
);

/**
 * Where `just build-once` puts the compiled themes.
 *
 * Resolved the way `lib/fixtures.ts` resolves the build output — honour
 * `CODETRACER_BUILD_DIR`, else `src/build-debug` — plus the layout of a
 * nix-built app, whose `ct` lives at `<prefix>/bin/ct` with the styles at
 * `<prefix>/frontend/styles`.  See
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
 * The themes the shipped shells link.  `index.html` links
 * `default_dark_theme_electron.css`; the web/extension shells link the other
 * two.  `default_white_theme.css` is deliberately absent: its `.styl` imports
 * `defaults` only, so the built file is 0 bytes and carries no footer rules
 * (verified in M43).
 *
 * Every one of these is checked, because the rule that regressed lives in
 * `components/status_bar.styl`, which all three import — a fix applied to one
 * theme only would leave the other shells broken.
 */
const THEMES = [
  "default_dark_theme_electron.css",
  "default_dark_theme.css",
  "default_dark_theme_extension.css",
] as const;

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
 * Every id / class name a Nim view can put into the DOM.
 *
 * The views write them as string literals, sometimes several to an attribute
 * (`class = "location-path status-inline"`), so a plain substring search
 * would both miss those and match a longer name by accident
 * (`file-info-status` inside `file-info-status-language`).  Collecting the
 * whitespace-separated words of every double-quoted literal gives an exact
 * membership test for the one thing that matters: does the app still emit
 * this identifier.
 */
function identifiersEmittedBy(viewPath: string): Set<string> {
  const source = fs.readFileSync(viewPath, "utf8");
  const identifiers = new Set<string>();
  for (const literal of source.match(/"[^"\n]*"/g) ?? []) {
    for (const word of literal.slice(1, -1).trim().split(/\s+/)) {
      if (word.length > 0) identifiers.add(word);
    }
  }
  return identifiers;
}

/**
 * The footer as the app renders it.
 *
 * Element for element the subtree `renderStatusShell` emits into the `#status`
 * host of `src/frontend/index.html`
 * (`src/frontend/viewmodel/views/isonim_status_view.nim`, the `tdiv(id =
 * StatusBaseId)` block), inside the same `#root-container > footer` chain
 * `index.html` puts that host in — so a rule written against any of those
 * ancestors is exercised too, not just rules rooted at `#status`.
 *
 * Text content is representative rather than recorded: the readouts need
 * *some* text to have a width, and what the strings say is irrelevant to a
 * visibility check.  `.test-movement` is included because the app renders it
 * under `data.startOptions.inTest`, which is exactly the configuration every
 * GUI spec runs in.
 */
const FOOTER_MARKUP = `
  <div id="root-container">
    <footer>
      <div id="search-results"></div>
      <div id="status" class="status-shell">
        <div id="active-notifications"></div>
        <div id="status-base">
          <div id="auto-hide-collapsed-icon-zone" class="collapsed-icon-zone"></div>
          <div id="file-info-status">
            <span class="file-info-status-language status-inline">Javascript</span>
            <div class="separate-bar"></div>
            <span class="file-info-status-encoding status-inline">UTF-8</span>
            <div class="separate-bar"></div>
            <span id="operation-status">
              <span id="stable-status" class="ready-status">stable: ready</span>
            </span>
          </div>
          <div id="auto-hide-bottom-strip" class="auto-hide-bottom-strip has-tabs">
            <div class="auto-hide-strip-tab"><span class="auto-hide-strip-tab-label">BUILD</span></div>
            <div class="auto-hide-strip-tab"><span class="auto-hide-strip-tab-label">PROBLEMS</span></div>
            <div class="auto-hide-strip-tab"><span class="auto-hide-strip-tab-label">SEARCH RESULTS</span></div>
            <div class="auto-hide-strip-tab"><span class="auto-hide-strip-tab-label">REQUESTS</span></div>
          </div>
          <span class="test-movement">17</span>
          <span class="status-right">
            <span id="location-status">
              <span class="location-path status-inline" data-toggle="tooltip"
                    data-placement="bottom" title="/tmp/program.js:1#3">/tmp/program.js:1#3</span>
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

/**
 * Lay the footer out under `theme`, optionally with `extraCss` appended after
 * it (the negative controls' blanket hides, applied the way a later rule in
 * the same cascade would be).
 */
async function layOutFooter(
  page: Page,
  theme: string,
  extraCss?: string,
): Promise<void> {
  await page.setContent(`<!doctype html><html><body>${FOOTER_MARKUP}</body></html>`);
  await page.addStyleTag({ path: resolveTheme(theme) });
  if (extraCss !== undefined) await page.addStyleTag({ content: extraCss });
  // One frame, so the fixed-position bar has been laid out before it is read.
  await page.evaluate(
    () => new Promise<void>((resolve) => requestAnimationFrame(() => resolve())),
  );
}

test.describe("footer visibility guard (Auto-Hide-Panes §3.1 / §10.3)", () => {
  for (const theme of THEMES) {
    test(`verify_built_theme_keeps_every_footer_region_visible__${theme.replace(/\W+/g, "_")}`, async ({
      page,
    }) => {
      await layOutFooter(page, theme);

      const probes = await probeFooterRegions(page);
      // A probe that found nothing would make every later assertion vacuous,
      // so say so first and say it in terms of the markup, not the CSS.
      expect(
        probes.filter((p) => !p.found).map((p) => p.selector),
        "every guarded region must resolve in the footer markup — if one " +
          "does not, FOOTER_MARKUP has drifted from isonim_status_view.nim",
      ).toEqual([]);

      expect(
        footerVisibilityFailures(probes),
        `\`${theme}\` takes part of the status bar footer away from the ` +
          "user — by removing its box, or by leaving the box intact and " +
          "putting it where nobody is looking.  Auto-Hide-Panes §3.1 keeps " +
          "the bar's own content (language, encoding, cursor location) while " +
          "hosting the bottom tab strip, and §10.3 puts the icon zone in the " +
          "same bar.  A quieter footer has to come from restyling or from " +
          "changing the design doc first — not from hiding or exiling " +
          "`#status-base`'s children.  See `status_bar.styl`, and the " +
          "regressions in `b27da3947`, `51a3e820e` and `00fd68b7f`.",
      ).toEqual([]);

      // §10.3: the icon zone is idle-hidden but reachable.  The regression's
      // `!important` outranked `.collapsed-icon-zone.has-icons`, so the zone
      // could never appear — assert the class wins, not that the host exists.
      const zone = await probeCollapsedIconZone(page);
      expect(zone.present, "§10.3's icon zone must be in the footer").toBe(true);
      expect(zone.idle, "the icon zone is hidden while no strip is collapsed").toBe(
        "none",
      );
      expect(
        zone.active,
        `\`.${COLLAPSED_ICON_ZONE_ACTIVE_CLASS}\` must be able to show the icon zone`,
      ).toBe("flex");
    });
  }

  test("verify_the_guard_fires_for_spellings_it_has_never_seen", async ({
    page,
  }) => {
    // The point of the whole file.  The check above must fail for ANY way of
    // hiding the footer, not for the one that has been written before, so
    // each spelling is applied on top of a known-good theme and the check
    // must go red.  Eight of the ten have never appeared in this repo; the
    // other two are the rules that shipped.
    const survived: string[] = [];
    for (const spelling of CAUGHT_HIDE_SPELLINGS) {
      await layOutFooter(page, THEMES[0], spelling.css);
      const failures = footerVisibilityFailures(await probeFooterRegions(page));
      if (failures.length === 0) survived.push(`${spelling.name}: ${spelling.css}`);
    }
    expect(
      survived,
      "these ways of hiding the footer slipped past the guard, which means " +
        "the guard is checking something other than whether the user can see " +
        "the footer",
    ).toEqual([]);

    // ... and the guard must still pass with none of them applied, so the
    // line above is not passing because the check is simply always red.
    await layOutFooter(page, THEMES[0]);
    expect(
      footerVisibilityFailures(await probeFooterRegions(page)),
      "the unmodified built theme must satisfy the same check",
    ).toEqual([]);
  });

  test("verify_the_guard_refuses_the_regression_that_shipped", async ({
    page,
  }) => {
    // Control data, not a synthesised spelling.  `OFF_SCREEN_RULE_CSS` is
    // `00fd68b7f`'s rule as it compiled into all three built themes, and the
    // predicate this guard published as unable to see it named it verbatim.
    // Watch it refused, region by region, with the coordinate in the message
    // — a guard that has never said no is not a guard, and this one's whole
    // history is that it said yes to the thing it was written to prevent.
    await layOutFooter(page, THEMES[0], OFF_SCREEN_RULE_CSS);

    const failures = footerVisibilityFailures(await probeFooterRegions(page));

    // Every region the rule displaced, by name.  `#auto-hide-bottom-strip` is
    // deliberately absent: the rule leaves the tab strip alone, which is the
    // whole intent of a tabs-only footer, and a control that expected all six
    // would be describing a different rule.
    const refused = failures
      .map((f) => {
        const at = f.indexOf(": off-screen");
        return at < 0 ? `NOT AN OFF-SCREEN FAILURE: ${f}` : f.slice(0, at);
      })
      .sort();
    expect(
      refused,
      "the rule displaces the two readout groups and everything inside them",
    ).toEqual(
      [
        "#status-base #file-info-status",
        "#status-base #file-info-status .file-info-status-language",
        "#status-base #file-info-status #stable-status",
        "#status-base .status-right .location-path",
        "#status-base #copy-path-image",
      ].sort(),
    );

    // The diagnosis has to carry the coordinate, or a red guard sends whoever
    // reads it back to the stylesheet to work out what "off-screen" meant.
    for (const failure of failures) {
      expect(failure, "each refusal names where the box actually went").toMatch(
        /at x=-9\d{3},/,
      );
    }

    // Both negative controls, the other direction: the strip is untouched and
    // still passes, and the unmodified theme passes in full.  A predicate
    // that rejects everything is not an improvement on one that rejects
    // nothing.
    const strip = "#status-base #auto-hide-bottom-strip";
    expect(
      footerVisibilityFailures(await probeFooterRegions(page, [strip])),
      "the tab strip is not moved by this rule and must stay green",
    ).toEqual([]);

    await layOutFooter(page, THEMES[0]);
    expect(
      footerVisibilityFailures(await probeFooterRegions(page)),
      "and the current, correct theme must still satisfy the guard",
    ).toEqual([]);
  });

  test("verify_the_blind_spot_is_where_the_guard_says_it_is", async ({
    page,
  }) => {
    // The odd one out: it asserts a WEAKNESS, on purpose.
    //
    // `SURVIVING_HIDE_SPELLINGS` is the MISSED list this file publishes, and
    // the last MISSED list this file published was accurate right up to the
    // moment someone read it as a route.  Running it makes two things true
    // that prose alone cannot: the list is measured rather than asserted, and
    // it cannot silently shrink — strengthening `footerVisibilityFailures`
    // without moving an entry into `CAUGHT_HIDE_SPELLINGS` turns this red.
    const unexpectedlyCaught: string[] = [];
    for (const spelling of SURVIVING_HIDE_SPELLINGS) {
      await layOutFooter(page, THEMES[0], spelling.css);
      const failures = footerVisibilityFailures(await probeFooterRegions(page));
      if (failures.length > 0) {
        unexpectedlyCaught.push(`${spelling.name} — ${failures[0]}`);
      }
    }
    expect(
      unexpectedlyCaught,
      "the guard now catches these, which is good news and a stale document. " +
        "Move each one into CAUGHT_HIDE_SPELLINGS and re-derive the MISSED " +
        "prose in ALL FIVE places that carry it: above " +
        "`footerVisibilityFailures` in `page-objects/status-footer-contract" +
        ".ts`; the `WHERE IT STOPS` note in this file's header; " +
        "`src/frontend/styles/components/status_bar.styl`; " +
        "`.agents/codebase-insights.txt`; and " +
        "`codetracer-specs/Planned-Features/Value-Origin-Tracking.milestones" +
        ".org`. Do not simply delete the entry: a list that shrinks without " +
        "saying so is worse than one that is honest about its edge, and a " +
        "check that is corrected while the sentences describing it are not " +
        "is how this guard came to publish a route past itself.",
    ).toEqual([]);

    // The two lists must stay disjoint, or "caught" and "missed" stop meaning
    // anything.
    const caught = new Set(CAUGHT_HIDE_SPELLINGS.map((s) => s.css));
    expect(
      SURVIVING_HIDE_SPELLINGS.filter((s) => caught.has(s.css)).map(
        (s) => s.name,
      ),
      "a spelling cannot be both caught and missed",
    ).toEqual([]);
  });

  test("verify_every_guarded_footer_region_is_still_rendered", () => {
    // M47's lesson: a selector the app stopped emitting is not a failing
    // guard, it is a silent one.  Anchor every guarded region to the view
    // that renders it, so a rename in the frontend fails HERE, loudly,
    // instead of leaving a guard that can never go red.
    const emitted = identifiersEmittedBy(STATUS_VIEW);
    const missing: string[] = [];
    for (const region of FOOTER_REQUIRED_REGIONS) {
      for (const token of region.renderedAs) {
        if (!emitted.has(token)) {
          missing.push(`${token} (for ${region.selector})`);
        }
      }
    }
    expect(
      missing,
      `these identifiers are guarded but no longer emitted by ` +
        `${path.relative(repoRoot, STATUS_VIEW)}.  Either the footer lost a ` +
        "region — which is the regression this file exists to catch — or it " +
        "was renamed, in which case update FOOTER_REQUIRED_REGIONS and " +
        "FOOTER_MARKUP together.",
    ).toEqual([]);

    // The two children the status view only hosts.
    expect(
      fs.readFileSync(STRIP_VIEW, "utf8"),
      "the bottom strip must still render tabs with the class FOOTER_MARKUP uses",
    ).toContain('"auto-hide-strip-tab"');
    expect(
      fs.readFileSync(ICON_ZONE_VIEW, "utf8"),
      `§10.3's icon zone must still use \`${COLLAPSED_ICON_ZONE_ACTIVE_CLASS}\``,
    ).toContain(COLLAPSED_ICON_ZONE_ACTIVE_CLASS);
  });
});

/**
 * Guard: the BUILD panel is set in a font the theme actually ships.
 *
 * *"The font used in the build panel is not right."* No further detail, and
 * none was needed once the stylesheet was read against its own `@font-face`
 * list: `components/status_bar.styl` set the build output in `"FiraCode"`,
 * and **no `@font-face` in this repo declares a family by that name.** The
 * design system ships four — `SpaceGrotesk`, `SpaceMono`, `FiraMono` and
 * `FontAwesome` — and there is no FiraCode file anywhere in the tree.
 *
 * WHY THIS PANEL AND NOT THE OTHER SEVENTEEN. `"FiraCode"` appears in 21
 * rules. Most write `"FiraCode", monospace`, so the family is unresolvable
 * but the fallback catches it and the pane merely looks off-brand. The build
 * panel's four rules had no second entry AND were `!important`, so an
 * unresolvable family with no generic fallback fell all the way to the
 * browser's default standard font — a PROPORTIONAL SERIF — for
 * column-aligned compiler output. That is a different class of failure from
 * the others, and it is the one that got reported.
 *
 * WHAT IT ASSERTS, AND WHY NOT THE SPELLING. Not "the rule says SpaceMono":
 * that is a transcription of the fix and would pass just as happily on the
 * next undeclared name someone types. It asks the browser to resolve the
 * family the panel actually computes, and requires the FIRST entry to be one
 * the stylesheet declares — which is the property that was violated, stated
 * directly. The guard therefore also fires on a typo that has never been
 * written yet.
 */
test.describe("build panel font", () => {
  /** The families the compiled theme actually declares. */
  function declaredFamilies(themePath: string): Set<string> {
    const css = fs.readFileSync(themePath, "utf8");
    const out = new Set<string>();
    for (const block of css.match(/@font-face\s*\{[^}]*\}/g) ?? []) {
      const m = block.match(/font-family:\s*["']?([^;"'}]+)["']?/);
      if (m) out.add(m[1].trim());
    }
    return out;
  }

  /** The first family in a computed `font-family`, unquoted. */
  function firstFamily(computed: string): string {
    return (computed.split(",")[0] ?? "").trim().replace(/^["']|["']$/g, "");
  }

  for (const theme of THEMES) {
    test(`build output resolves to a declared family (${theme})`, async ({
      page,
    }) => {
      const themePath = resolveTheme(theme);
      const declared = declaredFamilies(themePath);
      expect(
        declared.size,
        `${theme} declares no @font-face at all; the check below would be vacuous`,
      ).toBeGreaterThan(0);

      // Both build surfaces: the IsoNim panel and the legacy Karax one, which
      // is where the IsoNim panel copied the family from in the first place.
      await page.setContent(
        `<div class="build-panel isonim-build">` +
          `<div id="build" class="build-output-container">` +
          `<div class="build-output-line" id="isonim-line">compiling…</div>` +
          `<div class="build-stderr" id="isonim-err">error[E0001]</div>` +
          `</div></div>` +
          `<div id="build-errors"><div class="build-error" id="karax-line">` +
          `error[E0001]</div></div>`,
        { waitUntil: "domcontentloaded" },
      );
      await page.addStyleTag({ path: themePath });
      await page.evaluate(
        () =>
          new Promise((r) =>
            requestAnimationFrame(() => requestAnimationFrame(r)),
          ),
      );

      const seen = await page.evaluate(() =>
        ["build", "isonim-line", "isonim-err", "karax-line"].map((id) => ({
          id,
          family: getComputedStyle(document.getElementById(id)!).fontFamily,
        })),
      );

      for (const { id, family } of seen) {
        const first = firstFamily(family);
        expect(
          declared.has(first),
          `#${id} is set in "${first}", which ${theme} does not declare ` +
            `(@font-face has: ${[...declared].join(", ")}). An undeclared ` +
            `family here falls back to the browser's default serif, because ` +
            `these rules write no generic family after it.`,
        ).toBe(true);

        // The fallback, asserted separately — it is the property whose absence
        // turned a typo into a serif, so it is worth its own failure message.
        expect(
          family.split(",").length,
          `#${id} names a single family with no generic fallback`,
        ).toBeGreaterThan(1);
      }
    });
  }

  test("verify the font guard can fail", async ({ page }) => {
    // The rule as it shipped. Reproduced rather than described, so the check
    // above is watched failing against the declaration that was reported.
    await page.setContent(`<div id="shipped">compiling…</div>`, {
      waitUntil: "domcontentloaded",
    });
    await page.addStyleTag({
      content: `#shipped { font-family: "FiraCode" !important; }`,
    });
    await page.evaluate(
      () =>
        new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))),
    );

    const family = await page.evaluate(
      () => getComputedStyle(document.getElementById("shipped")!).fontFamily,
    );
    const declared = declaredFamilies(resolveTheme(THEMES[0]));

    expect(firstFamily(family), "the shipped rule must name FiraCode").toBe(
      "FiraCode",
    );
    expect(
      declared.has("FiraCode"),
      "FiraCode must be undeclared, or the guard above proves nothing",
    ).toBe(false);
    expect(family.split(",").length, "the shipped rule had no fallback").toBe(1);
  });
});
