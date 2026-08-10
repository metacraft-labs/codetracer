/**
 * Guard: the BUILT theme stylesheet must leave every required footer region
 * visible — whatever the rule that hides it looks like.
 *
 * `Auto-Hide-Panes.md` §3.1 keeps the status bar's own content (language,
 * encoding, cursor location) in the footer while the bottom auto-hide tab
 * strip moves in; §10.3 puts the collapsed-strip icon zone in the same bar.
 * Twice now a single stylesheet rule has made the bar tabs-only —
 * `b27da3947 "feat: Redesign of the status bar"` (milestone M43) and, after
 * M43 removed it, `51a3e820e "fix: UI regressions"` (milestone M66) — and
 * both times the symptom was not a footer complaint but a suite-wide
 * timeout, because every Electron spec opens with `readyOnEntryTest` waiting
 * for `.location-path` to be *visible*.
 *
 * WHY A SECOND GUARD, GIVEN `status-bar-footer-contract.spec.ts` EXISTS.
 * That spec asserts the same contract and would have failed on `51a3e820e`
 * — M66 confirmed it does, 3/3 — but it costs a real Electron launch
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
 * browser whether each region has a box the user could look at.
 * `verify_the_guard_fires_for_spellings_it_has_never_seen` proves that by
 * re-running the check under six different spellings, five of which have
 * never been written in this repo.
 *
 * WHERE IT STOPS — read this before relying on it.  Asking for a box catches
 * every regression that changes LAYOUT, and none that changes only PAINTING.
 * A footer moved off-screen (`position: absolute; left: -9999px`), clipped
 * (`clip-path: inset(100%)`), faded by `filter: opacity(0)` rather than
 * `opacity: 0`, or drawn in the background colour keeps a full-size box and
 * passes here.  `readyOnEntryTest` passes on those too — Playwright calls an
 * off-screen `.location-path` "visible, enabled and stable" — so that family
 * is currently unguarded by anything in the suite.  The full measured list of
 * what is caught and what is not lives above `footerVisibilityFailures` in
 * `page-objects/status-footer-contract.ts`.
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
  BLANKET_HIDE_SPELLINGS,
  COLLAPSED_ICON_ZONE_ACTIVE_CLASS,
  FOOTER_REQUIRED_REGIONS,
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
        `\`${theme}\` hides part of the status bar footer.  Auto-Hide-Panes ` +
          "§3.1 keeps the bar's own content (language, encoding, cursor " +
          "location) while hosting the bottom tab strip, and §10.3 puts the " +
          "icon zone in the same bar.  A quieter footer has to come from " +
          "restyling or from changing the design doc first — not from hiding " +
          "`#status-base`'s children.  See `status_bar.styl`, milestones " +
          "M43 and M66.",
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
    // must go red.  Five of the six have never appeared in this repo.
    const survived: string[] = [];
    for (const spelling of BLANKET_HIDE_SPELLINGS) {
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
