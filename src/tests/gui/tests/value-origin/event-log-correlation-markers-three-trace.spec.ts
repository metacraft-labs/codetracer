/**
 * M25b §5.3 — Playwright Layer-3 GUI test for Event Log correlation-marker
 * rendering against the three-trace `account-balance-with-wasm` fixture.
 *
 * Covers M25b Layer-3 verification entry
 * `e2e_event_log_jump_renders_in_codetracer_electron` per
 * `codetracer-specs/Planned-Features/Value-Origin-Tracking.milestones.org`.
 *
 * Renderer-side selectors come from
 * `src/frontend/viewmodel/views/isonim_event_log_view.nim`:
 *   - `div.event-log-marker-rows` — §5.1 marker-row host container
 *   - `div.marker-row[data-boundary-id=…][data-key-value=…]` — per row
 *   - `span.marker-boundary-chip` / `span.marker-direction-icon`
 *
 * and from `src/frontend/viewmodel/views/isonim_process_tree_view.nim`:
 *   - `.ct-process-tree-entry[data-process-role=…][aria-selected=…]`
 *
 * Skip discipline: SKIPs cleanly when the fixture isn't materialised
 * (any of frontend.ct / frontend-wasm.ct / backend.ct missing) or when
 * the `ct` binary is missing. Mirrors the M29 Rust sentinel wording from
 * `cross_process_origin_test.rs` so log greps land on both layers.
 */
import type { Page } from "@playwright/test";

import {
  expect,
  readyOnEntryTest as readyOnEntry,
  test,
} from "../../lib/fixtures";
import {
  threeTraceFixtureSkipReason,
  threeTraceRecordingRoot,
} from "../../lib/value-origin-fixtures";

// Shared with the sibling TCT-M5 spec rather than recomputed here. The
// local `path.resolve(__dirname, "..", "..", "..", "..")` this replaces
// climbed one directory too few — a spec under `tests/value-origin/`
// needs five levels, not four, to reach the repo root — so `fixtureDir`
// pointed at `<repo>/src/src/db-backend/...`, every container looked
// missing, and the spec skipped on every run instead of ever launching.
//
// The recordings are no longer committed: this call runs the demo
// through the real recorders and returns the cache directory they landed
// in, so the marker rows asserted below are the ones today's browser
// recorder emits rather than the ones some earlier build emitted.
const fixtureDir = threeTraceRecordingRoot();

// The HTTP boundary token the fixture's `frontend/app.js` passes to
// `__ct.markCorrelation` (`const BOUNDARY_HTTP = "account-balance";`),
// pinned by the fixture's `ANSWERS.md` and `README.md`. It is NOT the
// fixture directory name — the recordings carried the directory name
// until the fixture was rebuilt as a runnable three-tier demo, and this
// constant was left behind pointing at a token no recording emits.
const HTTP_BOUNDARY_ID = "account-balance";
const JS_WASM_BOUNDARY_ID = "js-wasm-realm";

// `trace-folder` is the Electron-only fixture path. It launches the real
// CodeTracer binary against the materialized multi-trace session and exposes
// its renderer as `ctPage`; the base Playwright `page` fixture would only
// create an unrelated blank Chromium tab.
test.use({ sourcePath: fixtureDir, launchMode: "trace-folder" });

/** One row of the §14.8 process tree, addressed by its manifest role. */
const processEntry = (page: Page, role: string) =>
  page.locator(`.ct-process-tree-entry[data-process-role="${role}"]`);

/**
 * The role of the recording the session is currently debugging.
 *
 * Read off the process tree, which renders `aria-selected="true"` on the
 * row bound to `SessionViewModel.activeProcessRecordingId` — the signal
 * that actually routes DAP requests (see `dap.nim`'s
 * `setActiveSessionThreadId`).
 *
 * This replaces a probe of `window.data.activeRecording.role`, a global
 * that exists nowhere in the product. It was written into `window` by an
 * `importjs` block in `ui/event_log.nim` that fired only for a boundary
 * id equal to the fixture's *directory* name, which no recording emits —
 * so the probe read `null` on every path it tried. Both the fake global
 * and its writer are gone.
 */
async function activeRecordingRole(page: Page): Promise<string | null> {
  return page.evaluate(() => {
    const active = document.querySelector(
      '.ct-process-tree-entry[aria-selected="true"]',
    );
    return active?.getAttribute("data-process-role") ?? null;
  });
}

/** Wait for a marker row carrying `boundaryId` and return its attrs/chip text. */
async function readMarkerRow(
  page: Page,
  boundaryId: string,
  timeoutMs = 30_000,
): Promise<{ keyValue: string; stepId: string; chipText: string } | null> {
  const selector = `div.event-log-marker-rows div.marker-row[data-boundary-id="${boundaryId}"]`;
  try {
    await page.locator(selector).first().waitFor({
      state: "visible",
      timeout: timeoutMs,
    });
  } catch {
    return null;
  }
  return page.evaluate((sel) => {
    const row = document.querySelector(sel) as HTMLElement | null;
    if (!row) return null;
    const chip = row.querySelector("span.marker-boundary-chip");
    return {
      keyValue: row.getAttribute("data-key-value") ?? "",
      stepId: row.getAttribute("data-step-id") ?? "",
      chipText: (chip?.textContent ?? "").trim(),
    };
  }, selector);
}

test.describe("M25b §5.3 — Event Log correlation-marker rendering (three-trace)", () => {
  test.setTimeout(300_000);

  let skipReason: string | null = null;

  test.beforeAll(() => {
    skipReason = threeTraceFixtureSkipReason();
  });

  test.beforeEach(({}, testInfo) => {
    if (skipReason !== null) testInfo.skip(true, skipReason);
  });

  test("e2e_event_log_jump_renders_in_codetracer_electron — both boundary markers render with chip badges", async ({
    ctPage,
  }, testInfo) => {
    if (skipReason !== null) {
      testInfo.skip(true, skipReason);
      return;
    }

    let lastEditorLabels: string[] = [];

    await readyOnEntry(ctPage);

    // The session opens on its first `[[trace]]`, `frontend-js`, and the
    // Event Log shows that recording's marker firings. `frontend.ct` is
    // the only recording that carries both boundary families — verify
    // with `ct print --filter markers frontend.ct`.
    await expect(
      processEntry(ctPage, "frontend-js"),
      "the session must open on its first recording",
    ).toHaveAttribute("aria-selected", "true", { timeout: 30_000 });

    // §5.1 — both boundary families must render as marker rows. The M25
    // HTTP boundary `account-balance` and the M27 → M25
    // PairIndex-bridge boundary `js-wasm-realm` are the two pairs the
    // fixture's ANSWERS.md pins.
    const httpRow = await readMarkerRow(ctPage, HTTP_BOUNDARY_ID);
    expect(httpRow, "HTTP boundary marker row must render").not.toBeNull();
    expect(httpRow!.chipText).toBe(`[${HTTP_BOUNDARY_ID}]`);
    // ANSWERS.md: `send | account-balance | req-0001 | 620 (names result)`.
    // The correlation *key* is the request id; `620` is the shown value.
    // This assertion used to expect the shown value in the key column.
    expect(httpRow!.keyValue, "matches ANSWERS.md").toBe("req-0001");

    const realmRow = await readMarkerRow(ctPage, JS_WASM_BOUNDARY_ID);
    expect(
      realmRow,
      "js-wasm-realm boundary marker row must render",
    ).not.toBeNull();
    expect(realmRow!.chipText).toBe(`[${JS_WASM_BOUNDARY_ID}]`);

    // Every rendered marker row must carry a direction icon (↑/↓).
    const counts = await ctPage.evaluate(() => {
      const rows = Array.from(
        document.querySelectorAll("div.event-log-marker-rows div.marker-row"),
      );
      const withIcon = rows.filter((r) =>
        r.querySelector("span.marker-direction-icon"),
      ).length;
      return { total: rows.length, withIcon };
    });
    expect(counts.withIcon).toBe(counts.total);
    expect(counts.total).toBeGreaterThanOrEqual(2);

    // §5.3 — the jump. The gesture is only meaningful from the side that
    // *received* the value, so switch to the server recording first:
    // `backend.ct` carries exactly one marker, `recv account-balance`,
    // whose counterpart is the `send` in `frontend.ct`. Clicking its
    // chip must therefore land the session in `frontend-js` — a value
    // observed on the server, explained by the browser that sent it,
    // which is the whole §14.8 story in one click.
    await processEntry(ctPage, "backend").click();
    await expect(
      processEntry(ctPage, "backend"),
      "clicking the backend row must select it",
    ).toHaveAttribute("aria-selected", "true", { timeout: 30_000 });

    // The Event Log must follow the active recording: the backend's own
    // `recv account-balance` firing, not the browser's `send`.
    const backendHttpRow = await readMarkerRow(ctPage, HTTP_BOUNDARY_ID);
    expect(
      backendHttpRow,
      "the Event Log must show the newly-active recording's markers",
    ).not.toBeNull();
    expect(backendHttpRow!.keyValue).toBe("req-0001");
    await expect(
      ctPage.locator(
        `div.event-log-marker-rows div.marker-row[data-boundary-id="${HTTP_BOUNDARY_ID}"]`,
      ),
      "backend.ct declares exactly one correlation marker",
    ).toHaveCount(1);

    // §5.3 — click the HTTP marker chip; the active recording must
    // switch to the matched sibling per `EventLogVM.jumpToCounterpartOf`
    // (resolves the counterpart through `ct/pairIndexLookup`, then
    // rotates through `SessionViewModel.onSwitchProcess`).
    await ctPage
      .locator(
        `div.event-log-marker-rows div.marker-row[data-boundary-id="${HTTP_BOUNDARY_ID}"] ` +
          `span.marker-boundary-chip`,
      )
      .first()
      .click();

    await expect
      .poll(() => activeRecordingRole(ctPage), {
        message: "click on HTTP marker chip must switch active recording",
        timeout: 60_000,
      })
      .toBe("frontend-js");

    // Confirm the editor settles on the JS-side send-marker source
    // location (`frontend/app.js` per ANSWERS.md). Polled rather than
    // read once after a fixed sleep: the rotation is asynchronous, and
    // a sleep long enough to be reliable is a sleep that hides how long
    // the gesture actually takes.
    await expect
      .poll(
        async () => {
          const labels: string[] = await ctPage.evaluate(() =>
            Array.from(
              document.querySelectorAll("div[id^='editorComponent']"),
            ).map((el) => el.getAttribute("data-label") ?? ""),
          );
          lastEditorLabels = labels;
          return labels.some(
            (l) => l.includes("frontend/app.js") || l.endsWith("app.js"),
          );
        },
        {
          message: "expected an editor tab on frontend/app.js",
          timeout: 60_000,
        },
      )
      .toBe(true);
    expect(
      lastEditorLabels.some(
        (l) => l.includes("frontend/app.js") || l.endsWith("app.js"),
      ),
      `expected an editor tab on frontend/app.js, got: ${lastEditorLabels.join(", ")}`,
    ).toBe(true);
  });
});
