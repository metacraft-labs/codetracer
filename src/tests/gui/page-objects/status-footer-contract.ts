/**
 * The status-bar footer contract, in one place, expressed as an *effect*.
 *
 * `Auto-Hide-Panes.md` §3.1 says the footer hosts the bottom auto-hide tab
 * strip **alongside** the bar's own content —
 *
 *     |-- Status Bar / Footer
 *     |     |-- Left: auto-hide tab labels for bottom-pinned panels
 *     |     |-- Right: existing status bar content (language, encoding, location)
 *
 * — and §10.3 puts the collapsed-strip icon zone in the same bar.
 * `tools/screen-briefs.md` (Screen 1) states the same expectation for the
 * visual audit.
 *
 * WHY THIS FILE IS SHAPED THE WAY IT IS.  The same regression has been
 * written three times.  `b27da3947 "feat: Redesign of the status bar"` added
 *
 *     #status #status-base > *:not(#auto-hide-bottom-strip)
 *       display: none !important
 *
 * making the footer tabs-only; it was removed and the contract pinned with
 * `tests/status-bar/status-bar-footer-contract.spec.ts`; and
 * `51a3e820e "fix: UI regressions"` wrote the identical rule back into
 * `status_bar.styl`.  Both times the visible symptom was not a footer
 * complaint but a suite-wide timeout: every Electron spec opens with
 * `readyOnEntryTest`, which waits for `.location-path` to be **visible**.
 *
 * The lesson of that repeat is that a guard must not recognise a *spelling*.
 * There are unboundedly many ways to make an element invisible —
 * `:not()`, `:where()`, `:has()`, an enumerated selector list, `visibility`,
 * `opacity`, a hidden ancestor — and only one thing they have in common:
 * the user cannot see the element.  So everything here is phrased as an
 * effect on what the user can look at, never as "does the stylesheet contain
 * this text".
 *
 * THE THIRD TIME TAUGHT THE SECOND LESSON, WHICH IS WHY THE PREDICATE MOVED.
 * The first version of that effect was "does this region have a box", and
 * its own header said in as many words that an off-screen region has one —
 * `position: absolute; left: -9999px` was the first entry in the MISSED list
 * this file published.  Eight days later `00fd68b7f "fix: status bar
 * styling"` wrote exactly that, on `#file-info-status` and `.status-right`,
 * and it shipped for two weeks.  A documented blind spot is not a smaller
 * guard, it is an invitation; so the predicate now asks whether the region
 * has a box **that lies where the user is looking**, and the two questions
 * are asked together.
 *
 * That is still not a complete net: a geometry probe cannot see a region
 * that is painted wrongly rather than laid out or placed wrongly.  The exact
 * boundary — what is caught, what is not, and why — is written out above
 * `footerVisibilityFailures`, which is where the decision is made, and it is
 * *executable*: `CAUGHT_HIDE_SPELLINGS` and `SURVIVING_HIDE_SPELLINGS` are
 * that boundary as data, and the guard asserts both halves on every run, so
 * a strengthened predicate cannot leave the prose behind again.  Read it
 * before trusting this file with a new class of regression.
 *
 * Consumers:
 *   - `tests/status-bar/footer-visibility-css-guard.spec.ts` — runs the probe
 *     against the BUILT theme stylesheets in a plain browser page (no
 *     Electron, no recorder, seconds not minutes).
 *   - `tests/status-bar/status-bar-footer-contract.spec.ts` — runs the same
 *     probe against the real Electron app, and re-injects every spelling in
 *     `CAUGHT_HIDE_SPELLINGS` as a negative control.
 */
import type { Page } from "@playwright/test";

/** A footer region the design requires to be visible, and the reason why. */
export interface FooterRegion {
  /** CSS selector, resolved inside the running page. */
  readonly selector: string;
  /** Why hiding it is a regression, in one line. */
  readonly why: string;
  /**
   * Identifier the frontend view must still emit for this selector to mean
   * anything — see `verify_every_guarded_footer_region_is_still_rendered`.
   * A guard whose selector no longer exists in the app is not a guard, it is
   * a locator that matches nothing (milestone M47).
   */
  readonly renderedAs: readonly string[];
}

/**
 * Everything `Auto-Hide-Panes.md` §3.1 keeps in the footer, plus the tab
 * strip §3.1 moves into it.  §10.3's icon zone is checked separately by
 * `probeCollapsedIconZone` because it is legitimately `display: none` until
 * a collapsed strip has panels.
 *
 * Scoped through `#status-base` so a region that survives *outside* the bar
 * cannot satisfy the check.
 */
export const FOOTER_REQUIRED_REGIONS: readonly FooterRegion[] = [
  {
    selector: "#status-base #file-info-status",
    why: "language / encoding / `stable: ready` readout — Auto-Hide-Panes §3.1",
    renderedAs: ["file-info-status"],
  },
  {
    selector: "#status-base #file-info-status .file-info-status-language",
    why: "the language readout §3.1 names explicitly",
    renderedAs: ["file-info-status-language"],
  },
  {
    selector: "#status-base #file-info-status #stable-status",
    why: "the `stable: ready` process state the screen brief requires",
    renderedAs: ["stable-status"],
  },
  {
    selector: "#status-base #auto-hide-bottom-strip",
    why: "the bottom auto-hide tab strip §3.1 moves into the footer",
    renderedAs: ["auto-hide-bottom-strip"],
  },
  {
    selector: "#status-base .status-right .location-path",
    why:
      "the ONLY display of the current debug location anywhere in the UI — " +
      "nothing else renders `StatusBaseModel.locationText` — and the element " +
      "`readyOnEntryTest` waits for, so hiding it fails every Electron spec",
    renderedAs: ["location-path", "location-status", "status-right"],
  },
  {
    selector: "#status-base #copy-path-image",
    why:
      "the only copy affordance for that location (the editor tab's " +
      "'Copy full path' copies the tab label, not the debug location)",
    renderedAs: ["copy-path-image"],
  },
] as const;

/** §10.3's collapsed-strip icon zone, hosted in the same bar. */
export const COLLAPSED_ICON_ZONE_SELECTOR = "#auto-hide-collapsed-icon-zone";

/** The class `auto_hide.styl` turns the idle icon zone into a flex row with. */
export const COLLAPSED_ICON_ZONE_ACTIVE_CLASS = "has-icons";

/** One way of writing "make the footer's own content go away". */
export interface HideSpelling {
  readonly name: string;
  readonly css: string;
}

/**
 * The rule that made the footer tabs-only in `b27da3947` and `51a3e820e`,
 * verbatim.  Named rather than reached by index, because two specs pin the
 * historical case by name and the list around it grows.
 */
export const TABS_ONLY_RULE_CSS =
  "#status #status-base > *:not(#auto-hide-bottom-strip) { display: none !important; }";

/**
 * The rule that made the footer tabs-only a third time, in `00fd68b7f`,
 * verbatim as it compiled into all three themes.  It is the whole reason the
 * predicate below measures placement as well as box: this is the spelling
 * the guard's own MISSED list named first, eight days before it shipped.
 */
export const OFF_SCREEN_RULE_CSS =
  "#status #status-base #file-info-status, #status #status-base .status-right " +
  "{ position: absolute; left: -9999px; }";

/**
 * Ways of writing "hide the footer's own content" that the guard must catch.
 *
 * Entries #1 and #7 are the rules that actually shipped — the tabs-only
 * `display: none` of `b27da3947`/`51a3e820e`, and the off-screen placement of
 * `00fd68b7f` — kept verbatim so the historical cases stay covered.  The rest
 * are spellings nobody has written yet: they exist to prove the guard checks
 * the *effect*.  A guard that only rejects entry #1 would have caught the
 * first two regressions and still waved through any of #2-#10 — which is not
 * hypothetical, because that is precisely what happened to #7.
 *
 * Add to this list rather than rewriting it — each entry is a shape the
 * guard is known to reject.  Its counterpart is `SURVIVING_HIDE_SPELLINGS`;
 * the two together are the guard's measured edge, and the browser guard
 * asserts the partition on every run.
 */
export const CAUGHT_HIDE_SPELLINGS: readonly HideSpelling[] = [
  {
    name: "the rule that shipped twice (b27da3947, 51a3e820e)",
    css: TABS_ONLY_RULE_CSS,
  },
  {
    name: "`:where()` instead of a bare `:not()`",
    css: "#status-base > :where(:not(#auto-hide-bottom-strip)) { display: none !important; }",
  },
  {
    name: "`visibility` instead of `display` — the boxes survive",
    css: "#status-base > *:not(#auto-hide-bottom-strip) { visibility: hidden !important; }",
  },
  {
    name: "`opacity: 0` — boxes and `visibility` both survive",
    css: "#status-base > *:not(#auto-hide-bottom-strip) { opacity: 0 !important; }",
  },
  {
    name: "an enumerated selector list, no `:not()` anywhere",
    css:
      "#status-base > #file-info-status, #status-base > .status-right, " +
      "#status-base > #auto-hide-collapsed-icon-zone { display: none !important; }",
  },
  {
    name: "an attribute selector instead of an id selector",
    css: '#status-base > *:not([id="auto-hide-bottom-strip"]) { display: none !important; }',
  },
  {
    name: "the rule that shipped a third time (00fd68b7f) — off-screen, box intact",
    css: OFF_SCREEN_RULE_CSS,
  },
  {
    name: "off-screen by `!important`, applied to the group rather than by name",
    css:
      "#status-base > *:not(#auto-hide-bottom-strip) " +
      "{ position: absolute !important; left: -9999px !important; }",
  },
  {
    name: "off-screen upwards instead of leftwards — `top`, not `left`",
    css:
      "#status-base > *:not(#auto-hide-bottom-strip) " +
      "{ position: fixed !important; top: -9999px !important; }",
  },
  {
    name: "off-screen by transform, which needs no `position` at all",
    css:
      "#status-base > *:not(#auto-hide-bottom-strip) " +
      "{ transform: translateX(-9999px) !important; }",
  },
] as const;

/**
 * Ways of making the footer unreadable that this guard does **not** catch,
 * measured rather than asserted.
 *
 * This list is the guard's edge stated as a fact about the predicate, and it
 * is checked: `verify_the_blind_spot_is_where_the_guard_says_it_is` requires
 * every entry here to leave `footerVisibilityFailures` empty.  That is a
 * deliberately odd-looking test — it asserts a *weakness* — and it exists
 * because this file's previous MISSED list went stale in the worst possible
 * direction: it was accurate, it named `position: absolute; left: -9999px`
 * first, and a regression walked straight through it.  Making the boundary
 * executable means a future strengthening of the predicate turns this test
 * red, and the only way to green is to move the entry into
 * `CAUGHT_HIDE_SPELLINGS` and re-derive the prose above
 * `footerVisibilityFailures`.  A silently shrinking MISSED list is worse
 * than an honest one.
 *
 * Every entry shares one shape: the geometry is intact, the box is where the
 * user is looking, and only the *painting* is wrong.  Seeing them needs a
 * different instrument — a screenshot of the footer strip, or an
 * `elementsFromPoint` hit test — not another rule in the predicate.
 */
export const SURVIVING_HIDE_SPELLINGS: readonly (HideSpelling & {
  /** Why a geometry probe cannot see this one, in one line. */
  readonly why: string;
  /**
   * A DIFFERENT guard that does catch this one, when there is one.
   *
   * Added when the colour-only entries stopped being a pure blind spot.
   * `tests/status-bar/footer-contrast-guard.spec.ts` measures what every
   * region of the bar is painted against what is behind it, which is exactly
   * the instrument the two `why` lines below said was needed — so those two
   * are no longer unseen by the suite, only unseen by THIS predicate.
   *
   * They stay in this list rather than moving to `CAUGHT_HIDE_SPELLINGS`,
   * because that list is what `footerVisibilityFailures` rejects and it still
   * does not reject these: a geometry probe cannot see a colour, and pretending
   * otherwise would put a false entry in the one place this file is trusted to
   * be literal. The honest shape is "missed here, caught there", said in data.
   *
   * `verify_it_closes_the_colour_half_of_the_blind_spot` in the contrast guard
   * RUNS every entry marked `"contrast"` and fails if it is not caught, so this
   * annotation cannot rot into a claim nothing checks — which is the exact
   * failure mode that made this file's previous MISSED list a published route
   * past the guard.
   */
  readonly caughtBy?: "contrast";
})[] = [
  {
    name: "`clip-path: inset(100%)`",
    css: "#status-base > *:not(#auto-hide-bottom-strip) { clip-path: inset(100%) !important; }",
    why: "clipping is a paint operation; the border box is untouched",
  },
  {
    name: "legacy `clip: rect(0, 0, 0, 0)`, the screen-reader-only idiom",
    css:
      "#status-base > *:not(#auto-hide-bottom-strip) " +
      "{ position: absolute !important; clip: rect(0, 0, 0, 0) !important; }",
    why:
      "same as `clip-path`, and the `position: absolute` it requires leaves " +
      "the element at its static position, which is on-screen",
  },
  {
    name: "`filter: opacity(0)` — one word from `opacity: 0`, which IS caught",
    css: "#status-base > *:not(#auto-hide-bottom-strip) { filter: opacity(0) !important; }",
    why: "`getComputedStyle().opacity` still reads 1; the fade is in the filter chain",
  },
  {
    name: "`filter: blur(40px)`",
    css: "#status-base > *:not(#auto-hide-bottom-strip) { filter: blur(40px) !important; }",
    why: "illegible but fully laid out, and unreadability is not a measurable threshold",
  },
  {
    name: "near-zero but non-zero opacity",
    css: "#status-base > *:not(#auto-hide-bottom-strip) { opacity: 0.001 !important; }",
    why: "the predicate rejects effective opacity 0; anything above it is a judgement call",
  },
  {
    name: "`color: transparent`",
    css: "#status-base > *:not(#auto-hide-bottom-strip) { color: transparent !important; }",
    why: "text colour is not geometry; the boxes keep their full size",
    caughtBy: "contrast",
  },
  {
    name: "text drawn in the background colour",
    css:
      "#status-base > *:not(#auto-hide-bottom-strip) " +
      "{ color: var(--colors-ui-surface-primary-default, #2c2c2c) !important; }",
    why: "requires comparing two computed colours against a contrast threshold, not a box",
    caughtBy: "contrast",
  },
  {
    name: "occlusion by an overlay painted on top",
    css:
      "#status-base::after { content: ''; position: absolute; inset: 0; " +
      "background: #2c2c2c; z-index: 999; }",
    why:
      "the regions are laid out, on-screen and opaque; only a hit test or a " +
      "screenshot can tell that something else is drawn over them",
  },
] as const;

/** What one region looks like to the user, measured in the live page. */
export interface RegionProbe {
  readonly selector: string;
  readonly found: boolean;
  readonly width: number;
  readonly height: number;
  /**
   * Where the box actually sits, in viewport coordinates.
   *
   * Carried because size alone answers the wrong question.  `00fd68b7f` left
   * every region at its full width and height and moved it to x = -9999, and
   * a predicate that reads only `width`/`height` calls that a visible footer
   * — as this one did, for two weeks.  `getBoundingClientRect` folds
   * `position`, `inset` and `transform` together, so one pair of numbers
   * covers every way of putting a box somewhere the user is not looking.
   */
  readonly x: number;
  readonly y: number;
  readonly right: number;
  readonly bottom: number;
  /** The viewport those coordinates are measured against. */
  readonly viewportWidth: number;
  readonly viewportHeight: number;
  readonly display: string;
  readonly visibility: string;
  /** Product of `opacity` from the element up to `<body>`. */
  readonly effectiveOpacity: number;
  /**
   * The nearest element on the chain (the region itself or an ancestor) that
   * removes it from view, described as `tag#id.class { … }`, or `null`.
   * This is what turns a red guard into a one-line diagnosis.
   */
  readonly hiddenBy: string | null;
  /**
   * The same, for placement: the OUTERMOST element on the chain whose own box
   * is wholly outside the viewport, described with the properties that put it
   * there (`position`, `left`/`top`, `transform`), or `null`.
   *
   * Reported separately from `hiddenBy` because the two failures read
   * differently to whoever has to fix them — one says "your rule removed the
   * box", the other says "your rule kept the box and moved it to x = -9999" —
   * and because they point at opposite ends of the ancestor chain.  See the
   * walk in `probeFooterRegions` for why.
   */
  readonly displacedBy: string | null;
}

/**
 * Measure every required region in whatever page `page` currently holds.
 *
 * Works identically against the real Electron renderer and against a plain
 * browser page carrying the built stylesheet, which is the point: one
 * predicate, two costs.
 */
export async function probeFooterRegions(
  page: Page,
  selectors: readonly string[] = FOOTER_REQUIRED_REGIONS.map((r) => r.selector),
): Promise<RegionProbe[]> {
  return page.evaluate((wanted: string[]) => {
    const describe = (node: Element): string => {
      const id = node.id ? `#${node.id}` : "";
      const cls = node.classList.length
        ? `.${Array.from(node.classList).join(".")}`
        : "";
      return `${node.tagName.toLowerCase()}${id}${cls}`;
    };

    const viewportWidth = window.innerWidth;
    const viewportHeight = window.innerHeight;

    /**
     * Does this box overlap the viewport at all?
     *
     * Deliberately the weakest form of the question.  A footer readout is
     * allowed to be partly off the right edge (`.location-path` ellipsises
     * rather than wraps, and the bar is tight at the 1050px minimum window),
     * so "wholly inside" would be a false positive waiting to happen.  "Not
     * one pixel of it is where the user is looking" is not.
     */
    const overlapsViewport = (r: DOMRect): boolean =>
      r.right > 0 && r.bottom > 0 && r.x < viewportWidth && r.y < viewportHeight;

    return wanted.map((selector) => {
      const el = document.querySelector(selector) as HTMLElement | null;
      if (el === null) {
        return {
          selector,
          found: false,
          width: 0,
          height: 0,
          x: 0,
          y: 0,
          right: 0,
          bottom: 0,
          viewportWidth,
          viewportHeight,
          display: "",
          visibility: "",
          effectiveOpacity: 0,
          hiddenBy: null,
          displacedBy: null,
        };
      }
      const rect = el.getBoundingClientRect();
      const own = getComputedStyle(el);
      let effectiveOpacity = 1;
      let hiddenBy: string | null = null;
      let displacedBy: string | null = null;
      for (
        let node: HTMLElement | null = el;
        node !== null;
        node = node.parentElement
      ) {
        const style = getComputedStyle(node);
        const opacity = Number.parseFloat(style.opacity);
        effectiveOpacity *= Number.isNaN(opacity) ? 1 : opacity;
        if (
          hiddenBy === null &&
          (style.display === "none" ||
            style.visibility === "hidden" ||
            style.visibility === "collapse" ||
            opacity === 0)
        ) {
          hiddenBy =
            `${describe(node)} { display: ${style.display}; ` +
            `visibility: ${style.visibility}; opacity: ${style.opacity} }` +
            (node === el ? " (the region itself)" : " (an ancestor)");
        }
        // Only elements that HAVE a box can be blamed for a misplaced one; a
        // zero-size ancestor sitting at the origin satisfies `right <= 0`
        // arithmetically without having moved anything.
        //
        // Unlike `hiddenBy`, this keeps walking and takes the OUTERMOST
        // offender rather than the nearest.  `display: none` is inherited by
        // effect, so the nearest hidden element is the one that did it; being
        // off-screen is inherited by POSITION, so the nearest one is almost
        // always an innocent `position: static` child dragged along by its
        // parent.  Blaming `.file-info-status-language { position: static }`
        // for a `#file-info-status { left: -9999px }` sends the reader to the
        // wrong rule.
        const nodeRect = node.getBoundingClientRect();
        if (
          nodeRect.width > 0 &&
          nodeRect.height > 0 &&
          !overlapsViewport(nodeRect)
        ) {
          displacedBy =
            `${describe(node)} { position: ${style.position}; ` +
            `left: ${style.left}; top: ${style.top}; ` +
            `transform: ${style.transform} } at x=${Math.round(nodeRect.x)}, ` +
            `y=${Math.round(nodeRect.y)}` +
            (node === el ? " (the region itself)" : " (an ancestor)");
        }
        if (node === document.body) break;
      }
      return {
        selector,
        found: true,
        width: rect.width,
        height: rect.height,
        x: rect.x,
        y: rect.y,
        right: rect.right,
        bottom: rect.bottom,
        viewportWidth,
        viewportHeight,
        display: own.display,
        visibility: own.visibility,
        effectiveOpacity,
        hiddenBy,
        displacedBy,
      };
    });
  }, selectors as string[]);
}

/**
 * Turn probes into human-readable failures — empty means the contract holds.
 *
 * The question is "could the user look at this region", and it has two
 * halves, because three regressions have now shown that answering only the
 * first half is answering the wrong question:
 *
 *   1. IS THERE A BOX.  The same property `readyOnEntryTest` waits for (a
 *      real box, not merely an attached node), widened to also reject
 *      `visibility` and `opacity` tricks that leave a box behind.
 *   2. IS THE BOX WHERE THE USER IS LOOKING.  Added after `00fd68b7f`, which
 *      kept every box at full size and put it at x = -9999.  A region whose
 *      rect does not overlap the viewport at all fails, and the failure names
 *      the coordinate.
 *
 * Returning strings rather than asserting keeps the negative controls able to
 * assert that the check *does* fail without wrapping an expectation in a
 * try/catch.
 *
 * WHERE THE PREDICATE STOPS.  Stated explicitly because the value of a guard
 * is knowing its edge — and stated as *data* rather than only as prose,
 * because the last time this boundary was written down as prose alone it
 * stayed accurate and the regression walked through it anyway.  The two lists
 * below are asserted on every run of the browser guard.  Re-derived by
 * running all 27 spellings back through the predicate: the 17 that were
 * caught still are, 2 of the 10 that were missed now fail, and 8 still pass.
 *
 *   CAUGHT (19) — see `CAUGHT_HIDE_SPELLINGS`.  `display: none` however the
 *            selector is written (`:not()`, `:where()`, `:has()`, an
 *            enumerated list, an attribute selector, wrapped in `@media`);
 *            `visibility: hidden/collapse`; `opacity: 0`; `transform:
 *            scale(0)` and `scale: 0`; `content-visibility: hidden`;
 *            `font-size: 0`; `width: 0` / `max-height: 0` with `overflow:
 *            hidden`; `text-indent`; flex collapse — those 17 by having no
 *            box.  Plus the two that changed sides: `position: absolute;
 *            left: -9999px` (equally by `top`/`right`, and equally with
 *            `fixed`) and `transform: translateX(-9999px)`, which needs no
 *            `position` at all — those by having a box nowhere on screen.
 *            All of the above also when applied to an ANCESTOR rather than to
 *            the region itself.
 *
 *   MISSED (8) — see `SURVIVING_HIDE_SPELLINGS`, which is the authoritative,
 *            executable copy.  Everything that keeps a full-size box *at its
 *            proper coordinates* and changes only the painting: the legacy
 *            `position: absolute; clip: rect(0,0,0,0)` idiom — note the
 *            previous version of this list filed that under "off-screen
 *            placement", and it is not: the `absolute` it needs leaves the
 *            element at its static position, and only the clip hides it;
 *            `clip-path: inset(100%)`; `filter: opacity(0)` and `filter:
 *            blur(40px)` — the first is a hair from `opacity: 0`, which IS
 *            caught; near-zero but non-zero opacity (`0.001`); colour-only
 *            invisibility (`color: transparent`, or a colour equal to the
 *            background); and occlusion by an overlay painted on top.
 *            There is also a boundary case by construction: `overlapsViewport`
 *            asks for one pixel of overlap, so a region pushed almost entirely
 *            off the edge still passes.
 *
 *            MISSED HERE IS NO LONGER MISSED EVERYWHERE, for two of those
 *            eight.  Colour-only invisibility is now measured by
 *            `tests/status-bar/footer-contrast-guard.spec.ts`, which compares
 *            what each region is painted against what is behind it — the very
 *            instrument the entries' own `why` said was required.  They stay
 *            in the MISSED list because THIS predicate still cannot see them
 *            and this list is about this predicate; they carry
 *            `caughtBy: "contrast"`, and that guard runs every entry so
 *            annotated.  The other six remain uncovered by anything.
 *
 * The misses share one shape: the geometry is intact and correctly placed,
 * and only the *painting* is wrong, which `getBoundingClientRect` plus the
 * computed-style chain cannot see.  `readyOnEntryTest` misses all of them and
 * misses the off-screen family too — Playwright's visibility predicate
 * reports an off-screen `.location-path` as "visible, enabled and stable" —
 * so this predicate is now strictly stronger than the readiness wait in both
 * halves.  Closing what remains needs a different instrument (a screenshot of
 * the footer strip, or an `elementsFromPoint` hit test), not another rule
 * here.
 */
export function footerVisibilityFailures(
  probes: readonly RegionProbe[],
): string[] {
  const reasonFor = (selector: string): string =>
    FOOTER_REQUIRED_REGIONS.find((r) => r.selector === selector)?.why ??
    "required by Auto-Hide-Panes §3.1";

  const failures: string[] = [];
  for (const probe of probes) {
    const suffix = ` — ${reasonFor(probe.selector)}`;
    if (!probe.found) {
      failures.push(`${probe.selector}: not present in the page${suffix}`);
      continue;
    }
    const hidden =
      probe.width <= 0 ||
      probe.height <= 0 ||
      probe.visibility === "hidden" ||
      probe.visibility === "collapse" ||
      probe.effectiveOpacity <= 0;
    if (hidden) {
      failures.push(
        `${probe.selector}: invisible — ` +
          `box ${probe.width}x${probe.height}, display ${probe.display}, ` +
          `visibility ${probe.visibility}, effective opacity ` +
          `${probe.effectiveOpacity}` +
          (probe.hiddenBy === null ? "" : `, hidden by ${probe.hiddenBy}`) +
          suffix,
      );
      // One diagnosis per region: a region with no box has no meaningful
      // coordinates to report on top of it.
      continue;
    }
    // The box exists.  Is any of it on screen?  `right`/`bottom` are
    // exclusive edges, so `right <= 0` means the box ends at or before the
    // left edge of the viewport — which is what x = -9999 produces.
    const offScreen =
      probe.right <= 0 ||
      probe.bottom <= 0 ||
      probe.x >= probe.viewportWidth ||
      probe.y >= probe.viewportHeight;
    if (offScreen) {
      failures.push(
        `${probe.selector}: off-screen — ` +
          `box ${probe.width}x${probe.height} at x=${Math.round(probe.x)}, ` +
          `y=${Math.round(probe.y)} (right=${Math.round(probe.right)}, ` +
          `bottom=${Math.round(probe.bottom)}), which is outside the ` +
          `${probe.viewportWidth}x${probe.viewportHeight} viewport` +
          (probe.displacedBy === null
            ? ""
            : `, displaced by ${probe.displacedBy}`) +
          suffix,
      );
    }
  }
  return failures;
}

/** Idle vs `has-icons` computed `display` of §10.3's icon zone. */
export interface IconZoneProbe {
  readonly present: boolean;
  readonly idle: string;
  readonly active: string;
}

/**
 * §10.3's icon zone is `display: none` until a collapsed strip has panels,
 * at which point `auto_hide.styl`'s `.collapsed-icon-zone.has-icons` turns it
 * into a flex row.  The blanket rule's `!important` outranked that class, so
 * the zone could never appear — the rule broke the very feature whose tab
 * strip it was making room for.  Assert the class actually wins, not merely
 * that the host element exists.
 */
export async function probeCollapsedIconZone(
  page: Page,
): Promise<IconZoneProbe> {
  return page.evaluate(
    ([selector, activeClass]: [string, string]) => {
      const zone = document.querySelector(selector) as HTMLElement | null;
      if (zone === null) return { present: false, idle: "", active: "" };
      const idle = getComputedStyle(zone).display;
      const hadClass = zone.classList.contains(activeClass);
      zone.classList.add(activeClass);
      const active = getComputedStyle(zone).display;
      if (!hadClass) zone.classList.remove(activeClass);
      return { present: true, idle, active };
    },
    [COLLAPSED_ICON_ZONE_SELECTOR, COLLAPSED_ICON_ZONE_ACTIVE_CLASS] as [
      string,
      string,
    ],
  );
}
