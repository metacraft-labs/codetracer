/**
 * The saved desktop arrangement a GUI test launches over.
 *
 * A launch's arrangement is decided by the files under
 * `$CODETRACER_HOME/config` (`lib/ct-home.ts`): `default_layout.json` (the
 * debug-mode layout), `auto_hide_state.json` (pinned panels) and
 * `default_edit_layout.json` (edit and review mode). Tests in one worker share
 * that directory, so the launch fixture (`lib/fixtures.ts`) resets all three
 * before every launch through the helpers below, unless a spec opts out.
 *
 * WHICH `default_layout.json` A LAUNCH GETS — `prepareUserLayout`:
 *
 *   * by default, NONE. The file is removed, so the index process takes the
 *     product's own first-run path (`index/config.installModeDefault`): it
 *     installs the Debug mode's default derived from the prefix's
 *     `config/default_layout.json` by `index/mode_default_layout.modeDefaultLayout`
 *     — TESTS a tab of the FILES stack, no CONSTRAINTS. That is the
 *     arrangement a user opens a recording with, and the one every CodeTracer
 *     front-end shares, so a spec that says nothing about the layout measures
 *     what the product shows;
 *   * `bundledLayout` — the bundled `src/config/default_layout.json` copied
 *     VERBATIM (`ensureDefaultLayout`). No mode draws that tree (its third
 *     column is a standing TEST RESULTS stack over a CONSTRAINTS stack), so it
 *     is only for a spec whose subject is the tree itself;
 *   * `preserveUserLayout` — whatever an earlier launch of the worker saved,
 *     untouched, for a spec that observes the desktop restoring its own layout.
 *
 * Until 2026-10-22 the bundled copy was the DEFAULT, so every spec that did
 * not opt out launched on that tree (codetracer-pm issue
 * `2026-10-14-gui-test-fixture-defaults-every-launch-to-the-bundled-layout-the-product-calls-nobodys-layout.md`).
 */

import * as fs from "node:fs";
import * as path from "node:path";
import { ctUserConfigDir } from "./ct-home";

function currentLayoutPaths(): { userLayoutDir: string; userLayoutPath: string; backupPath: string } {
  // `$CODETRACER_HOME/config` under the fixtures (lib/ct-home.ts).
  const userLayoutDir = ctUserConfigDir();
  const userLayoutPath = path.join(userLayoutDir, "default_layout.json");
  return {
    userLayoutDir,
    userLayoutPath,
    backupPath: userLayoutPath + backupSuffix,
  };
}

const backupSuffix = ".backup_build_tests";

/**
 * The bundled default layout shipped with the source tree.
 * `codetracerInstallDir` should be the repo root (one level above tsc-ui-tests).
 */
function bundledDefaultLayoutPath(codetracerInstallDir: string): string {
  return path.join(codetracerInstallDir, "src", "config", "default_layout.json");
}

function bundledDefaultConfigPath(codetracerInstallDir: string): string {
  return path.join(codetracerInstallDir, "src", "config", "default_config.yaml");
}

export function ensureDefaultConfig(codetracerInstallDir: string, theme = ""): void {
  const { userLayoutDir } = currentLayoutPaths();
  const bundled = bundledDefaultConfigPath(codetracerInstallDir);
  if (!fs.existsSync(bundled)) {
    throw new Error(`Bundled default config not found at ${bundled}`);
  }
  if (!fs.existsSync(userLayoutDir)) {
    fs.mkdirSync(userLayoutDir, { recursive: true });
  }
  const target = path.join(userLayoutDir, ".config.yaml");
  fs.copyFileSync(bundled, target);
  if (theme.length > 0) {
    // The bundled config names its theme on one top-level `theme:` line; a
    // config without exactly one is a changed schema, and silently launching
    // in the default theme would make a light capture a dark one.
    const text = fs.readFileSync(target, "utf8");
    const line = /^theme:.*$/m;
    if ((text.match(/^theme:.*$/gm) ?? []).length !== 1) {
      throw new Error(`${bundled} does not carry exactly one top-level 'theme:' line`);
    }
    fs.writeFileSync(target, text.replace(line, `theme: "${theme}"`));
  }
}

/**
 * Back up the saved `default_layout.json` and replace it with the bundled
 * `src/config/default_layout.json`, VERBATIM.
 *
 * The desktop then finds a saved layout and loads it as-is, so the product's
 * first-run derivation of the Debug mode's default never runs: the window
 * opens on the raw bundled tree, which no mode draws. The launch fixture calls
 * this only for a spec that sets `bundledLayout` (`prepareUserLayout`); a
 * spec does not call it itself — the fixture's reset runs at launch, after a
 * `beforeAll`, and would undo it.
 */
export function ensureDefaultLayout(codetracerInstallDir: string): void {
  const { userLayoutDir, userLayoutPath, backupPath } = currentLayoutPaths();

  // Backup existing user layout if present and no backup exists yet.
  if (fs.existsSync(userLayoutPath) && !fs.existsSync(backupPath)) {
    fs.copyFileSync(userLayoutPath, backupPath);
  }

  // Copy the bundled default into the user location.
  const bundled = bundledDefaultLayoutPath(codetracerInstallDir);
  if (!fs.existsSync(bundled)) {
    throw new Error(`Bundled default layout not found at ${bundled}`);
  }
  if (!fs.existsSync(userLayoutDir)) {
    fs.mkdirSync(userLayoutDir, { recursive: true });
  }
  fs.copyFileSync(bundled, userLayoutPath);
}

/**
 * PLAT-45: remove the user's saved `default_layout.json` (and its `.broken`
 * sibling) so the next launch takes the product's own first-run path — the
 * index process installs the Debug mode's default derived from
 * `<prefix>/config/default_layout.json` itself.
 */
export function removeUserLayout(): void {
  const { userLayoutPath } = currentLayoutPaths();
  for (const victim of [userLayoutPath, userLayoutPath + ".broken"]) {
    if (fs.existsSync(victim)) {
      fs.unlinkSync(victim);
    }
  }
}

/** The launch fixture's two `default_layout.json` options (`lib/fixtures.ts`). */
export interface UserLayoutOptions {
  /** Install the raw bundled tree instead of taking the first-run path. */
  bundledLayout: boolean;
  /** Leave whatever an earlier launch of the worker saved. */
  preserveUserLayout: boolean;
}

/** What `prepareUserLayout` did to `default_layout.json`. */
export type UserLayoutPreparation = "first-run" | "bundled" | "preserved";

/**
 * Put `default_layout.json` in the state the next launch should find — the
 * launch fixture's decision, as one function so it is testable without
 * Electron (`tests/harness/layout-reset.spec.ts`). See this module's header
 * for the three outcomes; the default (neither option) is the product's own
 * first-run path.
 *
 * Throws when both options are set: one asks for the bundled tree to be
 * written, the other for the saved file to be left alone, and silently
 * honouring either would launch a spec on a layout it did not ask for.
 */
export function prepareUserLayout(
  options: UserLayoutOptions,
  codetracerInstallDir: string,
): UserLayoutPreparation {
  if (options.bundledLayout && options.preserveUserLayout) {
    throw new Error(
      "layout-reset: `bundledLayout` and `preserveUserLayout` contradict each other — " +
        "one installs the bundled tree, the other keeps the saved layout; set at most one",
    );
  }
  if (options.preserveUserLayout) {
    return "preserved";
  }
  if (options.bundledLayout) {
    ensureDefaultLayout(codetracerInstallDir);
    return "bundled";
  }
  removeUserLayout();
  return "first-run";
}

/**
 * Drop the saved auto-hide state so the next launch starts with nothing
 * pinned.
 *
 * The auto-hide state is the second half of the saved arrangement: pinning a
 * panel REMOVES it from the GoldenLayout tree and records it in
 * `auto_hide_state.json` instead.  Resetting `default_layout.json` alone
 * therefore does not give a test a clean slate — it gives it a default layout
 * plus whichever panels an earlier test in the same worker left pinned, which
 * is a state no single test ever set up.  (Concretely: one test pinning FILES
 * to the bottom edge made every later test see five bottom strip tabs instead
 * of the four `layout.nim` registers by default.)
 *
 * Specs that are *about* restoring a persisted pin seed the file deliberately
 * and opt out via the `preserveAutoHideState` fixture option.
 */
export function resetAutoHideState(): void {
  const { userLayoutDir } = currentLayoutPaths();
  const statePath = path.join(userLayoutDir, "auto_hide_state.json");
  if (fs.existsSync(statePath)) {
    fs.unlinkSync(statePath);
  }
}

/**
 * Where the EDIT-mode layout is persisted.
 *
 * `index/window.onSaveConfig` writes here whenever an edit-mode session ends,
 * and — since RV-2 — `index/config.loadReviewLayoutConfig` READS it when
 * `ct review <PATH>` launches. One file, two modes, and edit mode's save-side
 * sanitiser (`editModeHiddenContentIds`) strips `Content.AgentActivity`, which
 * is DeepReview's third pillar. So "what a review actually opens" depends on
 * whether an edit-mode session has ever run — which, until these helpers
 * existed, no E2E test could set up or even observe.
 */
export function editLayoutPath(): string {
  const { userLayoutDir } = currentLayoutPaths();
  return path.join(userLayoutDir, "default_edit_layout.json");
}

/**
 * Drop any saved edit-mode layout so the next launch starts from the
 * bundled default.
 *
 * This is the third piece of the saved arrangement, after `default_layout.json`
 * and `auto_hide_state.json`, and it needs the same treatment for the same
 * reason: `XDG_CONFIG_HOME` is shared by every test in a worker, so an
 * edit-mode spec that runs before a review spec leaves its layout behind and
 * the review silently opens a *different* layout than it does when run alone.
 * That ordering dependence is precisely how a missing AGENT ACTIVITY panel
 * stayed invisible to the suite.
 *
 * Specs that write the file themselves in a fixture-free `beforeEach` (layout
 * recovery, auto-hide pinning) opt out via the `preserveEditLayout` fixture
 * option, because that hook runs BEFORE `ctPage` is instantiated.
 */
export function resetEditLayout(): void {
  const target = editLayoutPath();
  for (const victim of [target, target + ".broken"]) {
    if (fs.existsSync(victim)) {
      fs.unlinkSync(victim);
    }
  }
}

/**
 * Install `sourcePath` as the saved edit-mode layout, so a launch under test
 * reads a layout that a *previous session* would have left behind.
 *
 * The point is to exercise the pre-existing-file case: a review over a layout
 * edit mode has already sanitised is the common case for any real user, and it
 * is not reachable from a fresh `mkdtemp` config directory.
 */
export function seedEditLayout(sourcePath: string): void {
  const { userLayoutDir } = currentLayoutPaths();
  if (!fs.existsSync(sourcePath)) {
    throw new Error(`Seed edit layout not found at ${sourcePath}`);
  }
  if (!fs.existsSync(userLayoutDir)) {
    fs.mkdirSync(userLayoutDir, { recursive: true });
  }
  fs.copyFileSync(sourcePath, editLayoutPath());
}

/**
 * Restore the user's original layout from the backup.
 * Call this from `test.afterAll()`.
 */
export function restoreUserLayout(): void {
  const { userLayoutPath, backupPath } = currentLayoutPaths();

  if (fs.existsSync(backupPath)) {
    fs.copyFileSync(backupPath, userLayoutPath);
    fs.unlinkSync(backupPath);
  }
}
