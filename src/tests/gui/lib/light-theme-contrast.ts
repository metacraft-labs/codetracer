/**
 * The light theme's side of the stylesheet contrast guards.
 *
 * The desktop's light theme (`default_white_theme_electron.css`) paints from
 * the design system's LIGHT palette: `default_white_theme.styl` sets
 * `COLOR_MODE = "Light"` and the generated token index then carries every
 * `mapped` token's Light value. Until it did, the light theme painted the
 * footer and the BUILD panel with the dark surfaces and the dark inks, so the
 * contrast guards measured the same pairs twice and said so
 * (`verify_the_light_theme_is_not_a_different_*`).
 *
 * Painting from the Light palette exposes pairs the DESIGN SYSTEM fails on
 * its own Light surfaces — its Light text tiers (success, warning, error,
 * caption, label-subtle) are under 4.5:1 on its Light grounds. PLAT-46's rule
 * applies: "any pair the design system itself fails is filed, not silently
 * adjusted". So the light run carries a COUNTED register of those pairs,
 * filed in {@link DESIGN_SYSTEM_CONTRAST_ISSUE}: the run must fail exactly
 * the registered selectors, each at exactly its registered ratio. A new
 * failing pair reddens it (fix it, or file it and add it here); so does a
 * registered pair that starts passing (a palette fix landed: delete its
 * entry), and so does a registered pair whose ratio moved (its colours
 * changed: re-measure it, and re-file it if it still fails).
 */
import * as fs from "node:fs";
import * as path from "node:path";

/** Where the design system's own failing pairs are filed. */
export const DESIGN_SYSTEM_CONTRAST_ISSUE =
  "codetracer-pm/issues/2026-09-26-design-system-contrast-failures.md";

/** A light-theme pair the design system fails, as measured. */
export interface FiledLightPair {
  /** The probe's selector, exactly as the region list names it. */
  readonly selector: string;
  /** The ratio measured, as the probe rounds it (two decimals). */
  readonly ratio: number;
  /** The token painting the ink, on the token painting the ground, and the ratio measured. */
  readonly measured: string;
}

/**
 * A failure line from `contrastFailures` as `selector @ ratio`. A failure that
 * carries no ratio (a probe that found nothing) keys with ratio `NaN`, which
 * matches no registered pair, so it is always reported as unfiled.
 */
function failureKey(failure: string): string {
  const m = failure.match(/^(.*?): ([0-9.]+):1, needs /);
  if (m) return `${m[1]} @ ${Number(m[2])}`;
  const sep = failure.indexOf(": ");
  return `${sep < 0 ? failure : failure.slice(0, sep)} @ NaN`;
}

/**
 * The failures a light run reports that are NOT filed, and the filed pairs it
 * no longer reports at their registered ratio. Both must be empty.
 */
export function unfiledLightFailures(
  failures: readonly string[],
  filed: readonly FiledLightPair[],
): { unfiled: string[]; nowPassing: string[] } {
  const failing = failures.map(failureKey);
  const pairKey = (p: FiledLightPair): string => `${p.selector} @ ${p.ratio}`;
  const registered = new Set(filed.map(pairKey));
  return {
    unfiled: failures.filter((_f, i) => !registered.has(failing[i])),
    nowPassing: filed
      .filter((p) => !failing.includes(pairKey(p)))
      .map((p) => `${p.selector} (${p.measured})`),
  };
}

/**
 * A `mapped` colour token's resolved hex in one mode, read from the generated
 * `design_tokens.nim` (which `ci/test/design-tokens-fresh.sh` holds to the
 * pinned design system). `ident` is the Nim member, e.g.
 * `dtColorsUiSurfaceBasePanel`.
 */
export function designTokenHex(
  repoRoot: string,
  ident: string,
  mode: "Dark" | "Light",
): string {
  const file = path.join(repoRoot, "src/frontend/styles/generated/design_tokens.nim");
  const text = fs.readFileSync(file, "utf8");
  const m = text.match(new RegExp(`^\\s+${ident}: \\["(#[0-9a-f]{6})", "(#[0-9a-f]{6})"\\]`, "m"));
  if (!m) throw new Error(`${ident} is not a resolved token in ${file}`);
  return mode === "Dark" ? m[1] : m[2];
}

/** `rgb(r, g, b)` (a computed style) as `#rrggbb`. */
export function rgbToHex(css: string): string {
  const m = css.match(/rgba?\(\s*(\d+)[ ,]+(\d+)[ ,]+(\d+)/);
  if (!m) return css;
  return "#" + [m[1], m[2], m[3]].map((v) => Number(v).toString(16).padStart(2, "0")).join("");
}
