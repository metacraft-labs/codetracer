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

"use strict";

const sessionId = process.env.CT_FAKE_ACP_SESSION_ID || "session-fixture";
const advertisesLoad = process.env.CT_FAKE_ACP_NO_LOAD !== "1";
const isEmpty = process.env.CT_FAKE_ACP_EMPTY === "1";

const transcript = isEmpty
  ? []
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
