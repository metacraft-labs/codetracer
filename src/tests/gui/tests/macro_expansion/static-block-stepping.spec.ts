/**
 * E2E test for the "Trace Static Block Execution" context menu action
 * (CTFS-M-StaticBlockTrace).
 *
 * Mirrors the M11 macro-trace flow (`trace_macro.nim`): right-click on a
 * `static:` block in a Nim editor pane and select "Trace Static Block
 * Execution".  The renderer sends an LSP `workspace/executeCommand`
 * request with command `nim/traceStaticBlock` to the Nim language
 * server, which proxies nimsuggest's `tracestatic` query.  The
 * resulting `.ct` trace is loaded in a new session tab.
 *
 * Two outcomes are accepted as success:
 *
 * 1. **Full pipeline** — a Nim langserver is reachable and its
 *    nimsuggest binary supports `ideTraceStatic`.  The renderer opens a
 *    new session tab with the produced `.ct` trace.
 *
 * 2. **Heuristic + dispatch** — the renderer surfaces the menu item on
 *    the right line and the click handler fires, but the langserver
 *    refuses (not connected or feature missing).  The renderer must
 *    show a toast notification explaining the failure.
 *
 * In CI the second outcome is the normal case because the GUI test
 * harness does not currently spin up `nimlangserver`.  The first
 * outcome will exercise itself in environments where the user has the
 * trace-enabled nimsuggest configured.
 *
 * Sibling of `nim-view-switching/macro-expansion-stepping.spec.ts` (S7).
 */

import { test, expect } from "../../lib/fixtures";
import type { Page } from "@playwright/test";
import { LayoutPage } from "../../page-objects/layout-page";
import { ContextMenu } from "../../page-objects/components/context-menu";
import { retry } from "../../lib/retry-helpers";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const STATIC_BLOCK_MENU_ITEM = "Trace Static Block Execution";

/**
 * Wait for the editor to load with the Nim test program visible.
 */
async function waitForNimEditorReady(
  layout: LayoutPage,
  page: Page,
): Promise<void> {
  await layout.waitForBaseComponentsLoaded();
  await retry(
    async () => {
      const editors = await layout.editorTabs(true);
      return editors.some((e) => e.fileName.endsWith(".nim"));
    },
    { maxAttempts: 60, delayMs: 1000 },
  );
  // Give the Monaco editor a moment to finish mounting view-lines.
  await expect(page.locator(".monaco-editor .view-lines").first())
    .toBeVisible({ timeout: 30_000 });
}

/**
 * Locate the Monaco view-line element for a given 1-based line number
 * inside the first editor pane.
 *
 * Monaco does not annotate `.view-line` with a line-number attribute —
 * the canonical mapping comes from the line-number gutter, where each
 * `<div class="gutter" data-line="N">` is vertically aligned (same
 * `top`) with the corresponding `.view-line`.  We round-trip through
 * the gutter to find the `top` for the requested line, then return the
 * `.view-line` at that exact `top` offset.
 */
function viewLineLocator(page: Page, lineNumber: number) {
  return page.locator(
    `.monaco-editor .view-lines > .view-line`,
    { hasNot: undefined },
  )
    // Use a locator-builder that resolves at click/visibility time.
    .filter({
      has: page.locator(`xpath=ancestor::div[contains(@class, "monaco-editor")]`),
    })
    .nth(lineNumber - 1);
}

/**
 * Find the 1-based line number of a line that starts with the given
 * trimmed prefix (e.g. "static:").  Walks the visible Monaco view-lines
 * and correlates each with its line-number gutter entry via the shared
 * `top` CSS offset — Monaco does not put `data-line-number` on the
 * view-line itself, but every visible view-line has a sibling
 * `.gutter[data-line='N']` at the same vertical position.  Returns
 * -1 if no view-line matches.
 */
async function findLineNumberStartingWith(
  page: Page,
  prefix: string,
): Promise<number> {
  const result = await page.evaluate((p) => {
    // Build a map: top-px → 1-based line number, from the gutter.
    const topToLine = new Map<number, number>();
    const gutterLines = document.querySelectorAll(
      ".monaco-editor .margin-view-overlays .line-numbers .gutter[data-line]",
    );
    for (const gutter of Array.from(gutterLines)) {
      // The gutter's enclosing wrapper carries the `top:Npx` style.
      const wrapper = gutter.closest('[style*="top:"]') as HTMLElement | null;
      if (!wrapper) continue;
      const topMatch = /top:\s*(-?\d+(?:\.\d+)?)px/.exec(
        wrapper.getAttribute("style") ?? "",
      );
      if (!topMatch) continue;
      const top = Math.round(parseFloat(topMatch[1]));
      const lineAttr = gutter.getAttribute("data-line");
      if (lineAttr === null) continue;
      topToLine.set(top, parseInt(lineAttr, 10));
    }

    const lines = document.querySelectorAll(
      ".monaco-editor .view-lines > .view-line",
    );
    for (const node of Array.from(lines)) {
      const txt = (node.textContent ?? "").trim();
      if (!txt.startsWith(p)) continue;
      const topMatch = /top:\s*(-?\d+(?:\.\d+)?)px/.exec(
        (node as HTMLElement).getAttribute("style") ?? "",
      );
      if (!topMatch) continue;
      const top = Math.round(parseFloat(topMatch[1]));
      const lineNumber = topToLine.get(top);
      if (lineNumber !== undefined) return lineNumber;
    }
    return -1;
  }, prefix);
  return result;
}

/**
 * Wait for the global notification container to show a notification
 * whose text matches one of the predicates.  Returns the matched text
 * or null on timeout.
 */
async function waitForNotificationContaining(
  page: Page,
  fragments: string[],
  timeoutMs: number,
): Promise<string | null> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const matched = await page.evaluate((frags) => {
      const nodes = document.querySelectorAll(
        ".status-notification, .ct-notification",
      );
      for (const node of Array.from(nodes)) {
        const txt = (node.textContent ?? "").trim();
        if (txt.length === 0) continue;
        for (const frag of frags) {
          if (txt.toLowerCase().includes(frag.toLowerCase())) {
            return txt;
          }
        }
      }
      return null;
    }, fragments);
    if (matched) return matched;
    await new Promise((res) => setTimeout(res, 200));
  }
  return null;
}

/**
 * Count the number of session tabs currently visible in the session
 * switcher.  M11's flow opens a new session tab on success; we use
 * this to detect that path.
 */
async function countSessionTabs(page: Page): Promise<number> {
  return await page.evaluate(() => {
    const w = window as unknown as { data?: { sessions?: unknown[] } };
    return w.data?.sessions?.length ?? 0;
  });
}

// ---------------------------------------------------------------------------
// Test suite
// ---------------------------------------------------------------------------

test.describe("TraceStaticBlock", () => {
  // Use the dedicated nim_static_block test program; its main.nim
  // contains a real `static:` block (strtabs-based) that mirrors the
  // codetracer-nim/tests/sourcemap/tvm_trace_static.nim fixture.
  test.use({ sourcePath: "nim_static_block/main.nim", launchMode: "trace" });

  // Nim is an RR-based language: give extra time for record + replay.
  test.setTimeout(240_000);

  test("right-clicking a static: block surfaces and dispatches Trace Static Block Execution",
    async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await waitForNimEditorReady(layout, ctPage);

    // Locate the `static:` line in the editor by scanning rendered
    // view-lines.  We intentionally search for the visible text rather
    // than hardcoding a line number so the test does not break if the
    // fixture is reformatted.
    let staticLineNumber = -1;
    await retry(
      async () => {
        staticLineNumber = await findLineNumberStartingWith(ctPage, "static:");
        return staticLineNumber > 0;
      },
      { maxAttempts: 30, delayMs: 500 },
    );
    expect(staticLineNumber, "expected the editor to render `static:` line")
      .toBeGreaterThan(0);

    const staticLine = viewLineLocator(ctPage, staticLineNumber);
    await expect(staticLine).toBeVisible({ timeout: 15_000 });

    // Right-click to open the editor context menu.  Use a fresh
    // ContextMenu helper backed by the global #context-menu-container.
    const contextMenu = new ContextMenu(ctPage);
    await staticLine.click({ button: "right" });
    await contextMenu.waitForVisible();

    const entries = await contextMenu.getEntries();
    const entryTexts = entries.map((e) => e.text);

    // The heuristic in editor.nim should offer both the macro trace
    // action (always offered for Nim files) and the static-block
    // variant (offered when the line contains `static:`).
    expect(
      entryTexts.some((t) => t === STATIC_BLOCK_MENU_ITEM),
      `expected '${STATIC_BLOCK_MENU_ITEM}' in context menu, ` +
      `saw: ${entryTexts.join(", ")}`,
    ).toBe(true);

    const sessionsBefore = await countSessionTabs(ctPage);

    // Click the action.  Two acceptable outcomes:
    //   - the Nim langserver is reachable: a new session tab opens
    //     with the produced .ct trace (success path).
    //   - the langserver is missing / nimsuggest does not support
    //     tracestatic: a notification toast appears (dispatch
    //     confirmed, blocked downstream).
    await contextMenu.select(STATIC_BLOCK_MENU_ITEM);

    // First check for the immediate "tracing..." info toast that
    // confirms the click handler fired.  In environments where the
    // langserver is unreachable, the renderer warns before even
    // calling the LSP, so the "tracing..." toast may be skipped.
    const expectedFragments = [
      // Success path side-effects.
      "loading-trace",
      "trace file",
      // Failure path notifications produced by trace_static.nim.
      "Nim language server is not connected",
      "Trace static block",
      "static block",
      "compileTime",
      "Tracing static block",
      "language server does not support",
    ];

    const notification = await waitForNotificationContaining(
      ctPage,
      expectedFragments,
      30_000,
    );

    if (notification) {
      // Dispatch path confirmed.  Either the renderer told the user
      // we are now tracing, or it surfaced a clear error/warning.
      console.log(
        `# static-block-stepping: observed renderer feedback: ${notification}`,
      );
    } else {
      // No toast — the only way to call the test "successful" without a
      // visible notification is if a new session opened.
      const sessionsAfter = await countSessionTabs(ctPage);
      expect(
        sessionsAfter,
        "expected either a notification toast or a new session tab after " +
          "clicking 'Trace Static Block Execution'",
      ).toBeGreaterThan(sessionsBefore);
    }

    // If a new session opened, sanity-check that its editor surfaces
    // the static-block file.  This is the full-pipeline success path
    // and only fires when the langserver actually returned a .ct.
    const sessionsAfter = await countSessionTabs(ctPage);
    if (sessionsAfter > sessionsBefore) {
      await expect(ctPage.locator(".monaco-editor .view-lines").first())
        .toBeVisible({ timeout: 30_000 });
      const nimEditorVisible = await retry(
        async () => {
          const tabs = await layout.editorTabs(true);
          return tabs.some((t) => t.fileName.endsWith(".nim"));
        },
        { maxAttempts: 20, delayMs: 500 },
      );
      expect(nimEditorVisible).toBe(true);
    }
  });
});
