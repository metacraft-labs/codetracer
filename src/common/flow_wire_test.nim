## `flow_wire`: the elided fixture restores to exactly the full one, natively
## and (built with `nim js`) on the raw object the desktop reads; an unknown
## encoding is refused; an unmarked update is read as it is. The fixtures are
## `libs/ct-flow-wire`'s, written by the replay server's encoder.

import std/[json, os, unittest]
import flow_wire

when defined(js):
  import std/jsffi
  proc jsParse(text: cstring): JsObject {.importjs: "JSON.parse(#)".}
  proc jsStringify(o: JsObject): cstring {.importjs: "JSON.stringify(#)".}

const fixtures = currentSourcePath.parentDir / ".." / ".." / "libs" / "ct-flow-wire" / "tests" / "fixtures"
const fullText = staticRead(fixtures / "flow-update.full.json")
const elidedText = staticRead(fixtures / "flow-update.elided.json")

suite "flow wire":
  test "the elided fixture restores to exactly the full one":
    let update = parseJson(elidedText)
    check restoreElidedFlowValues(update) == ""
    check update == parseJson(fullText)

  test "an update without the marker is read as it is":
    let update = parseJson(fullText)
    check restoreElidedFlowValues(update) == ""
    check update == parseJson(fullText)

  test "an unknown encoding is refused":
    let update = %*{"valueEncoding": "elided-defaults-2", "viewUpdates": []}
    check restoreElidedFlowValues(update).len > 0

  when defined(js):
    test "the raw object restores to exactly the full one":
      let update = jsParse(cstring(elidedText))
      check restoreElidedFlowValuesJs(update) == cstring""
      # Key order differs from the fixture's; compare as parsed JSON.
      check parseJson($jsStringify(update)) == parseJson(fullText)

    test "the raw object refuses an unknown encoding":
      let update = jsParse(cstring"""{"valueEncoding": "x", "viewUpdates": []}""")
      check restoreElidedFlowValuesJs(update) != cstring""
