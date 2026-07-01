## Process-seam tests for the standalone `ct_incremental_adapter` module.

import std/[os, strutils, unittest]

import ct_incremental_adapter

let fakeCt = getTempDir() / "ct_fake_seam.sh"

proc installFakeCt() =
  writeFile(fakeCt,
    "#!/bin/sh\nprintf '%s\\n' \"$CT_FAKE_OUT\"\nexit ${CT_FAKE_CODE:-0}\n")
  inclFilePermissions(fakeCt, {fpUserExec, fpGroupExec, fpOthersExec})
  putEnv("CT_BIN", fakeCt)

proc setFake(output: string; code = 0) =
  putEnv("CT_FAKE_OUT", output)
  putEnv("CT_FAKE_CODE", $code)

proc decideWith(output: string; code = 0): WatchEdgeDecision =
  setFake(output, code)
  watchTestEdgeDecision("t::id", "/trace", "/root", "/cache.json")

suite "ct_incremental_adapter subprocess protocol":
  setup:
    installFakeCt()

  teardown:
    delEnv("CT_BIN")
    delEnv("CT_FAKE_OUT")
    delEnv("CT_FAKE_CODE")

  test "skip status maps to weaSkip":
    let d = decideWith("""{"status":"skip","reason":"unchanged","changedFuncs":[]}""")
    check d.action == weaSkip
    check d.reason == "unchanged"
    check d.testId == "t::id"

  test "fresh run maps to weaRun":
    let d = decideWith("""{"status":"run","reason":"fresh","changedFuncs":[]}""")
    check d.action == weaRun
    check d.reason == "fresh"

  test "changed run forwards reason and changedFuncs":
    let d = decideWith(
      """{"status":"run","reason":"changed: used_a","changedFuncs":["used_a"]}""")
    check d.action == weaRun
    check d.reason == "changed: used_a"
    check d.changedFuncs == @["used_a"]

  test "non-zero ct exit is fail-safe run":
    let d = decideWith("""{"status":"skip","reason":"unchanged"}""", code = 1)
    check d.action == weaRun
    check d.reason.startsWith("error:")

  test "unparseable ct output is fail-safe run":
    let d = decideWith("not json at all")
    check d.action == weaRun
    check d.reason.startsWith("error:")

  test "warnings before JSON line still parse":
    let d = decideWith("warning: something\n{\"status\":\"skip\"}")
    check d.action == weaSkip

  test "recordWatchTestEdge maps ok":
    setFake("""{"ok":true,"error":""}""")
    let r = recordWatchTestEdge("t::id", "/trace", "/root", "/cache.json")
    check r.ok
    check r.error == ""

  test "recordWatchTestEdge maps engine error":
    setFake("""{"ok":false,"error":"trace missing"}""")
    let r = recordWatchTestEdge("t::id", "/trace", "/root", "/cache.json")
    check not r.ok
    check r.error == "trace missing"

  test "recordWatchTestEdge fail-safes on non-zero ct exit":
    setFake("""{"ok":true}""", code = 2)
    let r = recordWatchTestEdge("t::id", "/trace", "/root", "/cache.json")
    check not r.ok
    check r.error.len > 0

suite "ct_incremental_adapter standalone contract":
  test "gate disabled short-circuits without execing ct":
    putEnv("CT_BIN", "/nonexistent/ct-should-not-run")
    let gate = WatchCtIncrementalGate(enabled: false)
    let d = gatedWatchDecision(gate, "t::id", "/trace", "/root", "/cache.json")
    check d.action == weaRun
    check d.reason == "ct-incremental-disabled"
    delEnv("CT_BIN")

  test "missing ct binary is fail-safe run":
    putEnv("CT_BIN", "/nonexistent/ct-does-not-exist")
    let d = watchTestEdgeDecision("t::id", "/trace", "/root", "/cache.json")
    check d.action == weaRun
    check d.reason.startsWith("error:")
    delEnv("CT_BIN")

  test "default cache path matches engine layout":
    check defaultCachePath("/proj") == "/proj" / ".ct-incremental" / "cache.json"
    check defaultCachePath(".") == "." / ".ct-incremental" / "cache.json"
