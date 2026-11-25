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
const lensInstaller = path.join(repoRoot, "src", "frontend", "viewmodel", "tests",
                                "unit", "install_ct_lens.nim");

export const PluginExecutablePattern = "acme-tools@1.0.0/bin/acme-tools-plugins";
/** The `ct-lens` package's executable (`src/plugins/ct-lens/`). */
export const LensExecutablePattern = "ct-lens@0.1.0/bin/ct-lens-plugins";

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

/**
 * A fresh components root holding the `ct-lens` package as it ships
 * (`src/plugins/ct-lens/`, built by `install_ct_lens.nim` with the plugin
 * SDK), and an empty user root.
 */
export function installCtLens(): PluginHome {
  const base = fs.mkdtempSync(path.join(os.tmpdir(), "ct-gui-ct-lens-"));
  const home: PluginHome = {
    components: path.join(base, "components"),
    userRoot: path.join(base, "user-root"),
  };
  fs.mkdirSync(home.components, { recursive: true });
  fs.mkdirSync(home.userRoot, { recursive: true });
  const nimcache = path.join(os.tmpdir(), "ct-gui-ct-lens-installer-cache");
  childProcess.execFileSync("nim", ["c", "-r", "--hints:off", "--warnings:off",
    `--nimcache:${nimcache}`, `-o:${path.join(nimcache, "install_ct_lens")}`,
    lensInstaller, home.components],
    { cwd: repoRoot, stdio: "pipe", timeout: 600_000 });
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
export function pluginPids(home?: PluginHome,
                           executable: string = PluginExecutablePattern): number[] {
  const pids: number[] = [];
  for (const entry of fs.readdirSync("/proc")) {
    if (!/^[0-9]+$/.test(entry)) continue;
    let argv0 = "";
    try {
      argv0 = fs.readFileSync(path.join("/proc", entry, "cmdline"), "latin1").split("\0")[0];
    } catch {
      continue;
    }
    const ok = home ? argv0.includes(path.join(home.components, executable))
                    : argv0.endsWith(executable);
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

/**
 * The recovery chord (§11.7.6) as a user presses it: three Escapes that
 * arrive together. Sent through the DevTools protocol without waiting for
 * each to be handled: three `keyboard.press` calls wait for one another, and
 * on a loaded machine they arrived 1.5-1.7 s apart (each key's own
 * `timeStamp`, measured), so the window rightly saw no chord.
 */
export async function pressRecoveryChord(page: Page): Promise<void> {
  const cdp = await page.context().newCDPSession(page);
  const key = { key: "Escape", code: "Escape", windowsVirtualKeyCode: 27, nativeVirtualKeyCode: 27 };
  const sent: Promise<unknown>[] = [];
  for (let i = 0; i < 3; i++) {
    sent.push(cdp.send("Input.dispatchKeyEvent", { type: "rawKeyDown", ...key }));
    sent.push(cdp.send("Input.dispatchKeyEvent", { type: "keyUp", ...key }));
  }
  await Promise.all(sent);
  await cdp.detach();
}

/** A plugin's status item `item`, as the session's plugin state names it. */
export function statusText(st: any, plugin: string, item: string): string {
  const it = (st?.status ?? []).find((s: any) => s.plugin === plugin && s.item === item);
  return it ? String(it.text) : "";
}

/** The page's debugger line, for a red run's message ("?" before a stop). */
export async function debuggerLine(page: Page): Promise<string> {
  return await page.evaluate(() => {
    const d = (window as any).data;
    const loc = d?.sessions?.[d.activeSessionIndex]?.services?.debugger?.location;
    return loc ? `line ${loc.line}` : "?";
  });
}

/** A plugin's command `op`, as the session's plugin state lists it, or null. */
export function commandOf(st: any, plugin: string, op: string): any {
  return (st?.commands ?? []).find((c: any) => c.plugin === plugin && c.op === op) ?? null;
}

/**
 * Step over (F10, which no plugin binds) until `plugin`'s status item `item`
 * names exactly ONE changed value, at most 25 times and within 6 minutes (so
 * a red run still reaches its assertion and says what the item read at each
 * stop). Returns that value ("" when no step did) and what the item read at
 * each stop, for the failure message.
 *
 * The item is read only once the plugin has answered about the NEW stop: the
 * session has moved past the stop before the key, and `command`'s enablement
 * (pushed with the item, after it) was computed there. Read as soon as the
 * key was pressed, the item still named the last stop's change: F7 then
 * watched that value while the step landed on the next stop, whose own
 * change it never watched (measured at load ~170). The same early read made
 * the loop press F10 again at once, while the step was still running: the
 * window ignores a step key during a step (7 presses in 0.6 s made one `next`
 * request, measured), so 25 tries were spent inside a few slow steps and
 * stepping looked stopped. The wait is on the new stop, so it is long enough
 * for a loaded replay. "changed: …" is the plugin's reading before it knows
 * the new stop's changes. At a new stop the plugin may push more than one
 * reading (what it can tell at once, then the stop's own changes as they
 * arrive), so the item is taken once it has held still for 1.5 s at the new
 * stop.
 */
export async function stepUntilOneChange(
  page: Page, plugin: string, item: string, command: string,
): Promise<{ changed: string; seen: string[] }> {
  let changed = "";
  const seen: string[] = [];
  const loopUntil = Date.now() + 360_000;
  for (let i = 0; i < 25 && changed === "" && Date.now() < loopUntil; i++) {
    const before = (await pluginState(page))?.position ?? -1;
    // The window's key, not a focused control's.
    await page.evaluate(() => (document.activeElement as any)?.blur?.());
    await page.keyboard.press("F10");
    const deadline = Date.now() + 60_000;
    let text = "";
    let heldSince = 0;
    let held = "";
    while (Date.now() < deadline) {
      const st = await pluginState(page);
      const at = st?.position ?? -1;
      const cmd = commandOf(st, plugin, command);
      text = statusText(st, plugin, item);
      const current = at > before && cmd?.position === at &&
        text.startsWith("changed: ") && text !== "changed: …";
      if (!current) {
        held = ""; heldSince = 0;
      } else if (text !== held) {
        held = text; heldSince = Date.now();
      } else if (Date.now() - heldSince >= 1_500) {
        break;
      }
      await page.waitForTimeout(300);
    }
    seen.push(`${await debuggerLine(page)}: ${text}`);
    const m = /^changed: ([^,\s…]+)$/.exec(text);
    if (m && m[1] !== "none") changed = m[1];
  }
  return { changed, seen };
}
