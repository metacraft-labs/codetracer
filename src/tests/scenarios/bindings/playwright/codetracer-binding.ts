// CodeTracer's Playwright binding: the desktop (Electron) flavour of the
// CodeTracer scenario pack (../../pack/codetracer.pack.yaml).
//
// Loaded by DemoVideoScript-Playwright's arm (`node src/main.ts --binding
// <this file>`), which answers the scenario runner's backend protocol through
// Playwright. This module supplies what is CodeTracer's:
//
//   * the stages, which record programs and write projects through the
//     pack's one stage implementation (`ct-scenario-stage`, the same Nim code
//     the terminal and GPUI bindings link), then start the real `ct` → Electron
//     with Playwright's Electron driver, recording video;
//   * the surface: the page objects a user sees, read from the DOM in one
//     pass with the selectors the desktop's page objects use
//     (`src/tests/gui/page-objects/`) — reading only, never changing the page;
//   * the conditions it can detect (`replay-idle`);
//   * the binding resolver: the running window's own router, asked through
//     the read-only seam `window.__CODETRACER_TEST__.chordForOperation`.
//
// Input never goes through here: the arm delivers it with Playwright's mouse
// and keyboard (real input events), and its lint refuses script injection on
// that path.
//
// No mocks: the recording, `ct`, the replay server and Electron are the real
// ones.
import { spawnSync } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";
import { fileURLToPath } from "node:url";
import { _electron } from "playwright-core";

type Ctx = any;
type Node = {
  role: string;
  keys: Array<[string, string]>;
  props: Record<string, unknown>;
  x: number;
  y: number;
  w: number;
  h: number;
  visible: boolean;
  focused?: boolean;
  unreadable?: Record<string, string>;
  children: Node[];
};

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, "..", "..", "..", "..", "..");
const srcDir = path.join(repo, "src");
const buildDir = process.env.CODETRACER_BUILD_DIR ?? path.join(srcDir, "build-debug");
const ctBin = process.env.CT_BIN ?? path.join(buildDir, "bin", "ct");

function stageCli(): string {
  const p = process.env.CT_SCENARIO_STAGE ?? path.join(repo, "build", "bin", "ct-scenario-stage");
  if (!fs.existsSync(p)) {
    throw new Error(`ct-scenario-stage is not built at ${p} (just scenario-build)`);
  }
  return p;
}

function runStageCli(args: string[]): any {
  const r = spawnSync(stageCli(), args, { encoding: "utf-8", maxBuffer: 64 << 20 });
  if (r.status !== 0) {
    throw new Error(`ct-scenario-stage ${args[0]} ${args[2] ?? ""}: ${(r.stderr || r.stdout || "").trim()}`);
  }
  const out = r.stdout.trim().split("\n").filter((l) => l.startsWith("{")).pop() ?? "{}";
  return JSON.parse(out);
}

// --- what this binding can deliver --------------------------------------------

const ROLES: Record<string, { affordances: string[]; properties: string[] }> = {
  window: { affordances: [], properties: ["title", "mode"] },
  "session-strip": { affordances: [], properties: ["count", "active"] },
  "session-tab": { affordances: ["click", "context-click"], properties: ["title", "active"] },
  "pane-tab": { affordances: ["click", "context-click", "drag-source"], properties: ["label", "active"] },
  toolbar: { affordances: [], properties: [] },
  "toolbar-button": { affordances: ["click"], properties: ["label", "enabled"] },
  editor: {
    affordances: ["click", "context-click", "wheel", "focusable", "text-entry"],
    properties: ["file", "active", "focused", "read-only", "current-line", "caret-line",
                 "first-visible", "last-visible", "text"],
  },
  line: {
    affordances: ["click", "double-click", "context-click"],
    properties: ["number", "text", "current", "caret", "breakpoint", "tracepoint"],
  },
  "call-trace": { affordances: ["wheel", "focusable"], properties: ["count", "focused"] },
  call: { affordances: ["click", "double-click", "context-click"],
          properties: ["name", "current", "selected", "arguments"] },
  "event-log": { affordances: ["wheel", "focusable"], properties: ["count", "total", "focused"] },
  event: { affordances: ["click", "double-click", "context-click"], properties: ["text", "kind", "current", "future"] },
  variables: { affordances: ["wheel", "focusable"], properties: ["count", "focused"] },
  variable: { affordances: ["click", "double-click", "context-click"], properties: ["name", "type", "value"] },
  "status-line": { affordances: [], properties: ["message", "location"] },
  omnibox: { affordances: ["click", "text-entry", "focusable"], properties: ["query", "focused", "count"] },
  option: { affordances: ["click"], properties: ["label", "detail", "selected"] },
  "context-menu": { affordances: [], properties: ["count"] },
  "menu-item": { affordances: ["click"], properties: ["label", "enabled", "shortcut"] },
  "terminal-output": { affordances: ["wheel", "focusable"], properties: ["text", "count"] },
  filesystem: { affordances: ["wheel", "focusable"], properties: ["count"] },
  "file-node": { affordances: ["click", "double-click", "context-click"], properties: ["name", "kind", "selected"] },
};

// --- the surface: one read of the DOM ------------------------------------------

// Runs IN THE PAGE. Reads only: it walks the DOM and measures it, and writes
// nothing (the runner probes that by reading every property twice).
function readSurface(): any {
  const vis = (el: Element | null): boolean => {
    if (!el) return false;
    const r = (el as HTMLElement).getBoundingClientRect();
    if (r.width <= 0 || r.height <= 0) return false;
    const cs = getComputedStyle(el as HTMLElement);
    return cs.visibility !== "hidden" && cs.display !== "none";
  };
  const box = (el: Element) => {
    const r = (el as HTMLElement).getBoundingClientRect();
    return { x: r.left, y: r.top, w: r.width, h: r.height };
  };
  const text = (el: Element | null | undefined) => ((el?.textContent ?? "").replace(/\s+/g, " ").trim());
  const node = (role: string, el: Element | null, props: Record<string, unknown>,
                keys: Array<[string, string]> = [], extra: Partial<any> = {}): any => {
    const b = el ? box(el) : { x: 0, y: 0, w: 0, h: 0 };
    return { role, keys, props, ...b, visible: el ? vis(el) : false, children: [], ...extra };
  };
  const active = document.activeElement;
  const within = (el: Element | null) => !!(el && active && (el === active || el.contains(active)));

  const W = window as any;
  const root = node("window", document.body, {
    title: document.title,
    mode: (document.querySelector("[data-session-mode]")?.getAttribute("data-session-mode") ?? "debug")
      .toLowerCase().includes("edit") ? "edit" : "debug",
  });
  root.x = 0; root.y = 0; root.w = window.innerWidth; root.h = window.innerHeight; root.visible = true;

  // session tabs
  // The strip is in the DOM with one tab too (`single-session`, drawn
  // compact): its count is still a fact about the window.
  const bar = document.querySelector("#session-tab-bar");
  if (bar) {
    const tabs = Array.from(bar.querySelectorAll(".session-tab")) as HTMLElement[];
    const strip = node("session-strip", bar, { count: tabs.length, active: "" });
    for (const t of tabs) {
      const title = text(t.querySelector(".session-tab-label") ?? t);
      const isActive = t.classList.contains("active");
      if (isActive) strip.props.active = title;
      strip.children.push(node("session-tab", t, { title, active: isActive }, [["title", title]]));
    }
    root.children.push(strip);
  }

  // pane tabs (GoldenLayout titles)
  for (const t of Array.from(document.querySelectorAll(".lm_tab")) as HTMLElement[]) {
    if (!vis(t)) continue;
    const label = text(t.querySelector(".lm_title") ?? t);
    if (!label) continue;
    root.children.push(node("pane-tab", t, { label, active: t.classList.contains("lm_active") }, [["label", label]]));
  }

  // debug toolbar
  const tb = document.querySelector("#debug, .debug-buttons, [data-session-mode]");
  if (tb && vis(tb)) {
    const toolbar = node("toolbar", tb, {});
    for (const b of Array.from(tb.querySelectorAll("button, .debug-button, [role=button]")) as HTMLElement[]) {
      if (!vis(b)) continue;
      const label = (b.getAttribute("aria-label") || b.getAttribute("title") || b.id || text(b)).trim();
      if (!label) continue;
      toolbar.children.push(node("toolbar-button", b, {
        label, enabled: !(b as HTMLButtonElement).disabled && !b.classList.contains("disabled"),
      }, [["label", label]]));
    }
    root.children.push(toolbar);
  }

  // editors: one per Monaco editor component; the file is its GoldenLayout tab
  for (const comp of Array.from(document.querySelectorAll("div[id^='editorComponent']")) as HTMLElement[]) {
    const container = comp.closest(".lm_item_container") as HTMLElement | null;
    const stack = comp.closest(".lm_stack");
    let file = comp.getAttribute("data-file-name") ?? comp.getAttribute("data-path") ?? "";
    let isActive = vis(comp);
    if (!file && stack) {
      // the tab whose content this is: the active one when the editor is shown
      const tabs = Array.from(stack.querySelectorAll(".lm_tab")) as HTMLElement[];
      const t = tabs.find((x) => x.classList.contains("lm_active"));
      if (t && isActive) file = text(t.querySelector(".lm_title") ?? t);
    }
    if (!file) continue;
    file = file.split("/").pop() ?? file;
    const ed = comp.querySelector(".monaco-editor") as HTMLElement | null;
    const props: Record<string, unknown> = {
      file, active: isActive, focused: within(comp), "read-only": false,
      "current-line": 0, "caret-line": 0, "first-visible": 0, "last-visible": 0, text: [] as string[],
    };
    const editorNode = node("editor", container ?? comp, props, [["file", file]]);
    if (ed) {
      // Each gutter row carries its line number (`.gutter[data-line]`); the
      // view line drawn at the same height is that line's text.
      const gutters = Array.from(ed.querySelectorAll(".margin-view-overlays .gutter[data-line]")) as HTMLElement[];
      const lines = Array.from(ed.querySelectorAll(".view-lines > .view-line")) as HTMLElement[];
      const lineAt = (top: number) => lines.find((l) => Math.abs(l.getBoundingClientRect().top - top) < 3);
      const rows: Array<{ n: number; g: HTMLElement; l: HTMLElement | undefined }> = gutters
        .map((g) => ({ n: parseInt(g.getAttribute("data-line") ?? "0", 10), g,
                       l: lineAt(g.getBoundingClientRect().top) }))
        .filter((r) => r.n > 0 && r.g.getBoundingClientRect().height > 0)
        .sort((a, b) => a.n - b.n);
      // The execution line: the gutter row or view line the editor marks
      // (`gutter-highlight-active`, `.view-line.highlight`, as the page
      // objects read it).
      const highlightTops = (Array.from(ed.querySelectorAll(
        ".gutter-highlight-active, .view-lines > .view-line.highlight")) as HTMLElement[])
        .map((e) => e.getBoundingClientRect().top);
      const cursorTop = (ed.querySelector(".cursors-layer .cursor") as HTMLElement | null)?.getBoundingClientRect();
      const cursorShown = !!cursorTop && cursorTop.height > 0 && within(comp);
      const texts: string[] = [];
      for (const r of rows) {
        const lineEl = r.l ?? r.g;
        const lb = lineEl.getBoundingClientRect();
        const gb = r.g.getBoundingClientRect();
        const t = (r.l?.textContent ?? "").replace(/ /g, " ");
        texts.push(t);
        const current = highlightTops.some((t) => Math.abs(t - r.g.getBoundingClientRect().top) < 3);
        const caret = cursorShown && cursorTop!.top >= lb.top - 1 && cursorTop!.top < lb.bottom - 1;
        if (current) props["current-line"] = r.n;
        if (caret) props["caret-line"] = r.n;
        const lnode = {
          role: "line", keys: [["number", String(r.n)]],
          props: {
            number: r.n, text: t, current, caret,
            breakpoint: !!r.g.querySelector(".gutter-breakpoint, .breakpoint, [class*='breakpoint']"),
            tracepoint: !!r.g.querySelector("[class*='tracepoint']"),
          },
          x: gb.left, y: lb.top, w: (lb.right - gb.left), h: lb.height,
          visible: lb.height > 0 && lb.bottom > 0 && lb.top < window.innerHeight,
          children: [],
          // anchors, measured where the line is drawn (read by `anchor`)
          anchors: {
            gutter: { x: gb.left + gb.width / 2, y: gb.top + gb.height / 2 },
            textLeft: lb.left, textRight: lb.left + (r.l ? Math.min(lb.width, (r.l.firstElementChild as HTMLElement | null)?.getBoundingClientRect().width ?? lb.width) : lb.width),
            charWidth: t.length > 0 && r.l ? ((r.l.firstElementChild as HTMLElement | null)?.getBoundingClientRect().width ?? 0) / Math.max(1, t.length) : 7,
            firstChar: t.length - t.trimStart().length,
            midY: lb.top + lb.height / 2,
          },
        };
        editorNode.children.push(lnode);
      }
      props.text = texts;
      if (rows.length > 0) {
        props["first-visible"] = rows[0].n;
        props["last-visible"] = rows[rows.length - 1].n;
      }
      props["read-only"] = ed.classList.contains("readonly") || !!ed.querySelector("textarea[readonly]");
    }
    root.children.push(editorNode);
  }

  // call trace
  const ctComp = document.querySelector("div[id^='calltraceComponent']") as HTMLElement | null;
  if (ctComp && vis(ctComp)) {
    const rowsEl = Array.from(ctComp.querySelectorAll(".calltrace-call-line")) as HTMLElement[];
    const ct = node("call-trace", ctComp, { count: rowsEl.length, focused: within(ctComp) });
    for (const r of rowsEl) {
      if (!vis(r)) continue;
      const name = text(r.querySelector(".call-text")).replace(/\s+#\d+\s*$/, "").trim();
      if (!name) continue;
      ct.children.push(node("call", r, {
        name, current: r.classList.contains("current") || r.classList.contains("active-call"),
        selected: r.classList.contains("selected") || r.classList.contains("calltrace-selected"),
        arguments: text(r.querySelector(".call-args")),
      }, [["name", name]]));
    }
    root.children.push(ct);
  }

  // event log
  const elComp = document.querySelector("div[id^='eventLogComponent']") as HTMLElement | null;
  if (elComp && vis(elComp)) {
    const rowsEl = Array.from(elComp.querySelectorAll(".eventLog-dense-table tbody tr")) as HTMLElement[];
    const footer = text(elComp.querySelector(".data-tables-footer-info"));
    const m = /of\s+([\d,]+)/.exec(footer);
    const el = node("event-log", elComp, {
      count: rowsEl.length, total: m ? parseInt(m[1].replace(/,/g, ""), 10) : rowsEl.length,
      focused: within(elComp),
    });
    for (const r of rowsEl) {
      if (!vis(r)) continue;
      const t = text(r.querySelector(".eventLog-text") ?? r);
      el.children.push(node("event", r, {
        text: t, kind: r.getAttribute("data-event-kind") ?? "", current: r.classList.contains("active") ||
          r.classList.contains("current"), future: r.classList.contains("future"),
      }, [["text", t]]));
    }
    root.children.push(el);
  }

  // variables (the state pane)
  const stComp = document.querySelector("div[id^='stateComponent']") as HTMLElement | null;
  if (stComp && vis(stComp)) {
    const rowsEl = Array.from(stComp.querySelectorAll("[data-variable-name]")) as HTMLElement[];
    const vs = node("variables", stComp, { count: rowsEl.length, focused: within(stComp) });
    for (const r of rowsEl) {
      if (!vis(r)) continue;
      const name = r.getAttribute("data-variable-name") ?? "";
      const value = text(r.querySelector(".value-expanded-text, .value-text, .value") ?? r);
      vs.children.push(node("variable", r, {
        name, type: text(r.querySelector(".value-type")), value,
      }, [["name", name]]));
    }
    root.children.push(vs);
  }

  // status line
  const loc = document.querySelector(".location-path");
  const status = document.querySelector("#status-base, #status, .status-bar") ?? loc?.closest("div");
  if (status) {
    root.children.push(node("status-line", status, {
      message: text(document.querySelector("#active-notifications .notification-message")),
      location: text(loc),
    }));
  }

  // the command palette / omnibox
  const pal = document.querySelector("#command-view") as HTMLElement | null;
  if (pal && vis(pal)) {
    const q = document.querySelector("#command-query-text") as HTMLInputElement | null;
    const results = Array.from(pal.querySelectorAll(".command-result:not(.empty)")) as HTMLElement[];
    const om = node("omnibox", pal, { query: q?.value ?? text(q), focused: within(pal), count: results.length });
    for (const r of results) {
      const label = text(r.querySelector(".command-result-name, .command-name") ?? r);
      om.children.push(node("option", r, { label, detail: "", selected: r.classList.contains("active") || r.classList.contains("selected") }, [["label", label]]));
    }
    root.children.push(om);
  }

  // a context menu
  const menu = Array.from(document.querySelectorAll(".vakata-context, #context-menu-container")).find((m) => vis(m)) as HTMLElement | undefined;
  if (menu) {
    const items = Array.from(menu.querySelectorAll(".context-menu-item, li")) as HTMLElement[];
    const cm = node("context-menu", menu, { count: 0 });
    for (const it of items) {
      if (!vis(it)) continue;
      const label = text(it.querySelector(".ct-menu-item-label, a") ?? it).replace(/\s{2,}.*$/, "");
      if (!label) continue;
      cm.children.push(node("menu-item", it, {
        label, enabled: !it.classList.contains("disabled") && !it.classList.contains("vakata-context-disabled"),
        shortcut: text(it.querySelector(".vakata-contextmenu-shortcut")),
      }, [["label", label]]));
    }
    cm.props.count = cm.children.length;
    root.children.push(cm);
  }
  void W;
  return root;
}

// --- the binding ----------------------------------------------------------------

async function launchElectron(ctx: Ctx, launch: any): Promise<void> {
  const env: Record<string, string> = {};
  for (const [k, v] of Object.entries(process.env)) if (v !== undefined) env[k] = v;
  for (const k of ["CODETRACER_TRACE_ID", "CODETRACER_RECORDING_ID", "CODETRACER_CALLER_PID",
                   "CODETRACER_PREFIX", "WAYLAND_DISPLAY", "XDG_SESSION_TYPE"]) delete env[k];
  Object.assign(env, launch.env);
  env.CODETRACER_IN_UI_TEST = "1";
  env.CODETRACER_TEST = "1";
  env.CT_HMR = "0";
  env.CODETRACER_NEW_TRACE_POLICY = "window";
  env.CODETRACER_ELECTRON_ARGS = ["--no-sandbox", "--no-zygote", "--disable-gpu",
    "--disable-gpu-compositing", "--disable-dev-shm-usage", "--in-process-gpu",
    "--ozone-platform-hint=x11"].join(" ");
  if (process.env.CT_LD_LIBRARY_PATH) {
    env.LD_LIBRARY_PATH = [process.env.CT_LD_LIBRARY_PATH, env.LD_LIBRARY_PATH ?? ""].filter((s) => s).join(":");
  }
  const args: string[] = [];
  if (launch.recording) {
    // the recording folder, imported the way `ct host --trace-path` imports one
    const r = spawnSync(ctBin, ["host", "--trace-path", launch.recording, "0", "--port=0",
      "--idle-timeout=1ms", "--backend-socket-port=0", "--frontend-socket=0"],
      { cwd: srcDir, env, encoding: "utf-8", timeout: 60_000 });
    const m = /imported as trace id\s+([0-9a-fA-F-]{36})/.exec(`${r.stdout}\n${r.stderr}`);
    if (!m) throw new Error(`ct host did not import ${launch.recording}: ${r.stderr || r.stdout}`);
    env.CODETRACER_RECORDING_ID = m[1];
  } else if (launch.project) {
    args.push("edit", launch.project);
    if (launch.file) args.push(path.join(launch.project, launch.file));
  }
  env.CODETRACER_CALLER_PID = String(process.pid);
  const width = launch.width || 1600;
  const height = launch.height || 1000;
  ctx.videoDir = path.join(ctx.state.root ?? process.env.TMPDIR ?? "/tmp", "video");
  fs.mkdirSync(ctx.videoDir, { recursive: true });
  const app = await _electron.launch({
    executablePath: ctBin, cwd: launch.workDir || srcDir, args, env,
    recordVideo: { dir: ctx.videoDir, size: { width, height } },
  });
  ctx.state.app = app;
  ctx.videoStartedAt = Date.now();
  await app.firstWindow({ timeout: 60_000 });
  let page: any;
  const deadline = Date.now() + 60_000;
  while (!page && Date.now() < deadline) {
    page = app.windows().find((w: any) => w.url() !== "about:blank" && !w.url().startsWith("devtools://"));
    if (!page) await new Promise((r) => setTimeout(r, 100));
  }
  if (!page) throw new Error("Electron opened no editor window");
  await page.waitForLoadState("domcontentloaded");
  // the window at the size the stage asked for
  await app.evaluate(({ BrowserWindow }: any, size: any) => {
    for (const w of BrowserWindow.getAllWindows()) w.setContentSize(size.width, size.height);
  }, { width, height });
  ctx.page = page;
  ctx.context = app.context();
}

function killTree(pid: number): void {
  // The application's process tree, children first.
  const r = spawnSync("pgrep", ["-P", String(pid)], { encoding: "utf-8" });
  for (const c of (r.stdout ?? "").split("\n").filter((x) => x.trim())) killTree(parseInt(c, 10));
  try { process.kill(pid, "SIGKILL"); } catch { /* already gone */ }
}

const binding = {
  name: "codetracer-desktop",
  roles: ROLES,
  unit: 1,

  async stage(ctx: Ctx, use: string, args: Record<string, unknown>): Promise<void> {
    const clean: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(args)) if (!k.startsWith("$")) clean[k] = v;
    if (!ctx.state.file) {
      ctx.state.file = path.join(process.env.TMPDIR ?? "/tmp", `ct-scenario-pw-${process.pid}-${Date.now()}.json`);
      const init = runStageCli(["init", ctx.state.file]);
      ctx.state.root = init.root;
    }
    const launch = runStageCli(["run", ctx.state.file, use, JSON.stringify(clean)]);
    if (use === "open-recording" || use === "open-project") await launchElectron(ctx, launch);
  },

  async surface(ctx: Ctx): Promise<Node> {
    return await ctx.page.evaluate(readSurface);
  },

  async condition(ctx: Ctx, name: string): Promise<boolean | undefined> {
    if (name === "replay-idle") {
      return await ctx.page.evaluate(() => {
        const d = (window as any).data;
        if (!d) return false;
        const s = d.status ?? d.sessions?.[d.activeSessionIndex ?? 0]?.status;
        const busy = !!(s && (s.stableBusy || s.busy));
        const loc = document.querySelector(".location-path")?.textContent ?? "";
        return !busy && loc.trim().length > 0;
      });
    }
    return undefined;
  },

  async resolveChord(ctx: Ctx, operation: string): Promise<string | null> {
    const chord: string = await ctx.page.evaluate(
      (op: string) => (window as any).__CODETRACER_TEST__?.chordForOperation?.(op) ?? "", operation);
    if (!chord) return null;
    // the router's display form (`Ctrl+K T M`) in the format's spelling: a bare
    // capital letter is the letter key
    return chord.split(" ").map((c) => c.replace(/(^|\+)([A-Z])$/, (_m, p, l) => p + l.toLowerCase())).join(" ");
  },

  async anchor(_ctx: Ctx, n: any, anchor: string): Promise<{ x: number; y: number } | undefined> {
    const a = n.anchors;
    if (!a) return undefined;
    if (anchor === "gutter") return a.gutter;
    if (anchor === "text-start") return { x: a.textLeft + (a.firstChar + 0.5) * a.charWidth, y: a.midY };
    if (anchor === "text-end") return { x: a.textRight - a.charWidth / 2, y: a.midY };
    const col = /^column\((\d+)\)$/.exec(anchor);
    if (col) return { x: a.textLeft + (parseInt(col[1], 10) - 0.5) * a.charWidth, y: a.midY };
    return undefined;
  },

  async close(ctx: Ctx): Promise<void> {
    const app = ctx.state.app;
    if (app) {
      ctx.state.app = undefined;
      const pid = app.process()?.pid;
      const within = (p: Promise<unknown>, ms: number) =>
        Promise.race([p.catch(() => {}), new Promise((r) => setTimeout(r, ms))]);
      // Closing the window's page completes its video; the application is
      // then ended with its children (its replay servers and agents keep an
      // orderly `app.close()` waiting).
      if (ctx.page) await within(ctx.page.close(), 15_000);
      await within(app.close(), 5_000);
      if (pid) killTree(pid);
    }
    // The run's state root (its recordings, homes and the video Playwright
    // wrote) is removed when the arm exits, after the runner has copied the
    // video into the run's recording.
    const file = ctx.state.file;
    if (file && !ctx.state.cleanupArmed) {
      ctx.state.cleanupArmed = true;
      process.on("exit", () => {
        try { spawnSync(stageCli(), ["remove", file]); } catch { /* best effort */ }
      });
    }
  },
};

export default binding;
