import { test, expect } from "@playwright/test";
import {
  window,
  page,
  // debugCodetracer,
  readyOnEntryTest as readyOnEntry,
  codeTracerRun,
} from "./lib/ct_helpers";
import { StatusBar } from "./page_objects/status_bar";

// debugCodetracer("rr_gdb", "rs");
codeTracerRun("/rs_rr_gdb/rr_gdb.rs");

const RR_GDB_ENTRY_LINE = 198;

test("we can access the browser window, not just dev tools", async () => {
  const title = await window.title();
  expect(title).toBe("editor");
  await window.focus("div");
});

test("correct entry status path/line", async () => {
  // TODO: actually wait for run-to-entry or status-bar appearing
  // or fail after a timeout
  // wait(ms) is usually flakey and bad
  await readyOnEntry();
  // const waitingTimeBeforeEntryIsReadyInMs = 2_500;
  // await wait(waitingTimeBeforeEntryIsReadyInMs);

  const statusBar = new StatusBar(page, page.locator(".status-bar"));
  const simpleLocation = await statusBar.location();
  expect(simpleLocation.path.endsWith("rr_gdb.rs")).toBeTruthy();
  expect(simpleLocation.line).toBe(RR_GDB_ENTRY_LINE);
});

test("expected event count", async () => {
  await readyOnEntry();

  const raw = await page.$eval(
    ".data-tables-footer-rows-count",
    (el) => el.textContent ?? "",
  );

  //await wait(3000);

  expect(raw.endsWith("15")).toBeTruthy();
  // let a = 155;
  // console.log(a);
  // expect((raw ?? "").endsWith("16")).toBeFalsy();
  expect(raw.endsWith("16")).toBeFalsy();
  // expect(raw != null && raw.endsWith("15")).toBeTruthy();
  // expect(simpleLocation.line).toBe(RR_GDB_ENTRY_LINE);
});

test("state panel loaded initially", async () => {
  await readyOnEntry();
  await expect(page.locator("#code-state-line-0")).toContainText(
    "198 | fn main() {",
  );
});

test("state panel after jump to end of run function", async () => {
  await readyOnEntry();
});
