/**
 * Entering the codetracer-ci sibling's development environment.
 *
 * The observability storage-server specs run `dotnet` harnesses that live in
 * the codetracer-ci checkout beside this repository. They need that
 * checkout's declared toolchain (its pinned .NET SDK), not whatever is
 * ambient.
 *
 * They used to get it with `direnv exec <codetracer-ci> …`. direnv refuses
 * any `.envrc` that was never `direnv allow`ed, which is every fresh CI clone
 * and every new workspace, so those specs failed as a readiness timeout
 * before any harness ran (codetracer-pm issues/2026-10-22-observability-e2e-
 * suite-runs-sibling-commands-through-direnv-exec-which-refuses-an-unallowed-
 * envrc.md).
 *
 * Why `nix develop <codetracer-ci>/nix --command …` and not
 * `repro exec <codetracer-ci> -- …`, which the other siblings use: entering
 * codetracer-ci through repro fails in a CodeTracer workspace because its
 * `repro.nim` uses `isonim-platform`, which that workspace does not check out
 * (codetracer-pm issues/2026-10-26-codetracer-ci-dev-env-does-not-compile-
 * in-a-codetracer-workspace-without-isonim-platform.md). codetracer-ci's
 * `.envrc` is exactly `use flake ./nix`, so `nix develop ./nix` is the very
 * environment direnv activated, and it needs no per-checkout approval. When
 * that issue is fixed this can move to `repro exec` like the other siblings.
 *
 * Process semantics: `nix develop --command` execs the command in place of
 * itself (measured 2026-10-26: the spawned pid IS the command's pid), so a
 * caller's existing process-tree stop sees the same tree it saw under
 * `direnv exec`, which also exec'd.
 */
import * as fs from "node:fs";
import * as path from "node:path";

/** A command ready for `child_process.spawn(command, args, …)`. */
export interface SiblingCommand {
  command: string;
  args: string[];
}

/**
 * Raised before anything is spawned when the sibling, the declaration it is
 * entered through, or the tool that enters it is missing. The message names
 * the sibling, so the failure is not mistaken for a harness that never became
 * ready.
 */
export class SiblingEnvironmentUnavailableError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "SiblingEnvironmentUnavailableError";
  }
}

/** The first executable `name` on `pathValue`, or null. */
function findOnPath(name: string, pathValue: string | undefined): string | null {
  for (const dir of (pathValue ?? "").split(path.delimiter)) {
    if (!dir) continue;
    const candidate = path.join(dir, name);
    try {
      fs.accessSync(candidate, fs.constants.X_OK);
      if (fs.statSync(candidate).isFile()) return candidate;
    } catch {
      // Not here; keep looking.
    }
  }
  return null;
}

/**
 * The command that runs `argv` inside codetracer-ci's declared development
 * shell.
 *
 * @param codetracerCiDir the codetracer-ci checkout.
 * @param argv the command to run there, e.g. `["dotnet", "run", …]`.
 * @param env the environment the command will be spawned with; `nix` is
 *   looked up on its `PATH`, which is the one `spawn` will search.
 * @throws SiblingEnvironmentUnavailableError when the checkout, its
 *   `nix/flake.nix` or `nix` itself is missing.
 */
export function codetracerCiDevShellCommand(
  codetracerCiDir: string,
  argv: readonly string[],
  env: NodeJS.ProcessEnv = process.env,
): SiblingCommand {
  const sibling = `${path.basename(codetracerCiDir)} (${codetracerCiDir})`;
  if (argv.length === 0) {
    throw new Error(`no command given to run in ${sibling}`);
  }
  if (!fs.existsSync(codetracerCiDir) || !fs.statSync(codetracerCiDir).isDirectory()) {
    throw new SiblingEnvironmentUnavailableError(
      `the sibling ${sibling} is not checked out; enable it in this workspace ` +
        "(repro ws enable codetracer) before running specs that need it",
    );
  }
  const flakeDir = path.join(codetracerCiDir, "nix");
  if (!fs.existsSync(path.join(flakeDir, "flake.nix"))) {
    throw new SiblingEnvironmentUnavailableError(
      `the sibling ${sibling} has no nix/flake.nix, which declares its development environment`,
    );
  }
  const nix = findOnPath("nix", env.PATH);
  if (nix === null) {
    throw new SiblingEnvironmentUnavailableError(
      `cannot enter the sibling ${sibling}: \`nix\` is not on PATH`,
    );
  }
  return { command: nix, args: ["develop", flakeDir, "--command", ...argv] };
}
