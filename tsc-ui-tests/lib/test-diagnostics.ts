import * as fs from "node:fs";
import * as path from "node:path";

import type { Page, TestInfo } from "@playwright/test";

import { debugLogger } from "./debug-logger";

const DIAGNOSTICS_DIR = path.join(process.cwd(), "test-diagnostics");

/**
 * Captures diagnostic artifacts when a test fails.
 *
 * Saves to ./test-diagnostics/:
 *   - DOM snapshot (.html) — full page HTML
 *   - DOM summary (.summary.txt) — component counts and stats
 *   - Exception details (.txt) — test info and error
 *
 * Screenshots are handled by Playwright's built-in `screenshot: "only-on-failure"`.
 */
export async function captureFailureDiagnostics(
  page: Page,
  testInfo: TestInfo,
): Promise<void> {
  try {
    fs.mkdirSync(DIAGNOSTICS_DIR, { recursive: true });

    const timestamp = new Date()
      .toISOString()
      .replace(/[:.]/g, "-")
      .slice(0, 19);
    const safeTitle = testInfo.title.replace(/[^a-zA-Z0-9_-]/g, "_");
    const baseName = `${timestamp}_${safeTitle}_attempt${testInfo.retry + 1}`;

    await captureDom(page, baseName);
    await captureDomSummary(page, baseName);
    saveExceptionDetails(baseName, testInfo);

    const dir = DIAGNOSTICS_DIR;
    debugLogger.log(`Diagnostics saved to ${dir}/${baseName}.*`);
    console.log(`  Diagnostics: ${dir}/${baseName}.*`);
  } catch (err) {
    debugLogger.log(`Failed to capture diagnostics: ${err}`);
  }
}

async function captureDom(page: Page, baseName: string): Promise<void> {
  try {
    const html = await page.content();
    const filePath = path.join(DIAGNOSTICS_DIR, `${baseName}.html`);
    fs.writeFileSync(filePath, html, "utf-8");
  } catch (err) {
    debugLogger.log(`Failed to capture DOM: ${err}`);
  }
}

async function captureDomSummary(page: Page, baseName: string): Promise<void> {
  try {
    const summary = await page.evaluate(() => {
      const all = document.querySelectorAll("*");
      const ids = document.querySelectorAll("[id]");
      const inputs = document.querySelectorAll("input, textarea");
      const buttons = document.querySelectorAll("button");

      // CodeTracer component counts
      const eventLog = document.querySelectorAll('[class*="event-log"], [id*="eventLog"]');
      const callTrace = document.querySelectorAll('[class*="call-trace"], [id*="callTrace"]');
      const editor = document.querySelectorAll('[class*="editor-component"], [id*="editor"]');
      const monaco = document.querySelectorAll(".monaco-editor");
      const traceLog = document.querySelectorAll('[class*="trace-log"], [id*="traceLog"]');
      const variables = document.querySelectorAll('[class*="variables"], [id*="variables"]');
      const programState = document.querySelectorAll('[class*="program-state"]');
      const goldenLayout = document.querySelectorAll(".lm_goldenlayout");
      const flowValues = document.querySelectorAll('[class*="flow-value"], [class*="omniscience"]');

      // Hidden elements
      const hidden = Array.from(all).filter((el) => {
        const style = window.getComputedStyle(el);
        return style.display === "none" || style.visibility === "hidden";
      });

      return [
        "DOM Summary",
        "===========",
        "",
        "Quick Stats:",
        `  Total elements: ${all.length}`,
        `  Elements with IDs: ${ids.length}`,
        `  Inputs/textareas: ${inputs.length}`,
        `  Buttons: ${buttons.length}`,
        `  Hidden elements: ${hidden.length}`,
        "",
        "CodeTracer Components:",
        `  Event Log: ${eventLog.length}`,
        `  Call Trace: ${callTrace.length}`,
        `  Editor: ${editor.length}`,
        `  Monaco editors: ${monaco.length}`,
        `  Trace Log: ${traceLog.length}`,
        `  Variables: ${variables.length}`,
        `  Program State: ${programState.length}`,
        `  GoldenLayout: ${goldenLayout.length}`,
        `  Flow/Omniscience: ${flowValues.length}`,
      ].join("\n");
    });

    const filePath = path.join(DIAGNOSTICS_DIR, `${baseName}.summary.txt`);
    fs.writeFileSync(filePath, summary, "utf-8");
  } catch (err) {
    debugLogger.log(`Failed to capture DOM summary: ${err}`);
  }
}

function saveExceptionDetails(baseName: string, testInfo: TestInfo): void {
  try {
    const errors = testInfo.errors
      .map(
        (e, i) =>
          `Error ${i + 1}:\n  Message: ${e.message ?? "(none)"}\n  Stack: ${e.stack ?? "(none)"}`,
      )
      .join("\n\n");

    const content = `Test Failure Report
===================
Title: ${testInfo.title}
File: ${testInfo.file}
Status: ${testInfo.status}
Expected: ${testInfo.expectedStatus}
Retry: ${testInfo.retry}
Duration: ${testInfo.duration}ms
Timestamp: ${new Date().toISOString()}

${errors || "No error details captured."}
`;
    const filePath = path.join(DIAGNOSTICS_DIR, `${baseName}.txt`);
    fs.writeFileSync(filePath, content, "utf-8");
  } catch (err) {
    debugLogger.log(`Failed to save exception details: ${err}`);
  }
}
