#!/usr/bin/env node

import { createRequire } from "node:module";
import { existsSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";

const __dirname = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(__dirname, "../..");
const storybookDir = join(repoRoot, "storybook");
const staticDir = join(storybookDir, "storybook-static");
const outDir = join(repoRoot, "tools/visual-review/screenshots");
const reportDir = join(repoRoot, "tools/visual-review/reports");

const requireFromStorybook = createRequire(join(storybookDir, "package.json"));
const { chromium } = requireFromStorybook("playwright");

const views = {
  "terminal-output": {
    storyId: "codetracer-surfaces--panel-terminal-output",
    brief: "tools/visual-review/briefs/storybook-terminal-output.md",
  },
  build: {
    storyId: "codetracer-surfaces--panel-build",
    brief: "tools/visual-review/briefs/storybook-build-panel.md",
  },
  "default-layout": {
    storyId: "codetracer-surfaces--layout-standalone-app-shell",
    brief: "tools/visual-review/briefs/storybook-default-layout.md",
  },
};

const sizes = {
  wide: { width: 1920, height: 1080 },
  laptop: { width: 1440, height: 900 },
  tablet: { width: 1024, height: 768 },
  mobile: { width: 390, height: 844 },
};

function argValue(name) {
  const index = process.argv.indexOf(name);
  if (index === -1) return null;
  return process.argv[index + 1] ?? null;
}

function hasArg(name) {
  return process.argv.includes(name);
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
  return child;
}

async function waitForServer(port) {
  const url = `http://127.0.0.1:${port}/iframe.html`;
  for (let i = 0; i < 60; i++) {
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
  if (selected) {
    if (!map[selected]) {
      throw new Error(`Unknown selection "${selected}"`);
    }
    return [[selected, map[selected]]];
  }
  return Object.entries(map);
}

async function main() {
  const selectedView = argValue("--view");
  const selectedSize = argValue("--size");
  const noBuild = hasArg("--no-build");
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

  if (!selectedView && !selectedSize) {
    rmSync(outDir, { recursive: true, force: true });
    rmSync(reportDir, { recursive: true, force: true });
    mkdirSync(outDir, { recursive: true });
    mkdirSync(reportDir, { recursive: true });
  }

  if (!existsSync(staticDir)) {
    throw new Error("Missing storybook/storybook-static. Run without --no-build first.");
  }

  const server = startStaticServer(port);
  try {
    await waitForServer(port);
    const browser = await chromium.launch({
      executablePath: "/run/current-system/sw/bin/chromium",
      headless: true,
      args: ["--no-sandbox"],
    });

    const reports = [];
    for (const [viewName, view] of selectedEntries(views, selectedView)) {
      for (const [sizeName, viewport] of selectedEntries(sizes, selectedSize)) {
        const page = await browser.newPage({ viewport });
        const resourceErrors = [];
        page.on("response", (response) => {
          if (response.status() >= 400) {
            resourceErrors.push(`${response.status()} ${response.url()}`);
          }
        });
        page.on("console", (message) => {
          if (message.type() === "error") {
            resourceErrors.push(`console: ${message.text()}`);
          }
        });

        const url = `http://127.0.0.1:${port}/iframe.html?id=${view.storyId}&viewMode=story`;
        await page.goto(url, { waitUntil: "networkidle" });
        await page.waitForTimeout(750);

        const captureId = `${viewName}-${sizeName}`;
        const screenshotPath = join(outDir, `${captureId}.png`);
        await page.screenshot({ path: screenshotPath, fullPage: true });

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
            document.querySelector(".isonim-app-shell") ||
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

        const report = {
          captureId,
          view: viewName,
          size: sizeName,
          storyId: view.storyId,
          brief: view.brief,
          screenshotPath,
          url,
          viewport,
          resourceErrors,
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
  } finally {
    server.kill();
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
