#!/usr/bin/env node

import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { join, resolve } from "node:path";

const repoRoot = resolve(new URL("../..", import.meta.url).pathname);
const outDir = join(repoRoot, "tools/visual-review/reports");

function argValue(name, fallback = null) {
  const index = process.argv.indexOf(name);
  if (index === -1) return fallback;
  return process.argv[index + 1] ?? fallback;
}

function load(path) {
  return JSON.parse(readFileSync(path, "utf8"));
}

function matching(elements, selector) {
  if (selector.startsWith("#")) {
    const id = selector.slice(1);
    return elements.filter((element) => element.id === id);
  }
  if (selector.startsWith(".")) {
    const cls = selector.slice(1);
    return elements.filter((element) =>
      (element.className || "").split(/\s+/).includes(cls),
    );
  }
  return elements.filter((element) => element.tag === selector);
}

function firstVisible(elements, selector) {
  return matching(elements, selector).find((element) =>
    element.rect.width > 0 &&
    element.rect.height > 0 &&
    element.styles.display !== "none" &&
    element.styles.visibility !== "hidden",
  ) || matching(elements, selector)[0] || null;
}

function roundedBox(rect) {
  if (!rect) return null;
  return {
    x: Math.round(rect.x),
    y: Math.round(rect.y),
    width: Math.round(rect.width),
    height: Math.round(rect.height),
  };
}

function pickStyles(element) {
  if (!element) return null;
  const keys = [
    "display",
    "position",
    "box-sizing",
    "width",
    "height",
    "padding",
    "margin",
    "background-color",
    "color",
    "font-family",
    "font-size",
    "line-height",
    "overflow",
    "flex",
    "flex-direction",
    "align-items",
  ];
  const result = {};
  for (const key of keys) result[key] = element.styles[key];
  return result;
}

function summarizeElement(element) {
  if (!element) return null;
  return {
    path: element.path,
    tag: element.tag,
    id: element.id,
    className: element.className,
    countText: element.text?.length ?? 0,
    rect: roundedBox(element.rect),
    styles: pickStyles(element),
  };
}

function compareSelector(reference, current, selector) {
  const refMatches = matching(reference.elements, selector);
  const curMatches = matching(current.elements, selector);
  const ref = firstVisible(reference.elements, selector);
  const cur = firstVisible(current.elements, selector);
  return {
    selector,
    counts: {
      reference: refMatches.length,
      current: curMatches.length,
    },
    reference: summarizeElement(ref),
    current: summarizeElement(cur),
  };
}

const referencePath = argValue("--reference");
const currentPath = argValue("--current");
const outPath = argValue("--out");

if (!referencePath || !currentPath) {
  console.error("Usage: compare-style-dumps.mjs --reference ref.json --current current.json [--out report.md]");
  process.exit(2);
}

const selectors = [
  "#ROOT",
  ".lm_goldenlayout",
  ".lm_stack",
  ".lm_header",
  ".lm_tabs",
  ".lm_tab",
  ".lm_active",
  ".lm_content",
  ".component-container",
  ".terminal",
  ".terminal-line",
  ".active",
  ".future",
  ".build-panel",
  ".build-header",
  ".build-output-container",
  ".build-stdout",
  ".build-stderr",
  ".build-clickable",
  ".build-line-error",
  ".build-line-warning",
];

const reference = load(referencePath);
const current = load(currentPath);
const comparisons = selectors.map((selector) =>
  compareSelector(reference, current, selector),
);

const lines = [
  `# Style Dump Comparison`,
  ``,
  `Reference: \`${referencePath}\``,
  `Current: \`${currentPath}\``,
  ``,
  `## Summary`,
  ``,
  `- Reference viewport: ${reference.viewport.width}x${reference.viewport.height}, captured elements ${reference.capturedElementCount}/${reference.elementCount}`,
  `- Current viewport: ${current.viewport.width}x${current.viewport.height}, captured elements ${current.capturedElementCount}/${current.elementCount}`,
  ``,
];

for (const item of comparisons) {
  lines.push(`## ${item.selector}`);
  lines.push(``);
  lines.push(`Counts: reference ${item.counts.reference}, current ${item.counts.current}`);
  lines.push(``);
  lines.push(`Reference:`);
  lines.push("```json");
  lines.push(JSON.stringify(item.reference, null, 2));
  lines.push("```");
  lines.push(`Current:`);
  lines.push("```json");
  lines.push(JSON.stringify(item.current, null, 2));
  lines.push("```");
  lines.push(``);
}

const report = lines.join("\n");
if (outPath) {
  mkdirSync(outDir, { recursive: true });
  writeFileSync(outPath, report);
  console.log(outPath);
} else {
  console.log(report);
}
