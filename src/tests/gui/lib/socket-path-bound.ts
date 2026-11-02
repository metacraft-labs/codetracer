/**
 * Whether a `CODETRACER_HOME` is short enough for the Unix sockets the
 * product binds under it, and where the GUI suite makes one that is.
 *
 * The desktop's main process talks to its session manager over a Unix-domain
 * socket at `$CODETRACER_HOME/tmp/session-manager/<pid>.sock`, and the
 * session manager gives every replay a socket of its own at
 * `$CODETRACER_HOME/tmp/session-manager/<pid>/<replay id>.sock`
 * (`src/frontend/index/ipc_utils.nim` `ready`, `src/backend-manager`
 * `start_replay_raw`). A socket address holds a fixed number of bytes
 * (`sockaddr_un.sun_path`: 108 on Linux, 104 on macOS and the BSDs, each
 * including the terminating NUL; https://man7.org/linux/man-pages/man7/unix.7.html,
 * https://man.freebsd.org/cgi/man.cgi?query=unix&sektion=4), and a longer
 * path cannot be bound. Under a home made in macOS's default `TMPDIR`
 * (`/var/folders/<..>/T/`, deeper still inside a nix shell) the replay's
 * socket did not fit, the session manager refused it, and the suite drove a
 * product with no replay backend. So the fixtures make the home under a short
 * base (`scratchBase`), and refuse one that does not fit before they launch
 * anything (`assertHomeFitsSocketBound`), naming the path, its length and
 * the limit, whether the home was made here or supplied through
 * `CODETRACER_GUI_TEST_CODETRACER_HOME`.
 *
 * Windows is not bounded: there the session manager and its replays use TCP
 * on localhost (`ipc_utils.nim`'s `.port` file), so no path is bound.
 *
 * Self-test: `tests/harness/codetracer-home-socket-bound.spec.ts`.
 */

import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

/** `sun_path` less its NUL on Linux (a 108-byte `sun_path`). */
const LINUX_MAX_SOCKET_PATH_BYTES = 107;
/** `sun_path` less its NUL on macOS and the BSDs (a 104-byte `sun_path`). */
const BSD_MAX_SOCKET_PATH_BYTES = 103;
/** Digits in macOS's `PID_MAX`, 99999. */
const DARWIN_PID_DIGITS = 5;
/** Digits in Linux's `PID_MAX_LIMIT`, 4194304, the most `pid_max` can be. */
const LINUX_PID_DIGITS = 7;

/**
 * The longest path, in bytes, a Unix socket address holds on `platform`:
 * `sun_path` less its terminating NUL. `undefined` on Windows, where the
 * product binds no Unix socket. A platform not listed gets the smaller,
 * BSD-family bound, which is the safe side of the two.
 */
export function maxUnixSocketPathBytes(
  platform: NodeJS.Platform = process.platform,
): number | undefined {
  switch (platform) {
    case "win32":
      return undefined;
    case "linux":
    case "android":
      return LINUX_MAX_SOCKET_PATH_BYTES;
    default:
      // darwin, freebsd, openbsd, netbsd, sunos, aix: 104-byte `sun_path`.
      return BSD_MAX_SOCKET_PATH_BYTES;
  }
}

/**
 * Digits in the largest process id `platform` hands out: the session
 * manager's pid is a component of every socket path it binds. Linux's
 * `pid_max` can be raised to `PID_MAX_LIMIT`, 4194304 (proc(5),
 * `/proc/sys/kernel/pid_max`); macOS's `PID_MAX` is 99999.
 */
function maxPidDigits(platform: NodeJS.Platform): number {
  return platform === "darwin" ? DARWIN_PID_DIGITS : LINUX_PID_DIGITS;
}

/**
 * Replay ids budgeted for: the session manager numbers replays from 0 and
 * does not reuse a number, so a long GUI spec that opens many traces has
 * longer ids. Four digits is far past any spec's count.
 */
const REPLAY_ID_DIGITS = 4;

/**
 * The longest Unix socket path the product derives under `home`: a replay's
 * socket, with the largest pid and replay id the bound budgets for.
 */
export function longestSocketPathUnder(
  home: string,
  platform: NodeJS.Platform = process.platform,
): string {
  return path.join(
    home,
    "tmp",
    "session-manager",
    "9".repeat(maxPidDigits(platform)),
    `${"9".repeat(REPLAY_ID_DIGITS)}.sock`,
  );
}

/**
 * `home` as the product will spell it, and, when it exists and differs, its
 * real path: either may reach a bind (macOS's `/tmp` is a link to
 * `/private/tmp`), so the longer one is the one measured.
 */
function spellingsOf(home: string): string[] {
  const spellings = [path.resolve(home)];
  try {
    const real = fs.realpathSync(home);
    if (!spellings.includes(real)) spellings.push(real);
  } catch {
    // Not made yet: only the spelling given can be measured.
  }
  return spellings;
}

/**
 * Why `home` cannot be a `CODETRACER_HOME` on `platform` — the longest
 * socket path under it, its length in bytes and the limit — or `undefined`
 * when every socket path under it fits. `source` says where the home came
 * from, for the message.
 */
export function socketBoundViolation(
  home: string,
  source: string,
  platform: NodeJS.Platform = process.platform,
): string | undefined {
  const max = maxUnixSocketPathBytes(platform);
  if (max === undefined) return undefined;
  for (const spelling of spellingsOf(home)) {
    const socketPath = longestSocketPathUnder(spelling, platform);
    const length = Buffer.byteLength(socketPath, "utf8");
    if (length > max) {
      return (
        `the CODETRACER_HOME ${home} (${source}) is too deep for the Unix sockets ` +
        `CodeTracer binds under it: ${socketPath} is ${length} bytes, and a socket ` +
        `address holds ${max} on ${platform} (sockaddr_un.sun_path). The session ` +
        `manager would refuse to bind it and no replay could start. Use a home of at ` +
        `most ${max - (length - Buffer.byteLength(spelling, "utf8"))} bytes ` +
        `(CODETRACER_GUI_TEST_CODETRACER_HOME).`
      );
    }
  }
  return undefined;
}

/** Throws `socketBoundViolation`'s message when `home` does not fit. */
export function assertHomeFitsSocketBound(
  home: string,
  source: string,
  platform: NodeJS.Platform = process.platform,
): void {
  const violation = socketBoundViolation(home, source, platform);
  if (violation !== undefined) throw new Error(violation);
}

/**
 * Where the suite makes its scratch homes: `/tmp` on every POSIX platform,
 * whose path is short wherever `TMPDIR` points (`os.tmpdir()` is the
 * deep per-user directory on macOS, and a nix shell nests another inside
 * it); `os.tmpdir()` on Windows, which binds no Unix socket.
 */
export function scratchBase(platform: NodeJS.Platform = process.platform): string {
  return platform === "win32" ? os.tmpdir() : "/tmp";
}
