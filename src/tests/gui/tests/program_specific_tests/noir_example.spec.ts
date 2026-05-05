import {
  test,
  expect,
  readyOnEntryTest as readyOnEntry,
  loadedEventLog,
  testProgramsPath,
} from "../../lib/fixtures";
import { StatusBar, } from "../../page-objects/status_bar";
import { StatePanel } from "../../page-objects/state";
import { LayoutPage } from "../../page-objects/layout-page";

const ENTRY_LINE = 17;
const NOIR_EXAMPLE_SOURCE_PATH = `${testProgramsPath}/noir_example/`;

// Each describe block gets its own fixture scope (each test records + launches independently).

test.describe("noir example — basic layout", () => {
  test.setTimeout(90_000);
  test.use({ sourcePath: NOIR_EXAMPLE_SOURCE_PATH, launchMode: "trace" });

  test("we can access the browser window, not just dev tools", async ({ ctPage }) => {
    const title = await ctPage.title();
    // In browser mode the page title includes the trace name (e.g.
    // "CodeTracer | Trace 42: noir_example"), so use toContain instead of toBe.
    expect(title).toContain("CodeTracer");
    await ctPage.focus("div");
  });

  test("correct entry status path/line", async ({ ctPage }) => {
    await readyOnEntry(ctPage);

    const statusBar = new StatusBar(ctPage, ctPage.locator("#status-base"));
    const simpleLocation = await statusBar.location();
    expect(simpleLocation.path.endsWith("main.nr")).toBeTruthy();
    expect(simpleLocation.line).toBe(ENTRY_LINE);
  });

  test("Files panel is populated for a real Noir replay", async ({ ctPage }, testInfo) => {
    await readyOnEntry(ctPage);
    const layout = new LayoutPage(ctPage);
    await layout.waitForFilesystemLoaded();

    const filesystem = (await layout.filesystemTabs(true))[0];
    await filesystem.clickTab();

    async function captureFilesystemDump() {
      return ctPage.evaluate(() => {
        const root = document.querySelector("div[id^='filesystemComponent']");
        const tree = root?.querySelector(".filesystem");
        const emptyOverlay = root?.querySelector(".filesystem-empty-overlay");
        const nodes = Array.from(root?.querySelectorAll("li.jstree-node") ?? []);
        const anchors = Array.from(root?.querySelectorAll(".jstree-anchor") ?? []);
        return {
          rootHtml: root?.outerHTML.slice(0, 4_000) ?? "",
          rootClass: root?.getAttribute("class") ?? "",
          treeClass: tree?.getAttribute("class") ?? "",
          treeVisible: tree ? window.getComputedStyle(tree).display !== "none" : false,
          nodeCount: nodes.length,
          labels: anchors.map((node) => node.textContent?.trim() ?? "").slice(0, 20),
          emptyOverlayText: emptyOverlay?.textContent?.trim() ?? "",
          emptyOverlayVisible: emptyOverlay
            ? window.getComputedStyle(emptyOverlay).display !== "none" &&
              !emptyOverlay.classList.contains("hidden")
            : false,
        };
      });
    }

    try {
      await filesystem.waitForReady();
    } finally {
      const preAssertionDump = await captureFilesystemDump();
      await testInfo.attach("noir-filesystem-dom.json", {
        body: JSON.stringify(preAssertionDump, null, 2),
        contentType: "application/json",
      });
    }

    const dump = await captureFilesystemDump();

    expect(dump.nodeCount, "Files panel should expose at least the source root").toBeGreaterThan(0);
    expect(dump.labels.join("\n")).toMatch(/source folders|main\.nr|src|noir/i);
    expect(dump.emptyOverlayVisible).toBe(false);
  });
});

test.describe("noir example — state and navigation", () => {
  test.setTimeout(90_000);
  test.use({ sourcePath: NOIR_EXAMPLE_SOURCE_PATH, launchMode: "trace" });

  test("expected event count", async ({ ctPage }) => {
    await loadedEventLog(ctPage);

    const raw = await ctPage.$eval(
      ".data-tables-footer-rows-count",
      (el) => el.textContent ?? "",
    );

    // The noir_example program executes several events (println, assert).
    // Verify at least one event is recorded rather than hardcoding a count
    // that can change with nargo/debugger version updates.
    const match = raw.match(/(\d+)/);
    expect(match).not.toBeNull();
    const count = parseInt(match![1], 10);
    expect(count).toBeGreaterThanOrEqual(1);
  });

  // PASSING since 2026-05-01 — `#code-state-line-0` is rendered by the
  // IsoNim state view on every CtCompleteMove (regardless of trace
  // kind), so noir DB traces now populate the panel correctly. See
  // `viewmodel/views/isonim_state_view.nim` and the matching
  // headless coverage in `tests/state/state_vm_test.nim` and
  // `tests/views/isonim_views_test.nim`.
  test("state panel loaded initially", async ({ ctPage }) => {
    await readyOnEntry(ctPage);
    const statePanel = new StatePanel(ctPage);
    await expect(statePanel.codeStateLine()).toContainText("17 | ");
  });

  // TODO(skipped): The noir DB-based debugger does not expose local variables in the state
  //   panel when running in browser mode. Variables x, y are expected but not present.
  //   Hypothesis: nargo trace output does not include variable inspection data in browser mode.
  //   Re-enable once nargo trace support includes variable inspection.
  test.fixme("state panel supports integer values", async ({ ctPage }) => {
    // await readyOnEntry(ctPage);
    const statePanel = new StatePanel(ctPage);

    const values = await statePanel.values();
    expect(values.x.text).toBe("0");
    expect(values.x.typeText).toBe("Field");

    expect(values.y.text).toBe("1");
    expect(values.y.typeText).toBe("Field");
  });

  // TODO(skipped): Debug movement (continue/next) does not work for noir traces in browser mode.
  //   The backend does not implement the `.test-movement` counter that the test helpers rely on.
  //   Hypothesis: The noir db-backend needs to emit a movement counter (or CtCompleteMove event)
  //   after each continue/next operation so the test can detect when the step has completed.
  test.fixme("continue", async () => {
    // Requires debug movement counter support in noir backend.
  });

  // TODO(skipped): Same as "continue" above -- debug movement counter not implemented for noir.
  //   Hypothesis: Needs CtCompleteMove event support in the noir db-backend.
  test.fixme("next", async () => {
    // Requires debug movement counter support in noir backend.
  });
});
