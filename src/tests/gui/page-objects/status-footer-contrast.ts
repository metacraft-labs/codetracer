/**
 * The status-bar footer's CONTRAST contract, expressed as an effect.
 *
 * *"The colors in the status bar are difficult to read."*  Reported against
 * noirstudio.dev, and true in a way no existing check could see.
 *
 * WHAT WAS ACTUALLY WRONG, measured in the running product with
 * `getComputedStyle` rather than read off the stylesheet.  `body`
 * (`components/legacy.styl`) declares a `background-color` and no `color`;
 * `#status-base` declared a `background-color` and no `color`; nothing in
 * between declares one either; and no `color-scheme` is set anywhere, so the
 * user-agent default `canvastext` resolved to BLACK.  Every readout in the
 * bar that did not name its own colour inherited it:
 *
 *     #status-base            rgb(0, 0, 0) on rgb(27, 27, 27)   1.22:1
 *     .file-info-status-language  ("Noir")                       1.22:1
 *     .file-info-status-encoding  ("UTF-8")                      1.22:1
 *     #location-status / .location-path                          1.22:1
 *     .build-identity         the same, times `opacity: 0.6`     1.14:1
 *
 * against a 4.5:1 requirement.  The complaint was not a badly chosen colour;
 * it was a colour that had never been chosen at all.
 *
 * WHY NOBODY HAD SEEN IT.  `00fd68b7f` parked these same readouts at
 * `left: -9999px` from 2026-08-18 until `74879f32c` restored them.  They had
 * always been painted black-on-near-black; for those weeks they were painted
 * black-on-near-black OFF SCREEN, so the defect could not be reported and no
 * check was looking.
 *
 * WHY A NEW PREDICATE RATHER THAN A STRONGER `footerVisibilityFailures`.
 * `status-footer-contract.ts` asks a GEOMETRY question — has this region a
 * box, and is the box where the user is looking — and it publishes, as
 * executable data in `SURVIVING_HIDE_SPELLINGS`, the fact that it cannot see
 * anything that keeps a correct box and paints it wrongly.  Two of its
 * entries are literally this defect: `color: transparent`, and text drawn in
 * the background colour, whose recorded `why` is *"requires comparing two
 * computed colours against a contrast threshold, not a box"*.  That is this
 * file.  Folding contrast into the geometry predicate would have turned
 * `verify_the_blind_spot_is_where_the_guard_says_it_is` red for the wrong
 * reason and muddled two questions that fail differently; instead the two
 * entries now carry `caughtBy: "contrast"`, and
 * `footer-contrast-guard.spec.ts` asserts that claim by running them, so the
 * cross-reference is measured rather than asserted in prose.
 *
 * WHAT IT REFUSES TO DO.  It does not look for a declaration, a token name or
 * a hex literal.  A guard that recognises `#000000` would wave through
 * `#050505`, and one that requires a particular token would fail the day the
 * palette is retuned.  It asks the browser what colour each region is
 * ACTUALLY painted, what colour is ACTUALLY behind it, and whether the ratio
 * between them clears the threshold for that kind of content.
 */
import type { Page } from "@playwright/test";

/**
 * WCAG 2.1 thresholds, as this repo applies them.
 *
 * 1.4.3 Contrast (Minimum) puts normal text at 4.5:1 and "large" text — 24px,
 * or 18.66px when bold — at 3:1.  1.4.11 Non-text Contrast puts user
 * interface components and meaningful graphics at 3:1.
 *
 * Every readout in this bar is normal text at 0.75rem-1rem, so in practice
 * `text` means 4.5:1 throughout; `large` is computed per element from the
 * resolved font rather than assumed, so a future restyle that legitimately
 * enlarges a readout relaxes on its own.
 */
export const TEXT_MIN = 4.5;
export const LARGE_TEXT_MIN = 3;
export const NON_TEXT_MIN = 3;

/** What kind of thing a region is, which is what picks its threshold. */
export type PaintKind =
  /** Reads as prose: 4.5:1, or 3:1 if the resolved font is "large". */
  | "text"
  /** A control or meaningful graphic painted with `color`: 3:1 (1.4.11). */
  | "icon"
  /** Painted by a border rather than by `color` — e.g. a 1px rule. */
  | "divider";

/** Which CSS property actually puts colour on the screen for this region. */
export type PaintProperty = "color" | "border-left-color" | "border-top-color";

export interface ContrastRegion {
  readonly selector: string;
  readonly kind: PaintKind;
  /**
   * The property that paints it.  Carried rather than assumed because getting
   * this wrong produces a confident, wrong number: `.separate-bar` is a
   * zero-width box painted entirely by `border-left`, and reading `color` off
   * it reports whatever it happens to inherit — which during this work first
   * read 1.22:1 and then 5.47:1, neither of which is the colour of the line
   * the user sees (1.51:1, and unchanged by any of it).
   */
  readonly paintedBy: PaintProperty;
  /** What the user loses if this is unreadable, in one line. */
  readonly why: string;
}

/**
 * Every region in the bar that paints with CSS, with what paints it.
 *
 * Derived from `isonim_status_view.nim`'s `renderStatusShellImpl` and the two
 * views it hosts, not from the stylesheet — the point is to cover what the
 * app renders, including the parts that name no colour of their own, which is
 * exactly the set the defect lived in.
 */
export const BAR_CONTRAST_REGIONS: readonly ContrastRegion[] = [
  {
    selector: "#status-base .file-info-status-language",
    kind: "text",
    paintedBy: "color",
    why: "the language readout Auto-Hide-Panes §3.1 names explicitly",
  },
  {
    selector: "#status-base .file-info-status-encoding",
    kind: "text",
    paintedBy: "color",
    why: "the encoding readout §3.1 names explicitly",
  },
  {
    selector: "#status-base #stable-status",
    kind: "text",
    paintedBy: "color",
    why: "the `stable: ready` process state the screen brief requires",
  },
  {
    selector: "#status-base .auto-hide-strip-tab.active .auto-hide-strip-tab-label",
    kind: "text",
    paintedBy: "color",
    why: "the name of the panel currently open below the bar",
  },
  {
    selector:
      "#status-base .auto-hide-strip-tab:not(.active) .auto-hide-strip-tab-label",
    kind: "text",
    paintedBy: "color",
    why: "the names of the panels the bar offers to open — every one is clickable",
  },
  {
    selector: "#status-base .build-identity",
    kind: "text",
    paintedBy: "color",
    why:
      "the only way a user of a served build can tell which revision the " +
      "page is; it is also the element the report's own screenshot shows " +
      "faded to 1.14:1",
  },
  {
    selector: "#status-base .disconnected-status",
    kind: "text",
    paintedBy: "color",
    why: "the badge saying the debugger connection has dropped",
  },
  {
    selector: "#status-base .location-path",
    kind: "text",
    paintedBy: "color",
    why:
      "the ONLY display of the current debug location anywhere in the UI — " +
      "nothing else renders `StatusBaseModel.locationText`",
  },
  {
    selector: "#status-base #auto-hide-collapsed-icon-zone .collapsed-icon",
    kind: "icon",
    paintedBy: "color",
    why:
      "Auto-Hide-Panes §10.3's collapsed-panel affordance; it is a text " +
      "glyph (`text icon.icon`), so it is held to the text threshold too",
  },
];

/**
 * Regions deliberately NOT required to clear a threshold, and why.
 *
 * Recorded as data rather than omitted, because a selector missing from the
 * list above is indistinguishable from one nobody thought about.  Each entry
 * is a decision someone made, with the number it was made against.
 */
export const EXEMPT_REGIONS: readonly (ContrastRegion & {
  readonly measured: string;
  readonly exemptBecause: string;
})[] = [
  {
    selector: "#status-base #file-info-status .separate-bar",
    kind: "divider",
    paintedBy: "border-left-color",
    why: "the hairline between the language, encoding and state readouts",
    measured: "1.51:1 — `colors-ui-border-secondary`, grey-600 #3a3a3a, on #1b1b1b",
    exemptBecause:
      "WCAG 1.4.11 applies to graphics REQUIRED to understand the content, " +
      "and exempts purely decorative ones.  This rule carries no information " +
      "the layout does not already carry: the three readouts either side of " +
      "it are separated by 0.6em of `gap` regardless, and removing the line " +
      "entirely would lose nothing but polish.  It is also using the design " +
      "system's own subtle-divider token for exactly the role that token " +
      "names, so raising it would mean overriding the palette's answer to " +
      "'how loud is a divider' for one bar — which is the overshoot this " +
      "work was explicitly asked not to commit.  Recorded, not fixed.",
  },
];

/**
 * Icons painted by an SVG asset rather than by CSS, which this predicate
 * cannot reach — the colour is inside the file, and `getComputedStyle` on the
 * element reports whatever `color` it happens to inherit, which paints
 * nothing.  Measuring `color` here is not a weak check, it is a wrong one: it
 * reported a comfortable 8.31:1 for an element whose visible ink is a stroke
 * in an SVG that the property has no relationship to.
 *
 * So the asset is checked instead: the spec asserts the file still paints in
 * the colour recorded here, and that colour's ratio against the bar is
 * computed like any other.  If someone re-draws the icon, the assertion fails
 * and the number gets re-derived rather than silently going stale.
 */
export const IMAGE_PAINTED_ICONS: readonly {
  readonly selector: string;
  readonly asset: string;
  readonly ink: string;
  readonly why: string;
}[] = [
  {
    selector: "#status-base #copy-path-image",
    asset: "src/public/resources/menu/copy_file_path_dark.svg",
    ink: "#ABABAB",
    why:
      "the only copy affordance for the debug location; painted by " +
      "`background-image`, with both paths stroked in this colour",
  },
];

/**
 * Selectors in `status_bar.styl` with poor contrast that are NOT fixed,
 * because nothing renders them.
 *
 * This list exists because the obvious reading of a contrast audit is "these
 * are the worst numbers, raise them", and for these two that would spend a
 * design token on a rule the application cannot produce — and would leave
 * behind a healthy-looking number that reads, to the next auditor, as
 * evidence the control is live.
 *
 * `renderedNowhere` is checked against the frontend SOURCES on every run, not
 * against the compiled `ui.js`: Nim's JS backend emits some string literals as
 * char-code arrays, so grepping the bundle answers a question about the
 * compiler, not about the app.
 */
export const UNREACHABLE_SELECTORS: readonly {
  readonly identifier: string;
  readonly measured: string;
  readonly evidence: string;
}[] = [
  {
    identifier: "whitespace-set",
    measured: "1.51:1 — `colors-ui-border-secondary`, grey-600 #3a3a3a, on #1b1b1b",
    evidence:
      "the markup was the Karax proc `editorWhitespaceOption`, removed in " +
      "`df4d3ef2f`, and it was already dead before that commit — in " +
      "`df4d3ef2f^` the proc occurs exactly once, at its own definition, " +
      "with no call site.  `.whitespace-change`, `.whitespace-label` and " +
      "`#file-info-status-editor-whitespace` are dead in the same way.",
  },
  {
    identifier: "status-button-clicked",
    measured:
      "2.35:1 — `colors-ui-border-primary`, grey-450 #565656, a BORDER token " +
      "used as a text colour, on #1b1b1b",
    evidence:
      "no `.nim`, `.ts`, `.js` or `.html` file in the tree emits " +
      "`status-button-clicked`, `status-button` or `status-buttons`; the " +
      "block that produced them is commented out in the pre-IsoNim history " +
      "and was dropped by `df4d3ef2f`.",
  },
];

/** What one region is actually painted, measured in the live page. */
export interface ContrastProbe {
  readonly selector: string;
  readonly kind: PaintKind;
  readonly found: boolean;
  /** The painting property's computed value, as `rgb()`/`rgba()`. */
  readonly ink: string;
  /** The nearest non-transparent background behind it, and which element. */
  readonly background: string;
  readonly backgroundFrom: string | null;
  /** Product of `opacity` from the region up to `<body>`. */
  readonly effectiveOpacity: number;
  readonly fontSizePx: number;
  readonly fontWeight: number;
  /** `ink` composited over `background` through alpha and opacity. */
  readonly composited: string;
  readonly ratio: number;
  readonly threshold: number;
}

/**
 * Measure every requested region in whatever page `page` currently holds.
 *
 * Works against the real Electron renderer and against a plain browser page
 * carrying the built stylesheet, exactly like `probeFooterRegions`.
 *
 * IT WAITS FOR THE PAINT TO SETTLE, which is not a nicety.
 * `.auto-hide-strip-tab` declares `transition: color 150ms ease`, and
 * attaching a stylesheet transitions the label from the user-agent default.
 * Reading one animation frame later measured the active tab label at
 * `#181818` / 1.20:1 — a colour it holds for a tenth of a second and that no
 * user ever sees — which would have been reported as a defect and "fixed".
 */
export async function probeBarContrast(
  page: Page,
  regions: readonly ContrastRegion[] = BAR_CONTRAST_REGIONS,
): Promise<ContrastProbe[]> {
  // Longer than the 150ms transition, plus a frame to settle.
  await page.waitForTimeout(400);
  await page.evaluate(
    () => new Promise<void>((r) => requestAnimationFrame(() => r())),
  );
  return page.evaluate(
    ([wanted, mins]: [
      { selector: string; kind: string; paintedBy: string }[],
      { text: number; large: number; nonText: number },
    ]) => {
      const parse = (value: string) => {
        const m = /rgba?\(([^)]+)\)/.exec(value);
        if (!m) return null;
        const p = m[1].split(/[,\s/]+/).filter(Boolean).map(Number);
        return { r: p[0], g: p[1], b: p[2], a: p.length > 3 ? p[3] : 1 };
      };
      const lin = (c: number) => {
        const s = c / 255;
        return s <= 0.03928 ? s / 12.92 : Math.pow((s + 0.055) / 1.055, 2.4);
      };
      const lum = (c: { r: number; g: number; b: number }) =>
        0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b);

      return wanted.map((region) => {
        const el = document.querySelector(region.selector) as HTMLElement | null;
        const empty = {
          selector: region.selector,
          kind: region.kind as never,
          found: false,
          ink: "",
          background: "",
          backgroundFrom: null,
          effectiveOpacity: 0,
          fontSizePx: 0,
          fontWeight: 0,
          composited: "",
          ratio: 0,
          threshold: 0,
        };
        if (el === null) return empty;

        const own = getComputedStyle(el);
        const ink = own.getPropertyValue(region.paintedBy);

        // The nearest ancestor (or the element itself) that actually paints a
        // background.  A transparent background is not a background: it is a
        // window onto whatever is behind, which is what the ratio must be
        // taken against.
        let background = "rgb(255, 255, 255)";
        let backgroundFrom: string | null = null;
        for (let n: HTMLElement | null = el; n !== null; n = n.parentElement) {
          const c = getComputedStyle(n).backgroundColor;
          const p = parse(c);
          if (p !== null && p.a > 0) {
            background = c;
            backgroundFrom =
              n.tagName.toLowerCase() + (n.id.length > 0 ? "#" + n.id : "");
            break;
          }
        }

        let effectiveOpacity = 1;
        for (let n: HTMLElement | null = el; n !== null; n = n.parentElement) {
          const o = Number.parseFloat(getComputedStyle(n).opacity);
          if (!Number.isNaN(o)) effectiveOpacity *= o;
          if (n === document.body) break;
        }

        const fg = parse(ink);
        const bg = parse(background);
        if (fg === null || bg === null) return { ...empty, found: true, ink };

        // Fold BOTH the colour's own alpha and the inherited `opacity` chain
        // into one composited colour.  `.build-identity` was `opacity: 0.6`,
        // and a ratio computed from the declared colour alone would have
        // called it legible while the user saw 1.14:1.
        const a = fg.a * effectiveOpacity;
        const composited = {
          r: fg.r * a + bg.r * (1 - a),
          g: fg.g * a + bg.g * (1 - a),
          b: fg.b * a + bg.b * (1 - a),
        };
        const lf = lum(composited);
        const lb = lum(bg);
        const ratio =
          (Math.max(lf, lb) + 0.05) / (Math.min(lf, lb) + 0.05);

        const fontSizePx = Number.parseFloat(own.fontSize);
        const fontWeight = Number.parseInt(own.fontWeight, 10) || 400;
        const large =
          fontSizePx >= 24 || (fontWeight >= 700 && fontSizePx >= 18.66);
        const threshold =
          region.kind === "text"
            ? large
              ? mins.large
              : mins.text
            : mins.nonText;

        const show = (c: { r: number; g: number; b: number }) =>
          "#" +
          [c.r, c.g, c.b]
            .map((v) => Math.round(v).toString(16).padStart(2, "0"))
            .join("");

        return {
          selector: region.selector,
          kind: region.kind as never,
          found: true,
          ink,
          background,
          backgroundFrom,
          effectiveOpacity,
          fontSizePx,
          fontWeight,
          composited: show(composited),
          ratio: Math.round(ratio * 100) / 100,
          threshold,
        };
      });
    },
    [
      regions.map((r) => ({
        selector: r.selector,
        kind: r.kind,
        paintedBy: r.paintedBy,
      })),
      { text: TEXT_MIN, large: LARGE_TEXT_MIN, nonText: NON_TEXT_MIN },
    ] as [
      { selector: string; kind: string; paintedBy: string }[],
      { text: number; large: number; nonText: number },
    ],
  );
}

/**
 * Turn probes into human-readable failures — empty means the contract holds.
 *
 * Each failure carries the two colours and the ratio, because "the status bar
 * has a contrast problem" sends the reader back to the stylesheet to work out
 * which of thirty declarations is meant, and "#919191 on #1b1b1b is 4.1:1,
 * needs 4.5:1" does not.
 *
 * WHERE THIS PREDICATE STOPS, stated because the guard beside it learned the
 * hard way that an undocumented edge is worse than a documented one:
 *
 *   - Colour painted by an ASSET rather than by CSS is invisible to it —
 *     `background-image` icons, `mask-image`, inline SVG fills.  Those are in
 *     `IMAGE_PAINTED_ICONS`, checked against the asset instead.
 *   - It compares a region against the nearest OPAQUE background in its
 *     ancestry.  Text over a gradient, an image, or a translucent overlay
 *     painted by a sibling gets a number that is right about the ancestry and
 *     wrong about the pixels.  Nothing in this bar does that today.
 *   - It is a ratio, not a legibility judgement.  Font weight below 400, a
 *     `text-shadow` that smears the glyph, and `filter: blur()` all leave the
 *     ratio untouched.
 *
 * Closing any of those needs pixel sampling, not another rule here.
 */
export function contrastFailures(probes: readonly ContrastProbe[]): string[] {
  const reasonFor = (selector: string): string =>
    BAR_CONTRAST_REGIONS.find((r) => r.selector === selector)?.why ??
    "a readout the status bar is required to show";

  const failures: string[] = [];
  for (const probe of probes) {
    if (!probe.found) {
      failures.push(
        `${probe.selector}: not present in the page — ` +
          "the markup has drifted from isonim_status_view.nim, and this " +
          `check is measuring nothing.  ${reasonFor(probe.selector)}`,
      );
      continue;
    }
    if (probe.ratio < probe.threshold) {
      const opacityNote =
        probe.effectiveOpacity < 1
          ? `, faded to ${probe.effectiveOpacity} by an \`opacity\` on it or ` +
            "an ancestor"
          : "";
      failures.push(
        `${probe.selector}: ${probe.ratio}:1, needs ${probe.threshold}:1 — ` +
          `painted ${probe.composited} on ${probe.background}` +
          (probe.backgroundFrom === null
            ? ""
            : ` (from ${probe.backgroundFrom})`) +
          opacityNote +
          `.  ${reasonFor(probe.selector)}`,
      );
    }
  }
  return failures;
}

/** The measured table, as a block of text a failure message can carry. */
export function formatContrastTable(
  probes: readonly ContrastProbe[],
): string {
  const rows = probes.map((p) =>
    p.found
      ? `${p.selector.padEnd(72)} ${p.composited.padEnd(9)} on ` +
        `${(p.background ?? "").padEnd(20)} ${String(p.ratio).padStart(6)}:1 ` +
        `(needs ${p.threshold}:1) ${p.ratio >= p.threshold ? "ok" : "FAIL"}`
      : `${p.selector.padEnd(72)} NOT FOUND`,
  );
  return rows.join("\n");
}
