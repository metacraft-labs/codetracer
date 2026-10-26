/** How the GUI suite enters the codetracer-ci sibling's environment.
 *
 * The observability storage-server specs run `dotnet` in the codetracer-ci
 * checkout beside this one. They used to do it through `direnv exec
 * <codetracer-ci> …`, and direnv refuses any `.envrc` nobody ran
 * `direnv allow` on — which is every fresh CI clone and every new workspace —
 * so those specs failed as a readiness timeout before any harness started
 * (codetracer-pm issues/2026-10-22-observability-e2e-suite-runs-sibling-
 * commands-through-direnv-exec-which-refuses-an-unallowed-envrc.md).
 *
 * Nothing is mocked. The behavioural test runs the real helper's command for
 * the real codetracer-ci checkout, under a fresh `XDG_DATA_HOME`: direnv keeps
 * its allow list there, so an empty one is exactly a fresh clone. A positive
 * control in the same test shows direnv refusing that sibling under the same
 * isolation, so the pass cannot come from an allow-list entry on this host.
 * The refusal tests use real temporary directories and a real `PATH`.
 */
import { test, expect } from "@playwright/test";
import * as childProcess from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

import {
  codetracerCiDevShellCommand,
  SiblingEnvironmentUnavailableError,
} from "../../lib/codetracer-ci-dev-shell";

const guiRoot = path.resolve(__dirname, "../..");
const workspaceRoot = path.resolve(guiRoot, "../../../..");
const codetracerCiDir = path.join(workspaceRoot, "codetracer-ci");

function onPath(executable: string, env: NodeJS.ProcessEnv = process.env): boolean {
  return (env.PATH ?? "")
    .split(path.delimiter)
    .filter(Boolean)
    .some((dir) => {
      try {
        fs.accessSync(path.join(dir, executable), fs.constants.X_OK);
        return true;
      } catch {
        return false;
      }
    });
}

test.describe("codetracer-ci dev shell entry", () => {
  test("enters codetracer-ci without a direnv approval", () => {
    // The first evaluation of codetracer-ci's flake on a host can take minutes.
    test.setTimeout(900_000);
    test.skip(
      !fs.existsSync(codetracerCiDir),
      `the codetracer-ci sibling is not checked out at ${codetracerCiDir}; ` +
        "the up-front refusal for that case is covered below",
    );
    const xdgDataHome = fs.mkdtempSync(path.join(os.tmpdir(), "ct-ci-shell-xdg-"));
    try {
      const env = { ...process.env, XDG_DATA_HOME: xdgDataHome };

      // Positive control: with no allow list, direnv refuses this sibling.
      // Skipped (only the control) when direnv is not installed, since then
      // there is no refusal to demonstrate.
      if (onPath("direnv")) {
        const control = childProcess.spawnSync("direnv", ["exec", codetracerCiDir, "true"], {
          cwd: codetracerCiDir,
          env,
          encoding: "utf-8",
        });
        expect(control.status, "direnv must refuse an unallowed .envrc").not.toBe(0);
        expect(control.stderr).toContain("is blocked");
      } else {
        test.info().annotations.push({
          type: "control-skipped",
          description: "direnv is not on PATH, so its refusal cannot be shown",
        });
      }

      const { command, args } = codetracerCiDevShellCommand(codetracerCiDir, ["dotnet", "--version"], env);
      const result = childProcess.spawnSync(command, args, {
        cwd: codetracerCiDir,
        env,
        encoding: "utf-8",
        maxBuffer: 64 * 1024 * 1024,
      });
      expect(
        result.status,
        `${command} ${args.join(" ")} failed:\n${result.stderr}`,
      ).toBe(0);
      expect(result.stderr).not.toContain("is blocked");
      // The sibling's declared .NET SDK answered. Its shell hook prints a
      // hint line to stdout first, so look for the version on a line of its
      // own rather than at the start of the output.
      expect(result.stdout).toMatch(/^\d+\.\d+\.\d+\s*$/m);
    } finally {
      fs.rmSync(xdgDataHome, { recursive: true, force: true });
    }
  });

  test("refuses up front, naming the sibling, when codetracer-ci is missing", () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), "ct-ci-missing-"));
    try {
      const missing = path.join(root, "codetracer-ci");
      expect(() => codetracerCiDevShellCommand(missing, ["dotnet", "--version"])).toThrow(
        SiblingEnvironmentUnavailableError,
      );
      expect(() => codetracerCiDevShellCommand(missing, ["dotnet", "--version"])).toThrow(
        /codetracer-ci.*not checked out/,
      );

      // A directory without the flake it is entered through is refused too.
      fs.mkdirSync(missing);
      expect(() => codetracerCiDevShellCommand(missing, ["dotnet", "--version"])).toThrow(
        /codetracer-ci.*nix\/flake\.nix/,
      );
    } finally {
      fs.rmSync(root, { recursive: true, force: true });
    }
  });

  test("refuses up front when nix is not on the PATH the command will run with", () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), "ct-ci-no-nix-"));
    try {
      const sibling = path.join(root, "codetracer-ci");
      fs.mkdirSync(path.join(sibling, "nix"), { recursive: true });
      fs.writeFileSync(path.join(sibling, "nix", "flake.nix"), "{ outputs = _: { }; }\n");
      const emptyBin = path.join(root, "bin");
      fs.mkdirSync(emptyBin);
      expect(() =>
        codetracerCiDevShellCommand(sibling, ["dotnet", "--version"], { ...process.env, PATH: emptyBin }),
      ).toThrow(/codetracer-ci.*`nix` is not on PATH/);
    } finally {
      fs.rmSync(root, { recursive: true, force: true });
    }
  });

  test("no GUI spec or library executes direnv against a sibling", () => {
    const offenders: string[] = [];
    const self = path.resolve(__filename);
    // A `direnv` command name as a string literal, or a shell string that
    // starts with `direnv exec`; comments are stripped first, so prose that
    // mentions direnv (e.g. a regeneration recipe in a doc comment) is fine.
    const executesDirenv = /(["'`])direnv\1|["'`]direnv\s+exec\b/;
    const walk = (dir: string): void => {
      for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
        const full = path.join(dir, entry.name);
        if (entry.isDirectory()) {
          if (entry.name !== "node_modules") walk(full);
        } else if (/\.(ts|js|mjs|cjs)$/.test(entry.name) && path.resolve(full) !== self) {
          fs.readFileSync(full, "utf-8")
            .split("\n")
            .forEach((line, index) => {
              const code = line.replace(/\/\/.*$/, "");
              if (/^\s*(\*|\/\*)/.test(code)) return;
              if (executesDirenv.test(code)) {
                offenders.push(`${path.relative(guiRoot, full)}:${index + 1}: ${line.trim()}`);
              }
            });
        }
      }
    };
    walk(path.join(guiRoot, "tests"));
    walk(path.join(guiRoot, "lib"));
    expect(offenders, "enter a sibling through its declared environment, not direnv").toEqual([]);
  });
});
