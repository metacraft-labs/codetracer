/**
 * Record a tiny JavaScript program with the `codetracer-js-recorder` sibling
 * and hand back a trace folder the `trace-folder` launch mode can open.
 *
 * Specs that only need "a real trace, any real trace" — status-bar contracts,
 * renderer-stability checks, console-cleanliness checks — should not each
 * carry their own copy of the recorder discovery and the record/rename dance.
 * The JavaScript recorder is the cheapest real recorder in the dev shell (no
 * virtualenv, no native extension), which is why it is the one used here.
 *
 * No mocks: this shells out to the real recorder and the resulting container
 * is opened by the real Electron app.
 */
import * as childProcess from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

const repoRoot = path.resolve(__dirname, "../../../..");

/**
 * Locate the JavaScript recorder CLI.
 *
 * `CODETRACER_JS_RECORDER_PATH` wins when set (that is what
 * `scripts/detect-siblings.sh` exports); otherwise fall back to the sibling
 * checkout's built CLI.
 */
export function findJsRecorder(): string {
  const fromEnv = process.env.CODETRACER_JS_RECORDER_PATH;
  if (fromEnv && fs.existsSync(fromEnv)) return fromEnv;
  const candidate = path.resolve(
    repoRoot,
    "..",
    "codetracer-js-recorder",
    "packages",
    "cli",
    "dist",
    "index.js",
  );
  if (fs.existsSync(candidate)) return candidate;
  throw new Error(
    "codetracer-js-recorder not found; set CODETRACER_JS_RECORDER_PATH or " +
      "build the sibling repo (npm run build).",
  );
}

export interface JsTraceFixture {
  /** Folder holding the recorded `.ct` container — pass as `sourcePath`. */
  traceDir: string;
  /** The recorded source file on disk. */
  sourcePath: string;
}

/**
 * Record `program` as `program.js` under a per-process temp directory named
 * after `name`, and return the resulting trace folder.
 *
 * Throws — rather than returning a sentinel — when the recorder is missing or
 * fails, so a spec that depends on a real recording fails loudly instead of
 * quietly testing nothing.
 */
export function recordJsTraceFixture(
  name: string,
  program: string,
): JsTraceFixture {
  const fixtureDir = path.join(os.tmpdir(), `ct-${name}-${process.pid}`);
  if (fs.existsSync(fixtureDir)) {
    fs.rmSync(fixtureDir, { recursive: true, force: true });
  }
  fs.mkdirSync(fixtureDir, { recursive: true });

  const sourcePath = path.join(fixtureDir, "program.js");
  fs.writeFileSync(sourcePath, program);

  const recorderOut = path.join(fixtureDir, "rec-out");
  fs.mkdirSync(recorderOut, { recursive: true });
  const result = childProcess.spawnSync(
    "node",
    [findJsRecorder(), "record", sourcePath, "--out-dir", recorderOut],
    { encoding: "utf-8", timeout: 60_000 },
  );
  if (result.status !== 0) {
    throw new Error(
      `JS recorder failed: status=${result.status}\n` +
        `stdout:\n${result.stdout}\nstderr:\n${result.stderr}`,
    );
  }

  const traceSubdir = fs
    .readdirSync(recorderOut, { withFileTypes: true })
    .find((e) => e.isDirectory() && e.name.startsWith("trace-"));
  if (!traceSubdir) {
    throw new Error(`recorder produced no trace-* dir under ${recorderOut}`);
  }

  const traceDir = path.join(fixtureDir, "trace");
  fs.renameSync(path.join(recorderOut, traceSubdir.name), traceDir);
  return { traceDir, sourcePath };
}

/**
 * A few statements over three lines — enough for the app to open a trace,
 * mount an editor, and populate the status bar, and nothing more.
 */
const CHROME_FIXTURE_PROGRAM =
  "var a = 1;\nvar b = a + 1;\nconsole.log(a, b);\n";

/**
 * Record the standard "any real trace will do" fixture.
 *
 * Specs about the app's *chrome* — the auto-hide strips, the docked panels
 * and the slide-in overlay, the BUILD / PROBLEMS / SEARCH RESULTS panes, the
 * status bar — assert on DOM that `ui/layout.nim` and `ui/auto_hide.nim`
 * build identically for every recorded language.  Pinning them to a Python
 * program made them silently unrunnable wherever the Python recorder is not
 * installed (`codetracer_python_recorder` is a PyO3/maturin extension, not a
 * pure-Python package), which is how eight of them went unexecuted long
 * enough to accumulate a suite-wide dead selector and a retired click
 * contract.  The JavaScript recorder is the cheapest real recorder in the dev
 * shell — no virtualenv, no native extension — so these specs record through
 * it and stay runnable by default.
 *
 * This is not a reduction in language coverage: Python trace-open coverage
 * lives in the specs that are actually *about* Python (`tests/languages/**`,
 * `tests/integration/real_backend.nim`) and in the other `py_console_logs`
 * users, none of which this helper touches.
 */
export function recordChromeTraceFixture(name: string): JsTraceFixture {
  return recordJsTraceFixture(name, CHROME_FIXTURE_PROGRAM);
}
