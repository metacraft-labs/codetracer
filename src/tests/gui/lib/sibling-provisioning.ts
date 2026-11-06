/**
 * Provisioning of sibling-repo artifacts for the Playwright fixtures.
 *
 * A recording that drives a recorder from a sibling checkout needs that
 * recorder built. The Rust harnesses build it themselves
 * (`src/db-backend/tests/test_harness/sibling_provisioning.rs`), and this
 * module is the same contract for the Playwright fixtures:
 *
 * - an override the developer named is used as given and never built. The
 *   names are the ones `ct` reads, in its order: `CODETRACER_CT_MCR_CMD`, then
 *   `CODETRACER_CT_MCR_PATH`, then a tool on `PATH` that is not the sibling's
 *   own build output. An empty variable counts as unset;
 * - otherwise the sibling is built or refreshed by
 *   `scripts/build-siblings.sh --only <key>`, which reuses an artifact only
 *   when its build stamp matches the sibling's current inputs;
 * - a sibling that is not checked out, or does not build, FAILS the test with
 *   the remedy. It is never skipped: the prerequisite is supplied, not waived.
 *
 * The work is asynchronous. A cold build of the recorder takes many minutes,
 * and a synchronous wait would block the worker's own test-timeout timer.
 * Playwright runs its workers as separate processes: the in-process memo
 * only spares a repeated call inside one worker, the lock makes the workers
 * take turns, and the build stamp makes every call after the first a stamp
 * check.
 */

import * as childProcess from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";

/** One artifact a sibling checkout provides, and the script key that builds it. */
export interface SiblingBuild {
  /** The `scripts/build-siblings.sh` key whose entry names the artifact. */
  key: string;
  /** The sibling checkout's directory name, beside the codetracer checkout. */
  repo: string;
  /** The artifact's path inside the sibling checkout. */
  artifact: string;
  /** The command that builds it by hand, printed with every failure. */
  remedy: string;
}

/**
 * `ct-mcr` (`ct_cli`): the MCR recorder that `ct record` runs for a compiled
 * `.nim` program. `build-ct-mcr` builds it in place, and the key is the one
 * `build-siblings.sh` gives that entry.
 */
export const CT_MCR_BUILD: SiblingBuild = {
  key: "codetracer-native-recorder/ct-mcr",
  repo: "codetracer-native-recorder",
  artifact: path.join("ct_cli", `ct_cli${process.platform === "win32" ? ".exe" : ""}`),
  remedy: "cd ../codetracer-native-recorder && just build-ct-mcr",
};

/** Builds for this worker process, by key: a settled or in-flight provisioning. */
const provisioned = new Map<string, Promise<string>>();

/** How long to wait between attempts to take the provisioning lock. */
const LOCK_RETRY_MS = 500;

/**
 * How old a break-lock file must be before it is treated as left behind by a
 * crashed breaker. A live breaker holds the break lock for a few syscalls.
 */
const BREAK_LOCK_STALE_MS = 60_000;

/**
 * Whether `ct record` of this recording runs `ct-mcr`.
 *
 * `ct` records a `.nim` program with `ct-mcr` (`src/ct/db_backend_record.nim`,
 * the default `raMcr` path of `src/ct/trace/recorder_dispatch.nim`). A `.nims`
 * script runs in the compiler's own VM and needs no `ct-mcr`, and the rr and
 * ttd backends do not use it.
 */
export function recordingNeedsCtMcr(sourcePath: string, backend?: string): boolean {
  return path.extname(sourcePath) === ".nim" && backend !== "rr" && backend !== "ttd";
}

/**
 * Make the `ct-mcr` that `ct record` will run a usable one, provisioning the
 * sibling when no override names a tool. Rejects, with the remedy, when that
 * cannot be done.
 *
 * Whatever this settles on is exported as `CODETRACER_CT_MCR_CMD`. `ct` reads
 * that name first, so the export holds for every process this worker starts,
 * and an empty `CODETRACER_CT_MCR_CMD` can no longer shadow the value.
 *
 * `codetracerRoot` is the codetracer checkout, whose parent holds the siblings.
 * `onBuildStart` runs only when this worker is about to provision, not when an
 * override or an earlier provisioning already answers, so the caller can give
 * a test the time a cold build needs and no more.
 */
export async function ensureCtMcr(
  codetracerRoot: string,
  onBuildStart: () => void = () => {},
): Promise<void> {
  const siblingDir = path.join(path.dirname(codetracerRoot), CT_MCR_BUILD.repo);
  const named = firstNonEmpty(process.env.CODETRACER_CT_MCR_CMD, process.env.CODETRACER_CT_MCR_PATH);
  if (named !== undefined && !isInside(named.value, siblingDir)) {
    // An explicit override is used as given and never built. A dangling one
    // fails here, naming it, rather than as a spawn error inside `ct record`.
    if (!fs.existsSync(named.value)) {
      throw new Error(
        `${named.name}='${named.value}' does not name a file. Unset it to build the ` +
          `workspace's ${CT_MCR_BUILD.repo}/${CT_MCR_BUILD.artifact}, or point it at a ct-mcr binary.`,
      );
    }
    process.env.CODETRACER_CT_MCR_CMD = named.value;
    return;
  }
  const onPath = findOnPath("ct-mcr") ?? findOnPath("ct_cli");
  if (named === undefined && onPath !== undefined && !isInside(onPath, siblingDir)) {
    process.env.CODETRACER_CT_MCR_CMD = onPath;
    return;
  }
  process.env.CODETRACER_CT_MCR_CMD = await provisionSiblingArtifact(
    codetracerRoot,
    CT_MCR_BUILD,
    onBuildStart,
  );
}

/**
 * Build or refresh one sibling artifact and resolve to its absolute path.
 *
 * Rejects when the sibling checkout is missing, when `build-siblings.sh` fails
 * (its own output, streamed above, names the failing build's log), or when the
 * build reports success without producing the artifact. The script itself
 * reports a missing checkout as MISSING and exits 0, so the checkout and the
 * artifact are checked here as well.
 */
export function provisionSiblingArtifact(
  codetracerRoot: string,
  build: SiblingBuild,
  onBuildStart: () => void = () => {},
): Promise<string> {
  const existing = provisioned.get(build.key);
  if (existing !== undefined) {
    return existing;
  }
  const attempt = runProvisioning(codetracerRoot, build, onBuildStart);
  provisioned.set(build.key, attempt);
  // A failed attempt is not memoised: a later test in this worker tries again
  // and reports its own failure with the remedy.
  attempt.catch(() => provisioned.delete(build.key));
  return attempt;
}

async function runProvisioning(
  codetracerRoot: string,
  build: SiblingBuild,
  onBuildStart: () => void,
): Promise<string> {
  const repoDir = path.join(path.dirname(codetracerRoot), build.repo);
  if (!isDirectory(repoDir)) {
    throw new Error(
      `MISSING PREREQUISITE: the \`${build.repo}\` sibling repository is not checked out at ` +
        `${repoDir}, so \`${build.artifact}\` cannot be built for this test. Check it out ` +
        "(`repro ws enable codetracer` checks out every repository the codetracer project " +
        "includes), or point this test at a build through the override it documents.",
    );
  }
  const script = path.join(codetracerRoot, "scripts", "build-siblings.sh");
  // Before the lock: a worker waiting for a peer's build is waiting for this
  // build too, and needs the same allowance as the worker that runs it.
  onBuildStart();
  const status = await withProvisioningLock(codetracerRoot, async () => {
    console.log(`# provisioning ${build.key}: bash ${script} --only ${build.key}`);
    // Output inherited: a first build takes minutes, and the script's progress
    // and summary are the only sign that the test has not hung.
    return runToExit("bash", [script, "--only", build.key], codetracerRoot);
  });
  if (status !== 0) {
    throw new Error(
      `${build.key}: scripts/build-siblings.sh exited ${status}, so the recorder for this ` +
        `recording was not built. The output above names the failing build's log. ` +
        `Remedy: ${build.remedy}`,
    );
  }
  const artifactPath = path.join(repoDir, build.artifact);
  if (!fs.existsSync(artifactPath)) {
    throw new Error(
      `${build.key}: scripts/build-siblings.sh reported success, but ${artifactPath} does not ` +
        `exist. Remedy: ${build.remedy}`,
    );
  }
  return artifactPath;
}

/** Run a command with inherited output and resolve to its exit status. */
function runToExit(command: string, args: string[], cwd: string): Promise<number | null> {
  return new Promise((resolve, reject) => {
    const child = childProcess.spawn(command, args, { cwd, stdio: ["ignore", "inherit", "inherit"] });
    child.on("error", reject);
    // A signal kill has no exit status: resolve null, which the caller reports.
    child.on("close", (code) => resolve(code));
  });
}

// ---------------------------------------------------------------------------
// Cross-process lock
// ---------------------------------------------------------------------------
//
// The lock is a file, `.tools/gui-test-provisioning.lock`, whose text names its
// owner: `<pid> <process start time>`. Three rules make it safe without a
// kernel lock, and every removal in this section follows them:
//
// 1. A lock appears only by `link()` of a temp file that already holds the
//    owner text, so it is never seen empty and creation is atomic.
// 2. Only the holder of the break lock (`...lock.break`, created with O_EXCL)
//    removes a lock held by a dead owner, and it first re-reads the lock and
//    removes it only if the text is still the dead owner's. A lock that has
//    already been replaced is left alone.
// 3. A holder removes its lock only if the text is still its own.
//
// A dead owner is one whose pid is gone, or whose pid now belongs to a process
// with a different start time (Linux). Without a timeout the waiter waits for
// a live owner, which is the intent: a build that takes long is waited for.

/** Run `produce` while holding the provisioning lock of this codetracer checkout. */
async function withProvisioningLock<T>(
  codetracerRoot: string,
  produce: () => Promise<T>,
): Promise<T> {
  const toolsDir = path.join(codetracerRoot, ".tools");
  fs.mkdirSync(toolsDir, { recursive: true });
  const lockFile = path.join(toolsDir, "gui-test-provisioning.lock");
  const myText = ownerRecord();
  for (;;) {
    if (tryCreateLock(lockFile, toolsDir, myText)) {
      break;
    }
    const heldText = readText(lockFile);
    if (heldText !== undefined && isDeadOwner(heldText) && breakDeadLock(lockFile, toolsDir, heldText)) {
      continue;
    }
    await sleep(LOCK_RETRY_MS);
  }
  try {
    return await produce();
  } finally {
    releaseLock(lockFile, myText);
  }
}

/** The owner text of this process: its pid and, where the OS reports it, its start time. */
function ownerRecord(): string {
  return `${process.pid} ${processStartTime(process.pid) ?? "-"}`;
}

/** Create the lock holding `text`, atomically. False when a lock is already there. */
function tryCreateLock(lockFile: string, toolsDir: string, text: string): boolean {
  const tmp = path.join(
    toolsDir,
    `gui-test-provisioning.lock.${process.pid}.${Math.random().toString(36).slice(2)}.tmp`,
  );
  fs.writeFileSync(tmp, text);
  try {
    fs.linkSync(tmp, lockFile);
    return true;
  } catch (ex) {
    if ((ex as NodeJS.ErrnoException).code === "EEXIST") {
      return false;
    }
    throw ex;
  } finally {
    fs.rmSync(tmp, { force: true });
  }
}

/**
 * Remove the lock held by `staleText`, if that is still what it holds, under the
 * break lock. Returns true when it made an attempt (the caller retries at once),
 * false when another breaker is at work (the caller waits).
 */
function breakDeadLock(lockFile: string, toolsDir: string, staleText: string): boolean {
  const breakFile = path.join(toolsDir, "gui-test-provisioning.lock.break");
  try {
    fs.closeSync(fs.openSync(breakFile, "wx"));
  } catch (ex) {
    if ((ex as NodeJS.ErrnoException).code !== "EEXIST") {
      throw ex;
    }
    // A breaker that crashed leaves its break file behind. A live one is done
    // within milliseconds, so an old file is a crash and is cleared.
    if (ageMs(breakFile) > BREAK_LOCK_STALE_MS) {
      fs.rmSync(breakFile, { force: true });
    }
    return false;
  }
  try {
    // Under the break lock only one breaker runs. The lock can have been replaced
    // since it was read as stale, so it is removed only if it still holds the
    // dead owner's text.
    if (readText(lockFile) === staleText) {
      fs.rmSync(lockFile, { force: true });
    }
    return true;
  } finally {
    fs.rmSync(breakFile, { force: true });
  }
}

/** Remove the lock, but only while it still holds this process's owner text. */
function releaseLock(lockFile: string, myText: string): void {
  if (readText(lockFile) === myText) {
    fs.rmSync(lockFile, { force: true });
  }
}

/**
 * Whether the owner named in `text` is gone. Unreadable text counts as dead: the
 * lock is only ever written whole, so unreadable text means it was damaged.
 */
function isDeadOwner(text: string): boolean {
  const [pidText, startText] = text.split(" ");
  const pid = Number(pidText);
  if (!Number.isInteger(pid) || pid <= 0) {
    return true;
  }
  try {
    process.kill(pid, 0);
  } catch (ex) {
    // EPERM means the process exists under another user: still alive.
    return (ex as NodeJS.ErrnoException).code === "ESRCH";
  }
  if (startText === undefined || startText === "-") {
    return false;
  }
  const now = processStartTime(pid);
  return now !== undefined && now !== startText;
}

/**
 * The OS start time of `pid`, on Linux, from `/proc/<pid>/stat` field 22. It
 * identifies a process beyond its pid, which the OS reuses. Undefined where
 * `/proc` does not carry it.
 */
function processStartTime(pid: number): string | undefined {
  try {
    const stat = fs.readFileSync(`/proc/${pid}/stat`, "utf-8");
    // The command name may contain spaces and parentheses; the fields after the
    // last ')' start at field 3 (state), so field 22 is index 19 of them.
    const fields = stat.slice(stat.lastIndexOf(")") + 2).split(" ");
    return fields[19];
  } catch {
    return undefined;
  }
}

/** The file's text, or undefined when it does not exist. */
function readText(file: string): string | undefined {
  try {
    return fs.readFileSync(file, "utf-8");
  } catch (ex) {
    if ((ex as NodeJS.ErrnoException).code === "ENOENT") {
      return undefined;
    }
    throw ex;
  }
}

/** Milliseconds since the file was last modified, or 0 when it is gone. */
function ageMs(file: string): number {
  try {
    return Date.now() - fs.statSync(file).mtimeMs;
  } catch {
    return 0;
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// ---------------------------------------------------------------------------
// Paths and environment
// ---------------------------------------------------------------------------

/** The first of the two `ct` override variables that is set and non-empty. */
function firstNonEmpty(
  cmd: string | undefined,
  mcrPath: string | undefined,
): { name: string; value: string } | undefined {
  if (cmd !== undefined && cmd !== "") {
    return { name: "CODETRACER_CT_MCR_CMD", value: cmd };
  }
  if (mcrPath !== undefined && mcrPath !== "") {
    return { name: "CODETRACER_CT_MCR_PATH", value: mcrPath };
  }
  return undefined;
}

function isDirectory(p: string): boolean {
  try {
    return fs.statSync(p).isDirectory();
  } catch {
    return false;
  }
}

/** Whether `p`, resolved, lies inside directory `dir`. */
function isInside(p: string, dir: string): boolean {
  const resolved = path.resolve(p);
  const root = path.resolve(dir);
  return resolved === root || resolved.startsWith(root + path.sep);
}

/** The first executable named `name` on `PATH`, or undefined. */
function findOnPath(name: string): string | undefined {
  const exts = process.platform === "win32" ? [".exe", ""] : [""];
  for (const dir of (process.env.PATH ?? "").split(path.delimiter)) {
    if (dir === "") {
      continue;
    }
    for (const ext of exts) {
      const candidate = path.join(dir, name + ext);
      try {
        fs.accessSync(candidate, fs.constants.X_OK);
        if (fs.statSync(candidate).isFile()) {
          return candidate;
        }
      } catch {
        // Not here: try the next directory.
      }
    }
  }
  return undefined;
}
