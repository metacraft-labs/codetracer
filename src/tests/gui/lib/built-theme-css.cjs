/**
 * built-theme-css.cjs — resolve a COMPILED theme stylesheet, and refuse one that
 * is older than the `.styl` it was compiled from.
 *
 * WHY THIS EXISTS
 * ---------------
 * Five contrast/layout specs carried the same resolver, copy-pasted:
 *
 *     for (const dir of candidateStyleDirs()) {
 *       const candidate = path.join(dir, theme);
 *       if (fs.existsSync(candidate)) return candidate;
 *     }
 *
 *   src/tests/gui/tests/debug-controls/toolbar-marks-contrast.spec.ts
 *   src/tests/gui/tests/build/build-panel-contrast-guard.spec.ts
 *   src/tests/gui/tests/status-bar/footer-contrast-guard.spec.ts
 *   src/tests/gui/tests/status-bar/footer-visibility-css-guard.spec.ts
 *   src/tests/gui/tests/session-chrome/edit-toolbar-layout.spec.ts
 *
 * These specs exist to catch a colour or a layout regressing in the SHIPPED
 * stylesheet. The stylesheet is the artefact under test — not an input to the
 * test, the subject of it. Resolving it by existence means the measurement is
 * taken from whatever CSS was last compiled, which after an edit to any `.styl`
 * is the previous build. The spec then reports green about a file nobody
 * changed and stays green through the regression it was written to catch.
 *
 * THE CODE ALREADY KNEW. Every one of the five says so in its own words:
 *
 *   - `build-panel-contrast-guard.spec.ts`, in the error message of the very
 *     function that cannot detect it: "run `just build-once` after editing any
 *     `.styl`, or this measures the previous build".
 *   - `toolbar-marks-contrast.spec.ts`, in its header: "a stale stylesheet is
 *     not detectable from here".
 *   - `footer-visibility-css-guard.spec.ts`, in its header: "A missing build
 *     output does fail loudly (see `resolveTheme`); a stale one" — and the
 *     sentence simply stops.
 *
 * That is the whole sweep in miniature: a guard that asks "does this exist?"
 * where it needed to ask "is this of THIS source?", with a message naming the
 * exact condition it cannot see.
 *
 * THE FIX WAS ALREADY IN THE BUILDING, one function below the defect.
 * `toolbar-marks-contrast.spec.ts`'s `resolveComponentsBundle` compares the
 * bundle's mtime against the two `.nim` views it is built from and throws when
 * the sources are newer — "The bundle IS the view under test. A stale one would
 * measure the previous toolbar and report green on a change that never reached
 * a browser." The same author asked the freshness question about the bundle and
 * not about the CSS, in the same file, ten lines apart. So this is that check,
 * extracted and pointed at the stylesheets.
 *
 * WHY EVERY `.styl`, RATHER THAN THE ONE THAT SHARES THE NAME
 * -----------------------------------------------------------
 * `default_dark_theme_electron.styl` is four lines of `@import`; the rules that
 * actually regress live in `components/status_bar.styl`, `components/build.styl`
 * and their siblings. Following the import graph would mean writing a stylus
 * parser and keeping it correct. Taking the newest mtime under
 * `src/frontend/styles/` is coarser — an edit to a stylesheet this theme does
 * not import will also demand a rebuild — and that is the right way to be
 * wrong: it costs a `just build-once` that was not strictly needed, where the
 * other direction costs a green spec over an unmeasured regression.
 *
 * WHY NEWEST RATHER THAN FIRST AMONG THE CANDIDATE DIRECTORIES
 * ------------------------------------------------------------
 * `src/build-debug` and `src/build-debug-repro` are produced by two different
 * build systems and neither removes the other, so both are routinely present
 * and one is routinely old. Ordering them and taking the first is a preference
 * for whichever happens to be staler. Candidates are still passed in preference
 * order, and `>` rather than `>=` keeps the earlier one winning a tie.
 */

const fs = require("fs");
const path = require("path");

/**
 * Where a compiled theme can legitimately be, in preference order.
 *
 * The union of what the five specs looked in before they shared this: an
 * explicit `CODETRACER_BUILD_DIR`, the two in-tree build variants, and the
 * `<prefix>/frontend/styles` layout of a nix-built app, whose `ct` is at
 * `<prefix>/bin/ct`. See
 * `codetracer-specs/Architecture/Build-Outputs-And-Path-Resolution.md`.
 */
function candidateStyleDirs(repoRoot) {
  const dirs = [];
  if (process.env.CODETRACER_BUILD_DIR) {
    dirs.push(path.join(process.env.CODETRACER_BUILD_DIR, "frontend", "styles"));
  }
  dirs.push(path.join(repoRoot, "src", "build-debug", "frontend", "styles"));
  dirs.push(path.join(repoRoot, "src", "build-debug-repro", "frontend", "styles"));
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
 * Nix sets EVERY file it puts in the store to mtime 1970-01-01T00:00:01Z, on
 * purpose: a build output must not vary with when it was built. So for a
 * `result/` artefact the file's own mtime is not "old", it is ABSENT, and
 * comparing it to a source mtime is not a freshness test — it is a test that
 * always says STALE.
 *
 * That is not a hypothetical. On `test-ui-tests (nixos)` the ct binary is
 * `nix build .#codetracer` output, `CODETRACER_E2E_CT_PATH` points at
 * `result/bin/ct`, and the last candidate below therefore resolves to
 * `result/frontend/styles/…`. Run 34026517513, job 101563733984:
 *
 *     the built stylesheet `default_dark_theme_electron.css` is STALE — it is
 *     older than src/frontend/styles/generated/index.styl
 *       stylesheet: …/result/frontend/styles/default_dark_theme_electron.css
 *                   (built 1970-01-01T00:00:01.000Z)
 *       source:     …/src/frontend/styles/generated/index.styl
 *                   (edited 2026-09-06T21:43:24.887Z)
 *
 * 23 failures, all of that shape, all unfixable by any rebuild. And because
 * the "Run TypeScript Playwright UI tests (DB-based only)" step carries no
 * `if:`, a red Stylesheet-guards step SKIPS it — so this one comparison cost
 * the nixos leg the entire Playwright suite. Only the trailing Event Log step,
 * which is `if: always()` and names a single file, ran at all: 2 tests.
 */
const TIMESTAMP_NORMALIZED_MS = 1000;

/**
 * When the artefact at `candidate` was actually produced, or null if that
 * cannot be established.
 *
 * The ordinary answer is its own mtime. For a timestamp-normalized artefact
 * the answer is the mtime of the SYMLINK THROUGH WHICH IT WAS REACHED --
 * `nix build` rewrites `result` on every build, and that symlink lives on the
 * ordinary filesystem and carries a real timestamp. That is the same question
 * the mtime asked ("when was this built"), answered where the build system
 * actually records it.
 *
 * The symlink must be one the artefact was reached THROUGH (its target is a
 * prefix of the artefact's real path) and must not also contain the checkout:
 * on macOS `/var -> /private/var` satisfies the first test for every path on
 * the machine, and its mtime means nothing about any build.
 */
function artefactBuiltAt(candidate, repoRoot) {
  const abs = path.resolve(candidate);
  const direct = fs.statSync(abs).mtimeMs;
  if (direct > TIMESTAMP_NORMALIZED_MS) {
    return { mtimeMs: direct, evidence: null };
  }

  const real = fs.realpathSync(abs);
  let repoRootReal;
  try {
    repoRootReal = fs.realpathSync(path.resolve(repoRoot));
  } catch {
    repoRootReal = path.resolve(repoRoot);
  }

  let dir = abs;
  for (;;) {
    const parent = path.dirname(dir);
    if (parent === dir) return null;
    dir = parent;

    let link;
    try {
      link = fs.lstatSync(dir);
    } catch {
      return null;
    }
    if (!link.isSymbolicLink()) continue;

    let target;
    try {
      target = fs.realpathSync(dir);
    } catch {
      continue;
    }
    // Reached through it?
    if (real !== target && !real.startsWith(target + path.sep)) continue;
    // A build-output symlink sits inside or at the tree, never above it.
    if (repoRootReal === target || repoRootReal.startsWith(target + path.sep)) continue;

    return { mtimeMs: link.mtimeMs, evidence: dir };
  }
}

/** The newest mtime among the stylus sources, and which file carried it. */
function newestStylSource(repoRoot) {
  const root = path.join(repoRoot, "src", "frontend", "styles");
  let newest = null;

  const walk = (dir) => {
    let entries;
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        walk(full);
      } else if (entry.isFile() && entry.name.endsWith(".styl")) {
        const { mtimeMs } = fs.statSync(full);
        if (newest === null || mtimeMs > newest.mtimeMs) {
          newest = { file: full, mtimeMs };
        }
      }
    }
  };

  walk(root);
  return newest;
}

/**
 * Resolve a built theme stylesheet, or throw saying why.
 *
 * Throws — rather than returning null — for the reason `ci/lib/published-asset.sh`
 * gives at length: a resolver that answers "" turns every caller into a
 * potential silent pass. `page.addStyleTag({ path: "" })` does not obviously
 * fail, and a contrast assertion against an unstyled page measures the browser
 * defaults and can pass.
 *
 * @param repoRoot   absolute path to the checkout
 * @param theme      the built file name, e.g. `default_dark_theme_electron.css`
 */
function resolveBuiltThemeCss(repoRoot, theme) {
  const tried = [];
  let best = null;
  const undatable = [];

  for (const dir of candidateStyleDirs(repoRoot)) {
    const candidate = path.join(dir, theme);
    tried.push(candidate);
    if (!fs.existsSync(candidate)) continue;
    const builtAt = artefactBuiltAt(candidate, repoRoot);
    if (builtAt === null) {
      // Present, but there is no honest answer to "when was this built".
      // Recorded rather than dropped: a candidate that silently vanishes here
      // would surface as the misleading "not found" below.
      undatable.push(candidate);
      continue;
    }
    if (best === null || builtAt.mtimeMs > best.mtimeMs) {
      best = { file: candidate, mtimeMs: builtAt.mtimeMs, evidence: builtAt.evidence };
    }
  }

  if (best === null && undatable.length > 0) {
    throw new Error(
      `built theme stylesheet \`${theme}\` cannot be dated, so its freshness ` +
        `cannot be checked and this spec would measure an artefact of unknown ` +
        `provenance.\n` +
        `  found: ${undatable.join("\n         ")}\n` +
        `Its mtime is the timestamp nix normalizes store files to ` +
        `(1970-01-01T00:00:01Z), and it was not reached through a build-output ` +
        `symlink whose own mtime could answer instead. Build with ` +
        `\`nix build .#codetracer\` so \`result\` exists, or point ` +
        `CODETRACER_BUILD_DIR at a tup/reprobuild output.`,
    );
  }

  if (best === null) {
    throw new Error(
      `built theme stylesheet \`${theme}\` not found — run \`just build-once\`. ` +
        `Looked in:\n  ${tried.join("\n  ")}\n` +
        `Or compile it directly with\n` +
        `  node node_modules/stylus/bin/stylus -o src/build-debug/frontend/styles ` +
        `src/frontend/styles/${theme.replace(/\.css$/, ".styl")}`,
    );
  }

  const newestSource = newestStylSource(repoRoot);
  if (newestSource !== null && newestSource.mtimeMs > best.mtimeMs) {
    throw new Error(
      `built theme stylesheet \`${theme}\` is STALE — it is older than ` +
        `${path.relative(repoRoot, newestSource.file)}, so this spec would ` +
        `measure the previous build and report green on a change that never ` +
        `reached a browser.\n` +
        `  stylesheet: ${best.file}\n` +
        `              (built ${new Date(best.mtimeMs).toISOString()}` +
        `${best.evidence ? `, dated from ${best.evidence}` : ""})\n` +
        `  source:     ${newestSource.file}\n` +
        `              (edited ${new Date(newestSource.mtimeMs).toISOString()})\n` +
        `Run \`just build-once\`.`,
    );
  }

  return best.file;
}

module.exports = { candidateStyleDirs, resolveBuiltThemeCss };
