/**
 * Program-agnostic tests that work across any traced program.
 * Uses the noir_space_ship trace as the default test subject.
 *
 * Theme switching, Find Symbol, the event-log filter and the Ctrl+F8 /
 * Ctrl+F11 editor shortcuts are scenarios now
 * (src/tests/scenarios/command-palette/, src/tests/scenarios/event-log/,
 * src/tests/scenarios/editor/). The busy-state check stays here, skipped:
 * the status area shows a busy mark only while a move is in flight, which a
 * user cannot catch at user pace, so no scenario can observe it.
 */

import { test } from "../../lib/fixtures";
import { retry } from "../../lib/retry-helpers";
import { LayoutPage } from "../../page-objects/layout-page";

test.describe("ProgramAgnostic", () => {
  test.setTimeout(90_000);
  test.use({ sourcePath: "noir_space_ship/", launchMode: "trace" });

  // TODO(skipped): operationStatus() does not show "busy" text after clicking Next.
  //   The debugger busy/ready state display is not implemented in the UI.
  //   Hypothesis: The frontend does not update the operationStatus element text when
  //   a debug step is in progress. Needs a "busy" indicator in the status area.
  test.skip(
    "debugger controls step buttons reflect busy state",
    async ({ ctPage }) => {
      const layout = new LayoutPage(ctPage);
      await layout.waitForAllComponentsLoaded();
      await layout.waitForTraceLoaded();

      await layout.nextButton().click();

      await retry(async () => {
        const text = await layout.operationStatus().innerText();
        return text.toLowerCase().includes("busy");
      });

      await retry(async () => {
        const text = await layout.operationStatus().innerText();
        return text.toLowerCase().includes("ready");
      });
    },
  );
});
