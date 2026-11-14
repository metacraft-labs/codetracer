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
import { spawn, spawnSync } from "node:child_process";
import * as crypto from "node:crypto";
import * as net from "node:net";
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
  window: { affordances: [], properties: ["title", "mode", "layout-tabs", "front-tabs", "strip-tabs", "pointer", "diff-tabs"] },
  "session-strip": { affordances: [], properties: ["count", "active"] },
  "session-tab": { affordances: ["click", "context-click"], properties: ["title", "active"] },
  "pane-tab": { affordances: ["click", "context-click", "drag-source"], properties: ["label", "active"] },
  toolbar: { affordances: [], properties: [] },
  "toolbar-button": { affordances: ["click"], properties: ["label", "enabled", "tooltip", "tooltip-chord", "tooltip-shown"] },
  editor: {
    affordances: ["click", "context-click", "wheel", "focusable", "text-entry"],
    properties: ["file", "active", "focused", "read-only", "current-line", "caret-line",
                 "first-visible", "last-visible", "text",
                 // pw2
                 "selections", "selected-text", "selection-count", "font-family", "font-size",
                 "find-shown", "find-query", "find-matches",
                 // pw4
                 "find-focused",
                 // pw8
                 "flow-values"],
  },
  line: {
    affordances: ["click", "double-click", "context-click"],
    properties: ["number", "text", "current", "caret", "breakpoint", "tracepoint",
                 "glyph", "dimmed", "inline-breakpoints", "diagnostic", "squiggle"],
  },
  "call-trace": { affordances: ["wheel", "focusable"], properties: ["count", "focused"] },
  call: { affordances: ["click", "double-click", "context-click"],
          properties: ["name", "current", "selected", "expanded", "arguments"] },
  "event-log": { affordances: ["click", "wheel", "focusable"], properties: ["count", "total", "focused", "last-shown", "columns", "search"] },
  event: { affordances: ["click", "double-click", "context-click"], properties: ["text", "kind", "current", "future"] },
  variables: { affordances: ["wheel", "focusable"], properties: ["count", "focused", "tab-strip"] },
  variable: { affordances: ["click", "double-click", "context-click"], properties: ["name", "type", "value", "origin-badge", "watch", "invalid", "text"] },
  "status-line": { affordances: [], properties: ["message", "location", "build-status", "notifications", "history"] },
  omnibox: { affordances: ["click", "text-entry", "focusable"], properties: ["query", "focused", "count", "labels"] },
  option: { affordances: ["click"], properties: ["label", "detail", "selected", "kind"] },
  "context-menu": { affordances: [], properties: ["count"] },
  "menu-item": { affordances: ["click"], properties: ["label", "enabled", "shortcut", "hint"] },
  "terminal-output": { affordances: ["click", "wheel", "focusable"], properties: ["text", "count", "focused"] },
  filesystem: { affordances: ["wheel", "focusable"], properties: ["count", "focused", "loading"] },
  // --- pw2 ---
  vcs: { affordances: [], properties: ["title", "commit", "stats", "count", "unified-diff", "error", "commits", "no-repo",
                                     "branch-picker", "review-extras"] },
  "changed-file": { affordances: ["click"], properties: ["name", "status", "status-kind", "stats", "coverage", "selected"] },
  "diff-toggle": { affordances: ["click"], properties: ["unified"] },
  "diff-view": { affordances: [], properties: ["file", "text", "hunks", "added", "removed", "selected-hunks", "toolbar",
                                               "line-numbers", "old-line-numbers", "token-colours"] },
  "columns-button": { affordances: ["click"], properties: ["label"] },
  "columns-menu": { affordances: ["click"], properties: [] },
  "column-option": { affordances: ["click", "drag-source", "drop-target"], properties: ["name", "shown"] },
  "file-node": { affordances: ["click", "double-click", "context-click"], properties: ["name", "kind", "expanded", "selected"] },
  // --- pw1 ---
  "strip-tab": { affordances: ["click", "context-click"], properties: ["label", "edge", "active"] },
  "auto-hide-overlay": { affordances: [], properties: ["title", "edge"] },
  "auto-hide-backdrop": { affordances: ["click"], properties: [] },
  "selection-outline": { affordances: [], properties: ["kind", "stroke", "stroke-width", "solid", "above-overlay",
                                                    "encloses", "measurable"] },
  sidebar: { affordances: [], properties: ["edge", "minimal", "toggle", "zone-visible", "mode-buttons"] },
  "docked-panel": { affordances: [], properties: ["edge"] },
  "panel-button": { affordances: ["click"], properties: ["label", "enabled", "active", "title"] },
  "build-panel": { affordances: ["wheel"], properties: ["verdict", "idle", "count", "text", "where", "state", "located"] },
  "build-line": { affordances: ["click"], properties: ["text", "stream", "severity", "located", "italic", "colour", "styled"] },
  "problems-panel": { affordances: [], properties: ["count", "errors", "warnings", "empty", "groups", "where"] },
  problem: { affordances: ["click"], properties: ["message", "path", "location", "severity"] },
  "find-in-files": { affordances: [], properties: ["count", "text", "where"] },
  "agent-activity": {
    affordances: [],
    properties: ["text", "conversation", "messages", "busy", "notice", "notices", "roll-up", "conversation-first",
                 "interaction-after", "failed-turns", "evidence-cards", "test-runs", "test-rows"],
  },
  "agent-prompt": { affordances: ["click", "text-entry", "focusable"], properties: ["value", "height", "lines", "focused", "visible-lines"] },
  "failed-turn": { affordances: [], properties: ["error", "icon"] },
  "test-run-card": { affordances: ["click"], properties: ["title", "status", "running", "expanded", "rows", "statuses"] },
  "agent-message": { affordances: [], properties: ["index", "text"] },
  "test-row": { affordances: ["click"], properties: ["name", "status", "outcome", "has-actions", "output", "diagnostic",
                                                     "recording-failed", "expanded", "recorded", "selected", "open-mode",
                                                     "open-title"] },
  "evidence-card": { affordances: [], properties: ["dataset", "path", "kind", "shape", "has-shape", "command", "note",
                                                   "output", "has-actions", "state"] },
  "agent-settings": { affordances: ["wheel"], properties: ["scroll-top", "overflow"] },
  "settings-select": { affordances: ["click"], properties: ["label", "value", "open"] },
  "settings-option": { affordances: ["click"], properties: ["label", "active"] },
  "settings-section": { affordances: ["click"], properties: ["title"] },
  "agent-workspace": { affordances: [], properties: ["label", "path", "files"] },
  "caption-progress": { affordances: ["click"], properties: ["text"] },
  "edit-toolbar": { affordances: [], properties: [] },
  "editor-hover": { affordances: [], properties: ["text"] },
  welcome: { affordances: [], properties: ["heading", "sections", "text"] },
  // --- pw4 ---
  "session-add": { affordances: ["click"], properties: [] },
  "menu-bar": { affordances: ["click"], properties: ["open"] },
  menu: { affordances: ["click"], properties: ["label", "open", "mnemonic", "highlighted"] },
  layout: { affordances: [], properties: ["stacks", "shape"] },
  "tracepoint-editor": { affordances: ["click", "text-entry", "focusable"],
                         properties: ["line", "text", "focused", "rows", "fits"] },
  "search-box": { affordances: ["click", "text-entry", "focusable"], properties: ["pane", "value", "focused"] },
  "search-result": { affordances: ["click"], properties: ["text"] },
  "shortcuts-dialog": { affordances: [], properties: ["scope"] },
  "shortcut-row": { affordances: [], properties: ["action", "chord"] },
  "binding-row": { affordances: [], properties: ["operation", "key", "layer", "shadowed-by", "text"] },
  dialog: { affordances: [], properties: ["title", "message"] },
  "dialog-button": { affordances: ["click"], properties: ["label", "enabled"] },
  "low-level-code": { affordances: ["click", "focusable"], properties: ["count", "sync", "stepping", "address", "focused", "pointer"] },
  instruction: { affordances: ["click", "context-click"],
                 properties: ["offset", "name", "source", "active", "executing", "focused"] },
  "source-line": { affordances: [], properties: ["number", "active"] },
  "h-scrubber": { affordances: ["click", "drag-source", "drop-target"],
                  properties: ["pane", "content", "viewport", "left", "thumb-px", "track-px", "overflows", "at-end", "centre", "left-columns",
                               "thumb-proportional", "clear-of-vertical"] },
  "table-pane": { affordances: ["click", "wheel"],
                  properties: ["pane", "fit", "sideways", "wider", "scroll-left", "header-follows"] },
  "table-cell": { affordances: ["click", "context-click", "drop-target"],
                  properties: ["cell", "column", "text", "full", "cut", "drawn-cut"] },
  "column-header": { affordances: ["click", "drag-source"], properties: ["column", "label", "cells"] },
  "table-tooltip": { affordances: [], properties: ["text", "widest"] },
  "row-detail": { affordances: [], properties: ["text", "count"] },
  "live-edit-panel": { affordances: [], properties: ["status", "detail"] },
  "text-field": { affordances: ["click", "text-entry", "focusable"], properties: ["label", "value", "focused"] },
  "welcome-action": { affordances: ["click"], properties: ["label"] },
  // --- pw8 ---
  "origin-chain": { affordances: [], properties: ["count", "hops", "terminator"] },
  "origin-hop": { affordances: ["click"], properties: ["number", "text", "file", "classification", "confidence", "low-confidence",
                                                     "low-confidence-text", "badge", "line", "frame-transition", "operands",
                                                     "operands-shown", "operand-values", "pointer"] },
  "origin-panel": { affordances: ["click", "focusable"], properties: ["count", "hops", "terminator", "crumbs", "focused", "empty"] },
  breadcrumb: { affordances: ["click"], properties: ["label", "current", "placeholder"] },
  scratchpad: { affordances: [], properties: ["count", "chains"] },
  "scratch-entry": { affordances: ["click", "context-click"], properties: ["expression", "value", "error", "kind"] },
  recent: { affordances: ["click", "double-click"], properties: ["name", "detail", "kind", "tooltip-shown", "tooltip"] },
  splitter: { affordances: ["click", "drag-source"], properties: ["orientation", "n"] },
  "verification-panel": { affordances: [], properties: ["phase", "outcome", "payload", "status", "command", "run", "stop", "groups", "count"] },
  finding: { affordances: ["click", "context-click"], properties: ["kind", "title", "message", "location"] },
  "process-tree": { affordances: [], properties: ["active", "roles"] },
  dialog: { affordances: [], properties: ["title", "message"] },
  "trace-results": { affordances: [], properties: ["line", "shown", "count"] },
  "trace-row": { affordances: ["click"], properties: ["n", "ticks", "values"] },
  "test-results": { affordances: [], properties: ["headline", "count", "failure", "absence"] },
  commit: { affordances: ["click"], properties: ["message", "expanded"] },
  "commit-file": { affordances: ["click"], properties: ["name"] },
  hunk: { affordances: ["click"], properties: ["number", "text"] },
  "expand-boundary": { affordances: ["click"], properties: ["n", "direction", "hidden"] },
  "diff-section": { affordances: ["click"], properties: ["path", "offset", "editors"] },
  process: { affordances: ["click"], properties: ["name", "title", "active"] },
  "event-marker": { affordances: ["click"], properties: ["boundary", "chip", "key-value", "direction"] },
  // --- pw3 ---
  "key-router": { affordances: [], properties: ["last-operation", "operations"] },
  dropdown: { affordances: [], properties: ["level", "name", "count"] },
  "dropdown-item": { affordances: ["click"], properties: ["label", "selected", "checked"] },
  scrubber: { affordances: ["drag-source", "drop-target"], properties: ["first", "visible-rows", "total"] },
  "video-player": { affordances: ["click", "focusable", "drag-source", "drop-target"],
                    properties: ["frame", "draw", "rate", "picking", "error", "starting", "transport-enabled",
                                 "last-frame", "focused"] },
  "frame-image": { affordances: ["click"], properties: ["geid", "frame", "quads", "width", "height"] },
  "pixel-history": { affordances: ["click"], properties: ["count", "pixel", "draws", "last-draw"] },
  "history-entry": { affordances: ["click"], properties: ["geid", "draw", "result", "selected", "title"] },
  "shader-debug": { affordances: [], properties: ["source", "current", "variables", "registers", "step"] },
  "flow-value": { affordances: ["click", "context-click"], properties: ["name", "side", "line", "value", "cut", "clipped", "single-line", "cap", "shown"] },
  "loop-control": { affordances: ["click"], properties: ["iteration", "total", "slider-width"] },
  popup: { affordances: ["click"], properties: ["text", "value", "type", "anchored"] },
};

// pw3: properties this batch reads on roles declared above.
ROLES["event-log"].properties.push("first-shown", "rows", "dimmed", "dimmed-tail", "first-in-view", "last-in-view");
ROLES.event.properties.push("selected");
ROLES.filesystem.properties.push("error");
ROLES["file-node"].properties.push("depth");
ROLES["columns-button"].properties.push("focused");
ROLES["column-option"].properties.push("outline");
ROLES.line.properties.push("flow", "flow-names");
ROLES["pane-tab"].properties.push("stack");

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
    // Edit mode shows the edit-mode toolbar (and no debug controls).
    mode: vis(document.querySelector(".edit-mode-toolbar")) ||
      (document.querySelector("[data-session-mode]")?.getAttribute("data-session-mode") ?? "debug")
        .toLowerCase().includes("edit") ? "edit" : "debug",
  });
  root.x = 0; root.y = 0; root.w = window.innerWidth; root.h = window.innerHeight; root.visible = true;

  // --- pw2 readers ---
  // A toolbar control's tooltip (`.custom-tooltip`): its text, and whether it
  // is being shown (computed style, as a user sees it: visible and opaque).
  function readToolbarTooltip(b: Element): Record<string, unknown> {
    const tip = b.querySelector(".custom-tooltip") as HTMLElement | null;
    if (!tip) return { tooltip: "", "tooltip-chord": "", "tooltip-shown": false };
    const cs = getComputedStyle(tip);
    const t = text(tip);
    return { tooltip: t, "tooltip-chord": /\(([^()]+)\)$/.exec(t)?.[1] ?? "",
             "tooltip-shown": cs.visibility === "visible" && Number(cs.opacity) > 0.5 };
  }
  // One palette result: its value, its suffix and its kind (`command-file`,
  // `command-command`, `command-symbol`, ...).
  function readPaletteOption(r: Element): any {
    const label = text(r.querySelector(".command-result-value") ?? r);
    const kind = (Array.from(r.classList).find((c) => /^command-(?!result|even|odd|selected)/.test(c)) ?? "")
      .replace(/^command-/, "");
    return node("option", r, {
      label, detail: text(r.querySelector(".command-result-suffix")), kind,
      selected: r.classList.contains("command-selected") || r.classList.contains("active"),
    }, [["label", label]]);
  }
  // A line's glyph-column marks (`gutter-glyph-breakpoint` → `breakpoint`,
  // `-disabled`, `-tracepoint`, `hint`), whether its text is dimmed as a
  // branch the run did not take (`line-flow-skip` / `line-flow-unknown`),
  // and the columns of its inline (column) breakpoint markers.
  function readLineExtras(ed: Element, l: Element | undefined, lb: DOMRect): Record<string, unknown> {
    const glyphs: string[] = [];
    for (const g of Array.from(ed.querySelectorAll(".glyph-margin-widgets .cgmr, .glyph-margin .cgmr")) as HTMLElement[]) {
      const gb = g.getBoundingClientRect();
      if (gb.height <= 0 || Math.abs(gb.top - lb.top) >= 3) continue;
      for (const c of Array.from(g.classList)) if (c.startsWith("gutter-glyph-")) glyphs.push(c.slice("gutter-glyph-".length));
    }
    const dimmed = !!l?.querySelector(".line-flow-skip, .line-flow-unknown");
    const span = l?.firstElementChild as HTMLElement | null;
    const t = (l?.textContent ?? "");
    const cw = span && t.length > 0 ? span.getBoundingClientRect().width / t.length : 0;
    const cols: string[] = [];
    for (const m of Array.from(ed.querySelectorAll(".ct-column-breakpoint-marker")) as HTMLElement[]) {
      const mb = m.getBoundingClientRect();
      if (mb.height <= 0 || mb.top < lb.top - 1 || mb.top >= lb.bottom - 1 || cw <= 0) continue;
      cols.push(String(Math.round((mb.left - lb.left) / cw) + 1));
    }
    return { glyph: glyphs.sort().join(" "), dimmed, "inline-breakpoints": cols };
  }
  // Where a user aims at a line's glyph cell and at its number.
  function lineAnchorExtras(ed: Element, g: Element, lb: DOMRect): Record<string, unknown> {
    const gm = ed.querySelector(".margin .glyph-margin") as HTMLElement | null;
    const gmb = gm?.getBoundingClientRect();
    // The line-number column as the editor lays it out (its DOM cell also
    // spans the folding column, where a press folds instead).
    const me = (window as any).monaco?.editor?.getEditors?.().find((e: any) => e.getDomNode?.() === ed);
    const li = me?.getLayoutInfo?.();
    const eb = ed.getBoundingClientRect();
    const nb = (g.querySelector(".gutter-line") ?? g).getBoundingClientRect();
    const numX = li ? eb.left + li.lineNumbersLeft + li.lineNumbersWidth / 2 : nb.left + nb.width / 2;
    return {
      glyph: gmb && gmb.width > 0 ? { x: gmb.left + gmb.width / 2, y: lb.top + lb.height / 2 } : undefined,
      lineNumber: { x: numX, y: lb.top + lb.height / 2 },
      // where the code area begins on screen: a text anchor scrolled off to
      // the left is aimed at the first visible character instead
      contentLeft: li ? eb.left + li.contentLeft : undefined,
    };
  }
  // The editor's selections (the selected text of each cursor; "" for a bare
  // caret), its code font, and its find widget.
  function readEditorExtras(ed: Element): Record<string, unknown> {
    const m = (window as any).monaco;
    const me = m?.editor?.getEditors?.().find((e: any) => e.getDomNode?.() === ed);
    const model = me?.getModel?.();
    const selections: string[] = me && model ? me.getSelections().map((x: any) => model.getValueInRange(x) as string) : [];
    const vl = ed.querySelector(".view-lines > .view-line") as HTMLElement | null;
    const cs = vl ? getComputedStyle(vl) : null;
    const fw = ed.querySelector(".find-widget") as HTMLElement | null;
    const findShown = !!fw && fw.classList.contains("visible") && vis(fw);
    const fi = fw?.querySelector("textarea, input") as HTMLInputElement | null;
    const ro = m?.editor?.EditorOption?.readOnly;
    return {
      // what the editor itself enforces (its `readOnly` option)
      ...(me && ro !== undefined ? { "read-only": !!me.getOption(ro) } : {}),
      selections,
      "selected-text": selections[0] ?? "",
      "selection-count": selections.length,
      "font-family": cs?.fontFamily ?? "",
      "font-size": cs ? Math.round(parseFloat(cs.fontSize)) : 0,
      "find-shown": findShown,
      "find-query": findShown ? (fi?.value ?? "") : "",
      "find-matches": findShown ? text(fw!.querySelector(".matchesCount")) : "",
      // pw4
      "find-focused": findShown && within(fw),
    };
  }
  // The event log's footer (`Rows <first> to <last> of <total>`), its visible
  // column titles, its Columns button and, while open, the Columns menu.
  function readEventLogExtras(comp: Element, el: any): void {
    const end = comp.querySelector(".data-tables-footer-end-row");
    const total = comp.querySelector(".data-tables-footer-rows-count");
    if (total) el.props.total = parseInt(text(total).replace(/,/g, ""), 10) || 0;
    el.props["last-shown"] = end ? parseInt(text(end).replace(/,/g, ""), 10) || 0 : 0;
    el.props.columns = (Array.from(comp.querySelectorAll(".eventLog-column-header > *")) as HTMLElement[])
      .filter((e) => e.offsetParent !== null).map((e) => text(e).replace(/\s*[▲▼]$/, ""));
    const body = comp.querySelector(".eventLog-scroll-body");
    if (body) {
      // rows are on screen only where the scroll body shows them
      const bb = body.getBoundingClientRect();
      for (const ev of el.children) {
        if (ev.y + ev.h <= bb.top + 1 || ev.y >= bb.bottom - 1) ev.visible = false;
      }
    }
    const btn = comp.querySelector(".eventLog-columns-button") as HTMLElement | null;
    if (btn && vis(btn)) el.children.push(node("columns-button", btn, { label: text(btn) }));
    const menu = comp.querySelector(".eventLog-columns-menu") as HTMLElement | null;
    if (menu && vis(menu)) {
      const cm = node("columns-menu", menu, {});
      for (const o of Array.from(menu.querySelectorAll(".eventLog-column-option")) as HTMLElement[]) {
        const name = o.getAttribute("data-column") ?? text(o.querySelector(".eventLog-column-title"));
        const check = o.querySelector(".eventLog-column-check") as HTMLElement | null;
        const handle = o.querySelector(".eventLog-column-handle") as HTMLElement | null;
        const centre = (e: HTMLElement | null) => {
          if (!e) return undefined;
          const r = e.getBoundingClientRect();
          return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
        };
        const opt = node("column-option", o, {
          name, shown: check?.getAttribute("aria-pressed") === "true",
        }, [["name", name], ["arguments", text(r.querySelector(".call-args"))]]);
        opt.anchors = { check: centre(check), handle: centre(handle) };
        cm.children.push(opt);
      }
      el.children.push(cm);
    }
  }
  // The files pane: its tree's nodes (jstree anchors), and whether it shows
  // its loading overlay instead of a tree.
  function readFilesystem(root: any): void {
    const comp = document.querySelector("div[id^='filesystemComponent']") as HTMLElement | null;
    if (!comp || !vis(comp)) return;
    const overlay = comp.querySelector(".filesystem-loading-overlay");
    const tree = comp.querySelector(".filesystem");
    const anchors = Array.from(comp.querySelectorAll("a.jstree-anchor")) as HTMLElement[];
    const fsNode = node("filesystem", comp, {
      count: anchors.length, focused: within(comp),
      loading: (!!overlay && !overlay.classList.contains("hidden") && vis(overlay)) ||
        tree?.getAttribute("aria-busy") === "true",
    });
    for (const a of anchors) {
      if (!vis(a)) continue;
      const li = a.closest("li");
      const name = text(a);
      fsNode.children.push(node("file-node", a, {
        name, kind: li?.classList.contains("jstree-leaf") ? "file" : "folder",
        expanded: li?.getAttribute("aria-expanded") === "true",
        selected: a.classList.contains("jstree-clicked"),
      }, [["name", name]]));
    }
    root.children.push(fsNode);
  }
  // The VCS panel of a review: the changeset header, its stats, the Unified
  // Diff / Open File toggle and the changed files; and the unified-diff
  // views the review opened.
  function readReview(root: any): void {
    const vc = document.querySelector(".vcs-container") as HTMLElement | null;
    if (vc && vis(vc)) {
      const items = Array.from(vc.querySelectorAll(".vcs-file-item")) as HTMLElement[];
      const toggle = vc.querySelector(".vcs-diff-toggle .vcs-toggle-button") as HTMLElement | null;
      const v = node("vcs", vc, {
        title: text(vc.querySelector(".vcs-branch-name")),
        commit: text(vc.querySelector(".vcs-changed-files-commit")),
        stats: text(vc.querySelector(".vcs-review-stats")),
        count: items.length,
        "unified-diff": !!toggle && toggle.classList.contains("vcs-toggle-active"),
        error: text(vc.querySelector(".vcs-error")),
      });
      for (const it of items) {
        const name = text(it.querySelector(".vcs-file-name"));
        const st = it.querySelector(".vcs-file-status");
        v.children.push(node("changed-file", it, {
          name, status: text(st),
          "status-kind": (Array.from(st?.classList ?? []).find((c) => /^vcs-status-/.test(c)) ?? "").replace(/^vcs-status-/, ""),
          stats: text(it.querySelector(".vcs-file-stats")),
          coverage: text(it.querySelector(".vcs-file-coverage")),
          selected: it.classList.contains("vcs-file-selected"),
        }, [["name", name]]));
      }
      if (toggle && vis(toggle)) v.children.push(node("diff-toggle", toggle, { unified: toggle.classList.contains("vcs-toggle-active") }));
      root.children.push(v);
    }
    for (const d of Array.from(document.querySelectorAll(".unified-diff-container")) as HTMLElement[]) {
      if (!vis(d)) continue;
      const file = text(d.querySelector(".unified-diff-file-header-path"));
      root.children.push(node("diff-view", d, {
        file, text: (Array.from(d.querySelectorAll(".view-line")) as HTMLElement[]).map((l) => (l.textContent ?? "").replace(/\u00a0/g, " ")),
      }, [["file", file]]));
    }
  }
  // A pane tab's close button, where a user aims to close it.
  function addPaneTabAnchors(root: any): void {
    const tabs = root.children.filter((c: any) => c.role === "pane-tab");
    for (const t of tabs) {
      const el = (Array.from(document.querySelectorAll(".lm_tab")) as HTMLElement[]).find((e) => {
        const r = e.getBoundingClientRect();
        return Math.abs(r.left - t.x) < 1 && Math.abs(r.top - t.y) < 1;
      });
      const c = el?.querySelector(".lm_close_tab") as HTMLElement | null;
      if (!c) continue;
      const r = c.getBoundingClientRect();
      if (r.width > 0) t.anchors = { ...(t.anchors ?? {}), close: { x: r.left + r.width / 2, y: r.top + r.height / 2 } };
    }
  }
  // --- end pw2 readers ---

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
      const btn = node("toolbar-button", b, {
        label, enabled: !(b as HTMLButtonElement).disabled && !b.classList.contains("disabled"),
      }, [["label", label]]);
      Object.assign(btn.props, readToolbarTooltip(b));
      toolbar.children.push(btn);
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
        Object.assign(lnode.props, readLineExtras(ed, r.l, lb));
        Object.assign(lnode.anchors, lineAnchorExtras(ed, r.g, lb));
        editorNode.children.push(lnode);
      }
      props.text = texts;
      if (rows.length > 0) {
        props["first-visible"] = rows[0].n;
        props["last-visible"] = rows[rows.length - 1].n;
      }
      props["read-only"] = ed.classList.contains("readonly") || !!ed.querySelector("textarea[readonly]");
      Object.assign(props, readEditorExtras(ed));
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
      // The current-call mark is drawn three ways on one row (the row's
      // `event-selected`, the `call-current` child box, the toggle icon's
      // `active`; `CallTraceEntry.isSelected` and codetracer#811): any of
      // them is the mark.
      const toggle = r.querySelector(".call-child-box .toggle-call") as HTMLElement | null;
      const callNode = node("call", r, {
        name, current: r.classList.contains("event-selected") ||
          !!r.querySelector(".call-child-box.call-current") || !!r.querySelector(".toggle-call .active"),
        selected: r.classList.contains("selected") || r.classList.contains("calltrace-selected")
          || r.classList.contains("event-selected"),
        expanded: !!r.querySelector(".toggle-call .collapse-call-img"),
        arguments: text(r.querySelector(".call-args")),
      }, [["name", name], ["arguments", text(r.querySelector(".call-args"))]]);
      const points: Record<string, { x: number; y: number }> = {};
      if (toggle && vis(toggle)) {
        const tb = toggle.getBoundingClientRect();
        points.expander = { x: tb.left + tb.width / 2, y: tb.top + tb.height / 2 };
      }
      // the call's name, where a click activates it
      const nameEl = r.querySelector(".call-text") as HTMLElement | null;
      if (nameEl && vis(nameEl)) {
        const nb = nameEl.getBoundingClientRect();
        points.name = { x: nb.left + Math.min(nb.width / 2, 40), y: nb.top + nb.height / 2 };
      }
      callNode.anchors = { points };
      ct.children.push(callNode);
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
    readEventLogExtras(elComp, el);
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

  // the command palette / omnibox: shown while its container is not `hidden`
  const pal = document.querySelector("#command-view") as HTMLElement | null;
  if (pal && vis(pal) && !pal.closest(".command-container.hidden")) {
    const q = document.querySelector("#command-query-text") as HTMLInputElement | null;
    const results = Array.from(pal.querySelectorAll(".command-result:not(.empty)")) as HTMLElement[];
    const om = node("omnibox", pal, { query: q?.value ?? text(q), focused: within(pal), count: results.length });
    for (const r of results) om.children.push(readPaletteOption(r));
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
        label, enabled: !it.classList.contains("disabled") && !it.classList.contains("vakata-context-disabled")
          && !it.classList.contains("ct-menu-item--disabled"),
        shortcut: text(it.querySelector(".vakata-contextmenu-shortcut")),
        // pw2: the row's second column (a hint, or why a disabled row is disabled)
        hint: text(it.querySelector(".ct-menu-item-sublabel")),
      }, [["label", label]]));
    }
    cm.props.count = cm.children.length;
    root.children.push(cm);
  }
  addPaneTabAnchors(root);
  readFilesystem(root);
  readReview(root);
  void W;
  return root;
}


// --- pw1: the auto-hide strips, the build / problems / find-in-files panes,
// the Agent Activity pane, the review's VCS panel ---------------------------
//
// Runs IN THE PAGE, in the same evaluation as `readSurface` (see
// `SURFACE_EXTENSIONS`), on the tree it returned. Reads only.
function readSurfacePw1(root: any): void {
  const vis = (el: Element | null): boolean => {
    if (!el) return false;
    const r = (el as HTMLElement).getBoundingClientRect();
    if (r.width <= 0 || r.height <= 0) return false;
    const cs = getComputedStyle(el as HTMLElement);
    return cs.visibility !== "hidden" && cs.display !== "none";
  };
  const text = (el: Element | null | undefined) => ((el?.textContent ?? "").replace(/\s+/g, " ").trim());
  const node = (role: string, el: Element | null, props: Record<string, unknown>,
                keys: Array<[string, string]> = []): any => {
    const r = el ? (el as HTMLElement).getBoundingClientRect() : { left: 0, top: 0, width: 0, height: 0 };
    return { role, keys, props, x: r.left, y: r.top, w: r.width, h: r.height,
             visible: el ? vis(el) : false, children: [] as any[] };
  };
  const centre = (el: Element) => {
    const r = (el as HTMLElement).getBoundingClientRect();
    return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
  };
  const active = document.activeElement;
  const within = (el: Element | null) => !!(el && active && (el === active || el.contains(active)));
  const has = (el: Element, cls: string) => el.classList.contains(cls);
  // A button of a panel, named by its text, else its title.
  const button = (b: HTMLElement, label?: string) => {
    const l = label ?? (text(b) || b.getAttribute("title") || b.getAttribute("aria-label") || "");
    return node("panel-button", b, {
      label: l, enabled: !has(b, "disabled") && !(b as HTMLButtonElement).disabled,
      active: has(b, "active"),
    }, [["label", l]]);
  };

  // auto-hide strip tabs: the bottom strip (in the footer) and both sides
  const edgeOf = (t: Element): string =>
    t.closest("#auto-hide-bottom-strip, .auto-hide-strip-bottom") ? "bottom"
      : t.closest("#auto-hide-strip-left, .auto-hide-strip-left") ? "left"
      : t.closest("#auto-hide-strip-right, .auto-hide-strip-right") ? "right" : "bottom";
  const stripTabs: string[] = [];
  for (const t of Array.from(document.querySelectorAll(".auto-hide-strip-tab")) as HTMLElement[]) {
    if (!vis(t)) continue;
    const label = text(t.querySelector(".auto-hide-strip-tab-label") ?? t);
    if (!label) continue;
    root.children.push(node("strip-tab", t, { label, edge: edgeOf(t), active: has(t, "active") },
                            [["label", label]]));
    stripTabs.push(`${edgeOf(t)}:${label}`);
  }
  root.props["strip-tabs"] = stripTabs;
  // the side strips' presentation: normal or minimal, the toggle in the
  // status bar's icon zone, and the minimal sidebar's panel icons
  for (const edge of ["left", "right"]) {
    const strip = document.querySelector(`#auto-hide-strip-${edge}`) as HTMLElement | null;
    const zone = document.querySelector(edge === "left" ? "#auto-hide-collapsed-icon-zone"
      : "#auto-hide-collapsed-icon-zone-right") as HTMLElement | null;
    if (!strip && !zone) continue;
    const restore = zone?.querySelector(".auto-hide-restore-button") as HTMLElement | null;
    const sb = node("sidebar", zone ?? strip, {
      edge, minimal: !!strip && has(strip, "collapsed-mode"),
      toggle: !restore ? "none" : has(restore, "sidebar-close") ? "close" : has(restore, "sidebar-open") ? "open" : "none",
      "zone-visible": vis(zone), "mode-buttons": strip ? strip.querySelectorAll(".auto-hide-mode-button").length : 0,
    }, [["edge", edge]]);
    // the zone's buttons, and the rows of its tab list (lifted to the top of
    // the page while open: `liftTabListMenu`, `ui/auto_hide.nim`)
    const lifted = document.querySelector(`body > .auto-hide-tablist-menu.align-${edge}`);
    for (const b of [...Array.from(zone?.querySelectorAll("button") ?? []),
                     ...Array.from(lifted?.querySelectorAll("button") ?? [])] as HTMLElement[]) {
      if (!vis(b)) continue;
      sb.children.push(button(b, b.getAttribute("aria-label") || b.getAttribute("title") || text(b)));
    }
    root.children.push(sb);
  }

  // the selection outline (`ui/layout.nim`): one stroked path around the
  // focused panel and its strip tab — docked, over the overlay, or a stack's
  const overlayEl = document.querySelector("#auto-hide-overlay") as HTMLElement | null;
  const overlayZ = overlayEl ? Number(getComputedStyle(overlayEl).zIndex) || 0 : 0;
  for (const [kind, cls] of [["docked", "ct-docked-outline"], ["overlay", "ct-overlay-outline"],
                             ["stack", "ct-selected-outline"]]) {
    for (const svg of Array.from(document.querySelectorAll(`.${cls}`)) as HTMLElement[]) {
      const p = svg.querySelector("path");
      if (!p) continue;
      const cs = getComputedStyle(p);
      const r = p.getBoundingClientRect();
      const tol = 2;
      const encloses = (Array.from(document.querySelectorAll(".auto-hide-strip-tab")) as HTMLElement[])
        .filter((t) => {
          const b = t.getBoundingClientRect();
          return vis(t) && r.left <= b.left + tol && r.right >= b.right - tol && r.top <= b.top + tol && r.bottom >= b.bottom - tol;
        }).map((t) => text(t.querySelector(".auto-hide-strip-tab-label") ?? t));
      root.children.push(node("selection-outline", p, {
        kind, stroke: cs.stroke, "stroke-width": parseFloat(cs.strokeWidth) || 0,
        solid: cs.strokeDasharray === "none" || cs.strokeDasharray === "",
        "above-overlay": (Number(getComputedStyle(svg).zIndex) || 0) > overlayZ,
        encloses, measurable: r.width > 1 && r.height > 1,
      }, [["kind", kind]]));
    }
  }

  // the backdrop behind the overlay (a click on it dismisses the overlay)
  const backdrop = document.querySelector("#auto-hide-backdrop") as HTMLElement | null;
  if (backdrop && vis(backdrop)) root.children.push(node("auto-hide-backdrop", backdrop, {}));
  // the slide-in overlay (a strip tab's hover preview)
  const overlay = document.querySelector("#auto-hide-overlay") as HTMLElement | null;
  if (overlay && has(overlay, "visible")) {
    const edge = has(overlay, "auto-hide-overlay-left") ? "left" : has(overlay, "auto-hide-overlay-right") ? "right" : "bottom";
    root.children.push(node("auto-hide-overlay", overlay, {
      title: text(document.querySelector("#auto-hide-overlay-title")), edge,
    }));
  }
  // panels docked open from their strip tab
  for (const edge of ["left", "right", "bottom"]) {
    const c = document.querySelector(`#auto-hide-docked-${edge}`) as HTMLElement | null;
    if (!c || !has(c, "docked-open")) continue;
    root.children.push(node("docked-panel", c, { edge }, [["edge", edge]]));
  }
  const whereOf = (el: Element): string =>
    el.closest("#auto-hide-overlay-content") ? "overlay"
      : el.closest("[id^='auto-hide-docked-']") ? "docked" : "layout";

  // the BUILD pane (`isonim_build_view.nim`): the one on screen
  const bp = (Array.from(document.querySelectorAll(".build-panel")) as HTMLElement[]).find((e) => vis(e));
  if (bp) {
    const out = bp.querySelector("#build, .build-output-container");
    const lines = out ? (Array.from(out.children) as HTMLElement[]) : [];
    const texts: string[] = [];
    const build = node("build-panel", bp, {
      verdict: text(bp.querySelector(".build-command-label")),
      idle: vis(bp.querySelector(".build-empty")),
      count: lines.length, text: texts, where: whereOf(bp),
      located: lines.filter((l) => has(l, "build-clickable")).length,
      state: has(bp.querySelector(".build-header") ?? bp, "build-failed") ? "failed"
        : has(bp.querySelector(".build-header") ?? bp, "build-succeeded") ? "succeeded"
        : has(bp.querySelector(".build-header") ?? bp, "build-cancelled") ? "cancelled" : "none",
    });
    for (const l of lines) {
      const t = (l.textContent ?? "").replace(/\u00a0/g, " ").replace(/\s+$/, "");
      texts.push(t);
      const cs = getComputedStyle(l);
      const sev = has(l, "build-line-error") ? "error" : has(l, "build-line-warning") ? "warning"
        : has(l, "build-line-info") ? "info" : "none";
      build.children.push(node("build-line", l, {
        text: t, stream: has(l, "build-stderr") ? "stderr" : has(l, "build-stdout") ? "stdout" : "located",
        severity: sev, located: has(l, "build-clickable"),
        italic: cs.fontStyle === "italic", colour: cs.color,
        // the line's text as drawn carries no raw escape sequence
        styled: l.querySelector("span") !== null,
      }, [["text", t]]));
    }
    // the header's controls, by what they are (`BuildControlTitles`, their
    // titles; a tooltip can take a title off while the pointer rests on it)
    for (const [cls, label] of [["build-run-btn", "Run build (no re-record)"], ["build-stop-btn", "Stop build"],
                                ["build-clear-btn", "Clear build output"], ["build-scroll-btn", "Toggle auto-scroll"]]) {
      for (const b of Array.from(bp.querySelectorAll(`.build-header-controls .${cls}`)) as HTMLElement[]) {
        build.children.push(button(b, label));
      }
    }
    root.children.push(build);
  }

  // the PROBLEMS pane (`isonim_errors_view.nim`)
  const pp = (Array.from(document.querySelectorAll(".problems-panel")) as HTMLElement[]).find((e) => vis(e));
  if (pp) {
    const rows = Array.from(pp.querySelectorAll(".problems-row")) as HTMLElement[];
    const pr = node("problems-panel", pp, {
      count: rows.length,
      errors: rows.filter((r) => has(r, "problems-severity-error")).length,
      warnings: rows.filter((r) => has(r, "problems-severity-warning")).length,
      empty: vis(pp.querySelector(".problems-empty")),
      groups: pp.querySelectorAll(".problems-file-header").length,
      where: whereOf(pp),
    });
    for (const r of rows) {
      const message = text(r.querySelector(".problems-message"));
      pr.children.push(node("problem", r, {
        message, path: text(r.querySelector(".problems-path")),
        location: text(r.querySelector(".problems-location")),
        severity: has(r, "problems-severity-error") ? "error" : has(r, "problems-severity-warning") ? "warning" : "info",
      }, [["message", message]]));
    }
    for (const b of Array.from(pp.querySelectorAll(".problems-filter-btn")) as HTMLElement[]) pr.children.push(button(b));
    root.children.push(pr);
  }

  // Find in Files (`isonim_search_results_view.nim`)
  const ff = (Array.from(document.querySelectorAll(".fif-panel")) as HTMLElement[]).find((e) => vis(e));
  if (ff) {
    const rows = Array.from(ff.querySelectorAll(".fif-match-row")) as HTMLElement[];
    root.children.push(node("find-in-files", ff, {
      count: rows.length, text: text(ff.querySelector(".fif-body")), where: whereOf(ff),
    }));
  }

  // the Agent Activity pane (`isonim_agent_activity_view.nim`)
  const aa = (Array.from(document.querySelectorAll(".agent-ha-container")) as HTMLElement[]).find((e) => vis(e));
  if (aa) {
    const com = aa.querySelector(".agent-com") as HTMLElement | null;
    const kids = Array.from(aa.children) as HTMLElement[];
    const rollup = aa.ownerDocument.querySelectorAll([".agent-ha-deepreview-host", ".activity-dr-container",
      ".activity-dr-header", ".activity-dr-summary", ".activity-dr-card", ".activity-dr-files",
      ".activity-dr-files-row", ".activity-dr-tests", ".activity-dr-test-item", ".activity-dr-notifs",
      ".activity-dr-notif-item"].join(", ")).length;
    const failed = Array.from(aa.querySelectorAll(".agent-turn-failed")) as HTMLElement[];
    const pane = node("agent-activity", aa, {
      text: aa.innerText ?? "",
      conversation: com ? (com.innerText ?? "") : "",
      messages: (Array.from(aa.querySelectorAll(".msg-content")) as HTMLElement[]).map((m) => text(m)),
      busy: !!aa.querySelector(".ai-status, .agent-working-indicator"),
      notice: text(aa.querySelector(".agent-session-notice")),
      notices: aa.querySelectorAll(".agent-session-notice").length,
      "roll-up": rollup,
      "conversation-first": kids.length > 0 && kids[0].classList.contains("agent-com"),
      "interaction-after": (() => {
        const c = kids.findIndex((k) => k.classList.contains("agent-com"));
        const i = kids.findIndex((k) => k.classList.contains("agent-interaction"));
        return c >= 0 && i > c;
      })(),
      "failed-turns": failed.length,
      "evidence-cards": aa.querySelectorAll(".agent-evidence").length,
      "test-runs": aa.querySelectorAll(".agent-test-run").length,
      "test-rows": aa.querySelectorAll(".agent-test-row").length,
    });
    const prompt = aa.querySelector(".agent-command-input") as HTMLTextAreaElement | null;
    if (prompt && vis(prompt)) {
      const value = prompt.value ?? "";
      // how many text lines the box shows (its content height over the line
      // height): the box grows with its text and shrinks back when emptied
      const cs = getComputedStyle(prompt);
      const lh = parseFloat(cs.lineHeight) || parseFloat(cs.fontSize) * 1.2;
      const inner = prompt.getBoundingClientRect().height - parseFloat(cs.paddingTop) - parseFloat(cs.paddingBottom)
        - parseFloat(cs.borderTopWidth) - parseFloat(cs.borderBottomWidth);
      pane.children.push(node("agent-prompt", prompt, {
        value, height: Math.round(prompt.getBoundingClientRect().height),
        lines: value.split("\n").length, focused: prompt === active,
        "visible-lines": Math.max(1, Math.round(inner / lh)),
      }));
    }
    // named by what they are (their `title` is the same words, but a tooltip
    // can take it off the element while the pointer rests on it)
    for (const [cls, label] of [["agent-start-button", "Send"], ["agent-stop-button", "Stop"],
                                ["agent-settings-button", "Agent settings"]]) {
      for (const b of Array.from(aa.querySelectorAll(`.${cls}`)) as HTMLElement[]) {
        if (vis(b)) pane.children.push(button(b, label));
      }
    }
    // each message, by its place in the conversation (1-based)
    (Array.from(aa.querySelectorAll(".msg-content")) as HTMLElement[]).forEach((m, i) => {
      pane.children.push(node("agent-message", m, { index: i + 1, text: text(m) }, [["index", String(i + 1)]]));
    });
    for (const f of failed) {
      pane.children.push(node("failed-turn", f, {
        error: text(f.querySelector(".agent-turn-error")), icon: vis(f.querySelector(".agent-turn-failed-icon")),
      }));
    }
    // a `ct test` run's card, and its rows
    for (const c of Array.from(aa.querySelectorAll(".agent-test-run")) as HTMLElement[]) {
      const header = c.querySelector(".agent-test-run-header");
      const title = text(c.querySelector(".agent-test-run-title"));
      const card = node("test-run-card", c, {
        title, status: text(c.querySelector(".agent-test-run-status")),
        running: has(c, "agent-test-run-running"), expanded: c.querySelectorAll(".agent-test-row").length > 0,
        rows: (Array.from(c.querySelectorAll(".agent-test-row .agent-test-row-name")) as HTMLElement[]).map((n) => text(n)),
        statuses: (Array.from(c.querySelectorAll(".agent-test-row .agent-test-row-status")) as HTMLElement[]).map((n) => text(n)),
      }, [["title", title]]);
      if (header) card.anchors = { points: { header: centre(header) } };
      for (const r of Array.from(c.querySelectorAll(".agent-test-row")) as HTMLElement[]) {
        const name = text(r.querySelector(".agent-test-row-name"));
        const rh = r.querySelector(".agent-test-row-header");
        const row = node("test-row", r, {
          name, status: text(r.querySelector(".agent-test-row-status")),
          outcome: has(r, "agent-test-row-passed") ? "passed" : has(r, "agent-test-row-failed") ? "failed"
            : has(r, "agent-test-row-errored") ? "errored" : has(r, "agent-test-row-running") ? "running" : "",
          "has-actions": !!r.querySelector(".agent-test-row-actions"),
          output: text(r.querySelector(".agent-test-row-output")),
          diagnostic: text(r.querySelector(".agent-test-row-diagnostic")),
          "recording-failed": !!r.querySelector(".agent-test-row-recording-failed"),
          expanded: !!r.querySelector(".agent-test-row-details"),
        }, [["name", name], ["arguments", text(r.querySelector(".call-args"))]]);
        if (rh) row.anchors = { points: { header: centre(rh) } };
        for (const b of Array.from(r.querySelectorAll(".agent-test-row-actions button")) as HTMLElement[]) row.children.push(button(b));
        card.children.push(row);
      }
      pane.children.push(card);
    }
    // an evidence tool call's card, keyed by its dataset's file name
    for (const c of Array.from(aa.querySelectorAll(".agent-evidence")) as HTMLElement[]) {
      const dataset = text(c.querySelector(".agent-evidence-dataset"));
      const name = dataset.split("/").pop() ?? dataset;
      const card = node("evidence-card", c, {
        dataset: name, path: dataset,
        kind: text(c.querySelector(".agent-evidence-kind")),
        shape: text(c.querySelector(".agent-evidence-shape")),
        "has-shape": !!c.querySelector(".agent-evidence-shape"),
        command: text(c.querySelector(".agent-evidence-command")),
        note: text(c.querySelector(".agent-evidence-note")),
        output: text(c.querySelector(".agent-evidence-output")),
        "has-actions": !!c.querySelector(".agent-evidence-actions"),
        state: has(c, "agent-evidence-unavailable") ? "unavailable" : has(c, "agent-evidence-failed") ? "failed"
          : has(c, "agent-evidence-unreported") ? "unreported" : "available",
      }, [["dataset", name]]);
      for (const b of Array.from(c.querySelectorAll(".agent-evidence-actions button")) as HTMLElement[]) card.children.push(button(b));
      pane.children.push(card);
    }
    // the settings panel: each select is named by the label it sits under
    const sp = aa.querySelector(".agent-settings-panel") as HTMLElement | null;
    if (sp && vis(sp)) {
      const st = node("agent-settings", sp, {
        "scroll-top": Math.round(sp.scrollTop), overflow: sp.scrollHeight - sp.clientHeight,
      });
      for (const host of Array.from(sp.querySelectorAll(".agent-settings-section, .agent-settings-half-col")) as HTMLElement[]) {
        const labels = (Array.from(host.children) as HTMLElement[]).filter((c) => has(c, "agent-settings-label"));
        const selects = (Array.from(host.children) as HTMLElement[]).filter((c) => has(c, "agent-settings-select-wrapper"));
        selects.forEach((w, i) => {
          const label = text(labels[i]);
          const list = w.querySelector(".agent-settings-dropdown-list");
          const sel = node("settings-select", w.querySelector(".agent-settings-select-trigger") ?? w, {
            label, value: text(w.querySelector(".agent-settings-select-text")), open: !!list && vis(list),
          }, [["label", label]]);
          for (const it of Array.from(w.querySelectorAll(".agent-settings-dropdown-item")) as HTMLElement[]) {
            const l = text(it);
            sel.children.push(node("settings-option", it, { label: l, active: has(it, "agent-settings-dropdown-item--active") }, [["label", l]]));
          }
          st.children.push(sel);
        });
        const h = (Array.from(host.children) as HTMLElement[]).find((c) => has(c, "agent-settings-section-header"));
        if (h) { const t = text(h); st.children.push(node("settings-section", h, { title: t }, [["title", t]])); }
      }
      const done = sp.querySelector(".agent-settings-done") as HTMLElement | null;
      if (done) st.children.push(button(done));
      pane.children.push(st);
    }
    root.children.push(pane);
  }

  // an agent's worktree session: the Agent Workspace panel and the caption
  // bar's progress
  const aw = (Array.from(document.querySelectorAll(".agent-workspace-container")) as HTMLElement[]).find((e) => vis(e));
  if (aw) {
    const w = node("agent-workspace", aw, {
      label: text(aw.querySelector(".agent-workspace-header-label")),
      path: text(aw.querySelector(".agent-workspace-header-path")),
      files: (Array.from(aw.querySelectorAll(".agent-workspace-file-item .agent-workspace-file-name")) as HTMLElement[])
        .map((f) => text(f)),
    });
    const toggle = aw.querySelector(".agent-workspace-view-toggle") as HTMLElement | null;
    if (toggle && vis(toggle)) w.children.push(button(toggle));
    root.children.push(w);
  }
  const cp = document.querySelector(".caption-progress-container") as HTMLElement | null;
  if (cp && vis(cp)) {
    root.children.push(node("caption-progress", cp, { text: text(cp) }));
  }

  // every GoldenLayout tab, shown or not, and the ones in front of their stack
  root.props["layout-tabs"] = (Array.from(document.querySelectorAll(".lm_tab .lm_title")) as HTMLElement[])
    .map((t) => text(t));
  root.props["front-tabs"] = (Array.from(document.querySelectorAll(".lm_tab.lm_active .lm_title")) as HTMLElement[])
    .map((t) => text(t));

  // the status bar's build verdict and its notifications
  const sl = root.children.find((c: any) => c.role === "status-line");
  if (sl) {
    sl.props["build-status"] = text(document.querySelector("#status .build-status-text"));
    sl.props.notifications = (Array.from(document.querySelectorAll(
      "#active-notifications .status-notification .notification-message")) as HTMLElement[]).map((n) => text(n));
    // pw8: View > Notifications, when open: every notice this bar was given
    sl.props.history = (Array.from(document.querySelectorAll(
      "#notifications-container .notification-message")) as HTMLElement[]).map((n) => text(n));
  }

  // the edit-mode toolbar's Build and Run
  const eb = document.querySelector("#build-image") as HTMLElement | null;
  const er = document.querySelector("#run-image") as HTMLElement | null;
  if ((eb && vis(eb)) || (er && vis(er))) {
    const tb = node("edit-toolbar", (eb ?? er)!.parentElement, {});
    for (const [b, l] of [[eb, "Build"], [er, "Run"]] as Array<[HTMLElement | null, string]>) {
      if (b && vis(b)) {
        const n = button(b, l);
        n.props.title = b.getAttribute("title") ?? "";
        tb.children.push(n);
      }
    }
    root.children.push(tb);
  }

  // a build's diagnostics on the editors' lines: the gutter's glyph
  // (`build-diagnostic-margin-<severity>`, `ui/build.nim`) and the squiggle
  // drawn on the line, matched to a line by where they are drawn
  for (const ed of root.children.filter((c: any) => c.role === "editor")) {
    const tops = (sel: string) => (Array.from(document.querySelectorAll(sel)) as HTMLElement[])
      .filter((e) => vis(e)).map((e) => {
        const r = e.getBoundingClientRect();
        const cls = Array.from(e.classList).find((c) => /-(error|warning|info)$/.test(c)) ?? "";
        return { top: r.top, bottom: r.bottom, x: r.left, sev: (/-(error|warning|info)$/.exec(cls) ?? ["", "none"])[1] };
      });
    const glyphs = tops(".build-diagnostic-margin");
    const squiggles = tops(".squiggly-error, .squiggly-warning, .squiggly-info");
    for (const ln of ed.children) {
      const mid = ln.y + ln.h / 2;
      const inRow = (g: any) => g.x >= ed.x && g.x <= ed.x + ed.w && mid >= g.top - 1 && mid <= g.bottom + 1;
      ln.props.diagnostic = glyphs.find(inRow)?.sev ?? "none";
      const sq = squiggles.filter((g: any) => g.x >= ed.x && g.x <= ed.x + ed.w &&
        (g.top + g.bottom) / 2 >= ln.y && (g.top + g.bottom) / 2 < ln.y + ln.h);
      ln.props.squiggle = sq.some((g: any) => g.sev === "error") ? "error" : sq[0]?.sev ?? "none";
    }
  }
  // the editor's hover (the message under the pointer)
  const hover = (Array.from(document.querySelectorAll(".monaco-hover")) as HTMLElement[])
    .find((h) => vis(h) && !has(h, "hidden"));
  if (hover) root.children.push(node("editor-hover", hover, { text: text(hover) }));

  // the command palette's rows: the label is the row's value, the detail its
  // suffix, the chosen row `command-selected` (`isonim_command_palette_view.nim`)
  const om = root.children.find((c: any) => c.role === "omnibox");
  if (om) {
    const rows = (Array.from(document.querySelectorAll("#command-view .command-result")) as HTMLElement[])
      .filter((r) => !has(r, "empty"));
    if (rows.length === om.children.length) {
      rows.forEach((r, i) => {
        const label = text(r.querySelector(".command-result-value")) || om.children[i].props.label;
        om.children[i].props.label = label;
        om.children[i].props.detail = text(r.querySelector(".command-result-suffix"));
        om.children[i].props.selected = has(r, "command-selected");
        om.children[i].keys = [["label", label]];
      });
    }
    om.props.labels = om.children.map((o: any) => o.props.label);
  }

  // the welcome screen, when no other reader drew it
  const ws = document.querySelector(".welcome-screen") as HTMLElement | null;
  if (ws && vis(ws) && !root.children.some((c: any) => c.role === "welcome")) {
    const w = node("welcome", ws, { heading: text(ws.querySelector("h1, .welcome-title")) });
    for (const o of Array.from(ws.querySelectorAll(".start-option")) as HTMLElement[]) {
      if (!vis(o)) continue;
      const label = text(o.querySelector(".start-option-name, .option-name") ?? o);
      w.children.push(node("welcome-action", o, { label }, [["label", label]]));
    }
    root.children.push(w);
  }
}


// --- pw8: value origin, the scratchpad, the welcome screen's lists, the
// program menu, the editor's flow values and the pointer's shape -----------
//
// Runs IN THE PAGE, in the same evaluation as `readSurface`, on the tree it
// returned. Reads only.
function readSurfacePw8(root: any): void {
  const vis = (el: Element | null): boolean => {
    if (!el) return false;
    const r = (el as HTMLElement).getBoundingClientRect();
    if (r.width <= 0 || r.height <= 0) return false;
    const cs = getComputedStyle(el as HTMLElement);
    return cs.visibility !== "hidden" && cs.display !== "none";
  };
  const text = (el: Element | null | undefined) => ((el?.textContent ?? "").replace(/\s+/g, " ").trim());
  const node = (role: string, el: Element | null, props: Record<string, unknown>,
                keys: Array<[string, string]> = []): any => {
    const r = el ? (el as HTMLElement).getBoundingClientRect() : { left: 0, top: 0, width: 0, height: 0 };
    return { role, keys, props, x: r.left, y: r.top, w: r.width, h: r.height,
             visible: el ? vis(el) : false, children: [] as any[] };
  };
  const centre = (el: Element) => {
    const r = (el as HTMLElement).getBoundingClientRect();
    return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
  };
  const active = document.activeElement;
  const within = (el: Element | null) => !!(el && active && (el === active || el.contains(active)));
  // Shown where a user can aim at it: drawn, its centre inside the window,
  // and the element there is it (a row scrolled out of its pane is in the
  // DOM, drawn, and out of reach).
  const shown = (el: Element | null): boolean => {
    if (!vis(el)) return false;
    const r = (el as HTMLElement).getBoundingClientRect();
    const cx = r.left + r.width / 2, cy = r.top + r.height / 2;
    if (cx < 0 || cy < 0 || cx > window.innerWidth || cy > window.innerHeight) return false;
    // what a press there would land on
    const hit = document.elementFromPoint(cx, cy);
    return !!hit && (hit === el || el!.contains(hit) || hit.contains(el));
  };
  const button = (b: HTMLElement, label?: string) => {
    const l = label ?? (text(b) || b.getAttribute("title") || b.getAttribute("aria-label") || "");
    return node("panel-button", b, {
      label: l, enabled: !b.classList.contains("disabled") && !(b as HTMLButtonElement).disabled,
      active: b.classList.contains("active"), title: b.getAttribute("title") ?? "",
    }, [["label", l]]);
  };
  // The kind a hop's label names (`hop 1: cross-thread copy at step 4`), in
  // the pack's spelling (the VS Code panel's `TrivialCopy`, …).
  const KINDS: Record<string, string> = {
    "trivial copy": "TrivialCopy", "field access": "FieldAccess", "index access": "IndexAccess",
    "computational expression": "Computational", "function call": "FunctionCall", literal: "Literal",
    "return capture": "ReturnCapture", "parameter pass": "ParameterPass",
    "cross-thread copy": "CrossThreadCopy", unknown: "Unknown",
  };

  // the State pane's rows: the origin badge, the value cell (where a press
  // focuses the row), and the chain expanded under the row
  const vs = root.children.find((c: any) => c.role === "variables");
  if (vs) {
    const rows = Array.from(document.querySelectorAll("div[id^='stateComponent'] [data-variable-name]")) as HTMLElement[];
    for (const v of vs.children) {
      const row = rows.find((r) => r.getAttribute("data-variable-name") === v.props.name && vis(r));
      if (!row) continue;
      const badge = row.querySelector("button.ct-origin-badge") as HTMLElement | null;
      v.props["origin-badge"] = !!badge && vis(badge);
      const cell = row.querySelector("[data-ct-cell$='|value']") as HTMLElement | null;
      v.anchors = { points: { ...(v.anchors?.points ?? {}),
                              ...(cell && vis(cell) ? { value: centre(cell) } : {}),
                              ...(row.querySelector(".value-name") ? { name: centre(row.querySelector(".value-name")!) } : {}) } };
      v.props.watch = row.classList.contains("value-watch");
      v.keys = [...(v.keys ?? []), ["watch", String(v.props.watch)]];
      v.props.invalid = row.classList.contains("watch-invalid");
      v.props.text = text(row);
      const chain = row.querySelector(".ct-origin-inline-chain") as HTMLElement | null;
      if (chain && vis(chain)) {
        const hops = (Array.from(chain.querySelectorAll(".ct-origin-inline-chain-hop")) as HTMLElement[]).filter((h) => vis(h));
        const oc = node("origin-chain", chain, {
          count: hops.length, hops: hops.map((h) => text(h)),
          terminator: text(chain.querySelector(".ct-origin-inline-chain-terminator")),
        });
        hops.forEach((h, i) => {
          const hn = node("origin-hop", h, {
            number: i + 1, text: text(h), file: "", pointer: getComputedStyle(h).cursor,
          }, [["number", String(i + 1)], ["file", ""]]);
          hn.visible = shown(h);
          oc.children.push(hn);
        });
        const side = chain.querySelector("button.ct-origin-show-in-side-panel") as HTMLElement | null;
        if (side && vis(side)) {
          const sb = button(side);
          sb.visible = shown(side);
          oc.children.push(sb);
        }
        v.children.push(oc);
      }
    }
  }

  // how many diff tabs the layout holds ("Diff: main.nim (77220c)", …)
  root.props["diff-tabs"] = (Array.from(document.querySelectorAll(".lm_tab .lm_title")) as HTMLElement[])
    .filter((t) => /^Diff:/.test(text(t))).length;

  // the status line's box is the status bar as drawn (`#status`), when the
  // element the shared reader found is laid out with no height
  const sl = root.children.find((c: any) => c.role === "status-line");
  // (or, failing that, the footer row that holds the bottom strip)
  let statusBar = document.querySelector("#status") as HTMLElement | null;
  if (!statusBar || statusBar.getBoundingClientRect().height <= 0) {
    statusBar = null;
    for (let a = document.querySelector("#auto-hide-bottom-strip")?.parentElement ?? null; a; a = a.parentElement) {
      const r = a.getBoundingClientRect();
      if (r.height > 0 && r.width >= window.innerWidth / 2) { statusBar = a; break; }
    }
  }
  if (sl && sl.h <= 0 && statusBar && vis(statusBar)) {
    const r = statusBar.getBoundingClientRect();
    Object.assign(sl, { x: r.left, y: r.top, w: r.width, h: r.height, visible: true });
  }

  // the State pane's watch input, and whether the pane draws a tab strip
  const stc = document.querySelector("div[id^='stateComponent']") as HTMLElement | null;
  if (vs && stc) {
    vs.props["tab-strip"] = !!stc.querySelector(".state-tabs");
    const wi = stc.querySelector("input[id^='watch-'], textarea[id^='watch-']") as HTMLInputElement | null;
    if (wi && vis(wi)) {
      vs.children.push(node("text-field", wi, { label: "watch", value: wi.value ?? "", focused: within(wi) },
                            [["label", "watch"]]));
    }
  }

  // the side panel (`ui/isonim_origin_chain.renderPanelDom`)
  const panel = document.querySelector("aside#ct-origin-chain-side-panel") as HTMLElement | null;
  if (panel && vis(panel)) {
    const hops = Array.from(panel.querySelectorAll("section > ol > li.ct-origin-hop")) as HTMLElement[];
    const crumbs = Array.from(panel.querySelectorAll("nav > button")) as HTMLElement[];
    const op = node("origin-panel", panel, {
      count: hops.length,
      hops: hops.map((h) => text(h.querySelector("button"))),
      terminator: text(panel.querySelector(".ct-origin-terminator-row")),
      crumbs: crumbs.map((c) => text(c)),
      focused: within(panel),
      empty: !!panel.querySelector(".ct-origin-side-empty"),
    });
    hops.forEach((h, i) => {
      const label = (h.getAttribute("aria-label") ?? "").replace(/^hop \d+:\s*/, "").replace(/\s+at step.*$/, "");
      const conf = /confidence\s+([\d.]+)/.exec(text(h.querySelector(".ct-origin-hop-confidence")));
      const details = h.querySelector("details") as HTMLDetailsElement | null;
      const hb = h.querySelector("button") as HTMLElement | null;
      const hopFile = text(hb).replace(/:\d+$/, "").split("/").pop() ?? "";
      const hn = node("origin-hop", h, {
        number: i + 1, text: text(hb), file: hopFile, classification: KINDS[label] ?? label,
        confidence: conf ? parseFloat(conf[1]) : 0,
        "low-confidence": !!h.querySelector(".ct-origin-low-confidence"),
        "low-confidence-text": text(h.querySelector(".ct-origin-low-confidence")),
        badge: text(h.querySelector(".ct-origin-cross-process-badge")),
        line: parseInt((/:(\d+)$/.exec(text(hb)) ?? ["", "0"])[1], 10),
        "frame-transition": label === "parameter pass" || label === "return capture",
        operands: details ? details.querySelectorAll(":scope > div").length : 0,
        "operands-shown": !!details?.open,
        "operand-values": details?.open ? (Array.from(details.querySelectorAll(":scope > div")) as HTMLElement[]).map((d) => text(d)) : [],
      }, [["number", String(i + 1)], ["file", hopFile]]);
      const summary = details?.querySelector("summary") as HTMLElement | null;
      hn.anchors = { points: { ...(summary && shown(summary) ? { expander: centre(summary) } : {}) } };
      hn.visible = shown(hb ?? h);
      op.children.push(hn);
    });
    crumbs.forEach((c) => {
      const l = text(c);
      op.children.push(node("breadcrumb", c, {
        label: l, current: c.getAttribute("aria-current") === "step",
        placeholder: c.getAttribute("data-placeholder") === "true",
      }, [["label", l]]));
    });
    for (const b of Array.from(panel.querySelectorAll("footer button")) as HTMLElement[]) {
      if (vis(b)) op.children.push(button(b));
    }
    root.children.push(op);
  }

  // the Scratchpad: its values and the chains pinned to it
  // (Each reader below leaves a role another reader already drew alone.)
  const has = (role: string) => root.children.some((c: any) => c.role === role);
  const sp = document.querySelector("div[id^='scratchpadComponent']") as HTMLElement | null;
  if (sp && vis(sp) && !has("scratchpad")) {
    const values = (Array.from(sp.querySelectorAll(".value-components-container > *")) as HTMLElement[]).filter((e) => vis(e));
    const chains = (Array.from(sp.querySelectorAll(".scratchpad-chain-view")) as HTMLElement[]).filter((e) => vis(e));
    const s = node("scratchpad", sp, { count: values.length + chains.length, chains: chains.length });
    for (const v of values) {
      const expr = text(v.querySelector(".value-name")).replace(/:$/, "");
      const val = text(v.querySelector(".value-expanded-text") ?? v.querySelector(".value-view"));
      s.children.push(node("scratch-entry", v, { expression: expr, value: val, kind: "value",
        error: !!v.querySelector(".error-trace") || /^<error/.test(val) }, [["expression", expr]]));
    }
    for (const c of chains) {
      const label = text(c.querySelector(".scratchpad-chain-label"));
      const expr = label.split(":")[0].trim();
      s.children.push(node("scratch-entry", c, { expression: expr, value: label, kind: "chain", error: false },
                           [["expression", expr]]));
    }
    root.children.push(s);
  }

  // the welcome screen's sections and its recent traces and folders
  const w = root.children.find((c: any) => c.role === "welcome");
  const ws = document.querySelector(".welcome-screen") as HTMLElement | null;
  if (w && ws) {
    const recentsDrawn = w.children.some((c: any) => c.role === "recent");
    w.props.sections = (Array.from(ws.querySelectorAll(
      ".welcome-left-panel, .welcome-right-panel, .recent-traces-title, .recent-folders-title, .recent-folders, .recent-traces")) as HTMLElement[])
      .filter((e) => vis(e)).map((e) => Array.from(e.classList).find((c) => /^(welcome|recent)-/.test(c)) ?? "");
    w.props.text = (Array.from(ws.querySelectorAll(".recent-traces-title, .recent-folders-title, .empty-state-text, .welcome-text, .start-option")) as HTMLElement[])
      .filter((e) => vis(e)).map((e) => text(e));
    for (const t of Array.from(ws.querySelectorAll(".recent-trace")) as HTMLElement[]) {
      if (!vis(t) || recentsDrawn) continue;
      const name = text(t.querySelector(".recent-trace-title-content"));
      const tip = t.parentElement?.querySelector(".recent-trace-tooltip, [class*='recent-trace-tooltip']") as HTMLElement | null;
      w.children.push(node("recent", t, {
        name, detail: text(t.querySelector(".recent-trace-title-time")), kind: "trace",
        "tooltip-shown": !!tip && vis(tip), tooltip: tip && vis(tip) ? text(tip) : "",
      }, [["name", name], ["kind", "trace"]]));
    }
    for (const f of Array.from(ws.querySelectorAll(".recent-folder")) as HTMLElement[]) {
      if (!vis(f) || recentsDrawn) continue;
      const name = text(f.querySelector(".recent-folder-name") ?? f);
      w.children.push(node("recent", f, { name, detail: "", kind: "folder", "tooltip-shown": false, tooltip: "" },
                           [["name", name], ["kind", "folder"]]));
    }
  }

  // the editor's flow values (`isonim_flow_inline_view`): each value box
  // drawn beside the code, by the variable it shows
  for (const ed of root.children.filter((c: any) => c.role === "editor")) {
    const comp = (Array.from(document.querySelectorAll("div[id^='editorComponent']")) as HTMLElement[]).find((c) => {
      const r = (c.closest(".lm_item_container") ?? c).getBoundingClientRect();
      return Math.abs(r.left - ed.x) < 1 && Math.abs(r.top - ed.y) < 1;
    });
    if (!comp) continue;
    // the editor's "Run test" controls beside its tests, named by their title
    // ("Run test_passes")
    for (const t of Array.from(comp.querySelectorAll(".editor-test-action")) as HTMLElement[]) {
      if (vis(t)) ed.children.push(button(t, t.getAttribute("title") ?? text(t)));
    }
  }

  // the pointer's shape where it rests: the cursor the innermost hovered
  // element draws (what a user sees, Pointer-Affordances.md §4)
  const hovered = Array.from(document.querySelectorAll(":hover"));
  const top = hovered[hovered.length - 1] as HTMLElement | undefined;
  root.props.pointer = top ? getComputedStyle(top).cursor : "default";

  // the VCS panel's history (edit mode) and its "not a repository" message
  const vcsNode = root.children.find((c: any) => c.role === "vcs");
  if (vcsNode) {
    const vc = document.querySelector(".vcs-container") as HTMLElement | null;
    vcsNode.props.commits = vc ? (Array.from(vc.querySelectorAll(".vcs-commit-entry, .vcs-commit-item")) as HTMLElement[]).filter((e) => vis(e)).length : 0;
    const nr = vc?.querySelector(".vcs-no-repo-message") as HTMLElement | null;
    vcsNode.props["no-repo"] = !!nr && vis(nr) && text(nr).length > 0;
  }

  // the Verification pane (`isonim_verification_view`)
  const vp = (Array.from(document.querySelectorAll(".ct-verification-panel")) as HTMLElement[]).find((e) => vis(e));
  if (vp) {
    const runB = vp.querySelector(".ct-verification-run") as HTMLElement | null;
    const stopB = vp.querySelector(".ct-verification-cancel") as HTMLElement | null;
    const rows = Array.from(vp.querySelectorAll("[data-ct-verification-row]")) as HTMLElement[];
    const pv = node("verification-panel", vp, {
      phase: vp.getAttribute("data-ct-verification-phase") ?? "",
      outcome: vp.getAttribute("data-ct-verification-outcome") ?? "",
      payload: vp.getAttribute("data-ct-verification-payload") ?? "",
      status: text(vp.querySelector(".ct-verification-status")),
      command: text(vp.querySelector(".ct-verification-command")),
      run: runB && vis(runB) ? text(runB) : "",
      stop: !!stopB && vis(stopB),
      groups: (Array.from(vp.querySelectorAll(".ct-verification-group-heading")) as HTMLElement[]).map((g) => text(g)),
      count: rows.length,
    });
    for (const r of rows) {
      const title = text(r.querySelector(".ct-verification-row-title"));
      pv.children.push(node("finding", r, {
        kind: text(r.querySelector(".ct-verification-row-kind")), title,
        message: text(r.querySelector(".ct-verification-row-message")),
        location: r.getAttribute("data-ct-verification-location") ?? "",
      }, [["title", title]]));
    }
    if (runB && vis(runB)) pv.children.push(button(runB, "Run"));
    if (stopB && vis(stopB)) pv.children.push(button(stopB, "Stop"));
    root.children.push(pv);
  }

  // the process tree of a multi-process session (`isonim_process_tree_view`)
  const ptEntries = (Array.from(document.querySelectorAll(".ct-process-tree-entry")) as HTMLElement[]).filter((e) => vis(e));
  if (ptEntries.length > 0 && !has("process-tree")) {
    const pt = node("process-tree", ptEntries[0].closest("[class*='ct-process-tree']:not(.ct-process-tree-entry)") ?? ptEntries[0],
                    { active: "", roles: [] as string[] });
    for (const e of ptEntries) {
      const role = e.getAttribute("data-process-role") ?? "";
      const act = e.classList.contains("active") || e.getAttribute("aria-selected") === "true";
      if (act) pt.props.active = role;
      (pt.props.roles as string[]).push(role);
      pt.children.push(node("process", e, { name: role, title: text(e.querySelector(".ct-process-tree-name")), active: act },
                            [["name", role]]));
    }
    root.children.push(pt);
  }

  // the event log's correlation markers: where a request, a response or a
  // realm crossing joins this recording to another
  const el = root.children.find((c: any) => c.role === "event-log");
  if (el) {
    // its search field ("Find event")
    const sf = document.querySelector("div[id^='eventLogComponent'] .eventLog-search-field") as HTMLInputElement | null;
    if (sf && vis(sf)) {
      el.props.search = sf.value ?? "";
      el.children.push(node("text-field", sf, { label: "Find event", value: sf.value ?? "", focused: within(sf) },
                            [["label", "Find event"]]));
    }
    for (const r of Array.from(document.querySelectorAll("div.event-log-marker-rows div.marker-row")) as HTMLElement[]) {
      if (!vis(r)) continue;
      const boundary = r.getAttribute("data-boundary-id") ?? "";
      const chip = r.querySelector("span.marker-boundary-chip") as HTMLElement | null;
      const m = node("event-marker", r, {
        boundary, chip: text(chip), "key-value": r.getAttribute("data-key-value") ?? "",
        direction: !!r.querySelector("span.marker-direction-icon"),
      }, [["boundary", boundary]]);
      if (chip && vis(chip)) m.anchors = { points: { chip: centre(chip) } };
      el.children.push(m);
    }
  }

  // the Test Results pane (`isonim_test_results_view`)
  const trp = (Array.from(document.querySelectorAll(".test-results")) as HTMLElement[]).find((e) => vis(e) &&
    e.querySelector(".test-results-headline"));
  if (trp) {
    const fail = trp.querySelector(".test-results-failure") as HTMLElement | null;
    const abs = trp.querySelector(".test-results-absence") as HTMLElement | null;
    const rows = (Array.from(trp.querySelectorAll(".test-results-row")) as HTMLElement[]).filter((r) => vis(r));
    const tp = node("test-results", trp, {
      headline: text(trp.querySelector(".test-results-headline")), count: rows.length,
      failure: fail && !fail.classList.contains("hidden") ? text(fail) : "",
      absence: abs && !abs.classList.contains("hidden") ? text(abs) : "",
    });
    const runB = trp.querySelector(".test-results-run-btn") as HTMLElement | null;
    if (runB && vis(runB)) tp.children.push(button(runB, "Run"));
    for (const r of rows) {
      const name = text(r.querySelector(".test-results-name"));
      const state = Array.from(r.classList).find((c) => c !== "test-results-row" && c !== "selected") ?? "";
      const open = r.querySelector(".test-results-open-btn") as HTMLElement | null;
      const refresh = r.querySelector(".test-results-refresh-btn") as HTMLElement | null;
      const tr = node("test-row", r, {
        name, status: state,
        outcome: /passed|failed|errored|running/.test(state) ? state.replace(/.*(passed|failed|errored|running).*/, "$1") : "",
        "has-actions": !!open || !!refresh,
        recorded: (r.getAttribute("data-ct-recording-id") ?? "") !== "",
        selected: r.classList.contains("selected") || r.getAttribute("data-ct-selected") === "true",
        "open-mode": open?.getAttribute("data-ct-open-mode") ?? "",
        "open-title": open?.getAttribute("title") ?? "",
      }, [["name", name]]);
      if (refresh && vis(refresh)) tr.children.push(button(refresh, "Refresh"));
      if (open && vis(open)) tr.children.push(button(open, "Open"));
      const nm = r.querySelector(".test-results-name") as HTMLElement | null;
      if (nm) tr.anchors = { points: { name: centre(nm) } };
      tp.children.push(tr);
    }
    root.children.push(tp);
  }

  // the VCS panel's commit history: each commit, its expand control and,
  // once expanded, its files with their View Diff button (shown on hover)
  if (vcsNode) {
    const vc = document.querySelector(".vcs-container") as HTMLElement | null;
    for (const e of (Array.from(vc?.querySelectorAll(".vcs-commit-entry") ?? []) as HTMLElement[])) {
      if (!vis(e)) continue;
      const msg = text(e.querySelector(".vcs-commit-msg"));
      const tg = e.querySelector(".vcs-commit-toggle") as HTMLElement | null;
      const hd = e.querySelector(".vcs-commit-msg") as HTMLElement | null;
      const c = node("commit", e, { message: msg, expanded: !!tg && tg.classList.contains("vcs-commit-toggle-open") },
                     [["message", msg]]);
      c.anchors = { points: { ...(tg && vis(tg) ? { toggle: centre(tg) } : {}), ...(hd && vis(hd) ? { header: centre(hd) } : {}) } };
      for (const f of Array.from(e.querySelectorAll(".vcs-accordion-file")) as HTMLElement[]) {
        const name = text(f.querySelector(".vcs-accordion-file-name"));
        if (!name || !vis(f)) continue;
        const cf = node("commit-file", f, { name }, [["name", name]]);
        const db = f.querySelector(".vcs-file-diff-btn") as HTMLElement | null;
        if (db && vis(db)) cf.children.push(button(db, "View Diff"));
        c.children.push(cf);
      }
      vcsNode.children.push(c);
    }
    vcsNode.props["branch-picker"] = !!vc?.querySelector(".vcs-branch-picker") && vis(vc!.querySelector(".vcs-branch-picker"));
    vcsNode.props["review-extras"] = !!vc?.querySelector(".vcs-review-trace-selector, .vcs-review-trace-select, .vcs-review-stats");
  }
  // a unified diff tab: its hunks (the `@@` dividers, where a click selects
  // one), its added and removed lines, and the hunk toolbar
  for (const dv of root.children.filter((c: any) => c.role === "diff-view")) {
    const d = (Array.from(document.querySelectorAll(".unified-diff-container")) as HTMLElement[]).find((x) => {
      const r = x.getBoundingClientRect();
      return Math.abs(r.left - dv.x) < 1 && Math.abs(r.top - dv.y) < 1;
    });
    if (!d) continue;
    const body = d.querySelector(".monaco-editor.modified-in-monaco-diff-editor") ?? d;
    const orig = d.querySelector(".monaco-editor.original-in-monaco-diff-editor");
    const headers = (Array.from(body.querySelectorAll(".view-line")) as HTMLElement[])
      .filter((l) => /@@\s-\d+,\d+\s\+\d+,\d+\s@@/.test((l.textContent ?? "").replace(/\u00a0/g, " ")))
      .sort((a, b) => a.getBoundingClientRect().top - b.getBoundingClientRect().top);
    dv.props.hunks = headers.length;
    dv.props.added = body.querySelectorAll(".view-overlays .ct-diff-line-added").length;
    dv.props.removed = orig ? orig.querySelectorAll(".view-overlays .ct-diff-line-removed").length : 0;
    dv.props["selected-hunks"] = d.querySelectorAll(".view-overlays .ct-diff-hunk-selected").length;
    const tb = d.querySelector(".hunk-toolbar") as HTMLElement | null;
    dv.props.toolbar = tb && vis(tb) ? text(tb.querySelector(".hunk-toolbar-count")) : "";
    headers.forEach((h, i) => {
      dv.children.push(node("hunk", h, { number: i + 1, text: text(h) }, [["number", String(i + 1)]]));
    });
    const nums = (el: Element | null) => (Array.from(el?.querySelectorAll(".margin-view-overlays .line-numbers") ?? []) as HTMLElement[])
      .map((n) => (n.textContent ?? "").replace(/\u00a0/g, " ").trim().replace(/\s+/g, " ")).filter((t) => t !== "");
    dv.props["line-numbers"] = nums(body);
    dv.props["old-line-numbers"] = nums(orig);
    // the syntax colours drawn (Monaco's `mtk<n>` token classes)
    dv.props["token-colours"] = new Set((Array.from(body.querySelectorAll(".view-line span span")) as HTMLElement[])
      .map((n) => Array.from(n.classList).find((c) => /^mtk\d+$/.test(c)) ?? "").filter((c) => c)).size;
    const perDirection: Record<string, number> = {};
    for (const b of (Array.from(body.querySelectorAll(".ct-diff-expand-boundary")) as HTMLElement[]).filter((x) => vis(x))) {
      const direction = b.getAttribute("data-ct-expand") ?? "";
      perDirection[direction] = (perDirection[direction] ?? 0) + 1;
      dv.children.push(node("expand-boundary", b, {
        n: perDirection[direction], direction,
        hidden: parseInt(b.getAttribute("data-ct-hidden") ?? "0", 10) || 0,
      }, [["direction", direction], ["n", String(perDirection[direction])]]));
    }
    if (tb && vis(tb)) {
      for (const b of Array.from(tb.querySelectorAll(".hunk-toolbar-button")) as HTMLElement[]) {
        if (vis(b)) dv.children.push(button(b, b.classList.contains("hunk-toolbar-button-subtle") ? "Clear" : text(b)));
      }
    }
  }

  // a whole-commit document's sections: one per file, under its heading
  const docScroller = (Array.from(document.querySelectorAll(".unified-diff-document-sections")) as HTMLElement[]).find((e) => vis(e));
  if (docScroller) {
    const top = docScroller.getBoundingClientRect().top;
    for (const sec of Array.from(docScroller.querySelectorAll(".unified-diff-document-section")) as HTMLElement[]) {
      const p = sec.getAttribute("data-path") ?? "";
      const st = sec.getBoundingClientRect().top - top;
      const ds = node("diff-section", sec, { path: p, offset: Math.round(st), editors: sec.querySelectorAll(
        ".monaco-editor.modified-in-monaco-diff-editor").length }, [["path", p]]);
      const link = sec.querySelector(".unified-diff-file-header-link") as HTMLElement | null;
      if (link && vis(link)) ds.anchors = { points: { link: centre(link) } };
      root.children.push(ds);
    }
  }

  // a tracepoint's results grid (`ui/trace.nim`): its rows' ticks and logged
  // values, and its Run button, per editor line
  for (const tr of Array.from(document.querySelectorAll("[id^='trace-'] .chart-table")) as HTMLElement[]) {
    const zone = tr.closest(".trace") as HTMLElement | null;
    if (!zone) continue;
    // (the zone names no line; its expression editor's host is
    // `edit-trace-<owner>-<line>`, as the tracepoint-editor reader reads it)
    const lineAttr = zone.getAttribute("data-line") ??
      (zone.querySelector("[id^='edit-trace-']")?.id.split("-").pop() ?? "0");
    const line = parseInt(lineAttr, 10) || 0;
    const shownGrid = vis(tr) && !tr.classList.contains("hidden");
    const rows = (Array.from(tr.querySelectorAll(".trace-table tbody tr")) as HTMLElement[]).filter((r) => vis(r) &&
      r.querySelector("td.direct-location-rr-ticks"));
    const res = node("trace-results", zone, { line, shown: shownGrid, count: rows.length }, [["line", String(line)]]);
    rows.forEach((r, i) => {
      const tick = r.querySelector("td.direct-location-rr-ticks") as HTMLElement;
      const vals = r.querySelector("td.trace-values") as HTMLElement | null;
      const rn = node("trace-row", r, { n: i + 1, ticks: text(tick), values: text(vals) }, [["n", String(i + 1)]]);
      rn.anchors = { points: { ticks: centre(tick), ...(vals ? { values: centre(vals.firstElementChild ?? vals) } : {}) } };
      res.children.push(rn);
    });
    const runB = zone.querySelector("#trace-run-button") as HTMLElement | null;
    if (runB && vis(runB)) res.children.push(button(runB, "Run"));
    root.children.push(res);
  }

  // a modal dialog (`role="dialog"`: the file-conflict dialog, …): its
  // heading, its text and its buttons
  if (!has("dialog")) {
    for (const dlg of Array.from(document.querySelectorAll("[role='dialog']")) as HTMLElement[]) {
      if (!vis(dlg)) continue;
      const title = text(dlg.querySelector("h1, h2, h3, .dialog-title"));
      const dn = node("dialog", dlg, { title, message: text(dlg.querySelector("p")) }, [["title", title]]);
      for (const b of Array.from(dlg.querySelectorAll("button")) as HTMLElement[]) {
        if (!vis(b)) continue;
        const l = text(b);
        dn.children.push(node("dialog-button", b, { label: l, enabled: !(b as HTMLButtonElement).disabled }, [["label", l]]));
      }
      root.children.push(dn);
    }
  }

  // the program's terminal output (`isonim_terminal_output_view`)
  const term = document.querySelector("div[id^='terminalComponent']") as HTMLElement | null;
  if (term && vis(term) && !has("terminal-output")) {
    const lines = (Array.from(term.querySelectorAll(".terminal-line")) as HTMLElement[]).map((l) => text(l));
    root.children.push(node("terminal-output", term, { text: lines, count: lines.length }));
  }

  // GoldenLayout's dividers, where a user drags to resize the panes
  const nth: Record<string, number> = {};
  for (const s of Array.from(document.querySelectorAll(".lm_splitter")) as HTMLElement[]) {
    if (!vis(s)) continue;
    const orientation = s.classList.contains("lm_vertical") ? "horizontal" : "vertical";
    nth[orientation] = (nth[orientation] ?? 0) + 1;
    root.children.push(node("splitter", s, { orientation, n: nth[orientation] },
                            [["orientation", orientation], ["n", String(nth[orientation])]]));
  }
}

// --- pw3: the event log's footer, rows, Filter list and scrubber; the Files
// pane's name field; the key router's trace; the visual-replay panes ---------
//
// Runs IN THE PAGE, in the same evaluation as `readSurface` (see
// `SURFACE_EXTENSIONS`), on the tree it returned. Reads only.
function readSurfacePw3(root: any): void {
  const vis = (el: Element | null): boolean => {
    if (!el) return false;
    const r = (el as HTMLElement).getBoundingClientRect();
    if (r.width <= 0 || r.height <= 0) return false;
    const cs = getComputedStyle(el as HTMLElement);
    return cs.visibility !== "hidden" && cs.display !== "none";
  };
  const text = (el: Element | null | undefined) => ((el?.textContent ?? "").replace(/\s+/g, " ").trim());
  const node = (role: string, el: Element | null, props: Record<string, unknown>,
                keys: Array<[string, string]> = []): any => {
    const r = el ? (el as HTMLElement).getBoundingClientRect() : { left: 0, top: 0, width: 0, height: 0 };
    return { role, keys, props, x: r.left, y: r.top, w: r.width, h: r.height,
             visible: el ? vis(el) : false, children: [] as any[] };
  };
  const num = (s: string | null | undefined) => {
    const n = parseInt((s ?? "").replace(/[^\d-]/g, ""), 10);
    return Number.isFinite(n) ? n : 0;
  };
  const outlined = (el: Element | null) => {
    if (!el) return false;
    const cs = getComputedStyle(el as HTMLElement);
    return cs.outlineStyle !== "none" && parseFloat(cs.outlineWidth || "0") > 0;
  };
  const active = document.activeElement;
  const within = (el: Element | null) => !!(el && active && (el === active || el.contains(active)));
  const find = (role: string) => root.children.find((c: any) => c.role === role);

  // A pane tab's title: where a user aims to bring the pane forward (the
  // middle of a narrow tab can be its pin or close button).
  for (const t of root.children.filter((c: any) => c.role === "pane-tab")) {
    const el = (Array.from(document.querySelectorAll(".lm_tab")) as HTMLElement[]).find((e) => {
      const r = e.getBoundingClientRect();
      return Math.abs(r.left - t.x) < 1 && Math.abs(r.top - t.y) < 1;
    });
    // the labels of every tab in its stack
    t.props.stack = (Array.from(el?.closest(".lm_stack")?.querySelectorAll(".lm_tab .lm_title") ?? []) as HTMLElement[])
      .map((x) => text(x));
    const ti = el?.querySelector(".lm_title") as HTMLElement | null;
    if (!ti) continue;
    const r = ti.getBoundingClientRect();
    if (r.width > 0) {
      t.anchors = t.anchors ?? {};
      t.anchors.points = { ...(t.anchors.points ?? {}), title: { x: r.left + Math.min(r.width / 2, 12), y: r.top + r.height / 2 } };
    }
  }

  // The key router's trace (`window.__ctKeyTrace`), read only: the operation
  // the router ran for the last key it resolved, and how many it has run.
  const trace = (window as any).__ctKeyTrace;
  if (Array.isArray(trace)) {
    const kr = node("key-router", null, {
      "last-operation": String(trace.length > 0 ? trace[trace.length - 1] : ""), operations: trace.length,
    });
    kr.visible = true;
    root.children.push(kr);
  }

  // The event log: the footer's range and count (`Rows X to Y of Z`), the
  // drawn rows and their dimming, the rows inside the scroll body, the
  // Filter button and list, the scrubber.
  const el = find("event-log");
  const elComp = document.querySelector("div[id^='eventLogComponent']") as HTMLElement | null;
  if (el && elComp) {
    const footer = elComp.querySelector(".data-tables-footer");
    const input = footer?.querySelector(".data-tables-footer-input") as HTMLInputElement | null;
    const count = footer?.querySelector(".data-tables-footer-rows-count");
    // the count's text may carry words around the number ("of 80")
    if (count) el.props.total = num(count.textContent);
    el.props["first-shown"] = num(input?.value);
    const rowsLabel = footer?.querySelector(".data-tables-footer-info, .data-tables-footer-label") ?? footer?.firstElementChild;
    if (rowsLabel && vis(rowsLabel)) {
      const r = rowsLabel.getBoundingClientRect();
      el.anchors = { ...(el.anchors ?? {}), points: { ...(el.anchors?.points ?? {}), footer: { x: r.left + Math.min(r.width / 2, 10), y: r.top + r.height / 2 } } };
    }
    const rows = (Array.from(elComp.querySelectorAll(".eventLog-dense-table tbody tr")) as HTMLElement[])
      .filter((tr) => !tr.querySelector("td.dataTables_empty, td.dt-empty"));
    el.props.rows = rows.map((r) => text(r.querySelector(".eventLog-text") ?? r));
    const dim = rows.map((r) => r.classList.contains("future"));
    el.props.dimmed = dim.filter((d) => d).length;
    const firstDim = dim.indexOf(true);
    el.props["dimmed-tail"] = firstDim < 0 || dim.slice(firstDim).every((d) => d);
    const body = elComp.querySelector(".eventLog-scroll-body") as HTMLElement | null;
    const inView: number[] = [];
    if (body) {
      const bb = body.getBoundingClientRect();
      for (const r of rows) {
        const rb = r.getBoundingClientRect();
        const pos = parseInt(r.dataset.position ?? "", 10);
        if (Number.isFinite(pos) && rb.bottom > bb.top + 1 && rb.top < bb.bottom - 1) inView.push(pos + 1);
      }
    }
    inView.sort((a, b) => a - b);
    el.props["first-in-view"] = inView.length ? inView[0] : 0;
    el.props["last-in-view"] = inView.length ? inView[inView.length - 1] : 0;
    for (const ev of el.children) {
      if (ev.role !== "event") continue;
      const r = rows.find((x) => text(x.querySelector(".eventLog-text") ?? x) === ev.props.text);
      ev.props.selected = !!r && r.classList.contains("selected");
    }
    // the Columns button's focus, and the key-focus outline of each option
    const cb = el.children.find((c: any) => c.role === "columns-button");
    const btn = elComp.querySelector(".eventLog-columns-button");
    if (cb) cb.props.focused = !!btn && btn === active;
    const cm = el.children.find((c: any) => c.role === "columns-menu");
    const menu = elComp.querySelector(".eventLog-columns-menu") as HTMLElement | null;
    if (cm && menu) {
      const mb = menu.getBoundingClientRect();
      cm.anchors = { points: { corner: { x: mb.right - 3, y: mb.top + 2 } } };
      const opts = Array.from(menu.querySelectorAll(".eventLog-column-option")) as HTMLElement[];
      for (const o of opts) {
        const name = o.getAttribute("data-column") ?? text(o.querySelector(".eventLog-column-title"));
        const opt = cm.children.find((c: any) => c.props.name === name);
        if (!opt) continue;
        const check = o.querySelector(".eventLog-column-check");
        const handle = o.querySelector(".eventLog-column-handle");
        opt.props.outline = outlined(o) ? "row" : outlined(check) ? "check" : outlined(handle) ? "handle" : "none";
      }
    }
    const filterBtn = elComp.querySelector("#category-image") as HTMLElement | null;
    if (filterBtn && vis(filterBtn)) {
      el.children.push(node("panel-button", filterBtn, {
        label: "Filter", enabled: true, active: false, title: filterBtn.getAttribute("title") ?? "",
      }, [["label", "Filter"]]));
    }
    const filter = document.querySelector("#category-image-list") as HTMLElement | null;
    if (filter && vis(filter)) {
      const dd = node("dropdown", filter, { level: 1, name: "Filter", count: 0 }, [["level", "1"], ["name", "Filter"]]);
      for (const row of Array.from(filter.querySelectorAll(":scope > li > label")) as HTMLElement[]) {
        const label = text(row.querySelector(".ct-checkmark-label"));
        dd.children.push(node("dropdown-item", row, {
          label, shortcut: "", folder: false, selected: outlined(row) || within(row),
          checked: row.querySelector(".ct-checkmark")?.getAttribute("data-state") === "checked",
        }, [["label", label]]));
      }
      dd.props.count = dd.children.length;
      el.children.push(dd);
    }
    const scrub = elComp.querySelector(".ct-list-scrubber") as HTMLElement | null;
    if (scrub && vis(scrub)) {
      const thumb = scrub.querySelector(".ct-list-scrubber-thumb") as HTMLElement | null;
      const sb = scrub.getBoundingClientRect();
      const tb = thumb?.getBoundingClientRect();
      const sn = node("scrubber", scrub, {
        first: num(scrub.getAttribute("data-ct-scrub-first")),
        "visible-rows": num(scrub.getAttribute("data-ct-scrub-visible")),
        total: num(scrub.getAttribute("data-ct-scrub-total")),
      });
      sn.anchors = {
        points: tb ? { thumb: { x: tb.left + tb.width / 2, y: tb.top + tb.height / 2 } } : {},
        track: { x: sb.left + sb.width / 2, top: sb.top, height: sb.height, thumb: tb ? tb.height : 0 },
      };
      el.children.push(sn);
    }
  }

  // The Files pane: each node's depth, the name field of a Create or Rename
  // (a `text-field` labelled `name`), and its refusal.
  const fsn = find("filesystem");
  const fsComp = document.querySelector("div[id^='filesystemComponent']") as HTMLElement | null;
  if (fsn && fsComp) {
    for (const fn of fsn.children) {
      if (fn.role !== "file-node") continue;
      const a = (Array.from(fsComp.querySelectorAll("a.jstree-anchor")) as HTMLElement[])
        .find((x) => text(x) === fn.props.name);
      let depth = 0;
      for (let li = a?.closest("li")?.parentElement?.closest("li.jstree-node"); li; li = li.parentElement?.closest("li.jstree-node")) depth++;
      fn.props.depth = depth;
    }
    const err = fsComp.querySelector(".filesystem-name-error") ?? document.querySelector(".filesystem-name-error");
    fsn.props.error = err && vis(err) ? text(err) : "";
    for (const f of Array.from(document.querySelectorAll(".filesystem-name-input")) as HTMLInputElement[]) {
      if (!vis(f)) continue;
      fsn.children.push(node("text-field", f, { label: "name", value: f.value, focused: f === active },
                             [["label", "name"]]));
    }
  }

  // The editors' omniscience flow: each line's branch colour (`flow-taken` /
  // `flow-not-taken`) and the names its flow chips draw; every value chip
  // (`flow-value`, by its variable and side); a loop header's control; and
  // the typed-value popup a chip opens.
  for (const ed of root.children.filter((c: any) => c.role === "editor")) {
    const comp = (Array.from(document.querySelectorAll("div[id^='editorComponent']")) as HTMLElement[])
      .find((c) => {
        const b = ((c.closest(".lm_item_container") as HTMLElement | null) ?? c).getBoundingClientRect();
        return vis(c) && Math.abs(b.left - ed.x) < 1 && Math.abs(b.top - ed.y) < 1 && Math.abs(b.width - ed.w) < 1;
      });
    if (!comp) continue;
    const flowRows = (Array.from(comp.querySelectorAll(".view-overlays .flow-taken, .view-overlays .flow-not-taken")) as HTMLElement[])
      .map((e) => ({ top: e.getBoundingClientRect().top, kind: e.classList.contains("flow-taken") ? "taken" : "not-taken" }));
    const widgets = (Array.from(comp.querySelectorAll(".contentWidgets [widgetid^='ct-flow-']")) as HTMLElement[]);
    for (const ln of ed.children.filter((c: any) => c.role === "line")) {
      const hit = flowRows.find((r) => Math.abs(r.top - ln.y) < 3);
      ln.props.flow = hit ? hit.kind : "none";
      const names: string[] = [];
      for (const w of widgets) {
        const id = w.getAttribute("widgetid") ?? "";
        if (Number(id.slice(id.lastIndexOf("-") + 1)) !== ln.props.number) continue;
        for (const n of Array.from(w.querySelectorAll(".ct-omni-name")) as HTMLElement[]) names.push(text(n));
      }
      ln.props["flow-names"] = names;
    }
    for (const w of widgets) {
      const id = w.getAttribute("widgetid") ?? "";
      const lineNo = Number(id.slice(id.lastIndexOf("-") + 1));
      for (const pill of Array.from(w.querySelectorAll(".ct-omni-value")) as HTMLElement[]) {
        const eye = pill.querySelector(".flow-view-more-button") as HTMLElement | null;
        const boxes = Array.from(pill.querySelectorAll("[class*='-value-box']")) as HTMLElement[];
        for (const b of boxes) {
          if (!vis(b)) continue;
          const bid = b.id ?? "";
          const dual = /-value-dual/.test(b.className);
          const side = !dual ? "single" : b.classList.contains("flow-dual-value-before") ? "before" : "after";
          const name = bid.replace(/^flow-[a-z]+-value-box-\d+-\d+-(before-|after-)?/, "");
          const cs = getComputedStyle(b);
          const lh = parseFloat(cs.lineHeight) || parseFloat(cs.fontSize) * 1.3 || 19;
          const fv = node("flow-value", b, {
            name, side, line: lineNo, value: text(b), cut: !!eye && vis(eye),
            // the box cuts what does not fit with an ellipsis, on one line
            clipped: cs.textOverflow === "ellipsis" && cs.whiteSpace === "nowrap" && cs.overflowX === "hidden",
            "single-line": pill.getBoundingClientRect().height <= lh * 1.6,
            cap: b.style.maxWidth ?? "",
          }, [["name", name], ["side", side], ["line", String(lineNo)]]);
          // on screen: inside the editor's code area, not scrolled off it
          const cr = (comp.querySelector(".monaco-scrollable-element.editor-scrollable") ?? comp).getBoundingClientRect();
          const bb = b.getBoundingClientRect();
          fv.props.shown = bb.left >= cr.left - 1 && bb.right <= cr.right + 1 && bb.top >= cr.top - 1 && bb.bottom <= cr.bottom + 1;
          fv.visible = fv.visible && fv.props.shown;
          if (eye && vis(eye)) {
            const r = eye.getBoundingClientRect();
            fv.anchors = { points: { eye: { x: r.left + r.width / 2, y: r.top + r.height / 2 } } };
          }
          ed.children.push(fv);
        }
      }
    }
    // every value box drawn beside the code, as `name=value` (pw8)
    ed.props["flow-values"] = ed.children.filter((c: any) => c.role === "flow-value" && c.visible)
      .map((c: any) => `${c.props.name}=${c.props.value}`);
    const lc = (Array.from(comp.querySelectorAll(".flow-multiline-value-container")) as HTMLElement[])
      .find((c) => c.querySelector(".flow-loop-textarea") && vis(c));
    if (lc) {
      const field = lc.querySelector(".flow-loop-textarea") as HTMLTextAreaElement | null;
      const base = lc.querySelector(".flow-loop-slider .noUi-base") as HTMLElement | null;
      const pts: Record<string, { x: number; y: number }> = {};
      for (const [k, sel] of [["forward", ".flow-loop-button.forward"], ["backward", ".flow-loop-button.backward"]]) {
        const e = lc.querySelector(sel) as HTMLElement | null;
        if (e && vis(e)) { const r = e.getBoundingClientRect(); pts[k] = { x: r.left + r.width / 2, y: r.top + r.height / 2 }; }
      }
      const n = node("loop-control", lc, {
        iteration: num(field?.value), total: num(text(lc.querySelector(".flow-parallel-loop-iteration-end"))),
        "slider-width": base ? Math.round(base.getBoundingClientRect().width) : 0,
      });
      n.anchors = { points: pts };
      ed.children.push(n);
    }
  }
  // tippy's root has no box of its own; its `.tippy-box` is what is drawn
  const tip = (Array.from(document.querySelectorAll("[data-tippy-root]")) as HTMLElement[])
    .find((t) => vis(t) || vis(t.querySelector(".tippy-box")));
  if (tip) {
    // the chip whose box the popup belongs to (tippy's own state on its box)
    let anchored = "none";
    for (const b of Array.from(document.querySelectorAll("[class*='-value-box']")) as any[]) {
      if (b._tippy?.state?.isVisible) {
        anchored = /-value-dual/.test(b.className)
          ? (b.classList.contains("flow-dual-value-before") ? "before" : "after") : "single";
      }
    }
    root.children.push(node("popup", tip, {
      title: "", text: text(tip).length ? [text(tip)] : [],
      value: text(tip.querySelector(".value-expanded-text")), type: text(tip.querySelector(".value-type")),
      anchored,
    }));
  }

  // The visual-replay panes.
  const vp = document.querySelector(".video-player-component") as HTMLElement | null;
  if (vp && vis(vp)) {
    const shown = (sel: string) => { const e = vp.querySelector(sel); return e && vis(e) ? e : null; };
    const transport = vp.querySelector(".video-player-transport");
    const scope = vp.closest("[data-scope-kind='pane']") ?? vp;
    const range = vp.querySelector(".video-player-scrub-range") as HTMLInputElement | null;
    const v = node("video-player", vp, {
      frame: text(vp.querySelector(".video-player-frame-label")),
      draw: text(vp.querySelector(".video-player-draw-label")),
      rate: text(vp.querySelector(".video-player-rate-badge")),
      picking: vp.classList.contains("picker-active"),
      error: text(shown(".video-player-error")),
      starting: !!shown(".video-player-startup"),
      "transport-enabled": !!transport && !transport.classList.contains("disabled"),
      "last-frame": range ? num(range.getAttribute("max")) : 0,
      focused: within(scope),
    });
    const fl = vp.querySelector(".video-player-frame-label") as HTMLElement | null;
    if (fl && vis(fl)) {
      const r = fl.getBoundingClientRect();
      v.anchors = { points: { label: { x: r.left + r.width / 2, y: r.top + r.height / 2 } } };
    }
    if (range && vis(range)) {
      // the scrub bar: its thumb where its value is, and its track
      const rb = range.getBoundingClientRect();
      const max = num(range.getAttribute("max")) || 1;
      const f = Math.min(1, Math.max(0, Number(range.value) / max));
      v.anchors = v.anchors ?? { points: {} };
      v.anchors.points["scrub-thumb"] = { x: rb.left + 8 + f * (rb.width - 16), y: rb.top + rb.height / 2 };
      v.anchors.range = { left: rb.left + 8, width: rb.width - 16, y: rb.top + rb.height / 2 };
    }
    for (const b of Array.from(vp.querySelectorAll("button.video-player-button")) as HTMLButtonElement[]) {
      if (!vis(b)) continue;
      const label = (b.getAttribute("title") ?? b.getAttribute("aria-label") ?? "").trim();
      v.children.push(node("toolbar-button", b, {
        label, enabled: !b.disabled, tooltip: "", "tooltip-chord": "", "tooltip-shown": false,
      }, [["label", label]]));
    }
    const img = shown(".video-player-image") as HTMLImageElement | null;
    if (img) {
      const src = decodeURIComponent(img.getAttribute("src") ?? "");
      const m = /GEID\s+(\d+)\s+frame\s+(\d+)/i.exec(src);
      // the colour of each quadrant's centre in the drawn image (its natural
      // size), Q0..Q3: bottom for 0 and 1, right for 1 and 3
      const quads: string[] = [];
      const w = img.naturalWidth, h = img.naturalHeight;
      if (img.complete && w > 0 && h > 0) {
        try {
          const c = document.createElement("canvas");
          c.width = w; c.height = h;
          const g = c.getContext("2d")!;
          g.drawImage(img, 0, 0);
          for (const q of [0, 1, 2, 3]) {
            const d = g.getImageData(q % 2 === 1 ? (3 * w) / 4 : w / 4, q >= 2 ? h / 4 : (3 * h) / 4, 1, 1).data;
            quads.push("#" + [d[0], d[1], d[2]].map((x) => x.toString(16).padStart(2, "0")).join(""));
          }
        } catch { /* a tainted or undecoded image: no colours */ }
      }
      const fi = node("frame-image", img, {
        geid: m ? parseInt(m[1], 10) : 0, frame: m ? parseInt(m[2], 10) : 0, quads, width: w, height: h,
      });
      const ib = img.getBoundingClientRect();
      fi.anchors = { image: { x: ib.left, y: ib.top, w: ib.width, h: ib.height, nw: w, nh: h } };
      v.children.push(fi);
    }
    root.children.push(v);
  }
  const ph = document.querySelector(".pixel-history-component") as HTMLElement | null;
  if (ph && vis(ph)) {
    const entries = Array.from(ph.querySelectorAll(".pixel-history-entry")) as HTMLElement[];
    const p = node("pixel-history", ph, {
      count: entries.length, pixel: text(ph.querySelector(".pixel-history-pixel")),
      draws: entries.map((e) => (/\d+/.exec(text(e.querySelector(".pixel-history-draw"))) ?? [""])[0]),
    });
    p.props["last-draw"] = p.props.draws.length ? p.props.draws[p.props.draws.length - 1] : "";
    const lastE = entries[entries.length - 1];
    if (lastE && vis(lastE)) {
      const r = lastE.getBoundingClientRect();
      p.anchors = { points: { "last-entry": { x: r.left + r.width / 2, y: r.top + r.height / 2 } } };
    }
    for (const e of entries) {
      const geid = num(e.getAttribute("data-geid")) || num(/GEID\s+(\d+)/.exec(text(e))?.[1]);
      p.children.push(node("history-entry", e, {
        geid, draw: text(e.querySelector(".pixel-history-draw")), result: text(e.querySelector(".pixel-history-pass")),
        selected: e.classList.contains("selected") || e.classList.contains("active"),
        title: e.getAttribute("title") ?? "",
      }, [["geid", String(geid)]]));
    }
    root.children.push(p);
  }
  // a values table's rows ("name type value"), whatever element draws them
  const tableRows = (t: Element | null): string[] => {
    if (!t) return [];
    const rows = (Array.from(t.querySelectorAll("tr, .shader-debug-value-row, [role='row']")) as HTMLElement[])
      .map((r) => text(r)).filter((x) => x.length > 0);
    if (rows.length) return rows;
    return (Array.from(t.children) as HTMLElement[]).map((r) => text(r)).filter((x) => x.length > 0);
  };
  const sd = document.querySelector(".shader-debug-component") as HTMLElement | null;
  if (sd && vis(sd)) {
    const s = node("shader-debug", sd, {
      source: (Array.from(sd.querySelectorAll(".shader-debug-source-line")) as HTMLElement[]).map((c) => text(c)),
      current: text(sd.querySelector(".shader-debug-source-line.current")),
      variables: tableRows(sd.querySelector(".shader-debug-variables-table")),
      registers: tableRows(sd.querySelector(".shader-debug-registers-table")),
      step: text(sd.querySelector(".shader-debug-step-label")),
    });
    for (const b of Array.from(sd.querySelectorAll("button")) as HTMLButtonElement[]) {
      if (!vis(b)) continue;
      const label = text(b) || b.getAttribute("title") || b.getAttribute("aria-label") ||
        (Array.from(b.classList).find((c) => c.startsWith("shader-debug-")) ?? "").replace(/^shader-debug-/, "");
      s.children.push(node("panel-button", b, { label, enabled: !b.disabled, active: false, title: b.getAttribute("title") ?? "" },
                           [["label", label]]));
    }
    root.children.push(s);
  }
}

// The readers that extend `readSurface`'s tree, run in the same page
// evaluation (one read of the DOM).
// --- pw4: the program menu, the layout's shape, tracepoint editors, the Call
// Trace search box, the keyboard shortcuts dialog, Low Level Code, Terminal
// Output's line view and the output panes' horizontal bars, the table panes'
// cells, the Live Edit panel, the session strip's "+" --------------------------
//
// Runs IN THE PAGE, in the same evaluation as `readSurface` (see
// `SURFACE_EXTENSIONS`), on the tree it returned. Reads only.
function readSurfacePw4(root: any): void {
  const vis = (el: Element | null): boolean => {
    if (!el) return false;
    const r = (el as HTMLElement).getBoundingClientRect();
    if (r.width <= 0 || r.height <= 0) return false;
    const cs = getComputedStyle(el as HTMLElement);
    return cs.visibility !== "hidden" && cs.display !== "none" && cs.opacity !== "0";
  };
  const text = (el: Element | null | undefined) => ((el?.textContent ?? "").replace(/\s+/g, " ").trim());
  const node = (role: string, el: Element | null, props: Record<string, unknown>,
                keys: Array<[string, string]> = [], extra: Partial<any> = {}): any => {
    const r = el ? (el as HTMLElement).getBoundingClientRect() : { left: 0, top: 0, width: 0, height: 0 };
    return { role, keys, props, x: r.left, y: r.top, w: r.width, h: r.height,
             visible: el ? vis(el) : false, children: [], ...extra };
  };
  const centre = (el: Element | null) => {
    if (!el) return undefined;
    const b = el.getBoundingClientRect();
    return { x: b.left + b.width / 2, y: b.top + b.height / 2 };
  };
  const active = document.activeElement;
  const within = (el: Element | null) => !!(el && active && (el === active || el.contains(active)));
  const add = (n: any) => root.children.push(n);

  // the session strip's "+"
  const strip = root.children.find((c: any) => c.role === "session-strip");
  const plus = document.querySelector("#session-tab-bar .session-tab-add");
  if (strip && plus && vis(plus)) strip.children.push(node("session-add", plus, {}));

  // the program menu: the main-menu button, its folders and its entries
  const nav = document.querySelector("#navigation-menu");
  if (nav) {
    const button = nav.querySelector("#menu-root");
    const main = nav.querySelector("#menu-main");
    const bar = node("menu-bar", button ?? nav, { open: !!main && vis(main) });
    for (const it of Array.from(nav.querySelectorAll(".menu-node-container > .ct-menu-item")) as HTMLElement[]) {
      if (!vis(it)) continue;
      const label = text(it.querySelector(".ct-menu-item-label"));
      if (!label) continue;
      const highlighted = it.classList.contains("ct-menu-item--active") ||
        (it.parentElement?.classList.contains("menu-active-node") ?? false);
      if (it.classList.contains("menu-folder")) {
        bar.children.push(node("menu", it, {
          label, open: false, mnemonic: text(it.querySelector(".ct-menu-mnemonic")), highlighted,
        }, [["label", label]]));
      } else {
        bar.children.push(node("menu-item", it, {
          label, enabled: !it.classList.contains("ct-menu-item--disabled"),
          shortcut: text(it.querySelector(".ct-menu-item-sublabel")), hint: "",
        }, [["label", label]]));
      }
    }
    // A folder is open while a nested panel shows its entries: the folder on
    // the highlighted path at each depth.
    if (Array.from(nav.querySelectorAll(".menu-nested-elements")).some((n) => vis(n))) {
      for (const f of bar.children) if (f.role === "menu" && f.props.highlighted) f.props.open = true;
    }
    add(bar);
  }

  // the layout's shape: rows, columns and stacks with their tabs, in order
  const glRoot = document.querySelector(".lm_goldenlayout > .lm_item");
  if (glRoot) {
    const walk = (el: Element): string => {
      const kids = Array.from(el.children).filter((c) => c.classList.contains("lm_item"));
      if (el.classList.contains("lm_stack")) {
        const tabs = Array.from(el.querySelectorAll(":scope > .lm_header .lm_title"))
          .map((t) => (t.textContent ?? "").trim());
        return `stack[${tabs.join(",")}]`;
      }
      const kind = el.classList.contains("lm_row") ? "row"
        : el.classList.contains("lm_column") ? "column" : "item";
      return `${kind}(${kids.map(walk).join(" ")})`;
    };
    add(node("layout", glRoot, {
      stacks: document.querySelectorAll(".lm_goldenlayout .lm_stack").length, shape: walk(glRoot),
    }));
  }

  // tracepoint editors (a `.trace` zone holding a Monaco instance)
  for (const z of Array.from(document.querySelectorAll(".monaco-editor .trace")) as HTMLElement[]) {
    if (!vis(z)) continue;
    const ed = z.querySelector(".monaco-editor") as HTMLElement | null;
    const lines = ed ? (Array.from(ed.querySelectorAll(".view-lines > .view-line")) as HTMLElement[])
      .sort((a, b) => a.getBoundingClientRect().top - b.getBoundingClientRect().top)
      .map((l) => (l.textContent ?? "").replace(/ /g, " ")) : [];
    const zb = z.getBoundingClientRect();
    const eb = ed?.getBoundingClientRect();
    // The expression editor's host is `edit-trace-<owner>-<line>`
    // (`ui/trace.nim`); the zone itself names no line.
    const lineAttr = z.getAttribute("data-line") ??
      (z.querySelector("[id^='edit-trace-']")?.id.split("-").pop() ?? "0");
    const line = parseInt(lineAttr, 10) || 0;
    const rowH = (ed?.querySelector(".view-lines > .view-line") as HTMLElement | null)?.getBoundingClientRect().height ?? 0;
    add(node("tracepoint-editor", ed ?? z, {
      line, text: lines, focused: within(z), rows: lines.length,
      fits: !!eb && rowH > 0 && eb.height >= lines.length * rowH - 1 && zb.height >= eb.height - 1,
    }, [["line", String(line)]]));
  }

  // the call trace's search box and its results
  const ctSearch = document.querySelector(".calltrace-search-input") as HTMLInputElement | null;
  if (ctSearch && vis(ctSearch)) {
    const sb = node("search-box", ctSearch, {
      pane: "call-trace", value: ctSearch.value, focused: document.activeElement === ctSearch,
    }, [["pane", "call-trace"]]);
    const comp = ctSearch.closest("div[id^='calltraceComponent']") ?? document;
    for (const r of Array.from(comp.querySelectorAll(".search-result")) as HTMLElement[]) {
      if (!vis(r)) continue;
      const t = text(r);
      sb.children.push(node("search-result", r, { text: t }, [["text", t]]));
    }
    add(sb);
  }

  // the keyboard shortcuts dialog
  const kb = document.querySelector("#keyboard-shortcuts-dialog");
  if (kb && vis(kb)) {
    const d = node("shortcuts-dialog", kb, {
      scope: kb.querySelector(".kb-reference")?.getAttribute("data-kb-scope") ?? "",
    });
    for (const r of Array.from(kb.querySelectorAll("[data-kb-action]")) as HTMLElement[]) {
      const a = r.getAttribute("data-kb-action") ?? "";
      d.children.push(node("shortcut-row", r, { action: a, chord: text(r.querySelector(".kb-chord")) }, [["action", a]]));
    }
    for (const r of Array.from(kb.querySelectorAll("[data-kb-ref-operation]")) as HTMLElement[]) {
      const op = r.getAttribute("data-kb-ref-operation") ?? "";
      const key = r.getAttribute("data-kb-ref-key") ?? "";
      d.children.push(node("binding-row", r, {
        operation: op, key, layer: r.getAttribute("data-kb-ref-layer") ?? "",
        "shadowed-by": r.getAttribute("data-kb-ref-shadowed-by") ?? "", text: text(r),
      }, [["operation", op], ["key", key]]));
    }
    const close = kb.querySelector("[data-kb-close]");
    if (close) d.children.push(node("dialog-button", close, { label: "Close", enabled: true }, [["label", "Close"]]));
    add(d);
  }

  // a product dialog (`[data-ct-dialog]`): its title, its message, its
  // buttons and its text fields — the breakpoint condition dialog is one
  for (const dl of Array.from(document.querySelectorAll("[data-ct-dialog]")) as HTMLElement[]) {
    if (!vis(dl)) continue;
    const title = text(dl.querySelector("[data-ct-dialog-title]"));
    const d = node("dialog", dl, { title, message: text(dl.querySelector("[data-ct-dialog-message]")) },
                   [["title", title]]);
    for (const b of Array.from(dl.querySelectorAll("[data-ct-dialog-button]")) as HTMLButtonElement[]) {
      const label = text(b);
      d.children.push(node("dialog-button", b, { label, enabled: !b.disabled }, [["label", label]]));
    }
    for (const f of Array.from(dl.querySelectorAll("input")) as HTMLInputElement[]) {
      const label = f.getAttribute("aria-label") ?? "";
      d.children.push(node("text-field", f, {
        label, value: f.value ?? "", focused: document.activeElement === f,
      }, [["label", label]]));
    }
    add(d);
  }

  // the Low Level Code view
  const llc = Array.from(document.querySelectorAll(".low-level-code")).find((e) => vis(e)) as HTMLElement | undefined;
  if (llc) {
    const stepping = llc.querySelector(".low-level-code-stepping");
    const v = node("low-level-code", llc, {
      count: 0, focused: within(llc.closest("[data-scope-kind='pane']") ?? llc),
      sync: text(llc.querySelector(".low-level-code-sync")),
      stepping: text(llc.querySelector(".low-level-code-stepping")),
      address: text(llc.querySelector(".low-level-code-address")),
    });
    for (const row of Array.from(llc.querySelectorAll(".low-level-code-instructions > div")) as HTMLElement[]) {
      if (row.classList.contains("low-level-code-source-line")) {
        const n = parseInt(text(row.querySelector(".low-level-code-source-line-number")), 10) || 0;
        v.children.push(node("source-line", row, { number: n, active: row.classList.contains("active-source-line") },
                             [["number", String(n)]]));
      } else if (row.classList.contains("low-level-code-instruction")) {
        const offset = text(row.querySelector(".low-level-code-instruction-offset"));
        v.children.push(node("instruction", row, {
          offset, name: text(row.querySelector(".low-level-code-instruction-name")),
          source: text(row.querySelector(".low-level-code-instruction-source")),
          active: row.classList.contains("active-instruction"),
          executing: row.classList.contains("execution-pointer"),
          focused: within(row),
        }, [["offset", offset]]));
      }
    }
    v.props.count = v.children.filter((c: any) => c.role === "instruction").length;
    const pointer = llc.querySelector(".low-level-code-instruction.execution-pointer");
    v.props.pointer = text(pointer?.querySelector(".low-level-code-instruction-offset"));
    v.anchors = { points: { ...(stepping ? { header: centre(stepping) } : {}),
                            ...(pointer ? { pointer: centre(pointer) } : {}) } };
    add(v);
  }

  // Terminal Output (its line view)
  const to = Array.from(document.querySelectorAll(".isonim-terminal-output")).find((e) => vis(e)) as HTMLElement | undefined;
  if (to) {
    const lines = (Array.from(to.querySelectorAll("pre .terminal-line")) as HTMLElement[]).map((l) => text(l));
    const pane = to.closest("[data-scope-kind='pane']") ?? to;
    const lb = to.querySelector(".terminal-view-button[data-view]");
    add(node("terminal-output", to.querySelector("pre") ?? to, {
      text: lines, count: lines.length, focused: within(pane),
    }, [], { anchors: { points: lb ? { "lines-button": centre(lb) } : {} } }));
  }

  // the horizontal bars of the output panes
  // A character's width in the pane a bar scrolls: its widest line's drawn
  // width over its length (the panes draw one monospace font).
  const charWidthOf = (bar: Element): number => {
    const pane = bar.closest("[data-scope-kind='pane']") ?? bar.parentElement;
    let best = 0, len = 0;
    for (const l of Array.from(pane?.querySelectorAll("pre .terminal-line, .build-stdout, .build-stderr") ?? []) as HTMLElement[]) {
      const t = (l.textContent ?? "").length;
      if (t > len) { len = t; best = l.scrollWidth; }
    }
    return len > 0 && best > 0 ? best / len : 1;
  };
  for (const tr of Array.from(document.querySelectorAll("[data-ct-hscrubber]")) as HTMLElement[]) {
    if (!vis(tr) || tr.style.display === "none") continue;
    const pane = tr.getAttribute("data-ct-hscrubber") ?? "";
    const thumb = tr.querySelector(".ct-hscrubber-thumb") as HTMLElement | null;
    const b = tr.getBoundingClientRect();
    const thumbPx = Number(thumb?.getAttribute("data-ct-thumb-px") ?? 0);
    const thumbLeft = Number(thumb?.getAttribute("data-ct-thumb-left") ?? 0);
    const content = Number(tr.getAttribute("data-ct-hscrub-content") ?? 0);
    const viewport = Number(tr.getAttribute("data-ct-hscrub-viewport") ?? 0);
    const vbar = document.querySelector(`[data-ct-list-scrubber='${pane}']`)?.getBoundingClientRect();
    const midY = b.top + b.height / 2;
    add(node("h-scrubber", tr, {
      pane, content, viewport,
      left: Number(tr.getAttribute("data-ct-hscrub-left") ?? 0),
      "thumb-px": thumbPx, "track-px": Math.round(b.width),
      overflows: content > viewport,
      "at-end": content > 0 && Number(tr.getAttribute("data-ct-hscrub-left") ?? 0) + viewport >= content - 1,
      centre: content > 0
        ? Math.round(((Number(tr.getAttribute("data-ct-hscrub-left") ?? 0) + viewport / 2) / content) * 100) / 100 : 0,
      "left-columns": Math.round(Number(tr.getAttribute("data-ct-hscrub-left") ?? 0) / charWidthOf(tr)),
      "thumb-proportional": content > 0 &&
        thumbPx === Math.min(Math.round(b.width), Math.max(20, Math.round((b.width * viewport) / content))),
      "clear-of-vertical": !vbar || (vbar.bottom <= b.top + 0.5 && b.right <= vbar.left + 0.5),
    }, [["pane", pane]], {
      anchors: {
        track: { left: b.left, width: b.width, midY },
        points: { thumb: { x: b.left + thumbLeft + thumbPx / 2, y: midY }, start: { x: b.left + 2, y: midY } },
      },
    }));
  }

  // the table panes: fit or scroll, and their cells
  const cellNode = (c: HTMLElement) => {
    const id = c.getAttribute("data-ct-cell") ?? "";
    const r = c.getBoundingClientRect();
    return node("table-cell", c, {
      cell: id, column: id.split("|").pop() ?? "",
      text: c.getAttribute("data-ct-text") ?? (c.textContent ?? "").trim(),
      full: c.getAttribute("data-ct-full") ?? "",
      cut: c.hasAttribute("data-ct-cut"), "drawn-cut": c.scrollWidth > c.clientWidth + 1,
    }, [["cell", id]], {
      anchors: { points: { ellipsis: { x: r.right - 3, y: r.top + r.height / 2 },
                           "text-start": { x: r.left + 4, y: r.top + r.height / 2 } } },
    });
  };
  const tablePane = (pane: string, comp: Element | null, scroller: HTMLElement | null, fitEl: Element | null) => {
    if (!comp || !vis(comp)) return undefined;
    const ox = scroller ? getComputedStyle(scroller).overflowX : "";
    const tp = node("table-pane", comp, {
      pane, fit: fitEl?.getAttribute("data-ct-fit") ?? "",
      sideways: ox === "auto" || ox === "scroll",
      wider: !!scroller && scroller.scrollWidth > scroller.clientWidth + 1,
      "scroll-left": scroller ? Math.round(scroller.scrollLeft) : 0,
      "header-follows": true,
    }, [["pane", pane]]);
    for (const c of Array.from(comp.querySelectorAll("[data-ct-cell]")) as HTMLElement[]) {
      if (c.offsetParent === null || c.clientWidth <= 0) continue;
      tp.children.push(cellNode(c));
    }
    add(tp);
    return tp;
  };
  const elTable = tablePane("event-log", document.querySelector("div[id^='eventLogComponent']"),
    document.querySelector(".eventLog-scroll-body") as HTMLElement | null,
    document.querySelector(".eventLog-dense-table"));
  if (elTable) {
    const h = document.querySelector(".eventLog-column-header .eventLog-text") as HTMLElement | null;
    const c = document.querySelector(".eventLog-rows td.eventLog-text") as HTMLElement | null;
    if (h && c) elTable.props["header-follows"] =
      Math.abs(h.getBoundingClientRect().left - c.getBoundingClientRect().left) <= 1;
    for (const hd of Array.from(document.querySelectorAll(".eventLog-column-header .eventLog-index")) as HTMLElement[]) {
      if (!vis(hd)) continue;
      const g = hd.querySelector(".eventLog-column-grip");
      elTable.children.push(node("column-header", hd, {
        column: "#", label: text(hd), cells: Math.round(hd.getBoundingClientRect().width / 8),
      }, [["column", "#"]], { anchors: { points: g ? { separator: centre(g) } : {} } }));
    }
  }
  tablePane("call-trace", document.querySelector("div[id^='calltraceComponent']"),
    document.querySelector(".local-calltrace-view") as HTMLElement | null,
    document.querySelector(".local-calltrace-view"));
  tablePane("variables", document.querySelector("div[id^='stateComponent']"),
    document.querySelector(".isonim-state .value-components-container") as HTMLElement | null, null);

  // a cut cell's tooltip and a row's detail
  const tip = Array.from(document.querySelectorAll(".ct-table-tooltip")).find((e) => vis(e)) as HTMLElement | undefined;
  if (tip) {
    const lines = (Array.from(tip.querySelectorAll(".ct-table-tooltip-line")) as HTMLElement[])
      .map((l) => l.textContent ?? "");
    add(node("table-tooltip", tip, { text: lines, widest: Math.max(0, ...lines.map((l) => l.length)) }));
  }
  const detail = Array.from(document.querySelectorAll(".ct-table-detail")).find((e) => vis(e)) as HTMLElement | undefined;
  if (detail) {
    const lines = (Array.from(detail.querySelectorAll(".ct-table-detail-line")) as HTMLElement[])
      .map((l) => l.textContent ?? "");
    add(node("row-detail", detail, { text: lines, count: lines.length }));
  }

  // the Live Edit (HCR) panel
  const le = Array.from(document.querySelectorAll(".hcr-live-edit-panel")).find((e) => vis(e)) as HTMLElement | undefined;
  if (le) {
    const p = node("live-edit-panel", le, {
      status: text(le.querySelector("[data-hcr-live-edit-status]")),
      detail: text(le.querySelector("[data-hcr-live-edit-detail]")),
    });
    const input = le.querySelector("[data-hcr-live-edit-input]") as HTMLInputElement | null;
    if (input) p.children.push(node("text-field", input, {
      label: "edit", value: input.value ?? "", focused: document.activeElement === input,
    }, [["label", "edit"]]));
    add(p);
  }
}

const SURFACE_EXTENSIONS: Array<(root: any) => void> = [readSurfacePw1, readSurfacePw3, readSurfacePw4, readSurfacePw8];

// --- the binding ----------------------------------------------------------------

// pw3: a visual recording's graphics stream (`gfx_stream/`) is a companion of
// the recording folder that `ct host --trace-path` does not import; it goes
// beside the imported trace, where the product looks for it.
function copyCompanionGfxStream(recording: string, home: string | undefined, id: string): void {
  const source = path.join(recording, "gfx_stream");
  if (!home || !fs.existsSync(source)) return;
  const data = path.join(home, "data");
  const target = fs.existsSync(path.join(data, `trace-${id}`)) && !fs.existsSync(path.join(data, id))
    ? path.join(data, `trace-${id}`, "gfx_stream") : path.join(data, id, "gfx_stream");
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.cpSync(source, target, { recursive: true, force: true });
  if (fs.existsSync(`${source}.ctfs`)) fs.copyFileSync(`${source}.ctfs`, `${target}.ctfs`);
}

async function launchElectron(ctx: Ctx, launch: any): Promise<void> {
  const env: Record<string, string> = {};
  for (const [k, v] of Object.entries(process.env)) if (v !== undefined) env[k] = v;
  for (const k of ["CODETRACER_TRACE_ID", "CODETRACER_RECORDING_ID", "CODETRACER_CALLER_PID",
                   "CODETRACER_PREFIX", "WAYLAND_DISPLAY", "XDG_SESSION_TYPE"]) delete env[k];
  Object.assign(env, launch.env);
  env.CODETRACER_IN_UI_TEST = "1";
  env.CODETRACER_TEST = "1";
  env.CT_HMR = "0";
  // (a stage may choose the policy, `front-end-options` env)
  env.CODETRACER_NEW_TRACE_POLICY = launch.env?.CODETRACER_NEW_TRACE_POLICY ?? "window";
  env.CODETRACER_ELECTRON_ARGS = ["--no-sandbox", "--no-zygote", "--disable-gpu",
    "--disable-gpu-compositing", "--disable-dev-shm-usage", "--in-process-gpu",
    "--ozone-platform-hint=x11"].join(" ");
  if (process.env.CT_LD_LIBRARY_PATH) {
    env.LD_LIBRARY_PATH = [process.env.CT_LD_LIBRARY_PATH, env.LD_LIBRARY_PATH ?? ""].filter((s) => s).join(":");
  }
  // (what an `act` step's second process of the product starts with)
  ctx.state.appEnv = env;
  ctx.state.launch = launch;
  const args: string[] = [];
  if (launch.recording) {
    // the recording folder, imported the way `ct host --trace-path` imports one
    const r = spawnSync(ctBin, ["host", "--trace-path", launch.recording, "0", "--port=0",
      "--idle-timeout=1ms", "--backend-socket-port=0", "--frontend-socket=0"],
      { cwd: srcDir, env, encoding: "utf-8", timeout: 60_000 });
    const m = /imported as trace id\s+([0-9a-fA-F-]{36})/.exec(`${r.stdout}\n${r.stderr}`);
    if (!m) throw new Error(`ct host did not import ${launch.recording}: ${r.stderr || r.stdout}`);
    env.CODETRACER_RECORDING_ID = m[1];
    copyCompanionGfxStream(launch.recording, env.CODETRACER_HOME, m[1]);
  } else if (launch.review) {
    // a review dataset, as a user opens one (`ct review <PATH>`)
    args.push("review", launch.review);
  } else if (launch.project) {
    // `ct edit` takes ONE path (`ct/launch/launch.nim`): the file, when the
    // stage names one (its folder is the project), else the folder.
    // pw8: `ct edit .` from inside the folder (`open-project` `from-inside`)
    const dot = !!launch.fromInside;
    args.push("edit", dot ? "." : launch.file ? path.join(launch.project, launch.file) : launch.project);
  }
  // (launch.welcome: no arguments — the welcome screen)
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
  // (A multi-recording session can navigate its window while it loads, which
  // destroys the context this runs in: try again.)
  for (let attempt = 0; ; attempt++) {
    try {
      await app.evaluate(({ BrowserWindow }: any, size: any) => {
        for (const w of BrowserWindow.getAllWindows()) w.setContentSize(size.width, size.height);
      }, { width, height });
      break;
    } catch (e) {
      if (attempt >= 4 || !/context was destroyed|navigation/i.test(String(e))) throw e;
      await new Promise((r) => setTimeout(r, 1000));
    }
  }
  ctx.page = page;
  // `CT_SCENARIO_APP_LOG=<file>`: the application's own output — the main
  // process's stdout/stderr and the window's console — appended to a file,
  // for diagnosing a run. Read only; off unless asked for.
  const appLog = process.env.CT_SCENARIO_APP_LOG;
  if (appLog) {
    const put = (tag: string, line: string) => fs.appendFileSync(appLog, `[${tag}] ${line}\n`);
    app.process()?.stdout?.on("data", (c: Buffer) => put("main", c.toString().trimEnd()));
    app.process()?.stderr?.on("data", (c: Buffer) => put("main!", c.toString().trimEnd()));
    page.on("console", (m: any) => put(`console.${m.type()}`, m.text()));
  }
  ctx.context = app.context();
}

// --- pw2: the web deployment -------------------------------------------------
// `open-recording` with `deployment: web`: the recording served by a real
// `ct host`, and its page opened in a browser (the arm's own page, so it is
// recorded like any other), as a user opens the URL `ct host` prints.
function freePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.once("error", reject);
    srv.listen(0, "127.0.0.1", () => {
      const port = (srv.address() as net.AddressInfo).port;
      srv.close(() => resolve(port));
    });
  });
}

async function launchHosted(ctx: Ctx, launch: any): Promise<void> {
  if (!launch.recording) throw new Error("open-recording (web): no recording");
  const env: Record<string, string> = {};
  for (const [k, v] of Object.entries(process.env)) if (v !== undefined) env[k] = v;
  for (const k of ["CODETRACER_TRACE_ID", "CODETRACER_RECORDING_ID", "CODETRACER_CALLER_PID",
                   "CODETRACER_PREFIX"]) delete env[k];
  Object.assign(env, launch.env);
  env.CODETRACER_IN_UI_TEST = "1";
  env.CODETRACER_TEST = "1";
  const secret = crypto.randomBytes(32).toString("base64url");
  env.CODETRACER_HOST_SESSION_SECRET = secret;
  if (process.env.CT_LD_LIBRARY_PATH) {
    env.LD_LIBRARY_PATH = [process.env.CT_LD_LIBRARY_PATH, env.LD_LIBRARY_PATH ?? ""].filter((x) => x).join(":");
  }
  const httpPort = await freePort();
  const backendPort = await freePort();
  const host = spawn(ctBin, ["host", `--trace-path=${launch.recording}`, `--port=${httpPort}`,
    `--backend-socket-port=${backendPort}`, `--frontend-socket=${backendPort}`],
    { cwd: launch.workDir || srcDir, env, stdio: ["ignore", "pipe", "pipe"] });
  const output: string[] = [];
  host.stdout?.on("data", (c: Buffer) => output.push(c.toString()));
  host.stderr?.on("data", (c: Buffer) => output.push(c.toString()));
  ctx.state.hostPid = host.pid;
  const width = launch.width || 1600;
  const height = launch.height || 1000;
  const url = `http://localhost:${httpPort}/?ct_session=${secret}`;
  const deadline = Date.now() + 180_000;
  let gfxCopied = !fs.existsSync(path.join(launch.recording, "gfx_stream"));
  for (;;) {
    if (host.exitCode !== null) throw new Error(`ct host exited ${host.exitCode}: ${output.join("").slice(-2000)}`);
    if (!gfxCopied) {
      // pw3: the graphics stream goes beside the trace once it is imported
      const m = /imported as trace id\s+([0-9a-fA-F-]{36})/.exec(output.join(""));
      if (m) {
        copyCompanionGfxStream(launch.recording, env.CODETRACER_HOME, m[1]);
        gfxCopied = true;
      } else {
        if (Date.now() > deadline) throw new Error(`ct host never imported ${launch.recording}: ${output.join("").slice(-2000)}`);
        await new Promise((r) => setTimeout(r, 200));
        continue;
      }
    }
    try {
      await new Promise<void>((resolve, reject) => {
        const sock = net.connect(httpPort, "127.0.0.1", () => { sock.end(); resolve(); });
        sock.once("error", reject);
      });
      break;
    } catch {
      if (Date.now() > deadline) throw new Error(`ct host never listened on ${httpPort}: ${output.join("").slice(-2000)}`);
      await new Promise((r) => setTimeout(r, 500));
    }
  }
  await ctx.open(url, { width, height });
  ctx.state.hosted = true;
}
// --- end pw2 ---

function killTree(pid: number): void {
  // The application's process tree, children first.
  const r = spawnSync("pgrep", ["-P", String(pid)], { encoding: "utf-8" });
  for (const c of (r.stdout ?? "").split("\n").filter((x) => x.trim())) killTree(parseInt(c, 10));
  try { process.kill(pid, "SIGKILL"); } catch { /* already gone */ }
}

// The point a line anchor names (`gutter`, `text-start`, `column(c)`, …).
async function textAnchor(n: any, anchor: string): Promise<{ x: number; y: number } | undefined> {
  const a = n.anchors;
  if (!a) return undefined;
  if (anchor === "gutter") return a.gutter;
  if (anchor === "glyph") return a.glyph;
  if (anchor === "line-number") return a.lineNumber;
  // pw2: a column option's check box and drag handle
  if ((anchor === "check" || anchor === "handle" || anchor === "close") && a[anchor]) return a[anchor];
  // pw2: `caret(c)`: just right of the boundary before the c-th character,
  // where a press puts the caret at column c
  const caretAt = /^caret\((\d+)\)$/.exec(anchor);
  if (caretAt) return { x: a.textLeft + (parseInt(caretAt[1], 10) - 1) * a.charWidth + 2, y: a.midY };
  if (anchor === "text-start") return { x: a.textLeft + (a.firstChar + 0.5) * a.charWidth, y: a.midY };
  if (anchor === "text-end") return { x: a.textRight - a.charWidth / 2, y: a.midY };
  const col = /^column\((\d+)\)$/.exec(anchor);
  if (col) return { x: a.textLeft + (parseInt(col[1], 10) - 0.5) * a.charWidth, y: a.midY };
  return undefined;
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
    if (launch.env?.CT_FAKE_ACP_LOG) ctx.state.agentLog = launch.env.CT_FAKE_ACP_LOG;
    if (use === "open-recording" && clean.deployment === "web") {
      await launchHosted(ctx, launch);
    } else if (use === "open-recording" || use === "open-project" || use === "open-review" || use === "open-welcome") {
      await launchElectron(ctx, launch);
    }
  },

  async surface(ctx: Ctx): Promise<Node> {
    // One evaluation: `readSurface`, then each extension over its tree.
    return await ctx.page.evaluate(
      `(() => { const root = (${readSurface.toString()})(); ` +
      `for (const ext of [${SURFACE_EXTENSIONS.map((f) => f.toString()).join(", ")}]) ext(root); ` +
      `return root; })()`);
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
    // pw1: the stand-in agent's method log (`stub-agent`): the pane opened
    // its ACP session. The log is the agent's, outside the application.
    if (name === "agent-session-open") {
      const log = ctx.state.agentLog;
      if (!log) return undefined;
      try {
        return fs.readFileSync(log, "utf8").split("\n").includes("session/new");
      } catch {
        return false;
      }
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

  async anchor(ctx: Ctx, n: any, anchor: string): Promise<{ x: number; y: number } | undefined> {
    // a point a reader measured for a named anchor (`expander`, …)
    if (n.anchors?.points?.[anchor]) return n.anchors.points[anchor];
    // pw4: `track(f)`, the point at fraction f of a horizontal bar's track
    const f = /^track\(([\d.]+)\)$/.exec(anchor);
    if (f && n.anchors?.track) {
      const t = n.anchors.track;
      return { x: t.left + Math.floor(t.width * parseFloat(f[1])), y: t.midY };
    }
    // pw3: the point of a scrubber's track where its thumb's centre sits
    // when the window starts `p`% of the way down the list
    // pw3: `pixel(x,y)`: the centre of the image's source pixel (x, y)
    const px = /^pixel\((\d+),\s*(\d+)\)$/.exec(anchor);
    if (px && n.anchors?.image?.nw) {
      const im = n.anchors.image;
      return { x: im.x + ((parseInt(px[1], 10) + 0.5) * im.w) / im.nw, y: im.y + ((parseInt(px[2], 10) + 0.5) * im.h) / im.nh };
    }
    // pw3: `scrub(p)`: the Video Player's scrub bar, p% along
    const sc = /^scrub\((\d+)\)$/.exec(anchor);
    if (sc && n.anchors?.range) {
      const r = n.anchors.range;
      return { x: r.left + (Math.min(100, parseInt(sc[1], 10)) / 100) * r.width, y: r.y };
    }
    const at = /^at\((\d+)\)$/.exec(anchor);
    if (at && n.role === "scrubber" && n.anchors?.track) {
      const t = n.anchors.track;
      const f = Math.min(100, parseInt(at[1], 10)) / 100;
      return { x: t.x, y: t.top + t.thumb / 2 + f * (t.height - t.thumb) };
    }
    const p = await textAnchor(n, anchor);
    // pw2: never aim into the margin when the code is scrolled horizontally
    if (p && n.anchors?.contentLeft !== undefined && /^(text-start|text-end|column\(|caret\()/.test(anchor)) {
      p.x = Math.max(p.x, n.anchors.contentLeft + 2);
    }
    void ctx;
    return p;
  },

  // `act` steps: a change outside the application, during the run
  // (DemoVideoScript-pm spec/Proposal-Outside-Actions.md). None of these
  // touches the application: they are another program writing a file of the
  // stage's project, its permissions changing, and a second process of the
  // product started from a shell, which hands its arguments to the open
  // window and exits.
  async act(ctx: Ctx, use: string, args: Record<string, unknown>): Promise<void> {
    const launch = ctx.state.launch ?? {};
    const project: string = launch.project || launch.workDir || "";
    const inProject = (rel: unknown): string => {
      const r = String(rel ?? "");
      if (!project) throw new Error(`${use}: the stage prepared no project folder`);
      if (!r || path.isAbsolute(r) || r.split(/[\\/]/).includes("..")) {
        throw new Error(`${use}: '${r}' is not a path inside the project`);
      }
      return path.join(project, r);
    };
    if (use === "write-file") {
      fs.writeFileSync(inProject(args.file), String(args.content ?? ""), "utf8");
    } else if (use === "make-read-only") {
      fs.chmodSync(inProject(args.file), 0o444);
    } else if (use === "run-product") {
      const cwd = String(args.cwd ?? "$project").replace("$project", project) || project;
      const env: Record<string, string> = { ...(ctx.state.appEnv ?? process.env) };
      for (const k of ["CODETRACER_TRACE_ID", "CODETRACER_RECORDING_ID", "CODETRACER_CALLER_PID"]) delete env[k];
      const r = spawnSync(ctBin, (args.args as string[]) ?? [], { cwd, env, encoding: "utf-8", timeout: 60_000 });
      if (r.error) throw new Error(`run-product: ${r.error.message}`);
      if (r.status !== 0) throw new Error(`run-product: ct exited ${r.status}: ${(r.stderr || r.stdout || "").trim().slice(-2000)}`);
    } else {
      throw new Error(`the CodeTracer pack has no action '${use}'`);
    }
  },

  async close(ctx: Ctx): Promise<void> {
    if (ctx.state.hosted) {
      // pw2: the web deployment — the page (its video) and then `ct host`
      ctx.state.hosted = false;
      await Promise.race([ctx.context?.close().catch(() => {}), new Promise((r) => setTimeout(r, 15_000))]);
      if (ctx.state.hostPid) killTree(ctx.state.hostPid);
    }
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
