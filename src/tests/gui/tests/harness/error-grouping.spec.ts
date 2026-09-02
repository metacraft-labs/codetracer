/**
 * Self-test for the harness's renderer-error reporter.
 *
 * The reporter this covers replaced a line that printed only a COUNT
 * (`FAIL JS errors (1257)`) followed by the first 50 entries. On the failure
 * that motivated it, all 1257 entries were one `nimCopy` throw re-firing on
 * every reactive write, so the count said "1257 problems" when there was one,
 * and the 50-entry dump was the same line 50 times. These assertions pin the
 * property that makes the reporter worth reading: **distinct causes, first
 * occurrence, with the stack** -- and, critically, that a genuinely second
 * fault is NOT collapsed into the first.
 *
 * Pure functions only -- no Electron, no app, runs in milliseconds.
 */

import { test, expect } from "@playwright/test";
import {
  groupErrorsBySignature,
  formatErrorGroups,
} from "../../lib/error-grouping";

/** One `nimCopy` throw as the collector records it, at write number `n`. */
function nimCopyThrow(n: number): string {
  return [
    "[pageerror] TypeError: Cannot read properties of undefined (reading 'slice')" +
      ` | details: {"stack":"...","message":"...","writeSeq":"${n}"}`,
    `    at nimCopy (file:///app/index.js:204:${34 + (n % 3)})`,
    `    at nimCopyAux (file:///app/index.js:496:36)`,
    `    at storeReactiveValue__abc123_u${18 + (n % 5)} (file:///app/index.js:767:15)`,
    `    at writeSignal__abc123_u${40 + n} (file:///app/index.js:778:5)`,
  ].join("\n");
}

test.describe("harness: renderer error grouping", () => {
  test("1257 repeats of one fault report as one distinct cause", () => {
    const errors = Array.from({ length: 1257 }, (_, i) => nimCopyThrow(i));

    const groups = groupErrorsBySignature(errors);

    expect(groups).toHaveLength(1);
    expect(groups[0].count).toBe(1257);
    expect(groups[0].firstIndex).toBe(0);
    // The reported entry is the FIRST occurrence, complete with its stack --
    // not a synthesised summary.
    expect(groups[0].first).toBe(errors[0]);
    expect(groups[0].first).toContain("at nimCopy");
  });

  test("a second, different fault is not collapsed into the first", () => {
    const errors = [
      ...Array.from({ length: 40 }, (_, i) => nimCopyThrow(i)),
      "[pageerror] TypeError: monaco.editor.create is not a function\n" +
        "    at mountEditor (file:///app/index.js:9001:3)",
      ...Array.from({ length: 40 }, (_, i) => nimCopyThrow(i + 40)),
    ];

    const groups = groupErrorsBySignature(errors);

    expect(groups).toHaveLength(2);
    // Order is by first occurrence, so the earliest cause leads.
    expect(groups[0].count).toBe(80);
    expect(groups[0].first).toContain("reading 'slice'");
    expect(groups[1].count).toBe(1);
    expect(groups[1].firstIndex).toBe(40);
    expect(groups[1].first).toContain("monaco.editor.create is not a function");
  });

  test("two callers of one runtime helper stay distinct", () => {
    // Same message, different topmost frame -- two defects, not one.
    const a =
      "[pageerror] TypeError: Cannot read properties of undefined (reading 'slice')\n" +
      "    at nimCopy (file:///app/index.js:204:34)";
    const b =
      "[pageerror] TypeError: Cannot read properties of undefined (reading 'slice')\n" +
      "    at splitSourceLines (file:///app/index.js:5150:22)";

    expect(groupErrorsBySignature([a, b, a, b])).toHaveLength(2);
  });

  test("the printed report leads with totals and then the first stack", () => {
    const errors = Array.from({ length: 1257 }, (_, i) => nimCopyThrow(i));

    const lines = formatErrorGroups(errors);

    expect(lines[0]).toBe("  FAIL JS errors: 1257 total, 1 distinct");
    expect(lines[1]).toBe("  FAIL JS error [1/1] x1257, first at index 0:");
    // The stack follows, indented, so the cause is readable without opening
    // the diagnostics file.
    expect(lines.slice(2).join("\n")).toContain("at nimCopy");
    expect(lines.slice(2).join("\n")).toContain("at storeReactiveValue");
  });

  test("an empty bucket prints nothing at all", () => {
    expect(formatErrorGroups([])).toEqual([]);
  });

  test("more distinct causes than the cap are counted, not dropped silently", () => {
    const errors = Array.from(
      { length: 14 },
      (_, i) => `[pageerror] Error: distinct fault ${i}\n    at f${i} (file:///a.js:1:1)`,
    );

    const lines = formatErrorGroups(errors, 10);

    expect(lines[0]).toBe("  FAIL JS errors: 14 total, 14 distinct");
    expect(lines[lines.length - 1]).toBe(
      "    ... and 4 more distinct errors",
    );
  });
});
