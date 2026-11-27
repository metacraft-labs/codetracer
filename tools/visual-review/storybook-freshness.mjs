// Is `storybook/storybook-static` a picture of the tree that is on disk now?
//
// EXISTENCE IS NOT FRESHNESS. `tools/visual-review/capture-storybook.mjs` used
// to ask `existsSync(staticDir)` and print "Run without --no-build first" when
// it was not there — a message naming the exact condition the check could not
// detect. `storybook-static` is a build output deleted ONLY by a real
// `just storybook-build` (justfile), and `--no-build` is a documented
// invocation (`storybook/README.md`, `tools/visual-review/reference-coverage.md`),
// so the visual-review corpus could be — and silently was allowed to be —
// photographs of components from several commits ago, reviewed and rated as the
// current design with nothing in the report saying so.
//
// A SEPARATE MODULE, not a function inside the capture script, for one reason:
// the capture script resolves Playwright out of `storybook/node_modules` at
// import time, so nothing that imports it can run without a full storybook
// install. This guard is the part that must be verifiable on a stock runner
// against a synthetic tree, which is what `ci/test/stale-artefact-guards-test.sh`
// does with it.

import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, lstatSync, readFileSync, readdirSync, realpathSync, renameSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, isAbsolute, join, parse, resolve, sep } from "node:path";

// firstNewerThan(paths, referenceMs) -> the first file found newer than the
// reference, or null. Early-exits, so a large tree costs one walk and stops at
// the first piece of evidence; the caller only ever names ONE offending file.
//
// Same shape and the same deliberate conservatism as `ctdr_require_not_stale`
// in `scripts/docs/deep-review-capture-lib.sh` and as the book-page check in
// `scripts/docs/capture-book-page-screenshot.mjs`: an mtime that merely LOOKS
// newer — a `git checkout` rewriting a file with identical bytes — is enough to
// refuse, because the remedy is a rebuild and the alternative is a published
// review of a product that no longer exists.
//
// `isOutput(path, stat)`, when given, names files that are build outputs
// rather than sources, which are passed over.
export function firstNewerThan(paths, referenceMs, isOutput = () => false) {
  const walk = (target) => {
    let stat;
    try {
      stat = statSync(target);
    } catch {
      return null; // a source that is not there cannot be newer than anything
    }
    if (!stat.isDirectory()) {
      if (isOutput(target, stat)) return null;
      return stat.mtimeMs > referenceMs ? target : null;
    }
    for (const entry of readdirSync(target, { withFileTypes: true })) {
      const found = walk(join(target, entry.name));
      if (found) return found;
    }
    return null;
  };
  for (const path of paths) {
    const found = walk(path);
    if (found) return found;
  }
  return null;
}

// isCompiledNimProgram(path, stat) -> true for the program `nim c foo.nim`
// writes beside its source when no `-o` is given: an extensionless
// executable `foo` next to `foo.nim` (git-ignored, e.g.
// src/frontend/tests/agent_harbor_story_data_test). It is an output of a test
// compile, not a source of the components bundle; counted as a source, merely
// compiling a test made the next render check refuse a fresh build as stale.
export function isCompiledNimProgram(path, stat) {
  if (!stat.isFile()) return false;
  // Windows: `foo.exe` (there is no executable bit to read).
  if (/\.exe$/i.test(path)) return existsSync(path.replace(/\.exe$/i, ".nim"));
  const name = path.split(/[\\/]/).pop();
  return (stat.mode & 0o111) !== 0 && !name.includes(".") && existsSync(`${path}.nim`);
}

// The stamp `just build-storybook-components` (scripts/build-storybook-components.sh)
// sets to the START of every successful compile of
// `storybook/dist/components.js`. `nim js` leaves the bundle itself untouched
// when its bytes do not change, so the bundle's own mtime says when it last
// CHANGED and the stamp says when it was last COMPILED:
// the bundle is current with its Nim sources as of the later of the two, and
// the stamp is not a source of `storybook-static` (it is not the bundle).
export const COMPONENTS_STAMP = "components.js.compiled";

// componentsCompiledAt(bundle) -> when the bundle at `bundle` was last
// compiled: the later of its own mtime and its stamp's (0 when absent).
export function componentsCompiledAt(bundle) {
  const at = (path) => {
    try {
      return statSync(path).mtimeMs;
    } catch {
      return 0;
    }
  };
  return Math.max(at(bundle), at(join(dirname(bundle), COMPONENTS_STAMP)));
}

// ---------------------------------------------------------------------------
// THE INPUTS OF THE COMPONENTS BUNDLE THAT ARE NOT UNDER `src/frontend`.
//
// The bundle compiles in modules from the sibling checkouts `config.nims` puts
// on the search path (nim-agents, nim-agents-isonim-viewmodels, isonim, ...),
// files embedded with `staticRead` (codetracer's `test-programs/`, the
// Agent Harbor fixture set), and whatever the Nim configuration files say. A
// bundle built before any of them changed shows the old inputs, and comparing
// it with `src/frontend` alone passed it as fresh: a bundle built before a
// fixture refresh was photographed as the current design.
//
// So the recipe RECORDS what the compile read, and the guard compares the
// record with the tree. Nothing here guesses the list: the modules come from
// the compiler's own dependency file (`nim js --genScript:on` writes
// `<nimcache>/<project>.deps`), and the embedded fixture files from the
// compile itself (`storybook_components.nim` writes `AgentHarborFixtureInputs`
// out when `-d:storybookFixtureInputsOut` is set), because the compiler's list
// names modules, not `staticRead` targets.
//
// The record, `storybook/dist/components.js.inputs.json`:
//
//   files    every input file, compared by mtime with the compile. The
//            modules (Nix store paths excepted: a store path is immutable),
//            the literal `staticRead`/`slurp` targets beside them, the
//            embedded fixture files, and the Nim configuration files that
//            exist among those the compile loads.
//   absent   paths whose ABSENCE decided what was compiled: configuration
//            files that do not exist, a literal `staticRead` target missing
//            beside its module, the private fixture manifest whose absence
//            chose the synthetic set. One that now exists is refused.
//   dirs     the checkout of every module that reads at compile time in a way
//            the scan below cannot resolve (a computed `staticRead` path, a
//            `gorgeEx`), walked for any file newer than the compile. Such a
//            read can name a git-ignored build output (isonim's
//            `build/tailwind-styles.json`), which no git state shows. This
//            over-approximates on purpose: a false refusal costs a rebuild,
//            a false acceptance a review of a design that no longer exists.
//   repos    every git checkout other than this one that holds a module, and
//            this one when it is in `dirs`: its HEAD and whether it had
//            uncommitted changes to tracked files. A checkout that moved, or
//            became dirty or clean, is refused. This catches a sibling switched
//            to another commit whose changed files keep old mtimes.
//   fixtures the Agent Harbor fixture set the compile embedded: its root and a
//            content digest of every file it embedded. A refresh that keeps
//            the files' mtimes (`cp -p`, `rsync -a`, an archive) is refused.
//
// The record is written beside the bundle and the stamp, and like the stamp it
// is not a source of `storybook-static`: every recompile rewrites it.
export const INPUTS_RECORD = "components.js.inputs.json";
export const INPUTS_RECORD_VERSION = 1;

const REBUILD_REMEDY =
  "Rebuild with `just storybook-build` (or `just build-storybook-components` for the bundle alone), then run this again.";

// gitCheckoutOf(path) -> the nearest directory containing the file `path`
// that holds a `.git` entry (a directory, or the file a worktree or submodule has), or null.
// Lexical, so it does not depend on a `git` binary.
export function gitCheckoutOf(path) {
  let dir = dirname(resolve(path));
  for (;;) {
    if (existsSync(join(dir, ".git"))) return dir;
    const parent = dirname(dir);
    if (parent === dir) return null;
    dir = parent;
  }
}

const realOrSelf = (path) => {
  try {
    return realpathSync(path);
  } catch {
    return resolve(path);
  }
};

// checkoutState(dir) -> { head, dirty } of the git checkout at `dir`, or null
// when it is not one any more. `dirty` counts changes to TRACKED files only:
// an untracked file is not compiled unless a module imports it, and then the
// importing module's own change is what is seen. GIT_OPTIONAL_LOCKS=0 keeps
// `git status` from refreshing the index, so checking a shared checkout never
// writes to it.
export function checkoutState(dir) {
  const git = (...args) =>
    execFileSync("git", ["-C", dir, ...args], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
      env: { ...process.env, GIT_OPTIONAL_LOCKS: "0" },
    });
  try {
    const head = git("rev-parse", "HEAD").trim();
    const dirty = git("status", "--porcelain", "--untracked-files=no").trim().length > 0;
    return { head, dirty };
  } catch {
    return null;
  }
}

// fixtureDigest(paths) -> a sha256 over each embedded file's path and bytes,
// in order, or null when one of them cannot be read.
export function fixtureDigest(paths) {
  const hash = createHash("sha256");
  for (const path of paths) {
    let bytes;
    try {
      bytes = readFileSync(path);
    } catch {
      return null;
    }
    hash.update(path).update("\0").update(bytes).update("\0");
  }
  return `sha256:${hash.digest("hex")}`;
}

// stripNimComment(line) -> the line without its `#` comment, keeping a `#`
// inside a double-quoted string. Enough for the scan below, which only needs
// to not mistake prose ("not a shell `test -f` through `gorgeEx`") for code.
function stripNimComment(line) {
  let inString = false;
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (c === '"' && line[i - 1] !== "\\") inString = !inString;
    else if (c === "#" && !inString) return line.slice(0, i);
  }
  return line;
}

// compileTimeReads(modulePath, text) -> { files, absent, unresolved }: what the
// module reads from the file system at compile time, as far as a scan of its
// text can tell. A literal `staticRead("x")` / `slurp("x")` is resolved
// against the module's directory, as the compiler first resolves it; found, it
// is a file, missing, it is absent (the compiler then searched the `--path`
// directories, which this does not follow). Any other mention of
// `staticRead` / `slurp` -- a computed argument, command syntax with a
// computed argument (`staticRead path`), method syntax (`path.staticRead`,
// `"x".slurp`), or the bare name passed as a value -- and any `gorge`,
// `gorgeEx` or `staticExec`, is `unresolved`: the caller then compares the
// module's whole checkout instead. Erring towards `unresolved` only widens
// what is compared; missing a read would accept a stale bundle.
// See https://nim-lang.org/docs/manual.html#procedures-command-invocation-syntax
// and https://nim-lang.org/docs/manual.html#procedures-method-call-syntax.
export function compileTimeReads(modulePath, text) {
  const files = [];
  const absent = [];
  let unresolved = false;
  const literal = /\b(?:staticRead|slurp)\s*\(?\s*"((?:[^"\\]|\\.)*)"\s*\)?/g;
  const anyRead = /\b(?:staticRead|slurp)\b/g;
  for (const raw of text.split(/\r?\n/)) {
    const line = stripNimComment(raw);
    if (/\b(?:gorge|gorgeEx|staticExec)\b/.test(line)) unresolved = true;
    // A literal read is one whose name is not the method of a dotted call:
    // `x.staticRead("y")` passes `x` as the first argument, not `"y"`.
    const isMethod = (index) => /\.\s*$/.test(line.slice(0, index));
    const literals = [...line.matchAll(literal)].filter((m) => !isMethod(m.index));
    const literalAt = new Set(literals.map((m) => m.index));
    // Every mention of the name that is not one of those literals.
    if ([...line.matchAll(anyRead)].some((m) => !literalAt.has(m.index))) unresolved = true;
    for (const m of literals) {
      // A literal that continues (`staticRead("dir/" & name)`) is computed.
      const after = line.slice(m.index + m[0].length).trimStart();
      if (!m[0].trimEnd().endsWith(")") && after.startsWith("&")) {
        unresolved = true;
        continue;
      }
      const target = isAbsolute(m[1]) ? m[1] : join(dirname(modulePath), m[1]);
      (existsSync(target) ? files : absent).push(target);
    }
  }
  return { files, absent, unresolved };
}

// nimConfigCandidates(projectFile, repoRoot, env) -> every configuration file
// `nim` would load for `projectFile`, whether or not it exists: the user's
// `nim.cfg` / `config.nims`, the same two in every parent directory of the
// project's directory and in that directory itself, the project's own
// `.nimcfg`, `.nim.cfg` and `.nims`, and the files this checkout's
// `config.nims` reads for search paths (`reprobuild.paths`, `repro.paths`).
// See https://nim-lang.org/docs/nimc.html#compiler-usage-configuration-files.
export function nimConfigCandidates(projectFile, repoRoot, env = process.env) {
  const userDir = env.XDG_CONFIG_HOME || join(env.HOME || homedir(), ".config");
  const out = [join(userDir, "nim", "nim.cfg"), join(userDir, "nim", "config.nims")];
  const projectDir = dirname(resolve(projectFile));
  const chain = [];
  for (let dir = projectDir; ; dir = dirname(dir)) {
    chain.unshift(dir);
    if (dirname(dir) === dir) break;
  }
  for (const dir of chain) out.push(join(dir, "nim.cfg"), join(dir, "config.nims"));
  const stem = join(projectDir, parse(projectFile).name);
  out.push(`${stem}.nimcfg`, `${stem}.nim.cfg`, `${stem}.nims`);
  out.push(join(repoRoot, "reprobuild.paths"), join(repoRoot, "repro.paths"));
  return out;
}

const isNixStore = (path) => path.startsWith(`${sep}nix${sep}store${sep}`);

// Directories a `dirs` walk does not enter: git's own, installed packages,
// Nim's intermediates, and the StoryBook outputs (this bundle, its record and
// the corpus are written after the compile starts, every time).
const WALK_SKIPPED = new Set([".git", "node_modules", ".nimcache", "storybook-static"]);

// isTestCompileOutput(path) -> true for what a test compile writes beside its
// source: the program `nim c foo.nim` writes as `foo` (see
// `isCompiledNimProgram`) or the `foo.js` that `nim js foo.nim` writes.
function isTestCompileOutput(path, stat) {
  if (path.endsWith(".js") && existsSync(path.replace(/\.js$/, ".nim"))) return true;
  return isCompiledNimProgram(path, stat);
}

// firstNewerInCheckout(dir, referenceMs) -> the first file under `dir` newer
// than the reference, or null. Symbolic links are compared by their own mtime
// and not followed, so a link into another tree (or a cycle) is not walked.
export function firstNewerInCheckout(dir, referenceMs) {
  const walk = (target) => {
    let entries;
    try {
      entries = readdirSync(target, { withFileTypes: true });
    } catch {
      return null;
    }
    for (const entry of entries) {
      const path = join(target, entry.name);
      if (entry.isDirectory()) {
        if (WALK_SKIPPED.has(entry.name) || path.endsWith(join("storybook", "dist"))) continue;
        const found = walk(path);
        if (found) return found;
        continue;
      }
      let stat;
      try {
        stat = lstatSync(path);
      } catch {
        continue;
      }
      if (stat.mtimeMs > referenceMs && !isTestCompileOutput(path, stat)) return path;
    }
    return null;
  };
  return walk(dir);
}

// collectStorybookInputs({...}) -> the record described above.
//   repoRoot     this checkout
//   projectFile  the compiled module (`src/frontend/storybook_components.nim`)
//   depsText     the compiler's dependency file: one absolute path per line
//   fixture      what the compile wrote for `-d:storybookFixtureInputsOut`
//                ({ root, inputs, absent }), or null for a compile that
//                embeds no fixture set
export function collectStorybookInputs({ repoRoot, projectFile, depsText, fixture, env = process.env }) {
  const files = new Set();
  const absent = new Set();
  const checkouts = new Map(); // real path -> lexical path
  const dirs = new Map(); // real path -> lexical path
  const self = realOrSelf(gitCheckoutOf(join(repoRoot, "x")) ?? repoRoot);
  const modules = depsText
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line.length > 0 && !isNixStore(line));
  for (const module of modules) {
    files.add(module);
    let text = "";
    try {
      text = readFileSync(module, "utf8");
    } catch {
      text = ""; // a listed module that is gone is refused by the check
    }
    const reads = compileTimeReads(module, text);
    for (const f of reads.files) if (!isNixStore(f)) files.add(f);
    for (const a of reads.absent) absent.add(a);
    const checkout = gitCheckoutOf(module);
    if (reads.unresolved) {
      const dir = checkout ?? dirname(module);
      dirs.set(realOrSelf(dir), dir);
    }
    if (checkout === null) continue;
    const real = realOrSelf(checkout);
    if (real !== self || reads.unresolved) checkouts.set(real, checkout);
  }
  for (const candidate of nimConfigCandidates(projectFile, repoRoot, env)) {
    (existsSync(candidate) ? files : absent).add(candidate);
  }
  let fixtures = null;
  if (fixture !== null && fixture !== undefined) {
    for (const f of fixture.inputs) files.add(f);
    for (const a of fixture.absent) absent.add(a);
    fixtures = { root: fixture.root, inputs: fixture.inputs, digest: fixtureDigest(fixture.inputs) };
  }
  const repos = [...checkouts.values()].sort().map((path) => {
    const state = checkoutState(path);
    if (state === null) throw new Error(`cannot read the git state of ${path}, which the bundle compiled from`);
    return { path, ...state };
  });
  for (const f of files) absent.delete(f);
  return {
    version: INPUTS_RECORD_VERSION,
    files: [...files].sort(),
    absent: [...absent].sort(),
    dirs: [...dirs.values()].sort(),
    repos,
    fixtures,
  };
}

// writeStorybookInputs(path, record): written whole or not at all, so a
// recording that fails leaves no half record for the guard to trust.
export function writeStorybookInputs(path, record) {
  const tmp = `${path}.tmp-${process.pid}`;
  writeFileSync(tmp, `${JSON.stringify(record, null, 2)}\n`);
  renameSync(tmp, path);
}

// checkStorybookInputs(components, componentsAt) — throws unless every input
// the record beside `components` names is as it was when the bundle compiled.
export function checkStorybookInputs(components, componentsAt) {
  const recordPath = join(dirname(components), INPUTS_RECORD);
  const refuse = (what) => {
    throw new Error(`Stale storybook components: ${components} ${what}\n${REBUILD_REMEDY}`);
  };
  let record;
  let recordAt;
  try {
    recordAt = statSync(recordPath).mtimeMs;
    record = JSON.parse(readFileSync(recordPath, "utf8"));
  } catch {
    throw new Error(
      `Unrecorded storybook components: ${components} has no readable record of the inputs it was compiled from (${recordPath}).\n` +
        "Without it a change to a sibling checkout or to the fixture set cannot be seen.\n" +
        REBUILD_REMEDY,
    );
  }
  const lists = ["files", "absent", "dirs", "repos"];
  if (record?.version !== INPUTS_RECORD_VERSION || !lists.every((key) => Array.isArray(record[key]))) {
    refuse(`has an input record of another format (${recordPath}, version ${record?.version}).`);
  }
  // The recipe writes the record after the compile and then stamps the compile
  // with its START, so a record older than the compile was not written by it.
  if (recordAt < componentsAt) {
    refuse(`was compiled after its input record was written (${recordPath}): the record describes an older compile.`);
  }
  for (const repo of record.repos) {
    const now = checkoutState(repo.path);
    if (now === null) refuse(`was compiled from the checkout ${repo.path}, which is no longer a git checkout.`);
    if (now.head !== repo.head) {
      refuse(`was compiled from ${repo.path} at ${repo.head.slice(0, 12)}, which is now at ${now.head.slice(0, 12)}.`);
    }
    if (now.dirty !== repo.dirty) {
      refuse(
        repo.dirty
          ? `was compiled from ${repo.path} with uncommitted changes, which it no longer has.`
          : `was compiled from ${repo.path} with no uncommitted changes, and it now has some.`,
      );
    }
  }
  if (record.fixtures) {
    const digest = fixtureDigest(record.fixtures.inputs);
    if (digest !== record.fixtures.digest) {
      refuse(`embeds the Agent Harbor fixture set at ${record.fixtures.root}, which has changed since it was compiled.`);
    }
  }
  for (const file of record.files) {
    // The later of the link's and its target's mtime: a symbolic link
    // re-pointed at an older file is a changed input too.
    let mtimeMs;
    try {
      mtimeMs = Math.max(lstatSync(file).mtimeMs, statSync(file).mtimeMs);
    } catch {
      refuse(`was compiled from ${file}, which is gone.`);
    }
    if (mtimeMs > componentsAt) refuse(`is older than its input ${file}.`);
  }
  for (const dir of record.dirs) {
    const newer = firstNewerInCheckout(dir, componentsAt);
    if (newer) {
      refuse(
        `is older than ${newer}, in ${dir}, which the compile read from at compile time in a way the record cannot list file by file.`,
      );
    }
  }
  for (const path of record.absent) {
    if (existsSync(path)) refuse(`was compiled while ${path} did not exist, and it now does.`);
  }
}

// The stamp `just storybook-styles` (scripts/build-storybook-styles.sh) sets to
// the START of every successful compile of the stylesheets StoryBook draws,
// `src/build-debug-repro/frontend/styles/*.css`. It sits beside the
// `frontend` directory, not in it, so `storybook build` does not copy it into
// the corpus and it is no source of `storybook-static`. It does for the
// stylesheets what `COMPONENTS_STAMP` does for the bundle: the stylus edges are
// cached, so a build after an edit that leaves the CSS byte-identical (or a
// checkout that only rewrites a `.styl`'s mtime) need not rewrite a `.css`.
export const STYLES_STAMP = "frontend-styles.compiled";

// stylesheetsCompiledAt(stylesDir, stamp) -> { at, oldest }: when the compiled
// stylesheets in `stylesDir` were last compiled, as one set, and the oldest of
// them. `at` is the later of the stamp's mtime and the OLDEST stylesheet's
// mtime: every one of them is current as of then, and one older stylesheet is
// enough to draw a story with CSS from before an edit. `oldest` is null when
// there are no stylesheets.
export function stylesheetsCompiledAt(stylesDir, stamp) {
  let oldest = null;
  let entries = [];
  try {
    entries = readdirSync(stylesDir, { withFileTypes: true });
  } catch {
    entries = [];
  }
  for (const entry of entries) {
    if (!entry.isFile() || !entry.name.endsWith(".css")) continue;
    const path = join(stylesDir, entry.name);
    const mtimeMs = statSync(path).mtimeMs;
    if (oldest === null || mtimeMs < oldest.mtimeMs) oldest = { path, mtimeMs };
  }
  let stampAt = 0;
  try {
    stampAt = statSync(stamp).mtimeMs;
  } catch {
    stampAt = 0;
  }
  return { at: Math.max(stampAt, oldest === null ? 0 : oldest.mtimeMs), oldest };
}

// requireFreshStorybookStatic(repoRoot) — throws unless the storybook corpus is
// current with respect to everything it is made of.
//
// WHAT THE STATIC TREE IS MADE OF is not guessed here: `storybook/.storybook/
// main.ts` declares `staticDirs`, and `storybook build` COPIES each of them into
// `storybook-static/`. So the frontend build tree is physically inside this
// corpus, and a stale `storybook-static` is a photograph of an old renderer as
// much as of an old story file. The list below mirrors that `staticDirs` array
// plus the story/config sources webpack compiles; if `main.ts` grows another
// entry, add it here too.
export function requireFreshStorybookStatic(repoRoot) {
  const storybookDir = join(repoRoot, "storybook");
  const staticDir = join(storybookDir, "storybook-static");
  const built = join(staticDir, "index.html");

  if (!existsSync(built)) {
    throw new Error(
      `Missing ${built}. Run without --no-build first, or: just storybook-build`,
    );
  }
  const builtAt = statSync(built).mtimeMs;

  // `main.ts` uses the same build tree, exactly as here.
  const buildDir = "build-debug-repro";

  const sources = [
    join(storybookDir, ".storybook"),
    join(storybookDir, "stories"),
    join(storybookDir, "scripts"),
    join(storybookDir, "package.json"),
    join(storybookDir, "package-lock.json"),
    join(storybookDir, "dist"),
    join(repoRoot, "src/frontend/index.html"),
    // The stylesheet sources. `just storybook-build` compiles them into the
    // build tree below before it builds (`just storybook-styles`), so a corpus
    // older than a `.styl` file shows CSS from before that edit. The
    // components rule further down does not catch it: a `.styl` edit leaves
    // `components.js` byte-identical, so `just build-storybook-components`
    // moves only its stamp, and both rules then passed a corpus whose CSS
    // predated the edit.
    join(repoRoot, "src/frontend/styles"),
    join(repoRoot, `src/${buildDir}/frontend`),
    join(repoRoot, `src/${buildDir}/public`),
  ];

  // Neither the compile stamp nor the input record is a source of the corpus:
  // every recompile rewrites both, even one that leaves the bundle unchanged.
  const isStamp = (path) => basename(path) === COMPONENTS_STAMP || basename(path) === INPUTS_RECORD;
  const newer = firstNewerThan(sources, builtAt, isStamp);
  if (newer) {
    throw new Error(
      `Stale storybook corpus: ${built} is older than its source ${newer}.\n` +
        "These screenshots would be reviewed as the current design while showing an older one.\n" +
        "Rebuild with `just storybook-build` (i.e. run this without --no-build), then run this again.",
    );
  }

  // THE COMPILED STYLESHEETS AGAINST THEIR SOURCES. The rule above compares
  // the corpus with the `.styl` files and with the build tree it copies, and
  // neither catches a corpus built AFTER a stylesheet edit from a build tree
  // whose CSS was compiled BEFORE it: `npm run build-storybook` (or any
  // `storybook build` without `just storybook-styles`) copies whatever CSS the
  // last `just build-once` left, and the copy is newer than both. Measured
  // 2026-11-25 on codetracer bc0793acb4: a corpus built at 13:09 from `.styl`
  // files checked out at 13:06 carried CSS compiled on 2026-11-22, before the
  // ring became an `outline` and before the busy spinner existed; this guard
  // passed it, and the render check then refused three stories over play
  // assertions (`outlineStyle` 'none', spinner width 0) that were right about
  // the stylesheet and wrong about why. So the stylesheets are refused here,
  // before any story is drawn, naming the cause.
  const stylesDir = join(repoRoot, `src/${buildDir}/frontend/styles`);
  const stylSources = join(repoRoot, "src/frontend/styles");
  if (existsSync(stylSources)) {
    const { at: stylesAt, oldest } = stylesheetsCompiledAt(stylesDir, join(repoRoot, `src/${buildDir}`, STYLES_STAMP));
    if (oldest === null) {
      throw new Error(
        `Missing compiled stylesheets: ${stylesDir} has no .css, so the corpus draws no stylesheet.\n` +
          "Rebuild with `just storybook-build`, which compiles them (`just storybook-styles`), then run this again.",
      );
    }
    const newerStyl = firstNewerThan([stylSources], stylesAt);
    if (newerStyl) {
      throw new Error(
        `Stale storybook stylesheets: ${oldest.path} was compiled before its source ${newerStyl}.\n` +
          "The corpus would draw the CSS from before that edit.\n" +
          "Rebuild with `just storybook-build`, which compiles them (`just storybook-styles`), then run this again.",
      );
    }
  }

  // The components bundle is the other end of the same chain: `storybook-build`
  // depends on `build-storybook-components`, so `--no-build` skips BOTH, and a
  // `dist/components.js` compiled from Nim sources that have since changed is
  // stale even when the static tree faithfully copied it. When it was compiled is
  // `componentsCompiledAt`: `scripts/build-storybook-components.sh` stamps the start
  // of each successful compile beside the bundle. Nim leaves an output whose bytes did
  // not change with its old mtime, so without the stamp a bundle the recipe has just
  // built would be refused.
  const components = join(storybookDir, "dist", "components.js");
  if (existsSync(components)) {
    const componentsAt = componentsCompiledAt(components);
    const newerNim = firstNewerThan([join(repoRoot, "src/frontend")], componentsAt, isCompiledNimProgram);
    if (newerNim) {
      throw new Error(
        `Stale storybook components: ${components} is older than its source ${newerNim}.\n` +
          REBUILD_REMEDY,
      );
    }
    // And everything else it was compiled from: the sibling checkouts, the
    // embedded fixture set, the Nim configuration (see `INPUTS_RECORD`).
    checkStorybookInputs(components, componentsAt);
  }
}
