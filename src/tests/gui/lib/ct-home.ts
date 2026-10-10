/**
 * Where the CodeTracer under test keeps a user's own state — the GUI suite's
 * spelling of `src/common/ct_home.nim`.
 *
 * `lib/fixtures.ts` gives every Playwright worker a scratch `CODETRACER_HOME`
 * at import time, and every CodeTracer process it launches inherits it, so the
 * app's config (`.config.yaml`, layouts, auto-hide state) is under
 * `$CODETRACER_HOME/config` and its recordings and trace index are under
 * `$CODETRACER_HOME/data` — never the developer's own profile, on any OS.
 * A spec that reads or plants one of those files asks here rather than
 * re-deriving the path from `XDG_*` or the home directory, which
 * `CODETRACER_HOME` outranks.
 */

import * as os from "node:os";
import * as path from "node:path";

function codetracerHome(): string | undefined {
  const raw = process.env.CODETRACER_HOME;
  return raw !== undefined && raw.trim().length > 0 ? path.resolve(raw.trim()) : undefined;
}

/** `$CODETRACER_HOME/config`, else `$XDG_CONFIG_HOME/codetracer`, else `~/.config/codetracer`. */
export function ctUserConfigDir(): string {
  const home = codetracerHome();
  if (home !== undefined) {
    return path.join(home, "config");
  }
  return path.join(process.env.XDG_CONFIG_HOME ?? path.join(os.homedir(), ".config"), "codetracer");
}

/** `$CODETRACER_HOME/data`, else `$XDG_DATA_HOME/codetracer`, else `~/.local/share/codetracer`. */
export function ctUserDataDir(): string {
  const home = codetracerHome();
  if (home !== undefined) {
    return path.join(home, "data");
  }
  return path.join(
    process.env.XDG_DATA_HOME ?? path.join(os.homedir(), ".local", "share"),
    "codetracer",
  );
}

/**
 * Where the NATIVE front-ends (terminal, GPUI) keep their own state:
 * `$CODETRACER_TUI_LAYOUT_DIR`, else `$CODETRACER_HOME/state`, else
 * `$XDG_STATE_HOME/codetracer`, else `~/.local/state/codetracer`
 * (`viewmodel/host/native_state.nativeStateRoot`).
 */
export function ctNativeStateDir(): string {
  const layoutDir = process.env.CODETRACER_TUI_LAYOUT_DIR;
  if (layoutDir !== undefined && layoutDir.length > 0) {
    return layoutDir;
  }
  const home = codetracerHome();
  if (home !== undefined) {
    return path.join(home, "state");
  }
  return path.join(
    process.env.XDG_STATE_HOME ?? path.join(os.homedir(), ".local", "state"),
    "codetracer",
  );
}
