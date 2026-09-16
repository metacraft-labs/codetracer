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

  for (const dir of candidateStyleDirs(repoRoot)) {
    const candidate = path.join(dir, theme);
    tried.push(candidate);
    if (!fs.existsSync(candidate)) continue;
    const { mtimeMs } = fs.statSync(candidate);
    if (best === null || mtimeMs > best.mtimeMs) {
      best = { file: candidate, mtimeMs };
    }
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
        `              (built ${new Date(best.mtimeMs).toISOString()})\n` +
        `  source:     ${newestSource.file}\n` +
        `              (edited ${new Date(newestSource.mtimeMs).toISOString()})\n` +
        `Run \`just build-once\`.`,
    );
  }

  return best.file;
}

module.exports = { candidateStyleDirs, resolveBuiltThemeCss };
