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

const userLayoutDir = path.join(
  process.env.XDG_CONFIG_HOME ?? path.join(os.homedir(), ".config"),
  "codetracer",
);

const userLayoutPath = path.join(userLayoutDir, "default_layout.json");
const backupSuffix = ".backup_build_tests";
const backupPath = userLayoutPath + backupSuffix;

/**
 * The bundled default layout shipped with the source tree.
 * `codetracerInstallDir` should be the repo root (one level above tsc-ui-tests).
 */
function bundledDefaultLayoutPath(codetracerInstallDir: string): string {
  return path.join(codetracerInstallDir, "src", "config", "default_layout.json");
}

/**
 * Backup the user's layout and replace it with the bundled default.
 * Call this from `test.beforeAll()`.
 */
export function ensureDefaultLayout(codetracerInstallDir: string): void {
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
 * Restore the user's original layout from the backup.
 * Call this from `test.afterAll()`.
 */
export function restoreUserLayout(): void {
  if (fs.existsSync(backupPath)) {
    fs.copyFileSync(backupPath, userLayoutPath);
    fs.unlinkSync(backupPath);
  }
}
