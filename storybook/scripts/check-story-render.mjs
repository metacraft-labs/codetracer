#!/usr/bin/env node
// Render EVERY CodeTracer story and fail on the ways a story can render
// broken while StoryBook still reports it as rendered: a placeholder, an
// empty panel, an error, or a panel at another type size than the app's.
// When a story counts as rendered, and the verdict's four categories, are
// defined once, in `story-render-judge.mjs` beside this script, which the
// capture tool (tools/visual-review/capture-storybook.mjs) uses as well: a
// capture is taken only of a story this check passes.
//
// What a story is meant to show comes from its declaration
// (`src/frontend/stories/codetracer_stories.nim`, `state`): `data` (the
// default) or a declared `empty`, `loading` or `error` state. A story that
// declares a state must show that state, and a story that declares data must
// show no such state. There is no allowlist: a story that cannot show
// realistic content is fixed or removed, not excused here.
//
// Usage (from the repository root, after `just storybook-build`, which
// `just storybook-check-render` runs first):
//
//   node storybook/scripts/check-story-render.mjs [--url <storybook>]
//       [--theme dark|light]... [--filter <substring>]... [--size WxH]
//       [--jobs N] [--shots <dir>] [--self-test]
//
// Without `--url` the script serves `storybook/storybook-static` itself
// (refusing a stale build, tools/visual-review/storybook-freshness.mjs).
// `--self-test` is the check's positive control: it plants each failure into
// a story that passes (`PLANTS` below: an unregistered surface, a mount whose
// content is taken away, a panel reduced to its title bar or to a toolbar,
// classed and unclassed empty-state text, unclassed loading and error text
// alone (in a CodeTracer panel and in an Agent Harbor panel; beside a
// spinner; split over an inline element; in one panel of a layout), an editor with
// an empty model, content faded out by an ancestor, the review without its
// diff, a panel mounted in `#main`, a console error, a thrown error, failed
// and aborted requests, and a declared empty state that shows data) and
// exits 0 only when the unplanted story passes and every planted one fails
// with the right category.

import { createRequire } from "node:module";
import { createServer } from "node:http";
import { existsSync, mkdirSync, readFileSync, statSync } from "node:fs";
import { dirname, extname, join, normalize, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { renderAndJudge } from "./story-render-judge.mjs";


const scriptDir = dirname(fileURLToPath(import.meta.url));
const storybookDir = resolve(scriptDir, "..");
const repoRoot = resolve(storybookDir, "..");
const staticDir = join(storybookDir, "storybook-static");
const indexPath = join(storybookDir, "stories", "generated", "stories.json");

// --- Arguments --------------------------------------------------------------

function argValues(name) {
  const values = [];
  for (let i = 2; i < process.argv.length; i++) {
    if (process.argv[i] === name && i + 1 < process.argv.length) values.push(process.argv[++i]);
  }
  return values;
}
const hasArg = (name) => process.argv.includes(name);
const known = new Set(["--url", "--theme", "--filter", "--size", "--jobs", "--shots", "--self-test", "--timeout"]);
for (const arg of process.argv.slice(2)) {
  if (arg.startsWith("--") && !known.has(arg)) {
    console.error(`check-story-render: unknown option ${arg}`);
    process.exit(2);
  }
}

const themes = argValues("--theme").length ? argValues("--theme") : ["dark", "light"];
for (const theme of themes) {
  if (!["dark", "light"].includes(theme)) {
    console.error(`check-story-render: unknown theme ${theme}`);
    process.exit(2);
  }
}
const [width, height] = (argValues("--size")[0] ?? "1440x900").split("x").map(Number);
const jobs = Math.max(1, Number(argValues("--jobs")[0] ?? 4));
const filters = argValues("--filter");
const shotsDir = argValues("--shots")[0];
const storyTimeoutMs = Number(argValues("--timeout")[0] ?? 90000);

// --- The planted failures (`--self-test`) ------------------------------------

// Each plant is JavaScript appended to `dist/components.js` as the page loads
// it, wrapping the real `mountCodeTracerStory` the bundle exports, so the
// failure goes through the real mount and the real StoryBook render.
const PLANTS = {
  placeholder: {
    expect: "placeholder",
    code: `mountCodeTracerStory = (function (real) { return function (c, k, n, f) {
      return real(c, k, "planted-unregistered-surface", f); }; })(mountCodeTracerStory);`,
  },
  empty: {
    expect: "empty",
    code: `mountCodeTracerStory = (function (real) { return function (c, k, n, f) {
      const dispose = real(c, k, n, f); c.replaceChildren(); return dispose; }; })(mountCodeTracerStory);`,
  },
  "console-error": {
    expect: "error",
    code: `mountCodeTracerStory = (function (real) { return function (c, k, n, f) {
      console.error("planted console error"); return real(c, k, n, f); }; })(mountCodeTracerStory);`,
  },
  "page-error": {
    expect: "error",
    code: `mountCodeTracerStory = (function (real) { return function (c, k, n, f) {
      setTimeout(() => { throw new Error("planted page error"); }, 0); return real(c, k, n, f); }; })(mountCodeTracerStory);`,
  },
  "failed-request": {
    expect: "error",
    code: `mountCodeTracerStory = (function (real) { return function (c, k, n, f) {
      fetch("./planted-missing-resource.json").catch(() => {}); return real(c, k, n, f); }; })(mountCodeTracerStory);`,
  },
  "declared-empty-shows-data": {
    // The fleet's empty story mounted over the snapshot: the declaration
    // says empty, the panel shows sessions.
    expect: "placeholder",
    story: "codetracer-agent-harbor--fleet-empty",
    code: `mountCodeTracerStory = (function (real) { return function (c, k, n, f) {
      return real(c, k, n, "snapshot"); }; })(mountCodeTracerStory);`,
  },
  "title-only-panel": {
    // A panel whose data never arrived but that still draws its own title
    // bar: everything but a bar reading the panel's name is taken away.
    expect: "empty",
    code: `mountCodeTracerStory = (function (real) { return function (c, k, n, f) {
      const dispose = real(c, k, n, f);
      const bar = document.createElement("div"); bar.className = "calltrace-header panel-title-bar";
      const title = document.createElement("span"); title.textContent = "Calltrace"; bar.appendChild(title);
      c.replaceChildren(bar); return dispose; }; })(mountCodeTracerStory);`,
  },
  "aborted-request": {
    // An arbitrary request the page aborts (a script, not the theme
    // stylesheet the theme switch supersedes): a failure like a 404.
    expect: "error",
    code: `mountCodeTracerStory = (function (real) { return function (c, k, n, f) {
      const abort = new AbortController();
      fetch("./dist/components.js?planted-abort=" + Date.now(), { signal: abort.signal }).catch(() => {});
      setTimeout(() => abort.abort(), 1);
      return real(c, k, n, f); }; })(mountCodeTracerStory);`,
  },
  "aborted-theme-fetch": {
    // The theme stylesheet's URL fetched and aborted by script: not the
    // `#theme` link the theme switch supersedes, so not excused.
    expect: "error",
    code: `mountCodeTracerStory = (function (real) { return function (c, k, n, f) {
      const abort = new AbortController();
      fetch("./frontend/styles/default_white_theme_electron.css?planted=" + Date.now(), { signal: abort.signal }).catch(() => {});
      setTimeout(() => abort.abort(), 1);
      return real(c, k, n, f); }; })(mountCodeTracerStory);`,
  },
  "toolbar-and-title-only": {
    // A toolbar's buttons and a heading repeating the panel's name.
    expect: "empty",
    code: `mountCodeTracerStory = (function (real) { return function (c, k, n, f) {
      const dispose = real(c, k, n, f);
      c.innerHTML = '<div class="calltrace-toolbar" role="toolbar"><button>Filter</button><button>Collapse all</button></div><div class="panel-heading"><span>CALLTRACE</span></div>';
      return dispose; }; })(mountCodeTracerStory);`,
  },
  "classed-empty-state": {
    expect: "placeholder",
    code: `mountCodeTracerStory = (function (real) { return function (c, k, n, f) {
      const dispose = real(c, k, n, f);
      c.innerHTML = '<div class="calltrace-toolbar"><button>Filter</button></div><div class="calltrace-empty">No calls recorded</div>';
      return dispose; }; })(mountCodeTracerStory);`,
  },
  "unclassed-empty-text": {
    // The same empty state in a plain element, with no state class.
    expect: "placeholder",
    code: `mountCodeTracerStory = (function (real) { return function (c, k, n, f) {
      const dispose = real(c, k, n, f);
      c.innerHTML = '<div class="calltrace-toolbar"><button>Filter</button></div><div class="calltrace-lines"><div>No calls recorded</div></div>';
      return dispose; }; })(mountCodeTracerStory);`,
  },
  "unclassed-loading-text": {
    // A data story whose panel, once mounted, shows nothing but "Loading…"
    // in a plain element: its data never arrived.
    expect: "placeholder",
    code: `mountCodeTracerStory = (function (real) { return function (c, k, n, f) {
      const dispose = real(c, k, n, f);
      setTimeout(() => { c.innerHTML = '<div class="calltrace-lines"><div>Loading…</div></div>'; }, 300);
      return dispose; }; })(mountCodeTracerStory);`,
  },
  "agent-panel-loading-text": {
    // The same in an Agent Harbor panel, worded by the panel:
    // "Loading initiatives…".
    expect: "placeholder",
    story: "codetracer-agent-harbor--initiatives",
    code: `mountCodeTracerStory = (function (real) { return function (c, k, n, f) {
      const dispose = real(c, k, n, f);
      setTimeout(() => { c.innerHTML = '<div class="ah-initiatives"><div>Loading initiatives…</div></div>'; }, 300);
      return dispose; }; })(mountCodeTracerStory);`,
  },
  "loading-text-with-spinner": {
    // "Loading…" beside a spinner, as a loading state is usually drawn: the
    // spinner is part of the message, not content of the panel's own.
    expect: "placeholder",
    code: `mountCodeTracerStory = (function (real) { return function (c, k, n, f) {
      const dispose = real(c, k, n, f);
      setTimeout(() => { c.innerHTML = '<div class="calltrace-lines"><svg width="16" height="16" viewBox="0 0 16 16"><circle cx="8" cy="8" r="6" stroke="currentColor" stroke-width="2" fill="none"/></svg><div>Loading…</div></div>'; }, 300);
      return dispose; }; })(mountCodeTracerStory);`,
  },
  "loading-text-split-inline": {
    // The loading line's words split over an inline element: the text in the
    // span is part of the line, not content.
    expect: "placeholder",
    code: `mountCodeTracerStory = (function (real) { return function (c, k, n, f) {
      const dispose = real(c, k, n, f);
      setTimeout(() => { c.innerHTML = '<div class="calltrace-lines"><div>Loading <span>the call trace</span>…</div></div>'; }, 300);
      return dispose; }; })(mountCodeTracerStory);`,
  },
  "layout-panel-loading-with-spinner": {
    // One panel of a layout reduced to a spinner and "Loading…" while the
    // others show their data.
    expect: "placeholder",
    story: "codetracer-layouts--noir-filesystem-active",
    code: `mountCodeTracerStory = (function (real) { return function (c, k, n, f) {
      const dispose = real(c, k, n, f);
      const started = Date.now();
      const timer = setInterval(() => {
        const panel = [...document.querySelectorAll(".ct-storybook-panel-content")].find((p) =>
          /VARIABLES/i.test(p.closest(".lm_stack")?.querySelector(".lm_tab.lm_active .lm_title")?.textContent ?? ""));
        if (panel && !panel.querySelector(".planted-line")) {
          panel.innerHTML = '<div class="planted-line"><svg width="16" height="16"><circle cx="8" cy="8" r="6" stroke="currentColor" stroke-width="2" fill="none"/></svg><span>Loading…</span></div>';
        }
        if (Date.now() - started > 15000) clearInterval(timer);
      }, 100);
      return dispose; }; })(mountCodeTracerStory);`,
  },
  "unclassed-error-text": {
    // A data story showing only an error line, with no state class.
    expect: "placeholder",
    code: `mountCodeTracerStory = (function (real) { return function (c, k, n, f) {
      const dispose = real(c, k, n, f);
      setTimeout(() => { c.innerHTML = '<div class="calltrace-lines"><div>Failed to load the call trace</div></div>'; }, 300);
      return dispose; }; })(mountCodeTracerStory);`,
  },
  "empty-monaco-editor": {
    // The editor with an empty model: Monaco still draws the number "1" and
    // its margin, and that is still an empty panel.
    expect: "empty",
    story: "codetracer-panels--editor",
    code: `mountCodeTracerStory = (function (real) { return function (c, k, n, f) {
      const dispose = real(c, k, n, f);
      const t = setInterval(() => {
        const eds = window.monaco && window.monaco.editor.getEditors();
        if (eds && eds.length) { eds.forEach((e) => e.setValue("")); clearInterval(t); }
      }, 20);
      return dispose; }; })(mountCodeTracerStory);`,
  },
  "invisible-content": {
    // The content faded out by an ANCESTOR (its own opacity computes 1).
    expect: "empty",
    code: `mountCodeTracerStory = (function (real) { return function (c, k, n, f) {
      const dispose = real(c, k, n, f); c.style.opacity = "0"; return dispose; }; })(mountCodeTracerStory);`,
  },
  "deep-review-without-diff": {
    // The review's diff tab kept empty: whatever Monaco draws into its host
    // is taken away again before the next task (a MutationObserver runs as a
    // microtask, so the play never sees a drawn diff). Its file header still
    // reads `src/shield.nr`, so the panel is not empty by the rule above;
    // what fails it is the story's own play check, whose added-line
    // decorations and value chips never arrive.
    expect: "error",
    story: "codetracer-panels--deep-review",
    code: `mountCodeTracerStory = (function (real) { return function (c, k, n, f) {
      const dispose = real(c, k, n, f);
      new MutationObserver(() => {
        const h = document.getElementById("unifiedDiffEditor-story");
        if (h && h.firstChild) h.replaceChildren();
      }).observe(document.body, { childList: true, subtree: true });
      return dispose; }; })(mountCodeTracerStory);`,
  },
  "panel-inside-main": {
    // The panel mounted inside \`#main\` (its 1.25rem), where the harness
    // used to mount every panel; the app never puts one there.
    expect: "type-size",
    code: `mountCodeTracerStory = (function (real) { return function (c, k, n, f) {
      const dispose = real(c, k, n, f);
      const main = document.getElementById("main");
      const layout = c.closest(".lm_goldenlayout");
      if (main && layout) main.appendChild(layout);
      return dispose; }; })(mountCodeTracerStory);`,
  },
};
const SELF_TEST_STORY = "codetracer-panels--calltrace";

// --- Serving ------------------------------------------------------------------

const MIME = {
  ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript", ".css": "text/css",
  ".json": "application/json", ".svg": "image/svg+xml", ".png": "image/png", ".woff": "font/woff",
  ".woff2": "font/woff2", ".ttf": "font/ttf", ".otf": "font/otf", ".map": "application/json",
};

function serveStatic(dir) {
  const server = createServer((req, res) => {
    const path = decodeURIComponent(new URL(req.url, "http://localhost").pathname);
    let file = normalize(join(dir, path));
    if (!file.startsWith(dir)) {
      res.writeHead(403).end();
      return;
    }
    if (existsSync(file) && statSync(file).isDirectory()) file = join(file, "index.html");
    if (!existsSync(file)) {
      res.writeHead(404).end("not found");
      return;
    }
    res.writeHead(200, { "content-type": MIME[extname(file)] ?? "application/octet-stream" });
    res.end(readFileSync(file));
  });
  return new Promise((resolvePromise) => server.listen(0, "127.0.0.1", () => resolvePromise(server)));
}

// --- Rendering ------------------------------------------------------------------

async function renderStory(browser, baseUrl, story, theme, plant) {
  const page = await browser.newPage({ viewport: { width, height } });
  try {
    const { failures } = await renderAndJudge(page, baseUrl, story, theme, {
      timeoutMs: storyTimeoutMs,
      // Each plant is appended to the components bundle as the page loads it.
      beforeGoto: plant ? (p) => p.route("**/dist/components.js", async (route) => {
        const response = await route.fetch();
        const body = (await response.text()) + "\n;" + plant.code + "\n";
        await route.fulfill({ response, body });
      }) : undefined,
      afterInspect: shotsDir
        ? (p) => p.screenshot({ path: join(shotsDir, `${story.id}-${theme}.png`) })
        : undefined,
    });
    return failures;
  } finally {
    await page.close();
  }
}

async function runAll(browser, baseUrl, work) {
  const results = [];
  let next = 0;
  const worker = async () => {
    while (next < work.length) {
      const item = work[next++];
      const failures = await renderStory(browser, baseUrl, item.story, item.theme, item.plant);
      results.push({ ...item, failures });
      const tag = failures.length ? "FAIL" : "ok  ";
      console.log(`${tag} ${item.story.id} [${item.theme}]${item.plantName ? ` (planted: ${item.plantName})` : ""}`);
      for (const f of failures) console.log(`       ${f.category}: ${f.message}`);
    }
  };
  await Promise.all(Array.from({ length: Math.min(jobs, work.length) }, worker));
  return results;
}

async function main() {
  const index = JSON.parse(readFileSync(indexPath, "utf8"));
  const stories = index.stories.filter((s) => filters.length === 0 || filters.some((f) => s.id.includes(f)));
  if (stories.length === 0) {
    console.error("check-story-render: no story matches");
    process.exit(2);
  }

  let baseUrl = argValues("--url")[0];
  let server = null;
  if (!baseUrl) {
    const { requireFreshStorybookStatic } = await import(join(repoRoot, "tools/visual-review/storybook-freshness.mjs"));
    requireFreshStorybookStatic(repoRoot);
    server = await serveStatic(staticDir);
    baseUrl = `http://127.0.0.1:${server.address().port}`;
  }
  baseUrl = baseUrl.replace(/\/$/, "");
  if (shotsDir) mkdirSync(shotsDir, { recursive: true });

  const requireFromStorybook = createRequire(join(storybookDir, "package.json"));
  const { chromium } = requireFromStorybook("playwright");
  const browser = await chromium.launch({
    executablePath: process.env.CODETRACER_CAPTURE_CHROMIUM || undefined,
    args: ["--no-sandbox"],
  });

  let exitCode = 0;
  try {
    if (hasArg("--self-test")) {
      const byId = new Map(index.stories.map((s) => [s.id, s]));
      const work = [{ story: byId.get(SELF_TEST_STORY), theme: themes[0] }];
      for (const [plantName, plant] of Object.entries(PLANTS)) {
        work.push({ story: byId.get(plant.story ?? SELF_TEST_STORY), theme: themes[0], plant, plantName });
      }
      for (const item of work) {
        if (!item.story) throw new Error("self-test: a story it plants into is not declared");
      }
      const results = await runAll(browser, baseUrl, work);
      console.log("\nself-test:");
      for (const r of results) {
        if (!r.plant) {
          const ok = r.failures.length === 0;
          console.log(`  ${ok ? "ok  " : "FAIL"} control ${r.story.id} passes unplanted`);
          if (!ok) exitCode = 1;
          continue;
        }
        const caught = r.failures.some((f) => f.category === r.plant.expect);
        console.log(`  ${caught ? "ok  " : "FAIL"} planted ${r.plantName} -> ${r.plant.expect}` +
          (caught ? "" : ` (got: ${r.failures.map((f) => f.category).join(", ") || "nothing"})`));
        if (!caught) exitCode = 1;
      }
      console.log(exitCode === 0 ? "self-test passed" : "self-test FAILED: the check misses a failure it exists to catch");
    } else {
      const work = [];
      for (const story of stories) for (const theme of themes) work.push({ story, theme });
      const results = await runAll(browser, baseUrl, work);
      const failed = results.filter((r) => r.failures.length);
      const counts = {};
      for (const r of failed) for (const f of r.failures) counts[f.category] = (counts[f.category] ?? 0) + 1;
      console.log(`\n${stories.length} stories x ${themes.length} theme(s) at ${width}x${height}: ` +
        `${results.length - failed.length} rendered clean, ${failed.length} failed` +
        (failed.length ? ` (${Object.entries(counts).map(([k, v]) => `${k} ${v}`).join(", ")})` : ""));
      if (failed.length) exitCode = 1;
    }
  } finally {
    await browser.close();
    if (server) server.close();
  }
  process.exit(exitCode);
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch((error) => {
    console.error(`check-story-render: ${error.stack ?? error}`);
    process.exit(2);
  });
}
