#!/usr/bin/env node

/**
 * Analyze accumulated test timing stats from test-stats/ JSONL files.
 *
 * Usage:
 *   node scripts/analyze-stats.mjs              # Latest run summary + top 10 slowest
 *   node scripts/analyze-stats.mjs --slowest    # Slowest tests across all runs (median)
 *   node scripts/analyze-stats.mjs --flaky      # Tests with inconsistent pass/fail
 *   node scripts/analyze-stats.mjs --trend PAT  # Duration trend for matching tests
 *   node scripts/analyze-stats.mjs --runs N     # Show last N runs (default: 10)
 */

import fs from "node:fs";
import path from "node:path";

const STATS_DIR = path.join(process.cwd(), "test-stats");

// ── Helpers ──────────────────────────────────────────────────────────

function findJsonlFiles(dir) {
  const files = [];
  if (!fs.existsSync(dir)) return files;
  for (const year of fs.readdirSync(dir).sort()) {
    const yearPath = path.join(dir, year);
    if (!fs.statSync(yearPath).isDirectory()) continue;
    for (const month of fs.readdirSync(yearPath).sort()) {
      const monthPath = path.join(yearPath, month);
      if (!fs.statSync(monthPath).isDirectory()) continue;
      for (const file of fs.readdirSync(monthPath).sort()) {
        if (file.endsWith(".jsonl")) {
          files.push(path.join(monthPath, file));
        }
      }
    }
  }
  return files;
}

function parseRun(filePath) {
  const content = fs.readFileSync(filePath, "utf-8").trim();
  if (!content) return null;
  const lines = content.split("\n").map((l) => JSON.parse(l));
  const tests = lines.filter((l) => l.type === "test");
  const summary = lines.find((l) => l.type === "run");
  const timestamp = path.basename(filePath, ".jsonl");
  return { timestamp, filePath, tests, summary };
}

function formatDuration(ms) {
  if (ms < 1000) return `${ms}ms`;
  if (ms < 60_000) return `${(ms / 1000).toFixed(1)}s`;
  const min = Math.floor(ms / 60_000);
  const sec = ((ms % 60_000) / 1000).toFixed(0);
  return `${min}m${sec}s`;
}

function median(arr) {
  if (arr.length === 0) return 0;
  const sorted = [...arr].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
}

function p95(arr) {
  if (arr.length === 0) return 0;
  const sorted = [...arr].sort((a, b) => a - b);
  return sorted[Math.floor(sorted.length * 0.95)];
}

function testKey(t) {
  return `${t.file}::${t.suite}::${t.title}`;
}

function pad(s, n) {
  return String(s).padEnd(n);
}

function rpad(s, n) {
  return String(s).padStart(n);
}

// ── Commands ─────────────────────────────────────────────────────────

function showLatest(runs) {
  const run = runs[runs.length - 1];
  if (!run) {
    console.log("No stats data found. Run tests first.");
    return;
  }

  console.log(`\nLatest run: ${run.timestamp}`);
  if (run.summary) {
    console.log(
      `  Status: ${run.summary.status}  Duration: ${formatDuration(run.summary.duration)}`,
    );
  }

  const passed = run.tests.filter((t) => t.status === "passed").length;
  const failed = run.tests.filter((t) => t.status === "failed").length;
  const timedOut = run.tests.filter((t) => t.status === "timedOut").length;
  const skipped = run.tests.filter((t) => t.status === "skipped").length;
  console.log(
    `  Tests: ${run.tests.length} total, ${passed} passed, ${failed} failed, ${timedOut} timed out, ${skipped} skipped`,
  );

  const sorted = [...run.tests]
    .filter((t) => t.status !== "skipped")
    .sort((a, b) => b.duration - a.duration);
  const top = sorted.slice(0, 10);

  if (top.length > 0) {
    console.log(`\n  Top ${top.length} slowest tests:`);
    console.log(
      `  ${pad("Duration", 10)} ${pad("Status", 10)} ${pad("Timeout", 10)} Test`,
    );
    console.log(`  ${"─".repeat(70)}`);
    for (const t of top) {
      const pct = t.timeout > 0 ? ` (${Math.round((t.duration / t.timeout) * 100)}%)` : "";
      console.log(
        `  ${pad(formatDuration(t.duration), 10)} ${pad(t.status, 10)} ${pad(formatDuration(t.timeout) + pct, 18)} ${t.suite} > ${t.title}`,
      );
    }
  }

  // Show tests that used > 70% of their timeout
  const nearTimeout = sorted.filter(
    (t) => t.timeout > 0 && t.duration / t.timeout > 0.7,
  );
  if (nearTimeout.length > 0) {
    console.log(`\n  Tests near their timeout (>70%):`);
    for (const t of nearTimeout) {
      const pct = Math.round((t.duration / t.timeout) * 100);
      console.log(
        `  ${pad(formatDuration(t.duration), 10)} / ${pad(formatDuration(t.timeout), 8)} (${pct}%)  ${t.suite} > ${t.title}`,
      );
    }
  }

  console.log();
}

function showSlowest(runs) {
  const durationsMap = new Map();
  for (const run of runs) {
    for (const t of run.tests) {
      if (t.status === "skipped") continue;
      const key = testKey(t);
      if (!durationsMap.has(key)) {
        durationsMap.set(key, {
          suite: t.suite,
          title: t.title,
          file: t.file,
          durations: [],
        });
      }
      durationsMap.get(key).durations.push(t.duration);
    }
  }

  const entries = [...durationsMap.values()]
    .map((e) => ({
      ...e,
      median: median(e.durations),
      p95: p95(e.durations),
      runs: e.durations.length,
    }))
    .sort((a, b) => b.median - a.median)
    .slice(0, 20);

  console.log(`\nSlowest tests across ${runs.length} runs (by median duration):\n`);
  console.log(
    `  ${pad("Median", 10)} ${pad("P95", 10)} ${pad("Runs", 6)} Test`,
  );
  console.log(`  ${"─".repeat(70)}`);
  for (const e of entries) {
    console.log(
      `  ${pad(formatDuration(e.median), 10)} ${pad(formatDuration(e.p95), 10)} ${rpad(e.runs, 4)}   ${e.suite} > ${e.title}`,
    );
  }
  console.log();
}

function showFlaky(runs) {
  const statusMap = new Map();
  for (const run of runs) {
    for (const t of run.tests) {
      if (t.status === "skipped") continue;
      const key = testKey(t);
      if (!statusMap.has(key)) {
        statusMap.set(key, {
          suite: t.suite,
          title: t.title,
          statuses: [],
        });
      }
      statusMap.get(key).statuses.push(t.status);
    }
  }

  const flaky = [...statusMap.values()]
    .filter((e) => {
      const unique = new Set(e.statuses);
      return unique.size > 1 && e.statuses.length > 1;
    })
    .map((e) => {
      const passed = e.statuses.filter((s) => s === "passed").length;
      const total = e.statuses.length;
      return { ...e, passRate: passed / total, total };
    })
    .sort((a, b) => a.passRate - b.passRate);

  if (flaky.length === 0) {
    console.log("\nNo flaky tests detected across runs.\n");
    return;
  }

  console.log(`\nFlaky tests (inconsistent results across ${runs.length} runs):\n`);
  console.log(
    `  ${pad("Pass Rate", 12)} ${pad("Runs", 6)} ${pad("Statuses", 30)} Test`,
  );
  console.log(`  ${"─".repeat(80)}`);
  for (const e of flaky) {
    const statusSummary = e.statuses.join(", ");
    console.log(
      `  ${pad(Math.round(e.passRate * 100) + "%", 12)} ${rpad(e.total, 4)}   ${pad(statusSummary, 30)} ${e.suite} > ${e.title}`,
    );
  }
  console.log();
}

function showTrend(runs, pattern) {
  const re = new RegExp(pattern, "i");
  const matching = new Map();

  for (const run of runs) {
    for (const t of run.tests) {
      if (t.status === "skipped") continue;
      const key = testKey(t);
      const label = `${t.suite} > ${t.title}`;
      if (!re.test(label) && !re.test(t.file)) continue;
      if (!matching.has(key)) {
        matching.set(key, { label, points: [] });
      }
      matching.get(key).points.push({
        timestamp: run.timestamp,
        duration: t.duration,
        status: t.status,
      });
    }
  }

  if (matching.size === 0) {
    console.log(`\nNo tests matching "${pattern}" found.\n`);
    return;
  }

  for (const [, entry] of matching) {
    console.log(`\n  ${entry.label}:`);
    for (const p of entry.points) {
      const bar = "█".repeat(Math.min(50, Math.ceil(p.duration / 1000)));
      const mark = p.status === "passed" ? "" : ` [${p.status}]`;
      console.log(
        `    ${p.timestamp}  ${pad(formatDuration(p.duration), 8)} ${bar}${mark}`,
      );
    }
  }
  console.log();
}

function showRunHistory(runs, maxRuns) {
  const display = runs.slice(-maxRuns);
  console.log(`\nRun history (last ${display.length} of ${runs.length}):\n`);
  console.log(
    `  ${pad("Timestamp", 22)} ${pad("Duration", 10)} ${pad("Status", 12)} ${pad("Pass", 6)} ${pad("Fail", 6)} ${pad("Skip", 6)} Total`,
  );
  console.log(`  ${"─".repeat(80)}`);
  for (const run of display) {
    const passed = run.tests.filter((t) => t.status === "passed").length;
    const failed = run.tests.filter(
      (t) => t.status === "failed" || t.status === "timedOut",
    ).length;
    const skipped = run.tests.filter((t) => t.status === "skipped").length;
    const dur = run.summary ? formatDuration(run.summary.duration) : "?";
    const status = run.summary?.status ?? "?";
    console.log(
      `  ${pad(run.timestamp, 22)} ${pad(dur, 10)} ${pad(status, 12)} ${rpad(passed, 4)}   ${rpad(failed, 4)}   ${rpad(skipped, 4)}   ${run.tests.length}`,
    );
  }
  console.log();
}

// ── Main ─────────────────────────────────────────────────────────────

const args = process.argv.slice(2);
const files = findJsonlFiles(STATS_DIR);

if (files.length === 0) {
  console.log("No stats data found in test-stats/. Run tests first.");
  process.exit(0);
}

const runs = files.map(parseRun).filter(Boolean);

if (args.includes("--slowest")) {
  showSlowest(runs);
} else if (args.includes("--flaky")) {
  showFlaky(runs);
} else if (args.includes("--trend")) {
  const idx = args.indexOf("--trend");
  const pattern = args[idx + 1] || ".";
  showTrend(runs, pattern);
} else if (args.includes("--runs")) {
  const idx = args.indexOf("--runs");
  const n = parseInt(args[idx + 1] || "10", 10);
  showRunHistory(runs, n);
} else {
  showLatest(runs);
  showRunHistory(runs, 5);
}
