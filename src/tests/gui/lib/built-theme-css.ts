/**
 * built-theme-css.ts — typed binding over `built-theme-css.cjs`.
 *
 * THE IMPLEMENTATION IS NOT HERE, and that is deliberate. It is in the sibling
 * `.cjs`, and this file is a types-only surface over it.
 *
 * WHY, when a `.ts` would be the obvious place: the rule for this whole sweep
 * is that no fix lands without a gate PROVED ABLE TO FAIL on the current tree.
 * The gate for this one lives in `ci/test/stale-artefact-guards-test.sh`, which
 * builds a throwaway tree, backdates a built stylesheet behind a `.styl`, and
 * asserts the resolver refuses it. That gate has to be able to CALL the
 * resolver.
 *
 * It cannot call a `.ts`. There is no `tsc` in the repository's node_modules,
 * `src/tests/gui/tsconfig.json` sets `"module": "CommonJS"` and explicitly
 * `"exclude"`s `**/*.mjs`, and the suite's own lane has no npm install — the
 * specs' TypeScript is transpiled by Playwright at run time and by nothing else.
 * A resolver written only as TypeScript would therefore be a fix whose guard
 * could never be watched going red, which is the one thing this campaign does
 * not accept. `ci/test/stale-artefact-guards-test.sh` puts it plainly: "a guard
 * that has never been seen to go red is indistinguishable from a guard that
 * cannot".
 *
 * So the logic is plain CommonJS that `node` runs with no toolchain at all, and
 * the specs get types from here. One implementation, two callers — not two
 * copies. `tsconfig.json`'s `include` lists only `**/*.ts`, so the `.cjs` is
 * never type-checked and never double-compiled.
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const impl = require("./built-theme-css.cjs") as {
  candidateStyleDirs(repoRoot: string): string[];
  resolveBuiltThemeCss(repoRoot: string, theme: string): string;
};

/** Where a compiled theme can legitimately be, in preference order. */
export const candidateStyleDirs: (repoRoot: string) => string[] =
  impl.candidateStyleDirs;

/**
 * Resolve a built theme stylesheet, or throw saying why.
 *
 * Picks the NEWEST candidate rather than the first that exists, then refuses it
 * if any `.styl` under `src/frontend/styles` is newer — see the `.cjs` for the
 * full argument.
 */
export const resolveBuiltThemeCss: (repoRoot: string, theme: string) => string =
  impl.resolveBuiltThemeCss;
