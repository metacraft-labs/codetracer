/**
 * E2E tests for AA-2: a `ct test` run in the session feed renders as a
 * drillable result summary.
 *
 * `codetracer-specs/DeepReview/DeepReview-GUI.md` §2.1.2:
 *
 *   "`ct test` executions in the session are rendered as a **summary of the
 *    run** rather than as raw output: what was run, how many passed, failed
 *    and were skipped, and how long it took."
 *
 *   "The summary is **drillable**: an individual test can be expanded to its
 *    status, duration and captured output."
 *
 *   "Recordings are optional per test. A test with no recording is shown
 *    normally with no drill-down affordance — not with an affordance that
 *    fails when used."
 *
 *   "If recording failed before a trace was produced, the panel shows the
 *    framework output and recorder diagnostics, and must **not** offer a
 *    trace to open."
 *
 * This is the *whole chain* in the shipped product: `ct review <PATH>` reads
 * the dataset's session reference, spawns the referenced stdio ACP agent,
 * issues `session/load` through `nim-agents` / `nim-acp`, the agent replays a
 * session whose tool call carries the runner's real NDJSON as its
 * `rawOutput`, and the renderer parses it with the production projection and
 * paints it. Nothing between the CLI and the DOM is stubbed.
 *
 * TEST DOUBLE JUSTIFICATION (workspace policy). One double, the same one the
 * RV-6 suite uses and for the same documented reasons: the *agent*,
 * `fixtures/acp-replay-agent.js`, whose header explains why a production
 * agent cannot hold a known prior session on demand. The event stream it
 * replays is not invented for the test — it is the byte shape
 * `ct_test/contracts.toJson` emits, arranged into the three cases §2.1.2
 * distinguishes (recorded / never recorded / recording failed). Every
 * CodeTracer-side layer is production code, including the projection
 * (`test_run_summary_vm.nim`) and the view.
 *
 * Headless counterparts (headless-first policy,
 * `codetracer-specs/Testing/Testing-Guidelines.md`):
 *   - src/tests/gui/tests/agent-activity/test_run_summary_vm_test.nim
 *   - src/tests/gui/tests/agent-activity/agent_activity_test_run_view_test.nim
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

const fixtureDir = path.join(os.tmpdir(), "ct-aa2-test-run-session");
const datasetPath = path.join(fixtureDir, "review.json");
const partialDatasetPath = path.join(fixtureDir, "review-partial.json");
/** The directory the recorded test in the replayed run reports as its trace. */
const traceDir = path.join(fixtureDir, "trace");

/**
 * Write `sample-review.json` back out with a session reference that selects
 * one of the replay agent's `ct test` transcripts.
 *
 * The transcript is chosen per invocation via `agentArgs` rather than through
 * the environment: with `--workers=1` every spec file shares one process, so
 * an environment variable set here would leak into the other suites'
 * launches.
 */
function writeDataset(target: string, agentArgs: string[]): void {
  const dataset = JSON.parse(fs.readFileSync(sampleReviewPath, "utf8"));
  dataset.session = {
    sessionId: HELD_SESSION_ID,
    backend: "acp",
    workspacePath: fixtureDir,
    taskId: "",
    agentCommand: replayAgentPath,
    agentArgs,
    endpoint: "",
  };
  fs.writeFileSync(target, JSON.stringify(dataset, null, 2));
}

if (fixturesExist) {
  fs.mkdirSync(traceDir, { recursive: true });
  writeDataset(datasetPath, ["--test-run", `--trace-dir=${traceDir}`]);
  writeDataset(partialDatasetPath, ["--test-run-partial"]);
}

const runCard = ".agent-test-run";

/**
 * One test row, addressed by the name it shows.
 *
 * Deliberately not by the row's DOM id: that id embeds the anchoring
 * message's `<sessionId>:<index>` key, which would couple every assertion
 * here to the fixture transcript's ordering. The name is what a reader of the
 * panel identifies the row by, so it is what the test identifies it by.
 */
function rowNamed(
  page: import("@playwright/test").Page,
  name: string,
): import("@playwright/test").Locator {
  return page.locator(
    `.agent-test-row:has(.agent-test-row-name:text-is("${name}"))`,
  );
}

test.describe("AA-2 - a ct test run renders as a drillable summary", () => {
  // eslint-disable-next-line @typescript-eslint/no-unused-expressions
  test.skip(!fixturesExist, "DeepReview / ACP replay fixtures not found");

  test.use({
    launchMode: "deepreview",
    deepreviewJsonPath: datasetPath,
  });

  test("e2e_ct_test_run_renders_as_a_summary_not_raw_output", async ({
    ctPage,
  }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(1500);

    const panel = ctPage.locator(".agent-ha-container");
    await expect(panel).toBeVisible();

    const card = ctPage.locator(`.agent-ha-container ${runCard}`);
    await expect(card).toHaveCount(1, { timeout: 15000 });

    // The run is summarised, not dumped: one failed, one errored, one passed.
    const status = card.locator(".agent-test-run-status");
    await expect(status).toContainText("1 passed");
    await expect(status).toContainText("1 failed");
    await expect(status).toContainText("1 errored");

    // The card is named by the command the runner reported, not by an
    // invented one.
    await expect(card.locator(".agent-test-run-title")).toContainText("ct-mcr");

    // "in place of raw runner output": the feed shows no NDJSON anywhere.
    const feed = await ctPage.locator(".agent-ha-container .agent-com").innerText();
    expect(feed).not.toContain("schemaVersion");
    expect(feed).not.toContain("recording-created");
    // Not vacuous — the rest of the conversation is there.
    expect(feed).toContain("Recording the calculator tests");
    expect(feed).toContain("One test fails and one could not be recorded.");
  });

  test("e2e_expanding_the_run_lists_its_tests_and_their_outcomes", async ({
    ctPage,
  }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(1500);

    const card = ctPage.locator(`.agent-ha-container ${runCard}`);
    await expect(card).toHaveCount(1, { timeout: 15000 });
    // Collapsed by default.
    await expect(ctPage.locator(".agent-test-row")).toHaveCount(0);

    await card.locator(".agent-test-run-header").click();
    await expect(ctPage.locator(".agent-test-row")).toHaveCount(3);

    const names = await ctPage
      .locator(".agent-test-row .agent-test-row-name")
      .allTextContents();
    expect(names).toEqual(["test_add", "test_sub", "test_mul"]);

    const statuses = await ctPage
      .locator(".agent-test-row .agent-test-row-status")
      .allTextContents();
    expect(statuses).toEqual(["passed", "failed", "errored"]);
  });

  test("e2e_a_test_with_a_recording_offers_the_drill_down", async ({
    ctPage,
  }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(1500);

    const card = ctPage.locator(`.agent-ha-container ${runCard}`);
    await expect(card).toHaveCount(1, { timeout: 15000 });
    await card.locator(".agent-test-run-header").click();

    const recorded = rowNamed(ctPage, "test_add");
    await expect(recorded).toHaveCount(1);
    await expect(
      recorded.locator(".agent-test-row-open-recording"),
    ).toHaveCount(1);
    // Both halves of the --open-policy distinction are reachable.
    await expect(
      recorded.locator(".agent-test-row-open-recording-new-tab"),
    ).toHaveCount(1);
  });

  test("e2e_a_test_without_a_recording_offers_no_drill_down", async ({
    ctPage,
  }) => {
    // §2.1.2: "A test with no recording is shown normally with no drill-down
    // affordance — not with an affordance that fails when used."
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(1500);

    const card = ctPage.locator(`.agent-ha-container ${runCard}`);
    await expect(card).toHaveCount(1, { timeout: 15000 });
    await card.locator(".agent-test-run-header").click();

    const notRecorded = rowNamed(ctPage, "test_sub");
    // Not vacuous: the row rendered, and rendered as failed.
    await expect(notRecorded).toHaveCount(1);
    await expect(notRecorded).toHaveClass(/agent-test-row-failed/);
    await expect(
      notRecorded.locator(".agent-test-row-open-recording"),
    ).toHaveCount(0);
    await expect(notRecorded.locator(".agent-test-row-actions")).toHaveCount(0);

    // Its captured output is still reachable by expanding it.
    await notRecorded.locator(".agent-test-row-header").click();
    await expect(notRecorded.locator(".agent-test-row-output")).toContainText(
      "expected 1, got 2",
    );
  });

  test("e2e_a_failed_recording_shows_diagnostics_and_offers_no_trace", async ({
    ctPage,
  }) => {
    // §2.1.2: "the panel shows the framework output and recorder diagnostics,
    // and must not offer a trace to open."
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(1500);

    const card = ctPage.locator(`.agent-ha-container ${runCard}`);
    await expect(card).toHaveCount(1, { timeout: 15000 });
    await card.locator(".agent-test-run-header").click();

    const broken = rowNamed(ctPage, "test_mul");
    await expect(broken).toHaveCount(1);
    await expect(broken).toHaveClass(/agent-test-row-errored/);
    await expect(broken.locator(".agent-test-row-open-recording")).toHaveCount(
      0,
    );

    await broken.locator(".agent-test-row-header").click();
    await expect(
      broken.locator(".agent-test-row-recording-failed"),
    ).toHaveCount(1);
    await expect(broken.locator(".agent-test-row-diagnostic")).toContainText(
      "did not produce a non-empty .ct artifact",
    );
    await expect(broken.locator(".agent-test-row-output")).toContainText(
      "cannot open perf events",
    );
    // Still nothing to open with the details visible.
    await expect(broken.locator(".agent-test-row-open-recording")).toHaveCount(
      0,
    );
  });

  test("e2e_drilling_into_a_recording_goes_through_the_trace_open_path", async ({
    ctPage,
  }) => {
    // §2.1.2: "opening one uses the existing trace-opening path and tab
    // model".
    //
    // Asserted by its *round trip*, which is the strongest observation this
    // fixture allows and a stronger one than watching the send: clicking the
    // affordance makes the renderer issue `CODETRACER::load-trace-file`, the
    // main process's existing `onLoadTraceFile` looks the path up in the
    // trace metadata store, finds nothing (the fixture's trace directory is
    // not a registered CodeTracer recording), and answers
    // `CODETRACER::trace-load-error` — which the renderer surfaces as an
    // error notification naming the path.  Seeing that sentence proves every
    // hop, *and* proves the spec's other rule at the same time: the outcome
    // of an unopenable trace is a message, never a broken trace tab.
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(1500);

    const card = ctPage.locator(`.agent-ha-container ${runCard}`);
    await expect(card).toHaveCount(1, { timeout: 15000 });
    await card.locator(".agent-test-run-header").click();

    // Nothing has claimed a trace yet.
    await expect(ctPage.locator(".status-notification")).toHaveCount(0);

    await rowNamed(ctPage, "test_add")
      .locator(".agent-test-row-open-recording")
      .click();

    const notification = ctPage.locator(".status-notification");
    await expect(notification).toHaveCount(1, { timeout: 15000 });
    await expect(notification).toContainText("No trace found at");
    // The exact path the row asked for, not its parent directory: the whole
    // reason `onLoadTraceFile` now tries the path as-is is that a `ct test`
    // provider reports the trace's *directory*, and a diagnostic naming
    // `dirname(traceDir)` would report a path nobody requested.
    await expect(notification).toContainText(traceDir);
  });
});

test.describe("AA-2 - a run still in progress renders incrementally", () => {
  // eslint-disable-next-line @typescript-eslint/no-unused-expressions
  test.skip(!fixturesExist, "DeepReview / ACP replay fixtures not found");

  test.use({
    launchMode: "deepreview",
    deepreviewJsonPath: partialDatasetPath,
  });

  test("e2e_a_run_still_in_flight_renders_without_waiting", async ({
    ctPage,
  }) => {
    // §2.1.2: the runner streams "so the ViewModel can update status without
    // waiting for process exit".  The replayed stream here stops after
    // `run-started` + `test-started` — exactly what a panel watching a live
    // run holds mid-flight — and the panel must render it as a run in
    // progress rather than as a finished one, and rather than not at all.
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(1500);

    const card = ctPage.locator(`.agent-ha-container ${runCard}`);
    await expect(card).toHaveCount(1, { timeout: 15000 });
    await expect(card).toHaveClass(/agent-test-run-running/);
    await expect(card.locator(".agent-test-run-status")).toHaveText(
      "1 running",
    );
    // It has not invented an outcome for a test that has not finished.
    const summary = await card.locator(".agent-test-run-status").innerText();
    expect(summary).not.toContain("passed");
    expect(summary).not.toContain("failed");

    // And it is drillable already: the started test is listed, as running,
    // with no recording to offer.
    await card.locator(".agent-test-run-header").click();
    const row = rowNamed(ctPage, "test_add");
    await expect(row).toHaveCount(1);
    await expect(row).toHaveClass(/agent-test-row-running/);
    await expect(row.locator(".agent-test-row-open-recording")).toHaveCount(0);
  });
});
