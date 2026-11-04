## ct_home_isolation_test — `CODETRACER_HOME` isolates EVERY per-user location,
## and every test entry point sets it.
##
## ## Why
##
## On 2026-09-23 `trace_index_test` and `trace_index_migration_test` wrote test
## recordings into a developer's real `trace_index.db` on Windows: they
## redirected `HOME` for their helper, and Nim's `getHomeDir` reads
## `USERPROFILE` there. LRS-6's review patched four suites to also set
## `USERPROFILE`/`LOCALAPPDATA`/`APPDATA` — an OS-specific list that the next
## suite would get wrong again. `CODETRACER_HOME` replaces the list with one
## variable every resolver honours (`src/common/ct_home.nim`, `libs/ct-home`).
##
## ## What this pins
##
##   1. BEHAVIOUR. This very process runs under a scratch `CODETRACER_HOME`
##      (the force-imported `state_isolation` module put it there before any
##      module initialised), and every path global CodeTracer computes at
##      start-up — the trace index, the recordings folder, the tmp and cache
##      dirs, the config dir — lies inside it. Make a resolver ignore
##      `CODETRACER_HOME` and these cases fail.
##   2. PRECEDENCE. While it is set, no OS variable (`HOME`, `USERPROFILE`,
##      `XDG_*`, `TMPDIR`, `APPDATA`, …) is consulted; while it is unset, every
##      location is exactly the historical one.
##   3. THE SWEEPS (source checks, so they hold on every OS before anyone runs
##      the suite there):
##        A. a test that redirects a child's home-ish variable also names
##           `CODETRACER_HOME` — the LRS-6 template, generalised;
##        B. every test ENTRY POINT (config.nims, the lane runner, the cargo
##           recipes, the db-backend harness, the GUI fixtures, the JS recipe)
##           still sets it — remove one and this fails by name;
##        C. no product source resolves a per-user location from an OS
##           variable without also going through `ct_home`;
##        C2. no CI script, `just` recipe or tool does either: the same rule
##           over `ci/`, `scripts/`, `tools/` and the `justfile`.
##
## The behavioural "the child lands in its scratch dir" pin for a SPAWNED
## process is `trace_index_test`'s "resolves its trace index INSIDE its scratch
## profile" case (and its twin in `trace_index_migration_test`).

import std/[os, strutils, unittest, sequtils]

import ct_home
import paths
import types
import config
import ../ct/globals
import ../ct/ci/ci_state
import ../ct/launch/grant_store
import ../frontend/viewmodel/host/native_state

let repoRoot = currentSourcePath.parentDir.parentDir.parentDir

proc norm(p: string): string =
  result = normalizedPath(absolutePath(p)).replace('\\', '/')
  when defined(windows):
    result = result.toLowerAscii

proc inside(path, root: string): bool =
  if path.len == 0 or root.len == 0:
    return false
  let p = norm(path)
  let r = norm(root).strip(leading = false, chars = {'/'})
  p == r or p.startsWith(r & "/")

proc isTestScratch(dir: string): bool =
  dir.len > 0 and (dir.inside(getTempDir()) or
                   fileExists(dir / ".codetracer-test-home"))

template withEnv(pairs: openArray[(string, string)]; body: untyped) =
  ## Set (or, for "", DELETE) each variable for `body`, then restore it.
  block:
    var saved: seq[(string, bool, string)] = @[]
    for (k, v) in pairs:
      saved.add((k, existsEnv(k), getEnv(k)))
      if v.len == 0: delEnv(k) else: putEnv(k, v)
    try:
      body
    finally:
      for (k, had, old) in saved:
        if had: putEnv(k, old) else: delEnv(k)

const Decoys = [
  ("HOME", "/decoy/home"), ("USERPROFILE", "/decoy/profile"),
  ("APPDATA", "/decoy/appdata"), ("LOCALAPPDATA", "/decoy/localappdata"),
  ("XDG_DATA_HOME", "/decoy/xdg-data"), ("XDG_CONFIG_HOME", "/decoy/xdg-config"),
  ("XDG_STATE_HOME", "/decoy/xdg-state"), ("XDG_CACHE_HOME", "/decoy/xdg-cache"),
  ("TMPDIR", "/decoy/tmpdir"), ("TEMP", "/decoy/temp"), ("TMP", "/decoy/tmp")]

proc codeLines(text, path: string): seq[string] =
  ## The lines of `text` that are not comments, by file kind.
  let ext = path.splitFile.ext
  let hashComments = ext in [".nim", ".nims", ".sh", ".py", ".toml", ""] or
                     path.endsWith("justfile")
  for line in text.splitLines:
    let s = line.strip
    if hashComments and s.startsWith("#"):
      continue
    if ext in [".rs", ".ts", ".js"] and
        (s.startsWith("//") or s.startsWith("*") or s.startsWith("/*")):
      continue
    result.add line

const HomeVars = ["HOME", "USERPROFILE", "APPDATA", "LOCALAPPDATA",
                  "XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_STATE_HOME",
                  "XDG_CACHE_HOME"]

proc hasToken(code, needle: string): bool =
  ## `needle` occurs in `code` not preceded by an identifier character, so
  ## `HOME:` does not match inside `XDG_CONFIG_HOME:`. Literal matching rather
  ## than `std/re`, which needs a PCRE library at run time that a Windows
  ## checkout does not have.
  var start = 0
  while true:
    let i = code.find(needle, start)
    if i < 0:
      return false
    # A needle that starts with punctuation (`.HOME =`) carries its own
    # boundary; `env2.XDG_CONFIG_HOME =` must match.
    if i == 0 or needle[0] notin IdentChars or code[i - 1] notin IdentChars:
      return true
    start = i + 1

proc redirectsHome(code, ext: string): bool =
  ## Whether `code` SETS one of `HomeVars` for itself or a child.
  for v in HomeVars:
    let q = "\"" & v & "\""
    if ext == ".ts":
      for n in [v & ":", v & " :", "." & v & " =", q & ":"]:
        if code.hasToken(n): return true
    else:
      for n in ["env[" & q & "] =", "env[" & q & "]=", "envSet(" & q & ",",
                "putEnv(" & q & ",", "setEnv(" & q & ",",
                "setEnv(cstring" & q & ",", ".env(" & q & ",",
                "set_var(" & q & ",", "(" & q & ",", "delEnv(" & q & ")"]:
        # `hasToken`, so `getEnv("HOME", "")` (a READ: `(` follows an
        # identifier) is not taken for an `extraEnv` tuple `("HOME", …)`.
        if code.hasToken(n): return true

const ResolutionNeedles = [
  "XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME",
  "\".local\"", ".local/share/codetracer", ".config/codetracer",
  "\"USERPROFILE\"", "\"LOCALAPPDATA\"", "\"APPDATA\"",
  "Library/Caches/com.codetracer",
  # The legacy per-run tmp dir (`<temp>/codetracer`), as Rust and Nim spelt
  # it before `ct_home::tmp_dir` / `ctTmpDir` -- a site that goes back to
  # one of these writes sockets and run dirs into the real profile.
  "temp_dir().join(\"codetracer", "getTempDir() / \"codetracer\"",
  "\"TEMPDIR\""]

const ScriptNeedles = [
  # A home-relative per-user directory spelt in shell or Python. `$HOME/.cache`
  # in any spelling (not only CodeTracer's own subdirectory): a CI script has
  # no business caching in the user's profile at all.
  "$HOME/.cache", "${HOME}/.cache", "~/.cache",
  ".cache/codetracer", ".config/codetracer", ".local/share/codetracer",
  ".local/state/codetracer",
  # The XDG fallback idiom, which is how every one of these was written.
  "XDG_CACHE_HOME:-", "XDG_CONFIG_HOME:-", "XDG_DATA_HOME:-",
  "XDG_STATE_HOME:-",
  "Path.home()", "expanduser("]

type ScriptUnit = object
  rel, name: string   ## `name` is the recipe for the justfile, "" otherwise
  code: seq[string]

proc justRecipe(line: string): string =
  ## The recipe a justfile line at column 0 opens (`name args...:`, with an
  ## optional `@`), or "" for anything else (`x := …`, `set …`, `[attr]`).
  if line.len == 0 or line[0] notin {'A'..'Z', 'a'..'z', '0'..'9', '_', '@'}:
    return ""
  let colon = line.find(':')
  if colon <= 0 or (colon + 1 < line.len and line[colon + 1] == '='):
    return ""
  let head = line[0 ..< colon].strip
  if '=' in head and not head.contains(' '):
    return ""
  result = head.split(' ')[0].strip(chars = {'@'})

proc scriptUnits(rel, text: string): seq[ScriptUnit] =
  ## A file is one unit; the justfile is one unit per recipe (and one for its
  ## top level), so an intentional recipe exempts itself and nothing else.
  let lines = codeLines(text, rel)
  if not rel.endsWith("justfile"):
    return @[ScriptUnit(rel: rel, code: lines)]
  result = @[ScriptUnit(rel: rel)]
  for line in lines:
    let r = justRecipe(line)
    if r.len > 0:
      result.add ScriptUnit(rel: rel, name: r)
    result[^1].code.add line

proc generated(rel: string): bool =
  for part in rel.split({'/', '\\'}):
    if part.startsWith("build") or part in ["node_modules", "target", "dist"] or
        "nimcache" in part:
      return true

suite "CODETRACER_HOME — this process":

  test "runs under a scratch CODETRACER_HOME, set before any module initialised":
    let h = getEnv("CODETRACER_HOME")
    checkpoint("CODETRACER_HOME=" & h & "  temp=" & getTempDir())
    check isTestScratch(h)

  test "every start-up path global lies inside it":
    ## Computed at module initialisation, so this is where a spawned `ct`, a
    ## helper or this suite would ACTUALLY write.
    let h = codetracerHome()
    check h.len > 0
    for (name, value) in [
        ("paths.codetracerTraceDir (trace index dir)", codetracerTraceDir),
        ("paths.DB_PATHS[0] (trace index)", DB_PATHS[0]),
        ("paths.codetracerTmpPath", codetracerTmpPath),
        ("paths.codetracerCache", codetracerCache),
        ("types.app (recordings)", app),
        ("globals.codetracerShareFolder (recordings, saves)", codetracerShareFolder),
        ("config.userConfigDir", userConfigDir),
        ("config.userLayoutDir", userLayoutDir)]:
      if not value.inside(h):
        checkpoint(name & " = " & value & " is OUTSIDE CODETRACER_HOME " & h &
                   " — a resolver stopped honouring it (src/common/ct_home.nim)")
      check value.inside(h)

  test "every resolver puts its area at CODETRACER_HOME/<area>":
    let h = codetracerHome()
    withEnv([("CODETRACER_TUI_LAYOUT_DIR", ""), ("CODETRACER_STATE_DIR", ""),
             ("CODETRACER_USER_ROOT", "")]):
      check norm(ctDataDir()) == norm(h / "data")
      check norm(ctDataDirIgnoringXdg()) == norm(h / "data")
      check norm(ctConfigDir()) == norm(h / "config")
      check norm(ctStateDir()) == norm(h / "state")
      check norm(ctCacheDir()) == norm(h / "cache")
      check norm(ctTmpDir()) == norm(h / "tmp")
      check norm(ctTmpCacheDir()) == norm(h / "cache")
      check norm(ctLauncherUserRootDefault()) == norm(h / "launcher")
      check norm(ctHomeAreaOr(chaConfig, "/legacy")) == norm(h / "config")
      # The local spellings outside `common/` agree with `ct_home`.
      check norm(nativeStateRoot()) == norm(ctStateDir())
      check norm(ci_state.stateDir()) == norm(h / "state" / "ci")
      check norm(launcherUserRoot()) == norm(h / "launcher")

  test "while it is set, no OS variable is consulted":
    let h = codetracerHome()
    withEnv(Decoys):
      for (name, value) in [
          ("ctDataDir", ctDataDir()), ("ctDataDirIgnoringXdg", ctDataDirIgnoringXdg()),
          ("ctConfigDir", ctConfigDir()), ("ctStateDir", ctStateDir()),
          ("ctCacheDir", ctCacheDir()), ("ctTmpDir", ctTmpDir()),
          ("ctTmpCacheDir", ctTmpCacheDir()),
          ("ctLauncherUserRootDefault", ctLauncherUserRootDefault())]:
        if not value.inside(h):
          checkpoint(name & " = " & value & " followed an OS variable")
        check value.inside(h)

  test "while it is unset, every location is the historical one":
    withEnv([("CODETRACER_HOME", ""), ("XDG_DATA_HOME", ""),
             ("XDG_CONFIG_HOME", ""), ("XDG_STATE_HOME", ""),
             ("XDG_CACHE_HOME", "")]):
      check codetracerHome() == ""
      check ctHomeArea(chaData) == ""
      let home = getHomeDir()
      check ctDataDir() == home / ".local" / "share" / "codetracer"
      check ctDataDirIgnoringXdg() == home / ".local" / "share" / "codetracer"
      check ctConfigDir() == home / ".config" / "codetracer"
      check ctStateDir() == home / ".local" / "state" / "codetracer"
      check ctCacheDir() == home / ".cache" / "codetracer"
      check ctHomeAreaOr(chaConfig, "/legacy") == "/legacy"
      when not defined(ctmacos):
        let tmp = getEnv("TMPDIR", getEnv("TEMPDIR", getEnv("TEMP",
                    getEnv("TMP", "/tmp"))))
        check ctTmpDir() == tmp / "codetracer"
        check ctTmpCacheDir() == tmp / "codetracer/cache"
      withEnv([("XDG_DATA_HOME", "/x/data"), ("XDG_CONFIG_HOME", "/x/cfg"),
               ("XDG_STATE_HOME", "/x/state"), ("XDG_CACHE_HOME", "/x/cache")]):
        check ctDataDir() == "/x/data" / "codetracer"
        # The trace index never honoured XDG_DATA_HOME, and still does not.
        check ctDataDirIgnoringXdg() == home / ".local" / "share" / "codetracer"
        check ctConfigDir() == "/x/cfg" / "codetracer"
        check ctStateDir() == "/x/state" / "codetracer"
        check ctCacheDir() == "/x/cache" / "codetracer"

suite "CODETRACER_HOME — the sweeps":

  test "A: a test that redirects a child's home directory also sets CODETRACER_HOME":
    ## The LRS-6 template, generalised. Redirecting `HOME`, `USERPROFILE`,
    ## `APPDATA`, `LOCALAPPDATA` or an `XDG_*_HOME` for a child no longer
    ## isolates anything CodeTracer writes — `CODETRACER_HOME` outranks them all
    ## and every test process inherits a scratch one — so a suite that does it
    ## and does not name `CODETRACER_HOME` either thinks it isolated a child it
    ## did not, or (run outside the harness) writes into a real profile. A
    ## file whose redirect is about something else says so with a
    ## `ct-home-sweep: not codetracer state` comment and its reason.
    var scanned, redirecting = 0
    for path in walkDirRec(repoRoot / "src"):
      let rel = path.relativePath(repoRoot).replace('\\', '/')
      if generated(rel):
        continue
      let name = path.extractFilename
      let ext = path.splitFile.ext
      let testShaped =
        (ext == ".nim" and (name.endsWith("_test.nim") or name.startsWith("test_") or
                            "/tests/" in rel)) or
        (ext == ".rs" and "/tests/" in rel) or
        (ext == ".ts" and rel.startsWith("src/tests/gui/"))
      if not testShaped:
        continue
      inc scanned
      let text = readFile(path)
      let code = codeLines(text, path).join("\n")
      if not redirectsHome(code, ext):
        continue
      inc redirecting
      # In CODE, not merely a comment: a comment that names the variable while
      # the statement setting it is gone is exactly the regression to catch.
      let ok = "CODETRACER_HOME" in code or
               "ct-home-sweep: not codetracer state" in text
      if not ok:
        checkpoint(rel & " redirects a home-directory variable for itself or " &
          "a child and never names CODETRACER_HOME. That variable outranks " &
          "HOME/USERPROFILE/XDG_* for every CodeTracer location, so set it " &
          "to the scratch directory (or, if the redirect is not about " &
          "CodeTracer state, say so with `ct-home-sweep: not codetracer state`).")
      check ok
    checkpoint("scanned " & $scanned & " test sources, " & $redirecting & " redirect")
    # Anti-vacuity: the four LRS-6 suites and the PTY/GPUI suites are found.
    check scanned > 100
    check redirecting >= 10

  test "B: every test entry point still sets CODETRACER_HOME":
    ## Each needle is the STATEMENT that sets it (comments are skipped), so
    ## deleting the line from any one harness fails here, naming the file.
    const entryPoints = [
      ("config.nims", "ctForceImportStateIsolation(repoRoot)"),
      ("src/frontend/test_support/force_import_isolation.nims", "\"state_isolation.nim\")"),
      ("src/ct_test/config.nims", "ctForceImportStateIsolation("),
      ("src/tests/config.nims", "state_isolation.nim\")"),
      ("src/frontend/tui/tests/config.nims", "state_isolation.nim\")"),
      ("src/frontend/gpui/tests/config.nims", "state_isolation.nim\")"),
      ("src/frontend/viewmodel/tests/config.nims", "state_isolation.nim\")"),
      ("src/frontend/test_support/state_isolation.nim", "putEnv(CodetracerHomeVar, dir)"),
      ("ci/lib/run-nim-test-lane.sh", "export CODETRACER_HOME=\"${_ct_lane_home}/${name}\""),
      # The export of the directory it CREATES, not the early returns'
      # re-export of an inherited one: dropping it leaves every child unset.
      ("ci/lib/codetracer-home.sh", "export CODETRACER_HOME=\"${ct_scratch_home_created}\""),
      ("justfile", "ct_export_scratch_codetracer_home rust-tests"),
      ("justfile", "ct_export_scratch_codetracer_home frontend-js"),
      ("ci/test/windows-rust-components-tests.sh", "ct_export_scratch_codetracer_home windows-rust-components"),
      ("ci/test/windows-headless-tests.sh", "ct_export_scratch_codetracer_home windows-headless"),
      ("scripts/run-cross-repo-tests.sh", "ct_export_scratch_codetracer_home cross-repo"),
      ("src/db-backend/tests/test_harness/mod.rs", "ct_home::isolate_for_tests();"),
      ("libs/ct-home/src/lib.rs", "env::set_var(CODETRACER_HOME_ENV, &dir);"),
      ("src/tests/gui/lib/fixtures.ts", "process.env.CODETRACER_HOME = guiTestCodetracerHome;"),
      ("src/tests/gui/lib/fixtures.ts", "env.CODETRACER_HOME = guiTestCodetracerHome;")]
    for (rel, needle) in entryPoints:
      let path = repoRoot / rel
      let present = fileExists(path) and
        codeLines(readFile(path), path).anyIt(needle in it)
      if not present:
        checkpoint(rel & " no longer contains `" & needle & "`: that test " &
          "entry point would run its suites (and every binary they spawn) " &
          "against the developer's real CodeTracer state.")
      check present

  test "B2: every config.nims under src/ keeps its tree isolated":
    ## Nim evaluates config files root-first, and only the LAST one may add the
    ## force-import (src/frontend/test_support/force_import_isolation.nims).
    ## A NEW `config.nims` under `src/` therefore silently ends isolation for
    ## its whole tree unless it imports `state_isolation` itself or calls
    ## `ctForceImportStateIsolation` — this case finds the one that does not.
    var found = 0
    for path in walkDirRec(repoRoot / "src"):
      let rel = path.relativePath(repoRoot).replace('\\', '/')
      if generated(rel) or path.extractFilename != "config.nims":
        continue
      inc found
      let code = codeLines(readFile(path), path).join("\n")
      let ok = "state_isolation.nim" in code or
               "ctForceImportStateIsolation(" in code
      if not ok:
        checkpoint(rel & " is evaluated after the repo-root config.nims for " &
          "every program under its directory, so the root no longer adds the " &
          "isolation import there. Include " &
          "src/frontend/test_support/force_import_isolation.nims and call " &
          "ctForceImportStateIsolation at its end.")
      check ok
    check found >= 5

  test "C: no product source resolves a per-user location around ct_home":
    ## A file that names an OS per-user variable or a home-relative CodeTracer
    ## path in CODE must also go through `ct_home` (or name `CODETRACER_HOME`
    ## in its own spelling). Text a user reads — help, an MCP tool
    ## description — is not a resolution and is listed with its reason. So is
    ## a location CodeTracer does not own: one an external specification
    ## defines, shared with other tools, with an override of its own.
    const textOnly = [
      ("src/backend-manager/src/mcp_server.rs", "an MCP tool's description text"),
      ("src/ct/utilities/types.nim", "a help message"),
      ("src/frontend/viewmodel/views/isonim_repl_view.nim", "a user-facing message"),
      ("src/ct_test/certificate_store_roots.nim",
       "the cross-tool test-certificates store (test-certificates-spec " &
       "Transport.md §2.1); its override is TEST_CERTIFICATES_DIR, and " &
       "CODETRACER_HOME deliberately does not move a store other producers share")]
    var scanned, resolving = 0
    for path in walkDirRec(repoRoot / "src"):
      let rel = path.relativePath(repoRoot).replace('\\', '/')
      if generated(rel) or "/tests/" in rel or "/test_support/" in rel:
        continue
      let name = path.extractFilename
      let ext = path.splitFile.ext
      if ext notin [".nim", ".rs"] or name.endsWith("_test.nim") or
          name.startsWith("test_") or name.endsWith("_test_helper.nim"):
        continue
      inc scanned
      let text = readFile(path)
      let code = codeLines(text, path).join("\n")
      if not ResolutionNeedles.anyIt(it in code):
        continue
      inc resolving
      if textOnly.anyIt(it[0] == rel):
        continue
      let ok = "CODETRACER_HOME" in text or "ct_home" in text or "ctHome" in text
      if not ok:
        checkpoint(rel & " resolves a per-user location from an OS variable " &
          "or a home-relative path and never goes through ct_home, so " &
          "CODETRACER_HOME does not move it and a test cannot isolate it.")
      check ok
    checkpoint("scanned " & $scanned & " product sources, " & $resolving & " resolve")
    check scanned > 200
    check resolving >= 8

  test "C2: no CI script, recipe or tool resolves a per-user location around CODETRACER_HOME":
    ## Sweep C's rule for what is not product code: a shell or Python file
    ## under `ci/`, `scripts/` or `tools/`, or a recipe in the `justfile`, that
    ## spells a per-user directory in CODE (`$HOME/.cache`,
    ## `.config/codetracer`, the `${XDG_*_HOME:-…}` idiom, …) must name
    ## `CODETRACER_HOME` in its own code, i.e. honour it first.
    ##
    ## WHY. On 2026-11-02 `ci/test/cua-keymap-extractor.sh`, run by the
    ## `lint-nim` stage, fetched the VS Code sources into
    ## `${XDG_CACHE_HOME:-$HOME/.cache}/codetracer/vscode-484fdf69` — the
    ## developer's real cache — and sweep C did not look outside `src/`.
    ##
    ## INTENTIONAL SITES are listed with their reason: the ones the spec says
    ## act on the default locations on purpose (Per-User-State-Locations.md
    ## §3.1: the developer reset recipes and the request-panel demos), and text
    ## a user reads. An entry that no longer matches fails: a stale exemption
    ## would excuse the next file or recipe to take its name.
    const intentional = [
      ("justfile", "reset-db", "§3.1: a developer reset of the REAL profile's " &
       "trace index; it acts on the default location on purpose"),
      ("justfile", "clear-local-traces", "§3.1: a developer reset of the " &
       "real profile's recordings"),
      ("justfile", "reset-config", "§3.1: a developer reset of the real " &
       "profile's config"),
      ("justfile", "reset-layout", "§3.1: a developer reset of the real " &
       "profile's layouts"),
      ("justfile", "demo-request-panel", "§3.1: the request-panel demos " &
       "write where the developer opens them; CODETRACER_DEMO_DIR overrides"),
      ("justfile", "demo-request-panel-live", "§3.1: as demo-request-panel"),
      ("scripts/require-runtime-assets.sh", "", "a message naming where `ct` " &
       "copies its default config on first run; nothing is resolved")]
    var scanned, resolving = 0
    var used: seq[string] = @[]
    var files: seq[string] = @[repoRoot / "justfile"]
    for dir in ["ci", "scripts", "tools"]:
      for path in walkDirRec(repoRoot / dir):
        let rel = path.relativePath(repoRoot).replace('\\', '/')
        if generated(rel):
          continue
        if path.splitFile.ext in [".sh", ".bash", ".py"]:
          files.add path
    for path in files:
      let rel = path.relativePath(repoRoot).replace('\\', '/')
      for u in scriptUnits(rel, readFile(path)):
        inc scanned
        let code = u.code.join("\n")
        let named = ScriptNeedles.filterIt(it in code)
        if named.len == 0:
          continue
        inc resolving
        let unitName = rel & (if u.name.len > 0: " recipe `" & u.name & "`" else: "")
        if intentional.anyIt(it[0] == rel and it[1] == u.name):
          used.add rel & ":" & u.name
          continue
        let ok = "CODETRACER_HOME" in code
        if not ok:
          checkpoint(unitName & " spells a per-user directory (" &
            named.join(", ") & ") and never names CODETRACER_HOME, so a " &
            "test lane that sets it still writes the developer's real " &
            "profile. Resolve `$CODETRACER_HOME/<area>` first (see " &
            "ci/test/cua-keymap-extractor.sh), or, if the spec says the site " &
            "acts on the default location on purpose, list it here with the " &
            "reason.")
        check ok
    for (rel, name, reason) in intentional:
      let key = rel & ":" & name
      if key notin used:
        checkpoint("stale exemption " & key & " (" & reason & "): it no " &
          "longer spells a per-user directory; remove the entry.")
      check key in used
    checkpoint("scanned " & $scanned & " scripts and recipes, " & $resolving &
      " spell a per-user directory")
    check scanned > 500
    check resolving >= intentional.len + 2
