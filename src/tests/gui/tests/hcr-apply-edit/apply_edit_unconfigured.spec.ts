/**
 * H4 — a REFUSAL from the apply-edit command reaches the screen, by name.
 *
 * This is a small test and it is not a consolation prize for the big one. The
 * reason the apply-edit path is routed through the UI at all, rather than left
 * as a terminal command, is that the *refusals* arrive too: a hot-reload tool
 * that declines an edit and says so only in a log leaves whoever is standing at
 * the screen with a program that did not change and no reason why. This asserts
 * that the product tells them which thing is missing, by the name of the thing.
 *
 * It lives in its own file rather than beside the hot-reload test because
 * `makeCleanEnv` in `lib/fixtures.ts` snapshots `process.env` when it launches
 * Electron. "Configured" and "not configured" are therefore two different
 * launches, and two different launches cannot be two tests in one module.
 *
 * Nothing is configured here on purpose. `delete` rather than "just don't set"
 * because the runner's own environment may carry these from a sibling spec or
 * from the operator's shell, and a test whose precondition depends on what the
 * shell happened to export is not one.
 */
import * as path from "node:path";
import { test, expect } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";

for (const name of [
  "CODETRACER_HCR_APPLY_EDIT_CMD",
  "CODETRACER_HCR_SOCKET",
  "CODETRACER_HCR_DRIVER",
  "CODETRACER_HCR_EDIT",
  "CODETRACER_HCR_WAIT_FOR",
  "CODETRACER_HCR_MARKER",
  "CODETRACER_HCR_MARKER_TIMEOUT_MS",
]) {
  delete process.env[name];
}

// The command itself IS configured: this test is about a missing running
// target, not a missing command, and the two produce different sentences.
const CODETRACER_REPO = path.resolve(__dirname, "../../../../..");
process.env.CODETRACER_HCR_APPLY_EDIT_CMD = path.join(
  path.dirname(CODETRACER_REPO),
  "codetracer-flame-demo",
  "scripts",
  "ct_hcr_apply_edit.py",
);

test.describe("H4 — the apply-edit command's refusals reach the screen", () => {
  test.setTimeout(180_000);
  test.use({ sourcePath: "py_console_logs/main.py", launchMode: "trace" });

  test("with no running target configured, the refusal names what is missing", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForAllComponentsLoaded();
    await layout.waitForTraceLoaded();

    await ctPage.keyboard.press("Control+KeyP");
    const input = ctPage.locator("#command-query-text");
    await expect(input).toBeVisible({ timeout: 15_000 });
    await input.fill(":Apply Edit");
    const hit = ctPage
      .locator(".command-results .command-result.command-command")
      .filter({ hasText: "Apply Edit & Hot-Reload" })
      .first();
    await expect(hit).toBeVisible({ timeout: 15_000 });
    await hit.click();

    // Matched on the NAME of the refusal and on the NAME of the missing thing.
    // "a notification appeared" would be satisfied by "an error occurred",
    // which is exactly the message this whole path exists to avoid producing.
    await expect(
      ctPage.locator(".status-notification").filter({ hasText: "refused: not-configured" }),
    ).toBeVisible({ timeout: 60_000 });
    await expect(
      ctPage.locator(".status-notification").filter({ hasText: "CODETRACER_HCR_SOCKET" }),
    ).toBeVisible({ timeout: 15_000 });
  });
});
