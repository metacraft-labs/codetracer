/**
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

import { test, expect, wait } from "../../lib/fixtures";
import * as path from "node:path";
import * as fs from "node:fs";
import * as os from "node:os";

import { DeepReviewPage } from "../deepreview/page-objects/deepreview-page";

const fixturesDir = path.join(__dirname, "..", "deepreview", "fixtures");
const sampleReviewPath = path.join(fixturesDir, "sample-review.json");
const replayAgentPath = path.join(__dirname, "fixtures", "acp-replay-agent.js");

const fixturesExist =
  fs.existsSync(sampleReviewPath) && fs.existsSync(replayAgentPath);

/** The session id `acp-replay-agent.js` holds by default. */
const HELD_SESSION_ID = "session-fixture";

const sessionFixtureDir = path.join(os.tmpdir(), "ct-rv6-review-session");
const resolvableDatasetPath = path.join(sessionFixtureDir, "review.json");
const prunedDatasetPath = path.join(sessionFixtureDir, "review-pruned.json");

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
  // The agent does not hold this one, and answers "unknown session" — the
  // pruned-session case.
  writeDatasetWithSession(prunedDatasetPath, "session-pruned");
}

test.describe("RV-6 - a resolvable session reference renders the conversation", () => {
  // eslint-disable-next-line @typescript-eslint/no-unused-expressions
  test.skip(!fixturesExist, "DeepReview / ACP replay fixtures not found");

  test.use({
    launchMode: "deepreview",
    deepreviewJsonPath: resolvableDatasetPath,
  });

  test("e2e_review_renders_the_referenced_agent_sessions_messages", async ({
    ctPage,
  }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(1500);

    const panel = ctPage.locator(".agent-ha-container");
    await expect(panel).toBeVisible();

    const messages = ctPage.locator(".agent-ha-container .msg-content");
    // The five updates the held session replays.
    await expect(messages).toHaveCount(5, { timeout: 15000 });

    const texts = await messages.allTextContents();
    // What the agent actually said, in the order it said it.
    expect(texts[0]).toContain("Reading the failing parser test");
    // An event with no text of its own is named by what it did, never blank.
    expect(texts[1]).toContain("Run the parser tests");
    expect(texts[3]).toContain("off-by-one was in the hunk parser");

    // A conversation that speaks for itself carries no explanatory notice.
    await expect(
      ctPage.locator(".agent-ha-container .agent-session-notice"),
    ).toHaveCount(0);

    // The review itself is unaffected: the VCS panel still has the changeset.
    await expect(dr.vcsReviewStats()).toContainText("3 files");
  });

  test("e2e_review_session_is_the_whole_of_what_the_panel_shows", async ({
    ctPage,
  }) => {
    // RV-6 made the session primary and folded the coverage roll-up beneath
    // it; AA-1 removed the roll-up, so §2.1 is now literal — "the primary
    // thing the panel shows in a review is the agent session that produced
    // it", with nothing else in the panel to be primary *over*.
    //
    // Asserted on the rendered DOM rather than on the ViewModel, because the
    // ordering this replaces was a DOM fact and its successor is too: the
    // conversation is the panel's whole body above the prompt.
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(1500);

    const layout = await ctPage.evaluate(() => {
      const panel = document.querySelector(".agent-ha-container");
      if (!panel) return null;
      const kids = Array.from(panel.children).map((c) => c.className);
      return {
        conversation: kids.findIndex((c) => c.includes("agent-com")),
        interaction: kids.findIndex((c) => c.includes("agent-interaction")),
        rollUpHosts: kids.filter((c) => c.includes("deepreview")).length,
      };
    });
    expect(layout).not.toBeNull();
    expect(layout!.conversation).toBe(0);
    expect(layout!.interaction).toBeGreaterThan(layout!.conversation);
    expect(layout!.rollUpHosts).toBe(0);
    await expect(dr.reviewActivityRollUpArtefacts()).toHaveCount(0);
  });

  test("e2e_review_dataset_references_the_session_and_does_not_embed_it", async () => {
    // §2.1: "Loading is by reference, never by copy. The dataset stores an
    // identifier and enough context to resolve it; it does not embed a
    // transcript." Asserted against the file the product just reviewed —
    // including that opening the review did not write the conversation back
    // into it.
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

test.describe("RV-6 - an unresolvable session reference says so explicitly", () => {
  // eslint-disable-next-line @typescript-eslint/no-unused-expressions
  test.skip(!fixturesExist, "DeepReview / ACP replay fixtures not found");

  test.use({
    launchMode: "deepreview",
    deepreviewJsonPath: prunedDatasetPath,
  });

  test("e2e_review_pruned_session_renders_an_explicit_state", async ({
    ctPage,
  }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(1500);

    const notice = ctPage.locator(".agent-ha-container .agent-session-notice");
    await expect(notice).toHaveCount(1, { timeout: 15000 });
    const text = await notice.textContent();
    // It names the session, so the reviewer knows which one is gone …
    expect(text).toContain("session-pruned");
    // … and quotes the agent's own reason rather than inventing one.
    expect(text).toContain("unknown session");

    // And it is a *statement*, not an empty panel: there is no conversation,
    // which is exactly the state that would otherwise read as "the agent did
    // nothing" (§2.1 names that a defect).
    await expect(
      ctPage.locator(".agent-ha-container .msg-content"),
    ).toHaveCount(0);

    // The review is still a complete review.
    await expect(dr.vcsReviewStats()).toContainText("3 files");
  });
});

test.describe("RV-6 - a dataset with no session reference reviews normally", () => {
  // eslint-disable-next-line @typescript-eslint/no-unused-expressions
  test.skip(!fixturesExist, "DeepReview fixtures not found");

  test.use({ launchMode: "deepreview", deepreviewJsonPath: sampleReviewPath });

  test("e2e_review_without_a_session_reference_shows_no_session_and_no_error", async ({
    ctPage,
  }) => {
    // §2.1: "A dataset collected by a human, or by an agent whose backend
    // cannot replay sessions, is a complete review; the panel simply shows no
    // session rather than an error or an empty shell."
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(1500);

    await expect(
      ctPage.locator(".agent-ha-container .agent-session-notice"),
    ).toHaveCount(0);
    await expect(
      ctPage.locator(".agent-ha-container .msg-content"),
    ).toHaveCount(0);

    // …and with no session there is nothing else for the panel to fall back
    // on: RV-1..RV-5 left a coverage roll-up open here, and AA-1 removed it.
    // An empty panel is the honest rendering of "this review names no
    // session"; a summary of the dataset would be the panel answering a
    // question nobody asked.
    await expect(dr.agentActivityPanel()).toBeVisible();
    await expect(dr.reviewActivityRollUpArtefacts()).toHaveCount(0);
    const panelText =
      (await dr.agentActivityPanel().textContent()) ?? "";
    expect(panelText).not.toContain("83.3%");
  });
});
