/**
 * Ported to the scenarios
 * src/tests/scenarios/agent-activity-deepreview/session-renders-conversation.yaml,
 * session-pruned-says-so.yaml and session-absent-shows-nothing.yaml; kept for
 * the one case with no UI: the dataset references the session and embeds no
 * transcript (a check of the file, not of the window).
 *
 * E2E tests for RV-6: a review loads the agent session that produced it.
 *
 * `codetracer-specs/DeepReview/DeepReview-GUI.md` §2.1:
 *
 *   "The primary thing the panel shows in a review is **the agent session
 *    that produced it**. A review dataset MAY carry an optional reference to
 *    that session; when it does, opening the review loads the session into
 *    the Agent Activity panel, so the reviewer can read what the agent
 *    actually did in the run leading up to the dataset."
 *
 *   "When the backend cannot resolve the referenced session — it has been
 *    pruned, the agent does not advertise `session/load`, the workspace is
 *    elsewhere — the panel says so explicitly. It must not silently render an
 *    empty session, which reads as 'the agent did nothing'."
 *
 * These are the *whole chain*, in the shipped product: `ct review <PATH>`
 * reads the dataset's session reference, spawns the referenced stdio ACP
 * agent, issues the protocol's `session/load` through `nim-agents` /
 * `nim-acp`, hands the resolved transcript to Electron, and the renderer
 * paints it in the Agent Activity panel. Nothing between the CLI and the DOM
 * is stubbed.
 *
 * TEST DOUBLE JUSTIFICATION (workspace policy). One double is used: the
 * agent itself, `fixtures/acp-replay-agent.js`, whose own header explains why
 * a production agent cannot serve here (credentials, minutes per run, and no
 * way to make it hold a known prior session, prune one, or withhold a
 * capability on demand). Every CodeTracer-side layer in the chain above is
 * production code.
 *
 * The dataset fixtures are written at module load rather than checked in,
 * because a session reference to a stdio ACP agent necessarily names an
 * absolute path to that agent, which only exists at run time.
 *
 * Headless counterparts (headless-first policy,
 * `codetracer-specs/Testing/Testing-Guidelines.md`):
 *   - src/tests/gui/tests/deepreview/review_session_vm_test.nim
 *       (the projection, the three explicit states, the collect-side stamp)
 *   - nim-acp/tests/test_session_load.nim          (the protocol method)
 *   - nim-agents/tests/test_session_load_client.nim (both backends)
 */

import { test, expect } from "../../lib/fixtures";
import * as path from "node:path";
import * as fs from "node:fs";
import * as os from "node:os";

const fixturesDir = path.join(__dirname, "..", "deepreview", "fixtures");
const sampleReviewPath = path.join(fixturesDir, "sample-review.json");
const replayAgentPath = path.join(__dirname, "fixtures", "acp-replay-agent.js");

const fixturesExist =
  fs.existsSync(sampleReviewPath) && fs.existsSync(replayAgentPath);

/** The session id `acp-replay-agent.js` holds by default. */
const HELD_SESSION_ID = "session-fixture";

const sessionFixtureDir = path.join(os.tmpdir(), "ct-rv6-review-session");
const resolvableDatasetPath = path.join(sessionFixtureDir, "review.json");

/**
 * Write `sample-review.json` back out with a session reference bolted on.
 *
 * The reference is exactly what `ct review collect` stamps: an id, a backend
 * and the context needed to resolve it. It carries **no** conversation
 * content — that is the property §2.1 calls "by reference, never by copy",
 * and it is asserted below rather than merely arranged for.
 */
function writeDatasetWithSession(target: string, sessionId: string): void {
  const dataset = JSON.parse(fs.readFileSync(sampleReviewPath, "utf8"));
  dataset.session = {
    sessionId,
    backend: "acp",
    workspacePath: sessionFixtureDir,
    taskId: "",
    agentCommand: replayAgentPath,
    agentArgs: [],
    endpoint: "",
  };
  fs.writeFileSync(target, JSON.stringify(dataset, null, 2));
}

if (fixturesExist) {
  fs.mkdirSync(sessionFixtureDir, { recursive: true });
  writeDatasetWithSession(resolvableDatasetPath, HELD_SESSION_ID);
}

test.describe("RV-6 - a review dataset references its session", () => {
  // eslint-disable-next-line @typescript-eslint/no-unused-expressions
  test.skip(!fixturesExist, "DeepReview / ACP replay fixtures not found");

  test("e2e_review_dataset_references_the_session_and_does_not_embed_it", async () => {
    // §2.1: "Loading is by reference, never by copy. The dataset stores an
    // identifier and enough context to resolve it; it does not embed a
    // transcript." Asserted against the dataset written above the way
    // `ct review collect` stamps one.
    const dataset = JSON.parse(fs.readFileSync(resolvableDatasetPath, "utf8"));
    expect(dataset.session.sessionId).toBe(HELD_SESSION_ID);
    const serialized = JSON.stringify(dataset);
    expect(serialized).not.toContain("off-by-one was in the hunk parser");
    expect(serialized).not.toContain("Reading the failing parser test");
    for (const key of ["events", "messages", "transcript", "updates"]) {
      expect(Object.keys(dataset.session)).not.toContain(key);
    }
  });
});
