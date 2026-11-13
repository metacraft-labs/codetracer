/**
 * Every synchronous child process the GUI suite starts ends before its test
 * does.
 *
 * `spawnSync`, `execSync` and `execFileSync` block the worker's event loop,
 * so a child that never exits holds the test past its own timeout: Playwright
 * cannot fire a timer while the loop is blocked. That happened on 2026-11-13:
 * `dotnet --version` (tests/harness/codetracer-ci-dev-shell.spec.ts)
 * deadlocked at start-up, ignored SIGTERM, and held two full-suite runs for
 * 1.5 hours each, one test from their end (codetracer-pm issues/2026-11-13-
 * dotnet-deadlocks-at-start-up-under-an-ld-preload-shim-with-lttng-ust.md).
 *
 * `installSyncChildTimeouts()` (called from playwright.config.ts, which
 * Playwright loads in every worker) wraps the three functions once. A call
 * that names its own `timeout` is left exactly as Node documents it. A call
 * that names none is bounded by the time left to the running test less a
 * margin (ten minutes outside a test), and runs under GNU `timeout -s KILL`:
 * that kills the child's whole process group, which matters because Node's
 * own `timeout` kills only the direct child, and a grandchild still holding
 * the output pipes (`nix develop` → `dotnet`, `sh -c` → its command) keeps the
 * call blocked after it. When the bound fires, the call throws a
 * `SyncChildTimeoutError` naming the command, rather than returning a status
 * a caller could read as the command's own failure.
 *
 * Left unwrapped, because they cannot hang or would change meaning: a command
 * that does not resolve to an executable (it fails at once, with Node's own
 * `ENOENT`, which callers test for), and a `spawnSync` / `execFileSync` with
 * `shell` set.
 */
import * as childProcess from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";

const OutsideATestMs = 600_000;
const MarginMs = 5_000;
const FloorMs = 1_000;
const BackstopMs = 3_000;
const Installed = Symbol.for("codetracer.gui.syncChildTimeouts");

type TestInfoLike = { timeout: number; _startWallTime?: number };

/** The time the running test has left, or null outside a test. */
function remainingTestMs(): number | null {
  let info: TestInfoLike | null = null;
  try {
    // Loaded lazily: the config imports this module before any test runs.
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const { test } = require("@playwright/test") as typeof import("@playwright/test");
    info = test.info() as unknown as TestInfoLike;
  } catch {
    return null;
  }
  if (!info || !info.timeout) return null; // 0 is "no timeout"
  // `_startWallTime` is `Date.now()` when the test began (`_startTime` is a
  // monotonic clock with another origin).
  const elapsed = typeof info._startWallTime === "number" ? Date.now() - info._startWallTime : 0;
  return info.timeout - elapsed;
}

/** The bound for a call that named none. */
export function defaultSyncChildTimeoutMs(): number {
  const left = remainingTestMs();
  if (left === null) return OutsideATestMs;
  return Math.max(FloorMs, left - MarginMs);
}

export class SyncChildTimeoutError extends Error {
  constructor(what: string, ms: number) {
    super(
      `\`${what}\` did not finish within ${ms} ms and was killed with its process ` +
        "group (SIGKILL). A synchronous child blocks the test worker's event loop, " +
        "so the test's own timeout cannot fire while it runs; this bound is the " +
        "time left to the test (lib/sync-child-timeout.ts).",
    );
    this.name = "SyncChildTimeoutError";
  }
}

function describe(command: unknown, args?: unknown): string {
  const words = [String(command)];
  if (Array.isArray(args)) words.push(...args.map(String));
  const text = words.join(" ");
  return text.length > 300 ? text.slice(0, 300) + "…" : text;
}

function isExecutableFile(p: string): boolean {
  try {
    fs.accessSync(p, fs.constants.X_OK);
    return fs.statSync(p).isFile();
  } catch {
    return false;
  }
}

/** Where `command` resolves on `pathValue` (relative to `cwd`), or null. */
function resolveExecutable(command: string, pathValue: string | undefined, cwd?: string): string | null {
  if (command.includes("/")) {
    const p = path.resolve(cwd ?? process.cwd(), command);
    return isExecutableFile(p) ? p : null;
  }
  for (const dir of (pathValue ?? "").split(path.delimiter)) {
    if (!dir) continue;
    const p = path.join(dir, command);
    if (isExecutableFile(p)) return p;
  }
  return null;
}

const timeoutBin =
  resolveExecutable("timeout", process.env.PATH) ??
  ["/run/current-system/sw/bin/timeout", "/usr/bin/timeout", "/bin/timeout"].find(isExecutableFile) ??
  null;

type Options = Record<string, unknown> & { timeout?: number; shell?: unknown; env?: NodeJS.ProcessEnv; cwd?: string };

function optionsOf(args: unknown[], at: number): Options {
  const o = args[at];
  return o && typeof o === "object" ? (o as Options) : {};
}

/** The bound and the rewritten call, or null to call through unchanged. */
function boundedCall(
  command: string,
  argv: readonly string[],
  options: Options,
): { bound: number; command: string; argv: string[]; options: Options } | null {
  if (timeoutBin === null || (options.timeout && options.timeout > 0) || options.shell) return null;
  const env = options.env ?? process.env;
  if (resolveExecutable(command, env.PATH, options.cwd) === null) return null;
  const bound = defaultSyncChildTimeoutMs();
  const seconds = (bound / 1000).toFixed(3);
  return {
    bound,
    command: timeoutBin,
    argv: ["-s", "KILL", seconds, command, ...argv],
    // Node's own bound behind GNU timeout's, in case `timeout` itself sticks.
    options: { ...options, timeout: bound + BackstopMs, killSignal: "SIGKILL" },
  };
}

/** Whether a finished call is the bound firing. */
function fired(started: number, bound: number, status: unknown, signal: unknown, err?: unknown): boolean {
  if ((err as { code?: string } | undefined)?.code === "ETIMEDOUT") return true;
  const killed = status === 137 || status === 124 || signal === "SIGKILL";
  return killed && Date.now() - started >= bound - 250;
}

export function installSyncChildTimeouts(): void {
  // The module itself, not this file's `import *` view of it: the transpiler
  // gives each importer a copy of the exports, taken when it first imports,
  // so only a change to the real exports, made before the specs load (the
  // config loads first in every worker), reaches every spec.
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const cp = require("node:child_process") as Record<string | symbol, unknown>;
  if (cp[Installed]) return;
  cp[Installed] = true;

  const spawnSync = cp.spawnSync as (...a: unknown[]) => childProcess.SpawnSyncReturns<unknown>;
  const execFileSync = cp.execFileSync as (...a: unknown[]) => unknown;

  cp.spawnSync = function (this: unknown, ...args: unknown[]) {
    const argv = Array.isArray(args[1]) ? (args[1] as string[]) : [];
    const options = optionsOf(args, Array.isArray(args[1]) ? 2 : 1);
    const call = boundedCall(String(args[0]), argv, options);
    if (call === null) return spawnSync.apply(this, args);
    const started = Date.now();
    const result = spawnSync.call(this, call.command, call.argv, call.options);
    if (fired(started, call.bound, result.status, result.signal, result.error)) {
      throw new SyncChildTimeoutError(describe(args[0], argv), call.bound);
    }
    return result;
  };

  cp.execFileSync = function (this: unknown, ...args: unknown[]) {
    const argv = Array.isArray(args[1]) ? (args[1] as string[]) : [];
    const options = optionsOf(args, Array.isArray(args[1]) ? 2 : 1);
    const call = boundedCall(String(args[0]), argv, options);
    if (call === null) return execFileSync.apply(this, args);
    const started = Date.now();
    try {
      return execFileSync.call(this, call.command, call.argv, call.options);
    } catch (err) {
      const e = err as { status?: unknown; signal?: unknown };
      if (fired(started, call.bound, e.status, e.signal, err)) {
        throw new SyncChildTimeoutError(describe(args[0], argv), call.bound);
      }
      throw err;
    }
  };

  // `execSync(command, options)` is `execFileSync(<shell>, ["-c", command])`.
  const execSync = cp.execSync as (...a: unknown[]) => unknown;
  cp.execSync = function (this: unknown, ...args: unknown[]) {
    const options = optionsOf(args, 1);
    if (timeoutBin === null || (options.timeout && options.timeout > 0)) return execSync.apply(this, args);
    const shell = typeof options.shell === "string" ? options.shell : "/bin/sh";
    const bound = defaultSyncChildTimeoutMs();
    const rest: Options = { ...options };
    delete rest.shell;
    const started = Date.now();
    try {
      return execFileSync.call(this, timeoutBin, ["-s", "KILL", (bound / 1000).toFixed(3), shell, "-c", String(args[0])], {
        ...rest,
        timeout: bound + BackstopMs,
        killSignal: "SIGKILL",
      });
    } catch (err) {
      const e = err as { status?: unknown; signal?: unknown };
      if (fired(started, bound, e.status, e.signal, err)) {
        throw new SyncChildTimeoutError(String(args[0]), bound);
      }
      throw err;
    }
  };
}
