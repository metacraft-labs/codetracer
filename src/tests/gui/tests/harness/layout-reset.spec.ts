/**
 * Self-test for the launch fixture's layout decision,
 * `lib/layout-reset.prepareUserLayout`: which `default_layout.json` the next
 * launch finds in `$CODETRACER_HOME/config`.
 *
 * The property pinned here is the DEFAULT: with neither option set the saved
 * layout is removed, so a launch takes the product's own first-run path and
 * opens the Debug mode's default. Until that was the default, every GUI spec
 * that did not opt out launched on the raw bundled tree, which no CodeTracer
 * mode draws. `tests/layout/fixture-default-layout.spec.ts` observes the same
 * property in the real Electron app; this one runs in milliseconds and needs
 * no build.
 *
 * No mocks: real files in a scratch `CODETRACER_HOME` and a scratch install
 * directory carrying a bundled `src/config/default_layout.json`. No Electron.
 */

import { test, expect } from "@playwright/test";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { prepareUserLayout } from "../../lib/layout-reset";

const BUNDLED = '{"bundled": true}\n';
const SAVED = '{"saved": "by an earlier launch"}\n';

interface Scratch {
  installDir: string;
  layoutFile: string;
}

let root = "";
let previousHome: string | undefined = undefined;

/** A scratch install (with a bundled layout) and a scratch home. */
function scratch(): Scratch {
  const installDir = path.join(root, "install");
  fs.mkdirSync(path.join(installDir, "src", "config"), { recursive: true });
  fs.writeFileSync(path.join(installDir, "src", "config", "default_layout.json"), BUNDLED);
  const configDir = path.join(root, "home", "config");
  fs.mkdirSync(configDir, { recursive: true });
  return { installDir, layoutFile: path.join(configDir, "default_layout.json") };
}

test.describe("harness: the launch fixture's saved-layout reset", () => {
  test.beforeEach(() => {
    root = fs.mkdtempSync(path.join(os.tmpdir(), "ct-layout-reset-"));
    previousHome = process.env.CODETRACER_HOME;
    process.env.CODETRACER_HOME = path.join(root, "home");
  });

  test.afterEach(() => {
    if (previousHome === undefined) delete process.env.CODETRACER_HOME;
    else process.env.CODETRACER_HOME = previousHome;
    fs.rmSync(root, { recursive: true, force: true });
  });

  test("by default the saved layout and its .broken sibling are removed: the first-run path", () => {
    const { installDir, layoutFile } = scratch();
    fs.writeFileSync(layoutFile, SAVED);
    fs.writeFileSync(layoutFile + ".broken", SAVED);

    expect(prepareUserLayout({ bundledLayout: false, preserveUserLayout: false }, installDir))
      .toBe("first-run");

    expect(fs.existsSync(layoutFile)).toBe(false);
    expect(fs.existsSync(layoutFile + ".broken")).toBe(false);
  });

  test("by default nothing is installed even when no layout was saved", () => {
    const { installDir, layoutFile } = scratch();

    expect(prepareUserLayout({ bundledLayout: false, preserveUserLayout: false }, installDir))
      .toBe("first-run");

    expect(fs.existsSync(layoutFile)).toBe(false);
  });

  test("bundledLayout installs the bundled tree byte for byte", () => {
    const { installDir, layoutFile } = scratch();
    fs.writeFileSync(layoutFile, SAVED);

    expect(prepareUserLayout({ bundledLayout: true, preserveUserLayout: false }, installDir))
      .toBe("bundled");

    expect(fs.readFileSync(layoutFile, "utf8")).toBe(BUNDLED);
  });

  test("bundledLayout without a bundled tree throws rather than launching on another layout", () => {
    const { installDir } = scratch();
    fs.rmSync(path.join(installDir, "src", "config", "default_layout.json"));

    expect(() => prepareUserLayout({ bundledLayout: true, preserveUserLayout: false }, installDir))
      .toThrow(/Bundled default layout not found/);
  });

  test("preserveUserLayout leaves the saved layout untouched", () => {
    const { installDir, layoutFile } = scratch();
    fs.writeFileSync(layoutFile, SAVED);

    expect(prepareUserLayout({ bundledLayout: false, preserveUserLayout: true }, installDir))
      .toBe("preserved");

    expect(fs.readFileSync(layoutFile, "utf8")).toBe(SAVED);
  });

  test("both options together are refused, and the saved layout is untouched", () => {
    const { installDir, layoutFile } = scratch();
    fs.writeFileSync(layoutFile, SAVED);

    expect(() => prepareUserLayout({ bundledLayout: true, preserveUserLayout: true }, installDir))
      .toThrow(/contradict/);

    expect(fs.readFileSync(layoutFile, "utf8")).toBe(SAVED);
  });
});
