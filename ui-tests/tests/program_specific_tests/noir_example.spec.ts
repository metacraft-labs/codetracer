import { test, expect } from "@playwright/test";
import {
  window,
  page,
  loadedEventLog,
  // wait,
  // debugCodetracer,
  clickNext,
  clickContinue,
  readyOnEntryTest as readyOnEntry,
  ctRun,
} from "../../lib/ct_helpers";
import { StatusBar, } from "../../page-objects/status_bar";
import { StatePanel } from "../../page-objects/state";


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

ctRun("noir_example/");

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
    const statePanel = new StatePanel(page);
    await expect(statePanel.codeStateLine()).toContainText("17 | println(");
  });
  
  test("state panel supports integer values", async () => {
    // await readyOnEntry();
    const statePanel = new StatePanel(page);
  
    const values = await statePanel.values();
    expect(values.x.text).toBe("0");
    expect(values.x.typeText).toBe("Field");
  
    expect(values.y.text).toBe("1");
    expect(values.y.typeText).toBe("Field");
  });

  test("continue", async () => {
    await readyOnEntry();
    // await wait(5_000);
    await clickContinue();
    expect(true);
  });
  
  test("next", async () => {
    await readyOnEntry();
    await clickNext();
  });