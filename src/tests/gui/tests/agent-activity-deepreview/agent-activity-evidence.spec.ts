/**
 * E2E tests for AA-3: an evidence tool call in the session feed is a
 * clickable entry that loads the review dataset it produced.
 *
 * `codetracer-specs/DeepReview/DeepReview-GUI.md` §2.1.1:
 *
 *   "When the agent hands a review over, that handoff appears in the session
 *    as a tool call like any other. It gets a **custom rendering** rather
 *    than the generic tool-call line, and it is **actionable**: selecting it
 *    loads the review dataset that call produced."
 *
 *   "The rendering identifies what the evidence *is* — the dataset it points
 *    at, and enough of its shape (file count, the reviewed commit) to be
 *    recognisable without opening it."
 *
 *   "Selecting it enters a review over that dataset through the ordinary
 *    review entry routine (§7, 'Transition into a Review'). It is not a
 *    second way to open a review; it is the same one, reached from the feed."
 *
 *   "A session may contain several evidence calls... Each is independently
 *    selectable."
 *
 *   "A dataset that no longer exists on disk says so when selected, rather
 *    than entering an empty review."
 *
 * This is the *whole chain* in the shipped product: `ct review <PATH>` reads
 * the launch dataset's session reference, spawns the referenced stdio ACP
 * agent, issues `session/load` through `nim-agents` / `nim-acp`, the agent
 * replays a session whose tool calls are the two commands
 * `docs/agent-prompt/deepreview-evidence.md` tells agents to run, and the
 * renderer recognises them with the production projection, asks the main
 * process to read each dataset off disk, and — on a click — enters a review
 * over it through `vcs.openReviewDataset` → `startDeepReviewNavigation` →
 * `review_entry.enterReview`. Nothing between the CLI and the DOM is stubbed.
 *
 * TEST DOUBLE JUSTIFICATION (workspace policy). One double, the same one the
 * RV-6 and AA-2 suites use and for the same documented reasons: the *agent*,
 * `fixtures/acp-replay-agent.js`, whose header explains why a production
 * agent cannot hold a known prior session on demand. The command lines it
 * replays are not invented for the test — they are the pair `ct agent prompt`
 * ships. The review datasets it points at are real dataset files, written
 * from the same `sample-review.json` the rest of the DeepReview suites load,
 * and they are read by production code (`index/review_dataset.nim`, the same
 * reader `--deepreview` uses). Every CodeTracer-side layer is production
 * code, including the recogniser (`evidence_call_vm.nim`) and the view.
 *
 * Headless counterparts (headless-first policy,
 * `codetracer-specs/Testing/Testing-Guidelines.md`):
 *   - src/tests/gui/tests/agent-activity/evidence_call_vm_test.nim
 *   - src/tests/gui/tests/agent-activity/agent_activity_evidence_view_test.nim
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

const fixtureDir = path.join(os.tmpdir(), "ct-aa3-evidence-session");
/** The dataset `ct review <PATH>` is launched over. */
const launchDatasetPath = path.join(fixtureDir, "launch.json");
/** The datasets the replayed session's evidence calls name. */
const evidenceDir = path.join(fixtureDir, "evidence");
const iterationOnePath = path.join(evidenceDir, "iteration-1.json");
const iterationTwoPath = path.join(evidenceDir, "iteration-2.json");
/** Deliberately never written: the "collected, then cleaned up" case. */
const gonePath = path.join(evidenceDir, "gone.json");

function readSample(): Record<string, unknown> {
  return JSON.parse(fs.readFileSync(sampleReviewPath, "utf8"));
}

/**
 * Write a review dataset with a chosen title and a chosen subset of files.
 *
 * Derived from `sample-review.json` rather than hand-written so the datasets
 * the cards open are the same shape every other DeepReview suite loads; only
 * the identity a reviewer would use to tell two reviews apart is changed.
 */
function writeEvidenceDataset(
  target: string,
  title: string,
  fileSlice: [number, number],
): void {
  const dataset = readSample();
  dataset.sessionTitle = title;
  dataset.files = (dataset.files as unknown[]).slice(...fileSlice);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, JSON.stringify(dataset, null, 2));
}

/** The launch dataset, pointed at the replay agent's evidence transcript. */
function writeLaunchDataset(): void {
  const dataset = readSample();
  dataset.session = {
    sessionId: HELD_SESSION_ID,
    backend: "acp",
    workspacePath: fixtureDir,
    taskId: "",
    agentCommand: replayAgentPath,
    agentArgs: ["--evidence", `--evidence-dir=${evidenceDir}`],
    endpoint: "",
  };
  fs.mkdirSync(path.dirname(launchDatasetPath), { recursive: true });
  fs.writeFileSync(launchDatasetPath, JSON.stringify(dataset, null, 2));
}

if (fixturesExist) {
  fs.rmSync(fixtureDir, { recursive: true, force: true });
  writeLaunchDataset();
  // `sample-review.json` covers src/main.rs, src/utils.rs and src/config.rs.
  // The two evidence datasets take *disjoint* slices of it, so switching from
  // one to the other cannot be confused with the panel simply not having
  // refreshed: the changeset, the count and the file that opens all change.
  writeEvidenceDataset(iterationOnePath, "DeepReview: iteration one", [0, 2]);
  writeEvidenceDataset(iterationTwoPath, "DeepReview: iteration two", [2, 3]);
  // `gone.json` is never written — that is the point of it.
  if (fs.existsSync(gonePath)) fs.rmSync(gonePath);
}

const card = ".agent-evidence";

/**
 * One evidence card, addressed by the dataset it names.
 *
 * Deliberately not by the card's DOM id: that id embeds the anchoring
 * message's `<sessionId>:<index>` key, which would couple every assertion
 * here to the fixture transcript's ordering. The dataset is what a reader of
 * the panel identifies the card by, so it is what the test identifies it by.
 */
function cardFor(
  page: import("@playwright/test").Page,
  datasetPath: string,
): import("@playwright/test").Locator {
  return page.locator(
    `${card}:has(.agent-evidence-dataset:text-is("${datasetPath}"))`,
  );
}

test.describe("AA-3 - evidence tool calls are clickable and load their dataset", () => {
  // eslint-disable-next-line @typescript-eslint/no-unused-expressions
  test.skip(!fixturesExist, "DeepReview / ACP replay fixtures not found");

  test.use({
    launchMode: "deepreview",
    deepreviewJsonPath: launchDatasetPath,
  });

  test("e2e_evidence_tool_calls_render_distinctly_from_generic_tool_calls", async ({
    ctPage,
  }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(1500);

    const panel = ctPage.locator(".agent-ha-container");
    await expect(panel).toBeVisible();

    // Five evidence calls in the transcript, five cards.
    await expect(ctPage.locator(`.agent-ha-container ${card}`)).toHaveCount(5, {
      timeout: 15000,
    });

    // The tool-call lines they replaced are gone from the feed…
    const feed = await ctPage
      .locator(".agent-ha-container .agent-com")
      .innerText();
    expect(
      feed.split("ct review collect --repo . --diff main..HEAD").length - 1,
      // Each collect command appears exactly once — inside its own card —
      // rather than twice (card plus generic tool-call line).
    ).toBe(4);
    // …and the rest of the conversation still renders, so "the line is gone"
    // is not satisfied by a panel that drew nothing.
    expect(feed).toContain("Collecting the first review dataset");
    expect(feed).toContain("The tokenizer change is ready to read.");
  });

  test("e2e_the_card_names_the_dataset_and_its_shape", async ({ ctPage }) => {
    // §2.1.1: "the dataset it points at, and enough of its shape (file count,
    // the reviewed commit) to be recognisable without opening it."
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(1500);

    const first = cardFor(ctPage, iterationOnePath);
    await expect(first).toHaveCount(1, { timeout: 15000 });
    await expect(first.locator(".agent-evidence-kind")).toHaveText(
      "Collected review evidence",
    );
    // The shape is a measurement of the file on disk: two files, and the
    // commit the dataset names, abbreviated exactly as the VCS panel header
    // abbreviates it.
    await expect(first.locator(".agent-evidence-shape")).toHaveText(
      "2 files · a1b2c3d4e5f6...",
    );
    // And the command, verbatim, so the reviewer can see what was run.
    await expect(first.locator(".agent-evidence-command")).toContainText(
      "ct review collect",
    );

    const second = cardFor(ctPage, iterationTwoPath);
    await expect(second.locator(".agent-evidence-kind")).toHaveText(
      "Handed over review evidence",
    );
    await expect(second.locator(".agent-evidence-shape")).toHaveText(
      "1 file · a1b2c3d4e5f6...",
    );
  });

  test("e2e_a_missing_dataset_says_so_and_offers_nothing", async ({
    ctPage,
  }) => {
    // §2.1.1: "A dataset that no longer exists on disk says so when selected,
    // rather than entering an empty review."  Met one step earlier than the
    // wording requires — the card knows before the click, so there is no
    // affordance to press, and AA-2's rule holds: where there is nothing to
    // open, emit no affordance at all rather than a disabled one.
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(1500);

    const missing = cardFor(ctPage, gonePath);
    // Not vacuous: the card rendered, and rendered as unavailable.
    await expect(missing).toHaveCount(1, { timeout: 15000 });
    await expect(missing).toHaveClass(/agent-evidence-unavailable/);
    await expect(missing.locator(".agent-evidence-open")).toHaveCount(0);
    await expect(missing.locator(".agent-evidence-actions")).toHaveCount(0);
    // It says what happened, in words, and quotes the reader rather than
    // inventing a reason.
    await expect(missing.locator(".agent-evidence-note")).toContainText(
      "could not be read",
    );
    await expect(missing.locator(".agent-evidence-note")).toContainText(
      gonePath,
    );
    // And it claims no shape it did not measure.
    await expect(missing.locator(".agent-evidence-shape")).toHaveCount(0);
  });

  test("e2e_a_failed_command_and_an_unreported_one_are_told_apart", async ({
    ctPage,
  }) => {
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(1500);

    const failed = cardFor(ctPage, path.join(evidenceDir, "failed.json"));
    await expect(failed).toHaveCount(1, { timeout: 15000 });
    await expect(failed).toHaveClass(/agent-evidence-failed/);
    await expect(failed.locator(".agent-evidence-open")).toHaveCount(0);
    await expect(failed.locator(".agent-evidence-note")).toHaveText(
      "This command failed, so there is no review dataset to open.",
    );
    // The backend's own output is kept, not summarised away.
    await expect(failed.locator(".agent-evidence-output")).toContainText(
      "found no recordings",
    );

    const pending = cardFor(ctPage, path.join(evidenceDir, "pending.json"));
    await expect(pending).toHaveCount(1);
    await expect(pending).toHaveClass(/agent-evidence-unreported/);
    await expect(pending.locator(".agent-evidence-open")).toHaveCount(0);
    // A distinct sentence: a command with no outcome is not a failed one, and
    // rendering the same words for both would defeat the point.
    await expect(pending.locator(".agent-evidence-note")).toHaveText(
      "No outcome has been reported for this command yet.",
    );
  });

  test("e2e_selecting_an_evidence_call_enters_a_review_over_its_dataset", async ({
    ctPage,
  }) => {
    // §2.1.1: "Selecting it enters a review over that dataset through the
    // ordinary review entry routine."
    //
    // Asserted by what the *ordinary* routine does, which is the strongest
    // observation available and a stronger one than watching the IPC: the VCS
    // panel header takes the new dataset's title, its Changed Files list
    // becomes the new dataset's changeset, and §7 step 2 happens — the new
    // review's first file opens in the editor.  Seeing all three proves every
    // hop, because nothing but `enterReview` performs them together.
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(1500);

    // The launch review is what is on screen: three files, its own title.
    await expect(dr.vcsReviewTitle()).toHaveText("DeepReview: parser cleanup");
    await expect(ctPage.locator(".vcs-file-item")).toHaveCount(3);

    const second = cardFor(ctPage, iterationTwoPath);
    await expect(second.locator(".agent-evidence-open")).toHaveCount(1, {
      timeout: 15000,
    });
    await second.locator(".agent-evidence-open").click();

    // The review was replaced, not opened alongside: one review per window,
    // exactly as `ct review <PATH>` gives.
    await expect(dr.vcsReviewTitle()).toHaveText("DeepReview: iteration two", {
      timeout: 15000,
    });
    await expect(ctPage.locator(".vcs-file-item")).toHaveCount(1);
    await expect(ctPage.locator(".vcs-file-item").first()).toContainText(
      "config.rs",
    );
    // §7 step 2: the new review's *first* file opened — the entry one-shot
    // was re-armed for a different dataset, which is the only reason a
    // second review opens anything at all.
    await expect(dr.diffTabs()).toHaveCount(2, { timeout: 15000 });
    // The launch review opened `main.rs`; this review opened its own first
    // file beside it, so the *new* dataset's file is what appeared.
    expect(await dr.layoutTabTitles()).toContain("Diff: config.rs");
  });

  test("e2e_several_evidence_calls_are_independently_selectable", async ({
    ctPage,
  }) => {
    // §2.1.1: "Each is independently selectable, so the reviewer can move
    // between 'what the agent proposed at the time' and 'what it proposed in
    // the end'."
    const dr = new DeepReviewPage(ctPage);
    await dr.waitForReady();
    await wait(1500);

    const first = cardFor(ctPage, iterationOnePath);
    const second = cardFor(ctPage, iterationTwoPath);
    await expect(first.locator(".agent-evidence-open")).toHaveCount(1, {
      timeout: 15000,
    });
    await expect(second.locator(".agent-evidence-open")).toHaveCount(1);

    await second.locator(".agent-evidence-open").click();
    await expect(dr.vcsReviewTitle()).toHaveText("DeepReview: iteration two", {
      timeout: 15000,
    });
    await expect(ctPage.locator(".vcs-file-item")).toHaveCount(1);

    // Moving back to the earlier proposal is one click, and lands on the
    // earlier changeset rather than on a merge of the two.
    await first.locator(".agent-evidence-open").click();
    await expect(dr.vcsReviewTitle()).toHaveText("DeepReview: iteration one", {
      timeout: 15000,
    });
    await expect(ctPage.locator(".vcs-file-item")).toHaveCount(2);

    // The session feed is untouched by entering a review from it: the
    // reviewer can keep moving between proposals.
    await expect(ctPage.locator(`.agent-ha-container ${card}`)).toHaveCount(5);
  });
});
