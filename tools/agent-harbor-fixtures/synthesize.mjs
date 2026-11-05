#!/usr/bin/env node
// Writes the SYNTHETIC Agent Harbor fixture set: the one public repositories
// commit and public CI builds and tests against.
//
//   node tools/agent-harbor-fixtures/synthesize.mjs [--out <dir>]
//
// Default output: ../nim-agents-isonim-viewmodels/fixtures/agent-harbor.
//
// The captured fixture set (a real fleet snapshot, real plans, diffs, test
// runs and scenario runs) is private and never enters a public repository.
// This set has the same files in the same shapes -- today's Agent Harbor wire
// types where an endpoint exists, the proposed shapes where none does -- so
// every viewmodel and story that reads the private set also works over this
// one. Everything in it is invented: session ids, prompts, hosts,
// repositories, branches, plan text, diffs and test names. Nothing is copied
// or derived from a capture, so the file can be regenerated anywhere.
//
// The output is deterministic: the same script writes the same bytes, so a
// regeneration that changes nothing shows no diff.

import { createHash } from "node:crypto";
import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, "../..");

function argValue(name) {
  const i = process.argv.indexOf(name);
  return i >= 0 ? process.argv[i + 1] ?? null : null;
}

const outDir = resolve(
  argValue("--out") ?? join(repoRoot, "../nim-agents-isonim-viewmodels/fixtures/agent-harbor"),
);

// ---------------------------------------------------------------------------
// Deterministic helpers
// ---------------------------------------------------------------------------

/** A UUID-shaped id derived from a label (RFC 9562 layout, version 4 bits). */
function syntheticId(label) {
  const h = createHash("sha256").update(`agent-harbor-synthetic:${label}`).digest("hex");
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-4${h.slice(13, 16)}-a${h.slice(17, 20)}-${h.slice(20, 32)}`;
}

/** Mulberry32: a small seeded PRNG, so the set is the same on every run. */
function prng(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const random = prng(20260115);
const pick = (list) => list[Math.floor(random() * list.length)];

const capturedAt = "2026-01-15T10:00:00.000Z";
const capturedMs = Date.parse(capturedAt);
const iso = (ms) => new Date(ms).toISOString();

function json(value) {
  return `${JSON.stringify(value, null, 2)}\n`;
}

// Every file is rewritten, so a renamed or dropped fixture leaves nothing behind.
rmSync(outDir, { recursive: true, force: true });
mkdirSync(outDir, { recursive: true });

const written = new Map();
function writeOut(path, content) {
  const full = join(outDir, path);
  mkdirSync(dirname(full), { recursive: true });
  writeFileSync(full, content);
  written.set(path, createHash("sha256").update(content).digest("hex"));
  return path;
}

// ---------------------------------------------------------------------------
// Invented fleet
// ---------------------------------------------------------------------------

const agents = [
  { software: "Claude", version: "4.2.0" },
  { software: "Codex", version: "0.91.3" },
  { software: "Gemini", version: "1.8.2" },
  { software: "Opencode", version: "0.12.7" },
];
const hosts = ["build-01", "build-02", "build-03", "gpu-01", "mac-01", "win-01"];
const repos = [
  "https://example.org/orbit-labs/orbit-sim.git",
  "https://example.org/orbit-labs/telemetry-ui.git",
  "https://example.org/orbit-labs/flight-planner.git",
  "https://example.org/meadow/paperboat.git",
];
const prompts = [
  "Add a retry budget to the telemetry uploader and cover it with tests",
  "Fix the off-by-one in the orbit propagator's step counter",
  "Port the flight planner's route cache to the new storage layer",
  "Write the migration guide for the 3.0 configuration format",
  "Make the dashboard's latency chart readable in the light theme",
  "Investigate why the nightly fuzz job times out on the parser",
  "Split the monolithic scheduler module into three cohesive parts",
  "Replace the hand-rolled JSON writer with the shared serializer",
  "Profile the paperboat renderer and remove the per-frame allocation",
  "Document every public function of the units library",
  "Add keyboard navigation to the mission timeline",
  "Teach the importer to accept gzip-compressed telemetry archives",
  "Cache the ephemeris tables between propagator runs",
  "Show the upload queue's depth on the status page",
  "Reject route plans whose waypoints leave the mission corridor",
  "Rename the legacy config keys and keep the old names as aliases",
  "Give the latency chart a percentile selector",
  "Shrink the parser's fuzz corpus without losing coverage",
  "Move the scheduler's clock behind an injectable interface",
  "Stream large telemetry exports instead of buffering them",
  "Fix the paperboat renderer's flicker on window resize",
  "Generate the units library's reference pages from its doc comments",
  "Let the mission timeline zoom to a selected range",
  "Validate archive checksums before the importer unpacks them",
  "Parallelise the orbit propagator's batch mode",
  "Retry failed uploads after a network change, not only on a timer",
  "Store route cache entries with their expiry time",
  "Add a dry-run flag to the configuration migrator",
  "Draw the latency chart's gridlines from the theme tokens",
  "Bisect the commit that made the fuzz job slow",
  "Document the scheduler's three new modules",
  "Benchmark the shared serializer against the hand-rolled writer",
  "Batch the paperboat renderer's draw calls per layer",
  "Mark the units library's deprecated functions in its index",
  "Show conflicting events on the mission timeline",
  "Log which telemetry archives the importer skipped, and why",
];
const branches = [
  "fix/propagator-step-count",
  "feat/telemetry-retry-budget",
  "feat/route-cache-storage",
  "docs/config-3-migration",
  "fix/latency-chart-light-theme",
  "chore/split-scheduler",
];
const failureLines = [
  "[exit] status=1",
  "build failed: 3 tests did not pass",
  "agent stopped: context window exhausted",
  "workspace provisioning failed: disk quota exceeded",
];
const logLines = [
  "Running the test suite",
  "Editing src/propagator/step.rs",
  "Reading docs/configuration.md",
  "Committed 2 files",
  "Pushed fix/propagator-step-count",
];

// The mix a real fleet shows at a glance: a few sessions waiting for a
// person, a handful running, some queued, failures, and a long tail of ended
// work. `withheld` sessions exercise the prompt-withheld state.
const plan = [
  ...Array(5).fill({ status: "running", awaiting: true }),
  ...Array(9).fill({ status: "running" }),
  ...Array(3).fill({ status: "queued" }),
  ...Array(7).fill({ status: "failed" }),
  ...Array(2).fill({ status: "cancelled" }),
  ...Array(6).fill({ status: "stopped" }),
  ...Array(16).fill({ status: "completed" }),
];

function eventsFor(id, status, awaiting, startMs, endMs) {
  // Newest first, as the server's history endpoint orders them.
  const events = [];
  let t = startMs;
  const push = (event) => {
    t += 15_000 + Math.floor(random() * 240_000);
    events.push({ ...event, timestamp: Math.min(t, endMs || capturedMs) });
  };
  push({
    type: "orchestration",
    kind: "session_metadata",
    targetSessionId: id,
    description: "foreground session metadata",
    payload: { agent: { agent: pick(agents), model: "default", count: 1 } },
  });
  push({ type: "status", status: "running" });
  for (let i = 0; i < 2 + Math.floor(random() * 3); i++) push({ type: "log", level: "info", message: pick(logLines) });
  if (random() < 0.4) push({ type: "session_resumed", deliverer: "human" });
  if (random() < 0.2) push({ type: "anti_halting_resume_confirmed", stallType: "idle_turn" });
  if (awaiting) {
    const request = `${id}:question:1`;
    push({ type: "session_awaiting_input", request });
    push({
      type: "agent_question",
      request,
      kind: "single_choice",
      prompt: "Which retry policy should the uploader use?",
      options: [
        { label: "Exponential backoff", recommended: true },
        { label: "Fixed interval", recommended: false },
        { label: "No retries", recommended: false },
      ],
    });
  }
  if (status === "failed") push({ type: "log", level: "error", message: pick(failureLines) });
  if (status === "failed" || status === "completed" || status === "stopped" || status === "cancelled") {
    push({ type: "status", status });
  }
  return events.reverse();
}

const sessions = [];
const labels = {};
const windowNames = ["retry-budget", "propagator", "route-cache", "migration-guide", "latency-chart", "fuzz-timeout", "scheduler-split"];
const initiatives = ["Telemetry upload retries", "Route cache on the new storage layer", ""];
const histories = {};
const infos = {};
const lifecycle = [];
let seq = 0;
let promptedSessions = 0;
const epoch = "5e7a1c0de0f1a2b3";
plan.forEach((spec, index) => {
  const id = syntheticId(`session-${index}`);
  const agent = agents[index % agents.length];
  const host = hosts[index % hosts.length];
  const ageMs = (index + 1) * 37 * 60_000 + Math.floor(random() * 600_000);
  const startMs = capturedMs - ageMs;
  const ended = !["running", "queued"].includes(spec.status);
  const endMs = ended ? startMs + 20 * 60_000 + Math.floor(random() * 3 * 3_600_000) : 0;
  const withheld = index % 4 === 3;
  const hasRepo = index % 3 !== 2;
  const events = spec.status === "queued" ? [] : eventsFor(id, spec.status, spec.awaiting, startMs, endMs);
  const session = {
    id,
    org_id: "00000000-0000-0000-0000-000000000000",
    // Each session that shows a prompt shows its own, as in a real fleet: a
    // fleet panel is how a person tells sessions apart. Drawn in order, not as
    // `prompts[index % n]`: with every fourth session withheld, an index that
    // shares a factor with 4 skips some prompts and repeats the rest (12
    // prompts gave 48 rows only 21 distinct titles).
    task: { prompt: withheld ? "" : prompts[promptedSessions++ % prompts.length] },
    agent: { agent, model: index % 5 === 0 ? "large" : "", count: index % 11 === 0 ? 2 : 1 },
    runtime: { type: index % 7 === 0 ? "devcontainer" : "local" },
    workspace: { snapshotProvider: "git", mountPath: "", host },
    vcs: hasRepo
      ? { repo_url: repos[index % repos.length], branch: branches[index % branches.length], commit: syntheticId(`commit-${index}`).replace(/-/g, "").slice(0, 40) }
      : { repo_url: null, branch: null, commit: null },
    status: spec.status,
    createdAt: iso(startMs - 4_000),
    updatedAt: iso(ended ? endMs : events.length ? events[0].timestamp : startMs),
    started_at: spec.status === "queued" ? null : iso(startMs),
    ...(ended ? { ended_at: iso(endMs) } : {}),
    awaiting_input: Boolean(spec.awaiting),
    ...(spec.awaiting ? { awaiting_input_source: "agent-question" } : {}),
    cacheWarmth: { state: "unknown", confidence: "estimated" },
    priority: index % 9 === 0 ? "high" : "normal",
    withheld: withheld ? ["prompt"] : [],
    links: {
      self: `/api/v1/sessions/${id}`,
      events: `/api/v1/sessions/${id}/events`,
      logs: `/api/v1/sessions/${id}/logs`,
    },
    recent_events: events.slice(0, 3).reverse(),
  };
  sessions.push(session);
  // The label table, as a capture records it for the sessions it can name:
  // most sessions here have one (a window name, a workspace, an initiative),
  // and every fifth has none, so the id-only title is exercised too.
  if (index % 5 !== 4) {
    labels[id] = {
      name: `${windowNames[index % windowNames.length]}-${Math.floor(index / windowNames.length) + 1}`,
      workspace: `orbit-ws-${(index % 6) + 1}`,
      branch: "",
      initiative: initiatives[index % initiatives.length],
      source: "the terminal window the session runs in",
    };
  }
  const captureEvents = spec.status !== "completed" || index % 4 === 0;
  if (captureEvents) {
    histories[id] = {
      events,
      has_more: false,
      oldest_timestamp: events.length ? events[events.length - 1].timestamp : 0,
      total_count: events.length,
    };
    infos[id] = { id, status: spec.status, fleet: { leader: host, followers: [] }, endpoints: { events: `/api/v1/sessions/${id}/events` } };
  }
  const frame = (kind, status, previousStatus, atMs) => {
    seq += 1;
    lifecycle.push(
      `event: lifecycle\ndata: ${JSON.stringify({
        kind,
        sessionId: id,
        status,
        ...(previousStatus ? { previousStatus } : {}),
        agent: agent.software.toLowerCase(),
        executor: `executor-${(index % 3) + 1}`,
        at: iso(atMs),
      })}\nid: ${epoch}-${seq}\n`,
    );
  };
  if (index >= plan.length - 12 || !ended) {
    frame("session_created", "queued", null, startMs - 4_000);
    if (spec.status !== "queued") frame("session_status_changed", "running", "queued", startMs);
    if (ended) frame("session_completed", spec.status, "running", endMs);
  }
});
sessions.sort((a, b) => Date.parse(b.createdAt) - Date.parse(a.createdAt));
lifecycle.push(`event: caught_up\ndata: ${JSON.stringify({ cursor: `${epoch}-${seq}` })}\n`);

// ---------------------------------------------------------------------------
// Plans, diffs, test runs, scenario runs
// ---------------------------------------------------------------------------

const planText = (title, ids) =>
  [
    `#+TITLE: ${title} Milestones`,
    "",
    "* Document",
    "  :PROPERTIES:",
    `  :next_steps: Finish ${ids[1]}.`,
    "  :last_updated: 2026-01-14",
    `  :current_milestone: ${ids[1]}`,
    `  :executive_summary: ${title}: one milestone done, one in progress, one planned.`,
    "  :END:",
    "",
    "* Introduction",
    "  An invented campaign for the synthetic fixture set.",
    "",
    "* Milestones",
    "",
    ...ids.flatMap((id, i) => [
      `** ${id}: ${["Groundwork", "The main change", "Polish and release"][i]}`,
      "   :PROPERTIES:",
      `   :status: ${["completed", "in_progress", "planned"][i]}`,
      `   :depends_on: ${i > 0 ? ids[i - 1] : ""}`,
      "   :END:",
      "",
      "*** Deliverables",
      `    - [${i === 0 ? "x" : " "}] The ${["groundwork", "change", "release notes"][i]} is in place.`,
      "",
      "*** Verification",
      `    - test_name: just test-${id.toLowerCase()}`,
      "      description: The milestone's tests pass.",
      `      status: ${i === 0 ? "passing" : "pending"}`,
      "",
    ]),
  ].join("\n");

const plans = [
  { name: "Telemetry-Retry.milestones.org", campaign: "Telemetry upload retries", ids: ["TR-M1", "TR-M2", "TR-M3"],
    initiative: { id: "telemetry-retry", repository: "orbit-labs/telemetry", manager: "tr-manager" } },
  { name: "Route-Cache.milestones.org", campaign: "Route cache on the new storage layer", ids: ["RC-M1", "RC-M2", "RC-M3"],
    initiative: { id: "route-cache", repository: "orbit-labs/flight-planner", manager: "" } },
].map((p) => ({
  name: p.name,
  campaign: p.campaign,
  visibility: "synthetic",
  revision: "",
  file: writeOut(`plans/${p.name}`, planText(p.campaign, p.ids)),
  // The initiative a server would list for the plan (a proposed shape).
  initiative: p.initiative,
}));

const diffOf = (files) =>
  files
    .map(
      ({ path, before, after }) =>
        `diff --git a/${path} b/${path}\nindex 1111111..2222222 100644\n--- a/${path}\n+++ b/${path}\n@@ -1,${before.length} +1,${after.length} @@\n` +
        before.map((l) => `-${l}`).join("\n") +
        "\n" +
        after.map((l) => `+${l}`).join("\n") +
        "\n",
    )
    .join("");

const diffs = [
  {
    name: "orbit-sim-propagator-step-count",
    repository: "orbit-labs/orbit-sim",
    base: "main",
    head: "fix/propagator-step-count",
    files: [
      { path: "src/propagator/step.rs", before: ["    for i in 0..=steps {"], after: ["    for i in 0..steps {"] },
      {
        path: "tests/propagator.rs",
        before: ["    assert_eq!(run(10).len(), 11);"],
        after: ["    assert_eq!(run(10).len(), 10);", "    assert_eq!(run(0).len(), 0);"],
      },
    ],
  },
  {
    name: "telemetry-ui-latency-chart-light-theme",
    repository: "orbit-labs/telemetry-ui",
    base: "main",
    head: "fix/latency-chart-light-theme",
    files: [
      { path: "src/chart/latency.ts", before: ['  stroke: "#ffffff",'], after: ["  stroke: theme.chartLine,"] },
      { path: "src/theme/light.ts", before: ["  chartGrid: grey[200],"], after: ["  chartGrid: grey[200],", "  chartLine: grey[800],"] },
      { path: "src/theme/dark.ts", before: ["  chartGrid: grey[700],"], after: ["  chartGrid: grey[700],", "  chartLine: grey[100],"] },
    ],
  },
].map((d) => {
  const text = diffOf(d.files);
  const insertions = d.files.reduce((n, f) => n + f.after.length, 0);
  const deletions = d.files.reduce((n, f) => n + f.before.length, 0);
  return {
    name: d.name,
    repository: d.repository,
    baseRef: d.base,
    headRef: d.head,
    baseCommit: syntheticId(`${d.name}-base`).replace(/-/g, "").slice(0, 12),
    headCommit: syntheticId(`${d.name}-head`).replace(/-/g, "").slice(0, 12),
    filesChanged: d.files.length,
    insertions,
    deletions,
    file: writeOut(`diffs/${d.name}.diff`, text),
  };
});

// `ct test run --events` lines (codetracer src/ct_test/contracts.nim
// `TestEvent`), and the same run in the test-run event shape a front-end
// consumes, as the capture maps it.
function testRun(name, description, tests, platform, traced) {
  const runId = `synthetic-${name}`;
  const providerId = "python-pytest";
  const ev = (kind, extra = {}) => ({
    schemaVersion: 1,
    kind,
    providerId,
    runId,
    testId: "",
    status: null,
    message: "",
    output: "",
    durationMs: 0,
    trace: null,
    diagnostic: null,
    ...extra,
  });
  const runner = [ev("run-started")];
  const mapped = [];
  const common = { testRunId: runId, platform, backend: "local-ct", runner: "ct" };
  mapped.push({ kind: "run-started", ...common });
  const totals = {};
  for (const t of tests) {
    const testId = `${providerId}/python/pytest/tests/${t.file}::${t.name}`;
    runner.push(ev("test-started", { testId }));
    mapped.push({ kind: "test-started", ...common, testId: `ct/${testId}` });
    if (t.status === "failed") {
      runner.push(ev("failure", { testId, message: t.message }));
      mapped.push({ kind: "failure", ...common, testId: `ct/${testId}`, message: t.message, location: null });
    }
    runner.push(ev("test-finished", { testId, status: t.status, durationMs: t.ms }));
    mapped.push({ kind: "test-finished", ...common, testId: `ct/${testId}`, status: t.status, durationMs: t.ms, reused: false });
    totals[t.status] = (totals[t.status] ?? 0) + 1;
  }
  runner.push(ev("run-finished"));
  let trace = null;
  if (traced) {
    const traceId = `synthetic-trace-${name}`;
    const testId = `ct/${providerId}/python/pytest/tests/${tests[0].file}::${tests[0].name}`;
    mapped.push({ kind: "trace-started", ...common, testId, recorder: "ct" });
    mapped.push({ kind: "trace-created", ...common, testId, trace: `agent-harbor://trace/${traceId}` });
    trace = { name: `${name}-trace`, program: "examples/units/convert.py", reference: `agent-harbor://trace/${traceId}` };
  }
  mapped.push({ kind: "run-finished", ...common, totals });
  return {
    name,
    description,
    exitStatus: totals.failed ? 1 : 0,
    trace,
    runnerEvents: writeOut(`tests/${name}.ct-events.jsonl`, runner.map((e) => JSON.stringify(e)).join("\n") + "\n"),
    testRunEvents: writeOut(`tests/${name}.test-run-events.json`, json(mapped)),
  };
}

const testRuns = [
  testRun(
    "units-library-tests",
    "A pytest run over an invented units library: passing, failing and skipped tests",
    [
      { file: "test_convert.py", name: "test_metres_to_feet", status: "passed", ms: 12 },
      { file: "test_convert.py", name: "test_feet_to_metres", status: "passed", ms: 9 },
      { file: "test_convert.py", name: "test_round_trip", status: "failed", ms: 31, message: "assert 3.2808 == 3.28084" },
      { file: "test_parse.py", name: "test_parse_with_unit", status: "passed", ms: 7 },
      { file: "test_parse.py", name: "test_parse_scientific", status: "skipped", ms: 0 },
    ],
    ["os.linux", "arch.x86_64"],
    true,
  ),
  testRun(
    "scheduler-tests",
    "A pytest run over an invented scheduler: every test passes",
    [
      { file: "test_queue.py", name: "test_fifo_order", status: "passed", ms: 4 },
      { file: "test_queue.py", name: "test_priority_order", status: "passed", ms: 5 },
      { file: "test_timer.py", name: "test_deadline_fires", status: "passed", ms: 18 },
    ],
    ["os.macos", "arch.aarch64"],
    false,
  ),
];

function scenarioRun(name, prompt, steps) {
  const id = syntheticId(`scenario-${name}`);
  const events = steps.map((s) => ({ ...s, timestamp: 0 })).reverse();
  const session = {
    id,
    org_id: "00000000-0000-0000-0000-000000000000",
    task: { prompt },
    agent: { agent: { software: "Claude", version: "latest" }, model: "", count: 1 },
    runtime: { type: "local" },
    workspace: { snapshotProvider: "git", mountPath: "" },
    vcs: { repo_url: null, branch: null, commit: null },
    status: "completed",
    createdAt: "1970-01-01T00:00:00Z",
    updatedAt: capturedAt,
    started_at: "1970-01-01T00:00:00Z",
    ended_at: capturedAt,
    awaiting_input: false,
    recent_events: events.slice(0, 3).reverse(),
  };
  const transcript = [
    { atMs: 0, direction: "client-to-agent", message: { jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: 1 } } },
    { atMs: 4, direction: "agent-to-client", message: { jsonrpc: "2.0", id: 1, result: { protocolVersion: 1 } } },
    { atMs: 5, direction: "client-to-agent", message: { jsonrpc: "2.0", id: 2, method: "session/new", params: { cwd: "/workspace", mcpServers: [] } } },
    { atMs: 7, direction: "agent-to-client", message: { jsonrpc: "2.0", id: 2, result: { sessionId: `${name}-session` } } },
    { atMs: 8, direction: "client-to-agent", message: { jsonrpc: "2.0", id: 3, method: "session/prompt", params: { sessionId: `${name}-session`, prompt: [{ type: "text", text: prompt }] } } },
    { atMs: 40, direction: "agent-to-client", message: { jsonrpc: "2.0", id: 3, result: { stopReason: "end_turn" } } },
  ];
  return {
    name,
    scenario: `${name}.yaml`,
    sessionStatus: "completed",
    eventCount: events.length,
    acpStopReason: "end_turn",
    acpMessageCount: transcript.length,
    session: writeOut(`scenarios/${name}.session.json`, json(session)),
    sessionList: writeOut(`scenarios/${name}.sessions.json`, json({ items: [session], total: 1, nextPage: null })),
    events: writeOut(`scenarios/${name}.events.json`, json({ events, has_more: false, oldest_timestamp: 0, total_count: events.length })),
    acpTranscript: writeOut(`scenarios/${name}.acp-transcript.json`, json(transcript)),
  };
}

// ---------------------------------------------------------------------------
// Write
// ---------------------------------------------------------------------------

const fleet = {
  label: "synthetic fleet, 2026-01-15 10:00 UTC",
  capturedAt,
  sessions: writeOut("fleet/sessions.json", json({ items: sessions, total: sessions.length, nextPage: null })),
  labels: writeOut("fleet/labels.json", json(labels)),
  lifecycle: writeOut("fleet/lifecycle.sse", `${lifecycle.join("\n")}\n`),
  events: {},
  info: {},
};
for (const id of Object.keys(histories)) {
  fleet.events[id] = writeOut(`fleet/events/${id}.json`, json(histories[id]));
  fleet.info[id] = writeOut(`fleet/info/${id}.json`, json(infos[id]));
}
const scenarioRuns = [
  scenarioRun("edit-and-test", "Rename the units module's helpers and run its tests", [
    { type: "status", status: "queued" },
    { type: "status", status: "running" },
    { type: "user_input", input_type: "text", content: "Rename the units module's helpers and run its tests" },
    { type: "log", level: "info", message: "assistant: renamed 4 helpers in units/convert.py" },
    { type: "log", level: "info", message: "assistant: 12 tests passed" },
    { type: "status", status: "completed" },
  ]),
  scenarioRun("permission-granted", "Ask before deleting the generated files", [
    { type: "status", status: "queued" },
    { type: "status", status: "running" },
    { type: "user_input", input_type: "text", content: "Ask before deleting the generated files" },
    { type: "log", level: "info", message: "agent permission request: delete build/generated (allow once, reject once); allowed once" },
    { type: "log", level: "info", message: "assistant: deleted 3 generated files" },
    { type: "status", status: "completed" },
  ]),
  scenarioRun("storage-choice", "Move the route cache to the new storage layer; ask me which backend if unsure", [
    { type: "status", status: "queued" },
    { type: "status", status: "running" },
    { type: "user_input", input_type: "text", content: "Move the route cache to the new storage layer; ask me which backend if unsure" },
    { type: "log", level: "info", message: "agent question (Claude Code): tool=AskUserQuestion" },
    { type: "log", level: "info", message: "assistant: Using the embedded key-value store, as chosen." },
    { type: "tool_use", status: "started", tool_name: "runCmd", tool_execution_id: "tool-1", tool_args: { command: "make test-cache" } },
    { type: "tool_result", status: "completed", tool_name: "runCmd", tool_execution_id: "tool-1" },
    { type: "status", status: "completed" },
  ]),
];

// The sessions an operator works with, as a front-end's tabs show them, and
// what the proposed shapes would say of each: the front-end it was started
// from and the plan it was launched for (the captured set's
// capture-sources.json states the same for real sessions).
const firstOf = (category) => sessions.find((s) => s.status === category)?.id;
const stated = (entries) => entries.map((entry) => ({ ...entry, stated: "invented, like every value of this set" }));
// Coherent sets, as in the captured set: the scenario runs with the plans
// they are launched for, and the fleet's sessions on their own.
const workingSets = {
  scenario: stated([
    { from: "scenario", scenarioRun: "storage-choice", at: "question", origin: "webui", plan: plans[1].name },
    { from: "scenario", scenarioRun: "edit-and-test", at: 4, origin: "codetracer", plan: plans[0].name },
    { from: "scenario", scenarioRun: "permission-granted", at: "end", origin: "tui", plan: plans[0].name },
  ]),
  real: stated([
    { from: "fleet", sessionId: firstOf("running"), origin: "cli", plan: plans[1].name },
    { from: "fleet", sessionId: firstOf("failed"), origin: "ah-lite", plan: "" },
  ]),
};


const manifest = {
  schema: 1,
  fixtureSet: "synthetic",
  generator: "codetracer: tools/agent-harbor-fixtures/synthesize.mjs",
  capturedAt,
  fleet,
  plans,
  diffs,
  testRuns,
  scenarioRuns,
  workingSets,
  files: Object.fromEntries([...written.entries()].sort(([a], [b]) => a.localeCompare(b))),
};
writeFileSync(join(outDir, "manifest.json"), json(manifest));
writeFileSync(
  join(outDir, "README.md"),
  [
    "# Agent Harbor fixtures (synthetic)",
    "",
    "An invented fixture set in the shapes of the Agent Harbor wire types: a",
    "fleet of sessions (`fleet/`), campaign plans (`plans/`), branch diffs",
    "(`diffs/`), test runs (`tests/`) and scenario runs (`scenarios/`).",
    "Every name, id, prompt, host and repository in it is made up.",
    "",
    "`src/nim_agents_isonim_viewmodels/agent_harbor/fixture_source.nim` embeds",
    "it when no captured fixture set is available to the build (its module",
    "comment says how the set is chosen). Regenerate it from a CodeTracer",
    "checkout beside this one:",
    "",
    "```bash",
    "node tools/agent-harbor-fixtures/synthesize.mjs",
    "```",
    "",
    "Do not edit these files by hand, and never copy captured data into them.",
    "",
  ].join("\n"),
);
console.log(`synthesize: wrote ${written.size} synthetic fixture files and manifest.json to ${outDir}`);
