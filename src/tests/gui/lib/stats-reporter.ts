import * as fs from "node:fs";
import * as path from "node:path";
import type {
  Reporter,
  FullConfig,
  Suite,
  TestCase,
  TestResult,
  FullResult,
} from "@playwright/test/reporter";

/**
 * Playwright reporter that writes per-test timing data to timestamped
 * JSONL files under test-stats/YYYY/MM/.
 *
 * Each test run produces one file. Each line is either:
 *   { type: "test", ... }   — one per test
 *   { type: "run", ... }    — final summary
 *
 * Designed to accumulate data across runs so external tools can
 * compute statistics, detect regressions, and identify flaky tests.
 */
class StatsReporter implements Reporter {
  private outputPath: string = "";
  private lines: string[] = [];

  onBegin(_config: FullConfig, _suite: Suite): void {
    const now = new Date();
    const yyyy = now.getFullYear().toString();
    const mm = (now.getMonth() + 1).toString().padStart(2, "0");
    const timestamp = now
      .toISOString()
      .replace(/:/g, "-")
      .replace(/\.\d+Z$/, "");

    const dir = path.join(
      process.cwd(),
      "test-stats",
      yyyy,
      mm,
    );

    try {
      fs.mkdirSync(dir, { recursive: true });
    } catch {
      // Directory may already exist.
    }

    this.outputPath = path.join(dir, `${timestamp}.jsonl`);
    this.lines = [];
  }

  onTestEnd(test: TestCase, result: TestResult): void {
    const record = {
      type: "test",
      project: test.parent?.project()?.name ?? "",
      suite: test.parent?.title ?? "",
      title: test.title,
      file: path.relative(process.cwd(), test.location.file),
      status: result.status,
      duration: result.duration,
      retry: result.retry,
      timeout: test.timeout,
    };
    this.lines.push(JSON.stringify(record));
  }

  onEnd(result: FullResult): void {
    const summary = {
      type: "run",
      status: result.status,
      duration: result.duration,
    };
    this.lines.push(JSON.stringify(summary));

    if (this.outputPath && this.lines.length > 0) {
      try {
        fs.writeFileSync(this.outputPath, this.lines.join("\n") + "\n", "utf-8");
      } catch {
        // Silently ignore write failures to avoid masking test results.
      }
    }
  }

  printsToStdio(): boolean {
    return false;
  }
}

export default StatsReporter;
