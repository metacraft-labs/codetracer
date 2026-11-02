/**
 * How much of a wall-clock interval a process tree spent waiting for a CPU.
 *
 * The GUI suite's performance limits (`lib/performance-limits.ts`) are
 * wall-clock budgets, and wall clock moves with the host's load: on a shared
 * 24-core host at load average 33-48 a clean tree measured `first window` at
 * 10.3-10.9 s against its 10 s limit, where the same launch measures 6.2-6.6 s
 * on a quieter minute (codetracer-pm issue
 * `2026-10-17-electron-build-specs-fail-on-clean-agents-under-host-load`).
 * A verdict that flips with what other tenants are doing cannot tell a
 * regression from a busy neighbour.
 *
 * Linux accounts, per thread, the time the thread ran and the time it was
 * RUNNABLE but waiting on a run queue — `/proc/<pid>/task/<tid>/schedstat`,
 * fields 1 and 2, in nanoseconds:
 * https://docs.kernel.org/scheduler/sched-stats.html#proc-pid-schedstat
 * The second number is exactly the cost of contention: it is zero on an idle
 * host and grows with the number of competing runnable tasks, while sleeping,
 * blocking on I/O and waiting on another process do not count towards it.
 *
 * `sampleProcessTree` reads both for every thread of a process and all its
 * descendants; `contentionBetween` turns two samples into the CPU and
 * run-queue-wait time the tree accrued in between, and
 * `contentionAdjustedMs` estimates the wall-clock time the interval would
 * have taken without that wait. See that function for the estimate and what
 * it can and cannot hide.
 *
 * Off Linux (or without schedstat) the samples are marked unsupported and the
 * adjusted figure is the wall clock itself, i.e. the old behaviour.
 */

import * as fs from "node:fs";

/** CPU and run-queue-wait time of one thread, in nanoseconds. */
interface ThreadTimes {
  cpuNs: number;
  waitNs: number;
  /** When the thread started, in clock ticks since boot. */
  startTicks: number;
}

/** A point-in-time reading of a process tree's per-thread scheduler times. */
export interface ProcessTreeSample {
  /** False when this platform does not expose per-thread schedstat. */
  supported: boolean;
  /**
   * Clock ticks since boot when the sample began, on the clock that thread
   * start times use (`/proc/uptime`, CLOCK_BOOTTIME).
   */
  takenAtTicks: number;
  /**
   * Keyed by `<pid>/<tid>/<start ticks>`: the start time tells a reused tid
   * from the thread that had it before.
   */
  threads: Map<string, ThreadTimes>;
}

/** What a process tree accrued between two samples. */
export interface Contention {
  supported: boolean;
  /** Time the tree's threads were on a CPU. */
  cpuMs: number;
  /** Time the tree's threads were runnable but waiting for a CPU. */
  waitMs: number;
}

function readText(file: string): string | null {
  try {
    return fs.readFileSync(file, "utf8");
  } catch {
    // The process or thread exited between listing and reading it.
    return null;
  }
}

function listDir(dir: string): string[] {
  try {
    return fs.readdirSync(dir);
  } catch {
    return [];
  }
}

/** Children of `pid`, through `/proc/<pid>/task/<tid>/children`. */
function childrenOf(pid: number): number[] {
  const out: number[] = [];
  for (const tid of listDir(`/proc/${pid}/task`)) {
    const text = readText(`/proc/${pid}/task/${tid}/children`);
    if (text === null) continue;
    for (const field of text.split(/\s+/)) {
      const child = Number(field);
      if (Number.isInteger(child) && child > 0) out.push(child);
    }
  }
  return out;
}

/** `rootPid` and every live descendant of it. */
function processTree(rootPid: number): number[] {
  const seen = new Set<number>();
  const stack = [rootPid];
  while (stack.length > 0) {
    const pid = stack.pop()!;
    if (seen.has(pid)) continue;
    seen.add(pid);
    stack.push(...childrenOf(pid));
  }
  return [...seen];
}

/**
 * Clock ticks per second of the thread start times in `/proc/<pid>/stat`. It
 * is `USER_HZ`, which the kernel's user-space ABI fixes at 100 on the
 * architectures these tests run on (proc(5), "starttime";
 * https://man7.org/linux/man-pages/man5/proc_pid_stat.5.html).
 */
const CLOCK_TICKS_PER_SECOND = 100;

/** Now, in clock ticks since boot, or NaN when `/proc/uptime` is unreadable. */
function uptimeTicks(): number {
  const text = readText("/proc/uptime");
  const seconds = text === null ? NaN : Number(text.trim().split(/\s+/)[0]);
  return Math.floor(seconds * CLOCK_TICKS_PER_SECOND);
}

/**
 * A thread's start time in clock ticks since boot (field 22 of its `stat`),
 * or NaN when it cannot be read. Fields are counted after the parenthesised
 * command name, which may itself contain spaces and parentheses.
 */
function threadStartTicks(pid: number, tid: string): number {
  const text = readText(`/proc/${pid}/task/${tid}/stat`);
  if (text === null) return NaN;
  const fields = text.slice(text.lastIndexOf(")") + 1).trim().split(/\s+/);
  // `fields[0]` is field 3 (state), so field 22 is at index 19.
  return Number(fields[19]);
}

/**
 * Whether this host exposes what `sampleProcessTree` needs. Computed once:
 * the files are kernel configuration (`CONFIG_SCHED_INFO`,
 * `CONFIG_PROC_CHILDREN`), not something that changes during a run.
 */
const schedstatSupported: boolean = (() => {
  if (process.platform !== "linux") return false;
  const tid = process.pid;
  return (
    readText(`/proc/${process.pid}/task/${tid}/schedstat`) !== null &&
    readText(`/proc/${process.pid}/task/${tid}/children`) !== null &&
    Number.isFinite(threadStartTicks(process.pid, String(tid))) &&
    Number.isFinite(uptimeTicks())
  );
})();

/**
 * Read the scheduler times of every thread of `rootPid` and its descendants.
 * Defaults to this process, whose descendants are everything a test launches
 * (Electron, its renderer and GPU processes, `ct` and the replay backends).
 */
export function sampleProcessTree(rootPid: number = process.pid): ProcessTreeSample {
  const threads = new Map<string, ThreadTimes>();
  const takenAtTicks = schedstatSupported ? uptimeTicks() : NaN;
  if (!Number.isFinite(takenAtTicks)) return { supported: false, takenAtTicks, threads };
  for (const pid of processTree(rootPid)) {
    for (const tid of listDir(`/proc/${pid}/task`)) {
      const text = readText(`/proc/${pid}/task/${tid}/schedstat`);
      if (text === null) continue;
      const [cpuNs, waitNs] = text.trim().split(/\s+/).map(Number);
      const startTicks = threadStartTicks(pid, tid);
      if (![cpuNs, waitNs, startTicks].every(Number.isFinite)) continue;
      threads.set(`${pid}/${tid}/${startTicks}`, { cpuNs, waitNs, startTicks });
    }
  }
  return { supported: true, takenAtTicks, threads };
}

/**
 * CPU and run-queue wait the tree accrued from `before` to `after`.
 *
 * A thread present only in `after` counts in full only if it STARTED after
 * `before` was taken, so that all of its time lies inside the interval. One
 * that started earlier but is missing from `before` has no baseline —
 * `children` is not guaranteed complete while the tree forks and exits
 * (proc(5)) — and counting its whole lifetime would credit wait from before
 * the interval, so it is left out. A thread present only in `before` exited
 * during the interval and its time after the first sample is lost with it.
 * In every case the wait total stays at or below what the tree accrued.
 */
export function contentionBetween(
  before: ProcessTreeSample,
  after: ProcessTreeSample,
): Contention {
  if (!before.supported || !after.supported) {
    return { supported: false, cpuMs: 0, waitMs: 0 };
  }
  let cpuNs = 0;
  let waitNs = 0;
  for (const [key, end] of after.threads) {
    const start = before.threads.get(key);
    if (start === undefined) {
      // One tick of slack: a thread may start in the tick in which `before`
      // read the clock, before that sample got round to listing the tree.
      if (end.startTicks < before.takenAtTicks - 1) continue;
      cpuNs += end.cpuNs;
      waitNs += end.waitNs;
    } else if (end.cpuNs >= start.cpuNs && end.waitNs >= start.waitNs) {
      // The same thread (same tid and start time): its counters only grow.
      cpuNs += end.cpuNs - start.cpuNs;
      waitNs += end.waitNs - start.waitNs;
    }
  }
  return { supported: true, cpuMs: cpuNs / 1e6, waitMs: waitNs / 1e6 };
}

/**
 * Estimate how long an interval of `wallMs` would have taken had the tree
 * never waited for a CPU.
 *
 * Two estimates, each exact in one limiting case, and the LARGER is returned
 * so that the adjustment never forgives more than either justifies:
 *
 *  - `wallMs - waitMs`: exact when the work is one thread (or a chain of
 *    threads handing off to each other), because every millisecond it waited
 *    was a millisecond of the interval. With parallel threads the waits add
 *    up to more than the interval, and this goes to zero or below.
 *  - `wallMs * cpuMs / (cpuMs + waitMs)`: exact when the work is spread over
 *    threads that were all slowed by the same factor, which is what a
 *    contended host does to parallel work.
 *
 * The result is never below `wallMs - waitMs`, so the adjustment never takes
 * off more than the run-queue wait the tree was measured to accrue. On an
 * idle host `waitMs` is ~0 and both estimates are `wallMs`, so an uncontended
 * run is graded exactly as before.
 *
 * What the adjustment cannot do is make a loaded host as sensitive as an idle
 * one. Extra CPU work is still graded: under contention it is scaled by the
 * same factor as the rest, so four times the work still grades at about four
 * times the time. But the factor is the whole tree's, so the wait of
 * contended threads off the critical path can discount critical-path time
 * (by at most that wait), and a regression that only adds sleeping (a timer,
 * a poll interval) to an interval whose other threads were contended can be
 * partly discounted too. An idle host catches both.
 */
export function contentionAdjustedMs(wallMs: number, c: Contention): number {
  if (!c.supported || c.cpuMs + c.waitMs <= 0) return wallMs;
  const serial = wallMs - c.waitMs;
  const parallel = (wallMs * c.cpuMs) / (c.cpuMs + c.waitMs);
  return Math.max(0, Math.min(wallMs, Math.max(serial, parallel)));
}
