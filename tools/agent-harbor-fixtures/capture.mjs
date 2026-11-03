#!/usr/bin/env node
// Captures the data the Agent Harbor front-end prototypes are built over, and
// writes it, scrubbed, as the PRIVATE fixture set that nim-agents-isonim-
// viewmodels' `FixtureDataSource` embeds when a build can see it (and
// through it, CodeTracer's StoryBook).
//
//   node tools/agent-harbor-fixtures/capture.mjs [--out <dir>] [--raw <dir>]
//        [--sources <file>] [--only fleet,plans,diffs,tests,scenarios]
//        [--workspace <dir>]
//
// Captured data is never written into a public repository. The default
// output is the private fixture directory beside this checkout
// (../codetracer-pm/design/agent-harbor-front-end/fixtures), and so is the
// default sources file (capture-sources.json beside it), which names the
// plans, branches, test workspaces, scenario files and the Agent Harbor
// binaries a capture uses. Public repositories carry only the synthetic set
// (synthesize.mjs); the scrub check fails if a captured file reaches one.
//
// Normally run through `just capture-agent-harbor-fixtures`, which also runs
// the scrub check and its self-test.
//
// Parts (sources.json says which plans, branches, test workspaces and
// scenario files):
//
//   fleet      a READ-ONLY snapshot of the Agent Harbor server the local `ah`
//              CLI is configured with: every page of `GET /api/v1/sessions`,
//              `GET /api/v1/sessions/{id}/events/history` and `/info` for a
//              bounded selection of sessions, and a replay of
//              `GET /api/v1/session-lifecycle/events`. `hubGet` is the only
//              function that talks to that server, and it issues GET only.
//   plans      the milestone plans of running campaigns, verbatim.
//   diffs      `git diff <merge-base> <head>` of real branches.
//   tests      `ct test run --events` over real test workspaces, kept both as
//              the runner's own events and mapped to the test-run event shape
//              Agent Harbor's front-ends consume; plus a real `ct record`
//              trace, referenced from the run.
//   scenarios  agents driven by Agent Harbor scenario files: the scenario
//              played by Agent Harbor's mock REST server (what a front-end
//              reads over REST), and the same scenario run by the mock ACP
//              agent (what the agent itself emits). Both are local processes
//              this capture starts and stops.
//
// Everything the fleet part reads is scrubbed (lib/scrub.mjs) before it is
// written. The raw prompt strings are kept in the raw directory, OUTSIDE the
// repositories, so the scrub check can prove none reached a fixture.

import { createHash } from "node:crypto";
import { spawn, spawnSync } from "node:child_process";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { basename, dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { captureServer } from "./lib/ah-config.mjs";
import { createScrubber, promptStrings } from "./lib/scrub.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, "../..");

function argValue(name) {
  const i = process.argv.indexOf(name);
  return i >= 0 ? process.argv[i + 1] ?? null : null;
}

const workspaceRoot = resolve(argValue("--workspace") ?? resolve(repoRoot, ".."));
const privateDesignDir = join(workspaceRoot, "codetracer-pm/design/agent-harbor-front-end");
const outDir = resolve(argValue("--out") ?? join(privateDesignDir, "fixtures"));
const rawDir = resolve(
  argValue("--raw") ??
    join(process.env.XDG_RUNTIME_DIR || tmpdir(), `codetracer-agent-harbor-capture-${process.getuid?.() ?? "user"}`),
);
const allParts = ["fleet", "plans", "diffs", "tests", "scenarios"];
const parts = (argValue("--only") ?? allParts.join(","))
  .split(",")
  .map((p) => p.trim())
  .filter(Boolean);
for (const part of parts) {
  if (!allParts.includes(part)) throw new Error(`unknown part '${part}' (known: ${allParts.join(", ")})`);
}
const sourcesPath = resolve(argValue("--sources") ?? join(privateDesignDir, "capture-sources.json"));
if (!existsSync(sourcesPath)) {
  throw new Error(`no capture sources at ${sourcesPath}; a capture needs the private design directory (or --sources)`);
}
const sources = JSON.parse(readFileSync(sourcesPath, "utf8"));

// The fleet part's scrubber, once it has run: later parts reuse it so a host or
// executor gets the same alias in every fixture (a plan naming a host the
// fleet lists says `host-a` where the fleet does).
let sharedScrub = null;
const scrubber = () => sharedScrub ?? createScrubber();

function log(message) {
  console.log(`capture-agent-harbor-fixtures: ${message}`);
}

function writeOut(path, content) {
  const full = join(outDir, path);
  mkdirSync(dirname(full), { recursive: true });
  writeFileSync(full, content);
  return path;
}

function writeRaw(path, content) {
  const full = join(rawDir, path);
  mkdirSync(dirname(full), { recursive: true });
  writeFileSync(full, content, { mode: 0o600 });
}

function json(value) {
  return `${JSON.stringify(value, null, 2)}\n`;
}

// ---------------------------------------------------------------------------
// fleet: read-only snapshot of the configured Agent Harbor server
// ---------------------------------------------------------------------------

function makeHubGet(server) {
  const headers = { Accept: "application/json" };
  if (server.apiKey) headers.Authorization = `ApiKey ${server.apiKey}`;
  const base = server.url.replace(/\/+$/, "");
  /** The ONLY request this capture sends to the fleet server: a GET. */
  return async function hubGet(path, { accept = "application/json", timeoutMs = 30000, untilFrame } = {}) {
    if (!path.startsWith("/api/v1/")) throw new Error(`refusing a non-API path ${path}`);
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    try {
      const response = await fetch(base + path, {
        method: "GET",
        headers: { ...headers, Accept: accept },
        signal: controller.signal,
      });
      if (!response.ok) throw new Error(`GET ${path}: HTTP ${response.status}`);
      if (accept !== "text/event-stream") return await response.json();
      // An SSE stream does not end; read until `untilFrame` says so or the
      // timeout aborts, and keep what arrived.
      let text = "";
      const decoder = new TextDecoder();
      try {
        for await (const chunk of response.body) {
          text += decoder.decode(chunk, { stream: true });
          if (untilFrame && untilFrame(text)) break;
        }
      } catch (error) {
        if (error.name !== "AbortError") throw error;
      }
      controller.abort();
      return text;
    } finally {
      clearTimeout(timer);
    }
  };
}

function selectEventSessions(items, policy) {
  const active = new Set(["queued", "provisioning", "running", "pausing", "paused", "resuming", "stopping"]);
  const chosen = [];
  const add = (item) => {
    if (!chosen.includes(item.id) && chosen.length < policy.max) chosen.push(item.id);
  };
  if (policy.allActive) items.filter((i) => active.has(i.status)).forEach(add);
  if (policy.allFailed) items.filter((i) => i.status === "failed" || i.status === "cancelled").forEach(add);
  items
    .filter((i) => !active.has(i.status) && i.status !== "failed" && i.status !== "cancelled")
    .slice(0, policy.newestEnded)
    .forEach(add);
  return chosen;
}

/**
 * What a person calls each session that runs on THIS host, read without
 * touching the hub: an agent session's processes name its id on their
 * command line, and the terminal-multiplexer pane it runs in names it (the
 * window) and its workspace (the pane's directory, and that checkout's
 * branch). The hub withholds prompt, workspace and branch from a caller
 * outside a session's scope, so without this every row would read alike.
 * Returns `{ <session id>: { name, workspace, branch, initiative, source } }`
 * for the ids in `wanted`; sessions on other hosts are not reachable here.
 */
function localSessionLabels(wanted) {
  const labels = {};
  const tmux = spawnSync("tmux", ["list-panes", "-a", "-F", "#{pane_pid}\t#{window_name}\t#{pane_current_path}"], { encoding: "utf8" });
  if (tmux.status !== 0) return labels;
  const panes = new Map();
  for (const line of tmux.stdout.split("\n")) {
    const [pid, windowName, path] = line.split("\t");
    if (pid) panes.set(Number(pid), { windowName, path });
  }
  const parentOf = (pid) => {
    try {
      const stat = readFileSync(`/proc/${pid}/stat`, "utf8");
      return Number(stat.slice(stat.lastIndexOf(")") + 2).split(" ")[1]);
    } catch {
      return 0;
    }
  };
  const idRe = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/g;
  let procs = [];
  try {
    procs = readdirSync("/proc").filter((p) => /^\d+$/.test(p));
  } catch {
    return labels;
  }
  for (const p of procs) {
    let cmdline = "";
    try {
      cmdline = readFileSync(`/proc/${p}/cmdline`, "utf8").replace(/\0/g, " ");
    } catch {
      continue;
    }
    for (const id of new Set(cmdline.match(idRe) ?? [])) {
      if (!wanted.has(id) || labels[id]) continue;
      for (let pid = Number(p), hops = 0; pid > 1 && hops < 32; pid = parentOf(pid), hops++) {
        const pane = panes.get(pid);
        if (!pane) continue;
        let branch = "";
        const head = spawnSync("git", ["-C", pane.path, "branch", "--show-current"], { encoding: "utf8" });
        if (head.status === 0) branch = head.stdout.trim();
        labels[id] = {
          name: pane.windowName,
          workspace: basename(pane.path),
          branch,
          initiative: "",
          source: "the terminal window the session runs in",
        };
        break;
      }
    }
  }
  return labels;
}

async function captureFleet(manifest) {
  const server = captureServer();
  const hubGet = makeHubGet(server);
  const capturedAt = new Date().toISOString();
  log(`fleet: reading ${server.name} (GET only)`);

  const items = [];
  let total = 0;
  let next = `/api/v1/sessions?perPage=${sources.fleet.pageSize}`;
  for (let page = 0; next && page < 50; page++) {
    const body = await hubGet(next);
    items.push(...(body.items ?? []));
    total = body.total ?? items.length;
    next = body.nextPage ? (body.nextPage.startsWith("/api/") ? body.nextPage : `/api/v1/${body.nextPage.replace(/^\/+/, "")}`) : null;
  }
  log(`fleet: ${items.length} of ${total} sessions listed`);

  const eventIds = selectEventSessions(items, sources.fleet.eventSessions);
  const histories = {};
  const infos = {};
  for (const id of eventIds) {
    histories[id] = await hubGet(`/api/v1/sessions/${encodeURIComponent(id)}/events/history?limit=200`);
    try {
      infos[id] = await hubGet(`/api/v1/sessions/${encodeURIComponent(id)}/info`);
    } catch (error) {
      infos[id] = { error: String(error.message ?? error) };
    }
  }
  log(`fleet: event histories of ${eventIds.length} sessions`);

  // The lifecycle feed resumes after a cursor `<epoch>-<seq>`. Without one it
  // answers `resync` naming the current epoch; resuming at `<epoch>-0`
  // replays the journal it still holds, then says `caught_up`.
  const first = await hubGet("/api/v1/session-lifecycle/events", {
    accept: "text/event-stream",
    timeoutMs: 5000,
    untilFrame: (t) => /\n\n/.test(t),
  });
  const cursorMatch = /"cursor"\s*:\s*"([^"]+)"/.exec(first);
  let lifecycle = first;
  if (cursorMatch) {
    const epoch = cursorMatch[1].replace(/-\d+$/, "");
    lifecycle = await hubGet(`/api/v1/session-lifecycle/events?after=${encodeURIComponent(`${epoch}-0`)}`, {
      accept: "text/event-stream",
      timeoutMs: sources.fleet.lifecycleSeconds * 1000,
      untilFrame: (t) => /event:\s*caught_up[^\n]*\n(?:[^\n]+\n)*\n/.test(t),
    });
  }

  // Raw copies stay outside the repositories (mode 0600), for the check.
  mkdirSync(rawDir, { recursive: true, mode: 0o700 });
  chmodSync(rawDir, 0o700);
  writeRaw("private-strings.json", json(promptStrings(items, Object.values(histories))));

  const hostnames = new Set();
  for (const item of items) if (item.workspace?.host) hostnames.add(item.workspace.host);
  for (const info of Object.values(infos)) {
    if (info?.fleet?.leader) hostnames.add(info.fleet.leader);
    for (const f of info?.fleet?.followers ?? []) hostnames.add(f);
  }
  try {
    const url = new URL(server.url);
    hostnames.add(url.hostname);
    hostnames.add(url.hostname.split(".")[0]);
  } catch {
    // keep going: the patterns still catch LAN names
  }
  const privateStrings = promptStrings(items, Object.values(histories));
  const scrub = createScrubber({
    secrets: server.apiKey ? [server.apiKey] : [],
    hostnames: [...hostnames],
    privateStrings,
  });
  sharedScrub = scrub;

  rmSync(join(outDir, "fleet"), { recursive: true, force: true });
  const fleet = {
    label: `fleet snapshot, ${capturedAt.slice(0, 16).replace("T", " ")} UTC`,
    capturedAt,
    sessions: writeOut("fleet/sessions.json", json({ items: items.map(scrub.session), total, nextPage: null })),
    lifecycle: writeOut("fleet/lifecycle.sse", scrub.lifecycleSse(lifecycle)),
    events: {},
    info: {},
  };
  const labels = localSessionLabels(new Set(items.map((i) => i.id)));
  const scrubbedLabels = {};
  for (const [id, label] of Object.entries(labels)) {
    scrubbedLabels[id] = Object.fromEntries(Object.entries(label).map(([k, v]) => [k, scrub.text(v)]));
  }
  fleet.labels = writeOut("fleet/labels.json", json(scrubbedLabels));
  log(`fleet: human labels for ${Object.keys(labels).length} session(s) running on this host`);
  for (const id of eventIds) {
    fleet.events[id] = writeOut(`fleet/events/${id}.json`, json(scrub.eventHistory(histories[id])));
    fleet.info[id] = writeOut(`fleet/info/${id}.json`, json(scrub.sessionInfo(infos[id])));
  }
  manifest.capturedAt = capturedAt;
  manifest.fleet = fleet;
  manifest.scrub = { ...scrub.stats, aliases: scrub.aliases() };
  log(`fleet: scrubbed (${JSON.stringify(manifest.scrub)})`);
}

// ---------------------------------------------------------------------------
// plans
// ---------------------------------------------------------------------------

function findPlan(fileName) {
  for (const repo of readdirSync(workspaceRoot)) {
    for (const sub of ["milestones", "Planned-Work", "docs"]) {
      const candidate = join(workspaceRoot, repo, sub, fileName);
      if (existsSync(candidate)) return candidate;
    }
  }
  return null;
}

function capturePlans(manifest) {
  rmSync(join(outDir, "plans"), { recursive: true, force: true });
  manifest.plans = [];
  for (const plan of sources.plans) {
    const path = plan.path ? join(workspaceRoot, plan.path) : findPlan(plan.fileName);
    if (!path || !existsSync(path)) throw new Error(`plan ${plan.name}: not found in ${workspaceRoot}`);
    const text = readFileSync(path, "utf8");
    manifest.plans.push({
      name: plan.name,
      campaign: plan.campaign,
      visibility: plan.visibility,
      revision: gitRevisionOf(path),
      file: writeOut(`plans/${plan.name}`, scrubber().text(text)),
    });
  }
  log(`plans: ${manifest.plans.length}`);
}

function git(cwd, args) {
  const result = spawnSync("git", ["-C", cwd, ...args], { encoding: "utf8", maxBuffer: 256 * 1024 * 1024 });
  if (result.status !== 0) throw new Error(`git -C ${cwd} ${args.join(" ")}: ${result.stderr.trim()}`);
  return result.stdout;
}

function gitRevisionOf(path) {
  try {
    return git(dirname(path), ["log", "-1", "--format=%h", "--", basename(path)]).trim();
  } catch {
    return "";
  }
}

// ---------------------------------------------------------------------------
// diffs
// ---------------------------------------------------------------------------

function captureDiffs(manifest) {
  rmSync(join(outDir, "diffs"), { recursive: true, force: true });
  manifest.diffs = [];
  const scrub = scrubber();
  for (const d of sources.diffs) {
    const repo = join(workspaceRoot, d.repository);
    const head = git(repo, ["rev-parse", d.head]).trim();
    const base = git(repo, ["merge-base", d.base, head]).trim();
    const stat = git(repo, ["diff", "--shortstat", base, head]);
    const num = (re) => Number((re.exec(stat) ?? [0, 0])[1]);
    manifest.diffs.push({
      name: d.name,
      repository: d.repository,
      baseRef: d.base,
      headRef: d.head.replace(/^origin\//, ""),
      baseCommit: base.slice(0, 12),
      headCommit: head.slice(0, 12),
      filesChanged: num(/(\d+) files? changed/),
      insertions: num(/(\d+) insertions?/),
      deletions: num(/(\d+) deletions?/),
      file: writeOut(`diffs/${d.name}.diff`, scrub.text(git(repo, ["diff", "--no-color", base, head]))),
    });
  }
  log(`diffs: ${manifest.diffs.length}`);
}

// ---------------------------------------------------------------------------
// tests: ct test run --events, and a real ct record trace
// ---------------------------------------------------------------------------

function ctBinary() {
  const candidates = [
    process.env.CODETRACER_CT_BIN,
    process.env.CODETRACER_BUILD_DIR && join(process.env.CODETRACER_BUILD_DIR, "bin/ct"),
    join(repoRoot, "src/build-debug-repro/bin/ct"),
    join(repoRoot, "src/build-debug/bin/ct"),
  ].filter(Boolean);
  const found = candidates.find((c) => existsSync(c));
  if (!found) throw new Error(`no ct binary (tried ${candidates.join(", ")}); run \`just build-once\` first`);
  return found;
}

/**
 * Maps one `ct test` event (src/ct_test/contracts.nim `TestEvent`) to the
 * test-run event shape Agent Harbor's front-ends consume: kinds `run-started`,
 * `test-started`, `output`, `failure`, `test-finished`, `trace-started`,
 * `trace-created`, `run-finished`, `diagnostic`, each carrying `testRunId`,
 * `platform` and `backend`. Kinds with no counterpart (discovery, an explicit
 * cancellation) become `diagnostic`, so no event is dropped silently.
 */
function toTestRunEvent(event, ctx) {
  const common = { testRunId: ctx.testRunId, platform: ctx.platform, backend: ctx.backend, runner: "ct" };
  const testId = event.testId ? `ct/${event.testId}` : undefined;
  switch (event.kind) {
    case "run-started":
      return { kind: "run-started", ...common };
    case "test-started":
      return { kind: "test-started", ...common, testId };
    case "output":
      return { kind: "output", ...common, testId, stream: "stdout", text: event.output || event.message || "" };
    case "failure":
      return { kind: "failure", ...common, testId, message: event.message ?? "", location: event.location ?? null };
    case "test-finished":
      return {
        kind: "test-finished",
        ...common,
        testId,
        status: event.status ?? "errored",
        durationMs: event.durationMs ?? null,
        reused: false,
      };
    case "record-started":
      return { kind: "trace-started", ...common, testId, recorder: event.trace?.backend || event.recorder || "ct" };
    case "recording-created":
      {
        const id = event.trace?.recordingId || event.trace?.traceId || event.recordingId;
        return { kind: "trace-created", ...common, testId, trace: id ? `agent-harbor://trace/${id}` : null };
      }
    case "run-finished":
      return { kind: "run-finished", ...common, totals: event.totals ?? null };
    default:
      return { kind: "diagnostic", ...common, testId, message: `${event.kind}${event.message ? `: ${event.message}` : ""}` };
  }
}

function captureTests(manifest) {
  const ct = ctBinary();
  const home = mkdtempSync(join(tmpdir(), "ct-fixture-home-"));
  rmSync(join(outDir, "tests"), { recursive: true, force: true });
  manifest.testRuns = [];
  const scrub = scrubber();
  const env = { ...process.env, CODETRACER_HOME: home };
  try {
    const traces = {};
    for (const t of sources.traces ?? []) {
      const out = join(home, `trace-${t.name}`);
      const result = spawnSync(ct, ["record", "-o", out, join(workspaceRoot, t.program)], { env, encoding: "utf8" });
      if (result.status !== 0) throw new Error(`ct record ${t.program}: ${result.stderr || result.stdout}`);
      const idMatch = /recordingId:\s*(\S+)/.exec(result.stdout + result.stderr);
      const traceId = idMatch ? idMatch[1] : basename(out);
      traces[t.forTest] = { name: t.name, traceId, program: t.program };
      log(`tests: recorded ${t.program} as ${traceId}`);
    }
    for (const t of sources.tests) {
      const eventsPath = join(home, `${t.name}.events.jsonl`);
      const result = spawnSync(
        ct,
        ["test", "run", "--workspace", join(workspaceRoot, t.workspace), "--events", eventsPath, "--no-certificate"],
        { env, encoding: "utf8" },
      );
      // 0: all passed, 1: some failed -- both are real runs worth keeping.
      if (result.status !== 0 && result.status !== 1) {
        throw new Error(`ct test run ${t.workspace} exited ${result.status}: ${result.stderr || result.stdout}`);
      }
      const runnerText = readFileSync(eventsPath, "utf8");
      const runnerEvents = runnerText
        .split("\n")
        .filter((l) => l.trim())
        .map((l) => JSON.parse(l));
      const ctx = { testRunId: `fixture-${t.name}`, platform: t.platform, backend: "local-ct" };
      const mapped = [];
      if (!runnerEvents.some((e) => e.kind === "run-started")) mapped.push(toTestRunEvent({ kind: "run-started" }, ctx));
      for (const e of runnerEvents) mapped.push(toTestRunEvent(e, ctx));
      const trace = traces[t.name];
      if (trace) {
        const firstTest = runnerEvents.find((e) => e.kind === "test-finished");
        const testId = firstTest?.testId;
        mapped.push(toTestRunEvent({ kind: "record-started", testId, recorder: "ct" }, ctx));
        mapped.push(toTestRunEvent({ kind: "recording-created", testId, recordingId: trace.traceId }, ctx));
      }
      if (!runnerEvents.some((e) => e.kind === "run-finished")) {
        const finished = mapped.filter((e) => e.kind === "test-finished");
        const totals = {};
        for (const e of finished) totals[e.status] = (totals[e.status] ?? 0) + 1;
        mapped.push(toTestRunEvent({ kind: "run-finished", totals }, ctx));
      }
      manifest.testRuns.push({
        name: t.name,
        description: t.description,
        exitStatus: result.status,
        trace: trace ? { name: trace.name, program: trace.program, reference: `agent-harbor://trace/${trace.traceId}` } : null,
        runnerEvents: writeOut(`tests/${t.name}.ct-events.jsonl`, scrub.text(runnerText)),
        testRunEvents: writeOut(`tests/${t.name}.test-run-events.json`, scrub.text(json(mapped))),
      });
      log(`tests: ${t.name}: ${runnerEvents.length} events, exit ${result.status}`);
    }
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
}

// ---------------------------------------------------------------------------
// scenarios: Agent Harbor's mock REST server and mock ACP agent
// ---------------------------------------------------------------------------

function agentHarborBin(role) {
  // `role` is `mockServer` or `mockAgent`; capture-sources.json names the
  // binary and how to build it in the Agent Harbor checkout.
  const spec = sources.agentHarbor?.[role];
  if (!spec?.bin) throw new Error(`capture sources name no ${role} binary (agentHarbor.${role}.bin)`);
  const name = spec.bin;
  // agent-harbor's dev shell points CARGO_TARGET_DIR outside the checkout,
  // at ~/.cache/ah/cargo-target/<checkout hash>/ (its flake's shellHook), so
  // a build made there is not under agent-harbor/target. Look in an explicit
  // AGENT_HARBOR_TARGET_DIR first, then the checkout's own target/, then the
  // newest build in that cache.
  const root = join(workspaceRoot, sources.agentHarbor.checkout ?? "agent-harbor");
  const targetDirs = [process.env.AGENT_HARBOR_TARGET_DIR, join(root, "target")].filter(Boolean);
  const cache = join(process.env.XDG_CACHE_HOME || join(process.env.HOME ?? "", ".cache"), "ah", "cargo-target");
  if (existsSync(cache)) {
    for (const entry of readdirSync(cache)) targetDirs.push(join(cache, entry));
  }
  const candidates = targetDirs
    .flatMap((dir) => [join(dir, "debug", name), join(dir, "release", name)])
    .filter((c) => existsSync(c))
    .sort((a, b) => statSync(b).mtimeMs - statSync(a).mtimeMs);
  const found = candidates[0];
  if (!found) {
    throw new Error(
      `no ${name} built for ${root}; build it in that checkout's dev shell: ${spec.build ?? "(capture sources give no build command)"}`,
    );
  }
  return found;
}

function freePort() {
  return new Promise((resolvePort, reject) => {
    const srv = createServer();
    srv.unref();
    srv.on("error", reject);
    srv.listen(0, "127.0.0.1", () => {
      const { port } = srv.address();
      srv.close(() => resolvePort(port));
    });
  });
}

// The Agent Harbor processes a capture starts run in process groups of their
// own (`detached`), so a signal one of them sends its group cannot stop the
// capture, and the capture kills every one it started when it exits, however
// it exits -- an interrupted capture must not leave a mock server listening.
const children = new Set();
function trackChild(child) {
  children.add(child);
  child.on("exit", () => children.delete(child));
}
function killChildren() {
  for (const child of children) {
    try {
      process.kill(-child.pid, "SIGKILL");
    } catch {
      // already gone
    }
  }
}
process.on("exit", killChildren);
for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"]) {
  process.on(signal, () => {
    killChildren();
    process.exit(128 + ({ SIGINT: 2, SIGTERM: 15, SIGHUP: 1 })[signal]);
  });
}

/** An argument template from capture-sources.json with `{name}` filled in. */
function expandArgs(template, values) {
  return (template ?? []).map((arg) =>
    arg.replace(/\{(\w+)\}/g, (whole, key) => {
      if (!(key in values)) throw new Error(`argument template names an unknown value ${whole}`);
      return values[key];
    }),
  );
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function initialPromptOf(scenarioPath) {
  // The scenario's own first prompt: its `initialPrompt`, else the first
  // `userInputs` entry's `input` (Agent Harbor's scenario format). A
  // single-line scalar is enough for the scenarios sources.json names.
  const text = readFileSync(scenarioPath, "utf8");
  const match = /^initialPrompt:\s*(.+)$/m.exec(text) ?? /^\s*input:\s*(.+)$/m.exec(text);
  return match ? match[1].trim().replace(/^['"]|['"]$/g, "") : basename(scenarioPath, ".yaml");
}

async function runOnMockServer(scenarioPath) {
  const bin = agentHarborBin("mockServer");
  const port = await freePort();
  const base = `http://127.0.0.1:${port}/api/v1`;
  const child = spawn(
    bin,
    expandArgs(sources.agentHarbor.mockServer.args, { bind: `127.0.0.1:${port}`, scenario: scenarioPath }),
    { cwd: dirname(scenarioPath), stdio: ["ignore", "pipe", "pipe"], detached: true },
  );
  trackChild(child);
  let stderr = "";
  child.stderr.on("data", (d) => (stderr += d));
  try {
    for (let i = 0; ; i++) {
      try {
        const r = await fetch(`${base}/sessions`);
        if (r.ok) break;
      } catch {
        // not listening yet
      }
      if (i > 120) throw new Error(`mock server did not start: ${stderr.slice(-2000)}`);
      await sleep(250);
    }
    const prompt = initialPromptOf(scenarioPath);
    const created = await fetch(`${base}/tasks`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        prompt,
        repo: { mode: "none" },
        runtime: { type: "local" },
        agents: [{ type: "claude", version: "latest", count: 1 }],
        output: { format: "text", flavor: "native", nonInteractive: false },
      }),
    });
    if (!created.ok) throw new Error(`mock server POST /tasks: HTTP ${created.status} ${await created.text()}`);
    const task = await created.json();
    const sessionId = task.session_ids?.[0] ?? task.sessionIds?.[0];
    if (!sessionId) throw new Error(`mock server created no session: ${JSON.stringify(task)}`);
    // Until the session ends, or until its event history has stopped growing
    // for a minute (the mock server plays some scenarios' steps tens of
    // seconds apart even sped up): a scenario that ends waiting for input (a question, a
    // permission gate) leaves its session running, and that state is worth
    // keeping as it is.
    let session = null;
    let lastCount = -1;
    let stableSince = Date.now();
    const startedPolling = Date.now();
    let lastReport = Date.now();
    for (;;) {
      if (Date.now() - lastReport > 10000) {
        // A long silent wait looks like a hung command to a supervisor.
        log(`scenarios: ${basename(scenarioPath)}: ${session?.status ?? "starting"}, ${Math.max(lastCount, 0)} events so far`);
        lastReport = Date.now();
      }
      session = await (await fetch(`${base}/sessions/${sessionId}`)).json();
      if (["completed", "failed", "cancelled", "stopped"].includes(session.status)) break;
      const history = await (await fetch(`${base}/sessions/${sessionId}/events/history?limit=200`)).json();
      const count = history.events?.length ?? 0;
      if (count !== lastCount) {
        lastCount = count;
        stableSince = Date.now();
      } else if (Date.now() - stableSince > 60000) {
        log(`scenarios: ${basename(scenarioPath)}: no new event for 60s; keeping the session as it is (${session.status})`);
        break;
      }
      if (Date.now() - startedPolling > 240000) {
        log(`scenarios: ${basename(scenarioPath)}: still ${session.status} after 240s; keeping it as it is`);
        break;
      }
      await sleep(250);
    }
    const events = await (await fetch(`${base}/sessions/${sessionId}/events/history?limit=200`)).json();
    const list = await (await fetch(`${base}/sessions?perPage=50`)).json();
    return { sessionId, session, events, list };
  } finally {
    child.kill("SIGTERM");
  }
}

async function runMockAgent(scenarioPath, extraArgs = []) {
  const bin = agentHarborBin("mockAgent");
  const cwd = mkdtempSync(join(tmpdir(), "ah-mock-agent-cwd-"));
  const child = spawn(bin, [...expandArgs(sources.agentHarbor.mockAgent.args, { scenario: scenarioPath, cwd }), ...extraArgs], {
    stdio: ["pipe", "pipe", "pipe"],
    detached: true,
  });
  trackChild(child);
  const transcript = [];
  const started = Date.now();
  const pending = new Map();
  let nextId = 1;
  let buffer = "";
  let stderr = "";
  child.stderr.on("data", (d) => (stderr += d));
  // An agent that exits without answering would leave its requests pending
  // forever, and Node exits 0 once nothing else keeps it alive -- a capture
  // that silently stopped half way. Every pending request fails instead.
  child.on("exit", (code, signal) => {
    for (const p of pending.values()) {
      p.reject(new Error(`mock-agent exited (${signal ?? code}) before answering`));
    }
    pending.clear();
  });
  const send = (message) => {
    transcript.push({ atMs: Date.now() - started, direction: "client-to-agent", message });
    child.stdin.write(`${JSON.stringify(message)}\n`);
  };
  const request = (method, params) =>
    new Promise((resolveReq, reject) => {
      const id = nextId++;
      pending.set(id, { resolve: resolveReq, reject });
      send({ jsonrpc: "2.0", id, method, params });
    });
  const answer = (message) => {
    // Requests the agent makes of its client (https://agentclientprotocol.com/protocol/overview).
    const reply = (result) => send({ jsonrpc: "2.0", id: message.id, result });
    switch (message.method) {
      case "session/request_permission": {
        const options = message.params?.options ?? [];
        const allow = options.find((o) => /allow/.test(o.kind ?? "")) ?? options[0];
        reply({ outcome: allow ? { outcome: "selected", optionId: allow.optionId } : { outcome: "cancelled" } });
        break;
      }
      case "fs/read_text_file": {
        const path = message.params?.path ?? "";
        const local = join(cwd, relative("/", path.startsWith(cwd) ? relative(cwd, path) : path));
        reply({ content: existsSync(local) ? readFileSync(local, "utf8") : "" });
        break;
      }
      case "fs/write_text_file": {
        const path = message.params?.path ?? "";
        const local = join(cwd, path.startsWith(cwd) ? relative(cwd, path) : basename(path));
        mkdirSync(dirname(local), { recursive: true });
        writeFileSync(local, message.params?.content ?? "");
        reply({});
        break;
      }
      default:
        send({ jsonrpc: "2.0", id: message.id, error: { code: -32601, message: `${message.method} is not offered by the fixture client` } });
    }
  };
  child.stdout.on("data", (d) => {
    buffer += d;
    let nl;
    while ((nl = buffer.indexOf("\n")) >= 0) {
      const line = buffer.slice(0, nl).trim();
      buffer = buffer.slice(nl + 1);
      if (!line) continue;
      let message;
      try {
        message = JSON.parse(line);
      } catch {
        continue;
      }
      transcript.push({ atMs: Date.now() - started, direction: "agent-to-client", message });
      if (message.id !== undefined && message.method === undefined && pending.has(message.id)) {
        const p = pending.get(message.id);
        pending.delete(message.id);
        if (message.error) p.reject(new Error(JSON.stringify(message.error)));
        else p.resolve(message.result);
      } else if (message.id !== undefined && message.method) {
        answer(message);
      }
    }
  });
  const timeout = setTimeout(() => child.kill("SIGKILL"), 180000);
  try {
    await request("initialize", {
      protocolVersion: 1,
      clientCapabilities: { fs: { readTextFile: true, writeTextFile: true }, terminal: false },
    });
    const session = await request("session/new", { cwd, mcpServers: [] });
    const result = await request("session/prompt", {
      sessionId: session.sessionId,
      prompt: [{ type: "text", text: initialPromptOf(scenarioPath) }],
    });
    return { stopReason: result?.stopReason ?? null, transcript };
  } catch (error) {
    throw new Error(`mock-agent ${basename(scenarioPath)}: ${error.message}; stderr: ${stderr.slice(-1500)}`);
  } finally {
    clearTimeout(timeout);
    child.kill("SIGTERM");
    rmSync(cwd, { recursive: true, force: true });
  }
}

async function captureScenarios(manifest) {
  rmSync(join(outDir, "scenarios"), { recursive: true, force: true });
  manifest.scenarioRuns = [];
  const scrub = scrubber();
  for (const s of sources.scenarios) {
    const scenarioPath = join(workspaceRoot, s.scenario);
    const served = await runOnMockServer(scenarioPath);
    const acp = await runMockAgent(scenarioPath, s.mockAgentArgs ?? []);
    manifest.scenarioRuns.push({
      name: s.name,
      scenario: basename(s.scenario),
      sessionStatus: served.session?.status ?? null,
      eventCount: served.events?.events?.length ?? 0,
      acpStopReason: acp.stopReason,
      acpMessageCount: acp.transcript.length,
      session: writeOut(`scenarios/${s.name}.session.json`, json(scrub.deep(served.session))),
      sessionList: writeOut(`scenarios/${s.name}.sessions.json`, json(scrub.deep(served.list))),
      events: writeOut(`scenarios/${s.name}.events.json`, json(scrub.deep(served.events))),
      acpTranscript: writeOut(`scenarios/${s.name}.acp-transcript.json`, json(scrub.deep(acp.transcript))),
    });
    log(`scenarios: ${s.name}: ${served.session?.status}, ${served.events?.events?.length ?? 0} REST events, ${acp.transcript.length} ACP messages (${acp.stopReason})`);
  }
}

// ---------------------------------------------------------------------------
// manifest
// ---------------------------------------------------------------------------

function referencedFiles(manifest) {
  const files = [];
  const visit = (value, key) => {
    if (typeof value === "string" && /\.(json|jsonl|sse|org|diff)$/.test(value) && !value.includes("://") && existsSync(join(outDir, value))) {
      if (key !== "name" && key !== "scenario") files.push(value);
    } else if (Array.isArray(value)) value.forEach((v) => visit(v, key));
    else if (value && typeof value === "object") for (const [k, v] of Object.entries(value)) if (k !== "files") visit(v, k);
  };
  visit(manifest, "");
  return [...new Set(files)].sort();
}

function pruneUnreferenced(keep) {
  const walk = (dir) => {
    for (const name of readdirSync(dir)) {
      const full = join(dir, name);
      if (statSync(full).isDirectory()) {
        walk(full);
        if (readdirSync(full).length === 0) rmSync(full, { recursive: true });
      } else {
        const rel = relative(outDir, full);
        if (rel !== "manifest.json" && rel !== "README.md" && !keep.has(rel)) rmSync(full);
      }
    }
  };
  walk(outDir);
}

async function main() {
  mkdirSync(outDir, { recursive: true });
  const manifestPath = join(outDir, "manifest.json");
  const manifest = existsSync(manifestPath)
    ? JSON.parse(readFileSync(manifestPath, "utf8"))
    : { schema: 1 };
  manifest.schema = 1;
  // The marker the scrub check looks for: a manifest saying `private` must
  // never be found in a public repository.
  manifest.fixtureSet = "private";
  manifest.generator = "codetracer: just capture-agent-harbor-fixtures";
  // Each part owns a directory and some manifest keys. The manifest is
  // rewritten after every part, and a part that fails is removed whole --
  // its directory and its keys -- so an interrupted capture leaves a smaller
  // set that is still consistent with its manifest, never a mixture of an old
  // manifest and new files.
  const steps = [
    { part: "fleet", run: captureFleet, dir: "fleet", keys: ["fleet", "capturedAt", "scrub"] },
    { part: "plans", run: capturePlans, dir: "plans", keys: ["plans"] },
    { part: "diffs", run: captureDiffs, dir: "diffs", keys: ["diffs"] },
    { part: "tests", run: captureTests, dir: "tests", keys: ["testRuns"] },
    { part: "scenarios", run: captureScenarios, dir: "scenarios", keys: ["scenarioRuns"] },
  ];
  const writeManifest = () => {
    const files = referencedFiles(manifest);
    pruneUnreferenced(new Set(files));
    manifest.files = {};
    for (const path of files) {
      manifest.files[path] = createHash("sha256").update(readFileSync(join(outDir, path))).digest("hex");
    }
    writeFileSync(manifestPath, json(manifest));
    return files.length;
  };
  for (const step of steps) {
    if (!parts.includes(step.part)) continue;
    try {
      await step.run(manifest);
    } catch (error) {
      for (const key of step.keys) delete manifest[key];
      rmSync(join(outDir, step.dir), { recursive: true, force: true });
      writeManifest();
      log(`${step.part}: FAILED; removed it from the set, which keeps the parts captured before`);
      throw error;
    }
    writeManifest();
  }
  const count = writeManifest();
  log(`wrote ${count} fixture files and manifest.json to ${outDir}`);
  log(`raw prompt strings for the scrub check: ${rawDir} (outside the repositories)`);
}

main().catch((error) => {
  console.error(`capture-agent-harbor-fixtures: ${error.stack ?? error}`);
  process.exit(1);
});
