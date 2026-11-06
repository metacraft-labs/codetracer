// Is `storybook/storybook-static` a picture of the tree that is on disk now?
//
// EXISTENCE IS NOT FRESHNESS. `tools/visual-review/capture-storybook.mjs` used
// to ask `existsSync(staticDir)` and print "Run without --no-build first" when
// it was not there — a message naming the exact condition the check could not
// detect. `storybook-static` is a build output deleted ONLY by a real
// `just storybook-build` (justfile), and `--no-build` is a documented
// invocation (`storybook/README.md`, `tools/visual-review/reference-coverage.md`),
// so the visual-review corpus could be — and silently was allowed to be —
// photographs of components from several commits ago, reviewed and rated as the
// current design with nothing in the report saying so.
//
// A SEPARATE MODULE, not a function inside the capture script, for one reason:
// the capture script resolves Playwright out of `storybook/node_modules` at
// import time, so nothing that imports it can run without a full storybook
// install. This guard is the part that must be verifiable on a stock runner
// against a synthetic tree, which is what `ci/test/stale-artefact-guards-test.sh`
// does with it.

import { existsSync, readdirSync, statSync } from "node:fs";
import { basename, dirname, join } from "node:path";

// firstNewerThan(paths, referenceMs) -> the first file found newer than the
// reference, or null. Early-exits, so a large tree costs one walk and stops at
// the first piece of evidence; the caller only ever names ONE offending file.
//
// Same shape and the same deliberate conservatism as `ctdr_require_not_stale`
// in `scripts/docs/deep-review-capture-lib.sh` and as the book-page check in
// `scripts/docs/capture-book-page-screenshot.mjs`: an mtime that merely LOOKS
// newer — a `git checkout` rewriting a file with identical bytes — is enough to
// refuse, because the remedy is a rebuild and the alternative is a published
// review of a product that no longer exists.
//
// `isOutput(path, stat)`, when given, names files that are build outputs
// rather than sources, which are passed over.
export function firstNewerThan(paths, referenceMs, isOutput = () => false) {
  const walk = (target) => {
    let stat;
    try {
      stat = statSync(target);
    } catch {
      return null; // a source that is not there cannot be newer than anything
    }
    if (!stat.isDirectory()) {
      if (isOutput(target, stat)) return null;
      return stat.mtimeMs > referenceMs ? target : null;
    }
    for (const entry of readdirSync(target, { withFileTypes: true })) {
      const found = walk(join(target, entry.name));
      if (found) return found;
    }
    return null;
  };
  for (const path of paths) {
    const found = walk(path);
    if (found) return found;
  }
  return null;
}

// isCompiledNimProgram(path, stat) -> true for the program `nim c foo.nim`
// writes beside its source when no `-o` is given: an extensionless
// executable `foo` next to `foo.nim` (git-ignored, e.g.
// src/frontend/tests/agent_harbor_story_data_test). It is an output of a test
// compile, not a source of the components bundle; counted as a source, merely
// compiling a test made the next render check refuse a fresh build as stale.
export function isCompiledNimProgram(path, stat) {
  if (!stat.isFile()) return false;
  // Windows: `foo.exe` (there is no executable bit to read).
  if (/\.exe$/i.test(path)) return existsSync(path.replace(/\.exe$/i, ".nim"));
  const name = path.split(/[\\/]/).pop();
  return (stat.mode & 0o111) !== 0 && !name.includes(".") && existsSync(`${path}.nim`);
}

// The stamp `just build-storybook-components` (scripts/build-storybook-components.sh)
// sets to the START of every successful compile of
// `storybook/dist/components.js`. `nim js` leaves the bundle itself untouched
// when its bytes do not change, so the bundle's own mtime says when it last
// CHANGED and the stamp says when it was last COMPILED:
// the bundle is current with its Nim sources as of the later of the two, and
// the stamp is not a source of `storybook-static` (it is not the bundle).
export const COMPONENTS_STAMP = "components.js.compiled";

// componentsCompiledAt(bundle) -> when the bundle at `bundle` was last
// compiled: the later of its own mtime and its stamp's (0 when absent).
export function componentsCompiledAt(bundle) {
  const at = (path) => {
    try {
      return statSync(path).mtimeMs;
    } catch {
      return 0;
    }
  };
  return Math.max(at(bundle), at(join(dirname(bundle), COMPONENTS_STAMP)));
}

// requireFreshStorybookStatic(repoRoot) — throws unless the storybook corpus is
// current with respect to everything it is made of.
//
// WHAT THE STATIC TREE IS MADE OF is not guessed here: `storybook/.storybook/
// main.ts` declares `staticDirs`, and `storybook build` COPIES each of them into
// `storybook-static/`. So the frontend build tree is physically inside this
// corpus, and a stale `storybook-static` is a photograph of an old renderer as
// much as of an old story file. The list below mirrors that `staticDirs` array
// plus the story/config sources webpack compiles; if `main.ts` grows another
// entry, add it here too.
export function requireFreshStorybookStatic(repoRoot) {
  const storybookDir = join(repoRoot, "storybook");
  const staticDir = join(storybookDir, "storybook-static");
  const built = join(staticDir, "index.html");

  if (!existsSync(built)) {
    throw new Error(
      `Missing ${built}. Run without --no-build first, or: just storybook-build`,
    );
  }
  const builtAt = statSync(built).mtimeMs;

  // `main.ts` picks the repro build tree when it exists, exactly as here.
  const buildDir = existsSync(join(repoRoot, "src/build-debug-repro/frontend"))
    ? "build-debug-repro"
    : "build-debug";

  const sources = [
    join(storybookDir, ".storybook"),
    join(storybookDir, "stories"),
    join(storybookDir, "scripts"),
    join(storybookDir, "package.json"),
    join(storybookDir, "package-lock.json"),
    join(storybookDir, "dist"),
    join(repoRoot, "src/frontend/index.html"),
    join(repoRoot, `src/${buildDir}/frontend`),
    join(repoRoot, `src/${buildDir}/public`),
  ];

  const isStamp = (path) => basename(path) === COMPONENTS_STAMP;
  const newer = firstNewerThan(sources, builtAt, isStamp);
  if (newer) {
    throw new Error(
      `Stale storybook corpus: ${built} is older than its source ${newer}.\n` +
        "These screenshots would be reviewed as the current design while showing an older one.\n" +
        "Rebuild with `just storybook-build` (i.e. run this without --no-build), then run this again.",
    );
  }

  // The components bundle is the other end of the same chain: `storybook-build`
  // depends on `build-storybook-components`, so `--no-build` skips BOTH, and a
  // `dist/components.js` compiled from Nim sources that have since changed is
  // stale even when the static tree faithfully copied it. When it was compiled is
  // `componentsCompiledAt`: `scripts/build-storybook-components.sh` stamps the start
  // of each successful compile beside the bundle. Nim leaves an output whose bytes did
  // not change with its old mtime, so without the stamp a bundle the recipe has just
  // built would be refused.
  const components = join(storybookDir, "dist", "components.js");
  if (existsSync(components)) {
    const componentsAt = componentsCompiledAt(components);
    const newerNim = firstNewerThan([join(repoRoot, "src/frontend")], componentsAt, isCompiledNimProgram);
    if (newerNim) {
      throw new Error(
        `Stale storybook components: ${components} is older than its source ${newerNim}.\n` +
          "Rebuild with `just build-storybook-components`, then run this again.",
      );
    }
  }
}
