import { expect, test } from "@playwright/test";

const receiverUrl = "ws://127.0.0.1:9230/ct-stream";

const intValue = (value) => ({
  value,
  typeKind: "Int",
});

async function sendRecording(page, program, events) {
  await page.evaluate(
    async ({ receiverUrl, program, events }) => {
      await new Promise((resolve, reject) => {
        const ws = new WebSocket(receiverUrl);
        const timer = window.setTimeout(() => {
          ws.close();
          reject(new Error(`timed out connecting to ${receiverUrl}`));
        }, 5000);
        ws.addEventListener("open", () => {
          window.clearTimeout(timer);
          ws.send(JSON.stringify({ kind: "SessionStart", program, args: [] }) + "\n");
          for (const event of events) {
            ws.send(JSON.stringify(event) + "\n");
          }
          ws.send(JSON.stringify({ kind: "SessionEnd" }) + "\n");
          ws.close();
          resolve(undefined);
        });
        ws.addEventListener("error", () => {
          window.clearTimeout(timer);
          reject(new Error(`failed connecting to ${receiverUrl}`));
        });
      });
    },
    { receiverUrl, program, events },
  );
}

test("records browser and wasm streams for the account-balance fixture", async ({ page }) => {
  await page.goto("/");
  await expect(page.locator("#status")).toHaveText("stored");

  await sendRecording(page, "frontend", [
    { kind: "Path", pathId: 0, path: "frontend/app.js" },
    { kind: "Step", siteId: 31 },
    { kind: "Value", name: "userId", value: intValue(42) },
    { kind: "Step", siteId: 32 },
    { kind: "Value", name: "amount", value: intValue(100) },
    { kind: "Step", siteId: 46 },
    { kind: "CorrelationMarker", direction: "recv", boundary: "js-wasm-realm", key: 1, payload: "compute_balance" },
    { kind: "Step", siteId: 47 },
    { kind: "CorrelationMarker", direction: "send", boundary: "account-balance-with-wasm", key: 620, payload: "POST /balance request" },
    { kind: "Value", name: "result", value: intValue(620) },
  ]);

  await sendRecording(page, "frontend-wasm", [
    { kind: "Path", pathId: 0, path: "wasm-src/lib.rs" },
    { kind: "Step", siteId: 41 },
    { kind: "CorrelationMarker", direction: "send", boundary: "js-wasm-realm", key: 1, payload: "compute_balance" },
    { kind: "Step", siteId: 44 },
    { kind: "Return", fnId: 1, returnValue: intValue(620) },
  ]);
});
