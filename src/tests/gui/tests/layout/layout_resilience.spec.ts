import { test, expect, wait, codetracerInstallDir } from "../../lib/fixtures";
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

/**
 * A layout that passes every check the loader used to make — valid JSON, a
 * `root` with a `type`, and a Filesystem panel — but that GoldenLayout
 * REFUSES at restore time.
 *
 * This is the shape issue #608 is about, and the reason the three recovery
 * cases above were never coverage for it: they are all rejected by
 * `isValidLayoutConfig` before GoldenLayout ever sees the config, so they
 * exercise the parse guard and nothing else.  Here the config reaches
 * `loadLayout`, where `Stack.init` throws
 *
 *     Error: ActiveItemIndex out of range: 3 id:
 *
 * (node_modules/golden-layout/src/ts/items/stack.ts:169-171).  Before the
 * fix that threw straight out of `initLayout`, leaving a half-built window
 * on every subsequent launch until `just reset-layout` was run.
 *
 * `brokenStack` is the second child of the root row and decides *how* the
 * config is unloadable; the Filesystem stack beside it is what gets the
 * config past `isValidLayoutConfig`.
 */
function writeSemanticallyBrokenLayoutFile(
  layoutPath: string,
  brokenStack: Record<string, unknown>,
): void {
  const dir = path.dirname(layoutPath);
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
  }
  const layout = {
    settings: { constrainDragToContainer: true, reorderEnabled: true },
    dimensions: { borderWidth: 4, headerHeight: 32 },
    root: {
      type: "row",
      content: [
        {
          type: "stack",
          size: "20%",
          activeItemIndex: 0,
          content: [
            {
              type: "component",
              componentType: "genericUiComponent",
              // Content.Filesystem == 9 — present so the layout passes
              // `isValidLayoutConfig` and the loader does NOT simply reset it.
              componentState: { id: 0, label: "filesystemComponent-0", content: 9 },
              title: "FILES",
            },
          ],
        },
        brokenStack,
      ],
    },
  };
  fs.writeFileSync(layoutPath, JSON.stringify(layout, null, 2), "utf8");
}

/** Every stack's `activeItemIndex` is within `[0, content.length - 1]`. */
function everyStackActiveItemIndexInRange(node: any): boolean {
  if (!node || typeof node !== "object") return true;
  if (Array.isArray(node.content)) {
    if (node.type === "stack") {
      const index = node.activeItemIndex ?? 0;
      if (!Number.isFinite(index) || index < 0 || index >= node.content.length) {
        return false;
      }
    }
    for (const child of node.content) {
      if (!everyStackActiveItemIndexInRange(child)) return false;
    }
  }
  return true;
}

/** Collect every `componentType` used anywhere in a layout tree. */
function collectComponentTypes(node: any, into: Set<string> = new Set()): Set<string> {
  if (!node || typeof node !== "object") return into;
  if (node.type === "component" && typeof node.componentType === "string") {
    into.add(node.componentType);
  }
  if (Array.isArray(node.content)) {
    for (const child of node.content) collectComponentTypes(child, into);
  }
  return into;
}

/**
 * Ensure a layout file is valid JSON with the expected structure.
 * If it exists but is corrupted or structurally invalid (e.g. left
 * over from a previous failed test run), delete it so the app creates
 * a fresh default on next launch.
 */
function ensureLayoutFileValid(layoutPath: string): void {
  // First, try to restore from a leftover backup.
  restoreLayoutFile(layoutPath);

  // If the file still exists but is corrupted or structurally invalid, remove it.
  if (fs.existsSync(layoutPath)) {
    try {
      const parsed = JSON.parse(fs.readFileSync(layoutPath, "utf8"));
      if (!parsed.root || !parsed.root.type) {
        fs.unlinkSync(layoutPath);
      }
    } catch {
      fs.unlinkSync(layoutPath);
    }
  }
}

// Clean up any corrupted layout files from previous failed runs so
// corruption doesn't leak across test sessions.
test.beforeAll(() => {
  ensureLayoutFileValid(defaultEditLayoutPath);
  ensureLayoutFileValid(defaultLayoutPath);
});

// Test: Normal operation with valid layout (sanity check)
test.describe("Normal operation with valid layout", () => {
  // Use default (hopefully valid) layout
  // This whole file manages `default_edit_layout.json` itself — backing it
  // up, corrupting it, restoring it — so the launch fixture must not reset it
  // out from under the scenario. (The reset exists because a review now reads
  // that file too; see `layout-reset.resetEditLayout`.)
  test.use({ launchMode: "edit", editFolderPath: testFolder, preserveEditLayout: true });

  test("app loads normally with valid layout", async ({ ctPage }) => {
    await ctPage.waitForSelector(".lm_goldenlayout", { timeout: 30000 });

    const layout = ctPage.locator(".lm_goldenlayout");
    await expect(layout).toBeVisible();

    // Should have at least one panel/tab
    const tabs = ctPage.locator(".lm_tab");
    const tabCount = await tabs.count();
    expect(tabCount).toBeGreaterThan(0);
  });

  test("layout contains expected panels", async ({ ctPage }) => {
    await ctPage.waitForSelector(".lm_goldenlayout", { timeout: 30000 });
    await wait(1000);

    // Check for some expected panel types
    const panels = ctPage.locator(".lm_stack");
    const panelCount = await panels.count();
    expect(panelCount).toBeGreaterThan(0);
  });

  test("layout file exists and is valid JSON", async ({ ctPage }) => {
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

// ---------------------------------------------------------------------------
// Port of ui-tests/Tests/ProgramAgnostic/LayoutResilienceTests.cs
// Recovery tests that corrupt/modify the layout file and verify the app recovers.
// ---------------------------------------------------------------------------

test.describe("Recovery from corrupted JSON", () => {
  // Recovery tests can be flaky when running sequentially due to
  // Playwright fixture lifecycle interactions.
  test.describe.configure({ retries: 2 });
  // This whole file manages `default_edit_layout.json` itself — backing it
  // up, corrupting it, restoring it — so the launch fixture must not reset it
  // out from under the scenario. (The reset exists because a review now reads
  // that file too; see `layout-reset.resetEditLayout`.)
  test.use({ launchMode: "edit", editFolderPath: testFolder, preserveEditLayout: true });

  test("app recovers from corrupted layout JSON", async ({ ctPage }) => {
    const layoutPath = defaultEditLayoutPath;
    backupLayoutFile(layoutPath);

    try {
      corruptLayoutFile(layoutPath);

      await ctPage.reload();
      await ctPage.waitForSelector(".lm_goldenlayout", { timeout: 30000 });

      const layout = ctPage.locator(".lm_goldenlayout");
      await expect(layout).toBeVisible();

      const layoutContent = ctPage.locator(".lm_content").first();
      await expect(layoutContent).toBeVisible();
    } finally {
      restoreLayoutFile(layoutPath);
    }
  });
});

test.describe("Recovery from invalid structure", () => {
  test.describe.configure({ retries: 2 });
  // This whole file manages `default_edit_layout.json` itself — backing it
  // up, corrupting it, restoring it — so the launch fixture must not reset it
  // out from under the scenario. (The reset exists because a review now reads
  // that file too; see `layout-reset.resetEditLayout`.)
  test.use({ launchMode: "edit", editFolderPath: testFolder, preserveEditLayout: true });

  test("app recovers from layout with missing root", async ({ ctPage }) => {
    const layoutPath = defaultEditLayoutPath;
    backupLayoutFile(layoutPath);

    try {
      createInvalidStructureLayoutFile(layoutPath);

      await ctPage.reload();
      await ctPage.waitForSelector(".lm_goldenlayout", { timeout: 30000 });

      const layout = ctPage.locator(".lm_goldenlayout");
      await expect(layout).toBeVisible();
    } finally {
      restoreLayoutFile(layoutPath);
    }
  });
});

test.describe("Recovery from missing type", () => {
  test.describe.configure({ retries: 2 });
  // This whole file manages `default_edit_layout.json` itself — backing it
  // up, corrupting it, restoring it — so the launch fixture must not reset it
  // out from under the scenario. (The reset exists because a review now reads
  // that file too; see `layout-reset.resetEditLayout`.)
  test.use({ launchMode: "edit", editFolderPath: testFolder, preserveEditLayout: true });

  test("app recovers from layout root missing type property", async ({ ctPage }) => {
    const layoutPath = defaultEditLayoutPath;
    backupLayoutFile(layoutPath);

    try {
      createMissingTypeLayoutFile(layoutPath);

      await ctPage.reload();
      await ctPage.waitForSelector(".lm_goldenlayout", { timeout: 30000 });

      const layout = ctPage.locator(".lm_goldenlayout");
      await expect(layout).toBeVisible();
    } finally {
      restoreLayoutFile(layoutPath);
    }
  });
});

// ---------------------------------------------------------------------------
// #608 (M41) — configs that GoldenLayout rejects *semantically*.
//
// Everything above is caught by the parse/shape guard before GoldenLayout is
// involved.  The two cases below are the ones the shipped code produced by
// itself and could not recover from.  The headless guard for the same
// invariants is `layout_config_roundtrip_test.nim` in this directory.
// ---------------------------------------------------------------------------

// NOTE ON SETUP: these two cases write the broken layout in `beforeEach`,
// NOT after `ctPage.reload()` like the three above.
//
// `reload()` only reloads the renderer; the index process read the layout
// file once at startup and never re-reads it, so a file written after launch
// is never seen by the loader under test.  A `beforeEach` that requests no
// fixture runs before Playwright instantiates `ctPage`, so the app boots with
// the broken file already on disk — which is what makes these assertions
// mean something.
//
// They also target `default_edit_layout.json` deliberately: the `ctPage`
// fixture copies the bundled default over `default_layout.json` on every
// test setup (`lib/layout-reset.ts` `ensureDefaultLayout`), so a broken
// replay-mode layout would be erased before the app ever saw it.

test.describe("Recovery from an out-of-range activeItemIndex", () => {
  test.describe.configure({ retries: 2 });
  // This whole file manages `default_edit_layout.json` itself — backing it
  // up, corrupting it, restoring it — so the launch fixture must not reset it
  // out from under the scenario. (The reset exists because a review now reads
  // that file too; see `layout-reset.resetEditLayout`.)
  test.use({ launchMode: "edit", editFolderPath: testFolder, preserveEditLayout: true });

  test.beforeEach(() => {
    backupLayoutFile(defaultEditLayoutPath);
    // One surviving tab, `activeItemIndex` pointing at index 3 — exactly what
    // the save-side sanitiser used to leave behind after stripping the editor
    // tabs out of a mixed `[editor, editor, CALLS]` stack.
    writeSemanticallyBrokenLayoutFile(defaultEditLayoutPath, {
      type: "stack",
      size: "80%",
      activeItemIndex: 3,
      content: [
        {
          type: "component",
          componentType: "genericUiComponent",
          // Content.CalltraceEditor == 23 ("CALLS"), the non-editor tab that
          // shares the editor stack in a real replay session.
          componentState: { id: 0, label: "calltraceEditorComponent-0", content: 23 },
          title: "CALLS",
        },
      ],
    });
  });

  test.afterEach(() => {
    restoreLayoutFile(defaultEditLayoutPath);
  });

  test("app starts, and the repaired index is written back", async ({ ctPage }) => {
    await ctPage.waitForSelector(".lm_goldenlayout", { timeout: 30000 });

    // The window must be usable, not half-built.  Before the fix
    // `Stack.init` threw `ActiveItemIndex out of range` out of `loadLayout`,
    // aborting `initLayout` after `data.ui.layout` was assigned but before
    // the auto-hide setup, the event handlers and the standalone panels.
    await expect(ctPage.locator(".lm_goldenlayout")).toBeVisible();
    expect(await ctPage.locator(".lm_tab").count()).toBeGreaterThan(0);

    // The repair must be persisted.  Without the rewrite the same repair is
    // paid on every launch, and any crash before it leaves the file broken
    // forever — which is the reported "requires just reset-layout" symptom.
    await wait(2000);
    const persisted = JSON.parse(fs.readFileSync(defaultEditLayoutPath, "utf8"));
    expect(everyStackActiveItemIndexInRange(persisted.root)).toBe(true);
  });
});

test.describe("Recovery from an unknown componentType", () => {
  test.describe.configure({ retries: 2 });
  // This whole file manages `default_edit_layout.json` itself — backing it
  // up, corrupting it, restoring it — so the launch fixture must not reset it
  // out from under the scenario. (The reset exists because a review now reads
  // that file too; see `layout-reset.resetEditLayout`.)
  test.use({ launchMode: "edit", editFolderPath: testFolder, preserveEditLayout: true });

  test.beforeEach(() => {
    backupLayoutFile(defaultEditLayoutPath);
    // `ui/layout.nim` registers only `editorComponent` and
    // `genericUiComponent`.  For anything else GoldenLayout falls through to
    // `VirtualLayout.bindComponent`, CodeTracer's handler returns `undefined`
    // and destructuring `{component, virtual}` throws a TypeError out of
    // `loadLayout`.
    writeSemanticallyBrokenLayoutFile(defaultEditLayoutPath, {
      type: "stack",
      size: "80%",
      activeItemIndex: 0,
      content: [
        {
          type: "component",
          componentType: "componentTypeThatWasNeverRegistered",
          componentState: { id: 0, label: "ghostComponent-0", content: 23 },
          title: "GHOST",
        },
      ],
    });
  });

  test.afterEach(() => {
    restoreLayoutFile(defaultEditLayoutPath);
  });

  test("app starts with a component type that was never registered", async ({ ctPage }) => {
    await ctPage.waitForSelector(".lm_goldenlayout", { timeout: 30000 });

    await expect(ctPage.locator(".lm_goldenlayout")).toBeVisible();
    expect(await ctPage.locator(".lm_tab").count()).toBeGreaterThan(0);

    await wait(2000);
    const persisted = JSON.parse(fs.readFileSync(defaultEditLayoutPath, "utf8"));
    const types = collectComponentTypes(persisted.root);
    expect(types.has("componentTypeThatWasNeverRegistered")).toBe(false);
  });
});
