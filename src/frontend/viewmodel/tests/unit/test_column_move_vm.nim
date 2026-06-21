## M1 — Headless ViewModel test for column-aware breakpoints driven
## through the **Move** recorder pipeline (`codetracer-move-recorder
## record <foo.move>`).
##
## Spec:
##   codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org
##   §M1 Acceptance tests — Headless ViewModel (Move language slice).
##
## Companions:
##   * ``test_column_breakpoint_vm.nim`` — canonical M1 (JS recorder).
##   * ``test_column_nim_vm.nim``        — Nim VM tracer variant.
##   * ``test_column_noir_vm.nim``       — Noir variant (gated on
##     ``NARGO_PATH``; same gating pattern we follow here).
##
## ## Why this test exists
##
## The Move recorder ships its own debug_info code_map pipeline
## (`codetracer-move-recorder` + `sui move test --trace`) that resolves
## each VM PC to a `(line, column)` byte offset.  The synthetic Rust
## sibling (`dap_column_move.rs`) pins the DAP→replay-engine contract
## against an in-memory trace, but does not exercise the real
## recorder→reader→ViewModel pipeline.  This test closes that gap by
## driving a *real* Move recording through ``headless_session.nim``
## and asserting on the `(line, column)` round-trip.
##
## ## Gating
##
## REQUIRES ``CODETRACER_MOVE_RECORDER_PATH`` (absolute path to a
## built ``codetracer-move-recorder``).  When unset the test is
## ``skip()``ped — running it against the legacy line-only Move
## recorder would fail confusingly on the column assertions.  This
## matches the gating discipline already established for the Noir
## variant (see ``test_column_noir_vm.nim``'s ``NARGO_PATH`` check).
##
## Environment summary:
##   * ``CODETRACER_MOVE_RECORDER_PATH`` — REQUIRED.  Path to the
##     column-aware ``codetracer-move-recorder`` binary.  Unset =>
##     SKIPPED.
##   * ``REPLAY_SERVER_BIN`` — path to a built replay-server; defaults
##     to the standard cargo-debug or `just build-once` output paths.
##   * ``CODETRACER_MOVE_COLUMN_AWARE_FIXTURE`` — override the
##     fixture project dir; defaults to
##     ``../codetracer-move-recorder/test-programs/move/column_aware``.
##   * ``CODETRACER_SUI_CLI`` — path to the ``sui`` CLI; defaults to
##     ``findExe("sui")``.  The Move recorder shells out to
##     ``sui move test --trace`` to generate the raw trace the
##     converter feeds into the column-aware reader.
##
## ## Compile + run
##
##   nim c -r src/frontend/viewmodel/tests/unit/test_column_move_vm.nim
##
## ## Fixture column layout (observed from a fresh recording)
##
## The Move recorder lands a step on each ``blackbox(`` call's
## **argument-borrow** PC.  For the ``column_aware`` fixture's line 23
## (``blackbox(&mut v, 100); blackbox(&mut v, 200); blackbox(&mut v, 300);``)
## those PCs map (via the debug_info code_map) to columns 18, 41, and
## 64 — the start of the ``&mut`` argument of each call, which is the
## first emitted instruction the Move bytecode generator pins to that
## call site.  Pinning as ``const`` doubles as a regression guard for
## the recorder's PC→column resolution.

import std/[json, options, os, osproc, strutils, unittest]

import ../../headless_session
import recorder_gate

# ---------------------------------------------------------------------------
# Fixture constants — pinned from the actual recorder output for the
# column_aware fixture (`codetracer-move-recorder/test-programs/move/
# column_aware/sources/column_aware.move`, line 23).  See module
# docstring for the source-to-column derivation.
# ---------------------------------------------------------------------------

const
  MultiStmtLine     = 23   # the three-blackbox-call line
  ColFirstBlackbox  = 18   # blackbox(&mut v, 100) arg-borrow start
  ColSecondBlackbox = 41   # blackbox(&mut v, 200) arg-borrow start
  ColThirdBlackbox  = 64   # blackbox(&mut v, 300) arg-borrow start
  VecLenLine        = 24   # `let len = std::vector::length(&v);`

# ---------------------------------------------------------------------------
# Repo + tool discovery (mirrors the gating pattern from the Noir variant).
# ---------------------------------------------------------------------------

proc repoRoot(): string =
  ## Locate the codetracer repo root by walking upward from this file.
  var dir = currentSourcePath().parentDir
  while dir.len > 0:
    if dirExists(dir / "src" / "db-backend") and dirExists(dir / "src" / "frontend"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "could not locate codetracer repo root from " & currentSourcePath())

proc findReplayServer(): string =
  ## Resolve a replay-server binary (env override or standard build paths).
  let envBin = getEnv("REPLAY_SERVER_BIN", "")
  if envBin.len > 0 and fileExists(envBin):
    return envBin
  for c in [repoRoot() / "src" / "build-debug" / "bin" / "replay-server",
            repoRoot() / "src" / "db-backend" / "target" / "debug" / "replay-server",
            repoRoot() / "src" / "db-backend" / "target" / "release" / "replay-server"]:
    if fileExists(c): return c
  raise newException(IOError,
    "missing replay-server; set REPLAY_SERVER_BIN or build via " &
    "`cd src/db-backend && cargo build`")

proc findColumnAwareMoveRecorder(): string =
  ## REQUIRES ``CODETRACER_MOVE_RECORDER_PATH`` (absolute path to a
  ## column-aware ``codetracer-move-recorder``).  Empty string =>
  ## test should skip.  We deliberately do NOT fall back to a
  ## sibling-repo lookup or ``which`` search: a legacy recorder
  ## without column-aware emission would silently surface
  ## ``column = None`` and the assertions below would fail
  ## confusingly.  Force opt-in instead — matches the
  ## ``NARGO_PATH`` gating in ``test_column_noir_vm.nim``.
  let envPath = getEnv("CODETRACER_MOVE_RECORDER_PATH", "")
  if envPath.len == 0:
    return ""
  if not fileExists(envPath):
    raise newException(IOError,
      "CODETRACER_MOVE_RECORDER_PATH=" & envPath &
      " does not point at an existing file")
  return envPath

proc findColumnAwareFixture(): tuple[projectDir, sourcePath: string] =
  ## Locate the ``column_aware`` Move test-program fixture.  Defaults
  ## to the sibling repo layout; an env override is provided so
  ## downstream packagers can point at a vendored copy.
  let envDir = getEnv("CODETRACER_MOVE_COLUMN_AWARE_FIXTURE", "")
  let projectDir =
    if envDir.len > 0 and dirExists(envDir):
      envDir
    else:
      repoRoot() / ".." / "codetracer-move-recorder" /
        "test-programs" / "move" / "column_aware"
  if not dirExists(projectDir):
    raise newException(IOError,
      "Move column_aware fixture project dir not found: " & projectDir &
      " — set CODETRACER_MOVE_COLUMN_AWARE_FIXTURE to override")
  let sourcePath = projectDir / "sources" / "column_aware.move"
  if not fileExists(sourcePath):
    raise newException(IOError,
      "Move column_aware fixture source not found: " & sourcePath)
  (projectDir: projectDir, sourcePath: sourcePath)

proc findSuiCli(): string =
  ## Locate the ``sui`` CLI used by the Move recorder's
  ## ``record_from_move_source`` path (shells out to ``sui move test
  ## --trace`` to produce the raw debug_info-enriched trace the
  ## converter then turns into a column-aware CTFS).
  let envBin = getEnv("CODETRACER_SUI_CLI", "")
  if envBin.len > 0 and fileExists(envBin):
    return envBin
  result = findExe("sui")
  if result.len == 0:
    raise newException(IOError,
      "missing `sui` CLI; set CODETRACER_SUI_CLI or enter the Nix " &
      "dev shell.  The Move recorder needs sui to regenerate the " &
      "column_aware test trace through `sui move test --trace`.")

proc fixtureDir(): string =
  ## Per-process temp dir for the recorded CodeTracer trace.  Scoped
  ## by pid so concurrent test runs don't stomp each other.
  getTempDir() / ("ct_column_move_vm_" & $getCurrentProcessId())

proc recordMoveTrace(recorder: string;
                     fixture: tuple[projectDir, sourcePath: string]): string =
  ## Drive the codetracer-move-recorder CLI through the
  ## ``record <foo.move>`` source pipeline (which spawns
  ## ``sui move test --trace`` then converts via
  ## ``ConverterOptions::for_ct_record_flow()`` — the only path that
  ## enables ``resolve_pc_lines_from_debug_info`` and thus emits the
  ## debug_info code_map columns this test asserts on; passing a
  ## pre-recorded ``.json.zst`` instead would silently fall through to
  ## the legacy ``convert_trace`` branch and report ``column=None``).
  ##
  ## Returns the recorded trace path (the ``.ct`` file the
  ## headless_session driver opens).
  let dir = fixtureDir()
  if dirExists(dir):
    removeDir(dir)
  createDir(dir)

  # Validate ``sui`` early so a missing toolchain produces a clear
  # error rather than a deep recorder-internal failure.
  discard findSuiCli()
  let outDir = dir / "trace"
  createDir(outDir)

  let cmd =
    quoteShell(recorder) & " record " &
    quoteShell(fixture.sourcePath) &
    " --out-dir " & quoteShell(outDir)
  let (output, code) = execCmdEx(cmd)
  doAssert code == 0,
    "Move recorder failed to record column_aware source " &
    fixture.sourcePath & " (exit " & $code & ")\n" & output

  # Recorder writes a ``<module>.ct`` CTFS container directly into
  # ``--out-dir``; older versions used a ``trace-N/`` subdirectory.
  # Probe for both shapes and return the first ``.ct`` found, falling
  # back to the out-dir itself for the rare case where a nested
  # directory IS the CTFS bundle the reader wants.
  for kind, path in walkDir(outDir):
    if kind == pcFile and path.endsWith(".ct"):
      return path
    if kind == pcDir and path.lastPathPart.startsWith("trace-"):
      for kind2, inner in walkDir(path):
        if kind2 == pcFile and inner.endsWith(".ct"):
          return inner
      return path
  doAssert false,
    "Move recorder produced no .ct file under " & outDir &
    "\n--- output ---\n" & output
  outDir  # unreachable

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc continueUntilLine(s: HeadlessDebugSession; line: int;
                       maxSteps: int = 64): bool =
  ## Issue forward Continues until the backend reports a step at the
  ## given line, or ``maxSteps`` iterations elapse.  Returns whether
  ## the target line was reached.  Used by the legacy line-only test
  ## to tolerate intermediate steps between the initial entry and the
  ## first step on ``VecLenLine`` — the recorder lands steps on
  ## inlined helpers (`blackbox` body on line 17) between top-level
  ## statements.
  for _ in 0 ..< maxSteps:
    if s.getCurrentLine() == line:
      return true
    s.continueForward()
  s.getCurrentLine() == line

# ---------------------------------------------------------------------------
# Test gating template — mirrors ``test_column_noir_vm.nim::gateOnNargo``.
# ---------------------------------------------------------------------------

template gateOnMoveRecorder(testName: string, body: untyped): untyped =
  ## Run ``body`` only when ``CODETRACER_MOVE_RECORDER_PATH`` is set;
  ## otherwise ``skip()``.  Exposes ``recorder``, ``replayServer``,
  ## ``fixture``, ``tracePath``, and ``session`` to ``body``.
  let recorderPath = findColumnAwareMoveRecorder()
  if recorderPath.len == 0:
    skipMissingRecorder("codetracer-move-recorder",
      "CODETRACER_MOVE_RECORDER_PATH",
      "Build the codetracer-move-recorder sibling (just build-release).")
  else:
    let recorder {.inject.} = recorderPath
    let fixture {.inject.} = findColumnAwareFixture()
    let replayServer {.inject.} = findReplayServer()
    let tracePath {.inject.} = recordMoveTrace(recorder, fixture)
    var session {.inject.} = newHeadlessDebugSession(tracePath, replayServer)
    body

# ---------------------------------------------------------------------------
# Test cases
# ---------------------------------------------------------------------------

suite "M1 — Column-aware breakpoint through the ViewModel (Move)":

  test "test_column_move_vm_stops_at_second_blackbox_call":
    ## STRICT — set a column-aware breakpoint at the SECOND blackbox
    ## call (column 41) on line 23, continue, and assert the stop's
    ## ``(line, column)`` matches.  A line-only fallback would
    ## (wrongly) stop at column 18 (first blackbox); the column-aware
    ## key must skip past it.
    gateOnMoveRecorder("test_column_move_vm_stops_at_second_blackbox_call"):
      check session.getCurrentFile().endsWith("column_aware.move")

      let resp = session.lastSetBreakpointsResponse(
        fixture.sourcePath, line = MultiStmtLine, column = ColSecondBlackbox)
      check resp.getOrDefault("success").getBool(false)
      let bps = resp.getOrDefault("body").getOrDefault("breakpoints")
      check bps.kind == JArray
      check bps.len == 1
      check bps[0].getOrDefault("verified").getBool(false)
      # Wire-level half of M1: the response MUST echo the bound column.
      check bps[0].hasKey("column")
      check bps[0]["column"].getInt(0) == ColSecondBlackbox
      check bps[0].getOrDefault("line").getInt(0) == MultiStmtLine

      session.continueForward()
      check session.getCurrentLine() == MultiStmtLine
      let afterCol = session.getCurrentColumn()
      check afterCol.isSome
      check afterCol.get() == ColSecondBlackbox

  test "test_column_move_vm_skips_earlier_columns_on_same_line":
    ## STRICT — breakpoint at the THIRD blackbox call (column 64); the
    ## replay engine MUST skip past earlier same-line steps (cols 18
    ## and 41).  Guards against the "store-but-not-consult" bug where
    ## the column lives on the breakpoint record but isn't consulted
    ## on the stop check (that bug would land us at column 18 or 41).
    gateOnMoveRecorder("test_column_move_vm_skips_earlier_columns_on_same_line"):
      check session.getCurrentFile().endsWith("column_aware.move")

      let resp = session.lastSetBreakpointsResponse(
        fixture.sourcePath, line = MultiStmtLine, column = ColThirdBlackbox)
      check resp.getOrDefault("success").getBool(false)
      let bps = resp.getOrDefault("body").getOrDefault("breakpoints")
      check bps.kind == JArray
      check bps.len == 1
      check bps[0].getOrDefault("verified").getBool(false)
      check bps[0]["column"].getInt(0) == ColThirdBlackbox

      session.continueForward()
      check session.getCurrentLine() == MultiStmtLine
      let afterCol = session.getCurrentColumn()
      check afterCol.isSome
      check afterCol.get() == ColThirdBlackbox
      # Document the unused first-column anchor so future readers see
      # the full set of three call sites at a glance; suppresses the
      # unused-warning without weakening the assertion above.
      discard ColFirstBlackbox

  test "test_column_move_vm_line_only_breakpoint_preserved":
    ## STRICT — legacy line-only breakpoints (no ``column`` key on
    ## the wire) MUST keep working after the M1 extension.  Pins
    ## back-compat for DAP clients (and recorders) that don't yet
    ## send columns.  The recorder still emits a column on every
    ## step (column-aware mode is trace-global), so a line-only
    ## match must fire on the FIRST same-line step regardless of
    ## that step's recorded column.
    gateOnMoveRecorder("test_column_move_vm_line_only_breakpoint_preserved"):
      check session.getCurrentFile().endsWith("column_aware.move")

      let resp = session.lastSetBreakpointsResponse(
        fixture.sourcePath, line = VecLenLine, column = 0)
      check resp.getOrDefault("success").getBool(false)
      let bps = resp.getOrDefault("body").getOrDefault("breakpoints")
      check bps.kind == JArray
      check bps.len == 1
      check bps[0].getOrDefault("verified").getBool(false)
      # `column` is `skip_serializing_if = Option::is_none` on the
      # Rust side, so the legacy response either omits the key or
      # sets it to JNull — both shapes are equivalent to "no column".
      let colNode = bps[0].getOrDefault("column")
      check colNode.isNil or colNode.kind == JNull

      # Continue forward to the vec_len line.  The Move recorder
      # lands many intermediate steps between the test entry and
      # line 24 (one per blackbox call's inlined push_back body on
      # line 17), so we tolerate intermediate stops by re-continuing.
      check session.continueUntilLine(VecLenLine)
      check session.getCurrentLine() == VecLenLine
      # The recorder still emits a column for column-aware Move
      # traces; line-only matching just means the breakpoint hit
      # fires regardless of column.  We don't pin the exact column
      # here because the recorder may land on a different code_map
      # entry on the same line (e.g. line-start vs the
      # ``std::vector::length`` call site) depending on which step
      # the line-only loop converges on first.
      let landedCol = session.getCurrentColumn()
      if landedCol.isSome:
        check landedCol.get() >= 1

when isMainModule:
  discard
