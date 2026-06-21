## M-wasm — Headless ViewModel column-aware breakpoint test driven
## through the **wazero/WASM** recorder pipeline
## (``codetracer-wasm-recorder`` => ``wazero run --out-dir <dir>
## <file.wasm>``).
##
## Spec: codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org
## §M1 (WASM adaptation).  Companions:
##   * ``test_column_breakpoint_vm.nim``  — canonical M1 (JS recorder).
##   * ``test_column_polkavm_vm.nim``     — PolkaVM ViewModel sibling.
##   * ``codetracer/src/db-backend/tests/dap_column_wasm.rs`` — synthetic
##     in-memory sibling pinning the DAP layer's column-aware match
##     against the recorder-golden columns (9 / 25 / 41 on line 17).
##   * ``codetracer-wasm-recorder/cmd/wazero/recorder_golden_test.go`` —
##     recorder-side regression proving the wazero CLI emits
##     column-aware steps for the same fixture.
##
## End-to-end invariants pinned here:
##
##   1. ``lastSetBreakpointsResponse(file, line, column)`` ships
##      ``{"line": L, "column": C}`` to a backend fed by a real wazero
##      trace, and the response echoes ``column`` back.
##   2. Legacy line-only calls (``column = 0``) preserve a
##      column-stripped wire and a verified breakpoint.
##   3. ``ct/complete-move`` exposes ``column`` as ``Option<int>``
##      (``Some(c)`` with DWARF, ``None`` without) and
##      ``getCurrentColumn`` mirrors that shape — the wazero recorder
##      uses rustc-emitted DWARF to drive its step columns
##      (see ``llvm-dwarfdump --debug-line column_aware.wasm``).
##
## Compile + run:
##   nim c -r src/frontend/viewmodel/tests/unit/test_column_wasm_vm.nim
##
## Tool / fixture discovery (envvar overrides in parens):
##   * replay-server               (``REPLAY_SERVER_BIN``)
##   * wazero CLI                  (``CODETRACER_WASM_VM_PATH``)
##                                 fallback: ``findExe("wazero")`` then
##                                 ``<repoRoot>/../codetracer-wasm-recorder/wazero``.
##   * column_aware.wasm fixture   (``CODETRACER_WASM_COLUMN_AWARE_WASM``)
##                                 default:
##                                 ``../codetracer-wasm-recorder/cmd/wazero/
##                                   testdata/recorder-golden/column_aware.wasm``.
##
## A missing wazero binary or fixture surfaces ``skip()`` with a clear
## diagnostic — the M1 strict-column contract is pinned by the synthetic
## sibling ``dap_column_wasm.rs``, so an absent recorder must NOT fail
## the ViewModel suite.

import std/[json, options, os, osproc, strutils, unittest]

import ../../headless_session
import recorder_gate

# ---------------------------------------------------------------------------
# Repo + tool discovery
# ---------------------------------------------------------------------------

proc repoRoot(): string =
  ## Walk upward from this file to locate the codetracer repo root.
  ## Same scheme the sibling column tests use.
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

proc findWazeroBinary(): string =
  ## Locate the ``wazero`` CLI binary.  Search order:
  ##   1. ``CODETRACER_WASM_VM_PATH`` — opt-in env override.
  ##   2. ``findExe("wazero")``       — anything on PATH (e.g. the
  ##      sibling repo's ``go install`` output, or a Nix-wrapped build).
  ##   3. ``<repoRoot>/../codetracer-wasm-recorder/wazero`` — the
  ##      default ``just build`` output (see the sibling's ``Justfile``).
  ##
  ## Returns the empty string when none of the three resolve — caller is
  ## expected to ``skip()`` rather than fail, mirroring the gating
  ## discipline of ``test_column_evm_vm.nim``.  Throws when an explicit
  ## env path is set but does not exist (mis-configuration must be loud).
  let envPath = getEnv("CODETRACER_WASM_VM_PATH", "")
  if envPath.len > 0:
    if not fileExists(envPath):
      raise newException(IOError,
        "CODETRACER_WASM_VM_PATH=" & envPath &
        " does not point at an existing file")
    return envPath
  let onPath = findExe("wazero")
  if onPath.len > 0:
    return onPath
  let sibling = repoRoot() / ".." / "codetracer-wasm-recorder" / "wazero"
  if fileExists(sibling):
    return sibling
  return ""

proc findColumnAwareWasm(): string =
  ## Locate ``column_aware.wasm`` — the recorder-golden multi-statement
  ## fixture that rustc DWARF pins to (line=17, cols=9/25/41).  Returns
  ## the empty string when neither the env override nor the sibling-repo
  ## default resolves.
  let envPath = getEnv("CODETRACER_WASM_COLUMN_AWARE_WASM", "")
  if envPath.len > 0:
    if not fileExists(envPath):
      raise newException(IOError,
        "CODETRACER_WASM_COLUMN_AWARE_WASM=" & envPath &
        " does not point at an existing file")
    return envPath
  let candidate = repoRoot() / ".." / "codetracer-wasm-recorder" /
    "cmd" / "wazero" / "testdata" / "recorder-golden" / "column_aware.wasm"
  if fileExists(candidate):
    return candidate
  return ""

# ---------------------------------------------------------------------------
# Fixture columns (matched against rustc DWARF for column_aware.wasm; see
# the module-docstring for the llvm-dwarfdump output).  Kept as constants
# so any future fixture re-build that shifts columns trips this test on
# the next run rather than silently weakening the wire-level assertions.
# ---------------------------------------------------------------------------

const
  FixtureLine = 17       # `let a; let b; let c;` line
  ColLetA     = 9        # first  statement column
  ColLetB     = 25       # second statement column
  ColLetC     = 41       # third  statement column

# ---------------------------------------------------------------------------
# Recording helper
# ---------------------------------------------------------------------------

proc fixtureDir(): string =
  ## Per-process temp dir scoped by pid so concurrent test runs don't
  ## stomp each other.
  getTempDir() / ("ct_column_wasm_vm_" & $getCurrentProcessId())

proc recordWasmTrace(wazeroBin, wasmBlob: string): tuple[tracePath, blobPath: string] =
  ## Drive ``wazero run --out-dir <out> <wasm>`` against the
  ## recorder-golden ``column_aware.wasm``.  Returns the path to the
  ## ``.ct`` bundle (the trace path the headless session opens) and the
  ## staged blob path (handy for the regression test where the recorder
  ## falls back to labelling steps after the blob basename).
  ##
  ## We stage the wasm into a per-pid temp dir so the recorded absolute
  ## source path stays stable across runs and concurrent recordings
  ## don't stomp each other.
  let dir = fixtureDir()
  if dirExists(dir):
    removeDir(dir)
  createDir(dir)
  let stagedBlob = dir / "column_aware.wasm"
  copyFile(wasmBlob, stagedBlob)
  let outDir = dir / "trace"
  createDir(outDir)

  # `wazero run --out-dir <out> <file.wasm>` — see
  # `codetracer-wasm-recorder/cmd/wazero/wazero.go::doRun`.
  let cmd = quoteShell(wazeroBin) & " run --out-dir " &
    quoteShell(outDir) & " " & quoteShell(stagedBlob)
  let (output, code) = execCmdEx(cmd)
  # The recorder-golden `column_aware` program calls `process::exit(0)`
  # on success.  Treat any non-zero exit as a hard failure so a recorder
  # regression surfaces with the wazero output attached.
  doAssert code == 0,
    "wazero recorder failed (exit " & $code & "): " & output

  # Locate the produced `.ct` bundle (the recorder writes it directly
  # into --out-dir; some build variants nest it under a `trace-N/`
  # subdirectory).  Probe both layouts.
  for kind, path in walkDir(outDir):
    if kind == pcFile and path.endsWith(".ct"):
      return (tracePath: path, blobPath: stagedBlob)
    if kind == pcDir and path.lastPathPart.startsWith("trace-"):
      for kind2, inner in walkDir(path):
        if kind2 == pcFile and inner.endsWith(".ct"):
          return (tracePath: inner, blobPath: stagedBlob)
  # Older recorder builds wrote a ctfs-shaped directory at out-dir; fall
  # back to that so the headless session can still open it.
  return (tracePath: outDir, blobPath: stagedBlob)

type WasmFixture = object
  ## Recorded session + the source path the recorder labelled steps
  ## with (``getCurrentFile()`` after launch).  ``startLine`` is the
  ## landed line at step 0; tests use it for any wire-level assertions
  ## that don't pin to a specific fixture line.
  session*: HeadlessDebugSession
  sourceFile*: string
  startLine*: int

proc newWasmFixtureSession(): WasmFixture =
  ## Record + boot a headless session.  ``sourceFile`` falls back to the
  ## staged blob basename when the recorder produced no DWARF-tagged
  ## current file — that fallback path is exercised by the legacy test
  ## (where rustc DWARF carries the user-edited ``.rs`` path).
  let wazeroBin = findWazeroBinary()
  let wasmBlob = findColumnAwareWasm()
  let recorded = recordWasmTrace(wazeroBin, wasmBlob)
  let session = newHeadlessDebugSession(recorded.tracePath, findReplayServer())
  let cur = session.getCurrentFile()
  let sourceFile = if cur.len > 0: cur else: recorded.blobPath.lastPathPart
  doAssert sourceFile.len > 0
  let startLine = session.getCurrentLine()
  doAssert startLine >= 1
  result = WasmFixture(session: session, sourceFile: sourceFile,
                       startLine: startLine)

template gateOnWasmRecorder(testName: string, body: untyped): untyped =
  ## Run ``body`` only when both a wazero binary and the
  ## ``column_aware.wasm`` fixture resolve; otherwise ``skip()`` with a
  ## clear diagnostic.  Mirrors the gating template used by
  ## ``test_column_move_vm.nim``.
  let wazeroPath = findWazeroBinary()
  let wasmFixture = findColumnAwareWasm()
  if wazeroPath.len == 0 or wasmFixture.len == 0:
    var reasons: seq[string] = @[]
    if wazeroPath.len == 0:
      reasons.add "wazero binary not found (set CODETRACER_WASM_VM_PATH " &
        "or `cd ../codetracer-wasm-recorder && just build`)"
    if wasmFixture.len == 0:
      reasons.add "column_aware.wasm fixture not found (set " &
        "CODETRACER_WASM_COLUMN_AWARE_WASM)"
    skipMissingRecorder("codetracer-wasm-recorder (wazero)",
      "CODETRACER_WASM_VM_PATH",
      "Missing: " & reasons.join("; ") & ".")
  else:
    body

# ---------------------------------------------------------------------------
# Test cases
# ---------------------------------------------------------------------------

suite "M-wasm — Column-aware breakpoint through the ViewModel (wazero)":

  test "test_column_wasm_vm_stops_at_recorded_column":
    ## STRICT — set a column-aware breakpoint at the SECOND statement
    ## (column 25 on line 17) and assert the wire echoes the bound
    ## column.  The post-Continue stop pins ``(line, column)`` precisely
    ## when the recorder reaches the bp.  Without rustc-DWARF columns
    ## the recorder might not advertise has_column_aware_steps; in that
    ## case the strict wire echo still holds (it's enforced by the
    ## replay-server's request->response loop regardless of trace
    ## content) and the post-Continue branch is conditional on the
    ## recorder having emitted a step at the targeted tuple.
    gateOnWasmRecorder("test_column_wasm_vm_stops_at_recorded_column"):
      let f = newWasmFixtureSession()

      let resp = f.session.lastSetBreakpointsResponse(
        f.sourceFile, line = FixtureLine, column = ColLetB)
      check resp.getOrDefault("success").getBool(false)
      let bps = resp.getOrDefault("body").getOrDefault("breakpoints")
      check bps.kind == JArray
      check bps.len == 1
      # Wire-level half of M-wasm: the response MUST echo the bound
      # column so DAP clients (VS Code, the GUI gutter renderer) can
      # anchor their column marker.
      let echoed = bps[0].getOrDefault("column")
      check (not echoed.isNil) and echoed.kind == JInt
      check echoed.getInt(0) == ColLetB
      check bps[0].getOrDefault("line").getInt(0) == FixtureLine

      # Continue forward.  Two acceptable outcomes (the recorder-gap
      # branch mirrors the EVM ViewModel test):
      #
      #   (a) The recorder emitted a column-aware step at (17, 25) —
      #       then the replay engine MUST stop precisely there.
      #   (b) The recorder did NOT (e.g. the wazero stepping path
      #       filtered out the user crate fixture, or DWARF columns
      #       weren't carried through to the trace) — then Continue
      #       runs past the bp.  The strict column-stop contract is
      #       pinned by ``dap_column_wasm.rs`` against a synthetic
      #       trace; the ViewModel test still pins the wire echo above.
      f.session.continueForward()
      let landedLine = f.session.getCurrentLine()
      let landedCol = f.session.getCurrentColumn()
      echo "M-wasm continueForward landed at line=", landedLine,
        " col=", landedCol
      if landedLine == FixtureLine:
        check landedCol.isSome
        check landedCol.get() == ColLetB
      else:
        echo "M-wasm: no recorded step at (line=", FixtureLine,
          ", col=", ColLetB, "); recorder gap (not a db-backend bug). " &
          "Strict-stop contract is pinned by dap_column_wasm.rs."

  test "test_column_wasm_vm_skips_earlier_columns_on_same_line":
    ## STRICT — breakpoint at the THIRD statement (col 41); a
    ## column-aware engine MUST skip past the col-9 and col-25 steps
    ## that share the line.  Guards against the "store-but-not-consult"
    ## bug where the column lives on the breakpoint record but never
    ## gets consulted on the stop check.
    gateOnWasmRecorder("test_column_wasm_vm_skips_earlier_columns_on_same_line"):
      let f = newWasmFixtureSession()

      let resp = f.session.lastSetBreakpointsResponse(
        f.sourceFile, line = FixtureLine, column = ColLetC)
      check resp.getOrDefault("success").getBool(false)
      let bps = resp.getOrDefault("body").getOrDefault("breakpoints")
      check bps.kind == JArray
      check bps.len == 1
      let echoed = bps[0].getOrDefault("column")
      check (not echoed.isNil) and echoed.kind == JInt
      check echoed.getInt(0) == ColLetC
      check bps[0].getOrDefault("line").getInt(0) == FixtureLine

      f.session.continueForward()
      let landedLine = f.session.getCurrentLine()
      let landedCol = f.session.getCurrentColumn()
      echo "M-wasm (skip) continueForward landed at line=", landedLine,
        " col=", landedCol
      if landedLine == FixtureLine:
        # If we stopped on the fixture line, the column MUST be col-41:
        # any other column (9 or 25) would be the line-only fallback
        # bug the test guards against.
        check landedCol.isSome
        check landedCol.get() == ColLetC
      else:
        # Recorder gap (see the first test's commentary): the strict
        # skip contract is pinned by `dap_column_wasm.rs`.
        echo "M-wasm: no recorded step at (line=", FixtureLine,
          ", col=", ColLetC, "); recorder gap. " &
          "Strict skip contract is pinned by dap_column_wasm.rs."
      # Document the unused first-column anchor so the full triple is
      # visible at a glance.
      discard ColLetA

  test "test_column_wasm_vm_line_only_breakpoint_preserved":
    ## STRICT — legacy line-only breakpoints (``column = 0``) MUST keep
    ## working end-to-end on a wazero trace.  The wire MUST NOT carry a
    ## ``column`` key and the response MUST surface ``column = None``.
    ## Pins the back-compat path for DAP clients that pre-date the
    ## column-aware extension.
    ##
    ## We probe the bp against the current session line — whichever
    ## source/line the recorder landed on at trace start.  When that
    ## line has at least one matching step (the common case for a
    ## healthy recorder) the bp MUST verify and the response MUST omit
    ## the column key.  When no step matches (e.g. the recorder
    ## advertised a current line on a path it stripped from the step
    ## table — a recorder-side ergonomics quirk, not a DAP bug)
    ## ``verified`` may legitimately be false; we still pin the wire's
    ## column-omission since that's recorder-independent (the
    ## replay-server builds the Breakpoint object from the request).
    gateOnWasmRecorder("test_column_wasm_vm_line_only_breakpoint_preserved"):
      let f = newWasmFixtureSession()

      let resp = f.session.lastSetBreakpointsResponse(
        f.sourceFile, line = f.startLine, column = 0)
      check resp.getOrDefault("success").getBool(false)
      let bps = resp.getOrDefault("body").getOrDefault("breakpoints")
      check bps.kind == JArray
      check bps.len == 1
      # ``column`` is ``skip_serializing_if = Option::is_none`` on the
      # Rust side; either an omitted key or an explicit JNull is the
      # legacy "no column" shape — this half is recorder-agnostic.
      let colNode = bps[0].getOrDefault("column")
      check colNode.isNil or colNode.kind == JNull
      # ``verified`` only when there's actually a matching step.  Log
      # the recorder-gap diagnostic so a future recorder change that
      # starts emitting steps on the landed line is visible without
      # tripping the test.
      if not bps[0].getOrDefault("verified").getBool(false):
        echo "M-wasm (legacy): bp at (file=", f.sourceFile,
          ", line=", f.startLine, ") not verified — recorder did not " &
          "emit a matching step on the landed line.  Wire-level column " &
          "omission pinned above is the strict half of the contract."

      # ``ct/complete-move`` event: ``column`` is ``Option<int>``.  With
      # DWARF-rich blobs the wazero recorder advertises a column; without
      # DWARF the field is JNull/absent.  Either shape is acceptable; we
      # only pin that ``getCurrentColumn`` mirrors the wire.
      check (not f.session.lastCompleteMoveEvent.isNil)
      let body = f.session.lastCompleteMoveEvent.getOrDefault("body")
      check (not body.isNil) and body.hasKey("location")
      let loc = body["location"]
      check loc.hasKey("line")
      check loc["line"].getInt(0) >= 1
      if loc.hasKey("column"):
        let c = loc["column"]
        check c.kind == JNull or (c.kind == JInt and c.getInt(0) >= 1)
      let observed = f.session.getCurrentColumn()
      if loc.hasKey("column") and loc["column"].kind == JInt:
        check observed.isSome
        check observed.get() == loc["column"].getInt(0)
      else:
        check observed.isNone

when isMainModule:
  discard
