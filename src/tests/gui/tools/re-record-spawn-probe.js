#!/usr/bin/env node
// Re-record spawn probe -- issue #747.
//
// Usage: node src/tests/gui/tools/re-record-spawn-probe.js [<recording-id>]
//        (with no argument it picks the first recording in the local index
//        whose `workdir` no longer exists, which is the interesting case.)
//
// WHY THIS EXISTS
// ---------------
// `Ctrl+R` produced `record start process error: ENOENT` and that message is
// not a diagnosis: `child_process.spawn` answers `ENOENT` for THREE unrelated
// causes and names the EXECUTABLE in `error.path` for all three, including the
// two where the executable is healthy.
//
//   * the executable path does not exist;
//   * `options.cwd` names a directory that does not exist;
//   * the executable is a bare name the effective `PATH` cannot resolve --
//     and `options.env` REPLACES that `PATH` when it is supplied.
//
// This probe replays the spawn `src/frontend/index/traces.nim onNewRecord`
// makes -- `spawn(codetracerExe, ["record", ...args], options)` -- for a real
// recording, with `options` built the way `renderer.launchReRecord` builds it
// (`cwd = Trace.workdir`, `env = buildRecordEnv(Trace.env)`), and shows which
// combination fails. It is a MANUAL diagnostic, not part of any lane: it reads
// the developer's own `trace_index.db` and spawns a real `ct`, which no
// automated suite should do. The DECISIONS it exercises are covered headlessly
// in `../tests/welcome-screen/re_record_queue_vm_test.nim`.
//
// The last block applies the production rule (`file_conflicts.recordLaunchCwd`)
// and re-spawns, so a run shows the before and the after side by side.
const { spawn, execFileSync } = require("child_process");
const fs = require("fs");
const path = require("path");
const os = require("os");

const db = path.join(os.homedir(), ".local", "share", "codetracer", "trace_index.db");
if (!fs.existsSync(db)) {
  console.error("no trace index at " + db);
  process.exit(2);
}

const sql = (query) =>
  execFileSync("sqlite3", [db, query], { maxBuffer: 256 * 1024 * 1024 })
    .toString().replace(/\n$/, "");

function pickRecording() {
  if (process.argv[2]) return process.argv[2];
  // `char(9)` rather than a `\t` escape: sqlite3 has no backslash escapes in
  // string literals, so '\t' would be a two-character literal.
  const rows = sql("select recording_id || char(9) || workdir from recordings;").split("\n");
  for (const row of rows) {
    const [id, workdir] = row.split("\t");
    if (workdir && !fs.existsSync(workdir)) return id;
  }
  console.error("every recording's workdir still exists; pass a recording id explicitly");
  process.exit(3);
}

const id = pickRecording();
const field = (name) =>
  sql(`select ${name} from recordings where recording_id='${id.replace(/'/g, "''")}';`);

const program = field("program");
const workdir = field("workdir");
const envDump = field("env");

// `src/frontend/renderer.nim buildRecordEnv`, verbatim.
function buildRecordEnv(dump) {
  if (!dump) return null;
  const out = {};
  for (const line of dump.split("\n")) {
    const sep = line.indexOf("=");
    if (sep <= 0) continue;
    out[line.slice(0, sep)] = line.slice(sep + 1);
  }
  return out;
}

// The two shapes `common/paths.nim resolveCodetracerExe` can return.
const repoRoot = path.resolve(__dirname, "..", "..", "..", "..");
const ct = process.env.CODETRACER_CT_EXE ||
  path.join(repoRoot, "src", "build-debug-repro", "bin", "ct");

const recEnv = buildRecordEnv(envDump);
const recPath = recEnv && recEnv.PATH ? recEnv.PATH.split(path.delimiter).filter(Boolean) : [];

console.log("recording                :", id);
console.log("codetracerExe            :", ct, "exists=" + fs.existsSync(ct));
console.log("trace.program            :", program, "exists=" + fs.existsSync(program));
console.log("trace.workdir            :", workdir, "exists=" + fs.existsSync(workdir));
console.log("trace.env vars           :", recEnv ? Object.keys(recEnv).length : 0,
            "| recorded PATH dirs still present:",
            recPath.filter((d) => fs.existsSync(d)).length, "of", recPath.length);

function probe(label, exe, options) {
  return new Promise((res) => {
    let child;
    try { child = spawn(exe, ["record", program], options); }
    catch (e) { console.log(label, "-> THROW", e.code, e.message); return res(); }
    child.on("error", (e) => {
      console.log(label, "-> ERROR code=" + e.code + " syscall=" + e.syscall + " path=" + e.path);
      res();
    });
    child.on("spawn", () => {
      console.log(label, "-> SPAWNED (pid " + child.pid + ")");
      child.kill("SIGKILL");
      res();
    });
  });
}

const isDir = (p) => { try { return fs.statSync(p).isDirectory(); } catch { return false; } };

(async () => {
  console.log("\n--- what launchReRecord sends today (cwd = trace.workdir, env = trace.env) ---");
  await probe("A  abs exe + recorded cwd + recorded env", ct,
    { stdio: "ignore", cwd: workdir, env: recEnv || undefined });
  await probe("B  abs exe + recorded cwd, no env       ", ct,
    { stdio: "ignore", cwd: workdir });
  await probe("C  abs exe + live cwd + recorded env    ", ct,
    { stdio: "ignore", cwd: process.cwd(), env: recEnv || undefined });

  console.log("\n--- the same, with `ct` as a bare name (resolveCodetracerExe's fallback) ---");
  await probe("D  bare exe + live cwd, no env          ", "ct",
    { stdio: "ignore", cwd: process.cwd() });
  await probe("E  bare exe + live cwd + recorded env   ", "ct",
    { stdio: "ignore", cwd: process.cwd(), env: recEnv || undefined });

  console.log("\n--- after the M49 rule (file_conflicts.recordLaunchCwd), applied as production applies it ---");
  const facts = { requestedCwd: workdir, requestedCwdUsable: isDir(workdir), fallbackCwd: "" };
  if (!facts.requestedCwdUsable && program) {
    if (isDir(program)) facts.fallbackCwd = program;
    else if (isDir(path.dirname(program))) facts.fallbackCwd = path.dirname(program);
  }
  const resolvedCwd = facts.requestedCwd === "" ? ""
    : facts.requestedCwdUsable ? facts.requestedCwd : facts.fallbackCwd;
  console.log("F  recordLaunchCwd(facts) =", JSON.stringify(resolvedCwd),
              "(fallbackCwd =", JSON.stringify(facts.fallbackCwd) + ")");
  await probe("G  abs exe + that cwd, no env           ", ct,
    { stdio: "ignore", cwd: resolvedCwd === "" ? undefined : resolvedCwd });
})();
