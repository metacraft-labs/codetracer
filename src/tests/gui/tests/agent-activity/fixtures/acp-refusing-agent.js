#!/usr/bin/env node
//
// A minimal stdio ACP agent whose first `session/prompt` is refused with a
// JSON-RPC error (GitHub metacraft-labs/codetracer#862).
//
// TEST DOUBLE JUSTIFICATION (workspace policy: every mock must be justified
// where it is defined).
//
// This is the *agent* side of the ACP boundary, which CodeTracer does not
// own.  The Agent Activity pane spawns `codex-acp` from `PATH`
// (`src/frontend/index/ipc_subsystems/acp_ipc.nim`, `defaultCmd`), and the
// defect under test is what CodeTracer does when that agent answers
// `session/prompt` with an error instead of a result.  The production agent
// cannot serve: it needs a paid ChatGPT/OpenAI account and network access,
// and it cannot be made to refuse a turn on demand.  The spec places a
// `codex-acp` wrapper that runs this file first on the launched app's `PATH`.
//
// Nothing on the CodeTracer side is stubbed.  The Electron main process runs
// its real `@agentclientprotocol/sdk` client over this process's real
// stdin/stdout, and the renderer runs its real Agent Activity pane.
//
// It is JavaScript rather than Nim so the Playwright harness can run it with
// no build step, like `agent-activity-deepreview/fixtures/acp-replay-agent.js`.
//
// Protocol: newline-delimited JSON-RPC 2.0 on stdin/stdout, per
// https://agentclientprotocol.com/protocol/overview and
// https://www.jsonrpc.org/specification#error_object.  Implemented:
//
//   initialize      -> protocol version 1, no optional capabilities
//   session/new     -> a fixed session id
//   session/prompt  -> the FIRST one is answered with the error body pxor
//                      reported in #862 (code -32603, "Internal error", the
//                      backend's refusal in `data`).  Every later one streams
//                      one `agent_message_chunk` and ends the turn normally,
//                      so the spec can show that a refused turn leaves the
//                      pane able to run the next one.
//                      Exception: a prompt whose text contains HOLD_MARKER is
//                      held open, with no answer, until a `session/cancel`
//                      arrives; it does not count towards the refusal above.
//                      The spec uses it for a turn that is still running.
//   session/cancel  -> a notification, never answered itself; it ends every
//                      held turn with `stopReason: "cancelled"`, as
//                      https://agentclientprotocol.com/protocol/prompt-turn#cancellation
//                      requires of the agent.
//
// Any other request is answered with JSON-RPC "Method not found" (-32601).
//
// Configuration, by environment variable:
//
//   CT_FAKE_ACP_LOG   when set, the method of every message received is
//                     appended to this file, one per line.  The spec reads it
//                     as its positive control: the refusal it asserts on must
//                     come from a `session/prompt` that really reached here.

"use strict";

const fs = require("node:fs");
const readline = require("node:readline");

const SESSION_ID = "refusing-session-1";

/** The refusal, verbatim from #862 apart from the transport wrapping. */
const REFUSAL_DETAIL =
  "The 'gpt-6.1-sol' model is not supported when using Codex with a ChatGPT account.";
const REFUSAL_ERROR = {
  code: -32603,
  message: "Internal error",
  data: `unexpected status 400 Bad Request: {"detail":"${REFUSAL_DETAIL}"}`,
};

/** The text the second (accepted) turn streams back. */
const SECOND_TURN_TEXT = "Second turn answered after the refusal.";

const logPath = process.env.CT_FAKE_ACP_LOG || "";
function logMethod(method) {
  if (logPath.length === 0) return;
  try {
    fs.appendFileSync(logPath, `${method}\n`);
  } catch {
    // The log is a test aid; never let it break the protocol.
  }
}

function send(message) {
  process.stdout.write(`${JSON.stringify(message)}\n`);
}

let promptCount = 0;

/** A prompt containing this text is held until it is cancelled. */
const HOLD_MARKER = "[hold this turn]";

/** Ids of the `session/prompt` requests being held, oldest first. */
const heldPromptIds = [];

function promptText(msg) {
  const blocks = (msg.params && msg.params.prompt) || [];
  return blocks.map((b) => (b && typeof b.text === "string" ? b.text : "")).join("");
}

function cancelHeldPrompts() {
  while (heldPromptIds.length > 0) {
    const id = heldPromptIds.shift();
    send({ jsonrpc: "2.0", id, result: { stopReason: "cancelled" } });
  }
}

function handleRequest(msg) {
  switch (msg.method) {
    case "initialize":
      send({
        jsonrpc: "2.0",
        id: msg.id,
        result: { protocolVersion: 1, agentCapabilities: {}, authMethods: [] },
      });
      return;
    case "session/new":
      send({ jsonrpc: "2.0", id: msg.id, result: { sessionId: SESSION_ID } });
      return;
    case "session/prompt": {
      if (promptText(msg).includes(HOLD_MARKER)) {
        heldPromptIds.push(msg.id);
        return;
      }
      promptCount += 1;
      if (promptCount === 1) {
        send({ jsonrpc: "2.0", id: msg.id, error: REFUSAL_ERROR });
        return;
      }
      const sessionId = (msg.params && msg.params.sessionId) || SESSION_ID;
      send({
        jsonrpc: "2.0",
        method: "session/update",
        params: {
          sessionId,
          update: {
            sessionUpdate: "agent_message_chunk",
            content: { type: "text", text: SECOND_TURN_TEXT },
          },
        },
      });
      send({ jsonrpc: "2.0", id: msg.id, result: { stopReason: "end_turn" } });
      return;
    }
    default:
      send({
        jsonrpc: "2.0",
        id: msg.id,
        error: { code: -32601, message: `Method not found: ${msg.method}` },
      });
  }
}

function serve() {
  const rl = readline.createInterface({ input: process.stdin });
  rl.on("line", (line) => {
    if (line.trim().length === 0) return;
    let msg;
    try {
      msg = JSON.parse(line);
    } catch {
      return;
    }
    if (typeof msg.method !== "string") {
      // A response to a request we never send; nothing to do.
      return;
    }
    logMethod(msg.method);
    // A message without an id is a notification (e.g. `session/cancel`) and
    // must not be answered (JSON-RPC 2.0 §4.1).
    if (msg.id === undefined || msg.id === null) {
      if (msg.method === "session/cancel") cancelHeldPrompts();
      return;
    }
    handleRequest(msg);
  });
  rl.on("close", () => process.exit(0));
}

// Serve only when run as the agent.  The spec `require`s this file for the
// strings it asserts on, and must not start reading its own stdin.
if (require.main === module) {
  serve();
}

module.exports = { REFUSAL_DETAIL, SECOND_TURN_TEXT, HOLD_MARKER };
