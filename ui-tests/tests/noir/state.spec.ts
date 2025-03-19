import { test, expect } from "@playwright/test";
import {
  page,
  readyOnEntryTest as readyOnEntry,
  ctRun,
} from "../lib/ct_helpers";

ctRun("noir_example/");

// TODO: run tests serially if in the same instance (?)
//   for now we're passing `--workers=1` to prevent parallelism: is this sufficient?
//   maybe we should use groups instead, as we might want parallelism in the future
//  (on the other hand, codetracer/backend itself might use parallelism, so we wouldn't want to parallelize tests in all cases)

test("state panel loaded initially", async () => {
  await readyOnEntry();
  await expect(page.locator("#code-state-line-0")).toContainText(
    "17 | println(",
  );
});
