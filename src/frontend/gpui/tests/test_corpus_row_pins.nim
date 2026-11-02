## No mocks: exercises the JSON reader used by the live corpus gate. Distinct
## literals stand for different platform measurements so a wrong branch is red.
import std/[json, unittest]
import corpus_row_pins

suite "corpus row pins retain platform provenance":
  let pins = %*{"gpuiEditorRows": ["linux"],
               "gpuiEditorRowsDarwin": ["darwin"],
               "electronEditorRows": ["electron"]}

  test "Darwin prefers its exact pin; other hosts keep the default":
    check admissibleRows(pins, "gpuiEditorRows", true) == @["darwin"]
    check admissibleRows(pins, "gpuiEditorRows", false) == @["linux"]
    check admissibleRows(pins, "gpuiEditorRows") ==
      (when defined(macosx): @["darwin"] else: @["linux"])

  test "a legacy pin falls back on both platforms":
    let legacy = %*{"gpuiEditorRows": ["legacy"]}
    check admissibleRows(legacy, "gpuiEditorRows", true) == @["legacy"]
    check admissibleRows(legacy, "gpuiEditorRows", false) == @["legacy"]

  test "Electron is unaffected by GPUI platform selection":
    check admissibleRows(pins, "electronEditorRows", true) == @["electron"]
    check admissibleRows(pins, "electronEditorRows", false) == @["electron"]

  test "an empty Darwin override is not hidden by fallback":
    let empty = %*{"gpuiEditorRows": ["linux"], "gpuiEditorRowsDarwin": []}
    check admissibleRows(empty, "gpuiEditorRows", true).len == 0
    check admissibleRows(empty, "gpuiEditorRows", false) == @["linux"]

  test "a missing pin stays empty":
    check admissibleRows(newJObject(), "gpuiEditorRows", true).len == 0
    check admissibleRows(newJObject(), "gpuiEditorRows", false).len == 0

  test "malformed overrides fail closed instead of widening to the default":
    for invalid in [%*"not-an-array", %*[12], %*["darwin", 12]]:
      let malformed = %*{"gpuiEditorRows": ["linux"],
                        "gpuiEditorRowsDarwin": invalid}
      check admissibleRows(malformed, "gpuiEditorRows", true).len == 0
      check admissibleRows(malformed, "gpuiEditorRows", false) == @["linux"]
