## Headless tests for the VFS marshaller and the `VfsResponse` decoder.
##
## LANE: `vm-unit` AND `vm-unit-js`, both by the directory glob. The subject is
## pure — no browser, no worker, no `when defined(js)` — so the backend the
## renderer ships on runs all of it.
##
## Compile and run:
##   nim c  -r src/frontend/viewmodel/tests/unit/test_noir_build_marshalling.nim
##   nim js -r src/frontend/viewmodel/tests/unit/test_noir_build_marshalling.nim
##
## ## Why the fixtures are VERBATIM WASM OUTPUT and not hand-written JSON
##
## Every response literal below was produced by running the real
## `noir_wasm.wasm` (built from the `noir` fork's `codetracer` branch) over the
## bundled template and copying what came back — one file per case, recorded in
## the comment above it with the source that produced it. A hand-written
## fixture proves the decoder agrees with the person who wrote the fixture,
## which is the same person who wrote the decoder.
##
## The two facts that a hand-written fixture would have got wrong, and did get
## wrong before these were measured:
##
##   * `warnings` and `diagnostics` are ABSENT, not `[]`, when empty. Both
##     carry `#[serde(skip_serializing_if = "Vec::is_empty")]`. A decoder that
##     indexed rather than probed raises on every successful build.
##   * a RESOLVE refusal carries zero diagnostics and one positioned message.
##     `{"ok":false}` with an empty diagnostic list is what the two most likely
##     first-run mistakes look like, and a pane rendering only `diagnostics`
##     paints nothing for either.

import std/[json, strutils, unittest]

import ../../platform/noir_build
import ../../platform/noir_template

# ---------------------------------------------------------------------------
# Counted assertions. `counted` is a TEMPLATE so `check` is inlined into the
# `test` body where `testStatusIMPL` is in scope — inside a proc every check
# would print and still report [OK].
# ---------------------------------------------------------------------------
var countedAssertions = 0

template counted(condition: untyped) =
  inc countedAssertions
  check condition

const ExpectedAssertions = 172
  ## Asserted by the last case. Update it deliberately, in the same commit as
  ## the checks that moved it.

# ---------------------------------------------------------------------------
# Fixtures: real `noir_wasm.wasm` output
# ---------------------------------------------------------------------------

const CleanCompile = """{"ok":true,"plan":{"entry_point":"hello_noir/src/main.nr","package_type":"bin"},"artifact":{"noir_version":"1.0.0-beta.26","hash":1234,"abi":{},"bytecode":"H4sI"}}"""
  ## `mode: "debug"` over the bundled template. NOTE the absent `warnings` and
  ## `diagnostics` keys — see the header.

const TypeError = """{"ok":false,"stage":"compile","kind":"compile-error","message":"the program did not compile: 1 diagnostic(s)","plan":{},"diagnostics":[{"message":"expected type u8, found type ()","file":"hello_noir/src/utils.nr","line":3,"column":41,"end_line":3,"end_column":43,"start":66,"end":68,"secondary_messages":["expected u8 because of return type","() returned here"],"notes":[],"severity":"error"}]}"""
  ## Produced by changing `pub fn assert_in_range(value: Field) {` to
  ## `... -> u8 {` in the template's `src/utils.nr`.

const MixedSeverities = """{"ok":false,"stage":"compile","kind":"compile-error","message":"the program did not compile: 2 diagnostic(s)","diagnostics":[{"message":"Unused expression result of type Field","file":"hello_noir/src/main.nr","line":3,"column":5,"end_line":3,"end_column":10,"start":40,"end":45,"secondary_messages":[],"notes":[],"severity":"warning"},{"message":"Could not resolve 'nope' in path","file":"hello_noir/src/main.nr","line":4,"column":12,"end_line":4,"end_column":16,"start":58,"end":62,"secondary_messages":[],"notes":[],"severity":"error"}]}"""
  ## `mode: "program"` over a `main` carrying BOTH `x + y;` (an unused
  ## expression) and `utils::nope(x)`. Measured: `program` reports both,
  ## `debug` reports only the error, because `debugging_compile_options()`
  ## sets `silence_warnings: true`. That measurement is why Build asks for
  ## `program` and Run asks for `debug`, and it is the fixture that proves the
  ## severities are not all forced to one value.

const GitDependencyRefused = """{"ok":false,"stage":"resolve","kind":"git-dependency-refused","message":"hello_noir/Nargo.toml:7:8: the dependency `util` is a GIT dependency (git = \"https://example.com/u\", tag = \"v1\"). A virtual filesystem cannot fetch it, and fetching one is not what compiling from a virtual filesystem means.","manifest":"hello_noir/Nargo.toml","line":7,"column":8}"""

const MissingManifest = """{"ok":false,"stage":"resolve","kind":"missing-manifest","message":"hello_noir/Nargo.toml: no Nargo.toml at this path in the virtual filesystem","manifest":"hello_noir/Nargo.toml"}"""
  ## A manifest and NO line — `VfsError::position()` is `None` here. The one
  ## fixture that separates `hasRefusalPosition` from `refusalIsPositioned`.

const TraceDocument = """{"events":[{"Path":"hello_noir/src/main.nr"},{"Call":{"function_id":0}},{"Step":{"path_id":0,"line":5}},{"Step":{"path_id":0,"line":6}},{"Call":{"function_id":1}},{"Step":{"path_id":1,"line":4}},{"Return":{}}],"paths":["hello_noir/src/main.nr","hello_noir/src/utils.nr"],"workdir":""}"""
  ## The shape of a real `MemoryTrace`, trimmed. The counts below are of THIS
  ## document, not of the 36-event one the full template produces — a fixture
  ## small enough to read is a fixture whose expected counts can be checked by
  ## eye.

const TrivialTrace = """{"events":[{"Path":"hello_noir/src/main.nr"}],"paths":["hello_noir/src/main.nr"]}"""
  ## ONE-EVENT-ZERO-STEPS: what an artifact compiled WITHOUT instrumentation
  ## traces to while both wasm modules report `ok`.
  ## `ci/test/noir-wasm-worker/compare.mjs`'s header records the measurement.

suite "the VFS a compile request carries":

  test "the bundled template marshals into the shape nv_compile_vfs wants":
    let tmpl = noirHelloWorld()
    var entries: seq[NoirSourceEntry] = @[]
    for file in tmpl.files:
      entries.add NoirSourceEntry(
        path: noirVfsPath(tmpl.name, file.path), content: file.content)

    let request = noirVfsRequest(entries, tmpl.name, nbmDebug)

    # THE THREE TOP-LEVEL KEYS, by name. `VfsRequest` deserializes by name and
    # a misspelling comes back as `kind: "bad-request"` naming serde rather
    # than the project.
    counted request.kind == JObject
    counted request.hasKey("files")
    counted request.hasKey("package_dir")
    counted request.hasKey("mode")
    counted request["files"].kind == JObject
    counted request["package_dir"].getStr == "hello_noir"
    counted request["mode"].getStr == "debug"

    # `files` is an OBJECT keyed by path, because `VfsRequest.files` is a
    # `BTreeMap<String, String>`. An array of pairs type-checks in JSON and is
    # refused by serde.
    counted request["files"].len == tmpl.files.len
    counted request["files"].len == 5

    # EVERY key carries the package-dir PREFIX. `resolve_vfs(&tree,
    # "hello_noir")` looks up the literal key `hello_noir/Nargo.toml`; a tree
    # keyed project-relative resolves to nothing.
    var prefixed = 0
    for path, content in request["files"].pairs:
      counted path.startsWith("hello_noir/")
      counted content.kind == JString
      inc prefixed
    counted prefixed == 5

    # And NO key carries the renderer's leading slash. The renderer keys tabs
    # by `/hello_noir/src/main.nr` and the compiler must not be handed that
    # spelling — the two are different on purpose.
    for path, _ in request["files"].pairs:
      counted not path.startsWith("/")

    # The four sources the compiler actually reads, plus the inputs file.
    counted request["files"].hasKey("hello_noir/Nargo.toml")
    counted request["files"].hasKey("hello_noir/src/main.nr")
    counted request["files"].hasKey("hello_noir/src/tests.nr")
    counted request["files"].hasKey("hello_noir/src/utils.nr")
    counted request["files"].hasKey("hello_noir/" & noirInputsFile)

    # CONTENT, not just presence. A marshaller that shipped every file as ""
    # would satisfy every assertion above.
    counted "fn main(x: Field, y: pub Field)" in
      request["files"]["hello_noir/src/main.nr"].getStr
    counted "name = \"hello_noir\"" in
      request["files"]["hello_noir/Nargo.toml"].getStr

  test "build and run ask for different modes, and the difference is measured":
    # `nbmProgram` reports warnings; `nbmDebug` silences them and is the only
    # mode whose artifact a tracer can walk. Two different questions.
    let entries = @[NoirSourceEntry(path: "p/Nargo.toml", content: "")]
    counted noirVfsRequest(entries, "p", nbmProgram)["mode"].getStr == "program"
    counted noirVfsRequest(entries, "p", nbmDebug)["mode"].getStr == "debug"
    counted $nbmProgram == "program"
    counted $nbmDebug == "debug"
    counted $nbmProgram != $nbmDebug

  test "the package dir is a prefix, not a root":
    counted noirVfsPath("hello_noir", "src/main.nr") == "hello_noir/src/main.nr"
    counted noirVfsPath("hello_noir", "Nargo.toml") == "hello_noir/Nargo.toml"
    # A package at the tree root keeps its paths bare rather than growing a
    # leading separator.
    counted noirVfsPath("", "src/main.nr") == "src/main.nr"

  test "the trace request carries the artifact and the inputs verbatim":
    let artifact = %*{"bytecode": "H4sI", "abi": {}}
    let request = noirTraceRequest(artifact, "x = \"1\"\ny = \"2\"\n")
    # The worker reads exactly these two fields off it.
    counted request.hasKey("artifact")
    counted request.hasKey("inputs")
    counted request["artifact"]["bytecode"].getStr == "H4sI"
    # TOML TEXT, not a JSON object: the worker passes `inputs_are_json = 0`.
    counted request["inputs"].kind == JString
    counted request["inputs"].getStr == "x = \"1\"\ny = \"2\"\n"
    # A nil artifact becomes `null` rather than crashing the renderer. The
    # trace phase only runs after a successful compile, so this is the state
    # after a chaining bug — and it must reach the tracer as a refusal rather
    # than as an exception in a tab.
    counted noirTraceRequest(nil, "")["artifact"].kind == JNull

  test "the subcommands the worker routes on are the ones we send":
    # `wasm_worker_browser.js` picks `args.find(a => !a.startsWith('-'))`, and
    # `wasm_registry.subcommandOf` resolves the same way. Both must see the
    # same word.
    counted noirCompileArgs() == @["compile"]
    counted noirTraceArgs() == @["trace"]
    counted noirCompileArgs()[0] == noirCompileSubcommand
    counted noirTraceArgs()[0] == noirTraceSubcommand
    counted not noirCompileArgs()[0].startsWith("-")
    counted not noirTraceArgs()[0].startsWith("-")

suite "what the compiler answers, decoded":

  test "a clean compile carries an artifact and NO warnings key":
    let response = parseNoirCompileResponse(CleanCompile)
    counted response.decoded
    counted response.ok
    counted not response.artifact.isNil
    counted response.artifact["bytecode"].getStr == "H4sI"
    # The absent-vs-empty distinction, asserted rather than assumed.
    counted response.warnings.len == 0
    counted response.diagnostics.len == 0
    counted diagnosticCount(response) == 0
    counted not hasRefusalPosition(response)

  test "a compile error is decoded field for field":
    let response = parseNoirCompileResponse(TypeError)
    counted response.decoded
    counted not response.ok
    counted response.stage == "compile"
    counted response.kind == "compile-error"
    counted response.artifact.isNil
    counted response.diagnostics.len == 1

    let diagnostic = response.diagnostics[0]
    counted diagnostic.message == "expected type u8, found type ()"
    counted diagnostic.file == "hello_noir/src/utils.nr"
    counted diagnostic.line == 3
    counted diagnostic.column == 41
    counted diagnostic.endLine == 3
    counted diagnostic.endColumn == 43
    counted diagnostic.startByte == 66
    counted diagnostic.endByte == 68
    counted diagnostic.severity == ndsError
    counted diagnostic.severityText == "error"
    # The secondaries are the half of the diagnostic that makes it
    # actionable — "expected type u8" alone does not say where the `u8` came
    # from.
    counted diagnostic.secondaryMessages.len == 2
    counted diagnostic.secondaryMessages[0] == "expected u8 because of return type"
    counted diagnostic.secondaryMessages[1] == "() returned here"
    counted diagnostic.notes.len == 0

  test "severities are read, not assumed — a mixed response stays mixed":
    # THE CHECK THE DESKTOP TEXT MATCHER FAILS. Its box-drawing parse forces
    # every severity to error; this path gets a field and must keep it.
    let response = parseNoirCompileResponse(MixedSeverities)
    counted response.diagnostics.len == 2
    counted countBySeverity(response.diagnostics, ndsWarning) == 1
    counted countBySeverity(response.diagnostics, ndsError) == 1
    counted countBySeverity(response.diagnostics, ndsBug) == 0
    counted countBySeverity(response.diagnostics, ndsInfo) == 0
    counted countBySeverity(response.diagnostics, ndsUnknown) == 0
    # The counts sum to the list, so a mutation that dropped a row cannot hide
    # behind two independent counts.
    counted countBySeverity(response.diagnostics, ndsWarning) +
      countBySeverity(response.diagnostics, ndsError) ==
      response.diagnostics.len
    # And they are attached to the RIGHT rows, in order.
    counted response.diagnostics[0].severity == ndsWarning
    counted response.diagnostics[1].severity == ndsError
    counted response.diagnostics[0].line == 3
    counted response.diagnostics[1].line == 4

  test "every DiagnosticKind spelling maps, and an unknown one is NAMED":
    # `vfs.rs` produces `format!("{:?}", kind).to_lowercase()` over an enum
    # with exactly four cases.
    counted noirSeverityOf("error") == ndsError
    counted noirSeverityOf("warning") == ndsWarning
    counted noirSeverityOf("bug") == ndsBug
    counted noirSeverityOf("info") == ndsInfo
    # Case-insensitive, because the `to_lowercase()` is one line on the far
    # side of a repository boundary; matching only the lowered form would
    # reclassify EVERY diagnostic at once the day it moved.
    counted noirSeverityOf("Error") == ndsError
    counted noirSeverityOf("WARNING") == ndsWarning
    # A fifth spelling is `ndsUnknown` and NOT silently `ndsError`: a decoder
    # that called everything an error cannot be told apart from one that reads
    # the field, which is the defect being repaired on the desktop side.
    counted noirSeverityOf("catastrophe") == ndsUnknown
    counted noirSeverityOf("") == ndsUnknown
    # And the raw word survives, so `ndsUnknown` can say what it did not know.
    let unknown = parseNoirDiagnostic(%*{
      "message": "m", "file": "f", "line": 1, "column": 1,
      "severity": "catastrophe"})
    counted unknown.severity == ndsUnknown
    counted unknown.severityText == "catastrophe"

  test "a resolve refusal carries a position and NO diagnostics":
    let response = parseNoirCompileResponse(GitDependencyRefused)
    counted response.decoded
    counted not response.ok
    counted response.stage == "resolve"
    counted response.kind == "git-dependency-refused"
    # ZERO diagnostics, and this is the whole point of the case: a pane
    # rendering only `diagnostics` paints nothing here.
    counted response.diagnostics.len == 0
    counted response.warnings.len == 0
    counted hasRefusalPosition(response)
    counted refusalIsPositioned(response)
    counted response.manifest == "hello_noir/Nargo.toml"
    counted response.line == 7
    counted response.column == 8
    counted "`util`" in response.message

  test "a missing manifest names a file and no line":
    # The fixture that separates the two accessors. `VfsError::position()` is
    # `None` here, so a caller that assumed a line would paint row 0 — a jump
    # target that navigates a user to nothing.
    let response = parseNoirCompileResponse(MissingManifest)
    counted response.decoded
    counted hasRefusalPosition(response)
    counted not refusalIsPositioned(response)
    counted response.manifest == "hello_noir/Nargo.toml"
    counted response.line == 0
    counted response.kind == "missing-manifest"

  test "something that is not a VfsResponse is a THIRD outcome":
    # A compile that produced no diagnostics and a worker that answered with
    # something else are identical in every other field, and are fixed by
    # different people.
    for raw in ["", "not json at all", "[1,2,3]", "{\"hello\":1}",
                "<!doctype html><html>"]:
      let response = parseNoirCompileResponse(raw)
      counted not response.decoded
      counted not response.ok
      counted response.raw == raw
    # CONTROL ARM: a well-formed response over the same decoder IS decoded,
    # so the assertions above are about the input and not about a decoder that
    # refuses everything.
    counted parseNoirCompileResponse(CleanCompile).decoded
    counted parseNoirCompileResponse(TypeError).decoded

  test "a diagnostic missing every optional field still names its file":
    # `PositionedDiagnostic` gains fields upstream from time to time. A rename
    # must degrade to a row that still points somewhere rather than raising
    # inside a build.
    let sparse = parseNoirDiagnostic(%*{
      "message": "boom", "file": "hello_noir/src/main.nr", "severity": "error"})
    counted sparse.message == "boom"
    counted sparse.file == "hello_noir/src/main.nr"
    counted sparse.line == 0
    counted sparse.secondaryMessages.len == 0
    counted sparse.notes.len == 0
    counted sparse.severity == ndsError
    # A field of the WRONG TYPE is a fallback, not a crash: `line` as a string
    # is what a future schema change looks like from here.
    let wrongType = parseNoirDiagnostic(%*{
      "message": "boom", "file": "f", "line": "3", "severity": "error"})
    counted wrongType.line == 0
    counted wrongType.message == "boom"

suite "what the tracer answers, counted":

  test "a real trace is counted by tag":
    let summary = summariseNoirTrace(TraceDocument)
    counted summary.decoded
    counted summary.events == 7
    counted summary.steps == 3
    counted summary.calls == 2
    counted summary.paths.len == 2
    counted summary.paths[0] == "hello_noir/src/main.nr"
    counted summary.paths[1] == "hello_noir/src/utils.nr"
    counted summary.bytes == TraceDocument.len
    counted not isTrivialTrace(summary)
    # Events that are neither Step nor Call are counted as events and as
    # neither — the totals must not be made to add up by miscounting.
    counted summary.steps + summary.calls < summary.events

  test "ONE-EVENT-ZERO-STEPS is reported as trivial, not as success":
    let summary = summariseNoirTrace(TrivialTrace)
    counted summary.decoded
    counted summary.events == 1
    counted summary.steps == 0
    counted isTrivialTrace(summary)
    # And an undecodable answer is trivial too — "it returned bytes" is not a
    # trace.
    counted isTrivialTrace(summariseNoirTrace("not a trace"))
    counted isTrivialTrace(summariseNoirTrace(""))
    counted summariseNoirTrace("not a trace").bytes == "not a trace".len
    counted not summariseNoirTrace("not a trace").decoded

suite "the template can be run":

  test "the bundled template ships the inputs a bin package needs":
    # `tracer_wasm`: "`inputs` is the text of a `Prover.toml`". Without one
    # there is nothing to encode against `main`'s ABI, which is why Run did
    # nothing before this file existed.
    let tmpl = noirHelloWorld()
    counted tmpl.templateFileCount == 5
    counted fileContent(tmpl, noirInputsFile).len > 0
    counted noirInputsFile == "Prover.toml"
    # Every parameter of `main(x: Field, y: pub Field)` is named. A
    # `Prover.toml` missing one is refused by the ABI encoder at run time,
    # which reads as "your program is broken" about a template that is fine.
    let inputs = fileContent(tmpl, noirInputsFile)
    counted "x = " in inputs
    counted "y = " in inputs
    # QUOTED, because `Field` is arbitrary-precision and nargo's TOML format
    # takes those as strings; a bare integer does not round-trip above 2^63.
    counted "\"" in inputs
    # THE VALUES ARE THE TEMPLATE'S OWN PASSING CASE. `test_main()` calls
    # `main(1, 2)`, so the first Run reproduces a test the visitor can see
    # rather than tripping `assert(x != y)` with two zeroes.
    counted "main(1, 2)" in fileContent(tmpl, noirEntryFile)
    counted "x = \"1\"" in inputs
    counted "y = \"2\"" in inputs
    # The file is in the tree, so the visitor can find and edit it.
    var found = 0
    for file in tmpl.files:
      if file.path == noirInputsFile: inc found
    counted found == 1

  test "noir_build_marshalling_assertion_count_is_measured":
    # The count is asserted so deleting or short-circuiting a check above
    # cannot pass silently: it has to move this number in the same commit.
    # Universal quantification over an empty set passes vacuously, and several
    # cases above are `for` loops.
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
