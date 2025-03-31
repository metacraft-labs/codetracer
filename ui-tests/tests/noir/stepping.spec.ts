// /* eslint-disable @typescript-eslint/no-magic-numbers */

import { test, expect } from "@playwright/test";
import {
  // window,
  // page,
  // wait,
  // debugCodetracer,
  readyOnEntryTest as readyOnEntry,
  clickNext,
  clickContinue,
  ctRun,
} from "../lib/ct_helpers";
// import { StatusBar } from "../page_objects/status_bar";

ctRun("noir_example/");

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
