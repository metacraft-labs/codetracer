/** Discovery uses actual filesystem entries and the real Playwright collector.
 * The inert CLI is never executed: its contents are irrelevant to discovery.
 * No recorder, filesystem, or child-process APIs are mocked.
 */
import { test, expect } from "@playwright/test";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { spawnSync } from "node:child_process";
import { findJsRecorder } from "../../lib/js-trace-fixture";
import { findRecorderRepo } from "../../lib/sibling-test-programs";
import { javascriptRecorderUnavailableReason } from "../../lib/value-origin-fixtures";

test("JavaScript CLI file resolves to its own recorder repository", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "ct-js-path-"));
  const cli = path.join(root, "packages/cli/dist/index.js");
  const previous = process.env.CODETRACER_JS_RECORDER_PATH;
  try {
    fs.mkdirSync(path.dirname(cli), { recursive: true });
    fs.mkdirSync(path.join(root, "test-programs"));
    fs.writeFileSync(cli, "// file discovery only\n");
    process.env.CODETRACER_JS_RECORDER_PATH = cli;
    expect(findJsRecorder()).toBe(cli);
    expect(findRecorderRepo("js")).toBe(root);
    expect(javascriptRecorderUnavailableReason()).toBeNull();
  } finally {
    if (previous === undefined) delete process.env.CODETRACER_JS_RECORDER_PATH;
    else process.env.CODETRACER_JS_RECORDER_PATH = previous;
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("a directory is not an available JavaScript recorder CLI", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "ct-js-directory-"));
  const previous = process.env.CODETRACER_JS_RECORDER_PATH;
  const previousPath = process.env.PATH;
  try {
    // Keep Node available while excluding any installed recorder from PATH.
    fs.symlinkSync(process.execPath, path.join(root, process.platform === "win32" ? "node.exe" : "node"));
    process.env.PATH = root;
    process.env.CODETRACER_JS_RECORDER_PATH = root;
    expect(javascriptRecorderUnavailableReason()).not.toBeNull();
    try {
      expect(findJsRecorder()).not.toBe(root);
    } catch (error) {
      expect(String(error)).toContain("codetracer-js-recorder not found");
    }
  } finally {
    if (previous === undefined) delete process.env.CODETRACER_JS_RECORDER_PATH;
    else process.env.CODETRACER_JS_RECORDER_PATH = previous;
    if (previousPath === undefined) delete process.env.PATH;
    else process.env.PATH = previousPath;
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("cross-tracer specs collect when recording prerequisites are missing", () => {
  const gui = path.resolve(__dirname, "../..");
  const result = spawnSync(process.execPath, [
    require.resolve("@playwright/test/cli"), "test", "--list", "--reporter=list",
    "tests/value-origin/cross-tracer-process-tree.spec.ts",
    "tests/value-origin/cross-tracer-three-recording.spec.ts",
    "tests/value-origin/event-log-correlation-markers-three-trace.spec.ts",
  ], {
    cwd: gui,
    encoding: "utf8",
    env: { ...process.env,
      CODETRACER_JS_RECORDER_PATH: "/nonexistent/packages/cli/dist/index.js",
      CODETRACER_WASM_INSTRUMENTER_PATH: "/nonexistent/instrumenter",
    },
  });
  expect(result.error).toBeUndefined();
  expect(result.status, result.stdout + result.stderr).toBe(0);
  for (const name of ["cross-tracer-process-tree", "cross-tracer-three-recording",
    "event-log-correlation-markers-three-trace"]) {
    expect(result.stdout).toContain(name + ".spec.ts");
  }
  expect(result.stdout).not.toContain("0 tests");
  expect(result.stderr).not.toContain("materialize-recording:");
});
