#!/usr/bin/env node
//
// A minimal stdio ACP agent that replays a scripted session (RV-6).
//
// TEST DOUBLE JUSTIFICATION (workspace policy: every mock must be justified
// where it is defined).
//
// This is the *agent* side of the ACP boundary, and CodeTracer does not own
// it.  The end-to-end claim RV-6 has to support is "opening a review over a
// dataset that names an agent session shows that session's conversation",
// and the only way to observe it in the shipped product is to have `ct`
// speak the real protocol to a real process over real pipes.  A production
// agent (`claude-code-acp`, `codex-acp`) cannot serve: it needs credentials
// and network, costs minutes per run, and — decisively — cannot be asked to
// hold a *specific, known* prior session, nor to have pruned one, nor to
// withhold the `loadSession` capability, which are the three states the
// suite must distinguish.
//
// Nothing on the CodeTracer side is stubbed by this file.  `ct` runs its
// real `nim-agents` client, which runs the real `nim-acp` client, which
// frames real JSON-RPC over a real child process's stdin/stdout; the
// renderer runs its real projection and its real view.  Only the remote
// agent is simulated — the same boundary, and the same rationale, as the
// sanctioned in-process `nim_acp/fake.nim` seam used by the unit suites.
//
// It is JavaScript rather than Nim so the Playwright harness can point at it
// with no build step: the test needs an executable that speaks the protocol,
// not a compilation target.
//
// Protocol: newline-delimited JSON-RPC 2.0 on stdin/stdout, per
// https://agentclientprotocol.com/protocol/.  Implemented:
//
//   initialize    → advertises `loadSession` (unless CT_FAKE_ACP_NO_LOAD=1)
//   session/load  → replays the scripted transcript as `session/update`
//                   notifications, then answers with a null result; answers
//                   an unknown session id with a JSON-RPC error, which is
//                   how a pruned session behaves
//
// Configuration, by environment variable so the dataset's `agentArgs` stay
// the protocol's business:
//
//   CT_FAKE_ACP_SESSION_ID  the one session this agent holds (default
//                           "session-fixture")
//   CT_FAKE_ACP_NO_LOAD=1   do not advertise `loadSession`
//   CT_FAKE_ACP_EMPTY=1     hold the session, but with no messages
//   CT_FAKE_ACP_TEST_RUN=1  replay a session whose tool call is a
//                           `ct test ... --json-events` run (AA-2)
//   CT_FAKE_ACP_TRACE_DIR   the trace directory the recorded test in that
//                           run reports (default "/tmp/ct-aa2-trace")
//
// The last two are also settable per invocation, as `--test-run` and
// `--trace-dir=<path>` in the dataset's own `agentArgs`.  That matters
// because `--workers=1` puts every Playwright spec file in one process:
// a spec that set the environment variable would set it for the *other*
// spec files' launches too, and a fixture whose behaviour depends on which
// file ran first is not a fixture.  Argv travels with the dataset that
// selected it.

"use strict";

const argv = process.argv.slice(2);
const argFlag = (name) => argv.includes(name);
const argValue = (name, fallback) => {
  const prefix = name + "=";
  const found = argv.find((a) => a.startsWith(prefix));
  return found === undefined ? fallback : found.slice(prefix.length);
};

const sessionId = process.env.CT_FAKE_ACP_SESSION_ID || "session-fixture";
const advertisesLoad = process.env.CT_FAKE_ACP_NO_LOAD !== "1";
const isEmpty = process.env.CT_FAKE_ACP_EMPTY === "1";
const isTestRun =
  argFlag("--test-run") || process.env.CT_FAKE_ACP_TEST_RUN === "1";
// A run whose stream stops mid-flight — one test started, none finished, the
// run scope still open. §2.1.2: "the events stream before process exit
// precisely so the panel need not wait", so this is what a panel watching a
// live run sees, not a special case.
const isPartialTestRun = argFlag("--test-run-partial");
const traceDir = argValue(
  "--trace-dir",
  process.env.CT_FAKE_ACP_TRACE_DIR || "/tmp/ct-aa2-trace",
);

// AA-2 (DeepReview-GUI.md §2.1.2) — an agent that ran the tests.
//
// The stream below is the **runner's own** NDJSON, in the shape
// `ct_test/contracts.toJson` writes it, delivered exactly the way a real
// session delivers it: as the `rawOutput` of a `tool_call_update`, which
// `nim-agents` maps to `AgentEvent.text` (client.nim, `sukToolCallUpdate`).
// Nothing on the CodeTracer side is simulated — the renderer parses these
// bytes with the production projection.
//
// Three tests, chosen to be the three renderings §2.1.2 distinguishes:
//   * `test_add` — recorded, so the panel offers the drill-down;
//   * `test_sub` — failed, never recorded, so no affordance at all;
//   * `test_mul` — recording *attempted* and failed before producing a
//     trace, so diagnostics and still no trace to open.
function event(kind, testId, extra) {
  return JSON.stringify(
    Object.assign(
      {
        schemaVersion: 1,
        kind,
        providerId: "native-m11",
        runId: "native-m11:record:file:tests/calc.c",
        testId,
        message: "",
        output: "",
        durationMs: 0,
      },
      extra || {},
    ),
  );
}

const addId = "native-m11/c/gtest/tests/calc.c::test_add";
const subId = "native-m11/c/gtest/tests/calc.c::test_sub";
const mulId = "native-m11/c/gtest/tests/calc.c::test_mul";

const testRunOutput = [
  event("record-started", addId, {
    message: "ct-mcr record --source tests/calc.c",
  }),
  event("test-started", addId),
  event("recording-created", addId, {
    message: "recorded",
    trace: {
      traceId: "aa2-trace",
      recordingId: "aa2-recording",
      path: traceDir,
      backend: "native",
      entryPoint: "tests/calc.c",
      metadata: {},
    },
  }),
  event("test-finished", addId, { status: "passed", durationMs: 83 }),
  event("test-started", subId),
  event("output", subId, { output: "calc.c:12: expected 1, got 2" }),
  event("failure", subId, {
    status: "failed",
    message: "assertion failed at calc.c:12",
  }),
  event("test-finished", subId, { status: "failed", durationMs: 12 }),
  event("record-started", mulId, { message: "ct-mcr record" }),
  event("test-started", mulId),
  event("output", mulId, { output: "ct-mcr: cannot open perf events" }),
  event("failure", mulId, {
    status: "errored",
    message: "ct-mcr did not produce a non-empty .ct artifact",
  }),
  event("record-finished", mulId, { status: "errored", durationMs: 40 }),
  event("record-finished", addId, { status: "passed", durationMs: 135 }),
].join("\n");

const partialTestRunOutput = [
  event("run-started", "", { message: "ctest --output-on-failure" }),
  event("test-started", addId),
].join("\n");

const testRunTranscript = [
  {
    sessionUpdate: "agent_thought_chunk",
    content: { type: "text", text: "Recording the calculator tests" },
  },
  {
    sessionUpdate: "tool_call",
    toolCallId: "tool-test",
    title: "ct test record --file tests/calc.c --json-events",
    rawInput: '{"cmd":"ct test record --file tests/calc.c --json-events"}',
  },
  {
    sessionUpdate: "tool_call_update",
    toolCallId: "tool-test",
    status: "completed",
    rawOutput: isPartialTestRun ? partialTestRunOutput : testRunOutput,
  },
  {
    sessionUpdate: "agent_message_chunk",
    content: {
      type: "text",
      text: isPartialTestRun
        ? "Still running the calculator tests."
        : "One test fails and one could not be recorded.",
    },
  },
  { sessionUpdate: "status", status: "completed" },
];

const transcript = isEmpty
  ? []
  : isTestRun || isPartialTestRun
  ? testRunTranscript
  : [
      {
        sessionUpdate: "agent_thought_chunk",
        content: { type: "text", text: "Reading the failing parser test" },
      },
      {
        sessionUpdate: "tool_call",
        toolCallId: "tool-1",
        title: "Run the parser tests",
        rawInput: '{"cmd":"just test-parser"}',
      },
      {
        sessionUpdate: "tool_call_update",
        toolCallId: "tool-1",
        status: "completed",
        rawOutput: "12 passed, 1 failed",
      },
      {
        sessionUpdate: "agent_message_chunk",
        content: {
          type: "text",
          text: "The off-by-one was in the hunk parser; I fixed it and collected a review.",
        },
      },
      { sessionUpdate: "status", status: "completed" },
    ];

function write(payload) {
  process.stdout.write(JSON.stringify(payload) + "\n");
}

function ok(id, result) {
  write({ jsonrpc: "2.0", id, result });
}

function fail(id, code, message) {
  write({ jsonrpc: "2.0", id, error: { code, message } });
}

function handle(request) {
  const { id, method, params } = request;
  switch (method) {
    case "initialize":
      ok(id, {
        protocolVersion: (params && params.protocolVersion) || 1,
        agentCapabilities: {
          streaming: true,
          text: true,
          loadSession: advertisesLoad,
        },
        _meta: { fixture: "acp-replay-agent" },
      });
      return;
    case "session/load": {
      const wanted = (params && params.sessionId) || "";
      if (!advertisesLoad) {
        // What an agent without the capability answers.  `ct` should never
        // get here — it checks the handshake first — so reaching this arm at
        // all is itself a finding.
        fail(id, -32601, "method not found: session/load");
        return;
      }
      if (wanted !== sessionId) {
        fail(id, -32602, "unknown session: " + wanted);
        return;
      }
      for (const update of transcript) {
        write({
          jsonrpc: "2.0",
          method: "session/update",
          params: { sessionId: wanted, update },
        });
      }
      // ACP's session/load result is null: the replay is the payload.
      ok(id, null);
      return;
    }
    default:
      fail(id, -32601, "method not found: " + method);
  }
}

let buffer = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => {
  buffer += chunk;
  let newline;
  while ((newline = buffer.indexOf("\n")) >= 0) {
    const line = buffer.slice(0, newline).trim();
    buffer = buffer.slice(newline + 1);
    if (!line) continue;
    let request;
    try {
      request = JSON.parse(line);
    } catch (e) {
      continue;
    }
    if (request && request.id !== undefined) handle(request);
  }
});
process.stdin.on("end", () => process.exit(0));
