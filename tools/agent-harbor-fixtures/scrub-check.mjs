#!/usr/bin/env node
// The scrub check for the Agent Harbor fixtures. It fails when
//
//   - a fixture file carries a credential, a private prompt or an
//     infrastructure identifier, or a fixture set and its manifest disagree;
//   - a PUBLIC repository's tree carries captured (private) data: a file
//     identical to a private fixture or private design document, a manifest
//     that declares itself `private`, a session id of the private fleet
//     snapshot, or a NEAR-COPY of private fixture content -- an excerpt of a
//     few hundred bytes or more, even edited, reflowed or reindented
//     (lib/near-copy.mjs says how and why);
//   - a PUBLIC repository's tree carries a credential: the credential rules
//     of lib/patterns.mjs and this machine's literal secrets, over every text
//     file git would commit, not only over the fixture sets.
//
// The near-copy part needs the private fixtures. Where they are absent (a
// public CI runner) it is SKIPPED and the check says so on stderr and in its
// summary line; the credential part runs everywhere. A documented false
// positive of either part is listed, with its reason, in
// public-tree-allowlist.json beside this file; see `loadAllowlist`.
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
// Per public-repository file (text files up to `maxTextBytes`; larger and
// binary files get the exact-copy rule only, and every skipped file is named):
//
//   exact copies     the sha256 of every private fixture and design document;
//   private data     a manifest declaring `fixtureSet: private`, a session id
//                    of the private fleet snapshot;
//   near copies      a region of shingles shared with the private fixtures
//                    (lib/near-copy.mjs), the synthetic set's shingles
//                    excluded;
//   credentials      the credential rules of lib/patterns.mjs and the literal
//                    local secrets, less the source-code names
//                    `isSourceCodeName` explains.
//
// `--self-test` is the vacuity guard: it plants a credential and a prompt in
// a copy of a fixture set; and in scratch "public" repositories private
// fixtures, edited excerpts of a private diff and plan (one character
// changed, reflowed, reindented, wrapped into a comment, pasted into a file
// the allowlist lets share other text) and credentials outside any fixture
// set; and requires the check to FAIL on each with the expected rule,
// through the same `checkPublicTree` the real check runs. Its negative
// controls (the synthetic set, source code that names tokens) must pass.
// Without private fixtures it plants from a stand-in made of the synthetic
// set plus generated text. A check that cannot fail proves nothing.
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
import { basename, dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { allRules, credentialRules, redact } from "./lib/patterns.mjs";
import { readAhServers } from "./lib/ah-config.mjs";
import { buildNearCopyIndex, minRegion, nearCopyRegions, shingleSize } from "./lib/near-copy.mjs";

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


/**
 * A match of a credential rule that, in SOURCE CODE, is a name and not a
 * credential. Fixture files are data a server returned, so there every match
 * counts; a public tree is code and documentation, which name tokens without
 * holding one. Two classes, each measured over the public trees on
 * 2026-11-04 (361 and 19 matches, none a credential):
 *
 *   - `assigned-secret` whose value carries no digit: `token: 'string.delimiter'`
 *     (an editor grammar's scope), `token = OriginContinuationToken` (a type),
 *     `secret = process.env.CT_TEST_SECRET` (a lookup). The issuer formats
 *     the other rules know are matched by those rules whatever their digits.
 *     A random value here lacks a digit with probability (6/16)^n for hex and
 *     (52/62)^n for base62: below 10^-6 for 16 hex characters, 6 % for 16
 *     base62 ones and 0.4 % for 32. A short letters-only secret assigned in
 *     source is the residual this accepts.
 *   - `url-credentials` whose password is a template or pattern, not a value:
 *     `${GH_TOKEN}`, `<TOKEN>`, `{secret}`, a regular-expression fragment, or
 *     a port number read as a password (`http://gw:8080@`).
 *
 * Anything else a public tree matches is either a credential or a false
 * positive that public-tree-allowlist.json documents one by one.
 */
export function isSourceCodeName(ruleId, match) {
  if (ruleId === "assigned-secret") {
    const value = match.replace(/^[^:=]*[:=]\s*["']?/, "");
    return !/[0-9]/.test(value);
  }
  if (ruleId === "url-credentials") {
    const userinfo = match.replace(/^[a-z][a-z0-9+.-]*:\/\//i, "").replace(/@$/, "");
    const password = userinfo.slice(userinfo.indexOf(":") + 1);
    return /^\d+$/.test(password) || /[$<>{}[\]()^*\\]/.test(password);
  }
  return false;
}

/**
 * Every match of `rules` and of the literal `secrets` in `text`. The fixture
 * check and the public-tree check both call this one function (with
 * `sourceTree` set for the latter, which drops the matches
 * `isSourceCodeName` explains), so the self-test's plants are caught, or
 * not, by exactly the code the real check runs.
 */
export function ruleFindings(text, file, rules, secrets, { sourceTree = false } = {}) {
  const findings = [];
  for (const rule of rules) {
    rule.re.lastIndex = 0;
    for (const match of text.matchAll(rule.re)) {
      if (sourceTree && isSourceCodeName(rule.id, match[0])) continue;
      findings.push({ rule: rule.id, file, line: lineOf(text, match.index), preview: redact(match[0]), match: match[0] });
    }
  }
  for (const secret of secrets) {
    const at = text.indexOf(secret);
    if (at >= 0) findings.push({ rule: "local-secret", file, line: lineOf(text, at), preview: redact(secret), match: secret });
  }
  return findings;
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
    findings.push(...ruleFindings(text, file, allRules, secrets));
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

/**
 * The largest text file the credential and near-copy rules read. Larger
 * files (generated bundles, lock dumps, corpora) still get the exact-copy
 * check up to `maxScannedBytes`; every one skipped is named in the summary.
 */
export const maxTextBytes = 2 * 1024 * 1024;

/**
 * The near-copy sources of one private fixture file. A diff is split into
 * one source per changed file, named `<fixture>#<path>` (the path of its
 * `diff --git a/<path> b/<path>` header, https://git-scm.com/docs/diff-format),
 * so an allowlist entry can let a public file share text with the hunks
 * that change another repository's copy of that same file and with nothing
 * else. Every other file is one source.
 */
export function nearCopySources(name, text) {
  if (!name.startsWith("diffs/")) return [{ name, text }];
  return text
    .split(/^(?=diff --git )/m)
    .filter((part) => part.length > 0)
    .map((part) => {
      const path = /^diff --git a\/(\S+) b\//.exec(part)?.[1];
      return { name: path ? `${name}#${path}` : name, text: part };
    });
}

/**
 * The near-copy index of the private fixtures in `fixtureDir` (every file of
 * the set, the manifest and README included; a diff one source per changed
 * file, `nearCopySources`), minus every shingle of the synthetic set in
 * `syntheticDir` -- the wire format's shape vocabulary, which is public on
 * purpose. Null when `fixtureDir` does not exist: then nothing was indexed
 * and the caller must SAY the near-copy part did not run.
 */
export function nearCopyIndexFor(fixtureDir = privateFixtureDir, syntheticDir = syntheticFixtureDir) {
  if (!fixtureDir || !existsSync(fixtureDir)) return null;
  const files = walk(fixtureDir);
  const sources = files.flatMap((path) => nearCopySources(relative(fixtureDir, path), readFileSync(path, "utf8")));
  const excluded = syntheticDir && existsSync(syntheticDir) ? walk(syntheticDir).map((p) => readFileSync(p, "utf8")) : [];
  const index = buildNearCopyIndex(sources, excluded);
  // Positive control (trap 4): an index of no shingles would pass every
  // public file. A private set that exists but indexes nothing is an error.
  if (files.length === 0 || index.hashes.size === 0) {
    throw new Error(`the near-copy index of ${fixtureDir} is empty (${files.length} file(s)); refusing to report the trees clean`);
  }
  return { ...index, fileCount: files.length };
}

/** `pattern` with `*` matching any run of characters but `#`, as a RegExp. */
function sourcePattern(pattern) {
  return new RegExp(`^${pattern.split("*").map(escapeRegExp).join("[^#]*")}$`);
}

/**
 * The documented false positives of the public-tree rules, from
 * public-tree-allowlist.json:
 *
 *   { "credentials": [ { "file", "rule", "sha256", "reason" } ],
 *     "nearCopy":    [ { "file", "sources": [pattern...], "reason" } ] }
 *
 * `file` is `<repository>/<path>`. A credential entry covers exactly one
 * matched text (its sha256, so the allowlist holds no secret and a different
 * value in the same file is still a finding). A near-copy entry lets one
 * public file share text with the private sources its `sources` patterns
 * name (`*` matches anything but `#`; a diff's sources are its sections,
 * `diffs/<fixture>#<changed path>`, see `nearCopySources`), and with no
 * other: a shingle counts unless every private source holding it matches.
 * So `diffs/*#config.nims` lets a repository's `config.nims` share the
 * hunks that change another repository's copy of it, while a plan, a fleet
 * record or any other hunk pasted into that file is still a finding. Every
 * entry needs a `reason`, and an entry no finding used is itself a finding,
 * so the list cannot outlive the reasons it records.
 */
export function loadAllowlist(path = join(here, "public-tree-allowlist.json")) {
  const empty = { credentials: [], nearCopy: [] };
  if (!existsSync(path)) return empty;
  const data = JSON.parse(readFileSync(path, "utf8"));
  const out = { credentials: data.credentials ?? [], nearCopy: data.nearCopy ?? [] };
  for (const entry of [...out.credentials, ...out.nearCopy]) {
    if (typeof entry.reason !== "string" || entry.reason.trim().length < 20) {
      throw new Error(`allowlist entry for ${entry.file} has no reason; every entry must say why it is a false positive`);
    }
  }
  for (const entry of out.credentials) {
    if (!entry.file || !entry.rule || !/^[0-9a-f]{64}$/.test(entry.sha256 ?? "")) {
      throw new Error(`credential allowlist entry for ${entry.file} needs file, rule and the sha256 of the matched text`);
    }
  }
  for (const entry of out.nearCopy) {
    const sources = entry.sources;
    // A pattern must name a section (`#`): a whole fixture file, or a whole
    // class of them, is what the allowlist must not be able to wave through.
    if (!entry.file || !Array.isArray(sources) || sources.length === 0 || !sources.every((s) => typeof s === "string" && /#[^*]/.test(s))) {
      throw new Error(`near-copy allowlist entry for ${entry.file} needs file and sources naming diff sections (diffs/<fixture>#<path>)`);
    }
  }
  return out;
}

/**
 * What a public-tree scan needs: the exact-copy fingerprints, the near-copy
 * index (null when skipped), the literal secrets and the allowlist. `used`
 * collects the allowlist entries a scan applied.
 */
export function publicTreeContext({
  designDir = privateDesignDir,
  fixtureDir = privateFixtureDir,
  syntheticDir = syntheticFixtureDir,
  secrets = localSecrets(),
  allowlist = loadAllowlist(),
} = {}) {
  return {
    fingerprints: privateFingerprints(designDir),
    nearIndex: nearCopyIndexFor(fixtureDir, syntheticDir),
    secrets,
    allowlist,
    used: new Set(),
  };
}

/**
 * Findings for private data and credentials in the public repository at
 * `root`, and what the scan read (`stats`), so the caller can print what was
 * skipped. The self-test's plants and the real check both come through here.
 */
export function checkPublicTree(root, context) {
  const findings = [];
  const { fingerprints, nearIndex, secrets, allowlist, used } = context;
  const { hashes, sessionIds } = fingerprints;
  const stats = { files: 0, text: 0, textBytes: 0, binary: 0, oversize: [] };
  for (const path of committableFiles(root)) {
    let stat;
    try {
      stat = statSync(path);
    } catch {
      continue; // listed but deleted in the worktree
    }
    if (!stat.isFile() || stat.size === 0) continue;
    stats.files++;
    const file = relative(resolve(root, ".."), path);
    if (stat.size > maxScannedBytes) {
      stats.oversize.push(`${file} (${stat.size} bytes, not read)`);
      continue;
    }
    const bytes = readFileSync(path);
    const digest = createHash("sha256").update(bytes).digest("hex");
    if (hashes.has(digest)) {
      findings.push({ rule: "private-fixture-in-public-repo", file, line: 0, preview: `copy of ${hashes.get(digest)}` });
      continue;
    }
    if (bytes.includes(0)) {
      stats.binary++; // binary; only an exact copy can match
      continue;
    }
    if (stat.size > maxTextBytes) {
      stats.oversize.push(`${file} (${stat.size} bytes, exact-copy check only)`);
      continue;
    }
    stats.text++;
    stats.textBytes += stat.size;
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
    if (nearIndex) {
      const allowed = allowlist.nearCopy.filter((e) => e.file === file);
      const patterns = allowed.flatMap((e) => e.sources.map(sourcePattern));
      const allowSource = patterns.length > 0 ? (name) => patterns.some((re) => re.test(name)) : null;
      const regions = nearCopyRegions(text, nearIndex, allowSource);
      for (const region of regions) {
        findings.push({
          rule: "private-near-copy-in-public-repo",
          file,
          line: region.line,
          preview: `${region.covered} non-blank characters shared with ${region.source}`,
        });
      }
      // An entry is used when, without it, the file would hold more.
      if (allowed.length > 0 && nearCopyRegions(text, nearIndex).length > regions.length) for (const e of allowed) used.add(e);
    }
    for (const finding of ruleFindings(text, file, credentialRules, secrets, { sourceTree: true })) {
      const sha = createHash("sha256").update(finding.match).digest("hex");
      const entry = allowlist.credentials.find((e) => e.file === file && e.rule === finding.rule && e.sha256 === sha);
      if (entry) {
        used.add(entry);
        continue;
      }
      findings.push(finding);
    }
  }
  return { findings, stats };
}

/**
 * The allowlist entries for the repositories in `scanned` (directory names)
 * that no finding used: stale entries are findings, so a reason cannot stay
 * on the list after its false positive is gone. Near-copy entries are judged
 * only when the near-copy part ran.
 */
export function unusedAllowlistEntries(context, scanned) {
  const inScope = (e) => scanned.includes(e.file.split("/")[0]);
  const stale = context.allowlist.credentials.filter((e) => inScope(e) && !context.used.has(e));
  if (context.nearIndex) stale.push(...context.allowlist.nearCopy.filter((e) => inScope(e) && !context.used.has(e)));
  return stale.map((e) => ({ rule: "allowlist-entry-unused", file: e.file, line: 0, preview: e.rule ?? `near copy of ${e.sources.join(", ")}` }));
}
/**
 * What a clean public-tree result may claim, from what the context could
 * check: an "ok" line names only the rules that ran, so a skipped part never
 * reads as a part that found nothing (Silent self-pass audit).
 */
function publicClaims(context) {
  const claims = ["credential", "private manifest"];
  if (context.fingerprints.hashes.size > 0) claims.push("copy of a private fixture or design document");
  if (context.fingerprints.sessionIds.size > 0) claims.push("private session id");
  if (context.nearIndex) claims.push("near copy of a private fixture");
  return claims.length > 1 ? `${claims.slice(0, -1).join(", ")} or ${claims.at(-1)}` : claims[0];
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

/** UTF-8 length of `text`. */
function bytesOf(text) {
  return Buffer.byteLength(text, "utf8");
}

/**
 * About `size` bytes from the middle of `text`, cut at line boundaries: what
 * someone pasting "a bit of" a fixture would take.
 */
export function excerptOf(text, size) {
  const middle = Math.max(0, Math.floor((text.length - size) / 2));
  const start = text.lastIndexOf("\n", middle) + 1;
  const end = text.indexOf("\n", start + size);
  return text.slice(start, end < 0 ? text.length : end + 1);
}

/** `text` with the letter or digit nearest its middle replaced by another. */
export function changeOneCharacter(text) {
  for (let d = 0; d < text.length; d++) {
    for (const i of [Math.floor(text.length / 2) + d, Math.floor(text.length / 2) - d]) {
      const c = text[i];
      if (c && /[A-Za-z0-9]/.test(c)) return text.slice(0, i) + (c === "Q" ? "Z" : "Q") + text.slice(i + 1);
    }
  }
  throw new Error("no letter or digit to change");
}

/** `text`'s words re-wrapped to lines of at most `width` columns. */
export function reflow(text, width) {
  const lines = [];
  let line = "";
  for (const word of text.split(/\s+/).filter(Boolean)) {
    if (line && line.length + 1 + word.length > width) {
      lines.push(line);
      line = word;
    } else line = line ? `${line} ${word}` : word;
  }
  if (line) lines.push(line);
  return `${lines.join("\n")}\n`;
}

/**
 * About `bytes` bytes of deterministic generated text, one line per call of
 * `line(words)` with eight generated words: a stand-in for private prose and
 * code that shares nothing with the synthetic set.
 */
function standInText(seed, bytes, line) {
  const out = [];
  let size = 0;
  for (let n = 0; size < bytes; n++) {
    const h = createHash("sha256").update(`${seed}:${n}`).digest("hex");
    const words = [];
    for (let w = 0; w < 8; w++) words.push(`w${h.slice(w * 8, w * 8 + 3 + (parseInt(h[w * 8], 16) % 5))}`);
    const text = line(words);
    out.push(text);
    size += text.length + 1;
  }
  return `${out.join("\n")}\n`;
}

export function selfTest({ fixtureDir, privateDir }) {
  const results = [];
  const scratch = mkdtempSync(join(tmpdir(), "ah-scrub-selftest-"));
  // A literal secret this run "knows", as `localSecrets` knows the ah API key.
  const plantedSecret = `stand-in-secret-${randomBytes(12).toString("hex")}`;
  try {
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
    const standIn = !source || !existsSync(join(source, "manifest.json"));
    if (standIn) {
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
      // The synthetic set's shingles are excluded from the near-copy index, so
      // a stand-in made only of it would index nothing the plants could copy.
      // A plan and a diff of generated text stand in for private prose and
      // code; they are what the excerpt plants are cut from.
      writeFileSync(join(source, "plans/stand-in.milestones.org"), standInText("plan", 8000, (words) => words.join(" ")));
      writeFileSync(
        join(source, "diffs/stand-in.diff"),
        standInText("diff", 8000, (words) => `+    let ${words[0]}_${words[1]} = ${words[2]}(${words.slice(3).join(", ")})`),
      );
      const m = JSON.parse(readFileSync(join(source, "manifest.json"), "utf8"));
      m.fixtureSet = "private";
      writeFileSync(join(source, "manifest.json"), JSON.stringify(m, null, 2));
    }
    const context = publicTreeContext({
      designDir: dirname(source),
      fixtureDir: source,
      syntheticDir: fixtureDir,
      secrets: [plantedSecret],
      allowlist: { credentials: [], nearCopy: [] },
    });
    const sessions = JSON.parse(readFileSync(join(source, "fleet/sessions.json"), "utf8"));
    const publicRepo = (label) => {
      const root = join(scratch, `public-${label}`);
      mkdirSync(join(root, "fixtures"), { recursive: true });
      writeFileSync(join(root, "README.md"), "a public repository\n");
      return root;
    };
    // A plant in a public repository counts as caught only when the scratch
    // repository was clean before it and the expected rule fires after it.
    const plantInPublic = (label, expectedRule, mutate) => {
      const root = publicRepo(label.replace(/[^a-z0-9]+/gi, "-").slice(0, 40));
      const baseline = checkPublicTree(root, context).findings.length;
      const detail = mutate(root) ?? "";
      const { findings } = checkPublicTree(root, context);
      results.push({
        label: `${label}${detail ? ` (${detail})` : ""}`,
        expectedRule,
        caught: baseline === 0 && findings.some((f) => f.rule === expectedRule),
        findings: findings.length,
      });
    };
    plantInPublic("private fleet snapshot copied into a public repository", "private-fixture-in-public-repo", (root) => {
      cpSync(join(source, "fleet/sessions.json"), join(root, "fixtures/sessions.json"));
    });
    plantInPublic("edited excerpt of the private snapshot in a public repository", "private-session-id-in-public-repo", (root) => {
      const excerpt = { items: [{ ...sessions.items[0], priority: "edited so no hash matches" }] };
      writeFileSync(join(root, "fixtures/excerpt.json"), JSON.stringify(excerpt));
    });
    plantInPublic("private manifest in a public repository", "private-manifest-in-public-repo", (root) => {
      const m = JSON.parse(readFileSync(join(source, "manifest.json"), "utf8"));
      m.note = "edited so no hash matches";
      writeFileSync(join(root, "fixtures/manifest.json"), JSON.stringify(m, null, 2));
    });

    // Near copies: excerpts of a private diff and a private plan, edited so
    // neither the exact-copy nor the session-id rule can see them.
    const largest = (kind) => {
      if (standIn) return join(source, kind === "diffs" ? "diffs/stand-in.diff" : "plans/stand-in.milestones.org");
      const files = walk(join(source, kind)).map((p) => [p, statSync(p).size]).sort((a, b) => b[1] - a[1]);
      return files[0][0];
    };
    const diffText = readFileSync(largest("diffs"), "utf8");
    const planText = readFileSync(largest("plans"), "utf8");
    const nearCopyRule = "private-near-copy-in-public-repo";
    const where = (kind, text) => `${bytesOf(text)} bytes of a ${standIn ? "stand-in" : "private"} ${kind}`;
    plantInPublic("excerpt of a private diff with one character changed", nearCopyRule, (root) => {
      const text = changeOneCharacter(excerptOf(diffText, 3000));
      writeFileSync(join(root, "notes.patch"), text);
      return where("diff", text);
    });
    plantInPublic("short excerpt of a private plan with one character changed", nearCopyRule, (root) => {
      const text = changeOneCharacter(excerptOf(planText, 300));
      writeFileSync(join(root, "docs.md"), text);
      return where("plan", text);
    });
    plantInPublic("excerpt of a private plan reflowed to another width", nearCopyRule, (root) => {
      const text = reflow(excerptOf(planText, 1500), 52);
      writeFileSync(join(root, "plan.txt"), text);
      return where("plan", text);
    });
    plantInPublic("short excerpt of a private plan wrapped into a Nim doc comment", nearCopyRule, (root) => {
      // Each line wrapped at 32 columns, as an editor wraps a comment: the
      // `##` that starts every continuation line sits where the private text
      // has none, so only dropping line leaders keeps those shingles whole.
      const text = changeOneCharacter(excerptOf(planText, 400));
      const wrapped = text.split("\n").flatMap((l) => reflow(l, 32).trimEnd().split("\n"));
      writeFileSync(join(root, "notes.nim"), `proc notes*() =\n${wrapped.map((l) => `  ## ${l}`).join("\n")}\n  discard\n`);
      return where("plan", text);
    });
    plantInPublic("excerpt of a private diff reindented", nearCopyRule, (root) => {
      const text = excerptOf(diffText, 1500).split("\n").map((l) => `\t    ${l.replace(/^\s+/, "")}`).join("\n");
      writeFileSync(join(root, "snippet.nim"), text);
      return where("diff", text);
    });

    // An allowlisted shared file -- an entry letting it share text with the
    // one private source it legitimately copies -- must still fail when a
    // private plan excerpt is pasted into it: the entry covers that source,
    // not the file. Clean before the paste, with the entry applied, or the
    // plant proves nothing.
    {
      const root = publicRepo("allowlisted-shared-file");
      const shared = excerptOf(diffText, 1200);
      writeFileSync(join(root, "config.nims"), shared);
      const file = relative(resolve(root, ".."), join(root, "config.nims"));
      const sharedWith = nearCopyRegions(shared, context.nearIndex).map((r) => r.source);
      const withEntry = {
        ...context,
        allowlist: { credentials: [], nearCopy: [{ file, sources: [...new Set(sharedWith)], reason: "self-test: a shared file" }] },
        used: new Set(),
      };
      const baseline = sharedWith.length > 0 ? checkPublicTree(root, withEntry).findings.length : -1;
      writeFileSync(join(root, "config.nims"), `${shared}\n#[\n${changeOneCharacter(excerptOf(planText, 400))}]#\n`);
      const { findings } = checkPublicTree(root, withEntry);
      results.push({
        label: `private plan excerpt pasted into an allowlisted shared file (allowed: ${[...new Set(sharedWith)].join(", ") || "nothing"}; ${baseline} finding(s) before the paste)`,
        expectedRule: nearCopyRule,
        caught: baseline === 0 && findings.some((f) => f.rule === nearCopyRule),
        findings: findings.length,
      });
    }

    // Credentials outside every fixture set: the public-tree credential rules.
    plantInPublic("GitHub token in a public source file", "github-token", (root) => {
      const token = "ghp_" + randomBytes(27).toString("base64").replace(/[^A-Za-z0-9]/g, "b").slice(0, 36);
      writeFileSync(join(root, "deploy.mjs"), `export const pushToken = "${token}";\n`);
    });
    plantInPublic("API key assigned in a public configuration file", "assigned-secret", (root) => {
      writeFileSync(join(root, "app.toml"), `[service]\napi_key = "${randomBytes(20).toString("hex")}"\n`);
    });
    plantInPublic("this machine's literal secret in a public document", "local-secret", (root) => {
      writeFileSync(join(root, "SETUP.md"), `Run it with the key ${plantedSecret} exported.\n`);
    });

    // The negative controls: what a public repository legitimately holds must
    // NOT be reported -- the synthetic set itself, and source code that names
    // tokens without holding one (the classes `isSourceCodeName` explains).
    const control = (label, fill) => {
      const root = publicRepo(label.replace(/[^a-z0-9]+/gi, "-").slice(0, 40));
      fill(root);
      const { findings } = checkPublicTree(root, context);
      results.push({ label: `negative control: ${label}`, expectedRule: "(none)", caught: findings.length === 0, findings: findings.length, control: true });
    };
    control("the synthetic set in a public repository", (root) => {
      cpSync(fixtureDir, join(root, "fixtures/agent-harbor"), { recursive: true });
    });
    control("source code that names tokens", (root) => {
      writeFileSync(
        join(root, "grammar.js"),
        [
          "{ token: 'string.delimiter', next: '@pop' },",
          "let token = OriginContinuationToken(raw)",
          "const secret = process.env.CT_TEST_SECRET;",
          'git clone "https://x-access-token:${GH_TOKEN}@github.com/org/repo"',
          "",
        ].join("\n"),
      );
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
      console.error("scrub-check self-test: FAILED: a planted secret, private fixture or excerpt went undetected, or a negative control was reported");
      process.exit(1);
    }
    console.log("scrub-check self-test: ok (every plant made the check fail; the negative controls passed)");
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
  const started = Date.now();
  const context = publicTreeContext();
  let nearCopyStatus;
  if (context.nearIndex) {
    const { hashes, fileCount, sourceCount, removed } = context.nearIndex;
    nearCopyStatus = `near-copy checked (${hashes.size} sampled ${shingleSize}-character shingles of ${fileCount} private fixture file(s) in ${sourceCount} source(s), ${removed} shared with the synthetic set dropped; a finding is a region of at least ${minRegion} non-blank characters)`;
  } else {
    // Loud on purpose (Silent self-pass audit): a skipped part must never read
    // like a part that ran and found nothing.
    nearCopyStatus = `near-copy SKIPPED (no private fixtures at ${privateFixtureDir})`;
    console.error("scrub-check: ======================================================================");
    console.error(`scrub-check: NEAR-COPY CHECK SKIPPED: there are no private fixtures at ${privateFixtureDir},`);
    console.error("scrub-check: so nothing says the public trees hold no edited excerpt of them. Only the");
    console.error(`scrub-check: rules this summary names ran over the public trees: ${publicClaims(context)}.`);
    console.error("scrub-check: ======================================================================");
  }
  let textFiles = 0;
  for (const root of publicRoots) {
    const { findings, stats } = checkPublicTree(root, context);
    textFiles += stats.text;
    for (const skipped of stats.oversize) console.log(`scrub-check: skipped (over ${maxTextBytes} bytes): ${skipped}`);
    const read = `${stats.text} text file(s), ${(stats.textBytes / 1048576).toFixed(1)} MiB, read; ${stats.binary} binary file(s) checked for exact copies only; ${stats.oversize.length} over the size cap`;
    // Positive control (trap 4): a scan that read no text file passes everything.
    if (stats.text === 0) {
      console.error(`scrub-check: the public repository ${root} yielded no text file to scan (${stats.files} file(s) listed); refusing to call it clean`);
      process.exit(2);
    }
    if (findings.length > 0) {
      report(findings);
      console.error(`scrub-check: FAILED: ${findings.length} finding(s) in the public repository ${root} (${read})`);
      failed = true;
    } else {
      console.log(`scrub-check: ok: no ${publicClaims(context)} in the public repository ${root} (${read})${context.nearIndex ? "" : "; near copies NOT checked"}`);
    }
  }
  const stale = unusedAllowlistEntries(context, publicRoots.map((r) => basename(r)));
  if (stale.length > 0) {
    report(stale);
    console.error(`scrub-check: FAILED: ${stale.length} allowlist entr(y/ies) in public-tree-allowlist.json no longer match anything; remove them`);
    failed = true;
  }
  console.log(
    `scrub-check: public trees: ${publicRoots.length} repositor(y/ies), ${textFiles} text file(s); credentials checked; ${nearCopyStatus}; ${context.used.size} allowlist entr(y/ies) applied; ${((Date.now() - started) / 1000).toFixed(1)} s`,
  );
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
