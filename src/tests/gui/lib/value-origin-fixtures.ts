/**
 * M5 — fixture resolution helper for Value Origin Tracking Playwright
 * specs.
 *
 * Each canonical-flow spec under `src/tests/gui/tests/value-origin/`
 * targets one of the M0 fixture programs at
 * `src/db-backend/tests/fixtures/origin/<lang>/<scenario>/`. The
 * `launchMode: "trace"` harness path drives `ct record` on the source
 * program; if the recorder for that language isn't available in this
 * environment, `ct record` exits with a non-zero status and the spec
 * fails loudly. That's the wrong failure mode for environment gaps —
 * spec authors want an honest SKIPPED outcome that pinpoints the
 * missing infrastructure, exactly the way
 * `src/db-backend/tests/origin_python_dap_test.rs::require_python_recorder`
 * handles missing-recorder cases at the M3 layer.
 *
 * This module exposes:
 *
 * - `originFixturePath(lang, scenario)` — absolute path to the
 *   fixture's source program.
 * - `isPythonRecorderAvailable()` /
 *   `isRubyRecorderAvailable()` /
 *   `isJavaScriptRecorderAvailable()` — environment-check helpers the
 *   specs can pass into `test.skip(...)`.
 * - `isCtBinaryAvailable()` — confirms `src/build-debug/bin/ct` exists
 *   and is executable; absent on machines that haven't run
 *   `just build-once` (e.g. the dev container where stylus is missing).
 */
import * as childProcess from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";

/**
 * Repository root, computed relative to this source file so callers
 * don't have to thread the path through `test.use()`.
 */
const repoRoot = path.resolve(__dirname, "..", "..", "..", "..");

/** Directory holding the M0 fixture catalogue. */
const fixtureRoot = path.join(
  repoRoot,
  "src",
  "db-backend",
  "tests",
  "fixtures",
  "origin",
);

/**
 * Absolute path to the fixture's source program, e.g.
 * `<repo>/src/db-backend/tests/fixtures/origin/python/simple_trivial_chain/main.py`.
 */
export function originFixturePath(
  language: "python" | "ruby" | "javascript" | "rust" | "c" | "cpp" | "nim" | "go" | "d",
  scenario: string,
): string {
  const fileName = (() => {
    switch (language) {
      case "python":
        return "main.py";
      case "ruby":
        return "main.rb";
      case "javascript":
        return "main.js";
      case "rust":
        return "main.rs";
      case "c":
        return "main.c";
      case "cpp":
        return "main.cpp";
      case "nim":
        return "main.nim";
      case "go":
        return "main.go";
      case "d":
        return "main.d";
    }
  })();
  return path.join(fixtureRoot, language, scenario, fileName);
}

/**
 * Path to the codetracer `ct` binary produced by `just build-once`.
 * The Playwright harness uses this binary via `launchTraceElectron`;
 * if it's missing the launch path will throw at module-load time and
 * the failure mode is opaque. Pre-checking lets the spec emit a
 * skip-with-reason.
 */
export function ctBinaryPath(): string {
  return path.join(repoRoot, "src", "build-debug", "bin", "ct");
}

export function isCtBinaryAvailable(): boolean {
  const p = ctBinaryPath();
  try {
    fs.accessSync(p, fs.constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

/**
 * Probe whether `ct record <source>` is likely to succeed for the
 * given language. Returns null when the prerequisites are met, or a
 * human-readable reason string when not.
 *
 * The probes intentionally mirror what
 * `src/db-backend/tests/test_harness/mod.rs::find_python_recorder` /
 * `find_ruby_recorder` / `find_js_recorder` already check on the
 * Rust side so the M3 and M5 layers SKIP for the same reasons in the
 * same environments.
 */
export function pythonRecorderUnavailableReason(): string | null {
  // The Rust-backed recorder is what `ct record` uses for Python on
  // the M3 path; it lives as a Python module installable into the
  // active interpreter. We probe by trying `python3 -c "import
  // codetracer_python_recorder"` — same heuristic as `find_python_recorder`.
  const r = childProcess.spawnSync("python3", ["-c", "import codetracer_python_recorder"], {
    encoding: "utf-8",
    timeout: 5_000,
    windowsHide: true,
  });
  if (r.status === 0) {
    return null;
  }
  return "codetracer_python_recorder module not importable from python3 " +
    "(install codetracer-python-recorder or activate the .python-recorder-venv shell)";
}

/**
 * Mirror of `test_harness::find_on_path` — returns the resolved path
 * to `binary` if it's on PATH, else null.
 */
function findOnPath(binary: string): string | null {
  const r = childProcess.spawnSync("sh", ["-c", `command -v ${binary} 2>/dev/null`], {
    encoding: "utf-8",
    timeout: 5_000,
    windowsHide: true,
  });
  if (r.status !== 0) return null;
  const trimmed = (r.stdout ?? "").trim();
  return trimmed.length > 0 ? trimmed : null;
}

/**
 * Conservative recorder probes for Ruby + JavaScript.
 *
 * Why "on PATH only": the Rust-side `test_harness::find_*_recorder`
 * helpers also accept sibling-repo paths, but the production `ct
 * record` dispatcher in this repo only invokes the recorder when it's
 * properly registered on `PATH` (or via an env var that the user has
 * already configured). When the sibling repo exists but isn't wired
 * into `ct`'s search path, `ct record` hangs waiting for the recorder
 * to start — a confusing timeout failure mode that's clearly an
 * environment gap, not a feature bug. Detecting it precisely is hard;
 * we err on the side of SKIPPING the spec with an honest reason
 * rather than letting `ct record` time out at 30s.
 */
export function rubyRecorderUnavailableReason(): string | null {
  const ruby = childProcess.spawnSync("ruby", ["--version"], {
    encoding: "utf-8",
    timeout: 5_000,
    windowsHide: true,
  });
  if (ruby.status !== 0) {
    return "ruby is not available on PATH";
  }
  const env = process.env.CODETRACER_RUBY_RECORDER_PATH;
  if (env && fs.existsSync(env)) {
    return null;
  }
  if (findOnPath("codetracer-ruby-recorder") !== null) {
    return null;
  }
  return "codetracer-ruby-recorder not on PATH " +
    "(set CODETRACER_RUBY_RECORDER_PATH or install the recorder gem so `ct record` can dispatch to it)";
}

export function javascriptRecorderUnavailableReason(): string | null {
  const node = childProcess.spawnSync("node", ["--version"], {
    encoding: "utf-8",
    timeout: 5_000,
    windowsHide: true,
  });
  if (node.status !== 0) {
    return "node is not available on PATH";
  }
  const env = process.env.CODETRACER_JS_RECORDER_PATH;
  if (env && fs.existsSync(env)) {
    return null;
  }
  if (findOnPath("codetracer-js-recorder") !== null) {
    return null;
  }
  return "codetracer-js-recorder not on PATH " +
    "(set CODETRACER_JS_RECORDER_PATH or install the recorder so `ct record` can dispatch to it)";
}

/**
 * Aggregate availability check for a Python spec. Returns the skip
 * reason when any prerequisite is missing — pass the result into
 * `test.skip(!!reason, reason)` at the top of the spec.
 */
export function pythonSpecSkipReason(): string | null {
  if (!isCtBinaryAvailable()) {
    return "ct binary missing at " + ctBinaryPath() +
      " — run `just build-once` to produce the Electron build the M5 specs drive";
  }
  return pythonRecorderUnavailableReason();
}

export function rubySpecSkipReason(): string | null {
  if (!isCtBinaryAvailable()) {
    return "ct binary missing at " + ctBinaryPath() +
      " — run `just build-once` to produce the Electron build the M5 specs drive";
  }
  return rubyRecorderUnavailableReason();
}

export function javascriptSpecSkipReason(): string | null {
  if (!isCtBinaryAvailable()) {
    return "ct binary missing at " + ctBinaryPath() +
      " — run `just build-once` to produce the Electron build the M5 specs drive";
  }
  return javascriptRecorderUnavailableReason();
}

/**
 * M11 — RR-backed origin specs (Rust + C + C++ + Nim + Go).
 *
 * The native-backend pipeline drives `rr` for record/replay and
 * `ct-native-replay` (formerly `ct-rr-support`) as the worker that
 * bridges to db-backend. The GUI launches a recorded RR trace via
 * `launchMode: "trace"`, so the spec needs the full toolchain present
 * when it asks the harness to record on demand.
 *
 * The probe checks:
 *
 *   - `ct` binary built (mirrors the other languages).
 *   - `rr` on PATH.
 *   - `ct-native-replay` on PATH.
 *   - Per-language compiler on PATH.
 *
 * Returns null when all probes pass; otherwise returns a human-readable
 * sentinel that the spec emits via `test.skip(!!reason, reason)`.
 */
export function rrToolchainUnavailableReason(): string | null {
  if (findOnPath("rr") === null) {
    return "rr binary not on PATH (install rr to run RR-backed origin tests)";
  }
  if (findOnPath("ct-native-replay") === null && findOnPath("ct-rr-support") === null) {
    return "ct-native-replay not on PATH (M11 RR specs need the native-backend replay worker)";
  }
  return null;
}

export function rustRrSpecSkipReason(): string | null {
  if (!isCtBinaryAvailable()) {
    return "ct binary missing at " + ctBinaryPath() +
      " — run `just build-once` to produce the Electron build the M11 specs drive";
  }
  const tc = rrToolchainUnavailableReason();
  if (tc !== null) return tc;
  if (findOnPath("rustc") === null) {
    return "rustc not on PATH (M11 Rust RR spec needs the Rust compiler)";
  }
  return null;
}

export function cRrSpecSkipReason(): string | null {
  if (!isCtBinaryAvailable()) {
    return "ct binary missing at " + ctBinaryPath() +
      " — run `just build-once` to produce the Electron build the M11 specs drive";
  }
  const tc = rrToolchainUnavailableReason();
  if (tc !== null) return tc;
  if (findOnPath("gcc") === null) {
    return "gcc not on PATH (M11 C RR spec needs a C compiler)";
  }
  return null;
}

/**
 * TCT-M5 — cross-tracer three-recording fixture probe.
 *
 * The `account-balance-with-wasm/` fixture under
 * `src/db-backend/tests/fixtures/cross_process/` ships sources + a
 * `session.toml.template` but **no** materialised `.ct` containers
 * (`frontend.ct` / `frontend-wasm.ct` / `backend.ct`). Materialisation
 * goes through `regenerate.sh` which is honestly gated on
 * `wasm-pack` + the wasm32 rustup target + `codetracer-js-recorder` +
 * `codetracer-python-recorder` + `browser_stream_receiver` + Playwright.
 *
 * The GUI E2E spec MUST skip cleanly with a precise sentinel — mirror
 * of the headless-DAP test pattern at
 * `src/db-backend/tests/cross_process_origin_test.rs::test_origin_three_trace_chain_balance_to_frontend_expression`.
 * Returning null means all three containers are on disk + `ct` is
 * built; otherwise the returned string is the test.skip() reason.
 */
export function threeTraceFixtureRoot(): string {
  return path.join(
    repoRoot,
    "src",
    "db-backend",
    "tests",
    "fixtures",
    "cross_process",
    "account-balance-with-wasm",
  );
}

export function threeTraceFixtureSkipReason(): string | null {
  if (!isCtBinaryAvailable()) {
    return "ct binary missing at " + ctBinaryPath() +
      " — run `just build-once` to produce the Electron build the M5 specs drive";
  }
  const root = threeTraceFixtureRoot();
  for (const name of ["frontend.ct", "frontend-wasm.ct", "backend.ct"]) {
    const candidate = path.join(root, name);
    if (!fs.existsSync(candidate)) {
      return "SKIPPED: account-balance-with-wasm fixture not materialized: " +
        candidate +
        " (regenerate.sh requires wasm-pack + rustup target add " +
        "wasm32-unknown-unknown + codetracer-js-recorder + " +
        "codetracer-python-recorder)";
    }
  }
  if (!fs.existsSync(path.join(root, "session.toml.template"))) {
    return "session.toml.template missing under " + root;
  }
  return null;
}
