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
 * written twice: `b27da3947 "feat: Redesign of the status bar"` added
 *
 *     #status #status-base > *:not(#auto-hide-bottom-strip)
 *       display: none !important
 *
 * making the footer tabs-only; milestone M43 removed it and pinned the
 * contract with `tests/status-bar/status-bar-footer-contract.spec.ts`; and
 * `51a3e820e "fix: UI regressions"` wrote the identical rule back into
 * `status_bar.styl` (M66).  Both times the visible symptom was not a footer
 * complaint but a suite-wide timeout: every Electron spec opens with
 * `readyOnEntryTest`, which waits for `.location-path` to be **visible**.
 *
 * The lesson M66 draws is that a guard must not recognise a *spelling*.
 * There are unboundedly many ways to make an element invisible —
 * `:not()`, `:where()`, `:has()`, an enumerated selector list, `visibility`,
 * `opacity`, a hidden ancestor — and only one thing they have in common:
 * the user cannot see the element.  So everything here is phrased as "does
 * this region have a box the user could look at", never as "does the
 * stylesheet contain this text".
 *
 * That buys a much wider net than matching rule text, but not a complete
 * one: a box-and-computed-style probe still cannot see a region that is
 * painted wrongly rather than laid out wrongly.  The exact boundary — what
 * is caught, what is not, and why — is written out above
 * `footerVisibilityFailures`, which is where the decision is made.  Read it
 * before trusting this file with a new class of regression.
 *
 * Consumers:
 *   - `tests/status-bar/footer-visibility-css-guard.spec.ts` — runs the probe
 *     against the BUILT theme stylesheets in a plain browser page (no
 *     Electron, no recorder, seconds not minutes).
 *   - `tests/status-bar/status-bar-footer-contract.spec.ts` — runs the same
 *     probe against the real Electron app, and re-injects every spelling in
 *     `BLANKET_HIDE_SPELLINGS` as a negative control.
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

/**
 * Ways of writing "hide the footer's own content" that the guard must catch.
 *
 * The first entry is the rule that actually shipped, twice, kept verbatim so
 * the historical case stays covered.  The rest are spellings nobody has
 * written yet: they exist to prove the guard checks the *effect*.  A guard
 * that only rejects entry #1 would have caught `b27da3947` and `51a3e820e`
 * and still waved through any of #2-#6.
 *
 * Add to this list rather than rewriting it — each entry is a shape the
 * guard is known to survive.
 */
export const BLANKET_HIDE_SPELLINGS: readonly {
  readonly name: string;
  readonly css: string;
}[] = [
  {
    name: "the rule that shipped twice (b27da3947, 51a3e820e)",
    css: "#status #status-base > *:not(#auto-hide-bottom-strip) { display: none !important; }",
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
] as const;

/** What one region looks like to the user, measured in the live page. */
export interface RegionProbe {
  readonly selector: string;
  readonly found: boolean;
  readonly width: number;
  readonly height: number;
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

    return wanted.map((selector) => {
      const el = document.querySelector(selector) as HTMLElement | null;
      if (el === null) {
        return {
          selector,
          found: false,
          width: 0,
          height: 0,
          display: "",
          visibility: "",
          effectiveOpacity: 0,
          hiddenBy: null,
        };
      }
      const rect = el.getBoundingClientRect();
      const own = getComputedStyle(el);
      let effectiveOpacity = 1;
      let hiddenBy: string | null = null;
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
        if (node === document.body) break;
      }
      return {
        selector,
        found: true,
        width: rect.width,
        height: rect.height,
        display: own.display,
        visibility: own.visibility,
        effectiveOpacity,
        hiddenBy,
      };
    });
  }, selectors as string[]);
}

/**
 * Turn probes into human-readable failures — empty means the contract holds.
 *
 * "Visible" here is the same property `readyOnEntryTest` waits for (a real
 * box, not merely an attached node), widened to also reject `visibility` and
 * `opacity` tricks that leave a box behind.  Returning strings rather than
 * asserting keeps the negative controls able to assert that the check *does*
 * fail without wrapping an expectation in a try/catch.
 *
 * WHAT THIS PREDICATE DOES **NOT** CATCH.  Stated explicitly because the
 * value of a guard is knowing its edge, and because the first draft of this
 * file claimed to catch "any spelling of a blanket hide", which is not true.
 * Measured against the built theme, region by region:
 *
 *   CAUGHT   `display: none` however the selector is written (`:not()`,
 *            `:where()`, `:has()`, an enumerated list, an attribute
 *            selector, wrapped in `@media`); `visibility: hidden/collapse`;
 *            `opacity: 0`; `transform: scale(0)` and `scale: 0`;
 *            `content-visibility: hidden`; `font-size: 0`; `width: 0` /
 *            `max-height: 0` with `overflow: hidden`; `text-indent`;
 *            flex collapse — and all of the above applied to an ANCESTOR
 *            rather than to the region itself.
 *
 *   MISSED   Anything that leaves a full-size box in place:
 *              * off-screen placement — `position: absolute; left: -9999px`,
 *                `transform: translateX(-9999px)`, legacy `clip: rect(0,0,0,0)`
 *              * `clip-path: inset(100%)`
 *              * `filter: opacity(0)` and `filter: blur(40px)` — note this is
 *                a hair from `opacity: 0`, which IS caught
 *              * near-zero but non-zero opacity (`0.001`)
 *              * colour-only invisibility (`color: transparent`, or a colour
 *                equal to the background)
 *              * occlusion by an overlay painted on top
 *
 * The misses share one shape: the geometry is intact and only the *painting*
 * is wrong, which `getBoundingClientRect` plus the computed-style chain
 * cannot see.  `readyOnEntryTest` misses every one of them too — Playwright's
 * visibility predicate reports an off-screen `.location-path` as "visible,
 * enabled and stable" — so nothing in the suite currently guards that family.
 * Closing it needs a different instrument (a screenshot of the footer strip,
 * or an `elementsFromPoint` hit test), not another rule in this list.
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
