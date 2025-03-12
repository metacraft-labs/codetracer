import { test, expect } from "@playwright/test";
import {
  window,
  page,
  // wait,
  // debugCodetracer,
  readyOnEntryTest as readyOnEntry,
  loadedEventLog,
  ctRun,
} from "./lib/ct_helpers";
import { StatusBar } from "./page_objects/status_bar";

ctRun("noir_example/");

const ENTRY_LINE = 17;

test("we can access the browser window, not just dev tools", async () => {
  const title = await window.title();
  expect(title).toBe("CodeTracer");
  await window.focus("div");
});

test("correct entry status path/line", async () => {
  await readyOnEntry();

  const statusBar = new StatusBar(page, page.locator(".status-bar"));
  const simpleLocation = await statusBar.location();
  expect(simpleLocation.path.endsWith("main.nr")).toBeTruthy();
  expect(simpleLocation.line).toBe(ENTRY_LINE);
});

// TODO: run tests serially if in the same instance (?)
//   for now we're passing `--workers=1` to prevent parallelism: is this sufficient?
//   maybe we should use groups instead, as we might want parallelism in the future
//  (on the other hand, codetracer/backend itself might use parallelism, so we wouldn't want to parallelize tests in all cases)

test("expected event count", async () => {
  await loadedEventLog();

  const raw = await page.$eval(
    ".data-tables-footer-rows-count",
    (el) => el.textContent ?? "",
  );

  expect(raw.endsWith("2")).toBeTruthy();
  expect(raw.endsWith("1")).toBeFalsy();
});

test("state panel loaded initially", async () => {
  await readyOnEntry();
  await expect(page.locator("#code-state-line-0")).toContainText(
    "17 | println(",
  );
});

// TODO
// test("state panel after jump to end of run function", async () => {
//   await readyOnEntry();
// });
