/**
 * A real pointer double click must survive the detail opening in a short
 * docked Requests panel. No mocks: the canonical demo writer makes a real
 * container, opened by the real Electron app and replay-server. In particular
 * the second press keeps the first press's coordinates; re-aiming a locator
 * would scroll the row and hide the regression.
 */
import { test, expect } from "../../lib/fixtures";
import { execFileSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import type { Page } from "@playwright/test";

const repo = path.resolve(__dirname, "../../../../..");
// Discovery imports this module too; create storage only in the worker's hook.
const work = path.join(os.tmpdir(), `ct-request-click-${randomUUID()}`);
const demo = path.join(work, "demo");

test.use({ deploymentMode: "electron", launchMode: "trace-folder", sourcePath: demo });
test.setTimeout(0);

test.beforeAll(() => {
  fs.mkdirSync(work);
  const writer = path.join(work, "writer");
  execFileSync("nim", ["c", "-d:release", "--hints:off", "--warnings:off",
    `--nimcache:${path.join(work, "nimcache")}`, `--out:${writer}`,
    "src/tools/demo_request_session.nim"], { cwd: repo, stdio: "inherit" });
  execFileSync(writer, [demo], { stdio: "inherit" });
});
test.afterAll(() => fs.rmSync(work, { recursive: true, force: true }));

async function position(page: Page) {
  return page.evaluate(() => {
    const loc = (window as any).data?.services?.debugger?.location;
    return loc ? { line: loc.line, step: Number(loc.rrTicks) } : null;
  });
}

async function openRequests(page: Page) {
  await expect(page.locator(".lm_goldenlayout")).toBeVisible();
  // The panel docks itself for a recording that serves requests (RS-M4); a
  // click on its strip label would hide it again.
  const panel = page.locator(".request-panel");
  await expect(panel.locator(".request-row")).toHaveCount(8);
  return panel;
}

test("a lower row's double click survives opening its detail", async ({ ctPage, electronApp }) => {
  expect(electronApp, "this regression must run in the real Electron app").not.toBeNull();
  await electronApp!.evaluate(({ BrowserWindow }) => {
    BrowserWindow.getAllWindows()[0].setSize(1900, 1400);
  });
  const panel = await openRequests(ctPage);
  const rows = panel.locator(".request-row");
  const body = panel.locator(".request-table-body");
  const initialHeight = await body.evaluate(el => el.clientHeight);
  const row = rows.nth(2); // request 04, below the newly opened detail's top
  const box = await row.boundingBox();
  expect(box).not.toBeNull();
  const point = { x: box!.x + box!.width / 2, y: box!.y + box!.height / 2 };
  const before = await position(ctPage);

  // Two physical presses, with layout between them and no locator re-aim.
  await ctPage.evaluate(() => {
    (window as any).requestClickTargets = [];
    document.addEventListener("mousedown", ev => {
      (window as any).requestClickTargets.push({ target: (ev.target as Element).className,
        time: ev.timeStamp });
    }, { capture: true });
  });
  await ctPage.mouse.dblclick(point.x, point.y, { delay: 50 });
  const targets = await ctPage.evaluate(() => (window as any).requestClickTargets);
  console.log("Requests double-click targets:", targets);
  console.log("Requests geometry after selection:", await panel.evaluate(el => {
    const rect = (selector: string) => {
      const r = el.querySelector(selector)!.getBoundingClientRect();
      return { top: r.top, bottom: r.bottom, height: r.height };
    };
    return { body: rect(".request-table-body"), detail: rect(".request-detail-host"),
      selected: rect(".request-row.selected") };
  }));
  expect(targets).toHaveLength(2);
  expect(targets[1].time - targets[0].time,
    "the gesture must fit the ViewModel's 500ms double-click interval").toBeLessThanOrEqual(500);
  await expect.poll(() => position(ctPage)).toEqual({ line: 13, step: 20 });
  expect(before?.step).not.toBe(20);
  await expect.poll(() => body.evaluate(el => el.clientHeight)).toBeLessThan(initialHeight);
  const bounds = await panel.evaluate(el => {
    const list = el.querySelector(".request-table-body")!.getBoundingClientRect();
    const detail = el.querySelector(".request-detail-host")!.getBoundingClientRect();
    const selected = el.querySelector(".request-row.selected")!.getBoundingClientRect();
    return { listBottom: list.bottom, detailTop: detail.top,
      selectedTop: selected.top, selectedBottom: selected.bottom, listTop: list.top };
  });
  // Chromium's independently rounded DOMRects can differ by a fraction of
  // a CSS pixel at the same flex boundary (0.00008px on the baseline).
  const epsilon = 0.5;
  expect(bounds.listBottom).toBeLessThanOrEqual(bounds.detailTop + epsilon);
  expect(bounds.selectedTop).toBeGreaterThanOrEqual(bounds.listTop - epsilon);
  expect(bounds.selectedBottom).toBeLessThanOrEqual(bounds.listBottom + epsilon);
});

test("detail controls, another row and resizing are separate gestures", async ({ ctPage }) => {
  const panel = await openRequests(ctPage);
  const before = await position(ctPage);
  await panel.locator(".request-row").nth(2).click();
  // A detail control is still operable immediately after the selection.
  const response = panel.locator(".request-detail-tab", { hasText: "Response" });
  await response.click();
  await expect(response).toHaveClass(/request-detail-tab--active/);
  expect(await position(ctPage)).toEqual(before);
  await panel.locator(".request-row").first().click();
  await expect(panel.locator(".request-row.selected .request-col-id")).toHaveText("02");
  expect(await position(ctPage)).toEqual(before);
  const body = panel.locator(".request-table-body");
  const height = await body.evaluate(el => el.clientHeight);
  const handle = await panel.locator(".request-detail-resize-handle").boundingBox();
  expect(handle).not.toBeNull();
  const x = handle!.x + handle!.width / 2;
  const y = handle!.y + handle!.height / 2;
  await ctPage.mouse.move(x, y);
  await ctPage.mouse.down();
  await ctPage.mouse.move(x, y - 20, { steps: 3 });
  await ctPage.mouse.up();
  await expect.poll(() => body.evaluate(el => el.clientHeight)).toBeLessThan(height);
  expect(await position(ctPage)).toEqual(before);
});

test("a later press on the opened detail is not a row activation", async ({ ctPage }) => {
  const panel = await openRequests(ctPage);
  const row = panel.locator(".request-row").nth(2);
  const box = await row.boundingBox();
  expect(box).not.toBeNull();
  const x = box!.x + box!.width / 2;
  const y = box!.y + box!.height / 2;
  const before = await position(ctPage);
  await ctPage.mouse.click(x, y);
  await expect(panel.locator(".request-detail")).toBeVisible();
  // This is the boundary being tested, rather than a settling delay: a
  // press outside RequestDoubleClickMs is a new detail gesture.
  await ctPage.waitForTimeout(550);
  expect(await ctPage.evaluate(({ x, y }) =>
    !!document.elementFromPoint(x, y)?.closest(".request-detail"), { x, y })).toBe(true);
  await ctPage.mouse.click(x, y);
  expect(await position(ctPage)).toEqual(before);
});
