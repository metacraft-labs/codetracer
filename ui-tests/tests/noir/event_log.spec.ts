import { test, expect } from "@playwright/test";
import { page, loadedEventLog, ctRun } from "../lib/ct_helpers";

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
