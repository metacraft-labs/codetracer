// The Files pane of a `ct host` page keeps the tree the page loaded once the
// server's session reaches the page.
//
// Under `ct host` the server owns the client's session and the page renders a
// mirror of it (Shared-DOM-Front-Ends, "Server-managed sessions"). The file
// tree is the exception: the page loads it itself, over its own IPC to the
// index (`CODETRACER::filesystem-loaded`, and `load-path-content` for each
// folder it opens), and its actions run on the page. The server's session
// never loads a tree, so its `FilesystemVM` stays at "Loading...".
//
// The page's mirror used to apply the server's file-tree signals like any
// other: the tree appeared, and when the server's first snapshot arrived (the
// replay's first stop, seconds later) the pane went back to "Loading..." for
// good. `mirror_session.HostedPageOwnedSignals` keeps them the page's; the
// headless half of this is `test_session_mirroring.nim`, "the page's file
// tree is the page's".
//
// The call trace is what tells this test the server's session has reached
// the page: its rows are loaded on the server's session, from the viewport
// the page relays, and arrive in the page's mirror only after the snapshot.
//
// No stand-ins: the real `ct host`, a real replay, a real browser.

import type { Page } from "@playwright/test";
import { test, expect } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";
import { retry } from "../../lib/retry-helpers";

test.use({ sourcePath: "noir_space_ship/", launchMode: "trace", deploymentMode: "web" });
// Starting a ct host and its replay takes minutes on a loaded host.
test.setTimeout(360_000);

interface FilesPaneState {
  busy: string | null;
  loadingShown: boolean;
  labels: string[];
}

async function filesPaneState(page: Page): Promise<FilesPaneState> {
  return await page.evaluate(() => {
    const pane = document.querySelector("div[id^='filesystemComponent']");
    const tree = pane?.querySelector(".filesystem") ?? null;
    const loading = pane?.querySelector(".filesystem-loading-overlay") ?? null;
    return {
      busy: tree?.getAttribute("aria-busy") ?? null,
      loadingShown:
        loading !== null && !loading.classList.contains("hidden"),
      labels: [...(pane?.querySelectorAll("a.jstree-anchor") ?? [])].map(
        (e) => e.textContent.trim(),
      ),
    };
  });
}

async function calltraceRows(page: Page): Promise<number> {
  return await page
    .locator("div[id^='calltraceComponent'] .calltrace-call-line")
    .count();
}

test("the Files pane keeps the page's tree after the server's session syncs", async ({ ctPage }) => {
  const layout = new LayoutPage(ctPage);
  await layout.waitForAllComponentsLoaded();

  // The server's session has reached the page: its call trace is shown.
  await retry(async () => (await calltraceRows(ctPage)) > 0, {
    maxAttempts: 240,
    delayMs: 500,
  });

  // The page's tree, not the server's "Loading...": the recording's source
  // folder `src` with the program's two files.
  let state: FilesPaneState = { busy: null, loadingShown: true, labels: [] };
  try {
    await retry(
      async () => {
        state = await filesPaneState(ctPage);
        return (
          state.busy === "false" &&
          !state.loadingShown &&
          state.labels.includes("src") &&
          state.labels.includes("shield.nr")
        );
      },
      { maxAttempts: 60, delayMs: 500 },
    );
  } catch {
    // Fall through: the assertions below say what the pane showed instead.
  }
  expect(state.loadingShown, JSON.stringify(state)).toBe(false);
  expect(state.busy).toBe("false");
  expect(state.labels).toContain("src");
  expect(state.labels).toContain("shield.nr");

  // A move publishes the server's session again; the tree stays.
  const before = await ctPage
    .locator(".monaco-editor .margin .line-numbers.active-line-number")
    .first()
    .textContent();
  await layout.clickNextButton();
  await retry(
    async () =>
      (await ctPage
        .locator(".monaco-editor .margin .line-numbers.active-line-number")
        .first()
        .textContent()) !== before,
    { maxAttempts: 120, delayMs: 500 },
  );
  await ctPage.waitForTimeout(2_000);
  const afterMove = await filesPaneState(ctPage);
  expect(afterMove.loadingShown, JSON.stringify(afterMove)).toBe(false);
  expect(afterMove.labels).toContain("shield.nr");

  // The tree is usable: a file in it that no editor shows yet opens in one.
  const [files] = await layout.filesystemTabs(true);
  expect(files).toBeDefined();
  await files.clickTab();
  await ctPage
    .locator(
      "div[id^='filesystemComponent'] li.jstree-leaf > a.jstree-anchor:text-is('shield.nr')",
    )
    .first()
    .click();
  await retry(
    async () =>
      (await ctPage.locator(".lm_title", { hasText: "shield.nr" }).count()) > 0,
    { maxAttempts: 60, delayMs: 500 },
  );
});
