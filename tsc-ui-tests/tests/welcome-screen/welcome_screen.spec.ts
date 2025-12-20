import { test, expect } from "@playwright/test";
import { page, ctWelcomeScreen, ctEditMode, wait } from "../../lib/ct_helpers";
import * as path from "node:path";
import * as fs from "node:fs";
import * as os from "node:os";

// Test the welcome screen functionality
ctWelcomeScreen();

test("welcome screen is displayed", async () => {
  // Wait for welcome screen to load
  await page.waitForSelector(".welcome-screen", { timeout: 15000 });

  // Verify the main welcome screen container is visible
  const welcomeScreen = page.locator(".welcome-screen");
  await expect(welcomeScreen).toBeVisible();
});

test("welcome screen has left and right panels", async () => {
  await page.waitForSelector(".welcome-screen", { timeout: 10000 });

  // Check for left panel (recent folders)
  const leftPanel = page.locator(".welcome-left-panel");
  await expect(leftPanel).toBeVisible();

  // Check for right panel (recent traces)
  const rightPanel = page.locator(".welcome-right-panel");
  await expect(rightPanel).toBeVisible();
});

test("welcome screen has start options buttons", async () => {
  await page.waitForSelector(".welcome-screen", { timeout: 10000 });

  // Check for Open Folder button
  const openFolderButton = page.locator(".start-options-button").filter({ hasText: /folder/i }).first();
  await expect(openFolderButton).toBeVisible();

  // Check for New Recording button
  const newRecordingButton = page.locator(".start-options-button").filter({ hasText: /recording/i }).first();
  await expect(newRecordingButton).toBeVisible();
});

test("recent traces section is visible", async () => {
  await page.waitForSelector(".welcome-screen", { timeout: 10000 });

  // Check for recent traces section
  const recentTraces = page.locator(".recent-traces");
  await expect(recentTraces).toBeVisible();

  // Check for title
  const title = page.locator(".recent-traces-title");
  await expect(title).toBeVisible();
});

test("recent folders section is visible", async () => {
  await page.waitForSelector(".welcome-screen", { timeout: 10000 });

  // Check for recent folders section
  const recentFolders = page.locator(".recent-folders");
  await expect(recentFolders).toBeVisible();
});

// Test for time ago display in trace list (if there are any traces)
test("trace entries show time ago format", async () => {
  await page.waitForSelector(".welcome-screen", { timeout: 10000 });

  // Check if there are any recent traces
  const traceEntries = page.locator(".recent-trace");
  const count = await traceEntries.count();

  if (count > 0) {
    // Check that the first trace has a time-ago element
    const firstTrace = traceEntries.first();
    const timeAgo = firstTrace.locator(".recent-trace-title-time");
    await expect(timeAgo).toBeVisible();

    // Verify it has some text content (could be "just now", "X minutes ago", etc.)
    const timeText = await timeAgo.textContent();
    expect(timeText).toBeTruthy();
  }
});

// Test tooltip visibility on hover
test("trace tooltip appears on hover", async () => {
  await page.waitForSelector(".welcome-screen", { timeout: 10000 });

  // Check if there are any recent traces
  const traceEntries = page.locator(".recent-trace");
  const count = await traceEntries.count();

  if (count > 0) {
    const firstTrace = traceEntries.first();
    const tooltip = firstTrace.locator(".recent-trace-tooltip");

    // Initially tooltip should be hidden (opacity: 0)
    await expect(tooltip).toBeHidden();

    // Hover over the trace
    await firstTrace.hover();

    // Wait for the tooltip delay (0.5s) plus some buffer
    await wait(700);

    // Now tooltip should be visible
    await expect(tooltip).toBeVisible();
  }
});
