#!/usr/bin/env node

import { createRequire } from "node:module";
import { createHash } from "node:crypto";
import { accessSync, constants as fsConstants, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";

import { requireFreshStorybookStatic } from "./storybook-freshness.mjs";
// When a story has rendered, and whether what it rendered is a story: the
// render check's own definition (`just storybook-check-render`), not a
// second one. A capture is taken only after that readiness and only of a
// story its judge passes; a story it fails is REFUSED, its image not written.
import { loadStoryDeclarations, renderAndJudge } from "../../storybook/scripts/story-render-judge.mjs";
import { readVerdicts, writeVerdicts } from "./capture-verdicts.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(__dirname, "../..");
const storybookDir = join(repoRoot, "storybook");
const staticDir = join(storybookDir, "storybook-static");
// `--out <dir>` redirects the images (e.g. a prototype's capture matrix under
// tools/visual-review/out/); reports and dumps stay where they always are.
const outDirArg = process.argv.indexOf("--out");
const outDir = outDirArg >= 0 && process.argv[outDirArg + 1]
  ? resolve(process.argv[outDirArg + 1])
  : join(repoRoot, "tools/visual-review/screenshots");
const reportDir = join(repoRoot, "tools/visual-review/reports");
const dumpDir = join(repoRoot, "tools/visual-review/dumps");

const requireFromStorybook = createRequire(join(storybookDir, "package.json"));
const { chromium } = requireFromStorybook("playwright");

const views = {
  "terminal-output": {
    storyId: "codetracer-panels--terminal-output",
    brief: "tools/visual-review/briefs/storybook-terminal-output.md",
  },
  build: {
    storyId: "codetracer-panels--build",
    brief: "tools/visual-review/briefs/storybook-build-panel.md",
  },
  "agent-activity-deepreview": {
    storyId: "codetracer-panels--agent-activity-deep-review",
    brief: "tools/visual-review/project-visual-brief.md",
  },
  deepreview: {
    storyId: "codetracer-panels--deep-review",
    brief: "tools/visual-review/project-visual-brief.md",
  },
  status: {
    storyId: "codetracer-components--status-shell",
    brief: "tools/visual-review/project-visual-brief.md",
  },
  "default-layout": {
    storyId: "codetracer-layouts--default-debug",
    brief: "tools/visual-review/briefs/storybook-default-layout.md",
  },
};

// CodeTracer as an Agent Harbor front-end. Each named view is captured at the
// sizes the design brief names and in both colour themes; the brief's "What
// is Expected on the Screenshot" block of the same name says what each image
// must show. The `agent-harbor-ref-*` views are the existing CodeTracer
// panels the new ones are reviewed against.
// The brief itself is private; the public stub says so, and
// CODETRACER_AGENT_HARBOR_BRIEF names the private one where a reviewer has it.
const agentHarborBrief = process.env.CODETRACER_AGENT_HARBOR_BRIEF ?? "tools/visual-review/briefs/agent-harbor-front-end.md";
const agentHarborSizes = ["panel", "sidebar", "laptop"];
const agentHarborThemes = ["dark", "light"];
const agentHarborViews = {
  "agent-harbor-fleet-snapshot": "codetracer-agent-harbor--fleet-snapshot",
  "agent-harbor-fleet-needs-input": "codetracer-agent-harbor--fleet-needs-input",
  "agent-harbor-fleet-failed": "codetracer-agent-harbor--fleet-failed",
  "agent-harbor-fleet-selected": "codetracer-agent-harbor--fleet-selected",
  "agent-harbor-fleet-loading": "codetracer-agent-harbor--fleet-loading",
  "agent-harbor-fleet-error": "codetracer-agent-harbor--fleet-error",
  "agent-harbor-fleet-empty": "codetracer-agent-harbor--fleet-empty",
  "agent-harbor-fleet-expanded": "codetracer-agent-harbor--fleet-expanded",
  "agent-harbor-fleet-filtered-empty": "codetracer-agent-harbor--fleet-filtered-empty",
  "agent-harbor-ref-agent-activity": "codetracer-panels--agent-activity",
  "agent-harbor-ref-test-results": "codetracer-panels--test-results",
  "agent-harbor-ref-vcs": "codetracer-panels--vcs",
  "agent-harbor-ref-session-tabs": "codetracer-views--session-tabs",
  "agent-harbor-ref-status-shell": "codetracer-views--status-shell",
};
// The sessions as tabs (in the caption bar, as a sidebar, docked), the
// Initiatives and Initiative Progress panels: one view per story of the Agent
// Harbor section, named after its export (`SessionTabsSingleLine` ->
// `agent-harbor-session-tabs-single-line`), all in the family
// `agent-harbor-session-tabs`.
const kebab = (name) => name.replace(/([a-z0-9])([A-Z])/g, "$1-$2").toLowerCase();
const sessionTabsExports = [
  "InitiativeTabs",
  "InitiativeTabsPopup",
  "InitiativeTabsPopupOverPanel",
  "InitiativeTabsElsewhere",
  "InitiativeTabsNext",
  "InitiativeTabsAutoSwitch",
  "InitiativeTabsRecordingsMany",
  "InitiativeTabsOverflow",
  "InitiativeTabsLongNames",
  "InitiativeTabsRealPlans",
  "InitiativeTabsEmpty",
  "InitiativeTabsLoading",
  "InitiativeTabsError",
  "SessionListSidebarTreeFolded",
  "SessionTabsSingleLine",
  "SessionTabsActiveOverflowed",
  "SessionTabsMultiLine",
  "SessionTabsSingleLineOverflow",
  "SessionTabsMultiLineOverflow",
  "SessionTabsLongNames",
  "SessionTabsNeedsInputWins",
  "SessionTabsFocusedInitiative",
  "SessionTabsEmpty",
  "SessionTabsLoading",
  "SessionTabsError",
  "SessionListSidebar",
  "SessionListSidebarUngrouped",
  "SessionListSidebarCollapsed",
  "SessionListSidebarOverflow",
  "SessionListDocked",
  "SessionListDockedOverflow",
  "SessionListEmpty",
  "SessionListLoading",
  "SessionListError",
  "Initiatives",
  "InitiativesSelected",
  "InitiativesOverflow",
  "InitiativesLongNames",
  "InitiativesRealPlans",
  "InitiativesEmpty",
  "InitiativesLoading",
  "InitiativesError",
  "InitiativeProgress",
  "InitiativeProgressBlocked",
  "InitiativeProgressEvent",
  "InitiativeProgressLongNames",
  "InitiativeProgressNoSummary",
  "InitiativeProgressRealPlan",
  "InitiativeProgressUnknown",
  "InitiativeProgressLoading",
  "InitiativeProgressError",
];
for (const name of sessionTabsExports) {
  agentHarborViews[`agent-harbor-${kebab(name)}`] = `codetracer-agent-harbor--${kebab(name)}`;
}
for (const [name, storyId] of Object.entries(agentHarborViews)) {
  views[name] = { storyId, brief: agentHarborBrief, sizes: agentHarborSizes, themes: agentHarborThemes };
}
// `--view agent-harbor-fleet` (or any prefix ending in a view family) selects
// every view of that family, e.g. `--view agent-harbor-ref` for the
// reference panels.
const viewFamilies = {
  "agent-harbor": Object.keys(agentHarborViews),
  "agent-harbor-fleet": Object.keys(agentHarborViews).filter((v) => v.startsWith("agent-harbor-fleet-")),
  "agent-harbor-ref": Object.keys(agentHarborViews).filter((v) => v.startsWith("agent-harbor-ref-")),
  "agent-harbor-session-tabs": sessionTabsExports.map((name) => `agent-harbor-${kebab(name)}`),
};

// The colour themes, as the StoryBook `theme` global (.storybook/preview.js)
// names them. A view that declares no `themes` is captured in dark only and
// keeps its historical file name.
const themes = ["dark", "light"];

// Chromium: an explicit override, the system browser where one is installed
// at the NixOS path, then whatever is on PATH, else Playwright's own build.
function chromiumExecutable() {
  const candidates = [
    process.env.CODETRACER_CAPTURE_CHROMIUM,
    "/run/current-system/sw/bin/chromium",
    ...(process.env.PATH ?? "").split(":").flatMap((dir) => [join(dir, "chromium"), join(dir, "chromium-browser")]),
  ].filter(Boolean);
  for (const candidate of candidates) {
    try {
      accessSync(candidate, fsConstants.X_OK);
      return candidate;
    } catch {
      // try the next one
    }
  }
  return undefined;
}

function slugify(value) {
  return value
    .toLowerCase()
    .replace(/&/g, " and ")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
}

const sizes = {
  wide: { width: 1920, height: 1080 },
  laptop: { width: 1440, height: 900 },
  tablet: { width: 1024, height: 768 },
  mobile: { width: 390, height: 844 },
  // A docked panel in CodeTracer's default layout, and a narrow side panel.
  panel: { width: 760, height: 640 },
  sidebar: { width: 360, height: 900 },
};

function argValue(name) {
  const index = process.argv.indexOf(name);
  if (index === -1) return null;
  return process.argv[index + 1] ?? null;
}

function argValues(name) {
  const values = [];
  for (let i = 0; i < process.argv.length; i++) {
    if (process.argv[i] === name && process.argv[i + 1]) {
      values.push(process.argv[i + 1]);
      i++;
    }
  }
  return values;
}

function hasArg(name) {
  return process.argv.includes(name);
}

function loadStorybookViews() {
  const indexPath = join(staticDir, "index.json");
  if (!existsSync(indexPath)) return {};

  const index = JSON.parse(readFileSync(indexPath, "utf8"));
  const entries = Object.values(index.entries ?? {});
  const discovered = {};
  for (const entry of entries) {
    if (entry.type !== "story" || !entry.title?.startsWith("CodeTracer/")) continue;

    const group = entry.title.slice("CodeTracer/".length);
    const groupSlug = slugify(group);
    const nameSlug = slugify(entry.name);
    const keys = [
      nameSlug,
      `${groupSlug}-${nameSlug}`,
      entry.id,
    ];

    for (const key of keys) {
      if (!key || discovered[key] || views[key]) continue;
      discovered[key] = {
        storyId: entry.id,
        brief: views[nameSlug]?.brief ?? "tools/visual-review/project-visual-brief.md",
      };
    }
  }
  return discovered;
}

function printViewList(map) {
  for (const [name, view] of Object.entries(map).sort(([a], [b]) => a.localeCompare(b))) {
    console.log(`${name}\t${view.storyId}\t${view.brief}`);
  }
}

function run(command, args, options = {}) {
  return new Promise((resolvePromise, reject) => {
    const child = spawn(command, args, {
      cwd: repoRoot,
      stdio: "inherit",
      ...options,
    });
    child.on("exit", (code) => {
      if (code === 0) resolvePromise();
      else reject(new Error(`${command} ${args.join(" ")} exited ${code}`));
    });
  });
}

function startStaticServer(port) {
  const child = spawn("python3", [
    "-m",
    "http.server",
    String(port),
    "--bind",
    "127.0.0.1",
  ], {
    cwd: staticDir,
    stdio: ["ignore", "pipe", "pipe"],
  });
  child.stderrText = "";
  child.stderr.on("data", (chunk) => {
    child.stderrText += chunk.toString();
  });
  return child;
}

async function waitForServer(port, child) {
  const url = `http://127.0.0.1:${port}/iframe.html`;
  for (let i = 0; i < 60; i++) {
    if (child.exitCode !== null) {
      throw new Error(
        `Static server exited before startup on port ${port}: ${child.stderrText.trim()}`,
      );
    }
    try {
      const response = await fetch(url);
      if (response.ok) return;
    } catch {
      // keep waiting
    }
    await new Promise((resolveWait) => setTimeout(resolveWait, 250));
  }
  throw new Error(`Timed out waiting for ${url}`);
}

function selectedEntries(map, selected) {
  if (Array.isArray(selected) && selected.length > 0) {
    return selected.map((name) => {
      if (!map[name]) {
        throw new Error(`Unknown selection "${name}"`);
      }
      return [name, map[name]];
    });
  }
  if (typeof selected === "string" && selected) {
    if (!map[selected]) {
      throw new Error(`Unknown selection "${selected}"`);
    }
    return [[selected, map[selected]]];
  }
  return Object.entries(map);
}

async function main() {
  const selectedViews = [
    ...argValues("--view"),
    ...argValues("--views").flatMap((value) =>
      value.split(",").map((item) => item.trim()).filter(Boolean),
    ),
  ];
  const selectedSize = argValue("--size");
  const selectedThemes = argValues("--theme");
  for (const theme of selectedThemes) {
    if (!themes.includes(theme)) throw new Error(`Unknown theme "${theme}" (known: ${themes.join(", ")})`);
  }
  const noBuild = hasArg("--no-build");
  // `--font-render-hinting <none|slight|medium|full>`: Chromium's own switch
  // for how the text rasteriser hints glyphs on Linux. Unset, the browser's
  // default applies (headless Chromium on Linux hints fully, which rounds
  // the advances of small text -- 11 to 13px -- to whole, often wider,
  // pixels); `none` sets text at the face's own advances, as a browser on
  // macOS does and as GPUI's text system does.
  const fontRenderHinting = argValue("--font-render-hinting");
  if (fontRenderHinting && !["none", "slight", "medium", "full"].includes(fontRenderHinting)) {
    throw new Error(`--font-render-hinting: unknown value "${fontRenderHinting}"`);
  }
  const regionsArg = argValue("--regions");
  const regionsDeclaration = regionsArg ? JSON.parse(readFileSync(resolve(regionsArg), "utf8")) : null;
  if (regionsDeclaration && !Array.isArray(regionsDeclaration.regions)) {
    throw new Error(`${regionsArg}: no "regions" array`);
  }
  const listViews = hasArg("--list-views");
  const port = Number(argValue("--port") ?? "6106");

  if (!noBuild) {
    if (existsSync(join(storybookDir, "storybook-static"))) {
      await run("chmod", ["-R", "u+w", join(storybookDir, "storybook-static")]);
    }
    await run("nix", [
      "shell",
      "nixpkgs#nodejs",
      "--command",
      "bash",
      "-lc",
      "just storybook-build",
    ]);
  }

  mkdirSync(outDir, { recursive: true });
  mkdirSync(reportDir, { recursive: true });
  mkdirSync(dumpDir, { recursive: true });

  if (!listViews && selectedViews.length === 0 && !selectedSize) {
    rmSync(outDir, { recursive: true, force: true });
    rmSync(reportDir, { recursive: true, force: true });
    rmSync(dumpDir, { recursive: true, force: true });
    mkdirSync(outDir, { recursive: true });
    mkdirSync(reportDir, { recursive: true });
    mkdirSync(dumpDir, { recursive: true });
  }

  // EXISTENCE IS NOT FRESHNESS: this replaced an `existsSync(staticDir)` whose
  // own message ("Run without --no-build first") named the condition it could
  // not detect. See tools/visual-review/storybook-freshness.mjs.
  requireFreshStorybookStatic(repoRoot);

  const allViews = {
    ...loadStorybookViews(),
    ...views,
  };

  if (listViews) {
    printViewList(allViews);
    return;
  }

  const expandedViews = selectedViews.flatMap((name) => viewFamilies[name] ?? [name]);
  // The declarations say what each story is meant to show (data, or a
  // declared empty / loading / error state): the judge needs them.
  const declarations = new Map(loadStoryDeclarations(repoRoot).stories.map((story) => [story.id, story]));
  // Each written image's verdict, kept beside the images
  // (`capture-verdicts.json`, VERDICTS_FILE; check-storybook-captures.mjs reads it).
  const verdicts = readVerdicts(outDir);
  const refused = [];

  const server = startStaticServer(port);
  try {
    await waitForServer(port, server);
    const browser = await chromium.launch({
      executablePath: chromiumExecutable(),
      headless: true,
      args: ["--no-sandbox", ...(fontRenderHinting ? [`--font-render-hinting=${fontRenderHinting}`] : [])],
    });

    const reports = [];
    for (const [viewName, view] of selectedEntries(allViews, expandedViews)) {
      const viewSizes = selectedSize
        ? [[selectedSize, sizes[selectedSize]]]
        : view.sizes
          ? view.sizes.map((name) => [name, sizes[name]])
          : Object.entries(sizes);
      if (selectedSize && !sizes[selectedSize]) throw new Error(`Unknown size "${selectedSize}"`);
      const viewThemes = selectedThemes.length > 0
        ? selectedThemes
        : view.themes ?? ["dark"];
      for (const [sizeName, viewport] of viewSizes)
      for (const theme of viewThemes) {
        const captureId = view.themes || theme !== "dark"
          ? `${viewName}-${sizeName}-${theme}`
          : `${viewName}-${sizeName}`;
        const screenshotPath = join(outDir, `${captureId}.png`);
        const story = declarations.get(view.storyId);
        if (!story) {
          throw new Error(`${captureId}: story ${view.storyId} is not declared in storybook/stories/generated/stories.json (run just storybook-stories)`);
        }
        const page = await browser.newPage({ viewport });
        const url = `http://127.0.0.1:${port}/iframe.html?id=${view.storyId}&viewMode=story&globals=theme:${theme}`;
        // The render check's readiness (StoryBook's render event after the
        // play check, no pending mount, network and DOM quiet twice) and its
        // verdict. Until 2026-11-06 this waited only for some visible text
        // and 750 ms, and shot panels whose data had not arrived: empty
        // panels and windows that the render check, waiting for the story,
        // passed.
        const { observed, failures } = await renderAndJudge(page, `http://127.0.0.1:${port}`, story, theme);
        if (failures.length > 0) {
          await page.close();
          // No image of a story the judge fails, and none left behind from an
          // earlier run under the same name: the directory then shows that
          // the capture is missing, and the PNG check fails on it.
          rmSync(screenshotPath, { force: true });
          verdicts[basename(screenshotPath)] = {
            storyId: view.storyId, size: sizeName, theme, viewport, verdict: "refused",
            failures, judgedAt: new Date().toISOString(),
          };
          refused.push({ captureId, failures });
          console.error(`REFUSED ${captureId} (${view.storyId}): the render check's judge fails it`);
          for (const f of failures) console.error(`       ${f.category}: ${f.message}`);
          continue;
        }
        const resourceErrors = [];
        const navigationWarnings = [];

        // The image must be set in the design system's faces, not in a
        // fallback: a story whose fonts 404 renders in the browser's default
        // serif and is then reviewed as if that were the design. Wait for the
        // font loads the page started, then refuse the capture if no
        // design-system face loaded or the story's text resolves to a serif.
        // Every text-bearing leaf of the story is checked, not a sample: each
        // design-system face the story's text names first must itself have
        // loaded (one face loading does not vouch for another), and no text
        // may name a serif first.
        const fontCheck = await page.evaluate(async () => {
          await document.fonts.ready;
          const designFaces = ["SpaceGrotesk", "SpaceMono", "FiraMono"];
          const loaded = [...new Set([...document.fonts]
            .filter((f) => f.status === "loaded")
            .map((f) => f.family.replace(/["']/g, "")))];
          const root = document.querySelector("#storybook-root") ?? document.body;
          const used = new Set();
          for (const el of root.querySelectorAll("*")) {
            const fieldText = el.matches("input,textarea") ? (el.value || el.placeholder || "").trim() : "";
            if (!fieldText && (el.childElementCount !== 0 || !el.textContent.trim())) continue;
            used.add(getComputedStyle(el).fontFamily.split(",")[0].replace(/["']/g, "").trim());
          }
          const usedFamilies = [...used];
          // `fonts.ready` only covers loads the page has STARTED; on a busy
          // host the story's text can lay out after it resolved. Ask for each
          // design face the text names, so the verdict is about the face
          // itself: a face whose files 404 still ends up not loaded.
          for (const f of usedFamilies.filter((f) => designFaces.includes(f))) {
            try {
              for (const face of await document.fonts.load(`16px "${f}"`)) {
                if (face.status === "loaded" && !loaded.includes(f)) loaded.push(f);
              }
            } catch {
              // a failed load leaves the face unloaded, which is the finding
            }
          }
          const unloaded = usedFamilies.filter((f) => designFaces.includes(f) && !loaded.includes(f));
          const serif = usedFamilies.filter((f) => f === "" || /^(serif|times|times new roman)$/i.test(f));
          return { loaded, usedFamilies, unloaded, serif };
        });
        if (fontCheck.usedFamilies.length === 0 || fontCheck.unloaded.length > 0 || fontCheck.serif.length > 0) {
          throw new Error(
            `${viewName} at ${sizeName}: the design-system fonts did not load (loaded: ${fontCheck.loaded.join(", ") || "none"}; ` +
              `story text uses ${fontCheck.usedFamilies.join(", ") || "nothing"}; not loaded: ${fontCheck.unloaded.join(", ") || "-"}; ` +
              `serif: ${fontCheck.serif.join(", ") || "-"}). Font files 404 when StoryBook does not serve the ` +
              "design-system directory (storybook/.storybook/main.ts staticDirs).",
          );
        }

        // The window must WEAR the theme it is labelled with: the app's
        // `#theme` stylesheet must be the requested build, or the image is a
        // dark capture named light (tools/visual-review/capture-deepreview-views.mjs
        // `assertTheme` makes the same refusal for the app window).
        const themeHref = await page.evaluate(() => document.getElementById("theme")?.getAttribute("href") ?? "");
        const wantedSheet = theme === "light" ? "default_white_theme_electron.css" : "default_dark_theme_electron.css";
        if (!themeHref.endsWith(wantedSheet)) {
          throw new Error(`${captureId}: theme '${theme}' requested but #theme is '${themeHref}'`);
        }
        await page.screenshot({ path: screenshotPath, fullPage: true });
        // The verdict the image was written under, and where the story drew
        // its content, so the image itself can be checked afterwards
        // (tools/visual-review/check-storybook-captures.mjs): it must be these bytes,
        // and it must show something inside each content box.
        verdicts[basename(screenshotPath)] = {
          storyId: view.storyId, size: sizeName, theme, viewport, verdict: "pass",
          kind: observed.page.kind, state: story.state ?? "data",
          contentBoxes: observed.page.contentBoxes,
          sha256: createHash("sha256").update(readFileSync(screenshotPath)).digest("hex"),
          judgedAt: new Date().toISOString(),
        };
        // `--regions <declaration>`: where the browser laid out each declared
        // region of the story (src/tests/visual/agent-harbor-regions.json),
        // written beside the image as `<capture id>.regions.json`. The GPUI
        // story window writes the same file from GPUI's own layout, and the
        // CTF-P1b layout test compares the two. A region is the first VISIBLE
        // match of its selector (an element with no area, or hidden, is left
        // out, as the GPUI side leaves out an element laid out with none), or,
        // for `"pick": "last-whole"`, the last visible match drawn whole --
        // its bottom edge inside the viewport (the last row of a list the
        // window shows entirely; a row cut by the window's edge can show
        // nothing but its background). A picked region also records its `index` among the
        // visible matches, so the layout test can tell that both sides picked
        // the same row and not two different rows that happen to sit near the
        // bottom of their windows.
        if (regionsDeclaration) {
          const regions = await page.evaluate((declared) => {
            const out = {};
            for (const region of declared) {
              const visible = [];
              for (const element of document.querySelectorAll(region.web)) {
                const rect = element.getBoundingClientRect();
                const style = getComputedStyle(element);
                if (rect.width <= 0 || rect.height <= 0 || style.visibility === "hidden" || style.display === "none") continue;
                visible.push({ element, rect });
              }
              let chosen = visible.length > 0 ? 0 : -1;
              if (region.pick === "last-whole") {
                chosen = -1;
                visible.forEach(({ rect }, i) => {
                  if (rect.y + rect.height <= window.innerHeight) chosen = i;
                });
              }
              if (chosen >= 0) {
                const { element, rect } = visible[chosen];
                out[region.name] = { x: rect.x, y: rect.y, w: rect.width, h: rect.height };
                if (region.pick) out[region.name].index = chosen;
                // A `fill` region also records the colour the browser
                // composites behind the element: its own background over
                // its ancestors', each `rgba()` blended over the one below
                // (https://www.w3.org/TR/compositing-1/#simplealphacompositing),
                // down to the page's opaque white.
                if (region.fill) {
                  const layers = [];
                  for (let e = element; e; e = e.parentElement) layers.push(getComputedStyle(e).backgroundColor);
                  let rgb = [255, 255, 255];
                  for (const layer of layers.reverse()) {
                    const m = layer.match(/rgba?\(([^)]+)\)/);
                    if (!m) continue;
                    const [r, g, b, a = 1] = m[1].split(",").map((v) => Number(v.trim()));
                    rgb = [r, g, b].map((c, i) => Math.round(c * a + rgb[i] * (1 - a)));
                  }
                  out[region.name].fill = `#${rgb.map((c) => c.toString(16).padStart(2, "0")).join("")}`;
                }
              }
            }
            return out;
          }, regionsDeclaration.regions.map(({ name, web, fill, pick }) => ({ name, web, fill: Boolean(fill), pick })));
          writeFileSync(
            join(outDir, `${captureId}.regions.json`),
            `${JSON.stringify({ renderer: "web", story: view.storyId, theme, viewport, regions }, null, 2)}\n`,
          );
        }
        const htmlPath = join(dumpDir, `${captureId}.html`);
        writeFileSync(htmlPath, await page.content());

        const diagnostics = await page.evaluate(() => {
          const stylesheets = [...document.querySelectorAll("link[rel=stylesheet]")].map((link) => {
            let rules = null;
            let ok = true;
            let error = "";
            try {
              rules = link.sheet ? link.sheet.cssRules.length : null;
            } catch (err) {
              ok = false;
              error = err.message;
            }
            return { href: link.href, ok, rules, error };
          });
          const root = document.querySelector("#ROOT");
          const panel =
            document.querySelector(".component-container") ||
            document.querySelector(".build-panel") ||
            document.querySelector(".ct-storybook-panel-content > *") ||
            document.querySelector(".isonim-app-shell") ||
            document.querySelector("#status-base") ||
            document.querySelector("#status") ||
            document.querySelector(".ct-storybook-frame > *") ||
            document.body;
          const panelStyle = getComputedStyle(panel);
          const rootStyle = root ? getComputedStyle(root) : null;
          const main = document.querySelector("#main");
          const boxFor = (element) => {
            if (!element) return null;
            const rect = element.getBoundingClientRect();
            return {
              x: rect.x,
              y: rect.y,
              width: rect.width,
              height: rect.height,
            };
          };
          return {
            title: document.title,
            hasRoot: Boolean(root),
            bodyClass: document.body.className,
            panelClass: panel.className,
            panelColor: panelStyle.color,
            panelBackground: panelStyle.backgroundColor,
            panelFont: panelStyle.fontFamily,
            rootBackground: rootStyle ? rootStyle.backgroundColor : null,
            mainBox: boxFor(main),
            panelBox: boxFor(panel),
            stylesheets,
          };
        });

        const computedStylePath = join(dumpDir, `${captureId}.computed-styles.json`);
        const computedStyles = await page.evaluate(() => {
          const styleProps = [
            "display",
            "visibility",
            "position",
            "box-sizing",
            "left",
            "top",
            "right",
            "bottom",
            "width",
            "height",
            "min-width",
            "min-height",
            "max-width",
            "max-height",
            "margin",
            "padding",
            "border",
            "border-radius",
            "background-color",
            "background-image",
            "color",
            "font-family",
            "font-size",
            "font-weight",
            "line-height",
            "overflow",
            "overflow-x",
            "overflow-y",
            "flex",
            "flex-direction",
            "align-items",
            "justify-content",
            "grid-template-columns",
            "grid-template-rows",
            "gap",
            "z-index",
            "opacity",
            "transform",
          ];

          function cssPath(element) {
            const parts = [];
            let current = element;
            while (current && current.nodeType === Node.ELEMENT_NODE) {
              let part = current.tagName.toLowerCase();
              if (current.id) part += `#${current.id}`;
              if (current.className && typeof current.className === "string") {
                const classes = current.className
                  .trim()
                  .split(/\s+/)
                  .filter(Boolean)
                  .slice(0, 4)
                  .join(".");
                if (classes) part += `.${classes}`;
              }
              parts.unshift(part);
              current = current.parentElement;
            }
            return parts.join(" > ");
          }

          const interestingSelectors = [
            "body",
            "#root-container",
            "#auto-hide-layout-row",
            "#ROOT",
            "#main",
            "#status",
            "#status-base",
            ".lm_goldenlayout",
            ".lm_row",
            ".lm_column",
            ".lm_stack",
            ".lm_header",
            ".lm_tabs",
            ".lm_tab",
            ".lm_active",
            ".lm_controls",
            ".lm_content",
            ".ct-storybook-panel-content",
            ".component-container",
            ".terminal",
            ".isonim-terminal-output",
            ".terminal-line",
            ".active",
            ".past",
            ".future",
            ".build-panel",
            ".build-header",
            ".build-command-label",
            ".build-header-controls",
            ".build-output-container",
            ".build-stdout",
            ".build-stderr",
            ".build-clickable",
            ".build-line-error",
            ".build-line-warning",
            ".filesystem-container",
            ".jstree",
            ".jstree-container-ul",
            ".jstree-node",
            ".jstree-anchor",
            ".jstree-icon",
            ".jstree-wholerow",
            ".filesystem-entry-row",
            ".filesystem-entry",
            ".filesystem-entry-icon",
            ".filesystem-entry-name",
            ".calltrace-view",
            ".calltrace-search",
            ".calltrace-search-input",
            ".local-calltrace-view",
            ".local-calltrace",
            ".calltrace-lines",
            ".calltrace-svg-line",
            ".calltrace-call-line",
            ".calltrace-child",
            ".call-child-box",
            ".call-current",
            ".toggle-call",
            ".collapse-call-img",
            ".dot-call-img",
            ".call-text",
            ".call-args",
            ".call-arg",
            ".call-arg-name",
            ".call-arg-text",
            ".return",
            ".return-arrow",
            ".return-text",
            ".calltrace-line",
            ".calltrace-name",
            ".calltrace-args",
            ".eventLog",
            ".eventLog-cell",
            ".eventLog-dense-table",
            ".dataTable",
            ".data-tables-footer",
            ".scratchpad",
            ".scratchpad-table",
            ".editor",
            ".code-editor",
            ".monaco-editor",
            ".overflow-guard",
            ".margin",
            ".margin-view-overlays",
            ".gutter",
            ".gutter-line",
            ".monaco-scrollable-element",
            ".lines-content",
            ".view-lines",
            ".view-line",
            ".line-numbers",
            ".folding",
            ".current-line",
            ".selected-text",
            ".scrollbar",
            ".slider",
            ".local-calltrace-view",
            ".local-calltrace",
            ".calltrace-search-input",
            "#fixed-search",
            ".fixed-search-query-field",
            ".fixed-search-include-field",
            ".fixed-search-exclude-field",
            ".search-component",
            ".search-mode-selector",
            ".search-input-row",
            ".search-query-input",
            ".search-result-row",
            ".search-results-header",
            ".search-results-find-query",
            ".search-results-body",
            ".search-results-file-group",
            ".search-results-match-row",
            ".search-results-highlight",
            ".command-container",
            ".command-view",
            ".command-input-row",
            ".command-input-field",
            ".command-input-placeholder",
            ".command-results",
            ".command-result",
            ".command-selected",
            ".low-level-code",
            ".flow-component",
            ".isonim-flow",
            ".timeline-component",
            ".isonim-timeline",
            ".point-list-component",
            ".isonim-point-list",
            ".request-panel",
            ".vcs-container",
            ".traceLog",
            ".trace-log",
            ".trace-log-table-header",
            ".trace-log-table-body",
            ".trace-log-row",
            ".event-rr-ticks-line",
            ".ct-header",
            ".isonim-debug-controls",
            ".debug-controls",
            ".debug-button-svg",
            ".session-tab-bar",
            ".session-tab",
            "#auto-hide-bottom-strip",
            ".auto-hide-strip-tab",
            ".auto-hide-collapsed-icon",
            ".auto-hide-overlay-tab",
            ".isonim-app-shell",
            ".isonim-panel-section",
            ".isonim-section-content",
          ];

          const seen = new Set();
          const elements = [];
          for (const selector of interestingSelectors) {
            for (const element of document.querySelectorAll(selector)) {
              if (seen.has(element)) continue;
              seen.add(element);
              const rect = element.getBoundingClientRect();
              const computed = window.getComputedStyle(element);
              const styles = {};
              for (const prop of styleProps) styles[prop] = computed.getPropertyValue(prop);
              elements.push({
                index: elements.length,
                selector,
                path: cssPath(element),
                tag: element.tagName.toLowerCase(),
                id: element.id || null,
                className: typeof element.className === "string" ? element.className : "",
                text: (element.textContent || "").trim().replace(/\s+/g, " ").slice(0, 250),
                rect: {
                  x: rect.x,
                  y: rect.y,
                  width: rect.width,
                  height: rect.height,
                },
                styles,
              });
            }
          }

          return {
            url: location.href,
            title: document.title,
            viewport: {
              width: window.innerWidth,
              height: window.innerHeight,
              devicePixelRatio: window.devicePixelRatio,
            },
            capturedAt: new Date().toISOString(),
            elementCount: document.querySelectorAll("*").length,
            capturedElementCount: elements.length,
            elements,
          };
        });
        writeFileSync(computedStylePath, JSON.stringify(computedStyles, null, 2));

        const report = {
          captureId,
          view: viewName,
          size: sizeName,
          theme,
          storyId: view.storyId,
          brief: view.brief,
          screenshotPath,
          htmlPath,
          computedStylePath,
          url,
          viewport,
          resourceErrors,
          navigationWarnings,
          diagnostics,
        };
        const reportPath = join(reportDir, `${captureId}.json`);
        writeFileSync(reportPath, JSON.stringify(report, null, 2));
        reports.push(reportPath);
        await page.close();
      }
    }

    await browser.close();
    console.log(reports.join("\n"));
    if (refused.length > 0) {
      console.error(`\n${refused.length} capture(s) REFUSED: the render check's judge fails their story:`);
      for (const r of refused) console.error(`  ${r.captureId}: ${r.failures.map((f) => f.category).join(", ")}`);
      process.exitCode = 1;
    }
  } finally {
    server.kill();
    // Also when a later capture throws (a font or theme refusal): the
    // images already written keep their verdicts.
    writeVerdicts(outDir, verdicts);
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
