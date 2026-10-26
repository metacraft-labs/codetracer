/**
 * plat54-agent-activity-capture.spec.ts — PLAT-54, the desktop's column: the
 * REFERENCE the terminal's and the GPUI window's Agent Activity panes are
 * measured against.
 *
 * Spec: codetracer-pm `spec/DeepReview/DeepReview-GUI.md` §2.1 (§2.1.1 the
 * evidence cards, §2.1.2 the `ct test` run summaries).
 *
 * The real Electron front-end launched by `ct review <dataset>` over a
 * dataset whose session reference names the AA suites' ACP replay agent —
 * the same two transcripts the native suites resolve (`--evidence` and
 * `--test-run`) — its Agent Activity pane read from the DOM:
 *
 *   * the evidence session: every card in order — its state (the
 *     `agent-evidence-<state>` class), kind, shape, dataset, command, note,
 *     whether it offers "Open review", its failing command's output — and
 *     what a right-click on a card opens;
 *   * the test-run session: the run card's title, status line and state, and
 *     after a press on its header every test row's outcome, name, duration
 *     and whether it offers its recording.
 *
 * Written to `src/tests/visual/answers/plat54-agent-activity.electron.json`,
 * which `src/frontend/tui/tests/test_plat54_agent_activity.nim` asserts the
 * native feed against (`just plat54-capture-electron`). The evidence
 * directory is written as `<evidence>` and the trace directory as `<trace>`,
 * so the answers do not depend on where the capture ran.
 *
 * TEST DOUBLE JUSTIFICATION (workspace policy): the agent,
 * `fixtures/acp-replay-agent.js`, whose header explains why a production
 * agent cannot hold a known prior session on demand. Everything on
 * CodeTracer's side — `ct review`, `nim-agents`, the renderer's projection
 * and view — is production code.
 */
import { test, expect, wait } from "../../lib/fixtures";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

import { DeepReviewPage } from "../deepreview/page-objects/deepreview-page";

const repoRoot = path.resolve(__dirname, "..", "..", "..", "..", "..");
const answersDir = path.join(repoRoot, "src", "tests", "visual", "answers");
const answersFile = path.join(answersDir, "plat54-agent-activity.electron.json");
const fixturesDir = path.join(__dirname, "..", "deepreview", "fixtures");
const sampleReviewPath = path.join(fixturesDir, "sample-review.json");
const replayAgentPath = path.join(__dirname, "fixtures", "acp-replay-agent.js");

const fixtureDir = path.join(os.tmpdir(), "ct-plat54-capture");
const evidenceDir = path.join(fixtureDir, "evidence");
const traceDir = path.join(fixtureDir, "trace");
const evidenceLaunch = path.join(fixtureDir, "evidence-launch.json");
const testRunLaunch = path.join(fixtureDir, "test-run-launch.json");

function readSample(): Record<string, unknown> {
  return JSON.parse(fs.readFileSync(sampleReviewPath, "utf8"));
}

/** The native suites' datasets: the same titles and the same file slices. */
function writeEvidenceDataset(target: string, title: string,
                              slice: [number, number]): void {
  const dataset = readSample();
  dataset.sessionTitle = title;
  dataset.files = (dataset.files as unknown[]).slice(...slice);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, JSON.stringify(dataset, null, 2));
}

function writeLaunch(target: string, agentArgs: string[]): void {
  const dataset = readSample();
  dataset.session = {
    sessionId: "session-fixture",
    backend: "acp",
    workspacePath: fixtureDir,
    taskId: "",
    agentCommand: replayAgentPath,
    agentArgs,
    endpoint: "",
  };
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, JSON.stringify(dataset, null, 2));
}

fs.rmSync(fixtureDir, { recursive: true, force: true });
fs.mkdirSync(traceDir, { recursive: true });
writeEvidenceDataset(path.join(evidenceDir, "iteration-1.json"), "Iteration one", [0, 2]);
writeEvidenceDataset(path.join(evidenceDir, "iteration-2.json"), "Iteration two", [2, 3]);
writeLaunch(evidenceLaunch, ["--evidence", `--evidence-dir=${evidenceDir}`]);
writeLaunch(testRunLaunch, ["--test-run", `--trace-dir=${traceDir}`]);

/** Where the capture ran, written as the placeholders the answers use. */
function portable(text: string): string {
  return text.split(evidenceDir).join("<evidence>").split(traceDir).join("<trace>");
}

function merge(part: Record<string, unknown>): void {
  fs.mkdirSync(answersDir, { recursive: true });
  const prior = fs.existsSync(answersFile)
    ? JSON.parse(fs.readFileSync(answersFile, "utf8"))
    : {};
  fs.writeFileSync(answersFile,
    JSON.stringify(Object.assign(prior, part), null, 2) + "\n");
}

test.describe("PLAT-54 — the desktop's Agent Activity, captured", () => {
  test.describe("the evidence session", () => {
    test.use({ launchMode: "deepreview", deepreviewJsonPath: evidenceLaunch });

    test("plat54_capture_the_evidence_cards", async ({ ctPage }) => {
      const dr = new DeepReviewPage(ctPage);
      await dr.waitForReady();
      await wait(1500);
      const cards = ctPage.locator(".agent-ha-container .agent-evidence");
      await expect(cards).toHaveCount(5, { timeout: 15000 });
      // Every dataset answered before the read: no card still "reading".
      await expect(ctPage.locator(".agent-evidence-reading")).toHaveCount(0,
        { timeout: 15000 });
      const captured = await cards.evaluateAll((els) => els.map((el) => {
        const text = (cls: string) => {
          const n = el.querySelector("." + cls);
          return n ? (n.textContent || "") : null;
        };
        const state = Array.from(el.classList)
          .find((c) => c.startsWith("agent-evidence-")) || "";
        return {
          state: state.replace("agent-evidence-", ""),
          kind: text("agent-evidence-kind"),
          shape: text("agent-evidence-shape"),
          dataset: text("agent-evidence-dataset"),
          command: text("agent-evidence-command"),
          note: text("agent-evidence-note"),
          open: el.querySelector(".agent-evidence-open") !== null,
          output: text("agent-evidence-output"),
        };
      }));
      const evidence = captured.map((c) => {
        const out: Record<string, unknown> = {};
        for (const [k, v] of Object.entries(c)) {
          out[k] = typeof v === "string" ? portable(v) : v;
        }
        return out;
      });
      // What a right-click on a card opens: the desktop's panel registers no
      // menu of its own — measured, so the native panes are measured
      // against it rather than against an assumption.
      await cards.first().click({ button: "right" });
      let menu: string[] = [];
      try {
        await ctPage.locator("#context-menu-container")
          .waitFor({ state: "visible", timeout: 3_000 });
        menu = await ctPage.locator("#context-menu-container .context-menu-item")
          .allInnerTexts();
      } catch {
        menu = [];
      }
      merge({ evidence, contextMenu: menu });
    });
  });

  test.describe("the test-run session", () => {
    test.use({ launchMode: "deepreview", deepreviewJsonPath: testRunLaunch });

    test("plat54_capture_the_run_card", async ({ ctPage }) => {
      const dr = new DeepReviewPage(ctPage);
      await dr.waitForReady();
      await wait(1500);
      const card = ctPage.locator(".agent-ha-container .agent-test-run");
      await expect(card).toHaveCount(1, { timeout: 15000 });
      const state = await card.evaluate((el) =>
        (Array.from(el.classList).find((c) => c.startsWith("agent-test-run-")) || "")
          .replace("agent-test-run-", ""));
      const title = await card.locator(".agent-test-run-title").textContent();
      const status = await card.locator(".agent-test-run-status").textContent();
      await card.locator(".agent-test-run-header").click();
      const rows = card.locator(".agent-test-row");
      await expect(rows).toHaveCount(3, { timeout: 15000 });
      const tests = await rows.evaluateAll((els) => els.map((el) => ({
        outcome: (el.querySelector(".agent-test-row-status")?.textContent) || "",
        name: (el.querySelector(".agent-test-row-name")?.textContent) || "",
        duration: (el.querySelector(".agent-test-row-duration")?.textContent) || "",
        recording: el.querySelector(".agent-test-row-open-recording") !== null,
      })));
      merge({
        testRun: {
          state,
          title: portable(title || ""),
          status: portable(status || ""),
          tests,
        },
      });
    });
  });
});
