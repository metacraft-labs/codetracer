#!/usr/bin/env node
// The scrub check for the Agent Harbor fixtures. It fails when
//
//   - a fixture file carries a credential, a private prompt or an
//     infrastructure identifier, or a fixture set and its manifest disagree;
//   - a PUBLIC repository's tree carries captured (private) data: a file
//     identical to a private fixture or private design document, a manifest
//     that declares itself `private`, or a session id of the private fleet
//     snapshot.
//
//   node tools/agent-harbor-fixtures/scrub-check.mjs [--fixtures <dir>]...
//        [--raw <dir>] [--public-root <dir>]...
//   node tools/agent-harbor-fixtures/scrub-check.mjs --self-test
//
// Fixture sets checked (unless `--fixtures` names others): the private set
// beside this checkout, when it exists, and the committed synthetic set. The
// public repositories scanned (unless `--public-root` names others) are the
// workspace siblings this campaign publishes from: codetracer,
// nim-agents-isonim-viewmodels, nim-agents, nim-agent-harbor and isonim. Only
// the files git would commit are scanned: tracked files and untracked files
// that are not ignored (`git ls-files -co --exclude-standard`).
//
// Per fixture file, independently of how the scrubber works:
//
//   credentials      every rule of lib/patterns.mjs; plus the literal API keys
//                    the local `ah` configuration names and the values of
//                    secret-looking environment variables;
//   prompts          (captured sets) the prompt-bearing fields of the session
//                    list and of every event history are empty, and question
//                    options carry placeholder labels; and, when the capture's
//                    raw directory is given, no prompt string of the raw
//                    capture -- nor any 32-character window of one -- occurs
//                    in any fixture file;
//   infrastructure   LAN names, private addresses, home directories, e-mail
//                    addresses, the local account name and the configured
//                    server's host name;
//   manifest         every file is listed in manifest.json with its sha256,
//                    every listed file exists, and the set declares which it
//                    is (`fixtureSet`: `private` or `synthetic`).
//
// `--self-test` is the vacuity guard: it plants a credential and a prompt in
// a copy of a fixture set, and private fixtures in a scratch "public"
// repository, and requires the check to FAIL on each with the expected rule.
// A check that cannot fail proves nothing.
//
// Exit status: 0 clean, 1 findings (or a self-test that saw no failure),
// 2 usage or I/O error. Findings never print the matched text in full.

import { createHash, randomBytes } from "node:crypto";
import { spawnSync } from "node:child_process";
import {
  cpSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir, userInfo } from "node:os";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { allRules, redact } from "./lib/patterns.mjs";
import { readAhServers } from "./lib/ah-config.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, "../..");
const workspaceRoot = resolve(repoRoot, "..");

/** The private design directory: captured fixtures, brief, inventory. */
export const privateDesignDir = join(workspaceRoot, "codetracer-pm/design/agent-harbor-front-end");
export const privateFixtureDir = join(privateDesignDir, "fixtures");
export const syntheticFixtureDir = join(workspaceRoot, "nim-agents-isonim-viewmodels/fixtures/agent-harbor");
/** Public repositories this campaign publishes code and fixtures from. */
export const publicRepositories = [
  "codetracer",
  "nim-agents-isonim-viewmodels",
  "nim-agents",
  "nim-agent-harbor",
  "isonim",
];

function walk(dir) {
  const out = [];
  for (const name of readdirSync(dir)) {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) out.push(...walk(path));
    else out.push(path);
  }
  return out.sort();
}

function lineOf(text, index) {
  let line = 1;
  for (let i = 0; i < index && i < text.length; i++) if (text.charCodeAt(i) === 10) line++;
  return line;
}

/** Literal secrets known on this machine: ah API keys, secret env values. */
export function localSecrets() {
  const secrets = new Set();
  for (const server of readAhServers()) {
    if (server.apiKey) secrets.add(server.apiKey);
  }
  for (const [name, value] of Object.entries(process.env)) {
    if (!value || value.length < 16) continue;
    if (/(TOKEN|SECRET|API_?KEY|PASSWORD|PASSWD|CREDENTIAL)/i.test(name)) secrets.add(value);
  }
  return [...secrets];
}

/**
 * The local account's login name: it names the person who captured the
 * fixtures, so it must not appear even outside a path.
 */
export function localAccountNames() {
  const names = new Set();
  try {
    const name = userInfo().username;
    if (name && name.length >= 4) names.add(name);
  } catch {
    // no passwd entry; nothing to add
  }
  return [...names];
}

/** Host names this machine's `ah` configuration points at. */
export function configuredHosts() {
  const hosts = new Set();
  for (const server of readAhServers()) {
    try {
      const host = new URL(server.url).hostname;
      hosts.add(host);
      const short = host.split(".")[0];
      if (short.length >= 4 && !/^\d+$/.test(short)) hosts.add(short);
    } catch {
      // not a URL; nothing to add
    }
  }
  return [...hosts];
}

/** Whitespace runs collapsed to one space, so layout cannot hide a match. */
export function normalizeSpace(text) {
  return text.replace(/\s+/g, " ");
}

/**
 * Overlapping 32-character windows of a prompt string, so a prompt that
 * reached a fixture truncated or split still matches. A window must carry at
 * least 16 letters or digits: a window of spaces and punctuation names no
 * prompt and would match any file.
 */
function windows(text, size = 32, step = 16) {
  const out = [];
  const flat = normalizeSpace(text).trim();
  const meaningful = (w) => (w.match(/[A-Za-z0-9]/g) ?? []).length >= 16;
  if (flat.length <= size) return meaningful(flat) ? [flat] : [];
  for (let i = 0; i + size <= flat.length; i += step) {
    const w = flat.slice(i, i + size);
    if (meaningful(w)) out.push(w);
  }
  return out;
}

/**
 * Where a raw prompt string is looked for. Fleet and scenario fixtures are
 * data the server returned about sessions, so ANY window of a prompt there is
 * a leak. Plans and diffs are files of their own that prompts often quote
 * (a prompt naming a milestone, a prompt pasting a line of code); in them
 * only a whole prompt string of 24 characters or more is a finding, or every
 * plan a prompt quotes would fail the check.
 */
function promptScope(file) {
  return file.startsWith("fleet/") || file.startsWith("scenarios/") ? "windows" : "whole";
}

function checkStructure(dir, findings) {
  const sessionsPath = join(dir, "fleet/sessions.json");
  const isOption = (label) => typeof label === "string" && /^Option \d+$/.test(label);
  const checkEvent = (file, ev, where) => {
    if (ev?.type !== "agent_question") return;
    if (typeof ev.prompt === "string" && ev.prompt.length > 0) {
      findings.push({ rule: "question-prompt-present", file, line: 0, preview: where });
    }
    for (const option of ev.options ?? []) {
      if (!isOption(option.label)) {
        findings.push({ rule: "question-option-text-present", file, line: 0, preview: where });
      }
    }
  };
  if (existsSync(sessionsPath)) {
    const file = relative(dir, sessionsPath);
    const data = JSON.parse(readFileSync(sessionsPath, "utf8"));
    for (const [i, item] of (data.items ?? []).entries()) {
      if (typeof item.task?.prompt === "string" && item.task.prompt.length > 0) {
        findings.push({ rule: "session-prompt-present", file, line: 0, preview: `items[${i}]` });
      }
      for (const [j, ev] of (item.recent_events ?? []).entries()) {
        checkEvent(file, ev, `items[${i}].recent_events[${j}]`);
      }
    }
  }
  const eventsDir = join(dir, "fleet/events");
  if (existsSync(eventsDir)) {
    for (const path of walk(eventsDir)) {
      const file = relative(dir, path);
      const data = JSON.parse(readFileSync(path, "utf8"));
      for (const [j, ev] of (data.events ?? []).entries()) checkEvent(file, ev, `events[${j}]`);
    }
  }
}

function checkManifest(dir, findings) {
  const manifestPath = join(dir, "manifest.json");
  if (!existsSync(manifestPath)) {
    findings.push({ rule: "manifest-missing", file: "manifest.json", line: 0, preview: "" });
    return;
  }
  const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
  const listed = manifest.files ?? {};
  const present = new Set(
    walk(dir)
      .map((p) => relative(dir, p))
      .filter((p) => p !== "manifest.json" && p !== "README.md"),
  );
  for (const [path, sha] of Object.entries(listed)) {
    const full = join(dir, path);
    if (!existsSync(full)) {
      findings.push({ rule: "manifest-file-missing", file: path, line: 0, preview: "" });
      continue;
    }
    const actual = createHash("sha256").update(readFileSync(full)).digest("hex");
    if (actual !== sha) findings.push({ rule: "manifest-sha-mismatch", file: path, line: 0, preview: "" });
    present.delete(path);
  }
  for (const path of present) {
    findings.push({ rule: "file-not-in-manifest", file: path, line: 0, preview: "" });
  }
}


function escapeRegExp(text) {
  return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function readManifest(dir) {
  const path = join(dir, "manifest.json");
  return existsSync(path) ? JSON.parse(readFileSync(path, "utf8")) : null;
}

/** Every finding in the fixture set `dir`; an empty list means clean. */
export function checkFixtures(
  dir,
  { rawDir = null, secrets = localSecrets(), hosts = configuredHosts(), accounts = localAccountNames() } = {},
) {
  const findings = [];
  const files = walk(dir);
  const manifest = readManifest(dir);
  const set = manifest?.fixtureSet;
  if (manifest && set !== "private" && set !== "synthetic") {
    findings.push({ rule: "fixture-set-unlabelled", file: "manifest.json", line: 0, preview: String(set ?? "") });
  }
  const privateWindows = [];
  const privateWholes = [];
  if (rawDir && existsSync(join(rawDir, "private-strings.json"))) {
    for (const s of JSON.parse(readFileSync(join(rawDir, "private-strings.json"), "utf8"))) {
      privateWindows.push(...windows(s));
      const whole = normalizeSpace(s).trim();
      if (whole.length >= 24) privateWholes.push(whole);
    }
  }
  for (const path of files) {
    const file = relative(dir, path);
    const text = readFileSync(path, "utf8");
    for (const rule of allRules) {
      rule.re.lastIndex = 0;
      for (const match of text.matchAll(rule.re)) {
        findings.push({ rule: rule.id, file, line: lineOf(text, match.index), preview: redact(match[0]) });
      }
    }
    for (const secret of secrets) {
      const at = text.indexOf(secret);
      if (at >= 0) findings.push({ rule: "local-secret", file, line: lineOf(text, at), preview: redact(secret) });
    }
    for (const account of accounts) {
      const re = new RegExp(`(?<![A-Za-z0-9])${escapeRegExp(account)}(?![A-Za-z0-9])`, "i");
      const match = re.exec(text);
      if (match) findings.push({ rule: "local-account-name", file, line: lineOf(text, match.index), preview: redact(account) });
    }
    for (const host of hosts) {
      const re = new RegExp(`(?<![A-Za-z0-9-])${escapeRegExp(host)}(?![A-Za-z0-9-])`, "i");
      const match = re.exec(text);
      if (match) findings.push({ rule: "configured-server-host", file, line: lineOf(text, match.index), preview: redact(host) });
    }
    const flat = normalizeSpace(text);
    const fragments = promptScope(file) === "windows" ? privateWindows : privateWholes;
    for (const fragment of fragments) {
      if (flat.includes(fragment)) {
        findings.push({ rule: "private-prompt-text", file, line: 0, preview: redact(fragment) });
        break;
      }
    }
  }
  // The synthetic set carries invented prompts on purpose; only a captured
  // set must have every prompt-bearing field empty.
  if (set !== "synthetic") checkStructure(dir, findings);
  checkManifest(dir, findings);
  return findings;
}

// ---------------------------------------------------------------------------
// Private data in public repositories
// ---------------------------------------------------------------------------

const uuidRe = /\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/gi;
const maxScannedBytes = 32 * 1024 * 1024;

/**
 * What identifies private data: the sha256 of every captured fixture file and
 * of every private design document, and the session ids of the captured
 * fleet. Empty when the private directory is not present (then there is
 * nothing a public tree could have copied from this machine).
 */
export function privateFingerprints(designDir = privateDesignDir) {
  const hashes = new Map();
  const sessionIds = new Set();
  if (!existsSync(designDir)) return { hashes, sessionIds };
  for (const path of walk(designDir)) {
    // A tiny file (`{}`, an empty list) is not identifying, and would match
    // unrelated public files of the same bytes.
    if (statSync(path).size < 64) continue;
    hashes.set(createHash("sha256").update(readFileSync(path)).digest("hex"), relative(designDir, path));
  }
  const sessions = join(designDir, "fixtures/fleet/sessions.json");
  if (existsSync(sessions)) {
    for (const item of JSON.parse(readFileSync(sessions, "utf8")).items ?? []) {
      // The all-zero organisation id and the like are not identifying.
      if (typeof item.id === "string" && !/^0{8}-/.test(item.id)) sessionIds.add(item.id.toLowerCase());
    }
  }
  return { hashes, sessionIds };
}

/** The files git would commit in `root`; every file when it is no repository. */
function committableFiles(root) {
  const listed = spawnSync("git", ["-C", root, "ls-files", "-co", "--exclude-standard", "-z"], {
    encoding: "buffer",
    maxBuffer: 512 * 1024 * 1024,
  });
  if (listed.status === 0) {
    return listed.stdout
      .toString("utf8")
      .split("\0")
      .filter(Boolean)
      .map((p) => join(root, p));
  }
  return walk(root);
}

/** Findings for private data in the public repository at `root`. */
export function checkPublicTree(root, fingerprints) {
  const findings = [];
  const { hashes, sessionIds } = fingerprints;
  for (const path of committableFiles(root)) {
    let stat;
    try {
      stat = statSync(path);
    } catch {
      continue; // listed but deleted in the worktree
    }
    if (!stat.isFile() || stat.size === 0 || stat.size > maxScannedBytes) continue;
    const bytes = readFileSync(path);
    const file = relative(resolve(root, ".."), path);
    const digest = createHash("sha256").update(bytes).digest("hex");
    if (hashes.has(digest)) {
      findings.push({ rule: "private-fixture-in-public-repo", file, line: 0, preview: `copy of ${hashes.get(digest)}` });
      continue;
    }
    if (bytes.includes(0)) continue; // binary; only an exact copy can match
    const text = bytes.toString("utf8");
    if (/"fixtureSet"\s*:\s*"private"/.test(text)) {
      findings.push({ rule: "private-manifest-in-public-repo", file, line: 0, preview: "fixtureSet: private" });
    }
    if (sessionIds.size > 0) {
      for (const match of text.matchAll(uuidRe)) {
        if (sessionIds.has(match[0].toLowerCase())) {
          findings.push({ rule: "private-session-id-in-public-repo", file, line: lineOf(text, match.index), preview: redact(match[0]) });
          break;
        }
      }
    }
  }
  return findings;
}

function report(findings) {
  for (const f of findings) {
    console.error(`scrub-check: ${f.rule}: ${f.file}${f.line ? `:${f.line}` : ""}${f.preview ? ` (${f.preview})` : ""}`);
  }
}

// ---------------------------------------------------------------------------
// Self-test: the vacuity guard
// ---------------------------------------------------------------------------

/**
 * Plants a credential and a prompt in copies of `fixtureDir`, and private
 * fixtures in a scratch public repository, and requires the check to fail on
 * each, naming the expected rule. `privateDir` supplies the private data to
 * plant; when this machine has none, a scratch private set is made from the
 * synthetic one, so the guard runs everywhere.
 */
/** A synthetic set made to pass the captured-set rules: `private`, no prompts. */
function makeLookCaptured(dir) {
  const manifestPath = join(dir, "manifest.json");
  const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
  manifest.fixtureSet = "private";
  const clearEvent = (ev) => {
    if (ev?.type !== "agent_question") return ev;
    return { ...ev, prompt: "", options: (ev.options ?? []).map((o, i) => ({ ...o, label: `Option ${i + 1}` })) };
  };
  const rewrite = (rel, edit) => {
    const path = join(dir, rel);
    writeFileSync(path, JSON.stringify(edit(JSON.parse(readFileSync(path, "utf8"))), null, 2));
    manifest.files[rel] = createHash("sha256").update(readFileSync(path)).digest("hex");
  };
  rewrite(manifest.fleet.sessions, (data) => ({
    ...data,
    items: data.items.map((item) => ({
      ...item,
      task: { ...item.task, prompt: "" },
      recent_events: (item.recent_events ?? []).map(clearEvent),
    })),
  }));
  for (const rel of Object.values(manifest.fleet.events ?? {})) {
    rewrite(rel, (data) => ({ ...data, events: (data.events ?? []).map(clearEvent) }));
  }
  writeFileSync(manifestPath, JSON.stringify(manifest, null, 2));
}

export function selfTest({ fixtureDir, privateDir }) {
  const results = [];
  const scratch = mkdtempSync(join(tmpdir(), "ah-scrub-selftest-"));
  try {
    const plant = (label, expectedRule, run) => {
      const findings = run();
      results.push({ label, expectedRule, caught: findings.some((f) => f.rule === expectedRule), findings: findings.length });
    };
    // Plants go into a copy of the captured set where this machine has one,
    // else into a copy of the synthetic set made to look captured (labelled
    // `private`, its invented prompts emptied). Either way the copy must be
    // CLEAN before the plant -- a plant is "caught" only if the check found
    // nothing before it and finds the expected rule after it, so a check that
    // fails on everything cannot pass this test.
    const hasPrivate = privateDir && existsSync(join(privateDir, "manifest.json"));
    const cleanCopy = () => {
      const copy = mkdtempSync(join(scratch, "set-"));
      cpSync(hasPrivate ? privateDir : fixtureDir, copy, { recursive: true });
      if (!hasPrivate) makeLookCaptured(copy);
      return copy;
    };
    const quiet = { secrets: [], hosts: [], accounts: [] };
    const plantInSet = (label, expectedRule, mutate) => {
      const copy = cleanCopy();
      const baseline = checkFixtures(copy, quiet).length;
      mutate(copy);
      const findings = checkFixtures(copy, quiet);
      results.push({
        label: `${label} (${hasPrivate ? "captured set" : "stand-in set"}, ${baseline} finding(s) before the plant)`,
        expectedRule,
        caught: baseline === 0 && findings.some((f) => f.rule === expectedRule),
        findings: findings.length,
      });
    };
    const sessionsFile = (copy) => join(copy, "fleet/sessions.json");
    const editSessions = (copy, edit) => {
      const data = JSON.parse(readFileSync(sessionsFile(copy), "utf8"));
      edit(data);
      writeFileSync(sessionsFile(copy), JSON.stringify(data, null, 2));
    };

    plantInSet("planted GitHub token in a session field", "github-token", (copy) =>
      editSessions(copy, (data) => {
        const token = "ghp_" + randomBytes(27).toString("base64").replace(/[^A-Za-z0-9]/g, "a").slice(0, 36);
        data.items[0].priority = `normal ${token}`;
      }),
    );
    plantInSet("planted Agent Harbor API key header in a log line", "authorization-apikey", (copy) =>
      editSessions(copy, (data) => {
        const key = randomBytes(24).toString("hex");
        data.items[0].recent_events = [
          ...(data.items[0].recent_events ?? []),
          { type: "log", level: "info", message: `curl -H 'Authorization: ApiKey ${key}'`, timestamp: 0 },
        ];
      }),
    );
    plantInSet("planted prompt text in a captured session", "session-prompt-present", (copy) =>
      editSessions(copy, (data) => {
        data.items[0].task = { ...(data.items[0].task ?? {}), prompt: "Refactor the private billing module" };
      }),
    );

    // The private data to plant: this machine's, or a stand-in made from the
    // synthetic set when there is none.
    let source = privateDir;
    if (!source || !existsSync(join(source, "manifest.json"))) {
      // Every file differs from its synthetic original (fresh session ids, one
      // more trailing newline), so the negative control below stays honest.
      source = join(scratch, "stand-in-private/fixtures");
      cpSync(fixtureDir, source, { recursive: true });
      const ids = new Map();
      const freshId = (id) => {
        if (!ids.has(id)) {
          const h = createHash("sha256").update(`stand-in:${id}`).digest("hex");
          ids.set(id, `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20, 32)}`);
        }
        return ids.get(id);
      };
      for (const path of walk(source)) {
        writeFileSync(path, `${readFileSync(path, "utf8").replace(uuidRe, freshId)}\n`);
      }
      const m = JSON.parse(readFileSync(join(source, "manifest.json"), "utf8"));
      m.fixtureSet = "private";
      writeFileSync(join(source, "manifest.json"), JSON.stringify(m, null, 2));
    }
    const fingerprints = privateFingerprints(dirname(source));
    const sessions = JSON.parse(readFileSync(join(source, "fleet/sessions.json"), "utf8"));
    const publicRepo = (label) => {
      const root = join(scratch, `public-${label}`);
      mkdirSync(join(root, "fixtures"), { recursive: true });
      writeFileSync(join(root, "README.md"), "a public repository\n");
      return root;
    };
    plant("private fleet snapshot copied into a public repository", "private-fixture-in-public-repo", () => {
      const root = publicRepo("copy");
      cpSync(join(source, "fleet/sessions.json"), join(root, "fixtures/sessions.json"));
      return checkPublicTree(root, fingerprints);
    });
    plant("edited excerpt of the private snapshot in a public repository", "private-session-id-in-public-repo", () => {
      const root = publicRepo("excerpt");
      const excerpt = { items: [{ ...sessions.items[0], priority: "edited so no hash matches" }] };
      writeFileSync(join(root, "fixtures/excerpt.json"), JSON.stringify(excerpt));
      return checkPublicTree(root, fingerprints);
    });
    plant("private manifest in a public repository", "private-manifest-in-public-repo", () => {
      const root = publicRepo("manifest");
      const m = JSON.parse(readFileSync(join(source, "manifest.json"), "utf8"));
      m.note = "edited so no hash matches";
      writeFileSync(join(root, "fixtures/manifest.json"), JSON.stringify(m, null, 2));
      return checkPublicTree(root, fingerprints);
    });
    // The negative control: the synthetic set itself, in a public repository,
    // must NOT be reported as private.
    const control = (() => {
      const root = publicRepo("control");
      cpSync(fixtureDir, join(root, "fixtures/agent-harbor"), { recursive: true });
      return checkPublicTree(root, fingerprints);
    })();
    results.push({
      label: "negative control: the synthetic set in a public repository",
      expectedRule: "(none)",
      caught: control.length === 0,
      findings: control.length,
      control: true,
    });
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
  return results;
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

function argValue(name) {
  const i = process.argv.indexOf(name);
  return i >= 0 ? process.argv[i + 1] ?? null : null;
}

function argValues(name) {
  const out = [];
  process.argv.forEach((arg, i) => {
    if (arg === name && process.argv[i + 1]) out.push(process.argv[i + 1]);
  });
  return out;
}

function defaultFixtureDirs() {
  return [privateFixtureDir, syntheticFixtureDir].filter((d) => existsSync(join(d, "manifest.json")));
}

function main() {
  const named = argValues("--fixtures").map((d) => resolve(d));
  const dirs = named.length > 0 ? named : defaultFixtureDirs();
  for (const dir of dirs) {
    if (!existsSync(join(dir, "manifest.json"))) {
      console.error(`scrub-check: no fixture set at ${dir} (manifest.json missing)`);
      process.exit(2);
    }
  }
  if (dirs.length === 0) {
    console.error("scrub-check: no fixture set found (neither the private nor the synthetic one)");
    process.exit(2);
  }

  if (process.argv.includes("--self-test")) {
    const fixtureDir = existsSync(join(syntheticFixtureDir, "manifest.json")) ? syntheticFixtureDir : dirs[0];
    const results = selfTest({ fixtureDir, privateDir: privateFixtureDir });
    let ok = true;
    for (const r of results) {
      const verdict = r.control
        ? r.caught ? "not reported, as required" : `WRONGLY REPORTED (${r.findings} finding(s))`
        : r.caught ? "check FAILED as required" : "NOT DETECTED";
      console.log(`scrub-check self-test: ${r.label}: ${verdict} (expected rule ${r.expectedRule}; ${r.findings} finding(s))`);
      ok &&= r.caught;
    }
    if (!ok) {
      console.error("scrub-check self-test: FAILED: a planted secret or private fixture went undetected, or the control was reported");
      process.exit(1);
    }
    console.log("scrub-check self-test: ok (every plant made the check fail; the control passed)");
    return;
  }

  const rawDir = argValue("--raw");
  let total = 0;
  let failed = false;
  for (const dir of dirs) {
    const findings = checkFixtures(dir, { rawDir: dir === privateFixtureDir ? rawDir : null });
    const set = readManifest(dir)?.fixtureSet ?? "unlabelled";
    if (findings.length > 0) {
      report(findings);
      console.error(`scrub-check: FAILED with ${findings.length} finding(s) in the ${set} set at ${dir}`);
      failed = true;
    } else {
      const count = walk(dir).length;
      total += count;
      console.log(
        `scrub-check: ok: ${count} file(s) of the ${set} set at ${dir} carry no credential, prompt or infrastructure identifier` +
          (set === "private" ? (rawDir ? ` (raw prompt strings from ${rawDir} compared)` : " (no raw capture given; structural prompt checks only)") : ""),
      );
    }
  }

  const roots = argValues("--public-root").map((r) => resolve(r));
  const publicRoots = roots.length > 0
    ? roots
    : publicRepositories.map((r) => join(workspaceRoot, r)).filter((r) => existsSync(r));
  const fingerprints = privateFingerprints();
  if (fingerprints.hashes.size === 0) {
    console.log("scrub-check: no private design directory here; public trees cannot hold this machine's captures");
  } else {
    for (const root of publicRoots) {
      const findings = checkPublicTree(root, fingerprints);
      if (findings.length > 0) {
        report(findings);
        console.error(`scrub-check: FAILED: ${findings.length} private file(s) or id(s) in the public repository ${root}`);
        failed = true;
      } else {
        console.log(`scrub-check: ok: no private fixture, design document or session id in the public repository ${root}`);
      }
    }
  }
  if (failed) process.exit(1);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    main();
  } catch (error) {
    console.error(`scrub-check: ${error.stack ?? error}`);
    process.exit(2);
  }
}
