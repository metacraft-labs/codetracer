## print_trace_test.nim
##
## `ct print` refuses test-oracle output by name.
##
## A `trace.json` event stream is what the pure Python and Ruby recorders
## write, to be compared against `ct print` of a production recording. It
## is not a recording, so `ct print` must neither decode it nor count it as
## one in a directory verification; it says what the file is instead.
##
## No mocks: real files in a real temporary directory, run through the
## production classification and verification.

import
  std / [ os, sequtils, strutils, unittest ],
  ./print_trace,
  ../trace/trace_kind

proc scratchDir(name: string): string =
  result = getTempDir() / "ct-print-trace-test" / name
  removeDir(result)
  createDir(result)

suite "ct print and test-oracle output":
  test "a trace.json file is classified as test-oracle output":
    let dir = scratchDir("oracle-file")
    writeFile(dir / "trace.json", "[]")
    check detectTraceType(dir / "trace.json") == ttTestOracle

  test "a folder holding a trace.json is classified as test-oracle output":
    let dir = scratchDir("oracle-dir")
    writeFile(dir / "trace.json", "[]")
    writeFile(dir / "trace_metadata.json", """{"program":"main.py"}""")
    check detectTraceType(dir) == ttTestOracle

  test "a folder holding a .ct container is still a recording":
    let dir = scratchDir("ct-dir")
    writeFile(dir / "trace.ct", "\xC0\xDE\x72\xAC\xE2payload")
    writeFile(dir / "trace.json", "[]")
    check detectTraceType(dir) == ttMcrTrace

  test "verifying a directory of oracle output fails with the refusal":
    let dir = scratchDir("oracle-parent")
    createDir(dir / "py-0")
    writeFile(dir / "py-0" / "trace.json", "[]")
    let verdict = verifyTraceDirectory(dir)
    check not verdict.valid
    check verdict.errors.anyIt(TestOracleOutputError in it)
