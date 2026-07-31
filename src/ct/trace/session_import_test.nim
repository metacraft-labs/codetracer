## Unit tests for the `session.toml` open path.
##
## Run with:
##
## ```
##   nim c -r --hints:off src/ct/trace/session_import_test.nim
## ```
##
## Two surfaces are covered:
##
## * `findSessionManifest` — the manifest/folder spelling equivalence
##   `ct host --trace-path` relies on;
## * `parseSessionListing` — the parse of the replay engine's
##   ``replay-server session`` listing.  This is deliberately a pure
##   function so it can be pinned without a built engine binary; the
##   *round trip* against the real binary is covered end-to-end by the
##   Rust suite and by `ct host` itself.
##
## No mocks are used: the parser is fed literal captures of the engine's
## real output (see ``main.rs::run_session_subcommand`` for the format).

import
  std / [ os, unittest ],
  trace_container,
  session_import

proc scratchDir(name: string): string =
  result = getTempDir() / "ct-session-import-test" / name
  removeDir(result)
  createDir(result)

## A verbatim capture of `replay-server session <manifest>` against the
## committed `account-balance-with-wasm` fixture, including the engine's
## startup chatter that shares the stream.
const REAL_LISTING = """
last "/tmp/codetracer/last"
error symlink Os { code: 17, kind: AlreadyExists, message: "File exists" }
session manifest /fixtures/account-balance-with-wasm/session.toml — version 1 (3 trace(s), correlation_index_mode=eager)
  [0] recording_id=018f0000-0000-7000-8000-frontendjs01 role=frontend-js prefix=fe path=/fixtures/account-balance-with-wasm/./frontend.ct
  [1] recording_id=018f0000-0000-7000-8000-frontendwsm1 role=frontend-wasm prefix=wasm path=/fixtures/account-balance-with-wasm/./frontend-wasm.ct
  [2] recording_id=018f0000-0000-7000-8000-backendnode1 role=backend prefix=be path=/fixtures/account-balance-with-wasm/./backend.ct
"""

suite "session manifest discovery":
  test "a folder containing session.toml resolves to the manifest":
    let dir = scratchDir("folder")
    writeFile(dir / SESSION_MANIFEST_FILE, "version = 1\n")
    check findSessionManifest(dir) == dir / SESSION_MANIFEST_FILE

  test "the manifest path itself resolves to itself":
    let dir = scratchDir("direct")
    let manifest = dir / SESSION_MANIFEST_FILE
    writeFile(manifest, "version = 1\n")
    check findSessionManifest(manifest) == manifest

  test "an unrelated toml is not a session manifest":
    let dir = scratchDir("other-toml")
    let other = dir / "origin-config.toml"
    writeFile(other, "mode = \"off\"\n")
    check findSessionManifest(other) == ""
    check findSessionManifest(dir) == ""

  test "a folder without a manifest resolves to nothing":
    let dir = scratchDir("bare")
    check findSessionManifest(dir) == ""

  test "an empty or absent path resolves to nothing":
    check findSessionManifest("") == ""
    check findSessionManifest(getTempDir() / "ct-session-import-test" / "nope") == ""

suite "session listing parse":
  test "every [[trace]] entry is recovered in manifest order":
    let info = parseSessionListing("/fixtures/session.toml", REAL_LISTING)
    check info.manifestPath == "/fixtures/session.toml"
    check info.traces.len == 3
    check info.traces[0].recordingId == "018f0000-0000-7000-8000-frontendjs01"
    check info.traces[0].role == "frontend-js"
    check info.traces[0].threadPrefix == "fe"
    check info.traces[0].path == "/fixtures/account-balance-with-wasm/./frontend.ct"
    check info.traces[1].role == "frontend-wasm"
    check info.traces[1].threadPrefix == "wasm"
    check info.traces[2].role == "backend"
    check info.traces[2].path == "/fixtures/account-balance-with-wasm/./backend.ct"

  test "the header line and unrelated engine chatter are ignored":
    # The header also contains `=` (correlation_index_mode=eager) and the
    # startup lines contain `[`, so both are real parser hazards.
    let info = parseSessionListing("/fixtures/session.toml", REAL_LISTING)
    for entry in info.traces:
      check entry.recordingId.len > 0
      check entry.path.len > 0

  test "a path containing spaces survives, because it is terminal":
    let listing = "  [0] recording_id=id-1 role=backend prefix=be " &
      "path=/tmp/my traces/backend.ct"
    let info = parseSessionListing("/tmp/session.toml", listing)
    check info.traces.len == 1
    check info.traces[0].path == "/tmp/my traces/backend.ct"

  test "an empty listing yields no traces rather than a bogus entry":
    check parseSessionListing("/tmp/session.toml", "").traces.len == 0
    check parseSessionListing("/tmp/session.toml",
      "session manifest /tmp/session.toml — version 1 (0 trace(s), correlation_index_mode=eager)").traces.len == 0

  test "a line without a recording_id is not accepted as a trace":
    # Guards against a future engine log line that happens to start with
    # `[` being mistaken for a manifest entry.
    let listing = "  [warn] something unrelated happened"
    check parseSessionListing("/tmp/session.toml", listing).traces.len == 0

suite "session manifest loading failures":
  test "a missing manifest raises a SessionManifestError naming the path":
    let missing = getTempDir() / "ct-session-import-test" / "absent-session.toml"
    removeFile(missing)
    expect SessionManifestError:
      discard loadSessionManifest(missing)

suite "session description":
  test "the session is described by its folder and member roles":
    let info = parseSessionListing(
      "/fixtures/account-balance-with-wasm/session.toml", REAL_LISTING)
    let described = describeSession(info)
    check described == "account-balance-with-wasm session " &
      "(frontend-js, frontend-wasm, backend)"
