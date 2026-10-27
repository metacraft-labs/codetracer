/**
 * Whether the Noir recorder is available to `ct record`.
 *
 * Specs whose fixture is a Noir program (`test-programs/noir_*`) are recorded
 * by `nargo`, which the dev shell provides but a bare host may not. Those
 * specs skip with a reason when it is absent rather than failing inside
 * `ct record`, the contract the suite follows for recorders it cannot assume.
 */
import * as fs from "node:fs";
import * as path from "node:path";

/** Whether `nargo` — the Noir recorder `ct record` shells out to — is on PATH. */
export function hasNargo(): boolean {
  const pathEntries = (process.env.PATH ?? "").split(path.delimiter);
  const names = process.platform === "win32" ? ["nargo.exe", "nargo"] : ["nargo"];
  return pathEntries.some((dir) =>
    dir.length > 0 && names.some((name) => fs.existsSync(path.join(dir, name))),
  );
}
