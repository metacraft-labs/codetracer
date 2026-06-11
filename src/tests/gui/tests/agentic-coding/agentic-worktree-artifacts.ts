import * as fs from "node:fs";
import * as path from "node:path";

import type { Page, TestInfo } from "@playwright/test";

type ArtifactSource = {
  name: string;
  path?: string;
};

function safeName(value: string): string {
  return value.replace(/[^a-zA-Z0-9._-]+/g, "_").replace(/^_+|_+$/g, "");
}

export class AgenticWorktreeArtifacts {
  readonly dir: string;
  private readonly consoleLines: string[] = [];

  constructor(testInfo: TestInfo) {
    const baseDir = path.join(
      process.cwd(),
      "test-results",
      "agentic-worktree",
    );
    const retrySuffix = testInfo.retry > 0 ? `-retry${testInfo.retry}` : "";
    this.dir = path.join(baseDir, `${safeName(testInfo.title)}${retrySuffix}`);
    fs.mkdirSync(this.dir, { recursive: true });
  }

  collectConsole(page: Page): void {
    page.on("console", (message) => {
      this.consoleLines.push(
        `[${new Date().toISOString()}] [${message.type()}] ${message.text()}`,
      );
    });
    page.on("pageerror", (error) => {
      this.consoleLines.push(
        `[${new Date().toISOString()}] [pageerror] ${error.message}\n${error.stack ?? ""}`,
      );
    });
  }

  writeJson(name: string, value: unknown): void {
    fs.writeFileSync(
      path.join(this.dir, `${safeName(name)}.json`),
      JSON.stringify(value, null, 2),
      "utf-8",
    );
  }

  async screenshot(
    page: Page,
    name: string,
    testInfo: TestInfo,
  ): Promise<void> {
    const screenshotPath = path.join(this.dir, `${safeName(name)}.png`);
    await page.screenshot({ path: screenshotPath, fullPage: true });
    await testInfo.attach(path.basename(screenshotPath), {
      path: screenshotPath,
      contentType: "image/png",
    });
  }

  async flush(
    testInfo: TestInfo,
    extraSources: ArtifactSource[] = [],
  ): Promise<void> {
    const consolePath = path.join(this.dir, "console.log");
    fs.writeFileSync(consolePath, this.consoleLines.join("\n") + "\n", "utf-8");
    await testInfo.attach("console.log", {
      path: consolePath,
      contentType: "text/plain",
    });

    const sources: ArtifactSource[] = [
      { name: "agent-harbor.log", path: process.env.AGENT_HARBOR_LOG_PATH },
      {
        name: "codetracer-host.log",
        path: process.env.CODETRACER_TEST_CT_HOST_OUTPUT_PATH,
      },
      {
        name: "codetracer-console.log",
        path: process.env.CODETRACER_TEST_CONSOLE_DUMP_PATH,
      },
      ...extraSources,
    ];

    for (const source of sources) {
      if (!source.path || !fs.existsSync(source.path)) continue;
      const target = path.join(this.dir, safeName(source.name));
      fs.copyFileSync(source.path, target);
      await testInfo.attach(path.basename(target), {
        path: target,
        contentType: "text/plain",
      });
    }

    const manifestPath = path.join(this.dir, "manifest.json");
    fs.writeFileSync(
      manifestPath,
      JSON.stringify(
        {
          artifactDir: this.dir,
          createdAt: new Date().toISOString(),
          files: fs.readdirSync(this.dir).sort(),
        },
        null,
        2,
      ),
      "utf-8",
    );
    await testInfo.attach("artifact-manifest.json", {
      path: manifestPath,
      contentType: "application/json",
    });
  }
}
