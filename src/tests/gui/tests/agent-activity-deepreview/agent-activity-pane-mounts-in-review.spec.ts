/**
 * A dataset review (`ct review <PATH>`) creates the Agent Activity pane, not
 * only its tab.
 *
 * codetracer-pm issue 2026-10-22, "`enter_submits_prompt.spec.ts` never
 * finds the Agent Activity tab or its prompt box" (the `deepreview-gui.spec.ts`
 * half: Test 1c, Test 25, DR-8 and RV-4 waited for `.agent-ha-container` and
 * found nothing). The layout a review opens carries an AGENT ACTIVITY tab
 * (DeepReview-GUI.md §2.1, the third pillar), and GoldenLayout made its
 * container. Since the pane moved onto the panel host
 * (`src/frontend/ui/panel_host.nim`), `mountPanel` holds a container until
 * `setPanelSession` installs the session whose ViewModels the pane renders,
 * and that call is made only by `configureMiddleware` in
 * `src/frontend/ui_js.nim`. The trace launch (`onTraceLoaded`) and the edit
 * launch (`onNoTrace`) run it; the dataset review's handler,
 * `onStartDeepReview`, did not, so every panel-host pane of a review — Agent
 * Activity, VCS, Files — waited forever behind a tab that showed an empty
 * container.
 *
 * What this spec holds the product to: after a dataset review launch, bringing
 * the AGENT ACTIVITY tab forward shows the pane (`.agent-ha-container`) and
 * its prompt textarea. It deliberately does not go through
 * `DeepReviewPage.waitForReady`, which waits on the VCS pane: that pane is a
 * second casualty of the same defect, and a spec whose readiness gate fails
 * first could never say which pane was missing.
 *
 * TEST DOUBLE JUSTIFICATION (workspace policy). One double is used: the
 * agent. A mounted pane opens an ACP session, which spawns `codex-acp` from
 * `PATH` (`src/frontend/index/ipc_subsystems/acp_ipc.nim`). The real agent
 * needs a paid account and network access, and whether it is installed on the
 * host would change what the pane shows; nothing about it decides whether the
 * pane is created. So `acp-stub-agent-harness.ts` puts a `codex-acp` wrapper
 * around `../agent-activity/fixtures/acp-refusing-agent.js` first on the
 * launched app's `PATH`. Everything else is production code: `ct review`, the
 * index process, the layout, the panel host and the pane's view.
 *
 * Headless counterpart: none is possible for the defect itself. It is the
 * omission of one call in an Electron IPC handler of `ui_js.nim`, the
 * renderer's entry module, which only loads inside a browser window with the
 * whole renderer. The panel host's own contract (a container waits for the
 * session, and is mounted when it is installed) is behaviour, not the bug.
 * The pane's view is covered headlessly by the `agent_activity_*_view_test.nim`
 * suites in `../agent-activity/`.
 */

import * as fs from "node:fs";
import * as path from "node:path";

import { test, expect } from "../../lib/fixtures";
import {
  isWindows,
  makeStubAgentDir,
  stubAgentLaunchEnv,
} from "../agent-activity/acp-stub-agent-harness";
import { PROMPT_SELECTOR } from "../agent-activity/prompt-input-counter";

const sampleReviewPath = path.join(
  __dirname,
  "..",
  "deepreview",
  "fixtures",
  "sample-review.json",
);

const stub = makeStubAgentDir();

test.describe("DeepReview - the Agent Activity pane is created in a dataset review", () => {
  // eslint-disable-next-line @typescript-eslint/no-unused-expressions
  test.skip(isWindows, "the stub codex-acp wrapper is a POSIX shell script");

  test.use({
    launchMode: "deepreview",
    deepreviewJsonPath: sampleReviewPath,
    launchEnv: stubAgentLaunchEnv(stub),
  });

  test.beforeEach(() => {
    // A missing fixture is a broken checkout, not a reason to pass.
    expect(fs.existsSync(sampleReviewPath), sampleReviewPath).toBe(true);
  });

  test("bringing the AGENT ACTIVITY tab forward shows the pane and its prompt", async ({
    ctPage,
  }) => {
    // The layout carries the tab: GoldenLayout built its container. This is
    // the half that already held while the pane was missing, so it is checked
    // first, to keep the two failures apart.
    const tab = ctPage
      .locator(".lm_title", { hasText: /agent activity/i })
      .first();
    await expect(tab).toBeAttached({ timeout: 30_000 });
    try {
      await tab.click({ timeout: 5_000 });
    } catch {
      // Xvfb can report GoldenLayout tabs as outside the viewport; the tab's
      // handler runs from a synthetic click just as well.
      await tab.dispatchEvent("click");
    }

    // ...and the pane was mounted into it.
    await expect(ctPage.locator(".agent-ha-container").first()).toBeVisible({
      timeout: 30_000,
    });
    await expect(ctPage.locator(PROMPT_SELECTOR).first()).toBeVisible({
      timeout: 30_000,
    });
  });
});
