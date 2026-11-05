#!/usr/bin/env node
// The smoke check of the IsoNim Editor instance over CodeTracer's stories,
// run by `just isonim-editor-codetracer --smoke` against an instance it
// started (scripts/isonim-editor-codetracer.sh).
//
// In a real headless Chromium, through the editor's own UI and route
// parameters, it checks that:
//   1. the editor lists every story the declaration has for the Agent Harbor
//      group, and only those (the sidebar rows against stories.json, which
//      `just storybook-stories` writes from the same declaration);
//   2. the fleet-snapshot story renders in the preview frame what its
//      StoryBook play check asserts (lib/plays.js), styled by CodeTracer's
//      own stylesheets and design-system fonts;
//   3. an existing CodeTracer story renders likewise: the terminal output
//      panel's "Populated" story and the default debugging layout;
//   4. a story the declaration does not have renders nothing (the checks
//      above could not pass on an editor that rendered something for any
//      name);
//   5. the preview a reviewer comments on (Comment mode) is drawn at its own
//      size and is, pixel for pixel, StoryBook's render of the same story at
//      that size, with the same text styles and faces (StoryBook's static
//      build, served to the browser by request interception);
//   6. design review reaches an agent: the Spec pane shows the Agent Harbor
//      brief when the private brief is present; a comment left in Comment
//      mode on a fleet row, then a prompt sent from the AI panel, arrive at
//      the agent session together (the session's peer is IsoNim's
//      deterministic test agent, which records what it receives; it is the
//      only substitute, and it replaces the language model, not a transport),
//      with the story, the project's instructions for review comments and,
//      when the private brief is present, its path in the agent's
//      environment.
// Exit 0 when every check passes, 1 otherwise. Screenshots and the browser's
// console go to --out.
//
//   node tools/isonim-editor/smoke.mjs --url <origin> --out <dir>
//     --stories <stories.json> --agent-log <jsonl> --storybook-static <dir>
//     [--private-brief <path>]

import { createRequire } from "node:module";
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { extname, join, normalize, sep } from "node:path";

const require = createRequire(import.meta.url);
// Playwright comes from the dev shell's NODE_PATH, as for the visual-review
// tools; ESM `import` does not search NODE_PATH, so it is required.
const { chromium } = require("playwright");

function arg(name, fallback = undefined) {
  const at = process.argv.indexOf(`--${name}`);
  if (at >= 0 && at + 1 < process.argv.length) return process.argv[at + 1];
  if (fallback === undefined) throw new Error(`missing --${name}`);
  return fallback;
}

const origin = arg("url").replace(/\/$/, "");
const outDir = arg("out");
const stories = JSON.parse(readFileSync(arg("stories"), "utf8")).stories;
const agentLog = arg("agent-log");
const privateBrief = arg("private-brief", "");
const storybookStatic = arg("storybook-static");

const results = [];
function check(name, ok, detail = "") {
  results.push({ name, ok: !!ok, detail });
  console.log(`${ok ? "PASS" : "FAIL"} ${name}${detail ? ` — ${detail}` : ""}`);
}

function storyUrl(group, name) {
  // The story's position in its group is part of its identity (a brief
  // covers `<group>/<name>:component#<index>`), as a sidebar click sets it.
  const index = Math.max(0, stories.filter((s) => s.editorGroup === group).findIndex((s) => s.name === name));
  const q = new URLSearchParams({ view: "detail", storyGroup: group, story: name, kind: "component", index: String(index) });
  return `${origin}/?${q}`;
}

// In View mode the story is in the detail view's frame; Comment and Edit
// mode move it to the edit view's (isonim views/component_edit).
const frameSelector = 'iframe[title^="Component preview"], iframe[title="Editable component preview"]';

async function frameDocument(page, predicate, arg, timeout = 90000) {
  // Wait until the visible project frame's document satisfies `predicate`.
  return page.waitForFunction(
    ([selector, source, value]) => {
      const fn = new Function("doc", "arg", `return (${source})(doc, arg);`);
      for (const frame of document.querySelectorAll(selector)) {
        if (frame.offsetParent === null) continue;
        const doc = frame.contentDocument;
        if (doc && doc.body && fn(doc, value)) return true;
      }
      return false;
    },
    [frameSelector, predicate.toString(), arg],
    { timeout, polling: 250 },
  );
}

async function inFrame(page, fn, value) {
  return page.evaluate(
    ([selector, source, v]) => {
      const run = new Function("doc", "arg", `return (${source})(doc, arg);`);
      for (const frame of document.querySelectorAll(selector)) {
        if (frame.offsetParent === null) continue;
        if (frame.contentDocument?.body) return run(frame.contentDocument, v);
      }
      return null;
    },
    [frameSelector, fn.toString(), value],
  );
}

async function shoot(page, name) {
  const frame = page.locator(frameSelector).filter({ visible: true }).first();
  try {
    await frame.screenshot({ path: join(outDir, `${name}.png`) });
  } catch {
    await page.screenshot({ path: join(outDir, `${name}.png`) });
  }
}

function agentRecords() {
  if (!existsSync(agentLog)) return [];
  return readFileSync(agentLog, "utf8").trim().split("\n").filter(Boolean).map((line) => JSON.parse(line));
}

// StoryBook's static build, served to the browser under its own origin by
// request interception (no second server to start and stop).
const storybookOrigin = "http://storybook.smoke.invalid";
const contentTypes = { ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript",
  ".css": "text/css", ".json": "application/json", ".svg": "image/svg+xml", ".png": "image/png",
  ".woff": "font/woff", ".woff2": "font/woff2", ".ttf": "font/ttf", ".otf": "font/otf" };
async function serveStorybook(context) {
  const root = normalize(storybookStatic) + sep;
  await context.route(`${storybookOrigin}/**`, async (route) => {
    const path = normalize(join(root, decodeURIComponent(new URL(route.request().url()).pathname)));
    if (!path.startsWith(root) || !existsSync(path)) return route.fulfill({ status: 404, body: "" });
    return route.fulfill({ status: 200, body: readFileSync(path),
      contentType: contentTypes[extname(path).toLowerCase()] ?? "application/octet-stream" });
  });
}

// The fraction of pixels whose largest channel difference exceeds `tolerance`
// (0-255) between two PNGs, decoded by the browser itself; 1 when their sizes
// differ.
async function pixelDifference(page, a, b, tolerance) {
  return page.evaluate(async ([a, b, tolerance]) => {
    const load = async (b64) => { const img = new Image(); img.src = "data:image/png;base64," + b64; await img.decode(); return img; };
    const [x, y] = [await load(a), await load(b)];
    if (x.naturalWidth !== y.naturalWidth || x.naturalHeight !== y.naturalHeight) {
      return { fraction: 1, size: [[x.naturalWidth, x.naturalHeight], [y.naturalWidth, y.naturalHeight]] };
    }
    const pixels = (img) => { const c = document.createElement("canvas"); c.width = img.naturalWidth; c.height = img.naturalHeight;
      const g = c.getContext("2d"); g.drawImage(img, 0, 0); return g.getImageData(0, 0, c.width, c.height).data; };
    const [p, q] = [pixels(x), pixels(y)];
    let differing = 0;
    for (let i = 0; i < p.length; i += 4) {
      if (Math.max(Math.abs(p[i] - q[i]), Math.abs(p[i + 1] - q[i + 1]), Math.abs(p[i + 2] - q[i + 2])) > tolerance) differing++;
    }
    return { fraction: differing / (p.length / 4), size: [[x.naturalWidth, x.naturalHeight]] };
  }, [a.toString("base64"), b.toString("base64"), tolerance]);
}

// What the text of a story looks like in a document: the font, size and
// spacing of every fleet text element, and the design-system faces loaded.
function textStyles(doc) {
  const sel = ".ah-fleet-source, .ah-fleet-filter, .ah-fleet-row-title, .ah-fleet-status-label, .ah-fleet-activity-line";
  const styles = [...doc.querySelectorAll(sel)].slice(0, 40).map((el) => {
    const cs = doc.defaultView.getComputedStyle(el);
    return [cs.fontFamily, cs.fontSize, cs.letterSpacing, cs.wordSpacing, cs.fontWeight, cs.fontStyle].join("|");
  });
  const faces = [...doc.fonts].filter((f) => f.status === "loaded").map((f) => f.family.replace(/["']/g, ""));
  return { styles, faces: [...new Set(faces)].sort() };
}

async function main() {
  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({ viewport: { width: 1600, height: 1000 } });
  await serveStorybook(context);
  const page = await context.newPage();
  const consoleLines = [];
  page.on("console", (msg) => consoleLines.push(`[${msg.type()}] ${msg.text()}`));
  page.on("pageerror", (error) => consoleLines.push(`[pageerror] ${error.message}`));

  try {
    // 1 + 2: the fleet-snapshot story.
    const harbor = stories.filter((s) => s.editorGroup === "Agent Harbor");
    check("the declaration has Agent Harbor stories", harbor.length >= 7, `${harbor.length}`);
    const snapshot = harbor.find((s) => s.fixture === "snapshot");
    await page.goto(storyUrl("Agent Harbor", snapshot.name), { waitUntil: "domcontentloaded" });
    await page.locator(`[data-story-row="Agent Harbor/${snapshot.name}"]`).waitFor({ timeout: 60000 });
    const rows = await page.$$eval("[data-story-row]", (els) => els.map((e) => e.getAttribute("data-story-row")));
    const listed = rows.filter((r) => r.startsWith("Agent Harbor/")).sort();
    const declared = harbor.map((s) => `Agent Harbor/${s.name}`).sort();
    check("the sidebar lists exactly the declared Agent Harbor stories",
      JSON.stringify(listed) === JSON.stringify(declared), `listed ${listed.length}, declared ${declared.length}`);
    const groups = [...new Set(stories.map((s) => s.editorGroup))];
    const groupsShown = await page.evaluate((names) => names.filter((n) => document.body.innerText.includes(n)), groups);
    check("the sidebar shows every declared story group", groupsShown.length === groups.length,
      `${groupsShown.length}/${groups.length}`);

    await frameDocument(page, (doc) => doc.querySelectorAll(".agent-harbor-fleet .ah-fleet-row").length > 0);
    const fleet = await inFrame(page, (doc) => {
      const rows = [...doc.querySelectorAll(".ah-fleet-row")];
      const title = doc.querySelector(".ah-fleet-row-title");
      const theme = doc.getElementById("theme");
      let themeRules = 0;
      try { themeRules = theme?.sheet?.cssRules?.length ?? 0; } catch { themeRules = -1; }
      return {
        rows: rows.length,
        filters: doc.querySelectorAll(".ah-fleet-filter").length,
        active: doc.querySelector(".ah-fleet-filter-active")?.textContent ?? "",
        firstNeedsInput: rows[0]?.classList.contains("ah-fleet-cat-needs-input") ?? false,
        firstStatus: rows[0]?.querySelector(".ah-fleet-status-label")?.textContent ?? "",
        distinctTitles: new Set(rows.map((r) => r.querySelector(".ah-fleet-row-title")?.textContent)).size,
        source: doc.querySelector(".ah-fleet-source")?.textContent ?? "",
        font: title ? getComputedStyle(title).fontFamily : "",
        themeRules,
        spaceGrotesk: [...doc.fonts].some((f) => /space\s*grotesk/i.test(f.family) && f.status === "loaded"),
      };
    });
    check("fleet snapshot: more than 40 session rows", fleet.rows > 40, `${fleet.rows}`);
    check("fleet snapshot: six filters, All active", fleet.filters === 6 && fleet.active.includes("All"),
      `${fleet.filters} filters, active "${fleet.active}"`);
    check("fleet snapshot: sessions waiting for a person first, labelled needs input",
      fleet.firstNeedsInput && /^needs input/.test(fleet.firstStatus), fleet.firstStatus);
    check("fleet snapshot: rows can be told apart", fleet.distinctTitles > fleet.rows / 2,
      `${fleet.distinctTitles} distinct titles`);
    check("fleet snapshot: the header names the snapshot", /fleet.*UTC/.test(fleet.source), fleet.source);
    check("fleet snapshot: CodeTracer's theme stylesheet applied", fleet.themeRules > 100, `${fleet.themeRules} rules`);
    check("fleet snapshot: design-system face, not a serif fallback",
      fleet.spaceGrotesk && !/^\s*(serif|"?times)/i.test(fleet.font), fleet.font);
    await shoot(page, "fleet-snapshot");

    // 3: existing CodeTracer stories.
    const terminal = stories.find((s) => s.editorGroup === "Compatibility / Terminal Output" && s.fixture === "demo");
    await page.goto(storyUrl(terminal.editorGroup, terminal.name), { waitUntil: "domcontentloaded" });
    await frameDocument(page, (doc) => doc.querySelectorAll(".isonim-terminal-output .terminal-line").length > 0);
    const term = await inFrame(page, (doc) => ({
      panel: !!doc.querySelector(".isonim-terminal-output"),
      lines: doc.querySelectorAll(".terminal-line").length,
      active: [...doc.querySelectorAll(".active")].map((e) => e.textContent.trim()).join(" | "),
      golden: !!doc.querySelector(".lm_goldenlayout"),
    }));
    check("terminal output (existing story): the panel with its three lines in a golden-layout host",
      term.panel && term.lines === 3 && term.golden, `${term.lines} lines`);
    check("terminal output (existing story): the active tab names noir-space-ship",
      term.active.includes("noir-space-ship"), term.active.trim());
    await shoot(page, "terminal-output-populated");

    const layout = stories.find((s) => s.kind === "layout" && s.surface === "default-debug" && s.fixture === "populated");
    await page.goto(storyUrl(layout.editorGroup, layout.name), { waitUntil: "domcontentloaded" });
    await frameDocument(page, (doc) => doc.querySelectorAll(".lm_goldenlayout .lm_item").length > 3);
    const debug = await inFrame(page, (doc) => ({
      items: doc.querySelectorAll(".lm_goldenlayout .lm_item").length,
      header: !!doc.querySelector("#debug"),
      bodyClass: doc.body.classList.contains("monaco-workbench"),
    }));
    check("default debugging layout (existing story): the reference shell with its panels, in the frame's own document",
      debug.items > 3 && debug.header && debug.bodyClass, `${debug.items} layout items`);
    await shoot(page, "default-debug");

    // 4: a story the declaration does not have is neither listed nor
    // rendered. The editor ignores an unknown route story; whatever a frame
    // shows must be a declared surface and fixture.
    await page.goto(storyUrl("Agent Harbor", "No Such Story"), { waitUntil: "domcontentloaded" });
    await page.locator("[data-story-row]").first().waitFor({ timeout: 60000 });
    await page.waitForTimeout(3000);
    const ghostRow = await page.locator('[data-story-row="Agent Harbor/No Such Story"]').count();
    const shown = await page.evaluate((selector) =>
      [...document.querySelectorAll(selector)].map((f) => f.contentDocument?.body?.getAttribute("data-codetracer-story"))
        .filter(Boolean), frameSelector);
    const declaredPairs = new Set(stories.map((s) => `${s.surface}/${s.fixture}`));
    check("an undeclared story is not listed, and no frame renders anything undeclared",
      ghostRow === 0 && shown.every((pair) => declaredPairs.has(pair)), `frames show ${JSON.stringify(shown)}`);

    // 5 + 6: design review, on the needs-input story (the snapshot under its
    // filter: real rows, a dozen of them). Not on the full snapshot: the
    // editor's control bridge resends the whole element tree on every poll
    // (8.9 MB for the full snapshot's 6,000 elements), which keeps its main
    // thread too busy for reliable interaction; recorded as an IsoNim issue
    // (isonim-pm issues, 2026-11-04, editor control poll payload).
    const reviewed = harbor.find((s) => s.fixture === "needs-input");
    await page.goto(storyUrl("Agent Harbor", reviewed.name), { waitUntil: "domcontentloaded" });
    await frameDocument(page, (doc) => doc.querySelectorAll(".ah-fleet-row").length > 0);
    if (privateBrief) {
      await page.locator('[data-preview-mode="spec"]').first().click();
      // The brief's own first heading, read from the private file (this
      // public script names none of its text).
      const heading = (readFileSync(privateBrief, "utf8").match(/^#\s+(.+)$/m) ?? [])[1]?.trim() ?? "";
      const specShown = heading.length > 0 && await page.waitForFunction((text) =>
        document.body.innerText.includes(text), heading, { timeout: 30000 })
        .then(() => true, () => false);
      check("Spec mode shows the Agent Harbor design brief", specShown);
      await page.screenshot({ path: join(outDir, "spec-brief.png") });
    } else {
      check("Spec mode (skipped: no private brief in this workspace)", true);
    }

    // Comment mode is surface-aware: on the Spec surface it comments on the
    // brief's text. Back to the preview first, then comment on an element.
    await page.locator('[data-preview-mode="view"]').first().click();
    await frameDocument(page, (doc) => doc.querySelectorAll(".ah-fleet-row").length > 0);
    await page.locator('[data-preview-mode="comment"]').first().click();
    await frameDocument(page, (doc) => doc.querySelectorAll(".ah-fleet-row").length > 0 && !!doc.getElementById("isonim-editor-selection-style"), undefined, 60000)
      .catch(() => {});

    // The preview a reviewer comments on is StoryBook's render of the story.
    // The same story in StoryBook's own preview frame (its static build, the
    // same components bundle and stylesheets), at the size the editor's frame
    // is drawn at on screen, compared pixel by pixel with that frame. Same
    // browser, fonts and size, so the two should be identical but for
    // anti-aliasing: a pixel counts as different when a channel differs by
    // more than 48 of 255, and at most 0.5% may. A frame drawn at another
    // size (the editor scaling a wider viewport down to fit its column)
    // differs everywhere, and so does text in another face or spacing.
    await page.mouse.move(0, 0);
    await page.waitForTimeout(500);
    const editorFrame = page.locator(frameSelector).filter({ visible: true }).first();
    const box = await editorFrame.boundingBox();
    const layoutWidth = await editorFrame.evaluate((f) => f.clientWidth);
    const editorShot = await editorFrame.screenshot({ path: join(outDir, "compare-editor.png") });
    const editorText = await inFrame(page, textStyles);
    const sbPage = await context.newPage();
    await sbPage.setViewportSize({ width: Math.round(box.width), height: Math.round(box.height) });
    await sbPage.goto(`${storybookOrigin}/iframe.html?id=${encodeURIComponent(reviewed.id)}&viewMode=story`,
      { waitUntil: "domcontentloaded" });
    await sbPage.waitForFunction(() => document.querySelectorAll(".ah-fleet-row").length > 0, null, { timeout: 90000 });
    await sbPage.evaluate(() => document.fonts.ready);
    await sbPage.waitForTimeout(500);
    const sbShot = await sbPage.screenshot({ path: join(outDir, "compare-storybook.png") });
    const sbText = await sbPage.evaluate(`(${textStyles.toString()})(document)`);
    await sbPage.close();
    const diff = await pixelDifference(page, editorShot, sbShot, 48);
    check("the editor draws the preview at its own size (not scaled to fit)",
      Math.round(box.width) === layoutWidth, `laid out ${layoutWidth} px wide, drawn ${Math.round(box.width)} px`);
    check("the editor's preview matches StoryBook's render of the same story at the same size",
      diff.fraction <= 0.005, `${(diff.fraction * 100).toFixed(2)}% of pixels differ, sizes ${JSON.stringify(diff.size)}`);
    check("the preview's text has StoryBook's font, size and spacing, and the same faces loaded",
      editorText.styles.length > 0 && JSON.stringify(editorText) === JSON.stringify(sbText),
      `${editorText.styles.length} text elements, faces ${editorText.faces.join(",")} vs ${sbText.faces.join(",")}`);
    const annotation = `SMOKE-ANNOTATION-${Date.now()}: the first row's status mark is too faint against the selection`;
    // The project frame that shows the story (several frames stay mounted).
    const frameHandle = await page.evaluateHandle((selector) =>
      [...document.querySelectorAll(selector)].find((f) => f.offsetParent !== null &&
        f.contentDocument?.querySelector(".ah-fleet-row")), frameSelector);
    const frame = await frameHandle.asElement().contentFrame();
    await frame.locator(".ah-fleet-row").first().click();
    const commentBox = frame.locator('textarea[aria-label="Comment on selected element"]');
    await commentBox.waitFor({ state: "visible", timeout: 30000 });
    await commentBox.fill(annotation);
    await frame.locator("#isonim-editor-comment-popup button", { hasText: "Add" }).click();
    const marker = await frame.locator('[data-isonim-review-comment="open"]').count();
    check("Comment mode: the comment is placed on the story", marker >= 1, `${marker} marker(s)`);
    await page.screenshot({ path: join(outDir, "comment-mode.png") });

    const promptText = "Record the review comment in this story's design brief and act on it.";
    const input = page.locator("textarea[aria-label='Agent prompt']");
    await input.waitFor({ state: "visible", timeout: 30000 });
    await input.fill(promptText);
    // The prompt goes to /api/agent/prompts once a session exists; a refused
    // session (/api/agent/sessions answering an error) means it never does,
    // so either answer ends the wait and the check names which one it was.
    const delivered = page.waitForResponse((r) => {
      const path = new URL(r.url()).pathname;
      return r.request().method() === "POST" &&
        (path === "/api/agent/prompts" || (path === "/api/agent/sessions" && r.status() >= 400));
    }, { timeout: 120000 });
    await page.locator("[aria-label='Send agent prompt']").click();
    const response = await delivered;
    const route = new URL(response.url()).pathname;
    let refusal = "";
    if (route !== "/api/agent/prompts") refusal = await response.text().catch(() => "");
    check("the prompt is admitted by the editor's agent route",
      route === "/api/agent/prompts" && response.status() === 200,
      `${route} HTTP ${response.status()}${refusal ? ` ${refusal.slice(0, 200)}` : ""}`);
    const replied = await page.waitForFunction(() => document.body.innerText.includes("CODETRACER_EDITOR_SMOKE_REPLY"),
      null, { timeout: 120000 }).then(() => true, () => false);
    check("the agent session answers in the AI panel", replied);
    await page.screenshot({ path: join(outDir, "agent-reply.png") });

    const prompts = agentRecords().filter((r) => r.source === "fake_acp");
    const last = prompts.at(-1)?.promptText ?? "";
    check("the agent received the operator's prompt", last.includes(promptText));
    check("the agent received the review comment", last.includes(annotation.split(":")[0]));
    check("the agent received the commented story", last.includes(reviewed.name) && last.includes("Agent Harbor"));
    check("the agent received the project's instructions for review comments",
      last.includes("PROJECT CONTEXT:") && last.includes("CODETRACER_AGENT_HARBOR_BRIEF"));
    if (privateBrief) {
      // The agent's own environment, read from the running peer process.
      // The host may be running other smokes' agents at the same time, so
      // this run's agent is recognised by the content log this run handed
      // it (FAKE_ACP_CONTENT_LOG is --agent-log, inherited through the
      // editor server). A process whose environment cannot be read (it
      // exited after `ps` listed it, or belongs to another user) is not
      // this run's agent and is skipped rather than failing the check.
      const marker = `FAKE_ACP_CONTENT_LOG=${agentLog}`;
      const agentEnvs = [];
      let detail = "";
      try {
        const ps = execFileSync("ps", ["-eo", "pid=,args="], { encoding: "utf8" });
        for (const line of ps.split("\n")) {
          const m = line.match(/^\s*(\d+)\s+(\S*fake-acp-agent)(\s|$)/);
          if (!m) continue;
          let vars;
          try {
            vars = readFileSync(`/proc/${m[1]}/environ`, "utf8").split("\0");
          } catch {
            continue;
          }
          if (vars.includes(marker)) agentEnvs.push(vars);
        }
        if (agentEnvs.length === 0) detail = `no running fake-acp-agent carries ${marker}`;
      } catch (error) {
        detail = `ps failed: ${error.message}`;
      }
      check("the agent's environment names the private brief",
        agentEnvs.length > 0 &&
          agentEnvs.every((vars) => vars.includes(`CODETRACER_AGENT_HARBOR_BRIEF=${privateBrief}`)),
        detail);
    }
  } catch (error) {
    check("smoke run completed", false, error.stack ?? String(error));
    await page.screenshot({ path: join(outDir, "failure.png") }).catch(() => {});
  } finally {
    writeFileSync(join(outDir, "browser-console.log"), consoleLines.join("\n") + "\n");
    writeFileSync(join(outDir, "results.json"), JSON.stringify(results, null, 2) + "\n");
    await browser.close();
  }
  const failed = results.filter((r) => !r.ok);
  console.log(`${results.length - failed.length}/${results.length} checks passed`);
  process.exit(failed.length === 0 ? 0 : 1);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
