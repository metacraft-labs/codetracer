/**
 * TCT-M5 — GUI Playwright spec for the three-tracer
 * `account-balance-with-wasm/` Value Origin fixture.
 *
 * Drives the user-visible end-to-end scenario per
 * `codetracer-specs/Planned-Features/Cross-Tracer-Origin-Test.audit.md`
 * § TCT-M5:
 *
 *   "Launch Electron with the 3-trace `session.toml`, right-click
 *    `balance` in the backend, assert the chain panel renders three
 *    `CrossProcessSpan` breadcrumb chips, seek across the WASM hop,
 *    switch active process twice."
 *
 * This is the user-visible E2E that proves a CodeTracer-novice can
 * right-click a value in the back-end and see the front-end
 * expression that produced it through TWO recording-boundary hops
 * (backend ↔ frontend-js HTTP + frontend-js ↔ frontend-wasm
 * realm-boundary), per the fixture's `ANSWERS.md`.
 *
 * **Skip discipline.** The fixture's `regenerate.sh` is honestly
 * gated on `wasm-pack` + the wasm32 rustup target +
 * `codetracer-js-recorder` + `codetracer-python-recorder` +
 * `browser_stream_receiver` + Playwright — none of which the dev
 * shell ships by default. When any of the three `.ct` containers
 * (`frontend.ct` / `frontend-wasm.ct` / `backend.ct`) is missing on
 * disk, the spec SKIPs cleanly with the precise sentinel from
 * `threeTraceFixtureSkipReason()` — mirror of the
 * `test_origin_three_trace_chain_balance_to_frontend_expression`
 * skip pattern in `src/db-backend/tests/cross_process_origin_test.rs`.
 * The spec does NOT silently fall back to a synthetic chain when
 * the fixture is absent — that would mask a genuine regression in
 * the cross-process composer or the GUI ViewModel wiring.
 *
 * Once `regenerate.sh` is wired into CI, the spec flips SKIP → PASS
 * without source changes.
 */
import { expect, readyOnEntryTest as readyOnEntry, test } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";
import { OriginChainPanePageObject } from "../../page-objects/originChainPane";
import {
  threeTraceFixtureRoot,
  threeTraceFixtureSkipReason,
} from "../../lib/value-origin-fixtures";

/**
 * The fixture root holds three materialised `.ct` containers + a
 * `session.toml.template`. The harness `launchMode: "trace-folder"`
 * path uses `ct host --trace-path <folder>` which inspects the
 * folder for any `.ct` file — when CI regenerates the fixture the
 * three containers land here, and Electron opens the session.
 */
const fixtureRoot = threeTraceFixtureRoot();

test.use({ sourcePath: fixtureRoot, launchMode: "trace-folder" });
test.setTimeout(240_000);

test.beforeAll(() => {
  const reason = threeTraceFixtureSkipReason();
  test.skip(reason !== null, reason ?? "");
});

/**
 * `e2e_origin_cross_tracer_three_recording_balance_chain`
 *
 * Single end-to-end test that walks the spec contract from steps 1
 * through 9 — process tree renders three entries, right-click on
 * `balance` opens the chain panel with three `CrossProcessSpan`
 * breadcrumb chips, seek across the WASM hop, seek to the JS
 * terminator, and confirm the chain panel survives process
 * switches. The single-test shape mirrors the JavaScript canonical
 * spec — TCT-M5 acceptance is a single end-to-end pass/fail per the
 * audit doc.
 */
test("e2e_origin_cross_tracer_three_recording_balance_chain", async ({ ctPage }) => {
  await readyOnEntry(ctPage);
  const layout = new LayoutPage(ctPage);
  const origin = new OriginChainPanePageObject(ctPage);

  // ---- 1 & 2. Process tree mounts with three entries ----------------------
  //
  // The renderer materialises one process-tree entry per `[[trace]]` in
  // the session manifest (see `viewmodel/session_vm.nim::setProcessTree`).
  // We probe for the three canonical roles emitted by the
  // `ct/listProcesses` reply (`frontend-js` / `frontend-wasm` / `backend`).
  // The exact DOM selector is forward-tolerant: the renderer may live
  // under `[data-role="..."]` (current ViewModel wire shape) or a
  // future `.ct-process-tree-entry[data-role="..."]` rendering. We use
  // a permissive locator that matches either.
  const processEntry = (role: string) =>
    ctPage.locator(
      `[data-process-role="${role}"], [data-role="${role}"], ` +
        `.ct-process-tree-entry[data-role="${role}"]`,
    );

  for (const role of ["frontend-js", "frontend-wasm", "backend"]) {
    await expect(
      processEntry(role),
      `process tree must render the ${role} entry`,
    ).toHaveCount(1, { timeout: 30_000 });
  }

  // ---- 3. Activate the backend process tab --------------------------------
  //
  // `SessionViewModel.onSwitchProcess` rotates `activeProcessRecordingId`
  // and rebinds `stateVM` to the selected process per the M29 wire-shape
  // tests (`session_vm_multi_process_test.nim`). The renderer's click
  // handler dispatches the same call.
  await processEntry("backend").first().click();

  // Wait for the editor to open `server.py` — the backend's entry source.
  let backendEditor = null as Awaited<ReturnType<typeof layout.editorTabs>>[number] | null;
  for (let attempt = 0; attempt < 30; attempt++) {
    const tabs = await layout.editorTabs(true);
    backendEditor = tabs.find((e) => e.fileName === "server.py") ?? null;
    if (backendEditor) break;
    await ctPage.waitForTimeout(1_000);
  }
  expect(
    backendEditor,
    "switching to the backend process must open server.py in the editor",
  ).toBeTruthy();

  // ---- 4. Step over to the line where `balance` is bound -----------------
  //
  // Per the fixture's `ANSWERS.md`: `balance = payload["balance"]` at
  // `backend/server.py:43`. We run-to-entry then step-over until the
  // State Pane surfaces a non-empty `balance` local. The fixture's
  // backend handler is short (≤30 effective Python statements before
  // the assignment); a 30-iteration cap covers it with margin.
  await layout.runToEntryButton().click();
  await ctPage.waitForTimeout(1_000);
  const statePane = (await layout.programStateTabs(true))[0];
  expect(statePane, "the backend process must own a State Pane").toBeDefined();

  let balanceVisible = (await statePane.variableValueText("balance")) !== "";
  for (let i = 0; i < 30 && !balanceVisible; i++) {
    await layout.nextButton().click();
    await ctPage.waitForTimeout(500);
    balanceVisible = (await statePane.variableValueText("balance")) !== "";
  }
  expect(
    balanceVisible,
    "stepping over the JSON-decode line must surface `balance` in the State Pane",
  ).toBe(true);

  // ---- 5. Right-click → "Show value origin" -------------------------------
  await origin.rightClickRow("balance");
  await origin.clickShowValueOriginMenuItem();
  await expect(
    origin.sidePanel(),
    "Origin Chain side panel must open after Show value origin",
  ).toBeVisible({ timeout: 15_000 });

  // ---- 6. Three `CrossProcessSpan` breadcrumb chips -----------------------
  //
  // Per `ANSWERS.md`: the chain carries three `CrossProcessSpan`
  // entries — one per recording (`backend` / `frontend-wasm` /
  // `frontend-js`). The breadcrumb nav inside the side panel emits one
  // chip per span. Page-object helper `breadcrumbChips()` selects the
  // `<button>` elements inside `nav` per `ui/isonim_origin_chain.nim`.
  await expect(
    origin.breadcrumbChips(),
    "three `CrossProcessSpan` breadcrumb chips — one per recording",
  ).toHaveCount(3, { timeout: 15_000 });

  // The chain panel also renders one `<li>` per hop. Per ANSWERS.md the
  // composer walks both boundaries so the chain has multiple hops; we
  // assert at least one hop is present (the exact count is recorder-
  // sensitive and pinned by the headless DAP test).
  await expect(
    origin.sidePanelHops().first(),
    "side panel must render at least one origin hop",
  ).toBeVisible({ timeout: 15_000 });

  // Snapshot the hops + breadcrumbs so we can pin their persistence
  // across process switches in step 9.
  const initialBreadcrumbCount = await origin.breadcrumbChips().count();
  const initialHopCount = await origin.sidePanelHops().count();

  // ---- 7. Click the WASM-side hop ----------------------------------------
  //
  // Per `ANSWERS.md`: hops 3-5 live in `frontend-wasm`, terminating at
  // `wasm-src/lib.rs`. Clicking a hop in the side panel fires
  // `OriginChainVM.onSeekToHop`, which rotates `activeProcessRecordingId`
  // to the hop's owning recording per `session_vm.nim::onSeekToHop` so
  // the editor + state pane both follow.
  //
  // The hop index is chain-shape-sensitive (the fixture can have 6 or
  // 9 hops depending on whether the §14.3 serialisation-aware collapse
  // is applied). We pick a middle hop that ANSWERS.md places in the
  // WASM span (hop 4 / hop 5 in the canonical numbering). Clamp to the
  // available range so the spec is resilient to minor composer churn.
  const wasmHopIndex = Math.min(2, Math.max(0, initialHopCount - 2));
  await origin.clickSidePanelHop(wasmHopIndex);
  await ctPage.waitForTimeout(1_000);

  await expect(
    processEntry("frontend-wasm"),
    "process-tree entry for frontend-wasm should remain present after the seek",
  ).toHaveCount(1, { timeout: 15_000 });

  // After the seek the editor opens the WASM source. The lib.rs tab
  // appears under the editor pane when `compute_balance` is the
  // current frame. We poll across editor tabs because the harness
  // refreshes the tab cache lazily.
  let wasmEditor = null as Awaited<ReturnType<typeof layout.editorTabs>>[number] | null;
  for (let attempt = 0; attempt < 20; attempt++) {
    const tabs = await layout.editorTabs(true);
    wasmEditor = tabs.find((e) => e.fileName === "lib.rs") ?? null;
    if (wasmEditor) break;
    await ctPage.waitForTimeout(750);
  }
  expect(
    wasmEditor,
    "clicking the WASM hop must open compute_balance in wasm-src/lib.rs",
  ).toBeTruthy();

  // ---- 8. Click the JS-side terminator hop -------------------------------
  //
  // Per `ANSWERS.md`: hops 6-8 live in `frontend-js`. Hop 7 is the
  // `TrivialCopy` terminator carrying `userId = 42` at
  // `frontend/app.js:31`. We click the last side-panel hop — the chain
  // walks most-recent-first per spec §4.4, so the final hop is the
  // terminator-side leaf in the JS recording.
  const refreshedHopCount = await origin.sidePanelHops().count();
  const jsHopIndex = Math.max(0, refreshedHopCount - 1);
  await origin.clickSidePanelHop(jsHopIndex);
  await ctPage.waitForTimeout(1_000);

  await expect(
    processEntry("frontend-js"),
    "process-tree entry for frontend-js should remain present after the JS seek",
  ).toHaveCount(1, { timeout: 15_000 });

  let jsEditor = null as Awaited<ReturnType<typeof layout.editorTabs>>[number] | null;
  for (let attempt = 0; attempt < 20; attempt++) {
    const tabs = await layout.editorTabs(true);
    jsEditor = tabs.find((e) => e.fileName === "app.js") ?? null;
    if (jsEditor) break;
    await ctPage.waitForTimeout(750);
  }
  expect(
    jsEditor,
    "clicking the JS terminator hop must open frontend/app.js",
  ).toBeTruthy();

  // The terminator row inside the side panel renders the leaf
  // expression (`42` per the fixture's `userId = 42` literal). We
  // assert it remains visible — the panel must not collapse when the
  // active process rotates.
  await expect(
    origin.sidePanelTerminator(),
    "terminator row must remain visible after the JS seek",
  ).toBeVisible();

  // ---- 9. Switch active process twice via the process tree ---------------
  //
  // The chain panel must survive process switches per the M29
  // ViewModel wire-shape: `OriginChainVM` is owned by the session,
  // not by the per-process `StateVM`, so it persists when
  // `activeProcessRecordingId` rotates.
  await processEntry("frontend-wasm").first().click();
  await ctPage.waitForTimeout(750);
  await expect(
    origin.sidePanel(),
    "chain panel must survive a frontend-wasm switch",
  ).toBeVisible();
  await expect(
    origin.breadcrumbChips(),
    "breadcrumb count must persist across a frontend-wasm switch",
  ).toHaveCount(initialBreadcrumbCount);

  await processEntry("backend").first().click();
  await ctPage.waitForTimeout(750);
  await expect(
    origin.sidePanel(),
    "chain panel must survive a backend switch",
  ).toBeVisible();
  await expect(
    origin.breadcrumbChips(),
    "breadcrumb count must persist across a backend switch",
  ).toHaveCount(initialBreadcrumbCount);
});
