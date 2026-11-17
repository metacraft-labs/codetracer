/**
 * desktop_verno_run.spec.ts — the desktop's Verification pane runs the
 * project's declared Verno action, as the terminal and the GPUI window do.
 *
 * Spec: codetracer-pm `spec/Planned-Features/Verification-Payload-Contract-v1.md`
 * §11 ("Who runs Verno"), §7 (discovery and staleness), §8 (the text tier).
 *
 * The real Electron front-end in edit mode over the `typeerr` Noir package
 * (`src/frontend/tui/tests/fixtures/plat63_verno_projects.nim`, the package
 * every Verification suite drives, written by that module's own code). View ›
 * Verification opens the pane; the pane reads the project's
 * `.vscode/tasks.json`, offers its Verno task as the Run control, and:
 *
 *   * a run still in flight is LIVE: the Stop control, the clock moving, the
 *     verifier's last output line; Stop ends it with no outcome (the
 *     verifier's whole process group is stopped, so its `sleep` goes too);
 *   * a run to the end shows the findings BY KIND, equal to the rows every
 *     front-end shows (`TypeErrExpectedRows` in the fixture), the verdict the
 *     native panes show, and the report the run wrote attached;
 *   * a press on a finding opens its file at its line in the editor (the
 *     text tier spells it from the package's parent, and the pane finds it);
 *   * the exit code reaches the classifier (an empty run exiting 0 is proved);
 *   * a project that declares no Verno action offers no Run.
 *
 * THE ONE STAND-IN, AND WHY IT IS NOT A MOCK. `verno` cannot be built on this
 * machine, so the `verno` first on the app's PATH (`launchEnv`) is the
 * fixture's script that REPLAYS a recorded real run: it prints the recorded
 * output, exits with the recorded code and writes the recorded report where
 * the real one writes it, its two timestamps stamped with this run's time.
 * A `hold` file beside it makes the run wait (to watch it live and Stop it).
 * The native suites run the same script. Everything else is the product's:
 * the task file read, the action recognised, the process launched by the
 * main process (`index/verification_runner`), the output streamed, the
 * report found by the discovery convention, decoded, checked for staleness
 * and attached, the pane drawn by the shared view.
 *
 * Isolation: the fixtures give the app a scratch `CODETRACER_HOME` and
 * `XDG_CONFIG_HOME`; the package is written under a scratch directory and
 * removed afterwards.
 */
import { test, expect } from "../../lib/fixtures";
import { execFileSync } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

const repoRoot = path.resolve(__dirname, "..", "..", "..", "..", "..");
const fixtureFile = path.join(
  repoRoot, "src", "frontend", "tui", "tests", "fixtures", "plat63_verno_projects.nim");
const work = fs.mkdtempSync(path.join(os.tmpdir(), "ct-desktop-verno-"));

/** The package and its replaying `verno`, written by the fixture's own code. */
let run: { root: string; bin: string } | null = null;
function vernoRun(): { root: string; bin: string } {
  if (run) return run;
  const writer = path.join(work, "write-verno-run");
  execFileSync("nim", ["c", "--hints:off", "--warnings:off",
    `--nimcache:${path.join(work, "nimcache")}`, `--out:${writer}`, fixtureFile],
  { cwd: repoRoot, stdio: ["ignore", "ignore", "inherit"] });
  const out = execFileSync(writer, ["typeerr"], {
    encoding: "utf8", env: { ...process.env, TMPDIR: work } });
  const [root, bin] = out.trim().split("\n");
  run = { root, bin };
  return run;
}

/** A project that declares nothing. */
const bare = path.join(work, "bare");
fs.mkdirSync(path.join(bare, "src"), { recursive: true });
fs.writeFileSync(path.join(bare, "Nargo.toml"),
  '[package]\nname = "bare"\ntype = "bin"\nauthors = [""]\n\n[dependencies]\n');
fs.writeFileSync(path.join(bare, "src", "main.nr"), "fn main() {}\n");

/** `TypeErrExpectedRows` of the fixture: (kind, title, message, location). */
function expectedRows(): string[][] {
  const text = fs.readFileSync(fixtureFile, "utf8");
  const block = text.match(/TypeErrExpectedRows\* = \[([\s\S]*?)\]\n/);
  if (!block) throw new Error(`TypeErrExpectedRows not in ${fixtureFile}`);
  return Array.from(block[1].matchAll(/\("([^"]*)", "([^"]*)",\s*"([^"]*)", "([^"]*)"\)/g))
    .map((m) => [m[1], m[2], m[3], m[4]]);
}

test.afterAll(() => fs.rmSync(work, { recursive: true, force: true }));

/** View › Verification, through the window's menu. */
async function openVerification(ctPage: any) {
  await ctPage.evaluate(() => (globalThis as any).__ctMenuVM.open());
  const view = ctPage.locator("#menu-elements").getByText("View", { exact: true }).first();
  await view.waitFor({ state: "visible", timeout: 10_000 });
  await view.click({ force: true });
  const item = ctPage.locator(".menu-nested-elements .ct-menu-item-label", { hasText: /^Verification$/ }).first();
  await item.waitFor({ state: "visible", timeout: 10_000 });
  await item.click();
  const panel = ctPage.locator(".ct-verification-panel").first();
  await panel.waitFor({ state: "attached", timeout: 30_000 });
  if (!(await panel.isVisible())) {
    // Edit mode places a pane no arrangement names beside Build, in the
    // bottom strip: show it from its tab.
    await ctPage.locator(".auto-hide-strip-tab", { hasText: /VERIFICATION/i }).first().click();
  }
  await expect(panel).toBeVisible({ timeout: 30_000 });
}

/** The pane as a reader of the DOM sees it. */
async function readPane(ctPage: any) {
  return await ctPage.evaluate(() => {
    const p = document.querySelector(".ct-verification-panel") as HTMLElement | null;
    const text = (n: Element | null) => (n ? (n.textContent || "").trim() : "");
    if (!p) return null;
    return {
      phase: p.getAttribute("data-ct-verification-phase"),
      outcome: p.getAttribute("data-ct-verification-outcome"),
      payload: p.getAttribute("data-ct-verification-payload"),
      status: text(p.querySelector(".ct-verification-status")),
      command: text(p.querySelector(".ct-verification-command")),
      run: text(p.querySelector(".ct-verification-run")),
      stop: p.querySelector(".ct-verification-cancel") !== null,
      groups: Array.from(p.querySelectorAll(".ct-verification-group-heading")).map((g) => text(g)),
      rows: Array.from(p.querySelectorAll("[data-ct-verification-row]")).map((r) => [
        text(r.querySelector(".ct-verification-row-kind")),
        text(r.querySelector(".ct-verification-row-title")),
        text(r.querySelector(".ct-verification-row-message")),
        r.getAttribute("data-ct-verification-location") || "",
      ]),
    };
  });
}

/** The active editor's path and its caret line, or nulls. */
async function activeEditor(ctPage: any) {
  return await ctPage.evaluate(() => {
    const d = (globalThis as any).data;
    const active = d?.services?.editor?.active;
    const tab = active ? d.ui.editors[active] : null;
    const pos = tab?.monacoEditor?.getPosition?.();
    return { path: active ? String(active) : null, line: pos ? pos.lineNumber : null };
  });
}

test.describe("the desktop's Verification pane runs the project's Verno action", () => {
  test.use({
    launchMode: "edit",
    editFolderPath: async ({}, use) => { await use(vernoRun().root); },
    launchEnv: async ({}, use) => {
      await use({ PATH: `${vernoRun().bin}${path.delimiter}${process.env.PATH ?? ""}` });
    },
  });
  test.setTimeout(300_000);

  test("Run live, Stop, Run to the end: the findings by kind, a press opens the source", async ({ ctPage }) => {
    const { root, bin } = vernoRun();
    await expect(ctPage.locator(".lm_goldenlayout")).toBeVisible({ timeout: 60_000 });
    await openVerification(ctPage);

    // OFFERED: the project's declared task, by its label; not yet run.
    const idle = await readPane(ctPage);
    expect(idle!.run, "the pane offers the project's declared Verno task").toBe("Verify with Verno");
    expect(idle!.phase).toBe("idle");
    expect(idle!.stop).toBe(false);

    // A LIVE RUN: held in flight by the replay's `hold` file.
    fs.writeFileSync(path.join(bin, "hold"), "");
    await ctPage.locator(".ct-verification-run").click();
    await expect
      .poll(async () => (await readPane(ctPage))!.phase, { timeout: 30_000, message: "Run starts a live run" })
      .toBe("running");
    // The clock moves and the verifier's last line is on the status line.
    await expect
      .poll(async () => (await readPane(ctPage))!.status, { timeout: 30_000, message: "a live run's clock moves" })
      .toMatch(/^Verifying with Verno — [1-9][0-9]*s/);
    await expect
      .poll(async () => (await readPane(ctPage))!.status, { timeout: 10_000, message: "a live run shows the verifier's last line" })
      .toMatch(/^Verifying with Verno — \S+ — \S/);
    const live = await readPane(ctPage);
    expect(live!.stop).toBe(true);
    expect(live!.run).toBe("");
    expect(live!.command).toBe("verno --program-dir . formal-verify -- --rlimit 60");

    // STOP: no outcome, and the held process group is gone well before its
    // minute is up.
    await ctPage.locator(".ct-verification-cancel").click();
    await expect
      .poll(async () => (await readPane(ctPage))!.phase, { timeout: 15_000, message: "Stop ends the verifier's whole process group" })
      .toBe("cancelled");
    const stopped = await readPane(ctPage);
    expect(stopped!.status).toMatch(/^Cancelled after .* — nothing was proved or disproved$/);
    expect(stopped!.rows).toEqual([]);
    expect(stopped!.run).toBe("Verify with Verno");

    // A RUN TO THE END.
    fs.rmSync(path.join(bin, "hold"));
    await ctPage.locator(".ct-verification-run").click();
    await expect
      .poll(async () => (await readPane(ctPage))!.phase, { timeout: 60_000, message: "a run to the end finishes, it does not read as a Stop" })
      .toBe("finished");
    const done = await readPane(ctPage);
    expect(done!.rows).toEqual(expectedRows());
    expect(done!.groups).toEqual(["pipeline error (2)"]);
    // The report the run wrote is this run's and was attached (found by the
    // discovery convention, not refused as stale), and the verdict is the
    // one the native panes show for the same run.
    expect(done!.payload, "the run's report is found and attached").toBe("attached");
    expect(done!.status).toMatch(/^failed before reaching the prover/);
    expect(done!.run).toBe("Verify with Verno");

    // A PRESS on the first finding: its file (spelled from the package's
    // parent by the text tier) at its line.
    await ctPage.locator("[data-ct-verification-row]").first().click();
    await expect
      .poll(async () => (await activeEditor(ctPage)).line, { timeout: 30_000, message: "a press opens the finding's file at its line" })
      .toBe(2);
    expect((await activeEditor(ctPage)).path).toBe(path.join(root, "src", "main.nr"));

    // THE EXIT CODE REACHES THE CLASSIFIER: the same replay, printing nothing
    // and exiting 0, is a proof only because of its code (`classifyVernoRun`:
    // "exited 0 without a success banner"; with no code it is a pipeline error).
    fs.writeFileSync(path.join(bin, "recorded-output.txt"), "");
    const script = path.join(bin, "verno");
    fs.writeFileSync(script, fs.readFileSync(script, "utf8").replace(/^exit 1$/m, "exit 0"));
    await ctPage.locator(".ct-verification-run").click();
    await expect
      .poll(async () => (await readPane(ctPage))!.status, { timeout: 60_000, message: "the exit code reaches the classifier" })
      .toMatch(/^proved — /);
  });
});

test.describe("a project that declares no Verno action", () => {
  test.use({ launchMode: "edit", editFolderPath: bare });
  test.setTimeout(300_000);

  test("offers no Run", async ({ ctPage }) => {
    await expect(ctPage.locator(".lm_goldenlayout")).toBeVisible({ timeout: 60_000 });
    await openVerification(ctPage);
    const pane = await readPane(ctPage);
    expect(pane!.phase).toBe("idle");
    expect(pane!.run, "a project that declares no Verno action is offered no Run").toBe("");
    expect(pane!.stop).toBe(false);
    expect(pane!.status).toBe("not run");
  });
});
