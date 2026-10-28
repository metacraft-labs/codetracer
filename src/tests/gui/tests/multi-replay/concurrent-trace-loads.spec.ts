/**
 * Real Electron admission and tab delivery, with real recorded Python traces.
 * Two registered IPC callbacks are dispatched in one main-process turn so the
 * first awaits real metadata/backend I/O before the second runs. No loader,
 * backend or routing is replaced. The optimistic Welcome loading flags are
 * seeded because direct IPC dispatch deliberately bypasses the click adapter.
 */
import * as path from "node:path";
import { test, expect, recordTestProgram, testProgramsPath } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";

test.use({ sourcePath: "py_console_logs/main.py", launchMode: "trace", deploymentMode: "electron" });
test.setTimeout(0);

test("overlapping loads refuse only the second tab and a retry loads its own recording", async ({ ctPage, electronApp }) => {
  expect(electronApp, "this regression requires the real Electron main process").not.toBeNull();
  const layout = new LayoutPage(ctPage);
  await layout.waitForTraceLoaded();
  await layout.waitForAllComponentsLoaded();
  const firstRecording = recordTestProgram(path.join(testProgramsPath, "py_checklist", "basics.py"));
  const secondRecording = await ctPage.evaluate(() => String((window as any).data.sessions[0].trace.recordingId));

  await ctPage.locator(".session-tab-add").click();
  await expect(ctPage.locator(".session-tab")).toHaveCount(2);
  await ctPage.locator(".session-tab-add").click();
  await expect(ctPage.locator(".session-tab")).toHaveCount(3);
  const ids = await ctPage.evaluate(() => {
    const d = (window as any).data;
    d.sessions[1].ui.welcomeScreen.loading = true;
    d.sessions[2].ui.welcomeScreen.loading = true;
    const electron = require("electron");
    (window as any).__concurrentLoadAnswers = [];
    for (const channel of ["trace-load-error", "init", "trace-loaded", "dap-replay-selected"]) {
      electron.ipcRenderer.on(`CODETRACER::${channel}`, (_event: unknown, payload: any) => {
        (window as any).__concurrentLoadAnswers.push({ channel, tab: payload.tab, error: payload.error,
          recordingId: payload.trace?.recordingId, preserveLoading: payload.preserveLoading });
      });
    }
    return d.sessions.map((s: any) => Number(s.id));
  });

  await electronApp!.evaluate(({ ipcMain, BrowserWindow }, args) => {
    const sender = BrowserWindow.getAllWindows().find((w: { webContents: { getURL(): string } }) => w.webContents.getURL().includes("index"))?.webContents
      ?? BrowserWindow.getAllWindows()[0].webContents;
    ipcMain.emit("CODETRACER::load-recent-trace", { sender }, { tab: args.firstTab, traceId: args.firstRecording });
    ipcMain.emit("CODETRACER::load-recent-trace", { sender }, { tab: args.secondTab, traceId: args.secondRecording });
    ipcMain.emit("CODETRACER::load-recent-trace", { sender }, { tab: args.loadedTab, traceId: args.firstRecording });
  }, { loadedTab: ids[0], firstTab: ids[1], secondTab: ids[2], firstRecording, secondRecording });

  const answers = () => ctPage.evaluate(() => (window as any).__concurrentLoadAnswers as any[]);
  await expect.poll(async () => (await answers()).filter((a) => a.channel === "trace-load-error").length,
    { timeout: 120_000 }).toBe(2);
  const refusal = (await answers()).find((a) => a.channel === "trace-load-error" && a.tab === ids[2]);
  expect(refusal.tab).toBe(ids[2]);
  expect(refusal.error).toMatch(/Wait.*try again/);
  expect(refusal.preserveLoading).toBe(false);
  await expect.poll(() => ctPage.evaluate(() => (window as any).data.ui.welcomeScreen.loading),
    { timeout: 120_000 }).toBe(false);
  await expect(ctPage.getByRole("alert").filter({ hasText:
    "Another trace or session is loading. Wait for it to finish and try again." })).toBeVisible({ timeout: 120_000 });
  await expect.poll(async () => (await answers()).some((a) => a.channel === "trace-loaded" && a.tab === ids[1]),
    { timeout: 120_000 }).toBe(true);
  expect((await answers()).filter((a) => a.channel === "dap-replay-selected").map((a) => a.tab)).toEqual([ids[1]]);
  expect(await ctPage.evaluate(() => String((window as any).data.sessions[0].trace.recordingId))).toBe(secondRecording);
  expect(await ctPage.evaluate(() => (window as any).data.sessions[2].trace)).toBeNull();

  await ctPage.locator(".session-tab").nth(0).click();
  await expect(ctPage.locator("#welcomeScreen")).toBeHidden();
  expect(await ctPage.evaluate(() => String((window as any).data.sessions[0].trace.recordingId))).toBe(secondRecording);

  await ctPage.locator(".session-tab").nth(1).click();
  await expect.poll(() => ctPage.evaluate(() => String((window as any).data.sessions[1].trace?.recordingId ?? "")),
    { timeout: 120_000 }).toBe(firstRecording);
  await ctPage.locator(".session-tab").nth(2).click();
  await ctPage.evaluate((traceId) => (window as any).data.ipc.send("CODETRACER::load-recent-trace", { traceId }), secondRecording);
  await expect.poll(() => ctPage.evaluate(() => String((window as any).data.sessions[2].trace?.recordingId ?? "")),
    { timeout: 120_000 }).toBe(secondRecording);
  expect(await ctPage.evaluate(() => String((window as any).data.sessions[1].trace.recordingId))).toBe(firstRecording);
});

test("open-trace-in-tab creates one tab before starting one addressed load", async ({ ctPage }) => {
  const layout = new LayoutPage(ctPage);
  await layout.waitForTraceLoaded();
  await layout.waitForAllComponentsLoaded();
  const recording = recordTestProgram(path.join(testProgramsPath, "py_checklist", "basics.py"));
  await ctPage.evaluate((traceId) => {
    (window as any).__newTabLoads = [];
    require("electron").ipcRenderer.on("CODETRACER::dap-replay-selected", (_event: unknown, payload: any) => {
      (window as any).__newTabLoads.push({ tab: payload.tab, recordingId: payload.trace?.recordingId });
    });
    (window as any).data.ipc.send("CODETRACER::open-trace-in-tab", { traceId });
  }, recording);
  await expect(ctPage.locator(".session-tab")).toHaveCount(2, { timeout: 120_000 });
  await expect.poll(() => ctPage.evaluate(() => String((window as any).data.sessions[1].trace?.recordingId ?? "")),
    { timeout: 120_000 }).toBe(recording);
  const result = await ctPage.evaluate(() => ({ loads: (window as any).__newTabLoads,
    id: Number((window as any).data.sessions[1].id), count: (window as any).data.sessions.length }));
  expect(result.count).toBe(2);
  expect(result.loads).toEqual([{ tab: result.id, recordingId: recording }]);
});
