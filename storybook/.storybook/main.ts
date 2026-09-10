import type { StorybookConfig } from "@storybook/html-webpack5";
import { existsSync } from "node:fs";
import { relative, resolve } from "node:path";

const repoRoot = resolve(__dirname, "../..");

/**
 * Where the built frontend + public trees live, in preference order.
 *
 * THE THIRD ENTRY IS WHY THIS IS A LIST. The two tup roots are what a
 * developer machine and the macOS CI leg produce (`just build-once` ->
 * `src/build-debug-repro`, plain tup -> `src/build-debug`). The NIXOS CI
 * leg produces NEITHER: its "Build CodeTracer (nix)" step runs
 * `nix build .#codetracer` and the artefacts land in `result/`, whose
 * `installPhase` (nix/packages/default.nix) creates exactly the two
 * directories wanted here -- `$out/frontend/styles` and `$out/public`.
 *
 * The previous form asked ONE question -- does `src/build-debug-repro/
 * frontend` exist? -- and fell through to `src/build-debug` without
 * checking it. `src/build-debug/` always exists, because `tup.config` is
 * COMMITTED there, but on the nixos leg `src/build-debug/frontend` does
 * not. Storybook treats a `staticDirs` entry pointing at a missing
 * directory as fatal, so `just storybook-build` died, and because
 * `just test-e2e` routes through `ensure-storybook-static` under `set -e`,
 * `npx playwright test` was never reached at all. A missing static
 * directory therefore cost the nixos leg the ENTIRE Playwright suite,
 * not the four `*storybook*.spec.ts` files that need it.
 */
const BUILD_ROOTS = ["src/build-debug-repro", "src/build-debug", "result"];

function resolveBuildRoot(): string {
  for (const candidate of BUILD_ROOTS) {
    const root = resolve(repoRoot, candidate);
    // BOTH, because both are served below and either one missing is fatal
    // to storybook. Checking only `frontend` is what let the fall-through
    // above select a root that could not satisfy the second entry.
    if (existsSync(resolve(root, "frontend")) && existsSync(resolve(root, "public"))) {
      return root;
    }
  }
  throw new Error(
    `storybook: no built frontend found. Looked for a "frontend" and a `
      + `"public" directory under, in order: `
      + `${BUILD_ROOTS.map((c) => resolve(repoRoot, c)).join(", ")}.\n`
      + `Build CodeTracer first -- "just build-once" (tup/reprobuild) or `
      + `"nix build .#codetracer" (produces ./result).`,
  );
}

const buildRoot = resolveBuildRoot();
// `staticDirs` entries are resolved relative to this config file, so keep
// them relative rather than absolute to stay consistent with the two
// entries above them.
const buildRootRelative = relative(__dirname, buildRoot);

const config: StorybookConfig = {
  stories: ["../stories/**/*.stories.@(js|ts)"],
  addons: ["@storybook/addon-essentials", "@storybook/addon-interactions"],
  framework: {
    name: "@storybook/html-webpack5",
    options: {},
  },
  staticDirs: [
    { from: "../dist", to: "/dist" },
    { from: "../../src/frontend/index.html", to: "/codetracer-app-index.html" },
    { from: `${buildRootRelative}/frontend`, to: "/frontend" },
    { from: `${buildRootRelative}/public`, to: "/public" },
  ],
};

export default config;
