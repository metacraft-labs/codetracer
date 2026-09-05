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
##      invalidates its recording rather than silently reusing a stale one;
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
##     message naming the build command, exactly as
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
  ## Locate `replay-server`, exactly as the existing headless suite does.
  ##
  ## `REPLAY_SERVER_BIN`, then `src/build-debug/bin/replay-server`, then a
  ## DIAGNOSTIC FAILURE naming the build command — never a skip. CTUI-1 states
  ## this as a contract, and the reason is that `replay-server` is not a
  ## per-fixture prerequisite: it is what "open a trace" MEANS. A run without
  ## it has not tested a fixture corpus, it has tested nothing, and a skip
  ## would let that read as green.
  let envBin = getEnv("REPLAY_SERVER_BIN", "")
  if envBin.len > 0 and fileExists(envBin):
    return envBin
  let candidate = repoRoot() / "src" / "build-debug" / "bin" / "replay-server"
  if fileExists(candidate):
    return candidate
  raise newException(IOError,
    "Could not find replay-server binary. Set REPLAY_SERVER_BIN or " &
    "build it with 'cargo build' in src/db-backend/. Tried: " & candidate)

proc findCtBinary*(): string =
  ## Locate `ct`, the binary that drives every recorder.
  ##
  ## Returns "" rather than raising when it is absent, because unlike
  ## `replay-server` this is a *recording* prerequisite: with a warm fixture
  ## cache the corpus is fully testable without it, so its absence must not
  ## fail a run that never needed to record anything. `resolveFixture` turns a
  ## "" here into a MISSING-PREREQ skip only when it actually has to record.
  let envBin = getEnv("CT_BIN", "")
  if envBin.len > 0 and fileExists(envBin):
    return envBin
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

  writeFile(recorded / FixtureStampFile, spec.name & "\n")
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

proc resolveFixture*(spec: FixtureSpec): FixtureResolution =
  ## Resolve one declared fixture to a trace directory, recording it if needed.
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
  if fileExists(cached / FixtureStampFile) and isUsableTraceDir(cached):
    result.outcome = foRecorded
    result.tracePath = cached
    return

  # 3. Record. `ct` is only required HERE — a warm cache needs no recorder at
  #    all, and failing a run for a missing recorder it never had to use would
  #    be the mirror image of the defect this file is written against.
  let ctBin = findCtBinary()
  if ctBin.len == 0:
    result.outcome = foMissingPrereq
    result.detail =
      "`ct` is not built (set $CT_BIN, or run `just build-once`), so " &
      spec.name & " cannot be recorded and nothing is cached at " & cached
    return

  let probed = probeRecorder(spec.probe)
  if not probed.ok:
    result.outcome = foMissingPrereq
    result.detail = probed.detail
    return

  createDir(fixtureCacheRoot(root))
  result.outcome = foRecorded
  result.tracePath = recordFixture(root, ctBin, spec, cached)

proc resolveFixture*(name: string): FixtureResolution =
  ## Convenience overload: resolve by declared name.
  resolveFixture(fixtureSpec(name))
