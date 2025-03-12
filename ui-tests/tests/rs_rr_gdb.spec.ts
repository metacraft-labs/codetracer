import { test, expect } from "@playwright/test";
import {
  window,
  page,
  wait,
  // debugCodetracer,
  readyOnEntryTest as readyOnEntry,
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

// TODO: not finding element
// TODO: run tests serially if in the same instance (?)

// const DELAY = 3_000;

// test("expected event count", async () => {
//   await readyOnEntry();

//   const raw = await page.$eval(
//     ".data-tables-footer-rows-count",
//     (el) => el.textContent ?? "",
//   );

//   await wait(DELAY);
//   expect(raw.endsWith("2")).toBeTruthy();
//   expect(raw.endsWith("1")).toBeFalsy();
// });

test("state panel loaded initially", async () => {
  await readyOnEntry();
  await expect(page.locator("#code-state-line-0")).toContainText(
    "17 | println(",
  );
});

// test("state panel after jump to end of run function", async () => {
//   await readyOnEntry();
// });
