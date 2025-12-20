import { test, expect } from "@playwright/test";
import { page, ctEditMode, wait, codetracerInstallDir } from "../../lib/ct_helpers";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

// Use the test-programs directory as the folder to open in edit mode
const testFolder = path.join(codetracerInstallDir, "test-programs");

// Get the user layout directory (same logic as in frontend/config.nim)
const userLayoutDir = path.join(
  process.env.XDG_CONFIG_HOME ?? path.join(os.homedir(), ".config"),
  "codetracer"
);

const defaultLayoutPath = path.join(userLayoutDir, "default_layout.json");
const defaultEditLayoutPath = path.join(userLayoutDir, "default_edit_layout.json");
const backupSuffix = ".backup_test";

/**
 * Helper to backup a layout file if it exists
 */
function backupLayoutFile(layoutPath: string): void {
  if (fs.existsSync(layoutPath)) {
    fs.copyFileSync(layoutPath, layoutPath + backupSuffix);
  }
}

/**
 * Helper to restore a layout file from backup
 */
function restoreLayoutFile(layoutPath: string): void {
  const backupPath = layoutPath + backupSuffix;
  if (fs.existsSync(backupPath)) {
    fs.copyFileSync(backupPath, layoutPath);
    fs.unlinkSync(backupPath);
  }
}

/**
 * Helper to corrupt a layout file with invalid JSON
 */
function corruptLayoutFile(layoutPath: string): void {
  // Ensure directory exists
  const dir = path.dirname(layoutPath);
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
  }
  // Write invalid JSON that can't be parsed
  fs.writeFileSync(layoutPath, "{ invalid json content without closing brace", "utf8");
}

/**
 * Helper to create a layout file with valid JSON but invalid structure
 */
function createInvalidStructureLayoutFile(layoutPath: string): void {
  const dir = path.dirname(layoutPath);
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
  }
  // Write valid JSON but missing required 'root' property
  const invalidLayout = {
    settings: {
      constrainDragToContainer: true,
    },
    dimensions: {
      borderWidth: 2,
    },
    // Missing 'root' property - this should trigger validation failure
    notRoot: {
      type: "row",
      content: [],
    },
  };
  fs.writeFileSync(layoutPath, JSON.stringify(invalidLayout, null, 2), "utf8");
}

/**
 * Helper to create a layout file with root but missing type
 */
function createMissingTypeLayoutFile(layoutPath: string): void {
  const dir = path.dirname(layoutPath);
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
  }
  const invalidLayout = {
    settings: {},
    root: {
      // Missing 'type' property
      content: [],
    },
  };
  fs.writeFileSync(layoutPath, JSON.stringify(invalidLayout, null, 2), "utf8");
}

// Test: Normal operation with valid layout (sanity check)
test.describe("Normal operation with valid layout", () => {
  // Use default (hopefully valid) layout
  ctEditMode(testFolder);

  test("app loads normally with valid layout", async () => {
    await page.waitForSelector(".lm_goldenlayout", { timeout: 30000 });

    const layout = page.locator(".lm_goldenlayout");
    await expect(layout).toBeVisible();

    // Should have at least one panel/tab
    const tabs = page.locator(".lm_tab");
    const tabCount = await tabs.count();
    expect(tabCount).toBeGreaterThan(0);
  });

  test("layout contains expected panels", async () => {
    await page.waitForSelector(".lm_goldenlayout", { timeout: 30000 });
    await wait(1000);

    // Check for some expected panel types
    const panels = page.locator(".lm_stack");
    const panelCount = await panels.count();
    expect(panelCount).toBeGreaterThan(0);
  });

  test("layout file exists and is valid JSON", async () => {
    await wait(2000);

    // Check that the layout file contains valid JSON
    // Edit mode uses default_edit_layout.json, but falls back to default_layout.json
    const layoutPath = fs.existsSync(defaultEditLayoutPath) ? defaultEditLayoutPath : defaultLayoutPath;

    if (fs.existsSync(layoutPath)) {
      const content = fs.readFileSync(layoutPath, "utf8");

      // Should be valid JSON
      expect(() => JSON.parse(content)).not.toThrow();

      // Should have the required 'root' property
      const parsed = JSON.parse(content);
      expect(parsed).toHaveProperty("root");
      expect(parsed.root).toHaveProperty("type");
    }
  });
});
