/**
 * What a GUI session opened on an MCR portable fixture from
 * `codetracer-example-recordings/mcr/<platform>/` must show, and how to
 * observe it.
 *
 * ## Why this module exists
 *
 * Two specs used to "verify" MCR replay by asserting the page title, that
 * GoldenLayout panels were visible, and that a session held the imported
 * trace's id. All of that is present before any replay answers, so the specs
 * passed while the backend refused the recording (codetracer-pm issue
 * `2026-10-09-gui-mcr-specs-pass-without-the-mcr-trace-replaying.md`).
 *
 * A session on a fixture must now end in one of two observable states, and
 * the spec says in advance which one:
 *
 * - **replay** — the status bar shows a location in the recorded program's
 *   source with a line that exists in it. Only a replay of the recording
 *   produces that; the GUI chrome does not.
 * - **refused** — the user is shown the refusal that the specifications
 *   prescribe for this recording on this host, word for word, and no source
 *   location appears.
 *
 * The issue allows one more result: a case this host cannot show is
 * **reported as not verified**, instead of passing on the GUI chrome. That
 * result is given only for an open, recorded product defect, and only when
 * exactly that defect's symptom is shown to the user AND the replay worker's
 * own log records the defect's cause (`knownDefect` below). The symptom alone
 * is not enough: any worker that drops its connection, including one that
 * replays nothing at all, produces the same toast. Any other outcome — chrome
 * only, nothing shown, a different error, the symptom without the cause —
 * fails.
 *
 * ## Which outcome is expected
 *
 * Replay, unless a specified refusal applies (checked in this order):
 *
 * 1. The fixture's CTFS container version is one this build does not read.
 *    The import reader (`openCtfs`, `src/ct/trace/ctfs_sources.nim`) refuses
 *    it, so `ct host` exits before it serves a page. That refusal is host
 *    independent.
 * 2. A Linux x86-64 recording opened on a Linux x86-64 host. `ct-mcr
 *    debugserver` serves such an `mcr-interpose` recording through the stage0
 *    emulator replay, and refuses one without a stage0 boundary or with more
 *    than one recorded thread (codetracer-pm
 *    `spec/CLI/ct-mcr/debugserver.md`, "Linux interpose recordings in trace
 *    mode"). The `linux-x86_64` fixture records four threads, so one of the
 *    two refusals applies whichever way it was recorded. The backend passes
 *    the refusal to the GUI as an error notification
 *    (`send_launch_failure_notification`, `src/db-backend/src/dap_server.rs`).
 *
 * Every other fixture is expected to replay. A fixture recorded on another
 * OS or ISA takes the debugserver's cross-platform path, and on a Linux
 * x86-64 host the macos-arm64 and windows-x86_64 fixtures carry the known
 * defects below (`crossPlatformKnownDefect`).
 */

import * as fs from "node:fs";
import * as path from "node:path";

import { expect, type Page } from "@playwright/test";

import { parseStatusLocation, type SimpleLocation, type StatusBar } from "../page-objects/status_bar";
import { ctfsContainerVersion, ctfsVersionRefusal, readableCtfsVersions } from "./ctfs-container";

/**
 * `ct-mcr debugserver` serves the macOS arm64 fixture (a cooperative
 * recording) from its static checkpoint mode, describing the process as the
 * host's ISA with zeroed registers, so LLDB drops the arm64 executable and no
 * entry breakpoint resolves.
 */
export const ISSUE_STATIC_MODE_FOREIGN_ISA =
  "codetracer-pm/issues/2026-10-22-ct-mcr-static-checkpoint-mode-serves-a-foreign-isa-trace-as-the-host-isa.md";

/**
 * `ct-mcr debugserver`'s cross-platform loader reads only `tstart.mem` /
 * `cp0.mem`, so the Windows fixture's `cp.entry.*` initial state is not
 * loaded and the server falls through to the static checkpoint mode.
 */
export const ISSUE_CROSS_PLATFORM_INITIAL_STATE =
  "codetracer-pm/issues/2026-10-22-ct-mcr-cross-platform-replay-ignores-a-windows-stage0-recordings-initial-state.md";

/**
 * `ct-mcr export --portable` bundles no dSYM or PDB, so neither fixture's
 * portable trace has a line table: with the two defects above fixed, a
 * replay still could not show a line of the program.
 */
export const ISSUE_PORTABLE_EXPORT_NO_LINE_TABLE =
  "codetracer-pm/issues/2026-10-22-portable-export-bundles-no-dsym-or-pdb-debug-info.md";

/**
 * Defect B: the Electron GUI does not show a replay launch failure of a
 * session opened after the first; the `ct/notification` and
 * `ct/launch-failed` events reach the renderer and nothing is shown.
 */
export const ISSUE_LATER_SESSION_LAUNCH_FAILURE_HIDDEN =
  "codetracer-pm/issues/2026-10-22-electron-gui-does-not-show-a-later-sessions-replay-launch-failure.md";

/** One `mcr/<platform>/` fixture directory with a portable trace. */
export interface McrPortableFixture {
  /** The directory name, which names the recording platform (`linux-x86_64`). */
  platform: string;
  /** The fixture directory. */
  dir: string;
  /** `<dir>/trace-portable.ct`. */
  tracePath: string;
  /** The program the fixture records: its `source.c` symlink, followed. */
  programSource: string;
  /** Number of lines in `programSource`; a replayed location's line is within it. */
  programLineCount: number;
}

/** The host a spec runs on, as Node reports it. */
export interface McrHost {
  platform: NodeJS.Platform;
  arch: string;
}

/** An open product defect that keeps a case from being verified on this host. */
export interface McrKnownDefect {
  /** Matches, exactly, a notification the defect shows the user. */
  symptom: RegExp;
  /**
   * Finds the defect's cause in the replay worker logs of the session
   * (`replayWorkerLogs`), and returns a one-line description of it, or
   * `null` when the logs do not show it. Required because the symptom alone
   * does not identify the defect.
   */
  causeInWorkerLog: (workerLog: string) => string | null;
  /** What the defect is, for the not-verified report. */
  summary: string;
  /**
   * The `codetracer-pm/issues/<file>`s recording the defect, the cause first
   * and then any defect that would keep the case unverified after it is fixed.
   */
  issues: string[];
}

/** The outcome a spec expects from opening a fixture. */
export type McrPortableExpectation =
  | {
      kind: "replay";
      /** A defect that, when its exact symptom is observed, makes the case not verified. */
      knownDefect?: McrKnownDefect;
    }
  | {
      kind: "refused";
      /** Which component refuses: the `.ct` import reader or `ct-mcr debugserver`. */
      refusedBy: "import-reader" | "debugserver";
      /** Matches the refusal text the user is shown. */
      refusal: RegExp;
      /** Why the specifications make this a refusal, for the test log. */
      reason: string;
    };

/** What the GUI showed for a session, collected by `observeMcrSession`. */
export interface McrSessionObservation {
  /** The first status-bar location in the recorded program's source, if any. */
  replayLocation: SimpleLocation | null;
  /** Every distinct notification toast seen while observing, in order. */
  notifications: string[];
  /** The last raw status-bar location text, for failure messages. */
  lastRawLocation: string;
}

/**
 * The refusal of a Linux x86-64 interpose recording by Linux x86-64 trace
 * mode: `Stage0NoBoundaryRefusal` (`ct_cli/src/ct_cli/debugserver_cmd.nim`)
 * or `Stage0ServeRefusal` followed by the replay's own multi-thread refusal,
 * which names XMR-B1 (`multiThreadRefusal`,
 * `ct_emulator/src/ct_emulator/stage0_driver.nim`), both in
 * codetracer-native-recorder.
 */
export const LINUX_TRACE_MODE_REFUSAL =
  /error: (trace mode serves a Linux interpose recording through the stage0 emulator replay, and this recording has no stage0 boundary the emulator can start from|trace mode cannot serve this recording: the stage0 driver serves a process that recorded one thread, and this one recorded \d+ threads; [^"]*XMR-B1)/;

/**
 * The whole notification both cross-platform defects show: the replay
 * worker answered the first query, `RunToEntry`, with
 * `error: run query error: "MCR run-to-entry could not resolve an entry breakpoint"`
 * (`run_mcr_lldb_connection_loop`, codetracer-native-backend
 * `src/lib_non_windows.inc.rs`), which the replay server reports as
 * `dispatch_replay_query ct rr worker error: <answer>` and
 * `launch_failure_text` renders with `{err:?}`. Anchored at both ends so that
 * no other launch error matches: a worker that drops the connection instead
 * (EOF, connection reset) or never starts shows a different one.
 */
const CROSS_PLATFORM_ENTRY_BREAKPOINT_REFUSAL =
  /^launch error: "dispatch_replay_query ct rr worker error: error: run query error: \\"MCR run-to-entry could not resolve an entry breakpoint\\""$/;

/**
 * Notification texts that report a failed `launch`: every rendering
 * `launch_failure_text` (`src/db-backend/src/dap_server.rs`) produces. One of
 * them means the backend has given up on this launch, so nothing more is
 * worth waiting for.
 */
const LAUNCH_FAILURE_NOTIFICATION =
  /^(launch error: |failed to initialize replay-worker transport|replay worker for pid \d+ refused to start|Free tier: |.*: this recording cannot be opened by this build)/;

/** The main binaries `ct-mcr debugserver` reported extracting, as the worker logged them. */
function reportedMainBinaries(workerLog: string): Set<string> {
  const reported = new Set<string>();
  for (const match of workerLog.matchAll(/MCR debugserver: debugserver: main binary: (?<binary>.+)$/gm)) {
    reported.add(match.groups?.binary ?? "");
  }
  return reported;
}

/**
 * The common half of both cross-platform causes, as `ct-native-replay` logs
 * it: the worker built its LLDB target from the main binary `ct-mcr
 * debugserver` reported extracting into its sysroot (`MCR debugserver:
 * debugserver: main binary: <path>`, then `MCR: using binary <path> for LLDB
 * target`, the same path), and AFTER that its `RunToEntry` failed resolving
 * the entry breakpoint (`run query error: "MCR run-to-entry could not resolve
 * an entry breakpoint"`). Returns the failure's log offset and the target
 * path, or `null` when the log does not show that sequence: a worker that
 * chose another binary, failed some other way, or failed before choosing.
 */
function extractedTargetThenEntryFailure(workerLog: string): { offset: number; binary: string } | null {
  const reported = reportedMainBinaries(workerLog);
  const failure = /\[ERROR\] - run query error: "MCR run-to-entry could not resolve an entry breakpoint"$/m.exec(
    workerLog,
  );
  if (failure === null) return null;
  for (const match of workerLog.matchAll(/MCR: using binary (?<binary>.+) for LLDB target$/gm)) {
    const binary = match.groups?.binary ?? "";
    if (binary !== "" && reported.has(binary) && match.index < failure.index) {
      return { offset: failure.index, binary };
    }
  }
  return null;
}

/**
 * Finds `debugserverLine` (a `ct-mcr debugserver` stdout line, as the worker
 * logs it after `MCR debugserver: `) in `workerLog` before `offset`, and none
 * of `absentLines`; returns whether it does.
 */
function debugserverSaid(
  workerLog: string,
  offset: number,
  debugserverLine: string,
  absentLines: string[] = [],
): boolean {
  const before = workerLog.slice(undefined, offset);
  const said = (line: string): boolean => before.includes(`MCR debugserver: ${line}\n`);
  return said(debugserverLine) && !absentLines.some(said);
}

/**
 * The known defect a session on `fixture` shows on this host, when the
 * fixture is one of the two cross-platform fixtures this host cannot
 * replay; `undefined` otherwise. Each cause requires the common half
 * (`extractedTargetThenEntryFailure`) AND the debugserver's own account of
 * the path it took for that fixture, so neither fixture's evidence satisfies
 * the other's defect.
 */
function crossPlatformKnownDefect(fixture: McrPortableFixture, host: McrHost): McrKnownDefect | undefined {
  if (host.platform !== "linux" || host.arch !== "x64") return undefined;
  if (fixture.platform === "macos-arm64") {
    return {
      symptom: CROSS_PLATFORM_ENTRY_BREAKPOINT_REFUSAL,
      causeInWorkerLog: (workerLog) => {
        const common = extractedTargetThenEntryFailure(workerLog);
        if (common === null) return null;
        // Served by the static checkpoint mode: the cross-platform notice,
        // and no emulator path.
        const staticMode = debugserverSaid(
          workerLog,
          common.offset,
          "debugserver: cross-platform replay (posMacos/paAarch64 on posLinux/paX86_64)",
          ["debugserver: cross-platform replay via emulator"],
        );
        return staticMode
          ? `target ${common.binary} (extracted), served by the static checkpoint mode, then ` +
              `"MCR run-to-entry could not resolve an entry breakpoint"`
          : null;
      },
      summary:
        "ct-mcr debugserver serves this foreign-ISA cooperative recording from its static " +
        "checkpoint mode as an x86-64 process with zeroed registers, so LLDB drops the arm64 " +
        "executable and RunToEntry finds no entry breakpoint",
      issues: [ISSUE_STATIC_MODE_FOREIGN_ISA, ISSUE_PORTABLE_EXPORT_NO_LINE_TABLE],
    };
  }
  if (fixture.platform === "windows-x86_64") {
    return {
      symptom: CROSS_PLATFORM_ENTRY_BREAKPOINT_REFUSAL,
      causeInWorkerLog: (workerLog) => {
        const common = extractedTargetThenEntryFailure(workerLog);
        if (common === null) return null;
        const fellThrough =
          debugserverSaid(
            workerLog,
            common.offset,
            "debugserver: emulator setup failed: failed to load initial state: trace contains no memory snapshot (tstart.mem / cp0.mem)",
          ) && debugserverSaid(workerLog, common.offset, "debugserver: falling through to static checkpoint mode");
        return fellThrough
          ? `target ${common.binary} (extracted), emulator setup failed on "no memory snapshot ` +
              `(tstart.mem / cp0.mem)" and fell through to the static checkpoint mode, then ` +
              `"MCR run-to-entry could not resolve an entry breakpoint"`
          : null;
      },
      summary:
        "ct-mcr debugserver's cross-platform loader does not load this Windows stage0 " +
        "recording's cp.entry.* initial state, falls through to the static checkpoint mode, " +
        "and RunToEntry finds no entry breakpoint (the bundled PE has no symbols either)",
      issues: [ISSUE_CROSS_PLATFORM_INITIAL_STATE, ISSUE_PORTABLE_EXPORT_NO_LINE_TABLE],
    };
  }
  return undefined;
}

/** The replay worker logs of one session, and where they were looked for. */
export interface ReplayWorkerLogs {
  /** The run directories the replay server connected to workers in. */
  runDirs: string[];
  /** Every `ct-native-replay-*.log` in those directories, concatenated. */
  text: string;
}

/**
 * Read the `ct-native-replay` logs of the workers a replay server started,
 * given the replay server's stderr.
 *
 * The replay server prints `[rr-worker] connecting to socket <path>` for each
 * worker (`setup_worker_sockets`, `src/db-backend/src/recreator_session.rs`),
 * and writes the worker's stderr to `ct-native-replay-<name>-<index>.log`
 * beside that socket (`log_path_in`, `src/db-backend/src/paths.rs`). The
 * directory is removed when the replay server exits, so call this while it
 * runs. A directory that cannot be read contributes nothing, which can only
 * make a cause harder to find, never easier.
 */
export function replayWorkerLogs(replayServerStderr: string): ReplayWorkerLogs {
  const runDirs = new Set<string>();
  for (const match of replayServerStderr.matchAll(/\[rr-worker\] connecting to socket (\S+)/g)) {
    runDirs.add(path.dirname(match[1]));
  }
  let text = "";
  for (const dir of runDirs) {
    let entries: string[];
    try {
      entries = fs.readdirSync(dir);
    } catch {
      continue;
    }
    for (const entry of entries.filter((name) => /^ct-native-replay-.*\.log$/.test(name)).sort()) {
      try {
        text += fs.readFileSync(path.join(dir, entry), "utf-8") + "\n";
      } catch {
        // Removed between the listing and the read.
      }
    }
  }
  return { runDirs: [...runDirs], text };
}

function escapeRegExp(text: string): string {
  return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/**
 * The file a fixture's `source.c` link names.
 *
 * A checkout without symlink support (git's `core.symlinks=false`, the
 * default on Windows) writes a link as a regular file holding the link
 * target. Such a file is followed by its text, so the replay assertion is
 * made against the program and not against a one-line path. Anything else
 * that is not a link throws: guessing the program would hide a broken
 * fixture.
 */
function followSourceLink(link: string): string {
  if (fs.lstatSync(link).isSymbolicLink()) {
    return fs.realpathSync(link);
  }
  const target = fs.readFileSync(link, "utf-8").trim();
  const resolved = path.resolve(path.dirname(link), target);
  if (target.includes("\n") || !fs.existsSync(resolved) || !fs.statSync(resolved).isFile()) {
    throw new Error(`MCR fixture source.c is neither a symlink nor a link written as text: ${link}`);
  }
  return fs.realpathSync(resolved);
}

/** Describe the fixture in `mcr/<platform>/`. */
export function mcrPortableFixture(mcrDir: string, platform: string): McrPortableFixture {
  const dir = path.join(mcrDir, platform);
  // Each fixture names the program it records by its own `source.c` symlink
  // into `../../programs/` (the CTSP client for the mobile fixtures, the
  // fixture program for the rest); nothing is assumed about which one.
  const link = path.join(dir, "source.c");
  if (!fs.existsSync(link)) {
    throw new Error(`MCR fixture has no source.c: ${link}`);
  }
  const programSource = followSourceLink(link);
  // A final newline ends the last line; it does not start another one.
  const programLineCount = fs.readFileSync(programSource, "utf-8").replace(/\n$/, "").split("\n").length;
  return {
    platform,
    dir,
    tracePath: path.join(dir, "trace-portable.ct"),
    programSource,
    programLineCount,
  };
}

/** The OS and Node architecture a fixture directory name says it was recorded on. */
function fixtureRecordingPlatform(fixture: McrPortableFixture): { os: string; arch: string } {
  const [os = "", isa = ""] = fixture.platform.split("-");
  const nodeOs: Record<string, string> = { linux: "linux", macos: "darwin", windows: "win32" };
  const nodeArch: Record<string, string> = { x86_64: "x64", arm64: "arm64" };
  return { os: nodeOs[os] ?? os, arch: nodeArch[isa] ?? isa };
}

/** The outcome the specifications prescribe for `fixture` on `host`. */
export function expectedMcrPortableOutcome(
  fixture: McrPortableFixture,
  host: McrHost = { platform: process.platform, arch: process.arch },
): McrPortableExpectation {
  // An unreadable container is refused by the import reader. The refusal is
  // matched on its reason, not on how `ct host` reports it: today `ct host`
  // ends in an unhandled exception
  // (codetracer-pm/issues/2026-10-04-ct-importer-turns-a-container-refusal-into-false.md),
  // and a clean refusal must still satisfy this. The android and ios fixtures
  // are such containers until they are re-recorded
  // (codetracer-pm/issues/2026-10-02-example-recordings-fixtures-are-container-v3-v4.md).
  const version = ctfsContainerVersion(fixture.tracePath);
  if (!readableCtfsVersions.includes(version)) {
    return {
      kind: "refused",
      refusedBy: "import-reader",
      refusal: new RegExp(escapeRegExp(ctfsVersionRefusal(version))),
      reason:
        `the fixture is CTFS container version ${version}, and this build reads ` +
        `versions ${readableCtfsVersions.join(" and ")}; the fixture must be re-recorded`,
    };
  }
  const recordedOn = fixtureRecordingPlatform(fixture);
  const samePlatform = recordedOn.os === host.platform && recordedOn.arch === host.arch;
  if (samePlatform && host.platform === "linux" && host.arch === "x64") {
    return {
      kind: "refused",
      refusedBy: "debugserver",
      refusal: LINUX_TRACE_MODE_REFUSAL,
      reason:
        "Linux x86-64 trace mode serves an interpose recording only from a stage0 " +
        "boundary and with one recorded thread (debugserver.md, \"Linux interpose " +
        "recordings in trace mode\"); this fixture records four threads",
    };
  }
  if (!samePlatform) {
    return { kind: "replay", knownDefect: crossPlatformKnownDefect(fixture, host) };
  }
  return { kind: "replay" };
}

/** Whether `location` is in the recorded program's source, at a line it has. */
function isFixtureSourceLocation(location: SimpleLocation, fixture: McrPortableFixture): boolean {
  // The location names the source as the recording's debug info does, or as
  // the copy a trace folder carries in `files/source.c`.
  const base = location.path.split(/[\\/]/).pop() ?? "";
  const names = new Set([path.basename(fixture.programSource), "source.c"]);
  return names.has(base) && location.line >= 1 && location.line <= fixture.programLineCount;
}

/**
 * Watch the GUI until it shows a location in the fixture's program source,
 * the backend reports a failed launch, or `timeoutMs` passes.
 *
 * Polls rather than waiting for one element: launch failures arrive as toasts
 * that dismiss themselves after three seconds.
 */
export async function observeMcrSession(
  statusBar: StatusBar,
  fixture: McrPortableFixture,
  timeoutMs = 60_000,
): Promise<McrSessionObservation> {
  const POLL_MS = 250;
  const observation: McrSessionObservation = {
    replayLocation: null,
    notifications: [],
    lastRawLocation: "",
  };
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    for (const text of await statusBar.activeNotificationTexts()) {
      if (!observation.notifications.includes(text)) {
        observation.notifications.push(text);
      }
    }
    observation.lastRawLocation = await statusBar.rawLocation();
    const location = parseStatusLocation(observation.lastRawLocation);
    if (location && isFixtureSourceLocation(location, fixture)) {
      observation.replayLocation = location;
      return observation;
    }
    if (observation.notifications.some((text) => LAUNCH_FAILURE_NOTIFICATION.test(text))) {
      return observation;
    }
    await statusBar.page.waitForTimeout(POLL_MS);
  }
  return observation;
}

/** Whether the user was shown the refusal `expectation` names. */
export function refusalShown(
  observation: McrSessionObservation,
  expectation: McrPortableExpectation,
): boolean {
  return (
    expectation.kind === "refused" &&
    observation.notifications.some((text) => expectation.refusal.test(text))
  );
}

/**
 * The not-verified report for `observation`, when the user was shown exactly
 * the symptom of the open defect `expectation` names and `workerLogs` record
 * that defect's cause, and `null` otherwise. A replay, a notification set
 * without that symptom, or the symptom without the cause in the logs, is
 * never not-verified.
 */
export function knownDefectReport(
  observation: McrSessionObservation,
  expectation: McrPortableExpectation,
  fixture: McrPortableFixture,
  workerLogs: ReplayWorkerLogs,
): string | null {
  if (expectation.kind !== "replay" || !expectation.knownDefect) return null;
  if (observation.replayLocation !== null) return null;
  const defect = expectation.knownDefect;
  if (!observation.notifications.some((text) => defect.symptom.test(text))) return null;
  const cause = defect.causeInWorkerLog(workerLogs.text);
  if (cause === null) return null;
  return `not verified: ${fixture.platform}: ${defect.summary} (worker log: ${cause}); ${defect.issues.join("; ")}`;
}

function describeObservation(observation: McrSessionObservation): string {
  const shown =
    observation.notifications.length > 0
      ? observation.notifications.map((text) => `  - ${text}`).join("\n")
      : "  (none)";
  return (
    `status-bar location: "${observation.lastRawLocation}"\n` +
    `notifications shown to the user:\n${shown}`
  );
}

/**
 * Assert that `observation` is the outcome `expectation` names, for a session
 * on `fixture`.
 *
 * For a refusal, both halves are asserted: the user was shown the refusal,
 * and no location in the program's source appeared (so the refusal is not a
 * stray message beside a replay that worked).
 */
export function assertMcrSessionOutcome(
  observation: McrSessionObservation,
  expectation: McrPortableExpectation,
  fixture: McrPortableFixture,
): void {
  if (expectation.kind === "replay") {
    expect(
      observation.replayLocation,
      `${fixture.platform}: expected a replay of ${fixture.tracePath} to put the status bar ` +
        `at a line of ${path.basename(fixture.programSource)} (1..${fixture.programLineCount}); ` +
        `it did not.\n${describeObservation(observation)}`,
    ).not.toBeNull();
    return;
  }
  expect(
    observation.replayLocation,
    `${fixture.platform}: expected the recording to be refused (${expectation.reason}), but ` +
      `the GUI shows a location in the program, so it replays. Replace the refusal ` +
      `expectation with replay assertions.\n${describeObservation(observation)}`,
  ).toBeNull();
  expect(
    refusalShown(observation, expectation),
    `${fixture.platform}: expected the user to be shown the ${expectation.refusedBy}'s ` +
      `refusal matching ${expectation.refusal} (${expectation.reason}).\n` +
      describeObservation(observation),
  ).toBe(true);
}

// ---------------------------------------------------------------------------
// What the Electron renderer received, as opposed to what it showed
// ---------------------------------------------------------------------------

/** One DAP event the renderer received from the main process. */
export interface RendererDapEvent {
  /** The DAP event name (`ct/notification`, `ct/launch-failed`, ...). */
  event: string;
  /** The session the main process tagged it with, when it did. */
  sessionId: number | null;
  /** The event's message: `body.text` of a notification, `body.message` of a launch failure. */
  text: string;
}

/** The DAP events `recordRendererDapEvents` keeps; everything else is ignored. */
const RECORDED_RENDERER_EVENTS = ["ct/notification", "ct/launch-failed"];

/**
 * Start recording the launch-failure DAP events the Electron renderer
 * receives on `CODETRACER::dap-receive-event` (the IPC channel
 * `onDapReceiveEvent` in `src/frontend/ui_js.nim` consumes), whatever the GUI
 * then does with them.
 *
 * This observes the renderer's input, beside the app's own listener; it does
 * not change what the app does. Call it before the launch whose events are
 * wanted. Calling it again keeps the events already recorded.
 */
export async function recordRendererDapEvents(page: Page): Promise<void> {
  await page.evaluate((wanted) => {
    const w = window as any;
    if (w.__ctTestRendererDapEvents) return;
    const events: unknown[] = [];
    w.__ctTestRendererDapEvents = events;
    const ipc = w.data?.ipc;
    if (!ipc || typeof ipc.on !== "function") {
      throw new Error("window.data.ipc has no on(): this renderer cannot be observed");
    }
    ipc.on("CODETRACER::dap-receive-event", (_sender: unknown, raw: any) => {
      const event = String(raw?.event ?? "");
      if (!wanted.includes(event)) return;
      const body = raw?.body ?? {};
      events.push({
        event,
        sessionId: typeof raw?.sessionId === "number" ? raw.sessionId : null,
        text: String(body.message ?? body.text ?? ""),
      });
    });
  }, RECORDED_RENDERER_EVENTS);
}

/** The events recorded since `recordRendererDapEvents`. */
export async function rendererDapEvents(page: Page): Promise<RendererDapEvent[]> {
  return page.evaluate(() => (window as any).__ctTestRendererDapEvents ?? []);
}
