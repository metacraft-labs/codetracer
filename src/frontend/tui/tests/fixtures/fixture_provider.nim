## fixture_provider.nim — CTUI-1, the fixture corpus.
##
## ## What this module is for
##
## Six later milestones (CTUI-5 … CTUI-10) assert against *named recorded
## traces*: `noir_space_ship`, `calc`, `threads`, `wide_state`. Before CTUI-1
## none of them existed in any form — the 2026-09-05 revision of
## `codetracer-specs/Front-Ends/CodeTracer-TUI.milestones.org` established that
## by reading the tree — so this module is the one place that answers "where is
## fixture X?", and the answer is a *directory a real recorder produced*, never
## a checked-in binary and never a synthetic stand-in.
##
## A fixture is resolved in three steps:
##
##   1. a cache lookup under `test-logs/tui-fixtures/<name>-<key>`, where
##      `<key>` is a digest of the program's own sources, so a program edit
##      invalidates its recording rather than silently reusing a stale one —
##      and adopted only if this build's CTFS reader opens it, so a container
##      from an older trace format is a miss, not a launch failure
##      (`cachedRecordingRefusal`);
##   2. failing that, a *recording*, driven through `ct record -o <dir>` — the
##      same binary and the same subcommand a user records with, so a fixture
##      cannot be produced by a path the product does not have;
##   3. failing that, a counted, named MISSING-PREREQ skip.
##
## ## THE RULE THIS FILE EXISTS TO OBEY
##
## `codetracer-specs/Testing/Silent-Self-Pass-Audit-2026-08-23.md`: *a test that
## detects a missing prerequisite, returns early, and is counted as PASSED is a
## lie.* Three consequences are wired into the types below rather than left to
## each caller's discretion:
##
##   * **`replay-server` is never a skip.** `findReplayServer` raises, with a
##     message naming the build command and every path searched
##     (`src/common/replay_server_path.missingReplayServerMessage`), exactly as
##     `src/tests/gui/tests/noir-space-ship/noir_space_ship_test.nim` does.
##     Every fixture needs it, so its absence is a broken environment, not a
##     partial one.
##   * **A missing *recorder* is a skip, but a LOUD and COUNTED one.**
##     `resolveFixture` returns `foMissingPrereq` carrying the fixture name and
##     the recorder name, and `missingPrereqMessage` renders the single
##     greppable line — the same shape `src/frontend/viewmodel/tests/unit/
##     recorder_gate.nim` and `just test-vm-recorder-gated` already use, with
##     `MISSING-PREREQ` in place of `MISSING-RECORDER` because a fixture can be
##     blocked by something that is not a recorder binary (see `threads`).
##   * **A recorder that is PRESENT and FAILS is a failure, not a skip.**
##     `recordFixture` raises on a non-zero `ct record`. Folding those two
##     states together is how a broken recorder stays invisible: the run is
##     green either way and the difference is exactly the interesting part.
##
## The fourth consequence — *the lane fails if every case skipped* — cannot
## live here, because this module resolves one fixture at a time and has no
## view of the run. It is asserted in `../test_fixture_corpus.nim`, over
## `DeclaredFixtures`, whose length is the count that guard is measured
## against (Verification-Harness-Traps §4b: when the membership is knowable,
## assert the COUNT, not its non-emptiness).
##
## ## Layer
##
## This is test-support code under `tests/`, not under `app/`, so the CTUI-0
## facade rule does not apply to it: `app/` may not reach a process or a
## terminal, and this module's whole job is to spawn `ct`.
## `ci/test/sdk-facade-boundary.sh` declares `src/frontend/tui/app` as the
## consumer directory and `src/frontend/tui/host` as the exemption; `tests/` is
## in neither set, and the Tier-1 lane compiles it with
## `--path:src/frontend/viewmodel` so `headless_session` — itself a
## process-spawning host — is reachable from the suites that use this.

import std/[algorithm, md5, os, osproc, strutils]

import ../../../../common/replay_server_path   # the one search order
from ../../../../ct/trace/ctfs_sources import readCtfsMetaDat
  # This build's own CTFS reader. `cachedRecordingRefusal` asks it whether a
  # cached container is one this build can open; see the note there.

const FixtureCacheSchema = 2
  ## Bumped whenever the *shape* of a cached fixture directory changes, so a
  ## workspace holding directories from an older provider re-records instead of
  ## adopting them. It participates in the cache key, which is why it is a
  ## number and not a comment.

const MissingPrereqSkipPrefix* = "MISSING-PREREQ SKIP:"
  ## Stable, greppable marker. `just test-tui` and any CI log reader find every
  ## unresolved fixture in a run with one pattern. Do not reword without
  ## updating `../test_fixture_corpus.nim`, which asserts on it.

type
  FixtureOutcome* = enum
    foRecorded         ## a trace directory exists (cached, or just recorded)
    foMissingPrereq    ## a NAMED prerequisite is absent — a counted skip

  FixtureSpec* = object
    ## One declared fixture. `DeclaredFixtures` below is the whole corpus, and
    ## it is a `const` so that "which fixtures exist" is answerable by reading
    ## one list rather than by grepping for call sites.
    name*: string
      ## The name later milestones use. Also the cache directory's prefix.
    program*: string
      ## Repo-relative path of the program to record. A directory for the
      ## project-shaped recorders (Noir), a file for the script-shaped ones.
    recorder*: string
      ## The recorder this fixture needs, by the name a human would install.
      ## Rendered into the MISSING-PREREQ line, so it must be actionable.
    probe*: FixtureProbe
      ## How to ask whether that recorder is present. See `ProbeKind`.
    buildHint*: string
      ## One line telling the reader how to get the recorder.
    blockedOn*: string
      ## Non-empty means DECLARED BUT UNOBTAINABLE: the recorder may be right
      ## here and the fixture still cannot be produced, because the *replay*
      ## layer cannot express what the fixture is for. The string is the reason,
      ## and it is reported verbatim in the skip line so the next reader
      ## inherits the finding rather than re-deriving it.

  ProbeKind* = enum
    pkNargo            ## `nargo` on PATH (or `$NARGO`)
    pkPythonRecorder   ## a python3 that can `import codetracer_python_recorder`

  FixtureProbe* = object
    kind*: ProbeKind

  FixtureResolution* = object
    ## The answer for one fixture. Deliberately a value rather than an
    ## exception-or-path: the caller has to *count* skips, and a control flow
    ## that can only either return a path or raise cannot be counted.
    spec*: FixtureSpec
    outcome*: FixtureOutcome
    tracePath*: string
      ## Set when `outcome == foRecorded`.
    detail*: string
      ## Set when `outcome == foMissingPrereq`: what exactly was missing.

# ---------------------------------------------------------------------------
# The corpus
# ---------------------------------------------------------------------------

const DeclaredFixtures*: seq[FixtureSpec] = @[
  FixtureSpec(
    name: "noir_space_ship",
    program: "test-programs/noir_space_ship",
    recorder: "nargo (Noir)",
    probe: FixtureProbe(kind: pkNargo),
    buildHint: "Put `nargo` on PATH (the codetracer dev shell provides it) " &
               "or set $NARGO.",
    blockedOn: "",
  ),
  FixtureSpec(
    name: "calc",
    program: "test-programs/calc/main.py",
    recorder: "codetracer-python-recorder",
    probe: FixtureProbe(kind: pkPythonRecorder),
    buildHint: "Install codetracer_python_recorder into the interpreter `ct` " &
               "will use (the repo's .python-recorder-venv, or " &
               "$CODETRACER_PYTHON_INTERPRETER).",
    blockedOn: "",
  ),
  FixtureSpec(
    name: "threads",
    program: "test-programs/threads/main.py",
    recorder: "a recorder whose traces expose per-thread state",
    probe: FixtureProbe(kind: pkPythonRecorder),
    buildHint: "There is nothing to install: the fixture becomes available " &
               "when replay-server answers DAP `threads` from per-thread " &
               "state, at which point emptying `blockedOn` is the whole change.",
    # ------------------------------------------------------------------
    # DECLARED, AND HONESTLY UNAVAILABLE. CTUI-1 anticipated this and asked
    # for the reason rather than for a substitute, so here it is, established
    # by reading the replay layer and confirmed by running it:
    #
    #   * The only thread surface a CodeTracer front-end has is the DAP
    #     `threads` request. `replay-server` answers it in
    #     `src/db-backend/src/dap_handler.rs::threads`, and that function's
    #     own comment says what it enumerates: "For multi-process recordings
    #     (fork / exec), enumerate the recorded PROCESSES via
    #     `ReplaySession::list_processes` and surface one DAP `Thread` per
    #     PROCESS."
    #   * `list_processes` has exactly two implementations.
    #     `src/db-backend/src/replay.rs:238` is the trait DEFAULT and returns
    #     one synthetic entry, unconditionally — that is the arm every
    #     CTFS/db-backed trace takes, which is every trace the Python, Noir,
    #     Ruby and JavaScript recorders produce.
    #     `src/db-backend/src/recreator_session.rs:1068` forwards
    #     `GetProcessInfo` to the rr worker, which builds its answer from
    #     `rr ps` (`codetracer-native-backend/src/multiprocess/
    #     process_tree.rs:180`) — a PROCESS table (PID/PPID/EXIT/CMD), not a
    #     thread table.
    #
    # So a genuinely multi-threaded program reports exactly ONE thread through
    # every path this workspace has, and the only way to make the number
    # exceed one is a multi-PROCESS rr recording — which is not what a thread
    # selector selects. Substituting one would be the fake CTUI-1 forbids.
    #
    # `test-programs/threads/main.py` is kept so the finding stays
    # reproducible, and so this fixture becomes available by emptying this
    # field once the replay layer grows a real per-thread surface.
    # ------------------------------------------------------------------
    blockedOn:
      "no recorder in this workspace produces a recording whose DAP `threads` " &
      "reports more than one entry: replay-server maps `threads` onto " &
      "`list_processes` (dap_handler.rs::threads), whose CTFS implementation " &
      "returns one synthetic process unconditionally (replay.rs:238) and " &
      "whose rr implementation reports `rr ps` PROCESSES, not threads " &
      "(recreator_session.rs:1068). CTUI-6's thread test is blocked-on-recorder.",
  ),
  FixtureSpec(
    name: "wide_state",
    program: "test-programs/wide_state/main.py",
    recorder: "codetracer-python-recorder",
    probe: FixtureProbe(kind: pkPythonRecorder),
    buildHint: "Install codetracer_python_recorder into the interpreter `ct` " &
               "will use (the repo's .python-recorder-venv, or " &
               "$CODETRACER_PYTHON_INTERPRETER).",
    blockedOn: "",
  ),
]

proc fixtureSpec*(name: string): FixtureSpec =
  ## Look a declared fixture up by name. Raises rather than returning a default:
  ## a typo in a fixture name must not resolve to a nameless spec that then
  ## skips for a reason nobody wrote down.
  for spec in DeclaredFixtures:
    if spec.name == name:
      return spec
  var known: seq[string]
  for spec in DeclaredFixtures:
    known.add(spec.name)
  raise newException(KeyError,
    "no fixture named '" & name & "'. Declared: " & known.join(", "))

# ---------------------------------------------------------------------------
# Locating the repository and the binaries
# ---------------------------------------------------------------------------

proc repoRoot*(): string =
  ## The checkout this module's source lives in.
  ##
  ## Walked upward rather than counted in `parentDir`s: this file sits five
  ## levels below the root today, and a moved directory would otherwise turn
  ## into a path that exists, resolves to the wrong tree, and reports a missing
  ## program instead of a moved test.
  var dir = currentSourcePath().parentDir
  while true:
    if dirExists(dir / "src" / "db-backend") and fileExists(dir / "justfile"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "could not locate the codetracer checkout from " & currentSourcePath())

proc findReplayServer*(): string =
  ## Locate `replay-server`, exactly as the TUI host and every headless suite
  ## do: through `src/common/replay_server_path`, whose order is the only one.
  ##
  ## Found, or a DIAGNOSTIC FAILURE naming every path searched — never a skip.
  ## CTUI-1 states this as a contract, and the reason is that `replay-server`
  ## is not a per-fixture prerequisite: it is what "open a trace" MEANS. A run
  ## without it has not tested a fixture corpus, it has tested nothing, and a
  ## skip would let that read as green.
  result = locateReplayServer()
  if result.len == 0:
    raise newException(IOError, missingReplayServerMessage())

proc findCtBinary*(): string =
  ## Locate `ct`, the binary that drives every recorder.
  ##
  ## Returns "" rather than raising when it is absent, because unlike
  ## `replay-server` this is a *recording* prerequisite: with a warm fixture
  ## cache the corpus is fully testable without it, so its absence must not
  ## fail a run that never needed to record anything. `resolveFixture` turns a
  ## "" here into a MISSING-PREREQ skip only when it actually has to record.
  ##
  ## `CT_BIN`, then beside the `replay-server` `src/common/replay_server_path`
  ## resolves — the build that produced the engine produced `ct` next to it,
  ## so this follows the Repro output root the same way the engine search
  ## does, and agrees with `host/native_host.findCtBinary` — then the tup tree.
  let envBin = getEnv("CT_BIN", "")
  if envBin.len > 0 and fileExists(envBin):
    return envBin
  let rs = locateReplayServer()
  if rs.len > 0 and fileExists(rs.parentDir / "ct".addFileExt(ExeExt)):
    return rs.parentDir / "ct".addFileExt(ExeExt)
  let candidate = repoRoot() / "src" / "build-debug" / "bin" / "ct"
  if fileExists(candidate):
    return candidate
  ""

# ---------------------------------------------------------------------------
# Recorder probes
# ---------------------------------------------------------------------------

proc pythonInterpreter(): string =
  ## The interpreter `ct record` will hand a Python program to.
  ##
  ## Mirrors the resolution order documented on `ct record --lang`'s help text
  ## (`src/ct/codetracerconf.nim`): CODETRACER_PYTHON_INTERPRETER,
  ## PYTHON_EXECUTABLE, PYTHONEXECUTABLE, PYTHON, then PATH. Probing a
  ## DIFFERENT interpreter from the one that will be used is the classic way to
  ## report a prerequisite as present and then fail on it.
  for varName in ["CODETRACER_PYTHON_INTERPRETER", "PYTHON_EXECUTABLE",
                  "PYTHONEXECUTABLE", "PYTHON"]:
    let value = getEnv(varName, "")
    if value.len > 0:
      return value
  let onPath = findExe("python3")
  if onPath.len > 0:
    return onPath
  findExe("python")

proc probeRecorder(probe: FixtureProbe): tuple[ok: bool, detail: string] =
  ## Is this fixture's recorder available? Answered by ASKING THE RECORDER, not
  ## by looking for a file whose presence is a proxy for it.
  case probe.kind
  of pkNargo:
    let fromEnv = getEnv("NARGO", "")
    if fromEnv.len > 0 and fileExists(fromEnv):
      return (true, fromEnv)
    let onPath = findExe("nargo")
    if onPath.len > 0:
      return (true, onPath)
    (false, "`nargo` is not on PATH and $NARGO is unset or does not exist")
  of pkPythonRecorder:
    let python = pythonInterpreter()
    if python.len == 0:
      return (false, "no python3 interpreter on PATH")
    # The import, not the file. A venv can carry a broken or partially
    # installed package, and `fileExists` on a site-packages directory would
    # call that present — after which the recording fails and the run reports a
    # product defect.
    let (output, code) = execCmdEx(
      quoteShell(python) & " -c \"import codetracer_python_recorder\"")
    if code == 0:
      return (true, python)
    (false, python & " cannot import codetracer_python_recorder: " &
            output.strip().splitLines()[^1])

# ---------------------------------------------------------------------------
# Cache keys
# ---------------------------------------------------------------------------

proc programFiles(root, program: string): seq[string] =
  ## Every file the recorded program is built from, repo-relative and sorted.
  ##
  ## Sorted because `walkDirRec`'s order is the filesystem's, and a cache key
  ## that depends on directory-entry order re-records for no reason on one host
  ## and reuses across a real edit on another.
  let full = root / program
  if fileExists(full):
    return @[program]
  if not dirExists(full):
    return @[]
  for path in walkDirRec(full, relative = false):
    # Skip anything a build left behind: `target/` under a Nargo project is a
    # build product, and folding it into the key would make the key depend on
    # whether the program had been compiled before.
    let rel = path.relativePath(root)
    if "/target/" in ("/" & rel) or "/.git/" in ("/" & rel):
      continue
    result.add(rel)
  result.sort()

proc fixtureKey*(root: string; spec: FixtureSpec): string =
  ## A content-addressed key for this fixture's program.
  ##
  ## CTUI-1's risk mitigation asks for exactly this: "fixtures are cached by
  ## content-addressed key under test-logs/; the record path runs once per
  ## workspace". Keying on CONTENT rather than on mtime means a `git checkout`
  ## that rewinds a program to a previously-recorded revision hits the cache,
  ## and an edit that leaves the mtime alone still misses it.
  var ctx = ""
  ctx.add("schema=" & $FixtureCacheSchema & "\n")
  ctx.add("name=" & spec.name & "\n")
  let files = programFiles(root, spec.program)
  if files.len == 0:
    raise newException(IOError,
      "fixture '" & spec.name & "': no program sources at " &
      (root / spec.program) & " — the fixture names a program that is not " &
      "in the tree, which is a defect in DeclaredFixtures, not a missing " &
      "prerequisite.")
  for rel in files:
    ctx.add(rel & "\n")
    ctx.add(readFile(root / rel))
    ctx.add("\n")
  getMD5(ctx)[0 ..< 12]

proc fixtureCacheRoot*(root: string): string =
  ## Where recorded fixtures live. Under `test-logs/`, which `.gitignore`
  ## excludes wholesale, because a trace container is large and reproducible
  ## and must never enter the repository.
  root / "test-logs" / "tui-fixtures"

# ---------------------------------------------------------------------------
# Recognising a recorded trace
# ---------------------------------------------------------------------------

const FixtureStampFile = ".ctui-fixture-complete"
  ## Written LAST, after `ct record` returned 0 and the directory was checked.
  ## Its absence is what distinguishes "a recording that finished" from "a
  ## directory a killed recorder left behind", and adopting the second as a
  ## fixture is how a truncated trace becomes a mysterious replay failure three
  ## milestones later.
  ##
  ## Its CONTENT answers a second question the key cannot — see
  ## `recorderIdentity` and `stampRecorder` below.

const StampRecorderPrefix = "recorder-identity="
  ## The line in `FixtureStampFile` that records WHICH RECORDER produced this
  ## directory. See `recorderIdentity`.

# ---------------------------------------------------------------------------
# Recorder identity — what the cache key cannot carry
# ---------------------------------------------------------------------------
#
# `fixtureKey` digests the fixture's schema, name and PROGRAM SOURCES. That is
# the right key, and it is not a sufficient cache validity condition, because
# a recorded trace is a function of two things and the key names only one:
#
#     trace = recorder(program)
#
# Hold the program fixed, change the recorder, and the key does not move — so
# a directory recorded by a recorder that no longer exists is adopted as
# though the current one had produced it. `isUsableTraceDir` cannot catch it
# either: it asks whether a container is THERE, never which version it is.
#
# MEASURED, 2026-10-12, aarch64-darwin, and the reason this exists. This
# checkout's `calc-2f0db4f45192` had been recorded by a recorder resolved out
# of a Nix store env registered 2026-09-29, two days before the CTFS v5
# container bump landed in `codetracer-trace-format-nim` `86ca226`. Its
# container byte was 4. The current `replay-server` — correctly, and by a
# tested refusal — answers
#
#     CTFS container version 4 is not readable: this reader reads versions 5 and 6
#
# Nothing in the resolution path could see that. The key matched (the program
# had not changed), the stamp was present, the shape was usable, so the stale
# directory was re-adopted on every run and the failure surfaced as an engine
# defect several layers away from its cause. It cost two days.
#
# WHY THE IDENTITY IS IN THE STAMP AND NOT IN THE KEY. Folding it into the key
# is the obvious move and it is the wrong one, for two independent reasons:
#
#   1. It would break the documented property that a WARM CACHE IS USABLE WITH
#      NO RECORDER INSTALLED (see `findCtBinary`). The key is computed before
#      the recorder is probed; if the key needed the recorder, a machine with
#      a warm cache and no recorder could no longer even look the fixture up.
#   2. The cache directory name is load-bearing OUTSIDE this module. Eight
#      GPUI/TUI suites name `test-logs/tui-fixtures/calc-2f0db4f45192` as a
#      literal constant. A key change renames the directory and reds all of
#      them for a reason unrelated to what they test.
#
# In the stamp, the identity is a VALIDITY CONDITION rather than an address:
# the lookup still finds the directory, and then asks whether the recorder
# that produced it is the one running now. Unknown on either side means "no
# opinion" and the cached directory is kept — which is exactly the warm-cache-
# without-a-recorder case, preserved rather than argued away. (Kept, that is,
# provided this build can read it: the identity says nothing about the
# READER, which is the question `cachedRecordingRefusal` answers first.)

proc nargoIdentity(): string =
  ## `nargo --version`, verbatim-ish. The Noir recorder is an external
  ## compiler whose output format moves with its version, which is precisely
  ## what the version string is for.
  let fromEnv = getEnv("NARGO", "")
  let exe = if fromEnv.len > 0 and fileExists(fromEnv): fromEnv else: findExe("nargo")
  if exe.len == 0:
    return ""
  let (output, code) = execCmdEx(quoteShell(exe) & " --version")
  if code != 0:
    return ""
  output.strip().replace("\n", " ")

const PythonRecorderIdentityProgram = """
import hashlib, os, sys
try:
    import codetracer_python_recorder as m
except Exception:
    sys.exit(1)
# The identity is the CONTENT of the installed package, not its import path.
# A path alone is wrong in both directions: two different Nix store paths can
# hold byte-identical recorders (a rebuild with no source change), and one
# stable path — a `pip install -e` checkout, or a venv's site-packages — can
# hold a recorder that changed under it. Content answers both.
root = os.path.dirname(os.path.realpath(m.__file__))
h = hashlib.sha256()
for dirpath, dirnames, filenames in os.walk(root):
    dirnames.sort()
    for name in sorted(filenames):
        if name.endswith(('.pyc', '.pyo')):
            continue          # byte-compiled caches are not the recorder
        p = os.path.join(dirpath, name)
        h.update(os.path.relpath(p, root).encode('utf-8'))
        h.update(b'\0')
        try:
            with open(p, 'rb') as fh:
                while True:
                    chunk = fh.read(1 << 20)
                    if not chunk:
                        break
                    h.update(chunk)
        except OSError:
            sys.exit(1)       # an unreadable member means NO identity, not a
                              # partial one that would compare equal by luck
print('py-' + h.hexdigest()[:24])
"""
  ## Run by `pythonRecorderIdentity` through the interpreter `ct record` will
  ## actually use. Computed in Python rather than in Nim because the question
  ## is "what will THAT interpreter import", and only that interpreter can
  ## answer it — resolving site-packages from the outside is how a probe comes
  ## to describe a different installation from the one that runs.

proc pythonRecorderIdentity(): string =
  let python = pythonInterpreter()
  if python.len == 0:
    return ""
  let tmp = getTempDir() / "ct-recorder-identity-" & $getCurrentProcessId() & ".py"
  try:
    writeFile(tmp, PythonRecorderIdentityProgram)
    let (output, code) = execCmdEx(quoteShell(python) & " " & quoteShell(tmp))
    if code != 0:
      return ""
    result = output.strip()
  except CatchableError:
    result = ""
  finally:
    removeFile(tmp)

proc recorderIdentity*(probe: FixtureProbe): string =
  ## A stable content identity for the recorder that would produce this
  ## fixture, or "" when it cannot be determined.
  ##
  ## "" IS A FIRST-CLASS ANSWER AND MUST NOT BE FAKED. It means "no opinion",
  ## and every caller treats it as such. Returning a placeholder instead — the
  ## interpreter path, a timestamp, the string "unknown" — would turn "we do
  ## not know" into a value that compares unequal to the stamp and re-records
  ## a perfectly good fixture on every run of a machine where the probe simply
  ## does not work.
  case probe.kind
  of pkNargo: nargoIdentity()
  of pkPythonRecorder: pythonRecorderIdentity()

proc stampContent(spec: FixtureSpec; identity: string): string =
  ## What `recordFixture` writes into `FixtureStampFile`.
  ##
  ## The first line is still the bare fixture name, unchanged, because that is
  ## what every existing reader of this file expects to find there.
  result = spec.name & "\n"
  if identity.len > 0:
    result.add(StampRecorderPrefix & identity & "\n")

proc stampRecorder(path: string): string =
  ## The recorder identity recorded in a stamp file, or "" if it carries none
  ## — which is what every stamp written before 2026-10-12 looks like.
  if not fileExists(path):
    return ""
  try:
    for line in readFile(path).splitLines():
      if line.startsWith(StampRecorderPrefix):
        return line[StampRecorderPrefix.len .. ^1].strip()
  except CatchableError:
    discard
  ""

proc findCtFile(dir: string): string =
  for kind, path in walkDir(dir):
    if kind == pcFile and path.endsWith(".ct"):
      return path
  ""

proc isUsableTraceDir*(dir: string): bool =
  ## Does this directory hold something `replay-server` can open?
  ##
  ## The three shapes are the ones `src/tests/gui/tests/noir-space-ship/
  ## noir_space_ship_test.nim` already recognises, kept identical on purpose:
  ## a `trace.bin` (db/CTFS container), an `rr/` subdirectory (native
  ## recording), or a `.ct` container file.
  if not dirExists(dir):
    return false
  if fileExists(dir / "trace.bin"):
    return true
  if dirExists(dir / "rr"):
    return true
  findCtFile(dir).len > 0

# ---------------------------------------------------------------------------
# Readability — can THIS build open the cached container?
# ---------------------------------------------------------------------------
#
# The recorder-identity check above answers "was this made by the recorder
# installed now". It cannot answer the question a cache hit actually depends
# on, "can the reader built from this checkout open it", in two cases:
#
#   * NO RECORDER HERE. The current identity is "", which means keep — the
#     warm-cache-without-a-recorder case. A shared cache copied into a fresh
#     worktree with no recorder installed was therefore adopted unconditionally,
#     and a CTFS v4 container in it reached a `replay-server` that reads 5 and
#     6 only, so every fixture suite died at launch naming itself
#     (codetracer-pm `issues/2026-10-11-tui-fixture-cache-adopts-a-container-
#     the-reader-refuses.md`).
#   * THE SAME RECORDER, A NEWER READER. A trace-format bump moves the reader
#     without moving the recorder's identity, and the stamp still matches.
#
# So adoption also asks the reader. `codetracer-pm spec/Testing/Testing-
# Guidelines.md` ("A cached recording is adopted only if this build can read
# it") states the rule: a container this build refuses is a cache MISS — it
# is re-recorded, or, with nothing to record it with, a counted MISSING-PREREQ
# skip that names the refusal — never a test failure in whichever suite opened
# it first.
#
# The question is put to `ctfs_sources.readCtfsMetaDat`, the CTFS reader this
# checkout's `ct` opens every recording with, rather than to a copy of its
# version numbers kept here: it gates the container version (`ctfs-container.md`
# §1, §2 "Older versions are refused") and the `meta.dat` schema version, which
# have each stranded this cache on their own (container v4, 2026-10-11;
# `meta.dat` v6 against a v7 engine, the PLAT-68 review), and both of its
# gates mirror `replay-server`'s (`ctfs_container.rs` `CTFS_VERSION` /
# `CTFS_VERSION_V6`, `meta_dat.rs` `SUPPORTED_VERSIONS`).

proc cachedRecordingRefusal*(dir: string): string =
  ## "" when this build's CTFS reader opens the recording in `dir`; otherwise
  ## the reader's own refusal, verbatim, so a skip or a failure that cites it
  ## names the version found and the versions read.
  ##
  ## A directory without a `.ct` container (`trace.bin`, `rr/`) is "" — this
  ## probe has nothing to say about a shape it does not read, and the other
  ## shapes are not the CTFS versioning this guards.
  let container = findCtFile(dir)
  if container.len == 0:
    return ""
  try:
    discard readCtfsMetaDat(container)
    ""
  except CatchableError as e:
    # `ValueError` is the reader's refusal; `IOError` an unreadable file. Both
    # mean this build cannot open it, and neither may escape as a crash of the
    # suite that merely asked for a fixture.
    container & ": " & e.msg

# ---------------------------------------------------------------------------
# Recording
# ---------------------------------------------------------------------------

proc recordTimeoutSeconds(): int =
  ## Per-fixture wall-clock budget for `ct record`.
  ##
  ## A timeout is a distinguishable outcome here, not a silent one: the
  ## `timeout` wrapper exits 124 and `recordFixture` raises naming that code,
  ## per Verification-Harness-Traps §1 ("a hang arm is one whose recorded rc is
  ## 124"). Overridable because a Noir recording on a cold `nargo` cache is
  ## legitimately slower than one on a warm one.
  let fromEnv = getEnv("CT_TUI_FIXTURE_TIMEOUT", "")
  if fromEnv.len > 0:
    try:
      return parseInt(fromEnv)
    except ValueError:
      raise newException(ValueError,
        "CT_TUI_FIXTURE_TIMEOUT is not a number: " & fromEnv)
  600

proc recordFixture(root, ctBin: string; spec: FixtureSpec;
                   destination: string): string =
  ## Record `spec` into `destination` and return the recorded trace directory.
  ##
  ## RAISES on every failure. A recorder that is present and produces nothing
  ## is a defect, and the whole point of the MISSING-PREREQ split above is that
  ## it is reported as one rather than folded into the same "not available"
  ## bucket as a recorder nobody installed.
  let staging = destination & ".partial"
  removeDir(staging)
  createDir(staging)

  let seconds = recordTimeoutSeconds()
  let command = "timeout " & $seconds & " " & quoteShell(ctBin) &
    " record -o " & quoteShell(staging) & " " & quoteShell(root / spec.program)
  let (output, code) = execCmdEx(command)
  if code != 0:
    let diagnosis =
      if code == 124:
        "timed out after " & $seconds & "s (raise CT_TUI_FIXTURE_TIMEOUT)"
      else:
        "exit " & $code
    removeDir(staging)
    raise newException(IOError,
      "fixture '" & spec.name & "': `ct record` failed (" & diagnosis &
      ")\n  command: " & command & "\n" & output)

  # `ct record` may place the container in the folder it was given, or in a
  # single subdirectory of it, depending on the recorder. Accept either, and
  # accept NOTHING ELSE: a directory that holds neither shape is a recording
  # that did not happen, and returning it would move the failure to the first
  # `launch` request, where it reads as a replay-server defect.
  var recorded = ""
  if isUsableTraceDir(staging):
    recorded = staging
  else:
    for kind, path in walkDir(staging):
      if kind == pcDir and isUsableTraceDir(path):
        recorded = path
        break
  if recorded.len == 0:
    raise newException(IOError,
      "fixture '" & spec.name & "': `ct record` reported success but left no " &
      "recognisable trace under " & staging & " (looked for trace.bin, an " &
      "rr/ directory, or a .ct container)\n  command: " & command & "\n" &
      output)

  # A recorder that is present and writes a container this build refuses is a
  # FAILURE, and it is raised here, naming the recorder, rather than cached for
  # the first suite to trip over at `launch`. Nothing is left under the cache
  # name: adopting it would only move the same refusal one run later.
  let refusal = cachedRecordingRefusal(recorded)
  if refusal.len > 0:
    removeDir(staging)
    raise newException(IOError,
      "fixture '" & spec.name & "': " & spec.recorder & " recorded a trace " &
      "this build cannot read — the recorder and this checkout's reader are " &
      "at different trace-format revisions: " & refusal &
      "\n  command: " & command)

  writeFile(recorded / FixtureStampFile,
            stampContent(spec, recorderIdentity(spec.probe)))
  # One rename, so a reader (or a concurrent lane) never sees a half-written
  # cache entry under the name it looks the fixture up by.
  if recorded != staging:
    # The recorder nested the container; promote it so the cached directory IS
    # the trace directory and callers never have to re-derive that.
    let promoted = staging & ".promoted"
    removeDir(promoted)
    moveDir(recorded, promoted)
    removeDir(staging)
    moveDir(promoted, destination)
  else:
    moveDir(staging, destination)
  destination

# ---------------------------------------------------------------------------
# Resolution
# ---------------------------------------------------------------------------

proc missingPrereqMessage*(spec: FixtureSpec; detail: string): string =
  ## The single greppable line a caller prints for an unresolved fixture.
  ##
  ## Shape fixed by CTUI-1: `MISSING-PREREQ SKIP: <fixture> (<recorder>)`,
  ## with the specific diagnosis after it — the prefix and the two names are
  ## what a log reader greps for, the detail is what tells them what to do.
  MissingPrereqSkipPrefix & " " & spec.name & " (" & spec.recorder & ") — " &
    detail & " " & spec.buildHint

proc resolveFixture*(spec: FixtureSpec;
                     locateCt: proc (): string {.nimcall.} = findCtBinary):
                    FixtureResolution =
  ## Resolve one declared fixture to a trace directory, recording it if needed.
  ##
  ## `locateCt` is how the record step finds `ct`; every production caller
  ## takes the default, `findCtBinary`. It is a parameter so a suite can stage
  ## "`ct` is not built" on a host where it is: `findCtBinary` falls back to
  ## paths inside the checkout, so no environment variable can hide a built
  ## `ct`, and the behaviour when it is absent — keep the cache, skip by name —
  ## is exactly what has to be tested (`../test_fixture_cache_stale_recorder.nim`).
  result.spec = spec

  let root = repoRoot()

  # 1. Declared but unobtainable. Checked FIRST, and deliberately before the
  #    recorder probe: `threads`'s recorder is installed and works, and the
  #    fixture is still impossible. Probing first would report "recorder
  #    present" and then record a trace that cannot answer the question the
  #    fixture exists to answer.
  if spec.blockedOn.len > 0:
    result.outcome = foMissingPrereq
    result.detail = spec.blockedOn
    return

  let key = fixtureKey(root, spec)
  let cached = fixtureCacheRoot(root) / (spec.name & "-" & key)

  # 2. The cache. The stamp is checked as well as the trace shape, so a
  #    directory left by an interrupted run is re-recorded rather than adopted.
  #
  #    AND the stamp's recorder identity is checked against the recorder that
  #    is installed NOW. `fixtureKey` cannot carry that (see the long note at
  #    `recorderIdentity`), so without this check a directory produced by a
  #    recorder that has since been replaced is re-adopted silently and
  #    forever — which on 2026-10-12 kept a CTFS v4 container in circulation
  #    against a `replay-server` that reads only 5 and 6.
  #
  #    THE ASYMMETRY BETWEEN THE TWO "UNKNOWN"S IS DELIBERATE, and it is the
  #    part worth reading twice, because the obvious symmetric rule ("re-record
  #    only when both are known and they differ") is inert against the very
  #    case that motivated this code:
  #
  #      * AN UNKNOWN **CURRENT** IDENTITY MEANS KEEP. There is no recorder
  #        here to ask, so there is nothing to compare against and no way to
  #        re-record either. This is the warm-cache-without-a-recorder case
  #        `findCtBinary` documents, and it is preserved exactly.
  #      * AN UNKNOWN **STAMPED** IDENTITY MEANS RE-RECORD (when a recorder is
  #        present). A stamp with no identity line was written by a provider
  #        that predates this check, so nothing vouches for which recorder
  #        produced it — and "recorded by an unknown recorder, some time ago"
  #        is the precise description of the v4 directory above. Treating it
  #        as "no opinion" would have let that directory survive this fix.
  #
  #    The cost of the asymmetry is one re-recording per pre-existing fixture
  #    per checkout, once. That is the migration, not a regression.
  #
  #    And before either identity is consulted, the READER is: a container
  #    this build refuses is never adopted, whatever its stamp says and
  #    whether or not a recorder is here (see `cachedRecordingRefusal`). That
  #    is the one case the "unknown current identity means keep" rule must not
  #    cover — keeping a recording nothing here can open is not keeping a warm
  #    cache, it is moving the failure to `launch`.
  #
  #    A MISS IS NOT A DELETION. Every reason below for not adopting the entry
  #    is a decision to RE-RECORD it, and that decision can only be carried out
  #    with `ct` and the recorder both present. Until step 3 has established
  #    that, the entry stays where it is and the skip names why it was not
  #    adopted. Deleting it earlier turned a stale-recorder hit on a host with
  #    no `ct` into a MISSING-PREREQ skip AND an empty cache, for every later
  #    suite in the lane (codetracer-pm `issues/2026-10-21-tui-fixture-
  #    provider-deletes-a-stale-fixture-it-cannot-re-record.md`).
  var refusal = ""
  var staleness = ""
  if fileExists(cached / FixtureStampFile) and isUsableTraceDir(cached):
    refusal = cachedRecordingRefusal(cached)
    if refusal.len == 0:
      let stamped = stampRecorder(cached / FixtureStampFile)
      let current = recorderIdentity(spec.probe)
      if current.len == 0 or stamped == current:
        result.outcome = foRecorded
        result.tracePath = cached
        return
      let stampedText =
        if stamped.len > 0: "by recorder " & stamped
        else: "by a recorder its stamp does not identify"
      staleness = "the recording cached at " & cached & " was made " &
        stampedText & ", not by the installed " & current &
        ", and is kept until it can be re-recorded"

  # A cache miss from here on, for one of four reasons: nothing cached, an
  # unfinished directory, a different recorder, or a container this build
  # refuses. The last two are named in a skip, because they are the ones
  # where a finished recording IS cached under the fixture's name, and a
  # reader seeing "nothing is cached" would go looking in the wrong place.
  let missed =
    if refusal.len > 0:
      "the recording cached at " & cached & " cannot be read by this build (" &
      refusal & ")"
    elif staleness.len > 0:
      staleness
    else:
      "nothing usable is cached at " & cached

  # 3. Record. `ct` is only required HERE — a warm cache needs no recorder at
  #    all, and failing a run for a missing recorder it never had to use would
  #    be the mirror image of the defect this file is written against.
  let ctBin = locateCt()
  if ctBin.len == 0:
    result.outcome = foMissingPrereq
    result.detail =
      "`ct` is not built (set $CT_BIN, or run `just build-once`), so " &
      spec.name & " cannot be recorded and " & missed
    return

  let probed = probeRecorder(spec.probe)
  if not probed.ok:
    result.outcome = foMissingPrereq
    result.detail = probed.detail & "; " & missed
    return

  # Remove whatever is under the cache name — a stale recording, or a
  # directory an interrupted run left without its stamp — only NOW, when a
  # re-recording is certain to be attempted: the path is the cache key's whole
  # address, so leaving it would make `recordFixture` `moveDir` onto an
  # existing directory. Removed no earlier, so a skip discards nothing.
  removeDir(cached)
  createDir(fixtureCacheRoot(root))
  result.outcome = foRecorded
  result.tracePath = recordFixture(root, ctBin, spec, cached)

proc resolveFixture*(name: string): FixtureResolution =
  ## Convenience overload: resolve by declared name.
  resolveFixture(fixtureSpec(name))
