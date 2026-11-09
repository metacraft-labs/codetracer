/**
 * The desktop's Trace Macro / Static Block route opens a Nim compile-time
 * trace that nimsuggest wrote as a bare `.ct` under its nimcache.
 *
 * Before the fix the window sent `CODETRACER::load-trace-file` with that path
 * and answered "No trace found at …", because nothing had registered the file.
 * The route now sends `CODETRACER::load-nim-trace-file` with the traced source,
 * and the main process imports the `.ct` into a folder of its own (with the
 * sources under `files/`, as the terminal and GPUI lay it out) before it opens
 * it. Spec: codetracer-pm `spec/Planned-Features/Nim-Compile-Time-Tracing-Milestones.md`,
 * "How the desktop opens a trace that nimsuggest wrote".
 *
 * The language server is not run in this suite, so the message the route sends
 * is sent here directly, with the paths it would carry.
 */
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { test, expect } from "../../lib/fixtures";

const codetracerRoot = path.resolve(process.cwd(), "..", "..", "..");
const xosFixture = path.join(
  codetracerRoot,
  "src",
  "db-backend",
  "tests",
  "fixtures",
  "xos",
  "xos_hello.ct",
);

test.describe("Nim trace route: a bare nimsuggest .ct opens from the desktop", () => {
  test.use({ sourcePath: "nim_static_block/main.nim", launchMode: "trace" });

  test("the trace is imported with its sources and opens, without a refusal", async ({
    ctPage,
  }) => {
    // What nimsuggest leaves: the trace in its nimcache, and the Nim file the
    // request was made in beside it.
    const work = fs.mkdtempSync(path.join(os.tmpdir(), "nim-trace-route-"));
    const nimcache = path.join(work, "nimcache");
    const project = path.join(work, "project");
    fs.mkdirSync(nimcache);
    fs.mkdirSync(project);
    const ct = path.join(nimcache, "static_trace_20.ct");
    fs.copyFileSync(xosFixture, ct);
    const source = path.join(project, "main.nim");
    fs.writeFileSync(source, "static:\n  discard\n");

    // The launch already has a trace open, so the imported recording is the
    // one whose folder differs from it.
    const launchFolder: string = await ctPage.evaluate(
      () => (window as any).data?.trace?.outputFolder ?? "",
    );

    await ctPage.evaluate(
      ({ tracePath, sourcePath }) => {
        (window as any).data.ipc.send("CODETRACER::load-nim-trace-file", {
          tracePath,
          sourcePath,
        });
      },
      { tracePath: ct, sourcePath: source },
    );

    // The window's trace is now the imported recording: a folder of its own
    // under the trace store, holding the container and the traced source.
    await expect
      .poll(
        () =>
          ctPage.evaluate(() => (window as any).data?.trace?.outputFolder ?? ""),
        { timeout: 120_000 },
      )
      .not.toBe(launchFolder);
    const folder: string = await ctPage.evaluate(
      () => (window as any).data.trace.outputFolder,
    );
    expect(folder).not.toBe(nimcache);
    expect(fs.existsSync(path.join(folder, "trace.ct"))).toBe(true);
    expect(
      fs.existsSync(path.join(folder, "files", source.replace(/^\/+/, ""))),
    ).toBe(true);
    // The nimcache file is left as nimsuggest wrote it.
    expect(fs.existsSync(ct)).toBe(true);

    await expect(
      ctPage.locator(".status-notification", { hasText: "No trace found at" }),
    ).toHaveCount(0);
    await expect(
      ctPage.locator(".status-notification", {
        hasText: "Could not open the Nim trace",
      }),
    ).toHaveCount(0);
  });
});
