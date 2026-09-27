/**
 * plat45-default-arrangement-capture.spec.ts — PLAT-45's desktop column: the
 * arrangement the REAL Electron front-end opens a recording with, when the
 * user has no saved layout at all.
 *
 * PLAT-45 makes every product open with ONE shared arrangement, and makes the
 * desktop's `src/config/default_layout.json` a GENERATED translation of it.
 * This spec reads, from a run of the real app on the `calc` recording, on the
 * product's own first-run path (no user `default_layout.json`, so the index
 * process copies `<prefix>/config/default_layout.json` itself):
 *
 *   * the GoldenLayout config AS LOADED (`layout.saveLayout()`), and
 *   * every stack's DOM rectangle, with the `Content` ordinals of its tabs and
 *     its active tab — what the user sees.
 *
 * It writes them to `src/tests/visual/answers/plat45-default-arrangement.electron.json`.
 * `src/frontend/tui/tests/test_plat45_three_media.nim` reduces the DOM
 * rectangles to the medium-independent relation and compares them with the
 * shared tree's, the terminal's and the GPUI window's; it FAILS BY NAME when
 * the file is absent, naming `just plat45-capture-electron`.
 *
 * Two runs, two prefixes, both prepared by `scripts/plat45-capture-electron.sh`
 * (in a whole-suite run with no prefix prepared, `generated` runs against the
 * build itself and `scratch` is skipped by name):
 *
 *   * `generated` — a prefix whose `config/default_layout.json` is the
 *     committed, generated file: the desktop's default AS SHIPPED;
 *   * `scratch` — a prefix whose `config/default_layout.json` was generated
 *     from a SCRATCH BUILD of the shared tree with one edit (the right
 *     column's two stacks swapped): the desktop's default must change with it.
 *
 * No mocks: a real recording, the real `ct`, a real `replay-server`, the real
 * Electron app.
 */

import * as crypto from "crypto";
import * as fs from "fs";
import * as path from "path";

import { test } from "../../lib/fixtures";

const repoRoot = path.resolve(__dirname, "..", "..", "..", "..", "..");
const answersDir = path.join(repoRoot, "src", "tests", "visual", "answers");
const answersFile = path.join(answersDir, "plat45-default-arrangement.electron.json");

// THE RECORDING IS MADE BY THE RUN ITSELF: `launchMode: "trace"` records
// `test-programs/calc/main.py` with the `ct` under test before the app opens,
// as every DB-based spec does. It used to read the terminal suites' cached
// `test-logs/tui-fixtures/calc-*` and threw at LOAD when that cache was cold —
// which is every CI job, since none of them runs the terminal lanes first.
const calcProgram = "calc/main.py";

function prefixVar(which: string): string {
  return which === "generated" ? "PLAT45_PREFIX_GENERATED" : "PLAT45_PREFIX_SCRATCH";
}

function buildPrefix(): string {
  const build = process.env.CODETRACER_BUILD_DIR && process.env.CODETRACER_BUILD_DIR.length > 0
    ? process.env.CODETRACER_BUILD_DIR
    : path.join(repoRoot, "src", "build-debug");
  // A job that runs a PACKAGED `ct` (CODETRACER_E2E_CT_PATH, the nix build)
  // has no tup build directory; its `config/` is this checkout's `src/config/`
  // copied into the package, so that is the shipped default to compare with.
  if (!fs.existsSync(path.join(build, "config", "default_layout.json"))) {
    return path.join(repoRoot, "src");
  }
  return build;
}

function prefixFor(which: string): string {
  // Read lazily, INSIDE the test, never at module load. With no prepared
  // prefix the GENERATED capture runs against the build itself (in CI's GUI
  // job the build is this checkout); the SCRATCH capture needs the prefix
  // `just plat45-capture-electron` prepares and is skipped by name without it.
  const value = process.env[prefixVar(which)] ?? "";
  if (value.length > 0) return value;
  return buildPrefix();
}

function readAnswers(): Record<string, unknown> {
  if (!fs.existsSync(answersFile)) return {};
  return JSON.parse(fs.readFileSync(answersFile, "utf8"));
}

for (const which of ["generated", "scratch"]) {
  test.describe(`PLAT-45 desktop default (${which})`, () => {
    test.use({
      sourcePath: calcProgram,
      launchMode: "trace",
      noUserLayout: true,
      codetracerPrefixOverride: process.env[prefixVar(which)] ?? "",
    });
    test.setTimeout(300_000);

    // Skipped BY NAME, before the app is launched, when the scratch prefix
    // was not prepared (a whole-suite run).
    test.skip(which === "scratch" && (process.env.PLAT45_PREFIX_SCRATCH ?? "").length === 0,
      "PLAT-45: the scratch-build capture needs the prefix 'just plat45-capture-electron' prepares (PLAT45_PREFIX_SCRATCH)");

    test(`the arrangement the desktop opens with (${which})`, async ({ ctPage }) => {
      await ctPage.waitForSelector(".view-line", { timeout: 90_000 });
      await ctPage.waitForTimeout(2_000);

      const captured = await ctPage.evaluate(() => {
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        const w = window as any;
        const gl = w.data?.ui?.layout;
        if (!gl) return { error: "no GoldenLayout instance at window.data.ui.layout" };
        const stacks: unknown[] = [];
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        const walk = (item: any) => {
          if (!item) return;
          if (item.type === "stack") {
            const rect = item.element.getBoundingClientRect();
            // eslint-disable-next-line @typescript-eslint/no-explicit-any
            const contents = item.contentItems.map((c: any) => {
              const cfg = c.toConfig ? c.toConfig() : {};
              const state = cfg.componentState ?? c.container?.state ?? {};
              return typeof state.content === "number" ? state.content : -1;
            });
            const active = item.getActiveComponentItem
              ? item.contentItems.indexOf(item.getActiveComponentItem())
              : 0;
            stacks.push({
              x: rect.x, y: rect.y, w: rect.width, h: rect.height,
              contents, active,
            });
            return;
          }
          for (const c of item.contentItems ?? []) walk(c);
        };
        walk(gl.rootItem);
        return {
          loadedConfig: gl.saveLayout ? gl.saveLayout() : null,
          stacks,
          viewport: { w: window.innerWidth, h: window.innerHeight },
        };
      });

      const prefix = prefixFor(which);
      const shipped = fs.readFileSync(path.join(prefix, "config", "default_layout.json"));
      const answers = readAnswers();
      answers[which] = {
        takenAt: new Date().toISOString(),
        prefixDefaultSha256: crypto.createHash("sha256").update(shipped).digest("hex"),
        ...captured,
      };
      fs.mkdirSync(answersDir, { recursive: true });
      // The loaded config names the opened source file by absolute path; the
      // checkout's own location is not part of the answer, so it is written
      // as `<repo>`.
      fs.writeFileSync(answersFile,
        JSON.stringify(answers, null, 2).split(repoRoot).join("<repo>") + "\n");
    });
  });
}
