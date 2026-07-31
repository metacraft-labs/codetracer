/**
 * Guard: no spec may name the retired bottom-tabs wrapper class.
 *
 * `verify_no_spec_locates_auto_hide_bottom_tabs` from Value-Origin-Tracking
 * milestone M47.
 *
 * The class this forbids was the container the pre-redesign status bar
 * wrapped its bottom tabs in.  Commit b27da3947 replaced it: tabs are now
 * direct children of `#auto-hide-bottom-strip`.  Nothing in the app emitted
 * the wrapper afterwards, yet roughly 48 locator sites across 8 spec files
 * kept asking for it — and a Playwright locator that matches nothing is not
 * an error, it is a wait that expires somewhere else.  Those specs looked
 * like they were testing the strip for months while testing nothing.
 *
 * A static check rather than a DOM assertion, because the failure mode is
 * precisely that the DOM never says anything: the class cannot come back as
 * a silent no-match if no spec is allowed to spell it.  The live-DOM half of
 * the contract — the strip exists, its tabs are direct children, and the
 * wrapper is absent from the running app — is asserted by
 * `status-bar-render-stability.spec.ts` and
 * `status-bar-footer-contract.spec.ts`.
 *
 * No browser is launched; this reads the suite's own sources.
 */
import * as fs from "node:fs";
import * as path from "node:path";

import { expect, test } from "@playwright/test";

/** Root of the GUI test package (`src/tests/gui`). */
const guiTestRoot = path.resolve(__dirname, "../..");

/**
 * The one file allowed to spell the retired class: the shared page object,
 * which exports it as `RETIRED_BOTTOM_TABS_SELECTOR` so the single spec that
 * legitimately asserts its *absence* can name it without a literal.
 */
const ALLOWED = new Set([
  path.join("page-objects", "auto-hide-strip.ts"),
  // This file, which has to spell the class in order to forbid it.
  path.join("tests", "status-bar", "bottom-strip-selector-guard.spec.ts"),
]);

/** Directories that are not ours to police. */
const SKIP_DIRS = new Set([
  "node_modules",
  "test-results",
  "test-diagnostics",
  "test-stats",
  ".playwright",
]);

const FORBIDDEN = "auto-hide-bottom-tabs";

function collectSources(dir: string, out: string[]): void {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.isDirectory()) {
      if (SKIP_DIRS.has(entry.name)) continue;
      collectSources(path.join(dir, entry.name), out);
    } else if (entry.isFile() && /\.(ts|tsx|js|mjs)$/.test(entry.name)) {
      out.push(path.join(dir, entry.name));
    }
  }
}

test("verify_no_spec_locates_auto_hide_bottom_tabs", () => {
  const sources: string[] = [];
  collectSources(guiTestRoot, sources);
  expect(
    sources.length,
    "the guard must actually have found the suite's sources",
  ).toBeGreaterThan(50);

  const offenders: string[] = [];
  for (const file of sources) {
    const relative = path.relative(guiTestRoot, file);
    if (ALLOWED.has(relative)) continue;
    const lines = fs.readFileSync(file, "utf8").split(/\r?\n/);
    lines.forEach((line, index) => {
      if (line.includes(FORBIDDEN)) {
        offenders.push(`${relative}:${index + 1}: ${line.trim()}`);
      }
    });
  }

  expect(
    offenders,
    `\`.${FORBIDDEN}\` is not rendered by the app. Bottom-strip tabs are ` +
      "direct children of `#auto-hide-bottom-strip`; locate them through " +
      "`page-objects/auto-hide-strip.ts`.",
  ).toEqual([]);
});
