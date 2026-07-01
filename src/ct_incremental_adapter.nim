## ct_incremental_adapter -- the watch-integration decision seam, backed by
## codetracer's canonical incremental engine invoked as a subprocess.
##
## Reprobuild's `repro watch --ct-incremental` needs a small decision API it can
## call on every filesystem-change cycle. CodeTracer owns the actual
## incremental engine; this adapter preserves that boundary by executing the
## `ct` binary instead of importing engine modules.
##
## The subprocess protocol lives in `src/ct_test/incremental_cli.nim`:
##   * `ct test --incremental --watch-decide ...`
##       -> `{"status":"run"|"skip","reason":..,"changedFuncs":[..]}`
##   * `ct test --incremental --watch-record ...`
##       -> `{"ok":bool,"error":str}`
##
## This module intentionally imports only std modules. Any subprocess failure
## is a conservative re-run, never a silent skip.

import std/[json, os, osproc, strutils]

type
  WatchEdgeAction* = enum
    ## What the watch loop should do with the watched test edge this cycle.
    weaRun
    weaSkip

  WatchEdgeDecision* = object
    ## The seam's verdict for one watched test edge on one change cycle.
    action*: WatchEdgeAction
    testId*: string
    reason*: string
    changedFuncs*: seq[string]

  WatchCtIncrementalGate* = object
    ## The enable/disable gate for the `--ct-incremental` watch feature.
    enabled*: bool

func runDecision(testId, reason: string;
                 changedFuncs: seq[string] = @[]): WatchEdgeDecision =
  WatchEdgeDecision(action: weaRun, testId: testId, reason: reason,
                    changedFuncs: changedFuncs)

func skipDecision(testId: string): WatchEdgeDecision =
  WatchEdgeDecision(action: weaSkip, testId: testId, reason: "unchanged")

proc ctBin(): string =
  ## Prefer the explicit CI/dev override, otherwise rely on `ct` on PATH.
  let fromEnv = getEnv("CT_BIN")
  if fromEnv.len > 0: fromEnv else: "ct"

func defaultCachePath*(root = "."): string =
  ## The incremental cache path expected by CodeTracer's engine.
  root / ".ct-incremental" / "cache.json"

proc runCt(mode: string; testId, traceDir, sourceRoot, cachePath: string;
           extra: seq[string] = @[]): tuple[ok: bool, output, err: string] =
  let cmd = quoteShellCommand(@[ctBin(), "test", "--incremental", mode,
    "--test-id", testId, "--trace-dir", traceDir,
    "--source-root", sourceRoot, "--cache-path", cachePath] & extra)
  try:
    let (output, code) = execCmdEx(cmd)
    if code != 0:
      return (false, output, "ct exited " & $code & ": " & output.strip())
    if output.strip().len == 0:
      return (false, output, "ct produced no output")
    (true, output, "")
  except OSError as e:
    (false, "", "could not exec ct (" & ctBin() & "): " & e.msg)

proc parseJsonLine(output: string): JsonNode =
  ## Parse the last non-empty line as JSON; ct may print warnings first.
  let lines = output.splitLines()
  for i in countdown(lines.high, 0):
    let s = lines[i].strip()
    if s.len == 0:
      continue
    try:
      return parseJson(s)
    except CatchableError:
      return nil
  nil

proc watchTestEdgeDecision*(testId, traceDir, sourceRoot, cachePath: string):
    WatchEdgeDecision =
  ## Decide skip vs. run by execing `ct test --incremental --watch-decide`.
  let res = runCt("--watch-decide", testId, traceDir, sourceRoot, cachePath)
  if not res.ok:
    return runDecision(testId, "error: " & res.err)

  let node = parseJsonLine(res.output)
  if node.isNil or node.kind != JObject or not node.hasKey("status"):
    return runDecision(testId, "error: malformed ct output: " &
      res.output.strip())

  let status = node["status"].getStr()
  if status == "skip":
    return skipDecision(testId)

  var changed: seq[string]
  if node.hasKey("changedFuncs"):
    for c in node["changedFuncs"]:
      changed.add c.getStr()
  let reason = if node.hasKey("reason"): node["reason"].getStr() else: "run"
  runDecision(testId, reason, changed)

proc recordWatchTestEdge*(testId, traceDir, sourceRoot, cachePath: string;
                          deterministic = true): tuple[ok: bool, error: string] =
  ## Refresh the cache by execing `ct test --incremental --watch-record`.
  let extra = if deterministic: newSeq[string]() else: @["--non-deterministic"]
  let res = runCt("--watch-record", testId, traceDir, sourceRoot, cachePath,
    extra)
  if not res.ok:
    return (false, res.err)

  let node = parseJsonLine(res.output)
  if node.isNil or node.kind != JObject or not node.hasKey("ok"):
    return (false, "malformed ct output: " & res.output.strip())
  if node["ok"].getBool():
    (true, "")
  else:
    (false, if node.hasKey("error"): node["error"].getStr() else: "record failed")

proc gatedWatchDecision*(gate: WatchCtIncrementalGate;
                         testId, traceDir, sourceRoot, cachePath: string):
    WatchEdgeDecision =
  ## Disabled mode preserves legacy behavior and does not execute `ct`.
  if not gate.enabled:
    return runDecision(testId, "ct-incremental-disabled")
  watchTestEdgeDecision(testId, traceDir, sourceRoot, cachePath)
