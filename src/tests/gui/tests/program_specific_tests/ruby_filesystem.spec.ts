import {
  test,
  expect,
  readyOnEntryTest as readyOnEntry,
  testProgramsPath,
} from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";

const RUBY_SUDOKU_SOURCE_PATH = `${testProgramsPath}/rb_sudoku_solver/sudoku_solver.rb`;

test.describe("ruby example — filesystem", () => {
  test.setTimeout(90_000);
  test.use({ sourcePath: RUBY_SUDOKU_SOURCE_PATH, launchMode: "trace" });

  test("Files panel is populated for a real Ruby replay", async ({ ctPage }, testInfo) => {
    await readyOnEntry(ctPage);
    const layout = new LayoutPage(ctPage);
    await layout.waitForFilesystemLoaded();

    const filesystem = (await layout.filesystemTabs(true))[0];
    await filesystem.clickTab();

    async function captureFilesystemDump() {
      return ctPage.evaluate(() => {
        const activeSession = document.querySelector(".session-container:not(.hidden)");
        const root = activeSession?.querySelector("div[id^='filesystemComponent']");
        const emptyOverlay = root?.querySelector(".filesystem-empty-overlay");
        const nodes = Array.from(root?.querySelectorAll("li.jstree-node") ?? []);
        const anchors = Array.from(root?.querySelectorAll(".jstree-anchor") ?? []);
        const appData = (window as any).data;
        const activeSessionIndex = appData?.activeSessionIndex ?? 0;
        const filesystem = appData?.sessions?.[activeSessionIndex]?.services?.editor?.filesystem;
        return {
          activeSessionId: activeSession?.id ?? "",
          activeSessionHidden: activeSession?.classList.contains("hidden") ?? true,
          activeSessionIndex,
          allFilesystemRootIds: Array.from(
            document.querySelectorAll("div[id^='filesystemComponent']"),
          ).map((node) => node.id),
          serviceRootText: filesystem?.text ?? "",
          serviceChildCount: filesystem?.children?.length ?? 0,
          rootHtml: root?.outerHTML.slice(0, 4_000) ?? "",
          rootId: root?.id ?? "",
          nodeCount: nodes.length,
          labels: anchors.map((node) => node.textContent?.trim() ?? "").slice(0, 20),
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
      await testInfo.attach("ruby-filesystem-dom.json", {
        body: JSON.stringify(await captureFilesystemDump(), null, 2),
        contentType: "application/json",
      });
    }

    const dump = await captureFilesystemDump();
    expect(dump.activeSessionHidden, "Filesystem must be mounted in the active session").toBe(false);
    expect(dump.serviceRootText, "filesystem-loaded should populate the editor service").toBe("source folders");
    expect(dump.serviceChildCount, "filesystem-loaded should include source roots").toBeGreaterThan(0);
    expect(dump.nodeCount, "Files panel should expose the Ruby source tree").toBeGreaterThan(0);
    expect(dump.labels.join("\n")).toMatch(/sudoku_solver\.rb/i);
    expect(dump.emptyOverlayVisible).toBe(false);
  });
});
