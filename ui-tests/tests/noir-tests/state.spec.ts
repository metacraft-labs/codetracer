import { test, expect } from "@playwright/test";
import {
  page,
  readyOnEntryTest as readyOnEntry,
  ctRun,
} from "../../test-framework/lib/ct_helpers";
import { StatePanel } from "../../test-framework/page-objects/state";

ctRun("noir_example/");

// TODO: run tests serially if in the same instance (?)
//   for now we're passing `--workers=1` to prevent parallelism: is this sufficient?
//   maybe we should use groups instead, as we might want parallelism in the future
//  (on the other hand, codetracer/backend itself might use parallelism, so we wouldn't want to parallelize tests in all cases)

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
