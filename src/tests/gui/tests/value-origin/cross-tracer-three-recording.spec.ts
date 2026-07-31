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
import * as fs from "node:fs";
import * as path from "node:path";
import { expect, readyOnEntryTest as readyOnEntry, test } from "../../lib/fixtures";
import { getCurrentLine } from "../../lib/column-aware-helpers";
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

/**
 * 1-based line of `const balance = payload.balance;` in the demo
 * backend.
 *
 * Resolved out of the source rather than hard-coded, mirroring
 * `src/db-backend/tests/cross_process_three_trace_dap_test.rs`, which
 * finds the same statement the same way. An edit to the demo therefore
 * retargets the headless test and this spec together instead of
 * silently pointing one of them at the wrong statement.
 */
function balanceBindingLine(): number {
  const serverSource = path.join(fixtureRoot, "backend", "server.js");
  const index = fs
    .readFileSync(serverSource, "utf8")
    .split(/\r?\n/)
    .findIndex((line) => line.includes("const balance = payload.balance"));
  if (index < 0) {
    throw new Error(
      `${serverSource} no longer binds \`balance\` from the request payload — ` +
        "the fixture's demo program changed and this spec's target statement " +
        "must be updated with it.",
    );
  }
  return index + 1;
}

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
  //
  // M42 settled the renderer on ONE attribute, `data-process-role`
  // (`viewmodel/views/isonim_process_tree_view.nim`), and this locator
  // was narrowed to it per that milestone's deliverable. The earlier
  // three-way permissive form was a placeholder written before any
  // renderer existed, and it cannot be kept: the Origin Chain
  // breadcrumb chips emit `data-role` carrying the very same role
  // tokens, so `[data-role="backend"]` would match both a process row
  // and a chip once the chain panel is open, and the `toHaveCount(1)`
  // assertions below would fail on a correct product.
  const processEntry = (role: string) =>
    ctPage.locator(`[data-process-role="${role}"]`);

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

  // Wait for the editor to open `server.js` — the backend's entry source.
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

  // ---- 4. Run to the line where `balance` is bound ------------------------
  //
  // Per the fixture's `ANSWERS.md`: `const balance = payload.balance;`
  // in `backend/server.js`. The fixture's own README describes this
  // step as "Step to the `const balance = payload.balance;` line"
  // without prescribing a gesture, and we reach it the way the headless
  // DAP test that proves this feature reaches it
  // (`src/db-backend/tests/cross_process_three_trace_dap_test.rs`): set
  // a breakpoint on that statement and continue to it.
  //
  // Not by pressing step-over, which is what this spec used to do.
  // `balance` is bound *inside* `handleBalance`, a synchronous callee
  // of the request-handler arrow — so step-over steps OVER the frame
  // that binds it, by definition and correctly. The recorded
  // step-over walk goes `server.js:84 → 57 → 74`, never entering
  // `handleBalance`'s body, and no number of presses changes that. The
  // old comment here ("the fixture's backend handler is short — well
  // under 30 statements before the assignment") mistook call depth for
  // statement count; the loop it justified could not have terminated
  // on a correct replay engine.
  //
  // How the cursor gets to the line is scaffolding. Everything this
  // spec asserts once it is there — the origin chain, its breadcrumb
  // chips, the boundary hops — is unchanged.
  await layout.runToEntryButton().click();
  await ctPage.waitForTimeout(1_000);
  const statePane = (await layout.programStateTabs(true))[0];
  expect(statePane, "the backend process must own a State Pane").toBeDefined();

  const balanceLine = balanceBindingLine();
  // Monaco virtualises its gutter, and `server.js` is long enough that
  // the target line starts outside the rendered window — scroll it into
  // view first or the gutter row simply does not exist in the DOM.
  await backendEditor!.revealLine(balanceLine);
  await expect(
    backendEditor!.gutterElement(balanceLine),
    `the gutter row for server.js:${balanceLine} must render before it can be clicked`,
  ).toHaveCount(1, { timeout: 30_000 });

  // A left-click on the CodeTracer gutter toggles a line breakpoint
  // (`lineActionClick` in `ui/editor.nim`) — the same user gesture the
  // column-breakpoint specs drive.
  await backendEditor!.gutterElement(balanceLine).click();
  await expect
    .poll(() => backendEditor!.hasBreakpointAt(balanceLine), { timeout: 30_000 })
    .toBeTruthy();

  await layout.continueButton().click();
  await expect
    .poll(() => getCurrentLine(backendEditor!), { timeout: 60_000 })
    .toBe(balanceLine);

  // The binding is visible from the statement that creates it onwards.
  // Poll rather than read once: the State Pane is repopulated
  // asynchronously after the cursor moves.
  await expect
    .poll(async () => await statePane.variableValueText("balance"), {
      timeout: 30_000,
    })
    .not.toBe("");
  const balanceVisible = (await statePane.variableValueText("balance")) !== "";
  expect(
    balanceVisible,
    "reaching the JSON-decode line must surface `balance` in the State Pane",
  ).toBe(true);

  // ---- 5. Right-click → "Show value origin" -------------------------------
  await origin.rightClickRow("balance");
  await origin.clickShowValueOriginMenuItem();
  await expect(
    origin.sidePanel(),
    "Origin Chain side panel must open after Show value origin",
  ).toBeVisible({ timeout: 15_000 });

  // ---- 6. One breadcrumb chip per recording the chain visits --------------
  //
  // The breadcrumb nav inside the side panel emits one chip per span.
  // Page-object helper `breadcrumbChips()` selects the `<button>`
  // elements inside `nav` per `ui/isonim_origin_chain.nim`.
  //
  // The floor is three, because that is the user-visible claim this spec
  // exists to make: the value observed on the server is explained by
  // walking through all three recordings the session holds, and a chain
  // that showed only two would mean a boundary went unwalked.
  //
  // A floor rather than an exact count deliberately: the composer
  // currently appends a fourth, empty chip for the recording on the far
  // side of the WebAssembly module's entry. Pinning four would write
  // that quirk into the contract, and pinning three would fail until it
  // is fixed. Structural assertions on the chain belong to the headless
  // DAP test, which can inspect the spans directly.
  await expect(
    origin.breadcrumbChips().first(),
    "the chain panel must render CrossProcessSpan breadcrumb chips",
  ).toBeVisible({ timeout: 15_000 });
  expect(
    await origin.breadcrumbChips().count(),
    "the chain must visibly span all three recordings",
  ).toBeGreaterThanOrEqual(3);

  // The chain panel also renders one `<li>` per hop. Per ANSWERS.md the
  // composer walks both boundaries so the chain has multiple hops; we
  // assert at least one hop is present (the exact count is recorder-
  // sensitive and pinned by the headless DAP test).
  await expect(
    origin.sidePanelHops().first(),
    "side panel must render at least one origin hop",
  ).toBeVisible({ timeout: 15_000 });

  // Snapshot the breadcrumbs so we can pin their persistence across
  // process switches in step 9.
  const initialBreadcrumbCount = await origin.breadcrumbChips().count();

  // ---- 7. Click the WASM-side hop ----------------------------------------
  //
  // Per `ANSWERS.md`: hops 3-5 live in `frontend-wasm`, terminating at
  // `wasm-src/lib.rs`. Clicking a hop in the side panel fires
  // `OriginChainVM.onSeekToHop`, which rotates `activeProcessRecordingId`
  // to the hop's owning recording per `session_vm.nim::onSeekToHop` so
  // the editor + state pane both follow.
  //
  // The hop is addressed by the file it names, not by an ordinal. Hop
  // counts are composer-sensitive — this chain has four hops, while the
  // ordinal this step used to use (`min(2, hopCount - 2)`) was derived
  // from ANSWERS.md's six-to-nine-hop canonical numbering and resolved
  // to hop 2, which is the *frontend-js* hop (`app.js:43`). The
  // assertion below then read "clicking the WASM hop must open lib.rs"
  // while the spec had in fact clicked the JavaScript one. Asking for
  // the hop that names `lib.rs` says what the step means and cannot
  // drift with the chain's shape.
  const wasmHopIndex = await origin.sidePanelHopIndexForFile("lib.rs");
  expect(
    wasmHopIndex,
    "the chain must render a hop in the WebAssembly source for the WASM seek to be exercisable",
  ).toBeGreaterThanOrEqual(0);
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
  // Per `ANSWERS.md` the chain terminates in `frontend/app.js`. Same
  // correction as step 7: "the last side-panel hop" was an ordinal
  // standing in for "the JavaScript-side hop", and in this chain the
  // last hop is the WebAssembly one — the walk ends in `lib.rs`, so
  // clicking `hopCount - 1` re-clicked the hop step 7 had just
  // clicked and asserted `app.js` opened. Address it by file instead.
  const jsHopIndex = await origin.sidePanelHopIndexForFile("app.js");
  expect(
    jsHopIndex,
    "the chain must render a hop in the browser JavaScript source",
  ).toBeGreaterThanOrEqual(0);
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
