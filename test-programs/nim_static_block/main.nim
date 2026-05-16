# Nim test program for the Trace Static Block Execution E2E test.
#
# The `static:` block does real work (a few strtabs-style operations)
# so that nimsuggest's `tracestatic` query produces a non-trivial .ct
# trace.  The fixture mirrors the `testSource` constant in
# codetracer-nim/tests/sourcemap/tvm_trace_static.nim.

import std/strtabs

static:
  let t = newStringTable(modeStyleInsensitive)
  t["alpha"] = "1"
  t["beta"] = "2"
  doAssert t["alpha"] == "1"
  doAssert t["beta"] == "2"

proc main() =
  echo "static block test"
  echo "alpha entries handled at compile time"

main()
