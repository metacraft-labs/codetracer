## host_test_oracle_test.nim
##
## `ct host` must refuse test-oracle output by name.
##
## A folder holding a `trace.json` event stream is what the pure Python and
## Ruby recorders write, to be compared against `ct print` of a production
## recording. It is not a recording, so `ct host` must not register it as a
## legacy materialized trace (which would hand it to a debugger that refuses
## it), and the user must be told why instead of getting "not a hostable
## trace folder".
##
## No mocks: real folders in a real temporary directory, run through the
## production lookup.
##
## Lane: `ct-trace-units` (discovered by `src/ct/trace/*_test.nim`).

import
  std / [ os, strutils, unittest ],
  ./host,
  ./trace_kind

proc scratchDir(name: string): string =
  result = getTempDir() / "ct-host-test-oracle-test" / name
  removeDir(result)
  createDir(result)

suite "ct host and test-oracle output":
  test "a trace.json folder is refused as test-oracle output":
    let dir = scratchDir("oracle")
    writeFile(dir / "trace.json", "[]")
    writeFile(dir / "trace_metadata.json", """{"program":"main.rb"}""")
    writeFile(dir / "trace_paths.json", "[]")
    var message = ""
    try:
      discard findLegacyMaterializedTraceFolder(dir)
    except ValueError as e:
      message = e.msg
    check TestOracleOutputError in message
    check dir in message

  test "a trace.json one level down is refused the same way":
    let dir = scratchDir("oracle-nested")
    createDir(dir / "run")
    writeFile(dir / "run" / "trace.json", "[]")
    writeFile(dir / "run" / "trace_metadata.json", """{"program":"main.rb"}""")
    var message = ""
    try:
      discard findLegacyMaterializedTraceFolder(dir)
    except ValueError as e:
      message = e.msg
    check TestOracleOutputError in message

  test "a legacy trace.bin folder is still found":
    let dir = scratchDir("legacy-bin")
    writeFile(dir / "trace.bin", "\x00\x01")
    writeFile(dir / "trace_metadata.json", """{"program":"main.py"}""")
    check findLegacyMaterializedTraceFolder(dir) == dir
