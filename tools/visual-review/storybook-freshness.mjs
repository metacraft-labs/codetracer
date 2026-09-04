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
import { join } from "node:path";

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
export function firstNewerThan(paths, referenceMs) {
  const walk = (target) => {
    let stat;
    try {
      stat = statSync(target);
    } catch {
      return null; // a source that is not there cannot be newer than anything
    }
    if (!stat.isDirectory()) {
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

  const newer = firstNewerThan(sources, builtAt);
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
  // stale even when the static tree faithfully copied it.
  const components = join(storybookDir, "dist", "components.js");
  if (existsSync(components)) {
    const componentsAt = statSync(components).mtimeMs;
    const newerNim = firstNewerThan([join(repoRoot, "src/frontend")], componentsAt);
    if (newerNim) {
      throw new Error(
        `Stale storybook components: ${components} is older than its source ${newerNim}.\n` +
          "Rebuild with `just build-storybook-components`, then run this again.",
      );
    }
  }
}
