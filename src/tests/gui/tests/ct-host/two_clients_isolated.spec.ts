// Two clients of one `ct host` get independent sessions — CLI/ct/host.md,
// "Sessions are isolated": "Two clients replaying the same trace get
// independent backends and cannot observe each other's position."
//
// Two browser contexts, so two tabs that share nothing (each has its own
// sessionStorage, where a tab keeps the client id it presents to `ct host`),
// open the same `ct host` over real WebSockets. Each tab steps its own
// replay; the other one stays where it was and stays connected. A reload
// presents the tab's id and resumes ITS session, at its position.
//
// The socket.io suite `src/tests/ct_host/test_ct_host_sessions_are_isolated_per_client.nim`
// drives the same rules without a browser; this one is the page itself — the
// toolbar a user clicks, the editor line a user reads — which is HSF-X3's
// "a real browser against a live ct host".
//
// No stand-ins: the real `ct host`, real replays, real browsers.

import type { Page } from "@playwright/test";
import { test, expect } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";
import { retry } from "../../lib/retry-helpers";

test.use({ sourcePath: "noir_space_ship/", launchMode: "trace", deploymentMode: "web" });
// Each case starts its own ct host and replays; on a loaded host that alone
// takes minutes, so the limit is generous rather than tight.
test.setTimeout(360_000);

const CLIENT_ID_KEY = "codetracer.hostClientId";

async function clientIdOf(page: Page): Promise<string> {
  let id = "";
  await retry(
    async () => {
      id = await page.evaluate(
        (key) => window.sessionStorage.getItem(key) ?? "",
        CLIENT_ID_KEY,
      );
      return id.length > 0;
    },
    { maxAttempts: 30, delayMs: 500 },
  );
  return id;
}

async function activeLine(layout: LayoutPage): Promise<number> {
  let line: number | null = null;
  await retry(
    async () => {
      const editors = await layout.editorTabs(true);
      for (const editor of editors) {
        line = await editor.activeLineNumber();
        if (line !== null && line > 0) return true;
      }
      return false;
    },
    { maxAttempts: 60, delayMs: 500 },
  );
  return line ?? -1;
}

async function stepNext(layout: LayoutPage, times: number): Promise<void> {
  // A step has landed when the editor's line moves: in `main` of this
  // program every `next` reaches a new line. Waiting on the thing the test
  // asserts, rather than on a status indicator, keeps the wait honest.
  for (let i = 0; i < times; i++) {
    const before = await activeLine(layout);
    await layout.clickNextButton();
    await retry(
      async () => (await activeLine(layout)) !== before,
      { maxAttempts: 120, delayMs: 500 },
    );
  }
}

test("two clients of one ct host step independently; a reload resumes its own", async ({ ctPage }) => {
  // Tab A: the fixture's page.
  const layoutA = new LayoutPage(ctPage);
  await layoutA.waitForAllComponentsLoaded();
  const idA = await clientIdOf(ctPage);
  const startA = await activeLine(layoutA);
  expect(startA).toBeGreaterThan(0);

  // Tab B: a second, unrelated browser context on the same host.
  const browser = ctPage.context().browser();
  expect(browser).not.toBeNull();
  const contextB = await browser!.newContext();
  try {
    const pageB = await contextB.newPage();
    await pageB.goto(ctPage.url());
    const layoutB = new LayoutPage(pageB);
    await layoutB.waitForAllComponentsLoaded();
    const idB = await clientIdOf(pageB);
    expect(idB).not.toBe(idA);
    const startB = await activeLine(layoutB);
    expect(startB).toBe(startA);

    // A moves. B does not see it.
    await stepNext(layoutA, 3);
    const movedA = await activeLine(layoutA);
    expect(movedA).not.toBe(startA);
    // Give a leaked move every chance to arrive before looking at B.
    await pageB.waitForTimeout(2_000);
    expect(await activeLine(layoutB)).toBe(startB);

    // B moves on its own replay — it was not superseded by A, nor A by B —
    // and A stays where it was.
    await stepNext(layoutB, 1);
    const movedB = await activeLine(layoutB);
    expect(movedB).not.toBe(startB);
    await ctPage.waitForTimeout(2_000);
    expect(await activeLine(layoutA)).toBe(movedA);

    // A reload of B presents B's id and resumes B's session, at B's
    // position, not A's and not the start.
    await pageB.reload();
    const reloadedB = new LayoutPage(pageB);
    await reloadedB.waitForAllComponentsLoaded();
    expect(await clientIdOf(pageB)).toBe(idB);
    expect(await activeLine(reloadedB)).toBe(movedB);
    expect(await activeLine(layoutA)).toBe(movedA);
  } finally {
    await contextB.close();
  }
});

// A DUPLICATED TAB (owner decision 2026-10-23, CLI/ct/host.md "Clients and
// Their Sessions"): the browser's "Duplicate" copies the tab's
// sessionStorage, so the copy starts out holding the original's client id
// while the original is still open. It must get a session of its own, and
// its own reload must resume that one.
//
// Playwright has no "duplicate tab", so this builds exactly what one is: a
// second page in the SAME browser context (so the two tabs share an origin's
// BroadcastChannel, as two tabs of one browser do) whose sessionStorage
// starts with the original's id. The seed is written once, so the
// duplicate's own reload does not plant the original's id again.
test("a duplicated tab gets its own session; its reload resumes its own", async ({ ctPage }) => {
  const layoutA = new LayoutPage(ctPage);
  await layoutA.waitForAllComponentsLoaded();
  const idA = await clientIdOf(ctPage);
  const startA = await activeLine(layoutA);
  expect(startA).toBeGreaterThan(0);

  // The original moves first, so a duplicate that took it over would open
  // at the original's position.
  await stepNext(layoutA, 3);
  const movedA = await activeLine(layoutA);
  expect(movedA).not.toBe(startA);

  const dup = await ctPage.context().newPage();
  try {
    await dup.addInitScript(
      ({ key, id }) => {
        if (window.sessionStorage.getItem("__ct_test_dup_seeded") === null) {
          window.sessionStorage.setItem("__ct_test_dup_seeded", "1");
          window.sessionStorage.setItem(key, id);
        }
      },
      { key: CLIENT_ID_KEY, id: idA },
    );
    await dup.goto(ctPage.url());
    const layoutDup = new LayoutPage(dup);
    await layoutDup.waitForAllComponentsLoaded();

    // Its own id, and its own replay at the start — not the original's.
    const idDup = await clientIdOf(dup);
    expect(idDup).not.toBe(idA);
    expect(await activeLine(layoutDup)).toBe(startA);
    // And the original was not taken over: still connected, still where it
    // was.
    expect(await activeLine(layoutA)).toBe(movedA);

    // The duplicate steps on its own replay; the original stays.
    await stepNext(layoutDup, 1);
    const movedDup = await activeLine(layoutDup);
    expect(movedDup).not.toBe(startA);
    await ctPage.waitForTimeout(2_000);
    expect(await activeLine(layoutA)).toBe(movedA);

    // The original steps; the duplicate stays.
    await stepNext(layoutA, 1);
    const movedA2 = await activeLine(layoutA);
    await dup.waitForTimeout(2_000);
    expect(await activeLine(layoutDup)).toBe(movedDup);

    // The duplicate's reload resumes the duplicate's session.
    await dup.reload();
    const reloadedDup = new LayoutPage(dup);
    await reloadedDup.waitForAllComponentsLoaded();
    expect(await clientIdOf(dup)).toBe(idDup);
    expect(await activeLine(reloadedDup)).toBe(movedDup);
    expect(await activeLine(layoutA)).toBe(movedA2);

    // And the original's reload resumes the original's.
    await ctPage.reload();
    const reloadedA = new LayoutPage(ctPage);
    await reloadedA.waitForAllComponentsLoaded();
    expect(await clientIdOf(ctPage)).toBe(idA);
    expect(await activeLine(reloadedA)).toBe(movedA2);
  } finally {
    await dup.close();
  }
});
