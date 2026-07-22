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
 * Skip discipline: SKIPs cleanly when the fixture isn't materialised
 * (any of frontend.ct / frontend-wasm.ct / backend.ct missing) or when
 * the `ct` binary is missing. Mirrors the M29 Rust sentinel wording from
 * `cross_process_origin_test.rs` so log greps land on both layers.
 */
import * as fs from "node:fs";
import * as path from "node:path";

import type { Page } from "@playwright/test";

import {
  expect,
  readyOnEntryTest as readyOnEntry,
  test,
} from "../../lib/fixtures";
import {
  isCtBinaryAvailable,
  ctBinaryPath,
} from "../../lib/value-origin-fixtures";

const repoRoot = path.resolve(__dirname, "..", "..", "..", "..");

const fixtureDir = path.join(
  repoRoot,
  "src",
  "db-backend",
  "tests",
  "fixtures",
  "cross_process",
  "account-balance-with-wasm",
);

const HTTP_BOUNDARY_ID = "account-balance-with-wasm";
const JS_WASM_BOUNDARY_ID = "js-wasm-realm";
const REQUIRED_CONTAINERS = ["frontend.ct", "frontend-wasm.ct", "backend.ct"];

// `trace-folder` is the Electron-only fixture path. It launches the real
// CodeTracer binary against the materialized multi-trace session and exposes
// its renderer as `ctPage`; the base Playwright `page` fixture would only
// create an unrelated blank Chromium tab.
test.use({ sourcePath: fixtureDir, launchMode: "trace-folder" });

/** First missing `.ct` container under the fixture root, or null. */
function firstMissingTraceContainer(): string | null {
  for (const name of REQUIRED_CONTAINERS) {
    const candidate = path.join(fixtureDir, name);
    if (!fs.existsSync(candidate)) return candidate;
  }
  return null;
}

function specSkipReason(): string | null {
  if (!isCtBinaryAvailable()) {
    return `ct binary missing at ${ctBinaryPath()} — run \`just build-once\``;
  }
  const missing = firstMissingTraceContainer();
  if (missing !== null) {
    return (
      `SKIPPED: account-balance-with-wasm fixture not materialized: ${missing} ` +
      "(regenerate.sh requires wasm-pack + codetracer_python_recorder + " +
      "codetracer-js-recorder + browser_stream_receiver + Playwright)"
    );
  }
  return null;
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
    skipReason = specSkipReason();
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

    await readyOnEntry(ctPage);

    // §5.1 — both boundary families must render as marker rows. The M25
    // HTTP boundary `account-balance-with-wasm` and the M27 → M25
    // PairIndex-bridge boundary `js-wasm-realm` are the two pairs the
    // fixture's ANSWERS.md pins.
    const httpRow = await readMarkerRow(ctPage, HTTP_BOUNDARY_ID);
    expect(httpRow, "HTTP boundary marker row must render").not.toBeNull();
    expect(httpRow!.chipText).toBe(`[${HTTP_BOUNDARY_ID}]`);
    expect(httpRow!.keyValue, "matches ANSWERS.md").toBe("620");

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

    // §5.3 — click the HTTP marker chip; the active recording must
    // switch to the matched sibling per `EventLogVM.jumpToCounterpart`
    // (routes through `ct/listProcesses` + `ct/goto-ticks`).
    await ctPage
      .locator(
        `div.event-log-marker-rows div.marker-row[data-boundary-id="${HTTP_BOUNDARY_ID}"] ` +
          `span.marker-boundary-chip`,
      )
      .first()
      .click();
    await ctPage.waitForTimeout(1500);

    const activeRole = await ctPage.evaluate(() => {
      const d = (window as any).data;
      return (
        d?.activeRecording?.role ??
        d?.activeProcess?.role ??
        d?.session?.activeProcess?.role ??
        d?.sessions?.[d?.activeSessionIndex ?? 0]?.activeRecording?.role ??
        null
      );
    });
    expect(
      activeRole,
      "click on HTTP marker chip must switch active recording",
    ).toBe("frontend-js");

    // Confirm the editor settles on the JS-side send-marker source
    // location (`frontend/app.js` per ANSWERS.md).
    const labels: string[] = await ctPage.evaluate(() =>
      Array.from(document.querySelectorAll("div[id^='editorComponent']")).map(
        (el) => el.getAttribute("data-label") ?? "",
      ),
    );
    expect(
      labels.some((l) => l.includes("frontend/app.js") || l.endsWith("app.js")),
      `expected an editor tab on frontend/app.js, got: ${labels.join(", ")}`,
    ).toBe(true);
  });
});
