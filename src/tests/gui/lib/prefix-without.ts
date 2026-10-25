/**
 * An install prefix that lacks some of its binaries: every other entry of a
 * real prefix, linked in.
 *
 * A spec that needs the product to meet a missing component — a session
 * manager that cannot be started, a replay command that does not exist —
 * launches with this as its `codetracerPrefixOverride`. `ct` derives the
 * paths of its helpers from the prefix (`src/common/paths.nim`:
 * `backendManagerExe`, `dbBackendExe` are `<prefix>/bin/<name>`), so the
 * product looks for them here and does not find the ones left out. Nothing
 * stands in for a component: every file that IS here is the build's own,
 * through a symbolic link, and the launch runs `<prefix>/bin/ct`, which is
 * the build's `ct` (it resolves its own location through the link, so the
 * main process and the renderer it loads are one build).
 *
 * POSIX only: Windows launches Electron directly rather than through `ct`.
 */

import * as fs from "node:fs";
import * as path from "node:path";

import { scratchBase } from "./socket-path-bound";

/**
 * A scratch prefix mirroring `prefix` without `bin/<name>` for each of
 * `missing`. The caller removes it (`fs.rmSync(.., { recursive: true })`
 * removes the links, never what they point at).
 */
export function prefixWithout(prefix: string, missing: readonly string[]): string {
  const bin = path.join(prefix, "bin");
  for (const name of missing) {
    if (!fs.existsSync(path.join(bin, name))) {
      // Leaving out what was never there would test nothing.
      throw new Error(`prefixWithout: ${prefix} has no bin/${name} to leave out`);
    }
  }
  const root = fs.mkdtempSync(path.join(scratchBase(), "ct-prefix-"));
  for (const entry of fs.readdirSync(prefix)) {
    if (entry === "bin") continue;
    fs.symlinkSync(path.join(prefix, entry), path.join(root, entry));
  }
  fs.mkdirSync(path.join(root, "bin"));
  for (const entry of fs.readdirSync(bin)) {
    if (missing.includes(entry)) continue;
    fs.symlinkSync(path.join(bin, entry), path.join(root, "bin", entry));
  }
  return root;
}
