## Every Nim compile in this checkout keeps its nimcache INSIDE the checkout.
##
## WHY.  Nim's default nimcache (`~/.cache/nim/<project>_d`, `_r` for
## -d:release, `%USERPROFILE%\nimcache\<project>_d` on Windows) is keyed by the
## project NAME only, and the generated file names inside it are the same in
## every checkout.  Two checkouts of this repository building the same project
## at the same time therefore share one set of intermediate files, and a build
## can exit 0 with the other checkout's code linked in.  The repo-root
## `config.nims` moves every such cache to
## `<checkout>/.nimcache/<main module's dir>/<module name>_<d|r|check>`; its
## header has the details.
##
## WHAT THIS CHECKS.
##   1. SELF.  The nimcache this test binary was itself compiled with, baked in
##      at compile time by `querySetting(nimcacheDir)`, is inside the checkout
##      (or is the lane runner's per-checkout cache, see below).
##      So a test runner that bypasses the config fails here, not only a
##      config that is wrong.
##   2. LAYOUT.  `nim dump` reports exactly the documented directory for this
##      file (from the repo root and from its own directory) and for the main
##      modules below, in debug (`_d`) and with -d:release (`_r`); and an
##      explicit `--nimcache:` on the command line still wins.
##   3. CONTROL.  The same probe with `--skipParentCfg`, which switches the
##      repo-root config off, must resolve OUTSIDE the checkout.  If it does
##      not, the probe cannot tell a shared cache from a local one, every
##      verdict above is vacuous, and the run fails saying so.
##
## Cost: a handful of `nim dump` probes (config evaluation only, no compile),
## about a second in total.
##
## NO MOCKS: the real compiler, the real config files, the real checkout.

import std/[compilesettings, json, os, osproc, streams, strtabs, strutils]
import std/unittest

const
  SelfNimcache = querySetting(nimcacheDir)
  SelfSource = currentSourcePath()
  CompilerAtBuild = getCurrentCompilerExe()

  # --- Per-repository settings ----------------------------------------------
  RootMarker = "justfile"
    ## A file every checkout of this repository has, used to validate the
    ## derived checkout root.  Never `config.nims`: that is the thing under
    ## test.
  LevelsBelowRoot = 2
    ## How many directories this file sits below the checkout root.
  MainModules: seq[string] = @["src/ct/codetracer.nim"]
    ## Checkout-relative main modules probed in debug and release.

var failures = 0

proc noteFail(msg: string) =
  inc failures
  echo "  FAIL  ", msg

proc notePass(msg: string) =
  echo "  ok    ", msg

proc comparable(p: string): string =
  ## Absolute and normalised; case-folded where the filesystem is.  Nim hands
  ## back symlink-resolved paths, and the root below is resolved the same way.
  result = normalizedPath(absolutePath(p))
  when defined(windows):
    result = result.replace('/', '\\').toLowerAscii()

proc isInside(child, parent: string): bool =
  let c = comparable(child)
  let p = comparable(parent)
  c.len > p.len and c.startsWith(p) and c[p.len] in {DirSep, AltSep}

proc sameDir(a, b: string): bool =
  comparable(a) == comparable(b)

proc canonical(p: string): string =
  try: expandFilename(p) except OSError: p

let selfFile = canonical(SelfSource)
var rootGuess = selfFile.parentDir
for _ in 1 .. LevelsBelowRoot:
  rootGuess = rootGuess.parentDir
let root = canonical(rootGuess)
if not fileExists(root / RootMarker):
  echo "nimcache-locality: cannot locate the checkout root from ", SelfSource,
    " (derived ", root, ", which has no ", RootMarker,
    "): refusing to report a verdict about an unknown tree"
  quit(2)

let nimExe =
  if fileExists(CompilerAtBuild): CompilerAtBuild
  else: findExe("nim")
if nimExe.len == 0:
  echo "nimcache-locality: no `nim` to probe with (neither ", CompilerAtBuild,
    " nor one on PATH): refusing to report a verdict"
  quit(2)

echo "nimcache-locality: checkout ", root
echo "nimcache-locality: probing with ", nimExe

proc nimcacheOf(workDir, project: string; extra: seq[string] = @[];
                env: StringTableRef = nil): string =
  ## The nimcache Nim would compile `project` into from `workDir`, as
  ## `nim dump` reports it; "" when the probe itself failed (already recorded).
  var args = @["dump", "--dump.format:json", "--hints:off"]
  args.add(extra)
  args.add(project)
  let what = "`nim " & args.join(" ") & "` in " & workDir
  var output = ""
  var code = -1
  try:
    let p = startProcess(nimExe, workingDir = workDir, args = args, env = env,
                         options = {poStdErrToStdOut})
    output = p.outputStream.readAll()
    code = p.waitForExit()
    p.close()
  except CatchableError as e:
    noteFail("could not run " & what & ": " & e.msg)
    return ""
  if code != 0:
    noteFail(what & " exited " & $code & ":\n" & output)
    return ""
  for line in output.splitLines():
    if line.startsWith("{"):
      try:
        return parseJson(line)["nimcache"].getStr()
      except CatchableError as e:
        noteFail(what & " printed unparseable JSON (" & e.msg & "): " & line)
        return ""
  noteFail(what & " printed no JSON:\n" & output)
  ""

proc expectedFor(projectRel, suffix: string): string =
  ## The layout config.nims promises: <checkout>/.nimcache/<rel dir>/<name><suffix>.
  let dir = projectRel.parentDir
  var d = root / ".nimcache"
  if dir.len > 0 and dir != ".":
    d = d / dir
  d / (projectRel.splitFile.name & suffix)

proc checkLayout(label, got, want: string) =
  if got.len == 0:
    return # the probe failure is already recorded
  if not isInside(got, root):
    noteFail(label & ": resolves OUTSIDE the checkout, to " & got &
         " -- a cache every checkout on this machine shares")
  elif not sameDir(got, want):
    noteFail(label & ": resolves to " & got & ", not the documented " & want)
  else:
    notePass(label & " -> " & relativePath(got, root))

let selfRel = relativePath(selfFile, root).replace('\\', '/')

# ---------------------------------------------------------------------------
echo "nimcache-locality: [1] the cache this test binary was compiled with"
# `ci/lib/run-nim-test-lane.sh` compiles every lane file with its own explicit
# cache, keyed on this checkout's absolute path:
# `$CT_NIM_CACHE_ROOT/...` or `/tmp/ct-nim-cache/<checkout basename>-<cksum>/...`.
# That is per-checkout too, so it counts; anything else outside the tree fails.
# (An explicit `$CT_NIM_CACHE_ROOT` is used as-is by the runner, so anything
# under it counts.)
let explicitLaneRoot = getEnv("CT_NIM_CACHE_ROOT")
let laneCachePrefix = "/tmp/ct-nim-cache" / (root.extractFilename & "-")
if (explicitLaneRoot.len > 0 and isInside(SelfNimcache, explicitLaneRoot)) or
    (isInside(SelfNimcache, "/tmp/ct-nim-cache") and
     comparable(SelfNimcache).startsWith(comparable(laneCachePrefix))):
  notePass("this binary was compiled in the lane runner's per-checkout cache " &
       SelfNimcache)
elif isInside(SelfNimcache, root):
  notePass("this binary was compiled in " & relativePath(SelfNimcache, root))
else:
  noteFail("this test binary was compiled with the nimcache " & SelfNimcache &
       ", OUTSIDE the checkout: whatever built it bypassed config.nims " &
       "without naming a checkout-local --nimcache:")

# ---------------------------------------------------------------------------
echo "nimcache-locality: [2] the documented layout"
checkLayout(selfRel & " (from the checkout root)",
            nimcacheOf(root, selfRel), expectedFor(selfRel, "_d"))
checkLayout(selfRel & " (from its own directory)",
            nimcacheOf(selfFile.parentDir, selfFile.extractFilename),
            expectedFor(selfRel, "_d"))
for m in MainModules:
  if not fileExists(root / m):
    noteFail(m & ": listed as a main module to probe, but it does not exist")
    continue
  checkLayout(m & " (debug)", nimcacheOf(root, m), expectedFor(m, "_d"))
  checkLayout(m & " (-d:release)", nimcacheOf(root, m, @["-d:release"]),
              expectedFor(m, "_r"))

let explicitDir = getTempDir() / "nimcache-locality-explicit"
let explicitGot = nimcacheOf(root, selfRel, @["--nimcache:" & explicitDir])
if explicitGot.len > 0:
  if sameDir(explicitGot, explicitDir):
    notePass("an explicit --nimcache: on the command line still wins")
  else:
    noteFail("an explicit --nimcache:" & explicitDir & " resolved to " &
         explicitGot & ": the config overrides the command line")

# ---------------------------------------------------------------------------
echo "nimcache-locality: [3] negative control: repo-root config switched off"
var controlEnv = newStringTable(modeCaseSensitive)
for k, v in envPairs():
  controlEnv[k] = v
let fakeXdg = getTempDir() / "nimcache-locality-control-xdg"
controlEnv["XDG_CACHE_HOME"] = fakeXdg
let controlGot = nimcacheOf(root, selfRel, @["--skipParentCfg"], controlEnv)
if controlGot.len > 0:
  if isInside(controlGot, root):
    noteFail("CONTROL did not fail: with the repo-root config switched off the " &
         "probe still reports " & controlGot & ", inside the checkout -- so " &
         "it cannot tell a shared cache from a local one, and every verdict " &
         "above is vacuous")
  else:
    when defined(posix):
      let want = fakeXdg / "nim" / (selfFile.splitFile.name & "_d")
      if sameDir(controlGot, want):
        notePass("with the config off, this file resolves to Nim's shared " &
             "default " & controlGot)
      else:
        noteFail("CONTROL resolved outside the checkout but not to Nim's " &
             "default formula ($XDG_CACHE_HOME/nim/<project>_d): " & controlGot)
    else:
      notePass("with the config off, this file resolves outside the checkout: " &
           controlGot)

# `ci/lib/run-nim-test-lane.sh` scores a lane file by its unittest `[OK]` /
# `[FAILED]` lines, so the verdict is reported as one unittest case.
suite "nimcache locality":
  test "every Nim compile in this checkout keeps its nimcache inside it":
    if failures > 0:
      echo "nimcache-locality: FAILED, ", failures, " failure(s): a Nim build in ",
        "this checkout can reach a nimcache that other checkouts share.  See the ",
        "header of config.nims."
    check failures == 0
