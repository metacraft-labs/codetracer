/**
 * HWG-M6 Windows refusal gate.
 *
 * allowed_mocks: none. The command palette reaches the real Python apply-edit
 * command, which derives its knob vocabulary from the Flame source and writes
 * the refusal report consumed by CodeTracer. The deliberately unknown knob is
 * rejected before a coordinator connection is attempted, so no target process
 * is needed for this negative arm.
 */
import * as fs from "node:fs";
import * as path from "node:path";
import { test, expect } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";

const CODETRACER_REPO = path.resolve(__dirname, "../../../../..");
const WORKSPACE = path.dirname(CODETRACER_REPO);
const FLAME = process.env.CODETRACER_FLAME_DEMO_REPO ?? path.join(WORKSPACE, "codetracer-flame-demo");
const APPLY_WORK = path.join(FLAME, "build", "hcr-windows-apply-edit");
const APPLY_EDIT = path.join(FLAME, "scripts", "ct_hcr_apply_edit.py");
const DRIVER = path.join(APPLY_WORK, "hcr_patch_driver_windows.exe");
const TARGET_IMAGE = path.join(FLAME, "bin", "flamefield.windows.template_debug.dll");
const TARGET_PDB = path.join(FLAME, "bin", "flamefield.windows.template_debug.pdb");
const WORK = path.join(FLAME, "build", "hcr-windows-gui-refusal");
const REPORT = path.join(WORK, "unknown-knob-report.json");
const required = [APPLY_EDIT, DRIVER, TARGET_IMAGE, TARGET_PDB];
const unavailable =
  process.platform !== "win32"
    ? "the HWG-M6 Windows refusal gate requires Windows"
    : required.find((candidate) => !fs.existsSync(candidate));

fs.mkdirSync(WORK, { recursive: true });
if (unavailable === undefined) {
  process.env.CODETRACER_HCR_APPLY_EDIT_CMD = APPLY_EDIT;
  process.env.CODETRACER_HCR_APPLY_EDIT_INTERPRETER = "python";
  process.env.CODETRACER_HCR_PLATFORM = "windows";
  process.env.CODETRACER_HCR_PID = "1";
  process.env.CODETRACER_HCR_DRIVER = DRIVER;
  process.env.CODETRACER_HCR_TARGET_IMAGE = TARGET_IMAGE;
  process.env.CODETRACER_HCR_TARGET_PDB = TARGET_PDB;
  process.env.CODETRACER_HCR_FIRST_INSTRUCTION_LENGTH = "2";
  process.env.CODETRACER_HCR_EDIT = "rise_speeed=5.4";
  process.env.CODETRACER_HCR_REPORT = REPORT;
  delete process.env.CODETRACER_HCR_PID_FILE;
  delete process.env.CODETRACER_HCR_SOCKET;
  delete process.env.CODETRACER_HCR_SESSION_DIR;
}

test.describe("HWG-M6 - Windows apply-edit refusal", () => {
  test.setTimeout(180_000);
  test.use({ sourcePath: "py_console_logs/main.py", launchMode: "trace" });

  test("an unknown knob reaches the screen by its stable refusal name", async ({ ctPage }) => {
    test.skip(unavailable !== undefined, `Windows HCR prerequisites are missing: ${unavailable}`);
    fs.rmSync(REPORT, { force: true });

    const layout = new LayoutPage(ctPage);
    await layout.waitForAllComponentsLoaded();
    await layout.waitForTraceLoaded();

    await ctPage.keyboard.press("Control+KeyP");
    const input = ctPage.locator("#command-query-text");
    await expect(input).toBeVisible({ timeout: 15_000 });
    await input.fill(":Apply Edit");
    const hit = ctPage
      .locator(".command-results .command-result.command-command")
      .filter({ hasText: "Apply Edit & Hot-Reload" })
      .first();
    await expect(hit).toBeVisible({ timeout: 15_000 });
    await hit.click();

    await expect(
      ctPage.locator(".status-notification").filter({ hasText: "refused: edit-unknown-knob" }),
    ).toBeVisible({ timeout: 60_000 });
    await expect(
      ctPage.locator(".status-notification").filter({ hasText: "rise_speeed" }),
    ).toBeVisible({ timeout: 15_000 });

    const report = JSON.parse(fs.readFileSync(REPORT, "utf8"));
    expect(report.status).toBe("edit-unknown-knob");
    expect(report.surfaceRow).toBeNull();
    expect(report.refusalDetail.knob).toBe("rise_speeed");
    expect(report.refusalDetail.knownKnobs).toContain("rise_speed");
  });
});
