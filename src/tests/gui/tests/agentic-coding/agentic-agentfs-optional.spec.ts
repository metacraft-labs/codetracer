import { test } from "@playwright/test";

const optIn = process.env.CODETRACER_AGENTFS_E2E === "1";
const baseUrl = process.env.AGENT_HARBOR_AGENTFS_BASE_URL ?? "";
const daemonSocket =
  process.env.AGENTFS_SOCKET_PATH ?? process.env.AGENTFS_SOCKET ?? "";

test("e2e_agentic_agentfs_session_optional_contract", async () => {
  if (!optIn) {
    const reason =
      "AgentFS snapshot-backed CodeTracer E2E requires explicit CODETRACER_AGENTFS_E2E=1 opt-in because the AgentFS/snapshot daemon may require sudo and platform-specific lifecycle setup.";
    console.log(`SKIP: ${reason}`);
    test.skip(true, reason);
  }
  if (baseUrl.length === 0) {
    const reason =
      "AgentFS snapshot-backed CodeTracer E2E requires AGENT_HARBOR_AGENTFS_BASE_URL pointing at a real Agent Harbor server configured for snapshot-backed sessions.";
    console.log(`SKIP: ${reason}`);
    test.skip(true, reason);
  }
  if (daemonSocket.length === 0) {
    const reason =
      "AgentFS snapshot-backed CodeTracer E2E requires AGENTFS_SOCKET_PATH or AGENTFS_SOCKET for an already-running AgentFS/snapshot daemon; the test runner does not start privileged daemons.";
    console.log(`SKIP: ${reason}`);
    test.skip(true, reason);
  }

  throw new Error(
    "AgentFS snapshot-backed CodeTracer E2E prerequisites were provided, but the safe Agent Harbor AgentFS GUI harness is not wired yet. Keep this target opt-in until daemon lifecycle and CI behavior are explicit.",
  );
});
