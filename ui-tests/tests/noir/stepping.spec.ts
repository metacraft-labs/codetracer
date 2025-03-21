import { test, expect } from "@playwright/test";
import {
  window,
  page,
  // wait,
  // debugCodetracer,
  readyOnEntryTest as readyOnEntry,
  clickNext,
  clickContinue,
  ctRun,
} from "../lib/ct_helpers";
import { StatusBar } from "../page_objects/status_bar";

ctRun("noir_example/");

const ENTRY_LINE = 17;

test("continue", async() => {
    await readyOnEntry();
    await clickContinue();
});

test("next", async() => {
    await readyOnEntry();
    await clickNext();
});
