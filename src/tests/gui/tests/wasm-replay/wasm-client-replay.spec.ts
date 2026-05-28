/**
 * Playwright E2E tests for TRUE client-side WASM replay.
 *
 * Architecture:
 *   - Server: dumb HTTP file server (Node http module) serving static files.
 *     No WebSocket, no custom endpoints, no server-side logic.
 *   - Browser: loads the WASM db-backend in a WebWorker, fetches trace files
 *     via fetch(), pushes them into the VFS, and runs the full DAP protocol
 *     entirely client-side.
 *
 * Tests cover the two CTFS replay paths used by the browser build:
 *   1. Materialized CTFS traces -- the committed Stylus fixture at
 *      src/db-backend/tests/fixtures/stylus-fund-trace/stylus_fund_tracking_demo.ct.
 *
 *   2. MCR CTFS traces -- the committed XOS fixture at
 *      src/db-backend/tests/fixtures/xos/xos_hello.ct. This is routed through
 *      the in-process EmulatorReplaySession.
 *
 * Comprehensive tests verify actual DAP panel data: variable values, function
 * names, source paths, step navigation, and event log content.
 */

import { test, expect, type Page } from "@playwright/test";
import * as http from "node:http";
import * as fs from "node:fs";
import * as path from "node:path";
import * as net from "node:net";
import * as childProcess from "node:child_process";

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------

// __dirname for this file is `<repo>/src/tests/gui/tests/wasm-replay`,
// which is five levels deep, so the repo root is five levels up. The
// earlier three-level form resolved to `<repo>/src/tests/`, producing
// paths like `<repo>/src/tests/src/db-backend/wasm-testing/...` (the
// doubled `src/` is the giveaway) and aborting the test in
// `beforeAll`.
const REPO_ROOT = path.resolve(__dirname, "..", "..", "..", "..", "..");
const DB_BACKEND_DIR = path.join(REPO_ROOT, "src", "db-backend");
const WASM_TESTING_DIR = path.join(REPO_ROOT, "src", "db-backend", "wasm-testing");
const WASM_PKG_DIR = path.join(WASM_TESTING_DIR, "pkg");
const WASM_PACKAGE_FILES = [
  path.join(WASM_PKG_DIR, "db_backend.js"),
  path.join(WASM_PKG_DIR, "db_backend_bg.wasm"),
];
const WASM_BINARY = path.join(WASM_PKG_DIR, "db_backend_bg.wasm");
const WASM_BUILD_SCRIPT = path.join(DB_BACKEND_DIR, "build_wasm.sh");
const NATIVE_RECORDER_ROOT = path.resolve(REPO_ROOT, "..", "codetracer-native-recorder");
const NATIVE_RECORDER_WASM_MODULES = [
  "ct_emulator",
  "ct_time_model",
  "ct_events",
  "ct_instrument",
  "ct_recorder",
  "ct_replayer",
  "ct_loader",
];
const SOURCE_EXTENSIONS = new Set([
  ".rs",
  ".c",
  ".cc",
  ".cpp",
  ".cxx",
  ".h",
  ".hh",
  ".hpp",
  ".nim",
  ".nims",
  ".capnp",
  ".lalrpop",
]);
const BUILD_OUTPUT_DIR_NAMES = new Set([
  ".git",
  "target",
  "build",
  "out",
  "pkg",
  "dist",
  "node_modules",
]);

const DB_FIXTURES_DIR = path.join(REPO_ROOT, "src", "db-backend", "tests", "fixtures");

// Materialized CTFS fixture: Stylus/WASM DAP flow.
const STYLUS_TRACES_DIR = path.join(DB_FIXTURES_DIR, "stylus-fund-trace");
const STYLUS_TRACE_FILES = ["stylus_fund_tracking_demo.ct"];

// MCR CTFS fixture: Linux x86_64 recording replayed by EmulatorReplaySession.
const XOS_TRACES_DIR = path.join(DB_FIXTURES_DIR, "xos");
const XOS_TRACE_FILES = ["xos_hello.ct"];

const TRACE_ROUTES: Record<string, string> = {
  "/stylus-traces/": STYLUS_TRACES_DIR,
  "/xos-traces/": XOS_TRACES_DIR,
};

let wasmPackageFreshnessChecked = false;

function repoRelative(filePath: string): string {
  return path.relative(REPO_ROOT, filePath);
}

function collectFiles(dir: string, predicate: (filePath: string) => boolean): string[] {
  if (!fs.existsSync(dir)) {
    return [];
  }

  const files: string[] = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const entryPath = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (BUILD_OUTPUT_DIR_NAMES.has(entry.name)) {
        continue;
      }
      files.push(...collectFiles(entryPath, predicate));
    } else if (entry.isFile() && predicate(entryPath)) {
      files.push(entryPath);
    }
  }
  return files;
}

function collectDirectFiles(dir: string, predicate: (filePath: string) => boolean): string[] {
  if (!fs.existsSync(dir)) {
    return [];
  }

  const files: string[] = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const entryPath = path.join(dir, entry.name);
    if (entry.isFile() && predicate(entryPath)) {
      files.push(entryPath);
    }
  }
  return files;
}

function uniqueExistingFiles(filePaths: string[]): string[] {
  return [...new Set(filePaths)].filter((filePath) => fs.existsSync(filePath));
}

function isMeaningfulSourceFile(filePath: string): boolean {
  return SOURCE_EXTENSIONS.has(path.extname(filePath));
}

function parseCargoFeatures(cargoToml: string): Map<string, string[]> {
  const features = new Map<string, string[]>();
  let inFeatures = false;
  let currentFeature: string | null = null;
  let currentValue = "";

  for (const line of cargoToml.split(/\r?\n/)) {
    const sectionMatch = line.match(/^\s*\[([^\]]+)\]\s*$/);
    if (sectionMatch) {
      inFeatures = sectionMatch[1] === "features";
      currentFeature = null;
      currentValue = "";
      continue;
    }

    if (!inFeatures) {
      continue;
    }

    if (!currentFeature) {
      const featureMatch = line.match(/^\s*([\w-]+)\s*=\s*\[(.*)$/);
      if (!featureMatch) {
        continue;
      }
      currentFeature = featureMatch[1];
      currentValue = featureMatch[2];
    } else {
      currentValue += "\n" + line;
    }

    if (currentValue.includes("]")) {
      const entries = [...currentValue.matchAll(/"([^"]+)"/g)].map((match) => match[1]);
      features.set(currentFeature, entries);
      currentFeature = null;
      currentValue = "";
    }
  }

  return features;
}

function enabledOptionalDependencyNames(cargoToml: string, featureName: string): Set<string> {
  const features = parseCargoFeatures(cargoToml);
  const enabled = new Set<string>();
  const visited = new Set<string>();
  const stack = [...(features.get(featureName) ?? [])];

  while (stack.length > 0) {
    const entry = stack.pop()!;
    if (entry.startsWith("dep:")) {
      enabled.add(entry.slice("dep:".length));
      continue;
    }
    if (visited.has(entry)) {
      continue;
    }
    visited.add(entry);
    for (const nestedEntry of features.get(entry) ?? []) {
      stack.push(nestedEntry);
    }
  }

  return enabled;
}

function stripTomlComment(line: string): string {
  let inString = false;
  let escaped = false;

  for (let i = 0; i < line.length; i++) {
    const char = line[i];
    if (escaped) {
      escaped = false;
      continue;
    }
    if (char === "\\" && inString) {
      escaped = true;
      continue;
    }
    if (char === '"') {
      inString = !inString;
      continue;
    }
    if (char === "#" && !inString) {
      return line.slice(0, i);
    }
  }

  return line;
}

function tomlStringValue(value: string, key: string): string | null {
  const match = value.match(new RegExp(`(?:^|[,\\s])${key}\\s*=\\s*"([^"]+)"`));
  return match ? match[1] : null;
}

function tomlBooleanValue(value: string, key: string): boolean {
  return new RegExp(`(?:^|[,\\s])${key}\\s*=\\s*true(?:[,\\s]|$)`).test(value);
}

function dependencySectionAffectsWasmBuild(section: string): boolean {
  if (section.startsWith("workspace.")) {
    return false;
  }
  if (section === "dependencies" || section === "build-dependencies") {
    return true;
  }
  return /^target\..+\.(dependencies|build-dependencies)$/.test(section);
}

function dependencyTableAffectsWasmBuild(section: string): boolean {
  if (section.startsWith("workspace.")) {
    return false;
  }
  return /(^|\.)(dependencies|build-dependencies)\.[^.]+$/.test(section);
}

function dependencyNameFromTable(section: string): string {
  return section.slice(section.lastIndexOf(".") + 1).replace(/^"|"$/g, "");
}

type CargoDependencyRef = {
  name: string;
  pathValue: string | null;
  workspace: boolean;
  optional: boolean;
};

function emptyCargoDependencyRef(name: string): CargoDependencyRef {
  return {
    name,
    pathValue: null,
    workspace: false,
    optional: false,
  };
}

function cargoDependencyRef(
  dependencies: Map<string, CargoDependencyRef>,
  name: string,
): CargoDependencyRef {
  let dependency = dependencies.get(name);
  if (!dependency) {
    dependency = emptyCargoDependencyRef(name);
    dependencies.set(name, dependency);
  }
  return dependency;
}

function cargoDependencyEnabled(
  dependency: CargoDependencyRef,
  includeOptionalDependencies: boolean,
  enabledOptionalDeps: Set<string>,
): boolean {
  return (
    !dependency.optional ||
    includeOptionalDependencies ||
    enabledOptionalDeps.has(dependency.name)
  );
}

function cargoLocalDependencyRefs(
  manifestPath: string,
  includeOptionalDependencies: boolean,
): CargoDependencyRef[] {
  const cargoToml = fs.readFileSync(manifestPath, "utf8");
  const enabledOptionalDeps = enabledOptionalDependencyNames(cargoToml, "browser-transport");
  const dependencies: CargoDependencyRef[] = [];
  let sectionDependencies = new Map<string, CargoDependencyRef>();
  let section = "";
  let tableDependencyName: string | null = null;
  let tableDependency: CargoDependencyRef | null = null;

  function pushDependency(dependency: CargoDependencyRef): void {
    if (
      (dependency.pathValue || dependency.workspace) &&
      cargoDependencyEnabled(dependency, includeOptionalDependencies, enabledOptionalDeps)
    ) {
      dependencies.push(dependency);
    }
  }

  function flushTableDependency(): void {
    if (tableDependencyName && tableDependency) {
      pushDependency(tableDependency);
    }
    tableDependencyName = null;
    tableDependency = null;
  }

  function flushSectionDependencies(): void {
    for (const dependency of sectionDependencies.values()) {
      pushDependency(dependency);
    }
    sectionDependencies = new Map<string, CargoDependencyRef>();
  }

  for (const line of cargoToml.split(/\r?\n/)) {
    const strippedLine = stripTomlComment(line);
    const sectionMatch = strippedLine.match(/^\s*\[([^\]]+)\]\s*$/);
    if (sectionMatch) {
      flushTableDependency();
      flushSectionDependencies();
      section = sectionMatch[1];
      if (dependencyTableAffectsWasmBuild(section)) {
        tableDependencyName = dependencyNameFromTable(section);
        tableDependency = emptyCargoDependencyRef(tableDependencyName);
      }
      continue;
    }

    if (dependencySectionAffectsWasmBuild(section)) {
      const inlineMatch = strippedLine.match(/^\s*([\w-]+)\s*=\s*\{([^}]*)\}/);
      if (inlineMatch) {
        const dependencyName = inlineMatch[1];
        const dependencyConfig = inlineMatch[2];
        const dependency = cargoDependencyRef(sectionDependencies, dependencyName);
        dependency.pathValue = tomlStringValue(dependencyConfig, "path");
        dependency.workspace = tomlBooleanValue(dependencyConfig, "workspace");
        dependency.optional = tomlBooleanValue(dependencyConfig, "optional");
        continue;
      }

      const dottedMatch = strippedLine.match(/^\s*([\w-]+)\.(path|workspace|optional)\s*=\s*(.+)$/);
      if (dottedMatch) {
        const dependency = cargoDependencyRef(sectionDependencies, dottedMatch[1]);
        const key = dottedMatch[2];
        const value = dottedMatch[3];
        if (key === "path") {
          dependency.pathValue = tomlStringValue(`path = ${value}`, "path");
        } else if (key === "workspace") {
          dependency.workspace = /^\s*true\b/.test(value);
        } else if (key === "optional") {
          dependency.optional = /^\s*true\b/.test(value);
        }
      }
    } else if (tableDependency) {
      const pathValue = strippedLine.match(/^\s*path\s*=\s*"([^"]+)"/);
      if (pathValue) {
        tableDependency.pathValue = pathValue[1];
      }
      if (/^\s*workspace\s*=\s*true\b/.test(strippedLine)) {
        tableDependency.workspace = true;
      }
      if (/^\s*optional\s*=\s*true\b/.test(strippedLine)) {
        tableDependency.optional = true;
      }
    }
  }
  flushTableDependency();
  flushSectionDependencies();

  return dependencies;
}

function cargoTomlHasSection(cargoToml: string, sectionName: string): boolean {
  return new RegExp(`^\\s*\\[${sectionName.replace(".", "\\.")}\\]\\s*$`, "m").test(cargoToml);
}

function nearestCargoWorkspaceManifest(manifestPath: string): string | null {
  let dir = path.dirname(manifestPath);

  while (true) {
    const candidate = path.join(dir, "Cargo.toml");
    if (
      fs.existsSync(candidate) &&
      cargoTomlHasSection(fs.readFileSync(candidate, "utf8"), "workspace")
    ) {
      return candidate;
    }

    const parent = path.dirname(dir);
    if (parent === dir) {
      return null;
    }
    dir = parent;
  }
}

function workspacePathDependencies(workspaceManifestPath: string): Map<string, string> {
  const cargoToml = fs.readFileSync(workspaceManifestPath, "utf8");
  const dependencies = new Map<string, string>();
  let section = "";
  let tableDependencyName: string | null = null;
  let tableDependencyPath: string | null = null;

  function flushTableDependency(): void {
    if (tableDependencyName && tableDependencyPath) {
      dependencies.set(tableDependencyName, tableDependencyPath);
    }
    tableDependencyName = null;
    tableDependencyPath = null;
  }

  for (const line of cargoToml.split(/\r?\n/)) {
    const strippedLine = stripTomlComment(line);
    const sectionMatch = strippedLine.match(/^\s*\[([^\]]+)\]\s*$/);
    if (sectionMatch) {
      flushTableDependency();
      section = sectionMatch[1];
      const workspaceDependencyTable = section.match(/^workspace\.dependencies\.([^.]+)$/);
      tableDependencyName = workspaceDependencyTable
        ? workspaceDependencyTable[1].replace(/^"|"$/g, "")
        : null;
      tableDependencyPath = null;
      continue;
    }

    if (section === "workspace.dependencies") {
      const inlineMatch = strippedLine.match(/^\s*([\w-]+)\s*=\s*\{([^}]*)\}/);
      if (inlineMatch) {
        const dependencyPath = tomlStringValue(inlineMatch[2], "path");
        if (dependencyPath) {
          dependencies.set(inlineMatch[1], dependencyPath);
        }
        continue;
      }

      const dottedPathMatch = strippedLine.match(/^\s*([\w-]+)\.path\s*=\s*"([^"]+)"/);
      if (dottedPathMatch) {
        dependencies.set(dottedPathMatch[1], dottedPathMatch[2]);
      }
    } else if (tableDependencyName) {
      const pathValue = strippedLine.match(/^\s*path\s*=\s*"([^"]+)"/);
      if (pathValue) {
        tableDependencyPath = pathValue[1];
      }
    }
  }
  flushTableDependency();

  return dependencies;
}

function cargoLocalDependencyRoots(rootManifestPath: string): {
  roots: string[];
  workspaceManifests: string[];
} {
  const roots: string[] = [];
  const workspaceManifests: string[] = [];
  const queuedManifests = new Set<string>();
  const visitedManifests = new Set<string>();
  const stack = [
    {
      manifestPath: rootManifestPath,
      includeOptionalDependencies: false,
    },
  ];

  while (stack.length > 0) {
    const { manifestPath, includeOptionalDependencies } = stack.pop()!;
    if (visitedManifests.has(manifestPath) || !fs.existsSync(manifestPath)) {
      continue;
    }
    visitedManifests.add(manifestPath);

    const workspaceManifest = nearestCargoWorkspaceManifest(manifestPath);
    const workspaceDependencies = workspaceManifest
      ? workspacePathDependencies(workspaceManifest)
      : new Map<string, string>();
    if (workspaceManifest) {
      workspaceManifests.push(workspaceManifest);
    }

    for (const dependency of cargoLocalDependencyRefs(manifestPath, includeOptionalDependencies)) {
      let dependencyRoot: string | null = null;
      if (dependency.pathValue) {
        dependencyRoot = path.resolve(path.dirname(manifestPath), dependency.pathValue);
      } else if (dependency.workspace && workspaceManifest) {
        const workspaceDependencyPath = workspaceDependencies.get(dependency.name);
        if (workspaceDependencyPath) {
          dependencyRoot = path.resolve(path.dirname(workspaceManifest), workspaceDependencyPath);
        }
      }

      if (
        !dependencyRoot ||
        !fs.existsSync(dependencyRoot) ||
        !fs.statSync(dependencyRoot).isDirectory()
      ) {
        continue;
      }

      const dependencyManifest = path.join(dependencyRoot, "Cargo.toml");
      if (!fs.existsSync(dependencyManifest)) {
        continue;
      }

      roots.push(dependencyRoot);
      if (!queuedManifests.has(dependencyManifest)) {
        queuedManifests.add(dependencyManifest);
        stack.push({
          manifestPath: dependencyManifest,
          includeOptionalDependencies: true,
        });
      }
    }
  }

  return {
    roots: [...new Set(roots)],
    workspaceManifests: [...new Set(workspaceManifests)],
  };
}

function cargoRootBuildInputs(root: string): string[] {
  const directInputs = ["Cargo.toml", "Cargo.lock", "build.rs"].map((fileName) =>
    path.join(root, fileName),
  );

  return [
    ...directInputs,
    ...collectFiles(path.join(root, "src"), isMeaningfulSourceFile),
  ];
}

function nativeRecorderWasmBuildInputs(): string[] {
  const emulatorDir = path.join(NATIVE_RECORDER_ROOT, "ct_emulator");
  if (!fs.existsSync(emulatorDir)) {
    return [];
  }

  const inputs = [
    path.join(emulatorDir, "build_wasm_api.sh"),
    path.join(emulatorDir, "ct_emulator.nimble"),
  ];

  for (const moduleName of NATIVE_RECORDER_WASM_MODULES) {
    const moduleRoot = path.join(NATIVE_RECORDER_ROOT, moduleName);
    inputs.push(...collectFiles(path.join(moduleRoot, "src"), isMeaningfulSourceFile));
    inputs.push(...collectDirectFiles(moduleRoot, (filePath) => {
      return [".nimble", ".nims"].includes(path.extname(filePath));
    }));
  }

  return inputs;
}

function wasmBuildInputs(): string[] {
  const directInputs = [
    path.join(DB_BACKEND_DIR, "Cargo.toml"),
    path.join(DB_BACKEND_DIR, "Cargo.lock"),
    path.join(DB_BACKEND_DIR, "build.rs"),
    WASM_BUILD_SCRIPT,
  ];

  const cargoManifest = path.join(DB_BACKEND_DIR, "Cargo.toml");
  const localCargoDependencies = cargoLocalDependencyRoots(cargoManifest);
  const pathDependencyInputs = localCargoDependencies.roots.flatMap(cargoRootBuildInputs);

  return uniqueExistingFiles([
    ...directInputs.filter((filePath) => fs.existsSync(filePath)),
    ...collectFiles(path.join(DB_BACKEND_DIR, "src"), (filePath) => filePath.endsWith(".rs")),
    ...localCargoDependencies.workspaceManifests,
    ...pathDependencyInputs,
    ...nativeRecorderWasmBuildInputs(),
  ]);
}

function latestMtime(files: string[]): { filePath: string; mtimeMs: number } {
  return files.reduce(
    (latest, filePath) => {
      const mtimeMs = fs.statSync(filePath).mtimeMs;
      return mtimeMs > latest.mtimeMs ? { filePath, mtimeMs } : latest;
    },
    { filePath: "", mtimeMs: 0 },
  );
}

function wasmPackageFreshness(): { fresh: boolean; reason: string } {
  const missingPackageFile = WASM_PACKAGE_FILES.find((filePath) => !fs.existsSync(filePath));
  if (missingPackageFile) {
    return {
      fresh: false,
      reason: `WASM package file is missing: ${repoRelative(missingPackageFile)}`,
    };
  }

  const inputs = wasmBuildInputs();
  if (inputs.length === 0) {
    throw new Error(`No WASM build inputs found under ${repoRelative(DB_BACKEND_DIR)}`);
  }

  const wasmMtimeMs = fs.statSync(WASM_BINARY).mtimeMs;
  const newestInput = latestMtime(inputs);
  if (wasmMtimeMs <= newestInput.mtimeMs) {
    return {
      fresh: false,
      reason:
        `${repoRelative(WASM_BINARY)} is older than ` +
        `${repoRelative(newestInput.filePath)}`,
    };
  }

  return { fresh: true, reason: "WASM package is fresh" };
}

function tail(value: string | undefined, maxChars = 6000): string {
  if (!value) {
    return "";
  }
  return value.length > maxChars ? value.slice(value.length - maxChars) : value;
}

function rebuildWasmPackage(reason: string): void {
  if (!fs.existsSync(WASM_BUILD_SCRIPT)) {
    throw new Error(
      `${reason}. Cannot rebuild because ${repoRelative(WASM_BUILD_SCRIPT)} does not exist.`,
    );
  }

  console.log(`[wasm-replay] ${reason}; rebuilding WASM package`);
  const result = childProcess.spawnSync("bash", [WASM_BUILD_SCRIPT], {
    cwd: DB_BACKEND_DIR,
    env: {
      ...process.env,
      CODETRACER_WASM_BUILD_CLEAN: "0",
    },
    encoding: "utf8",
    maxBuffer: 20 * 1024 * 1024,
  });

  if (result.error || result.status !== 0) {
    const command = `cd ${DB_BACKEND_DIR} && CODETRACER_WASM_BUILD_CLEAN=0 bash build_wasm.sh`;
    throw new Error(
      [
        `${reason}. Automatic WASM rebuild failed.`,
        `Run this command to reproduce: ${command}`,
        result.error ? `spawn error: ${result.error.message}` : `exit status: ${result.status}`,
        tail(result.stdout) ? `stdout:\n${tail(result.stdout)}` : "",
        tail(result.stderr) ? `stderr:\n${tail(result.stderr)}` : "",
      ]
        .filter(Boolean)
        .join("\n\n"),
    );
  }

  const freshness = wasmPackageFreshness();
  if (!freshness.fresh) {
    throw new Error(
      `WASM rebuild completed, but the package is still stale: ${freshness.reason}`,
    );
  }
}

function ensureFreshWasmPackage(): void {
  if (wasmPackageFreshnessChecked) {
    return;
  }

  const freshness = wasmPackageFreshness();
  if (!freshness.fresh) {
    rebuildWasmPackage(freshness.reason);
  }

  wasmPackageFreshnessChecked = true;
}

function assertFixtureFilesExist(traceDir: string, fileNames: string[], label: string): void {
  for (const f of fileNames) {
    const fp = path.join(traceDir, f);
    if (!fs.existsSync(fp)) {
      throw new Error(`${label} CTFS fixture file not found: ${fp}`);
    }
  }
}

function findVariable(scope: any, name: string): any {
  return scope?.variables?.find((v: any) => v.name === name);
}

function parseIntegerVariable(value: string): number {
  const parsed = Number.parseInt(value, 10);
  if (Number.isNaN(parsed)) {
    throw new Error(`Expected integer variable value, got ${JSON.stringify(value)}`);
  }
  return parsed;
}

function expectSuccessfulDapHandshake(result: any, label: string): void {
  expect(result.success, `${label} replay failed: ${result.error}`).toBe(true);
  expect(result.initResponse).toBeDefined();
  expect(result.initResponse.command).toBe("initialize");
  expect(result.initResponse.success).toBe(true);
  expect(result.launchResponse).toBeDefined();
  expect(result.launchResponse.command).toBe("launch");
  expect(result.launchResponse.success).toBe(true);
  expect(result.configDoneResponse).toBeDefined();
  expect(result.configDoneResponse.command).toBe("configurationDone");
  expect(result.configDoneResponse.success).toBe(true);
  expect(result.totalResponses).toBeGreaterThanOrEqual(4);
}

function expectSingleThread(result: any): void {
  expect(result.threads).toBeDefined();
  expect(result.threads.threads).toBeDefined();
  expect(result.threads.threads.length).toBeGreaterThanOrEqual(1);
  expect(result.threads.threads[0].id).toBe(1);
  expect(result.threads.threads[0].name).toBeTruthy();
}

function expectNonEmptyStack(result: any): any {
  expect(result.stackTrace).toBeDefined();
  expect(result.stackTrace.stackFrames).toBeDefined();
  expect(result.stackTrace.stackFrames.length).toBeGreaterThanOrEqual(1);
  expect(result.stackTrace.totalFrames).toBeGreaterThanOrEqual(1);
  return result.stackTrace.stackFrames[0];
}

function expectNonEmptyVariables(variablesByScope: any[]): any {
  expect(variablesByScope).toBeDefined();
  expect(variablesByScope.length).toBeGreaterThanOrEqual(1);
  const scope = variablesByScope.find((s: any) => s.variables?.length > 0);
  expect(scope, "expected at least one populated variables scope").toBeDefined();
  for (const v of scope.variables) {
    expect(v.name).toBeTruthy();
    expect(v.value).toBeDefined();
    expect(typeof v.value).toBe("string");
    expect(v.value.length).toBeGreaterThan(0);
  }
  return scope;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Find a free TCP port. */
function getFreePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.listen(0, () => {
      const addr = srv.address();
      if (addr && typeof addr === "object") {
        const port = addr.port;
        srv.close(() => resolve(port));
      } else {
        srv.close(() => reject(new Error("Could not determine port")));
      }
    });
    srv.on("error", reject);
  });
}

/**
 * Start a minimal static HTTP file server.
 *
 * Serves:
 *   /                       -- wasm-testing directory (HTML, JS, WASM, pkg/)
 *   /stylus-traces/<file>   -- Stylus materialized CTFS fixture files
 *   /xos-traces/<file>      -- XOS MCR CTFS fixture files
 */
async function startStaticServer(): Promise<{
  server: http.Server;
  baseUrl: string;
}> {
  const port = await getFreePort();

  const MIME: Record<string, string> = {
    ".html": "text/html",
    ".js": "application/javascript",
    ".wasm": "application/wasm",
    ".json": "application/json",
    ".css": "text/css",
    ".ts": "text/plain",
    ".ct": "application/octet-stream",
  };

  const server = http.createServer((req, res) => {
    const url = new URL(req.url || "/", `http://localhost:${port}`);
    let filePath: string | null = null;

    for (const [routePrefix, traceDir] of Object.entries(TRACE_ROUTES)) {
      if (url.pathname.startsWith(routePrefix)) {
        const fileName = path.basename(url.pathname);
        filePath = path.join(traceDir, fileName);
        break;
      }
    }

    if (!filePath) {
      const relPath = url.pathname.slice(1) || "replay-test.html";
      filePath = path.resolve(WASM_TESTING_DIR, relPath);
      if (!filePath.startsWith(WASM_TESTING_DIR)) {
        res.writeHead(403, { "Content-Type": "text/plain" });
        res.end("Forbidden");
        return;
      }
    }

    if (!fs.existsSync(filePath) || fs.statSync(filePath).isDirectory()) {
      res.writeHead(404, { "Content-Type": "text/plain" });
      res.end("Not found");
      return;
    }

    const ext = path.extname(filePath);
    const contentType = MIME[ext] || "application/octet-stream";

    const headers: Record<string, string> = {
      "Content-Type": contentType,
      "Access-Control-Allow-Origin": "*",
      "Cross-Origin-Resource-Policy": "same-origin",
    };

    const body = fs.readFileSync(filePath);
    res.writeHead(200, headers);
    res.end(body);
  });

  return new Promise((resolve, reject) => {
    server.listen(port, "127.0.0.1", () => {
      resolve({ server, baseUrl: `http://127.0.0.1:${port}` });
    });
    server.on("error", reject);
  });
}

/**
 * Navigate to the replay test page, wait for it to complete, and return
 * the result object from window.__replayTestResult.
 */
async function runReplayTest(
  page: Page,
  baseUrl: string,
  opts: {
    traceFolder: string;
    files: string;
    traceBaseUrl?: string;
    traceFile?: string;
    mode?: string;
  },
): Promise<any> {
  const consoleLogs: string[] = [];
  page.on("console", (msg) => consoleLogs.push(`[${msg.type()}] ${msg.text()}`));
  page.on("pageerror", (err) => consoleLogs.push(`[pageerror] ${err.message}`));

  const searchParams = new URLSearchParams({
    traceFolder: opts.traceFolder,
    files: opts.files,
    mode: opts.mode || "comprehensive",
  });
  if (opts.traceBaseUrl) {
    searchParams.set("traceBaseUrl", opts.traceBaseUrl);
  }
  if (opts.traceFile) {
    searchParams.set("traceFile", opts.traceFile);
  }

  const url = `${baseUrl}/replay-test.html?${searchParams.toString()}`;
  await page.goto(url);

  // Wait for the test to complete (success or failure).
  await page.waitForFunction(
    () => (window as any).__replayTestResult !== undefined,
    { timeout: 90_000 },
  );

  const result = await page.evaluate(() => (window as any).__replayTestResult);

  // Log all console output for debugging on failure.
  if (!result.success) {
    console.log("=== Browser console logs ===");
    for (const line of consoleLogs) {
      console.log(line);
    }
    console.log("=== End browser logs ===");
  }

  return result;
}

// ---------------------------------------------------------------------------
// Tests -- Materialized CTFS traces
// ---------------------------------------------------------------------------

test.describe("WASM client-side replay -- materialized CTFS trace", () => {
  let server: http.Server;
  let baseUrl: string;

  test.setTimeout(120_000);

  test.beforeAll(async () => {
    ensureFreshWasmPackage();
    assertFixtureFilesExist(STYLUS_TRACES_DIR, STYLUS_TRACE_FILES, "Stylus");
    const result = await startStaticServer();
    server = result.server;
    baseUrl = result.baseUrl;
  });

  test.afterAll(async () => {
    if (server) {
      await new Promise<void>((resolve) => server.close(() => resolve()));
    }
  });

  test("DAP initialize + launch + configurationDone succeeds for Stylus .ct trace", async ({
    page,
  }) => {
    const result = await runReplayTest(page, baseUrl, {
      traceFolder: "trace",
      files: STYLUS_TRACE_FILES.join(","),
      traceBaseUrl: "/stylus-traces/",
      traceFile: STYLUS_TRACE_FILES[0],
      mode: "basic",
    });

    expectSuccessfulDapHandshake(result, "Stylus");
  });

  test("comprehensive panel verification for Stylus materialized .ct trace", async ({
    page,
  }) => {
    const result = await runReplayTest(page, baseUrl, {
      traceFolder: "trace",
      files: STYLUS_TRACE_FILES.join(","),
      traceBaseUrl: "/stylus-traces/",
      traceFile: STYLUS_TRACE_FILES[0],
      mode: "comprehensive",
    });

    expectSuccessfulDapHandshake(result, "Stylus");
    expectSingleThread(result);

    const topFrame = expectNonEmptyStack(result);
    expect(topFrame.name).toBe("new");
    expect(topFrame.source?.path).toBeTruthy();
    expect(topFrame.source.path).toContain("test-programs/stylus_fund_tracker/src/lib.rs");
    expect(topFrame.line).toBe(49);

    expect(result.steppingSucceeded).toBe(true);
    expect(result.stackTraceAfterStep?.stackFrames?.length).toBeGreaterThanOrEqual(1);
    const frameAfterStep = result.stackTraceAfterStep.stackFrames[0];
    expect(frameAfterStep.name).toBe("deny_value");
    expect(frameAfterStep.source?.path).toBeTruthy();
    expect(frameAfterStep.source.path).toContain("test-programs/stylus_fund_tracker/src/lib.rs");
    expect(frameAfterStep.line).toBe(38);

    const variablesScope = expectNonEmptyVariables(result.variablesAfterStep);
    expect(variablesScope.scopeName).toBe("deny_value");

    const selfVar = findVariable(variablesScope, "self");
    expect(selfVar, "Stylus `self` local should be visible after stepping").toBeDefined();
    expect(selfVar.value).toContain("Value { kind: Pointer");

    expect(result.eventLog).toBeDefined();
    expect(result.eventLog.content).toContain("0xca1d209d");
    expect(result.eventLog.content).toContain("key:");
    expect(result.eventLog.content).toContain("value:");
    expect(result.eventLog.content).toContain("input:");
  });

  test("status element shows success for Stylus .ct trace", async ({ page }) => {
    const searchParams = new URLSearchParams({
      traceFolder: "trace",
      files: STYLUS_TRACE_FILES.join(","),
      traceBaseUrl: "/stylus-traces/",
      traceFile: STYLUS_TRACE_FILES[0],
      mode: "basic",
    });
    const url = `${baseUrl}/replay-test.html?${searchParams.toString()}`;
    await page.goto(url);

    await page.waitForFunction(
      () => {
        const el = document.getElementById("status");
        return el && el.classList.contains("ok");
      },
      { timeout: 60_000 },
    );

    const statusText = await page.textContent("#status");
    expect(statusText).toContain("trace loaded");
  });

  test("handles missing CTFS trace file gracefully", async ({ page }) => {
    const result = await runReplayTest(page, baseUrl, {
      traceFolder: "trace",
      files: "nonexistent.ct",
      traceBaseUrl: "/stylus-traces/",
      traceFile: "nonexistent.ct",
      mode: "basic",
    });

    expect(result.success).toBe(false);
    expect(result.error).toContain("404");
  });
});

// ---------------------------------------------------------------------------
// Tests -- MCR (CTFS container) traces
// ---------------------------------------------------------------------------

test.describe("WASM client-side replay -- MCR (CTFS .ct) trace", () => {
  let server: http.Server;
  let baseUrl: string;

  test.setTimeout(120_000);

  test.beforeAll(async () => {
    ensureFreshWasmPackage();
    assertFixtureFilesExist(XOS_TRACES_DIR, XOS_TRACE_FILES, "XOS");
    const result = await startStaticServer();
    server = result.server;
    baseUrl = result.baseUrl;
  });

  test.afterAll(async () => {
    if (server) {
      await new Promise<void>((resolve) => server.close(() => resolve()));
    }
  });

  test("DAP initialize + launch + configurationDone succeeds for XOS .ct trace", async ({
    page,
  }) => {
    const result = await runReplayTest(page, baseUrl, {
      traceFolder: "trace",
      files: XOS_TRACE_FILES.join(","),
      traceBaseUrl: "/xos-traces/",
      traceFile: XOS_TRACE_FILES[0],
      mode: "basic",
    });

    expectSuccessfulDapHandshake(result, "XOS");
  });

  test("comprehensive panel verification for XOS emulator .ct trace", async ({
    page,
  }) => {
    const result = await runReplayTest(page, baseUrl, {
      traceFolder: "trace",
      files: XOS_TRACE_FILES.join(","),
      traceBaseUrl: "/xos-traces/",
      traceFile: XOS_TRACE_FILES[0],
      mode: "comprehensive",
    });

    expectSuccessfulDapHandshake(result, "XOS");
    expectSingleThread(result);

    const rootFrame = expectNonEmptyStack(result);
    expect(rootFrame.name).toBeTruthy();
    expect(rootFrame.source?.path).toBeTruthy();
    expect(rootFrame.source.path).toContain("xos_hello.c");
    expect(rootFrame.line).toBeGreaterThan(1);

    expect(result.steppingSucceeded).toBe(true);
    expect(result.stackTraceAfterStep?.stackFrames?.length).toBeGreaterThanOrEqual(1);
    const frameAfterStep = result.stackTraceAfterStep.stackFrames[0];
    expect(frameAfterStep.name).toBeTruthy();
    expect(frameAfterStep.source?.path).toContain("xos_hello.c");
    expect(frameAfterStep.line).toBeGreaterThan(1);

    const variablesScope = expectNonEmptyVariables(result.variablesAfterStep);
    expect(variablesScope.scopeName).toBeTruthy();

    const ripVar = findVariable(variablesScope, "rip");
    expect(ripVar, "XOS register local `rip` should be visible").toBeDefined();
    expect(parseIntegerVariable(ripVar.value)).not.toBe(0);

    const rspVar = findVariable(variablesScope, "rsp");
    expect(rspVar, "XOS register local `rsp` should be visible").toBeDefined();
    expect(parseIntegerVariable(rspVar.value)).not.toBe(0);
  });
});
