/**
 * Helpers for ensuring the bundled default layout is used during tests.
 *
 * Some tests rely on specific tabs (BUILD, PROBLEMS, SEARCH RESULTS) being
 * present in the layout.  If the user has a saved custom layout that removed
 * these tabs, the tests would fail.  These helpers backup the user layout,
 * replace it with the bundled default from the source tree, and restore the
 * original on teardown.
 */

import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

function currentLayoutPaths(): { userLayoutDir: string; userLayoutPath: string; backupPath: string } {
  const userLayoutDir = path.join(
    process.env.XDG_CONFIG_HOME ?? path.join(os.homedir(), ".config"),
    "codetracer",
  );
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

export function ensureDefaultConfig(codetracerInstallDir: string): void {
  const { userLayoutDir } = currentLayoutPaths();
  const bundled = bundledDefaultConfigPath(codetracerInstallDir);
  if (!fs.existsSync(bundled)) {
    throw new Error(`Bundled default config not found at ${bundled}`);
  }
  if (!fs.existsSync(userLayoutDir)) {
    fs.mkdirSync(userLayoutDir, { recursive: true });
  }
  fs.copyFileSync(bundled, path.join(userLayoutDir, ".config.yaml"));
}

/**
 * Backup the user's layout and replace it with the bundled default.
 * Call this from `test.beforeAll()`.
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
