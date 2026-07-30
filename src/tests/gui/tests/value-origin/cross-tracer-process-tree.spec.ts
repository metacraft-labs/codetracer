/**
 * M42 §14.8 — GUI coverage for the multi-process session surface of the
 * three-tracer `account-balance-with-wasm/` fixture.
 *
 * ## Why this exists alongside `cross-tracer-three-recording.spec.ts`
 *
 * The TCT-M5 acceptance spec is the contract for the whole §14.8
 * gesture and stays exactly as written. It reaches the
 * `const balance = payload.balance;` line by clicking "step over" from
 * the backend recording's entry point, and that route is currently
 * blocked by a replay-engine limitation unrelated to §14.8: in the
 * committed `backend.ct`, "step over" at the last statement of the
 * top-level module (`server.js:108`) does not continue into the next
 * recorded event-loop turn, so the cursor never reaches the request
 * handler. "Step into" and "continue" both advance from that same
 * position, so it is step-over specifically, and it is a stepping
 * defect rather than a process-switching one.
 *
 * This spec therefore reaches the same program point through a
 * different, equally ordinary user gesture — clicking the
 * `handleBalance` frame in the Call Trace pane — so the §14.8 surface
 * itself (process tree, breadcrumb chips, cross-process hop badge,
 * hop-click navigation) is verified end to end against real session
 * data today. It deliberately asserts nothing about stepping.
 *
 * Selectors come from the production renderers:
 * - `viewmodel/views/isonim_process_tree_view.nim`
 *     → `div.ct-process-tree-entry[data-process-role=…]`
 * - `ui/isonim_origin_chain.nim`
 *     → `nav > button.ct-origin-breadcrumb-chip[data-role=…]`
 *       (`[data-placeholder="true"]` on zero-hop spans)
 *     → `li.ct-origin-hop-cross-process > span.ct-origin-cross-process-badge`
 */
import { expect, readyOnEntryTest as readyOnEntry, test } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";
import { OriginChainPanePageObject } from "../../page-objects/originChainPane";
import {
  threeTraceFixtureRoot,
  threeTraceFixtureSkipReason,
} from "../../lib/value-origin-fixtures";

const fixtureRoot = threeTraceFixtureRoot();

test.use({ sourcePath: fixtureRoot, launchMode: "trace-folder" });
test.setTimeout(240_000);

test.beforeAll(() => {
  const reason = threeTraceFixtureSkipReason();
  test.skip(reason !== null, reason ?? "");
});

/** One row of the §14.8 process tree, addressed by its manifest role. */
const processEntry = (page: import("@playwright/test").Page, role: string) =>
  page.locator(`.ct-process-tree-entry[data-process-role="${role}"]`);

test("process_tree_lists_every_recording_and_switches_the_active_one", async ({
  ctPage,
}) => {
  await readyOnEntry(ctPage);
  const layout = new LayoutPage(ctPage);

  // The tree is built from the `ct/listProcesses` payload the backend
  // dispatches at session load, i.e. from `session.toml` — not from
  // anything the renderer invents.
  for (const role of ["frontend-js", "frontend-wasm", "backend"]) {
    await expect(
      processEntry(ctPage, role),
      `process tree must render the ${role} entry`,
    ).toHaveCount(1, { timeout: 30_000 });
  }
  // The session opens on its first `[[trace]]`, which is `frontend-js`.
  await expect(processEntry(ctPage, "frontend-js")).toHaveClass(/\bactive\b/);

  // Switching rotates the active row AND moves the replay cursor into
  // the selected recording, which is what opens its source.
  await processEntry(ctPage, "backend").click();
  await expect(processEntry(ctPage, "backend")).toHaveClass(/\bactive\b/, {
    timeout: 15_000,
  });
  await expect(processEntry(ctPage, "frontend-js")).not.toHaveClass(/\bactive\b/);

  let backendEditor = null as Awaited<ReturnType<typeof layout.editorTabs>>[number] | null;
  for (let attempt = 0; attempt < 30; attempt++) {
    const tabs = await layout.editorTabs(true);
    backendEditor = tabs.find((e) => e.fileName === "server.js") ?? null;
    if (backendEditor) break;
    await ctPage.waitForTimeout(1_000);
  }
  expect(
    backendEditor,
    "switching to the backend process must open server.js in the editor",
  ).toBeTruthy();

  // The State Pane must now show the *backend* recording's locals —
  // proof the switch re-routed the backend, not just the highlight.
  await expect(
    ctPage.locator(`div[id^='stateComponent'] [data-variable-name="http"]`).first(),
    "the backend recording's module-scope locals must load after the switch",
  ).toBeVisible({ timeout: 30_000 });
});

test("origin_chain_panel_spans_all_three_recordings", async ({ ctPage }) => {
  await readyOnEntry(ctPage);
  const origin = new OriginChainPanePageObject(ctPage);

  await expect(processEntry(ctPage, "backend")).toHaveCount(1, {
    timeout: 30_000,
  });
  await processEntry(ctPage, "backend").click();
  await expect(
    ctPage.locator(`div[id^='stateComponent'] [data-variable-name="http"]`).first(),
  ).toBeVisible({ timeout: 30_000 });

  // Reach `const balance = payload.balance;` by stepping *into* from the
  // backend recording's entry point. "Step into" rather than "step over"
  // deliberately: in this recording step-over stalls at the last
  // statement of the top-level module and never enters the request
  // handler, whereas step-into walks the recorded steps in order. That
  // asymmetry is the replay-engine defect noted in the file header; it
  // is not part of the surface under test here, so this spec routes
  // around it rather than asserting on it.
  const balanceRow = ctPage
    .locator(`div[id^='stateComponent'] [data-variable-name="balance"]`)
    .first();
  const layout = new LayoutPage(ctPage);
  for (let i = 0; i < 70 && (await balanceRow.count()) === 0; i++) {
    await layout.stepInButton().click();
    await ctPage.waitForTimeout(400);
  }
  await expect(
    balanceRow,
    "stepping inside handleBalance must surface `balance` in the State Pane",
  ).toBeVisible({ timeout: 15_000 });

  await origin.rightClickRow("balance");
  await origin.clickShowValueOriginMenuItem();
  await expect(origin.sidePanel()).toBeVisible({ timeout: 15_000 });

  // §14.8 breadcrumb chips: one per recording the chain visits. The
  // floor is three real (non-placeholder) chips — the user-visible
  // claim is that all three recordings explain the server's value.
  await expect(origin.breadcrumbChips().first()).toBeVisible({
    timeout: 15_000,
  });
  const substantiveChips = origin
    .sidePanel()
    .locator('nav > button:not([data-placeholder="true"])');
  expect(
    await substantiveChips.count(),
    "the chain must visibly span all three recordings",
  ).toBeGreaterThanOrEqual(3);
  const chipRoles = await substantiveChips.evaluateAll((els) =>
    els.map((e) => e.getAttribute("data-role") ?? ""),
  );
  expect(new Set(chipRoles)).toEqual(
    new Set(["backend", "frontend-js", "frontend-wasm"]),
  );

  // §14.8 cross-process hop badge: at least one hop names the boundary
  // the chain walked and the recording on the far side.
  const crossProcessBadge = origin
    .sidePanel()
    .locator("li.ct-origin-hop-cross-process span.ct-origin-cross-process-badge")
    .first();
  await expect(
    crossProcessBadge,
    "a boundary-crossing hop must carry the cross-process badge",
  ).toBeVisible();
  await expect(crossProcessBadge).toHaveText("account-balance");

  // Clicking a chip rotates the active recording (§14.8 "Clicking a
  // chip jumps to the relevant process's editor").
  const chipCountBefore = await origin.breadcrumbChips().count();
  await substantiveChips
    .filter({ hasText: "frontend-wasm" })
    .first()
    .click();
  await expect(processEntry(ctPage, "frontend-wasm")).toHaveClass(/\bactive\b/, {
    timeout: 15_000,
  });

  // The chain panel is owned by the session, not by the per-process
  // State Pane, so it survives the switch intact.
  await expect(origin.sidePanel()).toBeVisible();
  await expect(origin.breadcrumbChips()).toHaveCount(chipCountBefore);
});
