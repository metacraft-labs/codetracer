// Installed plugins run out of process (Extensibility-Model.md §11): what the
// desktop and `ct host` plugin specs (`tests/plugins/`) share.
//
// The `acme-tools` test package
// (`src/frontend/viewmodel/tests/unit/plugin_packages/acme-tools/`) is built
// with the plugin SDK and installed as a component the way `ct install` lays
// one out, by the Nim fixture's own command (`install_acme_tools.nim`), with
// the compiler on `PATH`. It is a real native plugin: one executable hosting
// two plugins, `acme-tools.metrics` (well behaved) and `acme-tools.flame`
// (misbehaves on request through its `mode` setting).

import * as childProcess from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import type { Page } from "@playwright/test";

const repoRoot = path.resolve(path.resolve(), "..", "..", "..");
const installer = path.join(repoRoot, "src", "frontend", "viewmodel", "tests",
                            "unit", "install_acme_tools.nim");

export const PluginExecutablePattern = "acme-tools@1.0.0/bin/acme-tools-plugins";

export interface PluginHome {
  /** `CODETRACER_COMPONENTS_ROOT`: where the package is installed. */
  components: string;
  /** `CODETRACER_USER_ROOT`: the grant ledger and the plugin settings. */
  userRoot: string;
}

/**
 * A fresh components root holding `acme-tools@1.0.0`, and a user root whose
 * `plugin-settings.json` is `settings` (when given). With
 * `capturesWindowInput`, `flame` declares it (a window layer needs it).
 */
export function installAcmeTools(settings?: object, capturesWindowInput = false): PluginHome {
  const base = fs.mkdtempSync(path.join(os.tmpdir(), "ct-gui-plugins-"));
  const home: PluginHome = {
    components: path.join(base, "components"),
    userRoot: path.join(base, "user-root"),
  };
  fs.mkdirSync(home.components, { recursive: true });
  fs.mkdirSync(home.userRoot, { recursive: true });
  const nimcache = path.join(os.tmpdir(), "ct-gui-plugins-installer-cache");
  childProcess.execFileSync("nim", ["c", "-r", "--hints:off", "--warnings:off",
    `--nimcache:${nimcache}`, `-o:${path.join(nimcache, "install_acme_tools")}`,
    installer, home.components, ...(capturesWindowInput ? ["--captures-window-input"] : [])],
    { cwd: repoRoot, stdio: "pipe", timeout: 600_000 });
  if (settings !== undefined) {
    fs.writeFileSync(path.join(home.userRoot, "plugin-settings.json"),
                     JSON.stringify(settings));
  }
  return home;
}

export function pluginEnv(home: PluginHome, extra: Record<string, string> = {}): Record<string, string> {
  return {
    CODETRACER_COMPONENTS_ROOT: home.components,
    CODETRACER_USER_ROOT: home.userRoot,
    ...extra,
  };
}

/**
 * The pids of the running `acme-tools` plugin processes: those whose argv[0]
 * names the installed executable, read from `/proc` in this process. Not
 * `pgrep -f`: a full-command-line match also finds whatever wraps the probe
 * itself (a shell, or a command relay that carries pgrep's argv), which shows
 * up as a pid that is gone a moment later.
 */
export function pluginPids(home?: PluginHome): number[] {
  const pids: number[] = [];
  for (const entry of fs.readdirSync("/proc")) {
    if (!/^[0-9]+$/.test(entry)) continue;
    let argv0 = "";
    try {
      argv0 = fs.readFileSync(path.join("/proc", entry, "cmdline"), "latin1").split("\0")[0];
    } catch {
      continue;
    }
    const ok = home ? argv0.includes(path.join(home.components, PluginExecutablePattern))
                    : argv0.endsWith(PluginExecutablePattern);
    if (ok) pids.push(Number(entry));
  }
  return pids;
}

/**
 * `ps` lines (pid, parent, parent's command, own command) for `pids`, for an
 * assertion message: a plugin process that should not exist says who
 * started it.
 */
export function describePids(pids: number[]): string {
  return pids.map((pid) => {
    try {
      const own = childProcess.execFileSync("ps", ["-o", "pid=,ppid=,args=", "-p", String(pid)],
                                            { encoding: "utf-8" }).trim();
      const ppid = own.split(/\s+/)[1];
      const parent = childProcess.execFileSync("ps", ["-o", "args=", "-p", ppid],
                                               { encoding: "utf-8" }).trim();
      return `${own}\n    parent: ${parent}`;
    } catch {
      return `${pid} (gone)`;
    }
  }).join("\n");
}

/** The tab on screen's last `CODETRACER::plugins-state`, or null. */
export async function pluginState(page: Page): Promise<any> {
  const text = await page.evaluate(() => {
    const f = (globalThis as any).__ctPluginState;
    return typeof f === "function" ? String(f()) : "";
  });
  return text.length > 0 ? JSON.parse(text) : null;
}

export function pluginOf(state: any, id: string): any {
  return (state?.plugins ?? []).find((p: any) => p.id === id) ?? null;
}

/** The text a contributed pane shows, or "" when it is not mounted. */
export async function paneText(page: Page, id: string): Promise<string> {
  const pane = page.locator(`[data-contributed-pane="${id}"]`);
  if ((await pane.count()) === 0) return "";
  return (await pane.first().innerText()).trim();
}

/** The status bar's plugin item, or "". */
export async function pluginStatusItem(page: Page): Promise<string> {
  const item = page.locator("[data-ct-plugin-status]");
  if ((await item.count()) === 0) return "";
  return (await item.first().innerText()).trim();
}

/**
 * Count the keydowns that reach the document's body (the target phase): a key
 * a plugin took is stopped in the router's capture listener and never does.
 */
export async function countBodyKeys(page: Page): Promise<void> {
  await page.evaluate(() => {
    const g = globalThis as any;
    g.__ctBodyKeys = [];
    document.body.addEventListener("keydown", (ev) => g.__ctBodyKeys.push(ev.key));
  });
}

export async function bodyKeys(page: Page): Promise<string[]> {
  return await page.evaluate(() => (globalThis as any).__ctBodyKeys ?? []);
}
